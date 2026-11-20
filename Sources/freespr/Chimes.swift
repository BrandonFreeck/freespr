import AppKit

/// Distinct start/stop/ready/error chimes so you know recording is hot without a menu bar. Uses built-in
/// system sounds (/System/Library/Sounds) — zero shipped assets. play() is non-blocking and
/// main-thread safe; cached instances avoid clipping on rapid re-trigger.
final class Chimes {
    private let startSound = NSSound(named: "Tink")     // recording started
    private let stopSound  = NSSound(named: "Bottle")   // recording stopped, now transcribing
    private let readySound = NSSound(named: "Glass")    // result is on the clipboard, ready to paste
    private let errorSound = NSSound(named: "Basso")    // could not record (e.g. microphone denied)

    func start() { startSound?.stop(); startSound?.play() }
    func stop()  { stopSound?.stop();  stopSound?.play() }
    func ready() { readySound?.stop(); readySound?.play() }
    func error() { errorSound?.stop(); errorSound?.play() }
}
