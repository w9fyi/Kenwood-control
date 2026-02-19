//
//  MIDISectionView.swift
//  Kenwood control
//
//  MIDI controller setup: pick a MIDI source, map a CC number, choose the
//  tuning step applied to VFO A on each encoder click.
//
//  Fully accessible with VoiceOver — every interactive element has an
//  accessibilityLabel and, where helpful, an accessibilityHint.
//

import SwiftUI
import CoreMIDI

struct MIDISectionView: View {
    @ObservedObject var radio: RadioState
    @ObservedObject private var midi = MIDIController.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                Text("MIDI Controller")
                    .font(.title2)

                Text("Connect the CTR2MIDI (or any MIDI device) to tune VFO A with a hardware encoder. The app listens for one Control Change (CC) message and steps the frequency up or down by the selected amount per encoder click.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                // Status indicator
                HStack(spacing: 8) {
                    Circle()
                        .fill(midi.isConnected ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    Text(midi.isConnected ? "MIDI Connected" : "MIDI Not Connected")
                        .fontWeight(.medium)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(midi.isConnected ? "MIDI status: connected" : "MIDI status: not connected")

                // MARK: Source picker
                GroupBox("MIDI Source") {
                    VStack(alignment: .leading, spacing: 10) {
                        if midi.availableSources.isEmpty {
                            Text("No MIDI sources found. Connect the CTR2MIDI and press Refresh.")
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                        } else {
                            Picker("MIDI Source", selection: $midi.selectedSourceRef) {
                                Text("(none)").tag(MIDIEndpointRef(0))
                                ForEach(midi.availableSources) { src in
                                    Text(src.name).tag(src.id)
                                }
                            }
                            .accessibilityLabel("MIDI input source")
                            .onChange(of: midi.selectedSourceRef) { _, newRef in
                                if newRef == 0 {
                                    midi.disconnect()
                                } else {
                                    midi.connect(to: newRef)
                                }
                            }
                        }

                        HStack(spacing: 12) {
                            Button("Refresh Sources") {
                                midi.refreshSources()
                            }
                            .accessibilityHint("Scans for newly connected MIDI devices")

                            if midi.isConnected {
                                Button("Disconnect") {
                                    midi.disconnect()
                                }
                                .accessibilityHint("Disconnects the current MIDI source")
                            }
                        }
                    }
                    .padding(.top, 4)
                }

                // MARK: CC mapping
                GroupBox("CC Mapping") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Enter the MIDI channel and CC number your encoder sends. For the CTR2MIDI the factory default is usually Channel 1, CC 1.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 24) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("MIDI Channel (1–16)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                // Displayed as 1-based; stored as 0-based
                                Stepper(
                                    "Channel \(midi.ccChannel + 1)",
                                    value: $midi.ccChannel,
                                    in: 0...15
                                )
                                .accessibilityLabel("MIDI channel")
                                .accessibilityValue("Channel \(midi.ccChannel + 1)")
                                .accessibilityHint("Increment or decrement to match the channel your encoder uses")
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("CC Number (0–127)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Stepper(
                                    "CC \(midi.ccNumber)",
                                    value: $midi.ccNumber,
                                    in: 0...127
                                )
                                .accessibilityLabel("Control Change number")
                                .accessibilityValue("CC \(midi.ccNumber)")
                                .accessibilityHint("Increment or decrement to match the CC your encoder sends")
                            }
                        }

                        Button("Save CC Settings") {
                            midi.savePreferences()
                        }
                        .accessibilityHint("Saves channel and CC number so they persist across app launches")
                    }
                    .padding(.top, 4)
                }

                // MARK: Tuning step
                GroupBox("Tuning Step Per Click") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("How far VFO A moves per encoder click. Use 10 Hz or 100 Hz for precise tuning; 10 kHz or 100 kHz for fast band changes.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Picker("Tuning Step", selection: $midi.tuningStep) {
                            ForEach(MIDITuningStep.allCases) { step in
                                Text(step.label).tag(step)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityLabel("Tuning step size per encoder click")
                        .onChange(of: midi.tuningStep) { _, _ in
                            midi.savePreferences()
                        }
                    }
                    .padding(.top, 4)
                }

                // MARK: Live event monitor
                GroupBox("Last MIDI Event (diagnostic)") {
                    Text(midi.lastMIDIEvent.isEmpty ? "(none yet — turn the encoder to test)" : midi.lastMIDIEvent)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(midi.lastMIDIEvent.isEmpty ? .secondary : .primary)
                        .accessibilityLabel(
                            midi.lastMIDIEvent.isEmpty
                                ? "No MIDI events received yet"
                                : "Last MIDI event: \(midi.lastMIDIEvent)"
                        )
                }

                // MARK: How it works note
                GroupBox("How the CTR2MIDI works") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("The CTR2MIDI sends relative Control Change messages:")
                            .font(.footnote)
                        Text("  Clockwise:       CC value 1–63  (higher = faster spin)")
                            .font(.system(.footnote, design: .monospaced))
                        Text("  Counterclockwise: CC value 65–127 (127 = slowest)")
                            .font(.system(.footnote, design: .monospaced))
                        Text("Each click moves VFO A by the selected tuning step. Multiple clicks in the same direction in rapid succession move by proportionally more.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .onAppear {
            midi.radio = radio
            midi.refreshSources()
        }
    }
}
