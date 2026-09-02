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
    do { try p.run() } catch { return (-1, "", "не удалось запустить \(launchPath): \(error.localizedDescription)") }

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
        log("launched from \(Bundle.main.bundlePath)")
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
            "Переместить приложение в папку «Программы»?",
            "Сейчас оно запущено из:\n\(path)\n\n"
            + "macOS не разрешает назначать обработчиком файлов приложение вне папки "
            + "«Программы», поэтому отсюда оно работать не будет.",
            ok: "Переместить и перезапустить", cancel: "Не сейчас")
        guard move else {
            alert("Приложение работать не будет",
                  "Перенеси «Open in Google Sheets» в папку «Программы» и запусти оттуда.")
            return true
        }

        let fm = FileManager.default
        do {
            try? fm.createDirectory(atPath: "\(home)/Applications", withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
            try fm.copyItem(atPath: path, toPath: dest)
        } catch {
            alert("Не удалось переместить", "\(error.localizedDescription)\n\nПеренеси приложение в «Программы» вручную.")
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
            ? "Загружаю в Google Drive…"
            : (driveConnected ? "Активно · .xlsx и .xls открываются в Sheets"
                              : "Google Drive не подключён")
        let head = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())

        if driveConnected {
            menu.addItem(item("Открыть папку «\(kDriveFolder)» в Drive", #selector(openDriveFolder)))
            menu.addItem(item("Переподключить Google Drive…", #selector(connectDrive)))
        } else {
            let connect = item("Подключить Google Drive…", #selector(connectDrive))
            connect.attributedTitle = NSAttributedString(
                string: "Подключить Google Drive…",
                attributes: [.font: NSFont.menuFont(ofSize: 0).withTrait(.boldFontMask)])
            menu.addItem(connect)
        }

        menu.addItem(.separator())
        let login = item("Запускать при входе в систему", #selector(toggleLoginItem))
        login.state = loginItemEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("О программе", #selector(about)))
        menu.addItem(item("Выйти и вернуть Numbers", #selector(quit)))

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
            "Запускать «Open in Google Sheets» при входе в систему?",
            "Таблицы открываются в Google Sheets только пока приложение запущено. "
            + "Если добавить его в автозапуск, оно будет включаться само после перезагрузки.\n\n"
            + "Это можно изменить в любой момент в меню приложения.",
            ok: "Добавить в автозапуск", cancel: "Не сейчас")
        if ok {
            setLoginItem(true)
            if !loginItemEnabled {
                alert("Не удалось добавить в автозапуск",
                      "Открой Системные настройки → Основные → Объекты входа и добавь "
                      + "«Open in Google Sheets» вручную.")
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

        guard confirm("Подключение Google Drive",
                      "Сейчас откроется браузер — выбери аккаунт Google и разреши доступ.\n\n"
                      + "Окно с этим сообщением закроется, а по итогам подключения появится "
                      + "уведомление. Это нужно сделать один раз.",
                      ok: "Открыть браузер", cancel: "Отмена") else { return }

        setBusy(true)
        DispatchQueue.global().async {
            let r = run(self.rclonePath, args, timeout: 300)
            DispatchQueue.main.async {
                self.setBusy(false)
                if self.driveConnected {
                    alert("Google Drive подключён", "Теперь двойной клик по .xlsx или .xls "
                          + "откроет файл в Google Таблицах.", style: .informational)
                } else {
                    alert("Не удалось подключить Google Drive",
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
            alert("Google Drive не подключён",
                  "Открой меню «Open in Google Sheets» в строке меню и выбери "
                  + "«Подключить Google Drive…».")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            alert("Файл не найден", url.path)
            return
        }

        setBusy(true)
        DispatchQueue.global().async {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let dest = "\(kRemote):\(kDriveFolder)/\(stamp)-\(Int.random(in: 1000...9999))"

            let copy = run(self.rclonePath, [
                "copy", url.path, "\(dest)/",
                "--drive-import-formats", "xlsx,xls",
                "--drive-chunk-size", "16M",
                "--retries", "2",
            ], timeout: 900)

            guard copy.code == 0 else {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    alert("Не удалось загрузить файл в Google Drive",
                          copy.err.isEmpty ? "rclone завершился с кодом \(copy.code)"
                                           : String(copy.err.suffix(600)))
                }
                return
            }

            let list = run(self.rclonePath, ["lsjson", dest, "--files-only"], timeout: 120)
            var fileID: String?
            if let data = list.out.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                fileID = arr.first?["ID"] as? String
            }

            DispatchQueue.main.async {
                self.setBusy(false)
                guard let id = fileID else {
                    alert("Файл загрузился, но ссылку получить не удалось",
                          "Проверь папку «\(kDriveFolder)» в Google Drive.")
                    return
                }
                log("uploaded \(url.lastPathComponent) -> \(id)")
                NSWorkspace.shared.open(
                    URL(string: "https://docs.google.com/spreadsheets/d/\(id)/edit")!)
            }
        }
    }

    // MARK: Misc

    @objc func about() {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        alert("Open in Google Sheets \(v)",
              "Пока приложение запущено, двойной клик по .xlsx и .xls заливает файл "
              + "в Google Drive (папка «\(kDriveFolder)»), конвертирует в Google Таблицу "
              + "и открывает её в браузере.\n\n"
              + "При выходе из приложения эти типы файлов возвращаются Numbers.\n\n"
              + "Внимание: в Drive создаётся копия. Правки в Таблице не попадают обратно "
              + "в локальный файл.",
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
