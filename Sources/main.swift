import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let folderItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let toggleItem = NSMenuItem(title: "Start", action: #selector(toggle), keyEquivalent: "s")
    var timer: Timer?
    var folder: URL? {
        didSet { UserDefaults.standard.set(folder?.path, forKey: "folder"); refresh() }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        if let p = UserDefaults.standard.string(forKey: "folder") { folder = URL(fileURLWithPath: p) }
        let choose = NSMenuItem(title: "Choose Folder…", action: #selector(chooseFolder), keyEquivalent: "o")
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        [choose, toggleItem, folderItem, .separator(), quit].forEach { menu.addItem($0) }
        [choose, toggleItem].forEach { $0.target = self }
        folderItem.isEnabled = false
        item.menu = menu
        refresh()
    }

    func refresh() {
        let on = timer != nil
        item.button?.title = on ? "● Shot" : "○ Shot"
        toggleItem.title = on ? "Stop" : "Start"
        folderItem.title = folder.map { "Folder: \($0.path)" } ?? "No folder chosen"
    }

    @objc func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        if p.runModal() == .OK { folder = p.url }
    }

    @objc func toggle() {
        if let t = timer { t.invalidate(); timer = nil; refresh(); return }
        if folder == nil { chooseFolder(); if folder == nil { return } }
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        capture()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.capture() }
        refresh()
    }

    func capture() {
        guard let folder else { return }
        Task {
            do {
                let content = try await SCShareableContent.current
                let now = Date()
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyMMdd"; let day = f.string(from: now)
                f.dateFormat = "HHmmss"; let time = f.string(from: now)
                let dir = folder.appendingPathComponent(day)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for (i, d) in content.displays.enumerated() {
                    let filter = SCContentFilter(display: d, excludingWindows: [])
                    let cfg = SCStreamConfiguration()
                    let scale = Int(filter.pointPixelScale)
                    cfg.width = Int(filter.contentRect.width) * scale
                    cfg.height = Int(filter.contentRect.height) * scale
                    cfg.showsCursor = true
                    let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                    let url = dir.appendingPathComponent(String(format: "%@-%@%03d.jpg", day, time, i + 1))
                    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
                    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                    CGImageDestinationFinalize(dest)
                }
            } catch { NSLog("capture failed: \(error)") }
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
