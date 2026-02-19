import Foundation

/// Receives 48 kHz mono float, frames to RNNoise-sized chunks, processes, and emits.
final class LanAudioPipeline {
    private let processor: any NoiseReductionProcessor
    private let frameSize: Int
    private var buffer: [Float] = []

    var wetDry: Float = 1.0

    init(processor: any NoiseReductionProcessor, frameSize: Int = 480) {
        self.processor = processor
        self.frameSize = frameSize
        buffer.reserveCapacity(frameSize * 4)
    }

    func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    func process48kMono(_ samples: [Float], onOutput: ([Float]) -> Void) {
        guard !samples.isEmpty else { return }
        buffer.append(contentsOf: samples)

        while buffer.count >= frameSize {
            var frame = Array(buffer.prefix(frameSize))
            buffer.removeFirst(frameSize)

            let dry = frame
            processor.processFrame48kMonoInPlace(&frame)

            let mix = wetDry
            if mix < 1 {
                let inv = 1 - mix
                for i in 0..<frameSize {
                    frame[i] = dry[i] * inv + frame[i] * mix
                }
            }
            onOutput(frame)
        }
    }
}

