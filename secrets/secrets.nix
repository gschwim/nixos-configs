# =============================================================================
# agenix recipient declarations.
#
# This file lists who can decrypt each *.age file in this directory.
# `agenix` reads it (from the cwd) to know what keys to encrypt to.
# ALL `agenix` commands below must be run from THIS directory (secrets/).
# =============================================================================
#
# MENTAL MODEL
# ------------
# agenix has no edit-vs-read distinction. Each .age file is encrypted to a
# flat list of recipients (publicKeys). Anyone whose private key matches a
# recipient can decrypt — and therefore also re-encrypt, i.e. edit.
#
# To impose useful structure on a flat list, this file uses two kinds of
# variables:
#
#   - Identities (one per workstation/host): blushda, pleiades, iris, …
#     Each holds the pubkey for that machine.
#
#   - Access lists (named "<scope>Access"):
#       allAccess  = identities that should decrypt EVERY secret. Typically
#                    editor workstations + any host you'd run `agenix -e` on.
#       <x>Access  = per-secret consumers — hosts that only need ONE secret.
#                    Appended onto allAccess in that secret's publicKeys.
#
# A new secret's publicKeys is built as `allAccess ++ <specific>Access`. The
# union determines who can decrypt; the structure makes intent obvious.
#
# FIRST-TIME SETUP (do this once, on your Mac):
# ---------------------------------------------
#
#   1. Generate your authoring age keypair (if you don't already have one):
#
#        mkdir -p ~/.config/sops/age
#        nix --extra-experimental-features 'nix-command flakes' \
#            shell nixpkgs#age --command age-keygen -o ~/.config/sops/age/keys.txt
#
#      The terminal prints a line like:
#        Public key: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
#      Copy that age1... value and paste it as `blushda` below.
#      The private half stays in ~/.config/sops/age/keys.txt — never commit it.
#
#   2. Edit the wifi PSK secret (creates wifi-secrets.age the first time):
#
#        cd /Users/schwim/src/nixos-configs/secrets
#        rm -f wifi-secrets.age          # only if a 0-byte placeholder exists
#        nix --extra-experimental-features 'nix-command flakes' \
#            run github:ryantm/agenix -- -i ~/.config/sops/age/keys.txt \
#                                         -e wifi-secrets.age
#
#      Your $EDITOR opens with an empty buffer. Enter ONE line:
#        psk_canis_major=<the-actual-wifi-passphrase>
#      Save & exit. agenix encrypts to every recipient in this secret's
#      publicKeys (allAccess ++ wifiAccess). Commit the encrypted blob.
#
# ADDING A NEW HOST:
# ------------------
# `scripts/gen-host-key.sh <host>` handles the identity insertion:
# generates (or pulls from keepassxc) the host's ed25519 SSH key and
# inserts/replaces the `<host> = "ssh-ed25519 …";` line below for you.
#
# After it runs, you still need to:
#
#   1. Decide which lists the host belongs in:
#        - In allAccess if it should decrypt every secret (rare for non-
#          authoring hosts; usually only editor workstations live there).
#        - In some <x>Access list for the specific secrets it needs.
#      Edit those lists below by hand.
#
#   2. Re-encrypt every affected secret to the new recipient set:
#
#        cd /Users/schwim/src/nixos-configs/secrets
#        nix --extra-experimental-features 'nix-command flakes' \
#            run github:ryantm/agenix -- -i ~/.config/sops/age/keys.txt -r
#
#      Commit the updated .age files.
#
# EDITING AN EXISTING SECRET LATER:
# ---------------------------------
#
#   cd /Users/schwim/src/nixos-configs/secrets
#   nix --extra-experimental-features 'nix-command flakes' \
#       run github:ryantm/agenix -- -i ~/.config/sops/age/keys.txt \
#                                    -e wifi-secrets.age
#
# GOTCHAS:
# --------
# - agenix only looks at SSH keys (~/.ssh/id_*) by default. Our authoring
#   identity is an age key at ~/.config/sops/age/keys.txt, so every agenix
#   invocation needs `-i ~/.config/sops/age/keys.txt`. Without it you get:
#     age: error: no identity matched any of the recipients
# - agenix MUST be invoked from the directory containing secrets.nix.
# - If an identity in a publicKeys list is a placeholder/invalid key, agenix's
#   save step fails (malformed SSH recipient / failed to read header). Only
#   put REAL keys into publicKeys; keep placeholders out of any list until the
#   host actually exists.
# - `agenix -e` on a 0-byte file fails with "failed to read intro: EOF".
#   Delete the file first if you see this; agenix will create it fresh.
# =============================================================================

let
  # ---- Identities ----------------------------------------------------------
  # blushda is an age key (workstation authoring identity).
  # Hosts use their SSH host pubkey (ssh-ed25519 …) — managed by
  # scripts/gen-host-key.sh which inserts/replaces these in place.
  blushda = "age1gumg838j0s9fpmly4umss05e994dh7zgq6j94fyx8tel9v6nqansn8aq9p";

  pleiades = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOoCf/2e719Y8SzpIc4clVYtde8HEeq+3oLIbtkWDkJ2";
  iris    = "ssh-ed25519 AAAA_REPLACE_WITH_IRIS_HOST_PUBKEY";

  # ---- Access lists --------------------------------------------------------
  # Filter placeholder identities out of any list. Once gen-host-key.sh
  # swaps "ssh-ed25519 AAAA_REPLACE_WITH_<HOST>_HOST_PUBKEY" for a real key,
  # the corresponding host automatically appears in publicKeys on the next
  # agenix -r. Lets you express intent ahead of provisioning without
  # breaking the encrypt step.
  realKeys = builtins.filter
    (k: builtins.match ".*REPLACE_WITH.*" k == null);

  # allAccess: the shared base — recipients that should decrypt every
  # secret. Editor workstations and any host that should run `agenix -e`.
  example-host = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMWlfo53RiBjMA5oOH/617geQzieNm+IAb221SioIHcC";
  allAccess  = realKeys [ blushda pleiades ];

  # Per-secret access lists. Each is the COMPLETE recipient set for that
  # secret (allAccess + whoever else needs it), so the publicKeys line
  # below is just `= <name>Access;`. Reading the variable definition
  # answers "who can decrypt this secret?" in one place.
  wifiAccess = allAccess ++ realKeys [ iris ];
in {
  "wifi-secrets.age".publicKeys = wifiAccess;
}
