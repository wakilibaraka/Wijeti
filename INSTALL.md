# Installing Wijeti (beta)

Wijeti beta builds are **ad-hoc signed and not notarized by Apple**. That is a deliberate beta
choice (notarization needs a paid Apple Developer ID), and it means macOS Gatekeeper will stop
the app the first time you open it. This page shows how to install it safely and get past that.

## 1. Pick the right download

| Your Mac | Download |
| --- | --- |
| Apple Silicon (M1, M2, M3, M4…) | `Wijeti-<version>-arm64.dmg` |
| Intel | `Wijeti-<version>-x86_64.dmg` |

Not sure? Apple menu → **About This Mac**. "Chip: Apple M…" means Apple Silicon; "Processor: Intel…"
means Intel. Wijeti needs **macOS 15 (Sequoia) or later**.

## 2. Download only from the official release page

Get the file from this repository's **Releases** page
(<https://github.com/wakilibaraka/Wijeti/releases>) and from nowhere else. Because the app is not
notarized, the source and the checksum are your protection.

## 3. Verify the download (recommended, 10 seconds)

Each release has a `.sha256` file next to the DMG. In Terminal, from the folder you downloaded to:

```sh
shasum -a 256 -c Wijeti-0.1.0-beta.1-arm64.dmg.sha256
```

It must print `Wijeti-…dmg: OK`. If it does not, delete the file and download again.

## 4. Install

1. Open the DMG and drag **Wijeti** onto **Applications**.
2. Eject the DMG.

## 5. Open it the first time (getting past Gatekeeper)

Double-clicking will show *"Wijeti can't be opened because Apple cannot check it for malicious
software"* (or "is damaged"). On macOS 15 the old right-click → Open shortcut no longer works. Use
**one** of these:

**A. System Settings (no Terminal)**

1. Double-click Wijeti once and dismiss the warning with **Done**.
2. Open **System Settings → Privacy & Security** and scroll to **Security**.
3. Next to *"Wijeti" was blocked to protect your Mac*, click **Open Anyway**, then confirm with
   your password or Touch ID.

**B. Terminal (one line)**

```sh
xattr -dr com.apple.quarantine /Applications/Wijeti.app
```

This only removes the download "quarantine" flag from Wijeti. It does not turn Gatekeeper off for
anything else. You only need to do this once per install.

After that, Wijeti opens normally and lives in the menu bar.

## Updates

Wijeti checks for new versions in the background (Settings → General → Updates, or menu bar →
**Check for Updates…**). Update downloads are verified with a cryptographic signature before they
install, and they do not trigger the Gatekeeper warning again.

Because beta builds are ad-hoc signed, macOS may ask you to approve permissions (Automation,
Location, …) again after an update. That is expected until the app has a Developer ID.

## Uninstall

Quit Wijeti from the menu bar, drag it from Applications to the Trash, and optionally delete
`~/Library/Application Support/Wijeti` (your widgets and settings).

## Permissions

Wijeti asks for nothing at launch. Individual widgets may need access (Location for weather,
Automation for Music or Spotify, …). Open **Settings → Permissions** to see the status of each and
jump to the right System Settings pane. For Automation, press **Allow** next to the app you want
(for example Music): that is what makes Wijeti appear under Privacy & Security → Automation.

## Reporting a problem

Include your macOS version, chip (Apple Silicon or Intel) and the Wijeti version
(Settings → General → Updates). Logs, with your home folder already shortened to `~`:

```sh
log show --last 30m --predicate 'process == "WijetiApp"' --style compact > ~/Desktop/wijeti-log.txt
```
