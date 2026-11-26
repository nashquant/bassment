import CoreAudio
import Foundation

let systemObject = AudioObjectID(kAudioObjectSystemObject)

struct CAError: Error, CustomStringConvertible {
    let what: String
    let code: OSStatus
    var description: String { "\(what) (\(code))" }
}

enum CA {
    static func addr(_ sel: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func check(_ err: OSStatus, _ what: String) throws {
        if err != noErr { throw CAError(what: what, code: err) }
    }

    static func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T) -> T? {
        var a = addr(sel)
        var v = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = addr(sel)
        var v: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr, let s = v else { return nil }
        return s.takeRetainedValue() as String
    }

    static func list(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> [AudioObjectID] {
        var a = addr(sel)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static var defaultOutput: AudioObjectID {
        prop(systemObject, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0)) ?? 0
    }

    static func processObject(pid: pid_t) -> AudioObjectID {
        var a = addr(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var p = pid
        var out = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        _ = AudioObjectGetPropertyData(systemObject, &a, UInt32(MemoryLayout<pid_t>.size), &p, &size, &out)
        return out
    }

    /// Input channel count per stream of a device (diagnostics).
    static func inputLayout(_ dev: AudioObjectID) -> [Int] {
        var a = addr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return [] }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.map { Int($0.mNumberChannels) }
    }

    static func listen(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ block: @escaping () -> Void) {
        var a = addr(sel)
        AudioObjectAddPropertyListenerBlock(obj, &a, DispatchQueue.main) { _, _ in block() }
    }
}
