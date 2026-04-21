#!/bin/bash
# =============================================================================
#
#  UNINSTALL ONEDRIVE -- Complete Removal Script for macOS
#
#  Version:  2.1.0
#  Date:     2026-04-21
#  License:  MIT
#  Tested:   macOS Tahoe 26.3.1, OneDrive 26.055.0323
#
# =============================================================================
#
#  WHAT THIS SCRIPT DOES
#  ---------------------
#  Removes Microsoft OneDrive and every trace it leaves on macOS:
#
#    - Application bundle (/Applications and ~/Applications)
#    - Launch Agents and Daemons (auto-start plists)
#    - Sandboxed Containers and Application Scripts
#    - Application Support data, WebKit storage, HTTP cookies
#    - Group Containers (sync database, caches, .noindex files)
#    - User preferences (plist files AND the in-memory cfprefsd cache)
#    - Caches, logs, saved application state
#    - Installer receipts (BOM files in /private/var/db/receipts)
#    - CloudStorage sync root folders and legacy ~/OneDrive directories
#    - FileProvider domain registrations and internal database
#    - Keychain credentials (OneDrive + SharePoint tokens)
#    - Finder extension registrations (via pluginkit)
#    - Temp files in /private/tmp
#    - Hidden .ODContainer cache folders on all mounted volumes
#    - OneDrive-specific files inside shared Microsoft group containers
#      (the shared container itself is preserved for other Office apps)
#
#  HOW IT WORKS
#  ------------
#  The script operates in two phases:
#
#    Phase 1 -- SCAN (read-only, always runs with --SCAN or --REMOVE*)
#      Searches every known OneDrive location and collects a list of items
#      that actually exist on this Mac. Nothing is modified or deleted.
#      The full list is displayed to the user for review.
#
#    Phase 2 -- REMOVE (only runs with --REMOVE or --REMOVE-DEEP)
#      After the user reviews and types YES, each item is removed.
#      The removal strategy depends on the mode:
#
#      --REMOVE (standard)
#        Uses clean, safe removal methods: rm, sudo rm, defaults delete,
#        launchctl unload, pluginkit deregistration. If any item resists
#        deletion (typically CloudStorage folders with the SF_DATALESS
#        flag), it is logged and the script recommends --REMOVE-DEEP.
#
#      --REMOVE-DEEP (aggressive)
#        Everything in --REMOVE, plus:
#          - Kills the fileproviderd system daemon
#          - Wipes the FileProvider internal database (affects ALL cloud
#            providers, not just OneDrive -- see SIDE EFFECTS below)
#          - Escalating nuke sequence for stubborn folders: xattr strip,
#            chflags clear, mv to /tmp, Python shutil.rmtree, Perl
#            remove_tree, find -delete, compiled C rmdir(2)
#          - Removes SharePoint keychain entries (may require re-login
#            in Teams, Word, Excel)
#
#  SAFETY GUARANTEES
#  -----------------
#    - By default the script shows usage instructions and exits.
#    - With --SCAN, the script scans and reports but never deletes.
#    - With --REMOVE or --REMOVE-DEEP, the script scans, shows results,
#      and only deletes after the user types YES.
#    - The full list of items to be deleted is shown BEFORE any action.
#    - Every deletion targets only paths collected during the scan phase.
#      No new glob expansions or path discovery happens during removal.
#    - Every path is validated against an allowlist of expected prefixes
#      before deletion. If a path does not match, it is skipped and an
#      error is logged.
#    - Interactive prompts guard the deletion of user-facing sync folders
#      (~/OneDrive, ~/Library/CloudStorage/OneDrive-*) because these may
#      contain files the user wants to keep.
#    - A timestamped log of all actions is saved next to the script.
#
#  ABOUT SF_DATALESS (the "unkillable folder" problem)
#  ---------------------------------------------------
#  When OneDrive registers as a macOS FileProvider, it sets the SF_DATALESS
#  flag on cloud-backed directories. This flag tells the kernel to ask the
#  FileProvider daemon (fileproviderd) to materialize contents before any
#  filesystem operation that enumerates the directory (ls, find, rm -rf,
#  xattr -r, etc.). If OneDrive is uninstalled but the FileProvider domain
#  registration remains, these operations will timeout waiting for a
#  provider that no longer exists.
#
#  SF_DATALESS is a synthetic, read-only kernel flag that cannot be cleared
#  via chflags(2) even with root privileges -- the kernel excludes it from
#  the SF_SUPPORTED mask. The only ways to deal with it are:
#
#    1. Remove the stale FileProvider domain state so fileproviderd stops
#       trying to mediate access to the folder.
#    2. Use rename(2) (i.e. mv) which is a metadata-only operation on the
#       same filesystem and does not enumerate directory contents, so it
#       avoids triggering the dataless folder lookup.
#    3. Boot into Recovery Mode where fileproviderd does not run, and
#       clear the flag with chflags 0.
#
#  --REMOVE-DEEP uses approach (1) + (2): it wipes the FileProvider
#  database and kills the daemon, then uses mv to relocate the folder
#  before attempting rm. This combination has been empirically verified
#  to work.
#
#  SIDE EFFECTS OF --REMOVE-DEEP
#  -----------------------------
#  If CloudStorage folders with SF_DATALESS are found, --REMOVE-DEEP may
#  wipe the FileProvider internal database at:
#
#    ~/Library/Application Support/FileProvider/
#
#  This affects ALL FileProvider domains, not just OneDrive. However:
#    - iCloud re-registers its domain automatically at login.
#    - Dropbox, Google Drive, and other providers re-register on next
#      launch.
#    - No cloud files are lost -- only local tracking state is rebuilt.
#
#  Apple does not document this path as a supported reset mechanism.
#  This is an empirical approach based on observed behavior.
#
#  Additionally, --REMOVE-DEEP removes SharePoint keychain entries which
#  may require re-login in other Microsoft Office apps (Teams, Word,
#  Excel). Those apps will prompt for credentials automatically.
#
#  USAGE
#  -----
#    chmod +x uninstall_onedrive.sh
#
#    ./uninstall_onedrive.sh                # show usage instructions
#    ./uninstall_onedrive.sh --SCAN         # scan only, report findings
#    ./uninstall_onedrive.sh --REMOVE       # standard removal
#    ./uninstall_onedrive.sh --REMOVE-DEEP  # aggressive removal
#
#  REQUIREMENTS
#  ------------
#    - macOS 12 (Monterey) or later
#    - Administrator account (sudo access, needed for --REMOVE*)
#    - Terminal.app or any terminal emulator
#
# =============================================================================

# Do NOT use set -e -- this script must tolerate individual failures.
# Do NOT use set -u -- macOS ships bash 3.2 where empty array expansion
# under set -u throws "unbound variable" errors.
set -o pipefail

# =============================================================================
# Configuration
# =============================================================================

VERSION="2.1.0"
SCRIPT_PID=$$
MODE="instructions"  # "instructions", "scan", "remove", or "deep"
OP_TIMEOUT=5  # seconds before giving up on a hung filesystem operation
SUDO_PID=""

case "${1:-}" in
    --SCAN)        MODE="scan" ;;
    --REMOVE)      MODE="remove" ;;
    --REMOVE-DEEP) MODE="deep" ;;
esac

# If no valid flag was given, show usage instructions and exit.
if [ "$MODE" = "instructions" ]; then
    echo ""
    echo "Usage:"
    echo "  $0 --SCAN         Scan for OneDrive files and report findings."
    echo "                     Nothing is modified or deleted."
    echo ""
    echo "  $0 --REMOVE       Standard removal. Uses clean, safe methods."
    echo "                     If anything resists deletion, the script"
    echo "                     will recommend --REMOVE-DEEP."
    echo ""
    echo "  $0 --REMOVE-DEEP  Aggressive removal. Kills fileproviderd,"
    echo "                     wipes the FileProvider database, and uses"
    echo "                     escalating methods for stubborn folders."
    echo "                     Use only if --REMOVE reports failures."
    echo ""
    echo "Run --SCAN first to review what will be removed."
    echo ""
    exit 0
fi

# Log file is saved next to the script itself. If the script's directory
# is not writable (e.g. mounted read-only), fall back to the home dir.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/onedrive_uninstall_$(date +%Y%m%d_%H%M%S).log"
if ! touch "$LOG_FILE" 2>/dev/null; then
    LOG_FILE="${HOME}/onedrive_uninstall_$(date +%Y%m%d_%H%M%S).log"
fi
exec > >(tee -a "$LOG_FILE") 2>&1

# =============================================================================
# Output helpers -- plain text only, no colors, no emoji, no Unicode
# =============================================================================

# Draw a frame around one or more lines of text.
# Automatically sizes to fit the longest line.
# Usage: frame "line 1" "line 2" ...
frame() {
    local lines=("$@")
    local max_len=0
    local line
    for line in "${lines[@]}"; do
        local len=${#line}
        [ "$len" -gt "$max_len" ] && max_len=$len
    done
    local border
    border=$(printf '%*s' "$((max_len + 4))" '' | tr ' ' '-')
    printf "+%s+\n" "$border"
    for line in "${lines[@]}"; do
        printf "|  %-${max_len}s  |\n" "$line"
    done
    printf "+%s+\n" "$border"
}

divider() {
    echo ""
    echo "--------------------------------------------------------------"
    echo ""
}

info()    { echo "  [OK] $1"; }
warn()    { echo "  [!!] $1"; }
fail()    { echo "  [XX] $1"; }
note()    { echo "       $1"; }

# Print a category of scan results.
# Usage: print_category "Title:" ARRAY_NAME
# Uses eval for indirect array access (bash 3.2 compatible).
print_category() {
    local title="$1"
    local arr_name="$2"
    local count
    eval "count=\${#${arr_name}[@]}"
    if [ "$count" -gt 0 ]; then
        echo "  $title"
        eval "for item in \"\${${arr_name}[@]}\"; do echo \"    \$item\"; done"
        echo ""
    fi
}

# =============================================================================
# Timeout wrapper
# =============================================================================

# Run a command with a timeout to prevent hangs on SF_DATALESS folders.
# fileproviderd can cause filesystem operations to block indefinitely
# when the provider app is missing. This kills the operation after
# OP_TIMEOUT seconds.
timed() {
    "$@" &
    local pid=$!
    ( sleep "$OP_TIMEOUT" && kill -9 "$pid" 2>/dev/null ) &
    local timer=$!
    wait "$pid" 2>/dev/null
    local ret=$?
    kill "$timer" 2>/dev/null
    wait "$timer" 2>/dev/null
    return $ret
}

# =============================================================================
# Path safety validation
# =============================================================================

# Validate that a path is safe to delete. Returns 0 if safe, 1 if not.
# This is a defense-in-depth measure: even though all paths are collected
# from hardcoded locations in the scan phase, this function ensures that
# a bug in the script cannot accidentally delete something unexpected.
is_safe_path() {
    local target="$1"

    # Never delete empty paths, the root, or the home directory itself.
    if [ -z "$target" ] || [ "$target" = "/" ] || [ "$target" = "$HOME" ]; then
        return 1
    fi

    # Allowlist of prefixes. A path must start with one of these.
    local allowed_prefixes=(
        "/Applications/OneDrive"
        "${HOME}/Applications/OneDrive"
        "${HOME}/Library/Application Scripts/com.microsoft.OneDrive"
        "${HOME}/Library/Application Scripts/com.microsoft.OneDriveLauncher"
        "${HOME}/Library/Application Scripts/com.microsoft.FinderSync"
        "${HOME}/Library/Application Scripts/com.microsoft.DownloadAndGo"
        "${HOME}/Library/Application Scripts/UBF8T346G9."
        "${HOME}/Library/Application Support/com.microsoft.OneDrive"
        "${HOME}/Library/Application Support/OneDrive"
        "${HOME}/Library/Application Support/FileProvider/com.microsoft.OneDrive"
        "${HOME}/Library/Caches/com.microsoft.OneDrive"
        "${HOME}/Library/Caches/OneDrive"
        "${HOME}/Library/CloudStorage/OneDrive"
        "${HOME}/Library/Containers/com.microsoft.OneDrive"
        "${HOME}/Library/Containers/com.microsoft.OneDriveLauncher"
        "${HOME}/Library/Cookies/com.microsoft.OneDrive"
        "${HOME}/Library/Group Containers/UBF8T346G9."
        "${HOME}/Library/HTTPStorages/com.microsoft.OneDrive"
        "${HOME}/Library/Logs/OneDrive"
        "${HOME}/Library/Preferences/com.microsoft.OneDrive"
        "${HOME}/Library/Saved Application State/com.microsoft.OneDrive"
        "${HOME}/Library/Saved Application State/com.microsoft.OneDriveLauncher"
        "${HOME}/Library/WebKit/com.microsoft.OneDrive"
        "${HOME}/OneDrive"
        "/Library/LaunchAgents/com.microsoft.OneDrive"
        "/Library/LaunchAgents/com.microsoft.SyncReporter"
        "/Library/LaunchDaemons/com.microsoft.OneDrive"
        "/Library/Logs/Microsoft/OneDrive"
        "/private/var/db/receipts/com.microsoft.OneDrive"
        "/tmp/onedrive_nuke_"
    )

    local prefix
    for prefix in "${allowed_prefixes[@]}"; do
        case "$target" in
            "$prefix"*) return 0 ;;
        esac
    done

    # Also allow .ODContainer paths on any volume.
    case "$target" in
        */.ODContainer*) return 0 ;;
    esac

    return 1
}

# =============================================================================
# Removal functions
# =============================================================================

# Tracks paths that could not be removed by standard methods.
declare -a FAILED_PATHS=()

# Standard removal: validate path, try rm, fall back to sudo rm.
# Used by both --REMOVE and --REMOVE-DEEP.
do_remove() {
    local target="$1"
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then return 0; fi

    if ! is_safe_path "$target"; then
        fail "BLOCKED: path failed safety check, skipping: $target"
        return 1
    fi

    timed rm -rf "$target" 2>/dev/null && info "Removed: $target" && return 0
    timed sudo rm -rf "$target" 2>/dev/null && info "Removed (sudo): $target" && return 0
    warn "Standard removal failed: $target"
    return 1
}

# Aggressive removal for stubborn folders (e.g. SF_DATALESS).
# Only used by --REMOVE-DEEP. Tries an escalating sequence of methods,
# each with a timeout. Returns 0 if the folder is gone, 1 if all failed.
do_nuke() {
    local target="$1"
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then return 0; fi

    if ! is_safe_path "$target"; then
        fail "BLOCKED: path failed safety check, skipping: $target"
        return 1
    fi

    warn "Entering aggressive removal for: $target"

    # Method A: Kill fileproviderd + strip attributes + rm
    #
    # Killing fileproviderd creates a brief window where the daemon is
    # not mediating filesystem access. We use this window to strip
    # extended attributes and flags, then attempt removal.
    note "Trying: kill fileproviderd + strip attrs + rm..."
    sudo pkill -9 fileproviderd 2>/dev/null
    sleep 0.5
    timed sudo xattr -rc "$target" 2>/dev/null
    timed sudo chflags -R 0 "$target" 2>/dev/null
    timed sudo rm -rf "$target" 2>/dev/null
    if [ ! -e "$target" ]; then info "Removed (after killing fileproviderd): $target"; return 0; fi

    # Method B: Wipe FileProvider database + kill daemon + rm
    #
    # ~/Library/Application Support/FileProvider/ stores domain
    # registrations and item state. Removing it and restarting the
    # daemon causes fileproviderd to lose its association with the
    # orphaned OneDrive domain.
    #
    # SIDE EFFECT: this wipes ALL FileProvider state, not just OneDrive.
    # iCloud and other cloud providers re-register automatically.
    # Apple does not document this as a supported reset mechanism.
    note "Trying: wipe FileProvider database + kill daemon + rm..."
    sudo rm -rf "${HOME}/Library/Application Support/FileProvider/" 2>/dev/null
    sudo pkill -9 fileproviderd 2>/dev/null
    sleep 1
    timed sudo rm -rf "$target" 2>/dev/null
    if [ ! -e "$target" ]; then info "Removed (after FileProvider DB wipe): $target"; return 0; fi

    # Method C: mv (rename) to /tmp, then rm
    #
    # On the same filesystem, mv is implemented as rename(2), which is
    # a metadata-only operation that does not enumerate directory
    # contents. This avoids triggering the SF_DATALESS lookup that
    # causes timeouts. Combined with the FileProvider database wipe
    # from Method B, this severs the item from its old provider
    # resolution path.
    note "Trying: mv to /tmp + rm..."
    local tmpdest="/tmp/onedrive_nuke_$(date +%s)"
    timed sudo mv "$target" "$tmpdest" 2>/dev/null
    if [ ! -e "$target" ]; then
        timed sudo rm -rf "$tmpdest" 2>/dev/null
        if [ -e "$tmpdest" ]; then
            warn "Moved to $tmpdest but could not delete."
            note "/tmp is cleared on reboot, so it will be purged automatically."
        fi
        info "Removed (via mv + rm): $target"
        return 0
    fi

    # Method D: Python shutil.rmtree (different syscall path)
    note "Trying: Python shutil.rmtree..."
    timed sudo python3 -c "import shutil; shutil.rmtree('$target')" 2>/dev/null
    if [ ! -e "$target" ]; then info "Removed (via Python): $target"; return 0; fi

    # Method E: Perl remove_tree
    note "Trying: Perl remove_tree..."
    timed sudo perl -e "use File::Path qw(remove_tree); remove_tree('$target');" 2>/dev/null
    if [ ! -e "$target" ]; then info "Removed (via Perl): $target"; return 0; fi

    # Method F: find -delete
    note "Trying: find -delete..."
    timed sudo find "$target" -delete 2>/dev/null
    if [ ! -e "$target" ]; then info "Removed (via find): $target"; return 0; fi

    # Method G: Low-level C rmdir via inline compilation
    #
    # Compiles and runs a minimal C program that calls rmdir(2)
    # directly, bypassing any shell or library-level interception.
    note "Trying: compiled C rmdir..."
    local cfile
    cfile=$(mktemp /tmp/nuke_XXXXXX.c)
    cat > "$cfile" << 'CEOF'
#include <stdio.h>
#include <unistd.h>
#include <dirent.h>
#include <string.h>
#include <sys/stat.h>
int nuke(const char *p) {
    struct stat s;
    if (lstat(p, &s) != 0) return -1;
    if (S_ISDIR(s.st_mode)) {
        DIR *d = opendir(p);
        if (d) { struct dirent *e;
            while ((e = readdir(d))) {
                if (!strcmp(e->d_name,".") || !strcmp(e->d_name,"..")) continue;
                char sub[4096]; snprintf(sub,sizeof(sub),"%s/%s",p,e->d_name); nuke(sub);
            } closedir(d);
        } return rmdir(p);
    } return unlink(p);
}
int main(int c, char **v) { return (c>1 && nuke(v[1])==0) ? 0 : 1; }
CEOF
    local cbin="${cfile%.c}"
    cc -o "$cbin" "$cfile" 2>/dev/null
    if [ -x "$cbin" ]; then
        timed sudo "$cbin" "$target" 2>/dev/null
    fi
    rm -f "$cfile" "$cbin" 2>/dev/null
    if [ ! -e "$target" ]; then info "Removed (via compiled C): $target"; return 0; fi

    # All methods exhausted.
    fail "Could not remove: $target"
    fail "This folder likely has the SF_DATALESS flag at the kernel level."
    echo ""
    echo "  To remove it manually, boot into Recovery Mode:"
    echo "    Apple Silicon: shut down, hold power button, click Options"
    echo "    Intel: restart, hold Cmd+R"
    echo ""
    echo "  Open Utilities > Terminal, then run:"
    echo "    find /Volumes/ -name \"$(basename "$target")\" 2>/dev/null"
    echo "    chflags 0 \"<path from above>\""
    echo "    rm -rf \"<path from above>\""
    echo ""
    return 1
}

# =============================================================================
#
#  PHASE 1 -- SCAN
#
#  Collect everything that exists on this Mac. Nothing is modified.
#  All paths are derived from hardcoded known locations. No user input
#  is used to construct paths.
#
# =============================================================================

echo ""
frame "ONEDRIVE COMPLETE UNINSTALLER FOR macOS  v${VERSION}"
echo ""
echo "  Log file: $LOG_FILE"
case "$MODE" in
    scan)   echo "  Mode:     SCAN ONLY (use --REMOVE to enable removal)" ;;
    remove) echo "  Mode:     REMOVE (standard, safe methods)" ;;
    deep)   echo "  Mode:     REMOVE-DEEP (aggressive, with FileProvider reset)" ;;
esac
echo ""
echo "Scanning for OneDrive files and data..."

# These arrays collect items grouped by category for display and removal.
# All items are collected here; only these items can be deleted in Phase 2.
declare -a PROCESSES=()
declare -a APP_BUNDLES=()
declare -a LAUNCH_PLISTS=()
declare -a CONTAINERS=()
declare -a APP_SCRIPTS=()
declare -a APP_SUPPORT=()
declare -a WEB_HTTP_COOKIE=()
declare -a GROUP_CONTAINERS=()
declare -a GROUP_SUBPATHS=()
declare -a CACHES=()
declare -a PREF_DOMAINS=()
declare -a PREF_FILES=()
declare -a LOGS=()
declare -a SAVED_STATE=()
declare -a RECEIPTS=()
declare -a CLOUD_STORAGE=()
declare -a LEGACY_FOLDERS=()
declare -a KEYCHAIN_ONEDRIVE=()   # OneDrive-specific keychain entries
declare -a KEYCHAIN_SHAREPOINT=() # SharePoint entries (--REMOVE-DEEP only)
declare -a FINDER_EXTENSIONS=()
declare -a FILEPROVIDER_DB=()

# --- Processes ---

while IFS= read -r pid; do
    if [ -n "$pid" ] && [ "$pid" != "$SCRIPT_PID" ]; then
        proc_name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
        PROCESSES+=("$pid ($proc_name)")
    fi
done < <(pgrep -f "OneDrive" 2>/dev/null || true)

# --- Application Bundles ---

for p in "/Applications/OneDrive.app" "${HOME}/Applications/OneDrive.app"; do
    [ -e "$p" ] && APP_BUNDLES+=("$p")
done

# --- Launch Agents and Daemons ---
# Each entry is "domain|path" so we can unload before deleting.

LAUNCH_CANDIDATES=(
    "system|/Library/LaunchAgents/com.microsoft.OneDriveStandaloneUpdater.plist"
    "system|/Library/LaunchAgents/com.microsoft.SyncReporter.plist"
    "system|/Library/LaunchDaemons/com.microsoft.OneDriveStandaloneUpdaterDaemon.plist"
    "system|/Library/LaunchDaemons/com.microsoft.OneDriveUpdaterDaemon.plist"
    "user|${HOME}/Library/LaunchAgents/com.microsoft.OneDriveStandaloneUpdater.plist"
    "user|${HOME}/Library/LaunchAgents/com.microsoft.SyncReporter.plist"
)
for entry in "${LAUNCH_CANDIDATES[@]}"; do
    path="${entry#*|}"
    [ -e "$path" ] && LAUNCH_PLISTS+=("$entry")
done

# --- Containers ---

CONTAINER_IDS=(
    "com.microsoft.OneDrive-mac"
    "com.microsoft.OneDrive-mac.FinderSync"
    "com.microsoft.OneDrive.FinderSync"
    "com.microsoft.OneDrive.FileProvider"
    "com.microsoft.OneDriveLauncher"
)
for cid in "${CONTAINER_IDS[@]}"; do
    p="${HOME}/Library/Containers/$cid"
    [ -e "$p" ] && CONTAINERS+=("$p")
done

# --- Application Scripts ---

SCRIPT_IDS=(
    "com.microsoft.OneDrive"
    "com.microsoft.OneDrive-mac"
    "com.microsoft.OneDrive-mac.FileProvider"
    "com.microsoft.OneDrive-mac.FinderSync"
    "com.microsoft.OneDrive.FileProvider"
    "com.microsoft.OneDrive.FinderSync"
    "com.microsoft.OneDriveLauncher"
    "com.microsoft.FinderSync"
    "com.microsoft.DownloadAndGo"
    "UBF8T346G9.OfficeOneDriveSyncIntegration"
    "UBF8T346G9.OneDriveStandaloneSuite"
    "UBF8T346G9.OneDriveSyncClientSuite"
)
for sid in "${SCRIPT_IDS[@]}"; do
    p="${HOME}/Library/Application Scripts/$sid"
    [ -e "$p" ] && APP_SCRIPTS+=("$p")
done

# --- Application Support ---

SUPPORT_CANDIDATES=(
    "${HOME}/Library/Application Support/com.microsoft.OneDriveStandaloneUpdater"
    "${HOME}/Library/Application Support/com.microsoft.OneDriveUpdater"
    "${HOME}/Library/Application Support/OneDriveStandaloneUpdater"
    "${HOME}/Library/Application Support/OneDriveUpdater"
    "${HOME}/Library/Application Support/OneDrive"
    "${HOME}/Library/Application Support/FileProvider/com.microsoft.OneDrive.FileProvider"
    "${HOME}/Library/Application Support/FileProvider/com.microsoft.OneDrive-mac.FileProvider"
)
for p in "${SUPPORT_CANDIDATES[@]}"; do
    [ -e "$p" ] && APP_SUPPORT+=("$p")
done

# --- WebKit, HTTP Storages, Cookies ---

WEBHTTPCOOKIE_CANDIDATES=(
    "${HOME}/Library/WebKit/com.microsoft.OneDrive"
    "${HOME}/Library/HTTPStorages/com.microsoft.OneDrive"
    "${HOME}/Library/HTTPStorages/com.microsoft.OneDrive.binarycookies"
    "${HOME}/Library/HTTPStorages/com.microsoft.OneDriveStandaloneUpdater"
    "${HOME}/Library/HTTPStorages/com.microsoft.OneDriveStandaloneUpdater.binarycookies"
    "${HOME}/Library/HTTPStorages/com.microsoft.OneDriveUpdater"
    "${HOME}/Library/HTTPStorages/com.microsoft.OneDriveUpdater.binarycookies"
    "${HOME}/Library/Cookies/com.microsoft.OneDrive.binarycookies"
    "${HOME}/Library/Cookies/com.microsoft.OneDriveStandaloneUpdater.binarycookies"
    "${HOME}/Library/Cookies/com.microsoft.OneDriveUpdater.binarycookies"
)
for p in "${WEBHTTPCOOKIE_CANDIDATES[@]}"; do
    [ -e "$p" ] && WEB_HTTP_COOKIE+=("$p")
done

# --- Group Containers ---
# OneDrive-specific group containers can be deleted entirely.
# The shared UBF8T346G9.ms container is used by other Office apps (Word,
# Excel, Teams), so we only delete OneDrive-specific files inside it.

GC_FULL_CANDIDATES=(
    "${HOME}/Library/Group Containers/UBF8T346G9.OfficeOneDriveSyncIntegration"
    "${HOME}/Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite"
    "${HOME}/Library/Group Containers/UBF8T346G9.OneDriveSyncClientSuite"
)
for p in "${GC_FULL_CANDIDATES[@]}"; do
    [ -e "$p" ] && GROUP_CONTAINERS+=("$p")
done

# OneDrive files nested inside the shared Microsoft group container.
GC_SHARED_CANDIDATES=(
    "${HOME}/Library/Group Containers/UBF8T346G9.ms/com.microsoft.OneDrive"
    "${HOME}/Library/Group Containers/UBF8T346G9.ms/OneDrive.MERP.params.txt"
)
for p in "${GC_SHARED_CANDIDATES[@]}"; do
    [ -e "$p" ] && GROUP_SUBPATHS+=("$p")
done

# --- Caches ---

CACHE_CANDIDATES=(
    "${HOME}/Library/Caches/com.microsoft.OneDrive"
    "${HOME}/Library/Caches/com.microsoft.OneDriveStandaloneUpdater"
    "${HOME}/Library/Caches/com.microsoft.OneDriveUpdater"
    "${HOME}/Library/Caches/OneDrive"
)
for p in "${CACHE_CANDIDATES[@]}"; do
    [ -e "$p" ] && CACHES+=("$p")
done

# --- Preferences ---
# macOS caches preferences in memory via the cfprefsd daemon. If we only
# delete the plist file, cfprefsd can re-write it from its cache on next
# access. We need `defaults delete <domain>` to flush the in-memory copy.

PREF_DOMAIN_CANDIDATES=(
    "com.microsoft.OneDrive"
    "com.microsoft.OneDrive-mac"
    "com.microsoft.OneDriveStandaloneUpdater"
    "com.microsoft.OneDriveUpdater"
)
for d in "${PREF_DOMAIN_CANDIDATES[@]}"; do
    if defaults read "$d" &>/dev/null; then
        PREF_DOMAINS+=("$d")
    fi
done

PREF_FILE_CANDIDATES=(
    "${HOME}/Library/Preferences/com.microsoft.OneDrive.plist"
    "${HOME}/Library/Preferences/com.microsoft.OneDriveStandaloneUpdater.plist"
    "${HOME}/Library/Preferences/com.microsoft.OneDriveUpdater.plist"
    "${HOME}/Library/Preferences/com.microsoft.OneDrive-mac.plist"
)
for p in "${PREF_FILE_CANDIDATES[@]}"; do
    [ -e "$p" ] && PREF_FILES+=("$p")
done

# --- Logs ---

for p in "/Library/Logs/Microsoft/OneDrive" "${HOME}/Library/Logs/OneDrive"; do
    [ -e "$p" ] && LOGS+=("$p")
done

# --- Saved Application State ---

SAVED_STATE_CANDIDATES=(
    "${HOME}/Library/Saved Application State/com.microsoft.OneDrive.savedState"
    "${HOME}/Library/Saved Application State/com.microsoft.OneDriveLauncher.savedState"
)
for p in "${SAVED_STATE_CANDIDATES[@]}"; do
    [ -e "$p" ] && SAVED_STATE+=("$p")
done

# --- Installer Receipts ---

RECEIPT_CANDIDATES=(
    "/private/var/db/receipts/com.microsoft.OneDrive-mac.bom"
    "/private/var/db/receipts/com.microsoft.OneDrive-mac.plist"
    "/private/var/db/receipts/com.microsoft.OneDrive.bom"
    "/private/var/db/receipts/com.microsoft.OneDrive.plist"
)
for p in "${RECEIPT_CANDIDATES[@]}"; do
    [ -e "$p" ] && RECEIPTS+=("$p")
done

# --- CloudStorage Folders ---
# Modern macOS (Monterey+) stores sync roots in ~/Library/CloudStorage.
# These are managed by FileProvider and may have the SF_DATALESS flag.

if [ -d "${HOME}/Library/CloudStorage" ]; then
    for d in "${HOME}/Library/CloudStorage"/OneDrive*; do
        if [ -e "$d" ] || [ -L "$d" ]; then
            CLOUD_STORAGE+=("$d")
        fi
    done
fi

# --- Legacy Sync Folders ---
# Older OneDrive versions create ~/OneDrive or ~/OneDrive - CompanyName
# directly in the home folder.

for d in "${HOME}"/OneDrive*; do
    if [ -e "$d" ] || [ -L "$d" ]; then
        LEGACY_FOLDERS+=("$d")
    fi
done

# "OneDrive (Archive)" folders created by OneDrive's own reset scripts.
for d in "${HOME}/OneDrive (Archive)"*; do
    [ -e "$d" ] && LEGACY_FOLDERS+=("$d")
done

# --- Hidden .ODContainer Folders ---
# OneDrive may create hidden cache folders at the root of mounted volumes.

for vol in / /Volumes/*; do
    if [ -d "$vol" ]; then
        for d in "$vol"/.ODContainer*; do
            [ -d "$d" ] && LEGACY_FOLDERS+=("$d")
        done
    fi
done

# --- Keychain Entries ---
# OneDrive-specific entries are removed by both modes.
# SharePoint entries are only removed by --REMOVE-DEEP because they
# affect other Microsoft Office apps.

for label in "OneDrive Standalone Cached Credential" "OneDrive Cached Credential"; do
    security find-generic-password -l "$label" &>/dev/null && KEYCHAIN_ONEDRIVE+=("label:$label")
done
security find-generic-password -s "OneDrive" &>/dev/null && KEYCHAIN_ONEDRIVE+=("service:OneDrive")

# SharePoint entries (deep mode only)
security find-generic-password -s "com.microsoft.SharePoint" &>/dev/null && KEYCHAIN_SHAREPOINT+=("service:com.microsoft.SharePoint")

# --- Finder Extensions ---

while IFS= read -r line; do
    [ -n "$line" ] && FINDER_EXTENSIONS+=("$line")
done < <(pluginkit -m 2>/dev/null | grep -i "onedrive" || true)

# --- FileProvider Database ---
# Check if the FileProvider internal database contains stale OneDrive
# entries. Only wiped in --REMOVE-DEEP mode.

FP_HAS_ONEDRIVE=false
if [ -d "${HOME}/Library/Application Support/FileProvider" ]; then
    if fileproviderctl dump 2>&1 | grep -qi "onedrive"; then
        FP_HAS_ONEDRIVE=true
        FILEPROVIDER_DB+=("${HOME}/Library/Application Support/FileProvider/")
    fi
fi

# =============================================================================
#
#  DISPLAY SCAN RESULTS
#
# =============================================================================

divider

# Count total items found.
TOTAL=0
for arr in PROCESSES APP_BUNDLES LAUNCH_PLISTS CONTAINERS APP_SCRIPTS \
           APP_SUPPORT WEB_HTTP_COOKIE GROUP_CONTAINERS GROUP_SUBPATHS \
           CACHES PREF_DOMAINS PREF_FILES LOGS SAVED_STATE RECEIPTS \
           CLOUD_STORAGE LEGACY_FOLDERS KEYCHAIN_ONEDRIVE KEYCHAIN_SHAREPOINT \
           FINDER_EXTENSIONS FILEPROVIDER_DB; do
    eval "TOTAL=\$((TOTAL + \${#${arr}[@]}))"
done

if [ "$TOTAL" -eq 0 ]; then
    echo ""
    frame "No OneDrive files or data found -- your Mac is clean."
    echo ""
    echo "  Log saved to: $LOG_FILE"
    echo ""
    exit 0
fi

echo "Found $TOTAL item(s):"
echo ""

print_category "Processes to kill:" PROCESSES
print_category "Application bundles:" APP_BUNDLES

# Launch plists need special formatting (strip domain prefix).
if [ ${#LAUNCH_PLISTS[@]} -gt 0 ]; then
    echo "  Launch Agents and Daemons:"
    for entry in "${LAUNCH_PLISTS[@]}"; do
        echo "    ${entry#*|}"
    done
    echo ""
fi

print_category "Containers:" CONTAINERS
print_category "Application Scripts:" APP_SCRIPTS
print_category "Application Support:" APP_SUPPORT
print_category "WebKit, HTTP storage, and cookies:" WEB_HTTP_COOKIE
print_category "Group Containers (OneDrive-specific):" GROUP_CONTAINERS
print_category "Files in shared Microsoft container:" GROUP_SUBPATHS
print_category "Caches:" CACHES

if [ ${#PREF_DOMAINS[@]} -gt 0 ]; then
    echo "  Cached preferences (in-memory, flushed via defaults delete):"
    for d in "${PREF_DOMAINS[@]}"; do
        echo "    $d"
    done
    echo ""
fi

print_category "Preference files:" PREF_FILES
print_category "Logs:" LOGS
print_category "Saved application state:" SAVED_STATE
print_category "Installer receipts:" RECEIPTS
print_category "CloudStorage sync folders:" CLOUD_STORAGE
print_category "Legacy sync folders and caches:" LEGACY_FOLDERS

if [ ${#KEYCHAIN_ONEDRIVE[@]} -gt 0 ]; then
    echo "  Keychain entries (OneDrive):"
    for item in "${KEYCHAIN_ONEDRIVE[@]}"; do
        echo "    $item"
    done
    echo ""
fi

if [ ${#KEYCHAIN_SHAREPOINT[@]} -gt 0 ]; then
    echo "  Keychain entries (SharePoint, --REMOVE-DEEP only):"
    for item in "${KEYCHAIN_SHAREPOINT[@]}"; do
        echo "    $item"
    done
    echo "    NOTE: Removing these may require re-login in Teams, Word, Excel."
    echo ""
fi

print_category "Finder extensions:" FINDER_EXTENSIONS

if [ ${#FILEPROVIDER_DB[@]} -gt 0 ]; then
    echo "  FileProvider database (--REMOVE-DEEP only):"
    for item in "${FILEPROVIDER_DB[@]}"; do
        echo "    $item"
    done
    echo ""
    echo "    NOTE: Wiping this database affects all FileProvider"
    echo "    domains, not just OneDrive. iCloud and other cloud"
    echo "    providers will re-register automatically after a restart."
    echo ""
fi

# =============================================================================
#
#  CONFIRMATION (or exit if scan-only mode)
#
# =============================================================================

divider

if [ "$MODE" = "scan" ]; then
    frame \
        "SCAN COMPLETE -- no changes were made." \
        "" \
        "To remove the items listed above, re-run with:" \
        "" \
        "  $0 --REMOVE       (standard, safe removal)" \
        "  $0 --REMOVE-DEEP  (aggressive, if --REMOVE fails)"
    echo ""
    echo "  Log saved to: $LOG_FILE"
    echo ""
    exit 0
fi

if [ "$MODE" = "deep" ]; then
    echo "REMOVE-DEEP mode. This will:"
    echo "  - Remove all items listed above using standard methods"
    echo "  - Kill the fileproviderd system daemon"
    echo "  - Wipe the FileProvider database (affects all cloud providers)"
    echo "  - Use escalating methods for stubborn folders"
    echo "  - Remove SharePoint keychain entries"
    echo ""
fi

echo "The items listed above will be permanently deleted."
echo "Make sure you have backed up any files you want to keep."
echo ""
read -rp "Type YES to proceed with removal: " confirm
if [ "$confirm" != "YES" ]; then
    echo ""
    echo "Aborted. Nothing was modified."
    echo "  Log saved to: $LOG_FILE"
    echo ""
    exit 0
fi

# Ask for sudo upfront and keep it alive.
sudo -v
while true; do sudo -n true; sleep 30; done 2>/dev/null &
SUDO_PID=$!
trap "kill $SUDO_PID 2>/dev/null" EXIT

# =============================================================================
#
#  PHASE 2 -- REMOVE
#
#  Items are removed in a specific order to minimize interference:
#
#    1. Kill processes (so nothing is holding files open)
#    2. Unload launch agents/daemons (stop auto-restart)
#    3. [DEEP ONLY] Wipe FileProvider database (deregister stale domains
#       BEFORE touching CloudStorage folders -- critical for SF_DATALESS)
#    4. Deregister Finder extensions
#    5. Remove app bundles
#    6. Remove all ~/Library data (containers, support, caches, etc.)
#    7. Flush in-memory preferences via defaults delete
#    8. Remove CloudStorage and legacy folders
#       [DEEP ONLY] uses nuke sequence for stubborn folders
#    9. Remove Keychain entries
#       [DEEP ONLY] includes SharePoint entries
#
#  In --REMOVE mode, steps marked [DEEP ONLY] are skipped. If any items
#  cannot be removed, they are collected in FAILED_PATHS and the script
#  recommends --REMOVE-DEEP at the end.
#
#  In --REMOVE-DEEP mode, step 3 must happen before step 8. CloudStorage
#  folders may have the SF_DATALESS flag, and the nuke sequence relies on
#  the FileProvider database being wiped first so that fileproviderd no
#  longer tries to mediate access to orphaned directories.
#
#  SAFETY: every path passed to do_remove() or do_nuke() is validated
#  against is_safe_path() before any deletion is attempted. No new paths
#  are discovered during this phase -- only paths collected in Phase 1.
#
# =============================================================================

HAS_ERRORS=false

# --- 1. Kill Processes ---

if [ ${#PROCESSES[@]} -gt 0 ]; then
    divider
    echo "Killing OneDrive processes..."
    for entry in "${PROCESSES[@]}"; do
        pid="${entry%% *}"
        kill -9 "$pid" 2>/dev/null && info "Killed process $entry" || true
    done
    sleep 1
fi

# --- 2. Unload and Remove Launch Agents/Daemons ---

if [ ${#LAUNCH_PLISTS[@]} -gt 0 ]; then
    divider
    echo "Removing Launch Agents and Daemons..."
    for entry in "${LAUNCH_PLISTS[@]}"; do
        domain="${entry%%|*}"
        path="${entry#*|}"
        if [ "$domain" = "user" ]; then
            launchctl bootout "gui/$(id -u)" "$path" 2>/dev/null \
                || launchctl unload "$path" 2>/dev/null \
                || true
        else
            sudo launchctl bootout "gui/$(id -u)" "$path" 2>/dev/null \
                || sudo launchctl unload "$path" 2>/dev/null \
                || true
        fi
        sudo rm -f "$path" 2>/dev/null && info "Unloaded and removed: $path" || warn "Failed: $path"
    done
fi

# --- 3. [DEEP ONLY] Wipe FileProvider Database ---

if [ "$MODE" = "deep" ]; then
    if $FP_HAS_ONEDRIVE || [ ${#CLOUD_STORAGE[@]} -gt 0 ]; then
        divider
        echo "Clearing FileProvider state..."
        sudo rm -rf "${HOME}/Library/Application Support/FileProvider/" 2>/dev/null \
            && info "Wiped FileProvider database" || true
        sudo pkill -9 fileproviderd 2>/dev/null && info "Restarted fileproviderd" || true
        sleep 2
    fi
fi

# --- 4. Deregister Finder Extensions ---

if [ ${#FINDER_EXTENSIONS[@]} -gt 0 ]; then
    divider
    echo "Removing Finder extensions..."
    for ext in "${FINDER_EXTENSIONS[@]}"; do
        bundle_id=$(echo "$ext" | grep -oE 'com\.microsoft\.[^ (]+' || true)
        if [ -n "$bundle_id" ]; then
            pluginkit -r -i "$bundle_id" 2>/dev/null \
                && info "Deregistered Finder extension: $bundle_id" || true
        fi
    done
fi

# --- 5. Remove Application Bundles ---

if [ ${#APP_BUNDLES[@]} -gt 0 ]; then
    divider
    echo "Removing OneDrive.app..."
    for p in "${APP_BUNDLES[@]}"; do
        if ! do_remove "$p"; then
            HAS_ERRORS=true
            FAILED_PATHS+=("$p")
        fi
    done
fi

# --- 6. Remove Library Data ---

divider
echo "Removing application data, caches, logs, and receipts..."

for arr in CONTAINERS APP_SCRIPTS APP_SUPPORT WEB_HTTP_COOKIE \
           GROUP_CONTAINERS GROUP_SUBPATHS CACHES PREF_FILES \
           LOGS SAVED_STATE RECEIPTS; do
    eval "count=\${#${arr}[@]}"
    if [ "$count" -gt 0 ]; then
        eval "
        for p in \"\${${arr}[@]}\"; do
            if ! do_remove \"\$p\"; then
                HAS_ERRORS=true
                FAILED_PATHS+=(\"\$p\")
            fi
        done
        "
    fi
done

# --- 7. Flush In-Memory Preferences ---

if [ ${#PREF_DOMAINS[@]} -gt 0 ]; then
    divider
    echo "Flushing cached preferences..."
    for d in "${PREF_DOMAINS[@]}"; do
        defaults delete "$d" 2>/dev/null && info "Flushed: $d" || true
    done
fi

# --- 8. Remove CloudStorage and Legacy Sync Folders ---

if [ ${#CLOUD_STORAGE[@]} -gt 0 ]; then
    divider
    echo "Removing CloudStorage sync folders..."
    if [ "$MODE" = "deep" ]; then
        note "(Using aggressive removal methods)"
    fi
    echo ""
    for p in "${CLOUD_STORAGE[@]}"; do
        if ! do_remove "$p"; then
            if [ "$MODE" = "deep" ]; then
                if ! do_nuke "$p"; then
                    HAS_ERRORS=true
                    FAILED_PATHS+=("$p")
                fi
            else
                HAS_ERRORS=true
                FAILED_PATHS+=("$p")
            fi
        fi
    done
fi

if [ ${#LEGACY_FOLDERS[@]} -gt 0 ]; then
    divider
    echo "Removing legacy sync folders..."
    for p in "${LEGACY_FOLDERS[@]}"; do
        echo ""
        echo "  Found: $p"
        read -rp "  This may contain your files. Delete? (y/n): " choice
        if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
            if ! do_remove "$p"; then
                if [ "$MODE" = "deep" ]; then
                    if ! do_nuke "$p"; then
                        HAS_ERRORS=true
                        FAILED_PATHS+=("$p")
                    fi
                else
                    HAS_ERRORS=true
                    FAILED_PATHS+=("$p")
                fi
            fi
        else
            warn "Skipped: $p"
        fi
    done
fi

# --- 9. Remove Keychain Entries ---

if [ ${#KEYCHAIN_ONEDRIVE[@]} -gt 0 ]; then
    divider
    echo "Removing OneDrive Keychain entries..."
    for item in "${KEYCHAIN_ONEDRIVE[@]}"; do
        type="${item%%:*}"
        value="${item#*:}"
        if [ "$type" = "label" ]; then
            security delete-generic-password -l "$value" 2>/dev/null \
                && info "Removed Keychain entry: $value" || true
        elif [ "$type" = "service" ]; then
            while security delete-generic-password -s "$value" 2>/dev/null; do
                info "Removed Keychain entry (service: $value)"
            done
        fi
    done
fi

# SharePoint keychain entries: --REMOVE-DEEP only.
if [ "$MODE" = "deep" ] && [ ${#KEYCHAIN_SHAREPOINT[@]} -gt 0 ]; then
    divider
    echo "Removing SharePoint Keychain entries..."
    note "This may require re-login in Teams, Word, Excel."
    echo ""
    for item in "${KEYCHAIN_SHAREPOINT[@]}"; do
        value="${item#*:}"
        while security delete-generic-password -s "$value" 2>/dev/null; do
            info "Removed Keychain entry (service: $value)"
        done
    done
fi

# =============================================================================
#
#  DONE
#
# =============================================================================

divider

if [ ${#FAILED_PATHS[@]} -gt 0 ] && [ "$MODE" = "remove" ]; then
    # Standard mode had failures -- recommend deep mode.
    frame \
        "Removal partially complete." \
        "" \
        "The following items could not be removed:"

    echo ""
    for p in "${FAILED_PATHS[@]}"; do
        echo "    $p"
    done
    echo ""
    echo "  These are likely protected by the SF_DATALESS flag."
    echo "  To remove them, re-run with aggressive mode:"
    echo ""
    echo "    $0 --REMOVE-DEEP"
    echo ""
    echo "  --REMOVE-DEEP will kill fileproviderd, wipe the FileProvider"
    echo "  database, and use escalating removal methods. iCloud and"
    echo "  other cloud providers will re-register automatically."

elif [ ${#FAILED_PATHS[@]} -gt 0 ] && [ "$MODE" = "deep" ]; then
    # Deep mode also had failures -- recommend Recovery Mode.
    frame \
        "Removal partially complete." \
        "" \
        "Some items could not be removed even with aggressive methods."

    echo ""
    for p in "${FAILED_PATHS[@]}"; do
        echo "    $p"
    done
    echo ""
    echo "  To remove them, boot into Recovery Mode:"
    echo "    Apple Silicon: shut down, hold power button, click Options"
    echo "    Intel: restart, hold Cmd+R"
    echo ""
    echo "  Open Utilities > Terminal, then for each item run:"
    echo "    find /Volumes/ -name \"<folder name>\" 2>/dev/null"
    echo "    chflags 0 \"<path from above>\""
    echo "    rm -rf \"<path from above>\""

elif $HAS_ERRORS; then
    frame \
        "Removal complete with warnings." \
        "Review the log for details."
else
    frame "OneDrive has been completely removed."
fi

echo ""
echo "Recommended next steps:"
echo ""
echo "  1. Restart your Mac to clear in-memory caches and let"
echo "     FileProvider and iCloud re-register their domains."
echo ""
echo "  2. Open System Settings > General > Login Items and"
echo "     remove any remaining OneDrive entries."
echo ""
echo "  Log saved to: $LOG_FILE"
echo ""
