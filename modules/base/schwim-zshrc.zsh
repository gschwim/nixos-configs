# Default ~/.zshrc — staged by NixOS modules/base/default.nix via
# systemd-tmpfiles. home-manager intentionally overwrites this file on
# first `home-manager switch`.

# Lines configured by zsh-newuser-install
HISTFILE=~/.histfile
HISTSIZE=1000
SAVEHIST=1000
bindkey -e
# End of lines configured by zsh-newuser-install
# The following lines were added by compinstall
zstyle :compinstall filename '~/.zshrc'

autoload -Uz compinit
compinit
# End of lines added by compinstall

# ── First-login bootstrap ─────────────────────────────────────────────
# On interactive login shells, offer to clone the fleet repos under
# ~/src/. If declined, asks again on the next login. Once repos are
# present, prints the home-manager bootstrap hint instead. Running
# `nix run .#homectl -- switch` activates HM, which overwrites this file.

if [[ -o login ]] && [[ -t 0 ]]; then
  __src=$HOME/src
  __repos=(nix-home-manager nixos-configs)
  __missing=()
  for r in $__repos; do
    [[ -d "$__src/$r" ]] || __missing+=($r)
  done

  if (( ${#__missing} > 0 )); then
    print
    print "Fleet repos missing in $__src/: ${__missing[*]}"
    print -n "Clone now from github.com/gschwim/? [Y/n] "
    if read __ans; then
      if [[ -z "$__ans" || "$__ans" == [Yy]* ]]; then
        mkdir -p "$__src"
        for r in $__missing; do
          if ! git -C "$__src" clone "https://github.com/gschwim/$r.git"; then
            print "  clone of $r failed; will ask again next login"
          fi
        done
        print
        print "Next, bootstrap home-manager:"
        print "  cd ~/src/nix-home-manager/manager && nix run .#homectl -- switch"
        print "  then open a new zsh shell to pick up the changes."
        print
      else
        print "Skipped. Will ask again next login."
      fi
    fi
  elif [[ ! -e "$HOME/.local/state/nix/profiles/home-manager" ]]; then
    print
    print "Repos present; home-manager not yet set up:"
    print "  cd ~/src/nix-home-manager/manager && nix run .#homectl -- switch"
    print "  then open a new zsh shell to pick up the changes."
    print
  fi

  unset __src __repos __missing __ans r
fi
