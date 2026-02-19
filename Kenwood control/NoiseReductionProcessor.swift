import Foundation

protocol NoiseReductionProcessor: AnyObject {
    var isAvailable: Bool { get }
    var isEnabled: Bool { get set }

    /// Process a single 48 kHz mono frame. Frame length must match the engine's frame size.
    func processFrame48kMono(_ frame: [Float]) -> [Float]

    /// Process a single 48 kHz mono frame in place.
    func processFrame48kMonoInPlace(_ frame: inout [Float])
}

extension NoiseReductionProcessor {
    func processFrame48kMonoInPlace(_ frame: inout [Float]) {
        frame = processFrame48kMono(frame)
    }
}

/// Transparent pass-through — reports unavailable so the UI correctly disables the NR toggle.
final class PassthroughNoiseReduction: NoiseReductionProcessor {
    var isAvailable: Bool { false }
    var isEnabled: Bool = false

    func processFrame48kMono(_ frame: [Float]) -> [Float] { frame }

    func processFrame48kMonoInPlace(_ frame: inout [Float]) { /* no-op */ }
}

/// Proxy that forwards all calls to a swappable inner processor.
/// Passing this proxy to LanAudioPipeline means backend switches take effect
/// immediately without restarting the pipeline.
final class NoiseReductionProcessorProxy: NoiseReductionProcessor {
    var inner: any NoiseReductionProcessor

    init(inner: any NoiseReductionProcessor) { self.inner = inner }

    var isAvailable: Bool { inner.isAvailable }
    var isEnabled: Bool {
        get { inner.isEnabled }
        set { inner.isEnabled = newValue }
    }

    func processFrame48kMono(_ frame: [Float]) -> [Float] {
        inner.processFrame48kMono(frame)
    }

    func processFrame48kMonoInPlace(_ frame: inout [Float]) {
        inner.processFrame48kMonoInPlace(&frame)
    }
}
