//
//  ContentView.swift
//  Kenwood control
//
//  Created by justin Mann on 2/11/26.
//

import SwiftUI
import AppKit

struct ContentView: View {
    let radio: RadioState

    enum Section: String, Hashable {
        case connection, radio, audio, equalizer, memories, menu, profiles, midi, logs, ft8
    }

    @AppStorage("UI.SelectedSection") private var selectedSectionRaw: String = Section.connection.rawValue
    @State private var selectedSection: Section

    @State private var host: String
    @State private var portString: String
    @State private var showKnsWizard: Bool = false
    @State private var lastConnectedHost: String = UserDefaults.standard.string(forKey: "LastConnectedHost") ?? ""

    init(radio: RadioState) {
        self.radio = radio
        _selectedSection = State(initialValue: Section(rawValue: UserDefaults.standard.string(forKey: "UI.SelectedSection") ?? "") ?? .connection)
        _host = State(initialValue: KNSSettings.loadLastHost() ?? "192.168.50.56")
        if let p = KNSSettings.loadLastPort() {
            _portString = State(initialValue: String(p))
        } else {
            _portString = State(initialValue: "60000")
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                Text("Connection").tag(Section.connection)
                Text("Radio").tag(Section.radio)
                Text("Audio").tag(Section.audio)
                Text("Equalizer").tag(Section.equalizer)
                Text("Memories").tag(Section.memories)
                Text("Menu Access").tag(Section.menu)
                Text("Profiles").tag(Section.profiles)
                Text("MIDI").tag(Section.midi)
                Text("Logs").tag(Section.logs)
                Text("FT8").tag(Section.ft8)
            }
            .navigationTitle("Kenwood Control")
        } detail: {
            switch selectedSection {
            case .connection:
                ConnectionSectionView(
                    radio: radio,
                    host: $host,
                    portString: $portString,
                    showKnsWizard: $showKnsWizard,
                    lastConnectedHost: $lastConnectedHost
                )
            case .radio:
                RadioSectionView(radio: radio)
            case .audio:
                AudioSectionView(radio: radio)
            case .equalizer:
                EqualizerSectionView(radio: radio)
            case .memories:
                MemoryBrowserView(radio: radio)
            case .menu:
                RadioMenuView(radio: radio)
            case .profiles:
                ConnectionProfilesView(radio: radio)
            case .midi:
                MIDISectionView(radio: radio)
            case .logs:
                LogsSectionView(radio: radio)
            case .ft8:
                FT8SectionView(radio: radio)
            }
        }
        .controlSize(.large)
        .sheet(isPresented: $showKnsWizard) {
            KnsWizardSheetView(
                radio: radio,
                host: $host,
                portString: $portString,
                showKnsWizard: $showKnsWizard,
                lastConnectedHost: lastConnectedHost
            )
        }
        .onChange(of: selectedSection) { _, newValue in
            selectedSectionRaw = newValue.rawValue
            AppFileLogger.shared.log("UI: selectedSection=\(String(describing: newValue))")
        }
        .onReceive(NotificationCenter.default.publisher(for: KenwoodSelectSectionNotification)) { note in
            guard let raw = note.userInfo?[KenwoodSelectSectionUserInfoKey] as? String else { return }
            guard let sec = Section(rawValue: raw) else { return }
            selectedSection = sec
        }
        .onAppear {
            // Keep @State and @AppStorage in sync even if the stored value changes between runs.
            if let sec = Section(rawValue: selectedSectionRaw) {
                selectedSection = sec
            }
        }
    }
}

private struct ConnectionSectionView: View {
    @ObservedObject var radio: RadioState
    @Binding var host: String
    @Binding var portString: String
    @Binding var showKnsWizard: Bool
    @Binding var lastConnectedHost: String

    /// Credentials are considered saved when an adminId was loaded from storage.
    private var hasCredentials: Bool { !radio.adminId.isEmpty }

    /// Show the full credentials form when no saved credentials exist, or when user opts to edit.
    @State private var editingCredentials = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Connection")
                    .font(.title2)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Text("Host:")
                        TextField("Host/IP", text: $host)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 260)
                    }

                    if hasCredentials && !editingCredentials {
                        // Compact mode: credentials are saved, just show connect controls.
                        Text("Credentials saved for \(radio.adminId) (\(radio.knsAccountType == KenwoodKNS.AccountType.administrator.rawValue ? "Admin" : "User"))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Button("Edit Credentials…") { editingCredentials = true }
                            .font(.footnote)
                            .accessibilityLabel("Edit saved credentials")
                    } else {
                        // Full form: no credentials saved, or user requested edit.
                        HStack(spacing: 12) {
                            Text("Port:")
                            TextField("Port", text: $portString)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                        }

                        Toggle("Use KNS Login", isOn: $radio.useKnsLogin)

                        Picker("KNS Account Type", selection: $radio.knsAccountType) {
                            Text("Admin").tag(KenwoodKNS.AccountType.administrator.rawValue)
                            Text("User").tag(KenwoodKNS.AccountType.user.rawValue)
                        }
                        .pickerStyle(.segmented)

                        HStack(spacing: 12) {
                            Text("Admin ID:")
                            TextField("Admin ID", text: $radio.adminId)
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 260)
                        }

                        HStack(spacing: 12) {
                            Text("Password:")
                            SecureField("Password", text: $radio.adminPassword)
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 260)
                        }

                        Text("Credentials are saved when you connect.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if editingCredentials {
                            Button("Done Editing") { editingCredentials = false }
                                .font(.footnote)
                        }
                    }

                    HStack(spacing: 12) {
                        Button("Connect") {
                            let port = Int(portString) ?? 0
                            AppFileLogger.shared.log("UI: Connect pressed host=\(host) port=\(port)")
                            radio.connect(host: host, port: port)
                            editingCredentials = false
                        }
                        Button("Disconnect") { radio.disconnect() }
                        Button("KNS Setup Wizard") { showKnsWizard = true }
                    }

                    Text("Status: \(radio.connectionStatus)")
                        .font(.system(.body, design: .monospaced))

                    if let err = radio.lastError {
                        Text(err)
                            .foregroundStyle(.red)
                            .font(.system(.body, design: .monospaced))
                            .accessibilityLabel("Connection error: \(err)")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .onAppear {
            radio.loadSavedCredentials(host: host)
        }
        .onChange(of: host) { _, newHost in
            radio.loadSavedCredentials(host: newHost)
            editingCredentials = false
        }
        .onChange(of: radio.knsAccountType) { _, _ in
            radio.loadSavedCredentials(host: host)
        }
        .onChange(of: radio.connectionStatus) {
            if radio.connectionStatus == "Connected" {
                lastConnectedHost = host
                UserDefaults.standard.set(host, forKey: "LastConnectedHost")
            }
        }
    }
}

private struct RadioSectionView: View {
    @ObservedObject var radio: RadioState

    @State private var freqMHzString: String = "7.100"
    @State private var freqBMHzString: String = "7.100"

    @State private var memoryChannelString: String = "000"
    @State private var memoryProgramFreqMHzString: String = "7.100"
    @State private var memoryProgramNameString: String = ""
    @State private var memoryProgramMode: KenwoodCAT.OperatingMode = .usb
    @State private var memoryProgramFMNarrow: Bool = false

    @State private var rxVfoSelection: Int = KenwoodCAT.VFO.a.rawValue
    @State private var txVfoSelection: Int = KenwoodCAT.VFO.a.rawValue

    @State private var txPowerWattsString: String = "100"
    @State private var splitOffsetKHzString: String = "2"

    @State private var rfGainString: String = ""
    @State private var afGainString: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Radio")
                    .font(.title2)

                vfoSection

                Divider()

                memorySection

                Divider()

                transceiverControlsSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .onAppear {
            if let hz = radio.vfoAFrequencyHz {
                freqMHzString = String(format: "%.6f", Double(hz) / 1_000_000.0)
            }
            if let hz = radio.vfoBFrequencyHz {
                freqBMHzString = String(format: "%.6f", Double(hz) / 1_000_000.0)
            }
            if let v = radio.memoryChannelNumber {
                memoryChannelString = String(format: "%03d", v)
            }
            if let v = radio.rfGain {
                rfGainString = String(v)
            }
            if let v = radio.afGain {
                afGainString = String(v)
            }
        }
        .onChange(of: radio.vfoAFrequencyHz) { _, newValue in
            if let hz = newValue {
                freqMHzString = String(format: "%.6f", Double(hz) / 1_000_000.0)
            }
        }
        .onChange(of: radio.vfoBFrequencyHz) { _, newValue in
            if let hz = newValue {
                freqBMHzString = String(format: "%.6f", Double(hz) / 1_000_000.0)
            }
        }
        .onChange(of: radio.memoryChannelNumber) { _, newValue in
            if let v = newValue { memoryChannelString = String(format: "%03d", v) }
        }
        .onChange(of: radio.rxVFO?.rawValue) { _, newValue in
            if let v = newValue { rxVfoSelection = v }
        }
        .onChange(of: radio.txVFO?.rawValue) { _, newValue in
            if let v = newValue { txVfoSelection = v }
        }
        .onChange(of: radio.outputPowerWatts) { _, newValue in
            if let v = newValue { txPowerWattsString = String(v) }
        }
        .onChange(of: radio.rfGain) { _, newValue in
            if let v = newValue { rfGainString = String(v) }
        }
        .onChange(of: radio.afGain) { _, newValue in
            if let v = newValue { afGainString = String(v) }
        }
    }

    private var vfoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VFO")
                .font(.headline)

            HStack(spacing: 12) {
                Text("VFO A MHz:")
                TextField("MHz", text: $freqMHzString)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .accessibilityLabel("VFO A frequency in megahertz")
                    .onSubmit {
                        let mhz = Double(freqMHzString.replacingOccurrences(of: ",", with: ".")) ?? 0
                        let hz = Int((mhz * 1_000_000).rounded())
                        radio.send(KenwoodCAT.setVFOAFrequencyHz(hz))
                        radio.send(KenwoodCAT.getVFOAFrequency())
                    }
                Button("Set VFO A") {
                    let mhz = Double(freqMHzString.replacingOccurrences(of: ",", with: ".")) ?? 0
                    let hz = Int((mhz * 1_000_000).rounded())
                    radio.send(KenwoodCAT.setVFOAFrequencyHz(hz))
                    radio.send(KenwoodCAT.getVFOAFrequency())
                }
            }

            Divider()

            HStack(spacing: 12) {
                Text("VFO B MHz:")
                TextField("MHz", text: $freqBMHzString)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .accessibilityLabel("VFO B frequency in megahertz")
                    .onSubmit {
                        let mhz = Double(freqBMHzString.replacingOccurrences(of: ",", with: ".")) ?? 0
                        let hz = Int((mhz * 1_000_000).rounded())
                        radio.setVFOBFrequencyHz(hz)
                    }
                Button("Set VFO B") {
                    let mhz = Double(freqBMHzString.replacingOccurrences(of: ",", with: ".")) ?? 0
                    let hz = Int((mhz * 1_000_000).rounded())
                    radio.setVFOBFrequencyHz(hz)
                }
            }
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Memory Channels")
                .font(.headline)

            HStack(spacing: 12) {
                Toggle("Memory Mode", isOn: Binding(
                    get: { radio.isMemoryMode ?? false },
                    set: { radio.setMemoryMode(enabled: $0) }
                ))
                .accessibilityLabel("Memory channel mode")
            }

            HStack(spacing: 12) {
                Text("Channel:")
                TextField("000-119", text: $memoryChannelString)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .accessibilityLabel("Memory channel number")
                    .onSubmit {
                        let ch = Int(memoryChannelString.trimmingCharacters(in: .whitespaces)) ?? 0
                        radio.recallMemoryChannel(ch)
                    }

                Stepper(value: Binding(
                    get: { Int(memoryChannelString) ?? (radio.memoryChannelNumber ?? 0) },
                    set: { newValue in
                        memoryChannelString = String(format: "%03d", newValue)
                        radio.recallMemoryChannel(newValue)
                    }
                ), in: 0...119) {
                    Text(radio.memoryChannelNumber != nil ? String(format: "%03d", radio.memoryChannelNumber!) : "n/a")
                        .font(.system(.body, design: .monospaced))
                }
                .accessibilityLabel("Memory channel stepper")

                Button("Recall") {
                    let ch = Int(memoryChannelString.trimmingCharacters(in: .whitespaces)) ?? 0
                    radio.recallMemoryChannel(ch)
                }
            }

            HStack(spacing: 12) {
                Text("Name:")
                Text(radio.memoryChannelName ?? "(none)")
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Memory channel name")

                Text("Freq:")
                if let hz = radio.memoryChannelFrequencyHz {
                    Text(String(format: "%.6f MHz", Double(hz) / 1_000_000.0))
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("Memory channel frequency")
                } else {
                    Text("(unknown)")
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("Memory channel frequency unknown")
                }

                Text("Mode:")
                Text(radio.memoryChannelMode?.label ?? "(unknown)")
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Memory channel mode")
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Program Memory")
                    .font(.headline)

                HStack(spacing: 12) {
                    Text("Freq MHz:")
                    TextField("e.g. 7.100", text: $memoryProgramFreqMHzString)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .accessibilityLabel("Memory program frequency in megahertz")

                    Picker("Mode", selection: $memoryProgramMode) {
                        ForEach(KenwoodCAT.OperatingMode.allCases, id: \.rawValue) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .frame(width: 170)
                    .accessibilityLabel("Memory program mode")

                    Toggle("FM Narrow", isOn: $memoryProgramFMNarrow)
                        .disabled(memoryProgramMode != .fm)
                        .accessibilityLabel("FM narrow")
                }

                HStack(spacing: 12) {
                    Text("Name:")
                    TextField("Up to 10", text: $memoryProgramNameString)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .accessibilityLabel("Memory program name")
                }

                HStack(spacing: 12) {
                    Button("Program This Channel") {
                        let ch = Int(memoryChannelString.trimmingCharacters(in: .whitespaces)) ?? (radio.memoryChannelNumber ?? 0)
                        let mhz = Double(memoryProgramFreqMHzString.replacingOccurrences(of: ",", with: ".")) ?? 0
                        let hz = Int((mhz * 1_000_000).rounded())
                        radio.programMemoryChannel(channel: ch, frequencyHz: hz, mode: memoryProgramMode, fmNarrow: memoryProgramFMNarrow, name: memoryProgramNameString)
                    }
                    .accessibilityHint("Writes frequency, mode, and name into the selected memory channel")

                    Button("Use Current VFO A") {
                        if let hz = radio.vfoAFrequencyHz {
                            memoryProgramFreqMHzString = String(format: "%.6f", Double(hz) / 1_000_000.0)
                        }
                        if let mode = radio.operatingMode {
                            memoryProgramMode = mode
                        }
                    }
                }

                Text("Tip: select the memory channel above, then press Program.")
                    .font(.footnote)
            }
        }
    }

    private var transceiverControlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transceiver Controls")
                .font(.headline)

            // Split + RX/TX VFO selection.
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Toggle("Split (TX uses other VFO)", isOn: Binding(
                        get: { (radio.rxVFO != nil && radio.txVFO != nil) ? (radio.rxVFO != radio.txVFO) : false },
                        set: { radio.setSplitEnabled($0) }
                    ))
                    .accessibilityLabel("Split mode")
                }

                HStack(spacing: 12) {
                    Picker("RX VFO", selection: $rxVfoSelection) {
                        Text("VFO A").tag(KenwoodCAT.VFO.a.rawValue)
                        Text("VFO B").tag(KenwoodCAT.VFO.b.rawValue)
                    }
                    .frame(width: 180)
                    .accessibilityLabel("Receiver VFO")
                    .onChange(of: rxVfoSelection) { _, newValue in
                        if let v = KenwoodCAT.VFO(rawValue: newValue) {
                            radio.setReceiverVFO(v)
                        }
                    }

                    Picker("TX VFO", selection: $txVfoSelection) {
                        Text("VFO A").tag(KenwoodCAT.VFO.a.rawValue)
                        Text("VFO B").tag(KenwoodCAT.VFO.b.rawValue)
                    }
                    .frame(width: 180)
                    .accessibilityLabel("Transmitter VFO")
                    .onChange(of: txVfoSelection) { _, newValue in
                        if let v = KenwoodCAT.VFO(rawValue: newValue) {
                            radio.setTransmitterVFO(v)
                        }
                    }
                }

                Text("RX: \(radio.rxVFO?.label ?? "?")  TX: \(radio.txVFO?.label ?? "?")")
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Current receiver and transmitter VFO")
            }

            // RIT / XIT
            VStack(alignment: .leading, spacing: 10) {
                Text("RIT / XIT")
                    .font(.headline)

                HStack(spacing: 12) {
                    Toggle("RIT", isOn: Binding(
                        get: { radio.ritEnabled ?? false },
                        set: { radio.setRITEnabled($0) }
                    ))
                    Toggle("XIT", isOn: Binding(
                        get: { radio.xitEnabled ?? false },
                        set: { radio.setXITEnabled($0) }
                    ))
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Text("Offset: \(radio.ritXitOffsetHz ?? 0) Hz")
                            .font(.system(.body, design: .monospaced))
                            .accessibilityHidden(true)
                        Button("Clear") { radio.clearRitXitOffset() }
                    }
                    Slider(value: Binding(
                        get: { Double(radio.ritXitOffsetHz ?? 0) },
                        set: { radio.setRitXitOffsetHzDebounced(Int($0)) }
                    ), in: -9999...9999, step: 1)
                    .accessibilityLabel("RIT and XIT offset in hertz")
                    .accessibilityValue("\(radio.ritXitOffsetHz ?? 0) hertz")
                    Text("Adjusting the slider applies automatically.")
                        .font(.footnote)
                }
            }

            // RX Filter
            VStack(alignment: .leading, spacing: 10) {
                Text("RX Filter")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Low Cut (0–35): \(radio.rxFilterLowCutID ?? 0)")
                        .font(.system(.body, design: .monospaced))
                        .accessibilityHidden(true)
                    Slider(value: Binding(
                        get: { Double(radio.rxFilterLowCutID ?? 0) },
                        set: { radio.setReceiveFilterLowCutIDDebounced(Int($0)) }
                    ), in: 0...35, step: 1)
                    .accessibilityLabel("RX Low Cut ID")
                    .accessibilityValue("\(radio.rxFilterLowCutID ?? 0)")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("High Cut (0–27): \(radio.rxFilterHighCutID ?? 0)")
                        .font(.system(.body, design: .monospaced))
                        .accessibilityHidden(true)
                    Slider(value: Binding(
                        get: { Double(radio.rxFilterHighCutID ?? 0) },
                        set: { radio.setReceiveFilterHighCutIDDebounced(Int($0)) }
                    ), in: 0...27, step: 1)
                    .accessibilityLabel("RX High Cut ID")
                    .accessibilityValue("\(radio.rxFilterHighCutID ?? 0)")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Filter Shift (Hz): \(radio.rxFilterShiftHz ?? 0)")
                        .font(.system(.body, design: .monospaced))
                        .accessibilityHidden(true)
                    Slider(value: Binding(
                        get: { Double(radio.rxFilterShiftHz ?? 0) },
                        set: { radio.setReceiveFilterShiftHzDebounced(Int($0)) }
                    ), in: -9999...9999, step: 1)
                    .accessibilityLabel("RX Filter Shift in hertz")
                    .accessibilityValue("\(radio.rxFilterShiftHz ?? 0) hertz")
                }

                Text("Adjusting the sliders applies automatically.")
                    .font(.footnote)
                    .accessibilityLabel("Adjusting the filter sliders applies automatically")
            }

            // TX Power + ATU
            VStack(alignment: .leading, spacing: 10) {
                Text("TX Power / ATU")
                    .font(.headline)

                HStack(spacing: 12) {
                    Text("Power W:")
                    Slider(value: Binding(
                        get: { Double(radio.outputPowerWatts ?? (Int(txPowerWattsString) ?? 100)) },
                        set: { newValue in
                            let w = Int(newValue.rounded())
                            txPowerWattsString = String(w)
                            radio.setOutputPowerWattsDebounced(w)
                        }
                    ), in: 5...100, step: 1)
                    .frame(width: 220)

                    TextField("5-100", text: $txPowerWattsString)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .accessibilityLabel("Transmit power in watts")
                        .onSubmit {
                            let w = Int(txPowerWattsString) ?? 100
                            radio.setOutputPowerWattsDebounced(w)
                        }

                    Text(radio.outputPowerWatts != nil ? "\(radio.outputPowerWatts!) W" : "n/a")
                        .font(.system(.body, design: .monospaced))
                }

                Text("Adjusting the slider applies automatically.")
                    .font(.footnote)
                    .accessibilityLabel("Adjusting the transmit power slider applies automatically")

                HStack(spacing: 12) {
                    Toggle("ATU TX", isOn: Binding(
                        get: { radio.atuTxEnabled ?? false },
                        set: { radio.setATUTxEnabled($0) }
                    ))
                    Button("Tune") { radio.startATUTuning() }
                    Button("Stop Tune") { radio.stopATUTuning() }
                    Text("Tuning: \((radio.atuTuningActive ?? false) ? "On" : "Off")")
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("ATU tuning state")
                }

                HStack(spacing: 12) {
                    Text("Split Offset:")
                    TextField("kHz 1-9", text: $splitOffsetKHzString)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .accessibilityLabel("Split offset in kilohertz")
                    Button("+") {
                        let k = Int(splitOffsetKHzString) ?? 2
                        radio.setSplitOffset(plus: true, khz: k)
                    }
                    Button("-") {
                        let k = Int(splitOffsetKHzString) ?? 2
                        radio.setSplitOffset(plus: false, khz: k)
                    }
                    Text("Setting: \((radio.splitOffsetSettingActive ?? false) ? "Active" : "Idle")")
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("Split offset setting state")
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Gains")
                    .font(.headline)

                HStack(spacing: 12) {
                    Text("RF Gain:")
                    Slider(value: Binding(
                        get: { Double(radio.rfGain ?? 0) },
                        set: { newValue in
                            let v = Int(newValue.rounded())
                            rfGainString = String(v)
                            radio.setRFGainDebounced(v)
                        }
                    ), in: 0...255, step: 1)
                    .frame(width: 220)

                    TextField("0-255", text: $rfGainString)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onSubmit {
                            let v = Int(rfGainString) ?? 0
                            radio.setRFGainDebounced(v)
                        }

                    Text(radio.rfGain != nil ? "\(radio.rfGain!)" : "n/a")
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("RF gain value")
                }

                HStack(spacing: 12) {
                    Text("AF Gain:")
                    Slider(value: Binding(
                        get: { Double(radio.afGain ?? 0) },
                        set: { newValue in
                            let v = Int(newValue.rounded())
                            afGainString = String(v)
                            radio.setAFGainDebounced(v)
                        }
                    ), in: 0...255, step: 1)
                    .frame(width: 220)

                    TextField("0-255", text: $afGainString)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onSubmit {
                            let v = Int(afGainString) ?? 0
                            radio.setAFGainDebounced(v)
                        }

                    Text(radio.afGain != nil ? "\(radio.afGain!)" : "n/a")
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("AF gain value")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Squelch: \(radio.squelchLevel ?? 0)")
                        .font(.system(.body, design: .monospaced))
                        .accessibilityHidden(true)
                    Slider(value: Binding(
                        get: { Double(radio.squelchLevel ?? 0) },
                        set: { radio.setSquelchLevelDebounced(Int($0)) }
                    ), in: 0...255, step: 1)
                    .accessibilityLabel("Squelch Level")
                    .accessibilityValue("\(radio.squelchLevel ?? 0)")
                    Text("Adjusting the slider applies automatically.")
                        .font(.footnote)
                        .accessibilityLabel("Adjusting the squelch slider applies automatically")
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Mode / DSP")
                    .font(.headline)

                HStack(spacing: 12) {
                    Button("LSB") {
                        radio.operatingMode = .lsb
                        radio.send(KenwoodCAT.setOperatingMode(.lsb))
                        radio.send(KenwoodCAT.getOperatingMode(.left))
                    }
                    Button("USB") {
                        radio.operatingMode = .usb
                        radio.send(KenwoodCAT.setOperatingMode(.usb))
                        radio.send(KenwoodCAT.getOperatingMode(.left))
                    }
                }

                Picker("Mode", selection: Binding(
                    get: { radio.operatingMode ?? .usb },
                    set: { newMode in
                        radio.operatingMode = newMode
                        radio.send(KenwoodCAT.setOperatingMode(newMode))
                    }
                )) {
                    ForEach(KenwoodCAT.OperatingMode.allCases, id: \.rawValue) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                HStack(spacing: 12) {
                    Picker("NR", selection: Binding(
                        get: { radio.transceiverNRMode ?? .off },
                        set: { newMode in
                            radio.transceiverNRMode = newMode
                            radio.send(KenwoodCAT.setNoiseReduction(newMode))
                            radio.send(KenwoodCAT.getNoiseReduction())
                        }
                    )) {
                        Text("Off").tag(KenwoodCAT.NoiseReductionMode.off)
                        Text("NR1").tag(KenwoodCAT.NoiseReductionMode.nr1)
                        Text("NR2").tag(KenwoodCAT.NoiseReductionMode.nr2)
                    }
                    .pickerStyle(.radioGroup)
                }

                HStack(spacing: 12) {
                    Toggle("Notch", isOn: Binding(
                        get: { radio.isNotchEnabled ?? false },
                        set: { enabled in
                            radio.isNotchEnabled = enabled
                            radio.send(KenwoodCAT.setNotch(enabled: enabled))
                        }
                    ))
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("PTT")
                    .font(.headline)

                HStack(spacing: 12) {
                    Button("PTT Down (TX)") { radio.setPTT(down: true) }
                        .accessibilityLabel("PTT down transmit")
                    Button("PTT Up (RX)") { radio.setPTT(down: false) }
                        .accessibilityLabel("PTT up receive")
                }
                Text("Keyboard: hold Option-Space for push-to-talk.")
                    .font(.footnote)
            }
        }
    }
}

private struct AudioSectionView: View {
    @ObservedObject var radio: RadioState

    @State private var voipOutString: String = ""
    @State private var voipInString: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Audio")
                    .font(.title2)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Mic / VoIP")
                        .font(.headline)

                    HStack(spacing: 12) {
                        Picker("Mic Input", selection: $radio.selectedLanMicInputUID) {
                            if radio.audioInputDevices.isEmpty {
                                Text("No input devices").tag("")
                            } else {
                                Text("System Default Input").tag("")
                                ForEach(radio.audioInputDevices) { dev in
                                    Text(dev.displayName).tag(dev.uid)
                                }
                            }
                        }
                        .frame(minWidth: 360)
                        .accessibilityLabel("Microphone input device")

                        Text(radio.selectedLanMicInputUID.isEmpty ? "(default)" : "custom")
                            .font(.system(.body, design: .monospaced))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Text("VoIP Volume:")
                            Slider(value: Binding(
                                get: { Double(radio.voipOutputLevel ?? 0) },
                                set: { newValue in
                                    let v = Int(newValue.rounded())
                                    voipOutString = String(v)
                                    radio.setVoipOutputLevelDebounced(v)
                                }
                            ), in: 0...100, step: 1)
                            .frame(width: 240)

                            TextField("0-100", text: $voipOutString)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                                .onSubmit {
                                    let v = Int(voipOutString) ?? 0
                                    radio.setVoipOutputLevel(v)
                                }

                            Text(radio.voipOutputLevel != nil ? "\(radio.voipOutputLevel!)" : "n/a")
                                .font(.system(.body, design: .monospaced))
                        }
                        Text("Adjusting the slider applies automatically.")
                            .font(.footnote)
                            .accessibilityLabel("Adjusting the VoIP volume slider applies automatically")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Text("VoIP Mic:")
                            Slider(value: Binding(
                                get: { Double(radio.voipInputLevel ?? 0) },
                                set: { newValue in
                                    let v = Int(newValue.rounded())
                                    voipInString = String(v)
                                    radio.setVoipInputLevelDebounced(v)
                                }
                            ), in: 0...100, step: 1)
                            .frame(width: 240)

                            TextField("0-100", text: $voipInString)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                                .onSubmit {
                                    let v = Int(voipInString) ?? 0
                                    radio.setVoipInputLevel(v)
                                }

                            Text(radio.voipInputLevel != nil ? "\(radio.voipInputLevel!)" : "n/a")
                                .font(.system(.body, design: .monospaced))
                        }
                        Text("Adjusting the slider applies automatically.")
                            .font(.footnote)
                            .accessibilityLabel("Adjusting the VoIP mic slider applies automatically")
                    }

                    Text("If PTT keys but you have no modulation, set VoIP Mic above 0 (try 50).")
                        .font(.footnote)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Software Noise Reduction")
                        .font(.headline)

                    Toggle("Enable", isOn: Binding(
                        get: { radio.isNoiseReductionEnabled },
                        set: { radio.setNoiseReduction(enabled: $0) }
                    ))
                    .disabled(!radio.isNoiseReductionAvailable)
                    .accessibilityValue(radio.isNoiseReductionEnabled ? "On" : "Off")

                    Text("Shortcut: Command-Shift-N")
                        .accessibilityLabel("Noise Reduction Shortcut: Command Shift N")

                    if !radio.selectedNoiseReductionBackend.hasPrefix("WDSP") {
                        Picker("NR Profile", selection: Binding(
                            get: { radio.noiseReductionProfileRaw },
                            set: { radio.setNoiseReductionProfile(rawValue: $0) }
                        )) {
                            Text(RadioState.NoiseReductionProfile.speech.rawValue).tag(RadioState.NoiseReductionProfile.speech.rawValue)
                            Text(RadioState.NoiseReductionProfile.staticHiss.rawValue).tag(RadioState.NoiseReductionProfile.staticHiss.rawValue)
                        }
                        .frame(minWidth: 240)
                        .accessibilityLabel("Noise reduction profile")

                        HStack(spacing: 12) {
                            Text("NR Strength")
                                .accessibilityLabel("Noise reduction strength")
                            Slider(value: Binding(
                                get: { radio.noiseReductionStrength },
                                set: { radio.setNoiseReductionStrength($0) }
                            ), in: 0...1, step: 0.05)
                            .frame(minWidth: 260)
                            .accessibilityValue("\(Int(radio.noiseReductionStrength * 100)) percent")

                            Text("\(Int(radio.noiseReductionStrength * 100))%")
                                .font(.system(.body, design: .monospaced))
                                .accessibilityHidden(true)
                        }
                    }

                    HStack(spacing: 12) {
                        Text("Backend:")
                            .font(.system(.body, design: .monospaced))
                        
                        Picker("Noise Reduction Backend", selection: $radio.selectedNoiseReductionBackend) {
                            ForEach(radio.availableNoiseReductionBackends, id: \.self) { backend in
                                Text(backend).tag(backend)
                            }
                        }
                        .onChange(of: radio.selectedNoiseReductionBackend) { _, newBackend in
                            radio.setNoiseReductionBackend(newBackend)
                        }
                        .frame(minWidth: 260)
                    }
                    .accessibilityLabel("Noise reduction backend selector")
                    .accessibilityValue(radio.noiseReductionBackend)

                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("LAN RX Audio")
                        .font(.headline)

                    Toggle("Auto-start LAN audio when connected", isOn: $radio.autoStartLanAudio)

                    HStack(spacing: 12) {
                        Picker("Output", selection: $radio.selectedLanAudioOutputUID) {
                            if radio.audioOutputDevices.isEmpty {
                                Text("No output devices").tag("")
                            } else {
                                Text("System Default Output").tag("")
                                ForEach(radio.audioOutputDevices) { dev in
                                    Text(dev.displayName).tag(dev.uid)
                                }
                            }
                        }
                        .frame(minWidth: 360)
                        .accessibilityLabel("Mac speaker output device")
                        .onChange(of: radio.selectedLanAudioOutputUID) { _, newUID in
                            AppFileLogger.shared.log("UI: LAN output selection uid=\(newUID.isEmpty ? "(default)" : newUID)")
                            radio.applyLanAudioOutputSelection()
                        }

                        Button("Refresh Audio Devices") { radio.refreshAudioDevices() }

                        Text(radio.isLanAudioRunning ? "Running" : "Stopped")
                            .font(.system(.body, design: .monospaced))
                    }

                    HStack(spacing: 12) {
                        Text("Volume:")
                        Slider(value: Binding(
                            get: { radio.lanAudioOutputGain },
                            set: { radio.setLanAudioOutputGain($0) }
                        ), in: 0.1...4.0)
                        .frame(width: 240)

                        Text(String(format: "%.2f", radio.lanAudioOutputGain))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 64, alignment: .trailing)
                    }

                    if let err = radio.lanAudioError {
                        Text("LAN Audio Error: \(err)")
                            .foregroundStyle(.red)
                            .accessibilityLabel("LAN audio error \(err)")
                    }

                    HStack(spacing: 12) {
                        Text("Packets: \(radio.lanAudioPacketCount)")
                            .font(.system(.body, design: .monospaced))
                        if let t = radio.lanAudioLastPacketAt {
                            Text("Last: \(t.formatted(date: .omitted, time: .standard))")
                                .font(.system(.body, design: .monospaced))
                        } else {
                            Text("Last: (none)")
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .onAppear {
            if let v = radio.voipOutputLevel { voipOutString = String(v) }
            if let v = radio.voipInputLevel { voipInString = String(v) }
        }
        .onChange(of: radio.voipOutputLevel) { _, newValue in
            if let v = newValue { voipOutString = String(v) }
        }
        .onChange(of: radio.voipInputLevel) { _, newValue in
            if let v = newValue { voipInString = String(v) }
        }
    }
}

private struct LogsSectionView: View {
    @ObservedObject var radio: RadioState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Logs")
                    .font(.title2)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Status: \(radio.connectionStatus)")
                    if let vfo = radio.vfoAFrequencyHz {
                        Text(String(format: "VFO A: %.6f MHz", Double(vfo) / 1_000_000.0))
                    }
                    if let mode = radio.operatingMode {
                        Text("Mode: \(mode.label)")
                    } else {
                        Text("Mode: (unknown)")
                    }
                    if let isTx = radio.isTransmitting {
                        Text("PTT: \(isTx ? "TX" : "RX")")
                    } else {
                        Text("PTT: (unknown)")
                    }
                    Text("TX: \(radio.lastTXFrame)")
                    Text("RX: \(radio.lastRXFrame)")
                }
                .font(.system(.body, design: .monospaced))

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Text("Connection Log")
                            .font(.headline)
                        Button("Clear") { radio.clearConnectionLog() }
                            .disabled(radio.connectionLog.isEmpty)
                        Button("Copy Log") {
                            let joined = radio.connectionLog.joined(separator: "\n")
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(joined, forType: .string)
                        }
                        .disabled(radio.connectionLog.isEmpty)
                    }

                    if radio.connectionLog.isEmpty {
                        Text("No connection events")
                            .accessibilityLabel("No connection events")
                    } else {
                        List(radio.connectionLog.indices, id: \.self) { index in
                            Text(radio.connectionLog[index])
                        }
                        .frame(minHeight: 180)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Smoke Test")
                        .font(.headline)
                    Button("Run Smoke Test") { radio.runSmokeTest() }
                    Text("Smoke Test: \(radio.smokeTestStatus)")
                        .accessibilityLabel("Smoke test status \(radio.smokeTestStatus)")
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Errors")
                        .font(.headline)
                    if radio.errorLog.isEmpty {
                        Text("No errors")
                            .accessibilityLabel("No errors")
                    } else {
                        List(radio.errorLog.indices, id: \.self) { index in
                            Text(radio.errorLog[index])
                        }
                        .frame(minHeight: 180)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
    }
}

private struct KnsWizardSheetView: View {
    @ObservedObject var radio: RadioState
    @Binding var host: String
    @Binding var portString: String
    @Binding var showKnsWizard: Bool
    let lastConnectedHost: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("KNS Setup Wizard")
                .font(.title2)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Step 1: On the radio, enable KNS and set LAN operation.")
                    Text("Step 2: Set an administrator ID and password in the radio's LAN menu.")
                    Text("Step 3: Note the radio's IP address.")
                    Text("Step 4: Use TCP port 60000 for direct KNS control.")
                    Text("Step 5: Keep the connection active to avoid idle disconnect.")
                }
            }

            HStack(spacing: 12) {
                Text("Radio IP:")
                TextField("e.g. 192.168.1.20", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 260)
            }

            Toggle("Use KNS Login", isOn: $radio.useKnsLogin)

            Picker("KNS Account Type", selection: $radio.knsAccountType) {
                Text("Admin").tag(KenwoodKNS.AccountType.administrator.rawValue)
                Text("User").tag(KenwoodKNS.AccountType.user.rawValue)
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                Text("Admin ID:")
                TextField("Admin ID", text: $radio.adminId)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 260)
            }

            HStack(spacing: 12) {
                Text("Password:")
                SecureField("Password", text: $radio.adminPassword)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 260)
            }

            Text("Credentials are used for this session only.")
                .font(.footnote)

            Button("Use Last Connected IP") {
                if !lastConnectedHost.isEmpty {
                    host = lastConnectedHost
                }
            }
            .disabled(lastConnectedHost.isEmpty)

            Text("Status: \(radio.connectionStatus)")

            HStack(spacing: 12) {
                Button("Use Port 60000") { portString = "60000" }
                Button("Test Connection") {
                    let port = Int(portString) ?? 0
                    radio.connect(host: host, port: port)
                }
                Button("Disconnect") { radio.disconnect() }
                Button("Close") { showKnsWizard = false }
            }
            .padding(.top, 4)
        }
        .padding()
        .frame(minWidth: 520, minHeight: 320)
        .onAppear {
            radio.loadSavedCredentials(host: host)
        }
        .onChange(of: host) { _, newHost in
            radio.loadSavedCredentials(host: newHost)
        }
        .onChange(of: radio.knsAccountType) { _, _ in
            radio.loadSavedCredentials(host: host)
        }
    }
}

// Note: SwiftUI Previews are disabled for command-line builds in this project to avoid
// preview macro/plugin issues in headless environments.
