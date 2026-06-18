import CoreAudio
import Foundation

/// Native microphone-in-use detection via CoreAudio. This replaces the Electron
/// app's per-poll `michelper` subprocess — here it's a direct in-process query
/// with no spawning, so nothing can leak or wedge. Requires NO mic permission
/// (it only reads device state, never records).
enum MicMonitor {
    static func inUse() -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return false }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var devices = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr
        else { return false }
        for dev in devices where hasInput(dev) && runningSomewhere(dev) { return true }
        return false
    }

    private static func runningSomewhere(_ dev: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var s = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &s, &v) == noErr && v != 0
    }

    private static func hasInput(_ dev: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, buf) == noErr else { return false }
        return buf.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers > 0
    }
}
