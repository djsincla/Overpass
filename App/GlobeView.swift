import MapKit
import SkyKit
import SwiftUI

/// One shown pass on the globe.
struct GlobeTrack: Identifiable {
    let id: String
    let name: String
    let color: Color
    /// Half an orbit either side of the pass, split at the 180° meridian.
    let segments: [[Geodetic]]
    /// The part where it's above your horizon.
    let visible: [[Geodetic]]
    /// Where it is overhead at the time shown, if that's within the track.
    let now: Geodetic?
    /// The edge of the ground it can be seen from at that moment (above the horizon).
    let footprint: [Geodetic]?
    let focused: Bool
}

/// The Earth with the shown satellites' ground tracks: half an orbit either side of each pass,
/// thicker where it's above your horizon, with a dot where each satellite is now. As a globe from
/// space, or `flat` as a world map centred on you. Satellite imagery needs a network connection;
/// MapKit keeps what it has already loaded.
struct GlobeView: View {
    let home: Geodetic
    var flat = false
    let tracks: [GlobeTrack]
    /// Changed by the caller to bring the view back to the whole Earth.
    var recentreRequest = 0
    var onTapTrack: ((String) -> Void)?
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position) {
            ForEach(tracks) { track in
                ForEach(Array(track.segments.enumerated()), id: \.offset) { _, segment in
                    MapPolyline(coordinates: segment.map(\.coordinate), contourStyle: .geodesic)
                        .stroke(track.color.opacity(track.focused ? 0.7 : 0.45), lineWidth: track.focused ? 2 : 1.5)
                }
                ForEach(Array(track.visible.enumerated()), id: \.offset) { _, segment in
                    MapPolyline(coordinates: segment.map(\.coordinate), contourStyle: .geodesic)
                        .stroke(track.color, style: StrokeStyle(lineWidth: track.focused ? 5 : 3.5, lineCap: .round))
                }
                // A polygon worked out here: MapCircle can't draw a circle around a pole.
                if let footprint = track.footprint, track.focused {
                    MapPolygon(coordinates: footprint.map(\.coordinate))
                        .foregroundStyle(track.color.opacity(0.12))
                    // The outline only along the real edge: a polar cap's seam and pole points aren't one.
                    let polar = abs(footprint[0].latitude) == 90
                    let edge = polar ? Array(footprint.dropFirst().dropLast()) : footprint + [footprint[0]]
                    MapPolyline(coordinates: edge.map(\.coordinate))
                        .stroke(track.color.opacity(0.5), lineWidth: 1)
                }
                if let now = track.now {
                    Annotation(track.name, coordinate: now.coordinate) {
                        Circle()
                            .fill(track.color)
                            .stroke(.white, lineWidth: 1.5)
                            .frame(width: track.focused ? 14 : 10, height: track.focused ? 14 : 10)
                            .onTapGesture { onTapTrack?(track.id) }
                    }
                }
            }
            Annotation("You", coordinate: home.coordinate) {
                Image(systemName: "scope")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(Theme.target, in: Circle())
            }
        }
        .mapStyle(.imagery(elevation: flat ? .flat : .realistic))
        .mapControls {
            MapCompass()
            #if os(macOS)
            MapZoomStepper()
            #endif
        }
        .onAppear { recentre() }
        .onChange(of: flat) { _, _ in recentre() }
        .onChange(of: recentreRequest) { _, _ in withAnimation { recentre() } }
    }

    /// The whole Earth, centred on you.
    private func recentre() {
        if flat {
            position = .region(MKCoordinateRegion(center: home.coordinate,
                                                  span: MKCoordinateSpan(latitudeDelta: 150, longitudeDelta: 360)))
        } else {
            position = .camera(MapCamera(centerCoordinate: home.coordinate, distance: 22_000_000))
        }
    }
}
