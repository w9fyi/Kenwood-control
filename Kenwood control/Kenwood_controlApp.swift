//
//  Kenwood_controlApp.swift
//  Kenwood control
//
//  Created by justin Mann on 2/11/26.
//

import SwiftUI
import AppKit

let KenwoodSelectSectionNotification = Notification.Name("KenwoodControl.SelectSection")
let KenwoodSelectSectionUserInfoKey = "section"

final class PTTKeyMonitor {
    static let shared = PTTKeyMonitor()
    private init() {}

    // Strong ref on purpose: this singleton is app-global and should never lose the active RadioState.
    // A weak ref can become nil if SwiftUI recreates/replaces the state object, which makes PTT appear "dead"
    // even though key events are still being observed.
    private var radio: RadioState?
    private var monitor: Any?
    private var isDown: Bool = false
    private var optionIsDown: Bool = false
    private var lastLogAt: Date = .distantPast

    func attach(radio: RadioState) {
        self.radio = radio
        installIfNeeded()
        AppFileLogger.shared.log("PTTKeyMonitor: attached")

        // Safety: if app loses focus, ensure we drop PTT.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    private func installIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }

            // Push-to-talk: hold Option+Space.
            if event.type == .flagsChanged {
                // Under VoiceOver, keyDown/keyUp events sometimes arrive without the expected modifier flags.
                // Track Option state separately so Option+Space remains usable.
                self.optionIsDown = event.modifierFlags.contains(.option)
            }
            let opt = event.modifierFlags.contains(.option)
            let optEffective = opt || self.optionIsDown
            let isSpaceDown = (event.type == .keyDown && event.keyCode == 49)
            let isSpaceUp = (event.type == .keyUp && event.keyCode == 49)

            if isSpaceDown || isSpaceUp || event.type == .flagsChanged {
                let now = Date()
                if now.timeIntervalSince(self.lastLogAt) > 2.0 {
                    self.lastLogAt = now
                    AppFileLogger.shared.log("PTTKeyMonitor: event type=\(event.type.rawValue) keyCode=\(event.keyCode) opt=\(opt) optEffective=\(optEffective) mods=0x\(String(event.modifierFlags.rawValue, radix: 16))")
                }
            }

            if optEffective && isSpaceDown {
                if !self.isDown {
                    guard let radio = self.radio else {
                        AppFileLogger.shared.log("PTTKeyMonitor: DOWN ignored (radio=nil)")
                        self.isDown = true
                        return nil
                    }
                    AppFileLogger.shared.logSync("PTTKeyMonitor: calling setPTT(down:true) active=\(NSApp.isActive)")
                    radio.setPTT(down: true)
                    self.isDown = true
                    AppFileLogger.shared.log("PTTKeyMonitor: DOWN")
                }
                // Consume to avoid system "bonk"/click.
                return nil
            }

            if isSpaceUp || (!optEffective && self.isDown) {
                if self.isDown {
                    guard let radio = self.radio else {
                        AppFileLogger.shared.log("PTTKeyMonitor: UP ignored (radio=nil)")
                        self.isDown = false
                        if isSpaceUp { return nil }
                        return event
                    }
                    AppFileLogger.shared.logSync("PTTKeyMonitor: calling setPTT(down:false) active=\(NSApp.isActive)")
                    radio.setPTT(down: false)
                    self.isDown = false
                    AppFileLogger.shared.log("PTTKeyMonitor: UP")
                }
                // Consume the key-up (and option-release path) to keep UX quiet.
                if isSpaceUp { return nil }
            }

            return event
        }
    }

    @objc private func appDidResignActive() {
        if isDown {
            radio?.setPTT(down: false)
            isDown = false
        }
    }
}

@main
struct Kenwood_controlApp: App {
    // Important: create exactly one RadioState instance and use it everywhere (UI + key monitors).
    // SwiftUI may re-run `init()` for the App struct; using `_radio = StateObject(...)` guarantees
    // we keep a single stable object.
    @StateObject private var radio: RadioState
    @Environment(\.openWindow) private var openWindow

    init() {
        let r = RadioState()
        _radio = StateObject(wrappedValue: r)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        AppLogger.info("=== Launch v\(version) (\(build)) pid=\(ProcessInfo.processInfo.processIdentifier) ===")
        AppLogger.info("Use `scripts/checklogs.sh` to fetch logs.")
        AppFileLogger.shared.logLaunchHeader()
        AppFileLogger.shared.log("Tip: type `checklogs` in chat and I will fetch the latest log for you.")
        AppFileLogger.shared.log("Noise reduction backend: \(r.noiseReductionBackend)")

        // Install push-to-talk monitor (Option-Space). This should not beep/click.
        PTTKeyMonitor.shared.attach(radio: r)

        // Wire the MIDI controller so encoder movements tune VFO A.
        MIDIController.shared.radio = r
    }

    var body: some Scene {
        WindowGroup {
            ContentView(radio: radio)
        }
        Window("About Kenwood Control", id: "about") {
            AboutView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Kenwood Control") {
                    openWindow(id: "about")
                }
            }
            CommandMenu("Audio") {
                Toggle("Noise Reduction", isOn: Binding(
                    get: { radio.isNoiseReductionEnabled },
                    set: { radio.setNoiseReduction(enabled: $0) }
                ))
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!radio.isNoiseReductionAvailable)

                Button("Cycle NR Backend") { radio.cycleNoiseReductionBackend() }
                    .keyboardShortcut("r", modifiers: [.command, .control])
                    .disabled(!radio.isNoiseReductionAvailable)

                Toggle("Mute Audio", isOn: Binding(
                    get: { radio.isAudioMuted },
                    set: { radio.setAudioMuted($0) }
                ))
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }
            CommandMenu("Connection") {
                Button("Connect") { radio.reconnect() }
                    .keyboardShortcut("c", modifiers: [.command])
                Button("Disconnect") { radio.disconnect() }
                    .keyboardShortcut("d", modifiers: [.command])
            }
            CommandMenu("Mode") {
                Button("Lower Sideband (LSB)") {
                    radio.send(KenwoodCAT.setOperatingMode(.lsb))
                    radio.send(KenwoodCAT.getOperatingMode())
                }
                .keyboardShortcut("l", modifiers: [.control, .shift])

                Button("Upper Sideband (USB)") {
                    radio.send(KenwoodCAT.setOperatingMode(.usb))
                    radio.send(KenwoodCAT.getOperatingMode())
                }
                .keyboardShortcut("u", modifiers: [.control, .shift])

                Button("CW") {
                    radio.send(KenwoodCAT.setOperatingMode(.cw))
                    radio.send(KenwoodCAT.getOperatingMode())
                }
                .keyboardShortcut("c", modifiers: [.control, .shift])

                Button("AM") {
                    radio.send(KenwoodCAT.setOperatingMode(.am))
                    radio.send(KenwoodCAT.getOperatingMode())
                }
                .keyboardShortcut("a", modifiers: [.control, .shift])

                Button("FM") {
                    radio.send(KenwoodCAT.setOperatingMode(.fm))
                    radio.send(KenwoodCAT.getOperatingMode())
                }
                .keyboardShortcut("f", modifiers: [.control, .shift])
            }
            CommandMenu("Radio") {
                Button("PTT Down (TX)") { radio.setPTT(down: true) }
                Button("PTT Up (RX)") { radio.setPTT(down: false) }
                Divider()
                Text("Hold Option-Space for push-to-talk")
            }
            CommandMenu("View") {
                Button("Connection") {
                    NotificationCenter.default.post(name: KenwoodSelectSectionNotification, object: nil, userInfo: [KenwoodSelectSectionUserInfoKey: "connection"])
                }
                .keyboardShortcut("1", modifiers: [.command])
                Button("Radio") {
                    NotificationCenter.default.post(name: KenwoodSelectSectionNotification, object: nil, userInfo: [KenwoodSelectSectionUserInfoKey: "radio"])
                }
                .keyboardShortcut("2", modifiers: [.command])
                Button("Audio") {
                    NotificationCenter.default.post(name: KenwoodSelectSectionNotification, object: nil, userInfo: [KenwoodSelectSectionUserInfoKey: "audio"])
                }
                .keyboardShortcut("3", modifiers: [.command])
                Button("Logs") {
                    NotificationCenter.default.post(name: KenwoodSelectSectionNotification, object: nil, userInfo: [KenwoodSelectSectionUserInfoKey: "logs"])
                }
                .keyboardShortcut("4", modifiers: [.command])
                Divider()
                Button("FT8") {
                    NotificationCenter.default.post(name: KenwoodSelectSectionNotification, object: nil, userInfo: [KenwoodSelectSectionUserInfoKey: "ft8"])
                }
                .keyboardShortcut("5", modifiers: [.command])
            }
        }
    }
}
