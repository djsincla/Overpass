import SkyKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var advice: [CableStopAdvisor.Option] = []

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("Location") {
                    Button("Use my current location") { Task { await model.useCurrentLocation() } }
                    numberField("Latitude (° north)", $model.settings.latitude)
                    numberField("Longitude (° east)", $model.settings.longitude)
                    numberField("Height (m)", $model.settings.heightMeters)
                    Toggle("Location set", isOn: $model.settings.hasLocation)
                }

                Section {
                    LabeledSlider("Lowest altitude", value: $model.settings.minimumAltitude, in: 0...30, step: 1, unit: "°")
                    LabeledSlider("Dark when Sun is below", value: $model.settings.darkSkySunAltitude, in: -18...0, step: 1, unit: "°")
                    Toggle("Correct for refraction", isOn: $model.settings.refraction)
                } header: {
                    Text("Sky")
                } footer: {
                    Text("A pass counts as visible when the satellite is sunlit and the Sun is below this altitude for you (−6° civil, −12° nautical twilight).")
                }

                Section {
                    LabeledSlider("Cable stop azimuth", value: $model.settings.cableStopAzimuth, in: 0...355, step: 5, unit: "°")
                    LabeledSlider("Margin", value: $model.settings.cableMargin, in: 0...20, step: 1, unit: "°")
                    Button("Suggest a cable stop from upcoming passes") { advice = suggest() }
                        .disabled(model.passes.isEmpty)
                    ForEach(advice.prefix(3), id: \.azimuth) { option in
                        Button("\(Int(option.azimuth))° \(compass(option.azimuth)) — blocks \(option.blockedPasses) of \(model.passes.count)") {
                            model.settings.cableStopAzimuth = option.azimuth
                        }
                    }
                } header: {
                    Text("Cable stop")
                } footer: {
                    Text("The mount never rotates through this azimuth, so cables can't wind up. Set the cables neutral with the scope pointing the opposite way.")
                }

                Section {
                    Toggle("Allow over the top", isOn: Binding(get: { model.settings.maximumAltitudeAxis > 90 },
                                                                set: { model.settings.maximumAltitudeAxis = $0 ? 180 : 90 }))
                    if model.settings.maximumAltitudeAxis > 90 {
                        LabeledSlider("Altitude axis up to", value: $model.settings.maximumAltitudeAxis, in: 95...180, step: 5, unit: "°")
                    }
                    LabeledSlider("Azimuth speed", value: $model.settings.maximumAzimuthRate, in: 1...10, step: 0.5, unit: "°/s")
                    LabeledSlider("Altitude speed", value: $model.settings.maximumAltitudeRate, in: 1...10, step: 0.5, unit: "°/s")
                    LabeledSlider("On target within", value: Binding(get: { model.settings.pointingTolerance * 60 },
                                                                     set: { model.settings.pointingTolerance = $0 / 60 }),
                                  in: 1...60, step: 1, unit: "′")
                } header: {
                    Text("Mount")
                } footer: {
                    Text("Over the top tilts the tube past the zenith; check it clears the mount and tripod first. Speeds are assumptions until measured on your HAZ46. \"On target\" is about half your field of view.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
        }
    }

    func suggest() -> [CableStopAdvisor.Option] {
        CableStopAdvisor.rank(model.passes, limits: model.settings.limits)
    }

    func numberField(_ title: String, _ value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .number.precision(.fractionLength(0...6)))
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
        }
    }
}
