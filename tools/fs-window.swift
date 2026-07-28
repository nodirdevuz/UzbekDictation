// Тестовое ПОЛНОЭКРАННОЕ окно: занимает собственный Space, как Claude или Telegram
// в полноэкранном режиме. Нужно, чтобы проверить, рисуется ли капсула диктовки поверх него,
// не трогая рабочие окна владельца. Сам закрывается через 25 секунд.
import Cocoa

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let win = NSWindow(
    contentRect: NSRect(x: 100, y: 100, width: 900, height: 600),
    styleMask: [.titled, .closable, .resizable],
    backing: .buffered, defer: false)
win.title = "FS TEST"
win.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.55, alpha: 1)
win.collectionBehavior = [.fullScreenPrimary]
win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { win.toggleFullScreen(nil) }
DispatchQueue.main.asyncAfter(deadline: .now() + 25) { app.terminate(nil) }
app.run()
