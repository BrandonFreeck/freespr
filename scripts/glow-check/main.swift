import AppKit
// `make glow-check`: regression for the stranded-Space glow (2026-10-14). Builds the glow, lets it go
// idle the way a real dictation leaves it (purple bloom fades, windows ordered out), strands its
// windows on ONE inactive Space via WindowServer SPI (the state the live agent was found in), then
// shows it again and checks the glow is actually on screen. Needs a logged-in desktop with 2+ Spaces;
// flashes the glow for ~10s. Exit 0 = all pass.
func log(_ s: String) { print("  log:", s); fflush(stdout) }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let ind = Indicator()
let h = dlopen(nil, RTLD_NOW)
typealias MainConn = @convention(c) () -> Int32
typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
typealias ActiveSpace = @convention(c) (Int32) -> UInt64
typealias MoveSpaces = @convention(c) (Int32, CFArray, CFArray) -> Void
let cid = unsafeBitCast(dlsym(h, "CGSMainConnectionID")!, to: MainConn.self)()
let copySpaces = unsafeBitCast(dlsym(h, "CGSCopySpacesForWindows")!, to: CopySpaces.self)
let activeF = unsafeBitCast(dlsym(h, "CGSGetActiveSpace")!, to: ActiveSpace.self)
let removeF = unsafeBitCast(dlsym(h, "CGSRemoveWindowsFromSpaces")!, to: MoveSpaces.self)
let addF = unsafeBitCast(dlsym(h, "CGSAddWindowsToSpaces")!, to: MoveSpaces.self)
var failures = 0

func glow() -> [NSWindow] { NSApp.windows.filter { $0.contentView is GlowStripView } }
func spaces(_ w: Int) -> [UInt64] { copySpaces(cid, 7, [UInt32(w)] as CFArray)?.takeRetainedValue() as? [UInt64] ?? [] }
func check(_ tag: String, _ ok: Bool, _ detail: String) {
    if !ok { failures += 1 }
    print("[\(tag)] \(detail) — \(ok ? "PASS" : "FAIL")"); fflush(stdout)
}
func strand() {
    let ws = glow().map(\.windowNumber), all = spaces(ws[0]), active = activeF(cid)
    guard let other = all.first(where: { $0 != active }) else { print("need 2+ desktops"); exit(2) }
    removeF(cid, ws.map { UInt32($0) } as CFArray, all as CFArray)
    addF(cid, ws.map { UInt32($0) } as CFArray, [other] as CFArray)
    let now = Set(ws.map { spaces($0) })
    check("strand (setup)", now == [[other]] && glow().allSatisfy { !$0.isOnActiveSpace },
          "active=\(active), windows now on \(now)")
}
func onScreen(_ tag: String) {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
    let shown = Set(glow().filter(\.isVisible).map(\.windowNumber))
    let n = list.filter { shown.contains($0[kCGWindowNumber as String] as! Int) }.count
    check(tag, !shown.isEmpty && n == shown.count, "\(n)/\(shown.count) shown glow windows on screen")
}
var steps: [(Double, () -> Void)] = [
    (0.0, { ind.set(.recording) }),
    (0.5, { onScreen("fresh recording"); ind.clear(); ind.flourish() }),
    (2.6, { strand() }),
    (0.1, { ind.set(.recording) }),
    (0.5, { onScreen("recording after strand"); ind.clear(); ind.flourish() }),
    (2.6, { strand() }),
    (0.1, { ind.flourish() }),
    (0.3, { onScreen("bloom after strand") }),
    (3.0, { check("old windows released", glow().count == 4, "\(glow().count) glow windows alive (want 4)") }),
    (0.1, { print(failures == 0 ? "ALL PASS" : "\(failures) FAILED"); exit(failures == 0 ? 0 : 1) }),
]
var t = 0.3
for (d, f) in steps { t += d; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
app.run()
