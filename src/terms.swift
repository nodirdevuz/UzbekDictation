import Foundation

// Английские термины Whisper в русской речи пишет «на слух»: «Ворсил», «Supabae»,
// «веб-эп», «супы байс» (замеры 25.09.2026, large-v3-turbo). Подсказка в initial_prompt
// помогает не всегда, поэтому известные искажения исправляем словарём.
//
// Вынесено отдельно от dictate.swift, чтобы прогонять тестом без приложения:
//   swiftc -O -parse-as-library tools/test-terms.swift src/terms.swift -o /tmp/termtest && /tmp/termtest
enum Terms {
    // Слово ловится целиком, вместе с падежным окончанием («Супабейсе», «Рейлвея»),
    // и только если вокруг нет других букв — чтобы не задеть части обычных слов.
    private static let rules: [(NSRegularExpression, String)] = {
        let w = "\\p{L}*"
        let list: [(String, String)] = [
            ("supaba(?:e|es|se|ze|is|ise|ez)|supabeis|supabays|supabase"
             + "|суп[ыаиу]?[- ]?(?:б[аэе][йи]?[сз]\(w)|abae?s?e?|abase|abeis)"
             + "|супаб[аэе][йи]?[сз]\(w)|супабаес\(w)", "Supabase"),
            ("р[еэ][йи]лв[еэ][йи]\(w)|railwey|reilway", "Railway"),
            ("в[еёоа]рс[еиэ]л\(w)|в[еа]рц[еэ]л\(w)|versel|vercell", "Vercel"),
            ("в[еэ]б[- ]?(?:эп|эпп|апп?|ап)\(w)|web[- ]?app|webapp", "Web App"),
            ("мини[- ]?(?:эп|эпп|апп?|ап)\(w)|mini[- ]?app", "Mini App"),
            ("гит[- ]?хаб\(w)|github", "GitHub"),
            ("д[оа]к[еэ]р\(w)", "Docker"),
            ("(?:эн)?вид[иі]а|нвидиа", "Nvidia"),
            ("клод(?:а|у|ом|е)?", "Claude"),
            ("задеплай", "задеплой"),
            ("деплай", "деплой"),
        ]
        return list.compactMap { pat, rep in
            guard let re = try? NSRegularExpression(pattern: "(?<!\\p{L})(?:\(pat))(?!\\p{L})",
                                                    options: [.caseInsensitive]) else { return nil }
            return (re, rep)
        }
    }()

    static func fix(_ t: String) -> String {
        var s = t
        for (re, rep) in rules {
            // С конца, чтобы диапазоны не съезжали. Для русских замен («задеплой»)
            // сохраняем заглавную букву: в начале предложения «Задеплай» → «Задеплой».
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
                guard let r = Range(m.range, in: s) else { continue }
                var out = rep
                if let f = s[r].first, f.isUppercase, let o = out.first, o.isLowercase {
                    out = o.uppercased() + out.dropFirst()
                }
                s.replaceSubrange(r, with: out)
            }
        }
        if s != t { rlog("[rubai] atamalar tuzatildi: '\(t)' -> '\(s)'") }
        return s
    }
}
