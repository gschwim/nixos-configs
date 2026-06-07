#!/usr/bin/env bash
# trust-ssh-ca.sh — install an @cert-authority line into ~/.ssh/known_hosts so
# this workstation trusts any host signed by the SSH Host CA (stored in
# keepassxc at "SSH CA/SSH Host CA", attachment host_ca.pub).
#
# Run once on blushda after the host-cert workflow lands. Idempotent — re-runs
# detect the existing line and exit cleanly.
#
# Why pattern `*`:
#   The @cert-authority line's host-pattern is just a filter for "which
#   connections should I even check this CA against." The real trust boundary
#   is the cert's own principals, set at signing time by gen-host-key.sh.
#   Since this CA only ever signs hosts we control, `*` is safe and means
#   you never have to maintain a list of trusted hostnames here.
#
# Usage:
#   scripts/trust-ssh-ca.sh
#
# Env vars (same conventions as gen-host-key.sh):
#   KDBX_FILE  path to the .kdbx
#              default: $HOME/7e7 Dropbox/Greg Schwimer/Personal/keys/secrets.kdbx
#   KDBX_PW    kdbx unlock password. If unset, prompts and exports.

set -euo pipefail

KDBX_FILE="${KDBX_FILE:-$HOME/7e7 Dropbox/Greg Schwimer/Personal/keys/secrets.kdbx}"
KDBX_ENTRY="SSH CA/SSH Host CA"
KNOWN_HOSTS="${HOME}/.ssh/known_hosts"

die() { echo "ERROR: $*" >&2; exit 1; }

command -v keepassxc-cli >/dev/null \
  || die "keepassxc-cli not on PATH (macOS: brew install keepassxc)"
[ -r "$KDBX_FILE" ] || die "kdbx file not readable: $KDBX_FILE"

if [ -z "${KDBX_PW:-}" ]; then
  read -rsp "kdbx password: " KDBX_PW
  echo
  export KDBX_PW
fi

kpx() { printf '%s\n' "$KDBX_PW" | keepassxc-cli "$@"; }

# Sanity: password works against the DB.
kpx ls --quiet "$KDBX_FILE" / >/dev/null 2>&1 \
  || die "kdbx unlock failed (wrong password? bad file?)"

# Pull the CA pubkey to a temp file so we can read its raw contents.
tmp_pub="$(mktemp)"
trap 'rm -f "$tmp_pub"' EXIT INT TERM

kpx attachment-export --quiet "$KDBX_FILE" "$KDBX_ENTRY" \
    host_ca.pub "$tmp_pub" >/dev/null \
  || die "couldn't export 'host_ca.pub' from '$KDBX_ENTRY'"

CA_PUB="$(awk '{print $1, $2}' "$tmp_pub")"
[ -n "$CA_PUB" ] || die "host_ca.pub appears empty or malformed"

# Ensure ~/.ssh and known_hosts exist with sensible perms.
mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"
touch "$KNOWN_HOSTS"
chmod 600 "$KNOWN_HOSTS"

LINE="@cert-authority * ${CA_PUB}"

# Already present? Match on the key type + key data (ignore comment field and
# the * pattern, in case the user later edits the pattern).
if grep -qF "$CA_PUB" "$KNOWN_HOSTS"; then
  echo "@cert-authority already present in $KNOWN_HOSTS — no change."
  exit 0
fi

printf '%s\n' "$LINE" >> "$KNOWN_HOSTS"
echo "Added @cert-authority line to $KNOWN_HOSTS:"
echo "  $LINE"
