import Foundation
import Combine
import CoreAudio
#if canImport(AppKit)
import AppKit
#endif

struct MemoryChannel: Identifiable {
    let id: Int            // channel number 0–119
    var frequencyHz: Int
    var mode: KenwoodCAT.OperatingMode
    var name: String
    var isEmpty: Bool      // radio reports blank channel

    var frequencyMHz: String {
        String(format: "%.6f", Double(frequencyHz) / 1_000_000.0)
    }
}

final class RadioState: ObservableObject {
    enum ConnectionStatus: String { case disconnected = "Disconnected", connecting = "Connecting", authenticating = "Authenticating", connected = "Connected" }
    enum NoiseReductionProfile: String, CaseIterable {
        // Minimal, predictable presets. Users can fine-tune with NR Strength.
        case speech = "Speech"
        case staticHiss = "Static/Hiss"

        var recommendedStrength: Double {
            switch self {
            case .speech: return 0.60
            case .staticHiss: return 1.00
            }
        }
    }

    @Published var connectionStatus: String = ConnectionStatus.disconnected.rawValue
    @Published var lastRXFrame: String = ""
    @Published var lastTXFrame: String = ""
    @Published var vfoAFrequencyHz: Int?
    @Published var vfoBFrequencyHz: Int?
    @Published var operatingMode: KenwoodCAT.OperatingMode?
    @Published var transceiverNRMode: KenwoodCAT.NoiseReductionMode?
    @Published var isNotchEnabled: Bool?
    @Published var rfGain: Int?
    @Published var afGain: Int?
    @Published var squelchLevel: Int?
    @Published var sMeterDots: Int?
    @Published var rxVFO: KenwoodCAT.VFO?
    @Published var txVFO: KenwoodCAT.VFO?
    @Published var ritEnabled: Bool?
    @Published var xitEnabled: Bool?
    @Published var ritXitOffsetHz: Int?
    @Published var rxFilterShiftHz: Int?
    @Published var rxFilterLowCutID: Int?
    @Published var rxFilterHighCutID: Int?
    @Published var outputPowerWatts: Int?
    @Published var atuTxEnabled: Bool?
    @Published var atuTuningActive: Bool?
    @Published var splitOffsetSettingActive: Bool?
    @Published var splitOffsetPlus: Bool?
    @Published var splitOffsetKHz: Int?
    @Published var isTransmitting: Bool?
    @Published var isPTTDown: Bool = false
    @Published var isMemoryMode: Bool?
    @Published var memoryChannelNumber: Int?
    @Published var memoryChannelFrequencyHz: Int?
    @Published var memoryChannelMode: KenwoodCAT.OperatingMode?
    @Published var memoryChannelName: String?
    @Published var lastError: String?
    @Published var isNoiseReductionEnabled: Bool = false
    @Published var noiseReductionBackend: String = "Passthrough"
    @Published var availableNoiseReductionBackends: [String] = []
    @Published var selectedNoiseReductionBackend: String = "Passthrough"
    @Published var noiseReductionStrength: Double = 1.0
    @Published var noiseReductionProfileRaw: String = NoiseReductionProfile.speech.rawValue
    @Published var errorLog: [String] = []
    @Published var connectionLog: [String] = []
    @Published var smokeTestStatus: String = "Not run"
    @Published var useKnsLogin: Bool = true
    @Published var adminId: String = ""
    @Published var adminPassword: String = ""
    @Published var knsAccountType: String = KenwoodKNS.AccountType.administrator.rawValue

    // Audio monitor (USB audio in -> NR -> speakers out)
    @Published var audioInputDevices: [AudioDeviceInfo] = []
    @Published var audioOutputDevices: [AudioDeviceInfo] = []
    @Published var selectedAudioInputUID: String = ""
    @Published var selectedAudioOutputUID: String = ""
    @Published var isAudioMonitorRunning: Bool = false
    @Published var audioMonitorError: String?
    @Published var audioMonitorLog: [String] = []
    @Published var audioMonitorWetDry: Double = 1.0
    @Published var audioMonitorInputGain: Double = 1.0
    @Published var audioMonitorOutputGain: Double = 1.0

    // LAN audio (UDP 60001) experimental RX path
    @Published var isLanAudioRunning: Bool = false
    @Published var lanAudioError: String?
    @Published var lanAudioWetDry: Double = 1.0
    @Published var lanAudioOutputGain: Double = 1.0
    @Published var isAudioMuted: Bool = false
    @Published var selectedLanAudioOutputUID: String = ""
    @Published var lanAudioPacketCount: Int = 0
    @Published var lanAudioLastPacketAt: Date?
    @Published var autoStartLanAudio: Bool = true
    @Published var voipOutputLevel: Int?
    @Published var voipInputLevel: Int?
    @Published var selectedLanMicInputUID: String = ""
    @Published var dataModeEnabled: Bool?
    @Published var mdMode: Int?

    // MARK: - Built-in Radio EQ (via EX extended menu commands)
    // TX EQ: EX030 (low), EX031 (mid), EX032 (high)   range: −20…+10 dB
    // RX EQ: EX060 (low), EX061 (mid), EX062 (high)   range: −20…+10 dB
    @Published var txEQLowGain: Int? = nil
    @Published var txEQMidGain: Int? = nil
    @Published var txEQHighGain: Int? = nil
    @Published var rxEQLowGain: Int? = nil
    @Published var rxEQMidGain: Int? = nil
    @Published var rxEQHighGain: Int? = nil

    // General EX menu value store for the Menu Access view (menu# → last-seen value)
    @Published var exMenuValues: [Int: Int] = [:]

    // MARK: - Memory browser (all 120 channels)
    @Published var memoryChannels: [MemoryChannel] = []
    @Published var isLoadingAllMemories: Bool = false

    private let connection = TS890Connection()
    /// Proxy wrapping the active backend. Passed to LanAudioPipeline and AudioMonitor
    /// so backend switches (and enable/disable) immediately affect all running pipelines.
    private let processorProxy = NoiseReductionProcessorProxy(inner: PassthroughNoiseReduction())
    private var noiseProcessor: any NoiseReductionProcessor {
        get { processorProxy.inner }
        set { processorProxy.inner = newValue }
    }
    private var audioMonitor: AudioMonitor?
    private var lanReceiver: KenwoodLanAudioReceiver?
    private var lanPipeline: LanAudioPipeline?
    private var lanPlayer: AudioOutputPlayer?
    private var micCapture: KenwoodLanMicCapture?
    private let micSendQueue = DispatchQueue(label: "KenwoodLanMicSend.queue")
    private var micFrameLogCountdown: Int = 0
    private var micTxFrames: [[Int16]] = []
    private var micTxTimer: DispatchSourceTimer?
    private enum MicTxSource { case mic, generated }
    private var micTxSource: MicTxSource = .mic
    private struct GeneratedTxState {
        var framesRemaining: Int
        var phase: Double
        var frequencyHz: Double
        var amplitude: Double
    }
    private var generatedTxState: GeneratedTxState?
    private var currentHost: String = ""
    private var cancellables: Set<AnyCancellable> = []
    private let lanRxTapQueue = DispatchQueue(label: "KenwoodLanAudio.tap")

    // Optional tap for consumers (FT8, recording, etc). Called off the main thread.
    // Frame format: 48 kHz mono float samples.
    var onLanRxAudio48kMono: (([Float]) -> Void)?
    // Keep high-rate packet counts off the main thread; publish a throttled view for UI/VoiceOver.
    private var lanAudioPacketCountRaw: Int = 0
    private var lanAudioLastPacketAtRaw: Date?
    // Throttle noisy CAT frames so VoiceOver doesn't lose focus due to constant UI updates.
    private var lastRXFrameSMAt: Date = .distantPast
    private let nrStrengthKey        = "nr_strength"
    private let nrProfileKey         = "nr_profile"
    private let nrBackendKey         = "nr_backend"
    private let lanAudioOutputUIDKey = "lan_audio_output_uid"
    private let lanMicInputUIDKey    = "lan_mic_input_uid"
    private let audioInputUIDKey     = "audio_input_uid"
    // Cache the most recently loaded/saved credentials so we don't touch Keychain on every connect.
    // Keyed by "\(accountTypeRaw)|\(host)".
    private var knsCredentialCache: [String: (username: String, password: String)] = [:]
    private var debouncedCAT: [String: DispatchWorkItem] = [:]

    init() {
        // Build the list of available NR backends.
        var available: [String] = []
        if WDSPNoiseReductionProcessor(mode: .emnr) != nil { available.append("WDSP EMNR") }
        if WDSPNoiseReductionProcessor(mode: .anr)  != nil { available.append("WDSP ANR") }
        if RNNoiseProcessor() != nil { available.append("RNNoise (in-process)") }
        available.append("Passthrough (disabled)")
        self.availableNoiseReductionBackends = available

        // Pick the best available backend and wire it into the proxy.
        // Auto-selection order: WDSP EMNR → RNNoise C → Passthrough.
        if let emnr = WDSPNoiseReductionProcessor(mode: .emnr) {
            noiseProcessor = emnr
            isNoiseReductionEnabled = false
            noiseReductionBackend = "WDSP EMNR"
            selectedNoiseReductionBackend = "WDSP EMNR"
        } else if let rnnoise = RNNoiseProcessor() {
            noiseProcessor = rnnoise
            isNoiseReductionEnabled = rnnoise.isEnabled
            noiseReductionBackend = rnnoise.backendDescription
            selectedNoiseReductionBackend = "RNNoise (in-process)"
        } else {
            noiseProcessor = PassthroughNoiseReduction()
            isNoiseReductionEnabled = false
            noiseReductionBackend = "Passthrough (disabled)"
            selectedNoiseReductionBackend = "Passthrough (disabled)"
        }
        AppFileLogger.shared.log("Noise reduction backend: \(noiseReductionBackend)")

        loadPersistedKnsSettings()
        loadPersistedNoiseReductionSettings()
        // Apply initial strength to both paths (LAN + monitor).
        setNoiseReductionStrength(noiseReductionStrength, persist: false)
        // Apply profile after strength so preset can override if user chose it.
        applyNoiseReductionProfile(persist: false)

        refreshAudioDevices()
        // Restore saved audio input, or fall back to system default.
        if let saved = UserDefaults.standard.string(forKey: audioInputUIDKey), !saved.isEmpty,
           audioInputDevices.contains(where: { $0.uid == saved }) {
            selectedAudioInputUID = saved
        } else if selectedAudioInputUID.isEmpty {
            if let defaultID = AudioDeviceManager.defaultInputDeviceID(),
               let match = audioInputDevices.first(where: { $0.id == defaultID }) {
                selectedAudioInputUID = match.uid
            } else if let first = audioInputDevices.first {
                selectedAudioInputUID = first.uid
            }
        }
        if selectedAudioOutputUID.isEmpty {
            if let defaultID = AudioDeviceManager.defaultOutputDeviceID(),
               let match = audioOutputDevices.first(where: { $0.id == defaultID }) {
                selectedAudioOutputUID = match.uid
            } else if let first = audioOutputDevices.first {
                selectedAudioOutputUID = first.uid
            }
        }
        // Restore saved LAN audio output device, or default to system output (empty string).
        if let saved = UserDefaults.standard.string(forKey: lanAudioOutputUIDKey), !saved.isEmpty,
           audioOutputDevices.contains(where: { $0.uid == saved }) {
            selectedLanAudioOutputUID = saved
        }
        // Restore saved LAN mic input, or default to system input (empty string).
        if let saved = UserDefaults.standard.string(forKey: lanMicInputUIDKey), !saved.isEmpty,
           audioInputDevices.contains(where: { $0.uid == saved }) {
            selectedLanMicInputUID = saved
        }

        // Wire connection callbacks to update published state on main thread
        connection.onStatusChange = { [weak self] status in
            AppLogger.info("Status: \(status.rawValue)")
            AppFileLogger.shared.log("Status: \(status.rawValue)")
            DispatchQueue.main.async {
                let mapped: ConnectionStatus
                switch status {
                case .connected: mapped = .connected
                case .connecting: mapped = .connecting
                case .authenticating: mapped = .authenticating
                case .disconnected: mapped = .disconnected
                }
                self?.connectionStatus = mapped.rawValue.capitalized
                self?.announceConnectionStatus(mapped)

                guard let self else { return }
                if mapped == .connected, self.autoStartLanAudio, !self.currentHost.isEmpty {
                    if self.isLanAudioRunning {
                        // Receiver is already bound — just tell the radio to resume streaming.
                        AppFileLogger.shared.log("LAN: reconnect — reusing existing receiver, sending ##VP1")
                        self.connection.send("##VP1;")
                    } else {
                        self.startLanAudio(host: self.currentHost)
                    }
                    // Prime basic audio/rf controls so sliders reflect real state.
                    self.send(KenwoodCAT.getAFGain())
                    self.send(KenwoodCAT.getRFGain())
                    self.send(KenwoodCAT.getVoipInputLevel())
                    self.send(KenwoodCAT.getVoipOutputLevel())
                    // Prime common operating controls (top-5 features).
                    self.queryTop5()
                }
                if mapped == .disconnected {
                    self.stopMicCapture()
                    // Keep the UDP receiver alive so port 60001 stays bound.
                    // On reconnect we just re-send ##VP1 rather than rebinding.
                    self.isPTTDown = false
                }
            }
        }
        connection.onError = { [weak self] err in
            AppLogger.error(err)
            AppFileLogger.shared.log("Error: \(err)")
            DispatchQueue.main.async {
                self?.lastError = err
                self?.errorLog.append(err)
                self?.connectionLog.append("Error: \(err)")
                self?.announceError(err)
            }
        }
        connection.onFrame = { [weak self] frame in
            DispatchQueue.main.async {
                guard let self else { return }
                self.handleFrame(frame)
                if self.shouldPublishLastRXFrame(frame) {
                    self.lastRXFrame = frame
                }
            }
        }
        connection.onLog = { [weak self] message in
            // Auto Information (AI) produces a lot of RX: SM.... frames; keep them out of logs for performance/VoiceOver.
            if message.hasPrefix("RX: SM") { return }
            AppLogger.info(message)
            AppFileLogger.shared.log(message)
            DispatchQueue.main.async {
                guard let self else { return }
                self.connectionLog.append(message)
                if self.connectionLog.count > 50 {
                    self.connectionLog.removeFirst(self.connectionLog.count - 50)
                }
            }
        }

        // Switching output devices must take effect immediately, not only on the next start.
        $selectedLanAudioOutputUID
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] uid in
                guard let self else { return }
                UserDefaults.standard.set(uid, forKey: self.lanAudioOutputUIDKey)
                self.switchLanAudioOutputIfRunning()
            }
            .store(in: &cancellables)

        // Persist audio input selections whenever they change.
        $selectedLanMicInputUID
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] uid in
                guard let self else { return }
                UserDefaults.standard.set(uid, forKey: self.lanMicInputUIDKey)
            }
            .store(in: &cancellables)

        $selectedAudioInputUID
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] uid in
                guard let self else { return }
                UserDefaults.standard.set(uid, forKey: self.audioInputUIDKey)
            }
            .store(in: &cancellables)
    }

    func setAudioMuted(_ muted: Bool) {
        isAudioMuted = muted
        applyAudioMuteState()
        AppFileLogger.shared.log("Audio: muted=\(muted)")
    }

    func toggleAudioMute() {
        setAudioMuted(!isAudioMuted)
    }

    private func applyAudioMuteState() {
        let factor: Float = isAudioMuted ? 0.0 : 1.0
        lanPlayer?.gain = Float(lanAudioOutputGain) * factor
        audioMonitor?.outputGain = Float(audioMonitorOutputGain) * factor
    }

    func clearConnectionLog() {
        connectionLog.removeAll()
    }

    func connect(host: String, port: Int) {
        let p = UInt16(clamping: port)
        let type = KenwoodKNS.AccountType(rawValue: knsAccountType) ?? .administrator
        persistKnsSettings(host: host, port: port, accountType: type)
        currentHost = host
        lastError = nil
        connection.connect(host: host, port: p, useKnsLogin: useKnsLogin, accountType: type, adminId: adminId, adminPassword: adminPassword)
        connectionStatus = ConnectionStatus.connecting.rawValue
    }

    func disconnect() {
        stopLanAudio()
        connection.disconnect()
    }

    /// Reconnect using the last saved host and port (for keyboard shortcut use).
    func reconnect() {
        guard let host = KNSSettings.loadLastHost(), !host.isEmpty else { return }
        let port = KNSSettings.loadLastPort() ?? 60000
        loadSavedCredentials(host: host)
        connect(host: host, port: port)
    }

    /// Cycle through available NR backends in order.
    func cycleNoiseReductionBackend() {
        guard !availableNoiseReductionBackends.isEmpty else { return }
        let idx = availableNoiseReductionBackends.firstIndex(of: selectedNoiseReductionBackend) ?? -1
        let next = availableNoiseReductionBackends[(idx + 1) % availableNoiseReductionBackends.count]
        setNoiseReductionBackend(next)
        announceInfo("NR: \(next)")
    }

    func send(_ command: String) {
        // Don't surface admin credentials in the UI.
        lastTXFrame = command.hasPrefix("##ID") ? "##ID<redacted>;" : command
        connection.send(command)
    }

    func setNoiseReduction(enabled: Bool) {
        guard isNoiseReductionEnabled != enabled else { return }
        isNoiseReductionEnabled = enabled
        noiseProcessor.isEnabled = enabled
        AppFileLogger.shared.log("NR: enabled=\(enabled) backend=\(noiseReductionBackend) lanWetDry=\(String(format: "%.2f", lanAudioWetDry)) monitorWetDry=\(String(format: "%.2f", audioMonitorWetDry))")
        announceNoiseReductionChange(enabled: enabled)
    }

    func setNoiseReductionBackend(_ backendName: String) {
        selectedNoiseReductionBackend = backendName
        persistNoiseReductionSettings()
        switch backendName {
        case "WDSP EMNR":
            if let emnr = WDSPNoiseReductionProcessor(mode: .emnr) {
                noiseProcessor = emnr
                isNoiseReductionEnabled = emnr.isEnabled
                noiseReductionBackend = "WDSP EMNR"
                AppFileLogger.shared.log("NR backend switched to: WDSP EMNR")
            }
        case "WDSP ANR":
            if let anr = WDSPNoiseReductionProcessor(mode: .anr) {
                noiseProcessor = anr
                isNoiseReductionEnabled = anr.isEnabled
                noiseReductionBackend = "WDSP ANR"
                AppFileLogger.shared.log("NR backend switched to: WDSP ANR")
            }
        case "RNNoise (in-process)":
            if let rnnoise = RNNoiseProcessor() {
                noiseProcessor = rnnoise
                isNoiseReductionEnabled = rnnoise.isEnabled
                noiseReductionBackend = rnnoise.backendDescription
                AppFileLogger.shared.log("NR backend switched to: RNNoise (in-process)")
            }
        default: // "Passthrough (disabled)"
            noiseProcessor = PassthroughNoiseReduction()
            isNoiseReductionEnabled = false
            noiseReductionBackend = "Passthrough (disabled)"
            AppFileLogger.shared.log("NR backend switched to: Passthrough")
        }
    }

    var isNoiseReductionAvailable: Bool { noiseProcessor.isAvailable }


    func setNoiseReductionStrength(_ value: Double) {
        setNoiseReductionStrength(value, persist: true)
    }

    func setNoiseReductionProfile(rawValue: String) {
        noiseReductionProfileRaw = rawValue
        applyNoiseReductionProfile(persist: true)
    }

    func refreshAudioDevices() {
        audioInputDevices = AudioDeviceManager.inputDevices()
        audioOutputDevices = AudioDeviceManager.outputDevices()
        if !selectedAudioInputUID.isEmpty, AudioDeviceManager.deviceID(forUID: selectedAudioInputUID) == nil {
            selectedAudioInputUID = ""
        }
        if !selectedAudioOutputUID.isEmpty, AudioDeviceManager.deviceID(forUID: selectedAudioOutputUID) == nil {
            selectedAudioOutputUID = ""
        }
        if !selectedLanAudioOutputUID.isEmpty, AudioDeviceManager.deviceID(forUID: selectedLanAudioOutputUID) == nil {
            selectedLanAudioOutputUID = ""
        }
        if !selectedLanMicInputUID.isEmpty, AudioDeviceManager.deviceID(forUID: selectedLanMicInputUID) == nil {
            selectedLanMicInputUID = ""
        }

        if selectedAudioOutputUID.isEmpty {
            if let defaultID = AudioDeviceManager.defaultOutputDeviceID(),
               let match = audioOutputDevices.first(where: { $0.id == defaultID }) {
                selectedAudioOutputUID = match.uid
            } else if let first = audioOutputDevices.first {
                selectedAudioOutputUID = first.uid
            }
        }
        // Allow empty UID to mean "system default output".

        // Emit a concise device list to the file log for debugging VoiceOver selection issues.
        if !audioOutputDevices.isEmpty {
            let names = audioOutputDevices.prefix(10).map { "\($0.name) uid=\($0.uid)" }.joined(separator: " | ")
            AppFileLogger.shared.log("Audio outputs (first 10): \(names)")
        }
    }

    // MARK: - Top-5 Operating Features

    func queryTop5() {
        // VFO A (also pushed by AI, but query on connect for instant population).
        send(KenwoodCAT.getVFOAFrequency())
        // VFO B + split (FR/FT), RIT/XIT, RX filter, power, ATU.
        send(KenwoodCAT.getVFOBFrequency())
        send(KenwoodCAT.getReceiverVFO())
        send(KenwoodCAT.getTransmitterVFO())
        send(KenwoodCAT.ritGetState())
        send(KenwoodCAT.xitGetState())
        send(KenwoodCAT.ritXitGetOffset())
        send(KenwoodCAT.getReceiveFilterShift())
        send(KenwoodCAT.getReceiveFilterLowCutSettingID())
        send(KenwoodCAT.getReceiveFilterHighCutSettingID())
        send(KenwoodCAT.getOutputPower())
        send(KenwoodCAT.getAntennaTuner())
        send(KenwoodCAT.getSplitOffsetSettingState())
        // Memory mode/channel are useful for quick operation.
        send(KenwoodCAT.getMemoryMode())
        send(KenwoodCAT.getMemoryChannelNumber())
        // Mode, squelch, NR, notch — not pushed by AI mode.
        send(KenwoodCAT.getOperatingMode(.left))
        send(KenwoodCAT.getSquelchLevel())
        send(KenwoodCAT.getNoiseReduction())
        send(KenwoodCAT.getNotch())
    }

    func setVFOBFrequencyHz(_ hz: Int) {
        send(KenwoodCAT.setVFOBFrequencyHz(hz))
        send(KenwoodCAT.getVFOBFrequency())
    }

    func setSplitEnabled(_ enabled: Bool) {
        // Split means TX VFO differs from RX VFO.
        let rx = rxVFO ?? .a
        if enabled {
            let tx: KenwoodCAT.VFO = (rx == .a) ? .b : .a
            send(KenwoodCAT.setTransmitterVFO(tx))
            send(KenwoodCAT.getTransmitterVFO())
        } else {
            send(KenwoodCAT.setTransmitterVFO(rx))
            send(KenwoodCAT.getTransmitterVFO())
        }
    }

    func setReceiverVFO(_ vfo: KenwoodCAT.VFO) {
        send(KenwoodCAT.setReceiverVFO(vfo))
        send(KenwoodCAT.getReceiverVFO())
    }

    func setTransmitterVFO(_ vfo: KenwoodCAT.VFO) {
        send(KenwoodCAT.setTransmitterVFO(vfo))
        send(KenwoodCAT.getTransmitterVFO())
    }

    func setRITEnabled(_ enabled: Bool) {
        send(KenwoodCAT.ritSetEnabled(enabled))
        send(KenwoodCAT.ritGetState())
    }

    func setXITEnabled(_ enabled: Bool) {
        send(KenwoodCAT.xitSetEnabled(enabled))
        send(KenwoodCAT.xitGetState())
    }

    func clearRitXitOffset() {
        send(KenwoodCAT.ritXitClearOffset())
        send(KenwoodCAT.ritXitGetOffset())
    }

    func setRitXitOffsetHz(_ hz: Int) {
        send(KenwoodCAT.ritXitSetOffsetHz(hz))
        send(KenwoodCAT.ritXitGetOffset())
    }

    func stepRitXit(up: Bool) {
        send(up ? KenwoodCAT.ritXitStepUp() : KenwoodCAT.ritXitStepDown())
        send(KenwoodCAT.ritXitGetOffset())
    }

    func setReceiveFilterShiftHz(_ hz: Int) {
        send(KenwoodCAT.setReceiveFilterShiftHz(hz))
        send(KenwoodCAT.getReceiveFilterShift())
    }

    func setReceiveFilterLowCutID(_ id: Int) {
        send(KenwoodCAT.setReceiveFilterLowCutSettingID(id))
        send(KenwoodCAT.getReceiveFilterLowCutSettingID())
    }

    func setReceiveFilterHighCutID(_ id: Int) {
        send(KenwoodCAT.setReceiveFilterHighCutSettingID(id))
        send(KenwoodCAT.getReceiveFilterHighCutSettingID())
    }

    private func debounceCAT(key: String, delaySeconds: Double, _ block: @escaping () -> Void) {
        if let existing = debouncedCAT[key] {
            existing.cancel()
        }
        let work = DispatchWorkItem(block: block)
        debouncedCAT[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds, execute: work)
    }

    func setOutputPowerWatts(_ watts: Int) {
        send(KenwoodCAT.setOutputPowerWatts(watts))
        send(KenwoodCAT.getOutputPower())
    }

    func setOutputPowerWattsDebounced(_ watts: Int) {
        let clamped = max(5, min(watts, 100))
        outputPowerWatts = clamped
        debounceCAT(key: "tx_power", delaySeconds: 0.20) { [weak self] in
            guard let self else { return }
            self.send(KenwoodCAT.setOutputPowerWatts(clamped))
            self.send(KenwoodCAT.getOutputPower())
        }
    }

    func setATUTxEnabled(_ enabled: Bool) {
        send(KenwoodCAT.setAntennaTuner(txEnabled: enabled))
        send(KenwoodCAT.getAntennaTuner())
    }

    func setMemoryMode(enabled: Bool) {
        isMemoryMode = enabled
        send(KenwoodCAT.setMemoryMode(enabled))
        send(KenwoodCAT.getMemoryMode())
        send(KenwoodCAT.getMemoryChannelNumber())
    }

    func recallMemoryChannel(_ channel: Int) {
        let clamped = max(0, min(channel, 119))
        memoryChannelNumber = clamped
        send(KenwoodCAT.setMemoryChannelNumber(clamped))
        send(KenwoodCAT.getMemoryChannelNumber())
        send(KenwoodCAT.getMemoryChannelConfiguration(clamped))
    }

    func queryMemoryChannel(_ channel: Int) {
        let clamped = max(0, min(channel, 119))
        send(KenwoodCAT.getMemoryChannelConfiguration(clamped))
    }

    func programMemoryChannel(channel: Int, frequencyHz: Int, mode: KenwoodCAT.OperatingMode, fmNarrow: Bool, name: String) {
        let ch = max(0, min(channel, 119))
        let hz = max(0, min(frequencyHz, 99_999_999_999))
        memoryChannelNumber = ch
        AppFileLogger.shared.log("UI: Program memory ch=\(ch) hz=\(hz) mode=\(mode.rawValue) fmNarrow=\(fmNarrow) name=\(name)")

        // Select the channel, then write frequency/mode, then name (optional).
        send(KenwoodCAT.setMemoryChannelNumber(ch))
        send(KenwoodCAT.setMemoryChannelDirectWriteFrequencyHz(hz, mode: mode, fmNarrow: fmNarrow))

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            send(KenwoodCAT.setMemoryChannelName(ch, name: trimmedName))
        }

        // Read back for confirmation.
        send(KenwoodCAT.getMemoryChannelNumber())
        send(KenwoodCAT.getMemoryChannelConfiguration(ch))
    }

    // MARK: - Memory Browser — batch load all 120 channels

    func loadAllMemoryChannels() {
        guard !isLoadingAllMemories else { return }
        isLoadingAllMemories = true
        memoryChannels = []
        AppFileLogger.shared.log("Memory: loading all 120 channels")
        // Stagger requests by 50 ms to avoid flooding the radio's command queue.
        for ch in 0..<120 {
            let delay = Double(ch) * 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.send(KenwoodCAT.getMemoryChannelConfiguration(ch))
                if ch == 119 {
                    // Allow last response time to arrive before clearing the flag.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.isLoadingAllMemories = false
                    }
                }
            }
        }
    }

    func startATUTuning() {
        send(KenwoodCAT.startAntennaTuning())
        send(KenwoodCAT.getAntennaTuner())
    }

    func stopATUTuning() {
        let enabled = atuTxEnabled ?? false
        send(KenwoodCAT.stopAntennaTuning(txEnabled: enabled))
        send(KenwoodCAT.getAntennaTuner())
    }

    func setSplitOffset(plus: Bool, khz: Int) {
        splitOffsetPlus = plus
        splitOffsetKHz = khz
        send(KenwoodCAT.startSplitOffsetSetting())
        send(KenwoodCAT.setSplitOffset(plus: plus, khz: khz))
        send(KenwoodCAT.getSplitOffsetSettingState())
    }

    func startAudioMonitor() {
        audioMonitorError = nil
        guard !isAudioMonitorRunning else { return }
        guard let inputID = AudioDeviceManager.deviceID(forUID: selectedAudioInputUID) else {
            audioMonitorError = "Select an audio input device"
            return
        }
        let outputID: AudioDeviceID
        if let id = AudioDeviceManager.deviceID(forUID: selectedAudioOutputUID) {
            outputID = id
        } else if let id = AudioDeviceManager.defaultOutputDeviceID() {
            outputID = id
        } else {
            audioMonitorError = "No audio output device"
            return
        }

        let monitor = AudioMonitor(processor: processorProxy)
        monitor.wetDry = Float(audioMonitorWetDry)
        monitor.inputGain = Float(audioMonitorInputGain)
        monitor.outputGain = Float(audioMonitorOutputGain) * (isAudioMuted ? 0.0 : 1.0)
        monitor.onLog = { [weak self] msg in
            DispatchQueue.main.async {
                self?.audioMonitorLog.append(msg)
                if (self?.audioMonitorLog.count ?? 0) > 50 {
                    self?.audioMonitorLog.removeFirst((self?.audioMonitorLog.count ?? 0) - 50)
                }
            }
        }
        monitor.onError = { [weak self] msg in
            DispatchQueue.main.async {
                self?.audioMonitorError = msg
                self?.audioMonitorLog.append("Error: \(msg)")
            }
        }

        do {
            try monitor.start(inputDeviceID: inputID, outputDeviceID: outputID)
            audioMonitor = monitor
            isAudioMonitorRunning = true
        } catch {
            audioMonitorError = error.localizedDescription
            audioMonitor = nil
            isAudioMonitorRunning = false
        }
    }

    func stopAudioMonitor() {
        audioMonitor?.stop()
        audioMonitor = nil
        isAudioMonitorRunning = false
    }

    func setAudioMonitorWetDry(_ value: Double) {
        audioMonitorWetDry = value
        audioMonitor?.wetDry = Float(value)
    }

    func setAudioMonitorInputGain(_ value: Double) {
        audioMonitorInputGain = value
        audioMonitor?.inputGain = Float(value)
    }

    func setAudioMonitorOutputGain(_ value: Double) {
        audioMonitorOutputGain = value
        audioMonitor?.outputGain = Float(value) * (isAudioMuted ? 0.0 : 1.0)
    }

    func startLanAudio(host: String) {
        AppFileLogger.shared.log("LAN: startLanAudio host=\(host) isRunning=\(isLanAudioRunning)")
        lanAudioError = nil
        guard !isLanAudioRunning else {
            AppFileLogger.shared.log("LAN: startLanAudio skipped — already running")
            return
        }
        lanAudioPacketCountRaw = 0
        lanAudioLastPacketAtRaw = nil
        lanAudioPacketCount = 0
        lanAudioLastPacketAt = nil

        // Start output first, so we can surface any errors early.
        let player = AudioOutputPlayer(sampleRate: 48_000)
        player.gain = Float(lanAudioOutputGain) * (isAudioMuted ? 0.0 : 1.0)
        do {
            try player.start(outputDeviceID: AudioDeviceManager.deviceID(forUID: selectedLanAudioOutputUID))
        } catch {
            let msg = "LAN audio player failed: \(error.localizedDescription)"
            AppFileLogger.shared.log(msg)
            lanAudioError = error.localizedDescription
            announceError(msg)
            return
        }

        let pipeline = LanAudioPipeline(processor: processorProxy, frameSize: 480)
        pipeline.wetDry = Float(lanAudioWetDry)

        let receiver = KenwoodLanAudioReceiver()
        receiver.onError = { [weak self] msg in
            AppLogger.error("LAN audio error: \(msg)")
            AppFileLogger.shared.log("LAN audio error: \(msg)")
            DispatchQueue.main.async {
                self?.lanAudioError = msg
            }
        }
        receiver.onLog = { [weak self] msg in
            AppLogger.info("LAN: \(msg)")
            AppFileLogger.shared.log("LAN: \(msg)")
            DispatchQueue.main.async {
                self?.connectionLog.append("LAN: \(msg)")
                if (self?.connectionLog.count ?? 0) > 50 {
                    self?.connectionLog.removeFirst((self?.connectionLog.count ?? 0) - 50)
                }
            }
        }
        receiver.onPacket = { [weak self] seq, ssrc, payloadBytes in
            guard let self else { return }
            self.lanAudioPacketCountRaw &+= 1
            self.lanAudioLastPacketAtRaw = Date()

            // Updating @Published 50 times/sec can make SwiftUI + VoiceOver feel hung.
            // Publish only occasionally while keeping accurate internal counts.
            let n = self.lanAudioPacketCountRaw
            if n == 1 || (n % 25) == 0 {
                let lastAt = self.lanAudioLastPacketAtRaw
                DispatchQueue.main.async {
                    self.lanAudioPacketCount = n
                    self.lanAudioLastPacketAt = lastAt
                    if n == 1 {
                        self.connectionLog.append("LAN: first packet seq=\(seq) ssrc=\(String(format: "0x%08X", ssrc)) bytes=\(payloadBytes)")
                        AppLogger.info("LAN: first packet seq=\(seq) ssrc=\(String(format: "0x%08X", ssrc)) bytes=\(payloadBytes)")
                        AppFileLogger.shared.log("LAN: first packet seq=\(seq) ssrc=\(String(format: "0x%08X", ssrc)) bytes=\(payloadBytes)")
                    }
                }
            }
        }
        receiver.onAudio48kMono = { [weak self] samples in
            if let tap = self?.onLanRxAudio48kMono {
                // Copy the frame to decouple from any internal buffers.
                let frame = samples
                self?.lanRxTapQueue.async {
                    tap(frame)
                }
            }
            pipeline.process48kMono(samples) { outFrame in
                self?.lanPlayer?.enqueue48kMono(outFrame)
            }
        }

        do {
            try receiver.start(host: host, port: 60001)
        } catch {
            player.stop()
            let msg = "LAN audio receiver failed: \(error.localizedDescription)"
            AppFileLogger.shared.log(msg)
            lanAudioError = error.localizedDescription
            announceError(msg)
            return
        }

        lanPlayer = player
        lanPipeline = pipeline
        lanReceiver = receiver
        isLanAudioRunning = true

        AppFileLogger.shared.log("LAN: output device uid=\(selectedLanAudioOutputUID.isEmpty ? "(default)" : selectedLanAudioOutputUID)")

        // Kenwood KNS VoIP: explicitly start voice communication; otherwise the radio may not emit UDP 60001.
        // P1: 0=Stop, 1=Start (high quality), 2=Start (low quality). (TS-890 PC command guide: ##VP)
        if useKnsLogin {
            connection.send("##VP1;")
        }
    }

    func stopLanAudio() {
        if useKnsLogin {
            // Tell the radio to stop its VoIP UDP stream. This runs before connection.disconnect()
            // in the explicit-disconnect path, so the NWConnection is still open.
            connection.send("##VP0;")
        }
        stopMicCapture()
        // Final publish snapshot (useful if UI throttling skipped the last updates).
        lanAudioPacketCount = lanAudioPacketCountRaw
        lanAudioLastPacketAt = lanAudioLastPacketAtRaw
        lanReceiver?.stop()
        lanReceiver = nil
        lanPipeline = nil
        lanPlayer?.stop()
        lanPlayer = nil
        isLanAudioRunning = false
    }

    func setLanAudioWetDry(_ value: Double) {
        lanAudioWetDry = value
        lanPipeline?.wetDry = Float(value)
    }

    func setLanAudioOutputGain(_ value: Double) {
        lanAudioOutputGain = value
        lanPlayer?.gain = Float(value) * (isAudioMuted ? 0.0 : 1.0)
    }

    func applyLanAudioOutputSelection() {
        // Explicit entrypoint for the View (helps debug when Combine observation is unreliable).
        AppFileLogger.shared.log("LAN: apply output selection uid=\(selectedLanAudioOutputUID.isEmpty ? "(default)" : selectedLanAudioOutputUID)")
        switchLanAudioOutputIfRunning()
    }

    private func switchLanAudioOutputIfRunning() {
        AppFileLogger.shared.log("LAN: switch output requested running=\(isLanAudioRunning) uid=\(selectedLanAudioOutputUID.isEmpty ? "(default)" : selectedLanAudioOutputUID)")
        guard isLanAudioRunning else { return }
        guard let player = lanPlayer else { return }
        let id = AudioDeviceManager.deviceID(forUID: selectedLanAudioOutputUID)
        AppFileLogger.shared.log("LAN: switch output deviceID=\(id ?? 0)")

        // Restart player to apply new output device. Keep receiver/pipeline running.
        player.stop()
        do {
            try player.start(outputDeviceID: id)
            player.gain = Float(lanAudioOutputGain) * (isAudioMuted ? 0.0 : 1.0)
            AppFileLogger.shared.log("LAN: switched output device uid=\(selectedLanAudioOutputUID.isEmpty ? "(default)" : selectedLanAudioOutputUID)")
        } catch {
            lanAudioError = error.localizedDescription
            AppFileLogger.shared.log("LAN: switch output failed: \(error.localizedDescription)")
        }
    }

    private func setNoiseReductionStrength(_ value: Double, persist: Bool) {
        let clamped = max(0.0, min(1.0, value))
        noiseReductionStrength = clamped
        // Drive both pipelines from one "strength" knob. Wet/dry mix is a stable,
        // artifact-safe way to tune aggressiveness without changing the RNNoise model.
        setLanAudioWetDry(clamped)
        setAudioMonitorWetDry(clamped)
        if persist { persistNoiseReductionSettings() }
        AppFileLogger.shared.log("NR: strength=\(String(format: "%.2f", clamped)) profile=\(noiseReductionProfileRaw)")
    }

    private func applyNoiseReductionProfile(persist: Bool) {
        let profile = NoiseReductionProfile(rawValue: noiseReductionProfileRaw) ?? .speech
        // Profile sets a good starting point; user can fine-tune with the strength slider.
        setNoiseReductionStrength(profile.recommendedStrength, persist: false)
        if persist { persistNoiseReductionSettings() }
        AppFileLogger.shared.log("NR: profile=\(profile.rawValue) recommendedStrength=\(String(format: "%.2f", profile.recommendedStrength))")
    }

    private func loadPersistedNoiseReductionSettings() {
        let d = UserDefaults.standard
        if d.object(forKey: nrStrengthKey) != nil {
            noiseReductionStrength = d.double(forKey: nrStrengthKey)
        }
        if let raw = d.string(forKey: nrProfileKey), !raw.isEmpty {
            noiseReductionProfileRaw = raw
        }
        // Restore last-used backend — but never restore Passthrough as the default;
        // if no backend was saved or the saved one isn't valid, keep the auto-selected one.
        if let saved = d.string(forKey: nrBackendKey),
           !saved.isEmpty,
           saved != "Passthrough (disabled)",
           availableNoiseReductionBackends.contains(saved) {
            setNoiseReductionBackend(saved)
        }
        AppFileLogger.shared.log("Loaded saved NR settings strength=\(String(format: "%.2f", noiseReductionStrength)) profile=\(noiseReductionProfileRaw) backend=\(noiseReductionBackend)")
    }

    private func persistNoiseReductionSettings() {
        let d = UserDefaults.standard
        d.set(noiseReductionStrength, forKey: nrStrengthKey)
        d.set(noiseReductionProfileRaw, forKey: nrProfileKey)
        d.set(selectedNoiseReductionBackend, forKey: nrBackendKey)
    }

    func runSmokeTest() {
        smokeTestStatus = "Running"
        announceInfo("Smoke test started")
        lastTXFrame = "SMOKE: TX"
        lastRXFrame = "SMOKE: RX"
        smokeTestStatus = "Complete"
        announceInfo("Smoke test complete")
    }

    func loadSavedCredentials(host: String) {
        let typeRaw = knsAccountType
        if let u = KNSSettings.loadUsername(host: host, accountTypeRaw: typeRaw) {
            adminId = u
            if let p = KNSSettings.loadPassword(host: host, accountTypeRaw: typeRaw, username: u) {
                adminPassword = p
            } else {
                adminPassword = ""
            }
            knsCredentialCache["\(typeRaw)|\(host)"] = (u, adminPassword)
            AppFileLogger.shared.log("Loaded saved credentials for host \(host) type \(typeRaw)")
        } else {
            adminId = ""
            adminPassword = ""
        }
    }

    private func handleFrame(_ frame: String) {
        let cleaned = frame.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        let core = cleaned.hasSuffix(";") ? String(cleaned.dropLast()) : cleaned

        if core.hasPrefix("FA") {
            let digits = core.dropFirst(2).prefix { $0.isNumber }
            if let hz = Int(digits) { vfoAFrequencyHz = hz }
            return
        }

        if core.hasPrefix("FB") {
            let digits = core.dropFirst(2).prefix { $0.isNumber }
            if let hz = Int(digits) { vfoBFrequencyHz = hz }
            return
        }

        if core.hasPrefix("OM"), core.count >= 4 {
            // Format: OM + P1 + P2
            let params = core.dropFirst(2)
            let modeDigit = params.dropFirst().prefix(1)
            if let raw = Int(modeDigit), let mode = KenwoodCAT.OperatingMode(rawValue: raw) {
                operatingMode = mode
            }
            return
        }

        if core.hasPrefix("MD") {
            let digits = core.dropFirst(2).prefix { $0.isNumber }
            if let v = Int(digits) { mdMode = v }
            return
        }

        if core.hasPrefix("DA"), core.count >= 3 {
            // DA + P1 (0/1). Some rigs may respond with `?;` instead.
            let p1 = core.dropFirst(2).prefix(1)
            if let raw = Int(p1) {
                dataModeEnabled = (raw == 1)
            }
            return
        }

        if core.hasPrefix("FR") {
            let p1 = core.dropFirst(2).prefix(1)
            if let raw = Int(p1), let vfo = KenwoodCAT.VFO(rawValue: raw) {
                rxVFO = vfo
            }
            return
        }

        if core.hasPrefix("FT") {
            let p1 = core.dropFirst(2).prefix(1)
            if let raw = Int(p1), let vfo = KenwoodCAT.VFO(rawValue: raw) {
                txVFO = vfo
            }
            return
        }

        if core.hasPrefix("NR") {
            let p1 = core.dropFirst(2).prefix(1)
            if let raw = Int(p1), let mode = KenwoodCAT.NoiseReductionMode(rawValue: raw) {
                transceiverNRMode = mode
            }
            return
        }

        if core.hasPrefix("RT") {
            let p1 = core.dropFirst(2).prefix(1)
            if let raw = Int(p1) {
                ritEnabled = (raw == 1)
            }
            return
        }

        if core.hasPrefix("XT") {
            let p1 = core.dropFirst(2).prefix(1)
            if let raw = Int(p1) {
                xitEnabled = (raw == 1)
            }
            return
        }

        if core.hasPrefix("RF"), core.count >= 7 {
            // RF + P1(direction 0/1) + P2P2P2P2 (Hz)
            let params = core.dropFirst(2)
            let dirChar = params.prefix(1)
            let hzDigits = params.dropFirst(1).prefix(4)
            if let dir = Int(dirChar), let hz = Int(hzDigits) {
                ritXitOffsetHz = (dir == 1) ? -hz : hz
            }
            return
        }

        if core.hasPrefix("IS"), core.count >= 7 {
            // IS + sign (+/-/space) + 4 digits
            let params = core.dropFirst(2)
            let signChar = params.prefix(1)
            let hzDigits = params.dropFirst(1).prefix(4)
            if let hz = Int(hzDigits) {
                let sign = (signChar == "-") ? -1 : 1
                rxFilterShiftHz = hz * sign
            }
            return
        }

        if core.hasPrefix("SL"), core.count >= 5 {
            // SL + P1(type) + P2P2
            let params = core.dropFirst(2)
            let typeChar = params.prefix(1)
            let idDigits = params.dropFirst(1).prefix(2)
            if typeChar == "0", let id = Int(idDigits) {
                rxFilterLowCutID = id
            }
            return
        }

        if core.hasPrefix("SH"), core.count >= 6 {
            // SH + P1(type) + P2P2P2
            let params = core.dropFirst(2)
            let typeChar = params.prefix(1)
            let idDigits = params.dropFirst(1).prefix(3)
            if typeChar == "0", let id = Int(idDigits) {
                rxFilterHighCutID = id
            }
            return
        }

        if core.hasPrefix("PC") {
            let digits = core.dropFirst(2).prefix { $0.isNumber }
            if let w = Int(digits) { outputPowerWatts = w }
            return
        }

        if core.hasPrefix("MV") {
            // MV P1 ;; (0 = VFO, 1 = Memory Channel)
            let p1 = core.dropFirst(2).prefix(1)
            if let raw = Int(p1) {
                isMemoryMode = (raw == 1)
            }
            return
        }

        if core.hasPrefix("MN") {
            let digits = core.dropFirst(2).prefix { $0.isNumber }
            if let ch = Int(digits) {
                memoryChannelNumber = ch
            }
            return
        }

        if core.hasPrefix("MA0"), core.count >= 7 {
            // MA0 + channel(3) + freq(11) + mode(1) + ... + name(<=10)
            let params = core.dropFirst(3)
            let chStr = String(params.prefix(3)).trimmingCharacters(in: .whitespaces)
            let rest = params.dropFirst(3)
            if let ch = Int(chStr) {
                // Only overwrite details when the MA0 response matches the selected channel.
                if memoryChannelNumber == nil || memoryChannelNumber == ch {
                    memoryChannelNumber = ch

                    let freqField = String(rest.prefix(11))
                    let freqDigits = freqField.filter(\.isNumber)
                    if !freqDigits.isEmpty, let hz = Int(freqDigits) {
                        memoryChannelFrequencyHz = hz
                    } else {
                        memoryChannelFrequencyHz = nil
                    }

                    let modeField = String(rest.dropFirst(11).prefix(1))
                    if let raw = Int(modeField), let mode = KenwoodCAT.OperatingMode(rawValue: raw) {
                        memoryChannelMode = mode
                    } else {
                        memoryChannelMode = nil
                    }

                    let name = String(core.suffix(10)).trimmingCharacters(in: .whitespaces)
                    memoryChannelName = name.isEmpty ? nil : name

                    // Also populate the MemoryBrowserView array regardless of selected channel.
                    let hz = memoryChannelFrequencyHz ?? 0
                    let mode = memoryChannelMode ?? .usb
                    let isEmpty = (hz == 0)
                    let entry = MemoryChannel(id: ch, frequencyHz: hz, mode: mode, name: name, isEmpty: isEmpty)
                    if let idx = memoryChannels.firstIndex(where: { $0.id == ch }) {
                        memoryChannels[idx] = entry
                    } else {
                        // Insert in order
                        let insertIdx = memoryChannels.firstIndex(where: { $0.id > ch }) ?? memoryChannels.endIndex
                        memoryChannels.insert(entry, at: insertIdx)
                    }
                }
            }
            return
        }

        if core.hasPrefix("AC"), core.count >= 5 {
            // AC + P1(rx) + P2(tx) + P3(tune active)
            let params = core.dropFirst(2)
            let p1 = params.prefix(1)
            let p2 = params.dropFirst(1).prefix(1)
            let p3 = params.dropFirst(2).prefix(1)
            if let txRaw = Int(p2) { atuTxEnabled = (txRaw == 1) }
            if let tuneRaw = Int(p3) { atuTuningActive = (tuneRaw == 1) }
            // We don't surface rx AT yet; docs say use EX to set it.
            _ = p1
            return
        }

        if core.hasPrefix("SP") {
            // Answer is SP + P1 (0/1). Setting details are not echoed.
            let p1 = core.dropFirst(2).prefix(1)
            if let raw = Int(p1) {
                splitOffsetSettingActive = (raw == 1)
            }
            return
        }

        if core.hasPrefix("##KN3"), core.count >= 7 {
            // ##KN3 + P1(type) + P2P2P2(level)
            let params = core.dropFirst(5)
            let typeChar = params.prefix(1)
            let levelDigits = params.dropFirst(1).prefix(3)
            if let type = Int(typeChar), let level = Int(levelDigits) {
                if type == 0 { voipInputLevel = level }
                if type == 1 { voipOutputLevel = level }
            }
            return
        }

        if core.hasPrefix("AG") {
            let digits = core.dropFirst(2).prefix { $0.isNumber }
            if let v = Int(digits) { afGain = v }
            return
        }

        if core.hasPrefix("RG") {
            let digits = core.dropFirst(2).prefix { $0.isNumber }
            if let v = Int(digits) { rfGain = v }
            return
        }

        if core.hasPrefix("NT") {
            let p1 = core.dropFirst(2).prefix(1)
            if let raw = Int(p1) {
                isNotchEnabled = (raw == 1)
            }
            return
        }

        if core.hasPrefix("SQ") {
            let digits = core.dropFirst(2).prefix { $0.isNumber }
            if let v = Int(digits) { squelchLevel = v }
            return
        }

        if core.hasPrefix("SM") {
            let digits = core.dropFirst(2).prefix { $0.isNumber }
            if let v = Int(digits) { sMeterDots = v }
            return
        }

        if core.hasPrefix("EX"), core.count >= 6 {
            // EX + 3-digit menu number + value (signed or unsigned)
            let menuStr = String(core.dropFirst(2).prefix(3))
            guard let menuNum = Int(menuStr) else { return }
            let valueStr = String(core.dropFirst(5))
            let value: Int
            if valueStr.hasPrefix("+") {
                value = Int(valueStr.dropFirst()) ?? 0
            } else if valueStr.hasPrefix("-") {
                value = -(Int(valueStr.dropFirst()) ?? 0)
            } else {
                value = Int(valueStr) ?? 0
            }
            // Store in general map (used by RadioMenuView)
            exMenuValues[menuNum] = value
            // Dispatch to typed EQ properties
            switch menuNum {
            case 30: txEQLowGain = value
            case 31: txEQMidGain = value
            case 32: txEQHighGain = value
            case 60: rxEQLowGain = value
            case 61: rxEQMidGain = value
            case 62: rxEQHighGain = value
            default: break
            }
            return
        }

        if core == "RX" {
            isTransmitting = false
            isPTTDown = false
            return
        }

        if core.hasPrefix("TX") {
            isTransmitting = true
            isPTTDown = true
            return
        }
    }

    func setPTT(down: Bool) {
        setPTT(down: down, useMicAudio: true)
    }

    func setPTT(down: Bool, useMicAudio: Bool) {
        // Log synchronously: PTT debugging is high-value and these calls are infrequent.
        let hostLabel = currentHost.isEmpty ? "(empty)" : currentHost
        AppFileLogger.shared.logSync("PTT: request down=\(down) useMicAudio=\(useMicAudio) isPTTDown=\(isPTTDown) host=\(hostLabel) status=\(connectionStatus)")

        guard down != isPTTDown else {
            AppFileLogger.shared.logSync("PTT: ignored (already in requested state)")
            return
        }
        guard !currentHost.isEmpty else {
            AppFileLogger.shared.logSync("PTT: blocked (no host set)")
            announceError("No radio host set")
            return
        }

        if down {
            AppFileLogger.shared.logSync("UI: PTT down")
            // Ensure VoIP is started before attempting LAN mic streaming.
            if useKnsLogin {
                connection.send("##VP1;")
                // If we haven't observed the input level yet, assume a sane default so TX isn't silent.
                if voipInputLevel == nil {
                    send(KenwoodCAT.setVoipInputLevel(50))
                    send(KenwoodCAT.getVoipInputLevel())
                }
            }
            if autoStartLanAudio, !isLanAudioRunning {
                startLanAudio(host: currentHost)
            }
            if useMicAudio {
                micTxSource = .mic
                startMicCapture()
            } else {
                micTxSource = .generated
                stopMicCapture()
                // Ensure the paced sender exists so generated frames can be delivered.
                guard let receiver = lanReceiver else {
                    announceError("LAN audio receiver is not running")
                    return
                }
                micSendQueue.sync { micTxFrames.removeAll(keepingCapacity: true) }
                startMicTxTimerIfNeeded(receiver: receiver)
            }
            AppFileLogger.shared.logSync("PTT: sending TX0;")
            send(KenwoodCAT.pttDown())
            isPTTDown = true
            announceInfo("PTT down")
        } else {
            AppFileLogger.shared.logSync("UI: PTT up")
            generatedTxState = nil
            stopMicCapture()
            AppFileLogger.shared.logSync("PTT: sending RX;")
            send(KenwoodCAT.pttUp())
            isPTTDown = false
            announceInfo("PTT up")
        }
    }

    // Generated audio TX: used by digital modes like FT8. This does not use the selected microphone.
    // Current implementation sends a test tone; FT8 waveform generation will be added later.
    func transmitGeneratedTestTone(toneHz: Double, durationSeconds: Double, amplitude: Double = 0.2) {
        guard !isPTTDown else {
            AppFileLogger.shared.log("FT8: transmitGeneratedTestTone ignored (already TX)")
            return
        }
        guard durationSeconds > 0.1 else { return }
        guard toneHz > 10 else { return }

        // Ensure we're ready to send generated audio frames.
        setPTT(down: true, useMicAudio: false)

        // Timer sends 20ms frames (320 @ 16k). Convert duration to frames.
        let frames = max(1, Int((durationSeconds / 0.02).rounded()))
        generatedTxState = GeneratedTxState(framesRemaining: frames, phase: 0.0, frequencyHz: toneHz, amplitude: max(0.0, min(1.0, amplitude)))
        AppFileLogger.shared.log("FT8: generated test tone hz=\(toneHz) dur=\(String(format: "%.2f", durationSeconds))s frames=\(frames)")

        DispatchQueue.main.asyncAfter(deadline: .now() + durationSeconds) { [weak self] in
            guard let self else { return }
            if self.isPTTDown {
                self.setPTT(down: false, useMicAudio: false)
            }
        }
    }

    func setVoipOutputLevel(_ level: Int) {
        let clamped = max(0, min(level, 100))
        voipOutputLevel = clamped
        send(KenwoodCAT.setVoipOutputLevel(clamped))
        send(KenwoodCAT.getVoipOutputLevel())
    }

    func setVoipOutputLevelDebounced(_ level: Int) {
        let clamped = max(0, min(level, 100))
        voipOutputLevel = clamped
        debounceCAT(key: "voip_out", delaySeconds: 0.15) { [weak self] in
            guard let self else { return }
            self.send(KenwoodCAT.setVoipOutputLevel(clamped))
            self.send(KenwoodCAT.getVoipOutputLevel())
        }
    }

    func setVoipInputLevel(_ level: Int) {
        let clamped = max(0, min(level, 100))
        voipInputLevel = clamped
        send(KenwoodCAT.setVoipInputLevel(clamped))
        send(KenwoodCAT.getVoipInputLevel())
    }

    func setVoipInputLevelDebounced(_ level: Int) {
        let clamped = max(0, min(level, 100))
        voipInputLevel = clamped
        debounceCAT(key: "voip_in", delaySeconds: 0.15) { [weak self] in
            guard let self else { return }
            self.send(KenwoodCAT.setVoipInputLevel(clamped))
            self.send(KenwoodCAT.getVoipInputLevel())
        }
    }

    func setRFGainDebounced(_ value: Int) {
        let clamped = max(0, min(value, 255))
        rfGain = clamped
        debounceCAT(key: "rf_gain", delaySeconds: 0.15) { [weak self] in
            guard let self else { return }
            self.send(KenwoodCAT.setRFGain(clamped))
            self.send(KenwoodCAT.getRFGain())
        }
    }

    func setAFGainDebounced(_ value: Int) {
        let clamped = max(0, min(value, 255))
        afGain = clamped
        debounceCAT(key: "af_gain", delaySeconds: 0.15) { [weak self] in
            guard let self else { return }
            self.send(KenwoodCAT.setAFGain(clamped))
            self.send(KenwoodCAT.getAFGain())
        }
    }

    func setSquelchLevelDebounced(_ value: Int) {
        let clamped = max(0, min(value, 255))
        squelchLevel = clamped
        debounceCAT(key: "squelch", delaySeconds: 0.15) { [weak self] in
            guard let self else { return }
            self.send(KenwoodCAT.setSquelchLevel(clamped))
            self.send(KenwoodCAT.getSquelchLevel())
        }
    }

    func setReceiveFilterLowCutIDDebounced(_ id: Int) {
        let clamped = max(0, min(id, 35))
        rxFilterLowCutID = clamped
        debounceCAT(key: "rx_low_cut", delaySeconds: 0.15) { [weak self] in
            guard let self else { return }
            self.send(KenwoodCAT.setReceiveFilterLowCutSettingID(clamped))
            self.send(KenwoodCAT.getReceiveFilterLowCutSettingID())
        }
    }

    func setReceiveFilterHighCutIDDebounced(_ id: Int) {
        let clamped = max(0, min(id, 27))
        rxFilterHighCutID = clamped
        debounceCAT(key: "rx_high_cut", delaySeconds: 0.15) { [weak self] in
            guard let self else { return }
            self.send(KenwoodCAT.setReceiveFilterHighCutSettingID(clamped))
            self.send(KenwoodCAT.getReceiveFilterHighCutSettingID())
        }
    }

    func setReceiveFilterShiftHzDebounced(_ hz: Int) {
        let clamped = max(-9999, min(hz, 9999))
        rxFilterShiftHz = clamped
        debounceCAT(key: "rx_shift", delaySeconds: 0.15) { [weak self] in
            guard let self else { return }
            self.send(KenwoodCAT.setReceiveFilterShiftHz(clamped))
            self.send(KenwoodCAT.getReceiveFilterShift())
        }
    }

    func setRitXitOffsetHzDebounced(_ hz: Int) {
        let clamped = max(-9999, min(hz, 9999))
        ritXitOffsetHz = clamped
        debounceCAT(key: "rit_xit_offset", delaySeconds: 0.15) { [weak self] in
            guard let self else { return }
            self.send(KenwoodCAT.ritXitSetOffsetHz(clamped))
            self.send(KenwoodCAT.ritXitGetOffset())
        }
    }

    // MARK: - EQ debounced setters

    func queryAllEQ() {
        send(KenwoodCAT.getTXEQLow())
        send(KenwoodCAT.getTXEQMid())
        send(KenwoodCAT.getTXEQHigh())
        send(KenwoodCAT.getRXEQLow())
        send(KenwoodCAT.getRXEQMid())
        send(KenwoodCAT.getRXEQHigh())
    }

    func setTXEQLowDebounced(_ dB: Int) {
        let v = max(-20, min(dB, 10))
        txEQLowGain = v
        debounceCAT(key: "tx_eq_low", delaySeconds: 0.20) { [weak self] in
            guard let self else { return }
            self.send(KenwoodCAT.setTXEQLow(v))
            self.send(KenwoodCAT.getTXEQLow())
        }
    }

    func setTXEQMidDebounced(_ dB: Int) {
        let v = max(-20, min(dB, 10))
        txEQMidGain = v
        debounceCAT(key: "tx_eq_mid", delaySeconds: 0.20) { [weak self] in
            guard let self else { return }
            self.send(KenwoodCAT.setTXEQMid(v))
            self.send(KenwoodCAT.getTXEQMid())
        }
    }

    func setTXEQHighDebounced(_ dB: Int) {
        let v = max(-20, min(dB, 10))
        txEQHighGain = v
        debounceCAT(key: "tx_eq_high", delaySeconds: 0.20) { [weak self] in
            guard let self else { return }
            self.send(KenwoodCAT.setTXEQHigh(v))
            self.send(KenwoodCAT.getTXEQHigh())
        }
    }

    func setRXEQLowDebounced(_ dB: Int) {
        let v = max(-20, min(dB, 10))
        rxEQLowGain = v
        debounceCAT(key: "rx_eq_low", delaySeconds: 0.20) { [weak self] in
            guard let self else { return }
            self.send(KenwoodCAT.setRXEQLow(v))
            self.send(KenwoodCAT.getRXEQLow())
        }
    }

    func setRXEQMidDebounced(_ dB: Int) {
        let v = max(-20, min(dB, 10))
        rxEQMidGain = v
        debounceCAT(key: "rx_eq_mid", delaySeconds: 0.20) { [weak self] in
            guard let self else { return }
            self.send(KenwoodCAT.setRXEQMid(v))
            self.send(KenwoodCAT.getRXEQMid())
        }
    }

    func setRXEQHighDebounced(_ dB: Int) {
        let v = max(-20, min(dB, 10))
        rxEQHighGain = v
        debounceCAT(key: "rx_eq_high", delaySeconds: 0.20) { [weak self] in
            guard let self else { return }
            self.send(KenwoodCAT.setRXEQHigh(v))
            self.send(KenwoodCAT.getRXEQHigh())
        }
    }

    // MARK: - General EX menu read/write

    func readMenuValue(_ menuNumber: Int) {
        send(KenwoodCAT.getMenuValue(menuNumber))
    }

    func writeMenuValue(_ menuNumber: Int, value: Int) {
        send(KenwoodCAT.setMenuValue(menuNumber, value: value))
        send(KenwoodCAT.getMenuValue(menuNumber))
    }

    private func startMicCapture() {
        guard micCapture == nil else { return }
        guard let receiver = lanReceiver else {
            announceError("LAN audio receiver is not running")
            return
        }

        // Reset paced TX queue.
        micSendQueue.sync {
            micTxFrames.removeAll(keepingCapacity: true)
        }
        startMicTxTimerIfNeeded(receiver: receiver)

        let cap = KenwoodLanMicCapture()
        cap.onLog = { msg in
            AppLogger.info(msg)
            AppFileLogger.shared.log(msg)
        }
        cap.onError = { msg in
            AppLogger.error(msg)
            AppFileLogger.shared.log("LAN mic error: \(msg)")
        }
        cap.onFrame320 = { [weak self, weak receiver] ptr in
            guard let self else { return }
            // If we're in generated-TX mode, ignore microphone frames.
            guard self.micTxSource == .mic else { return }
            // Keep the audio callback lightweight: copy and send on a separate queue.
            var frame = [Int16](repeating: 0, count: 320)
            frame.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.assign(from: ptr, count: 320)
            }

            // Lightweight mic level indicator for debugging "keys but no modulation".
            // Log about once per second (50 frames @ 20ms).
            if self.micFrameLogCountdown <= 0 {
                var peak: Int16 = 0
                for s in frame {
                    let a = s == Int16.min ? Int16.max : abs(s)
                    if a > peak { peak = a }
                }
                AppFileLogger.shared.log("LAN mic: peak=\(peak)")
                self.micFrameLogCountdown = 50
            } else {
                self.micFrameLogCountdown -= 1
            }

            // Don't burst-send multiple frames back-to-back; queue and let the paced timer send at 20ms cadence.
            self.micSendQueue.async {
                self.micTxFrames.append(frame)
                // Bound latency: keep ~120ms max queued.
                if self.micTxFrames.count > 6 {
                    self.micTxFrames.removeFirst(self.micTxFrames.count - 6)
                }
            }
        }

        do {
            let inputID: AudioDeviceID? = {
                if !selectedLanMicInputUID.isEmpty {
                    return AudioDeviceManager.deviceID(forUID: selectedLanMicInputUID)
                }
                return AudioDeviceManager.defaultInputDeviceID()
            }()
            guard let inputID else {
                throw NSError(domain: "KenwoodLanMicCapture", code: -1, userInfo: [NSLocalizedDescriptionKey: "No microphone input device available"])
            }
            if let info = audioInputDevices.first(where: { $0.id == inputID }) {
                AppFileLogger.shared.log("LAN mic: input device \(info.name) uid=\(info.uid)")
            } else {
                AppFileLogger.shared.log("LAN mic: input deviceID=\(inputID)")
            }
            try cap.start(deviceID: inputID)
            micCapture = cap
        } catch {
            AppFileLogger.shared.log("LAN mic start failed: \(error.localizedDescription)")
            announceError("LAN mic failed: \(error.localizedDescription)")
            micCapture = nil
        }
    }

    private func stopMicCapture() {
        micCapture?.stop()
        micCapture = nil
        stopMicTxTimer()
        micSendQueue.async { [weak self] in
            self?.micTxFrames.removeAll(keepingCapacity: true)
        }
    }

    private func startMicTxTimerIfNeeded(receiver: KenwoodLanAudioReceiver) {
        guard micTxTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: micSendQueue)
        timer.schedule(deadline: .now() + 0.02, repeating: 0.02, leeway: .milliseconds(2))
        let silence = [Int16](repeating: 0, count: 320)
        timer.setEventHandler { [weak self, weak receiver] in
            guard let self, let receiver else { return }
            guard self.isPTTDown else { return }
            let frame: [Int16]
            switch self.micTxSource {
            case .mic:
                if !self.micTxFrames.isEmpty {
                    frame = self.micTxFrames.removeFirst()
                } else {
                    frame = silence
                }
            case .generated:
                if var st = self.generatedTxState, st.framesRemaining > 0 {
                    var out = [Int16](repeating: 0, count: 320)
                    let sampleRate = 16_000.0
                    let step = 2.0 * Double.pi * st.frequencyHz / sampleRate
                    for i in 0..<320 {
                        let v = sin(st.phase) * st.amplitude
                        let s = Int16(max(-32767.0, min(32767.0, v * 32767.0)))
                        out[i] = s
                        st.phase += step
                        if st.phase > 2.0 * Double.pi { st.phase -= 2.0 * Double.pi }
                    }
                    st.framesRemaining -= 1
                    self.generatedTxState = st
                    frame = out
                } else {
                    frame = silence
                }
            }
            frame.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                receiver.sendMicFramePCM16(base, count: 320)
            }
        }
        micTxTimer = timer
        timer.resume()
    }

    private func stopMicTxTimer() {
        micTxTimer?.cancel()
        micTxTimer = nil
    }

    private func shouldPublishLastRXFrame(_ frame: String) -> Bool {
        let cleaned = frame.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        let core = cleaned.hasSuffix(";") ? String(cleaned.dropLast()) : cleaned
        if core.hasPrefix("SM") {
            let now = Date()
            if now.timeIntervalSince(lastRXFrameSMAt) < 0.5 { return false }
            lastRXFrameSMAt = now
            return true
        }
        return true
    }

    private func loadPersistedKnsSettings() {
        if let useLogin = KNSSettings.loadUseLogin() {
            useKnsLogin = useLogin
        }
        if let t = KNSSettings.loadAccountTypeRaw() {
            knsAccountType = t
        }
        // Pre-fill credentials for the last host (ContentView also uses this for its initial Host field).
        if let host = KNSSettings.loadLastHost() {
            loadSavedCredentials(host: host)
        }
    }

    private func persistKnsSettings(host: String, port: Int, accountType: KenwoodKNS.AccountType) {
        KNSSettings.saveLastConnection(host: host, port: port)
        KNSSettings.saveUseLogin(useKnsLogin)
        KNSSettings.saveAccountTypeRaw(accountType.rawValue)

        // Save credentials for this host/account type. ID is not secret; password goes in Keychain.
        let username = adminId
        let password = adminPassword
        let cacheKey = "\(accountType.rawValue)|\(host)"
        if let cached = knsCredentialCache[cacheKey],
           cached.username == username,
           cached.password == password {
            // Avoid unnecessary keychain updates, which can trigger repeated macOS keychain prompts.
            return
        }
        if !username.isEmpty {
            KNSSettings.saveUsername(username, host: host, accountTypeRaw: accountType.rawValue)
            if !password.isEmpty {
                KNSSettings.savePassword(password, host: host, accountTypeRaw: accountType.rawValue, username: username)
            }
        }
        knsCredentialCache[cacheKey] = (username, password)
    }

    private func announceNoiseReductionChange(enabled: Bool) {
        #if canImport(AppKit)
        let message: String
        if !noiseProcessor.isAvailable {
            message = "Noise reduction unavailable"
        } else {
            message = enabled ? "Noise reduction enabled" : "Noise reduction disabled"
        }
        DispatchQueue.main.async {
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    NSAccessibility.NotificationUserInfoKey.announcement: message,
                    NSAccessibility.NotificationUserInfoKey.priority: NSAccessibilityPriorityLevel.high
                ]
            )
        }
        #endif
    }

    private func announceConnectionStatus(_ status: ConnectionStatus) {
        #if canImport(AppKit)
        let message: String
        switch status {
        case .connected: message = "Radio connected"
        case .connecting: message = "Radio connecting"
        case .authenticating: message = "Radio authenticating"
        case .disconnected: message = "Radio disconnected"
        }
        DispatchQueue.main.async {
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    NSAccessibility.NotificationUserInfoKey.announcement: message,
                    NSAccessibility.NotificationUserInfoKey.priority: NSAccessibilityPriorityLevel.high
                ]
            )
        }
        #endif
    }

    private func announceError(_ message: String) {
        #if canImport(AppKit)
        DispatchQueue.main.async {
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    NSAccessibility.NotificationUserInfoKey.announcement: "Error: \(message)",
                    NSAccessibility.NotificationUserInfoKey.priority: NSAccessibilityPriorityLevel.high
                ]
            )
        }
        #endif
    }

    private func announceInfo(_ message: String) {
        #if canImport(AppKit)
        DispatchQueue.main.async {
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    NSAccessibility.NotificationUserInfoKey.announcement: message,
                    NSAccessibility.NotificationUserInfoKey.priority: NSAccessibilityPriorityLevel.high
                ]
            )
        }
        #endif
    }
}
