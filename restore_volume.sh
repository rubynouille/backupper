#!/usr/bin/env bash
# restore_volume.sh
# Usage: restore_volume.sh <volume_name> <snapshot_id>
# 
# To list available snapshots: restic -r <repository> snapshots
set -euo pipefail

umask 077

# ===== LOAD ENV FILE (SECURE) =====
ENV_FILE="${BACKUP_ENV_FILE:-$HOME/.backup_env}"
if [[ -f "$ENV_FILE" ]]; then
  # Vérification des permissions du fichier .env
  FILE_PERMS=$(stat -c "%a" "$ENV_FILE" 2>/dev/null || stat -f "%Lp" "$ENV_FILE" 2>/dev/null)
  if [[ "$FILE_PERMS" != "600" && "$FILE_PERMS" != "400" ]]; then
    echo "[WARN] Insecure permissions on $ENV_FILE ($FILE_PERMS). Should be 600 or 400." >&2
    echo "Fix with: chmod 600 $ENV_FILE" >&2
  fi
  source "$ENV_FILE"
fi

# ===== AUTO INSTALLER FUNCTION =====
install_dependency() {
  local pkg="$1"
  local alt_pkg="${2:-}"
  
  if command -v "$pkg" >/dev/null 2>&1; then
    return 0
  fi
  
  echo "Dependency '$pkg' not found. Attempting to install..."
  
  # Detect package manager
  if command -v apt-get >/dev/null 2>&1; then
    # Debian/Ubuntu
    sudo apt-get update && sudo apt-get install -y "$pkg"
  elif command -v yum >/dev/null 2>&1; then
    # RHEL/CentOS/Fedora
    sudo yum install -y "${alt_pkg:-$pkg}"
  elif command -v dnf >/dev/null 2>&1; then
    # Modern Fedora
    sudo dnf install -y "${alt_pkg:-$pkg}"
  elif command -v pacman >/dev/null 2>&1; then
    # Arch Linux
    sudo pacman -Sy --noconfirm "${alt_pkg:-$pkg}"
  elif command -v zypper >/dev/null 2>&1; then
    # openSUSE
    sudo zypper install -y "${alt_pkg:-$pkg}"
  elif command -v brew >/dev/null 2>&1; then
    # macOS with Homebrew
    brew install "${alt_pkg:-$pkg}"
  else
    echo "Could not determine package manager. Please install '$pkg' manually." >&2
    return 1
  fi
  
  # Check if installation succeeded
  if ! command -v "$pkg" >/dev/null 2>&1; then
    echo "Failed to install '$pkg'. Please install it manually." >&2
    return 1
  fi
  
  echo "Successfully installed '$pkg'."
  return 0
}

# ===== DEPENDENCY CHECKS & INSTALLATION =====
# Essential: Docker
install_dependency docker docker.io || exit 1

# Essential: Restic
install_dependency restic || exit 1

# ===== SECURE ENV VAR PROMPTS =====
secure_read() {
  local var="$1"; local prompt="$2"; local silent="$3"
  if [ -z "${!var:-}" ]; then
    if [ -t 0 ]; then  # Vérifie si on est dans un terminal interactif
      if [ "$silent" = "1" ]; then
        read -rsp "$prompt" "$var" && echo
      else
        read -rp "$prompt" "$var"
      fi
    else
      echo "Error: $var is not set and no terminal for input. Set it in $ENV_FILE or environment." >&2
      exit 1
    fi
  fi
}

secure_read RESTIC_PASSWORD "RESTIC password: " 1
secure_read RESTIC_REPOSITORY "RESTIC repository: " 0

# Check if using S3 backend
if [[ "$RESTIC_REPOSITORY" == s3:* ]]; then
  secure_read RESTIC_S3_ACCESS_KEY "S3 Access Key: " 1
  secure_read RESTIC_S3_SECRET_KEY "S3 Secret Key: " 1
  
  # Set up environment for S3 backend
  export AWS_ACCESS_KEY_ID="$RESTIC_S3_ACCESS_KEY"
  export AWS_SECRET_ACCESS_KEY="$RESTIC_S3_SECRET_KEY"
fi

# NOTE: Secure temporary directories
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  # Check usage
  if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <volume_name> <snapshot_id>" >&2
    echo "" >&2
    echo "To list available snapshots:" >&2
    echo "  RESTIC_PASSWORD=xxx restic -r \"$RESTIC_REPOSITORY\" snapshots" >&2
    exit 1
  fi
  
  VOL_NAME="$1"
  SNAPSHOT_ID="$2"
  LOCAL_DIR="/tmp/restore_restic_$RANDOM"
  mkdir -p "$LOCAL_DIR"
  chmod 700 "$LOCAL_DIR"
  
  echo "Restoring snapshot $SNAPSHOT_ID to volume $VOL_NAME using restic..."
  
  # Restore from restic to local directory
  RESTIC_PASSWORD="$RESTIC_PASSWORD" restic -r "$RESTIC_REPOSITORY" restore "$SNAPSHOT_ID" --target "$LOCAL_DIR"
  
  # Get the volume subdirectory from the restore (restic creates a directory structure)
  RESTORED_DIR=$(find "$LOCAL_DIR" -type d -name "$VOL_NAME" | head -n 1)
  if [[ -z "$RESTORED_DIR" ]]; then
    # If volume subdirectory not found, use the whole restored directory
    RESTORED_DIR="$LOCAL_DIR"
  fi
  
  # Copy files to docker volume
  docker run --rm -v "$VOL_NAME:/restore:rw" -v "$RESTORED_DIR:/backup:ro" busybox:latest sh -c \
    "cd /restore && rm -rf * && cp -a /backup/. ."
    
  echo "✔ Volume '$VOL_NAME' restored from restic snapshot $SNAPSHOT_ID"
  
  # Cleanup
  rm -rf "$LOCAL_DIR"
fi 