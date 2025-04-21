#!/usr/bin/env bash
# backup_volumes.sh
# Secure backup of Docker volumes with Restic

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

: "${BACKUP_BASE_DIR:=${BACKUP_BASE_DIR:-/var/backups/docker-volumes}}"
: "${PARALLEL_JOBS:=${PARALLEL_JOBS:-2}}"
: "${RETENTION_DAYS:=${RETENTION_DAYS:-30}}"

# ===== SECURITY CHECKS =====
# Vérifier les permissions du dossier de backup
if [[ -d "$BACKUP_BASE_DIR" ]]; then
  DIR_PERMS=$(stat -c "%a" "$BACKUP_BASE_DIR" 2>/dev/null || stat -f "%Lp" "$BACKUP_BASE_DIR" 2>/dev/null)
  if [[ "$DIR_PERMS" != "700" && "$DIR_PERMS" != "750" && "$DIR_PERMS" != "770" ]]; then
    echo "[WARN] Insecure permissions on backup dir $BACKUP_BASE_DIR ($DIR_PERMS). Should be 700." >&2
    echo "Fix with: chmod 700 $BACKUP_BASE_DIR" >&2
  fi
fi

# Créer le dossier de backup avec permissions sécurisées
mkdir -p "$BACKUP_BASE_DIR"
chmod 700 "$BACKUP_BASE_DIR"

# ===== LOGGING & TIMESTAMP =====
TIMESTAMP=$(date -u +"%Y-%m-%dT%H%M%SZ")
BACKUP_DIR="$BACKUP_BASE_DIR/$TIMESTAMP"
mkdir -p "$BACKUP_DIR"
LOG_FILE="$BACKUP_BASE_DIR/backup_$TIMESTAMP.log"

# Rediriger stdout/stderr vers fichier et console (never log secrets)
exec > >(tee -a "$LOG_FILE") 2>&1

# Notification function: send a real webhook if WEBHOOK_URL is set
send_notification() {
  local msg="$1"
  if [[ -n "$WEBHOOK_URL" ]]; then
    curl -s -X POST -H 'Content-Type: application/json' \
      -d "{\"text\":\"$msg\"}" "$WEBHOOK_URL" >/dev/null 2>&1 || \
      echo "[NOTIFY][ERROR] Failed to send webhook notification"
  else
    echo "[NOTIFY] $msg"
  fi
}

trap 'send_notification "❌ Backup failed at $TIMESTAMP"' ERR

echo "✓ Dependencies OK"

echo "→ Using restic for backups"
# Initializing restic repository if needed
if ! RESTIC_PASSWORD="$RESTIC_PASSWORD" restic -r "$RESTIC_REPOSITORY" snapshots &>/dev/null; then
  echo "→ Initializing restic repository..."
  RESTIC_PASSWORD="$RESTIC_PASSWORD" restic -r "$RESTIC_REPOSITORY" init
fi

echo "\n=== Backup Docker volumes at $TIMESTAMP ==="

# Get all volume names
VOLUMES=$(docker volume ls -q)

# Using restic for backups
for vol in $VOLUMES; do
  echo "--> Processing volume: $vol"
  TEMP_DIR="$BACKUP_DIR/$vol"
  mkdir -p "$TEMP_DIR"

  # Mount and backup
  docker run --rm -v "$vol:/volume:ro" -v "$TEMP_DIR:/backup" alpine sh -c "cp -a /volume/. /backup/"
  
  # Backup with restic
  RESTIC_PASSWORD="$RESTIC_PASSWORD" restic -r "$RESTIC_REPOSITORY" backup "$TEMP_DIR" --tag "docker-volume,$vol,$TIMESTAMP"
  
  # Delete temporary files immediately
  rm -rf "$TEMP_DIR"
done

# Delete old snapshots based on retention policy
if [[ "$RETENTION_DAYS" -gt 0 ]]; then
  echo "→ Cleaning old restic snapshots (keeping ${RETENTION_DAYS} days)..."
  RESTIC_PASSWORD="$RESTIC_PASSWORD" restic -r "$RESTIC_REPOSITORY" forget --prune --keep-within "${RETENTION_DAYS}d"
fi

# Delete the backup directory regardless as it's just temporary
echo "→ Deleting temporary backup directory..."
rm -rf "$BACKUP_DIR"

echo "\n✔ Backup completed successfully at $TIMESTAMP"
send_notification "✅ Backup succeeded at $TIMESTAMP" 