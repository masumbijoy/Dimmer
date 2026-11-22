// Dimmer — a menu-bar brightness control for an external monitor.
// Changes the monitor's real backlight over DDC/CI using `m1ddc` (brew install m1ddc).
// The LG 27UP85 accepts DDC writes but never answers reads, so Dimmer remembers the
// last value itself.
//
// Control from anywhere (Shortcuts, Control Center "Run Shortcut", Terminal):
//   open dimmer://up      open dimmer://down      open dimmer://set/50
import Cocoa

final class Dimmer: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var slider: NSSlider!
    private var valueLabel: NSTextField!
    private var presetItems: [NSMenuItem] = []
    private let step = 5
    private let queue = DispatchQueue(label: "dimmer.ddc")   // one m1ddc call at a time
    private var pending: Int?
    private var sending = false

    private let m1ddc: String? = ["/opt/homebrew/bin/m1ddc", "/usr/local/bin/m1ddc"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private var level: Int {
        get { UserDefaults.standard.object(forKey: "brightness") as? Int ?? 70 }
        set { UserDefaults.standard.set(newValue, forKey: "brightness") }
    }

    // MARK: launch

    func applicationWillFinishLaunching(_ note: Notification) {
        // Register for dimmer:// links before launch finishes, so a link that starts the app is handled.
        NSAppleEventManager.shared().setEventHandler(self,
            andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = buildMenu()
        // Started at login → respect "hidden". Opened by hand → always show the icon (the fallback).
        if !CommandLine.arguments.contains("--login") { iconHidden = false }
        if loginEnabled { writeAgent() }   // keep the login item's arguments up to date
        statusItem.isVisible = !iconHidden
        refreshUI()

        if m1ddc == nil {
            let a = NSAlert()
            a.messageText = "m1ddc not found"
            a.informativeText = "Dimmer needs m1ddc to talk to the monitor.\nInstall it with:  brew install m1ddc"
            a.runModal()
        }

        // ⌃⌥↑ / ⌃⌥↓
        let handler: (NSEvent) -> Void = { [weak self] e in self?.handleShortcut(e) }
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { handler($0); return $0 }

        // ☀︎ brightness keys — needs Accessibility permission.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        installKeyTap()
    }

    // MARK: menu

    private func symbol(_ name: String, _ size: CGFloat = 13) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        return img?.withSymbolConfiguration(.init(pointSize: size, weight: .regular))
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.minimumWidth = 260

        // Header + slider, laid out to line up with the menu items' text below.
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 62))
        box.autoresizingMask = [.width]

        let title = NSTextField(labelWithString: "LG Brightness")
        title.font = .boldSystemFont(ofSize: 13)
        valueLabel = NSTextField(labelWithString: "")
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right

        let lo = NSImageView(image: symbol("sun.min", 12)!)
        let hi = NSImageView(image: symbol("sun.max", 14)!)
        [lo, hi].forEach { $0.contentTintColor = .secondaryLabelColor }

        slider = NSSlider(value: Double(level), minValue: 0, maxValue: 100,
                          target: self, action: #selector(sliderMoved))
        slider.isContinuous = true
        slider.controlSize = .small

        for v in [title, valueLabel, lo, hi, slider] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(v)
        }
        let inset: CGFloat = 14
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: inset),
            title.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -inset),
            valueLabel.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),

            lo.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: inset),
            lo.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            hi.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -inset),
            hi.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: lo.trailingAnchor, constant: 8),
            slider.trailingAnchor.constraint(equalTo: hi.leadingAnchor, constant: -8),
            slider.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
        ])
        let sliderItem = NSMenuItem(); sliderItem.view = box
        menu.addItem(sliderItem)
        menu.addItem(.separator())

        let presets: [(Int, String)] = [(100, "sun.max.fill"), (75, "sun.max"),
                                        (50, "sun.min.fill"), (25, "sun.min"), (0, "moon")]
        for (pct, icon) in presets {
            let m = NSMenuItem(title: "\(pct)%", action: #selector(preset(_:)), keyEquivalent: "")
            m.tag = pct; m.target = self; m.image = symbol(icon)
            presetItems.append(m); menu.addItem(m)
        }
        menu.addItem(.separator())

        let keys = NSMenuItem(title: "☀︎ keys  or  ⌃⌥↑ ↓", action: nil, keyEquivalent: "")
        keys.image = symbol("keyboard"); keys.isEnabled = false
        menu.addItem(keys)

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self; login.image = symbol("power")
        login.state = loginEnabled ? .on : .off
        menu.addItem(login)

        let hide = NSMenuItem(title: "Hide Menu Bar Icon", action: #selector(hideIcon), keyEquivalent: "")
        hide.target = self; hide.image = symbol("eye.slash")
        menu.addItem(hide)

        let quit = NSMenuItem(title: "Quit Dimmer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = symbol("xmark.circle")
        menu.addItem(quit)
        return menu
    }

    private func refreshUI() {
        slider?.doubleValue = Double(level)
        valueLabel?.stringValue = "\(level)%"
        for m in presetItems { m.state = (m.tag == level) ? .on : .off }
        let name = level == 0 ? "moon" : level < 50 ? "sun.min" : "sun.max"
        statusItem?.button?.image = symbol(name, 14)
        statusItem?.button?.toolTip = "LG Brightness \(level)%"
    }

    // MARK: hide / show the menu-bar icon
    // Hidden icon comes back by opening Dimmer again (Spotlight / Applications) or `open dimmer://show`.

    private var iconHidden: Bool {
        get { UserDefaults.standard.bool(forKey: "iconHidden") }
        set { UserDefaults.standard.set(newValue, forKey: "iconHidden") }
    }

    @objc private func hideIcon() {
        let a = NSAlert()
        a.messageText = "Hide the menu bar icon?"
        a.informativeText = "Brightness keys, shortcuts and Control Center keep working, and it stays hidden after restarts.\n\nTo show the icon again, open Dimmer from Spotlight or Applications."
        a.addButton(withTitle: "Hide")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        iconHidden = true
        statusItem.isVisible = false
    }

    private func showIcon() {
        iconHidden = false
        statusItem.isVisible = true
    }

    // Opening Dimmer while it is already running brings the icon back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showIcon(); return false
    }

    @objc private func sliderMoved() { set(Int(slider.doubleValue.rounded())) }
    @objc private func preset(_ s: NSMenuItem) { set(s.tag) }

    // MARK: input

    private func handleShortcut(_ e: NSEvent) {
        let mods = e.modifierFlags.intersection([.control, .option, .command, .shift])
        guard mods == [.control, .option] else { return }
        if e.keyCode == 126 { set(level + step) }       // ↑
        else if e.keyCode == 125 { set(level - step) }  // ↓
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: s) else { return }
        let parts = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).map { $0.lowercased() }
        switch parts.first {
        case "up":   set(level + step)
        case "down": set(level - step)
        case "set":  if parts.count > 1, let v = Int(parts[1]) { set(v) }
        case "show": showIcon()
        case "hide": iconHidden = true; statusItem.isVisible = false
        default: break
        }
    }

    private var tap: CFMachPort?

    private func installKeyTap() {
        let mask = CGEventMask(1 << 14)                                     // NX_SYSDEFINED (media keys)
                 | CGEventMask(1 << CGEventType.keyDown.rawValue)
                 | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                options: .defaultTap, eventsOfInterest: mask,
                                callback: { _, type, event, ctx in
            Unmanaged<Dimmer>.fromOpaque(ctx!).takeUnretainedValue().handleTap(type: type, event: event)
        }, userInfo: me)
        guard let tap else {
            // No Accessibility permission yet — try again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.installKeyTap() }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Built-in keyboard: media-key event, subtype 8, key 2 = brightness up, 3 = down.
        if type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 {
            let key = (ns.data1 & 0xFFFF0000) >> 16
            let down = ((ns.data1 & 0xFF00) >> 8) == 0xA
            if key == 2 || key == 3 {
                if down { DispatchQueue.main.async { self.set(self.level + (key == 2 ? self.step : -self.step)) } }
                return nil
            }
        }
        // Some keyboards send brightness as key codes 144 (up) / 145 (down).
        if type == .keyDown || type == .keyUp {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == 144 || code == 145 {
                if type == .keyDown {
                    DispatchQueue.main.async { self.set(self.level + (code == 144 ? self.step : -self.step)) }
                }
                return nil
            }
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: brightness

    private func set(_ v: Int) {
        level = min(100, max(0, v))
        refreshUI()
        send(level)
    }

    // Coalesce rapid changes: only the newest value is sent once the previous call finishes.
    private func send(_ v: Int) {
        queue.async {
            self.pending = v
            guard !self.sending else { return }
            self.sending = true
            while let next = self.pending {
                self.pending = nil
                self.run(["set", "luminance", String(next)])
            }
            self.sending = false
        }
    }

    private func run(_ args: [String]) {
        guard let path = m1ddc else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: login item (LaunchAgent)

    private var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/local.dimmer.plist")
    }
    private var loginEnabled: Bool { FileManager.default.fileExists(atPath: agentURL.path) }
    @objc private func toggleLogin(_ item: NSMenuItem) {
        if loginEnabled {
            try? FileManager.default.removeItem(at: agentURL)
        } else {
            writeAgent()
        }
        item.state = loginEnabled ? .on : .off
    }

    private func writeAgent() {
        let plist: [String: Any] = ["Label": "local.dimmer",
            "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath, "--args", "--login"],
            "RunAtLoad": true]
        try? FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        (plist as NSDictionary).write(to: agentURL, atomically: true)
    }
}

let app = NSApplication.shared
let delegate = Dimmer()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
