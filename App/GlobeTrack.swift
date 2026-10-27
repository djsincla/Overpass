import SkyKit
import SwiftUI

/// One shown pass on the globe and the flat map.
struct GlobeTrack: Identifiable {
    let id: String
    let name: String
    let color: Color
    /// Half an orbit either side of the pass, with the satellite's height.
    let path: [Geodetic]
    /// The part where it's above your horizon.
    let visiblePath: [Geodetic]
    /// Where it is overhead at the time shown, if that's within the track.
    let now: Geodetic?
    /// The edge of the ground it can be seen from at that moment (above the horizon).
    let footprint: [Geodetic]?
    let focused: Bool
}
