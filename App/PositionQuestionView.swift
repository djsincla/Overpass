import SkyKit
import SwiftUI

/// Asked when the mount's reading and Overpass's record of where the scope points disagree:
/// which one is right, or where it actually points. Each has been the wrong one.
struct PositionQuestionView: View {
    @Environment(AppModel.self) private var model
    let question: MountSession.PositionQuestion
    @State private var azimuth: Double
    @State private var altitude: Double

    init(question: MountSession.PositionQuestion) {
        self.question = question
        _azimuth = State(initialValue: (question.record.azimuth * 10).rounded() / 10)
        _altitude = State(initialValue: (question.record.altitude * 10).rounded() / 10)
    }

    var body: some View {
        let apart = angularSeparation(question.mount.unitVector, question.record.unitVector)
        VStack(alignment: .leading, spacing: 14) {
            Text("Where is the scope pointing?").font(.title3.bold())
            Text("The mount and Overpass disagree by \(Int(apart.rounded()))°. Either can be wrong: after leaving Special mode the mount can report an old position, and Overpass doesn't see moves made with the hand controller.")
                .fixedSize(horizontal: false, vertical: true)

            choice("The mount's reading", question.mount, detail: "What the mount reports now") { model.mount.answerPosition(.mount) }
            choice("Overpass's record", question.record,
                   detail: "Where Overpass last saw the scope, \(question.recordDate.formatted(date: .abbreviated, time: .shortened))") {
                model.mount.answerPosition(.record)
            }

            Divider()
            Text("Or enter where it points").font(.headline)
            HStack {
                TextField("Azimuth", value: $azimuth, format: .number.precision(.fractionLength(0...2)))
                    .frame(width: 80).multilineTextAlignment(.trailing)
                Text("az")
                TextField("Altitude", value: $altitude, format: .number.precision(.fractionLength(0...2)))
                    .frame(width: 80).multilineTextAlignment(.trailing)
                Text("alt")
                Spacer()
                Button("Use this") {
                    model.mount.answerPosition(.entered(Horizontal(azimuth: normalizedDegrees(azimuth), altitude: altitude)))
                }
                .disabled(!(-90...90).contains(altitude))
            }
            .textFieldStyle(.roundedBorder)
            Text("Not sure? Take the mount's reading, then centre a bright star or planet and use Sync on target.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 460)
        #endif
        .interactiveDismissDisabled()
    }

    private func choice(_ title: String, _ h: Horizontal, detail: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(String(format: "az %.1f°  alt %.1f°", h.azimuth, h.altitude)).monospacedDigit()
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
    }
}
