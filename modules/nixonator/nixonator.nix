# NOTE: Intentional `nixos-rebuild` name collision.
# This module defines a `nixos-rebuild` wrapper (via writeShellScriptBin) that
# shadows the stock NixOS binary. Which one actually wins depends on PATH
# resolution between this package and the `nixos` package's own `nixos-rebuild`.
# Do NOT assume this wrapper always comes first:
#   - If you observe plain NixOS rebuild behavior instead of Nixonator's output,
#     this wrapper is being shadowed by the real binary.
#   - Fix by raising this package's priority in environment.systemPackages
#     (e.g. `lib.setPrio 1 nixonatorScript` or `meta.priority`), or by invoking
#     the wrapper through an explicit PATH in your host configuration.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  nixonatorScript = pkgs.writeShellScriptBin "nixos-rebuild" ''  
    CONFIG_DIR="/etc/nixos"
    MODULES_DIR="$CONFIG_DIR/modules"
    cd "$CONFIG_DIR" || exit 1

    # ANSI Color Codes
    RED='\033[1;31m'
    GREEN='\033[1;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[1;34m'
    CYAN='\033[1;36m'
    RESET='\033[0m'

    info() { echo -e "''${BLUE}==>''${RESET} $1"; }
    success() { echo -e "''${GREEN}==>''${RESET} $1"; }
    warn() { echo -e "''${YELLOW}==> [Warning]''${RESET} $1"; }
    err() { echo -e "''${RED}==> [Error]''${RESET} $1"; }

    NIXONATOR_CONF="$MODULES_DIR/nixonator/nixonator.conf"

    if [ -f "$NIXONATOR_CONF" ]; then
      source "$NIXONATOR_CONF"
    else
      err "No nixonator.conf found in $MODULES_DIR/nixonator!"
      echo -e "Please run the installation setup script first:"
      echo -e "  sudo bash <(curl -sL https://raw.githubusercontent.com/usr40k/nixonator/refs/heads/main/install.sh)"
      exit 1
    fi

    # Defaults for options that may be missing from an older nixonator.conf,
    # so upgrading the module doesn't require regenerating the config file.
    : "''${PRE_INSTALL_SUMMARY:=true}"
    : "''${CONFIRM_UPDATE:=false}"
    : "''${PRETTY_GIT_SUMMARY:=true}"
    : "''${SHOW_GC_STATS:=true}"
    : "''${PROMPT_UNTRACKED:=ask}"

    HOSTNAME_VAL="$(hostname)"
    HOST_DIR="hosts/$HOSTNAME_VAL"
    HOST_LOCK="$HOST_DIR/flake.lock"
    mkdir -p "$HOST_DIR"

    if [ -n "$SUDO_USER" ]; then
      export USER="$SUDO_USER"
    else
      export USER="$(whoami)"
    fi

    eval SSH_KEY_EXPANDED="$SSH_KEY_PATH"
    if [ -f "$SSH_KEY_EXPANDED" ]; then
      export GIT_SSH_COMMAND="ssh -i $SSH_KEY_EXPANDED -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
    fi

    export GPG_TTY=$(tty)
    if command -v gpg-connect-agent >/dev/null 2>&1; then
      gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1 || true
    fi

    DO_GIT=true
    REBUILD_ARGS=()

    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        --no-git)
          DO_GIT=false
          shift
          ;;
        --upgrade)
          info "Updating flake inputs for ''${CYAN}$HOSTNAME_VAL''${RESET}..."
          if [ -f "$HOST_LOCK" ]; then
            cp "$HOST_LOCK" flake.lock
          elif [ -f "flake.lock" ]; then
            cp flake.lock "$HOST_LOCK"
          fi
          
          set +e
          ${pkgs.nix}/bin/nix flake update --log-format internal-json -v 2>&1 | ${pkgs.nix-output-monitor}/bin/nom --json
          UPDATE_EXIT=$?
          set -e
          
          if [ $UPDATE_EXIT -ne 0 ]; then
            err "Flake update failed!"
            rm -f flake.lock
            exit $UPDATE_EXIT
          fi
          
          cp flake.lock "$HOST_LOCK"
          success "Flake inputs successfully updated and locked for $HOSTNAME_VAL."
          exit 0
          ;;
        --nixonator-update)
          info "Self-updating Nixonator module from remote repository..."
          mkdir -p modules/nixonator
          if curl -sSL "https://raw.githubusercontent.com/usr40k/nixonator/main/modules/nixonator/nixonator.nix" -o modules/nixonator/nixonator.nix; then
            success "Successfully updated modules/nixonator/nixonator.nix"
          else
            err "Failed to fetch remote nixonator.nix"
            exit 1
          fi
          exit 0
          ;;
        --nuke)
          if [ "$2" = "CONFIRM" ]; then
            RECLONE=true
            for arg in "$@"; do
              if [ "$arg" = "--no-reclone" ]; then
                RECLONE=false
              fi
            done

            warn "Nuking configuration directory ($CONFIG_DIR)..."
            rm -rf .git hosts modules flake.nix flake.lock nixonator.conf 2>/dev/null || true

            if [ "$RECLONE" = true ]; then
              info "Re-cloning repository from $REPO_URL..."
              git clone "$REPO_URL" .
              success "Nuke complete! Please re-run your configuration setup."
            else
              info "Skipping re-clone (--no-reclone passed)."
              success "Nuke complete! $CONFIG_DIR is now empty."
            fi
            exit 0
          else
            err "Dangerous command! To confirm complete wipe and re-clone, run: sudo nixos-rebuild --nuke CONFIRM"
            err "By default this re-clones $REPO_URL afterward. To skip that, add --no-reclone."
            exit 1
          fi
          ;;
        *)
          REBUILD_ARGS+=("$1")
          shift
          ;;
      esac
    done

    if [ -f "$HOST_LOCK" ]; then
      cp "$HOST_LOCK" flake.lock
    elif [ -f "flake.lock" ]; then
      cp flake.lock "$HOST_LOCK"
    fi

    if [ "$DO_GIT" = true ]; then
      if [ ! -d ".git" ]; then
        git init
        git remote add origin "$REPO_URL"
        git branch -M "$GIT_BRANCH"
      fi

      if [ -n "$GIT_USER_NAME" ]; then
        git config user.name "$GIT_USER_NAME"
      fi
      if [ -n "$GIT_USER_EMAIL" ]; then
        git config user.email "$GIT_USER_EMAIL"
      fi
      if [ -n "$GPG_SIGNING_KEY" ]; then
        git config user.signingkey "$GPG_SIGNING_KEY"
        git config commit.gpgsign true
      fi

      STASHED=false
      if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        info "Stashing local uncommitted changes..."
        git stash push -m "Nixonator auto-stash: $(date)" >/dev/null 2>&1
        STASHED=true
      fi

      git fetch origin "$GIT_BRANCH" >/dev/null 2>&1 || true

      if git rev-parse --verify "origin/$GIT_BRANCH" >/dev/null 2>&1; then
        git merge "origin/$GIT_BRANCH" --no-edit >/dev/null 2>&1 || true
      fi

      if [ "$STASHED" = true ]; then
        git stash pop >/dev/null 2>&1 || true
      fi
    fi

    TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    PREV_PROFILE=$(readlink -f /nix/var/nix/profiles/system || true)
    PREV_GEN_INFO="$(${pkgs.nix}/bin/nix-env -p /nix/var/nix/profiles/system --list-generations | grep '(current)' || true)"

    if [ "$PRE_INSTALL_SUMMARY" = "true" ]; then
      echo -e "''${CYAN}────────────────────────────────────────────''${RESET}"
      echo -e "''${CYAN}Nixonator: pre-rebuild summary''${RESET}"
      echo -e "  Host:          $HOSTNAME_VAL"
      echo -e "  Branch:        $GIT_BRANCH"
      echo -e "  Flake target:  $CONFIG_DIR#$HOSTNAME_VAL"
      echo -e "  Extra args:    ''${REBUILD_ARGS[*]:-(none)}"
      if [ -d .git ]; then
        PENDING_COUNT="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
        echo -e "  Local changes: ''${PENDING_COUNT:-0} file(s) not yet committed"
        if [ "''${PENDING_COUNT:-0}" -gt 0 ]; then
          git status --short 2>/dev/null | sed 's/^/    /'
        fi
      fi
      echo -e "''${CYAN}────────────────────────────────────────────''${RESET}"
    fi

    if [ "$CONFIRM_UPDATE" = "true" ]; then
      read -p "$(echo -e "''${YELLOW}Proceed with rebuild? [y/N]: ''${RESET}")" CONFIRM_ANS </dev/tty || CONFIRM_ANS="n"
      case "$CONFIRM_ANS" in
        y|Y|yes|YES) ;;
        *)
          warn "Rebuild cancelled by user."
          exit 0
          ;;
      esac
    fi

    info "Starting NixOS rebuild for ''${CYAN}$HOSTNAME_VAL''${RESET}..."
    
    set +e
    ${pkgs.nixos-rebuild}/bin/nixos-rebuild "''${REBUILD_ARGS[@]}" --impure --flake "$CONFIG_DIR#$HOSTNAME_VAL" --log-format internal-json -v 2>&1 | ${pkgs.nix-output-monitor}/bin/nom --json
    REBUILD_EXIT=$?
    set -e

    if [ $REBUILD_EXIT -ne 0 ]; then
      err "NixOS rebuild failed! Changes will not be committed."
      rm -f flake.lock
      exit $REBUILD_EXIT
    fi

    if [ "$AUTO_GC" = "true" ]; then
      info "Running automatic garbage collection (removing generations older than $GC_DAYS days)..."
      sudo nix profile wipe-history --older-than "$GC_DAYS"d >/dev/null 2>&1 || true

      if [ "$SHOW_GC_STATS" = "true" ]; then
        GC_OUTPUT="$(nix-collect-garbage --delete-older-than "$GC_DAYS"d 2>&1 || true)"
        GC_STATS_LINE="$(echo "$GC_OUTPUT" | grep -Ei 'freed|store paths deleted' | tail -n 1)"
        echo -e "''${CYAN}────────────────────────────────────────────''${RESET}"
        echo -e "''${CYAN}Nixonator: garbage collection summary''${RESET}"
        if [ -n "$GC_STATS_LINE" ]; then
          echo -e "  ''${GREEN}$GC_STATS_LINE''${RESET}"
        else
          echo -e "  Nothing to collect (no generations older than $GC_DAYS days)."
        fi
        echo -e "''${CYAN}────────────────────────────────────────────''${RESET}"
      else
        nix-collect-garbage --delete-older-than "$GC_DAYS"d >/dev/null 2>&1 || true
      fi
    fi

    NEW_PROFILE=$(readlink -f /nix/var/nix/profiles/system || true)
    NEW_GEN_INFO="$(${pkgs.nix}/bin/nix-env -p /nix/var/nix/profiles/system --list-generations | grep '(current)' || true)"

    if [ -n "$PREV_PROFILE" ] && [ -n "$NEW_PROFILE" ] && [ "$PREV_PROFILE" != "$NEW_PROFILE" ]; then
      PACKAGE_DIFF="$(${pkgs.nvd}/bin/nvd diff "$PREV_PROFILE" "$NEW_PROFILE" 2>&1 || echo "Package diff failed")"
    else
      PACKAGE_DIFF="No package profile changes detected."
    fi

    if [ "$DO_GIT" = true ]; then
      rm -f flake.lock

      # Stage changes/deletions to files git already tracks.
      git add -u

      # Handle newly created (untracked) files according to PROMPT_UNTRACKED:
      #   ask    - prompt per file: [y]es/[n]o/[a]lways (persists "always" to nixonator.conf)
      #   always - stage every untracked file without prompting
      #   never  - leave untracked files untracked
      UNTRACKED_FILES="$(git ls-files --others --exclude-standard)"
      if [ -n "$UNTRACKED_FILES" ]; then
        case "$PROMPT_UNTRACKED" in
          never)
            info "Leaving $(echo "$UNTRACKED_FILES" | wc -l | tr -d ' ') untracked file(s) untracked (PROMPT_UNTRACKED=never)."
            ;;
          always)
            while IFS= read -r f; do
              [ -n "$f" ] && git add "$f"
            done <<< "$UNTRACKED_FILES"
            ;;
          *)
            while IFS= read -r f; do
              [ -z "$f" ] && continue
              read -p "$(echo -e "''${YELLOW}New untracked file: $f — add to repo? [y]es/[n]o/[a]lways: ''${RESET}")" UT_ANS </dev/tty || UT_ANS="n"
              case "$UT_ANS" in
                y|Y|yes|YES)
                  git add "$f"
                  ;;
                a|A|always|ALWAYS)
                  git add "$f"
                  PROMPT_UNTRACKED="always"
                  if [ -f "$NIXONATOR_CONF" ]; then
                    if grep -q '^PROMPT_UNTRACKED=' "$NIXONATOR_CONF"; then
                      sed -i 's/^PROMPT_UNTRACKED=.*/PROMPT_UNTRACKED="always"/' "$NIXONATOR_CONF"
                    else
                      echo 'PROMPT_UNTRACKED="always"' >> "$NIXONATOR_CONF"
                    fi
                  fi
                  info "PROMPT_UNTRACKED set to \"always\" in nixonator.conf; future new files will be added automatically."
                  ;;
                *)
                  info "Leaving $f untracked."
                  ;;
              esac
            done <<< "$UNTRACKED_FILES"
            ;;
        esac
      fi

      FILE_SUMMARY="$(git diff --cached --name-status | while read -r status file; do
        case "$status" in
          A) echo "  - [Added]    $file" ;;
          M) echo "  - [Modified] $file" ;;
          D) echo "  - [Deleted]  $file" ;;
          *) echo "  - [$status]    $file" ;;
        esac
      done || echo "  - No changes detected.")"

      COMMIT_MSG="NixOS System Update: $HOSTNAME_VAL - $TIMESTAMP

    ### System Metadata
    - Hostname: $HOSTNAME_VAL
    - Triggered By: $USER
    - Timestamp: $TIMESTAMP

    ### Generation Shift
    - Previous:
      $PREV_GEN_INFO
    - Current:
      $NEW_GEN_INFO

    ### Package Changes (Installs, Updates, Removals)
    $PACKAGE_DIFF

    ### Files Uploaded & Updated
    $FILE_SUMMARY"

      if ! git diff --cached --quiet; then
        CACHED_STATUS="$(git diff --cached --name-status)"
        info "Committing configuration changes..."
        git commit -m "$COMMIT_MSG" >/dev/null 2>&1

        if [ "$PRETTY_GIT_SUMMARY" = "true" ]; then
          echo -e "''${CYAN}────────────────────────────────────────────''${RESET}"
          echo -e "''${CYAN}Nixonator: git summary''${RESET}"
          echo -e "  Commit: $(git rev-parse --short HEAD)"
          echo "$CACHED_STATUS" | while read -r status file; do
            case "$status" in
              A) echo -e "  ''${GREEN}+ added''${RESET}     $file" ;;
              M) echo -e "  ''${YELLOW}~ modified''${RESET}  $file" ;;
              D) echo -e "  ''${RED}- deleted''${RESET}   $file" ;;
              *) echo -e "    $status $file" ;;
            esac
          done
          STAT_LINE="$(git show --stat --format="" HEAD 2>/dev/null | tail -n 1)"
          [ -n "$STAT_LINE" ] && echo -e "  $STAT_LINE"
          echo -e "''${CYAN}────────────────────────────────────────────''${RESET}"
        fi
      else
        info "No configuration file changes to commit."
      fi

      info "Pushing changes to GitHub..."
      git push origin "$GIT_BRANCH" >/dev/null 2>&1 || warn "Failed to push to remote repository."
    else
      rm -f flake.lock
    fi

    success "Rebuild and sync completed successfully!"
  '';
in
{
  environment.systemPackages = with pkgs; [
    nixonatorScript
    git
    gnupg
    nix-output-monitor
    nvd
  ];

  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
  };
}
