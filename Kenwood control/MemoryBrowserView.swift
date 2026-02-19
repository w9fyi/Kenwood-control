//
//  MemoryBrowserView.swift
//  Kenwood control
//
//  Scrollable list of all 120 TS-890S memory channels with in-place editing.
//

import SwiftUI

struct MemoryBrowserView: View {
    @ObservedObject var radio: RadioState

    @State private var selectedChannelID: Int? = nil
    @State private var editFreqMHz: String = ""
    @State private var editName: String = ""
    @State private var editMode: KenwoodCAT.OperatingMode = .usb
    @State private var editFMNarrow: Bool = false

    var body: some View {
        HSplitView {
            // Left: channel list
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("Memories")
                        .font(.title2)
                    Spacer()
                    if radio.isLoadingAllMemories {
                        ProgressView()
                            .scaleEffect(0.7)
                            .accessibilityLabel("Loading memory channels")
                    }
                    Button("Load All") {
                        radio.loadAllMemoryChannels()
                    }
                    .disabled(radio.isLoadingAllMemories)
                    .accessibilityHint("Reads all 120 memory channels from the radio")
                }
                .padding([.top, .horizontal])

                if radio.memoryChannels.isEmpty {
                    Text(radio.isLoadingAllMemories ? "Loading..." : "Press Load All to read memories from the radio.")
                        .foregroundStyle(.secondary)
                        .padding()
                    Spacer()
                } else {
                    List(radio.memoryChannels, selection: $selectedChannelID) { ch in
                        MemoryRowView(channel: ch, isSelected: selectedChannelID == ch.id)
                            .tag(ch.id)
                    }
                    .onChange(of: selectedChannelID) { _, newID in
                        guard let id = newID,
                              let ch = radio.memoryChannels.first(where: { $0.id == id }) else { return }
                        loadEditFields(from: ch)
                    }
                }
            }
            .frame(minWidth: 300)

            // Right: editor for the selected channel
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let id = selectedChannelID,
                       let ch = radio.memoryChannels.first(where: { $0.id == id }) {
                        Text("Channel \(String(format: "%03d", id))")
                            .font(.title3)

                        HStack(spacing: 12) {
                            Button("Tune to this channel") {
                                radio.setMemoryMode(enabled: true)
                                radio.recallMemoryChannel(id)
                            }
                            .accessibilityHint("Switches radio to memory mode and tunes to channel \(id)")

                            Button("Recall (VFO copy)") {
                                radio.recallMemoryChannel(id)
                            }
                            .accessibilityHint("Copies memory frequency to VFO")
                        }

                        Divider()

                        Text("Edit Channel")
                            .font(.headline)

                        HStack(spacing: 12) {
                            Text("Frequency (MHz):")
                            TextField("e.g. 7.100000", text: $editFreqMHz)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                                .accessibilityLabel("Memory channel frequency in megahertz")
                        }

                        HStack(spacing: 12) {
                            Text("Name (10 chars):")
                            TextField("Up to 10", text: $editName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                                .onChange(of: editName) { _, v in
                                    if v.count > 10 { editName = String(v.prefix(10)) }
                                }
                                .accessibilityLabel("Memory channel name up to 10 characters")
                        }

                        HStack(spacing: 12) {
                            Text("Mode:")
                            Picker("Mode", selection: $editMode) {
                                ForEach(KenwoodCAT.OperatingMode.allCases, id: \.rawValue) { m in
                                    Text(m.label).tag(m)
                                }
                            }
                            .frame(width: 160)
                            .accessibilityLabel("Memory channel mode")

                            Toggle("FM Narrow", isOn: $editFMNarrow)
                                .disabled(editMode != .fm)
                        }

                        HStack(spacing: 12) {
                            Button("Save Changes") {
                                saveChannel(id: id)
                            }
                            .accessibilityHint("Writes edited frequency, mode, and name to channel \(id)")

                            Button("Revert") {
                                loadEditFields(from: ch)
                            }
                            .accessibilityHint("Restores the editor to the last received values for channel \(id)")
                        }

                        Text("Current on radio: \(ch.frequencyMHz) MHz • \(ch.mode.label) • \"\(ch.name)\"")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)

                    } else {
                        Text("Select a memory channel from the list.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .frame(minWidth: 300)
        }
    }

    private func loadEditFields(from ch: MemoryChannel) {
        editFreqMHz = ch.isEmpty ? "" : String(format: "%.6f", Double(ch.frequencyHz) / 1_000_000.0)
        editName = ch.name
        editMode = ch.mode
        editFMNarrow = false
    }

    private func saveChannel(id: Int) {
        let mhz = Double(editFreqMHz.replacingOccurrences(of: ",", with: ".")) ?? 0
        let hz = Int((mhz * 1_000_000).rounded())
        radio.programMemoryChannel(
            channel: id,
            frequencyHz: hz,
            mode: editMode,
            fmNarrow: editFMNarrow,
            name: editName
        )
    }
}

private struct MemoryRowView: View {
    let channel: MemoryChannel
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(String(format: "%03d", channel.id))
                .font(.system(.body, design: .monospaced))
                .frame(width: 36, alignment: .trailing)
                .foregroundStyle(isSelected ? .primary : .secondary)

            if channel.isEmpty {
                Text("(empty)")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.frequencyMHz + " MHz")
                        .font(.system(.body, design: .monospaced))
                    HStack(spacing: 6) {
                        Text(channel.mode.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !channel.name.isEmpty {
                            Text("·")
                                .foregroundStyle(.secondary)
                            Text(channel.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(channel.isEmpty
            ? "Channel \(channel.id), empty"
            : "Channel \(channel.id), \(channel.frequencyMHz) megahertz, \(channel.mode.label)\(channel.name.isEmpty ? "" : ", \(channel.name)")")
    }
}
