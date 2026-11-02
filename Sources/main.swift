import AppKit
import SwiftUI
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

// MARK: - Settings window (SwiftUI grouped Form, the System Settings look)

final class SettingsModel: ObservableObject {
    @Published var folder: URL? = Prefs.folder
    @Published var quality: Double = Double(Prefs.quality)
    @Published var interval: Int = Prefs.interval
    @Published var allDisplays: Bool = Prefs.allDisplays
    @Published var showSaved = false
    var onChange: () -> Void = {}
    private var savedToken = 0

    func reload() {
        folder = Prefs.folder; quality = Double(Prefs.quality)
        interval = Prefs.interval; allDisplays = Prefs.allDisplays
    }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        if p.runModal() == .OK, let u = p.url { Prefs.folder = u; folder = u; changed() }
    }

    /// Called after any value was stored: apply live and flash "Saved".
    func changed() {
        onChange()
        savedToken += 1
        let t = savedToken
        withAnimation(.easeOut(duration: 0.15)) { showSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.savedToken == t else { return }
            withAnimation(.easeOut(duration: 0.4)) { self.showSaved = false }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var m: SettingsModel
    static let intervals: [(Int, String)] = [
        (5, "5 seconds"), (10, "10 seconds"), (30, "30 seconds"), (60, "1 minute"),
        (120, "2 minutes"), (300, "5 minutes"), (600, "10 minutes"), (1800, "30 minutes"), (3600, "1 hour"),
    ]
    var options: [(Int, String)] {
        Self.intervals.contains { $0.0 == m.interval } ? Self.intervals : Self.intervals + [(m.interval, "\(m.interval) seconds")]
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Save to") {
                    HStack(spacing: 10) {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(m.folder?.lastPathComponent ?? "Not chosen").foregroundStyle(.primary)
                            if let parent = m.folder?.deletingLastPathComponent().path {
                                Text(parent).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Button("Choose…") { m.chooseFolder() }
                    }
                }
            }
            Section {
                LabeledContent("JPEG quality") {
                    HStack(spacing: 10) {
                        Slider(value: $m.quality, in: 10...100, step: 5) { Text("JPEG quality") }
                            .labelsHidden().frame(width: 170)
                        Text("\(Int(m.quality))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                Picker("Every", selection: $m.interval) {
                    ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
                }
            } footer: {
                Text("Higher quality creates larger files.")
            }
            Section {
                Picker("Capture", selection: $m.allDisplays) {
                    Text("All displays").tag(true)
                    Text("Primary display only").tag(false)
                }
            } footer: {
                Text(m.allDisplays ? "All screens are combined into one image." : "Only the main display is saved.")
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Text("✓ Saved").font(.callout).foregroundStyle(.secondary)
                .opacity(m.showSaved ? 1 : 0)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 20).padding(.bottom, 10)
                .accessibilityHidden(!m.showSaved)
        }
        .onChange(of: m.quality) { _, v in Prefs.quality = Int(v); m.changed() }
        .onChange(of: m.interval) { _, v in Prefs.interval = v; m.changed() }
        .onChange(of: m.allDisplays) { _, v in Prefs.allDisplays = v; m.changed() }
    }
}

final class SettingsWindow: NSObject {
    let model = SettingsModel()
    let window: NSWindow
    var onChange: () -> Void {
        get { model.onChange }
        set { model.onChange = newValue }
    }

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsView(m: model))
        window.setContentSize(NSSize(width: 480, height: 360))
    }

    func show() {
        model.reload()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    let toggleItem = NSMenuItem(title: "Start Capture", action: #selector(toggle), keyEquivalent: "s")
    let revealItem = NSMenuItem(title: "Show in Finder", action: #selector(revealFolder), keyEquivalent: "")
    let settings = SettingsWindow()
    var timer: Timer?
    var lastSaved: Date?
    var problem: String?

    static let time: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .medium; f.dateStyle = .none; return f
    }()
    static let shortTime: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()

    /// Native menu-item subtitle (macOS 14.4+); older systems rely on the status-item tooltip.
    static func setSubtitle(_ item: NSMenuItem, _ text: String?) {
        if #available(macOS 14.4, *) { item.subtitle = text }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // Minimal app menu so Cmd-, and Cmd-Q work while the Settings window is key.
        let main = NSMenu(), appMenu = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)
        let s1 = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","); s1.target = self
        appMenu.addItem(s1)
        appMenu.addItem(NSMenuItem(title: "Quit InstantShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        NSApp.mainMenu = main
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        let quit = NSMenuItem(title: "Quit InstantShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        [toggleItem, .separator(), revealItem, prefs, .separator(), quit].forEach { menu.addItem($0) }
        [toggleItem, revealItem, prefs].forEach { $0.target = self }
        item.menu = menu
        item.button?.setAccessibilityLabel("InstantShot")
        settings.onChange = { [weak self] in self?.settingsChanged() }
        refresh()
    }

    func settingsChanged() {
        // Only an interval change replaces the timer; quality/folder/display edits leave the clock running.
        if let t = timer, t.timeInterval != TimeInterval(Prefs.interval) { schedule() }   // stopped stays stopped
        refresh()
    }

    func refresh() {
        let on = timer != nil
        item.button?.image = Self.indicator(recording: on)
        toggleItem.title = on ? "Stop Capture" : "Start Capture"

        // Short context lives as a subtitle on the action it belongs to; the tooltip carries the full detail.
        var detail: String
        var captureNote: String? = nil
        if let problem {
            detail = problem
            captureNote = problem.hasPrefix("Needs Screen Recording") ? "Needs Screen Recording access" : "Last capture failed"
        } else if on {
            detail = "Capturing every \(Prefs.interval) s"
            if let t = lastSaved {
                detail += " · last saved \(Self.time.string(from: t))"
                captureNote = "Last saved \(Self.shortTime.string(from: t))"
            }
        } else { detail = "Stopped" }
        Self.setSubtitle(toggleItem, captureNote)
        Self.setSubtitle(revealItem, Prefs.folder?.lastPathComponent)
        item.button?.toolTip = "InstantShot — " + detail
        item.button?.setAccessibilityValue(detail)
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
