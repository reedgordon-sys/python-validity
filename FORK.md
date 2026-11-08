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

## Changes from upstream

- `validity-sensors-firmware` creates `/run/python-validity/` before copying the firmware there. `/run` is emptied
  at boot, so on a fresh boot the copy failed if the driver hadn't run yet.
- `packaging/arch/`: Arch package that installs the files directly (current setuptools no longer supports
  `setup.py install`), restarts the driver after sleep, and a one-command setup script.

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
