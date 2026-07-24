import SwiftUI
import AVFoundation
import AppKit
import Carbon.HIToolbox
import ApplicationServices
import ServiceManagement

// MARK: - Whisper (rubaiSTT) yadrosi

final class Whisper {
    static let shared = Whisper()
    private var loaded = false
    private let q = DispatchQueue(label: "rubai.whisper")

    // Fizik yadrolar soni (i9-9880H = 8). Hyper-threading yadrolarini qo'shish
    // whisper matmul'ini sekinlashtiradi, shuning uchun mantiqiy emas, fizik.
    static let threads: Int32 = {
        var n: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.physicalcpu", &n, &size, nil, 0) == 0, n > 0 { return n }
        return Int32(max(4, ProcessInfo.processInfo.activeProcessorCount / 2))
    }()

    private func modelPath() -> String? {
        if let p = Bundle.main.path(forResource: "ggml-rubaistt", ofType: "bin") { return p }
        let fb = NSHomeDirectory() + "/rubai-stt/models/ggml-rubaistt.bin"
        return FileManager.default.fileExists(atPath: fb) ? fb : nil
    }

    // Ilova ishga tushganda fonda chaqiriladi — birinchi diktovkadagi
    // ~1.3 s model yuklash kutishini yo'q qiladi.
    func preload(lang: String) {
        q.async {
            guard !self.loaded, let mp = self.modelPath() else { return }
            let t0 = Date()
            if rubai_preload(mp, lang) == 0 {
                self.loaded = true
                NSLog("[rubai] model oldindan yuklandi (\(lang)) \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
            }
        }
    }

    func setLanguage(_ lang: String) { rubai_set_language(lang) }

    func transcribe(_ samples: [Float], done: @escaping (String) -> Void,
                    fail: @escaping (String) -> Void = { _ in }) {
        q.async {
            if !self.loaded {
                guard let mp = self.modelPath() else {
                    NSLog("[rubai] XATO: model fayli topilmadi (bundle/uy)")
                    DispatchQueue.main.async { fail("Model fayli topilmadi") }; return
                }
                let rc = rubai_load(mp)
                NSLog("[rubai] rubai_load(\(mp)) = \(rc)")
                guard rc == 0 else {
                    DispatchQueue.main.async { fail("Model yuklanmadi (kod \(rc))") }; return
                }
                self.loaded = true
            }
            let t0 = Date()
            var text = ""
            samples.withUnsafeBufferPointer { buf in
                if let c = rubai_transcribe(buf.baseAddress, Int32(buf.count), Whisper.threads) {
                    text = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                    rubai_free_str(c)
                }
            }
            NSLog("[rubai] transcribe: \(String(format: "%.2f", Date().timeIntervalSince(t0)))s / audio \(String(format: "%.1f", Double(samples.count) / 16000.0))s")
            DispatchQueue.main.async { done(text) }
        }
    }

    func unload() { q.async { if self.loaded { rubai_unload(); self.loaded = false } } }
    var isLoaded: Bool { loaded }
}

// MARK: - Mikrofon (16kHz mono float32)

final class Recorder {
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 16000, channels: 1, interleaved: false)!
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false

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
        // Har yozishda YANGI engine — login'da/qurilma o'zgarganda qotib qolgan
        // (jim, "musiqa") holatdan saqlaydi.
        //
        // DIQQAT: engine'ni oldindan tayyorlab qo'yish (prepare()) mumkin emas —
        // AVAudioEngineGraph::Initialize ObjC-istisno tashlaydi, Swift uni ushlay
        // olmaydi va ilova qulaydi (SIGSEGV, 25.07.2026 da tekshirildi).
        engine = AVAudioEngine()
        let input = engine.inputNode
        let hw = input.outputFormat(forBus: 0)
        guard hw.sampleRate > 0 else { return false }
        converter = AVAudioConverter(from: hw, to: target)
        input.installTap(onBus: 0, bufferSize: 4096, format: hw) { [weak self] buf, _ in
            guard let self = self, let conv = self.converter else { return }
            let ratio = self.target.sampleRate / hw.sampleRate
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
                self.lock.unlock()

                // RMS -> daraja. Sekundiga ~30 marta yuboramiz (CPU'ni bekorga isitmaslik uchun).
                if self.onLevel != nil, n > 0, Date().timeIntervalSince(self.lastLevelSent) > 0.033 {
                    self.lastLevelSent = Date()
                    var sum: Float = 0
                    for i in 0..<n { let v = ch[0][i]; sum += v * v }
                    let rms = sqrt(sum / Float(n))
                    // Nutq oralig'i: -52 dB (jimlik) … -14 dB (baland gap).
                    // Kvadrat ildiz — pastki qismini "ochadi": shivirlash ham ko'rinadi,
                    // baland ovoz esa ustunni to'liq ko'taradi.
                    let db = 20 * log10(max(rms, 1e-6))
                    let norm = max(0, min(1, (db + 52) / 38))
                    let lvl = sqrt(norm)
                    DispatchQueue.main.async { self.onLevel?(lvl) }
                }
            }
        }
        engine.prepare()
        do { try engine.start() } catch { return false }
        isRecording = true
        return true
    }

    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        lock.lock(); let s = samples; lock.unlock()
        return s
    }

    private static let win = 320          // 20 ms oyna

    // Oynalar bo'yicha RMS
    private static func envelope(_ s: [Float]) -> [Float] {
        var rms = [Float](); rms.reserveCapacity(s.count / win)
        var i = 0
        while i + win <= s.count {
            var sum: Float = 0
            for j in i..<(i + win) { let v = s[j]; sum += v * v }
            rms.append(sqrt(sum / Float(win)))
            i += win
        }
        return rms
    }

    // Boshi va oxiridagi jimlikni kesish: koder oynasi qisqaradi -> tezroq.
    static func trimSilence(_ s: [Float]) -> [Float] {
        guard s.count > win * 4 else { return s }
        let rms = envelope(s)
        let peak = rms.max() ?? 0
        guard peak > 0.004 else { return s }              // butunlay jim — tegmaymiz
        let thr = max(0.006, peak * 0.08)
        guard let first = rms.firstIndex(where: { $0 > thr }),
              let last  = rms.lastIndex(where: { $0 > thr }) else { return s }
        let from = max(0, (first * win) - Int(0.08 * 16000))
        let to   = min(s.count, ((last + 1) * win) + Int(0.15 * 16000))
        guard to > from else { return s }
        return Array(s[from..<to])
    }

    // Uzun ichki pauzalarni qisqartirish. Koder har soniya uchun to'laydi,
    // shuning uchun 0.7 s dan uzun jimliklarni 0.25 s ga siqamiz — matn
    // o'zgarmaydi, lekin uzun diktovkalar sezilarli tez tanilади.
    static func compressPauses(_ s: [Float]) -> [Float] {
        guard s.count > 16000 * 3 else { return s }       // 3 s dan qisqa — tegmaymiz
        let rms = envelope(s)
        let peak = rms.max() ?? 0
        guard peak > 0.004 else { return s }
        let thr = max(0.006, peak * 0.08)
        let maxPauseWins = Int(0.5 * 16000) / win
        let keepWins     = Int(0.2 * 16000) / win

        var out = [Float](); out.reserveCapacity(s.count)
        var i = 0
        while i < rms.count {
            if rms[i] > thr {
                let from = i * win
                out.append(contentsOf: s[from..<min(from + win, s.count)])
                i += 1
            } else {
                var j = i
                while j < rms.count && rms[j] <= thr { j += 1 }
                let keep = (j - i) > maxPauseWins ? keepWins : (j - i)
                let from = i * win
                let to = min(from + keep * win, s.count)
                if to > from { out.append(contentsOf: s[from..<to]) }
                i = j
            }
        }
        // oxirgi to'liq bo'lmagan oyna
        let tail = rms.count * win
        if tail < s.count { out.append(contentsOf: s[tail...]) }
        return out
    }

    // Yozuvdagi eng baland joy — "umuman jim edi" holatini aniqlash uchun
    static func peakLevel(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        return envelope(s).max() ?? 0
    }

    // whisper 1 soniyadan qisqa audioni qabul qilmaydi — nol bilan to'ldiramiz.
    static func padIfShort(_ s: [Float]) -> [Float] {
        let minLen = Int(1.1 * 16000)
        if s.count >= minLen { return s }
        return s + [Float](repeating: 0, count: minLen - s.count)
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
    static let barCount = 11
    var levels: [CGFloat] = Array(repeating: 0.02, count: barCount + 1)
    var targets: [CGFloat] = Array(repeating: 0.02, count: barCount + 1)
    var phase: CGFloat = 0                // 0…1 — qadamlar orasidagi uzluksiz siljish
    var spinPhase: CGFloat = 0
    var dotsPhase: CGFloat = 0

    var onCancel: (() -> Void)?
    var onAccept: (() -> Void)?

    private let sidePad: CGFloat = 0      // soya — oynaning o'zida
    private let btnR: CGFloat = 9

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

        // Til bejagi: RU / UZ
        let badge = lang == "ru" ? "RU" : "UZ"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.42),
            .kern: 0.5,
        ]
        let str = NSAttributedString(string: badge, attributes: attrs)
        let badgeX = leftBtnCenter.x + btnR + 5
        str.draw(at: NSPoint(x: badgeX, y: r.midY - str.size().height / 2 + 0.5))

        // Ekvalayzer
        let barsX0 = badgeX + str.size().width + 5
        let barsX1 = rightBtnCenter.x - btnR - 5
        drawBars(from: barsX0, to: barsX1, midY: r.midY)

        drawAcceptButton()
    }

    // To'lqin uzluksiz oqadi: chiziqlar phase ulushiga surilib chiziladi,
    // chetlarida esa asta so'nadi — sakrash ko'rinmaydi.
    private func drawBars(from x0: CGFloat, to x1: CGFloat, midY: CGFloat) {
        let visible = CapsuleView.barCount
        guard levels.count > visible, x1 > x0 else { return }
        let barW: CGFloat = 2.6
        let step = (x1 - x0) / CGFloat(visible - 1)
        let base = lang == "ru"
            ? NSColor.white
            : NSColor(calibratedRed: 0.40, green: 0.92, blue: 0.87, alpha: 1)

        for i in 0...visible {
            let x = x0 + (CGFloat(i) - phase) * step
            if x < x0 - step || x > x1 + step { continue }
            // chetlarida shaffoflik — chiziqlar "paydo bo'lib / yo'qolib" turadi
            var edge: CGFloat = 1
            if x < x0 + step      { edge = max(0, (x - (x0 - step)) / (step * 2)) }
            else if x > x1 - step { edge = max(0, ((x1 + step) - x) / (step * 2)) }

            // jim — ingichka chiziqcha, gapirganda — baland ustun (diktofondagidek)
            let h = 2.6 + levels[min(i, levels.count - 1)] * 18
            base.withAlphaComponent(0.9 * edge).setFill()
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

    private func ensurePanel() -> (NSPanel, CapsuleView) {
        if let p = panel, let v = view { return (p, v) }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        // Eng yuqori daraja — to'liq ekranli oynalar (foto ko'ruvchi, video)
        // ustidan ham ko'rinsin.
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true             // tizim soyasi — yumshoqroq
        p.ignoresMouseEvents = false
        p.appearance = NSAppearance(named: .vibrantDark)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

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

    private func place(_ p: NSPanel) {
        guard let scr = NSScreen.main else { return }
        let f = scr.visibleFrame
        p.setFrameOrigin(NSPoint(x: f.midX - W / 2, y: f.minY + 46))
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

    func setLanguage(_ lang: String) {
        view?.lang = lang
        view?.needsDisplay = true
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

    private func appear(_ p: NSPanel) {
        if !p.isVisible {
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.13
                p.animator().alphaValue = 1
            }
        } else {
            p.alphaValue = 1
            p.orderFrontRegardless()
        }
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
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.12
            p.animator().alphaValue = 0
        }, completionHandler: { [weak p] in p?.orderOut(nil) })
    }

    // Xato xabari — kapsula ichida qisqa matn
    func flash(_ text: String, seconds: TimeInterval = 3.0) {
        let (p, v) = ensurePanel()
        timer?.invalidate(); timer = nil
        v.mode = .message
        v.messageText = text
        place(p); appear(p)
        v.needsDisplay = true
        NSLog("[rubai] overlay: \(text)")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.hide() }
    }
}

// MARK: - Matnni faol input'ga kiritish (clipboard + ⌘V)

enum Inserter {
    // ⌘V yuborishdan oldin chaqiriladi: sintetik Cmd bosish "tap" deb
    // hisoblanib qolmasligi uchun detektor vaqtincha o'chiriladi.
    static var willPaste: (() -> Void)?

    // Accessibility ruxsati yo'q bo'lsa chaqiriladi (matn buferda qoladi)
    static var onNoAccessibility: (() -> Void)?

    static func insert(_ text: String) {
        let trusted = AXIsProcessTrusted()
        NSLog("[rubai] insert: len=\(text.count) AXTrusted=\(trusted)")
        guard !text.isEmpty else { NSLog("[rubai] insert: matn bo'sh, to'xtatildi"); return }
        let pb = NSPasteboard.general
        let old = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Ruxsat yo'q — sintetik ⌘V ishlamaydi. Eski buferni QAYTARMAYMIZ,
        // aks holda matn butunlay yo'qoladi: foydalanuvchi o'zi ⌘V bosa oladi.
        guard trusted else {
            NSLog("[rubai] Accessibility yo'q — matn faqat buferga qo'yildi")
            onNoAccessibility?()
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
        NSLog("[rubai] ⌘V yuborildi (down=\(down != nil) up=\(up != nil))")
        // eski clipboard'ni qaytarish
        if let old = old {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                pb.clearContents(); pb.setString(old, forType: .string)
            }
        }
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
    func install() {
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
            NSLog("[rubai] CGEventTap o'rnatildi (AXTrusted=\(AXIsProcessTrusted()))")
        } else {
            NSLog("[rubai] CGEventTap yaratilmadi — NSEvent monitorlari (zaxira)")
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
            NSLog("[rubai] CGEventTap qayta yoqildi")
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
            NSLog("[rubai] hotkey handler o'rnatildi: \(s1) (0 = OK)")
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
        NSLog("[rubai] hotkey ro'yxatdan o'tkazildi \(c.displayString): \(s) (0 = OK)")
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
        w.title = "RubaiSTT — Sozlamalar"
        w.isReleasedWhenClosed = false
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 230))

        let main = NSTextField(labelWithString: "Asosiy usul: ⌘ tugmasi")
        main.font = .systemFont(ofSize: 14, weight: .semibold)
        main.frame = NSRect(x: 24, y: 188, width: 332, height: 20)
        v.addSubview(main)

        let mainHint = NSTextField(wrappingLabelWithString:
            "⌘⌘ — ruscha yozishni boshlash\n⌘⌘⌘ — o'zbekcha yozishni boshlash\n⌘ — to'xtatish va matnni qo'yish  ·  ⎋ — bekor qilish")
        mainHint.font = .systemFont(ofSize: 11)
        mainHint.textColor = .secondaryLabelColor
        mainHint.frame = NSRect(x: 24, y: 128, width: 332, height: 56)
        v.addSubview(mainHint)

        let title = NSTextField(labelWithString: "Zaxira tugma birikmasi")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 24, y: 100, width: 332, height: 18)
        v.addSubview(title)

        recordButton = NSButton(title: current.displayString, target: self, action: #selector(toggleRecord))
        recordButton.bezelStyle = .rounded
        recordButton.font = .systemFont(ofSize: 16, weight: .medium)
        recordButton.frame = NSRect(x: 24, y: 60, width: 332, height: 34)
        v.addSubview(recordButton)

        hintLabel = NSTextField(labelWithString: "Tugmani o'zgartirish uchun bosing.")
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.frame = NSRect(x: 24, y: 42, width: 332, height: 16)
        v.addSubview(hintLabel)

        let reset = NSButton(title: "Standartga qaytarish (⌃⌥D)", target: self, action: #selector(resetDefault))
        reset.bezelStyle = .rounded
        reset.frame = NSRect(x: 24, y: 12, width: 332, height: 26)
        v.addSubview(reset)

        w.contentView = v
        window = w
    }

    private func refreshButton() {
        recordButton.title = recording ? "Tugmani bosing…" : current.displayString
        hintLabel.stringValue = recording
            ? "Kamida bitta modifier (⌃ ⌥ ⌘ ⇧) + tugma. Bekor qilish: ⎋"
            : "Tugmani o'zgartirish uchun bosing."
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
                self.hintLabel.stringValue = "Kamida bitta modifier (⌃ ⌥ ⌘ ⇧) kerak!"
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
            NSLog("[rubai] login item xato: \(error.localizedDescription)")
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
        w.title = "RubaiSTT Diktovka"
        w.isReleasedWhenClosed = false
        let v = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))

        // Ikona
        let iconView = NSImageView(frame: NSRect(x: (W - 72) / 2, y: H - 96, width: 72, height: 72))
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        v.addSubview(iconView)

        let title = NSTextField(labelWithString: "Xush kelibsiz!")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.alignment = .center
        title.frame = NSRect(x: 0, y: H - 130, width: W, height: 26)
        v.addSubview(title)

        let sub = NSTextField(wrappingLabelWithString:
            "⌘ tugmasini 2 marta bosing → gapiring → 1 marta bosing, matn yoziladi.\n⌘ 3 marta — o'zbekcha. Zaxira birikma: \(hotkeyText)")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor
        sub.alignment = .center
        sub.frame = NSRect(x: 20, y: H - 168, width: W - 40, height: 34)
        v.addSubview(sub)

        // 1-qadam: Mikrofon
        micDot = stepRow(in: v, y: H - 220,
                         title: "1. Mikrofon ruxsati",
                         desc: "Ovozingizni eshitish uchun.",
                         button: "Ruxsat so'rash", action: #selector(askMic))
        // 2-qadam: Accessibility
        axDot = stepRow(in: v, y: H - 280,
                        title: "2. Accessibility ruxsati",
                        desc: "Tugmalarni eshitish va matn yozish uchun.",
                        button: "Sozlamani ochish", action: #selector(openAX))

        // Login'da ishga tushirish
        let loginCheck = NSButton(checkboxWithTitle: "Kompyuter yonganda avtomatik ishga tushsin",
                                  target: self, action: #selector(toggleLogin(_:)))
        loginCheck.state = LoginItem.isEnabled ? .on : .off
        loginCheck.frame = NSRect(x: 30, y: 70, width: W - 60, height: 20)
        v.addSubview(loginCheck)

        let done = NSButton(title: "Boshladik!", target: self, action: #selector(closeWindow))
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
    private var langItemRU: NSMenuItem!
    private var langItemUZ: NSMenuItem!

    // Joriy diktovka tili va u qaysi tap-seriyasida boshlanganini eslab qolamiz
    private var lang = "ru"
    private var startedByTapSeries = false

    private var defaultLang: String {
        get { UserDefaults.standard.string(forKey: "lastLang") ?? "ru" }
        set { UserDefaults.standard.set(newValue, forKey: "lastLang") }
    }

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

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "rubaiSTT")
        let menu = NSMenu()
        dictateItem = NSMenuItem(title: "Diktovka  (⌘⌘)", action: #selector(toggle), keyEquivalent: "")
        menu.addItem(dictateItem)
        menu.addItem(.separator())
        langItemRU = NSMenuItem(title: "Ruscha  (⌘⌘)", action: #selector(pickRU), keyEquivalent: "")
        langItemUZ = NSMenuItem(title: "O'zbekcha  (⌘⌘⌘)", action: #selector(pickUZ), keyEquivalent: "")
        menu.addItem(langItemRU)
        menu.addItem(langItemUZ)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Sozlamalar…", action: #selector(openSettings), keyEquivalent: ","))
        loginItem = NSMenuItem(title: "Login'da ishga tushirish", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Accessibility ruxsatini ochish", action: #selector(openAX), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Yo'riqnoma…", action: #selector(openWelcome), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Chiqish", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        lang = defaultLang
        refreshLangMenu()
        Whisper.shared.setLanguage(lang)

        // Zaxira birikma (⌃⌥D) — ishlashda qoladi
        hotkey.install()
        NotificationCenter.default.addObserver(self, selector: #selector(toggle), name: .rubaiHotkey, object: nil)

        // ⌘ tap'lari — asosiy usul
        taps.onTap = { [weak self] n in self?.handleTap(n) }
        taps.onEscape = { [weak self] in self?.cancel() }
        taps.install()
        Inserter.willPaste = { [weak self] in self?.taps.mute(0.8) }
        Inserter.onNoAccessibility = { [weak self] in self?.warnNoAccessibility() }

        // Mikrofon darajasi -> ekvalayzer
        rec.onLevel = { [weak self] lvl in self?.overlay.push(level: lvl) }
        overlay.onCancel = { [weak self] in self?.cancel() }
        overlay.onAccept = { [weak self] in self?.stopAndTranscribe() }

        // Modelni oldindan yuklaymiz (fon oqimida) — birinchi diktovka ham tez bo'lsin
        DispatchQueue.global(qos: .utility).async { [lang] in
            Whisper.shared.preload(lang: lang)
        }

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

    // Yozish ketayotgan bo'lsa: 1 tap = to'xtatish. Lekin agar yozish shu
    // seriyaning 2-tapida boshlangan bo'lsa, 3-tap tilni o'zbekchaga o'zgartiradi
    // (yozish davom etaveradi — hech narsa yo'qolmaydi).
    private func handleTap(_ n: Int) {
        if rec.isRecording {
            if startedByTapSeries && n == 3 {
                switchLanguage("uz")
            } else {
                stopAndTranscribe()
            }
            return
        }
        if n == 2 {
            startedByTapSeries = true
            start(lang: "ru")
        }
    }

    private func switchLanguage(_ l: String) {
        lang = l
        defaultLang = l
        Whisper.shared.setLanguage(l)
        overlay.setLanguage(l)
        refreshLangMenu()
        NSLog("[rubai] til -> \(l)")
    }

    private func start(lang l: String) {
        lang = l
        defaultLang = l
        Whisper.shared.setLanguage(l)
        refreshLangMenu()
        rec.start { [weak self] ok in
            guard let self = self else { return }
            NSLog("[rubai] record start ok=\(ok) lang=\(l)")
            if ok {
                self.overlay.showRecording(lang: l)
            } else {
                self.overlay.flash("Mikrofonga ruxsat yo'q", seconds: 2.0)
            }
        }
    }

    private func stopAndTranscribe() {
        guard rec.isRecording else { return }
        startedByTapSeries = false
        taps.resetSeries()
        let raw = rec.stop()

        // Jim yozuvda whisper "*qush sayrashi*", "(musiqa)" kabi narsalarni
        // o'ylab topadi va ular matn maydoniga tushib qoladi. Shuning uchun
        // umuman ovoz bo'lmasa — umuman tanimaymiz.
        let peak = Recorder.peakLevel(raw)
        if peak < 0.012 {
            NSLog("[rubai] jim yozuv (peak=\(String(format: "%.4f", peak))) — tanilmadi")
            overlay.flash("Ovoz eshitilmadi", seconds: 1.4)
            return
        }

        let trimmed = Recorder.padIfShort(Recorder.compressPauses(Recorder.trimSilence(raw)))
        NSLog("[rubai] stopped: \(String(format: "%.1f", Double(raw.count)/16000.0))s -> \(String(format: "%.1f", Double(trimmed.count)/16000.0))s (jimlik kesildi)")
        overlay.showProcessing()
        Whisper.shared.transcribe(trimmed) { [weak self] text in
            NSLog("[rubai] natija: '\(text)' (uzunlik=\(text.count))")
            self?.overlay.hide()
            Inserter.insert(AppDelegate.dropHallucination(text))
        } fail: { [weak self] msg in
            NSLog("[rubai] transcription XATO: \(msg)")
            self?.overlay.flash("⚠️ \(msg)")
        }
    }

    // Butunlay qavs/yulduzcha ichidagi qisqa natija — bu nutq emas, whisper'ning
    // "sahna izohi": «*qush sayrashi*», «(musiqa)», «[shovqin]». Bunday matnni
    // foydalanuvchi maydoniga qo'ymaymiz.
    static func dropHallucination(_ t: String) -> String {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count <= 40, let f = s.first, let l = s.last else { return s }
        let wrapped = (f == "(" && l == ")") || (f == "*" && l == "*")
                   || (f == "[" && l == "]") || (f == "«" && l == "»")
        if wrapped { NSLog("[rubai] natija tashlandi (sahna izohi): '\(s)'"); return "" }
        return s
    }

    private func cancel() {
        guard rec.isRecording else { return }
        startedByTapSeries = false
        taps.resetSeries()
        _ = rec.stop()
        overlay.hide()
        NSLog("[rubai] bekor qilindi")
    }

    // Accessibility yo'q: matn buferda qoldi. Bir marta sozlamalarni taklif qilamiz.
    private var axWarned = false
    private func warnNoAccessibility() {
        overlay.flash("Matn buferda — ⌘V bosing", seconds: 4)
        guard !axWarned else { return }
        axWarned = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let a = NSAlert()
            a.messageText = "Accessibility ruxsati yo'q"
            a.informativeText = "Shu sababli matn o'zi qo'yilmadi — u faqat buferga tushdi (⌘V bilan qo'ying).\n\nSozlamalar → Maxfiylik va xavfsizlik → Universal Access ro'yxatida «RubaiSTT Dictation» yoqilsin."
            a.addButton(withTitle: "Sozlamani ochish")
            a.addButton(withTitle: "Keyinroq")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn {
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
    }

    private func refreshLangMenu() {
        langItemRU?.state = lang == "ru" ? .on : .off
        langItemUZ?.state = lang == "uz" ? .on : .off
    }

    @objc private func pickRU() { switchLanguage("ru") }
    @objc private func pickUZ() { switchLanguage("uz") }

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
            startedByTapSeries = false
            start(lang: lang)
        }
    }

    @objc private func quit() { rubai_unload(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ n: Notification) { rubai_unload() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
