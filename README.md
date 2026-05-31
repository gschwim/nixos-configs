# nixos-configs

Flakes-based NixOS configurations for a small home fleet. Three NixOS configurations are exposed today: `pleiades` (desktop laptop), `iris` (headless server), and `installer` (a custom NixOS minimal ISO used to bootstrap new hosts).

## Layout

| Path | Contents |
| --- | --- |
| [hosts/](hosts/) | Per-host config. `hosts/<name>/default.nix` is the only file edited per host. `hosts/_templates/` holds the scaffold templates used by `scripts/new-host.sh`. |
| [modules/](modules/) | Shared modules (base, boot/zfs, disko, desktop/gnome, networking, services, power, secrets, home-manager). Auto-imported via [modules/default.nix](modules/default.nix). |
| [lib/](lib/) | [mkHost.nix](lib/mkHost.nix) (host-config helper) and [admin-keys.nix](lib/admin-keys.nix) (workstation SSH pubkeys authorised across the fleet). |
| [home/](home/) | Home-manager config for the admin user. |
| [secrets/](secrets/) | agenix-encrypted secrets + [secrets.nix](secrets/secrets.nix) recipient declarations. |
| [scripts/](scripts/) | Provisioning tooling: `new-host.sh`, `gen-host-key.sh`, `install-host.sh`. |

## Prerequisites

One-time setup on the authoring machine (the Mac you edit this repo from, referred to below as the workstation):

- **Nix with flakes enabled.** `experimental-features = nix-command flakes` in `~/.config/nix/nix.conf`.
- **An age authoring identity** at `~/.config/sops/age/keys.txt`. Generate with `age-keygen -o ~/.config/sops/age/keys.txt`, then paste its `Public key: age1...` value into [secrets/secrets.nix](secrets/secrets.nix) (replace the workstation identity at the top of the `let` block). Full setup recipe lives in the comment block at the top of that file.
- **`keepassxc-cli` ≥ 2.7.7** on PATH. macOS: `brew install keepassxc`. 2.7.6 has an attachment-import bug that silently drops the second back-to-back import (see [scripts/gen-host-key.sh:15-17](scripts/gen-host-key.sh#L15-L17)) — verify with `keepassxc-cli --version`.
- **A KeepassXC database** holding (or about to hold) the per-host SSH host keys. `scripts/gen-host-key.sh` reads/writes entries under `ssh-host-keys/<hostname>`. Point at it with `export KDBX_FILE=<path-to-kdbx>` in your shell (or accept the script's hardcoded default and adjust it locally). Set `KDBX_PW` to skip the per-invocation password prompt.
- **A Linux build environment** for building the custom installer ISO. Mac alone cannot build x86_64-linux closures. Options: an existing NixOS host (e.g. `pleiades` once it's up), a configured remote builder in `/etc/nix/machines`, or `nix.linux-builder.enable = true` under nix-darwin.

## Adding a new host

End state of this section: a host directory exists, the host is registered in the flake, its ed25519 SSH host key is in KeepassXC and authorised in `secrets/secrets.nix`, and every agenix secret it needs decrypts to it. After this, jump to either "Installing with the USB installer" or "Manual install".

### 1. Scaffold the host directory

```bash
scripts/new-host.sh <hostname> <server|desktop>
```

Creates `hosts/<hostname>/{default.nix,hardware-configuration.nix}` from [hosts/_templates/server.nix](hosts/_templates/server.nix) or [hosts/_templates/desktop.nix](hosts/_templates/desktop.nix), substituting the hostname and a freshly-rolled 8-hex `hostId` (used by ZFS). The script intentionally does **not** touch `flake.nix` or `secrets/secrets.nix`; both edits happen in steps 3 and 4 below.

### 2. Fill in the per-host file

Open `hosts/<hostname>/default.nix` and confirm these fields (the templates contain sane defaults but most are placeholders):

- `networking.hostName` — auto-filled, just verify.
- `networking.hostId` — auto-filled (random). Immutable after first install: ZFS pool metadata bakes this in.
- `my.disko.disk` — `/dev/sda` (server template) or `/dev/nvme0n1` (desktop template). Confirm at install with `lsblk` before running the installer.
- `my.network.static.{interface,address,prefixLength,gateway,nameservers}` — pick a real IP, set the NIC name. For a desktop with wifi, see the commented-out `my.network.wireless` block.
- Feature toggles — uncomment the ones you want (`my.desktop.gnome.enable`, `my.services.incus.enable`, `my.services.xrdp.enable`, etc.). Default-on baselines (openssh, networking, home-manager) need no entry.

The templates are the authoritative reference for what's available.

### 3. Register the host in `flake.nix`

Add one line to `nixosConfigurations` in [flake.nix](flake.nix):

```nix
<hostname> = mkHost { hostName = "<hostname>"; system = "x86_64-linux"; };
```

`scripts/new-host.sh` prints the exact line at the end of its output. Done by hand to avoid the script clobbering nearby entries.

### 4. Generate (or pull) the host's SSH key

```bash
scripts/gen-host-key.sh <hostname>
```

Three things happen, in order:

1. **KeepassXC lookup.** Looks for entry `ssh-host-keys/<hostname>` in the kdbx.
   - **Present:** exports the two attachments (`ssh_host_ed25519_key`, `ssh_host_ed25519_key.pub`) to `~/.local/share/nixos-configs/host-keys/<hostname>_ed25519` (private) and `…_ed25519.pub` (public).
   - **Absent:** runs `ssh-keygen -t ed25519`, writes to the cache, then creates the entry in KeepassXC with both attachments.
2. **secrets.nix reconciliation.** Inserts or replaces a `<hostname> = "ssh-ed25519 …";` line in [secrets/secrets.nix](secrets/secrets.nix). If a real entry already exists and doesn't match the cache, the script hard-fails — *do not* install a host whose pubkey in `secrets.nix` doesn't match the key it'll boot with, or agenix secrets won't decrypt on first boot.
3. **Prints the pubkey** for confirmation.

The KeepassXC round-trip is the authoritative store; the local file is a cache. Re-running for an existing host is idempotent (same pubkey every time).

### 5. Add the host to the right access lists

[secrets/secrets.nix](secrets/secrets.nix) maintains named access lists (`allAccess`, `wifiAccess`, etc.) that compose per-secret recipient sets. Step 4 added the identity but not its memberships — by hand, append `<hostname>` to whatever lists apply:

- `allAccess` — recipients that should decrypt **every** secret. Usually only editor workstations and any host you'd run `agenix -e` on. Don't put a regular host in here unless it really needs full access.
- A per-secret list like `wifiAccess` — for hosts that only need one specific secret. The `realKeys` helper filters out `REPLACE_WITH_…` placeholders, so you can list a host's identifier ahead of provisioning without breaking the encrypt step.

### 6. Re-key and commit

```bash
cd secrets
nix --extra-experimental-features 'nix-command flakes' \
    run github:ryantm/agenix -- -i ~/.config/sops/age/keys.txt -r
cd ..
git add -A
git commit -m "secrets: add <hostname>"
git push
```

Two agenix invocation gotchas to remember:

- agenix reads `secrets.nix` from the **current working directory** — always `cd secrets` first.
- The authoring identity is an age key (not an SSH key), so `-i ~/.config/sops/age/keys.txt` is required on every `agenix -e` / `-r`. Without it: `age: error: no identity matched any of the recipients`.

The host is now ready to install. Pick a path:

- **"Installing with the USB installer"** — fast path, recommended. The custom ISO + `scripts/install-host.sh` handle everything end-to-end from the workstation.
- **"Manual install"** — fallback when you can't reach the target over SSH from the workstation.

## Creating the USB installer

The flake exposes a `nixosConfigurations.installer` that builds a NixOS minimal ISO tuned for this fleet. What it does differently from the stock minimal installer (see [hosts/installer/default.nix](hosts/installer/default.nix)):

- Console output mirrored to both `tty1` (VGA) and `ttyS0,115200n8` (serial) — works in VMs and headless boxes.
- sshd up by default, key-only auth, the workstation's ed25519 pubkey embedded for both the admin user and root (the latter is required because `nixos-anywhere` pivots to `root@` mid-install).
- Admin user has passwordless sudo (the installer is ephemeral and SSH-key-protected).
- Bundles `git`, `vim`, `htop`, `nix-output-monitor`, `cryptsetup`.
- NetworkManager left enabled (the upstream installer default — easiest path to wifi).
- Fleet baselines that conflict with a live ISO (`home-manager`, `networking`) are disabled.
- Live ISO root is writable as tmpfs; no persistent partition.

### Build

```bash
nix --extra-experimental-features 'nix-command flakes' \
    build .#nixosConfigurations.installer.config.system.build.isoImage
# Output: result/iso/nixos-*-x86_64-linux.iso
```

This step **must run on a Linux host** — Mac alone can't build x86_64-linux closures. Use any running NixOS host in the fleet (typically `pleiades` once it's up), a configured remote builder, or `nix.linux-builder.enable = true` under nix-darwin.

Bootstrap reality: the *first* host you install (the first time you set this up) needs the stock NixOS 25.11 minimal ISO from <https://nixos.org/download/>, since there's no Linux host yet to build the custom one. Every install after that can use the custom ISO.

### Flash to USB (on macOS)

```bash
diskutil list                                       # find the USB
diskutil unmountDisk /dev/diskN                     # unmount but don't eject
sudo dd bs=4M conv=fsync oflag=direct status=progress \
    if=result/iso/nixos-*-x86_64-linux.iso of=/dev/rdiskN
diskutil eject /dev/diskN
```

Use `/dev/rdiskN` (raw device) — it's substantially faster than `/dev/diskN`.

### VM use

Attach `result/iso/nixos-*-x86_64-linux.iso` as a CD/DVD device and boot from it. With qemu, add `-serial mon:stdio` to capture the serial console at the host terminal; or just wait for the VM to come up and SSH in (`ssh <user>@<vm-ip>`).

### Iteration loop

```bash
# edit hosts/installer/default.nix
git add hosts/installer/default.nix
git commit -m "installer: ..."
git push
# on a Linux host (e.g. pleiades):
git pull
nix build .#nixosConfigurations.installer.config.system.build.isoImage
# re-flash result/iso/nixos-*.iso
```

## Installing with the USB installer

End state of this section: the target is installed, rebooted, and fully configured. No second rebuild needed; agenix secrets decrypt on first boot because the SSH host key was pre-staged.

### 1. Boot the target

Plug in the USB and boot from it. NetworkManager is on by default in the custom installer; once at the prompt:

```bash
ip a               # find the target's IPv4 address
```

sshd is already running and the workstation's key is authorised for both the admin user and root. No setup needed in the live environment.

### 2. Run the installer from the workstation

```bash
cd /path/to/nixos-configs
scripts/install-host.sh <hostname> <target-ip>
```

Override the SSH user via env if the target's admin user differs: `INSTALL_USER=nixos scripts/install-host.sh ...`. The target user must have passwordless sudo (the custom ISO grants this for the admin user out of the box).

What the script does end-to-end (see [scripts/install-host.sh](scripts/install-host.sh)):

1. Reads `networking.hostId` from `hosts/<hostname>/default.nix`.
2. Calls `scripts/gen-host-key.sh <hostname>` to ensure the SSH host key exists in KeepassXC and the cache, and the entry in `secrets/secrets.nix` matches. If it's the first time for this host, you'll be prompted for the kdbx password.
3. Stages the key under an extra-files tree at `/etc/ssh/ssh_host_ed25519_key{,.pub}` for `nixos-anywhere` to drop onto the target before first boot. **This is what makes agenix decryption work on first boot — no second rebuild.**
4. SSHes to the installer, sets the transient hostid via `zgenhostid -fo /run/hostid <hostId>` + `mount --bind /run/hostid /etc/hostid` (so the ZFS pool is born with the *target's* hostid, not the installer's), and copies the user's authorized_keys to `/root/.ssh/` (nixos-anywhere pivots to `root@` mid-install).
5. Invokes `nixos-anywhere --flake .#<hostname> --extra-files <staging> --generate-hardware-config nixos-generate-config <path> --build-on remote`. Disko wipes + partitions, nixos-anywhere generates a real `hardware-configuration.nix` back into the host directory, copies the closure, installs.

Notes on the flags: `--build-on remote` is set explicitly because the workstation (Darwin) can't build x86_64-linux; without it `nixos-anywhere` runs a noisy probe before falling back. `StrictHostKeyChecking=no` is set on every installer-bound SSH connection because installer ISOs regenerate their host keys every boot — a stable known_hosts entry would only cause "host key changed" errors on re-installs.

The script prompts twice before doing anything destructive: once if `secrets/secrets.nix` still has a `REPLACE_WITH_…` placeholder for this host, once again before the disk wipe.

### 3. Commit the regenerated `hardware-configuration.nix`

```bash
git add hosts/<hostname>/hardware-configuration.nix
git commit -m "<hostname>: hardware-configuration.nix from install"
git push
```

### 4. Back up the host key

`~/.local/share/nixos-configs/host-keys/<hostname>_ed25519` is the agenix decryption identity for this host. The KeepassXC round-trip already protects it (the kdbx is the source of truth), but if you lose both the kdbx entry *and* the local cache, every agenix secret encrypted to this host has to be re-keyed. Keep your kdbx backed up.

## Manual install

Fallback path. Use when you can't reach the target from the workstation over SSH (no working network adapter, target on an isolated network, prefer to install entirely on-console). The end result is the same; you just do by hand what `install-host.sh` would have done remotely.

### 1. Boot stock NixOS

Download the NixOS 25.11 minimal ISO from <https://nixos.org/download/>, flash it to USB with the same `dd` recipe as in "Creating the USB installer", boot the target from it.

### 2. Get the installer online

Wired: plug in, DHCP usually completes automatically. Verify with `ip a` + `ping -c 2 1.1.1.1`.

Wifi (`iwd` ships in the installer):

```bash
sudo systemctl start iwd
iwctl
# inside iwctl:
[iwd]# device list
[iwd]# station <wifi-iface> scan
[iwd]# station <wifi-iface> get-networks
[iwd]# station <wifi-iface> connect "<your-wifi-ssid>"
# (enter passphrase when prompted)
[iwd]# exit
```

### 3. Pull the flake onto the installer

Easiest: clone from your git remote.

```bash
nix-shell -p git
cd /tmp
git clone <your-flake-repo-url>
cd nixos-configs
```

USB alternative: copy the repo to a USB stick on the workstation first, then on the target `mount /dev/sdX1 /mnt-usb && cp -R /mnt-usb/nixos-configs /tmp/`.

### 4. Verify the disko target

```bash
lsblk
```

Confirm the device path in `hosts/<hostname>/default.nix` matches. Edit if it doesn't.

⚠️ The next step erases the target disk. No prompt. Triple-check `lsblk` before continuing.

### 5. Set the installer's hostid

```bash
HOSTID=$(grep hostId hosts/<hostname>/default.nix | sed -E 's/.*"([^"]+)".*/\1/')
sudo zgenhostid -fo /run/hostid "$HOSTID"
sudo mount --bind /run/hostid /etc/hostid
hostid           # verify it prints the expected value
```

The live ISO's `/etc` is read-only, so the bind-mount from `/run` is required. If you skip this, the ZFS pool is born with the installer's hostid and won't import on first boot (see the recovery recipe at the bottom of this README).

### 6. Run disko

```bash
sudo nix --extra-experimental-features 'nix-command flakes' \
    run github:nix-community/disko -- \
    --mode disko \
    --flake /tmp/nixos-configs#<hostname>
```

Verify after: `mount | grep /mnt`, `zfs list`, `ls /mnt/boot`.

### 7. Generate `hardware-configuration.nix`

```bash
sudo nixos-generate-config --no-filesystems --root /mnt
sudo cp /mnt/etc/nixos/hardware-configuration.nix \
        /tmp/nixos-configs/hosts/<hostname>/hardware-configuration.nix
cd /tmp/nixos-configs
git add hosts/<hostname>/hardware-configuration.nix
git -c user.email='you@example.com' -c user.name='<you>' \
    commit -m "<hostname>: hardware-configuration.nix from install"
git push                                  # or copy the file back to the workstation by hand
```

### 8. Install

```bash
sudo nixos-install --flake /tmp/nixos-configs#<hostname>
```

Prompts for the root password at the end. Set one.

### 9. Set the admin user's password

The admin user is created by the base module without a password:

```bash
sudo nixos-enter --root /mnt -- passwd <user>
```

### 10. Pre-stage the SSH host key (if you want to skip the second rebuild)

If you ran `scripts/gen-host-key.sh <hostname>` on the workstation *before* this install and committed the resulting `secrets.nix` change, copy the cached private/public keys onto the target before reboot:

```bash
# On the workstation:
scp ~/.local/share/nixos-configs/host-keys/<hostname>_ed25519 \
    ~/.local/share/nixos-configs/host-keys/<hostname>_ed25519.pub \
    root@<target-ip>:/tmp/

# On the target:
sudo install -m 600 /tmp/<hostname>_ed25519     /mnt/etc/ssh/ssh_host_ed25519_key
sudo install -m 644 /tmp/<hostname>_ed25519.pub /mnt/etc/ssh/ssh_host_ed25519_key.pub
```

If you skip this, work the bootstrap from step 12.

### 11. Reboot

```bash
sudo reboot
# Remove the USB during POST.
```

Log in as the admin user (GDM if it's a desktop, console otherwise).

### 12. Agenix bootstrap (only if you skipped step 10)

The target generated a fresh SSH host key at first boot that the rest of the fleet doesn't know about. From the target:

```bash
cat /etc/ssh/ssh_host_ed25519_key.pub
```

Copy the full `ssh-ed25519 …` line. Back on the workstation:

1. Run `scripts/gen-host-key.sh <hostname>` — it'll detect the mismatch between the cached/kdbx key and the now-installed key, and refuse. Resolve by either pulling the just-printed key into KeepassXC manually (then re-running `gen-host-key.sh`), or by pasting the new pubkey directly into `secrets/secrets.nix` and updating KeepassXC.
2. Re-encrypt: `cd secrets && agenix -i ~/.config/sops/age/keys.txt -r`.
3. Commit, push.
4. On the target: `git pull && sudo nixos-rebuild switch --flake .#<hostname>`.

After this `/run/agenix/*` exists and any secret the host needs decrypts.

## Day-to-day rebuilds

```bash
# On the workstation: edit, commit, push.
cd /path/to/nixos-configs
# ... edit hosts/<hostname>/default.nix or a module ...
git add -A && git commit -m "<hostname>: enable foo"
git push

# On the target: pull and rebuild.
cd /path/to/nixos-configs        # wherever you cloned it
git pull
sudo nixos-rebuild switch --flake .#<hostname>
```

## Editing secrets

Full recipe (first-time setup, gotchas) lives at the top of [secrets/secrets.nix](secrets/secrets.nix). Common case:

```bash
cd /path/to/nixos-configs/secrets
nix --extra-experimental-features 'nix-command flakes' \
    run github:ryantm/agenix -- -i ~/.config/sops/age/keys.txt -e <name>.age
```

## Gotchas

- **`nix flake check` requires files be `git add`-ed.** Untracked files are invisible to the flake. Always `git add -A` after creating new files, even before committing.
- **Disko erases the target disk with no prompt.** `install-host.sh` wraps it with one; the manual path does not. Confirm `lsblk` carefully.
- **ZFS hostId** must match between pool-create time and runtime. The per-host file's `networking.hostId` is the source of truth. `install-host.sh` handles this automatically; the manual path requires the `zgenhostid` + bind-mount dance before disko. Don't change `networking.hostId` after install or the rpool won't import. Recovery recipe below.
- **agenix invocation needs both `-i ~/.config/sops/age/keys.txt` and a `cd secrets` first** — the agenix CLI only auto-discovers SSH identities, not the age key the workstation uses, and it reads `secrets.nix` from the cwd.
- **`agenix -e` on a 0-byte file fails** with "failed to read intro: EOF". Delete the empty placeholder first; agenix recreates it.
- **Pre-staging the SSH host key** (what `install-host.sh` does via `--extra-files`) is what allows agenix-encrypted secrets to decrypt on first boot. Skip it and you need a second rebuild after the manual agenix bootstrap.
- **`gen-host-key.sh` hard-fails on mismatch** between the cached/kdbx pubkey and what's in `secrets/secrets.nix`. This is by design — installing a host whose recipient list doesn't match the SSH key it boots with means agenix secrets won't decrypt. Resolve by updating whichever side is stale.

## Recovery: hostid mismatch

If first boot fails with `cannot import 'rpool': pool was previously in use by another system`, boot the installer USB and do this once. Substitute the host's actual `hostId` value from `hosts/<hostname>/default.nix`.

```bash
# 1. Force-import past the safety check.
sudo zpool import -f rpool

# 2. Set the installer's hostid to match the installed system.
#    The live ISO's /etc is read-only, so write to /run and bind-mount.
sudo zgenhostid -fo /run/hostid <hostId>
sudo mount --bind /run/hostid /etc/hostid
hostid                        # verify it prints <hostId>

# 3. Re-export, then plain re-import — this bakes the new hostid
#    into the pool's metadata.
sudo zpool export rpool
sudo zpool import rpool

# 4. Clean export so the next boot finds a tidy pool.
sudo zpool export rpool

# 5. Reboot, remove the USB during POST.
sudo reboot
```
