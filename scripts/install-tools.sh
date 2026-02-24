#!/bin/bash
set -euo pipefail

# Install zsh, oh-my-zsh, plugins, and zellij on a fresh Ubuntu server.
# Usage: ./scripts/install-tools.sh

if [ "$(id -u)" -eq 0 ]; then
  echo "Error: do not run as root. The script will use sudo when needed."
  exit 1
fi

echo "=== Updating package index ==="
sudo apt-get update

echo "=== Installing zsh ==="
sudo apt-get install -y zsh git curl fzf

# --- oh-my-zsh + plugins ---
echo "=== Installing oh-my-zsh ==="

if [ ! -d "$HOME/.oh-my-zsh" ]; then
  RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi

ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

if [ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]; then
  echo "Installing zsh-autosuggestions..."
  git clone https://github.com/zsh-users/zsh-autosuggestions "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
fi

if [ ! -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]; then
  echo "Installing zsh-syntax-highlighting..."
  git clone https://github.com/zsh-users/zsh-syntax-highlighting "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
fi

# Configure .zshrc
cat > "$HOME/.zshrc" << 'ZSHRC'
export PATH="$HOME/.local/bin:$PATH"
export KUBECONFIG="$HOME/.kube/config"
export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME="robbyrussell"

plugins=(
  git
  kubectl
  fzf
  zsh-autosuggestions
  zsh-syntax-highlighting
)

source $ZSH/oh-my-zsh.sh

# kubectl autocomplete
[[ -x /usr/local/bin/kubectl ]] && source <(kubectl completion zsh)

# nvm
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# Auto-attach to zellij session
if command -v zellij &>/dev/null && [ -z "$ZELLIJ" ]; then
  zellij attach main --create
fi
ZSHRC

# --- nvm + Node.js LTS ---
if [ ! -d "$HOME/.nvm" ]; then
  echo "=== Installing nvm ==="
  NVM_VERSION=$(curl -s https://api.github.com/repos/nvm-sh/nvm/releases/latest | grep -oP '"tag_name": "\K[^"]+')
  curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
fi

# Load nvm in current shell to install Node
export NVM_DIR="$HOME/.nvm"
# shellcheck source=/dev/null
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

echo "=== Installing Node.js LTS ==="
nvm install --lts
nvm use --lts

# --- zellij ---
if ! command -v zellij &>/dev/null; then
  echo "=== Installing zellij ==="
  ZJ_VERSION=$(curl -s https://api.github.com/repos/zellij-org/zellij/releases/latest | grep -oP '"tag_name": "\K[^"]+')
  curl -Lo /tmp/zellij.tar.gz "https://github.com/zellij-org/zellij/releases/download/${ZJ_VERSION}/zellij-x86_64-unknown-linux-musl.tar.gz"
  sudo tar -xzf /tmp/zellij.tar.gz -C /usr/local/bin
  rm /tmp/zellij.tar.gz
fi

# Set zsh as default shell
if [ "$SHELL" != "$(which zsh)" ]; then
  echo "=== Setting zsh as default shell ==="
  sudo chsh -s "$(which zsh)" "$USER"
fi

echo ""
echo "=== Installation Complete ==="
echo ""
echo "  Shell:    zsh + oh-my-zsh (robbyrussell)"
echo "  Plugins:  git, kubectl, fzf, autosuggestions, syntax-highlighting"
echo "  Terminal: zellij"
echo "  Node.js:  nvm + Node.js LTS"
echo ""
echo "Start a new shell with: exec zsh"
echo "Start zellij with:      zellij"
