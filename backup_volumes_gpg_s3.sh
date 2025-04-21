#!/usr/bin/env bash
# docker_backup_volumes.sh & restore_volume.sh
# Secure backup with GPG and S3-compatible storage

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

# ===== DEPENDENCY CHECKS =====
REQUIRED_CMDS=(docker gpg aws)
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: $cmd is required but not installed or not in PATH." >&2
    exit 1
  fi
done

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

secure_read GPG_RECIPIENT "GPG recipient (email or key ID): " 0
secure_read AWS_ACCESS_KEY_ID "AWS Access Key ID: " 1
secure_read AWS_SECRET_ACCESS_KEY "AWS Secret Access Key: " 1
secure_read S3_ENDPOINT "S3 Endpoint URL: " 0
secure_read S3_BUCKET "S3 Bucket name: " 0
: "${AWS_REGION:=${AWS_REGION:-us-east-1}}"
: "${BACKUP_BASE_DIR:=${BACKUP_BASE_DIR:-/var/backups/docker-volumes}}"
: "${PARALLEL_JOBS:=${PARALLEL_JOBS:-2}}"
: "${USE_ZSTD:=${USE_ZSTD:-0}}"
: "${RETENTION_DAYS:=${RETENTION_DAYS:-7}}"

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

# Notification function (à personnaliser si besoin)
send_notification() {
  local msg="$1"
  # Example: curl -X POST -H 'Content-Type: application/json' \
  #   -d "{\"text\":\"$msg\"}" "$WEBHOOK_URL"
  echo "[NOTIFY] $msg"
}

trap 'send_notification "❌ Backup failed at $TIMESTAMP"' ERR

# Nettoyage des anciens backups locaux
echo "→ Cleaning local backups older than $RETENTION_DAYS days..."
find "$BACKUP_BASE_DIR" -maxdepth 1 -type d -mtime +"$RETENTION_DAYS" -print -exec rm -rf {} \;

echo "✓ Dependencies OK"

echo "→ Testing GPG encryption for $GPG_RECIPIENT"
TEST_FILE="$BACKUP_DIR/test_gpg.txt"
echo "gpg_test" > "$TEST_FILE"
gpg --batch --yes --encrypt -r "$GPG_RECIPIENT" -o "$TEST_FILE.gpg" "$TEST_FILE"
rm -f "$TEST_FILE" "$TEST_FILE.gpg"
echo "✓ GPG OK"

# Tester S3
echo "→ Testing S3 connectivity..."
aws --endpoint-url "$S3_ENDPOINT" s3 ls "s3://$S3_BUCKET/" --region "$AWS_REGION" >/dev/null 2>&1 && \
  echo "✓ S3 accessible" || (echo "Error: Cannot access S3://$S3_BUCKET" >&2; exit 1)

echo "\n=== Backup Docker volumes at $TIMESTAMP ==="

docker volume ls -q | xargs -P "$PARALLEL_JOBS" -n1 -I {} bash -c '
  set -euo pipefail
  VOL="{}"
  BASE="$BACKUP_DIR"
  TS="$TIMESTAMP"
  EXT="tar.gz"
  if [[ "$USE_ZSTD" -eq 1 && command -v zstd >/dev/null ]]; then
    EXT="tar.zst"
  fi
  TAR_NAME="${VOL}_${TS}.${EXT}"
  ENC_NAME="${TAR_NAME}.gpg"
  echo "--> Processing volume: $VOL"
  # Archive
  if [[ "$EXT" == "tar.zst" ]]; then
    docker run --rm -v "$VOL:/volume:ro" -v "$BASE:/backup" alpine sh -c \
      "cd /volume && tar cf - . | zstd -o /backup/$TAR_NAME"
  else
    docker run --rm -v "$VOL:/volume:ro" -v "$BASE:/backup" busybox:latest sh -c \
      "cd /volume && tar czf /backup/$TAR_NAME ."
  fi
  # Checksum
  sha256sum "$BASE/$TAR_NAME" >> "$BASE/manifest_${TS}.txt"
  # Encrypt
  gpg --batch --yes --encrypt -r "$GPG_RECIPIENT" -o "$BASE/$ENC_NAME" "$BASE/$TAR_NAME"
  rm -f "$BASE/$TAR_NAME"
  # Upload (export AWS secrets uniquement dans ce sous-shell)
  AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" aws --endpoint-url "$S3_ENDPOINT" s3 cp "$BASE/$ENC_NAME" "s3://$S3_BUCKET/$TS/$ENC_NAME" --region "$AWS_REGION"
  # Vérification d'intégrité post-upload
  LOCAL_SUM=$(sha256sum "$BASE/$ENC_NAME" | awk '{print $1}')
  REMOTE_SUM=$(AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" aws --endpoint-url "$S3_ENDPOINT" s3api head-object --bucket "$S3_BUCKET" --key "$TS/$ENC_NAME" --region "$AWS_REGION" --query "Metadata.sha256sum" --output text 2>/dev/null || echo "")
  if [ -n "$REMOTE_SUM" ] && [ "$LOCAL_SUM" != "$REMOTE_SUM" ]; then
    echo "[WARN] Checksum mismatch for $ENC_NAME between local and S3!"
  fi
'

echo "\n✔ Backup completed successfully at $TIMESTAMP"
send_notification "✅ Backup succeeded at $TIMESTAMP" 