import SwiftUI

/// Who made Overpass, the version, and where the code and data come from.
struct AboutRows: View {
    static let author = "Dwayne Sinclair"
    static let callSign = "AB6A"
    static let email = "AB6A@arrl.net"
    static let credits = "Orbital elements and the satellite catalogue (launch, orbit, radar cross-section) come from CelesTrak. Physical dimensions come from Jonathan McDowell's General Catalog of Artificial Space Objects (planet4589.org/space/gcat), under CC BY 4.0."

    var body: some View {
        LabeledContent("Version", value: SettingsView.version)
        LabeledContent("Made by", value: "\(Self.author), \(Self.callSign)")
        Link(destination: URL(string: "mailto:\(Self.email)")!) {
            Label("Contact: \(Self.email)", systemImage: "envelope")
        }
        Link(destination: URL(string: "https://djsincla.github.io/Overpass/")!) {
            Label("Website", systemImage: "globe")
        }
        Link(destination: URL(string: "https://github.com/djsincla/Overpass")!) {
            Label("Source code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
        }
        Link(destination: URL(string: "https://github.com/djsincla/Overpass/blob/main/LICENSE")!) {
            Label("Apache License 2.0", systemImage: "doc.text")
        }
    }
}

#if os(macOS)
/// The About window, opened from the app menu.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                Text("Overpass").font(.title.bold())
                Text("Satellite tracking for iOptron alt-az mounts").foregroundStyle(.secondary)
            }
            .padding(.top, 20)
            Form {
                Section {
                    AboutRows()
                } footer: {
                    Text(AboutRows.credits)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 440, height: 520)
    }
}

/// Replaces the standard About item, which shows only the name and version.
struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About Overpass") { openWindow(id: "about") }
    }
}
#endif
