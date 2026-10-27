import SceneKit
import SkyKit
import SwiftUI

/// The Earth in 3D, drawn here rather than by MapKit, so it works with no network and shows the
/// poles. NASA imagery bundled with the app (public domain): Blue Marble (December 2004) by day
/// and Black Marble (2016) city lights by night, both 5400×2700, with the boundary following the
/// Sun. Each shown pass has its ground track on the surface, its orbit at the satellite's real
/// height, the satellite with a line down to the point below it, and its footprint.
struct EarthGlobeView {
    let home: Geodetic
    let tracks: [GlobeTrack]
    /// Towards the Sun, Earth-fixed.
    let sun: Vec3
    var redMode = false
    /// Changed by the caller to bring the view back to the Earth around you.
    var recentreRequest = 0
    var onTapTrack: ((String) -> Void)?

    @MainActor final class Coordinator: NSObject {
        let scene = SCNScene()
        let earth: SCNNode
        let tracksNode = SCNNode()
        let homeNode: SCNNode
        let camera = SCNNode()
        weak var view: SCNView?
        var onTapTrack: ((String) -> Void)?
        var lastRecentre = 0
        /// The static part of each track (ground track and orbit), rebuilt only when it changes.
        var built: [String: (key: String, node: SCNNode)] = [:]

        override init() {
            earth = SCNNode(geometry: Globe.earthGeometry())
            homeNode = Globe.pin(color: PlatformColor(Theme.target))
            super.init()
            scene.background.contents = PlatformColor.black
            scene.rootNode.addChildNode(earth)
            scene.rootNode.addChildNode(Globe.atmosphere())
            scene.rootNode.addChildNode(tracksNode)
            scene.rootNode.addChildNode(homeNode)
            camera.camera = SCNCamera()
            camera.camera?.fieldOfView = 38
            camera.camera?.zNear = 0.01
            camera.camera?.zFar = 50
            scene.rootNode.addChildNode(camera)
        }

        func lookAt(_ place: Geodetic, animated: Bool) {
            let target = Globe.point(place, radius: 3.4)
            SCNTransaction.begin()
            SCNTransaction.animationDuration = animated ? 0.6 : 0
            camera.position = target
            camera.look(at: SCNVector3(0, 0, 0), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
            SCNTransaction.commit()
            view?.defaultCameraController.target = SCNVector3(0, 0, 0)
        }

        @objc func tapped(_ gesture: NSObject) {
            guard let view else { return }
            #if os(iOS)
            guard let tap = gesture as? UITapGestureRecognizer else { return }
            let location = tap.location(in: view)
            #else
            guard let click = gesture as? NSClickGestureRecognizer else { return }
            let location = click.location(in: view)
            #endif
            let hits = view.hitTest(location, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
            if let id = hits.lazy.compactMap({ $0.node.name ?? $0.node.parent?.name }).first(where: { $0.hasPrefix("sat:") }) {
                onTapTrack?(String(id.dropFirst(4)))
            }
        }
    }

    @MainActor func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor private func makeView(_ coordinator: Coordinator) -> SCNView {
        let view = SCNView()
        view.scene = coordinator.scene
        view.pointOfView = coordinator.camera
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.target = SCNVector3(0, 0, 0)
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .black
        coordinator.view = view
        coordinator.lookAt(home, animated: false)
        #if os(iOS)
        view.addGestureRecognizer(UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped(_:))))
        #else
        view.addGestureRecognizer(NSClickGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped(_:))))
        #endif
        return view
    }

    @MainActor private func update(_ coordinator: Coordinator) {
        coordinator.onTapTrack = onTapTrack
        if recentreRequest != coordinator.lastRecentre {
            coordinator.lastRecentre = recentreRequest
            coordinator.lookAt(home, animated: true)
        }
        Globe.place(coordinator.homeNode, at: home)
        let sunScene = Globe.vector(sun)
        let earth = coordinator.earth.geometry?.firstMaterial
        earth?.setValue(NSValue(scnVector3: sunScene), forKey: "sunDirection")
        Globe.showFootprint(of: tracks.first { $0.focused && $0.now != nil }, on: earth)

        // Static parts: rebuilt when a track's points or focus change.
        var keep = Set<String>()
        for track in tracks {
            let key = "\(track.path.count)-\(track.path.first?.latitude ?? 0)-\(track.focused)-\(track.color.description)"
            keep.insert(track.id)
            if coordinator.built[track.id]?.key != key {
                coordinator.built[track.id]?.node.removeFromParentNode()
                let node = Globe.staticTrack(track)
                coordinator.tracksNode.addChildNode(node)
                coordinator.built[track.id] = (key, node)
            }
            // Moving parts: the satellite, its drop line and footprint, every update.
            let node = coordinator.built[track.id]!.node
            node.childNode(withName: "moving", recursively: false)?.removeFromParentNode()
            if let moving = Globe.movingTrack(track) { node.addChildNode(moving) }
        }
        for (id, entry) in coordinator.built where !keep.contains(id) {
            entry.node.removeFromParentNode()
            coordinator.built[id] = nil
        }

        // Every update: the moving parts are new materials each time.
        let red = NSNumber(value: redMode ? 1 : 0)
        coordinator.scene.rootNode.enumerateHierarchy { node, _ in
            node.geometry?.materials.forEach { $0.setValue(red, forKey: "redMode") }
        }
    }
}

#if os(iOS)
typealias PlatformColor = UIColor
extension EarthGlobeView: UIViewRepresentable {
    @MainActor func makeUIView(context: Context) -> SCNView { makeView(context.coordinator) }
    @MainActor func updateUIView(_ view: SCNView, context: Context) { update(context.coordinator) }
}
#else
typealias PlatformColor = NSColor
extension EarthGlobeView: NSViewRepresentable {
    @MainActor func makeNSView(context: Context) -> SCNView { makeView(context.coordinator) }
    @MainActor func updateNSView(_ view: SCNView, context: Context) { update(context.coordinator) }
}
#endif

/// Geometry for the globe. The scene's unit is the Earth's equatorial radius; +Y is north, and
/// longitude 0 faces +Z, which is how SceneKit wraps an equirectangular image round a sphere.
@MainActor enum Globe {
    static let earthRadius = Observer.wgs84A

    /// Red mode for every material: grey turned to red, so the globe matches the rest of the app.
    static let redShader = """
    #pragma arguments
    float redMode;
    #pragma body
    float grey = dot(_output.color.rgb, float3(0.299, 0.587, 0.114));
    _output.color.rgb = mix(_output.color.rgb, float3(grey, 0.0, 0.0), redMode);
    """

    static func point(_ place: Geodetic, radius: Double? = nil) -> SCNVector3 {
        let r = radius ?? 1 + place.height / earthRadius
        let lat = place.latitude.radians, lon = place.longitude.radians
        return SCNVector3(r * cos(lat) * sin(lon), r * sin(lat), r * cos(lat) * cos(lon))
    }

    /// An Earth-fixed vector (x to 0°/0°, y to 90° E, z north) in scene axes, unit length.
    static func vector(_ v: Vec3) -> SCNVector3 {
        let n = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        return SCNVector3(v.y / n, v.z / n, v.x / n)
    }

    static func material(_ color: PlatformColor, opacity: CGFloat = 1) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.transparency = opacity
        m.blendMode = opacity < 1 ? .alpha : .replace
        m.writesToDepthBuffer = opacity == 1
        m.shaderModifiers = [.fragment: redShader]
        return m
    }

    static func earthGeometry() -> SCNGeometry {
        let sphere = SCNSphere(radius: 1)
        sphere.segmentCount = 144
        let m = SCNMaterial()
        m.diffuse.contents = Bundle.main.url(forResource: "earth-day", withExtension: "jpg")
        m.emission.contents = Bundle.main.url(forResource: "earth-night", withExtension: "jpg")
        m.lightingModel = .constant
        m.diffuse.mipFilter = .linear
        m.emission.mipFilter = .linear
        // Day where the Sun is up, city lights where it isn't, with a soft twilight between.
        m.shaderModifiers = [
            .surface: """
            #pragma arguments
            float3 sunDirection;
            float3 footprintCenter;
            float footprintCos;
            float3 footprintColor;
            #pragma body
            float3 n = normalize((scn_frame.inverseViewTransform * float4(_surface.normal, 0.0)).xyz);
            float day = smoothstep(-0.10, 0.10, dot(n, normalize(sunDirection)));
            _surface.diffuse.rgb *= mix(0.07, 1.0, day);
            _surface.emission.rgb *= (1.0 - day) * 1.3;
            // The focused satellite's footprint: a tint inside, a line about 1.5 px wide at its edge.
            float d = dot(n, normalize(footprintCenter)) - footprintCos;
            float w = max(fwidth(d), 1e-6);
            float inside = smoothstep(-w, w, d);
            float edge = 1.0 - smoothstep(0.75 * w, 1.75 * w, abs(d));
            _surface.diffuse.rgb = mix(_surface.diffuse.rgb, footprintColor, max(inside * 0.16, edge * 0.8));
            _surface.emission.rgb *= 1.0 - edge;
            """,
            .fragment: redShader,
        ]
        m.setValue(NSValue(scnVector3: SCNVector3(0, 0, 1)), forKey: "sunDirection")
        m.setValue(NSValue(scnVector3: SCNVector3(0, 0, 1)), forKey: "footprintCenter")
        m.setValue(NSNumber(value: 2), forKey: "footprintCos")
        m.setValue(NSValue(scnVector3: SCNVector3(1, 1, 1)), forKey: "footprintColor")
        sphere.firstMaterial = m
        return sphere
    }

    /// A thin blue glow at the limb.
    static func atmosphere() -> SCNNode {
        let sphere = SCNSphere(radius: 1.02)
        sphere.segmentCount = 96
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.shaderModifiers = [.fragment: """
            #pragma arguments
            float redMode;
            #pragma body
            float rim = 1.0 - abs(dot(normalize(_surface.normal), normalize(_surface.view)));
            float glow = pow(rim, 6.0) * 0.55;
            float3 color = mix(float3(0.35, 0.6, 1.0), float3(0.5, 0.0, 0.0), redMode);
            _output.color = float4(color * glow, glow);
            """]
        m.setValue(NSNumber(value: 0), forKey: "redMode")
        sphere.firstMaterial = m
        let node = SCNNode(geometry: sphere)
        node.renderingOrder = 10
        return node
    }

    /// Your location: a small post with a head, standing on the surface.
    static func pin(color: PlatformColor) -> SCNNode {
        let node = SCNNode()
        let post = SCNCylinder(radius: 0.003, height: 0.05)
        post.firstMaterial = material(color)
        let postNode = SCNNode(geometry: post)
        postNode.position = SCNVector3(0, 0.025, 0)
        let head = SCNSphere(radius: 0.012)
        head.firstMaterial = material(color)
        let headNode = SCNNode(geometry: head)
        headNode.position = SCNVector3(0, 0.05, 0)
        node.addChildNode(postNode)
        node.addChildNode(headNode)
        return node
    }

    /// Stands `node` on the surface at `place`, its +Y pointing straight up.
    static func place(_ node: SCNNode, at place: Geodetic) {
        node.position = point(Geodetic(latitude: place.latitude, longitude: place.longitude), radius: 1)
        node.look(at: point(place, radius: 2), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 1, 0))
    }

    /// A flat strip through `points`, `width` wide (scene units), lying across the radial
    /// direction so it faces out from the Earth.
    static func ribbon(_ points: [SCNVector3], width: Double) -> SCNGeometry? {
        guard points.count > 1 else { return nil }
        var vertices: [SCNVector3] = []
        vertices.reserveCapacity(points.count * 2)
        for i in points.indices {
            let a = points[max(i - 1, 0)], b = points[min(i + 1, points.count - 1)]
            let p = points[i]
            let t = SIMD3<Double>(Double(b.x - a.x), Double(b.y - a.y), Double(b.z - a.z))
            let up = SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z))
            var side = simd_cross(t, up)
            let length = simd_length(side)
            side = length > 0 ? side / length * width / 2 : .zero
            vertices.append(SCNVector3(Double(p.x) + side.x, Double(p.y) + side.y, Double(p.z) + side.z))
            vertices.append(SCNVector3(Double(p.x) - side.x, Double(p.y) - side.y, Double(p.z) - side.z))
        }
        let indices = (0..<Int32(vertices.count)).map { $0 }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)],
                           elements: [SCNGeometryElement(indices: indices, primitiveType: .triangleStrip)])
    }

    /// The ground track on the surface (thick where it's above your horizon) and the orbit at height.
    static func staticTrack(_ track: GlobeTrack) -> SCNNode {
        let node = SCNNode()
        let color = PlatformColor(track.color)
        let lift = 1.0015
        let ground = track.path.map { point($0, radius: lift) }
        if let g = ribbon(ground, width: track.focused ? 0.006 : 0.004) {
            g.firstMaterial = material(color, opacity: 0.55)
            node.addChildNode(SCNNode(geometry: g))
        }
        let visible = track.visiblePath.map { point($0, radius: lift + 0.0005) }
        if let g = ribbon(visible, width: track.focused ? 0.016 : 0.011) {
            g.firstMaterial = material(color)
            node.addChildNode(SCNNode(geometry: g))
        }
        let orbit = track.path.map { point($0) }
        if let g = ribbon(orbit, width: 0.004) {
            g.firstMaterial = material(color, opacity: 0.4)
            node.addChildNode(SCNNode(geometry: g))
        }
        return node
    }

    /// The satellite at its height, a line down to the point below, and the name.
    static func movingTrack(_ track: GlobeTrack) -> SCNNode? {
        guard let now = track.now else { return nil }
        let node = SCNNode()
        node.name = "moving"
        let color = PlatformColor(track.color)

        let satellite = SCNNode(geometry: SCNSphere(radius: track.focused ? 0.016 : 0.012))
        satellite.geometry?.firstMaterial = material(color)
        satellite.position = point(now)
        satellite.name = "sat:" + track.id
        node.addChildNode(satellite)

        let below = point(now, radius: 1.002)
        if let drop = ribbon([below, point(now)], width: 0.003) {
            drop.firstMaterial = material(color, opacity: 0.7)
            node.addChildNode(SCNNode(geometry: drop))
        }

        let label = SCNText(string: track.name, extrusionDepth: 0)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.flatness = 0.1
        label.firstMaterial = material(.white)
        let labelNode = SCNNode(geometry: label)
        let (minimum, maximum) = labelNode.boundingBox
        labelNode.pivot = SCNMatrix4MakeTranslation((maximum.x - minimum.x) / 2 + minimum.x, -8, 0)
        labelNode.scale = SCNVector3(0.0025, 0.0025, 0.0025)
        labelNode.position = satellite.position
        labelNode.constraints = [SCNBillboardConstraint()]
        labelNode.renderingOrder = 20
        node.addChildNode(labelNode)
        return node
    }

    /// The ground the satellite can be seen from, tinted on the Earth's own surface with an edge
    /// at its horizon. Drawn per pixel, so it stays on the sphere however wide it is: a mesh cap's
    /// flat triangles sank below the surface in bands once a high satellite's cap spanned 70° or more.
    static func showFootprint(of track: GlobeTrack?, on material: SCNMaterial?) {
        guard let material else { return }
        guard let track, let now = track.now else {
            material.setValue(NSNumber(value: 2), forKey: "footprintCos")
            return
        }
        let angle = GroundTrack.footprintAngle(height: now.height)
        material.setValue(NSValue(scnVector3: point(Geodetic(latitude: now.latitude, longitude: now.longitude), radius: 1)),
                          forKey: "footprintCenter")
        material.setValue(NSNumber(value: cos(angle.radians)), forKey: "footprintCos")
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        #if os(iOS)
        PlatformColor(track.color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #else
        (PlatformColor(track.color).usingColorSpace(.sRGB) ?? .white).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #endif
        material.setValue(NSValue(scnVector3: SCNVector3(red, green, blue)), forKey: "footprintColor")
    }
}
