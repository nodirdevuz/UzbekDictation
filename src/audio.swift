import Foundation

// MARK: - Audio ustida sof hisob (mikrofonga bog'liq emas)
//
// Bu yerda AVAudioEngine yo'q — faqat [Float] massivi ustidagi hisob. Shuning
// uchun uni ilovani ishga tushirmasdan sinash mumkin: tools/test-chunking.swift
// aynan shu faylni qo'shib kompilyatsiya qilinadi.
//
// Barcha o'lchovlar 16 kGts mono uchun.
enum Audio {
    static let rate = 16000
    static let win = 320                  // 20 ms oyna

    // Oynalar bo'yicha RMS
    static func envelope(_ s: [Float]) -> [Float] {
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

    // Jimlik chegarasi — trimSilence, compressPauses va cutPoint uchun bitta qoida.
    private static func threshold(_ rms: [Float]) -> Float? {
        let peak = rms.max() ?? 0
        guard peak > 0.004 else { return nil }   // butunlay jim
        return max(0.006, peak * 0.08)
    }

    // Boshi va oxiridagi jimlikni kesish: koder oynasi qisqaradi -> tezroq.
    static func trimSilence(_ s: [Float]) -> [Float] {
        guard s.count > win * 4 else { return s }
        let rms = envelope(s)
        guard let thr = threshold(rms) else { return s }
        guard let first = rms.firstIndex(where: { $0 > thr }),
              let last  = rms.lastIndex(where: { $0 > thr }) else { return s }
        let from = max(0, (first * win) - Int(0.08 * Double(rate)))
        let to   = min(s.count, ((last + 1) * win) + Int(0.15 * Double(rate)))
        guard to > from else { return s }
        return Array(s[from..<to])
    }

    // Uzun ichki pauzalarni qisqartirish. Koder har soniya uchun to'laydi,
    // shuning uchun 0.5 s dan uzun jimliklarni 0.2 s ga siqamiz — matn
    // o'zgarmaydi, lekin uzun diktovkalar sezilarli tez tanilади.
    static func compressPauses(_ s: [Float]) -> [Float] {
        guard s.count > rate * 3 else { return s }       // 3 s dan qisqa — tegmaymiz
        let rms = envelope(s)
        guard let thr = threshold(rms) else { return s }
        let maxPauseWins = Int(0.5 * Double(rate)) / win
        let keepWins     = Int(0.2 * Double(rate)) / win

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
        let minLen = Int(1.1 * Double(rate))
        if s.count >= minLen { return s }
        return s + [Float](repeating: 0, count: minLen - s.count)
    }

    // Yozuv oldidan whisper'ga beriladigan tayyorgarlik — bo'lak uchun ham,
    // butun yozuv uchun ham bir xil.
    static func prepare(_ s: [Float]) -> [Float] {
        padIfShort(compressPauses(trimSilence(s)))
    }

    // MARK: Bo'lakka kesish nuqtasi

    // Bo'lak chegaralari. 6 s dan qisqa bo'lakda whisper kontekstni yo'qotadi va
    // xato qila boshlaydi; 25 s — koder oynasining amaliy chegarasi.
    static let minChunk = Int(6.0 * 16000)
    static let maxChunk = Int(25.0 * 16000)
    private static let minPauseWins = Int(0.6 * 16000) / win   // nafas olish pauzasi
    private static let hotEdgeWins  = Int(0.25 * 16000) / win  // "issiq" chet
    private static let openPauseWins = Int(1.5 * 16000) / win  // "o'ylab turibdi"

    // Hali topshirilmagan qismda (`tail`) kesish nuqtasini izlaydi.
    // Kesish HAR DOIM pauzaning O'RTASIDAN bo'ladi — shunda birorta so'z
    // ikkiga bo'linmaydi. Topilmasa nil (hali kutamiz).
    // Kesish natijasi: qayerdan kesildi va NIMA UCHUN (log uchun — jonli
    // diktovkada nima bo'layotganini ko'rish uchun yagona yo'l).
    enum CutReason: String {
        case closedPause = "yopiq pauza"
        case openPause   = "uzoq ochiq pauza"
        case forced      = "majburiy (pauza yo'q)"
        case allSilent   = "butunlay jim"
    }

    static func cutPoint(_ tail: [Float]) -> Int? {
        cut(tail)?.at
    }

    static func cut(_ tail: [Float]) -> (at: Int, why: CutReason, pause: Double, level: Float)? {
        guard tail.count >= minChunk else { return nil }
        let rms = envelope(tail)
        guard !rms.isEmpty else { return nil }

        guard let thr = threshold(rms) else {
            // Butunlay jimlik: uzun bo'lib ketgan bo'lsa, shunchaki kesamiz —
            // bo'lak keyin "ovoz yo'q" deb tashlanadi.
            guard tail.count >= maxChunk else { return nil }
            return (maxChunk, .allSilent, 0, 0)
        }

        let minWin = minChunk / win
        let lastAllowed = rms.count - hotEdgeWins   // odam hali gapirayotgan chet

        var i = minWin
        while i < lastAllowed {
            guard rms[i] <= thr else { i += 1; continue }
            var j = i
            while j < rms.count && rms[j] <= thr { j += 1 }

            // Yopiq pauza (nutq qaytadan boshlangan) — eng ishonchli kesish joyi.
            if j < lastAllowed && (j - i) >= minPauseWins {
                let at = ((i + j) / 2)
                return (at * win, .closedPause, Double((j - i) * win) / Double(rate), rms[at])
            }
            // Pauza yozuv oxirigacha davom etyapti. Qisqa bo'lsa — tegmaymiz:
            // odam hali gapini tugatmagan bo'lishi mumkin. Lekin 1.5 s dan
            // uzoq jim tursa (o'ylayapti) — kesaverish xavfsiz: kesish baribir
            // jimlikning ichida bo'ladi, dum esa qisqaradi.
            if j >= lastAllowed && (rms.count - i) >= openPauseWins {
                let at = i + openPauseWins / 2
                return (at * win, .openPause, Double((rms.count - i) * win) / Double(rate), rms[min(at, rms.count - 1)])
            }
            i = j + 1
        }

        // 25 s to'xtovsiz nutq — pauza yo'q. Eng jim nuqtadan majburan kesamiz.
        if tail.count >= maxChunk {
            let from = minWin
            let to = min(rms.count, maxChunk / win)
            if to > from {
                var best = from
                var bestVal = rms[from]
                for k in from..<to where rms[k] < bestVal { bestVal = rms[k]; best = k }
                return (best * win, .forced, 0, bestVal)
            }
        }
        return nil
    }
}
