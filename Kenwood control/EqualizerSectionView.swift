//
//  EqualizerSectionView.swift
//  Kenwood control
//
//  Built-in radio parametric EQ for TS-890S.
//  TX EQ: EX030 (Low ~100 Hz), EX031 (Mid ~1 kHz), EX032 (High ~10 kHz)
//  RX EQ: EX060 (Low),         EX061 (Mid),          EX062 (High)
//  Range: −20…+10 dB per band.
//
//  Note: EX menu numbers may vary by firmware. Use the Menu Access section
//  to verify the correct numbers for your TS-890S.
//

import SwiftUI

struct EqualizerSectionView: View {
    @ObservedObject var radio: RadioState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Radio Equalizer")
                    .font(.title2)

                Text("Controls the TS-890S built-in parametric EQ via EX menu commands. Sliders apply after a brief pause.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Divider()

                GroupBox("TX Equalizer") {
                    VStack(alignment: .leading, spacing: 12) {
                        EQBandSlider(
                            label: "TX Low (≈100 Hz)",
                            value: Binding(
                                get: { radio.txEQLowGain ?? 0 },
                                set: { radio.setTXEQLowDebounced($0) }
                            )
                        )
                        EQBandSlider(
                            label: "TX Mid (≈1 kHz)",
                            value: Binding(
                                get: { radio.txEQMidGain ?? 0 },
                                set: { radio.setTXEQMidDebounced($0) }
                            )
                        )
                        EQBandSlider(
                            label: "TX High (≈10 kHz)",
                            value: Binding(
                                get: { radio.txEQHighGain ?? 0 },
                                set: { radio.setTXEQHighDebounced($0) }
                            )
                        )
                        Button("Reset TX EQ to Flat") {
                            radio.setTXEQLowDebounced(0)
                            radio.setTXEQMidDebounced(0)
                            radio.setTXEQHighDebounced(0)
                        }
                        .accessibilityHint("Sets all TX EQ bands to 0 dB")
                    }
                    .padding(.top, 4)
                }

                GroupBox("RX Equalizer") {
                    VStack(alignment: .leading, spacing: 12) {
                        EQBandSlider(
                            label: "RX Low (≈100 Hz)",
                            value: Binding(
                                get: { radio.rxEQLowGain ?? 0 },
                                set: { radio.setRXEQLowDebounced($0) }
                            )
                        )
                        EQBandSlider(
                            label: "RX Mid (≈1 kHz)",
                            value: Binding(
                                get: { radio.rxEQMidGain ?? 0 },
                                set: { radio.setRXEQMidDebounced($0) }
                            )
                        )
                        EQBandSlider(
                            label: "RX High (≈10 kHz)",
                            value: Binding(
                                get: { radio.rxEQHighGain ?? 0 },
                                set: { radio.setRXEQHighDebounced($0) }
                            )
                        )
                        Button("Reset RX EQ to Flat") {
                            radio.setRXEQLowDebounced(0)
                            radio.setRXEQMidDebounced(0)
                            radio.setRXEQHighDebounced(0)
                        }
                        .accessibilityHint("Sets all RX EQ bands to 0 dB")
                    }
                    .padding(.top, 4)
                }

                Text("EQ menu numbers: TX = EX030–032, RX = EX060–062. Verify with Menu Access if results seem incorrect.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .onAppear {
            radio.queryAllEQ()
        }
    }
}

/// A single EQ band row: label, dB readout, and a −20…+10 slider.
private struct EQBandSlider: View {
    let label: String
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(label)
                Spacer()
                Text("\(value >= 0 ? "+" : "")\(value) dB")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 64, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            Slider(value: Binding(
                get: { Double(value) },
                set: { value = Int($0.rounded()) }
            ), in: -20...10, step: 1)
            .accessibilityLabel(label)
            .accessibilityValue("\(value >= 0 ? "plus" : "minus") \(abs(value)) decibels")
        }
    }
}
