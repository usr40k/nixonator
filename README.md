# Nixonator

Nixonator is a NixOS helper that wraps `nixos-rebuild` in a script which:

- pulls your NixOS config from a git repo (dotfiles-style `/etc/nixos` management),
- optionally shows a pre-rebuild summary and asks for confirmation,
- runs `nixos-rebuild` (or any subcommand/flags you pass) against a per-host
  flake output,
- diffs the resulting package set with `nvd`,
- prompts you about new untracked files, commits everything in `/etc/nixos`
  with an auto-generated summary, and pushes it back to your git remote,
- optionally runs garbage collection and reports how much was freed.

It ships as a NixOS module (`modules/nixonator/nixonator.nix`) plus a
bootstrap installer (`install.sh`).

## How it works

`nixonator.nix` is a NixOS module that uses `pkgs.writeShellScriptBin` to
build a script literally named `nixos-rebuild` and adds it to
`environment.systemPackages`. Once the module is imported, calling
`sudo nixos-rebuild <args>` on the machine runs the Nixonator wrapper, which
calls the real `nixos-rebuild` internally.

> **Note on the name collision:** the wrapper intentionally shadows the stock
> `nixos-rebuild` binary. Which one actually wins on a given system depends on
> `PATH` ordering between this package and the system's own `nixos-rebuild`. If
> you see plain, un-wrapped rebuild behavior, the real binary is winning —
> raise this package's priority (`lib.setPrio` / `meta.priority`) or invoke it
> via an explicit `PATH` entry.

The wrapper reads its settings from
`/etc/nixos/modules/nixonator/nixonator.conf`, generated interactively by
`install.sh`.

## Requirements

- NixOS with flakes enabled:
  ```nix
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  ```
- A git repository to hold your `/etc/nixos` configuration. **This repo
  should vendor `modules/nixonator/nixonator.nix` itself** — `--nuke` wipes
  and re-clones from `REPO_URL` by default, so if your own dotfiles repo
  doesn't include the module, you'll need to re-run the installer (or pass
  `--no-reclone`, see below) to get it back.
- `root`/`sudo` access (the installer refuses to run as a non-root user).
- Packages pulled in automatically by the module: `git`, `gnupg`,
  `nix-output-monitor`, `nvd`.

## Installation

```bash
sudo bash <(curl -sL https://raw.githubusercontent.com/usr40k/nixonator/main/install.sh)
```

The installer will:

1. Create `/etc/nixos` if it doesn't exist, and warn you about the trust
   model (it runs as root, can fully wipe `/etc/nixos` via `--nuke`, and
   whatever `REPO_URL`/the Nixonator module resolve to at rebuild time
   effectively controls the machine — only point it at repos you trust).
2. Ask for your dotfiles repo URL, then either `git clone` into
   `/etc/nixos` (if empty) or initialize it as a remote and fetch `main`
   (if `/etc/nixos` already has files in it).
3. Fetch `nixonator.nix` into `/etc/nixos/modules/nixonator/nixonator.nix`.
   If the fetch fails, it writes a minimal fallback wrapper instead (which
   passes through to the real `nixos-rebuild` and supports
   `--nixonator-update` to pull down the full module later).
4. Ask for your git user name/email and write
   `/etc/nixos/modules/nixonator/nixonator.conf`.
5. Mark `/etc/nixos` as a git `safe.directory`.

After that, wire it into your flake:

```nix
# hosts/<hostname>/default.nix or configuration.nix
imports = [ ../../modules/nixonator/nixonator.nix ];
```

```nix
# flake.nix
outputs = { self, nixpkgs, ... }@inputs: {
  nixosConfigurations.<hostname> = nixpkgs.lib.nixosSystem {
    modules = [ ./hosts/<hostname>/configuration.nix ];
  };
};
```

Then run your first managed rebuild:

```bash
sudo nixos-rebuild switch
```

## Usage

Once installed, `nixos-rebuild` behaves as usual, with extra flags:

| Flag | Effect |
|---|---|
| `--no-git` | Skip the git pull/commit/push steps for this run. |
| `--upgrade` | Runs `nix flake update` for the host's flake, locks the result, and exits (does not rebuild). |
| `--nixonator-update` | Re-fetches `nixonator.nix` from the GitHub repo into `modules/nixonator/`. |
| `--nuke CONFIRM` | **Destructive.** Deletes `.git`, `hosts`, `modules`, `flake.nix`, `flake.lock`, and `nixonator.conf` from `/etc/nixos`, then re-clones from `REPO_URL` by default. Requires the literal `CONFIRM` argument. |
| `--nuke CONFIRM --no-reclone` | Same wipe as above, but leaves `/etc/nixos` empty afterward instead of re-cloning. |

Any other flags are passed straight through to the real `nixos-rebuild`.

On a normal run, the wrapper will:

1. Sync `flake.lock` between the shared location and the per-host copy.
2. Stash any uncommitted local changes, fetch/merge from `origin/$GIT_BRANCH`,
   then pop the stash back.
3. Show a **pre-rebuild summary** (host, branch, flake target, extra args,
   and any uncommitted local changes) if `PRE_INSTALL_SUMMARY="true"`.
4. Ask **"Proceed with rebuild? [y/N]"** if `CONFIRM_UPDATE="true"`, aborting
   cleanly if you answer no.
5. Run `nixos-rebuild --impure --flake /etc/nixos#$(hostname)` with the args
   you passed, piping output through `nix-output-monitor`.
6. Run garbage collection if `AUTO_GC="true"`, printing freed-space stats if
   `SHOW_GC_STATS="true"`.
7. Diff the previous and new system profiles with `nvd`.
8. Stage tracked-file changes automatically. For any **new, untracked**
   files, prompt per `PROMPT_UNTRACKED` (see below).
9. Commit everything with a message containing the hostname, user, timestamp,
   generation info, package diff, and changed files, then push to
   `origin/$GIT_BRANCH`. If `PRETTY_GIT_SUMMARY="true"`, also print a
   colorized added/modified/deleted summary with the diffstat line.

## Configuration

`nixonator.conf` (generated by the installer):

```bash
# Nixonator Configuration
REPO_URL="..."
GIT_BRANCH="main"
SSH_KEY_PATH="/root/.ssh/id_ed25519"

# Git Identity & GPG Signing Configuration
GIT_USER_NAME="..."
GIT_USER_EMAIL="..."
GPG_SIGNING_KEY=""

# Automatic Garbage Collection Options
AUTO_GC="true"
GC_DAYS="7"

# Pre-rebuild summary & confirmation
PRE_INSTALL_SUMMARY="true"
CONFIRM_UPDATE="false"

# Output style
PRETTY_GIT_SUMMARY="true"
SHOW_GC_STATS="true"

# How to handle newly created (untracked) files in /etc/nixos:
#   ask    - prompt per file: [y]es/[n]o/[a]lways
#   always - stage every untracked file automatically
#   never  - never stage untracked files automatically
PROMPT_UNTRACKED="ask"
```

| Key | Values | Effect |
|---|---|---|
| `PRE_INSTALL_SUMMARY` | `true` / `false` | Print host, branch, flake target, and pending local changes before rebuilding. |
| `CONFIRM_UPDATE` | `true` / `false` | Require a `[y/N]` confirmation before the rebuild runs. |
| `PRETTY_GIT_SUMMARY` | `true` / `false` | Print a colorized added/modified/deleted file list and diffstat after committing. |
| `SHOW_GC_STATS` | `true` / `false` | Show how much was freed by `nix-collect-garbage` (only relevant when `AUTO_GC="true"`). |
| `PROMPT_UNTRACKED` | `ask` / `always` / `never` | How to handle files under `/etc/nixos` that git doesn't yet track. Picking `[a]lways` at a prompt persists `PROMPT_UNTRACKED="always"` back to this file automatically. |

All five keys have safe built-in defaults, so an existing `nixonator.conf`
from before these options existed will keep working without edits.

Edit this file directly to change the git remote, branch, SSH key, GPG
signing key, GC retention window, or any of the options above.

## Trust model

`install.sh` runs as root, clones an arbitrary user-supplied `REPO_URL` into
`/etc/nixos`, and `--nuke` can wipe most of that directory and re-clone. The
installer prints an explicit warning about this before proceeding. This is
inherent to the "dotfiles as NixOS config" pattern — just be aware that a
compromised or MITM'd `REPO_URL` (or the `nixonator.nix` module it vendors)
effectively controls the machine at rebuild time.

## License

GPL-3.0 (see [`LICENSE`](./LICENSE)).
