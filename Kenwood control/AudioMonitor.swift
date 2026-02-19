import Foundation
import AudioToolbox
import CoreAudio

final class AudioMonitor {
    enum MonitorError: LocalizedError {
        case missingDevices
        case unsupportedSampleRate(Double)
        case audioUnitError(OSStatus, String)

        var errorDescription: String? {
            switch self {
            case .missingDevices:
                return "Missing audio devices"
            case .unsupportedSampleRate(let sr):
                return "Unsupported sample rate: \(sr). This build expects 48000 Hz."
            case .audioUnitError(let status, let context):
                return "\(context) (OSStatus=\(status))"
            }
        }
    }

    var onLog: ((String) -> Void)?
    var onError: ((String) -> Void)?

    var wetDry: Float = 1.0
    var inputGain: Float = 1.0
    var outputGain: Float = 1.0

    private let processor: any NoiseReductionProcessor
    private let sampleRate: Double = 48_000
    private let channels: UInt32 = 1
    private let frameSize: Int = 480 // RNNoise frame size at 48 kHz

    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?

    private var inputScratch: [Float] = Array(repeating: 0, count: 4096)
    private let rawFifo = AudioRingBuffer(capacitySamples: 48_000 * 2)
    private let outFifo = AudioRingBuffer(capacitySamples: 48_000 * 2)
    private let processQueue = DispatchQueue(label: "AudioMonitor.process")
    private var processTimer: DispatchSourceTimer?

    private var isRunning = false
    private var dryFrame: [Float]
    private var wetFrame: [Float]

    init(processor: any NoiseReductionProcessor) {
        self.processor = processor
        self.dryFrame = Array(repeating: 0, count: frameSize)
        self.wetFrame = Array(repeating: 0, count: frameSize)
    }

    func start(inputDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID) throws {
        stop()

        // Keep the first cut simple: require 48 kHz end-to-end so we can focus on NR quality first.
        let inputSR = AudioDeviceManager.inputDevices().first(where: { $0.id == inputDeviceID })?.nominalSampleRate
        if let inputSR, abs(inputSR - sampleRate) > 1 {
            throw MonitorError.unsupportedSampleRate(inputSR)
        }

        let outputSR: Double? = {
            // Output may not show up in inputDevices(); fetch via CoreAudio scalar property.
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var value: Double = 0
            var size = UInt32(MemoryLayout<Double>.size)
            let status = AudioObjectGetPropertyData(outputDeviceID, &address, 0, nil, &size, &value)
            return status == noErr ? value : nil
        }()
        if let outputSR, abs(outputSR - sampleRate) > 1 {
            throw MonitorError.unsupportedSampleRate(outputSR)
        }

        rawFifo.clear()
        outFifo.clear()

        inputUnit = try makeInputUnit(deviceID: inputDeviceID)
        outputUnit = try makeOutputUnit(deviceID: outputDeviceID)

        try initializeAndStartUnits()
        startProcessingLoop()

        isRunning = true
        onLog?("Audio monitor started (48 kHz mono)")
    }

    func stop() {
        isRunning = false
        stopProcessingLoop()
        stopAndDispose(&inputUnit)
        stopAndDispose(&outputUnit)
        rawFifo.clear()
        outFifo.clear()
    }

    // MARK: - AudioUnits

    private func makeInputUnit(deviceID: AudioDeviceID) throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw MonitorError.audioUnitError(-1, "AudioComponentFindNext failed (input)")
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(comp, &unit)
        guard status == noErr, let unit else { throw MonitorError.audioUnitError(status, "AudioComponentInstanceNew failed (input)") }

        // Enable input on bus 1, disable output on bus 0.
        var one: UInt32 = 1
        var zero: UInt32 = 0
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw MonitorError.audioUnitError(status, "EnableIO input failed") }
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw MonitorError.audioUnitError(status, "Disable output failed") }

        // Select device.
        var dev = deviceID
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw MonitorError.audioUnitError(status, "Set input device failed") }

        // Set stream format for data we pull from bus 1 (unit output scope).
        var asbd = makeASBD()
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { throw MonitorError.audioUnitError(status, "Set input stream format failed") }

        // Install input callback.
        var cb = AURenderCallbackStruct(
            inputProc: { refCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData in
                let monitor = Unmanaged<AudioMonitor>.fromOpaque(refCon).takeUnretainedValue()
                return monitor.handleInput(ioActionFlags: ioActionFlags, inTimeStamp: inTimeStamp, inBusNumber: inBusNumber, inNumberFrames: inNumberFrames, ioData: ioData)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { throw MonitorError.audioUnitError(status, "Set input callback failed") }

        return unit
    }

    private func makeOutputUnit(deviceID: AudioDeviceID) throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw MonitorError.audioUnitError(-1, "AudioComponentFindNext failed (output)")
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(comp, &unit)
        guard status == noErr, let unit else { throw MonitorError.audioUnitError(status, "AudioComponentInstanceNew failed (output)") }

        // Enable output on bus 0, disable input on bus 1.
        var one: UInt32 = 1
        var zero: UInt32 = 0
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw MonitorError.audioUnitError(status, "EnableIO output failed") }
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &zero, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw MonitorError.audioUnitError(status, "Disable input failed") }

        // Select device.
        var dev = deviceID
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw MonitorError.audioUnitError(status, "Set output device failed") }

        // Set stream format for data we provide to bus 0 (unit input scope).
        var asbd = makeASBD()
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { throw MonitorError.audioUnitError(status, "Set output stream format failed") }

        // Install render callback.
        var cb = AURenderCallbackStruct(
            inputProc: { refCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData in
                let monitor = Unmanaged<AudioMonitor>.fromOpaque(refCon).takeUnretainedValue()
                return monitor.handleOutput(ioActionFlags: ioActionFlags, inTimeStamp: inTimeStamp, inBusNumber: inBusNumber, inNumberFrames: inNumberFrames, ioData: ioData)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { throw MonitorError.audioUnitError(status, "Set render callback failed") }

        return unit
    }

    private func initializeAndStartUnits() throws {
        if let inputUnit {
            var status = AudioUnitInitialize(inputUnit)
            guard status == noErr else { throw MonitorError.audioUnitError(status, "AudioUnitInitialize failed (input)") }
            status = AudioOutputUnitStart(inputUnit)
            guard status == noErr else { throw MonitorError.audioUnitError(status, "AudioOutputUnitStart failed (input)") }
        }
        if let outputUnit {
            var status = AudioUnitInitialize(outputUnit)
            guard status == noErr else { throw MonitorError.audioUnitError(status, "AudioUnitInitialize failed (output)") }
            status = AudioOutputUnitStart(outputUnit)
            guard status == noErr else { throw MonitorError.audioUnitError(status, "AudioOutputUnitStart failed (output)") }
        }
    }

    private func stopAndDispose(_ unit: inout AudioUnit?) {
        guard let u = unit else { return }
        AudioOutputUnitStop(u)
        AudioUnitUninitialize(u)
        AudioComponentInstanceDispose(u)
        unit = nil
    }

    private func makeASBD() -> AudioStreamBasicDescription {
        let bytesPerSample = UInt32(MemoryLayout<Float>.size)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: bytesPerSample * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerSample * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 8 * bytesPerSample,
            mReserved: 0
        )
    }

    // MARK: - Callbacks

    private func handleInput(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?,
        inTimeStamp: UnsafePointer<AudioTimeStamp>?,
        inBusNumber: UInt32,
        inNumberFrames: UInt32,
        ioData: UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus {
        guard let inputUnit else { return noErr }
        let frames = Int(inNumberFrames)
        if frames <= 0 { return noErr }
        if frames > inputScratch.count {
            // Avoid allocating in realtime callback.
            return noErr
        }

        // Pull audio from input bus 1.
        return inputScratch.withUnsafeMutableBufferPointer { scratch in
            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: channels,
                    mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                    mData: scratch.baseAddress
                )
            )
            var flags: AudioUnitRenderActionFlags = []
            var ts = inTimeStamp?.pointee ?? AudioTimeStamp()
            let status = withUnsafePointer(to: &ts) { tsPtr in
                AudioUnitRender(inputUnit, &flags, tsPtr, 1, inNumberFrames, &abl)
            }
            guard status == noErr else { return status }

            // Apply input gain and enqueue.
            if inputGain != 1 {
                for i in 0..<frames { scratch[i] *= inputGain }
            }
            _ = rawFifo.write(from: scratch.baseAddress!, count: frames)
            return noErr
        }
    }

    private func handleOutput(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?,
        inTimeStamp: UnsafePointer<AudioTimeStamp>?,
        inBusNumber: UInt32,
        inNumberFrames: UInt32,
        ioData: UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus {
        guard let ioData else { return noErr }
        let frames = Int(inNumberFrames)
        if frames <= 0 { return noErr }

        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        guard let first = buffers.first else { return noErr }
        guard first.mNumberChannels == channels else { return noErr }
        guard let outPtr = first.mData?.assumingMemoryBound(to: Float.self) else { return noErr }

        let got = outFifo.read(into: outPtr, count: frames)
        if got < frames {
            outPtr.advanced(by: got).initialize(repeating: 0, count: frames - got)
        }
        if outputGain != 1 {
            for i in 0..<frames { outPtr[i] *= outputGain }
        }
        return noErr
    }

    // MARK: - Processing

    private func startProcessingLoop() {
        stopProcessingLoop()

        let timer = DispatchSource.makeTimerSource(queue: processQueue)
        // Small cadence; the real driver is rawFifo fill level.
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            self?.drainAndProcess()
        }
        processTimer = timer
        timer.resume()
    }

    private func stopProcessingLoop() {
        processTimer?.cancel()
        processTimer = nil
    }

    private func drainAndProcess() {
        guard isRunning else { return }

        while rawFifo.availableToRead() >= frameSize {
            let readCount = dryFrame.withUnsafeMutableBufferPointer { ptr in
                rawFifo.read(into: ptr.baseAddress!, count: frameSize)
            }
            if readCount < frameSize { break }

            wetFrame = dryFrame
            processor.processFrame48kMonoInPlace(&wetFrame)

            let mix = wetDry
            if mix < 1 {
                let inv = 1 - mix
                for i in 0..<frameSize {
                    wetFrame[i] = dryFrame[i] * inv + wetFrame[i] * mix
                }
            }

            _ = wetFrame.withUnsafeBufferPointer { ptr in
                outFifo.write(from: ptr.baseAddress!, count: frameSize)
            }
        }
    }
}
