import Foundation
import AVFoundation
import Darwin

/// Captures the default microphone and streams 16 kHz mono PCM16 frames to the radio over UDP 60001
/// using the same RTP-like framing observed for RX audio (12-byte header + 640-byte payload).
final class KenwoodLanMicTransmitter {
    enum TxError: LocalizedError {
        case invalidHost
        case socketFailed(String)
        case audioFormat
        case converterFailed

        var errorDescription: String? {
            switch self {
            case .invalidHost: return "Invalid host/IP address"
            case .socketFailed(let s): return s
            case .audioFormat: return "Audio format unsupported"
            case .converterFailed: return "Audio converter failed"
            }
        }
    }

    var onLog: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private var fd: Int32 = -1
    private var sin = sockaddr_in()

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var seq: UInt16 = 0
    private let ssrc: UInt32 = 0x4B4E5331 // "KNS1"
    private var isRunning: Bool = false

    func start(host: String, port: UInt16 = 60001) throws {
        stop()

        var addr = in_addr()
        if inet_pton(AF_INET, host, &addr) != 1 {
            throw TxError.invalidHost
        }

        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if fd < 0 {
            throw TxError.socketFailed("socket() failed: \(String(cString: strerror(errno)))")
        }

        sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = port.bigEndian
        sin.sin_addr = addr

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw TxError.converterFailed
        }
        self.converter = converter

        // 20 ms of input audio (matches the 20 ms framing used by KNS VoIP).
        let framesPer20ms = max(1, Int((inputFormat.sampleRate * 0.02).rounded()))
        let bufferSize = AVAudioFrameCount(framesPer20ms)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
        onLog?("LAN mic transmitter started -> \(host):\(port) (input \(Int(inputFormat.sampleRate)) Hz)")
    }

    func stop() {
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        isRunning = false
        converter = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    private func handleTap(buffer: AVAudioPCMBuffer) {
        guard isRunning, fd >= 0, let converter else { return }

        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 320) else { return }

        var hadInput = false
        let status = converter.convert(to: out, error: nil) { _, outStatus in
            if hadInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            hadInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            onError?("Mic convert failed")
            return
        }

        // We want exactly 320 samples (20 ms at 16 kHz). If we get less, skip to avoid timing drift.
        if out.frameLength < 320 { return }
        guard let ch = out.int16ChannelData else { return }

        var packet = [UInt8](repeating: 0, count: 12 + 640)
        packet[0] = 0x80
        packet[1] = 0x60
        // Sequence number (big endian)
        packet[2] = UInt8((seq >> 8) & 0xFF)
        packet[3] = UInt8(seq & 0xFF)
        // Timestamp left at 0 (observed captures use 0)
        // SSRC
        packet[8] = UInt8((ssrc >> 24) & 0xFF)
        packet[9] = UInt8((ssrc >> 16) & 0xFF)
        packet[10] = UInt8((ssrc >> 8) & 0xFF)
        packet[11] = UInt8(ssrc & 0xFF)

        // Payload: little-endian PCM16.
        let src = ch[0]
        for i in 0..<320 {
            let v = UInt16(bitPattern: src[i])
            packet[12 + i * 2] = UInt8(v & 0xFF)
            packet[12 + i * 2 + 1] = UInt8((v >> 8) & 0xFF)
        }

        let sent: Int = packet.withUnsafeBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return withUnsafePointer(to: &sin) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, base, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 {
            onError?("Mic send failed: \(String(cString: strerror(errno)))")
        }

        seq &+= 1
    }
}

