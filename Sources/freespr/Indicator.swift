import AppKit

/// On-screen state indicator: soft glow strips hugging every display's edges — blue breathing
/// while the mic is hot, green (dimmer) breathing while transcribing, and a one-shot purple
/// "bloom" when the text lands. Main-thread only, hosted by the agent's existing AppKit run loop.
///
/// Cheap by construction, because this daemon is always-on:
///  - Four thin edge windows per screen, NOT one full-screen window — ~1% of the backing store,
///    and full-screen apps underneath keep WindowServer direct scanout.
///  - Windows are built once and reused; state changes just recolor and re-show. They're rebuilt
///    only if macOS strands them on one Space (see `stranded`).
///  - Breathing is a repeating CAAnimation executed in the render server — zero app-side timer
///    wakeups during a recording.
///
/// Colors picked from a live demo (2026-07-02): .systemBlue / .systemGreen / .systemPurple —
/// each a one-line swap if taste changes.
enum IndicatorState { case recording, transcribing }

final class Indicator {
    static let glowDepth: CGFloat = 14    // visible depth of the recording/transcribing glow
    static let bloomDepth: CGFloat = 35   // the completion bloom draws 2.5× deep (visibility)

    private var windows: [NSWindow] = []
    private var strips: [GlowStripView] = []
    private var visible: IndicatorState?
    private var epoch = 0   // bumped on every visual change; cancels an in-flight flourish fade

    init() {
        // Display set changed (unplug/lid/resolution): rebuild so the glow lives on whatever
        // screens remain — a hot mic must never be cue-less because a monitor left.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        }
    }

    func set(_ state: IndicatorState) {
        epoch += 1
        visible = state
        ensureWindows()
        let (color, low): (NSColor, Float) = state == .recording
            ? (.systemBlue, 0.35)
            : (.systemGreen, 0.25)
        for v in strips {
            v.color = color
            v.depth = Self.glowDepth
            v.needsDisplay = true
            v.layer?.removeAllAnimations()
            v.layer?.add(Self.breathePulse(low: low), forKey: "breathe")
        }
        show(alpha: 1)
    }

    func clear() {
        epoch += 1
        visible = nil
        for v in strips { v.layer?.removeAllAnimations() }
        for w in windows { w.orderOut(nil) }
    }

    /// One-shot completion bloom: the frame flares purple and fades out, reusing the persistent
    /// windows (no per-dictation allocation). A state change during the ~0.8s bloom bumps
    /// `epoch`, so the fade's completion handlers become no-ops and a fresh recording glow is
    /// never overdrawn or hidden.
    func flourish() {
        epoch += 1
        let myEpoch = epoch
        visible = nil
        ensureWindows()
        for v in strips {
            v.layer?.removeAllAnimations()
            v.color = .systemPurple
            v.depth = Self.bloomDepth   // 2.5× deep so the bloom is unmissable
            v.needsDisplay = true
        }
        show(alpha: 0)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            self.windows.forEach { $0.animator().alphaValue = 1 }
        }, completionHandler: { [weak self] in
            guard let self, self.epoch == myEpoch else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 2.0   // slow fade — the flash was barely visible at 0.7s
                self.windows.forEach { $0.animator().alphaValue = 0 }
            }, completionHandler: { [weak self] in
                guard let self, self.epoch == myEpoch else { return }
                self.windows.forEach { $0.orderOut(nil) }
            })
        })
    }

    /// Pure geometry (self-checked): the four edge-strip frames for a screen rect, tagged with
    /// which edge each hugs. Left/right strips run the FULL screen height so the corners have no
    /// gap; the windows overlap there, but each view miters its paint at 45° (GlowStripView.draw),
    /// so the corner is painted exactly once and the frame reads as one continuous gradient.
    static func stripFrames(around b: NSRect, thickness t: CGFloat) -> [(rect: NSRect, edge: NSRectEdge)] {
        [(NSRect(x: b.minX, y: b.maxY - t, width: b.width, height: t), .maxY),
         (NSRect(x: b.minX, y: b.minY, width: b.width, height: t), .minY),
         (NSRect(x: b.minX, y: b.minY, width: t, height: b.height), .minX),
         (NSRect(x: b.maxX - t, y: b.minY, width: t, height: b.height), .maxX)]
    }

    // MARK: - internals

    private static func breathePulse(low: Float) -> CABasicAnimation {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = low
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return pulse
    }

    /// Hard-set window alpha through a zero-duration animator group — interrupts any in-flight
    /// flourish fade instead of racing it — then order front.
    private func show(alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            windows.forEach { $0.animator().alphaValue = alpha }
        }
        windows.forEach { $0.orderFrontRegardless() }
    }

    /// `.canJoinAllSpaces` windows that sit hidden between dictations can end up pinned to ONE Space
    /// (seen 2026-10-14 on macOS 26.6: sticky tag still set, membership collapsed to a single
    /// desktop), so the glow draws on a desktop you aren't looking at. Only ordered-out windows
    /// get stranded, so checking before every show is enough; a fresh window joins every Space
    /// again, so a stranded fleet is simply rebuilt.
    private var stranded: Bool { windows.contains { !$0.isOnActiveSpace } }

    private func ensureWindows() {
        if stranded {
            log("indicator: glow windows were stranded on another Space; rebuilding them")
            windows.forEach { $0.orderOut(nil) }
            windows.removeAll()
            strips.removeAll()
        }
        guard windows.isEmpty else { return }
        for screen in NSScreen.screens {
            // Windows are sized for the DEEPEST effect (the bloom); the shallower states just
            // draw less of the strip. One persistent fleet serves both.
            for (rect, edge) in Self.stripFrames(around: screen.frame, thickness: Self.bloomDepth) {
                let w = NSWindow(contentRect: rect, styleMask: [.borderless],
                                 backing: .buffered, defer: false)
                w.backgroundColor = .clear
                w.isOpaque = false
                w.hasShadow = false
                w.ignoresMouseEvents = true
                w.level = .screenSaver              // above full-screen video + the menu bar — the point
                w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                w.isReleasedWhenClosed = false
                let v = GlowStripView(edge: edge)
                v.frame = NSRect(origin: .zero, size: rect.size)
                w.contentView = v
                windows.append(w)
                strips.append(v)
            }
        }
    }

    private func screensChanged() {
        let current = visible
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        strips.removeAll()
        if let current { set(current) }   // rebuilds for the new screen set; hidden states stay hidden
    }
}

/// One edge's glow: a gradient bright at the screen border, fading inward. `depth` is how far
/// the gradient reaches (anchored at the outer edge) — the window is sized for the deepest
/// effect, so shallower states paint only the outer part of it.
///
/// Corners are mitered picture-frame style: each strip clips its paint at 45° where two edges
/// meet, so overlapping windows never double-paint. The gradient's alpha depends only on
/// distance-from-edge, which is equal on both sides of the miter line — the seam is invisible
/// and the four strips read as ONE continuous gradient frame.
final class GlowStripView: NSView {
    var color: NSColor = .systemBlue
    var depth: CGFloat = Indicator.glowDepth
    private let edge: NSRectEdge

    init(edge: NSRectEdge) {
        self.edge = edge
        super.init(frame: .zero)
        wantsLayer = true   // the breathe CAAnimation animates this layer's opacity
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let d = depth
        // Repaints swap color/depth, so wipe the previous frame first (views are non-opaque).
        NSColor.clear.setFill()
        b.fill()

        // (outer edge corner 1, corner 2, inner mitered corner 2, inner mitered corner 1)
        let quad: [NSPoint]
        let r: NSRect
        let angle: CGFloat
        switch edge {
        case .maxY:
            r = NSRect(x: 0, y: b.maxY - d, width: b.width, height: d); angle = 270
            quad = [NSPoint(x: 0, y: b.maxY), NSPoint(x: b.maxX, y: b.maxY),
                    NSPoint(x: b.maxX - d, y: b.maxY - d), NSPoint(x: d, y: b.maxY - d)]
        case .minY:
            r = NSRect(x: 0, y: 0, width: b.width, height: d); angle = 90
            quad = [NSPoint(x: 0, y: 0), NSPoint(x: b.maxX, y: 0),
                    NSPoint(x: b.maxX - d, y: d), NSPoint(x: d, y: d)]
        case .minX:
            r = NSRect(x: 0, y: 0, width: d, height: b.height); angle = 0
            quad = [NSPoint(x: 0, y: 0), NSPoint(x: 0, y: b.maxY),
                    NSPoint(x: d, y: b.maxY - d), NSPoint(x: d, y: d)]
        default:
            r = NSRect(x: b.maxX - d, y: 0, width: d, height: b.height); angle = 180
            quad = [NSPoint(x: b.maxX, y: 0), NSPoint(x: b.maxX, y: b.maxY),
                    NSPoint(x: b.maxX - d, y: b.maxY - d), NSPoint(x: b.maxX - d, y: d)]
        }
        let clip = NSBezierPath()
        clip.move(to: quad[0])
        quad.dropFirst().forEach { clip.line(to: $0) }
        clip.close()
        clip.addClip()
        NSGradient(starting: color.withAlphaComponent(0.85), ending: color.withAlphaComponent(0))?
            .draw(in: r, angle: angle)
    }
}
