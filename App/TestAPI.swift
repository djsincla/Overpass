#if os(macOS) && DEBUG
import Foundation
import Network

/// Debug builds only, and only when asked (`-testAPI YES` at launch): a small HTTP interface on
/// the Mac's loopback, so scripted tests can drive a real mount through the same MountSession
/// calls the buttons make. Every request needs the token, sent as `X-Overpass-Token`: the one
/// given at launch with `-testAPIToken` (16 characters or more), else the one written to
/// `test-api-token` beside the mount log. Not in Release builds, so never in TestFlight or the App Store.
///
///     GET  /state                       connection, axes, sky position, status, past north
///     GET  /log?lines=40                the end of the mount log
///     POST /connect?kind=usb            usb (Special mode), usbNormal or wifi; &port=/dev/cu.… for USB
///     POST /answer?position=mount       when /state shows a question: mount or record
///     POST /disconnect
///     POST /tap?dir=up&ms=80            press and release a jog arrow, as JogButton does
///     POST /jog?dir=up&action=press     or action=release; a press left held is released after 10 s
///     POST /stop?unwind=0               Stop, unwinding past north only with unwind=1
///     POST /background                  what the app does on going to the background
///     POST /unwind
@MainActor
final class TestAPI {
    private static var shared: TestAPI?
    static let port: NWEndpoint.Port = 48_123
    static var tokenFile: URL { AppModel.storage.appending(path: "test-api-token") }

    private let model: AppModel
    private let listener: NWListener
    /// `-testAPIToken` at launch, else a fresh one. Sandboxed, the app's container is closed to
    /// other programs, so a script can't read the token file; it passes its own at launch.
    private let token = UserDefaults.standard.string(forKey: "testAPIToken").flatMap { $0.count >= 16 ? $0 : nil } ?? UUID().uuidString
    /// Presses made through the API that haven't been released, by direction.
    private var held: [JogDirection: Task<Void, Never>] = [:]

    static func startIfAsked(_ model: AppModel) {
        guard UserDefaults.standard.bool(forKey: "testAPI"), shared == nil else { return }
        do {
            shared = try TestAPI(model: model)
        } catch {
            model.mount.log("Test API didn't start: \(error)")
        }
    }

    private init(model: AppModel) throws {
        self.model = model
        let parameters = NWParameters.tcp
        // Bound to 127.0.0.1 itself, not every address with local-only filtering on top.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: Self.port)
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters)
        try FileManager.default.createDirectory(at: Self.tokenFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(token.utf8).write(to: Self.tokenFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.tokenFile.path)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.serve(connection) }
        }
        listener.start(queue: .main)
        model.mount.log("Test API listening on 127.0.0.1:\(Self.port.rawValue)")
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                let (status, body) = await self.handle(String(decoding: data ?? Data(), as: UTF8.self))
                let json = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])) ?? Data()
                let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + json, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private func handle(_ request: String) async -> (Int, [String: Any]) {
        let lines = request.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return (400, ["error": "bad request"]) }
        let given = lines.first { $0.lowercased().hasPrefix("x-overpass-token:") }?
            .split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
        guard given == token else { return (403, ["error": "token missing or wrong"]) }
        let method = String(parts[0])
        let url = URLComponents(string: String(parts[1]))
        let query = Dictionary((url?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        let mount = model.mount

        switch (method, url?.path ?? "") {
        case ("GET", "/state"):
            return (200, state())
        case ("GET", "/log"):
            let count = min(Int(query["lines"] ?? "") ?? 40, 500)
            let text = (try? String(contentsOf: MountSession.logFile, encoding: .utf8)) ?? ""
            return (200, ["lines": Array(text.split(separator: "\n").suffix(count).map(String.init))])
        case ("POST", "/connect"):
            guard let kind = ["usb": ConnectionKind.usb, "usbNormal": .usbNormal, "wifi": .wifi][query["kind"] ?? ""] else {
                return (400, ["error": "kind is usb, usbNormal or wifi"])
            }
            if mount.state == .connected { await mount.disconnect(releasingTarget: false) }
            model.settings.connection = kind
            if let port = query["port"], !port.isEmpty { model.settings.serialPath = port }
            mount.log("Test API: connect \(kind.rawValue)")
            // Connecting can stop to ask where the scope points: return then, and let /answer
            // carry on, rather than hold the request until someone clicks.
            let connecting = Task { await mount.connect() }
            let deadline = Date.now.addingTimeInterval(30)
            while Date.now < deadline, mount.positionQuestion == nil, mount.state == .connecting || mount.state == .disconnected {
                try? await Task.sleep(for: .milliseconds(200))
                if mount.state == .disconnected, connecting.isCancelled { break }
            }
            if mount.positionQuestion == nil { await connecting.value }
            return (200, state())
        case ("POST", "/answer"):
            guard mount.positionQuestion != nil else { return (409, ["error": "no question waiting"]) }
            switch query["position"] {
            case "mount": mount.answerPosition(.mount)
            case "record": mount.answerPosition(.record)
            default: return (400, ["error": "position is mount or record"])
            }
            mount.log("Test API: answered the position question: \(query["position"] ?? "")")
            let deadline = Date.now.addingTimeInterval(30)
            while Date.now < deadline, mount.state == .connecting { try? await Task.sleep(for: .milliseconds(200)) }
            return (200, state())
        case ("POST", "/disconnect"):
            mount.log("Test API: disconnect")
            await mount.disconnect()
            return (200, state())
        case ("POST", "/jog"):
            guard let direction = Self.direction(query["dir"]) else { return (400, ["error": "dir is up, down, left or right"]) }
            switch query["action"] {
            case "press": press(direction)
            case "release": release(direction)
            default: return (400, ["error": "action is press or release"])
            }
            return (200, state())
        case ("POST", "/tap"):
            guard let direction = Self.direction(query["dir"]) else { return (400, ["error": "dir is up, down, left or right"]) }
            let ms = min(max(Int(query["ms"] ?? "") ?? 80, 0), 10_000)
            mount.log("Test API: tap \(direction) for \(ms) ms")
            // As JogButton: the press and the release each in their own task, ms apart.
            press(direction)
            try? await Task.sleep(for: .milliseconds(ms))
            release(direction)
            return (200, state())
        case ("POST", "/stop"):
            mount.log("Test API: stop")
            await mount.stopAll(unwinding: query["unwind"] == "1")
            return (200, state())
        case ("POST", "/background"):
            mount.log("Test API: going to the background")
            await mount.stopForBackground()
            return (200, state())
        case ("POST", "/unwind"):
            mount.log("Test API: unwind")
            mount.unwind()
            return (200, state())
        default:
            return (404, ["error": "no \(method) \(url?.path ?? "")"])
        }
    }

    /// A press as JogButton makes it, with a backstop: released after 10 s if nothing else does.
    private func press(_ direction: JogDirection) {
        held[direction]?.cancel()
        Task { await model.mount.jog(direction, pressed: true) }
        held[direction] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            self.model.mount.log("Test API: \(direction) held 10 s; releasing")
            self.release(direction)
        }
    }

    private func release(_ direction: JogDirection) {
        held[direction]?.cancel()
        held[direction] = nil
        Task { await model.mount.jog(direction, pressed: false) }
    }

    private static func direction(_ name: String?) -> JogDirection? {
        ["up": .up, "down": .down, "left": .left, "right": .right][name ?? ""]
    }

    private func state() -> [String: Any] {
        let mount = model.mount
        var out: [String: Any] = [
            "state": { switch mount.state {
                case .disconnected: "disconnected"
                case .connecting: "connecting"
                case .connected: "connected"
                case .failed(let why): "failed: \(why)"
            } }(),
            "status": mount.status,
            "tracking": mount.isTracking,
            "unwinding": mount.isUnwinding,
            "holdsSpecialMode": mount.holdsSpecialMode,
        ]
        if let kind = mount.kind { out["kind"] = kind.rawValue }
        if let identity = mount.identity { out["mount"] = identity.model.name; out["mountInfo"] = identity.rawCode }
        if let axes = mount.axes { out["axes"] = ["primary": axes.primary, "secondary": axes.secondary] }
        if let sky = mount.skyPosition { out["sky"] = ["azimuth": sky.azimuth, "altitude": sky.altitude] }
        if let date = mount.skyPositionDate { out["skyDate"] = date.formatted(.iso8601.time(includingFractionalSeconds: true)) }
        if let past = mount.pastNorth { out["pastNorth"] = past }
        if let question = mount.positionQuestion {
            out["question"] = ["mount": ["azimuth": question.mount.azimuth, "altitude": question.mount.altitude],
                               "record": ["azimuth": question.record.azimuth, "altitude": question.record.altitude]]
        }
        return out
    }
}
#endif
