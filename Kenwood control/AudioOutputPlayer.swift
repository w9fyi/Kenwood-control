import Foundation
import AudioToolbox
import CoreAudio

final class AudioOutputPlayer {
    enum PlayerError: LocalizedError {
        case noDefaultOutput
        case audioUnitError(OSStatus, String)

        var errorDescription: String? {
            switch self {
            case .noDefaultOutput:
                return "No default audio output device"
            case .audioUnitError(let status, let context):
                return "\(context) (OSStatus=\(status))"
            }
        }
    }

    var onLog: ((String) -> Void)?
    var onError: ((String) -> Void)?

    var gain: Float = 1.0

    private let sampleRate: Double
    private let channels: UInt32 = 1

    private var unit: AudioUnit?
    private let fifo = AudioRingBuffer(capacitySamples: 48_000 * 4)

    init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
    }

    func start(outputDeviceID: AudioDeviceID? = nil) throws {
        stop()
        let outputID: AudioDeviceID
        if let outputDeviceID {
            outputID = outputDeviceID
        } else if let d = AudioDeviceManager.defaultOutputDeviceID() {
            outputID = d
        } else {
            throw PlayerError.noDefaultOutput
        }

        unit = try makeOutputUnit(deviceID: outputID)

        if let unit {
            var status = AudioUnitInitialize(unit)
            guard status == noErr else { throw PlayerError.audioUnitError(status, "AudioUnitInitialize failed (output)") }
            status = AudioOutputUnitStart(unit)
            guard status == noErr else { throw PlayerError.audioUnitError(status, "AudioOutputUnitStart failed (output)") }
        }

        fifo.clear()
        onLog?("Audio output started (\(Int(sampleRate)) Hz mono)")
    }

    func stop() {
        if let u = unit {
            AudioOutputUnitStop(u)
            AudioUnitUninitialize(u)
            AudioComponentInstanceDispose(u)
        }
        unit = nil
        fifo.clear()
    }

    func enqueue48kMono(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            _ = fifo.write(from: base, count: samples.count)
        }
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
            throw PlayerError.audioUnitError(-1, "AudioComponentFindNext failed (output)")
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(comp, &unit)
        guard status == noErr, let unit else { throw PlayerError.audioUnitError(status, "AudioComponentInstanceNew failed (output)") }

        // Enable output on bus 0, disable input on bus 1.
        var one: UInt32 = 1
        var zero: UInt32 = 0
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw PlayerError.audioUnitError(status, "EnableIO output failed") }
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &zero, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw PlayerError.audioUnitError(status, "Disable input failed") }

        // Select device.
        var dev = deviceID
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw PlayerError.audioUnitError(status, "Set output device failed") }

        // Set stream format for data we provide to bus 0 (unit input scope).
        var asbd = makeASBD()
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { throw PlayerError.audioUnitError(status, "Set output stream format failed") }

        // Install render callback.
        var cb = AURenderCallbackStruct(
            inputProc: { refCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData in
                let player = Unmanaged<AudioOutputPlayer>.fromOpaque(refCon).takeUnretainedValue()
                return player.handleOutput(ioActionFlags: ioActionFlags, inTimeStamp: inTimeStamp, inBusNumber: inBusNumber, inNumberFrames: inNumberFrames, ioData: ioData)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { throw PlayerError.audioUnitError(status, "Set render callback failed") }

        return unit
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

        let got = fifo.read(into: outPtr, count: frames)
        if got < frames {
            outPtr.advanced(by: got).initialize(repeating: 0, count: frames - got)
        }
        if gain != 1 {
            for i in 0..<frames { outPtr[i] *= gain }
        }
        return noErr
    }
}
