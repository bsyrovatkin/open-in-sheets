import AppKit
import CoreServices
import ServiceManagement

// MARK: - Constants

let kBundleID = "io.github.bsyrovatkin.OpenInSheets"
let kUTIs = ["org.openxmlformats.spreadsheetml.sheet", "com.microsoft.excel.xls"]
let kRemote = "gdrive"
let kDriveFolder = "Finder Uploads"
let kDefaultsAskedLoginItem = "askedLoginItem"

let rcloneConfigPath = NSString(string: "~/.config/rclone/rclone.conf").expandingTildeInPath

// MARK: - Helpers

let logPath = NSString(string: "~/Library/Logs/OpenInSheets.log").expandingTildeInPath

func log(_ msg: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date()))  \(msg)\n"
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}

func alert(_ title: String, _ body: String, style: NSAlert.Style = .warning) {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.alertStyle = style
    a.messageText = title
    a.informativeText = body
    a.addButton(withTitle: "OK")
    a.runModal()
}

func confirm(_ title: String, _ body: String, ok: String, cancel: String) -> Bool {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.alertStyle = .informational
    a.messageText = title
    a.informativeText = body
    a.addButton(withTitle: ok)
    a.addButton(withTitle: cancel)
    return a.runModal() == .alertFirstButtonReturn
}

@discardableResult
func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 600) -> (code: Int32, out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    do { try p.run() } catch { return (-1, "", "could not launch \(launchPath): \(error.localizedDescription)") }

    // Read pipes on background queues so a large output cannot deadlock the process.
    var outData = Data(), errData = Data()
    let group = DispatchGroup()
    for (pipe, isOut) in [(outPipe, true), (errPipe, false)] {
        group.enter()
        DispatchQueue.global().async {
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            if isOut { outData = d } else { errData = d }
            group.leave()
        }
    }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(100_000) }
    if p.isRunning { p.terminate() }
    p.waitUntilExit()
    group.wait()
    return (p.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "")
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem!
    /// Handler bundle ids that were in place before we took over, restored on quit.
    var previousHandlers: [String: String] = [:]
    var busyCount = 0

    var rclonePath: String {
        Bundle.main.resourceURL!.appendingPathComponent("rclone").path
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ n: Notification) {
        let t0 = Date()
        log("launched from \(Bundle.main.bundlePath)")
        defer { log(String(format: "startup took %.2fs", Date().timeIntervalSince(t0))) }
        buildStatusItem()
        guard ensureInApplicationsFolder() else { return }
        takeOverHandlers()
        maybeAskAboutLoginItem()
        rebuildMenu()
    }

    func applicationWillTerminate(_ n: Notification) {
        restoreHandlers()
        log("terminated, handlers restored")
    }

    /// LaunchServices refuses to make an app in a temp/download location the default handler
    /// for a file type, so the app is useless until it lives in an Applications folder.
    /// Returns false if we started a relocation and this instance is about to quit.
    func ensureInApplicationsFolder() -> Bool {
        let path = Bundle.main.bundlePath
        let home = NSHomeDirectory()
        if path.hasPrefix("/Applications/") || path.hasPrefix("\(home)/Applications/") { return true }

        let dest = "\(home)/Applications/\(Bundle.main.bundleURL.lastPathComponent)"
        let move = confirm(
            "Move the app to your Applications folder?",
            "It is currently running from:\n\(path)\n\n"
            + "macOS will not let an app outside an Applications folder become a file "
            + "handler, so it cannot do anything from here.",
            ok: "Move and relaunch", cancel: "Not now")
        guard move else {
            alert("The app will not work from here",
                  "Move Open in Google Sheets into your Applications folder and launch it there.")
            return true
        }

        let fm = FileManager.default
        do {
            try? fm.createDirectory(atPath: "\(home)/Applications", withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
            try fm.copyItem(atPath: path, toPath: dest)
        } catch {
            alert("Could not move the app", "\(error.localizedDescription)\n\nMove it into Applications yourself.")
            return true
        }
        log("relocated to \(dest)")
        let cfg = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: dest), configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return false
    }

    // MARK: Status item

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(named: "menubar") {
            img.isTemplate = true
            img.size = NSSize(width: 18, height: 18)
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "GS"
        }
        statusItem.button?.toolTip = "Open in Google Sheets"
    }

    func setBusy(_ busy: Bool) {
        DispatchQueue.main.async {
            self.busyCount += busy ? 1 : -1
            if self.busyCount < 0 { self.busyCount = 0 }
            self.statusItem.button?.alphaValue = self.busyCount > 0 ? 0.35 : 1.0
            self.rebuildMenu()
        }
    }

    // MARK: Menu

    var driveConnected: Bool {
        guard let cfg = try? String(contentsOfFile: rcloneConfigPath, encoding: .utf8) else { return false }
        guard let range = cfg.range(of: "[\(kRemote)]") else { return false }
        // token must appear inside this remote's section, before the next one
        let tail = cfg[range.upperBound...]
        let section = tail.range(of: "\n[").map { String(tail[..<$0.lowerBound]) } ?? String(tail)
        return section.contains("token")
    }

    func rebuildMenu() {
        let menu = NSMenu()

        let status = busyCount > 0
            ? "Uploading to Google Drive…"
            : (driveConnected ? "Active · .xlsx and .xls open in Sheets"
                              : "Google Drive not connected")
        let head = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())

        if driveConnected {
            menu.addItem(item("Open “\(kDriveFolder)” in Drive", #selector(openDriveFolder)))
            menu.addItem(item("Reconnect Google Drive…", #selector(connectDrive)))
        } else {
            let connect = item("Connect Google Drive…", #selector(connectDrive))
            connect.attributedTitle = NSAttributedString(
                string: "Connect Google Drive…",
                attributes: [.font: NSFont.menuFont(ofSize: 0).withTrait(.boldFontMask)])
            menu.addItem(connect)
        }

        menu.addItem(.separator())
        let login = item("Launch at login", #selector(toggleLoginItem))
        login.state = loginItemEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("About Open in Google Sheets", #selector(about)))
        menu.addItem(item("Quit and restore Numbers", #selector(quit)))

        statusItem.menu = menu
    }

    func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    // MARK: Default handlers

    func takeOverHandlers() {
        for uti in kUTIs {
            let current = LSCopyDefaultRoleHandlerForContentType(uti as CFString, .editor)?
                .takeRetainedValue() as String?
            if let c = current, c.caseInsensitiveCompare(kBundleID) != .orderedSame {
                previousHandlers[uti] = c
            }
            LSSetDefaultRoleHandlerForContentType(uti as CFString, .all, kBundleID as CFString)
        }
    }

    func restoreHandlers() {
        for uti in kUTIs {
            // Only give the type back if we are still the one holding it.
            let current = LSCopyDefaultRoleHandlerForContentType(uti as CFString, .editor)?
                .takeRetainedValue() as String?
            guard current?.caseInsensitiveCompare(kBundleID) == .orderedSame else { continue }
            let restore = previousHandlers[uti] ?? "com.apple.iWork.Numbers"
            LSSetDefaultRoleHandlerForContentType(uti as CFString, .all, restore as CFString)
        }
    }

    // MARK: Login item

    var loginItemEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return FileManager.default.fileExists(atPath: legacyAgentPath)
    }

    var legacyAgentPath: String {
        NSString(string: "~/Library/LaunchAgents/\(kBundleID).plist").expandingTildeInPath
    }

    func setLoginItem(_ on: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if on { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
                return
            } catch {
                // fall through to the LaunchAgent fallback below
            }
        }
        let fm = FileManager.default
        if on {
            let plist: [String: Any] = [
                "Label": kBundleID,
                "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                "RunAtLoad": true,
            ]
            try? fm.createDirectory(atPath: (legacyAgentPath as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            (plist as NSDictionary).write(toFile: legacyAgentPath, atomically: true)
        } else {
            try? fm.removeItem(atPath: legacyAgentPath)
        }
    }

    func maybeAskAboutLoginItem() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: kDefaultsAskedLoginItem) else { return }
        d.set(true, forKey: kDefaultsAskedLoginItem)
        guard !loginItemEnabled else { return }
        let ok = confirm(
            "Launch Open in Google Sheets at login?",
            "Spreadsheets only open in Google Sheets while this app is running. "
            + "Adding it to your login items starts it for you after a restart.\n\n"
            + "You can change this at any time from the app’s menu.",
            ok: "Add to login items", cancel: "Not now")
        if ok {
            setLoginItem(true)
            if !loginItemEnabled {
                alert("Could not add it to your login items",
                      "Open System Settings → General → Login Items and add "
                      + "Open in Google Sheets there.")
            }
        }
    }

    @objc func toggleLoginItem() {
        setLoginItem(!loginItemEnabled)
        rebuildMenu()
    }

    // MARK: Drive connection

    @objc func connectDrive() {
        let exists = (try? String(contentsOfFile: rcloneConfigPath, encoding: .utf8))?
            .contains("[\(kRemote)]") ?? false
        let args = exists
            ? ["config", "reconnect", "\(kRemote):", "--auto-confirm"]
            : ["config", "create", kRemote, "drive", "scope=drive"]

        guard confirm("Connect Google Drive",
                      "A browser window will open — pick your Google account and grant access.\n\n"
                      + "This message closes now; you will get another one when the connection "
                      + "finishes. You only need to do this once.",
                      ok: "Open browser", cancel: "Cancel") else { return }

        setBusy(true)
        DispatchQueue.global().async {
            let r = run(self.rclonePath, args, timeout: 300)
            DispatchQueue.main.async {
                self.setBusy(false)
                if self.driveConnected {
                    alert("Google Drive connected", "Double-clicking an .xlsx or .xls now opens it "
                          + "as a Google Sheet.", style: .informational)
                } else {
                    alert("Could not connect Google Drive",
                          (r.err.isEmpty ? r.out : r.err).suffix(600).description)
                }
                self.rebuildMenu()
            }
        }
    }

    @objc func openDriveFolder() {
        setBusy(true)
        DispatchQueue.global().async {
            let r = run(self.rclonePath, ["lsjson", "\(kRemote):", "--dirs-only"], timeout: 60)
            var opened = false
            if let data = r.out.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let dir = arr.first(where: { ($0["Name"] as? String) == kDriveFolder }),
               let id = dir["ID"] as? String {
                NSWorkspace.shared.open(URL(string: "https://drive.google.com/drive/folders/\(id)")!)
                opened = true
            }
            if !opened { NSWorkspace.shared.open(URL(string: "https://drive.google.com/drive/my-drive")!) }
            DispatchQueue.main.async { self.setBusy(false) }
        }
    }

    // MARK: Opening files

    func application(_ sender: NSApplication, open urls: [URL]) {
        for url in urls { handle(url) }
    }

    func handle(_ url: URL) {
        log("open request: \(url.path)")
        guard driveConnected else {
            alert("Google Drive not connected",
                  "Open the Open in Google Sheets menu in the menu bar and choose "
                  + "“Connect Google Drive…”.")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            alert("File not found", url.path)
            return
        }

        setBusy(true)
        DispatchQueue.global().async {
            let tStart = Date()
            // One folder per day rather than per file: creating a fresh Drive folder costs
            // about three seconds, and that is a third of the whole round trip.
            let day = DateFormatter()
            day.dateFormat = "yyyy-MM-dd"
            let dest = "\(kRemote):\(kDriveFolder)/\(day.string(from: Date()))"

            let copy = run(self.rclonePath, [
                "copy", url.path, "\(dest)/",
                "--drive-import-formats", "xlsx,xls",
                "--ignore-times",
                "--retries", "2",
            ], timeout: 900)

            let tCopy = Date()
            log(String(format: "rclone copy: %.2fs", tCopy.timeIntervalSince(tStart)))

            guard copy.code == 0 else {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    alert("Could not upload the file to Google Drive",
                          copy.err.isEmpty ? "rclone exited with code \(copy.code)"
                                           : String(copy.err.suffix(600)))
                }
                return
            }

            let list = run(self.rclonePath, ["lsjson", dest, "--files-only"], timeout: 120)
            log(String(format: "rclone lsjson: %.2fs", Date().timeIntervalSince(tCopy)))
            // The day folder holds every upload made today, and an import strips the
            // extension, so match on the base name and take the most recent one.
            let base = url.deletingPathExtension().lastPathComponent
            var fileID: String?
            if let data = list.out.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                // rclone lists an imported Google Sheet with a virtual ".xlsx" extension,
                // so strip any extension before comparing with the local base name.
                let mine = arr.filter {
                    guard let n = $0["Name"] as? String else { return false }
                    return n == base || (n as NSString).deletingPathExtension == base
                }
                let newest = mine.max { a, b in
                    (a["ModTime"] as? String ?? "") < (b["ModTime"] as? String ?? "")
                }
                fileID = (newest ?? arr.last)?["ID"] as? String
            }

            DispatchQueue.main.async {
                self.setBusy(false)
                guard let id = fileID else {
                    alert("Uploaded, but could not build a link",
                          "Check the “\(kDriveFolder)” folder in Google Drive.")
                    return
                }
                log(String(format: "uploaded %@ -> %@ (total %.2fs)",
                           url.lastPathComponent, id, Date().timeIntervalSince(tStart)))
                NSWorkspace.shared.open(
                    URL(string: "https://docs.google.com/spreadsheets/d/\(id)/edit")!)
            }
        }
    }

    // MARK: Misc

    @objc func about() {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        alert("Open in Google Sheets \(v)",
              "While this app is running, double-clicking an .xlsx or .xls uploads it to "
              + "Google Drive (the “\(kDriveFolder)” folder), converts it to a Google Sheet "
              + "and opens it in your browser.\n\n"
              + "Quitting hands both file types back to Numbers.\n\n"
              + "Note: Drive gets a copy. Edits in the Sheet do not flow back into the "
              + "local file.",
              style: .informational)
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

extension NSFont {
    func withTrait(_ trait: NSFontTraitMask) -> NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: trait)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
