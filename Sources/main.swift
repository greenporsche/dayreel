import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Settings (UserDefaults-backed)

enum Prefs {
    static let d = UserDefaults.standard
    static var folder: URL? {
        get { d.string(forKey: "folder").map { URL(fileURLWithPath: $0) } }
        set { d.set(newValue?.path, forKey: "folder") }
    }
    static var quality: Int {   // percent
        get { d.object(forKey: "quality") as? Int ?? 80 }
        set { d.set(min(100, max(1, newValue)), forKey: "quality") }
    }
    static var interval: Int {  // whole seconds
        get { d.object(forKey: "interval") as? Int ?? 30 }
        set { d.set(max(1, newValue), forKey: "interval") }
    }
    static var allDisplays: Bool {
        get { d.object(forKey: "allDisplays") as? Bool ?? true }
        set { d.set(newValue, forKey: "allDisplays") }
    }
}

// MARK: - Settings window

final class SettingsWindow: NSObject {
    let window: NSWindow
    let folderLabel = NSTextField(labelWithString: "")
    let qualityField = NSTextField()
    let qualityStepper = NSStepper()
    let intervalField = NSTextField()
    let intervalStepper = NSStepper()
    let displays = NSPopUpButton()
    var onChange: () -> Void = {}

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 190),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "InstantShot Settings"
        window.isReleasedWhenClosed = false

        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        let folderRow = NSStackView(views: [folderLabel, choose]); folderRow.spacing = 8

        configure(qualityField, qualityStepper, min: 1, max: 100, action: #selector(qualityChanged))
        configure(intervalField, intervalStepper, min: 1, max: 86400, action: #selector(intervalChanged))
        let q = NSStackView(views: [qualityField, qualityStepper, NSTextField(labelWithString: "%")]); q.spacing = 6
        let i = NSStackView(views: [intervalField, intervalStepper, NSTextField(labelWithString: "seconds")]); i.spacing = 6

        displays.addItems(withTitles: ["All displays", "Primary display only"])
        displays.target = self; displays.action = #selector(displaysChanged)

        let grid = NSGridView(views: [
            [label("Save to"), folderRow],
            [label("JPEG quality"), q],
            [label("Interval"), i],
            [label("Capture"), displays],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 12; grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
    }

    func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }

    func configure(_ f: NSTextField, _ s: NSStepper, min: Double, max: Double, action: Selector) {
        f.alignment = .right
        f.widthAnchor.constraint(equalToConstant: 56).isActive = true
        f.target = self; f.action = action
        s.minValue = min; s.maxValue = max; s.increment = 1; s.valueWraps = false
        s.target = self; s.action = action
    }

    func show() {
        folderLabel.stringValue = Prefs.folder?.path ?? "Not chosen"
        qualityField.integerValue = Prefs.quality; qualityStepper.integerValue = Prefs.quality
        intervalField.integerValue = Prefs.interval; intervalStepper.integerValue = Prefs.interval
        displays.selectItem(at: Prefs.allDisplays ? 0 : 1)
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        if p.runModal() == .OK, let u = p.url { Prefs.folder = u; folderLabel.stringValue = u.path; onChange() }
    }
    @objc func qualityChanged(_ s: Any) {
        let v = (s as? NSStepper)?.integerValue ?? qualityField.integerValue
        Prefs.quality = v
        qualityField.integerValue = Prefs.quality; qualityStepper.integerValue = Prefs.quality; onChange()
    }
    @objc func intervalChanged(_ s: Any) {
        let v = (s as? NSStepper)?.integerValue ?? intervalField.integerValue
        Prefs.interval = v
        intervalField.integerValue = Prefs.interval; intervalStepper.integerValue = Prefs.interval; onChange()
    }
    @objc func displaysChanged() { Prefs.allDisplays = displays.indexOfSelectedItem == 0; onChange() }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    let toggleItem = NSMenuItem(title: "Start", action: #selector(toggle), keyEquivalent: "s")
    let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let settings = SettingsWindow()
    var timer: Timer?
    var lastSaved: Date?
    var problem: String?

    static let time: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .medium; f.dateStyle = .none; return f
    }()

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.mainMenu = NSMenu()   // lets Cmd-, work in the Settings window
        let reveal = NSMenuItem(title: "Show Folder in Finder", action: #selector(revealFolder), keyEquivalent: "")
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        let quit = NSMenuItem(title: "Quit InstantShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusLine.isEnabled = false
        [toggleItem, statusLine, .separator(), reveal, prefs, .separator(), quit].forEach { menu.addItem($0) }
        [toggleItem, reveal, prefs].forEach { $0.target = self }
        item.menu = menu
        item.button?.setAccessibilityLabel("InstantShot")
        settings.onChange = { [weak self] in self?.settingsChanged() }
        refresh()
    }

    func settingsChanged() {
        if timer != nil { schedule() }   // interval change replaces the timer; stopped stays stopped
        refresh()
    }

    func refresh() {
        let on = timer != nil
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        if on {
            let red = cfg.applying(.init(paletteColors: [.systemRed]))
            let img = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(red)
            img?.isTemplate = false
            item.button?.image = img
        } else {
            let img = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            img?.isTemplate = true
            item.button?.image = img
        }
        toggleItem.title = on ? "Stop" : "Start"

        var status: String
        if let problem { status = problem }
        else if on {
            status = "Capturing every \(Prefs.interval) s"
            if let t = lastSaved { status += " · last saved \(Self.time.string(from: t))" }
        } else { status = "Stopped" }
        statusLine.title = status
        item.button?.toolTip = "InstantShot — " + status
        item.button?.setAccessibilityValue(status)
    }

    @objc func openSettings() { settings.show() }

    @objc func revealFolder() {
        guard let f = Prefs.folder else { settings.show(); return }
        NSWorkspace.shared.activateFileViewerSelecting([f])
    }

    func chooseFolderIfNeeded() -> Bool {
        if Prefs.folder != nil { return true }
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.message = "Choose where InstantShot saves screenshots"
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        if p.runModal() == .OK { Prefs.folder = p.url }
        return Prefs.folder != nil
    }

    @objc func toggle() {
        if let t = timer { t.invalidate(); timer = nil; refresh(); return }
        guard chooseFolderIfNeeded() else { return }
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        problem = nil
        schedule()
        capture()
    }

    func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(Prefs.interval), repeats: true) { [weak self] _ in self?.capture() }
    }

    func capture() {
        // One settings snapshot per cycle.
        guard let folder = Prefs.folder else { return }
        let quality = Double(Prefs.quality) / 100.0
        let all = Prefs.allDisplays
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.current
                var displays = content.displays
                if !all {
                    let main = CGMainDisplayID()
                    displays = displays.filter { $0.displayID == main }
                }
                guard !displays.isEmpty else { throw NSError(domain: "InstantShot", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"]) }
                let now = Date()
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyMMdd"; let day = f.string(from: now)
                f.dateFormat = "HHmmss"; let time = f.string(from: now)
                let dir = folder.appendingPathComponent(day)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for (i, d) in displays.enumerated() {
                    let filter = SCContentFilter(display: d, excludingWindows: [])
                    let cfg = SCStreamConfiguration()
                    let scale = Int(filter.pointPixelScale)
                    cfg.width = Int(filter.contentRect.width) * scale
                    cfg.height = Int(filter.contentRect.height) * scale
                    cfg.showsCursor = true
                    let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                    let url = dir.appendingPathComponent(String(format: "%@-%@%03d.jpg", day, time, i + 1))
                    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                        throw NSError(domain: "InstantShot", code: 2, userInfo: [NSLocalizedDescriptionKey: "Can't write to the save folder"])
                    }
                    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                    guard CGImageDestinationFinalize(dest) else {
                        throw NSError(domain: "InstantShot", code: 3, userInfo: [NSLocalizedDescriptionKey: "Couldn't save a screenshot. Check the save folder."])
                    }
                }
                lastSaved = now; problem = nil
            } catch {
                NSLog("capture failed: \(error)")
                let denied = !CGPreflightScreenCaptureAccess()
                problem = denied ? "Needs Screen Recording access (System Settings › Privacy & Security)"
                                 : "Last capture failed: \(error.localizedDescription)"
            }
            refresh()
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
