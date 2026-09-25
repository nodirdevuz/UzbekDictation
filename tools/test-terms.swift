// Тест словаря терминов (src/terms.swift) — без приложения и микрофона:
//   swiftc -O -parse-as-library tools/test-terms.swift src/terms.swift -o /tmp/termtest && /tmp/termtest
import Foundation

func rlog(_ s: String) {}

@main struct TermTest {
    static func main() {
        let cases: [(String, String)] = [
            // реальные ответы whisper из логов 25.09.2026
            ("Задеплай веб-эп на Ворсил, подключи Supabae с Railway.", "Задеплой Web App на Vercel, подключи Supabase с Railway."),
            ("Задеплой веб-эп на Ворсил, подключи супы байс и рейлвей.", "Задеплой Web App на Vercel, подключи Supabase и Railway."),
            ("Супabae.", "Supabase."),
            ("базу данных Supabaes", "базу данных Supabase"),
            ("в Супабейсе лежит таблица", "в Supabase лежит таблица"),
            ("выложи на гитхаб и собери в докере", "выложи на GitHub и собери в Docker"),
            ("открой мини-апп в Telegram", "открой Mini App в Telegram"),
            // обычные русские слова НЕ трогаем
            ("сварил суп и поел", "сварил суп и поел"),
            ("версия вышла вчера", "версия вышла вчера"),
            ("это вид сверху", "это вид сверху"),
            ("докер", "Docker"),
        ]
        var bad = 0
        for (inp, want) in cases {
            let got = Terms.fix(inp)
            let ok = got == want
            if !ok { bad += 1 }
            print(ok ? "✓" : "✗", inp, "→", got, ok ? "" : "  (ожидалось: \(want))")
        }
        print(bad == 0 ? "ВСЕ \(cases.count) ПРОШЛИ" : "ОШИБОК: \(bad)")
        exit(bad == 0 ? 0 : 1)
    }
}
