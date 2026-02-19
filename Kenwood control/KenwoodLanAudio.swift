import Foundation
import Darwin

struct RTPHeader {
    let payloadType: UInt8
    let sequenceNumber: UInt16
    let timestamp: UInt32
    let ssrc: UInt32
    let headerLength: Int

    static func parse(_ bytes: UnsafePointer<UInt8>, count: Int) -> RTPHeader? {
        guard count >= 12 else { return nil }
        let b0 = bytes[0]
        let b1 = bytes[1]
        let version = b0 >> 6
        guard version == 2 else { return nil }

        let padding = (b0 & 0x20) != 0
        let ext = (b0 & 0x10) != 0
        let cc = Int(b0 & 0x0F)

        let payloadType = b1 & 0x7F
        let seq = (UInt16(bytes[2]) << 8) | UInt16(bytes[3])
        let ts = (UInt32(bytes[4]) << 24) | (UInt32(bytes[5]) << 16) | (UInt32(bytes[6]) << 8) | UInt32(bytes[7])
        let ssrc = (UInt32(bytes[8]) << 24) | (UInt32(bytes[9]) << 16) | (UInt32(bytes[10]) << 8) | UInt32(bytes[11])

        var headerLen = 12 + 4 * cc
        if count < headerLen { return nil }

        if ext {
            // Header extension: 16-bit profile + 16-bit length (in 32-bit words), followed by extension data.
            if count < headerLen + 4 { return nil }
            let extLenWords = (UInt16(bytes[headerLen + 2]) << 8) | UInt16(bytes[headerLen + 3])
            headerLen += 4 + Int(extLenWords) * 4
            if count < headerLen { return nil }
        }

        if padding {
            // We handle padding at payload extraction time; keep headerLen here.
        }

        return RTPHeader(payloadType: payloadType, sequenceNumber: seq, timestamp: ts, ssrc: ssrc, headerLength: headerLen)
    }
}

final class KenwoodLanAudioReceiver {
    enum ReceiverError: LocalizedError {
        case invalidHost
        case socketFailed(String)
        case bindFailed(String)
        case nonBlockingFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidHost:
                return "Invalid host/IP address"
            case .socketFailed(let s), .bindFailed(let s), .nonBlockingFailed(let s):
                return s
            }
        }
    }

    var onLog: ((String) -> Void)?
    var onError: ((String) -> Void)?

    // Output is always 48 kHz mono float.
    var onAudio48kMono: (([Float]) -> Void)?
    // Per-packet diagnostics (seq/ssrc/payload bytes).
    var onPacket: ((UInt16, UInt32, Int) -> Void)?

    private let queue = DispatchQueue(label: "KenwoodLanAudioReceiver.queue")
    private var readSource: DispatchSourceRead?
    private var fd: Int32 = -1

    private var expectedHostAddr: in_addr?
    private var expectedHostPort: UInt16 = 60001
    private var destAddr: sockaddr_in?

    // TX (microphone) state. TS-Control captures show PC->radio UDP comes from port 60001 with RTP PT=96,
    // timestamp=0, and SSRC="890\0".
    private var txSeq: UInt16 = 0
    private let txSSRC: UInt32 = 0x38393000 // "890\0"
    private var txPacketCount: Int = 0

    private var pendingSample: Float?
    private var lastSeq: UInt16?

    func start(host: String, port: UInt16 = 60001) throws {
        stop()

        var addr = in_addr()
        if inet_pton(AF_INET, host, &addr) != 1 {
            throw ReceiverError.invalidHost
        }
        expectedHostAddr = addr
        expectedHostPort = port
        txSeq = UInt16.random(in: 0...UInt16.max)
        txPacketCount = 0
        destAddr = {
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_port = port.bigEndian
            sin.sin_addr = addr
            return sin
        }()

        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if fd < 0 { throw ReceiverError.socketFailed("socket() failed: \(String(cString: strerror(errno)))") }

        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = port.bigEndian
        sin.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

        let bindStatus: Int32 = withUnsafePointer(to: &sin) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindStatus != 0 {
            let e = errno
            let msg = (e == EADDRINUSE)
                ? "UDP port \(port) is already in use (close TS-Control and retry)."
                : "bind() failed: \(String(cString: strerror(e)))"
            throw ReceiverError.bindFailed(msg)
        }

        let flags = fcntl(fd, F_GETFL)
        if flags < 0 { throw ReceiverError.nonBlockingFailed("fcntl(F_GETFL) failed: \(String(cString: strerror(errno)))") }
        if fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 {
            throw ReceiverError.nonBlockingFailed("fcntl(F_SETFL) failed: \(String(cString: strerror(errno)))")
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drain()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fd >= 0 { close(self.fd) }
            self.fd = -1
        }
        readSource = source
        source.resume()

        pendingSample = nil
        lastSeq = nil
        onLog?("LAN audio receiver started on UDP \(port) for host \(host)")
        // Some implementations only start sending audio after they observe inbound UDP from the client.
        // Send a small "probe" datagram from our bound socket so the radio can learn/confirm our endpoint.
        sendProbe()
    }

    func stop() {
        // Cancel the dispatch source first so no more read events fire.
        readSource?.cancel()
        readSource = nil
        // Close the file descriptor synchronously so the OS releases the port
        // immediately, before the dispatch source's async cancel handler runs.
        // The cancel handler already guards with `if self.fd >= 0`, so it will
        // skip the double-close when it eventually fires.
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        expectedHostAddr = nil
        destAddr = nil
        pendingSample = nil
        lastSeq = nil
    }

    /// Send one 20 ms microphone frame (16 kHz mono PCM16, 320 samples) to the radio.
    /// Uses the same bound socket as the receiver, so the source port is 60001.
    func sendMicFramePCM16(_ samples: UnsafePointer<Int16>, count: Int) {
        guard count == 320 else { return }
        guard fd >= 0, var destAddr else { return }

        var packet = [UInt8](repeating: 0, count: 12 + 640)
        packet[0] = 0x80 // V=2
        packet[1] = 0x60 // PT=96
        packet[2] = UInt8((txSeq >> 8) & 0xFF)
        packet[3] = UInt8(txSeq & 0xFF)
        // timestamp stays 0 in observed TS-Control traffic
        packet[8] = UInt8((txSSRC >> 24) & 0xFF)
        packet[9] = UInt8((txSSRC >> 16) & 0xFF)
        packet[10] = UInt8((txSSRC >> 8) & 0xFF)
        packet[11] = UInt8(txSSRC & 0xFF)

        for i in 0..<320 {
            let v = UInt16(bitPattern: samples[i])
            packet[12 + i * 2] = UInt8(v & 0xFF)
            packet[12 + i * 2 + 1] = UInt8((v >> 8) & 0xFF)
        }

        let sent: Int = packet.withUnsafeBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return withUnsafePointer(to: &destAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, base, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 {
            onError?("Mic send failed: \(String(cString: strerror(errno)))")
        }
        txPacketCount += 1
        if txPacketCount == 1 {
            onLog?("LAN mic: first frame sent seq=\(txSeq)")
        }
        txSeq &+= 1
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var from = sockaddr_in()
            var fromLen: socklen_t = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n: Int = buffer.withUnsafeMutableBytes { raw in
                let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                return withUnsafeMutablePointer(to: &from) { fromPtr in
                    fromPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(fd, base, raw.count, 0, sa, &fromLen)
                    }
                }
            }

            if n < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN { break }
                onError?("recvfrom() failed: \(String(cString: strerror(errno)))")
                break
            }
            if n == 0 { break }

            if let expectedHostAddr, from.sin_addr.s_addr != expectedHostAddr.s_addr {
                // Ignore stray packets.
                continue
            }

            handlePacket(buffer, count: n)
        }
    }

    private func handlePacket(_ bytes: [UInt8], count: Int) {
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            guard let hdr = RTPHeader.parse(base, count: count) else { return }
            // We expect dynamic PT 96 in observed captures; don't hard-fail on mismatch.

            let payloadStart = hdr.headerLength
            var payloadEnd = count

            let padding = (base[0] & 0x20) != 0
            if padding, payloadEnd > payloadStart {
                let padLen = Int(base[payloadEnd - 1])
                if padLen > 0, payloadEnd - padLen >= payloadStart {
                    payloadEnd -= padLen
                }
            }

            let payloadLen = payloadEnd - payloadStart
            // Observed: 640 bytes of PCM16 in 20 ms frames (16 kHz * 0.02 s * 2 bytes = 640).
            guard payloadLen >= 640 else { return }

            onPacket?(hdr.sequenceNumber, hdr.ssrc, payloadLen)

            // Packet loss concealment: if seq jumps, insert silence for each missing packet.
            if let lastSeq {
                let expected = lastSeq &+ 1
                if hdr.sequenceNumber != expected {
                    let delta = Int(hdr.sequenceNumber &- expected)
                    // Clamp to avoid runaway on wrap/large jumps.
                    let missing = max(0, min(delta, 10))
                    if missing > 0 {
                        // Each missing packet is ~20 ms => ~960 samples at 48k after upsample.
                        for _ in 0..<missing {
                            onAudio48kMono?(Array(repeating: 0, count: 960))
                        }
                    }
                }
            }
            lastSeq = hdr.sequenceNumber

            // Decode little-endian signed 16-bit PCM -> float [-1, 1]
            let sampleCount16k = 320
            var samples16k = [Float](repeating: 0, count: sampleCount16k)
            for i in 0..<sampleCount16k {
                let lo = UInt16(base[payloadStart + i * 2])
                let hi = UInt16(base[payloadStart + i * 2 + 1]) << 8
                let u = lo | hi
                let s = Int16(bitPattern: u)
                samples16k[i] = Float(s) / 32768.0
            }

            // Upsample 16 kHz -> 48 kHz (factor 3) with linear interpolation between samples.
            // We intentionally hold one sample between calls so the steady-state output is 960 samples/packet.
            var out48k: [Float] = []
            out48k.reserveCapacity(960)

            if let pending = pendingSample, let first = samples16k.first {
                appendUpsampleTriplet(from: pending, to: first, into: &out48k)
            }
            if samples16k.count >= 2 {
                for i in 0..<(samples16k.count - 1) {
                    appendUpsampleTriplet(from: samples16k[i], to: samples16k[i + 1], into: &out48k)
                }
            }
            pendingSample = samples16k.last

            if !out48k.isEmpty {
                onAudio48kMono?(out48k)
            }
        }
    }

    private func appendUpsampleTriplet(from a: Float, to b: Float, into out: inout [Float]) {
        out.append(a)
        let d = b - a
        out.append(a + d / 3.0)
        out.append(a + 2.0 * d / 3.0)
    }

    private func sendProbe() {
        guard fd >= 0, var sin = destAddr else { return }

        // Send one RTP-like silent frame matching the observed stream shape:
        // 12-byte header + 640 bytes PCM16 payload = 652 bytes (UDP length usually 660).
        var payload = [UInt8](repeating: 0, count: 12 + 640)
        payload[0] = 0x80 // V=2, no padding/ext, CC=0
        payload[1] = 0x60 // M=0, PT=96
        // seq (2 bytes), timestamp (4 bytes) left as 0
        // ssrc: match TS-Control ("890\0")
        payload[8] = UInt8((txSSRC >> 24) & 0xFF)
        payload[9] = UInt8((txSSRC >> 16) & 0xFF)
        payload[10] = UInt8((txSSRC >> 8) & 0xFF)
        payload[11] = UInt8(txSSRC & 0xFF)

        let sent: Int = payload.withUnsafeBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return withUnsafePointer(to: &sin) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, base, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent >= 0 {
            onLog?("LAN audio probe sent (\(sent) bytes)")
        } else {
            onLog?("LAN audio probe failed: \(String(cString: strerror(errno)))")
        }
    }
}
