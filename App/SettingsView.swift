import IOptronKit
import SkyKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    /// "0.1.0 (1)", from the bundle (set in project.yml).
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    @Environment(AppModel.self) private var model
    @State private var slewTest: String?
    @State private var testingSlew = false
    @State private var modeTest: String?
    @State private var setAzimuth = 0.0
    @State private var setAltitude = 0.0
    @State private var positionResult: String?
    @State private var busy = false
    @State private var exportingSettings = false
    @State private var importingSettings = false
    @State private var importResult: String?
    @State private var settingsFile = JSONFile(data: Data())
    #if os(macOS)
    @State private var serialPorts: [String] = []
    #endif

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Toggle("Always dark", isOn: $model.settings.alwaysDark)
                    Toggle("Red mode", isOn: $model.settings.redMode)
                    Picker("Units", selection: $model.settings.imperial) {
                        Text("Metric (km, m)").tag(false)
                        Text("Imperial (mi, ft)").tag(true)
                    }
                    #if os(iOS)
                    Toggle("Red app icon", isOn: $model.settings.redAppIcon)
                        .onChange(of: model.settings.redAppIcon) { _, red in AppIcon.setRed(red) }
                    #endif
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Red mode draws everything in red on black so your eyes stay dark-adapted. Also turn your screen brightness down.")
                }

                connectionSection

                Section("Location") {
                    Button("Use my current location") { Task { await model.useCurrentLocation() } }
                    Button("Use the mount's GPS") { Task { await model.useMountLocation() } }
                        .disabled(model.mount.site == nil)
                        .help("The latitude and longitude the mount had when it connected, from its GPS or hand controller. Connect over WiFi or USB Normal mode first.")
                    numberField("Latitude (° north)", $model.settings.latitude)
                    numberField("Longitude (° east)", $model.settings.longitude)
                    if model.settings.imperial {
                        numberField("Height (ft)", Binding(get: { model.settings.heightMeters / Units.metresPerFoot },
                                                           set: { model.settings.heightMeters = $0 * Units.metresPerFoot }))
                    } else {
                        numberField("Height (m)", $model.settings.heightMeters)
                    }
                }
                // Typing a position counts as setting one. (A "Location set" switch used to sit
                // here, and turning it off emptied the Observe screen.)
                .onChange(of: model.settings.latitude) { _, _ in model.settings.hasLocation = true }
                .onChange(of: model.settings.longitude) { _, _ in model.settings.hasLocation = true }

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
                    LabeledContent("Cable stop", value: "\(Int(model.settings.cableStopAzimuth))° \(compass(model.settings.cableStopAzimuth))")
                    LabeledSlider("Margin", value: $model.settings.cableMargin, in: 0...20, step: 1, unit: "°")
                    Toggle("Unwind at north without asking", isOn: $model.settings.unwindsWithoutAsking)
                    Toggle("Track past north (Special mode)", isOn: $model.settings.tracksPastNorth)
                        .help("Smooth and camera tracking carry on past north by up to the overtravel, then the mount unwinds when tracking ends. The cables need that much slack.")
                    if model.settings.tracksPastNorth {
                        LabeledSlider("Overtravel", value: $model.settings.overtravel, in: 15...180, step: 15, unit: "°")
                    }
                } header: {
                    Text("Cable stop")
                } footer: {
                    Text("The mount never turns through north, in either hemisphere. Its own goto works this way, so Overpass does the same. When tracking reaches north, the mount stops and Overpass asks whether to go the long way round and carry on. Set the cables neutral with the scope pointing the opposite way.")
                }

                Section {
                    Toggle("Allow over the top", isOn: Binding(get: { model.settings.maximumAltitudeAxis > 90 },
                                                                set: { model.settings.maximumAltitudeAxis = $0 ? 180 : 90 }))
                    if model.settings.maximumAltitudeAxis > 90 {
                        LabeledSlider("Altitude axis up to", value: $model.settings.maximumAltitudeAxis, in: 95...180, step: 5, unit: "°")
                    }
                    LabeledSlider("Point down to", value: $model.settings.minimumAltitudeAxis, in: -45...10, step: 1, unit: "°")
                        .help("The lowest altitude Overpass will drive the mount to. Below 0° points under the horizon (from a hillside, or at the ground for testing); check the tube clears the tripod and anything around it.")
                    LabeledSlider("Start tracking at", value: $model.settings.trackingStartAltitude, in: 0...45, step: 1, unit: "°")
                    LabeledContent("Sound alerts") {
                        VStack(alignment: .leading) {
                            Toggle("A minute before tracking starts", isOn: $model.settings.minuteWarningSound)
                                .help("A 1500 Hz tone, the WWV time signal's hour mark")
                            Toggle("Count down the last 10 seconds", isOn: $model.settings.countdownSounds)
                                .help("A tick each second, like WWV on 10 MHz, and a long 1000 Hz tone as tracking begins")
                        }
                    }
                    Picker("Normal mode updates", selection: $model.settings.normalModePeriod) {
                        ForEach([0.5, 1, 2, 5], id: \.self) { period in
                            Text("Every \(period.formatted(.number.precision(.fractionLength(0...1)))) s").tag(period)
                        }
                    }
                    .help("Normal mode (WiFi or USB): how often the position is read while idle, and the shortest Step tracking interval. Sub-second commands have caused trouble on the HAZ46 in Normal mode.")
                    Picker("Smooth tracking updates", selection: $model.settings.trackingPeriod) {
                        ForEach([0.05, 0.1, 0.2, 0.5, 1, 2], id: \.self) { period in
                            Text("Every \(period.formatted(.number.precision(.fractionLength(0...2)))) s").tag(period)
                        }
                    }
                    .help("How often Smooth tracking reads the axes and sets the speeds (Special mode). Each update takes about 45 ms on the HAZ46, so 0.05 s runs them nearly as fast as the mount answers. Longer periods hold each speed for the whole interval and correct more gently.")
                    LabeledSlider("Azimuth speed", value: $model.settings.maximumAzimuthRate, in: 1...10, step: 0.5, unit: "°/s")
                    LabeledSlider("Altitude speed", value: $model.settings.maximumAltitudeRate, in: 1...10, step: 0.5, unit: "°/s")
                    LabeledSlider("On target within", value: Binding(get: { model.settings.pointingTolerance * 60 },
                                                                     set: { model.settings.pointingTolerance = $0 / 60 }),
                                  in: 1...60, step: 1, unit: "′")
                    Toggle("Keep a tracking log to export", isOn: $model.settings.tracksLog)
                        .help("For debugging: keeps the last \(Int(MountSession.traceSpan / 60)) minutes of tracking and adds an export button to the tracking chart, to save it as CSV")
                } header: {
                    Text("Mount")
                } footer: {
                    Text("Over the top tilts the tube past the zenith; check it clears the mount and tripod first. Speeds are assumptions until measured on your HAZ46. \"On target\" is about half your field of view.")
                }

                Section {
                    Button("Export settings…") {
                        settingsFile = JSONFile(data: model.settingsFile())
                        exportingSettings = true
                    }
                    Button("Import settings…") { importingSettings = true }
                    if let importResult { Text(importResult).font(.callout).foregroundStyle(.secondary) }
                } header: {
                    Text("Settings file")
                } footer: {
                    Text("Carries the location, cable stop, limits, speeds, timing and alignment to another device, by AirDrop or Files. Each device keeps its own connection, camera and appearance.")
                }
                .fileExporter(isPresented: $exportingSettings, document: settingsFile, contentType: .json,
                              defaultFilename: "Overpass settings") { _ in }
                .fileImporter(isPresented: $importingSettings, allowedContentTypes: [.json]) { result in
                    if case .success(let url) = result { importResult = model.importSettings(from: url) }
                }

                Section {
                    ShareLink(item: MountSession.logFile) {
                        Label("Share the mount log", systemImage: "doc.text")
                    }
                    .disabled(!FileManager.default.fileExists(atPath: MountSession.logFile.path))
                } header: {
                    Text("Reporting a problem")
                } footer: {
                    Text("Email AB6A@arrl.net with the mount log, the settings file, the time it went wrong (UTC if you can) and what you were tracking. The log has every connect, mode switch, goto, step and stop, with what the mount read back.")
                }

                #if os(iOS)
                Section {
                    AboutRows()
                } header: {
                    Text("About")
                } footer: {
                    Text(AboutRows.credits)
                }
                #endif
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
        }
    }

    private var connectionSection: some View {
        @Bindable var model = model
        return Section {
            Picker("Connect by", selection: $model.settings.connection) {
                ForEach(ConnectionKind.allCases) { Text($0.rawValue).tag($0) }
            }
            if !model.settings.connection.isSpecialMode {
                Toggle("Turn off the mount's tracking when connecting", isOn: $model.settings.stopsMountTrackingOnConnect)
                    .help("The mount can be tracking by itself at the sidereal, lunar or solar rate, after a goto from the hand controller or from an earlier session. On, Overpass turns that off when it connects, so the mount sits still until you track something.")
            }
            switch model.settings.connection {
            case .wifi:
                TextField("Mount address", text: $model.settings.wifiHost).autocorrectionDisabled()
                LabeledContent("Port") {
                    TextField("Port", value: $model.settings.wifiPort, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                }
            case .usb, .usbNormal:
                #if os(macOS)
                HStack {
                    Picker("USB port", selection: $model.settings.serialPath) {
                        Text("Choose…").tag("")
                        ForEach(serialPorts, id: \.self) { Text($0).tag($0) }
                    }
                    Button { serialPorts = SerialTransport.availablePorts() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Look for USB serial ports again (after plugging the mount in)")
                        .accessibilityLabel("Refresh USB ports")
                }
                .onAppear { serialPorts = SerialTransport.availablePorts() }
                #else
                TextField("Relay address", text: $model.settings.relayHost).autocorrectionDisabled()
                LabeledContent("Relay port") {
                    TextField("Port", value: $model.settings.relayPort, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                }
                #endif
                if model.settings.connection.isSpecialMode {
                    Toggle("Use the mount's own alignment", isOn: $model.settings.captureMountAlignment)
                        .help("Use iOptron's own axis coordinates instead of a star alignment. The mount loses its position when it changes mode, so each time it enters Special mode Overpass sets the axes to where the scope points: from the mount's Normal-mode position if it has one, otherwise from where Overpass last saw it.")
                    Button(testingSlew ? "Testing the mount's slew…" : "Test the mount's slew") {
                        testingSlew = true
                        Task {
                            slewTest = await model.mount.testNativeSlew()
                            testingSlew = false
                        }
                    }
                    .disabled(testingSlew || model.mount.kind != .usb || model.mount.state != .connected)
                    .help("Moves the azimuth axis about 25°, including across north, to learn how the mount's own slew counts position. Stand by the mount.")
                    if let slewTest {
                        Text(slewTest).font(.caption.monospacedDigit()).textSelection(.enabled)
                    }
                    let connected = model.mount.kind == .usb && model.mount.state == .connected
                    Button(busy ? "Working…" : "Test mode switching") {
                        busy = true
                        Task {
                            modeTest = await model.mount.testModeSwitching()
                            busy = false
                        }
                    }
                    .disabled(busy || !connected)
                    .help("Switches to Normal mode and back without moving or syncing anything, reading the position at each step. Nothing moves.")
                    if let modeTest {
                        Text(modeTest).font(.caption.monospacedDigit()).textSelection(.enabled)
                    }
                    HStack {
                        Text("Set position")
                        Spacer()
                        TextField("Azimuth", value: $setAzimuth, format: .number.precision(.fractionLength(0...3)))
                            .frame(width: 80).multilineTextAlignment(.trailing)
                        Text("az")
                        TextField("Altitude", value: $setAltitude, format: .number.precision(.fractionLength(0...3)))
                            .frame(width: 80).multilineTextAlignment(.trailing)
                        Text("alt")
                        Button("Set") {
                            busy = true
                            Task {
                                positionResult = await model.mount.setPosition(Horizontal(azimuth: setAzimuth, altitude: setAltitude))
                                busy = false
                            }
                        }
                        .disabled(busy || !connected)
                    }
                    .help("Tells the mount where the scope actually points, in degrees, when you know it (a park position, or from a trace). Nothing moves.")
                    .onAppear {
                        if let known = model.mount.knownPointing { setAzimuth = known.azimuth; setAltitude = known.altitude }
                    }
                    if let positionResult {
                        Text(positionResult).font(.caption).textSelection(.enabled)
                    }
                }
            }
        } header: {
            Text("Mount connection")
        } footer: {
            switch model.settings.connection {
            case .wifi:
                Text("Normal mode over the mount's WiFi: Passive and Step tracking. Join the mount's WiFi network first. 10.10.100.254:8899 is iOptron's usual address; check your manual.")
            case .usbNormal:
                Text("Normal mode over the mount's USB port: Passive and Step tracking, as over WiFi. If the mount is in Special mode it leaves it, and its position is carried across.")
            case .usb:
                #if os(macOS)
                Text("Special mode over the mount's USB port: Smooth tracking, after star alignment. Special mode stays on through power cycles, and WiFi won't work while it's on.")
                #else
                Text("Special mode only works over USB, so an iPhone or iPad reaches it through a relay plugged into the mount, such as a Raspberry Pi running ser2net at 115200 baud.")
                #endif
            }
        }
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

/// A JSON file to save, for the settings export.
struct JSONFile: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
