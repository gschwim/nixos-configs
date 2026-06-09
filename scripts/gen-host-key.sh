#!/usr/bin/env bash
# gen-host-key.sh — single entry point for the full host-identity bootstrap.
#
# Per <host>, this script makes the following exist (idempotent across runs):
#
#   ~/.local/share/nixos-configs/host-bootstrap-keys/<host>.key
#       Per-host age priv. kdbx-backed at ssh-host-bootstrap-keys/<host>.
#       Becomes /etc/age/host.key on the target via install-host.sh
#       extra-files staging.
#
#   ~/.local/share/nixos-configs/host-keys/<host>_ed25519{,.pub,-cert.pub}
#       SSH host keypair + cert. kdbx-backed at ssh-host-keys/<host> (priv,
#       pub, cert as three attachments).
#
#   secrets/secrets.nix
#       <host> identity line set to the bootstrap age pubkey (was the SSH
#       host pubkey before this change).
#
#   secrets/host-keys/<host>_ssh_host_ed25519_key.age   (in the repo)
#       SSH host priv, agenix-encrypted to the host's bootstrap age key.
#       Must be declared in secrets/secrets.nix beforehand:
#         "host-keys/<host>_ssh_host_ed25519_key.age".publicKeys =
#             realKeys [ <host> ];
#       The script bails clearly if the declaration is missing.
#
#   lib/host-certs/<host>_ssh_host_ed25519_key{,.pub,-cert.pub}        (in the repo)
#       SSH host pub + cert, committed plaintext (they're public).
#
# kdbx is the canonical store for the bootstrap age key, the SSH host
# keypair, and the cert; the local cache on blushda is a working copy.
#
# keepassxc-cli requirement: 2.7.7 or newer. 2.7.6 silently dropped the
# second back-to-back attachment-import. Verify with `keepassxc-cli --version`.
#
# Usage:
#   scripts/gen-host-key.sh <hostname> [extra-principals]
#     extra-principals: comma-separated; hostname is always included first.
#                       Pass the host's static IP so SSH-by-IP works
#                       (OpenSSH 9.x+ requires principal match).
#
# Env (defaults usually fine):
#   KDBX_FILE  path to the .kdbx
#              default: $HOME/7e7 Dropbox/Greg Schwimer/Personal/keys/secrets.kdbx
#   KDBX_PW    kdbx unlock password. If unset, prompts once and exports.

set -euo pipefail

[ "$#" -ge 1 ] && [ "$#" -le 2 ] \
  || { echo "usage: $0 <hostname> [extra-principals]" >&2; exit 1; }

HOSTNAME="$1"
EXTRA_PRINCIPALS="${2:-}"
if [ -n "$EXTRA_PRINCIPALS" ]; then
  PRINCIPALS="${HOSTNAME},${EXTRA_PRINCIPALS}"
else
  PRINCIPALS="$HOSTNAME"
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Cache paths.
BOOT_CACHE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nixos-configs/host-bootstrap-keys"
BOOT_KEY="$BOOT_CACHE_DIR/${HOSTNAME}.key"

KEY_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nixos-configs/host-keys"
KEY="$KEY_DIR/${HOSTNAME}_ed25519"
CERT="${KEY}-cert.pub"

# Repo paths.
LIB_PUB="$REPO_ROOT/lib/host-certs/${HOSTNAME}_ssh_host_ed25519_key.pub"
LIB_CERT="$REPO_ROOT/lib/host-certs/${HOSTNAME}_ssh_host_ed25519_key-cert.pub"
SECRETS_PRIV_REL="host-keys/${HOSTNAME}_ssh_host_ed25519_key.age"     # relative to secrets/
SECRETS_PRIV_ABS="$REPO_ROOT/secrets/$SECRETS_PRIV_REL"
SECRETS_FILE="$REPO_ROOT/secrets/secrets.nix"

# kdbx entries.
KDBX_FILE="${KDBX_FILE:-$HOME/7e7 Dropbox/Greg Schwimer/Personal/keys/secrets.kdbx}"
KDBX_BOOT_ENTRY="ssh-host-bootstrap-keys/$HOSTNAME"
KDBX_KEY_ENTRY="ssh-host-keys/$HOSTNAME"
KDBX_CA_ENTRY="SSH CA/SSH Host CA"

# age identity for re-encrypting (workstation authoring key).
AGE_IDENTITY="$HOME/.config/sops/age/keys.txt"

die() { echo "ERROR: $*" >&2; exit 1; }
rel() { echo "${1#$REPO_ROOT/}"; }

# ----- preflight ----------------------------------------------------------

command -v keepassxc-cli >/dev/null \
  || die "keepassxc-cli not on PATH (macOS: brew install keepassxc)"
command -v ssh-keygen >/dev/null \
  || die "ssh-keygen not on PATH"

# age-keygen: direct if on PATH, otherwise run via `nix shell nixpkgs#age`.
# This lets the script run without a permanent age install on blushda —
# nix is already a hard dependency of the rest of the workflow.
if command -v age-keygen >/dev/null; then
  age_keygen() { age-keygen "$@"; }
else
  command -v nix >/dev/null \
    || die "neither age-keygen nor nix on PATH; one of them is needed"
  age_keygen() {
    nix --extra-experimental-features 'nix-command flakes' \
        shell nixpkgs#age --command age-keygen "$@"
  }
fi
[ -r "$KDBX_FILE" ] || die "kdbx file not readable: $KDBX_FILE"
[ -f "$AGE_IDENTITY" ] || die "no age authoring identity at $AGE_IDENTITY"

if [ -z "${KDBX_PW:-}" ]; then
  printf 'kdbx password: '; stty -echo; IFS= read -r KDBX_PW; stty echo; echo
  export KDBX_PW
fi

# Helper: pipe kdbx password to keepassxc-cli.
kpx() { printf '%s\n' "$KDBX_PW" | keepassxc-cli "$@"; }

# Helper: ensure the parent group of a kdbx entry path exists. kpx add
# doesn't auto-create groups, so a fresh kdbx (or a host-class slot we've
# never used before — e.g. ssh-host-bootstrap-keys/) needs the group
# materialized first.
kpx_ensure_parent_group() {
  local entry_path="$1"
  local parent="${entry_path%/*}"
  [ "$parent" = "$entry_path" ] && return 0   # no slash, nothing to create
  if ! kpx ls --quiet "$KDBX_FILE" "$parent" >/dev/null 2>&1; then
    kpx mkdir --quiet "$KDBX_FILE" "$parent" >/dev/null \
      || die "failed to create kdbx group '$parent'"
  fi
}

# Validate password works.
kpx ls --quiet "$KDBX_FILE" / >/dev/null 2>&1 \
  || die "kdbx unlock failed (wrong password? bad file?)"

# Helper: insert/replace a host's identity in secrets/secrets.nix.
# Pattern is unchanged; the *value* is what's changing (was an ssh-ed25519
# pubkey, now an age1… pubkey). awk treats the value as opaque.
modify_secrets_nix() {
  local host="$1" pubkey="$2" file="$3"
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
    die "couldn't find an insertion point in $file (expected a '<name>Access =' line)"
  fi
  mv "$tmp" "$file"
}

mkdir -p "$BOOT_CACHE_DIR" "$KEY_DIR" \
         "$REPO_ROOT/lib/host-certs" "$REPO_ROOT/secrets/host-keys"
chmod 700 "$BOOT_CACHE_DIR" "$KEY_DIR"

# ======================================================================
# Phase 0 — Bootstrap age key
# ======================================================================
#
# Ensures the per-host age keypair exists in the cache and kdbx, and that
# the corresponding pubkey is the <host> identity in secrets/secrets.nix.
# The pub is needed BEFORE Phase 4 (agenix encryption) because
# secrets.nix's recipient resolution reads it.

if kpx show --quiet "$KDBX_FILE" "$KDBX_BOOT_ENTRY" >/dev/null 2>&1; then
  echo "Pulling $KDBX_BOOT_ENTRY from keepassxc → $BOOT_KEY"
  # Pre-create the destination at mode 600 so keepassxc-cli's write
  # inherits our perms (it creates 644 by default).
  ( umask 077 && : > "$BOOT_KEY" )
  kpx attachment-export --quiet "$KDBX_FILE" "$KDBX_BOOT_ENTRY" \
      host_bootstrap_age.key "$BOOT_KEY" >/dev/null \
    || die "failed to export bootstrap age key attachment"
  chmod 600 "$BOOT_KEY"
else
  echo "No keepassxc entry $KDBX_BOOT_ENTRY — generating fresh age keypair"
  rm -f "$BOOT_KEY"
  age_keygen -o "$BOOT_KEY" 2>/dev/null
  chmod 600 "$BOOT_KEY"
  echo "Pushing $KDBX_BOOT_ENTRY to keepassxc"
  kpx_ensure_parent_group "$KDBX_BOOT_ENTRY"
  kpx add --quiet --generate "$KDBX_FILE" "$KDBX_BOOT_ENTRY" >/dev/null \
    || die "failed to add entry $KDBX_BOOT_ENTRY to keepassxc"
  kpx attachment-import --quiet "$KDBX_FILE" "$KDBX_BOOT_ENTRY" \
      host_bootstrap_age.key "$BOOT_KEY" >/dev/null \
    || die "failed to import bootstrap age key attachment"
fi

# Derive the bootstrap age pubkey from the priv.
BOOT_PUB="$(age_keygen -y "$BOOT_KEY")"
case "$BOOT_PUB" in
  age1*) ;;
  *) die "unexpected age-keygen -y output: $BOOT_PUB" ;;
esac

# Reconcile <host> identity in secrets.nix with the bootstrap age pub.
SECRETS_HOST_VAL=$(
  sed -n "s/^[[:space:]]*${HOSTNAME}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
      "$SECRETS_FILE" || true
)
if [ -z "$SECRETS_HOST_VAL" ]; then
  modify_secrets_nix "$HOSTNAME" "$BOOT_PUB" "$SECRETS_FILE"
  echo "Inserted '$HOSTNAME = \"$BOOT_PUB\"' into secrets/secrets.nix"
elif [[ "$SECRETS_HOST_VAL" == *REPLACE_WITH* ]] \
     || [[ "$SECRETS_HOST_VAL" == ssh-* ]] \
     || [ "$SECRETS_HOST_VAL" != "$BOOT_PUB" ]; then
  modify_secrets_nix "$HOSTNAME" "$BOOT_PUB" "$SECRETS_FILE"
  echo "Updated '$HOSTNAME' identity in secrets/secrets.nix (now age pubkey)"
else
  echo "secrets.nix '$HOSTNAME' identity already matches bootstrap age pub"
fi

# Precondition for Phase 4: the per-host host-key .age recipient list must
# already be declared. We DON'T auto-edit this — it's a structural choice
# the user makes once per host.
grep -q "\"$SECRETS_PRIV_REL\"" "$SECRETS_FILE" \
  || die "secrets/secrets.nix doesn't declare \"$SECRETS_PRIV_REL\" — add a line like:
       \"$SECRETS_PRIV_REL\".publicKeys = realKeys [ $HOSTNAME ];
     in the 'in { … }' block, then re-run."

# ======================================================================
# Phase 1 — SSH host keypair
# ======================================================================

if kpx show --quiet "$KDBX_FILE" "$KDBX_KEY_ENTRY" >/dev/null 2>&1; then
  echo "Pulling $KDBX_KEY_ENTRY from keepassxc → $KEY"
  tmp_priv="$(mktemp)"
  tmp_pub="$(mktemp)"
  trap 'rm -f "$tmp_priv" "$tmp_pub"' EXIT
  kpx attachment-export --quiet "$KDBX_FILE" "$KDBX_KEY_ENTRY" \
      ssh_host_ed25519_key     "$tmp_priv" >/dev/null \
    || die "failed to export ssh_host_ed25519_key attachment"
  kpx attachment-export --quiet "$KDBX_FILE" "$KDBX_KEY_ENTRY" \
      ssh_host_ed25519_key.pub "$tmp_pub"  >/dev/null \
    || die "failed to export ssh_host_ed25519_key.pub attachment"
  install -m 600 "$tmp_priv" "$KEY"
  install -m 644 "$tmp_pub"  "${KEY}.pub"
  rm -f "$tmp_priv" "$tmp_pub"
  trap - EXIT
else
  echo "No keepassxc entry $KDBX_KEY_ENTRY — generating fresh ed25519 SSH keypair"
  rm -f "$KEY" "${KEY}.pub"
  ssh-keygen -t ed25519 -N "" -f "$KEY" \
    -C "ssh_host_ed25519_key@$HOSTNAME" >/dev/null
  echo "Pushing $KDBX_KEY_ENTRY to keepassxc"
  kpx_ensure_parent_group "$KDBX_KEY_ENTRY"
  kpx add --quiet --generate "$KDBX_FILE" "$KDBX_KEY_ENTRY" >/dev/null \
    || die "failed to add entry $KDBX_KEY_ENTRY to keepassxc"
  kpx attachment-import --quiet "$KDBX_FILE" "$KDBX_KEY_ENTRY" \
      ssh_host_ed25519_key     "$KEY"        >/dev/null \
    || die "failed to import ssh_host_ed25519_key attachment"
  kpx attachment-import --quiet "$KDBX_FILE" "$KDBX_KEY_ENTRY" \
      ssh_host_ed25519_key.pub "${KEY}.pub"  >/dev/null \
    || die "failed to import ssh_host_ed25519_key.pub attachment"
fi

# ======================================================================
# Phase 2 — SSH host certificate
# ======================================================================

if kpx attachment-export --quiet "$KDBX_FILE" "$KDBX_KEY_ENTRY" \
       ssh_host_ed25519_key-cert.pub "$CERT" 2>/dev/null; then
  chmod 644 "$CERT"
  echo "Pulled cert from $KDBX_KEY_ENTRY → $CERT"

  # If the user passed extra principals, sanity-check that the cached cert
  # already matches. Re-signing is an explicit operation: delete the cert
  # attachment from kdbx + the local cache, then re-run.
  CERT_PRINCIPALS=$(ssh-keygen -L -f "$CERT" \
                    | awk '/Principals:/{flag=1; sub(/.*Principals:/,""); print; flag=0; exit}' \
                    | tr -d ' ' | tr '\n' ',' | sed 's/,$//')
  if [ -n "$EXTRA_PRINCIPALS" ] && [ "$CERT_PRINCIPALS" != "$PRINCIPALS" ]; then
    echo
    echo "WARNING: cached cert principals ($CERT_PRINCIPALS) differ from requested ($PRINCIPALS)."
    echo "         To re-sign with new principals: delete the cert attachment from kdbx"
    echo "         (attachment ssh_host_ed25519_key-cert.pub on entry $KDBX_KEY_ENTRY)"
    echo "         and remove $CERT, then re-run."
  fi
else
  echo "No cert on $KDBX_KEY_ENTRY — signing host pubkey with CA, principals: $PRINCIPALS"
  tmp_ca="$(mktemp)"
  ( umask 077 && : > "$tmp_ca" )
  trap 'rm -f "$tmp_ca"' EXIT INT TERM

  kpx attachment-export --quiet "$KDBX_FILE" "$KDBX_CA_ENTRY" \
      host_ca "$tmp_ca" >/dev/null \
    || die "couldn't export 'host_ca' attachment from '$KDBX_CA_ENTRY'"
  chmod 600 "$tmp_ca"

  # -h: host cert. -I: label. -V: validity. -n: principals (OpenSSH 9.x+
  # requires non-empty list for host certs; "no principals = any host" was
  # deprecated). Pass IP as extra-principals when calling this script so
  # SSH-by-IP works.
  ssh-keygen -s "$tmp_ca" -h -I "$HOSTNAME" -n "$PRINCIPALS" \
             -V "always:forever" "${KEY}.pub" >/dev/null \
    || die "ssh-keygen cert signing failed"

  rm -f "$tmp_ca"
  trap - EXIT INT TERM

  echo "Pushing cert to keepassxc as attachment on $KDBX_KEY_ENTRY"
  kpx attachment-import --quiet "$KDBX_FILE" "$KDBX_KEY_ENTRY" \
      ssh_host_ed25519_key-cert.pub "$CERT" >/dev/null \
    || die "failed to import cert attachment"
fi

# ======================================================================
# Phase 3 — Write declarative repo artifacts
# ======================================================================

# Pub + cert: plaintext, committed.
install -m 644 "${KEY}.pub" "$LIB_PUB"
install -m 644 "$CERT"      "$LIB_CERT"

# Priv: agenix-encrypted to the host's bootstrap age pub (declared in
# secrets/secrets.nix's recipient list). Uses EDITOR="cp <src>" so agenix
# opens its tempfile via cp, which overwrites with our SSH priv content.
echo "agenix-encrypting SSH host priv → $(rel "$SECRETS_PRIV_ABS")"
cd "$REPO_ROOT/secrets"
EDITOR="cp $KEY" \
  nix --extra-experimental-features 'nix-command flakes' \
      run github:ryantm/agenix -- \
        -i "$AGE_IDENTITY" \
        -e "$SECRETS_PRIV_REL" >/dev/null \
  || die "agenix encrypt failed (does the recipient list resolve to a real key?)"
cd - >/dev/null

# ======================================================================
# Phase 4 — Report
# ======================================================================

echo
echo "Bootstrap age pub: $BOOT_PUB"
echo
echo "SSH host pub:"
cat "${KEY}.pub"
echo
echo "Certificate (ssh-keygen -L):"
ssh-keygen -L -f "$CERT" | sed -E 's/^/  /'
echo
echo "Repo artifacts ready:"
echo "  $(rel "$LIB_PUB")"
echo "  $(rel "$LIB_CERT")"
echo "  $(rel "$SECRETS_PRIV_ABS")"
echo
echo "Next: git add -A && git commit -m '$HOSTNAME: refresh host identity' && git push"
