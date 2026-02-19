import Foundation
import CoreAudio

struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let nominalSampleRate: Double
    let inputChannelCount: UInt32
    let outputChannelCount: UInt32

    var displayName: String {
        // Keep UI stable and scannable.
        "\(name) (\(Int(nominalSampleRate)) Hz, in \(inputChannelCount), out \(outputChannelCount))"
    }
}

enum AudioDeviceManager {
    static func inputDevices() -> [AudioDeviceInfo] {
        var devices: [AudioDeviceInfo] = []
        for deviceID in allDevices() {
            guard let info = deviceInfo(deviceID), info.inputChannelCount > 0 else { continue }
            devices.append(info)
        }
        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func outputDevices() -> [AudioDeviceInfo] {
        var devices: [AudioDeviceInfo] = []
        for deviceID in allDevices() {
            guard let info = deviceInfo(deviceID), info.outputChannelCount > 0 else { continue }
            devices.append(info)
        }
        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        for deviceID in allDevices() {
            guard let deviceUID: String = getStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) else { continue }
            if deviceUID == uid { return deviceID }
        }
        return nil
    }

    private static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func deviceInfo(_ deviceID: AudioDeviceID) -> AudioDeviceInfo? {
        guard let uid: String = getStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) else { return nil }
        guard let name: String = getStringProperty(deviceID, selector: kAudioObjectPropertyName) else { return nil }
        let sampleRate: Double = getScalarProperty(deviceID, selector: kAudioDevicePropertyNominalSampleRate) ?? 0
        let inputChannels = channelCount(deviceID, scope: kAudioDevicePropertyScopeInput)
        let outputChannels = channelCount(deviceID, scope: kAudioDevicePropertyScopeOutput)
        return AudioDeviceInfo(
            id: deviceID,
            uid: uid,
            name: name,
            nominalSampleRate: sampleRate,
            inputChannelCount: inputChannels,
            outputChannelCount: outputChannels
        )
    }

    private static func channelCount(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return 0 }
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ptr.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr) == noErr else { return 0 }
        let abl = ptr.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        return buffers.reduce(0) { $0 + $1.mNumberChannels }
    }

    private static func getStringProperty(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &unmanaged)
        guard status == noErr, let unmanaged else { return nil }
        return unmanaged.takeUnretainedValue() as String
    }

    private static func getScalarProperty<T: FixedWidthInteger>(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = T.zero
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value
    }

    private static func getScalarProperty(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value
    }
}
