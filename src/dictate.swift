import SwiftUI
import AVFoundation
import CoreAudio
import AudioToolbox
import AppKit
import Carbon.HIToolbox
import ApplicationServices
import ServiceManagement
import os

// На macOS 26 NSLog прячет текст сообщения в системном журнале («<private>»),
// и без sudo его не прочитать. os_log с %{public} виден всегда.
private let rubaiLog = OSLog(subsystem: "com.rubaistt.dictation", category: "app")
func rlog(_ s: String) { os_log("%{public}@", log: rubaiLog, type: .default, s) }

// MARK: - Whisper (rubaiSTT) yadrosi

final class Whisper {
    static let shared = Whisper()
    private var loaded = false
    private let q = DispatchQueue(label: "rubai.whisper")

    // Файл модели. large-v3-turbo на Metal: заметно точнее small в русском.
    // q5_0, а не q8_0: точность на замере одинаковая, а модель на 300 МБ меньше —
    // меньше памяти и нагрева на MacBook Air без вентилятора.
    static let modelFile = "ggml-large-v3-turbo-q5_0"

    // Сколько модель живёт в памяти после последней диктовки. Потом выгружается —
    // в простое приложение не держит ~1 ГБ и ничего не считает.
    static let idleUnload: TimeInterval = 120
    private var unloadWork: DispatchWorkItem?

    // Потоки CPU: только производительные ядра (на M5 их 4). Основную работу
    // делает GPU, а энергоэффективные ядра в матрицах только тормозят.
    static let threads: Int32 = {
        var n: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &n, &size, nil, 0) == 0, n > 0 { return n }
        size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.physicalcpu", &n, &size, nil, 0) == 0, n > 0 { return n }
        return Int32(max(4, ProcessInfo.processInfo.activeProcessorCount / 2))
    }()

    // Model qayerdan izlanadi. Bundle ichida bo'lmasligi mumkin: build.sh
    // ilovani ~/Applications ga yig'adi, modellar esa /Applications dagi
    // nusxada turadi. Shuning uchun barcha ma'lum joylarni ketma-ket tekshiramiz —
    // qaysi nusxa ishga tushsa ham diktovka ishlayveradi.
    private func modelPath() -> String? {
        let f = Whisper.modelFile + ".bin"
        var candidates: [String] = []
        if let p = Bundle.main.path(forResource: Whisper.modelFile, ofType: "bin") { candidates.append(p) }
        candidates += [
            "/Applications/RubaiSTT Dictation.app/Contents/Resources/" + f,
            NSHomeDirectory() + "/Applications/RubaiSTT Dictation.app/Contents/Resources/" + f,
            NSHomeDirectory() + "/rubai-stt/models/" + f,
        ]
        for p in candidates where FileManager.default.fileExists(atPath: p) {
            if p != candidates.first { rlog("[rubai] model boshqa joydan olindi: \(p)") }
            return p
        }
        return nil
    }

    // Вызывается в момент старта записи: модель грузится, пока человек говорит,
    // поэтому в ожидание после ⌘ загрузка не попадает.
    func preload() {
        DispatchQueue.main.async { self.unloadWork?.cancel(); self.unloadWork = nil }
        q.async(qos: .userInitiated) {
            guard !self.loaded, let mp = self.modelPath() else { return }
            let t0 = Date()
            if rubai_load(mp) == 0 {
                self.loaded = true
                rlog("[rubai] model yuklandi \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
            }
        }
    }

    // Диктовка закончилась — через idleUnload секунд простоя выгружаем модель.
    // Выгрузка встаёт в ту же очередь, поэтому не может случиться посреди распознавания.
    func scheduleUnload() {
        unloadWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.unloadWork = nil
            self.q.async {
                guard self.loaded else { return }
                rubai_unload()
                self.loaded = false
                rlog("[rubai] model xotiradan chiqarildi (bo'sh turibdi)")
            }
        }
        unloadWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Whisper.idleUnload, execute: w)
    }

    // Fon bo'laklari uchun yadrolarning yarmi: odam shu payt gapiryapti va
    // shu mashinada ishlayapti ham — 8 yadroni to'liq band qilish sezilib qoladi.
    // Bo'lak sekinroq tanilsa ham zarari yo'q: u navbatdagi vaqtdan yeydi, kutishdan emas.
    static var backgroundThreads: Int32 { max(2, threads / 2) }

    // accurate: nil = menyudagi sozlama, true/false = majburan.
    // fullCtx: qisqa bo'laklarda aniqlikni saqlaydi (fon bo'laklari uchun).
    // prompt: oldingi bo'lakning oxiri — chegarada so'z buzilmasligi uchun.
    func transcribe(_ samples: [Float],
                    threads: Int32 = Whisper.threads,
                    qos: DispatchQoS = .userInitiated,
                    accurate: Bool? = nil,
                    fullCtx: Bool = false,
                    prompt: String? = nil,
                    tag: String = "",
                    done: @escaping (String) -> Void,
                    fail: @escaping (String) -> Void = { _ in }) {
        q.async(qos: qos) {
            if !self.loaded {
                guard let mp = self.modelPath() else {
                    rlog("[rubai] XATO: model fayli topilmadi (bundle/uy)")
                    DispatchQueue.main.async { fail("Файл модели не найден") }; return
                }
                let rc = rubai_load(mp)
                rlog("[rubai] rubai_load(\(mp)) = \(rc)")
                guard rc == 0 else {
                    DispatchQueue.main.async { fail("Модель не загрузилась (код \(rc))") }; return
                }
                self.loaded = true
            }
            let t0 = Date()
            var text = ""
            let acc: Int32 = accurate == nil ? -1 : (accurate! ? 1 : 0)
            samples.withUnsafeBufferPointer { buf in
                if let c = rubai_transcribe(buf.baseAddress, Int32(buf.count), threads,
                                            acc, fullCtx ? 1 : 0, prompt) {
                    text = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                    rubai_free_str(c)
                }
            }
            rlog("[rubai] transcribe\(tag): \(String(format: "%.2f", Date().timeIntervalSince(t0)))s / audio \(String(format: "%.1f", Double(samples.count) / 16000.0))s")
            DispatchQueue.main.async { done(text) }
        }
    }

    // Navbat bo'shaganini kutish. Navbat ketma-ket, shuning uchun bu blok
    // undan oldin qo'yilgan barcha bo'laklardan keyin ishlaydi.
    func barrier(qos: DispatchQoS = .userInitiated, _ done: @escaping () -> Void) {
        q.async(qos: qos) { DispatchQueue.main.async(execute: done) }
    }

}

// MARK: - Kirish qurilmalari (qaysi mikrofondan yozamiz)

// Tizimdagi "standart kirish" bizga to'g'ri kelmaydi: Bluetooth-garnitura
// ulanishi bilanoq macOS uni standart qilib qo'yadi, garnitura esa mikrofon
// rejimida (HFP) 8 kHz beradi — whisper uchun bu deyarli shovqin. Yomoni ham
// bor: 02.08.2026 da M-106BT garnitura umuman JIMLIK berdi (ffmpeg bilan
// o'lchandi: max_volume −91 dB, ya'ni toza nol), diktovka esa "qotib qolgandek"
// ko'rindi — kapsuladagi ekvalayzer qimirlamadi, chunki daraja rostdan ham nol.
// Shuning uchun mikrofonni O'ZIMIZ tanlaymiz: ichki mikrofon bor bo'lsa — u.
enum InputDevice {

    static func name(_ id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr,
              let s = cf?.takeRetainedValue() else { return "?" }
        return s as String
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t)
        return t
    }

    private static func all() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
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

    // Ichki mikrofon. Topilmasa — nil, o'shanda tizim standartida qolamiz.
    static func builtIn() -> AudioDeviceID? {
        all().first { inputChannels($0) > 0 && transportType($0) == kAudioDeviceTransportTypeBuiltIn }
    }

    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        let t = transportType(id)
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    static var systemInput: AudioDeviceID {
        get {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var id: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
            return id
        }
        set {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var v = newValue
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                       UInt32(MemoryLayout<AudioDeviceID>.size), &v)
        }
    }

    // Bluetooth kolonka MIKROFON bo'lib qolmasin. macOS uni ulanishi bilan
    // "standart kirish" qilib qo'yadi va ikki zarar keltiradi:
    //   1) diktovka: kolonka mikrofoni jim qolishi mumkin (02.08.2026, M-106BT)
    //      yoki eng yaxshi holatda 8 kHz beradi — whisper uchun deyarli shovqin;
    //   2) musiqa: mikrofoni band bo'lgani uchun kolonka HFP rejimiga tushadi va
    //      8 kHz da "telefon ovozi" bilan chalinadi.
    // Ikkalasi ham bitta harakat bilan davolanadi — kirishni ichki mikrofonga
    // qaytarish. Egasining talabi ham shu: "bluetooth — kolonka, eshitish — Mac".
    @discardableResult
    static func keepSystemInputOffBluetooth() -> Bool {
        let cur = systemInput
        guard isBluetooth(cur), let mac = builtIn(), mac != cur else { return false }
        systemInput = mac
        rlog("[rubai] tizim kirishi \(name(cur)) (bluetooth) dan \(name(mac)) ga qaytarildi")
        return true
    }

    // Kolonka har ulanganda macOS uni yana kirish qilib qo'yadi — shuning uchun
    // bir marta tuzatish yetmaydi, o'zgarishni kuzatib turamiz. O'zimiz qo'ygan
    // qiymat ham hodisa keltiradi, lekin u BT bo'lmagani uchun tsikl bo'lmaydi.
    private static var listening = false
    static func watchSystemInput() {
        guard !listening else { return }
        listening = true
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                            &addr, DispatchQueue.main) { _, _ in
            keepSystemInputOffBluetooth()
        }
    }
}

// MARK: - Mikrofon (16kHz mono float32)

final class Recorder {
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var convFrom: AVAudioFormat?   // konverter qaysi formatga yig'ilgan
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 16000, channels: 1, interleaved: false)!
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false

    // Qaysi mikrofondan yozyapmiz — xabar va log uchun.
    private(set) var deviceName = "?"

    // Har yozuvning o'z raqami: kechikkan tekshiruv keyingi yozuvni urmasin.
    private(set) var sessionNo = 0

    // Hech bo'lmasa bitta noldan farqli sample keldimi. Jim mikrofon (uzilgan
    // Bluetooth-transport) toza nol beradi, tirik mikrofon esa hech qachon —
    // hatto jim xonada ham shovqin bor. Shu farq bilan "mikrofon o'lik"ligini
    // yozuv oxirini kutmasdan, 1,5 soniyada bilamiz.
    private var sound = false
    var sawSound: Bool { lock.lock(); defer { lock.unlock() }; return sound }

    // Diagnostika: yozuv boshi, kelgan bufer soni. "Bufer umuman kelmadi" bilan
    // "buferlar keldi, lekin ichi nol" — bular boshqa-boshqa nosozliklar.
    private var startedAt = Date()
    private var bufCount = 0
    var buffersSeen: Int { lock.lock(); defer { lock.unlock() }; return bufCount }

    // Ovoz balandligi (0…1) — ekvalayzer animatsiyasi uchun.
    var onLevel: ((Float) -> Void)?
    private var lastLevelSent = Date.distantPast

    func start(_ cb: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: cb(begin())
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { cb(ok ? self.begin() : false) }
            }
        default: cb(false)
        }
    }

    private func begin() -> Bool {
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        // Bluetooth kolonka kirishni egallab olgan bo'lsa — qaytarib olamiz.
        // Bu shunchaki "toza"lik uchun emas: kirish BT'da turganda CoreAudio
        // HFP'ga o'tish bilan band bo'lib, bizning grafimizga bitta ham bufer
        // bermay qo'yishi o'lchandi (02.08.2026, "bufer: 0").
        InputDevice.keepSystemInputOffBluetooth()
        // Har yozishda YANGI engine — login'da/qurilma o'zgarganda qotib qolgan
        // (jim, "musiqa") holatdan saqlaydi.
        //
        // DIQQAT: engine'ni oldindan tayyorlab qo'yish (prepare()) mumkin emas —
        // AVAudioEngineGraph::Initialize ObjC-istisno tashlaydi, Swift uni ushlay
        // olmaydi va ilova qulaydi (SIGSEGV, 25.07.2026 da tekshirildi).
        engine = AVAudioEngine()
        sessionNo += 1
        startedAt = Date()
        lock.lock(); sound = false; bufCount = 0; lock.unlock()
        let input = engine.inputNode

        // Mikrofonni tizim tanlashiga qoldirmaymiz — ichki mikrofonni o'zimiz
        // qo'yamiz (sabab InputDevice izohida). Qurilma FORMATNI o'qishdan oldin
        // qo'yilishi shart, aks holda konverter eski qurilma formatida qoladi.
        if let dev = InputDevice.builtIn() {
            do {
                // setDeviceID — AVAudioEngine'ning o'z yo'li (AudioUnitSetProperty
                // ham qurilmani qo'yadi, lekin bu API xatoni qaytaradi va tugun
                // formati bilan kelishilgan). Formatni qanday o'qish kerakligi —
                // pastdagi izohda: bu yerda eng oson yiqiladigan joy.
                try input.auAudioUnit.setDeviceID(dev)
                deviceName = InputDevice.name(dev)
            } catch {
                deviceName = "\(InputDevice.name(dev)) (qo'yilmadi: \(error.localizedDescription))"
            }
        } else {
            deviceName = "tizim standarti"
        }

        // Format AYNAN inputFormat'dan olinadi, outputFormat'dan emas.
        // 02.08.2026 da o'lchandi: qurilmani o'zimiz qo'yganimizdan keyin
        //   inputFormat  = 48000 Hz  (qurilmaning haqiqiy formati)
        //   outputFormat = 44100 Hz  (tugunning eski, yangilanmagan formati)
        // installTap esa qurilma formatini talab qiladi — outputFormat bilan u
        // "Input HW format and tap format not matching" deb yiqilardi va yozuv
        // umuman boshlanmasdi (ilova tirik, lekin ovoz yozilmaydi).
        var hw = input.inputFormat(forBus: 0)
        if hw.sampleRate <= 0 { hw = input.outputFormat(forBus: 0) }
        guard hw.sampleRate > 0 else { return false }
        rlog("[rubai] mikrofon: \(deviceName) — \(Int(hw.sampleRate)) Hz, \(hw.channelCount) kanal")
        converter = AVAudioConverter(from: hw, to: target)
        convFrom = hw
        input.installTap(onBus: 0, bufferSize: 4096, format: hw) { [weak self] buf, _ in
            guard let self = self else { return }
            // Format baribir boshqacha kelsa (qurilma yozuv ustida almashsa),
            // konverterni qayta yig'amiz: bu bo'lakni yo'qotgandan afzal.
            if self.convFrom == nil || !self.convFrom!.isEqual(buf.format) {
                self.converter = AVAudioConverter(from: buf.format, to: self.target)
                self.convFrom = buf.format
                rlog("[rubai] kirish formati o'zgardi -> \(Int(buf.format.sampleRate)) Hz")
            }
            guard let conv = self.converter else { return }
            let ratio = self.target.sampleRate / buf.format.sampleRate
            let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: self.target, frameCapacity: cap) else { return }
            var fed = false; var err: NSError?
            conv.convert(to: out, error: &err) { _, s in
                if fed { s.pointee = .noDataNow; return nil }
                fed = true; s.pointee = .haveData; return buf
            }
            if let ch = out.floatChannelData {
                let n = Int(out.frameLength)
                self.lock.lock()
                self.samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
                self.bufCount += 1
                // Tirik mikrofonmi. Faqat birinchi ovoz kelgunga qadar sanaymiz.
                var firstSound = false
                if !self.sound {
                    for i in 0..<n where ch[0][i] != 0 { self.sound = true; firstSound = true; break }
                }
                self.lock.unlock()
                if firstSound {
                    rlog("[rubai] birinchi ovoz: \(String(format: "%.2f", Date().timeIntervalSince(self.startedAt)))s")
                }

                // RMS -> daraja. Sekundiga ~30 marta yuboramiz (CPU'ni bekorga isitmaslik uchun).
                if self.onLevel != nil, n > 0, Date().timeIntervalSince(self.lastLevelSent) > 0.033 {
                    self.lastLevelSent = Date()
                    var sum: Float = 0
                    for i in 0..<n { let v = ch[0][i]; sum += v * v }
                    let rms = sqrt(sum / Float(n))
                    // Речь: −46 дБ (тишина) … −14 дБ (громко). Раньше порог был −52 дБ
                    // с корнем — фоновый шум комнаты поднимал все столбики до половины
                    // (скриншот владельца 25.09.2026). Теперь тишина — ровная линия.
                    let db = 20 * log10(max(rms, 1e-6))
                    let norm = max(0, min(1, (db + 46) / 30))
                    let lvl = pow(norm, 0.9)
                    DispatchQueue.main.async { self.onLevel?(lvl) }
                }
            }
        }
        engine.prepare()
        do { try engine.start() } catch { return false }
        isRecording = true
        return true
    }

    // Graf ishga tushdi, lekin bitta ham bufer bermadi — CoreAudio o'sha payt
    // qurilma almashtirish bilan band bo'lgan. Grafni qaytadan yig'amiz:
    // yo'qotadigan narsa yo'q (bufer kelmagan), yozuv esa davom etadi.
    @discardableResult
    func restartEngine() -> Bool {
        guard isRecording else { return false }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        let ok = begin()
        rlog("[rubai] audio grafi qayta yig'ildi: \(ok ? "ok" : "muvaffaqiyatsiz")")
        return ok
    }

    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        lock.lock(); let s = samples; lock.unlock()
        return s
    }

    // MARK: - Oqimli o'qish (gapirayotganda tanish uchun)

    // Yozishni to'xtatmasdan — shu paytgacha nechta sample yig'ilgani.
    var sampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }

    // [from..<to] oralig'ining nusxasi; yozish davom etaveradi.
    func slice(from: Int, to: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let a = max(0, min(from, samples.count))
        let b = max(a, min(to, samples.count))
        return Array(samples[a..<b])
    }

}

// MARK: - Oqimli tanish (gapirayotganda)

// Diktovka tugashini kutmaydi: yozib olingan qismni pauzalar bo'yicha bo'laklarga
// ajratib, whisper'ga fonda beradi. ⌘ bosilganda faqat DUM — oxirgi jumla — qoladi,
// shuning uchun kutish diktovka uzunligiga qarab o'smaydi.
//
// Butun holat FAQAT main oqimida o'zgaradi (taymer ham, whisper javoblari ham
// main'ga keladi) — shuning uchun bu yerda lock kerak emas. Og'ir hisob
// (kesish nuqtasini izlash) fon oqimiga chiqarilgan, chunki main'da kapsula
// 60 kadr/s chiziladi.
final class StreamTranscriber {
    private let rec: Recorder

    // Bir diktovka = bir "avlod". Til almashsa yoki bekor qilinsa avlod ortadi,
    // yo'lda qolgan bo'laklarning javoblari e'tiborsiz qoladi.
    private var generation = 0
    private var cursor = 0             // nechta sample tanishga topshirilgan
    private var parts: [String] = []   // natijalar — topshirilgan tartibda
    private var chunkNo = 0
    private var scanning = false
    private var timer: DispatchSourceTimer?

    init(_ rec: Recorder) { self.rec = rec }

    var chunksSubmitted: Int { parts.count }

    // MARK: hayot sikli

    func begin() {
        generation += 1
        cursor = 0
        parts = []
        chunkNo = 0
        scanning = false
        startTimer()
    }

    func abort() {
        generation += 1
        cursor = 0
        parts = []
        stopTimer()
    }

    // ⌘ bosildi. `all` — butun yozuv; undan faqat topshirilmagan dum olinadi.
    func finish(all: [Float], done: @escaping (String, Int) -> Void) {
        stopTimer()
        let gen = generation
        var tailSec = 0.0
        if cursor < all.count {
            let tail = Array(all[cursor...])
            cursor = all.count
            tailSec = Double(tail.count) / 16000.0
            // 0.35 s dan qisqa dum — bu pauzaning quyrug'i, tanishga hojat yo'q.
            //
            // Dum — odam KUTIB turgan yagona qism, shuning uchun eng tez sozlama:
            // greedy va uzunlikka moslangan audio_ctx. To'liq audio_ctx bu yerda
            // o'lchandi: 3.3 s dumga 2.85 s (5 barobar qimmat) — hammasini yeb
            // qo'yadi. Aniqlikni esa oldingi bo'lak matni (prompt) ko'taradi.
            if tail.count >= Int(0.35 * 16000) {
                submit(tail, threads: Whisper.threads, qos: .userInitiated)
            }
        }
        let submitted = parts.count
        // Navbat ketma-ket: bu blok undan oldingi barcha bo'laklardan keyin ishlaydi.
        Whisper.shared.barrier { [weak self] in
            guard let self = self, gen == self.generation else { return }
            rlog("[rubai] oqim: \(submitted) bo'lak, dum \(String(format: "%.1f", tailSec))s")
            done(self.joined(), submitted)
        }
    }

    // MARK: ichki

    private func startTimer() {
        stopTimer()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.7, repeating: 0.7, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.pump() }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func pump() {
        guard !scanning, rec.isRecording else { return }
        let total = rec.sampleCount
        guard total - cursor >= Audio.minChunk else { return }

        let from = cursor
        let gen = generation
        let tail = rec.slice(from: from, to: total)
        scanning = true
        DispatchQueue.global(qos: .utility).async {
            let cut = Audio.cut(tail)
            DispatchQueue.main.async {
                self.scanning = false
                // Skanerlash paytida til almashgan/bekor qilingan bo'lishi mumkin.
                guard gen == self.generation, self.cursor == from, let cut = cut else { return }
                rlog("[rubai] kesish: \(String(format: "%.1f", Double(cut.at) / 16000.0))s — \(cut.why.rawValue), pauza \(String(format: "%.1f", cut.pause))s, rms=\(String(format: "%.4f", cut.level))")
                self.cursor = from + cut.at
                // Fon bo'lagi: odam hali gapiryapti, ya'ni vaqt baribir bo'sh
                // turardi — shuning uchun ANIQ rejim va to'liq audio_ctx.
                self.submit(Array(tail[0..<cut.at]), threads: Whisper.backgroundThreads,
                            qos: .utility, accurate: true, fullCtx: true)
            }
        }
    }

    // Oldingi bo'lakning oxiri — keyingisiga old matn sifatida beriladi.
    // Bo'lak chegarasida dekoder gap boshini bilmay qolmasligi uchun.
    private func promptTail() -> String? {
        guard let last = parts.last(where: { !$0.isEmpty }) else { return nil }
        return last.count > 200 ? String(last.suffix(200)) : last
    }

    private func submit(_ raw: [Float], threads: Int32, qos: DispatchQoS,
                        accurate: Bool? = nil, fullCtx: Bool = false) {
        let prompt = promptTail()
        let idx = parts.count
        parts.append("")
        chunkNo += 1
        let no = chunkNo
        let gen = generation

        // Jim bo'lak whisper'ga umuman berilmaydi: jimlikda u «[музыка]»,
        // «*звук птиц*» o'ylab topadi (shu sabab butun yozuv uchun ham tekshiramiz).
        let peak = Audio.peakLevel(raw)
        guard peak >= 0.012 else {
            rlog("[rubai] bo'lak #\(no): jim (peak=\(String(format: "%.4f", peak))) — o'tkazildi")
            return
        }

        let audio = Audio.prepare(raw)
        Whisper.shared.transcribe(audio, threads: threads, qos: qos,
                                  accurate: accurate, fullCtx: fullCtx,
                                  prompt: prompt, tag: " #\(no)") { [weak self] text in
            rlog("[rubai] bo'lak #\(no) matni: '\(text)'")
            guard let self = self, gen == self.generation, idx < self.parts.count else { return }
            self.parts[idx] = text
        }
    }

    private func joined() -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
             .filter { !$0.isEmpty }
             .joined(separator: " ")
    }
}

// MARK: - Kapsula overlay: (✕) RU ▁▄█▅▂ (✓)

private enum CapsuleMode { case recording, processing, message }

private final class CapsuleView: NSView {
    var mode: CapsuleMode = .recording
    var lang: String = "ru"
    var messageText: String = ""
    // levels — ekrandagi (silliq), targets — mikrofondan kelgan nishon qiymatlar.
    // Bittasi ortiqcha: to'lqin uzluksiz surilishi uchun (phase bilan).
    static let barCount = 15
    var levels: [CGFloat] = Array(repeating: 0.02, count: barCount + 1)
    var targets: [CGFloat] = Array(repeating: 0.02, count: barCount + 1)
    var phase: CGFloat = 0                // 0…1 — qadamlar orasidagi uzluksiz siljish
    var spinPhase: CGFloat = 0
    var dotsPhase: CGFloat = 0

    var onCancel: (() -> Void)?
    var onAccept: (() -> Void)?

    private let sidePad: CGFloat = 0      // soya — oynaning o'zida
    private let btnR: CGFloat = 8

    private var capsuleRect: NSRect { bounds.insetBy(dx: sidePad, dy: sidePad) }
    private var leftBtnCenter: NSPoint {
        NSPoint(x: capsuleRect.minX + 6 + btnR, y: capsuleRect.midY)
    }
    private var rightBtnCenter: NSPoint {
        NSPoint(x: capsuleRect.maxX - 6 - btnR, y: capsuleRect.midY)
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let r = capsuleRect
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)

        // Fon: oynada NSVisualEffectView (matoviy shisha) turibdi — ustidan
        // yupqa qora qatlam beramiz: "qora matoviy shaffof".
        NSColor.black.withAlphaComponent(0.42).setFill()
        path.fill()

        // Yuqori qirrada zo'rg'a sezilarli yorug' chiziq — "qimmat" ko'rinish uchun
        NSColor.white.withAlphaComponent(0.07).setStroke()
        path.lineWidth = 0.75
        path.stroke()

        switch mode {
        case .recording:  drawRecording(r)
        case .processing: drawProcessing(r)
        case .message:    drawMessage(r)
        }
    }

    private func drawMessage(_ r: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
        ]
        let s = NSAttributedString(string: messageText, attributes: attrs)
        let sz = s.size()
        s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
    }

    // MARK: yozish holati

    private func drawRecording(_ r: NSRect) {
        drawCancelButton()

        // Эквалайзер — на всё место между кнопками (надпись RU убрана по просьбе владельца)
        let barsX0 = leftBtnCenter.x + btnR + 9
        let barsX1 = rightBtnCenter.x - btnR - 9
        drawBars(from: barsX0, to: barsX1, midY: r.midY)

        drawAcceptButton()
    }

    // To'lqin uzluksiz oqadi: chiziqlar phase ulushiga surilib chiziladi,
    // chetlarida esa asta so'nadi — sakrash ko'rinmaydi.
    private func drawBars(from x0: CGFloat, to x1: CGFloat, midY: CGFloat) {
        let visible = CapsuleView.barCount
        guard levels.count > visible, x1 > x0 else { return }
        let barW: CGFloat = 2.2
        let step = (x1 - x0) / CGFloat(visible - 1)
        let base = NSColor.white

        for i in 0...visible {
            let x = x0 + (CGFloat(i) - phase) * step
            if x < x0 - step || x > x1 + step { continue }
            // chetlarida shaffoflik — chiziqlar "paydo bo'lib / yo'qolib" turadi
            var edge: CGFloat = 1
            if x < x0 + step      { edge = max(0, (x - (x0 - step)) / (step * 2)) }
            else if x > x1 - step { edge = max(0, ((x1 + step) - x) / (step * 2)) }

            // Огибающая: в центре столбики выше, к краям плавно ниже — форма «волны»,
            // а не забор одинаковых палочек.
            let u = max(0, min(1, (x - x0) / (x1 - x0)))
            let env = 0.35 + 0.65 * sin(u * .pi)
            // jim — ingichka chiziqcha, gapirganda — baland ustun (diktofondagidek)
            let h = 2.2 + levels[min(i, levels.count - 1)] * env * 20
            base.withAlphaComponent((0.55 + 0.4 * env) * edge).setFill()
            let rect = NSRect(x: x - barW / 2, y: midY - h / 2, width: barW, height: h)
            NSBezierPath(roundedRect: rect, xRadius: barW / 2, yRadius: barW / 2).fill()
        }
    }

    // MARK: matnga o'girish holati

    private func drawProcessing(_ r: NSRect) {
        // Chapda "nafas oluvchi" nuqtalar — to'lqin bo'ylab yumshoq yorishadi
        let n = 12
        let x0 = r.minX + 16
        let x1 = r.maxX - 34
        let step = (x1 - x0) / CGFloat(n - 1)
        for i in 0..<n {
            let wave = sin(dotsPhase - CGFloat(i) * 0.55)      // -1…1
            let alpha = 0.16 + max(0, wave) * 0.62
            NSColor.white.withAlphaComponent(alpha).setFill()
            let d: CGFloat = 2.2 + max(0, wave) * 0.8
            let rect = NSRect(x: x0 + CGFloat(i) * step - d / 2, y: r.midY - d / 2, width: d, height: d)
            NSBezierPath(ovalIn: rect).fill()
        }

        // O'ngda spinner — uzluksiz aylanadi
        let c = NSPoint(x: r.maxX - 17, y: r.midY)
        let spokes = 10
        for i in 0..<spokes {
            let a = CGFloat(i) / CGFloat(spokes) * .pi * 2 - spinPhase
            let fade = CGFloat(i) / CGFloat(spokes)
            NSColor.white.withAlphaComponent(0.14 + fade * 0.7).setStroke()
            let p = NSBezierPath()
            p.lineWidth = 1.4
            p.lineCapStyle = .round
            p.move(to: NSPoint(x: c.x + cos(a) * 3.2, y: c.y + sin(a) * 3.2))
            p.line(to: NSPoint(x: c.x + cos(a) * 6.4, y: c.y + sin(a) * 6.4))
            p.stroke()
        }
    }

    // MARK: tugmalar

    private func drawCancelButton() {
        let c = leftBtnCenter
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - btnR, y: c.y - btnR, width: btnR * 2, height: btnR * 2)).fill()
        NSColor.white.withAlphaComponent(0.85).setStroke()
        let p = NSBezierPath()
        p.lineWidth = 1.3
        p.lineCapStyle = .round
        let d: CGFloat = 2.7
        p.move(to: NSPoint(x: c.x - d, y: c.y - d)); p.line(to: NSPoint(x: c.x + d, y: c.y + d))
        p.move(to: NSPoint(x: c.x - d, y: c.y + d)); p.line(to: NSPoint(x: c.x + d, y: c.y - d))
        p.stroke()
    }

    private func drawAcceptButton() {
        let c = rightBtnCenter
        NSColor.white.withAlphaComponent(0.95).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - btnR, y: c.y - btnR, width: btnR * 2, height: btnR * 2)).fill()
        NSColor(calibratedWhite: 0.05, alpha: 1).setStroke()
        let p = NSBezierPath()
        p.lineWidth = 1.5
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        p.move(to: NSPoint(x: c.x - 3.2, y: c.y + 0.2))
        p.line(to: NSPoint(x: c.x - 1.0, y: c.y - 2.1))
        p.line(to: NSPoint(x: c.x + 3.3, y: c.y + 2.6))
        p.stroke()
    }

    // MARK: bosish

    override func mouseDown(with event: NSEvent) {
        guard mode == .recording else { return }
        let p = convert(event.locationInWindow, from: nil)
        if hypot(p.x - leftBtnCenter.x, p.y - leftBtnCenter.y) <= btnR + 4 { onCancel?(); return }
        if hypot(p.x - rightBtnCenter.x, p.y - rightBtnCenter.y) <= btnR + 4 { onAccept?(); return }
    }
}

final class Overlay {
    private var panel: NSPanel?
    private var view: CapsuleView?
    private var timer: Timer?
    private var frame = 0
    private var currentLevel: CGFloat = 0
    private let W: CGFloat = 126
    private let H: CGFloat = 32

    var onCancel: (() -> Void)?
    var onAccept: (() -> Void)?

    // ⚠️ DARAJA: aynan .screenSaver, CGShieldingWindowLevel EMAS.
    // Shielding darajasidagi oyna ish stoli Space'ining kompozitsiyasiga tegishli va boshqa
    // ilovaning TO'LIQ EKRANLI Space'ida umuman chizilmaydi — egasi 28.07 shundan shikoyat qildi:
    // to'liq ekranli Claude'da diktovka ishlaydi, lekin kapsula ko'rinmaydi (u ish stolida qoladi).
    // .screenSaver to'liq ekranli oyna ustida ham chiziladi va Space'lar bilan to'g'ri ishlaydi.
    private let capsuleLevel = NSWindow.Level.screenSaver

    // ⚠️ HAR SAFAR ko'rsatishdan oldin qayta qo'yiladi: .canJoinAllSpaces — kapsula BARCHA
    // Space'larda (ish stollari va to'liq ekranli oynalar) turishi uchun, .fullScreenAuxiliary —
    // to'liq ekranli oyna yonida yashashi mumkinligi uchun. `.stationary` olib tashlandi: u faqat
    // Exposé uchun kerak edi va foyda bermasdi.
    //
    // `spacesMode` — o'zini tuzatish natijasi (pastdagi verifyVisible). 0 — odatdagi yo'l;
    // 1 — oynani majburan faol Space'ga ko'chirish (agar birinchisi bu tizimda ishlamasa).
    // Bir marta topilgan ishlaydigan yo'l ESLAB QOLINADI, shuning uchun keyingi safar kapsula
    // darrov to'g'ri joyda chiqadi va "avval noto'g'ri, keyin tuzaladi" miltillashi bo'lmaydi.
    private var spacesMode = 0

    private func applySpaces(_ p: NSPanel) {
        p.collectionBehavior = spacesMode == 0
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            : [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        p.level = capsuleLevel
    }

    /// Kapsula HAQIQATAN ekranda ko'rinyaptimi — tekshiramiz va o'zimizni tuzatamiz.
    ///
    /// ⚠️ NEGA KERAK. Oyna qaysi Space'da chizilishi macOS ning ichki qarori: u hujjatlashtirilmagan
    /// va versiyadan versiyaga o'zgaradi. 27.07 monitor tanlash tuzatildi, 28.07 esa o'sha kapsula
    /// to'liq ekranli oynada ko'rinmay qoldi — bayroqlar "to'g'ri" bo'lsa ham. Shuning uchun endi
    /// bayroqqa ISHONMAYMIZ, balki NATIJANI o'lchaymiz: oyna faol Space ro'yxatida bormi.
    /// Yo'q bo'lsa — zinapoya bo'yicha tuzatamiz va ishlagan usulni eslab qolamiz.
    private func verifyVisible(_ p: NSPanel, attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, p.isVisible else { return }
            if self.isOnScreen(p) {
                if attempt > 0 { rlog("[rubai] kapsula \(attempt)-chora bilan ko'rindi (spacesMode=\(self.spacesMode))") }
                return
            }
            switch attempt {
            case 0:
                // 1-chora: majburan faol Space'ga ko'chirish. Buni ESLAB QOLAMIZ.
                self.spacesMode = 1
                p.orderOut(nil)
                self.applySpaces(p)
                p.orderFrontRegardless()
            case 1:
                // 2-chora: mumkin bo'lgan eng yuqori daraja.
                p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
                p.orderFrontRegardless()
            default:
                // Diktovkaning o'zi ishlayveradi — matn baribir qo'yiladi, faqat kapsula ko'rinmaydi.
                rlog("[rubai] kapsulani ko'rsatib bo'lmadi — diktovka ishlashda davom etadi")
                return
            }
            self.verifyVisible(p, attempt: attempt + 1)
        }
    }

    /// Oyna faol Space'da chizilyaptimi. ⚠️ Qiymatlar NSNumber — to'g'ridan-to'g'ri `as? UInt32`
    /// jimgina nil beradi (27.07 da aynan shu tuzoqqa tushgan edik kCGWindowOwnerPID bilan).
    private func isOnScreen(_ p: NSPanel) -> Bool {
        let num = UInt32(max(0, p.windowNumber))
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return true }   // ro'yxatni ololmadik — tuzatishga urinmaymiz, yomonlashtirmaylik
        return list.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == num }
    }

    private func ensurePanel() -> (NSPanel, CapsuleView) {
        if let p = panel, let v = view { return (p, v) }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.level = capsuleLevel
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true             // tizim soyasi — yumshoqroq
        p.ignoresMouseEvents = false
        p.appearance = NSAppearance(named: .vibrantDark)
        applySpaces(p)

        // Matoviy shisha fon (orqadagi tasvirni xiralashtiradi)
        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        // .behindWindow rejimida layer.cornerRadius ishlamaydi — kapsula shaklini
        // maskImage bilan beramiz (aks holda atrofida to'rtburchak fon ko'rinadi).
        let r = H / 2
        let mask = NSImage(size: NSSize(width: r * 2 + 1, height: r * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        mask.resizingMode = .stretch
        blur.maskImage = mask

        let v = CapsuleView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        v.autoresizingMask = [.width, .height]
        v.onCancel = { [weak self] in self?.onCancel?() }
        v.onAccept = { [weak self] in self?.onAccept?() }
        blur.addSubview(v)

        p.contentView = blur
        panel = p; view = v
        return (p, v)
    }

    // MARK: - Kapsula qayerda chiqadi

    /// AX koordinatalari (chap-YUQORI boshlanish, y pastga o'sadi) → AppKit (chap-PAST, y yuqoriga).
    /// Asos — asosiy displey balandligi: barcha AX-to'rtburchaklar shunga nisbatan beriladi.
    private func axToAppKit(_ r: CGRect) -> CGRect {
        let primaryTop = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?
            .frame.maxY ?? 0
        return CGRect(x: r.origin.x, y: primaryTop - r.maxY, width: r.width, height: r.height)
    }

    private func axRect(_ el: AXUIElement, _ attr: String) -> CGRect? {
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &val) == .success,
              let v = val, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var out = CGRect.zero
        // Pozitsiya va o'lcham alohida atributlar: ikkalasini ham o'qib, to'rtburchak yig'amiz.
        if attr == kAXPositionAttribute as String {
            var pt = CGPoint.zero
            guard AXValueGetValue(v as! AXValue, .cgPoint, &pt) else { return nil }
            out = CGRect(origin: pt, size: .zero)
        } else if AXValueGetValue(v as! AXValue, .cgRect, &out) == false {
            return nil
        }
        return out
    }

    /// Matn kiritish joyi (karetka) yoki faol oyna — ekran koordinatalarida, AppKit tizimida.
    /// Nil qaytsa — chaqiruvchi sichqoncha ostidagi ekranga qaytadi.
    private func focusRect() -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let sys = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let fr = focusedRef, CFGetTypeID(fr) == AXUIElementGetTypeID() else { return nil }
        let el = fr as! AXUIElement

        // 1) Karetka: tanlangan matn diapazoni → uning ekrandagi to'rtburchagi.
        //    Nativ maydonlarda ishlaydi; Electron/veb ilovalarda ko'pincha yo'q — shunda 2-bosqich.
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rr = rangeRef, CFGetTypeID(rr) == AXValueGetTypeID() {
            var boundsRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                el, kAXBoundsForRangeParameterizedAttribute as CFString, rr, &boundsRef) == .success,
               let br = boundsRef, CFGetTypeID(br) == AXValueGetTypeID() {
                var r = CGRect.zero
                if AXValueGetValue(br as! AXValue, .cgRect, &r), r.height > 0, r.height < 200 {
                    return axToAppKit(r)
                }
            }
        }

        // 2) Fokusdagi element joylashgan OYNA (Electron/veb uchun ham ishlaydi).
        var winRef: CFTypeRef?
        var winEl: AXUIElement?
        if AXUIElementCopyAttributeValue(el, kAXWindowAttribute as CFString, &winRef) == .success,
           let wr = winRef, CFGetTypeID(wr) == AXUIElementGetTypeID() {
            winEl = (wr as! AXUIElement)
        } else if let app = NSWorkspace.shared.frontmostApplication {
            // Fokusdagi element oynani bermasa — old plandagi ilovaning faol oynasini so'raymiz.
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            var w: CFTypeRef?
            if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &w) == .success,
               let ww = w, CFGetTypeID(ww) == AXUIElementGetTypeID() {
                winEl = (ww as! AXUIElement)
            }
        }
        if let w = winEl,
           let pos = axRect(w, kAXPositionAttribute as String),
           let size = axRect(w, kAXSizeAttribute as String) {
            let r = CGRect(x: pos.origin.x, y: pos.origin.y, width: size.width, height: size.height)
            if r.width > 40, r.height > 40 { return axToAppKit(r) }
        }
        return nil
    }

    /// Old plandagi ilovaning eng ustki oynasi — QUARTZ orqali (AX'siz).
    /// Kerak, chunki hamma ilova ham AX'ni bermaydi: masalan Telegram Desktop (Qt) na karetkani,
    /// na oynani qaytaradi — o'lchov bilan tasdiqlangan (log: `place src=screen app=Telegram`).
    /// CGWindowList esa tizim darajasida ishlaydi va har qanday ilovaning oynasini ko'radi.
    private func frontWindowRect() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for w in list {                                   // ro'yxat ustki oynadan boshlanadi
            // ⚠️ Lug'atdagi sonlar — NSNumber. To'g'ridan-to'g'ri `as? pid_t` deb olish HECH QACHON
            // ishlamaydi (o'lchov: Telegram oynasi topilmay, kapsula ekran pastiga tushib qolgan).
            guard (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  ((w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1) == 0, // 0 — oddiy oyna
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let ww = b["Width"], let hh = b["Height"],
                  ww > 120, hh > 120 else { continue }
            return axToAppKit(CGRect(x: x, y: y, width: ww, height: hh))
        }
        return nil
    }

    /// Kapsula HAR DOIM pastda, o'rtada turadi — egasining talabi 27.07.2026: kursor ortidan
    /// sakrab yurgani noqulay ("hoh qayerda bosay, pastda, o'rtada chiqsin").
    /// Karetka/oyna esa baribir kerak, lekin faqat BITTA narsa uchun: qaysi EKRANDA turibmiz.
    /// Ilgari `NSScreen.main` ishlatilardi — fon ilovasi uchun u deyarli doim ASOSIY ekranni
    /// qaytaradi, shuning uchun to'liq ekranli ilovada yozayotganda kapsula ish stolida qolib
    /// ketardi. Ekranni topish tartibi: karetka → AX-oyna → Quartz-oyna → sichqoncha.
    private func place(_ p: NSPanel) {
        let anchor = focusRect() ?? frontWindowRect()
        let mouse = NSEvent.mouseLocation
        let screen = anchor.flatMap { r in NSScreen.screens.first { $0.frame.intersects(r) } }
            ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let scr = screen else { return }
        let vis = scr.visibleFrame

        // Doimiy joy: pastki chekkadan 46 px yuqorida, gorizontal — markazda.
        var origin = NSPoint(x: vis.midX - W / 2, y: vis.minY + 46)
        origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - W - 8)
        origin.y = min(max(origin.y, vis.minY + 8), vis.maxY - H - 8)
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        rlog("[rubai] place app=\(app) ekran=\(Int(vis.minX)),\(Int(vis.minY)) \(Int(vis.width))x\(Int(vis.height)) → \(Int(origin.x)),\(Int(origin.y))")
        p.setFrameOrigin(origin)
    }

    func showRecording(lang: String) {
        let (p, v) = ensurePanel()
        v.mode = .recording
        v.lang = lang
        v.levels = Array(repeating: 0.03, count: v.levels.count)
        v.targets = v.levels
        v.phase = 0
        currentLevel = 0
        place(p)
        appear(p)
        startAnimation()
        v.needsDisplay = true
    }

    func showProcessing() {
        let (p, v) = ensurePanel()
        v.mode = .processing
        place(p)
        appear(p)
        startAnimation()
        v.needsDisplay = true
    }

    // Mikrofondan kelgan daraja — faqat yig'iladi, chizishni taymer boshqaradi.
    // Assimetrik filtr (haqiqiy VU-o'lchagichlardagidek): ovoz kelganda tez
    // ko'tariladi, jimlikda esa asta tushadi — shuning uchun "qayerda gapirdim,
    // qayerda jim turdim" aniq ko'rinadi.
    func push(level: Float) {
        let v = CGFloat(level)
        currentLevel = v > currentLevel
            ? currentLevel * 0.35 + v * 0.65      // hujum — tez
            : currentLevel * 0.82 + v * 0.18      // so'nish — yumshoq
    }

    // Номер показа: анимация скрытия завершается через 0,12 с и не должна убрать
    // то, что показали после неё (например «Скопировано» сразу за результатом).
    private var showGen = 0

    private func appear(_ p: NSPanel) {
        showGen += 1
        applySpaces(p)   // Space'ga oid xatti-harakat ba'zan tiklanadi — har safar qayta qo'yamiz
        if !p.isVisible {
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.13
                p.animator().alphaValue = 1
            }
        } else {
            // Через animator, а не присваиванием: иначе идущая анимация скрытия
            // продолжит гасить окно до нуля поверх нового показа.
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.06
                p.animator().alphaValue = 1
            }
        }
        verifyVisible(p)   // ko'rsatdik deb ishonmaymiz — tekshiramiz
    }

    // Bitta 60 Hz taymer: to'lqin nishon qiymatlarga silliq intiladi (lerp),
    // shuning uchun harakat sakramaydi. Jimlikda o'zgarish bo'lmaydi —
    // qayta chizish ham bo'lmaydi, ya'ni protsessor bekorga qizimaydi.
    private func startAnimation() {
        timer?.invalidate()
        frame = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
    }

    private func tick() {
        guard let v = view else { return }
        frame += 1
        let dt: CGFloat = 1.0 / 60.0
        switch v.mode {
        case .recording:
            // to'lqin uzluksiz oqadi: phase 0→1 orasida silliq o'sadi,
            // 1 ga yetganda tarix bir qadam suriladi (sakrash ko'rinmaydi)
            v.phase += dt / 0.07
            if v.phase >= 1 {
                v.phase -= 1
                v.targets.removeFirst()
                v.targets.append(currentLevel)
            }
            var changed = false
            for i in v.levels.indices {
                let d = v.targets[i] - v.levels[i]
                if abs(d) > 0.0015 { v.levels[i] += d * 0.3; changed = true }
            }
            // jimlikda hech narsa o'zgarmasa — qayta chizmaymiz (protsessor bo'sh turadi)
            if changed { v.needsDisplay = true }
        case .processing:
            v.spinPhase += dt * 3.4
            v.dotsPhase += dt * 5.2
            v.needsDisplay = true
        case .message:
            break
        }
    }

    func hide() {
        timer?.invalidate(); timer = nil
        guard let p = panel, p.isVisible else { return }
        let gen = showGen
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.12
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak p] in
            guard let self = self, self.showGen == gen else { return }
            p?.orderOut(nil)
        })
    }

    // Xato xabari — kapsula ichida qisqa matn
    func flash(_ text: String, seconds: TimeInterval = 3.0) {
        let (p, v) = ensurePanel()
        timer?.invalidate(); timer = nil
        v.mode = .message
        v.messageText = text
        place(p); appear(p)
        v.needsDisplay = true
        rlog("[rubai] overlay: \(text)")
        let gen = showGen
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self = self, self.showGen == gen else { return }   // уже показано другое
            self.hide()
        }
    }
}

// MARK: - Matnni faol input'ga kiritish (clipboard + ⌘V)

enum Inserter {
    // ⌘V yuborishdan oldin chaqiriladi: sintetik Cmd bosish "tap" deb
    // hisoblanib qolmasligi uchun detektor vaqtincha o'chiriladi.
    static var willPaste: (() -> Void)?

    // Accessibility ruxsati yo'q bo'lsa chaqiriladi (matn buferda qoladi)
    static var onNoAccessibility: (() -> Void)?

    // Курсора (поля ввода) нет — текст только скопирован, ⌘V не отправлялся
    static var onCopiedOnly: (() -> Void)?

    // Роли, в которых точно нет места для текста: список файлов, таблица, кнопка…
    // AXGroup/AXWebArea сюда НЕ входят — так выглядят и Electron/веб-приложения
    // с настоящим полем ввода; там безопаснее вставить (текст всё равно в буфере).
    private static let nonTextRoles: Set<String> = [
        "AXList", "AXOutline", "AXTable", "AXBrowser", "AXScrollArea", "AXButton",
        "AXRow", "AXCell", "AXImage", "AXMenuBar", "AXMenuItem", "AXCheckBox",
        "AXRadioButton", "AXSlider", "AXToolbar", "AXSplitGroup", "AXTabGroup",
        "AXPopUpButton", "AXWindow", "AXApplication", "AXStaticText",
    ]
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    // Есть ли куда вставлять. false — только когда УВЕРЕНЫ, что поля ввода нет.
    // Системный AXFocusedUIElement на macOS 26 отвечает -25204 (замер 25.09.2026),
    // поэтому спрашиваем у активного приложения.
    // Electron/Chromium (Claude, Telegram Desktop, VS Code, Slack…) не строят дерево
    // доступности, пока его не попросить: фокус отвечает -25212 даже при курсоре в поле,
    // и текст раньше только копировался (замер 25.09.2026, Claude.app). Флаг
    // AXManualAccessibility будит дерево; зовём на старте записи — к ⌘ оно уже готово.
    static func wakeAccessibility(_ app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) {
        guard let app = app else { return }
        let ae = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(ae, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    static func hasTextTarget() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return true }
        let ae = AXUIElementCreateApplication(app.processIdentifier)
        var f: CFTypeRef?
        var err = AXUIElementCopyAttributeValue(ae, kAXFocusedUIElementAttribute as CFString, &f)
        if err == .noValue {
            // Дерево могло не проснуться (приложение переключили во время записи).
            wakeAccessibility(app)
            usleep(150_000)
            err = AXUIElementCopyAttributeValue(ae, kAXFocusedUIElementAttribute as CFString, &f)
        }
        if err == .noValue {
            // Окно есть, а фокус не отдают — скорее всего поле, которого AX не видит.
            // Копировать-только — лишь когда у приложения вообще нет окна.
            var w: CFTypeRef?
            let hasWindow = AXUIElementCopyAttributeValue(ae, kAXFocusedWindowAttribute as CFString, &w) == .success
            rlog("[rubai] fokus yo'q (\(app.localizedName ?? "?")) oyna=\(hasWindow)")
            return hasWindow && app.bundleIdentifier != "com.apple.finder"
        }
        guard err == .success, let fr = f, CFGetTypeID(fr) == AXUIElementGetTypeID() else { return true }
        let el = fr as! AXUIElement
        var r: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r)
        let role = (r as? String) ?? ""
        if textRoles.contains(role) { return true }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue { return true }
        // Рабочий стол / окно Finder без поля переименования — AXGroup.
        let finderDesk = app.bundleIdentifier == "com.apple.finder" && role == "AXGroup"
        let none = nonTextRoles.contains(role) || finderDesk
        rlog("[rubai] fokus: \(app.localizedName ?? "?") role=\(role) → \(none ? "maydon yo'q" : "qo'yamiz")")
        return !none
    }

    static func insert(_ text: String) {
        let trusted = AXIsProcessTrusted()
        rlog("[rubai] insert: len=\(text.count) AXTrusted=\(trusted)")
        guard !text.isEmpty else { rlog("[rubai] insert: matn bo'sh, to'xtatildi"); return }
        // Текст ВСЕГДА остаётся в буфере (раньше прежний буфер возвращался через 0,6 с,
        // и если вставить было некуда — диктовка терялась). Владелец: «если курсора
        // нигде нет — пусть просто скопируется, потом я вставлю».
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Ruxsat yo'q — sintetik ⌘V ishlamaydi. Eski buferni QAYTARMAYMIZ,
        // aks holda matn butunlay yo'qoladi: foydalanuvchi o'zi ⌘V bosa oladi.
        guard trusted else {
            rlog("[rubai] Accessibility yo'q — matn faqat buferga qo'yildi")
            onNoAccessibility?()
            return
        }

        guard hasTextTarget() else {
            rlog("[rubai] maydon yo'q — faqat nusxalandi")
            onCopiedOnly?()
            return
        }

        willPaste?()
        // ⌘V yuborish (Accessibility ruxsati kerak)
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // 'v'
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
        rlog("[rubai] ⌘V yuborildi (down=\(down != nil) up=\(up != nil))")
    }
}

// MARK: - Command tugmasi "tap"lari (2× = boshlash, 1× = to'xtatish)

final class CommandTapDetector {
    var onTap: ((Int) -> Void)?      // seriyadagi tap raqami: 1, 2, 3…
    var onEscape: (() -> Void)?

    private var globalMon: Any?
    private var localMon: Any?

    private var cmdDown = false
    private var cmdDownAt: TimeInterval = 0
    private var dirty = false        // Cmd bilan birga boshqa tugma/modifier bosildi
    private var tapCount = 0
    private var lastTapAt: TimeInterval = 0
    private var muteUntil: TimeInterval = 0
    private var eventCountAtDown: UInt32 = 0

    // Tizim hisoblagichlari: ⌘ bosilgan paytda boshqa tugma yoki sichqoncha
    // bosilganini aniqlaydi. NSEvent monitorlaridan farqli — bu Accessibility
    // ruxsatiga bog'liq emas, shuning uchun ⌘C / ⌘V hech qachon "tap" bo'lmaydi.
    private static func inputEventCount() -> UInt32 {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        var n: UInt32 = 0
        for t in types {
            n &+= UInt32(truncatingIfNeeded: CGEventSource.counterForEventType(.combinedSessionState, eventType: t))
        }
        return n
    }

    private let maxHold: TimeInterval = 0.35     // uzoq ushlash — tap emas
    private let seriesGap: TimeInterval = 0.35   // shu oraliqda kelgan taplar — bitta seriya

    private var tapPort: CFMachPort?
    private var tapSource: CFRunLoopSource?

    // CGEventTap — Accessibility ruxsati bilan ishlaydi (Hammerspoon ham shunday).
    // NSEvent global monitorlari esa alohida "Input Monitoring" ruxsatini talab
    // qiladi — u bo'lmasa jimgina hech narsa kelmaydi. Shuning uchun asosiy yo'l
    // — event tap, monitorlar faqat zaxira.
    private var watchdog: Timer?

    func install() {
        installTap()
        startWatchdog()
    }

    // Uyqudan uyg'onish, ekran qulfi, foydalanuvchi seansi almashishi —
    // bularning har biri event tap'ni o'chirib qo'yishi mumkin. Shuning uchun
    // uni doimiy kuzatamiz va tiklaymiz: "ertaga ham, bir haftadan keyin ham
    // xuddi shunday ishlasin".
    private func startWatchdog() {
        watchdog?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.checkAlive()
        }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t

        let nc = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [NSWorkspace.didWakeNotification,
                                          NSWorkspace.screensDidWakeNotification,
                                          NSWorkspace.sessionDidBecomeActiveNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                rlog("[rubai] tizim uyg'ondi — tap tekshirilmoqda")
                self?.checkAlive()
            }
        }
    }

    private func checkAlive() {
        guard let p = tapPort else { installTap(); return }
        if !CGEvent.tapIsEnabled(tap: p) {
            rlog("[rubai] tap o'chib qolgan — yoqilmoqda")
            CGEvent.tapEnable(tap: p, enable: true)
            if !CGEvent.tapIsEnabled(tap: p) {
                rlog("[rubai] yoqilmadi — qaytadan yaratamiz")
                teardownTap()
                installTap()
            }
        }
    }

    private func teardownTap() {
        if let s = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        if let p = tapPort { CFMachPortInvalidate(p) }
        tapSource = nil; tapPort = nil
    }

    private func installTap() {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
                              | (1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        if let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                        place: .tailAppendEventTap,
                                        options: .listenOnly,
                                        eventsOfInterest: mask,
                                        callback: rubaiTapCallback,
                                        userInfo: me) {
            tapPort = port
            tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            rlog("[rubai] CGEventTap o'rnatildi (AXTrusted=\(AXIsProcessTrusted()))")
        } else {
            rlog("[rubai] CGEventTap yaratilmadi — NSEvent monitorlari (zaxira)")
            guard globalMon == nil else { return }   // takroriy o'rnatishdan saqlanamiz
            let m: NSEvent.EventTypeMask = [.flagsChanged, .keyDown,
                                            .leftMouseDown, .rightMouseDown, .otherMouseDown]
            globalMon = NSEvent.addGlobalMonitorForEvents(matching: m) { [weak self] e in
                self?.handle(e)
            }
            localMon = NSEvent.addLocalMonitorForEvents(matching: m) { [weak self] e in
                self?.handle(e); return e
            }
        }
    }

    // Tizim tap'ni o'chirib qo'ysa (timeout) — qayta yoqamiz
    fileprivate func reenable() {
        if let p = tapPort {
            CGEvent.tapEnable(tap: p, enable: true)
            rlog("[rubai] CGEventTap qayta yoqildi")
        }
    }

    fileprivate func handleCG(_ type: CGEventType, _ event: CGEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        let f = event.flags

        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 { onEscape?() }
            if cmdDown { dirty = true }          // ⌘ bilan birikma
            return
        }
        guard type == .flagsChanged else { return }

        let cmd = f.contains(.maskCommand)
        let others = f.contains(.maskControl) || f.contains(.maskAlternate)
                  || f.contains(.maskShift)   || f.contains(.maskSecondaryFn)

        if cmd && !cmdDown {
            cmdDown = true; cmdDownAt = now; dirty = others
            eventCountAtDown = CommandTapDetector.inputEventCount()
        } else if cmd && cmdDown {
            if others { dirty = true }
        } else if !cmd && cmdDown {
            cmdDown = false
            let held = now - cmdDownAt
            let usedWithOther = CommandTapDetector.inputEventCount() != eventCountAtDown
            let clean = !dirty && !others && !usedWithOther && held <= maxHold && now >= muteUntil
            dirty = false
            if clean { registerTap(now) }
        }
    }

    private func registerTap(_ now: TimeInterval) {
        if now - lastTapAt > seriesGap { tapCount = 0 }
        lastTapAt = now
        tapCount += 1
        onTap?(tapCount)
    }

    // Sintetik ⌘V ni o'z tapimiz deb o'ylamaslik uchun
    func mute(_ seconds: TimeInterval) {
        muteUntil = ProcessInfo.processInfo.systemUptime + seconds
        cmdDown = false; dirty = false
    }

    func resetSeries() { tapCount = 0 }

    private func handle(_ e: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime

        if e.type == .keyDown, e.keyCode == UInt16(kVK_Escape) {
            onEscape?()
        }

        guard e.type == .flagsChanged else {
            if cmdDown { dirty = true }   // ⌘C, ⌘V, ⌘Tab, sichqoncha bilan…
            return
        }

        let f = e.modifierFlags
        let cmd = f.contains(.command)
        let others = f.contains(.control) || f.contains(.option)
                  || f.contains(.shift)   || f.contains(.function)

        if cmd && !cmdDown {
            cmdDown = true; cmdDownAt = now; dirty = others
            eventCountAtDown = CommandTapDetector.inputEventCount()
        } else if cmd && cmdDown {
            if others { dirty = true }
        } else if !cmd && cmdDown {
            cmdDown = false
            let held = now - cmdDownAt
            // ⌘ ushlab turilganda birorta tugma/sichqoncha bosilgan bo'lsa — bu birikma
            let usedWithOther = CommandTapDetector.inputEventCount() != eventCountAtDown
            let clean = !dirty && !others && !usedWithOther && held <= maxHold && now >= muteUntil
            dirty = false
            if clean { registerTap(now) }
        }
    }
}

// CGEventTap chaqiruvi (C-funksiya): obyektga qaytib, hodisani o'zgarishsiz uzatadi.
private func rubaiTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                              event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let me = Unmanaged<CommandTapDetector>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        me.reenable()
    } else {
        me.handleCG(type, event)
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - Zaxira hotkey sozlamasi (UserDefaults'da saqlanadi)

struct HotKeyConfig {
    var keyCode: UInt32          // virtual key code (masalan kVK_ANSI_D)
    var carbonModifiers: UInt32  // controlKey | optionKey | ...
    var label: String            // ekranda ko'rsatiladigan tugma nomi, masalan "D"

    static let `default` = HotKeyConfig(keyCode: UInt32(kVK_ANSI_D),
                                        carbonModifiers: UInt32(controlKey | optionKey),
                                        label: "D")

    // Ekranda ko'rinishi, masalan "⌃⌥D"
    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s + label
    }
}

enum HotKeyStore {
    private static let d = UserDefaults.standard
    static func load() -> HotKeyConfig {
        guard d.object(forKey: "hk.keyCode") != nil else { return .default }
        return HotKeyConfig(keyCode: UInt32(d.integer(forKey: "hk.keyCode")),
                            carbonModifiers: UInt32(d.integer(forKey: "hk.mods")),
                            label: d.string(forKey: "hk.label") ?? "?")
    }
    static func save(_ c: HotKeyConfig) {
        d.set(Int(c.keyCode), forKey: "hk.keyCode")
        d.set(Int(c.carbonModifiers), forKey: "hk.mods")
        d.set(c.label, forKey: "hk.label")
    }
}

// NSEvent modifier'larini Carbon maskasiga o'girish
func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var m: UInt32 = 0
    if flags.contains(.control) { m |= UInt32(controlKey) }
    if flags.contains(.option)  { m |= UInt32(optionKey) }
    if flags.contains(.shift)   { m |= UInt32(shiftKey) }
    if flags.contains(.command) { m |= UInt32(cmdKey) }
    return m
}

// keyDown hodisasidan tugmaning ko'rinadigan nomini olish
func keyLabel(for event: NSEvent) -> String {
    let special: [UInt16: String] = [
        UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥",
        UInt16(kVK_Escape): "⎋", UInt16(kVK_Delete): "⌫", UInt16(kVK_ForwardDelete): "⌦",
        UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_Home): "↖", UInt16(kVK_End): "↘", UInt16(kVK_PageUp): "⇞", UInt16(kVK_PageDown): "⇟",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
    ]
    if let s = special[event.keyCode] { return s }
    if let c = event.charactersIgnoringModifiers, !c.isEmpty,
       c.rangeOfCharacter(from: .controlCharacters) == nil {
        return c.uppercased()
    }
    return "Key\(event.keyCode)"
}

// MARK: - Global hotkey (Carbon) -> Notification

extension Notification.Name { static let rubaiHotkey = Notification.Name("rubaiHotkey") }

private func hotkeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ ud: UnsafeMutableRawPointer?) -> OSStatus {
    NotificationCenter.default.post(name: .rubaiHotkey, object: nil)
    return noErr
}

final class HotKey {
    private var ref: EventHotKeyRef?
    private var installed = false

    // Hodisa qabul qiluvchini bir marta o'rnatib, hozirgi sozlamani qo'llaydi
    func install() {
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let s1 = InstallEventHandler(GetApplicationEventTarget(), hotkeyHandler, 1, &spec, nil, nil)
            rlog("[rubai] hotkey handler o'rnatildi: \(s1) (0 = OK)")
            installed = true
        }
        apply(HotKeyStore.load())
    }

    // Eski tugmani bekor qilib, yangisini ro'yxatdan o'tkazadi
    func apply(_ c: HotKeyConfig) {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
        let id = EventHotKeyID(signature: OSType(0x52535454), id: 1) // 'RSTT'
        let s = RegisterEventHotKey(c.keyCode, c.carbonModifiers, id,
                                    GetApplicationEventTarget(), 0, &ref)
        rlog("[rubai] hotkey ro'yxatdan o'tkazildi \(c.displayString): \(s) (0 = OK)")
    }
}

// MARK: - Sozlamalar oynasi (zaxira tugmani yozib olish)

final class SettingsWindow {
    private var window: NSWindow?
    private var monitor: Any?
    private var recordButton: NSButton!
    private var hintLabel: NSTextField!
    private var current: HotKeyConfig
    private var recording = false
    var onChange: ((HotKeyConfig) -> Void)?

    init(_ c: HotKeyConfig) { current = c }

    func update(_ c: HotKeyConfig) { current = c; refreshButton() }

    func show() {
        if window == nil { build() }
        stopRecording()
        refreshButton()
        NSApp.activate(ignoringOtherApps: true)
        window!.center()
        window!.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 230),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "RubaiSTT — Настройки"
        w.isReleasedWhenClosed = false
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 230))

        let main = NSTextField(labelWithString: "Основной способ: клавиша ⌘")
        main.font = .systemFont(ofSize: 14, weight: .semibold)
        main.frame = NSRect(x: 24, y: 188, width: 332, height: 20)
        v.addSubview(main)

        let mainHint = NSTextField(wrappingLabelWithString:
            "⌘⌘ (левая или правая) — начать запись\n⌘ — остановить и вставить текст\n⎋ — отмена")
        mainHint.font = .systemFont(ofSize: 11)
        mainHint.textColor = .secondaryLabelColor
        mainHint.frame = NSRect(x: 24, y: 128, width: 332, height: 56)
        v.addSubview(mainHint)

        let title = NSTextField(labelWithString: "Запасное сочетание клавиш")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 24, y: 100, width: 332, height: 18)
        v.addSubview(title)

        recordButton = NSButton(title: current.displayString, target: self, action: #selector(toggleRecord))
        recordButton.bezelStyle = .rounded
        recordButton.font = .systemFont(ofSize: 16, weight: .medium)
        recordButton.frame = NSRect(x: 24, y: 60, width: 332, height: 34)
        v.addSubview(recordButton)

        hintLabel = NSTextField(labelWithString: "Нажмите, чтобы изменить.")
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.frame = NSRect(x: 24, y: 42, width: 332, height: 16)
        v.addSubview(hintLabel)

        let reset = NSButton(title: "Вернуть по умолчанию (⌃⌥D)", target: self, action: #selector(resetDefault))
        reset.bezelStyle = .rounded
        reset.frame = NSRect(x: 24, y: 12, width: 332, height: 26)
        v.addSubview(reset)

        w.contentView = v
        window = w
    }

    private func refreshButton() {
        recordButton.title = recording ? "Нажмите сочетание…" : current.displayString
        hintLabel.stringValue = recording
            ? "Модификатор (⌃ ⌥ ⌘ ⇧) + клавиша. Отмена: ⎋"
            : "Нажмите, чтобы изменить."
    }

    @objc private func toggleRecord() {
        if recording { stopRecording() } else { startRecording() }
        refreshButton()
    }

    @objc private func resetDefault() {
        stopRecording()
        current = .default
        refreshButton()
        onChange?(current)
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return event }
            // ⎋ — bekor qilish
            if event.keyCode == UInt16(kVK_Escape) {
                self.stopRecording(); self.refreshButton(); return nil
            }
            let mods = carbonModifiers(from: event.modifierFlags)
            // Kamida bitta modifier shart (aks holda oddiy tugma global qotib qoladi)
            guard mods != 0 else {
                self.hintLabel.stringValue = "Нужен хотя бы один модификатор (⌃ ⌥ ⌘ ⇧)!"
                return nil
            }
            let cfg = HotKeyConfig(keyCode: UInt32(event.keyCode),
                                   carbonModifiers: mods,
                                   label: keyLabel(for: event))
            self.current = cfg
            self.stopRecording()
            self.refreshButton()
            self.onChange?(cfg)
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

// MARK: - Login'da ishga tushirish (SMAppService)

enum LoginItem {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            rlog("[rubai] login item xato: \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Xush kelibsiz / ruxsat onboarding oynasi (birinchi ishga tushishda)

final class WelcomeWindow {
    private var window: NSWindow?
    private var statusTimer: Timer?
    private var micDot: NSTextField!
    private var axDot: NSTextField!
    var hotkeyText: String = "⌃⌥D"

    func show() {
        if window == nil { build() }
        refreshStatus()
        NSApp.activate(ignoringOtherApps: true)
        window!.center()
        window!.makeKeyAndOrderFront(nil)
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    private func build() {
        let W: CGFloat = 460, H: CGFloat = 420
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "RubaiSTT Диктовка"
        w.isReleasedWhenClosed = false
        let v = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))

        // Ikona
        let iconView = NSImageView(frame: NSRect(x: (W - 72) / 2, y: H - 96, width: 72, height: 72))
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        v.addSubview(iconView)

        let title = NSTextField(labelWithString: "Добро пожаловать!")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.alignment = .center
        title.frame = NSRect(x: 0, y: H - 130, width: W, height: 26)
        v.addSubview(title)

        let sub = NSTextField(wrappingLabelWithString:
            "Нажмите ⌘ дважды → говорите → нажмите ⌘ один раз, текст вставится.\nЗапасное сочетание: \(hotkeyText)")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor
        sub.alignment = .center
        sub.frame = NSRect(x: 20, y: H - 168, width: W - 40, height: 34)
        v.addSubview(sub)

        // 1-qadam: Mikrofon
        micDot = stepRow(in: v, y: H - 220,
                         title: "1. Доступ к микрофону",
                         desc: "Чтобы слышать ваш голос.",
                         button: "Разрешить", action: #selector(askMic))
        // 2-qadam: Accessibility
        axDot = stepRow(in: v, y: H - 280,
                        title: "2. Универсальный доступ",
                        desc: "Чтобы слышать ⌘ и вставлять текст.",
                        button: "Открыть", action: #selector(openAX))

        // Login'da ishga tushirish
        let loginCheck = NSButton(checkboxWithTitle: "Запускать автоматически при включении",
                                  target: self, action: #selector(toggleLogin(_:)))
        loginCheck.state = LoginItem.isEnabled ? .on : .off
        loginCheck.frame = NSRect(x: 30, y: 70, width: W - 60, height: 20)
        v.addSubview(loginCheck)

        let done = NSButton(title: "Готово", target: self, action: #selector(closeWindow))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.frame = NSRect(x: W - 150, y: 20, width: 120, height: 32)
        v.addSubview(done)

        w.contentView = v
        window = w
    }

    // Bitta qadam qatori: holat nuqtasi + sarlavha + tugma. Holat nuqtasini qaytaradi.
    private func stepRow(in parent: NSView, y: CGFloat, title: String, desc: String,
                         button: String, action: Selector) -> NSTextField {
        let dot = NSTextField(labelWithString: "○")
        dot.font = .systemFont(ofSize: 16)
        dot.frame = NSRect(x: 30, y: y, width: 22, height: 22)
        parent.addSubview(dot)

        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        t.frame = NSRect(x: 54, y: y + 4, width: 240, height: 18)
        parent.addSubview(t)

        let d = NSTextField(labelWithString: desc)
        d.font = .systemFont(ofSize: 11)
        d.textColor = .secondaryLabelColor
        d.frame = NSRect(x: 54, y: y - 14, width: 260, height: 16)
        parent.addSubview(d)

        let b = NSButton(title: button, target: self, action: action)
        b.bezelStyle = .rounded
        b.frame = NSRect(x: parent.frame.width - 160, y: y - 4, width: 130, height: 28)
        parent.addSubview(b)
        return dot
    }

    private func refreshStatus() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        micDot.stringValue = mic ? "✅" : "○"
        axDot.stringValue = AXIsProcessTrusted() ? "✅" : "○"
    }

    @objc private func askMic() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async { self.refreshStatus() }
        }
    }

    @objc private func openAX() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        LoginItem.set(sender.state == .on)
        sender.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func closeWindow() {
        statusTimer?.invalidate(); statusTimer = nil
        window?.close()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let rec = Recorder()
    private let overlay = Overlay()
    private let hotkey = HotKey()
    private let taps = CommandTapDetector()
    private var hkConfig = HotKeyStore.load()
    private var dictateItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var accurateItem: NSMenuItem!
    private var streamItem: NSMenuItem!
    private lazy var stream = StreamTranscriber(rec)

    // «Aniqroq rejim» — beam search. Sozlama saqlanadi.
    private var accurate: Bool {
        get { UserDefaults.standard.bool(forKey: "accurateMode") }
        set { UserDefaults.standard.set(newValue, forKey: "accurateMode") }
    }

    // «Gapirganda tanish» — bo'laklar yozish davomida tanilади (standart: yoqilgan).
    // O'chirilsa — eski yo'l: hamma narsa ⌘ dan keyin bir marta tanilади.
    private var streaming: Bool {
        get { UserDefaults.standard.object(forKey: "streamingMode") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "streamingMode") }
    }

    // Shu diktovka oqimli ketyaptimi. Yozish o'rtasida menyudan almashtirilsa
    // ham joriy diktovka boshlangan rejimda tugashi kerak.
    private var streamingNow = false


    private lazy var settings: SettingsWindow = {
        let s = SettingsWindow(hkConfig)
        s.onChange = { [weak self] cfg in self?.applyHotKey(cfg) }
        return s
    }()
    private lazy var welcome: WelcomeWindow = {
        let w = WelcomeWindow()
        w.hotkeyText = hkConfig.displayString
        return w
    }()

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar (Dock'da yo'q)
        // У меню-бар приложения нет окон, и macOS считает его кандидатом на
        // «автоматическое завершение» в простое (в журнале: WouldBeTerminatedByTAL=1).
        // Диктовка обязана ждать ⌘ всегда — запрещаем.
        ProcessInfo.processInfo.disableAutomaticTermination("diktovka ⌘ ni kutadi")
        ProcessInfo.processInfo.disableSuddenTermination()

        // Bluetooth kolonka mikrofon bo'lib qolmasin — diktovka boshlanishini
        // kutmasdan, hozirdanoq. Kolonka HFP'dan chiqadi va musiqa ham tiniq
        // chalinadi (HFP'da u 8 kHz — "telefon ovozi").
        InputDevice.keepSystemInputOffBluetooth()
        InputDevice.watchSystemInput()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "rubaiSTT")
        let menu = NSMenu()
        dictateItem = NSMenuItem(title: "Диктовка  (⌘⌘)", action: #selector(toggle), keyEquivalent: "")
        menu.addItem(dictateItem)
        menu.addItem(.separator())
        accurateItem = NSMenuItem(title: "Точный режим (медленнее)", action: #selector(toggleAccuracy), keyEquivalent: "")
        accurateItem.state = accurate ? .on : .off
        menu.addItem(accurateItem)
        streamItem = NSMenuItem(title: "Распознавать во время речи (быстрее)", action: #selector(toggleStreaming), keyEquivalent: "")
        streamItem.state = streaming ? .on : .off
        menu.addItem(streamItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ","))
        loginItem = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Открыть настройки Универсального доступа", action: #selector(openAX), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Инструкция…", action: #selector(openWelcome), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выйти", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        rubai_set_accuracy(accurate ? 1 : 0)

        // Zaxira birikma (⌃⌥D) — ishlashda qoladi
        hotkey.install()
        NotificationCenter.default.addObserver(self, selector: #selector(toggle), name: .rubaiHotkey, object: nil)

        // ⌘ tap'lari — asosiy usul
        taps.onTap = { [weak self] n in self?.handleTap(n) }
        taps.onEscape = { [weak self] in self?.cancel() }
        taps.install()
        Inserter.willPaste = { [weak self] in self?.taps.mute(0.8) }
        Inserter.onNoAccessibility = { [weak self] in self?.warnNoAccessibility() }
        Inserter.onCopiedOnly = { [weak self] in self?.overlay.flash("Скопировано · ⌘V", seconds: 2.2) }

        // Mikrofon darajasi -> ekvalayzer
        rec.onLevel = { [weak self] lvl in self?.overlay.push(level: lvl) }
        overlay.onCancel = { [weak self] in self?.cancel() }
        overlay.onAccept = { [weak self] in self?.stopAndTranscribe() }

        // Модель при запуске НЕ грузим: в простое приложение не должно занимать
        // память и процессор. Она грузится на старте записи (см. start()).

        // Birinchi ishga tushish — onboarding oynasi; aks holda jim Accessibility tekshiruvi
        let d = UserDefaults.standard
        if !d.bool(forKey: "didOnboard") {
            d.set(true, forKey: "didOnboard")
            LoginItem.set(true)                       // standart: login'da yonsin
            loginItem.state = LoginItem.isEnabled ? .on : .off
            welcome.show()
        } else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
    }

    // MARK: ⌘ tap mantiqi

    // ⌘⌘ (двойной тап левой или правой) — старт; одиночный ⌘ во время записи — стоп
    // и вставка. Старт двойным — чтобы случайное нажатие ⌘ не включало запись.
    private var recordStartedAt: TimeInterval = 0

    private func handleTap(_ n: Int) {
        if rec.isRecording {
            // Лишний тап той же серии, что запустила запись (⌘⌘⌘), — не стоп.
            if ProcessInfo.processInfo.systemUptime - recordStartedAt < 0.45 { return }
            stopAndTranscribe()
        } else if n == 2 {
            start()
        }
    }

    private func start() {
        recordStartedAt = ProcessInfo.processInfo.systemUptime
        // Модель грузится параллельно с речью — к моменту ⌘ она уже готова.
        Whisper.shared.preload()
        Inserter.wakeAccessibility()
        rec.start { [weak self] ok in
            guard let self = self else { return }
            rlog("[rubai] record start ok=\(ok)")
            if ok {
                self.streamingNow = self.streaming
                if self.streamingNow { self.stream.begin() }
                self.overlay.showRecording(lang: "ru")
                self.watchSilentMic()
            } else {
                self.overlay.flash("Нет доступа к микрофону", seconds: 2.0)
                Whisper.shared.scheduleUnload()
            }
        }
    }

    // Mikrofon o'lik bo'lsa — buni YOZUV OXIRIDA emas, darrov aytamiz.
    // 02.08.2026: Bluetooth-garnitura ulanib, transport ko'tarilmagan edi —
    // tizim ilovaga toza nol berdi. Kapsuladagi ekvalayzer qimirlamadi va bu
    // "ilova qotib qoldi"dek ko'rindi; egasi 88 soniya bekorga gapirdi, xato
    // esa faqat ⌘ bosilgandan keyin ko'rindi.
    private func watchSilentMic(after: TimeInterval = 1.5, lastChance: Bool = false) {
        let no = rec.sessionNo
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
            guard let self = self,
                  self.rec.isRecording, self.rec.sessionNo == no, !self.rec.sawSound else { return }

            // Bufer umuman kelmagan bo'lsa — bu hali "o'lik mikrofon" degani emas:
            // CoreAudio qurilma almashuvi ustida bo'lsa (masalan Bluetooth kolonka
            // HFP'ga o'tayotgan bo'lsa) grafimizga umuman bufer bermaydi. Bunda
            // grafni qayta yig'ib, yana bir imkon beramiz — odam buni sezmaydi ham.
            // Buferlar kelyapti-yu, ichi toza nol bo'lsa — mana bu o'lik kanal.
            if self.rec.buffersSeen == 0 && !lastChance, self.rec.restartEngine() {
                self.watchSilentMic(after: 2.0, lastChance: true)
                return
            }

            rlog("[rubai] mikrofon jim: \(self.rec.deviceName) — ovoz yo'q (bufer: \(self.rec.buffersSeen))")
            _ = self.rec.stop()
            if self.streamingNow { self.stream.abort(); self.streamingNow = false }
            self.taps.resetSeries()
            self.overlay.flash("Микрофон молчит", seconds: 2.5)   // qurilma nomi logda
            Whisper.shared.scheduleUnload()
        }
    }

    private func stopAndTranscribe() {
        guard rec.isRecording else { return }
        taps.resetSeries()
        let t0 = Date()
        let raw = rec.stop()

        // Jim yozuvda whisper "*qush sayrashi*", "(musiqa)" kabi narsalarni
        // o'ylab topadi va ular matn maydoniga tushib qoladi. Shuning uchun
        // umuman ovoz bo'lmasa — umuman tanimaymiz.
        let peak = Audio.peakLevel(raw)
        if peak < 0.012 {
            rlog("[rubai] jim yozuv (peak=\(String(format: "%.4f", peak))) — tanilmadi")
            if streamingNow { stream.abort(); streamingNow = false }
            overlay.flash("Голос не слышно", seconds: 1.4)
            Whisper.shared.scheduleUnload()
            return
        }

        let rawSec = String(format: "%.1f", Double(raw.count) / 16000.0)
        overlay.showProcessing()

        // Oqimli yo'l: yozish davomida bo'laklar allaqachon tanilgan, endi
        // faqat dum qoladi — kutish diktovka uzunligiga bog'liq emas.
        if streamingNow {
            streamingNow = false
            rlog("[rubai] stopped: \(rawSec)s (oqimli)")
            stream.finish(all: raw) { [weak self] text, chunks in
                rlog("[rubai] kutish: \(String(format: "%.2f", Date().timeIntervalSince(t0)))s (\(chunks) bo'lak)")
                self?.deliver(text)
            }
            return
        }

        // Eski yo'l — hammasi bir marta, ⌘ dan keyin.
        let trimmed = Audio.prepare(raw)
        rlog("[rubai] stopped: \(rawSec)s -> \(String(format: "%.1f", Double(trimmed.count)/16000.0))s (jimlik kesildi)")
        Whisper.shared.transcribe(trimmed) { [weak self] text in
            rlog("[rubai] kutish: \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
            self?.deliver(text)
        } fail: { [weak self] msg in
            rlog("[rubai] transcription XATO: \(msg)")
            self?.overlay.flash("⚠️ \(msg)")
            Whisper.shared.scheduleUnload()
        }
    }

    // Tanilgan matnni tozalab, faol maydonga qo'yish. Ikkala yo'l uchun bitta joy.
    private func deliver(_ text: String) {
        rlog("[rubai] natija: '\(text)' (uzunlik=\(text.count))")
        overlay.hide()
        Inserter.insert(Terms.fix(AppDelegate.collapseRepeats(AppDelegate.dropHallucination(text))))
        Whisper.shared.scheduleUnload()
    }

    // Whisper jimlikda "sahna izohi" o'ylab topadi: «[музыка]», «*звук птиц*»,
    // «(аплодисменты)». Ular matn ICHIDA ham, oxirida ham chiqadi — masalan
    // «...ясно понятно. [музыка]». Shuning uchun butun matnni emas, har bir
    // bo'lakni alohida tozalaymiz.
    //
    // [...] va *...* — diktovkada odam bunday yozdirmaydi, doim olib tashlaymiz.
    // (...) — faqat ichida "tovush" so'zlari bo'lsa yoki juda qisqa bo'lsa.
    private static let soundWords = [
        "музык", "звук", "шум", "смех", "аплодис", "тишин", "птиц", "аудио", "субтитр",
        "music", "sound", "noise", "laugh", "applause", "silence", "blank_audio", "subtitle",
        "musiqa", "tovush", "shovqin", "kulgi",
    ]

    static func dropHallucination(_ t: String) -> String {
        var s = t
        for (open, close, always) in [("[", "]", true), ("*", "*", true), ("(", ")", false)] {
            s = removeTags(in: s, open: open, close: close, always: always)
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // ortda qolgan yakka tinish belgilari
        while let f = s.first, ".,;:!?-—…".contains(f) {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if s != t.trimmingCharacters(in: .whitespacesAndNewlines) {
            rlog("[rubai] sahna izohlari tozalandi: '\(t)' -> '\(s)'")
        }
        return s
    }

    // Dekoder "sirg'alib" ketganda bitta jumlani qayta-qayta chiqaradi
    // (o'zbekchada 3.3 s yozuvda 9 marta takrorlangan holat kuzatilgan).
    // Asosiy himoya — harorat fallback'i (whisper_bridge.c), bu esa ikkinchi
    // qavat: ketma-ket takrorlangan bloklarni yig'ib tashlaymiz.
    //
    // k=1 (yakka so'z) uchun 3 martadan, k>=2 (jumla) uchun 2 martadan
    // boshlab qisqartiramiz — jonli nutqdagi «ha, ha» yoki «juda juda» qoladi.
    static func collapseRepeats(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        guard words.count > 3 else { return text }

        func norm(_ w: String) -> String {
            w.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:—-…\"'«»()"))
        }

        var changed = true
        var loops = 0
        while changed && loops < 40 {
            changed = false; loops += 1
            outer: for k in 1...max(1, min(14, words.count / 2)) {
                var i = 0
                while i + 2 * k <= words.count {
                    let a = words[i..<i+k].map(norm)
                    if a == words[i+k..<i+2*k].map(norm) {
                        var reps = 2
                        var j = i + 2 * k
                        while j + k <= words.count, words[j..<j+k].map(norm) == a { reps += 1; j += k }
                        if reps >= (k == 1 ? 3 : 2) {
                            words.removeSubrange((i + k)..<(i + k * reps))
                            changed = true
                            break outer
                        }
                    }
                    i += 1
                }
            }
        }
        let out = words.joined(separator: " ")
        if out != text { rlog("[rubai] takrorlar yig'ildi: \(text.count) -> \(out.count) belgi") }
        return out
    }

    private static func removeTags(in text: String, open: String, close: String, always: Bool) -> String {
        var out = text
        var guardCount = 0
        while guardCount < 20, let r1 = out.range(of: open) {
            let rest = out[r1.upperBound...]
            guard let r2 = rest.range(of: close) else { break }
            let inner = String(rest[..<r2.lowerBound])
            guardCount += 1
            guard inner.count <= 40 else { break }
            let low = inner.lowercased()
            // Yumaloq qavs uchun ehtiyot bo'lamiz: «(a + b)» kabi haqiqiy matnni
            // saqlaymiz, «(музыка)», «(права)» kabi bitta so'zlik izohni olib tashlaymiz.
            let singleWord = !inner.contains(" ") && inner.count <= 15
            let isSound = always || singleWord || soundWords.contains { low.contains($0) }
            guard isSound else { break }
            out.replaceSubrange(r1.lowerBound..<r2.upperBound, with: "")
            out = out.replacingOccurrences(of: "  ", with: " ")
        }
        return out
    }

    private func cancel() {
        guard rec.isRecording else { return }
        taps.resetSeries()
        _ = rec.stop()
        // Avlod ortadi: yo'lda qolgan bo'laklarning javoblari keyingi diktovkaga
        // aralashib ketmaydi.
        if streamingNow { stream.abort(); streamingNow = false }
        overlay.hide()
        Whisper.shared.scheduleUnload()
        rlog("[rubai] bekor qilindi")
    }

    // Accessibility yo'q: matn buferda qoldi. Bir marta sozlamalarni taklif qilamiz.
    private var axWarned = false
    private func warnNoAccessibility() {
        overlay.flash("Текст в буфере — ⌘V", seconds: 4)
        guard !axWarned else { return }
        axWarned = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let a = NSAlert()
            a.messageText = "Нет Универсального доступа"
            a.informativeText = "Поэтому текст не вставился сам — он в буфере обмена (вставьте ⌘V).\n\nНастройки → Конфиденциальность и безопасность → Универсальный доступ → включите «RubaiSTT Dictation»."
            a.addButton(withTitle: "Открыть настройки")
            a.addButton(withTitle: "Позже")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn {
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
    }

    @objc private func toggleAccuracy() {
        accurate.toggle()
        accurateItem.state = accurate ? .on : .off
        rubai_set_accuracy(accurate ? 1 : 0)
        rlog("[rubai] aniqroq rejim: \(accurate)")
        overlay.flash(accurate ? "Точный режим" : "Быстрый режим", seconds: 1.2)
    }

    @objc private func toggleStreaming() {
        streaming.toggle()
        streamItem.state = streaming ? .on : .off
        rlog("[rubai] gapirganda tanish: \(streaming)")
        overlay.flash(streaming ? "Во время речи" : "В конце", seconds: 1.2)
    }

    @objc private func toggleLogin() {
        LoginItem.set(!LoginItem.isEnabled)
        loginItem.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func openWelcome() {
        welcome.hotkeyText = hkConfig.displayString
        welcome.show()
    }

    // Yangi zaxira hotkey'ni qo'llab, saqlaydi
    private func applyHotKey(_ cfg: HotKeyConfig) {
        hkConfig = cfg
        HotKeyStore.save(cfg)
        hotkey.apply(cfg)
        settings.update(cfg)
    }

    @objc private func openSettings() { settings.show() }

    @objc private func openAX() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // Zaxira birikma va menyu uchun: bosildi -> boshla/to'xtat
    @objc private func toggle() {
        if rec.isRecording {
            stopAndTranscribe()
        } else {
            start()
        }
    }

    @objc private func quit() { rubai_unload(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ n: Notification) { rubai_unload() }
}

// Kirish nuqtasi. Endi bir nechta fayl kompilyatsiya qilinadi (audio.swift ham),
// shuning uchun "top-level" kod o'rniga @main — Swift boshqacha ruxsat bermaydi.
@main
struct RubaiSTTApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
