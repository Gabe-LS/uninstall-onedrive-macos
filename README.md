# uninstall-onedrive-macos

Completely remove Microsoft OneDrive and every trace it leaves on macOS.

> **Note:** tested on macOS Tahoe 26.3.1 with OneDrive 26.055.0323. Should work on macOS 12 (Monterey) and later but has not been verified.

---

## What gets removed

The script finds and removes all of the following:

- Application bundle, launch agents, launch daemons
- Sandboxed containers, application scripts, application support data
- Group containers (sync database, caches, `.noindex` files)
- WebKit data, HTTP session storage, cookies
- User preferences (both on-disk plist files and the in-memory cfprefsd cache)
- Caches, logs, saved application state
- Installer receipts
- CloudStorage sync root folders and legacy `~/OneDrive` directories
- FileProvider domain registrations and internal database
- Keychain credentials (OneDrive and SharePoint tokens)
- Finder extension registrations
- Hidden `.ODContainer` cache folders on all mounted volumes
- OneDrive-specific files inside shared Microsoft group containers (the shared container itself is preserved for other Office apps)

---

## Step 1 — Download the script

1. Click the green **Code** button at the top of this page
2. Click **Download ZIP**
3. Unzip the downloaded file
4. You'll find `uninstall_onedrive.sh` inside the folder

---

## Step 2 — Open a terminal in the script folder

1. Open the **Terminal** app — press `Command + Space`, type `Terminal`, press Enter
2. Open **Finder** and navigate to the folder containing `uninstall_onedrive.sh` — it should be in your `Downloads` folder
3. In Terminal, type `cd ` (the letters c, d, and a space — do not press Enter yet)
4. Click on the folder in Finder, then drag it into the Terminal window — the folder path will appear automatically after `cd `
5. Press Enter

---

## Step 3 — Make it executable

In the terminal you opened in Step 2, type:

```
chmod +x uninstall_onedrive.sh
```

**You only need to do this once.**

---

## Step 4 — Scan

Run the script in scan-only mode first. This shows everything the script would remove without touching anything:

```
./uninstall_onedrive.sh --SCAN
```

You'll see a categorized list of every OneDrive file, folder, preference, keychain entry, and extension found on your Mac. Review it carefully.

---

## Step 5 — Remove

If the scan looks right, run:

```
./uninstall_onedrive.sh --REMOVE
```

The script will show the same list again, then ask you to type `YES` to confirm. It uses clean, safe removal methods (rm, sudo rm, defaults delete, launchctl unload).

If everything is removed successfully, you're done.

### If something resists deletion

Some OneDrive folders (typically in `~/Library/CloudStorage`) are protected by a macOS kernel flag called `SF_DATALESS` that prevents normal deletion. If this happens, the script will tell you exactly which items failed and recommend:

```
./uninstall_onedrive.sh --REMOVE-DEEP
```

This uses aggressive methods — see "How `--REMOVE-DEEP` works" under Technical details.

---

## Something not working?

Open an issue at [github.com/Gabe-LS/uninstall-onedrive-macos/issues](https://github.com/Gabe-LS/uninstall-onedrive-macos/issues)

---

## Features

- **Scan before delete** — nothing is removed without showing you exactly what will be removed first
- **Three modes** — `--SCAN` (read-only), `--REMOVE` (safe), `--REMOVE-DEEP` (aggressive)
- **Path safety validation** — every path is checked against an allowlist of expected prefixes before deletion; unexpected paths are blocked and logged
- **No accidental collateral** — shared Microsoft containers (used by Word, Excel, Teams) are preserved; only OneDrive-specific files inside them are removed
- **Automatic escalation** — `--REMOVE` tells you if and when you need `--REMOVE-DEEP`
- **Timeout protection** — filesystem operations that hang (due to SF_DATALESS) are killed after 5 seconds so the script never gets stuck
- **Full logging** — a timestamped log file is saved next to the script after every run

---

## Technical details

<details>
<summary>Click to expand</summary>

**How it works**

The script runs in two phases:

1. **Scan** — searches ~70 hardcoded known locations and collects everything that exists on this Mac. Nothing is modified. All paths are stored in arrays grouped by category.
2. **Remove** — iterates only over the paths collected in the scan phase. No new glob expansions or path discovery happens during removal. Every path is validated against `is_safe_path()` before deletion.

Removal order matters. The script processes items in this sequence:

1. Kill OneDrive processes (so nothing holds files open)
2. Unload launch agents/daemons with `launchctl bootout` (stop auto-restart)
3. [DEEP only] Wipe FileProvider database and kill `fileproviderd`
4. Deregister Finder extensions via `pluginkit`
5. Remove app bundles
6. Remove all ~/Library data (containers, support, caches, preferences, logs, receipts)
7. Flush in-memory preferences via `defaults delete` (cfprefsd caches prefs in memory — just deleting the plist file is not enough)
8. Remove CloudStorage and legacy sync folders ([DEEP only] uses nuke sequence)
9. Remove Keychain entries ([DEEP only] includes SharePoint entries)

**How `--REMOVE-DEEP` works**

Standard removal uses `rm` and `sudo rm`. If those fail (typically on CloudStorage folders with the `SF_DATALESS` kernel flag), `--REMOVE-DEEP` adds:

- Wipes `~/Library/Application Support/FileProvider/` to deregister stale OneDrive domains from `fileproviderd`
- Kills `fileproviderd` so it restarts with a clean slate
- Then runs an escalating nuke sequence with per-operation timeouts:

| Method | Why it might work |
|--------|-------------------|
| Kill fileproviderd + strip xattrs + chflags + rm | Brief window while daemon is down |
| Wipe FileProvider DB + kill daemon + rm | Daemon loses domain association |
| mv to /tmp + rm | rename(2) doesn't enumerate directory contents, avoids SF_DATALESS lookup |
| Python shutil.rmtree | Different syscall path |
| Perl remove_tree | Different syscall path |
| find -delete | Different traversal strategy |
| Compiled C rmdir(2) | Direct syscall, bypasses shell |

If all methods fail, the script prints Recovery Mode instructions.

Additionally, `--REMOVE-DEEP` removes SharePoint keychain entries. These are shared with other Microsoft Office apps (Teams, Word, Excel), so removing them may require re-login in those apps.

**About SF_DATALESS**

When OneDrive registers as a macOS FileProvider, it sets the `SF_DATALESS` flag on cloud-backed directories. This tells the kernel to ask `fileproviderd` to materialize contents before allowing any operation that enumerates the directory (`ls`, `find`, `rm -rf`, `xattr -r`). After OneDrive is uninstalled, these operations timeout waiting for a provider that no longer exists.

`SF_DATALESS` is a synthetic, read-only kernel flag. It cannot be cleared via `chflags` even with root privileges — the kernel excludes synthetic flags from the `SF_SUPPORTED` mask. The combination that works empirically is: wipe the FileProvider database (so the daemon loses its domain association), then use `mv` (which is `rename(2)` on the same filesystem — a metadata-only operation that does not enumerate directory contents), then `rm` at the new location.

Apple does not document the FileProvider database path as a supported reset mechanism. This is based on observed behavior.

**Side effects of `--REMOVE-DEEP`**

Wiping the FileProvider database affects all cloud providers, not just OneDrive:

- iCloud re-registers its domain automatically at login
- Dropbox, Google Drive, and other providers re-register on next launch
- No cloud files are lost — only local tracking state is rebuilt

The wipe is only performed when `--REMOVE-DEEP` is explicitly requested and the user confirms.

**Files**

| File | Purpose |
|------|---------|
| `uninstall_onedrive.sh` | The script |
| `onedrive_uninstall_*.log` | Timestamped log — auto-created next to the script |

</details>

---

## License

MIT License — Copyright (c) 2026 Gabriele Lo Surdo

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
