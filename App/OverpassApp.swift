import SwiftUI

@main
struct OverpassApp: App {
    @State private var model = AppModel()
    #if os(macOS)
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
        .commands {
            #if os(macOS)
            CommandGroup(replacing: .appInfo) { AboutCommand() }
            #endif
        }
        #if os(macOS)
        SwiftUI.Settings {
            SettingsView()
                .environment(model)
                .frame(minWidth: 520, idealWidth: 600, minHeight: 500, idealHeight: 760)
                .tint(Theme.accent)
                .modifier(NightVision(enabled: model.settings.redMode))
        }

        Window("About Overpass", id: "about") {
            AboutView()
                .tint(Theme.accent)
                .modifier(NightVision(enabled: model.settings.redMode))
        }
        .windowResizability(.contentSize)
        #endif
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
            ConjunctionsView()
                .tabItem { Label("Conjunctions", systemImage: "moon.stars") }
            CameraTrackView()
                .tabItem { Label("Camera", systemImage: "camera.viewfinder") }
            #if os(iOS)
            // On the Mac, Settings is in the app menu (⌘,).
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
            #endif
        }
        .tint(Theme.accent)
        .modifier(Appearance(dark: model.settings.alwaysDark || model.settings.redMode))
        .modifier(NightVision(enabled: model.settings.redMode))
        .task {
            #if os(macOS)
            AppDelegate.model = model
            #endif
            await model.start()
        }
    }
}

#if os(macOS)
/// Stops the mount on quit. In Special mode it keeps turning at the last speeds it was given
/// until told otherwise, so quitting mid-track would leave it running.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let mount = Self.model?.mount, mount.state == .connected else { return .terminateNow }
            Task {
                await mount.stopAll()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }
}
#endif

/// Dark, or whatever the system uses. On macOS, SwiftUI's preferredColorScheme doesn't let go
/// once it has forced dark (the window stays dark after switching back to nil), so set the
/// app's appearance directly there.
struct Appearance: ViewModifier {
    let dark: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        content.onChange(of: dark, initial: true) { _, dark in
            NSApp.appearance = dark ? NSAppearance(named: .darkAqua) : nil
        }
        #else
        content.preferredColorScheme(dark ? .dark : nil)
        #endif
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
