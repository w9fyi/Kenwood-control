import Foundation
import AudioToolbox
import CoreAudio

/// Captures a selected CoreAudio input device and converts to 16 kHz mono PCM16 frames (320 samples per 20 ms).
///
/// We use a HAL AudioUnit so the app can select a specific input device (e.g. Shure MVX2U),
/// rather than relying on the system default input.
final class KenwoodLanMicCapture {
    enum CaptureError: LocalizedError {
        case unsupportedSampleRate(Double)
        case audioUnitError(OSStatus, String)

        var errorDescription: String? {
            switch self {
            case .unsupportedSampleRate(let sr):
                return "Unsupported sample rate: \(sr). This build expects 48000 Hz."
            case .audioUnitError(let st, let ctx):
                return "\(ctx) (OSStatus=\(st))"
            }
        }
    }

    var onLog: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onFrame320: ((UnsafePointer<Int16>) -> Void)?

    private let sampleRate: Double = 48_000
    private let channels: UInt32 = 1

    private var unit: AudioUnit?
    private var isRunning: Bool = false
    private var scratch: [Float] = Array(repeating: 0, count: 4096)
    private var pending16k: [Int16] = []

    // 48k -> 16k (factor 3) carry.
    private var carry0: Float = 0
    private var carry1: Float = 0
    private var carryCount: Int = 0 // 0,1,2

    func start(deviceID: AudioDeviceID) throws {
        stop()

        // Require 48 kHz so the downsampler is trivial and deterministic.
        if let info = AudioDeviceManager.inputDevices().first(where: { $0.id == deviceID }),
           abs(info.nominalSampleRate - sampleRate) > 1 {
            throw CaptureError.unsupportedSampleRate(info.nominalSampleRate)
        }

        pending16k.removeAll(keepingCapacity: true)
        carryCount = 0

        unit = try makeInputUnit(deviceID: deviceID)
        try initializeAndStart()
        isRunning = true
        onLog?("LAN mic capture started (deviceID \(deviceID), 48000 Hz)")
    }

    func stop() {
        if isRunning {
            stopAndDispose()
        }
        isRunning = false
        pending16k.removeAll(keepingCapacity: true)
        carryCount = 0
    }

    // MARK: - AudioUnit

    private func makeInputUnit(deviceID: AudioDeviceID) throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw CaptureError.audioUnitError(-1, "AudioComponentFindNext failed (mic)")
        }

        var unit: AudioUnit?
        var st = AudioComponentInstanceNew(comp, &unit)
        guard st == noErr, let unit else { throw CaptureError.audioUnitError(st, "AudioComponentInstanceNew failed (mic)") }

        // Enable input on bus 1, disable output on bus 0.
        var one: UInt32 = 1
        var zero: UInt32 = 0
        st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, UInt32(MemoryLayout<UInt32>.size))
        guard st == noErr else { throw CaptureError.audioUnitError(st, "EnableIO input failed (mic)") }
        st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, UInt32(MemoryLayout<UInt32>.size))
        guard st == noErr else { throw CaptureError.audioUnitError(st, "Disable output failed (mic)") }

        // Select device.
        var dev = deviceID
        st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard st == noErr else { throw CaptureError.audioUnitError(st, "Set input device failed (mic)") }

        // 48 kHz mono float (packed).
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size) * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size) * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        st = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard st == noErr else { throw CaptureError.audioUnitError(st, "Set mic stream format failed") }

        var maxFrames: UInt32 = 4096
        st = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size))
        if st != noErr {
            // Not fatal; continue.
            onError?("SetMaximumFramesPerSlice failed (OSStatus=\(st))")
        }

        // Install input callback.
        var cb = AURenderCallbackStruct(
            inputProc: { refCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData in
                let me = Unmanaged<KenwoodLanMicCapture>.fromOpaque(refCon).takeUnretainedValue()
                return me.handleInput(ioActionFlags: ioActionFlags, inTimeStamp: inTimeStamp, inBusNumber: inBusNumber, inNumberFrames: inNumberFrames)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard st == noErr else { throw CaptureError.audioUnitError(st, "Set input callback failed (mic)") }

        return unit
    }

    private func initializeAndStart() throws {
        guard let unit else { return }
        var st = AudioUnitInitialize(unit)
        guard st == noErr else { throw CaptureError.audioUnitError(st, "AudioUnitInitialize failed (mic)") }
        st = AudioOutputUnitStart(unit)
        guard st == noErr else { throw CaptureError.audioUnitError(st, "AudioOutputUnitStart failed (mic)") }
    }

    private func stopAndDispose() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    private func handleInput(ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, inTimeStamp: UnsafePointer<AudioTimeStamp>, inBusNumber: UInt32, inNumberFrames: UInt32) -> OSStatus {
        guard isRunning, let unit else { return noErr }

        let frames = Int(inNumberFrames)
        if frames <= 0 { return noErr }
        if scratch.count < frames {
            scratch = Array(repeating: 0, count: frames)
        }

        return scratch.withUnsafeMutableBufferPointer { bufPtr in
            guard let base = bufPtr.baseAddress else { return noErr }

            var flags = ioActionFlags.pointee
            var ts = inTimeStamp.pointee

            let byteCount = UInt32(frames * MemoryLayout<Float>.size)
            var buffer = AudioBuffer(mNumberChannels: channels, mDataByteSize: byteCount, mData: base)
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)

            let st = AudioUnitRender(unit, &flags, &ts, 1, inNumberFrames, &abl)
            if st != noErr {
                onError?("Mic AudioUnitRender failed (OSStatus=\(st))")
                return st
            }

            consume48kMono(base, frames: frames)
            return noErr
        }
    }

    private func consume48kMono(_ ptr: UnsafePointer<Float>, frames: Int) {
        // 48k float -> 16k int16 by averaging each group of 3 samples.
        for i in 0..<frames {
            let x = ptr[i]
            if carryCount == 0 {
                carry0 = x; carryCount = 1
            } else if carryCount == 1 {
                carry1 = x; carryCount = 2
            } else {
                let y = (carry0 + carry1 + x) / 3.0
                carryCount = 0

                let scaled = Int((y * 32767.0).rounded())
                let clamped = max(Int(Int16.min), min(Int(Int16.max), scaled))
                pending16k.append(Int16(clamped))
            }
        }

        // Emit 20 ms frames (320 @ 16k).
        while pending16k.count >= 320 {
            var frame = [Int16](repeating: 0, count: 320)
            frame.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: pending16k, count: 320)
            }
            pending16k.removeFirst(320)

            frame.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                onFrame320?(base)
            }
        }
    }
}
