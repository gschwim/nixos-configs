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
# On interactive login shells: offer to clone the fleet repos under ~/src/,
# then offer to bootstrap home-manager by running `nix run .#homectl -- switch`
# in ~/src/nix-home-manager/manager. Both prompts default to Yes and re-ask on
# the next login until done. The homectl run activates HM, which then overwrites
# this entire file (so this block only runs pre-HM).

if [[ -o login ]] && [[ -t 0 ]]; then
  __src=$HOME/src
  __repos=(nix-home-manager nixos-configs)
  __hm=$__src/nix-home-manager/manager
  __missing=()
  for r in $__repos; do
    [[ -d "$__src/$r" ]] || __missing+=($r)
  done

  # 1. Clone any missing fleet repos.
  if (( ${#__missing} > 0 )); then
    print
    print "Fleet repos missing in $__src/: ${__missing[*]}"
    print -n "Clone now from github.com/gschwim/? [Y/n] "
    if read __ans && [[ -z "$__ans" || "$__ans" == [Yy]* ]]; then
      mkdir -p "$__src"
      for r in $__missing; do
        git -C "$__src" clone "https://github.com/gschwim/$r.git" \
          || print "  clone of $r failed; will ask again next login"
      done
    else
      print "Skipped. Will ask again next login."
    fi
  fi

  # 2. Offer to bootstrap home-manager (once the repo is present and HM isn't
  #    set up yet). Actually runs it, rather than just printing the command.
  if [[ -d "$__hm" ]] && [[ ! -e "$HOME/.local/state/nix/profiles/home-manager" ]]; then
    print
    print -n "Bootstrap home-manager now (nix run .#homectl -- switch)? [Y/n] "
    if read __ans && [[ -z "$__ans" || "$__ans" == [Yy]* ]]; then
      if ( cd "$__hm" && nix run .#homectl -- switch ); then
        print
        print "home-manager activated. Open a new zsh shell to pick up the changes."
      else
        print "homectl switch failed; re-run later from $__hm"
      fi
    else
      print "Skipped. Run later:  cd $__hm && nix run .#homectl -- switch"
    fi
  fi

  unset __src __repos __hm __missing __ans r
fi
