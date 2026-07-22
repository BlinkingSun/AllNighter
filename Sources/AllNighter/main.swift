import Cocoa
import Network
import QuartzCore
import ImageIO
import UniformTypeIdentifiers

let kDefaultPort: NWEndpoint.Port = 17893
let kLidDefaultsKey = "closedLidMode"
let kSudoersPath = "/etc/sudoers.d/allnighter-pmset"

/// Resolve listener port: optional `ALLNIGHTER_PORT` env override, else 17893.
func resolvePort() -> NWEndpoint.Port {
    if let env = ProcessInfo.processInfo.environment["ALLNIGHTER_PORT"],
       let n = UInt16(env), n > 0,
       let p = NWEndpoint.Port(rawValue: n) {
        return p
    }
    return kDefaultPort
}

// MARK: - Agent pulse envelope (verbatim from reference_mockup.swift mode A)

let kGoldCore = NSColor(calibratedRed: 1.00, green: 0.80, blue: 0.25, alpha: 1)
let kGoldGlow = NSColor(calibratedRed: 1.00, green: 0.72, blue: 0.15, alpha: 1)

/// Gold intensity 0..1 for cycle phase t in 0..<1 (Option A: ramp-up).
func goldIntensity(t: CGFloat) -> CGFloat {
    // mode "A": builds 0→full over 0.8s, sharp fade over 0.2s
    return t < 0.8 ? (t / 0.8) : (1 - (t - 0.8) / 0.2)
}

/// Black contrast ring alpha: rises as gold fades (0.8→1.0), decays to 0 by t=0.3.
func blackAlpha(t: CGFloat) -> CGFloat {
    if t >= 0.8 { return (t - 0.8) / 0.2 }
    if t < 0.3 { return 1 - (t / 0.3) }
    return 0
}

// MARK: - Status-bar icon rendering (shared by the app and the --preview mode)

/// Draws the on/off pill. `isOn` colours it green vs gray; when `lidMode` is true
/// and agent is inactive a glowing yellow ring is drawn (closed-lid keep-alive).
/// `agentPhase` nil = no agent (legacy path); 0..<1 = agent pulse phase.
func makeStatusIcon(isOn: Bool, lidMode: Bool, agentPhase: CGFloat? = nil,
                    barHeight: CGFloat) -> NSImage {
    let padX: CGFloat = 5          // horizontal room so the glow isn't clipped
    let padY: CGFloat = 3          // vertical room for the glow
    let pillH = max(12, barHeight - padY * 2)
    let pillW: CGFloat = 42
    let size = NSSize(width: pillW + padX * 2, height: barHeight)

    let img = NSImage(size: size)
    img.lockFocus()
    defer { img.unlockFocus() }

    let pillRect = NSRect(x: padX, y: (barHeight - pillH) / 2, width: pillW, height: pillH)
    let radius = pillH / 2

    // Pill background — USER display switch only
    let bg = isOn ? NSColor.systemGreen : NSColor.gray
    let pill = NSBezierPath(roundedRect: pillRect, xRadius: radius, yRadius: radius)
    bg.setFill()
    pill.fill()

    // Sliding thumb
    let thumbD = pillH - 4
    let thumbX = isOn ? (pillRect.maxX - thumbD - 2) : (pillRect.minX + 2)
    let thumbRect = NSRect(x: thumbX, y: pillRect.minY + 2, width: thumbD, height: thumbD)
    NSColor.white.withAlphaComponent(0.95).setFill()
    NSBezierPath(ovalIn: thumbRect).fill()

    // ON / OFF label
    let text = isOn ? "ON" : "OFF"
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10, weight: .bold),
        .foregroundColor: NSColor.white
    ]
    let ts = text.size(withAttributes: attrs)
    let textX = isOn ? (pillRect.minX + 5) : (pillRect.maxX - ts.width - 5)
    let textY = pillRect.minY + (pillH - ts.height) / 2
    text.draw(at: NSPoint(x: textX, y: textY), withAttributes: attrs)

    if let t = agentPhase {
        // Agent active: static yellow lid ring NEVER drawn. Black contrast then gold pulse.
        let ba = blackAlpha(t: t)
        if ba > 0.01 {
            let r = pillRect.insetBy(dx: -0.25, dy: -0.25)
            let p = NSBezierPath(roundedRect: r, xRadius: radius + 0.25, yRadius: radius + 0.25)
            p.lineWidth = 1.0
            NSColor.black.withAlphaComponent(ba).setStroke()
            p.stroke()
        }
        let gi = goldIntensity(t: t)
        if gi > 0.01 {
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = kGoldGlow.withAlphaComponent(0.95 * gi)
            glow.shadowBlurRadius = 4 + 3 * gi
            glow.shadowOffset = .zero
            glow.set()
            let ringRect = pillRect.insetBy(dx: -1.5, dy: -1.5)
            let ring = NSBezierPath(roundedRect: ringRect, xRadius: radius + 1.5, yRadius: radius + 1.5)
            ring.lineWidth = 1.8
            kGoldCore.withAlphaComponent(gi).setStroke()
            ring.stroke()
            ring.stroke()
            if gi > 0.6 { ring.stroke() }   // extra bloom at peak
            NSGraphicsContext.restoreGraphicsState()
        }
    } else if lidMode {
        // Glowing yellow ring — closed-lid keep-alive when agent is inactive only.
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = NSColor.systemYellow.withAlphaComponent(0.95)
        glow.shadowBlurRadius = 4
        glow.shadowOffset = .zero
        glow.set()
        let ringRect = pillRect.insetBy(dx: -1.5, dy: -1.5)
        let ring = NSBezierPath(roundedRect: ringRect, xRadius: radius + 1.5, yRadius: radius + 1.5)
        ring.lineWidth = 1.8
        NSColor.systemYellow.setStroke()
        ring.stroke()
        ring.stroke()   // second pass intensifies the bloom
        NSGraphicsContext.restoreGraphicsState()
    }

    img.isTemplate = false   // keep our colours (no menu-bar tinting)
    return img
}

// MARK: - Agent id parsing

/// Parse and sanitize an agent id from a query string (`id=X`). Missing / empty /
/// fully-stripped → `"default"`; length > 64 → truncate to 64. Takes the FIRST
/// `id=` param only. Strips whitespace/control chars; removes `"` and `\`.
func parseAgentID(query: String?) -> String {
    guard let query = query, !query.isEmpty else { return "default" }
    var raw: String?
    for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
        let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard let key = kv.first, key == "id" else { continue }
        raw = kv.count > 1 ? String(kv[1]) : ""
        break
    }
    guard let raw = raw else { return "default" }
    return sanitizeAgentID(raw)
}

func sanitizeAgentID(_ raw: String) -> String {
    let stripped = raw.unicodeScalars
        .filter { !CharacterSet.whitespacesAndNewlines.contains($0)
               && !CharacterSet.controlCharacters.contains($0) }
        .map(String.init)
        .joined()
        .replacingOccurrences(of: "\\", with: "")
        .replacingOccurrences(of: "\"", with: "")
    if stripped.isEmpty { return "default" }
    if stripped.count > 64 { return String(stripped.prefix(64)) }
    return stripped
}

final class AllNighter: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var caffeinate: Process?
    private var listener: NWListener?
    private(set) var isOn = false            // USER display keep-awake switch
    private(set) var lidMode = false         // USER closed-lid switch (persisted)
    private var agentIDs: Set<String> = []   // ACTIVE agent sessions (in-memory only)
    var agentActive: Bool { !agentIDs.isEmpty }
    private var appliedEffectiveLid = false  // last SUCCESSFULLY applied disablesleep state
    private var needsRecompute = false       // coalesce flag while privileged work in flight
    private var lidBusy = false              // guards against overlapping privileged calls
    private let lidQueue = DispatchQueue(label: "com.allnighter.mac.lid")
    private var sigSources: [DispatchSourceSignal] = []
    /// ~30 Hz redraw timer; non-nil ONLY while agentActive.
    private var pulseTimer: DispatchSourceTimer?
    /// Discrete phase buckets per 1.0 s cycle (timer resolution → 30 distinct frames).
    private let pulseBucketCount = 30
    /// Last bucket assigned to the status button (skip assign when unchanged).
    private var lastDrawnBucket: Int? = nil
    /// Cached CGImages keyed by bucket; valid for one (userOn, barHeight) pair.
    private var pulseCGCache: [Int: CGImage] = [:]
    private var pulseCacheIsOn: Bool?
    private var pulseCacheBarHeight: CGFloat = -1
    /// Placeholder NSImage kept on the button for correct status-item sizing only.
    private var pulseSizePlaceholder: NSImage?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refreshIcon()
        startServer()
        installSignalHandlers()
        restoreLidModeAtLaunch()
    }

    @objc private func handleClick(_ sender: Any?) {
        // Ctrl-click is the trackpad right-click convention
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            statusItem.menu = buildMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            setState(!isOn)
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let h1 = NSMenuItem(title: "Display keep-awake: \(isOn ? "ON" : "OFF")",
                            action: nil, keyEquivalent: "")
        h1.isEnabled = false
        menu.addItem(h1)

        let h2 = NSMenuItem(title: "Closed-lid keep-alive: \(lidMode ? "ON" : "OFF")",
                            action: nil, keyEquivalent: "")
        h2.isEnabled = false
        menu.addItem(h2)

        let h3 = NSMenuItem(
            title: agentActive
                ? "Agent keep-awake: ACTIVE (\(agentIDs.count))"
                : "Agent keep-awake: off",
            action: nil, keyEquivalent: "")
        h3.isEnabled = false
        menu.addItem(h3)

        menu.addItem(NSMenuItem.separator())

        let toggleItem = NSMenuItem(
            title: isOn ? "Turn Off (display awake)" : "Turn On (display awake)",
            action: #selector(toggleFromMenu),
            keyEquivalent: "t"
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        let lidItem = NSMenuItem(
            title: lidBusy ? "Keep awake with lid closed…" : "Keep awake with lid closed",
            action: #selector(toggleLidFromMenu),
            keyEquivalent: "l"
        )
        lidItem.target = self
        lidItem.state = lidMode ? .on : .off
        lidItem.isEnabled = !lidBusy
        lidItem.toolTip = "Let the Mac stay awake with the lid closed (screen may turn off). "
                        + "Uses pmset disablesleep; first use asks for your admin password once."
        menu.addItem(lidItem)

        let clearItem = NSMenuItem(
            title: "Clear agent keep-awake",
            action: #selector(clearAgentFromMenu),
            keyEquivalent: ""
        )
        clearItem.target = self
        clearItem.isEnabled = agentActive
        clearItem.toolTip = "Agents switch this on via the local API; clearing reverts "
                          + "to the user switches."
        menu.addItem(clearItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit AllNighter",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)
        return menu
    }

    @objc private func toggleFromMenu() {
        setState(!isOn)
    }

    @objc private func toggleLidFromMenu() {
        setLidMode(!lidMode, interactive: true)
    }

    @objc private func clearAgentFromMenu() {
        clearAgentIDs()
    }

    // MARK: - Desired effective state

    private var desiredDisplay: Bool { isOn || agentActive }
    private var desiredLid: Bool { lidMode || agentActive }

    // MARK: - applyEffectiveState (single transition path)

    /// Apply caffeinate / pmset to match desired effective state derived from
    /// user switches + agent set. Coalesces while privileged work is in flight.
    private func applyEffectiveState() {
        // Display (caffeinate) — always applied immediately on main.
        let wantDisplay = desiredDisplay
        let running = caffeinate.map { $0.isRunning } ?? false
        if wantDisplay && !running {
            startCaffeinate()
        } else if !wantDisplay && caffeinate != nil {
            caffeinate?.terminate()
            caffeinate = nil
        }

        // Lid (pmset disablesleep) — only when desired ≠ last successful apply.
        let wantLid = desiredLid
        if wantLid == appliedEffectiveLid {
            refreshIcon()
            return
        }

        if lidBusy {
            // Coalesce, never drop: mark for a single re-run with latest flags.
            needsRecompute = true
            refreshIcon()
            return
        }

        lidBusy = true
        let target = wantLid
        lidQueue.async { [weak self] in
            guard let self = self else { return }
            let ok = self.sudoSet(target ? 1 : 0)
            DispatchQueue.main.async {
                self.lidBusy = false
                if ok {
                    self.appliedEffectiveLid = target
                } else {
                    NSLog("AllNighter: sudo pmset disablesleep \(target ? 1 : 0) failed (silent)")
                    // Leave appliedEffectiveLid unchanged; a later external apply retries.
                }

                let stillDesired = self.desiredLid
                if self.needsRecompute {
                    self.needsRecompute = false
                    self.applyEffectiveState()
                } else if stillDesired != self.appliedEffectiveLid {
                    // Desired drifted during the job (or silent failure left a gap).
                    // On silent failure avoid an infinite spin: only re-enter when
                    // the just-finished job succeeded and flags changed mid-flight.
                    if ok {
                        self.applyEffectiveState()
                    } else {
                        self.refreshIcon()
                    }
                } else {
                    self.refreshIcon()
                }
            }
        }
    }

    // MARK: - Display keep-awake (user switch only; effects via applyEffectiveState)

    /// Start caffeinate with -w watch-pid so it self-terminates if this process dies
    /// (prevents orphans after kill -9 that reparent to launchd and leave the display awake).
    private func startCaffeinate() {
        let p = Process()
        p.launchPath = "/usr/bin/caffeinate"
        let pid = ProcessInfo.processInfo.processIdentifier
        p.arguments = ["-d", "-i", "-w", "\(pid)"]
        do {
            try p.run()
            caffeinate = p
        } catch {
            NSLog("Failed to launch caffeinate: \(error)")
            caffeinate = nil
        }
    }

    func setState(_ on: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if on == self.isOn { return }
            self.isOn = on
            self.applyEffectiveState()
        }
    }

    // MARK: - Closed-lid keep-alive (user switch; effects via applyEffectiveState)

    /// Toggle closed-lid user switch. Runs privileged work only through
    /// `applyEffectiveState()` (silent sudo). Interactive menu lid-on may
    /// install the sudoers rule once after silent failure — exactly as before.
    func setLidMode(_ on: Bool, interactive: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if on == self.lidMode { return }

            if interactive && on {
                // Interactive enable: try silent apply after committing intention;
                // if sudo fails, prompt for sudoers install once, then re-apply.
                self.lidMode = true
                UserDefaults.standard.set(true, forKey: kLidDefaultsKey)
                self.applyEffectiveStateInteractiveLidOn()
                return
            }

            self.lidMode = on
            UserDefaults.standard.set(on, forKey: kLidDefaultsKey)
            self.applyEffectiveState()
        }
    }

    /// Interactive lid-on path: silent sudo first; on failure, one-time admin
    /// prompt via installSudoersRule, then silent retry. Never used by API/agent.
    private func applyEffectiveStateInteractiveLidOn() {
        // Always sync display first (caffeinate half of apply).
        let wantDisplay = desiredDisplay
        let running = caffeinate.map { $0.isRunning } ?? false
        if wantDisplay && !running {
            startCaffeinate()
        } else if !wantDisplay && caffeinate != nil {
            caffeinate?.terminate()
            caffeinate = nil
        }

        let wantLid = desiredLid
        if wantLid == appliedEffectiveLid {
            refreshIcon()
            return
        }
        if lidBusy {
            needsRecompute = true
            refreshIcon()
            return
        }

        lidBusy = true
        lidQueue.async { [weak self] in
            guard let self = self else { return }
            var ok = self.sudoSet(1)
            if !ok, self.installSudoersRule() {
                ok = self.sudoSet(1)
            }
            DispatchQueue.main.async {
                self.lidBusy = false
                if ok {
                    self.appliedEffectiveLid = true
                } else {
                    // Revert user intention — match prior interactive failure UX.
                    self.lidMode = false
                    UserDefaults.standard.set(false, forKey: kLidDefaultsKey)
                    self.showLidError()
                }
                if self.needsRecompute {
                    self.needsRecompute = false
                    self.applyEffectiveState()
                } else if self.desiredLid != self.appliedEffectiveLid {
                    if ok {
                        self.applyEffectiveState()
                    } else {
                        self.refreshIcon()
                    }
                } else {
                    self.refreshIcon()
                }
            }
        }
    }

    // MARK: - Agent set (agent routes only; effects via applyEffectiveState)

    /// Insert id and recompute. Safe from any queue (hops to main).
    func agentOn(id: String) {
        let work = { [weak self] in
            guard let self = self else { return }
            let wasEmpty = self.agentIDs.isEmpty
            self.agentIDs.insert(id)
            if wasEmpty { self.syncPulseTimer() }
            self.applyEffectiveState()
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// Remove id (unknown = no-op) and recompute.
    func agentOff(id: String) {
        let work = { [weak self] in
            guard let self = self else { return }
            self.agentIDs.remove(id)
            if self.agentIDs.isEmpty { self.syncPulseTimer() }
            self.applyEffectiveState()
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// Empty the agent set and recompute.
    func clearAgentIDs() {
        let work = { [weak self] in
            guard let self = self else { return }
            self.agentIDs.removeAll()
            self.syncPulseTimer()
            self.applyEffectiveState()
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// Start ~30 Hz redraw timer only while agentActive; cancel when the set empties.
    private func syncPulseTimer() {
        if agentActive {
            guard pulseTimer == nil else { return }
            // Render all buckets once up front so steady-state ticks never lockFocus.
            prewarmPulseCache()
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .milliseconds(8))
            t.setEventHandler { [weak self] in
                self?.pulseTick()
            }
            t.resume()
            pulseTimer = t
        } else {
            pulseTimer?.cancel()
            pulseTimer = nil
            clearPulseCache()
        }
    }

    private func clearPulseCache() {
        lastDrawnBucket = nil
        pulseCGCache.removeAll(keepingCapacity: false)
        pulseCacheIsOn = nil
        pulseCacheBarHeight = -1
        pulseSizePlaceholder = nil
    }

    /// Media-time phase → bucket index in `0 ..< pulseBucketCount`.
    private func currentPulseBucket() -> Int {
        let phase = fmod(CACurrentMediaTime(), 1.0)
        var b = Int(phase * Double(pulseBucketCount))
        if b >= pulseBucketCount { b = pulseBucketCount - 1 }
        if b < 0 { b = 0 }
        return b
    }

    /// Ensure cache matches (userOn, barHeight); drop frames if either changed.
    private func ensurePulseCacheValid(barHeight: CGFloat) {
        if pulseCacheIsOn != isOn || pulseCacheBarHeight != barHeight {
            pulseCGCache.removeAll(keepingCapacity: true)
            pulseCacheIsOn = isOn
            pulseCacheBarHeight = barHeight
            pulseSizePlaceholder = nil
            lastDrawnBucket = nil
        }
    }

    /// Rasterize one bucket to a CGImage at menu-bar backing scale (once per frame key).
    private func rasterizedCG(isOn: Bool, barHeight: CGFloat, bucket: Int, scale: CGFloat) -> CGImage? {
        let qPhase = CGFloat(bucket) / CGFloat(pulseBucketCount)
        let drawn = makeStatusIcon(isOn: isOn,
                                   lidMode: lidMode,
                                   agentPhase: qPhase,
                                   barHeight: barHeight)
        // Stable size placeholder (empty) so status-item length does not thrash on frame swaps.
        if pulseSizePlaceholder == nil {
            let ph = NSImage(size: drawn.size)
            ph.isTemplate = false
            pulseSizePlaceholder = ph
        }
        let pxW = max(1, Int((drawn.size.width * scale).rounded()))
        let pxH = max(1, Int((drawn.size.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pxW,
                pixelsHigh: pxH,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ) else { return nil }
        rep.size = drawn.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        drawn.draw(in: NSRect(origin: .zero, size: drawn.size),
                   from: .zero,
                   operation: .sourceOver,
                   fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// Render every bucket once for the current (userOn, barHeight).
    private func prewarmPulseCache() {
        let height = NSStatusBar.system.thickness
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        ensurePulseCacheValid(barHeight: height)
        for b in 0..<pulseBucketCount where pulseCGCache[b] == nil {
            if let cg = rasterizedCG(isOn: isOn, barHeight: height, bucket: b, scale: scale) {
                pulseCGCache[b] = cg
            }
        }
    }

    /// Swap layer.contents to a pre-baked CGImage (cheap texture swap; no NSImage rebuild).
    private func presentPulseCG(_ cg: CGImage, on button: NSButton) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        // Placeholder image keeps status-item length stable; pixels come from the layer.
        if button.image !== pulseSizePlaceholder, let ph = pulseSizePlaceholder {
            button.image = ph
        }
        button.wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let layer = button.layer {
            layer.contents = cg
            layer.contentsGravity = .center
            layer.contentsScale = scale
        }
        CATransaction.commit()
    }

    /// ~30 Hz tick: skip when bucket unchanged; else present a cached frame only.
    private func pulseTick() {
        guard agentActive else { return }
        let bucket = currentPulseBucket()
        if bucket == lastDrawnBucket { return }
        // Steady-state: cache is prewarmed — no makeStatusIcon, no height re-check.
        if let cg = pulseCGCache[bucket], let button = statusItem.button {
            presentPulseCG(cg, on: button)
            lastDrawnBucket = bucket
            return
        }
        // Rare miss (e.g. first tick before prewarm finished): bake this bucket only.
        applyPulseBucket(bucket)
    }

    /// Force-apply a pulse frame (state change / cache miss). May bake on miss.
    private func applyPulseBucket(_ bucket: Int) {
        guard let button = statusItem.button else { return }
        let height = NSStatusBar.system.thickness
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        ensurePulseCacheValid(barHeight: height)
        let cg: CGImage
        if let cached = pulseCGCache[bucket] {
            cg = cached
        } else if let made = rasterizedCG(isOn: isOn, barHeight: height, bucket: bucket, scale: scale) {
            pulseCGCache[bucket] = made
            cg = made
        } else {
            return
        }
        presentPulseCG(cg, on: button)
        lastDrawnBucket = bucket
    }

    /// Snapshot agent set for status responses (main-thread).
    private func agentStatusParts() -> (on: Bool, count: Int, list: [String]) {
        let list = agentIDs.sorted()
        return (!list.isEmpty, list.count, list)
    }

    /// Re-establish the persisted closed-lid state at launch, without ever prompting.
    /// Also clears any stale `disablesleep` left behind by a hard crash (incl. agent-only).
    private func restoreLidModeAtLaunch() {
        let want = UserDefaults.standard.bool(forKey: kLidDefaultsKey)
        lidQueue.async { [weak self] in
            guard let self = self else { return }
            var active = false
            if want {
                active = self.sudoSet(1)        // silent; only succeeds if the rule is installed
            } else {
                _ = self.sudoSet(0)             // harmless no-op if the rule is absent
            }
            DispatchQueue.main.async {
                self.lidMode = active
                self.appliedEffectiveLid = active
                if want != active {
                    UserDefaults.standard.set(active, forKey: kLidDefaultsKey)
                }
                self.refreshIcon()
            }
        }
    }

    @discardableResult
    private func runSync(_ launch: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.launchPath = launch
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Set pmset disablesleep without prompting; succeeds only when the sudoers rule exists.
    private func sudoSet(_ value: Int) -> Bool {
        return runSync("/usr/bin/sudo",
                       ["-n", "/usr/bin/pmset", "-a", "disablesleep", "\(value)"]) == 0
    }

    private func asEscape(_ s: String) -> String {
        return s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// One-time: install a validated, minimal NOPASSWD sudoers drop-in (prompts once for admin).
    /// Only `pmset -a disablesleep 0|1` is permitted; the file is validated with visudo first.
    private func installSudoersRule() -> Bool {
        let user = NSUserName()
        let line = "\(user) ALL=(root) NOPASSWD: "
                 + "/usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        let shell = "f=$(/usr/bin/mktemp); "
                  + "/bin/echo '\(line)' > \"$f\"; "
                  + "/usr/sbin/visudo -cf \"$f\" && "
                  + "/usr/bin/install -m 440 -o root -g wheel \"$f\" \(kSudoersPath); "
                  + "r=$?; /bin/rm -f \"$f\"; exit $r"
        let osa = "do shell script \"\(asEscape(shell))\" with administrator privileges"
        return runSync("/usr/bin/osascript", ["-e", osa]) == 0
    }

    private func showLidError() {
        let a = NSAlert()
        a.messageText = "Couldn’t enable closed-lid mode"
        a.informativeText = "AllNighter needs one-time administrator approval to let the Mac stay "
            + "awake with the lid closed (it uses “pmset disablesleep”). The password prompt was "
            + "cancelled or failed, so nothing was changed."
        a.alertStyle = .warning
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // MARK: - Icon

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        if agentActive {
            // State change while pulsing: ensure cache matches isOn, force current frame.
            prewarmPulseCache()
            applyPulseBucket(currentPulseBucket())
        } else {
            clearPulseCache()
            // Drop pulse layer so the static NSImage is what the menu bar shows.
            if button.wantsLayer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                button.layer?.contents = nil
                CATransaction.commit()
            }
            button.image = makeStatusIcon(isOn: isOn,
                                          lidMode: lidMode,
                                          agentPhase: nil,
                                          barHeight: NSStatusBar.system.thickness)
        }
        let agentPart = agentActive ? "ACTIVE(\(agentIDs.count))" : "off"
        button.toolTip = "AllNighter — display: \(isOn ? "ON" : "OFF"), "
                       + "closed-lid: \(lidMode ? "ON" : "OFF"), "
                       + "agent: \(agentPart)"
    }

    // MARK: - Clean-up on exit (never leave the Mac unable to sleep)

    /// Best-effort clear of disablesleep + caffeinate. Routed through lidQueue so an
    /// in-flight privileged job cannot skip the cleanup.
    private func cleanupBeforeExit() {
        pulseTimer?.cancel()
        pulseTimer = nil
        clearPulseCache()
        let needClear = appliedEffectiveLid || lidMode || agentActive
        lidQueue.sync {
            if needClear {
                _ = sudoSet(0)
            }
        }
        caffeinate?.terminate()
        caffeinate = nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanupBeforeExit()
    }

    private func installSignalHandlers() {
        for s in [SIGTERM, SIGINT] {
            signal(s, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: s, queue: .main)
            src.setEventHandler { [weak self] in
                self?.cleanupBeforeExit()
                exit(0)
            }
            src.resume()
            sigSources.append(src)
        }
    }

    // MARK: - HTTP server

    private func startServer() {
        let port = resolvePort()
        do {
            let params = NWParameters.tcp
            params.acceptLocalOnly = true
            listener = try NWListener(using: params, on: port)
        } catch {
            NSLog("HTTP listener failed to bind on \(port): \(error)")
            return
        }
        listener?.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener?.start(queue: .main)
        NSLog("AllNighter HTTP listening on 127.0.0.1:\(port)")
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self = self, let data = data,
                  let req = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            let firstLine = req.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ").map(String.init)
            let method = parts.count > 0 ? parts[0] : ""
            let rawPath = parts.count > 1 ? parts[1] : "/"
            // Split on FIRST '?' before routing so a query string never 404s.
            let path: String
            let query: String?
            if let q = rawPath.firstIndex(of: "?") {
                path = String(rawPath[..<q])
                query = String(rawPath[rawPath.index(after: q)...])
            } else {
                path = rawPath
                query = nil
            }
            self.respond(conn, method: method, path: path, query: query)
        }
    }

    private func respond(_ conn: NWConnection, method: String, path: String, query: String?) {
        var body = ""
        var status = "200 OK"
        let route = "\(method) \(path)"
        switch route {
        case "GET /status", "GET /":
            // Prefix-compatible: existing keys first, then new keys in documented order.
            let stateS = isOn ? "on" : "off"
            let lidS = lidMode ? "on" : "off"
            let agentS = agentActive ? "on" : "off"
            let n = agentIDs.count
            let edS = desiredDisplay ? "on" : "off"
            let elS = desiredLid ? "on" : "off"
            body = "{\"state\":\"\(stateS)\",\"closedLid\":\"\(lidS)\""
                 + ",\"agent\":\"\(agentS)\",\"agentIds\":\(n)"
                 + ",\"effectiveDisplay\":\"\(edS)\""
                 + ",\"effectiveLid\":\"\(elS)\"}"
        case "POST /on", "GET /on", "PUT /on":
            setState(true)
            body = "{\"state\":\"on\"}"
        case "POST /off", "GET /off", "PUT /off":
            setState(false)
            body = "{\"state\":\"off\"}"
        case "POST /toggle", "GET /toggle", "PUT /toggle":
            setState(!isOn)
            body = "{\"state\":\"\(!isOn ? "on" : "off")\"}"
        case "POST /lid/on", "GET /lid/on", "PUT /lid/on":
            setLidMode(true, interactive: false)
            body = "{\"closedLid\":\"on\"}"
        case "POST /lid/off", "GET /lid/off", "PUT /lid/off":
            setLidMode(false, interactive: false)
            body = "{\"closedLid\":\"off\"}"
        case "POST /lid/toggle", "GET /lid/toggle", "PUT /lid/toggle":
            let target = !lidMode
            setLidMode(target, interactive: false)
            body = "{\"closedLid\":\"\(target ? "on" : "off")\"}"
        case "POST /agent/on", "GET /agent/on", "PUT /agent/on":
            let id = parseAgentID(query: query)
            agentOn(id: id)
            body = "{\"agent\":\"on\",\"ids\":\(agentIDs.count)}"
        case "POST /agent/off", "GET /agent/off", "PUT /agent/off":
            let id = parseAgentID(query: query)
            agentOff(id: id)
            body = "{\"agent\":\"\(agentIDs.isEmpty ? "off" : "on")\",\"ids\":\(agentIDs.count)}"
        case "POST /agent/clear", "GET /agent/clear", "PUT /agent/clear":
            clearAgentIDs()
            body = "{\"agent\":\"off\",\"ids\":0}"
        case "POST /agent/status", "GET /agent/status", "PUT /agent/status":
            let parts = agentStatusParts()
            let listJSON = parts.list.map { "\"\($0)\"" }.joined(separator: ",")
            body = "{\"agent\":\"\(parts.on ? "on" : "off")\",\"ids\":\(parts.count)"
                 + ",\"idList\":[\(listJSON)]}"
        default:
            status = "404 Not Found"
            body = "{\"error\":\"unknown route\",\"hint\":\"GET /status | POST /on | POST /off | POST /toggle | POST /lid/on | POST /lid/off | POST /lid/toggle | POST /agent/on | POST /agent/off | POST /agent/clear | POST /agent/status\"}"
        }
        let resp = """
        HTTP/1.1 \(status)\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r
        \(body)
        """
        conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

// MARK: - Entry point

/// Scale icon onto a dark menu-bar background (preview / GIF frames).
func previewOnDarkBar(_ small: NSImage, scale: CGFloat) -> NSImage {
    let big = NSImage(size: NSSize(width: small.size.width * scale,
                                   height: small.size.height * scale))
    big.lockFocus()
    NSColor(calibratedWhite: 0.15, alpha: 1).setFill()   // approximate a dark menu bar
    NSRect(origin: .zero, size: big.size).fill()
    NSGraphicsContext.current?.imageInterpolation = .high
    small.draw(in: NSRect(origin: .zero, size: big.size))
    big.unlockFocus()
    return big
}

func previewPNGData(_ img: NSImage) -> Data? {
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}

// Offline preview: render the pill in each state to /tmp so the icon can be
// eyeballed without touching the menu bar or pmset.  Usage: AllNighter --preview
if CommandLine.arguments.contains("--preview") {
    // Envelope sanity (DESIGN.md curves) for verification tooling.
    for t in [CGFloat(0.15), 0.5, 0.9] {
        print(String(format: "envelope t=%.2f gold=%.6f black=%.6f",
                     Double(t), Double(goldIntensity(t: t)), Double(blackAlpha(t: t))))
    }

    // Existing 4 stills — agentPhase nil; must stay pixel-identical to pre-S2.
    let states: [(String, Bool, Bool)] = [
        ("off", false, false),
        ("on", true, false),
        ("on-lid", true, true),
        ("off-lid", false, true)
    ]
    for (name, on, lid) in states {
        let small = makeStatusIcon(isOn: on, lidMode: lid, agentPhase: nil, barHeight: 22)
        let big = previewOnDarkBar(small, scale: 6)
        if let png = previewPNGData(big) {
            try? png.write(to: URL(fileURLWithPath: "/tmp/allnighter-icon-\(name).png"))
            print("wrote /tmp/allnighter-icon-\(name).png")
        }
    }

    // Agent phase snapshots: user-ON and user-OFF at pinned phases.
    let phases: [(String, CGFloat)] = [
        ("00", 0.00), ("15", 0.15), ("30", 0.30),
        ("50", 0.50), ("80", 0.80), ("90", 0.90)
    ]
    for userOn in [true, false] {
        let tag = userOn ? "useron" : "useroff"
        for (label, t) in phases {
            let small = makeStatusIcon(isOn: userOn, lidMode: false, agentPhase: t, barHeight: 22)
            let big = previewOnDarkBar(small, scale: 6)
            let path = "/tmp/allnighter-agent-\(tag)-t\(label).png"
            if let png = previewPNGData(big) {
                try? png.write(to: URL(fileURLWithPath: path))
                print("wrote \(path)")
            }
        }
    }

    // Animated GIF: user-OFF, one full cycle, 20 fps, infinite loop, 6× scale.
    let gifURL = URL(fileURLWithPath: "/tmp/allnighter-agent-pulse.gif")
    let frames = 20
    if let dest = CGImageDestinationCreateWithURL(
        gifURL as CFURL, UTType.gif.identifier as CFString, frames, nil
    ) {
        let gifProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(dest, gifProps)
        for i in 0..<frames {
            let t = CGFloat(i) / CGFloat(frames)
            let img = previewOnDarkBar(
                makeStatusIcon(isOn: false, lidMode: false, agentPhase: t, barHeight: 22),
                scale: 6
            )
            guard let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let cg = rep.cgImage else { continue }
            let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]] as CFDictionary
            CGImageDestinationAddImage(dest, cg, frameProps)
        }
        if CGImageDestinationFinalize(dest) {
            print("wrote /tmp/allnighter-agent-pulse.gif")
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AllNighter()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no dock icon, no app menu
app.run()
