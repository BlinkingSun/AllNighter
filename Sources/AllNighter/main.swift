import Cocoa
import Network

let kPort: NWEndpoint.Port = 17893
let kLidDefaultsKey = "closedLidMode"
let kSudoersPath = "/etc/sudoers.d/allnighter-pmset"

// MARK: - Status-bar icon rendering (shared by the app and the --preview mode)

/// Draws the on/off pill. `isOn` colours it green vs gray; when `lidMode` is true
/// a glowing yellow ring is drawn around the pill (closed-lid keep-alive active).
func makeStatusIcon(isOn: Bool, lidMode: Bool, barHeight: CGFloat) -> NSImage {
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

    // Pill background
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

    // Glowing yellow ring — shown whenever closed-lid keep-alive is enabled.
    if lidMode {
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

final class AllNighter: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var caffeinate: Process?
    private var listener: NWListener?
    private(set) var isOn = false            // display keep-awake (caffeinate -d -i)
    private(set) var lidMode = false         // closed-lid keep-alive (pmset disablesleep)
    private var lidBusy = false              // guards against overlapping privileged calls
    private let lidQueue = DispatchQueue(label: "com.allnighter.mac.lid")
    private var sigSources: [DispatchSourceSignal] = []

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

    // MARK: - Display keep-awake (caffeinate)

    func setState(_ on: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if on == self.isOn { return }
            self.isOn = on
            if on {
                let p = Process()
                p.launchPath = "/usr/bin/caffeinate"
                p.arguments = ["-d", "-i"]
                do {
                    try p.run()
                    self.caffeinate = p
                } catch {
                    NSLog("Failed to launch caffeinate: \(error)")
                    self.isOn = false
                }
            } else {
                self.caffeinate?.terminate()
                self.caffeinate = nil
            }
            self.refreshIcon()
        }
    }

    // MARK: - Closed-lid keep-alive (pmset disablesleep, root)

    /// Toggle closed-lid mode. Runs the privileged work off the main thread.
    /// `interactive` controls whether a failure to gain privilege shows an alert.
    func setLidMode(_ on: Bool, interactive: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.lidBusy { return }
            if on == self.lidMode { return }
            self.lidBusy = true
            self.refreshIcon()      // reflect the "…busy" state in the menu next open

            self.lidQueue.async {
                var ok = false
                if on {
                    ok = self.sudoSet(1)                 // silent path (rule already present)
                    if !ok, self.installSudoersRule() {  // one-time admin prompt
                        ok = self.sudoSet(1)
                    }
                } else {
                    _ = self.sudoSet(0)                  // best-effort revert
                    ok = true                            // turning off always succeeds in the UI
                }

                DispatchQueue.main.async {
                    self.lidBusy = false
                    if on {
                        if ok {
                            self.lidMode = true
                            UserDefaults.standard.set(true, forKey: kLidDefaultsKey)
                        } else if interactive {
                            self.showLidError()
                        }
                    } else {
                        self.lidMode = false
                        UserDefaults.standard.set(false, forKey: kLidDefaultsKey)
                    }
                    self.refreshIcon()
                }
            }
        }
    }

    /// Re-establish the persisted closed-lid state at launch, without ever prompting.
    /// Also clears any stale `disablesleep` left behind by a hard crash.
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
        button.image = makeStatusIcon(isOn: isOn,
                                      lidMode: lidMode,
                                      barHeight: NSStatusBar.system.thickness)
        button.toolTip = "AllNighter — display: \(isOn ? "ON" : "OFF"), "
                       + "closed-lid: \(lidMode ? "ON" : "OFF")"
    }

    // MARK: - Clean-up on exit (never leave the Mac unable to sleep)

    func applicationWillTerminate(_ notification: Notification) {
        if lidMode { _ = sudoSet(0) }
        caffeinate?.terminate()
    }

    private func installSignalHandlers() {
        for s in [SIGTERM, SIGINT] {
            signal(s, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: s, queue: .main)
            src.setEventHandler { [weak self] in
                if self?.lidMode == true { _ = self?.sudoSet(0) }
                self?.caffeinate?.terminate()
                exit(0)
            }
            src.resume()
            sigSources.append(src)
        }
    }

    // MARK: - HTTP server

    private func startServer() {
        do {
            let params = NWParameters.tcp
            params.acceptLocalOnly = true
            listener = try NWListener(using: params, on: kPort)
        } catch {
            NSLog("HTTP listener failed to bind on \(kPort): \(error)")
            return
        }
        listener?.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener?.start(queue: .main)
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
            let path = parts.count > 1 ? parts[1] : "/"
            self.respond(conn, method: method, path: path)
        }
    }

    private func respond(_ conn: NWConnection, method: String, path: String) {
        var body = ""
        var status = "200 OK"
        let route = "\(method) \(path)"
        switch route {
        case "GET /status", "GET /":
            body = "{\"state\":\"\(isOn ? "on" : "off")\",\"closedLid\":\"\(lidMode ? "on" : "off")\"}"
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
        default:
            status = "404 Not Found"
            body = "{\"error\":\"unknown route\",\"hint\":\"GET /status | POST /on | POST /off | POST /toggle | POST /lid/on | POST /lid/off | POST /lid/toggle\"}"
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

// Offline preview: render the pill in each state to /tmp so the icon can be
// eyeballed without touching the menu bar or pmset.  Usage: AllNighter --preview
if CommandLine.arguments.contains("--preview") {
    let states: [(String, Bool, Bool)] = [
        ("off", false, false),
        ("on", true, false),
        ("on-lid", true, true),
        ("off-lid", false, true)
    ]
    for (name, on, lid) in states {
        let small = makeStatusIcon(isOn: on, lidMode: lid, barHeight: 22)
        let scale: CGFloat = 6
        let big = NSImage(size: NSSize(width: small.size.width * scale,
                                       height: small.size.height * scale))
        big.lockFocus()
        NSColor(calibratedWhite: 0.15, alpha: 1).setFill()   // approximate a dark menu bar
        NSRect(origin: .zero, size: big.size).fill()
        NSGraphicsContext.current?.imageInterpolation = .high
        small.draw(in: NSRect(origin: .zero, size: big.size))
        big.unlockFocus()
        if let tiff = big.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "/tmp/allnighter-icon-\(name).png"))
            print("wrote /tmp/allnighter-icon-\(name).png")
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AllNighter()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no dock icon, no app menu
app.run()
