#!/usr/bin/env bash
# restore_volume_from_s3.sh
# Usage: restore_volume_from_s3.sh <volume_name> <timestamp> <backup_filename.gpg>
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

secure_read S3_ENDPOINT "S3 Endpoint URL: " 0
secure_read S3_BUCKET "S3 Bucket name: " 0
secure_read AWS_ACCESS_KEY_ID "AWS Access Key ID: " 1
secure_read AWS_SECRET_ACCESS_KEY "AWS Secret Access Key: " 1

# NOTE: Assurez-vous que le dossier temporaire $LOCAL_DIR n'est accessible que par l'utilisateur du script (chmod 700 recommandé)

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <volume_name> <timestamp> <backup_filename.gpg>" >&2
    exit 1
  fi
  VOL_NAME="$1"
  TS="$2"
  ENC_FILE="$3"
  LOCAL_DIR="/tmp/restore_$TS"
  mkdir -p "$LOCAL_DIR"
  chmod 700 "$LOCAL_DIR"
  # Download
  AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" aws --endpoint-url "$S3_ENDPOINT" s3 cp "s3://$S3_BUCKET/$TS/$ENC_FILE" "$LOCAL_DIR/"
  # Vérification d'intégrité si manifest présent
  if AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" aws --endpoint-url "$S3_ENDPOINT" s3 ls "s3://$S3_BUCKET/$TS/manifest_${TS}.txt" >/dev/null 2>&1; then
    AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" aws --endpoint-url "$S3_ENDPOINT" s3 cp "s3://$S3_BUCKET/$TS/manifest_${TS}.txt" "$LOCAL_DIR/"
    EXPECTED_SUM=$(grep "$ENC_FILE" "$LOCAL_DIR/manifest_${TS}.txt" | awk '{print $1}')
    ACTUAL_SUM=$(sha256sum "$LOCAL_DIR/$ENC_FILE" | awk '{print $1}')
    if [ "$EXPECTED_SUM" != "$ACTUAL_SUM" ]; then
      echo "[WARN] Checksum mismatch for $ENC_FILE!" >&2
    fi
  fi
  # Decrypt
  gpg --batch --yes --output "$LOCAL_DIR/${ENC_FILE%.gpg}" --decrypt "$LOCAL_DIR/$ENC_FILE"
  # Extract into volume
  docker run --rm -v "$VOL_NAME:/restore:rw" -v "$LOCAL_DIR:/backup:ro" busybox:latest sh -c \
    "cd /restore && tar xzf /backup/${ENC_FILE%.gpg}"
  echo "✔ Volume '$VOL_NAME' restored from $ENC_FILE"
  # Nettoyage sécurisé
  rm -rf "$LOCAL_DIR"
fi 