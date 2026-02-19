//
//  RadioMenuView.swift
//  Kenwood control
//
//  EX extended menu browser for TS-890S.
//  Exposes curated common menu items as labeled sliders/toggles,
//  plus a freeform numeric entry for any EX menu number.
//

import SwiftUI

struct RadioMenuView: View {
    @ObservedObject var radio: RadioState

    @State private var customMenuNumber: String = ""
    @State private var customMenuValue: String = ""

    // Curated TS-890S menu entries (EX menu number → human description)
    private let menuEntries: [MenuEntry] = [
        // TX bandwidth / EQ (verify menu numbers match your firmware)
        MenuEntry(number: 10,  label: "TX Bandwidth",     unit: "",    min: 0, max: 4,  isBool: false),
        MenuEntry(number: 11,  label: "TX Low Cut",        unit: "Hz",  min: 0, max: 6,  isBool: false),
        MenuEntry(number: 12,  label: "TX High Cut",       unit: "Hz",  min: 0, max: 10, isBool: false),
        MenuEntry(number: 30,  label: "TX EQ Low (≈100 Hz)",  unit: "dB", min: -20, max: 10, isBool: false),
        MenuEntry(number: 31,  label: "TX EQ Mid (≈1 kHz)",   unit: "dB", min: -20, max: 10, isBool: false),
        MenuEntry(number: 32,  label: "TX EQ High (≈10 kHz)", unit: "dB", min: -20, max: 10, isBool: false),
        MenuEntry(number: 60,  label: "RX EQ Low (≈100 Hz)",  unit: "dB", min: -20, max: 10, isBool: false),
        MenuEntry(number: 61,  label: "RX EQ Mid (≈1 kHz)",   unit: "dB", min: -20, max: 10, isBool: false),
        MenuEntry(number: 62,  label: "RX EQ High (≈10 kHz)", unit: "dB", min: -20, max: 10, isBool: false),
        MenuEntry(number: 70,  label: "NR Level",          unit: "",    min: 0, max: 15, isBool: false),
        MenuEntry(number: 80,  label: "NB Level",          unit: "",    min: 0, max: 10, isBool: false),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Menu Access (EX)")
                    .font(.title2)

                Text("Read and write TS-890S extended menu (EX) settings. Values are saved to the radio immediately when you press Write. Query first to see the current value.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                // Curated menu items
                ForEach(menuEntries) { entry in
                    MenuEntryRow(entry: entry, radio: radio)
                    Divider()
                }

                // Custom / freeform entry
                GroupBox("Custom Menu Number") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Enter any EX menu number to read or write it directly.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            Text("Menu #:")
                            TextField("000–999", text: $customMenuNumber)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                                .accessibilityLabel("Custom EX menu number")

                            Button("Read") {
                                if let n = Int(customMenuNumber) {
                                    radio.readMenuValue(n)
                                    if let v = radio.exMenuValues[n] {
                                        customMenuValue = String(v)
                                    }
                                }
                            }
                        }

                        HStack(spacing: 12) {
                            Text("Value:")
                            TextField("integer", text: $customMenuValue)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                                .accessibilityLabel("Custom EX menu value")

                            Button("Write") {
                                if let n = Int(customMenuNumber), let v = Int(customMenuValue) {
                                    radio.writeMenuValue(n, value: v)
                                }
                            }
                        }

                        if let n = Int(customMenuNumber), let v = radio.exMenuValues[n] {
                            Text("Last received: \(v)")
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                    .padding(.top, 4)
                }
                .onChange(of: radio.exMenuValues) { _, _ in
                    if let n = Int(customMenuNumber), let v = radio.exMenuValues[n] {
                        customMenuValue = String(v)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
    }
}

struct MenuEntry: Identifiable {
    let number: Int
    let label: String
    let unit: String
    let min: Int
    let max: Int
    let isBool: Bool
    var id: Int { number }
}

private struct MenuEntryRow: View {
    let entry: MenuEntry
    @ObservedObject var radio: RadioState

    var currentValue: Int { radio.exMenuValues[entry.number] ?? entry.min }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("EX\(String(format: "%03d", entry.number))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(entry.label)
                    .fontWeight(.medium)
                Spacer()
                Button("Read") {
                    radio.readMenuValue(entry.number)
                }
                .font(.caption)
            }

            if entry.isBool {
                Toggle(entry.label, isOn: Binding(
                    get: { currentValue != 0 },
                    set: { newVal in
                        radio.writeMenuValue(entry.number, value: newVal ? 1 : 0)
                    }
                ))
                .labelsHidden()
                .accessibilityLabel(entry.label)
            } else {
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { Double(currentValue) },
                        set: { radio.writeMenuValue(entry.number, value: Int($0.rounded())) }
                    ), in: Double(entry.min)...Double(entry.max), step: 1)
                    .accessibilityLabel(entry.label)
                    .accessibilityValue("\(currentValue)\(entry.unit.isEmpty ? "" : " \(entry.unit)")")

                    let sign = currentValue >= 0 && entry.min < 0 ? "+" : ""
                    Text("\(sign)\(currentValue)\(entry.unit.isEmpty ? "" : " \(entry.unit)")")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 72, alignment: .trailing)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}
