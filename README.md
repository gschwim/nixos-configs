# nixos-configs

Flakes-based NixOS configurations for multiple hosts.
Hosts currently defined: `pleades` (Lenovo Thinkpad P1 Gen2), `iris` (headless server).

The per-host file at [hosts/`<name>`/default.nix](hosts/) is the only file edited per host. Everything else is shared modules under [modules/](modules/).

## Provisioning a host (the fast path)

Three scripts, run in order. The same flow works for first installs and re-installs.

### Step 1 — Scaffold the host (skip if the host already exists)

```bash
scripts/new-host.sh <host> <type>      # type = server | desktop
```

Creates `hosts/<host>/{default.nix,hardware-configuration.nix}` from the matching template with a random `hostId`. Prints the line to add to `flake.nix`. Then edit `hosts/<host>/default.nix` and confirm: disk device, NIC name, static IP, toggles.

### Step 2 — Pre-stage agenix recipient (skip if host needs no secrets)

```bash
scripts/gen-host-key.sh <host>
```

Generates `~/.local/share/nixos-configs/host-keys/<host>_ed25519` (outside the repo, never committed) and prints the pubkey. Then:

1. Paste the pubkey as the value of `<host>` in `secrets/secrets.nix`.
2. Add `<host>` to the `publicKeys` list of every secret it needs (e.g. `wifi-secrets.age`).
3. Re-key:
   ```bash
   cd secrets
   nix --extra-experimental-features 'nix-command flakes' \
       run github:ryantm/agenix -- -r
   cd ..
   ```
4. Commit + push:
   ```bash
   git add -A && git commit -m "secrets: add <host>" && git push
   ```

### Step 3 — Install

On the target, boot the NixOS installer (graphical or minimal):

```bash
sudo passwd root            # set a password
sudo systemctl start sshd   # if not already running
ip a                        # note the IPv4 address
```

On blushda:

```bash
scripts/install-host.sh <host> <target-ip>
```

`install-host.sh` wraps [nixos-anywhere](https://github.com/nix-community/nixos-anywhere) and handles the rest end-to-end:

- Reads the host's `networking.hostId` from its per-host file.
- Sets the installer's hostid before disko (no more first-boot ZFS dance).
- Stages the pre-generated SSH host key into `/etc/ssh/` on the target (so agenix decryption works on first boot — no second rebuild needed).
- Invokes nixos-anywhere: runs disko, pulls a real `hardware-configuration.nix` back into the flake, copies the closure, installs.
- Uses `StrictHostKeyChecking=no` for installer connections (ephemeral fingerprints; expected to change each boot).
- Prompts for confirmation before doing anything destructive.

### Step 4 — Commit the generated hardware-configuration.nix

```bash
git add hosts/<host>/hardware-configuration.nix
git commit -m "<host>: hardware-configuration.nix from install"
git push
```

The target reboots fully configured. **Back up `~/.local/share/nixos-configs/host-keys/`** — those keys are the agenix decryption identities; if you lose them and re-install, every secret encrypted to that host must be re-keyed.

## Manual install (fallback)

The rest of this document describes the original step-by-step manual install workflow. Use it if you can't reach the target over SSH from blushda — e.g. installing from a USB on an offline machine.

## Installing a host from scratch (baremetal, manual)

The steps below assume installing `pleades` on a fresh Thinkpad P1 Gen2 from blushda (the authoring Mac). For `iris`, substitute `iris` everywhere and adjust the disk path / interface names.

### 0. Prerequisites on blushda (the Mac)

```bash
cd /Users/schwim/src/nixos-configs

# Sanity-check the flake evaluates
nix --extra-experimental-features 'nix-command flakes' flake check --no-build

# If you haven't yet set up the agenix wifi secret, follow the recipe in
# secrets/secrets.nix top-of-file. Do this BEFORE installing pleades only
# if you plan to rely on wifi at install time (you can also use ethernet).
```

### 1. Make the repo reachable from the installer

Pick ONE:

**A. Push to a git remote** (recommended — simplest from the installer):

```bash
cd /Users/schwim/src/nixos-configs
git remote add origin git@github.com:gschwim/nixos-configs.git   # one-time only
git add -A
git commit -m "initial scaffold"
git push -u origin master
```

**B. Copy to a USB stick** (offline path):

```bash
# Format a USB as exFAT or ext4 first (skip if already done).
# Then copy the repo to it:
cp -R /Users/schwim/src/nixos-configs /Volumes/<your-usb-label>/
```

### 2. Create the NixOS installer USB

Download the **NixOS 25.11 minimal ISO** for x86_64 from <https://nixos.org/download/#nixos-iso>.

On blushda, flash to USB (find the device first with `diskutil list`):

```bash
# Identify the USB (look for an external, removable device)
diskutil list

# Unmount but don't eject (replace diskN with the actual device)
diskutil unmountDisk /dev/diskN

# Flash. Replace path-to-iso with the downloaded file path.
# /dev/rdiskN (raw device) is faster than /dev/diskN.
sudo dd if=/path/to/nixos-minimal-25.11-x86_64-linux.iso \
        of=/dev/rdiskN bs=4m status=progress

# Eject when done
diskutil eject /dev/diskN
```

### 3. Boot the installer on pleades

1. Insert the installer USB into pleades.
2. Power on. Press **F12** as the Lenovo logo appears to get the boot menu.
3. Select the USB device. (If it doesn't appear: enter **F1** BIOS setup → Security → Secure Boot → Disabled; also Startup → UEFI/Legacy → UEFI Only.)
4. Wait for the NixOS installer to drop you at a root shell.

### 4. Get the installer online

The P1 Gen2 has no built-in RJ45 — you need either a USB-C/Thunderbolt ethernet adapter, USB tether from a phone, or wifi.

**Option A — Wired (preferred for first install):**

Plug in the adapter; DHCP usually completes automatically. Verify:

```bash
ip a
ping -c 2 1.1.1.1
```

**Option B — WiFi via iwd (NixOS installer ships with `iwctl`):**

```bash
sudo systemctl start iwd
iwctl
# inside iwctl:
[iwd]# device list
[iwd]# station wlan0 scan
[iwd]# station wlan0 get-networks
[iwd]# station wlan0 connect "Canis Major"
# (enter passphrase when prompted)
[iwd]# exit

ping -c 2 1.1.1.1
```

(Interface name may differ — check `ip a` first; on most modern installers it's `wlan0`.)

### 5. Pull the flake onto the installer

**If you pushed to git** (option 1A above):

```bash
nix-shell -p git
cd /tmp
git clone https://github.com/gschwim/nixos-configs.git
cd nixos-configs
```

**If you brought it on USB** (option 1B): mount the USB and copy:

```bash
mkdir -p /mnt-usb
mount /dev/sdX1 /mnt-usb        # find the device with `lsblk`
cp -R /mnt-usb/nixos-configs /tmp/
cd /tmp/nixos-configs
```

### 6. Verify the target disk path

The disko config in [hosts/pleades/default.nix](hosts/pleades/default.nix) uses `/dev/nvme0n1`. Confirm this matches what's actually present:

```bash
lsblk
```

Expect to see `nvme0n1` of the correct size. If not, edit `hosts/pleades/default.nix` to set the right device path before continuing.

⚠️  **The next step erases everything on the target disk.** No prompt, no confirmation. Be sure.

### 7. Partition + format with disko

**Important:** set the installer's hostid to match this host's `networking.hostId` BEFORE running disko. Otherwise the ZFS pool is born with the installer's hostid and won't import on first boot. (Look up the host's `hostId` in `hosts/<host>/default.nix`.)

```bash
# Substitute the host's actual hostId value (e.g. deadbeef for pleades).
# The live ISO's /etc is read-only, so write to /run and bind-mount.
sudo zgenhostid -fo /run/hostid deadbeef
sudo mount --bind /run/hostid /etc/hostid
hostid                        # verify it prints deadbeef

# Now create the pool. It will be born with the right hostid.
sudo nix --extra-experimental-features 'nix-command flakes' \
    run github:nix-community/disko -- \
    --mode disko \
    --flake /tmp/nixos-configs#pleades
```

If you forgot the `zgenhostid` step and got "pool was previously in use by another system" on first boot, see [Recovering from a hostid mismatch](#recovering-from-a-hostid-mismatch) below.

Disko partitions `/dev/nvme0n1`, creates the rpool, makes the datasets, and mounts everything under `/mnt`. Verify:

```bash
mount | grep /mnt
zfs list
ls /mnt/boot
```

### 8. Generate hardware-configuration.nix for this hardware

The stub at `hosts/pleades/hardware-configuration.nix` is a placeholder. Replace it with the real one generated against this exact machine:

```bash
sudo nixos-generate-config --no-filesystems --root /mnt

# That writes to /mnt/etc/nixos/hardware-configuration.nix.
# Copy it into the flake, replacing the stub:
sudo cp /mnt/etc/nixos/hardware-configuration.nix \
        /tmp/nixos-configs/hosts/pleades/hardware-configuration.nix

# Commit + push so blushda gets the change too.
cd /tmp/nixos-configs
git add hosts/pleades/hardware-configuration.nix
git -c user.email='schwim@7e7.co' -c user.name='schwim' \
    commit -m "pleades: hardware-configuration.nix from first install"
git push    # if you used the git remote path
```

(If you used USB instead of git, copy the file back to blushda after install.)

### 9. Install

```bash
sudo nixos-install --flake /tmp/nixos-configs#pleades
```

This builds the system in the flake's nixpkgs (25.11), copies the closure to `/mnt/nix`, and installs the bootloader. It prompts for the **root password** at the very end — set one.

### 10. Set schwim's password before first boot

The `schwim` user is created by the base module but has no password. Set one inside the chroot:

```bash
sudo nixos-enter --root /mnt -- passwd schwim
```

### 11. Reboot into the installed system

```bash
sudo reboot
# Remove the USB during POST.
```

Log in as `schwim` at the GDM greeter (pleades) or console (iris).

### 12. Bootstrap agenix for this host

The wifi secret is currently encrypted only for blushda. Pleades needs its own SSH host key added so it can decrypt. From pleades:

```bash
cat /etc/ssh/ssh_host_ed25519_key.pub
# Copy the full "ssh-ed25519 AAAA... root@pleades" line
```

Back on blushda:

1. Open [secrets/secrets.nix](secrets/secrets.nix), paste the pubkey as the value of `pleades`.
2. Change the last line from `editors` to `editors ++ [ pleades ]`.
3. Re-encrypt:

```bash
cd /Users/schwim/src/nixos-configs/secrets
nix --extra-experimental-features 'nix-command flakes' \
    run github:ryantm/agenix -- -r
```

4. Commit + push:

```bash
cd /Users/schwim/src/nixos-configs
git add secrets/
git commit -m "secrets: add pleades host key, re-key wifi-secrets"
git push
```

5. On pleades, pull + rebuild to activate the now-decryptable secret:

```bash
cd /tmp/nixos-configs   # or wherever you cloned it
git pull
sudo nixos-rebuild switch --flake .#pleades
```

After the rebuild, `/run/agenix/wifi-secrets` exists (root-readable only) and wpa_supplicant can authenticate to Canis Major.

### 13. Verify

```bash
# Services up?
systemctl status sshd incus

# ZFS layout matches the disko spec?
zfs list

# WiFi associated? (only if you switched to wifi after install)
ip a show wlp82s0
iwconfig wlp82s0 2>/dev/null || iw dev wlp82s0 link

# Agenix decryption worked?
sudo ls -la /run/agenix/

# Incus listening?
ss -tlnp | grep 8443
```

If you're joining `pleades` to an existing incus cluster, run `incus cluster join` interactively per the incus docs (cluster membership is incus-level state, not NixOS-level).

## Day-to-day rebuilds

After the initial install, all changes flow through git:

```bash
# On blushda: edit something, commit, push.
cd /Users/schwim/src/nixos-configs
# ... edit hosts/pleades/default.nix or a module ...
git add -A && git commit -m "pleades: enable foo"
git push

# On pleades: pull and rebuild.
cd /path/to/checkout
git pull
sudo nixos-rebuild switch --flake .#pleades
```

## Editing secrets

See the comment block at the top of [secrets/secrets.nix](secrets/secrets.nix) for the full recipe (first-time setup, adding a host, editing later, gotchas).

## Gotchas

- **`nix flake check` requires files be `git add`-ed.** Untracked files are invisible to the flake. Always `git add -A` after creating new files, even before committing.
- **Disko erases the target disk with no prompt.** Triple-check `lsblk` output before step 7.
- **ZFS hostId** must match between pool-create time and runtime. The per-host file's `networking.hostId` is the source of truth. Run `sudo zgenhostid -f <hostId>` in the installer BEFORE disko (step 7). Don't change `networking.hostId` after install or rpool won't import. See recovery recipe below if you hit "pool was previously in use by another system" at first boot.
- **`agenix -e` on an empty file fails** with EOF; `rm` the empty file first.
- **`agenix` reads `secrets.nix` from cwd**, not from a repo-relative path; always `cd secrets` first.
- **First boot before agenix bootstrap**: pleades's wifi won't work because the secret is encrypted only for blushda. Use wired/tether for the install, complete the agenix bootstrap (step 12), then switch to wifi.

### Recovering from a hostid mismatch

If first boot fails with `cannot import 'rpool': pool was previously in use by another system`, boot the installer USB and do this once. Substitute the host's actual `hostId` value from `hosts/<host>/default.nix`.

```bash
# 1. Force-import past the safety check.
sudo zpool import -f rpool

# 2. Set the installer's hostid to match the installed system.
#    The live ISO's /etc is read-only, so write to /run and bind-mount.
sudo zgenhostid -fo /run/hostid deadbeef
sudo mount --bind /run/hostid /etc/hostid
hostid                        # verify it prints deadbeef

# 3. Re-export, then plain re-import — this bakes the new hostid
#    into the pool's metadata.
sudo zpool export rpool
sudo zpool import rpool

# 4. Clean export so the next boot finds a tidy pool.
sudo zpool export rpool

# 5. Reboot, remove the USB during POST.
sudo reboot
```
