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

final class SettingsWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let folderLabel = NSTextField(labelWithString: "")
    let pathLabel = NSTextField(labelWithString: "")
    let savedLabel = NSTextField(labelWithString: "")
    var savedGeneration = 0
    let qualityField = NSTextField()
    let qualityStepper = NSStepper()
    let intervalField = NSTextField()
    let intervalStepper = NSStepper()
    let displays = NSPopUpButton()
    var onChange: () -> Void = {}

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 380),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self

        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.font = .systemFont(ofSize: 13, weight: .medium)
        folderLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let names = NSStackView(views: [folderLabel, pathLabel]); names.orientation = .vertical
        names.alignment = .leading; names.spacing = 2
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        let folderRow = NSStackView(views: [names, choose]); folderRow.spacing = 12
        folderRow.alignment = .centerY

        configure(qualityField, qualityStepper, name: "JPEG quality, percent", min: 1, max: 100, action: #selector(qualityChanged))
        configure(intervalField, intervalStepper, name: "Capture interval, seconds", min: 1, max: 86400, action: #selector(intervalChanged))
        let q = NSStackView(views: [qualityField, qualityStepper, NSTextField(labelWithString: "%")]); q.spacing = 6
        let i = NSStackView(views: [intervalField, intervalStepper, NSTextField(labelWithString: "seconds")]); i.spacing = 6

        displays.addItems(withTitles: ["All displays", "Primary display only"])
        displays.setAccessibilityLabel("Capture displays")
        displays.target = self; displays.action = #selector(displaysChanged)

        displaysHelp = helper("")
        let blank = NSGridCell.emptyContentView
        let grid = NSGridView(views: [
            [label("Save to:"), folderRow],
            [blank, NSView()],            // 1: separator
            [label("JPEG quality:"), q],
            [blank, helper("Higher quality creates larger files.")],
            [label("Every:"), i],
            [blank, helper("How often a screenshot is saved.")],
            [blank, NSView()],            // 6: separator
            [label("Capture:"), displays],
            [blank, displaysHelp],
            [blank, NSView()],            // 9: separator
            [blank, bottomRow()],
        ])
        for r in [1, 6, 9] {
            let box = NSBox(); box.boxType = .separator
            grid.cell(atColumnIndex: 1, rowIndex: r).contentView = box
            grid.row(at: r).mergeCells(in: NSRange(location: 0, length: 2))
            grid.cell(atColumnIndex: 0, rowIndex: r).contentView = box
            grid.cell(atColumnIndex: 0, rowIndex: r).xPlacement = .fill
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10; grid.columnSpacing = 14
        for r in [1, 6, 9] { grid.row(at: r).topPadding = 8; grid.row(at: r).bottomPadding = 8 }
        for r in [2, 4] { grid.row(at: r).bottomPadding = 0 }
        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
        ])
    }

    var displaysHelp = NSTextField(labelWithString: "")

    func helper(_ text: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = .systemFont(ofSize: 11)
        t.textColor = .secondaryLabelColor
        t.preferredMaxLayoutWidth = 300
        return t
    }

    func updateDisplaysHelp() {
        displaysHelp.stringValue = Prefs.allDisplays
            ? "All screens are combined into one image."
            : "Only the main display is saved."
    }

    func bottomRow() -> NSView {
        savedLabel.font = .systemFont(ofSize: 12)
        savedLabel.textColor = .secondaryLabelColor
        savedLabel.alphaValue = 0
        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [savedLabel, spacer, done]); row.spacing = 8
        return row
    }

    @objc func done() { window.close() }

    /// Quiet confirmation that a change was stored.
    func flashSaved() {
        savedLabel.stringValue = "✓ Saved"
        savedLabel.alphaValue = 1
        savedGeneration += 1
        let g = savedGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.savedGeneration == g else { return }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.4; self.savedLabel.animator().alphaValue = 0 }
        }
    }

    func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }

    func configure(_ f: NSTextField, _ s: NSStepper, name: String, min: Double, max: Double, action: Selector) {
        (f.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true   // commit on focus loss, not only Return
        f.setAccessibilityLabel(name); s.setAccessibilityLabel(name)
        f.alignment = .right
        f.widthAnchor.constraint(equalToConstant: 56).isActive = true
        f.target = self; f.action = action
        s.minValue = min; s.maxValue = max; s.increment = 1; s.valueWraps = false
        s.target = self; s.action = action
    }

    func show() {
        showFolder()
        qualityField.integerValue = Prefs.quality; qualityStepper.integerValue = Prefs.quality
        intervalField.integerValue = Prefs.interval; intervalStepper.integerValue = Prefs.interval
        displays.selectItem(at: Prefs.allDisplays ? 0 : 1)
        updateDisplaysHelp()
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(nil)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ n: Notification) { window.makeFirstResponder(nil) }   // ends editing, commits typed value

    @objc func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        if p.runModal() == .OK, let u = p.url { Prefs.folder = u; showFolder(); onChange(); flashSaved() }
    }
    func showFolder() {
        folderLabel.stringValue = Prefs.folder?.lastPathComponent ?? "Not chosen"
        pathLabel.stringValue = Prefs.folder?.deletingLastPathComponent().path ?? ""
    }
    @objc func qualityChanged(_ s: Any) {
        let v = (s as? NSStepper)?.integerValue ?? qualityField.integerValue
        Prefs.quality = v
        qualityField.integerValue = Prefs.quality; qualityStepper.integerValue = Prefs.quality; onChange(); flashSaved()
    }
    @objc func intervalChanged(_ s: Any) {
        let v = (s as? NSStepper)?.integerValue ?? intervalField.integerValue
        Prefs.interval = v
        intervalField.integerValue = Prefs.interval; intervalStepper.integerValue = Prefs.interval; onChange(); flashSaved()
    }
    @objc func displaysChanged() { Prefs.allDisplays = displays.indexOfSelectedItem == 0; updateDisplaysHelp(); onChange(); flashSaved() }
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
        // Minimal app menu so Cmd-, and Cmd-Q work while the Settings window is key.
        let main = NSMenu(), appMenu = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)
        let s1 = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","); s1.target = self
        appMenu.addItem(s1)
        appMenu.addItem(NSMenuItem(title: "Quit InstantShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        NSApp.mainMenu = main
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
        item.button?.image = Self.indicator(recording: on)
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

    /// Same ring in both states; the inside fills red while capturing.
    static func indicator(recording: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 2.5, dy: 2.5))
            ring.lineWidth = 1.6
            NSColor.labelColor.setStroke()
            ring.stroke()
            if recording {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: r.insetBy(dx: 5.5, dy: 5.5)).fill()
            }
            return true
        }
        img.isTemplate = false   // drawn with dynamic colors so it follows light/dark
        return img
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
        problem = nil
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()   // one system prompt per Start press
            problem = "Needs Screen Recording access (System Settings › Privacy & Security). Press Start after allowing."
            refresh()
            return
        }
        schedule()
        capture()
    }

    func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(Prefs.interval), repeats: true) { [weak self] _ in self?.capture() }
    }

    /// Pure layout: canvas size in pixels and each display's pixel rect (origin bottom-left, as CGContext expects).
    static func layout(_ frames: [(frame: CGRect, scale: Int)]) -> (size: CGSize, rects: [CGRect]) {
        let union = frames.dropFirst().reduce(frames[0].frame) { $0.union($1.frame) }
        let scale = CGFloat(frames.map { $0.scale }.max() ?? 1)
        let rects = frames.map { f in
            CGRect(x: (f.frame.minX - union.minX) * scale,
                   y: (union.maxY - f.frame.maxY) * scale,
                   width: f.frame.width * scale, height: f.frame.height * scale)
        }
        return (CGSize(width: (union.width * scale).rounded(), height: (union.height * scale).rounded()), rects)
    }

    static func stitch(_ shots: [(frame: CGRect, scale: Int, image: CGImage)]) throws -> CGImage {
        let l = layout(shots.map { ($0.frame, $0.scale) })
        guard let ctx = CGContext(data: nil, width: Int(l.size.width), height: Int(l.size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw NSError(domain: "InstantShot", code: 4, userInfo: [NSLocalizedDescriptionKey: "Couldn't combine displays"])
        }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: l.size))
        ctx.interpolationQuality = .high
        for (shot, r) in zip(shots, l.rects) { ctx.draw(shot.image, in: r) }
        guard let out = ctx.makeImage() else {
            throw NSError(domain: "InstantShot", code: 4, userInfo: [NSLocalizedDescriptionKey: "Couldn't combine displays"])
        }
        return out
    }

    func capture() {
        // One settings snapshot per cycle.
        guard let folder = Prefs.folder else { return }
        // Without access, don't touch ScreenCaptureKit: every call would re-raise the system prompt.
        guard CGPreflightScreenCaptureAccess() else {
            timer?.invalidate(); timer = nil
            problem = "Needs Screen Recording access (System Settings › Privacy & Security). Press Start after allowing."
            refresh()
            return
        }
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
                var shots: [(frame: CGRect, scale: Int, image: CGImage)] = []
                for d in displays {
                    let filter = SCContentFilter(display: d, excludingWindows: [])
                    let cfg = SCStreamConfiguration()
                    let scale = Int(filter.pointPixelScale)
                    cfg.width = Int(filter.contentRect.width) * scale
                    cfg.height = Int(filter.contentRect.height) * scale
                    cfg.showsCursor = true
                    let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                    shots.append((d.frame, scale, img))
                }
                // One image per interval: several displays are stitched in their System Settings arrangement.
                let final = shots.count == 1 ? shots[0].image : try Self.stitch(shots)
                let url = dir.appendingPathComponent("\(day)-\(time).jpg")
                guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw NSError(domain: "InstantShot", code: 2, userInfo: [NSLocalizedDescriptionKey: "Can't write to the save folder"])
                }
                CGImageDestinationAddImage(dest, final, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                guard CGImageDestinationFinalize(dest) else {
                    throw NSError(domain: "InstantShot", code: 3, userInfo: [NSLocalizedDescriptionKey: "Couldn't save a screenshot. Check the save folder."])
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
