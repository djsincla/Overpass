import Foundation
import Network

public enum TransportError: Error, Equatable {
    case timedOut
    case closed
    case cannotOpen(String)
}

/// TCP to a serial relay on the mount's USB port, e.g. a Raspberry Pi running ser2net.
/// Special Mode only works over USB, so this is how iPhone and iPad reach the mount.
public actor TCPTransport: MountTransport {
    private let connection: NWConnection
    private var buffer = Data()
    public let timeout: Double

    public init(host: String, port: UInt16, timeout: Double = 2) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        self.timeout = timeout
    }

    public func open() async throws {
        let connection = connection, timeout = timeout
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume() }
                case .failed(let error): once.run { continuation.resume(throwing: error) }
                case .cancelled: once.run { continuation.resume(throwing: TransportError.timedOut) }
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            // Cancelling is the only way to abandon a connection attempt; it ends the wait above.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.run { continuation.resume(throwing: TransportError.timedOut) }
            }
        }
    }

    public func close() {
        connection.cancel()
    }

    public func write(_ text: String) async throws {
        // A stale partial reply would be read as the answer to this command.
        buffer.removeAll()
        let connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    public func read(count: Int) async throws -> String {
        while buffer.count < count { try await receive() }
        let out = buffer.prefix(count)
        buffer.removeFirst(count)
        return String(decoding: out, as: UTF8.self)
    }

    public func read(until terminator: Character) async throws -> String {
        let byte = terminator.asciiValue!
        while true {
            if let i = buffer.firstIndex(of: byte) {
                let end = buffer.index(after: i)
                let out = buffer[buffer.startIndex..<end]
                buffer.removeSubrange(buffer.startIndex..<end)
                return String(decoding: out, as: UTF8.self)
            }
            try await receive()
        }
    }

    /// A pending NWConnection receive can't be cancelled on its own, so a timeout closes the
    /// connection: the mount has stopped answering, and the caller must reconnect anyway.
    private func receive() async throws {
        let connection = connection, timeout = timeout
        let chunk: Data = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                once.run {
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if isComplete { continuation.resume(throwing: TransportError.closed) }
                    else { continuation.resume(returning: Data()) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.run {
                    connection.cancel()
                    continuation.resume(throwing: TransportError.timedOut)
                }
            }
        }
        buffer.append(chunk)
    }
}

/// Resumes a continuation at most once, however many state changes arrive.
final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

#if os(macOS)
import Darwin

/// The mount's USB serial port on a Mac (115200 8N1).
public final class SerialTransport: MountTransport, @unchecked Sendable {
    private let fd: Int32
    /// All I/O happens here, so blocking reads never tie up Swift's cooperative threads.
    private let queue = DispatchQueue(label: "overpass.serial")
    private var buffer = Data()

    /// Likely mount ports: USB serial adapters and CDC devices.
    public static func availablePorts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter(isLikelyUSBSerial).map { "/dev/" + $0 }.sorted()
    }

    /// USB serial adapters, by the names their drivers give them: Apple's own (usbserial,
    /// usbmodem), WCH, Silicon Labs, FTDI, and Prolific's newer driver (PL2303G-USBtoUART…).
    /// Bluetooth devices also appear as cu.* ports; those are left out.
    public static func isLikelyUSBSerial(_ name: String) -> Bool {
        guard name.hasPrefix("cu.") else { return false }
        let lower = name.lowercased()
        return ["usbserial", "usbmodem", "wchusbserial", "slab", "usbtouart", "pl2303", "ftdi", "uart"]
            .contains { lower.contains($0) }
    }

    public init(path: String, baud: speed_t = 115_200) throws {
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw TransportError.cannotOpen("\(path): \(String(cString: strerror(errno)))") }

        var options = termios()
        tcgetattr(fd, &options)
        cfmakeraw(&options)
        cfsetspeed(&options, baud)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CRTSCTS)
        // Reads return whatever has arrived, waiting at most 0.1 s.
        withUnsafeMutablePointer(to: &options.c_cc) {
            $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[Int(VMIN)] = 0
                cc[Int(VTIME)] = 1
            }
        }
        tcsetattr(fd, TCSANOW, &options)
        // Back to blocking now the port is configured; VTIME bounds each read.
        _ = fcntl(fd, F_SETFL, 0)
        tcflush(fd, TCIOFLUSH)
    }

    deinit { Darwin.close(fd) }

    public func write(_ text: String) async throws {
        try await perform {
            tcflush(self.fd, TCIFLUSH)
            self.buffer.removeAll()
            let bytes = Array(text.utf8)
            var sent = 0
            while sent < bytes.count {
                let n = bytes[sent...].withUnsafeBytes { Darwin.write(self.fd, $0.baseAddress, $0.count) }
                guard n > 0 else { throw TransportError.closed }
                sent += n
            }
        }
    }

    public func read(count: Int) async throws -> String {
        try await perform {
            try self.fill(deadline: Date() + 2) { $0.count >= count }
            let out = self.buffer.prefix(count)
            self.buffer.removeFirst(count)
            return String(decoding: out, as: UTF8.self)
        }
    }

    public func read(until terminator: Character) async throws -> String {
        let byte = terminator.asciiValue!
        return try await perform {
            try self.fill(deadline: Date() + 2) { $0.contains(byte) }
            let end = self.buffer.index(after: self.buffer.firstIndex(of: byte)!)
            let out = self.buffer[self.buffer.startIndex..<end]
            self.buffer.removeSubrange(self.buffer.startIndex..<end)
            return String(decoding: out, as: UTF8.self)
        }
    }

    private func fill(deadline: Date, until done: (Data) -> Bool) throws {
        var chunk = [UInt8](repeating: 0, count: 256)
        while !done(buffer) {
            guard Date() < deadline else { throw TransportError.timedOut }
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n < 0 { throw TransportError.closed }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    private func perform<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}
#endif
