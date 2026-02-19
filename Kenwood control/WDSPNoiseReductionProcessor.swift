import Foundation

enum WDSPMode {
    case emnr  // Enhanced Minimum NR: Wiener filter + psychoacoustic artifact elimination
    case anr   // Adaptive NR: LMS adaptive filter (good for periodic tones/carriers)
}

final class WDSPNoiseReductionProcessor: NoiseReductionProcessor {
    // WDSP_EMNR / WDSP_ANR are opaque C structs (forward-declared only),
    // so Swift imports them as OpaquePointer, not UnsafeMutablePointer<T>.
    private var emnrCtx: OpaquePointer?
    private var anrCtx:  OpaquePointer?
    private(set) var mode: WDSPMode

    var isAvailable: Bool { emnrCtx != nil || anrCtx != nil }
    var isEnabled: Bool = false

    init?(mode: WDSPMode = .emnr, sampleRate: Int32 = 48000) {
        self.mode = mode
        switch mode {
        case .emnr:
            guard let ctx = wdsp_emnr_create(sampleRate) else {
                AppFileLogger.shared.log("WDSP EMNR: create failed (FFTW not available?)")
                return nil
            }
            emnrCtx = ctx
        case .anr:
            guard let ctx = wdsp_anr_create(sampleRate) else {
                AppFileLogger.shared.log("WDSP ANR: create failed")
                return nil
            }
            anrCtx = ctx
        }
        AppFileLogger.shared.log("WDSP \(mode == .emnr ? "EMNR" : "ANR"): initialized at \(sampleRate) Hz")
    }

    deinit {
        if let c = emnrCtx { wdsp_emnr_destroy(c) }
        if let c = anrCtx  { wdsp_anr_destroy(c) }
    }

    func processFrame48kMono(_ frame: [Float]) -> [Float] {
        var out = frame
        processFrame48kMonoInPlace(&out)
        return out
    }

    func processFrame48kMonoInPlace(_ frame: inout [Float]) {
        guard isEnabled else { return }
        frame.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            let count = Int32(buf.count)
            switch mode {
            case .emnr:
                if let c = emnrCtx { wdsp_emnr_process(c, base, count) }
            case .anr:
                if let c = anrCtx  { wdsp_anr_process(c, base, count) }
            }
        }
    }
}
