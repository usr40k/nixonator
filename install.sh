#!/usr/bin/env bash
set -e

# Ensure the installer is run with sudo/root privileges
if [ "$EUID" -ne 0 ]; then
  echo "==> [Error] Please run this installer with sudo: sudo bash install.sh"
  exit 1
fi

RED='\033[1;31m'
GREEN='\033[1;32m'
BLUE='\033[1;34m'
RESET='\033[0m'

info() { echo -e "${BLUE}==>${RESET} $1"; }
success() { echo -e "${GREEN}==>${RESET} $1"; }
err() { echo -e "${RED}==> [Error]${RESET} $1"; }

info "Initializing Nixonator root-protected bootstrap installation..."

CONFIG_DIR="/etc/nixos"
mkdir -p "$CONFIG_DIR"
cd "$CONFIG_DIR"

# Explicitly read from /dev/tty so piping via curl | sudo sh works smoothly
read -p "Enter your dotfiles git repository URL: " REPO_URL </dev/tty
if [ -z "$REPO_URL" ]; then
  err "Repository URL cannot be empty!"
  exit 1
fi

# Clone repository directly if .git doesn't exist
if [ ! -d ".git" ]; then
  if [ -z "$(ls -A "$CONFIG_DIR")" ]; then
    info "Cloning repository from $REPO_URL..."
    git clone "$REPO_URL" .
  else
    info "Directory is not empty. Initializing remote connection..."
    git init -b main
    git remote add origin "$REPO_URL"
    git fetch origin main
    git checkout -b main origin/main 2>/dev/null || true
  fi
else
  git remote set-url origin "$REPO_URL" 2>/dev/null || git remote add origin "$REPO_URL"
  info "Pulling latest changes from remote..."
  git pull origin main || true
fi

# Ensure modules/nixonator directory exists
MODULE_DIR="$CONFIG_DIR/modules/nixonator"
mkdir -p "$MODULE_DIR"

# Automatically create or fetch nixonator.nix if missing locally
if [ ! -f "$MODULE_DIR/nixonator.nix" ]; then
  info "Fetching/creating nixonator.nix module..."
  # If fetching from a live repo, or writing it directly:
  curl -sL "https://raw.githubusercontent.com/usr40k/nixonator/main/modules/nixonator/nixonator.nix" -o "$MODULE_DIR/nixonator.nix" 2>/dev/null || true
  
  # Fallback if remote fetch fails or isn't pushed yet
  if [ ! -s "$MODULE_DIR/nixonator.nix" ]; then
    warn "Could not fetch remote nixonator.nix, generating base template..."
    # A lightweight fallback can be placed here or handled via repo inclusion
  fi
fi

# Generate configuration file if it doesn't exist
if [ ! -f "$MODULE_DIR/nixonator.conf" ]; then
  info "Generating nixonator.conf..."
  read -p "Enter your Git User Name: " GIT_NAME </dev/tty
  read -p "Enter your Git User Email: " GIT_EMAIL </dev/tty

  cat <<EOF > $MODULE_DIR/nixonator.conf
# Nixonator Configuration
REPO_URL="$REPO_URL"
GIT_BRANCH="main"
SSH_KEY_PATH="/root/.ssh/id_ed25519"

# Git Identity & GPG Signing Configuration
GIT_USER_NAME="$GIT_NAME"
GIT_USER_EMAIL="$GIT_EMAIL"
GPG_SIGNING_KEY=""

# Automatic Garbage Collection Options
AUTO_GC="true"
GC_DAYS="7"
EOF
  success "Created $MODULE_DIR/nixonator.conf"
fi

# Ensure git trusts the root-owned repository directory
git config --system --add safe.directory "$CONFIG_DIR" 2>/dev/null || git config --global --add safe.directory "$CONFIG_DIR" 2>/dev/null || true

success "Nixonator root-protected bootstrap complete!"
echo ""
echo "======================================================================"
echo "🎯 NEXT STEPS TO ACTIVATE NIXONATOR:"
echo "======================================================================"
echo "1. Ensure Flakes are enabled in your system (e.g. in configuration.nix):"
echo "   nix.settings.experimental-features = [ \"nix-command\" \"flakes\" ];"
echo ""
echo "2. Import the Nixonator module inside your host configuration file"
echo "   (e.g., hosts/\$(hostname)/default.nix or configuration.nix):"
echo "   imports = [ ../../modules/nixonator/nixonator.nix ];"
echo ""
echo "3. Ensure your flake outputs map to your hostname:"
echo "   outputs = { self, nixpkgs, ... }@inputs: {"
echo "     nixosConfigurations.$(hostname) = nixpkgs.lib.nixosSystem {"
echo "       modules = [ ./hosts/$(hostname)/configuration.nix ];"
echo "     };"
echo "   };"
echo ""
echo "4. Run your first managed rebuild:"
echo "   sudo nixos-rebuild switch"
echo "======================================================================"
