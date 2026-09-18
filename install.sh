#!/usr/bin/env bash
set -e

RED='\033[1;31m'
GREEN='\033[1;32m'
BLUE='\033[1;34m'
RESET='\033[0m'

info() { echo -e "''${BLUE}==>''${RESET} $1"; }
success() { echo -e "''${GREEN}==>''${RESET} $1"; }
err() { echo -e "''${RED}==> [Error]''${RESET} $1"; }

info "Initializing Nixonator bootstrap installation..."

# Ensure /etc/nixos exists and is writable by the current user
sudo mkdir -p /etc/nixos
sudo chown -R "$(whoami):$(id -gn)" /etc/nixos
cd /etc/nixos

# Prompt for repository URL since there is no default fallback anymore
read -p "Enter your dotfiles git repository URL: " REPO_URL
if [ -z "$REPO_URL" ]; then
  err "Repository URL cannot be empty!"
  exit 1
fi

if [ ! -d ".git" ]; then
  git init
  git remote add origin "$REPO_URL"
  git branch -M main
else
  git remote set-url origin "$REPO_URL" 2>/dev/null || git remote add origin "$REPO_URL"
fi

# Generate configuration file if it doesn't exist
if [ ! -f "nixonator.conf" ]; then
  info "Generating nixonator.conf..."
  read -p "Enter your Git User Name: " GIT_NAME
  read -p "Enter your Git User Email: " GIT_EMAIL

  cat <<EOF > nixonator.conf
# Nixonator Configuration
REPO_URL="$REPO_URL"
GIT_BRANCH="main"
SSH_KEY_PATH="\$HOME/.ssh/id_ed25519"

# Git Identity & GPG Signing Configuration
GIT_USER_NAME="$GIT_NAME"
GIT_USER_EMAIL="$GIT_EMAIL"
GPG_SIGNING_KEY=""

# Automatic Garbage Collection Options
AUTO_GC="true"
GC_DAYS="7"
EOF
  success "Created /etc/nixos/nixonator.conf"
fi

success "Nixonator environment bootstrap complete!"
echo "Next steps:"
echo "  1. Add your host configuration inside /etc/nixos/hosts/\$(hostname)/"
echo "  2. Run 'sudo nixos-rebuild switch' to build and deploy your system."
