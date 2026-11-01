import Foundation

/// A satellite's radio transmitter, from the SatNOGS DB.
public struct Transmitter: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let description: String
    public let alive: Bool
    public let status: String
    public let mode: String?
    /// Hz.
    public let downlink: Double?
    /// Hz.
    public let uplink: Double?
    /// Inverting transponder (an uplink at the bottom comes down at the top).
    public let invert: Bool
    public let baud: Double?

    public var isActive: Bool { alive && status == "active" }

    enum CodingKeys: String, CodingKey {
        case id = "uuid", description, alive, status, mode, invert, baud
        case downlink = "downlink_low", uplink = "uplink_low"
    }
}

public enum SatNOGS {
    /// The transmitters SatNOGS lists for a satellite. Only the NORAD ID is sent.
    public static func transmittersURL(noradID: String) -> URL {
        URL(string: "https://db.satnogs.org/api/transmitters/?format=json&satellite__norad_cat_id=\(noradID)")!
    }

    public static func parseTransmitters(_ data: Data) throws -> [Transmitter] {
        try JSONDecoder().decode([Transmitter].self, from: data)
    }

    /// Active ones first, then by downlink frequency.
    public static func sorted(_ transmitters: [Transmitter]) -> [Transmitter] {
        transmitters.sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            return ($0.downlink ?? .infinity) < ($1.downlink ?? .infinity)
        }
    }

    public static func fetchTransmitters(noradID: String, session: URLSession = .shared) async throws -> [Transmitter] {
        let (data, response) = try await session.data(from: transmittersURL(noradID: noradID))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try parseTransmitters(data)
    }
}
