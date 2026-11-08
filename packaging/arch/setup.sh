#!/usr/bin/env bash
# Fingerprint reader setup for this fork (made for the ThinkPad X1 Yoga 3rd gen, Synaptics 06cb:009a).
#
#   ~/src/python-validity/packaging/arch/setup.sh
#
# Run as your normal user; it asks for your sudo password when it needs it. Safe to re-run:
# after editing the driver, run it again to rebuild, reinstall and restart.
#   1. installs open-fprintd + fprintd-clients from the AUR (if missing)
#   2. builds this checkout into the python-validity-reedg package and installs it with pacman
#   3. downloads the reader's firmware from Lenovo (only until it's on the reader)
#   4. enables and (re)starts the services; offers a factory reset of the reader if it won't start
#   5. enrolls your right index finger (if none is enrolled yet)
#   6. offers fingerprint for sudo (your password keeps working)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG=python-validity-reedg

say()  { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[31m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }
ask()  { local a; read -rp "    $1 [y/N] " a; [[ ${a,,} == y* ]]; }
indent() { sed 's/^/    /'; }

[[ $EUID -ne 0 ]] || die "run this as your normal user, not with sudo (it asks for sudo itself)."
command -v yay >/dev/null || die "yay is needed for the two AUR packages."

# fprintd-list prints one of these once the reader is up (and "No devices available" until then).
# (Output is captured first: with pipefail, `fprintd-list | grep -q` can fail on SIGPIPE.)
fingers() { fprintd-list "$USER" 2>&1 || true; }
reader_up() { grep -qE 'Fingerprints for user|has no fingers enrolled' <<<"$(fingers)"; }
wait_for_reader() {
    for _ in $(seq 20); do reader_up && return 0; sleep 1; done
    return 1
}
# Private backup of Lenovo's driver download, in case Lenovo ever removes it (it's only needed again
# after a factory reset, but without it a reset would leave the reader dead). Never put it in git:
# it's Lenovo's file. validity-sensors-firmware checks its SHA-512 either way.
FW_BACKUP_DIR="$HOME/.local/share/python-validity-firmware"
fw_info() {   # prints "<url> <sha512>" for the reader in this machine, from the driver's own table
    (cd "$HERE/../.." && PYTHONDONTWRITEBYTECODE=1 python3 -c '
import sys; sys.path.insert(0, ".")
import usb.core
from validitysensor.usb import SupportedDevices
from validitysensor.firmware_tables import FIRMWARE_URIS
for d in SupportedDevices:
    if usb.core.find(idVendor=d.value[0], idProduct=d.value[1]):
        print(FIRMWARE_URIS[d]["driver"], FIRMWARE_URIS[d]["sha512"]); break')
}
fw_backup_file() {   # prints the backup's path if it exists and matches the expected SHA-512
    local url sha f
    read -r url sha < <(fw_info) || return 1
    f="$FW_BACKUP_DIR/$(basename "$url")"
    [[ -f $f ]] && [[ $(sha512sum "$f" | cut -d' ' -f1) == "$sha" ]] && echo "$f"
}
ensure_fw_backup() {
    local url sha f
    if f=$(fw_backup_file); then ok "firmware backup present ($f)"; return; fi
    read -r url sha < <(fw_info) || { warn "couldn't identify the reader, so no firmware backup"; return; }
    f="$FW_BACKUP_DIR/$(basename "$url")"
    mkdir -p "$FW_BACKUP_DIR"
    if curl -fsSL --max-time 120 -o "$f.part" "$url" && [[ $(sha512sum "$f.part" | cut -d' ' -f1) == "$sha" ]]; then
        mv "$f.part" "$f"; ok "backed up Lenovo's firmware download to $f"
    else
        rm -f "$f.part"; warn "couldn't back up the firmware from Lenovo (download failed or didn't match)"
    fi
}
fetch_firmware() {   # uses the private backup when there is one, otherwise downloads from Lenovo
    local f
    if f=$(fw_backup_file); then
        sudo validity-sensors-firmware --driver-uri "file://$f" 2>&1 | indent
    else
        sudo validity-sensors-firmware 2>&1 | indent
    fi
}
# `start`, never `restart`: killing the driver mid-handshake leaves the reader stuck
# (every later start times out on its first command until a USB reset or a reboot).
start_services() {
    sudo systemctl reset-failed python3-validity.service open-fprintd.service 2>/dev/null || true
    sudo systemctl start open-fprintd.service python3-validity.service
}
# Un-stick the reader: stop the driver, reset the reader's USB port, start the driver again.
usb_reset() {
    sudo systemctl stop python3-validity.service
    sudo python3 - <<'PY' 2>&1 | indent || true
import usb.core
for vid, pid in ((0x06cb, 0x009a), (0x138a, 0x0097), (0x138a, 0x0090)):
    d = usb.core.find(idVendor=vid, idProduct=pid)
    if d:
        d.reset()
        print("reset USB device %04x:%04x" % (vid, pid))
PY
    sleep 2
    start_services
}
# Driver log since $LOG_SINCE (set before each attempt), so old errors don't count.
LOG_SINCE="-1min"
driver_log() { sudo journalctl -u python3-validity.service --since "$LOG_SINCE" -n "${1:-15}" --no-pager | indent; }

# ---------------------------------------------------------------- 1. AUR pieces
say "AUR pieces (open-fprintd, fprintd-clients)"
# pacman -T also counts packages that *provide* these names (yay installs fprintd-clients-git).
mapfile -t missing < <(pacman -T open-fprintd fprintd-clients || true)
if ((${#missing[@]})); then yay -S --needed --noconfirm "${missing[@]}"; fi
ok "installed"

# ---------------------------------------------------------------- 2. the driver package
say "Building $PKG from this checkout"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
if ! (cd "$HERE" && BUILDDIR="$tmp/build" PKGDEST="$tmp" makepkg -fcd --noconfirm) >"$tmp/build.log" 2>&1; then
    cat "$tmp/build.log"; die "package build failed"
fi
pkgfile=$(ls "$tmp/$PKG"-*.pkg.tar.*)
ok "built $(basename "$pkgfile")"
say "Installing it with pacman"
sudo pacman -U --noconfirm "$pkgfile" | indent

# ---------------------------------------------------------------- 3. firmware
# The driver writes the firmware into the reader's own memory once; after that it isn't needed.
# validity-sensors-firmware keeps its copy in /run (emptied at boot), so fetch it only when the
# reader isn't already working.
say "Reader firmware"
ensure_fw_backup
if reader_up; then
    ok "reader already working (firmware is on it)"
else
    fetch_firmware
    ok "firmware ready"
fi

# ---------------------------------------------------------------- 4. services
say "Starting the fingerprint services"
sudo systemctl daemon-reload
sudo systemctl enable --quiet open-fprintd.service python3-validity.service python3-validity-suspend-hotfix.service
start_services
if wait_for_reader; then
    ok "reader is up"
else
    warn "the reader didn't come up; resetting its USB connection and trying again"
    LOG_SINCE=$(date '+%Y-%m-%d %H:%M:%S')
    usb_reset
    if wait_for_reader; then
        ok "reader is up after a USB reset"
    elif grep -q 'Operation timed out' <<<"$(driver_log 40)"; then
        driver_log
        die "the reader is stuck (USB timeouts above). Reboot, then run this script again."
    else
        warn "the reader still didn't come up. Last driver log lines:"
        driver_log
        echo "    On first setup a factory reset of the reader's chip usually fixes this."
        echo "    It erases fingerprints stored on the chip (e.g. ones Windows enrolled)."
        ask "Factory-reset the reader now?" || die "stopped. Re-run this script when you're ready."
        sudo systemctl stop python3-validity.service
        if ! sudo python3 /usr/share/python-validity/playground/factory-reset.py 2>&1 | indent; then
            die "the factory reset failed (output above). Reboot, then run this script again."
        fi
        fetch_firmware     # a reset wipes the firmware too
        start_services
        wait_for_reader || { driver_log 25; die "the reader still didn't come up (log above)."; }
        ok "reader is up after the reset"
    fi
fi

# ---------------------------------------------------------------- 5. enroll
say "Your fingerprint"
enrolled=$(grep ' - #' <<<"$(fingers)" | sed 's/.*: //' | paste -sd, - || true)
if [[ -n $enrolled ]]; then
    ok "already enrolled: $enrolled"
else
    echo "    Enrolling your right index finger: touch the reader each time it asks,"
    echo "    lifting your finger in between (about 5-10 touches)."
    fprintd-enroll -f right-index-finger "$USER" || sudo fprintd-enroll -f right-index-finger "$USER"
    ok "enrolled. Add more fingers in System Settings → Users → Configure Fingerprint Authentication"
fi

# ---------------------------------------------------------------- 6. sudo
say "Fingerprint for sudo"
if grep -q pam_fprintd /etc/pam.d/sudo; then
    ok "already on"
elif [[ ! -e /usr/lib/security/pam_fprintd.so ]]; then
    warn "pam_fprintd.so is missing (it comes with fprintd-clients), so this was skipped"
elif ask "Let sudo accept your fingerprint? (your password still works; Ctrl+C at the finger prompt skips to it)"; then
    sudo cp -a /etc/pam.d/sudo /etc/pam.d/sudo.before-fingerprint
    sudo sed -i '1a auth        sufficient  pam_fprintd.so' /etc/pam.d/sudo
    ok "on. To undo: sudo mv /etc/pam.d/sudo.before-fingerprint /etc/pam.d/sudo"
else
    ok "left as is"
fi

say "Done. The lock screen accepts your finger now too; the first login after boot still uses your password."
