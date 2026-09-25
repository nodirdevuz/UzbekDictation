import CoreAudio
import Foundation

// Kirish qurilmalarini ko'rsatadi va kerak bo'lsa tizim standartini almashtiradi.
// "Diktovka jim" muammosida BIRINCHI qadam shu: qaysi mikrofon standart va u
// umuman tirikmi (02.08.2026 da Bluetooth-garnitura toza nol bergan edi).
//
//   swiftc -O tools/mic-check.swift -o /tmp/mic && /tmp/mic
//   /tmp/mic "MacBook"     — standart kirishni ichki mikrofonga qaytarish
//
// Darajani o'lchash (ilovadan mustaqil, qurilma raqami ffmpeg ro'yxatidan):
//   ffmpeg -f avfoundation -list_devices true -i ""
//   ffmpeg -f avfoundation -i ":2" -t 3 -af volumedetect -f null -
// max_volume −90 dB atrofida bo'lsa — mikrofon jim, gap kodda emas.

enum Mic {

    static func all() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func name(_ id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr,
              let s = cf?.takeRetainedValue() else { return "?" }
        return s as String
    }

    static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func transport(_ id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t)
        switch t {
        case kAudioDeviceTransportTypeBuiltIn:   return "ichki"
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeUSB:       return "usb"
        case kAudioDeviceTransportTypeVirtual:   return "virtual"
        case kAudioDeviceTransportTypeContinuityCaptureWired: return "continuity"
        default: return "boshqa"
        }
    }

    static func rate(_ id: AudioDeviceID) -> Double {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var r: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &r)
        return r
    }

    static var defaultInput: AudioDeviceID {
        get {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            var id: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
            return id
        }
        set {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            var v = newValue
            let rc = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &v)
            print(rc == noErr ? "OK: standart kirish → \(name(newValue))" : "XATO: kod \(rc)")
        }
    }
}

let inputs = Mic.all().filter { Mic.inputChannels($0) > 0 }
let cur = Mic.defaultInput

print("Kirish qurilmalari (* — tizim standarti):")
for id in inputs {
    let mark = id == cur ? "*" : " "
    print("\(mark) [\(id)] \(Mic.name(id))  — \(Mic.transport(id)), \(Int(Mic.rate(id))) Hz, kanal \(Mic.inputChannels(id))")
}

// Diktovka o'zi ICHKI mikrofonni oladi, tizim standartidan qat'i nazar.
if let builtIn = inputs.first(where: { Mic.transport($0) == "ichki" }) {
    print("\nDiktovka ishlatadigan qurilma: \(Mic.name(builtIn))")
}

if CommandLine.arguments.count > 1 {
    let want = CommandLine.arguments[1]
    guard let target = inputs.first(where: { Mic.name($0).localizedCaseInsensitiveContains(want) }) else {
        print("\nXATO: '\(want)' topilmadi"); exit(1)
    }
    print()
    Mic.defaultInput = target
}
