#!/usr/bin/env bash
# gen-host-key.sh — ensure an ed25519 SSH host key for <hostname> exists,
# using keepassxc as the canonical store and ~/.local/share/... as a cache.
#
# Behavior:
#   1. Look up keepassxc entry "ssh-host-keys/<hostname>".
#   2. If present : export both attachments into the local cache.
#      If absent  : ssh-keygen a new key, push to keepassxc, write the cache.
#   3. Reconcile with secrets/secrets.nix:
#        no <hostname> entry            → insert one (before `editors =`)
#        placeholder (REPLACE_WITH_…)   → replace with real pubkey
#        real entry matches cache       → no-op
#        real entry differs from cache  → hard fail
#
# keepassxc-cli requirement: 2.7.7 or newer. 2.7.6 silently dropped the
# second back-to-back attachment-import (private landed, .pub didn't,
# exit code 0). Verify with `keepassxc-cli --version` before running.
#
# Re-running for an existing host is safe and idempotent — same pubkey
# every time, which is the whole point of caching to keepassxc.
#
# Usage:
#   scripts/gen-host-key.sh <hostname>
#
# Env vars (both have sane defaults — typically you set neither):
#   KDBX_FILE  path to the .kdbx
#              default: $HOME/7e7 Dropbox/Greg Schwimer/Personal/keys/secrets.kdbx
#   KDBX_PW    kdbx unlock password. If unset, prompts once and exports
#              so child scripts in the same shell reuse it.

set -euo pipefail

[ "$#" -eq 1 ] || { echo "usage: $0 <hostname>" >&2; exit 1; }

HOSTNAME="$1"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nixos-configs/host-keys"
KEY="$KEY_DIR/${HOSTNAME}_ed25519"
KDBX_FILE="${KDBX_FILE:-$HOME/7e7 Dropbox/Greg Schwimer/Personal/keys/secrets.kdbx}"
KDBX_ENTRY="ssh-host-keys/$HOSTNAME"

die() { echo "ERROR: $*" >&2; exit 1; }

command -v keepassxc-cli >/dev/null \
  || die "keepassxc-cli not on PATH (macOS: brew install keepassxc)"
[ -r "$KDBX_FILE" ] || die "kdbx file not readable: $KDBX_FILE"

# Prompt once per shell, export so subsequent script invocations reuse it.
if [ -z "${KDBX_PW:-}" ]; then
  read -rsp "kdbx password: " KDBX_PW
  echo
  export KDBX_PW
fi

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

# Helper: pipe the kdbx password to a keepassxc-cli invocation.
kpx() { printf '%s\n' "$KDBX_PW" | keepassxc-cli "$@"; }

# Helper: insert/replace a host's pubkey in secrets/secrets.nix.
# Idempotent: re-running with the same value produces no further change.
# Replaces an existing entry line (real or placeholder) in place; otherwise
# inserts a new entry before the first `<name>Access =` line — the convention
# established in secrets.nix for access-list declarations. Aborts if no
# insertion anchor exists (i.e. secrets.nix has been restructured in a way
# the script can't reason about).
modify_secrets_nix() {
  local host="$1" pubkey="$2"
  local file="$3"
  local tmp="${file}.tmp.$$"

  if ! awk -v host="$host" -v key="$pubkey" '
    BEGIN { handled = 0 }
    $0 ~ "^[[:space:]]*" host "[[:space:]]*=" {
      printf "  %s = \"%s\";\n", host, key
      handled = 1
      next
    }
    $0 ~ "^[[:space:]]*[a-zA-Z][a-zA-Z0-9_]*Access[[:space:]]*=" && !handled {
      printf "  %s = \"%s\";\n", host, key
      handled = 1
    }
    { print }
    END { exit (handled ? 0 : 2) }
  ' "$file" > "$tmp"; then
    rm -f "$tmp"
    die "couldn'\''t find an insertion point in $file (expected a '<name>Access =' line)"
  fi

  mv "$tmp" "$file"
}

# 1) Validate password against the DB (any successful ls works).
kpx ls --quiet "$KDBX_FILE" / >/dev/null 2>&1 \
  || die "kdbx unlock failed (wrong password? bad file?)"

# 2) Pull or generate.
if kpx show --quiet "$KDBX_FILE" "$KDBX_ENTRY" >/dev/null 2>&1; then
  echo "Pulling $KDBX_ENTRY from keepassxc → $KEY"
  tmp_priv="$(mktemp)"
  tmp_pub="$(mktemp)"
  trap 'rm -f "$tmp_priv" "$tmp_pub"' EXIT
  kpx attachment-export --quiet "$KDBX_FILE" "$KDBX_ENTRY" \
      ssh_host_ed25519_key     "$tmp_priv" >/dev/null \
    || die "failed to export private attachment"
  kpx attachment-export --quiet "$KDBX_FILE" "$KDBX_ENTRY" \
      ssh_host_ed25519_key.pub "$tmp_pub"  >/dev/null \
    || die "failed to export public attachment"
  install -m 600 "$tmp_priv" "$KEY"
  install -m 644 "$tmp_pub"  "${KEY}.pub"
else
  echo "No keepassxc entry $KDBX_ENTRY — generating fresh ed25519 key"
  # Clear any stale cache from a previous failed run; if we're in this
  # branch the keepassxc side has no entry, so any local file is orphaned.
  # Without the rm, ssh-keygen prompts "Overwrite (y/n)?" — and with stdout
  # redirected to /dev/null below, that prompt is invisible and the script
  # silently exits via set -e when ssh-keygen returns non-zero.
  rm -f "$KEY" "${KEY}.pub"
  ssh-keygen -t ed25519 -N "" -f "$KEY" \
    -C "ssh_host_ed25519_key@$HOSTNAME" >/dev/null
  echo "Pushing $KDBX_ENTRY to keepassxc"
  # `--generate` fills the (unused) password field with a random value.
  kpx add --quiet --generate "$KDBX_FILE" "$KDBX_ENTRY" >/dev/null \
    || die "failed to add entry $KDBX_ENTRY to keepassxc"
  kpx attachment-import --quiet "$KDBX_FILE" "$KDBX_ENTRY" \
      ssh_host_ed25519_key     "$KEY"        >/dev/null \
    || die "failed to import private attachment"
  kpx attachment-import --quiet "$KDBX_FILE" "$KDBX_ENTRY" \
      ssh_host_ed25519_key.pub "${KEY}.pub"  >/dev/null \
    || die "failed to import public attachment"
fi

# 2b) Pull or sign the host certificate.
# Cert lives as a third attachment on the host's keepassxc entry. If absent,
# we pull the CA private key from "SSH CA/SSH Host CA" (attachment host_ca),
# sign, push the cert back, and shred the CA copy from disk. Re-runs that
# find the cert attachment just pull it — idempotent.

# The key block above only sets a temp-file trap inside its pull branch;
# clear any residual trap before our own setup. tmp_priv/tmp_pub were
# install(1)-copied to $KEY earlier, so the source temps are now orphaned —
# rm them explicitly (no-op if they don't exist).
rm -f "${tmp_priv:-}" "${tmp_pub:-}"
trap - EXIT

CERT="${KEY}-cert.pub"

if kpx attachment-export --quiet "$KDBX_FILE" "$KDBX_ENTRY" \
       ssh_host_ed25519_key-cert.pub "$CERT" 2>/dev/null; then
  chmod 644 "$CERT"
  echo "Pulled cert from $KDBX_ENTRY → $CERT"
else
  echo "No cert on $KDBX_ENTRY — signing host pubkey with CA"
  tmp_ca="$(mktemp)"
  chmod 600 "$tmp_ca"
  trap 'rm -f "$tmp_ca"' EXIT INT TERM

  kpx attachment-export --quiet "$KDBX_FILE" "SSH CA/SSH Host CA" \
      host_ca "$tmp_ca" >/dev/null \
    || die "couldn't export 'host_ca' attachment from 'SSH CA/SSH Host CA'"

  # -h: this is a HOST certificate (not a user cert).
  # -I: cert identity — a label shown by `ssh-keygen -L` and in sshd logs,
  #     no role in validation.
  # -V always:forever: never expires (OpenSSH 8.2+).
  # No -n principals. Empty principal list means the cert is valid for any
  # host the @cert-authority pattern in known_hosts trusts. We need this
  # because principals would otherwise have to include every hostname / IP
  # a client might reach the host on (LAN, VPN, DHCP-assigned IP, etc.),
  # which is unworkable. The trust boundary is "signed by our CA"; see the
  # README "SSH host certificates" section for the rationale.
  ssh-keygen -s "$tmp_ca" -h -I "$HOSTNAME" \
             -V "always:forever" "${KEY}.pub" >/dev/null \
    || die "ssh-keygen cert signing failed"

  # CA private off disk ASAP. The trap is belt-and-suspenders for any abort
  # between here and rm.
  rm -f "$tmp_ca"
  trap - EXIT INT TERM

  echo "Pushing $CERT to keepassxc as attachment on $KDBX_ENTRY"
  kpx attachment-import --quiet "$KDBX_FILE" "$KDBX_ENTRY" \
      ssh_host_ed25519_key-cert.pub "$CERT" >/dev/null \
    || die "failed to import cert attachment"
fi

# 3) Reconcile with secrets/secrets.nix.
# Compare only the key type + data, not the comment field (those differ
# between the ssh-keygen comment and whatever's pasted into secrets.nix).
SECRETS_FILE="$REPO_ROOT/secrets/secrets.nix"
PUB_CACHE=$(awk '{print $1, $2}' "${KEY}.pub")
PUB_SECRETS_RAW=$(
  sed -n "s/^[[:space:]]*${HOSTNAME}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
      "$SECRETS_FILE" || true
)

if [ -z "$PUB_SECRETS_RAW" ]; then
  modify_secrets_nix "$HOSTNAME" "$PUB_CACHE" "$SECRETS_FILE"
  echo "Inserted '$HOSTNAME' into secrets/secrets.nix"
elif [[ "$PUB_SECRETS_RAW" == *REPLACE_WITH* ]]; then
  modify_secrets_nix "$HOSTNAME" "$PUB_CACHE" "$SECRETS_FILE"
  echo "Replaced placeholder for '$HOSTNAME' in secrets/secrets.nix"
else
  PUB_SECRETS=$(awk '{print $1, $2}' <<<"$PUB_SECRETS_RAW")
  if [ "$PUB_CACHE" != "$PUB_SECRETS" ]; then
    echo
    echo "ERROR: pubkey for '$HOSTNAME' differs between keepassxc and secrets.nix"
    echo "  keepassxc:   $PUB_CACHE"
    echo "  secrets.nix: $PUB_SECRETS"
    echo
    echo "One of them is stale. Resolve before continuing — DO NOT install a"
    echo "host whose pubkey doesn't match the recipient list it'll be installed"
    echo "with, or its agenix secrets won't decrypt on first boot."
    exit 1
  else
    echo "Pubkey matches secrets/secrets.nix entry for $HOSTNAME"
  fi
fi

echo
echo "Public key:"
cat "${KEY}.pub"
echo
echo "Certificate (ssh-keygen -L):"
ssh-keygen -L -f "$CERT" | sed -E 's/^/  /'
