//
//  MIDIController.swift
//  Kenwood control
//
//  CoreMIDI integration — listens for MIDI input from any connected device
//  (including CTR2MIDI) and maps a single Control Change message to VFO A
//  tuning steps.  Designed for VoiceOver-first use; no mouse required.
//
//  Tuning step / CC mapping is persisted in UserDefaults so settings survive
//  app restarts.
//

import Foundation
import CoreMIDI
import Combine

// MARK: - Tuning step

/// How far VFO A moves per encoder click.
enum MIDITuningStep: Int, CaseIterable, Identifiable {
    case hz10    =      10
    case hz100   =     100
    case khz1    =   1_000
    case khz10   =  10_000
    case khz100  = 100_000

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .hz10:   return "10 Hz"
        case .hz100:  return "100 Hz"
        case .khz1:   return "1 kHz"
        case .khz10:  return "10 kHz"
        case .khz100: return "100 kHz"
        }
    }
}

// MARK: - MIDI source info (for the picker)

struct MIDISourceInfo: Identifiable, Hashable {
    let id: MIDIEndpointRef   // unique across the session
    let name: String
}

// MARK: - Controller

/// Singleton that manages a CoreMIDI input port and routes encoder CC messages
/// to the connected radio's VFO A frequency.
///
/// Usage:
///   1. Set `radio` to the app's `RadioState` instance (done in the App struct).
///   2. Present `MIDISectionView` so the user can pick a source and configure CC.
///   3. Move the CTR2MIDI encoder; VFO A tunes up/down by `tuningStep`.
final class MIDIController: ObservableObject {

    static let shared = MIDIController()

    // MARK: Published

    @Published var availableSources: [MIDISourceInfo] = []
    @Published var selectedSourceRef: MIDIEndpointRef = 0
    @Published var tuningStep: MIDITuningStep = .khz1
    @Published var ccChannel: Int = 0     // 0-based internally; displayed as 1–16
    @Published var ccNumber:  Int = 1     // CC 0–127
    @Published var isConnected: Bool = false
    @Published var lastMIDIEvent: String = ""

    /// Weak reference so MIDIController does not keep RadioState alive by itself.
    weak var radio: RadioState?

    // MARK: Private CoreMIDI state

    private var midiClient:   MIDIClientRef = 0
    private var inputPort:    MIDIPortRef   = 0
    private var activeSource: MIDIEndpointRef = 0

    // UserDefaults keys
    private let kSourceName  = "MIDI.SourceName"
    private let kCCChannel   = "MIDI.CCChannel"
    private let kCCNumber    = "MIDI.CCNumber"
    private let kTuningStep  = "MIDI.TuningStep"

    // MARK: Init

    private init() {
        loadPreferences()
        setupClient()
        refreshSources()
    }

    // MARK: - CoreMIDI setup

    private func setupClient() {
        // Notify block is called by CoreMIDI when the device list changes.
        let clientStatus = MIDIClientCreateWithBlock(
            "KenwoodControl.MIDIClient" as CFString,
            &midiClient
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshSources() }
        }
        guard clientStatus == noErr else {
            AppLogger.error("MIDI: MIDIClientCreate failed (\(clientStatus))")
            return
        }

        // Use the block-based port API (MIDIPacketList / MIDI 1.0 bytes directly).
        // This is simpler than the UMP-based protocol API and works on all our
        // supported OS versions.
        let portStatus = MIDIInputPortCreateWithBlock(
            midiClient,
            "KenwoodControl.InputPort" as CFString,
            &inputPort
        ) { [weak self] packetListPtr, _ in
            self?.processMIDIPacketList(packetListPtr)
        }
        guard portStatus == noErr else {
            AppLogger.error("MIDI: MIDIInputPortCreate failed (\(portStatus))")
            return
        }
    }

    // MARK: - Source management

    func refreshSources() {
        let count = MIDIGetNumberOfSources()
        var sources: [MIDISourceInfo] = []
        for i in 0..<count {
            let endpoint = MIDIGetSource(i)
            var cfName: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &cfName)
            let name = (cfName?.takeRetainedValue() as String?) ?? "MIDI Source \(i)"
            sources.append(MIDISourceInfo(id: endpoint, name: name))
        }
        availableSources = sources

        // Auto-select: prefer CTR2MIDI by name, then the saved source name.
        if selectedSourceRef == 0 || !sources.contains(where: { $0.id == selectedSourceRef }) {
            if let ctr = sources.first(where: {
                let n = $0.name.lowercased()
                return n.contains("ctr2midi") || n.contains("ctr 2 midi") || n.contains("ctr-2-midi")
            }) {
                connect(to: ctr.id)
            } else if let savedName = UserDefaults.standard.string(forKey: kSourceName),
                      let found = sources.first(where: { $0.name == savedName }) {
                connect(to: found.id)
            }
        }
    }

    func connect(to endpoint: MIDIEndpointRef) {
        // Disconnect current source first.
        if activeSource != 0 {
            MIDIPortDisconnectSource(inputPort, activeSource)
            activeSource = 0
        }
        guard MIDIPortConnectSource(inputPort, endpoint, nil) == noErr else {
            DispatchQueue.main.async { self.isConnected = false }
            return
        }
        activeSource = endpoint
        selectedSourceRef = endpoint
        if let info = availableSources.first(where: { $0.id == endpoint }) {
            UserDefaults.standard.set(info.name, forKey: kSourceName)
        }
        DispatchQueue.main.async { self.isConnected = true }
    }

    func disconnect() {
        guard activeSource != 0 else { return }
        MIDIPortDisconnectSource(inputPort, activeSource)
        activeSource = 0
        DispatchQueue.main.async {
            self.selectedSourceRef = 0
            self.isConnected = false
        }
    }

    // MARK: - Packet processing (CoreMIDI thread)

    /// Iterate a classic MIDI 1.0 MIDIPacketList and dispatch each complete
    /// status+data tuple to the main thread.
    private func processMIDIPacketList(_ listPtr: UnsafePointer<MIDIPacketList>) {
        var packet = listPtr.pointee.packet
        let count  = listPtr.pointee.numPackets
        for _ in 0..<count {
            let length = Int(packet.length)
            // packet.data is a fixed-size tuple (UInt8 × 256); read via mirror.
            withUnsafeBytes(of: packet.data) { raw in
                var i = 0
                while i < length {
                    let status = raw[i]
                    let messageType = status & 0xF0
                    let channel     = Int(status & 0x0F)
                    // Only handle 3-byte messages (CC = 0xBn).
                    if messageType == 0xB0, i + 2 < length {
                        let cc    = Int(raw[i + 1])
                        let value = Int(raw[i + 2])
                        DispatchQueue.main.async { [weak self] in
                            self?.handleCC(channel: channel, cc: cc, value: value)
                        }
                        i += 3
                    } else if messageType == 0xF0 {
                        // SysEx — skip the whole packet remainder
                        break
                    } else {
                        // Unknown or running-status; advance one byte and try again
                        i += 1
                    }
                }
            }
            packet = MIDIPacketNext(&packet).pointee
        }
    }

    // MARK: - CC → frequency (main thread)

    private func handleCC(channel: Int, cc: Int, value: Int) {
        lastMIDIEvent = "CC ch\(channel + 1) #\(cc) = \(value)"

        guard channel == ccChannel, cc == ccNumber else { return }
        guard let radio, let currentHz = radio.vfoAFrequencyHz else { return }

        // Relative encoder convention (most common):
        //   1–63  → clockwise  (+1 to +63 clicks)
        //   65–127 → counterclockwise (127 = -1, 65 = -63 clicks)
        //   64    → center detent / no change (some encoders)
        //   0     → some encoders send 0 for step-down; treat as -1
        let clicks: Int
        switch value {
        case 1...63:   clicks =  value
        case 65...127: clicks = -(128 - value)
        case 0:        clicks = -1
        default:       clicks =  0
        }
        guard clicks != 0 else { return }

        let delta  = clicks * tuningStep.rawValue
        let newHz  = max(0, min(currentHz + delta, 999_999_999))
        radio.send(KenwoodCAT.setVFOAFrequencyHz(newHz))
    }

    // MARK: - Persistence

    func savePreferences() {
        UserDefaults.standard.set(ccChannel,       forKey: kCCChannel)
        UserDefaults.standard.set(ccNumber,        forKey: kCCNumber)
        UserDefaults.standard.set(tuningStep.rawValue, forKey: kTuningStep)
    }

    private func loadPreferences() {
        if let v = UserDefaults.standard.object(forKey: kCCChannel) as? Int {
            ccChannel = v
        }
        if let v = UserDefaults.standard.object(forKey: kCCNumber) as? Int {
            ccNumber = v
        }
        if let raw = UserDefaults.standard.object(forKey: kTuningStep) as? Int,
           let step = MIDITuningStep(rawValue: raw) {
            tuningStep = step
        }
    }
}
