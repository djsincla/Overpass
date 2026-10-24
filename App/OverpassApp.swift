import SwiftUI

@main
struct OverpassApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            SkyTab()
                .tabItem { Label("Sky", systemImage: "circle.dashed") }
            PassListView()
                .tabItem { Label("Passes", systemImage: "list.bullet") }
            SatellitesView()
                .tabItem { Label("Satellites", systemImage: "antenna.radiowaves.left.and.right") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task { await model.start() }
    }
}
