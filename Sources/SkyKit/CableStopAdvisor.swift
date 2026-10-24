/// Suggests where to put the cable stop so the fewest upcoming passes are blocked by it.
public enum CableStopAdvisor {
    public struct Option: Sendable {
        public let azimuth: Double
        public let blockedPasses: Int
    }

    /// Tries stop azimuths every `step` degrees and returns them, best first.
    public static func rank(_ passes: [SatellitePass], limits: MountLimits,
                            model: AlignmentModel = AlignmentModel(), step: Double = 15) -> [Option] {
        rank(tracks: passes.map(\.track), limits: limits, model: model, step: step)
    }

    public static func rank(tracks: [[PassSample]], limits: MountLimits,
                            model: AlignmentModel = AlignmentModel(), step: Double = 15) -> [Option] {
        stride(from: 0.0, to: 360, by: step).map { azimuth in
            var l = limits
            l.cableStopAzimuth = azimuth
            let planner = MountPlanner(limits: l, model: model)
            return Option(azimuth: azimuth, blockedPasses: tracks.filter { planner.plan($0) == nil }.count)
        }.sorted { $0.blockedPasses < $1.blockedPasses }
    }
}
