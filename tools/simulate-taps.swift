// Diktovkani tekshirish uchun ⌘ bosishlarini sintetik yuborish.
// Egasini bezovta qilmasdan to'liq siklni sinash imkonini beradi.
//
//   swiftc -O tools/simulate-taps.swift -o /tmp/taps
//   /tmp/taps tap2   — левый ⌘⌘  (старт записи)
//   /tmp/taps rtap2  — правый ⌘⌘ (старт записи)
//   /tmp/taps tap1   — левый ⌘   (стоп и вставка; без записи — ничего не делает)
//   /tmp/taps rtap1  — правый ⌘  (то же самое)
//   /tmp/taps cmdc   — ⌘C ikki marta: yozish BOSHLANMASLIGI kerak
//   /tmp/taps hold   — ⌘ ni uzoq ushlash: yozish boshlanmasligi kerak
//   /tmp/taps esc    — ⎋ (bekor qilish)
//
// Eslatma: ishga tushiruvchi terminalda Accessibility ruxsati bo'lishi shart.

import Cocoa

let src = CGEventSource(stateID: .hidSystemState)

func post(_ key: CGKeyCode, _ down: Bool, _ flags: CGEventFlags = []) {
    let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
    e?.flags = flags
    e?.post(tap: .cghidEventTap)
}

/// Bitta toza ⌘ "tap"i. 55 — левый ⌘, 54 — правый.
func cmdTap(hold: UInt32 = 60_000, key: CGKeyCode = 55) {
    post(key, true, .maskCommand)
    usleep(hold)
    post(key, false, [])
}

/// ⌘C — birikma, u hech qachon tap deb hisoblanmasligi kerak
func cmdC() {
    post(55, true, .maskCommand); usleep(30_000)
    post(8, true, .maskCommand); usleep(20_000); post(8, false, .maskCommand)
    usleep(30_000); post(55, false, [])
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "tap2"
switch mode {
case "tap1": cmdTap()
case "rtap1": cmdTap(key: 54)
case "tap2": cmdTap(); usleep(140_000); cmdTap()
case "rtap2": cmdTap(key: 54); usleep(140_000); cmdTap(key: 54)
case "cmdc": cmdC(); usleep(150_000); cmdC()
case "hold": post(55, true, .maskCommand); usleep(900_000); post(55, false, [])
case "esc":  post(53, true, []); usleep(20_000); post(53, false, [])
default:
    print("noma'lum rejim: \(mode)")
    exit(1)
}
print("yuborildi: \(mode)  (AXTrusted=\(AXIsProcessTrusted()))")
