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
        .tint(Theme.accent)
        .preferredColorScheme(model.settings.alwaysDark ? .dark : nil)
        .modifier(NightVision(enabled: model.settings.redMode))
        .task { await model.start() }
    }
}

/// Red mode: everything rendered as shades of pure red on black. Dark adaptation survives red
/// light far better than white, which is why observatories use it. Converting to grayscale first
/// keeps contrast for colours with no red in them (the cyan pass track would otherwise vanish).
struct NightVision: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .preferredColorScheme(.dark)
                .grayscale(1)
                .colorMultiply(Color(red: 1, green: 0, blue: 0))
        } else {
            content
        }
    }
}

#if os(iOS)
import UIKit

enum AppIcon {
    /// iOS asks the user to confirm icon changes with its own alert; that's expected.
    @MainActor static func setRed(_ red: Bool) {
        guard UIApplication.shared.supportsAlternateIcons else { return }
        let name = red ? "AppIconRed" : nil
        if UIApplication.shared.alternateIconName != name {
            UIApplication.shared.setAlternateIconName(name)
        }
    }
}
#endif
