#!/usr/bin/env bash
# rekey-shared.sh — re-encrypt the SHARED agenix secrets to the current
# recipient set declared in secrets/secrets.nix.
#
# WHY THIS EXISTS (and why plain `agenix -r` does not work here):
#   `agenix -r` rekeys EVERY secret, which means it must first decrypt each one.
#   Per-host secrets (host-keys/*, users/*) are encrypted ONLY to their host —
#   your authoring key is not a recipient — so `agenix -r` dies on the first one
#   with "no identity matched any of the recipients". Those per-host blobs are
#   never rekeyed anyway; they're regenerated fresh by gen-host-key.sh /
#   provision-user-key.sh. This script rekeys exactly the subset you CAN decrypt
#   (today: wifi-secrets.age) — the shared secrets — and skips the rest.
#
# WHEN TO RUN:
#   After adding a host to a shared access list in secrets.nix (e.g. wifiAccess),
#   so the secret gets re-encrypted to include that host's key. install-host.sh
#   detects this case and runs this script for you.
#
# Usage:
#   scripts/rekey-shared.sh           # rekey every shared secret to current recipients
#   scripts/rekey-shared.sh --check   # list which secrets are shared; change nothing
#
# Auth: uses your authoring age identity at
#   $AGENIX_IDENTITY (default ~/.config/sops/age/keys.txt).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS_DIR="$REPO_ROOT/secrets"
AGE_IDENTITY="${AGENIX_IDENTITY:-$HOME/.config/sops/age/keys.txt}"

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

[ -f "$SECRETS_DIR/secrets.nix" ] || { echo "ERROR: $SECRETS_DIR/secrets.nix not found" >&2; exit 2; }
[ -f "$AGE_IDENTITY" ] || { echo "ERROR: age identity not found at $AGE_IDENTITY (set AGENIX_IDENTITY)" >&2; exit 2; }

agenix() { nix --extra-experimental-features 'nix-command flakes' run github:ryantm/agenix -- "$@"; }

# agenix must run from the directory holding secrets.nix.
cd "$SECRETS_DIR"

# Discover the shared secrets: those our authoring identity can decrypt. The
# per-host blobs fail this test (we aren't a recipient) and are skipped.
shared=()
while IFS= read -r f; do
  if agenix -i "$AGE_IDENTITY" -d "$f" >/dev/null 2>&1; then
    shared+=("$f")
  fi
done < <(find . -name '*.age' -type f | sed 's#^\./##' | sort)

if [ "${#shared[@]}" -eq 0 ]; then
  echo "No shared (operator-decryptable) secrets found — nothing to rekey."
  exit 0
fi

if [ "$CHECK" -eq 1 ]; then
  echo "Shared (rekeyable) secrets:"
  printf '  %s\n' "${shared[@]}"
  exit 0
fi

# EDITOR=true => a no-op "edit": agenix decrypts, runs `true` (changes nothing),
# then re-encrypts the unchanged plaintext to the CURRENT recipients in
# secrets.nix. age ciphertext is non-deterministic, so each file will show a git
# diff even when only the recipient set changed — that's expected; commit them.
for f in "${shared[@]}"; do
  echo "rekeying $f"
  EDITOR=true agenix -i "$AGE_IDENTITY" -e "$f"
done

echo
echo "Rekeyed ${#shared[@]} shared secret(s). Review + commit:"
echo "  git -C \"$REPO_ROOT\" diff --stat -- secrets/"
