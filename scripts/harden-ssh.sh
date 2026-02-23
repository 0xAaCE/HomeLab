#!/bin/bash
set -euo pipefail

# Harden SSH: install selected public keys, then disable password authentication.
# Usage: sudo ./scripts/harden-ssh.sh [username]
#   username: the user to install keys for (default: current SUDO_USER or USER)

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEYS_DIR="$REPO_ROOT/keys/ssh"
SSHD_CONFIG="/etc/ssh/sshd_config"

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: run as root (sudo $0)"
  exit 1
fi

TARGET_USER="${1:-${SUDO_USER:-$USER}}"
TARGET_HOME=$(eval echo "~$TARGET_USER")

echo "Target user: $TARGET_USER ($TARGET_HOME)"
echo ""

# --- Step 1: Select and install SSH public keys ---

PUB_KEYS=()
while IFS= read -r -d '' f; do
  PUB_KEYS+=("$f")
done < <(find "$KEYS_DIR" -name "*.pub" -print0 2>/dev/null)

if [ ${#PUB_KEYS[@]} -eq 0 ]; then
  echo "No .pub files found in $KEYS_DIR"
  echo "Add your public keys there first (e.g. keys/ssh/mykey.pub)"
  exit 1
fi

echo "Available SSH public keys:"
echo ""
for i in "${!PUB_KEYS[@]}"; do
  filename=$(basename "${PUB_KEYS[$i]}")
  # Show key comment (last field) or truncated key for identification
  key_comment=$(awk '{print $NF}' "${PUB_KEYS[$i]}")
  echo "  [$((i+1))] $filename  ($key_comment)"
done
echo "  [A] All of the above"
echo ""

read -rp "Which keys to install? (comma-separated numbers, or A for all): " selection

SELECTED=()
if [[ "$selection" =~ ^[Aa]$ ]]; then
  SELECTED=("${PUB_KEYS[@]}")
else
  IFS=',' read -ra choices <<< "$selection"
  for choice in "${choices[@]}"; do
    idx=$((${choice// /} - 1))
    if [ "$idx" -ge 0 ] && [ "$idx" -lt ${#PUB_KEYS[@]} ]; then
      SELECTED+=("${PUB_KEYS[$idx]}")
    else
      echo "Invalid selection: $choice"
      exit 1
    fi
  done
fi

if [ ${#SELECTED[@]} -eq 0 ]; then
  echo "No keys selected. Aborted."
  exit 1
fi

# Install selected keys
SSH_DIR="$TARGET_HOME/.ssh"
mkdir -p "$SSH_DIR"
touch "$SSH_DIR/authorized_keys"

ADDED=0
for key_file in "${SELECTED[@]}"; do
  key_content=$(cat "$key_file")
  if grep -qF "$key_content" "$SSH_DIR/authorized_keys" 2>/dev/null; then
    echo "Already installed: $(basename "$key_file")"
  else
    echo "$key_content" >> "$SSH_DIR/authorized_keys"
    echo "Installed: $(basename "$key_file")"
    ADDED=$((ADDED + 1))
  fi
done

chown -R "$TARGET_USER:$TARGET_USER" "$SSH_DIR"
chmod 700 "$SSH_DIR"
chmod 600 "$SSH_DIR/authorized_keys"

echo ""
echo "$ADDED key(s) added, $(( ${#SELECTED[@]} - ADDED )) already present."
echo ""

# --- Step 2: Harden sshd_config ---

read -rp "Disable password authentication now? (y/N): " confirm
if [ "$confirm" != "y" ]; then
  echo "Keys installed. SSH config unchanged."
  exit 0
fi

# Backup current config
BACKUP="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
cp "$SSHD_CONFIG" "$BACKUP"
echo "Backed up $SSHD_CONFIG → $BACKUP"

declare -A SETTINGS=(
  ["PasswordAuthentication"]="no"
  ["KbdInteractiveAuthentication"]="no"
  ["UsePAM"]="no"
  ["PermitRootLogin"]="prohibit-password"
)

for key in "${!SETTINGS[@]}"; do
  value="${SETTINGS[$key]}"
  if grep -qE "^#?\s*${key}\b" "$SSHD_CONFIG"; then
    sed -i "s/^#*\s*${key}\b.*/${key} ${value}/" "$SSHD_CONFIG"
  else
    echo "${key} ${value}" >> "$SSHD_CONFIG"
  fi
done

# Validate before restarting
if sshd -t; then
  # Ubuntu uses "ssh", other distros use "sshd"
  if systemctl is-active --quiet ssh 2>/dev/null; then
    systemctl restart ssh
  else
    systemctl restart sshd
  fi
  echo ""
  echo "SSH hardened. Password authentication is now disabled."
  echo ""
  echo "IMPORTANT: Keep this session open and test with a new connection before closing!"
else
  echo "ERROR: Invalid sshd config. Restoring backup."
  cp "$BACKUP" "$SSHD_CONFIG"
  exit 1
fi
