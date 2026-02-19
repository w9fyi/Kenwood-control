import Foundation

// In-process RNNoise integration.
//
// We prefer linking the RNNoise C sources (BSD-3) directly into the app:
// ThirdParty/rnnoise/src/*.c and ThirdParty/rnnoise/src/rnnoise.h
//
// The RNNoise C API expects 48 kHz mono float frames in "int16-like" amplitude units,
// so we scale [-1, 1] floats up/down by 32768 when calling rnnoise_process_frame.

#if RNNOISE_C

final class RNNoiseProcessor: NoiseReductionProcessor {
    private var state: OpaquePointer?
    private let frameSize: Int
    private var inScaled: [Float]
    private var outScaled: [Float]

    var isAvailable: Bool { state != nil }
    var isEnabled: Bool = false
    var backendDescription: String { "RNNoise (in-process C, frame=\(frameSize))" }

    init?() {
        let sz = Int(rnnoise_get_frame_size())
        guard sz > 0 else {
            AppFileLogger.shared.log("RNNoise C: rnnoise_get_frame_size() returned \(sz) (init failed)")
            return nil
        }
        frameSize = sz
        inScaled = Array(repeating: 0, count: frameSize)
        outScaled = Array(repeating: 0, count: frameSize)

        state = rnnoise_create(nil)
        if state == nil {
            AppFileLogger.shared.log("RNNoise C: rnnoise_create(nil) returned nil (init failed)")
            return nil
        }
        AppFileLogger.shared.log("RNNoise C: initialized ok frameSize=\(frameSize)")
    }

    deinit {
        if let state {
            rnnoise_destroy(state)
        }
        state = nil
    }

    func processFrame48kMono(_ frame: [Float]) -> [Float] {
        var out = frame
        processFrame48kMonoInPlace(&out)
        return out
    }

    func processFrame48kMonoInPlace(_ frame: inout [Float]) {
        guard isEnabled, let state else { return }
        guard frame.count == frameSize else { return }

        // Scale [-1, 1] float audio to RNNoise's expected float units (int16-like).
        for i in 0..<frameSize {
            inScaled[i] = frame[i] * 32768.0
        }

        // Process.
        inScaled.withUnsafeBufferPointer { inBuf in
            outScaled.withUnsafeMutableBufferPointer { outBuf in
                guard let inBase = inBuf.baseAddress, let outBase = outBuf.baseAddress else { return }
                _ = rnnoise_process_frame(state, outBase, inBase)
            }
        }

        // Scale back to [-1, 1].
        for i in 0..<frameSize {
            frame[i] = outScaled[i] / 32768.0
        }
    }
}

#else

// Build without RNNoise sources present.
final class RNNoiseProcessor: NoiseReductionProcessor {
    var isAvailable: Bool { false }
    var isEnabled: Bool = false
    var backendDescription: String { "RNNoise (in-process C not built)" }

    init?() { return nil }

    func processFrame48kMono(_ frame: [Float]) -> [Float] { frame }

    func processFrame48kMonoInPlace(_ frame: inout [Float]) { /* no-op */ }
}

#endif
