# reedg's fork of python-validity

A personal fork, kept working for my **ThinkPad X1 Yoga 3rd gen** (fingerprint reader Synaptics `06cb:009a`)
on Arch Linux. The original is [uunicorn/python-validity](https://github.com/uunicorn/python-validity),
which has been quiet since release 0.15 (June 2025). The stock Linux fingerprint library (`libfprint`) lists
this reader as unsupported, so this driver is the only way to use it.

No promises for other machines. If it helps you, great.

## Install / after any change

```bash
~/src/python-validity/packaging/arch/setup.sh
```

Run it as your normal user (it asks for sudo when needed). It installs `open-fprintd` + `fprintd-clients` from the
AUR, builds this checkout into the `python-validity-reedg` package, downloads the reader's firmware from Lenovo
(never stored in this repo), starts the services, enrolls a finger and offers fingerprint for `sudo`.
Re-run it after editing the driver: it rebuilds, reinstalls and restarts.

After a Python minor-version upgrade (e.g. 3.14 → 3.15), re-run it so the driver lands in the new `site-packages`.

**Gotcha: never restart the driver while it's starting up.** Killing it mid-handshake leaves the reader stuck:
every later start fails with `USBTimeoutError: Operation timed out` on its first command. A USB reset sometimes
clears it; a reboot always does. (`setup.sh` uses `systemctl start`, never `restart`, and tries a USB reset first.)

## Changes from upstream

- `validity-sensors-firmware` creates `/run/python-validity/` before copying the firmware there. `/run` is emptied
  at boot, so on a fresh boot the copy failed if the driver hadn't run yet.
- `dbus-service` uses `GLibUnix.signal_add` (falls back to the deprecated `GLib.unix_signal_add` on older GLib),
  so a future PyGObject that drops the old name won't stop the driver from starting.
- `packaging/arch/`: Arch package that installs the files directly (current setuptools no longer supports
  `setup.py install`), restarts the driver after sleep, warns after a Python upgrade, and a one-command setup script.

## Keeping it working

Nobody upstream updates this, so these are the things that can break it and what's in place:

| What changes | What happens | What to do |
|---|---|---|
| Python minor upgrade (3.14 → 3.15, about once a year) | Driver and `open-fprintd` stop loading | pacman prints a **"!! Python is now 3.x"** warning right after the upgrade. Run `setup.sh` and `yay -S --rebuild open-fprintd` |
| Lenovo removes the firmware download | Only matters after a factory reset | `setup.sh` keeps a private copy in `~/.local/share/python-validity-firmware/` (checked against the SHA-512 in `firmware_tables.py`) and uses it automatically. Back that folder up with the rest of your home folder |
| PyGObject drops deprecated names | Driver: already fixed. `open-fprintd` still uses `GObject.MainLoop` (warning in the journal) | If `open-fprintd` stops starting, fork it the same way (one-line fix: `GLib.MainLoop`) |
| Finger stops working after sleep | The suspend hotfix restarts the driver on wake | `sudo systemctl restart python3-validity` once the laptop is idle; if it times out, reboot |

Quick health check: `fprintd-list $USER` should list your finger. `journalctl -u python3-validity -b` shows the driver's log since boot.

## Git workflow

| Remote | Points to | Use |
|---|---|---|
| `origin` | `reedgordon-sys/python-validity` (public) | where my fixes go |
| `upstream` | `uunicorn/python-validity` | pull in the original's changes, if it ever moves again |

```bash
# save + publish a fix
git add -A && git commit -m "what changed" && git push

# bring in new upstream changes
git fetch upstream && git merge upstream/master && packaging/arch/setup.sh
```

One-time, to create the fork on GitHub (GitHub forks of public repos are always public):

```bash
gh repo fork --remote --remote-name origin && git push -u origin master
```

## Undo

```bash
sudo pacman -R python-validity-reedg open-fprintd fprintd-clients
sudo mv /etc/pam.d/sudo.before-fingerprint /etc/pam.d/sudo    # only if you turned on fingerprint for sudo
```
