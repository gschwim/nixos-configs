# =============================================================================
# agenix recipient declarations.
#
# This file lists who can decrypt each *.age file in this directory.
# `agenix` reads it (from the cwd) to know what keys to encrypt to.
# ALL `agenix` commands below must be run from THIS directory (secrets/).
# =============================================================================
#
# FIRST-TIME SETUP (do this once, on your Mac):
# ---------------------------------------------
#
#   1. Generate your editor age keypair (if you don't already have one):
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
#      Save & exit. agenix encrypts to everyone listed in publicKeys below
#      (right now: just blushda). Commit the resulting encrypted blob.
#
# ADDING A NEW HOST (do this once per host, after its first boot):
# ----------------------------------------------------------------
#
#   1. SSH to the host (or run on it directly) and grab its pubkey:
#
#        cat /etc/ssh/ssh_host_ed25519_key.pub
#
#      Copy the full "ssh-ed25519 AAAA... root@hostname" line.
#
#   2. Back on blushda, paste it as the value of that host's variable below
#      (replacing the placeholder string).
#
#   3. Add the host's variable to the publicKeys list of every secret it
#      needs to decrypt. E.g. for pleades to read wifi-secrets:
#        "wifi-secrets.age".publicKeys = editors ++ [ pleades ];
#
#   4. Re-encrypt all secrets in this directory to the new recipient list:
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
# - agenix only looks at SSH keys (~/.ssh/id_*) by default. Our editor
#   identity is an age key at ~/.config/sops/age/keys.txt, so every agenix
#   invocation needs `-i ~/.config/sops/age/keys.txt`. Without it you get:
#     age: error: no identity matched any of the recipients
# - agenix MUST be invoked from the directory containing secrets.nix.
# - If a file in publicKeys list is a placeholder/invalid key, agenix's save
#   step fails (malformed SSH recipient / failed to read header). Only put
#   REAL keys into publicKeys; keep placeholders out of the list until the
#   host actually exists.
# - `agenix -e` on a 0-byte file fails with "failed to read intro: EOF".
#   Delete the file first if you see this; agenix will create it fresh.
# =============================================================================

let
  # ---- Editor identities (workstations where secrets get authored) ----------
  blushda = "age1gumg838j0s9fpmly4umss05e994dh7zgq6j94fyx8tel9v6nqansn8aq9p";

  # ---- Host identities (each host's SSH host pubkey, post-install) ---------
  # Placeholders below — replace AFTER each host's first boot, then add the
  # variable to the publicKeys list of the secrets that host needs.
  pleades = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOoCf/2e719Y8SzpIc4clVYtde8HEeq+3oLIbtkWDkJ2";
  iris    = "ssh-ed25519 AAAA_REPLACE_WITH_IRIS_HOST_PUBKEY";

  editors = [ blushda pleades ];
in {
  # During bootstrap, only blushda (the editor) can decrypt.
  # Once pleades has a real key above, change to:
  #   "wifi-secrets.age".publicKeys = editors ++ [ pleades ];
  "wifi-secrets.age".publicKeys = editors;
}
