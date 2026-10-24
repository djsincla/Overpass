import SkyKit
import SwiftUI

/// Special-mode star alignment: centre a few bright stars with the jog pad and record each.
struct AlignmentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: String?
    @State private var failed = false

    var body: some View {
        let mount = model.mount
        NavigationStack {
            Form {
                Section {
                    Text("Pick a star, move the scope until it's centred with the arrows, then tap Record. Two stars align the mount; three or more also show how good the alignment is.")
                        .font(.callout)
                }
                Section("Suggested now") {
                    ForEach(suggestions, id: \.star.name) { s in
                        Button { chosen = SkyObject.star(s.star).id } label: {
                            HStack {
                                Image(systemName: chosen == SkyObject.star(s.star).id ? "largecircle.fill.circle" : "circle")
                                Text(s.star.name)
                                Spacer()
                                Text("\(Int(s.position.azimuth))° \(compass(s.position.azimuth)) · \(Int(s.position.altitude))° up")
                                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(planetsUp, id: \.self) { body in
                        Button { chosen = SkyObject.body(body).id } label: {
                            HStack {
                                Image(systemName: chosen == SkyObject.body(body).id ? "largecircle.fill.circle" : "circle")
                                Text(body.name)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section {
                    JogPad()
                    Button("Record — it's centred") {
                        if let id = chosen, let object = model.object(id) { Task { await mount.addAlignmentPoint(object) } }
                    }
                    .disabled(chosen == nil)
                }
                Section("Recorded") {
                    if mount.alignmentPoints.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                    ForEach(Array(mount.alignmentPoints.enumerated()), id: \.offset) { i, point in
                        HStack {
                            Text(point.targetName)
                            Spacer()
                            Text(point.date, style: .time).foregroundStyle(.secondary)
                        }
                        .swipeActions { Button("Remove", role: .destructive) { mount.removeAlignmentPoint(at: i) } }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Align")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use alignment") {
                        if mount.finishAlignment() { mount.clearAlignment(); dismiss() } else { failed = true }
                    }
                    .disabled(mount.alignmentPoints.isEmpty)
                }
            }
            .alert("Couldn't align", isPresented: $failed) {
                Button("OK") {}
            } message: {
                Text("The first alignment needs at least two stars, well apart. If you used two, one of them may be mis-centred.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 600)
        #endif
    }

    private var suggestions: [(star: Star, position: Horizontal)] {
        AlignmentStarPicker.suggest(observer: model.settings.observer, date: .now, count: 6)
    }

    private var planetsUp: [SolarSystemBody] {
        let time = AstroTime(.now)
        return [.venus, .mars, .jupiter, .saturn].filter {
            ((try? model.settings.observer.look(at: $0, time))?.altitude ?? -90) > 15
        }
    }
}
