import Foundation

// Audio.cutPoint uchun sinov. Ilovani ishga tushirish va gapirish shart emas —
// sun'iy signal (nutq = shovqin, pauza = jimlik) yasab, kesish TO'G'RI joydan
// bo'lganini tekshiradi.
//
//   swiftc -O -parse-as-library tools/test-chunking.swift src/audio.swift -o /tmp/chunktest && /tmp/chunktest
//
// Nima uchun kerak: kesish indekslari — shu ishning eng xavfli joyi. Bu yerda
// xato bo'lsa, so'zlar bo'linib ketadi yoki bo'lak umuman yuborilmaydi, va buni
// jonli diktovkada payqash qiyin.

let rate = Audio.rate
var failures = 0
var checks = 0

func check(_ ok: Bool, _ what: String, _ detail: String = "") {
    checks += 1
    if ok {
        print("  ✓ \(what)")
    } else {
        failures += 1
        print("  ✗ \(what)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

// Determinlashgan "shovqin" — har safar bir xil (Math.random emas).
var seed: UInt64 = 0x9E3779B97F4A7C15
func rnd() -> Float {
    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
    return Float(Int64(bitPattern: seed % 2_000_000) - 1_000_000) / 1_000_000.0
}

func speech(_ sec: Double, level: Float = 0.25) -> [Float] {
    (0..<Int(sec * Double(rate))).map { _ in rnd() * level }
}
func silence(_ sec: Double, level: Float = 0.0008) -> [Float] {
    (0..<Int(sec * Double(rate))).map { _ in rnd() * level }
}
func sec(_ samples: Int) -> Double { Double(samples) / Double(rate) }

@main
struct ChunkTest {
    static func main() {
    print("cutPoint — pauza bo'yicha kesish")

    // 1. Qisqa yozuv: 6 s dan kam — kesilmaydi.
    do {
        let a = speech(3) + silence(1) + speech(1.5)
        check(Audio.cutPoint(a) == nil, "5.5 s — kesilmaydi (min bo'lak 6 s)")
    }

    // 2. Pauza bor, lekin 6 s dan oldin — kesilmaydi, keyingisini kutamiz.
    do {
        let a = speech(2) + silence(1) + speech(2)      // jami 5 s
        check(Audio.cutPoint(a) == nil, "pauza 6 s dan oldin — hali kesilmaydi")
    }

    // 3. Asosiy holat: 7 s nutq, 1 s pauza, yana 3 s nutq.
    //    Kesish pauzaning O'RTASIDAN (7.5 s atrofida) bo'lishi kerak.
    do {
        let a = speech(7) + silence(1.0) + speech(3)
        guard let cut = Audio.cutPoint(a) else {
            check(false, "pauza topildi"); exit(1)
        }
        let t = sec(cut)
        check(abs(t - 7.5) < 0.25, "kesish pauza o'rtasida (7.5 s)", "chiqdi \(String(format: "%.2f", t)) s")
        // Kesilgan bo'lak oxiri jim bo'lishi shart — so'z bo'linmagan.
        let edge = Array(a[max(0, cut - rate / 10)..<min(a.count, cut + rate / 10)])
        check(Audio.peakLevel(edge) < 0.01, "kesish nuqtasi jimlikda (so'z bo'linmagan)")
    }

    // 4. Qisqa pauza (0.3 s) — nafas emas, so'zlar orasidagi tanaffus. Kesilmaydi.
    do {
        let a = speech(7) + silence(0.3) + speech(3)
        check(Audio.cutPoint(a) == nil, "0.3 s pauza — kesilmaydi (nafas emas)")
    }

    // 5. "Issiq chet": qisqa pauza yozuvning eng oxirida — odam hali gapini
    //    tugatmagan bo'lishi mumkin, tegmaymiz.
    do {
        let a = speech(8) + silence(1.0)
        check(Audio.cutPoint(a) == nil, "qisqa ochiq pauza oxirida — kesilmaydi")
    }

    // 5b. Uzoq ochiq pauza (odam o'ylab turibdi) — kesish xavfsiz, dum qisqaradi.
    do {
        let a = speech(8) + silence(2.5)
        guard let cut = Audio.cutPoint(a) else {
            check(false, "uzoq ochiq pauza — kesildi"); exit(1)
        }
        let t = sec(cut)
        check(t > 8.0 && t < 10.5, "uzoq ochiq pauza ichidan kesildi", "chiqdi \(String(format: "%.2f", t)) s")
        let edge = Array(a[max(0, cut - rate / 10)..<min(a.count, cut + rate / 10)])
        check(Audio.peakLevel(edge) < 0.01, "kesish jimlikda (uzoq ochiq pauza)")
    }

    // 6. To'xtovsiz nutq 30 s: pauza yo'q, lekin 25 s dan keyin majburan kesiladi.
    do {
        let a = speech(30)
        guard let cut = Audio.cutPoint(a) else {
            check(false, "30 s to'xtovsiz nutq — majburan kesildi"); exit(1)
        }
        let t = sec(cut)
        check(t >= 6.0 && t <= 25.0, "majburiy kesish 6…25 s oralig'ida", "chiqdi \(String(format: "%.2f", t)) s")
    }

    // 7. 20 s to'xtovsiz nutq — hali chegara emas, kutamiz.
    do {
        check(Audio.cutPoint(speech(20)) == nil, "20 s to'xtovsiz — hali kesilmaydi")
    }

    // 8. Butunlay jim uzun yozuv — kesiladi (bo'lak keyin "ovoz yo'q" deb tashlanadi).
    do {
        let a = silence(30)
        let cut = Audio.cutPoint(a)
        check(cut != nil, "jim 30 s — kesiladi")
        check(Audio.peakLevel(a) < 0.012, "jim bo'lak whisper'ga bermaslik chegarasidan past")
    }

    // 9. Ketma-ket kesish: uzun yozuv bo'laklarga bo'linadi va HECH NARSA yo'qolmaydi.
    do {
        var full: [Float] = []
        for _ in 0..<6 { full += speech(7) + silence(0.8) }     // ~47 s, 6 ta jumla
        var cursor = 0
        var chunks: [Int] = []
        while true {
            let tail = Array(full[cursor...])
            guard let cut = Audio.cutPoint(tail) else { break }
            chunks.append(cut)
            cursor += cut
        }
        check(chunks.count >= 4, "uzun yozuv bo'laklarga bo'lindi", "bo'laklar: \(chunks.map { String(format: "%.1f", sec($0)) })")
        check(chunks.allSatisfy { sec($0) >= 6.0 }, "har bo'lak 6 s dan uzun")
        check(chunks.allSatisfy { sec($0) <= 25.0 }, "har bo'lak 25 s dan qisqa")
        let covered = chunks.reduce(0, +)
        check(covered == cursor, "bo'laklar ustma-ust tushmaydi va oraliq qolmaydi")
        // Dum — bu OXIRGI jumla, butun yozuv emas: ⌘ dan keyingi kutish
        // diktovka uzunligiga qarab o'smasligining sababi shu.
        check(sec(full.count - cursor) <= 10.0, "dum — faqat oxirgi jumla",
              "dum \(String(format: "%.1f", sec(full.count - cursor))) s / yozuv \(String(format: "%.1f", sec(full.count))) s")
    }

    // 10. prepare(): bo'lak whisper'ga tayyorlanadi — jimlik kesiladi, 1.1 s dan qisqa emas.
    do {
        let a = silence(1.0) + speech(4) + silence(1.5)
        let p = Audio.prepare(a)
        check(p.count < a.count, "prepare chetdagi jimlikni kesdi",
              "\(String(format: "%.1f", sec(a.count))) s -> \(String(format: "%.1f", sec(p.count))) s")
        check(Audio.prepare(speech(0.4)).count >= Int(1.1 * Double(rate)), "qisqa bo'lak 1.1 s gacha to'ldirildi")
    }

    print("\n\(checks - failures)/\(checks) tekshiruv o'tdi")
    exit(failures == 0 ? 0 : 1)
    }
}
