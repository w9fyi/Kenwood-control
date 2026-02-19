import Foundation

final class AudioFrameBuffer {
    private var buffer: [Float] = []
    private let frameSize: Int

    init(frameSize: Int) {
        self.frameSize = frameSize
        buffer.reserveCapacity(frameSize * 2)
    }

    func append(_ samples: [Float], onFrame: ([Float]) -> Void) {
        guard !samples.isEmpty else { return }
        buffer.append(contentsOf: samples)

        while buffer.count >= frameSize {
            let frame = Array(buffer.prefix(frameSize))
            buffer.removeFirst(frameSize)
            onFrame(frame)
        }
    }

    func reset() { buffer.removeAll(keepingCapacity: true) }
}

final class NoiseReductionPipeline {
    private let processor: any NoiseReductionProcessor
    private let frameBuffer: AudioFrameBuffer

    init(processor: any NoiseReductionProcessor, frameSize: Int) {
        self.processor = processor
        self.frameBuffer = AudioFrameBuffer(frameSize: frameSize)
    }

    /// Accepts 48 kHz mono float samples and returns denoised output frames.
    func process(samples: [Float], onOutput: ([Float]) -> Void) {
        frameBuffer.append(samples) { [processor] frame in
            let processed = processor.processFrame48kMono(frame)
            onOutput(processed)
        }
    }

    func reset() { frameBuffer.reset() }
}
