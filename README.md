# Open in Google Sheets

A macOS menu bar app. While it is running, double-clicking an `.xlsx` or `.xls` uploads the file
to Google Drive, converts it to a Google Sheet and opens it in your browser. Quit the app and
those file types go back to Numbers.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/infographic-dark.png">
  <img alt="Before: seven steps per file — export the .xlsx, double-click, Numbers opens, close Numbers, open drive.google.com, drag the file in, wait for the upload, right-click and open with Google Sheets. After: one step — double-click." src="docs/infographic-light.png">
</picture>

---

## Why

Your export lands in Downloads. A double-click hands it to Numbers — but the work happens in
Google Sheets. Numbers gives you a file to email around, not a link, comments and two people in
the same sheet. And without Excel installed there is no second option: dragging every file into
Drive by hand *is* the workflow.

This app removes steps two through seven.

**Requirements:** macOS 13+, Apple Silicon.

---

## Install

1. Download `Open in Google Sheets.zip` from [Releases](../../releases) and unpack it.
2. **Drag the app into your Applications folder.** This is required — macOS will not let an app
   in Downloads or a temp directory become a file handler. If you launch it from there, the app
   offers to relocate itself.
3. First launch: **right-click the icon → Open**. A plain double-click is blocked, because the
   app is ad-hoc signed rather than signed with an Apple Developer certificate.
4. On first launch it asks whether to add itself to your login items.
5. From the menu bar icon, choose **“Подключить Google Drive…”** (Connect Google Drive). A
   browser opens; pick your account and grant access. This is a one-time step.

If Gatekeeper still calls the app damaged, clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine "/Applications/Open in Google Sheets.app"
```

> **Note on language:** the app's own interface is in Russian. Only the documentation is in
> English. See [Interface strings](#interface-strings) for what each menu item says.

---

## Interface strings

| Menu item | Meaning |
|---|---|
| Активно · .xlsx и .xls открываются в Sheets | Active — .xlsx and .xls open in Sheets |
| Google Drive не подключён | Google Drive not connected |
| Загружаю в Google Drive… | Uploading to Google Drive… |
| Открыть папку «Finder Uploads» в Drive | Open the “Finder Uploads” folder in Drive |
| Подключить / Переподключить Google Drive… | Connect / reconnect Google Drive |
| Запускать при входе в систему | Launch at login |
| О программе | About |
| Выйти и вернуть Numbers | Quit and restore Numbers |

The menu bar icon dims while an upload is in flight.

---

## What to keep in mind

- **Drive gets a copy.** Google Sheets cannot edit a local file, so edits in the Sheet do not
  flow back into the `.xlsx` on disk.
- **Every open makes a new copy**, in a timestamped subfolder inside `Finder Uploads`. The
  folder grows; clear it out every couple of months.
- **It only works while the app is running.** That is the design.
- If you force-quit the app, it stays registered as the handler. Harmless — the next double-click
  on an `.xlsx` simply launches it again.
- To undo by hand: Finder → <kbd>Cmd</kbd>+<kbd>I</kbd> on any `.xlsx` → Open with → Numbers →
  Change All.

**Log:** `~/Library/Logs/OpenInSheets.log` records launches, quits and every upload.

---

## How it works

```
Open in Google Sheets.app/
  Contents/MacOS/OpenInSheets     Swift + AppKit, LSUIElement (no Dock icon)
  Contents/Resources/rclone       rclone (arm64), bundled — nothing to install separately
  Contents/Resources/AppIcon.icns
```

The file handler is swapped through `LSSetDefaultRoleHandlerForContentType`: on launch the app
records whoever currently owns `.xlsx` / `.xls` and installs itself; on quit it hands the types
back to whoever it recorded (Numbers by default).

Google Drive access is a plain rclone config at `~/.config/rclone/rclone.conf`, with a remote
named `gdrive`. An upload runs `rclone copy <file> gdrive:"Finder Uploads"/<timestamp>/
--drive-import-formats xlsx,xls`, then `rclone lsjson` to read the new file's ID, then opens
`docs.google.com/spreadsheets/d/<id>/edit`.

### Two things that are easy to get wrong

**LaunchServices silently ignores apps outside an Applications folder.** Setting an app in
`/private/tmp` or `~/Downloads` as the default handler returns success and changes nothing.
Hence the location check on launch — without it the app just quietly does nothing.

**AppleScript cannot find it by name.** `tell application "OpenInSheets" to quit` is ignored;
only `tell application id "io.github.bsyrovatkin.OpenInSheets" to quit` works.

---

## Building from source

```bash
./src/build.sh
```

Needs Xcode Command Line Tools (`swiftc`) and rclone at `~/bin/rclone`. The script compiles the
binary, assembles the bundle, signs it ad-hoc and registers it with LaunchServices. Icons are
regenerated separately:

```bash
python3 src/makeicons.py && iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
```

The build stages into a temp directory rather than building in place. On directories managed by
a file provider (iCloud, Dropbox) macOS attaches `com.apple.FinderInfo`, which makes `codesign`
fail with *resource fork, Finder information, or similar detritus not allowed*.

The infographic above is a standalone page — `docs/infographic.html`. Re-render it with headless
Chrome at `1600×690`:

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new \
  --force-device-scale-factor=2 --window-size=1600,690 --virtual-time-budget=9000 \
  --screenshot=docs/infographic-light.png "file://$PWD/docs/infographic.html"
```

---

A personal tool. Not affiliated with Apple or Google. Ad-hoc signed, not notarized.
