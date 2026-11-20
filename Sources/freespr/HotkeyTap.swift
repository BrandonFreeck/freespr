import Foundation
import CoreGraphics

let kRightCmd  = 0x36   // Right-Command
let kRightCtrl = 0x3E   // Right-Control

/// Global hotkey via an ACTIVE CGEvent tap. Tap-to-toggle: hold Right-Cmd or Right-Ctrl ALONE,
/// and the toggle fires the INSTANT the hold reaches `threshold` — while the key is still down,
/// no need to release first. A quick tap (released before threshold) or the key used in a
/// shortcut (Right-Cmd+C) never fires, so normal modifiers keep working.
///
/// The tap is `.defaultTap`, which requires ACCESSIBILITY. The headless daemon requests Accessibility
/// in its OWN bundle context (Agent.runForever → AXIsProcessTrustedWithOptions), so the grant attaches
/// to com.freespr.agent and the tap receives events. (Input Monitoring + .listenOnly was a dead end:
/// it has no grant-prompt API, so the grant stranded on the CLI path and the bundle daemon stayed deaf.
/// Accessibility is what every comparable dictation app uses, and is a superset of Input Monitoring.)
///
/// Highest-risk file. Things that bite if gotten wrong, all handled below:
///  1. Key off the KEYCODE, not the modifier mask (the mask can't tell left from right).
///  2. Re-enable the tap on .tapDisabledBy* or the hotkey dies silently.
///  3. Fire from a timer (no key-up event arrives while you keep holding). A generation counter
///     invalidates the timer the moment the hold is cancelled (release / chord / tap-disable), so
///     a stale timer can never fire a phantom toggle.
final class HotkeyTap {
    var onToggle: () -> Void = {}

    private let triggerRightCmd: Bool
    private let triggerRightCtrl: Bool
    private let threshold: TimeInterval

    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdog: DispatchSourceTimer?
    private var tapWasDead = false                       // once-per-episode throttle for the DEAD path
    private var lastReenableLog: CFAbsoluteTime = 0      // rate-limits the re-enabled line (flap guard)

    // Pending-hold state (mutated only on the main run-loop thread: tap callback + main-queue timer).
    private var pendingKey: Int?
    private var chord = false
    private var holdGeneration = 0   // bumped on every state change; a scheduled fire only runs if its gen still matches

    // Modifier bits we treat as "real" for the alone-check (capslock ignored on purpose).
    static let modMask: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]

    init(triggerRightCmd: Bool, triggerRightCtrl: Bool, threshold: TimeInterval) {
        self.triggerRightCmd = triggerRightCmd
        self.triggerRightCtrl = triggerRightCtrl
        self.threshold = threshold
    }

    /// Install the tap on the current run loop. Returns false if the tap couldn't be created
    /// (almost always missing Accessibility) — caller surfaces the permission message.
    @discardableResult
    func start() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,                       // ACTIVE tap: needs Accessibility. The daemon requests
                                                        // it in its OWN bundle context (Agent.runForever), so the
                                                        // grant attaches to com.freespr.agent — unlike Input
                                                        // Monitoring, which has no prompt API and stranded the
                                                        // grant on the CLI path. We still never suppress events.
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tapPort = port
        runLoopSource = source
        armWatchdog()
        return true
    }

    func stop() {
        cancelHold()
        watchdog?.cancel()
        watchdog = nil
        teardownPort()
    }

    private func teardownPort() {
        if let port = tapPort { CGEvent.tapEnable(tap: port, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        tapPort = nil
        runLoopSource = nil
    }

    // MARK: - Watchdog (backstop for silent tap death)

    /// The event-driven re-enable in handle() only helps when the .tapDisabledBy* event is
    /// actually delivered — a tap can also die silently (observed 2026-07-02: live process, dead
    /// hotkey, nothing in the log). Poll health every 30s (recovery latency is free — this
    /// failure previously needed a manual restart): re-enable a disabled tap, re-create a dead
    /// one, and on a mid-session Accessibility revoke surface the SAME recovery UX as launch
    /// (prompt + open the pane, once per episode) instead of spinning silently.
    /// The log lines here are `freespr status` sentinels — keep Lifecycle.daemonHotkeyLive() in sync.
    private func armWatchdog() {
        guard watchdog == nil else { return }   // idempotent: watchdog-triggered start() must not stack timers
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(10))
        t.setEventHandler { [weak self] in self?.checkTapHealth() }
        t.resume()
        watchdog = t
    }

    private func checkTapHealth() {
        guard watchdog != nil else { return }   // a tick already enqueued when stop() ran must not resurrect the tap
        if let port = tapPort, CFMachPortIsValid(port), CGEvent.tapIsEnabled(tap: port) {
            if tapWasDead { log("watchdog: hotkey tap recovered"); tapWasDead = false }
            return
        }
        // Unhealthy. Events were missed while the tap was out — drop any mid-hold state so a
        // swallowed key-release can't fire a phantom toggle (mirrors handle()'s .tapDisabledBy* reset).
        chord = false
        cancelHold()
        if let port = tapPort, CFMachPortIsValid(port) {
            CGEvent.tapEnable(tap: port, enable: true)
            if CGEvent.tapIsEnabled(tap: port) {
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastReenableLog > 600 {   // flap guard: a chronically re-disabled tap logs ~once/10min, not per tick
                    log("watchdog: tap was disabled — re-enabled")
                    lastReenableLog = now
                }
                return
            }
        }
        // Dead port, or the re-enable didn't stick → rebuild from scratch.
        teardownPort()
        if start() {
            log("watchdog: tap recreated")
            tapWasDead = false
        } else if !tapWasDead {
            tapWasDead = true
            log("watchdog: hotkey DEAD — tap recreate failed (Accessibility revoked?); retrying every 30s")
            _ = Permissions.hasAccessibility(prompt: true)   // same recovery UX as launch, once per episode
            Permissions.openPane(Permissions.axPane)
        }
    }

    // MARK: - Callback dispatch (main thread)

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port = tapPort { CGEvent.tapEnable(tap: port, enable: true) } // re-arm or the hotkey dies
            chord = false; cancelHold()   // drop any mid-hold state; events may have been missed
            return nil
        case .keyDown:
            if pendingKey != nil { chord = true; cancelHold() }   // a real key while holding the candidate = a shortcut
            return Unmanaged.passUnretained(event)
        case .flagsChanged:
            return handleFlags(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleFlags(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let active = event.flags.intersection(Self.modMask)

        guard isCandidate(keycode) else {
            // A different modifier changed mid-hold → it's a chord (e.g. R-Cmd+Shift). Cancel.
            if pendingKey != nil { chord = true; cancelHold() }
            return Unmanaged.passUnretained(event)
        }

        let candFlag: CGEventFlags = (keycode == kRightCmd) ? .maskCommand : .maskControl
        let isDown = active.contains(candFlag)

        if isDown {
            if active == candFlag {            // pressed alone → arm the fire-at-threshold timer
                startHold(keycode)
            } else {                            // pressed as part of a combo → not a toggle
                cancelHold()
            }
        } else {
            cancelHold()   // released: already-fired holds are a no-op; a release before threshold = quick tap, no toggle
        }
        // Always pass events through — the toggle fires from the timer, never by swallowing input.
        return Unmanaged.passUnretained(event)
    }

    /// Arm a one-shot timer that fires the toggle when the hold reaches `threshold`, IF the same
    /// key is still held alone (no release, no chord) at that point.
    private func startHold(_ keycode: Int) {
        holdGeneration += 1
        let gen = holdGeneration
        pendingKey = keycode
        chord = false
        DispatchQueue.main.asyncAfter(deadline: .now() + threshold) { [weak self] in
            guard let self, gen == self.holdGeneration, self.pendingKey == keycode, !self.chord else { return }
            self.holdGeneration += 1   // consume this hold so the eventual release is a clean no-op
            self.pendingKey = nil
            self.onToggle()
        }
    }

    /// Invalidate any scheduled fire and clear the pending hold.
    private func cancelHold() {
        holdGeneration += 1
        pendingKey = nil
    }

    private func isCandidate(_ keycode: Int) -> Bool {
        (keycode == kRightCmd && triggerRightCmd) || (keycode == kRightCtrl && triggerRightCtrl)
    }
}

/// Top-level C callback (CGEventTapCallBack is a bare function pointer — no captures). The
/// HotkeyTap instance arrives via refcon.
private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type: type, event: event)
}
