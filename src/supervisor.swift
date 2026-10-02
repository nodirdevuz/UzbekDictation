// Самолечение приложения (02.10.2026).
//
// Что случилось: после отключения Bluetooth-гарнитуры CoreAudio перестал отвечать, и главный поток
// навсегда завис в `AVAudioEngine.inputNode` (синхронный запрос к coreaudiod, который не
// возвращается). Приложение осталось «живым», но не реагировало, а coreaudiod и мы грели
// ноутбук на 30–60 % CPU. Починить зависание внутри чужого API нельзя — можно только
// гарантировать, что оно не живёт дольше нескольких секунд.
//
// Сторож работает в ОТДЕЛЬНОМ потоке, который не ходит ни в CoreAudio, ни в главный поток, поэтому
// сам застрять не может. Три условия самоперезапуска:
//   1. главный поток не откликается дольше hangLimit (20 с) — «пульс» с таймера главного потока;
//   2. CoreAudio не ответил на старт/перезапуск записи за Recorder.audioTimeout (вызов heal из Recorder);
//   3. приложение в простое (не пишет, давно ничего не делало), а процессор > 25 % три окна подряд (90 с).
// Перезапуск: `_exit` (без atexit — они могли бы снова зависнуть) + отдельный `sh` поднимает
// новую копию через `open`. Не чаще 3 раз за 10 минут; дальше работает launchd-страховка
// (~/Library/LaunchAgents/com.rubaistt.dictation.keepalive.plist, раз в 2 минуты).
import Foundation
import AppKit
import Darwin

final class Supervisor {
    static let shared = Supervisor()

    /// Идёт ли запись прямо сейчас (потокобезопасно — читает защищённое поле Recorder).
    var isRecording: () -> Bool = { false }

    private let lock = NSLock()
    private var beat = Date()
    private var lastActivity = Date()
    private let selfTest = ProcessInfo.processInfo.environment["RUBAI_SELFTEST"]
    private var fast: Bool { selfTest != nil }

    // Пороги. В самотесте (RUBAI_SELFTEST=…) сжаты, чтобы проверка занимала секунды.
    private var hangLimit: TimeInterval { fast ? 5 : 20 }
    private var cpuWindow: TimeInterval { fast ? 4 : 30 }
    private var idleAfter: TimeInterval { fast ? 4 : 150 }   // выгрузка модели — через 120 с
    private var cpuWindowsNeeded: Int { fast ? 2 : 3 }
    private let cpuLimit = 25.0                               // % одного ядра

    private var cpuHigh = 0
    private var lastCPU = Supervisor.cpuSeconds()
    private var lastWall = Date()

    /// Любая «настоящая работа» (старт записи, распознавание, вставка) — отодвигает «простой».
    func touch() { lock.lock(); lastActivity = Date(); lock.unlock() }

    func start() {
        let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock(); self.beat = Date(); self.lock.unlock()
        }
        RunLoop.main.add(t, forMode: .common)   // .common — чтобы жил и при открытом меню

        let th = Thread { [weak self] in self?.loop() }
        th.name = "rubai.supervisor"
        th.qualityOfService = .utility
        th.start()

        runSelfTestIfAsked()
    }

    private func loop() {
        while true {
            Thread.sleep(forTimeInterval: 2)

            lock.lock(); let silentFor = Date().timeIntervalSince(beat); let idleFor = Date().timeIntervalSince(lastActivity); lock.unlock()
            if silentFor > hangLimit {
                heal("главный поток не отвечает \(Int(silentFor)) с")
            }

            let wall = Date().timeIntervalSince(lastWall)
            if wall >= cpuWindow {
                let cpu = Supervisor.cpuSeconds()
                let pct = (cpu - lastCPU) / wall * 100
                lastCPU = cpu; lastWall = Date()
                if !isRecording() && idleFor > idleAfter && pct > cpuLimit {
                    cpuHigh += 1
                    rlog("[rubai] simple, lekin CPU \(Int(pct))% (\(cpuHigh)/\(cpuWindowsNeeded))")
                    if cpuHigh >= cpuWindowsNeeded { heal("в простое процессор \(Int(pct))%") }
                } else {
                    cpuHigh = 0
                }
            }
        }
    }

    private static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(u.ru_utime) + s(u.ru_stime)
    }

    // MARK: - Перезапуск

    private static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RubaiSTT")
    }
    static var quitFlag: URL { supportDir.appendingPathComponent("user-quit") }
    private var restartsFile: URL { Supervisor.supportDir.appendingPathComponent("restarts.log") }
    private var healLog: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RubaiSTT-self-heal.log")
    }

    /// Можно вызывать из любого потока. Не возвращается.
    func heal(_ reason: String) {
        rlog("[rubai] SAMOLECHENIE: \(reason)")
        let now = Date().timeIntervalSince1970
        try? FileManager.default.createDirectory(at: Supervisor.supportDir, withIntermediateDirectories: true)

        // Сколько перезапусков было за последние 10 минут — чтобы не крутиться в петле.
        let recent = ((try? String(contentsOf: restartsFile)) ?? "")
            .split(separator: "\n").compactMap { Double($0) }.filter { now - $0 < 600 }
        try? (recent.map { String($0) } + [String(now)]).joined(separator: "\n").write(to: restartsFile, atomically: true, encoding: .utf8)

        let stamp = ISO8601DateFormatter().string(from: Date())
        if let h = try? FileHandle(forWritingTo: healLog) {
            h.seekToEndOfFile(); h.write("\(stamp) \(reason)\n".data(using: .utf8)!); try? h.close()
        } else {
            try? "\(stamp) \(reason)\n".write(to: healLog, atomically: true, encoding: .utf8)
        }

        // Уведомление (необязательное) и запуск новой копии — отдельными процессами,
        // которые переживут наш выход.
        let app = Bundle.main.bundlePath
        let note = recent.count < 3
            ? "Диктовка зависла и перезапущена. Нажмите ⌘⌘ ещё раз."
            : "Диктовка снова зависла. Перезапуск через минуту."
        let cmd = "/usr/bin/osascript -e 'display notification \"\(note)\" with title \"RubaiSTT\"' >/dev/null 2>&1; "
            + (recent.count < 3 ? "sleep 1.5; /usr/bin/open -a '\(app)'" : "")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        try? p.run()
        usleep(150_000)
        _exit(75)   // без atexit: они могут снова зависнуть в том же CoreAudio
    }

    // MARK: - Самотест (RUBAI_SELFTEST=hang|spin|audiohang)

    private func runSelfTestIfAsked() {
        guard let mode = selfTest else { return }
        rlog("[rubai] SAMOTEST: \(mode)")
        switch mode {
        case "hang":   // главный поток «зависает» на минуту
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { sleep(60) }
        case "spin":   // простой, но процессор занят
            let t = Thread { while true { _ = sin(Double.random(in: 0...1)) } }
            t.start()
        default: break  // audiohang обрабатывает Recorder.begin()
        }
    }
}
