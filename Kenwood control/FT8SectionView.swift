//
//  FT8SectionView.swift
//  Kenwood control
//
//  FT8 in this app is intentionally non-GPL: do not copy WSJT-X code.
//  This file provides a VoiceOver-first UI scaffold and a text-level auto-reply state machine.
//

import SwiftUI
import Combine
import Foundation
import AppKit

final class FT8ViewModel: ObservableObject {
    @Published var isAutoReplyEnabled: Bool = false
    @Published var simulateDecodedText: String = ""
    @Published var decodedMessages: [DecodedMessage] = []
    @Published var holdDecodedListUpdates: Bool = true
    @Published var pendingDecodedMessagesCount: Int = 0
    @Published var activityLog: [String] = []
    @Published var verboseFT8Logging: Bool = false
    @Published var lastTxSummary: String = "No FT8 transmit yet."
    @Published var txText: String = ""
    @Published var plannedTxText: String = ""
    @Published var isFT8Running: Bool = false
    @Published var preFT8Summary: String = ""
    @Published var isCQRunning: Bool = false
    @Published var cqParityRaw: String = "Even"
    @Published var isTxArmed: Bool = false
    @Published var nextCQTxAt: Date?

    private var cqTimer: DispatchSourceTimer?

    // RX capture (decode not implemented yet).
    @Published var isRxCaptureEnabled: Bool = false
    @Published var rxLevelDbFS: Double = -120.0
    @Published var rxBufferedSeconds: Double = 0.0
    @Published var lastSavedWavPath: String = ""
    @Published var isDecoding: Bool = false
    @Published var lastDecodeSummary: String = ""
    @Published var isAutoDecodeEnabled: Bool = false
    @Published var jt9DecoderPathLabel: String = "(not selected)"

    // Per-caller simple state so we don't keep repeating the same response.
    private var qsoStageByCaller: [String: Stage] = [:]
    private var pendingDecodedMessages: [DecodedMessage] = []

    enum Stage: String {
        case none
        case sentGrid
        case sentRReport
        case sentRRR
        case sent73
    }

    // Best-effort snapshot so we can put the rig back when FT8 is stopped.
    var preFT8FrequencyHz: Int?
    var preFT8Mode: KenwoodCAT.OperatingMode?
    var preFT8DataModeEnabled: Bool?
    var preFT8MDMode: Int?

    // RX buffering at 12 kHz for future decode.
    private let rxQueue = DispatchQueue(label: "FT8.rx")
    private var rx12k: [Float] = []
    private var rxFrameCounter: Int = 0
    private var rxEndTime: TimeInterval?

    private let jt9BookmarkKey = "FT8.JT9Bookmark"

    init() {
        // Best-effort: resolve stored decoder selection for sandbox access.
        _ = autoConfigureJT9DecoderIfNeeded(logToActivity: false)
    }

    private var autoDecodeWorkItem: DispatchWorkItem?
    private var autoDecodeMyCall: String = ""
    private var autoDecodeMyGrid: String = ""

    enum CQParity: String, CaseIterable {
        case even = "Even"
        case odd = "Odd"
    }

    struct DecodedMessage: Identifiable {
        let id = UUID()
        let receivedAt: Date
        let raw: String
        let caller: String
        let to: String
        let payload: String
        let isDirectedToMe: Bool
    }

    func appendLog(_ line: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        activityLog.append("[\(ts)] \(line)")
        if activityLog.count > 400 {
            activityLog.removeFirst(activityLog.count - 400)
        }
    }

    func processDecodedLine(_ line: String, myCall: String, myGrid: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let normalized = trimmed.uppercased()
        if verboseFT8Logging {
            appendLog("RX: \(normalized)")
        }

        if let msg = parseDecodedLine(normalized, myCall: myCall.uppercased()) {
            ingestDecodedMessage(msg)
        }

        guard isAutoReplyEnabled else { return }
        guard !myCall.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            appendLog("Auto-reply skipped: set your callsign first.")
            return
        }

        if let reply = autoReply(forDecodedLine: normalized, myCall: myCall.uppercased(), myGrid: myGrid.uppercased()) {
            plannedTxText = reply
            appendLog("Plan TX: \(reply)")
        }
    }

    private func ingestDecodedMessage(_ msg: DecodedMessage) {
        if holdDecodedListUpdates {
            pendingDecodedMessages.insert(msg, at: 0)
            if pendingDecodedMessages.count > 200 {
                pendingDecodedMessages.removeLast(pendingDecodedMessages.count - 200)
            }
            pendingDecodedMessagesCount = pendingDecodedMessages.count
            return
        }

        decodedMessages.insert(msg, at: 0)
        if decodedMessages.count > 200 {
            decodedMessages.removeLast(decodedMessages.count - 200)
        }
    }

    func setHoldDecodedListUpdates(_ hold: Bool) {
        holdDecodedListUpdates = hold
        if hold {
            appendLog("Hold decoded list updates: ON")
        } else {
            appendLog("Hold decoded list updates: OFF")
            flushPendingDecodedMessages()
        }
    }

    func flushPendingDecodedMessages() {
        guard !pendingDecodedMessages.isEmpty else { return }
        let count = pendingDecodedMessages.count
        decodedMessages.insert(contentsOf: pendingDecodedMessages, at: 0)
        if decodedMessages.count > 200 {
            decodedMessages.removeLast(decodedMessages.count - 200)
        }
        pendingDecodedMessages.removeAll()
        pendingDecodedMessagesCount = 0
        appendLog("Loaded \(count) queued decoded messages")
    }

    func clearDecodedMessages() {
        decodedMessages.removeAll()
        pendingDecodedMessages.removeAll()
        pendingDecodedMessagesCount = 0
        appendLog("Cleared decoded messages")
    }

    func fillReply(for msg: DecodedMessage, myCall: String, myGrid: String) {
        let call = myCall.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let grid = myGrid.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !call.isEmpty else {
            appendLog("Click-reply skipped: set your callsign first.")
            return
        }

        // Prefer state-machine reply if we have the full raw line.
        if let r = autoReply(forDecodedLine: msg.raw, myCall: call, myGrid: grid) {
            txText = r
            plannedTxText = r
            appendLog("Fill TX from click: \(r)")
            return
        }

        // Fallback: a safe first exchange is sending our grid.
        let r = "\(call) \(msg.caller) \(grid)"
        txText = r
        plannedTxText = r
        appendLog("Fill TX (fallback): \(r)")
    }

    // Minimal FT8 directed-message responder:
    // - Only reacts when the message is directed to myCall (CALLER MYCALL ...).
    // - Does not attempt signal report math; it mirrors the received report with the correct prefix.
    func autoReply(forDecodedLine line: String, myCall: String, myGrid: String) -> String? {
        let tokens = line
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { String($0) }

        // Expect at least: CALLER MYCALL <X>
        guard tokens.count >= 2 else { return nil }
        let caller = tokens[0]
        let to = tokens[1]
        guard to == myCall else { return nil }

        let third = tokens.count >= 3 ? tokens[2] : ""
        let stage = qsoStageByCaller[caller] ?? .none

        // If caller sends us their grid (often the first directed call),
        // respond with our grid.
        if isGrid(third), stage == .none || stage == .sentGrid {
            qsoStageByCaller[caller] = .sentGrid
            return "\(myCall) \(caller) \(myGrid)"
        }

        // Signal report forms: "-10", "+02", "R-05", "R+00"
        if isReport(third) {
            // If they gave us a plain report, we respond with "R<report>".
            // If they gave "R<report>", we respond with "RRR".
            if third.hasPrefix("R") {
                if stage != .sentRRR {
                    qsoStageByCaller[caller] = .sentRRR
                    return "\(myCall) \(caller) RRR"
                }
                return nil
            } else {
                if stage != .sentRReport {
                    qsoStageByCaller[caller] = .sentRReport
                    return "\(myCall) \(caller) R\(third)"
                }
                return nil
            }
        }

        if third == "RRR" {
            if stage != .sent73 {
                qsoStageByCaller[caller] = .sent73
                return "\(myCall) \(caller) 73"
            }
            return nil
        }

        if third == "73" {
            qsoStageByCaller[caller] = .sent73
            return nil
        }

        // Unknown payload; ignore.
        return nil
    }

    func parseDecodedLine(_ line: String, myCall: String) -> DecodedMessage? {
        let tokens = line
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { Self.normalizedToken(String($0)) }
            .filter { !$0.isEmpty }
        guard tokens.count >= 2 else { return nil }
        // Common FT8 "CQ" form: "CQ K1ABC FN42"
        if tokens[0] == "CQ", tokens.count >= 2 {
            guard let callerIndex = tokens.indices.dropFirst().first(where: { Self.looksLikeHamCallsign(tokens[$0]) }) else {
                return nil
            }
            let caller = tokens[callerIndex]
            let to = "CQ"
            let payload = callerIndex + 1 < tokens.count ? tokens[(callerIndex + 1)...].joined(separator: " ") : ""
            return DecodedMessage(
                receivedAt: Date(),
                raw: line,
                caller: caller,
                to: to,
                payload: payload,
                isDirectedToMe: false
            )
        }
        let caller = tokens[0]
        let to = tokens[1]
        guard Self.looksLikeHamCallsign(caller) else { return nil }
        guard Self.looksLikeHamCallsign(to) || to == "CQ" else { return nil }
        let payload = tokens.dropFirst(2).joined(separator: " ")
        return DecodedMessage(
            receivedAt: Date(),
            raw: line,
            caller: caller,
            to: to,
            payload: payload,
            isDirectedToMe: to == myCall
        )
    }

    func ingestRx48kMono(_ samples48k: [Float]) {
        guard isRxCaptureEnabled else { return }
        rxQueue.async { [weak self] in
            guard let self else { return }
            self.rxEndTime = Date().timeIntervalSince1970
            // Downsample 48k -> 12k by factor 4 with a simple 4-sample box filter.
            // This is sufficient for initial capture; we can replace with a proper resampler later.
            var out = [Float]()
            out.reserveCapacity(samples48k.count / 4)
            var i = 0
            while i + 3 < samples48k.count {
                let y = (samples48k[i] + samples48k[i + 1] + samples48k[i + 2] + samples48k[i + 3]) * 0.25
                out.append(y)
                i += 4
            }

            self.rx12k.append(contentsOf: out)
            // Keep last ~45 seconds.
            let maxSamples = 12_000 * 45
            if self.rx12k.count > maxSamples {
                self.rx12k.removeFirst(self.rx12k.count - maxSamples)
            }

            // Level/seconds updates at ~2 Hz.
            self.rxFrameCounter += 1
            if (self.rxFrameCounter % 50) == 0 {
                var sum: Double = 0
                for s in samples48k {
                    let d = Double(s)
                    sum += d * d
                }
                let mean = sum / Double(max(1, samples48k.count))
                let rms = sqrt(mean)
                let db = 20.0 * log10(rms + 1e-9)
                let seconds = Double(self.rx12k.count) / 12_000.0

                DispatchQueue.main.async {
                    self.rxLevelDbFS = max(-120.0, min(0.0, db))
                    self.rxBufferedSeconds = seconds
                }
            }
        }
    }

    func saveLast15SecondsToWav() {
        // Backward-compatible alias: what we really want for FT8 is the last full 15s slot.
        saveLastFull15SecondSlotToWav()
    }

    func saveLastFull15SecondSlotToWav(completion: ((String?) -> Void)? = nil) {
        rxQueue.async { [weak self] in
            guard let self else { return }
            let need = 12_000 * 15
            guard self.rx12k.count >= need else {
                DispatchQueue.main.async {
                    self.appendLog("RX save blocked: need 15s buffered (have \(Int(self.rxBufferedSeconds))s)")
                    completion?(nil)
                }
                AppFileLogger.shared.log("FT8: RX save blocked (need 15s) bufferedSeconds=\(String(format: "%.2f", self.rxBufferedSeconds))")
                return
            }

            guard let endTime = self.rxEndTime else {
                DispatchQueue.main.async {
                    self.appendLog("RX save blocked: no timing info yet (wait a second and retry).")
                    completion?(nil)
                }
                AppFileLogger.shared.log("FT8: RX save blocked (no timing info)")
                return
            }

            // Save the most recent *full* 15s slot (aligned to UTC seconds).
            // Example: if now is :37, slotEnd is :30, slotStart is :15.
            let nowSec = Int(Date().timeIntervalSince1970)
            let slotEndSec = nowSec - (nowSec % 15)
            let slotEnd = TimeInterval(slotEndSec)
            let slotStart = slotEnd - 15.0

            // Compute where that slot ends in our rolling buffer (relative to the last ingested audio timestamp).
            let secondsFromBufferEndToSlotEnd = endTime - slotEnd
            let offsetToSlotEndSamples = Int((secondsFromBufferEndToSlotEnd * 12_000.0).rounded())
            let slotEndIndex = self.rx12k.count - offsetToSlotEndSamples
            let slotStartIndex = slotEndIndex - need

            guard slotStartIndex >= 0, slotEndIndex <= self.rx12k.count, slotStartIndex < slotEndIndex else {
                DispatchQueue.main.async {
                    self.appendLog("RX save blocked: slot not in buffer yet (buffered=\(String(format: "%.1f", self.rxBufferedSeconds))s).")
                    completion?(nil)
                }
                AppFileLogger.shared.log("FT8: RX save blocked (slot not in buffer) bufferedSeconds=\(String(format: "%.2f", self.rxBufferedSeconds)) slotStartIndex=\(slotStartIndex) slotEndIndex=\(slotEndIndex) rx12k=\(self.rx12k.count)")
                return
            }

            let slot = Array(self.rx12k[slotStartIndex..<slotEndIndex])
            // Use the sandbox temp directory (absolute /tmp may be denied under App Sandbox).
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft8_rx_slot_\(Self.timestampForFilename()).wav")
            do {
                try Self.writeWav16Mono(path: url, sampleRate: 12_000, samples: slot)
                DispatchQueue.main.async {
                    self.lastSavedWavPath = url.path
                    let startLabel = Date(timeIntervalSince1970: slotStart).formatted(date: .omitted, time: .standard)
                    let endLabel = Date(timeIntervalSince1970: slotEnd).formatted(date: .omitted, time: .standard)
                    self.appendLog("Saved RX slot (\(startLabel)-\(endLabel)): \(url.path)")
                    completion?(url.path)
                }
                AppFileLogger.shared.log("FT8: RX slot saved path=\(url.path)")
            } catch {
                DispatchQueue.main.async {
                    self.appendLog("RX save failed: \(error.localizedDescription)")
                    completion?(nil)
                }
                AppFileLogger.shared.log("FT8: RX save failed: \(error.localizedDescription)")
            }
        }
    }

    func decodeLastSavedWavWithWSJTX(myCall: String, myGrid: String) {
        let wavPath = lastSavedWavPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wavPath.isEmpty else {
            appendLog("Decode blocked: save a slot first.")
            return
        }
        decodeWavWithWSJTX(wavPath: wavPath, myCall: myCall, myGrid: myGrid)
    }

    func decodeMostRecentSlotWithWSJTX(myCall: String, myGrid: String) {
        saveLastFull15SecondSlotToWav { [weak self] path in
            guard let self else { return }
            guard let path else { return }
            self.decodeWavWithWSJTX(wavPath: path, myCall: myCall, myGrid: myGrid)
        }
    }

    private func decodeWavWithWSJTX(wavPath: String, myCall: String, myGrid: String) {
        guard !isDecoding else {
            appendLog("Decode skipped: already decoding.")
            return
        }
        isDecoding = true
        lastDecodeSummary = ""
        AppFileLogger.shared.log("FT8: decode start wav=\(wavPath)")

        guard let jt9URL = resolveJT9URL() else {
            isDecoding = false
            appendLog("Decode failed: select the WSJT-X decoder (jt9) first.")
            AppFileLogger.shared.log("FT8: decode failed (jt9 not selected / not accessible)")
            return
        }

        jt9DecoderPathLabel = jt9URL.path
        let execDir = jt9URL.deletingLastPathComponent().path
        let wsjtxTmp = FileManager.default.temporaryDirectory.appendingPathComponent("wsjtx_tmp", isDirectory: true)
        let wsjtxData = FileManager.default.temporaryDirectory.appendingPathComponent("wsjtx_data", isDirectory: true)
        try? FileManager.default.createDirectory(at: wsjtxTmp, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: wsjtxData, withIntermediateDirectories: true)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // Ensure sandbox access for the decoder binary while it runs.
            let scoped = jt9URL.startAccessingSecurityScopedResource()
            defer {
                if scoped { jt9URL.stopAccessingSecurityScopedResource() }
            }
            let p = Process()
            p.executableURL = jt9URL
            p.arguments = [
                "-8",
                "-p", "15",
                "-q",
                "-e", execDir,
                "-a", wsjtxData.path,
                "-t", wsjtxTmp.path,
                "-c", myCall.uppercased(),
                "-G", myGrid.uppercased(),
                wavPath
            ]

            let out = Pipe()
            let err = Pipe()
            p.standardOutput = out
            p.standardError = err

            do {
                try p.run()
                p.waitUntilExit()
            } catch {
                DispatchQueue.main.async {
                    self.isDecoding = false
                    self.appendLog("Decode failed to start: \(error.localizedDescription)")
                    AppFileLogger.shared.log("FT8: decode failed to start: \(error.localizedDescription)")
                }
                return
            }

            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            let outStr = String(data: outData, encoding: .utf8) ?? ""
            let errStr = String(data: errData, encoding: .utf8) ?? ""

            let lines = (outStr + "\n" + errStr)
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            DispatchQueue.main.async {
                self.isDecoding = false
                if lines.isEmpty {
                    self.lastDecodeSummary = "No decodes"
                    self.appendLog("Decode complete: no output.")
                    AppFileLogger.shared.log("FT8: decode complete (no output)")
                    return
                }

                let logDecodePayloadDetails = true
                var decodedCount = 0
                var rawLogCount = 0
                var extractedRejectedCount = 0
                var acceptedLogCount = 0
                for l in lines {
                    // WSJT-X jt9 output contains many formats; best-effort extract the message tail.
                    // Heuristic: find first occurrence of " CQ " or a token that looks like a callsign, then keep the rest.
                    let up = l.uppercased()
                    if logDecodePayloadDetails, rawLogCount < 16 {
                        AppFileLogger.shared.log("FT8: jt9 raw[\(rawLogCount + 1)] \(Self.compactForLog(up, limit: 220))")
                        rawLogCount += 1
                    }
                    if let msg = Self.extractMessageFromJT9Line(up) {
                        if let parsed = self.parseDecodedLine(msg, myCall: myCall.uppercased()) {
                            if logDecodePayloadDetails, acceptedLogCount < 16 {
                                AppFileLogger.shared.log(
                                    "FT8: parsed accepted[\(acceptedLogCount + 1)] caller=\(parsed.caller) to=\(parsed.to) payload=\(Self.compactForLog(parsed.payload, limit: 120)) raw=\(Self.compactForLog(parsed.raw, limit: 220))"
                                )
                                acceptedLogCount += 1
                            }
                            self.processDecodedLine(msg, myCall: myCall, myGrid: myGrid)
                            decodedCount += 1
                        } else if logDecodePayloadDetails, extractedRejectedCount < 16 {
                            AppFileLogger.shared.log("FT8: parsed rejected[\(extractedRejectedCount + 1)] \(Self.compactForLog(msg, limit: 220))")
                            extractedRejectedCount += 1
                        }
                    } else if self.verboseFT8Logging {
                        self.appendLog("jt9: \(up)")
                    }
                }
                self.lastDecodeSummary = "Decoded \(decodedCount) messages"
                self.appendLog("Decode complete: \(decodedCount) messages")
                if logDecodePayloadDetails {
                    AppFileLogger.shared.log(
                        "FT8: decode lines total=\(lines.count) rawLogged=\(rawLogCount) accepted=\(decodedCount) extractedRejected=\(extractedRejectedCount)"
                    )
                }
                AppFileLogger.shared.log("FT8: decode complete decodedCount=\(decodedCount)")
            }
        }
    }

    func selectJT9DecoderBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.title = "Select WSJT-X decoder (jt9)"
        panel.message = "Choose the jt9 binary inside WSJT-X (usually wsjtx.app/Contents/MacOS/jt9)."
        panel.prompt = "Select"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        panel.begin { [weak self] resp in
            guard let self else { return }
            guard resp == .OK, let selectedURL = panel.url else { return }
            let url = Self.normalizeJT9URL(selectedURL)
            guard Self.isJT9Executable(url) else {
                self.appendLog("Invalid decoder selection: choose the jt9 binary in WSJT-X.")
                AppFileLogger.shared.log("FT8: invalid jt9 selection path=\(selectedURL.path)")
                return
            }
            do {
                let bookmark = try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(bookmark, forKey: self.jt9BookmarkKey)
                self.jt9DecoderPathLabel = url.path
                self.appendLog("Selected jt9 decoder: \(url.path)")
                AppFileLogger.shared.log("FT8: selected jt9 path=\(url.path)")
            } catch {
                self.appendLog("Failed to store jt9 selection: \(error.localizedDescription)")
                AppFileLogger.shared.log("FT8: failed to store jt9 selection: \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    func autoConfigureJT9DecoderIfNeeded(logToActivity: Bool = true) -> Bool {
        guard let url = resolveJT9URL() else {
            jt9DecoderPathLabel = "(jt9 not found)"
            if logToActivity {
                appendLog("WSJT-X decoder not found automatically. Use Select WSJT-X decoder (jt9)...")
            }
            AppFileLogger.shared.log("FT8: jt9 auto-config not found")
            return false
        }
        jt9DecoderPathLabel = url.path
        if logToActivity {
            appendLog("WSJT-X decoder ready: \(url.path)")
        }
        AppFileLogger.shared.log("FT8: jt9 auto-config path=\(url.path)")
        return true
    }

    private func persistJT9Bookmark(_ url: URL) {
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: jt9BookmarkKey)
        } catch {
            AppFileLogger.shared.log("FT8: jt9 bookmark persist failed for \(url.path): \(error.localizedDescription)")
        }
    }

    private static func normalizeJT9URL(_ url: URL) -> URL {
        let path = url.path
        let lower = path.lowercased()
        let last = url.lastPathComponent.lowercased()

        if lower.hasSuffix(".app") {
            return url.appendingPathComponent("Contents/MacOS/jt9")
        }
        if last == "wsjtx" || last == "wsjtx-pro" {
            return url.deletingLastPathComponent().appendingPathComponent("jt9")
        }
        return url
    }

    private static func isJT9Executable(_ url: URL) -> Bool {
        guard url.lastPathComponent.lowercased() == "jt9" else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    private func resolveJT9URL() -> URL? {
        if let data = UserDefaults.standard.data(forKey: jt9BookmarkKey) {
            var stale = false
            if let resolvedURL = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                let normalized = Self.normalizeJT9URL(resolvedURL)
                if Self.isJT9Executable(normalized) {
                    return normalized
                }
            }
        }

        // Non-sandbox fallback (or if sandbox allows it): common locations.
        let candidates = [
            URL(fileURLWithPath: "/Applications/wsjtx.app"),
            URL(fileURLWithPath: "/Applications/WSJT-X.app"),
            URL(fileURLWithPath: "/Applications/wsjtx.app/Contents/MacOS/jt9"),
            URL(fileURLWithPath: "/Applications/WSJT-X.app/Contents/MacOS/jt9"),
            URL(fileURLWithPath: "/Applications/wsjtx-pro.app"),
            URL(fileURLWithPath: "/Applications/wsjtx-pro.app/Contents/MacOS/jt9")
        ]
        for candidate in candidates {
            let normalized = Self.normalizeJT9URL(candidate)
            if Self.isJT9Executable(normalized) {
                return normalized
            }
        }
        return nil
    }

    func setAutoDecodeEnabled(_ enabled: Bool, myCall: String, myGrid: String) {
        isAutoDecodeEnabled = enabled
        autoDecodeMyCall = myCall
        autoDecodeMyGrid = myGrid
        if enabled {
            appendLog("Auto-decode enabled (every 15s slot)")
            scheduleNextAutoDecodeTick()
        } else {
            appendLog("Auto-decode disabled")
            autoDecodeWorkItem?.cancel()
            autoDecodeWorkItem = nil
        }
    }

    private func scheduleNextAutoDecodeTick() {
        guard isAutoDecodeEnabled else { return }

        // Next 15s boundary + a small delay so we have the full slot in the buffer.
        let now = Date()
        let nowSec = Int(now.timeIntervalSince1970)
        let nextBoundary = nowSec - (nowSec % 15) + 15
        let fireAt = Date(timeIntervalSince1970: TimeInterval(nextBoundary) + 0.6)

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isAutoDecodeEnabled else { return }
            if self.isDecoding {
                self.appendLog("Auto-decode skipped: decoder busy")
                self.scheduleNextAutoDecodeTick()
                return
            }
            self.appendLog("Auto-decode tick")
            self.decodeMostRecentSlotWithWSJTX(myCall: self.autoDecodeMyCall, myGrid: self.autoDecodeMyGrid)
            self.scheduleNextAutoDecodeTick()
        }

        autoDecodeWorkItem?.cancel()
        autoDecodeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, fireAt.timeIntervalSinceNow), execute: item)
    }

    private static func extractMessageFromJT9Line(_ line: String) -> String? {
        // Common WSJT-X style includes "~ CQ K1ABC FN42" or "... CQ K1ABC FN42"
        // or "... K1ABC W9XYZ -10". We try to find the start of the actual message.
        let tokens = line
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { String($0) }
        if tokens.isEmpty { return nil }

        // Prefer explicit CQ lines, allowing forms like "CQ DX K1ABC FN42".
        for i in 0..<tokens.count {
            guard normalizedToken(tokens[i]) == "CQ" else { continue }
            let hasCallAfterCQ = ((i + 1)..<tokens.count).contains { j in
                looksLikeHamCallsign(normalizedToken(tokens[j]))
            }
            if hasCallAfterCQ {
                return tokens[i...].joined(separator: " ")
            }
        }

        // Directed FT8 form usually starts with two callsigns.
        if tokens.count >= 2 {
            for i in 0..<(tokens.count - 1) {
                let a = normalizedToken(tokens[i])
                let b = normalizedToken(tokens[i + 1])
                if looksLikeHamCallsign(a), looksLikeHamCallsign(b) {
                    return tokens[i...].joined(separator: " ")
                }
            }
        }

        // Fallback: a callsign followed by a likely payload token.
        for i in 0..<tokens.count {
            let a = normalizedToken(tokens[i])
            guard looksLikeHamCallsign(a) else { continue }
            if i + 1 < tokens.count {
                let b = normalizedToken(tokens[i + 1])
                if isLikelyGridToken(b) || isLikelyReportToken(b) || b == "RRR" || b == "RR73" || b == "73" {
                    return tokens[i...].joined(separator: " ")
                }
            } else {
                return tokens[i...].joined(separator: " ")
            }
        }
        return nil
    }

    private static let nonCallTokens: Set<String> = [
        "FT8", "FT4", "JT9", "JT65", "Q65", "MSK144", "WSPR", "FST4", "FST4W",
        "USB", "LSB", "AM", "FM", "CW", "SNR", "DT", "FREQ", "FREQUENCY",
        "HZ", "KHZ", "MHZ", "TX", "RX", "DECODE", "DECODING",
        "USAGE", "OPTIONS", "READS", "DISPLAY", "DEFAULT", "PATH", "KEY",
        "SECONDS", "DATA", "FROM", "SHARED", "MEMORY", "FILE", "FILE1", "FILE2"
    ]

    private static func normalizedToken(_ s: String) -> String {
        let up = s.uppercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/+-"))
        var scalars = Array(up.unicodeScalars)
        while let first = scalars.first, !allowed.contains(first) { scalars.removeFirst() }
        while let last = scalars.last, !allowed.contains(last) { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func looksLikeHamCallsign(_ s: String) -> Bool {
        let up = normalizedToken(s)
        guard up.count >= 3 && up.count <= 12 else { return false }
        guard !nonCallTokens.contains(up) else { return false }
        guard up.rangeOfCharacter(from: CharacterSet.decimalDigits) != nil else { return false }
        let parts = up.split(separator: "/")
        guard !parts.isEmpty else { return false }
        let main = String(parts[0])
        guard !main.isEmpty else { return false }
        for ch in up.unicodeScalars {
            let v = ch.value
            let isAZ = (65...90).contains(v)
            let is09 = (48...57).contains(v)
            let isSlash = v == 47
            if !(isAZ || is09 || isSlash) { return false }
        }
        let chars = Array(main)
        guard let firstDigit = chars.firstIndex(where: { $0.isNumber }),
              let lastDigit = chars.lastIndex(where: { $0.isNumber }) else {
            return false
        }
        let prefix = String(chars[..<firstDigit])
        let numeral = String(chars[firstDigit...lastDigit])
        let suffixStart = chars.index(after: lastDigit)
        let suffix = suffixStart < chars.endIndex ? String(chars[suffixStart...]) : ""
        guard prefix.count >= 1 && prefix.count <= 3 else { return false }
        guard numeral.count >= 1 && numeral.count <= 2 else { return false }
        guard suffix.count >= 1 && suffix.count <= 4 else { return false }
        guard prefix.allSatisfy(\.isLetter) else { return false }
        guard suffix.allSatisfy(\.isLetter) else { return false }
        for p in parts.dropFirst() {
            guard !p.isEmpty else { return false }
            guard p.count <= 6 else { return false }
        }
        return true
    }

    private static func isLikelyGridToken(_ s: String) -> Bool {
        let up = normalizedToken(s)
        guard up.count == 4 || up.count == 6 else { return false }
        let chars = Array(up)
        guard chars.count >= 4 else { return false }
        guard chars[0].isLetter, chars[1].isLetter else { return false }
        guard chars[2].isNumber, chars[3].isNumber else { return false }
        return true
    }

    private static func isLikelyReportToken(_ s: String) -> Bool {
        let up = normalizedToken(s)
        let body = up.hasPrefix("R") ? String(up.dropFirst()) : up
        guard body.count == 3 else { return false }
        let chars = Array(body)
        guard chars[0] == "+" || chars[0] == "-" else { return false }
        return chars[1].isNumber && chars[2].isNumber
    }

    private static func compactForLog(_ s: String, limit: Int) -> String {
        let collapsed = s
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "..."
    }

    private static func timestampForFilename() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }

    private static func writeWav16Mono(path: URL, sampleRate: Int, samples: [Float]) throws {
        // 16-bit PCM WAV, little-endian.
        let numSamples = samples.count
        let bytesPerSample = 2
        let dataBytes = numSamples * bytesPerSample
        let riffChunkSize = 36 + dataBytes

        var data = Data()
        data.reserveCapacity(44 + dataBytes)

        func putASCII(_ s: String) { data.append(contentsOf: s.utf8) }
        func putU32(_ v: UInt32) {
            var le = v.littleEndian
            data.append(UnsafeBufferPointer(start: &le, count: 1))
        }
        func putU16(_ v: UInt16) {
            var le = v.littleEndian
            data.append(UnsafeBufferPointer(start: &le, count: 1))
        }

        putASCII("RIFF")
        putU32(UInt32(riffChunkSize))
        putASCII("WAVE")

        putASCII("fmt ")
        putU32(16) // PCM fmt chunk size
        putU16(1) // PCM
        putU16(1) // mono
        putU32(UInt32(sampleRate))
        putU32(UInt32(sampleRate * bytesPerSample)) // byte rate
        putU16(UInt16(bytesPerSample)) // block align
        putU16(16) // bits per sample

        putASCII("data")
        putU32(UInt32(dataBytes))

        for s in samples {
            let clamped = max(-1.0, min(1.0, Double(s)))
            let v = Int16(clamped * 32767.0)
            var le = v.littleEndian
            data.append(UnsafeBufferPointer(start: &le, count: 1))
        }

        try data.write(to: path, options: .atomic)
    }

    private func isGrid(_ s: String) -> Bool {
        // Very loose: 4 or 6 chars; first 2 letters, next 2 digits.
        let up = s.uppercased()
        guard up.count == 4 || up.count == 6 else { return false }
        let chars = Array(up)
        guard chars.count >= 4 else { return false }
        guard chars[0].isLetter, chars[1].isLetter else { return false }
        guard chars[2].isNumber, chars[3].isNumber else { return false }
        return true
    }

    private func isReport(_ s: String) -> Bool {
        // "-10", "+02", "R-05", "R+00"
        let up = s.uppercased()
        let body = up.hasPrefix("R") ? String(up.dropFirst()) : up
        guard body.count == 3 else { return false }
        let chars = Array(body)
        guard chars[0] == "+" || chars[0] == "-" else { return false }
        return chars[1].isNumber && chars[2].isNumber
    }
}

struct FT8SectionView: View {
    let radio: RadioState

    @StateObject private var vm = FT8ViewModel()
    @State private var showStationProfile: Bool = false
    @State private var showFT8ActivityLog: Bool = false

    @AppStorage("FT8.MyCallsign") private var myCallsign: String = ""
    @AppStorage("FT8.MyGrid") private var myGrid: String = ""
    @AppStorage("FT8.MyLocation") private var myLocation: String = ""

    struct BandPreset: Identifiable, Hashable {
        let id: String
        let label: String
        let frequencyHz: Int
        let notes: String
    }

    // Defaults are editable by changing code; user can also type an override below.
    // These are common FT8 dial frequencies; if you use a different plan, set the override.
    private let presets: [BandPreset] = [
        BandPreset(id: "160m", label: "160m", frequencyHz: 1_840_000, notes: "FT8"),
        BandPreset(id: "80m", label: "80m", frequencyHz: 3_573_000, notes: "FT8"),
        BandPreset(id: "60m", label: "60m", frequencyHz: 5_357_000, notes: "FT8 (channelized band; verify)"),
        BandPreset(id: "40m", label: "40m", frequencyHz: 7_074_000, notes: "FT8"),
        BandPreset(id: "30m", label: "30m", frequencyHz: 10_136_000, notes: "FT8"),
        BandPreset(id: "20m", label: "20m", frequencyHz: 14_074_000, notes: "FT8"),
        BandPreset(id: "17m", label: "17m", frequencyHz: 18_100_000, notes: "FT8"),
        BandPreset(id: "15m", label: "15m", frequencyHz: 21_074_000, notes: "FT8"),
        BandPreset(id: "12m", label: "12m", frequencyHz: 24_915_000, notes: "FT8"),
        BandPreset(id: "10m", label: "10m", frequencyHz: 28_074_000, notes: "FT8"),
        BandPreset(id: "6m", label: "6m", frequencyHz: 50_313_000, notes: "FT8"),
        BandPreset(id: "2m", label: "2m", frequencyHz: 144_174_000, notes: "FT8")
    ]

    @State private var selectedPresetID: String = "20m"
    @State private var frequencyOverrideMHz: String = ""
    @State private var forceUSB: Bool = true
    @State private var forceDataMode: Bool = true
    @State private var ensureLanAudio: Bool = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("FT8")
                    .font(.title2)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Station Profile")
                        .font(.headline)

                    HStack(spacing: 12) {
                        Button("Edit Station Profile") { showStationProfile = true }
                        Text("Call: \(myCallsign.isEmpty ? "(unset)" : myCallsign.uppercased())")
                            .font(.system(.body, design: .monospaced))
                        Text("Grid: \(myGrid.isEmpty ? "(unset)" : myGrid.uppercased())")
                            .font(.system(.body, design: .monospaced))
                    }
                    if !myLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Location: \(myLocation)")
                            .font(.system(.body, design: .monospaced))
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Band / Frequency")
                        .font(.headline)

                    HStack(spacing: 12) {
                        Picker("Band", selection: $selectedPresetID) {
                            ForEach(presets) { p in
                                Text(p.label).tag(p.id)
                            }
                        }
                        .frame(minWidth: 200)
                        .accessibilityLabel("FT8 band picker")

                        Text("Dial:")
                        Text(dialFrequencyLabelHz(selectedFrequencyHz))
                            .font(.system(.body, design: .monospaced))
                            .accessibilityLabel("Selected FT8 dial frequency \(dialFrequencyLabelHz(selectedFrequencyHz))")

                        if let p = presets.first(where: { $0.id == selectedPresetID }) {
                            Text(p.notes)
                                .font(.footnote)
                        }
                    }

                    HStack(spacing: 12) {
                        Text("Override (MHz):")
                        TextField("e.g. 14.074", text: $frequencyOverrideMHz)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                            .accessibilityLabel("Frequency override megahertz")
                        Button("Clear Override") { frequencyOverrideMHz = "" }
                            .disabled(frequencyOverrideMHz.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Toggle("Force USB", isOn: $forceUSB)
                    Toggle("Force Data Mode (USB-DATA via MD2)", isOn: $forceDataMode)
                    Toggle("Ensure LAN RX audio is running", isOn: $ensureLanAudio)

                    HStack(spacing: 12) {
                        Button(vm.isFT8Running ? "Stop FT8" : "Start FT8") {
                            if vm.isFT8Running {
                                stopFT8()
                            } else {
                                startFT8()
                            }
                        }
                        .accessibilityLabel(vm.isFT8Running ? "Stop FT8" : "Start FT8")

                        Text(vm.isFT8Running ? "Running" : "Stopped")
                            .font(.system(.body, design: .monospaced))
                    }

                    if !vm.preFT8Summary.isEmpty {
                        Text("Restore plan: \(vm.preFT8Summary)")
                            .font(.footnote)
                            .accessibilityLabel("Restore plan \(vm.preFT8Summary)")
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("CQ / Cycle Timing (Scaffold)")
                        .font(.headline)

                    HStack(spacing: 12) {
                        Picker("TX Cycle", selection: $vm.cqParityRaw) {
                            ForEach(FT8ViewModel.CQParity.allCases, id: \.rawValue) { p in
                                Text(p.rawValue).tag(p.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                        .accessibilityLabel("FT8 transmit cycle parity")

                        Toggle("TX Armed", isOn: $vm.isTxArmed)
                            .accessibilityLabel("Transmit armed")
                    }

                    HStack(spacing: 12) {
                        Button(vm.isCQRunning ? "Stop CQ" : "CQ") {
                            if vm.isCQRunning {
                                stopCQ()
                            } else {
                                startCQ()
                            }
                        }
                        .disabled(!vm.isFT8Running)
                        .accessibilityLabel(vm.isCQRunning ? "Stop CQ" : "CQ")

                        if let next = vm.nextCQTxAt {
                            Text("Next: \(next.formatted(date: .omitted, time: .standard))")
                                .font(.system(.body, design: .monospaced))
                        } else {
                            Text("Next: (not scheduled)")
                                .font(.system(.body, design: .monospaced))
                        }
                    }

                    Text("CQ message: CQ \(myCallsign.uppercased()) \(myGrid.uppercased())")
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("CQ message CQ \(myCallsign.uppercased()) \(myGrid.uppercased())")

                    Text("Last TX: \(vm.lastTxSummary)")
                        .font(.footnote)
                        .accessibilityLabel("Last FT8 transmit status \(vm.lastTxSummary)")

                    Text("Note: This build only keys a generated test tone when TX is armed. Real FT8 waveform generation is next.")
                        .font(.footnote)

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reception (FT8 RX Capture + Decode)")
                            .font(.headline)

                        Toggle("Enable RX capture (from LAN audio)", isOn: $vm.isRxCaptureEnabled)
                            .accessibilityLabel("Enable FT8 receive capture")

                        HStack(spacing: 12) {
                            Button("Select WSJT-X decoder (jt9)…") {
                                vm.selectJT9DecoderBinary()
                            }
                            Text(vm.jt9DecoderPathLabel)
                                .font(.footnote)
                                .textSelection(.enabled)
                        }

                        Toggle("Auto-decode every 15 seconds (WSJT-X)", isOn: Binding(
                            get: { vm.isAutoDecodeEnabled },
                            set: { vm.setAutoDecodeEnabled($0, myCall: myCallsign, myGrid: myGrid) }
                        ))
                        .disabled(!vm.isRxCaptureEnabled)
                        .accessibilityLabel("Enable automatic FT8 decoding")

                        Toggle("Verbose FT8 logging (advanced)", isOn: $vm.verboseFT8Logging)
                            .accessibilityLabel("Verbose FT8 logging")

                        Text("RX level: \(String(format: "%.1f", vm.rxLevelDbFS)) dBFS, buffered: \(String(format: "%.1f", vm.rxBufferedSeconds)) s")
                            .font(.system(.body, design: .monospaced))
                            .accessibilityLabel("FT8 receive level and buffer status")

                        HStack(spacing: 12) {
                            Button("Save last full 15s slot (WAV)") {
                                vm.saveLastFull15SecondSlotToWav()
                            }
                            .disabled(!vm.isRxCaptureEnabled)

                            Button(vm.isDecoding ? "Decoding..." : "Decode last slot (WSJT-X)") {
                                vm.decodeMostRecentSlotWithWSJTX(myCall: myCallsign, myGrid: myGrid)
                            }
                            .disabled(!vm.isRxCaptureEnabled || vm.isDecoding)
                        }

                        if !vm.lastSavedWavPath.isEmpty {
                            Text("Last WAV: \(vm.lastSavedWavPath)")
                                .font(.footnote)
                                .textSelection(.enabled)
                        }
                        if !vm.lastDecodeSummary.isEmpty {
                            Text("Decode: \(vm.lastDecodeSummary)")
                                .font(.footnote)
                        }

                        Text("Note: Decode uses your local WSJT-X jt9 binary if present. The app does not bundle WSJT-X.")
                            .font(.footnote)
                    }

                    Divider()

                    Text("Auto-Answer / Auto-Respond (Scaffold)")
                        .font(.headline)

                    Toggle("Auto-reply to directed calls (CALLER MYCALL ...)", isOn: $vm.isAutoReplyEnabled)
                        .accessibilityValue(vm.isAutoReplyEnabled ? "On" : "Off")

                    Text("This is text-level logic only right now; FT8 decode/encode and timed TX are not implemented yet.")
                        .font(.footnote)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Decoded Messages")
                            .font(.headline)
                        Text("Callsigns are clickable: click the caller to auto-fill your reply.")
                            .font(.footnote)

                        Toggle("Hold live list updates (VoiceOver)", isOn: Binding(
                            get: { vm.holdDecodedListUpdates },
                            set: { vm.setHoldDecodedListUpdates($0) }
                        ))
                        .accessibilityLabel("Hold live decoded list updates")

                        HStack(spacing: 12) {
                            Button("Load queued decodes (\(vm.pendingDecodedMessagesCount))") {
                                vm.flushPendingDecodedMessages()
                            }
                            .disabled(vm.pendingDecodedMessagesCount == 0)
                            .accessibilityLabel("Load queued decoded messages")

                            Button("Clear decoded list") {
                                vm.clearDecodedMessages()
                            }
                            .disabled(vm.decodedMessages.isEmpty && vm.pendingDecodedMessagesCount == 0)
                            .accessibilityLabel("Clear decoded message list")
                        }

                        if vm.decodedMessages.isEmpty {
                            Text("No decoded messages yet.")
                                .font(.footnote)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(vm.decodedMessages.prefix(12)) { msg in
                                    HStack(spacing: 12) {
                                        Button(msg.caller) {
                                            vm.fillReply(for: msg, myCall: myCallsign, myGrid: myGrid)
                                        }
                                        .buttonStyle(.link)
                                        .accessibilityLabel("Callsign \(msg.caller)")

                                        Text(msg.to)
                                            .font(.system(.body, design: .monospaced))
                                            .accessibilityLabel("To \(msg.to)")

                                        Text(msg.payload.isEmpty ? "(no payload)" : msg.payload)
                                            .font(.system(.body, design: .monospaced))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .accessibilityLabel("Message \(msg.payload.isEmpty ? "no payload" : msg.payload)")

                                        if msg.isDirectedToMe {
                                            Text("to me")
                                                .font(.footnote)
                                                .accessibilityHidden(true)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("TX Message")
                            .font(.headline)
                        TextField("Transmit text (planned)", text: $vm.txText)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Transmit message text")
                        Text("When you click a callsign above, this field fills automatically.")
                            .font(.footnote)
                    }

                    HStack(spacing: 12) {
                        TextField("Simulate a decoded FT8 line (example: K1ABC \(myCallsign.uppercased()) -10)", text: $vm.simulateDecodedText)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 520)
                            .accessibilityLabel("Simulate decoded FT8 line")
                            .onSubmit {
                                vm.processDecodedLine(vm.simulateDecodedText, myCall: myCallsign, myGrid: myGrid)
                            }

                        Button("Process") {
                            vm.processDecodedLine(vm.simulateDecodedText, myCall: myCallsign, myGrid: myGrid)
                        }
                    }

                    if !vm.plannedTxText.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Planned TX:")
                                .font(.headline)
                            Text(vm.plannedTxText)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .accessibilityLabel("Planned transmit message \(vm.plannedTxText)")
                            Text("Next step: we’ll generate the FT8 waveform from this and transmit via LAN mic frames.")
                                .font(.footnote)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Show FT8 Activity Log (advanced)", isOn: $showFT8ActivityLog)
                        .accessibilityLabel("Show FT8 activity log")
                    if showFT8ActivityLog {
                        if vm.activityLog.isEmpty {
                            Text("No FT8 activity yet.")
                                .font(.footnote)
                        } else {
                            Text(vm.activityLog.suffix(120).joined(separator: "\n"))
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityLabel("FT8 activity log")
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Audio Path (For Future FT8)")
                        .font(.headline)
                    Text("RX can come from LAN RX audio. TX will be sent over the existing LAN mic/VoIP transmit path.")
                        .font(.footnote)
                    Text("LAN RX running: \(radio.isLanAudioRunning ? "Yes" : "No")")
                        .font(.system(.body, design: .monospaced))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .sheet(isPresented: $showStationProfile) {
            FT8StationProfileSheet(
                myCallsign: $myCallsign,
                myGrid: $myGrid,
                myLocation: $myLocation,
                isPresented: $showStationProfile
            )
        }
        .onAppear {
            _ = vm.autoConfigureJT9DecoderIfNeeded(logToActivity: false)
            if myCallsign.isEmpty || myGrid.isEmpty {
                // Don't force modal, but make it easy to fill in.
                vm.appendLog("Tip: set your callsign/grid in Station Profile for auto-reply.")
            }
            // Tap LAN RX audio for FT8 reception/capture.
            // The vm internally gates on isRxCaptureEnabled to avoid extra work.
            radio.onLanRxAudio48kMono = { [weak vm] frame in
                vm?.ingestRx48kMono(frame)
            }
            AppFileLogger.shared.log("FT8: installed RX audio tap")
        }
        .onDisappear {
            // Best-effort: avoid leaving a stale tap installed.
            radio.onLanRxAudio48kMono = nil
            AppFileLogger.shared.log("FT8: removed RX audio tap")
        }
    }

    private var selectedFrequencyHz: Int {
        let trimmed = frequencyOverrideMHz.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let mhz = Double(trimmed) {
            return Int((mhz * 1_000_000.0).rounded())
        }
        return presets.first(where: { $0.id == selectedPresetID })?.frequencyHz ?? 14_074_000
    }

    private func dialFrequencyLabelHz(_ hz: Int) -> String {
        String(format: "%.6f MHz", Double(hz) / 1_000_000.0)
    }

    private func startFT8() {
        let hz = selectedFrequencyHz

        // Snapshot what we know now (best-effort). If values are unknown,
        // we won't try to restore them.
        vm.preFT8FrequencyHz = radio.vfoAFrequencyHz
        vm.preFT8Mode = radio.operatingMode
        vm.preFT8DataModeEnabled = radio.dataModeEnabled
        vm.preFT8MDMode = radio.mdMode
        vm.preFT8Summary = [
            vm.preFT8FrequencyHz != nil ? "freq=\(dialFrequencyLabelHz(vm.preFT8FrequencyHz!))" : nil,
            vm.preFT8Mode != nil ? "mode=\(vm.preFT8Mode!.label)" : nil,
            vm.preFT8MDMode != nil ? "md=\(vm.preFT8MDMode!)" : nil
        ].compactMap { $0 }.joined(separator: ", ")

        vm.isFT8Running = true
        vm.appendLog("FT8 start: tuning to \(dialFrequencyLabelHz(hz))")
        AppFileLogger.shared.log("FT8: start hz=\(hz) preset=\(selectedPresetID)")
        if !vm.isRxCaptureEnabled {
            vm.isRxCaptureEnabled = true
            vm.appendLog("FT8 start: RX capture enabled automatically")
            AppFileLogger.shared.log("FT8: RX capture auto-enabled")
        }
        if vm.autoConfigureJT9DecoderIfNeeded(logToActivity: true) {
            vm.setAutoDecodeEnabled(true, myCall: myCallsign, myGrid: myGrid)
            vm.appendLog("FT8 start: auto-decode enabled automatically")
            AppFileLogger.shared.log("FT8: auto-decode auto-enabled")
        }

        // Set dial frequency and mode.
        radio.send(KenwoodCAT.setVFOAFrequencyHz(hz))
        if forceUSB {
            radio.send(KenwoodCAT.setOperatingMode(.usb))
        }
        if forceDataMode {
            // TS-890 appears to use MD for USB-DATA (DA is rejected by the radio).
            radio.send(KenwoodCAT.setModeMD(2))
            radio.send(KenwoodCAT.getModeMD())
        }

        // Start LAN RX audio if requested (best-effort: uses last host).
        if ensureLanAudio, !radio.isLanAudioRunning {
            let host = UserDefaults.standard.string(forKey: "LastConnectedHost")
                ?? KNSSettings.loadLastHost()
                ?? "192.168.50.56"
            vm.appendLog("FT8 start: ensuring LAN audio on host \(host)")
            AppFileLogger.shared.log("FT8: ensure LAN audio host=\(host)")
            radio.startLanAudio(host: host)
        }
    }

    private func stopFT8() {
        stopCQ()
        vm.appendLog("FT8 stop: restoring pre-FT8 rig state (best-effort)")
        AppFileLogger.shared.log("FT8: stop restore")

        if let hz = vm.preFT8FrequencyHz {
            vm.appendLog("Restore: VFO A \(dialFrequencyLabelHz(hz))")
            AppFileLogger.shared.log("FT8: restore FA hz=\(hz)")
            radio.send(KenwoodCAT.setVFOAFrequencyHz(hz))
        }
        if let mode = vm.preFT8Mode {
            vm.appendLog("Restore: mode \(mode.label)")
            AppFileLogger.shared.log("FT8: restore OM \(mode.label)")
            radio.send(KenwoodCAT.setOperatingMode(mode))
            radio.send(KenwoodCAT.getOperatingMode())
        }
        if let md = vm.preFT8MDMode {
            vm.appendLog("Restore: MD \(md)")
            AppFileLogger.shared.log("FT8: restore MD \(md)")
            radio.send(KenwoodCAT.setModeMD(md))
            radio.send(KenwoodCAT.getModeMD())
        }

        if vm.isAutoDecodeEnabled {
            vm.setAutoDecodeEnabled(false, myCall: myCallsign, myGrid: myGrid)
            AppFileLogger.shared.log("FT8: auto-decode auto-disabled on stop")
        }
        if vm.isRxCaptureEnabled {
            vm.isRxCaptureEnabled = false
            vm.appendLog("FT8 stop: RX capture disabled")
            AppFileLogger.shared.log("FT8: RX capture auto-disabled on stop")
        }

        vm.lastTxSummary = "FT8 stopped; TX idle."
        vm.isFT8Running = false
    }

    private func startCQ() {
        let call = myCallsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let grid = myGrid.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !call.isEmpty, !grid.isEmpty else {
            vm.appendLog("CQ start blocked: set callsign + grid in Station Profile.")
            AppFileLogger.shared.log("FT8: CQ start blocked (missing callsign/grid)")
            return
        }
        guard vm.isFT8Running else { return }
        vm.isCQRunning = true
        vm.appendLog("CQ loop started parity=\(vm.cqParityRaw) txArmed=\(vm.isTxArmed)")
        AppFileLogger.shared.log("FT8: CQ start parity=\(vm.cqParityRaw) txArmed=\(vm.isTxArmed)")
        scheduleNextCQTick()
    }

    private func stopCQ() {
        vm.isCQRunning = false
        vm.nextCQTxAt = nil
        vm.appendLog("CQ loop stopped")
        vm.lastTxSummary = "CQ stopped; TX idle."
        AppFileLogger.shared.log("FT8: CQ stop")
    }

    private func scheduleNextCQTick() {
        guard vm.isCQRunning else { return }
        let parity = FT8ViewModel.CQParity(rawValue: vm.cqParityRaw) ?? .even

        let now = Date()
        let nowSec = Int(now.timeIntervalSince1970)
        var t = nowSec - (nowSec % 15) + 15 // next 15s boundary
        while true {
            let slot = (t % 60) / 15 // 0,1,2,3
            let isEven = (slot % 2) == 0
            if (parity == .even && isEven) || (parity == .odd && !isEven) { break }
            t += 15
        }

        let next = Date(timeIntervalSince1970: TimeInterval(t))
        vm.nextCQTxAt = next

        // Fire once at the next matching boundary; reschedule after each tick.
        let dt = max(0.01, next.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + dt) {
            guard vm.isCQRunning else { return }
            cqTick(at: next)
            scheduleNextCQTick()
        }
    }

    private func cqTick(at when: Date) {
        let call = myCallsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let grid = myGrid.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let msg = "CQ \(call) \(grid)"
        vm.txText = msg
        vm.plannedTxText = msg
        vm.appendLog("CQ tick @\(when.formatted(date: .omitted, time: .standard)): \(msg)")
        vm.lastTxSummary = "CQ queued: \(msg)"
        AppFileLogger.shared.log("FT8: CQ tick \(msg)")

        guard vm.isTxArmed else {
            vm.appendLog("TX not armed: no RF transmission")
            vm.lastTxSummary = "Not transmitted: TX not armed."
            AppFileLogger.shared.log("FT8: CQ tick skipped (TX not armed)")
            return
        }

        // Placeholder until we implement real FT8 waveform generation.
        // Test tone is generated and sent via the LAN mic/VoIP TX path, not from the selected microphone.
        AppFileLogger.shared.log("FT8: TX placeholder test tone")
        vm.lastTxSummary = "Transmitted placeholder 1500 Hz tone (12.6 s) for \(msg)"
        radio.transmitGeneratedTestTone(toneHz: 1500, durationSeconds: 12.6, amplitude: 0.15)
    }
}

private struct FT8StationProfileSheet: View {
    @Binding var myCallsign: String
    @Binding var myGrid: String
    @Binding var myLocation: String
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("FT8 Station Profile")
                .font(.title2)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text("Callsign:")
                        .frame(width: 90, alignment: .leading)
                    TextField("e.g. W9XYZ", text: $myCallsign)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 240)
                        .accessibilityLabel("Callsign")
                }

                HStack(spacing: 12) {
                    Text("Grid:")
                        .frame(width: 90, alignment: .leading)
                    TextField("e.g. EN50", text: $myGrid)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 240)
                        .accessibilityLabel("Grid square")
                }

                HStack(spacing: 12) {
                    Text("Location:")
                        .frame(width: 90, alignment: .leading)
                    TextField("City, State (optional)", text: $myLocation)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 360)
                        .accessibilityLabel("Location")
                }

                Text("These values are saved on this Mac.")
                    .font(.footnote)
            }

            HStack(spacing: 12) {
                Button("Close") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 520)
    }
}
