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
            ObserveView()
                .tabItem { Label("Observe", systemImage: "scope") }
            ObjectsView()
                .tabItem { Label("Objects", systemImage: "checklist") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task { await model.start() }
    }
}
