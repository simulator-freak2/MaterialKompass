#!/bin/sh

# This file is mounted into a Linux container and must use LF line endings.

set -eu

BACKUP_DIR=${BACKUP_DIR:-/backups}
BACKUP_HOUR_UTC=${BACKUP_HOUR_UTC:-2}
BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-30}
BACKUP_PREFIX=${BACKUP_PREFIX:-materialkompass-v2}
LEGACY_BACKUP_PREFIX=${LEGACY_BACKUP_PREFIX:-materialkompass}
ALLOW_LEGACY_BACKUP=${ALLOW_LEGACY_BACKUP:-false}
BACKUP_ONCE=${BACKUP_ONCE:-false}
LAST_SUCCESS_FILE="$BACKUP_DIR/.last-successful-backup-date"

case "$BACKUP_HOUR_UTC" in
  ''|*[!0-9]*)
    echo "BACKUP_HOUR_UTC must be an integer from 0 to 23" >&2
    exit 1
    ;;
esac

if [ "$BACKUP_HOUR_UTC" -gt 23 ]; then
  echo "BACKUP_HOUR_UTC must be an integer from 0 to 23" >&2
  exit 1
fi

case "$BACKUP_RETENTION_DAYS" in
  ''|*[!0-9]*)
    echo "BACKUP_RETENTION_DAYS must be a positive integer" >&2
    exit 1
    ;;
esac

if [ "$BACKUP_RETENTION_DAYS" -lt 1 ]; then
  echo "BACKUP_RETENTION_DAYS must be a positive integer" >&2
  exit 1
fi

: "${DB_HOST:?DB_HOST must be set}"
: "${DB_PORT:?DB_PORT must be set}"
: "${DB_NAME:?DB_NAME must be set}"
: "${DB_USER:?DB_USER must be set}"
: "${DB_PASSWORD:?DB_PASSWORD must be set}"

umask 077
mkdir -p "$BACKUP_DIR"

run_backup() {
  backup_date=$(date -u '+%Y-%m-%d')
  timestamp=$(date -u '+%Y%m%dT%H%M%SZ')

  identity_protection_version=$(MYSQL_PWD="$DB_PASSWORD" mariadb \
    --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" \
    --batch --skip-column-names "$DB_NAME" \
    -e "SELECT CASE WHEN
      (SELECT state_value FROM identity_protection_state WHERE state_key = 'backup_format') = '2'
      AND NOT EXISTS (
        SELECT 1 FROM users WHERE identity_ciphertext IS NULL AND identity_erased = 0
      ) THEN '2' ELSE '' END" \
    2>/dev/null || true)
  effective_prefix=$BACKUP_PREFIX
  if [ "$identity_protection_version" != "2" ]; then
    case "$ALLOW_LEGACY_BACKUP" in
      true|1|yes) effective_prefix=$LEGACY_BACKUP_PREFIX ;;
      *)
        echo "Database backup blocked: identity protection migration is not complete" >&2
        return 1
        ;;
    esac
  fi

  final_file="$BACKUP_DIR/$effective_prefix-$timestamp.sql.gz"
  temporary_sql_file="$BACKUP_DIR/.$effective_prefix-$timestamp.sql.tmp"
  temporary_gzip_file="$BACKUP_DIR/.$effective_prefix-$timestamp.sql.gz.tmp"

  remove_temporary_files() {
    rm -f "$temporary_sql_file" "$temporary_gzip_file"
  }
  trap remove_temporary_files EXIT HUP INT TERM

  if [ "$identity_protection_version" = "2" ]; then
    echo "Creating identity-protected database backup $final_file"
  else
    echo "Creating one-time legacy rollback backup $final_file"
  fi
  if ! MYSQL_PWD="$DB_PASSWORD" mariadb-dump \
    --host="$DB_HOST" \
    --port="$DB_PORT" \
    --user="$DB_USER" \
    --single-transaction \
    --quick \
    --skip-lock-tables \
    --no-tablespaces \
    --hex-blob \
    --default-character-set=utf8mb4 \
    "$DB_NAME" > "$temporary_sql_file"; then
    echo "Database backup failed" >&2
    return 1
  fi

  if ! gzip -9 < "$temporary_sql_file" > "$temporary_gzip_file"; then
    echo "Backup compression failed" >&2
    return 1
  fi
  if ! gzip -t "$temporary_gzip_file"; then
    echo "Compressed backup validation failed" >&2
    return 1
  fi
  if ! mv "$temporary_gzip_file" "$final_file"; then
    echo "Publishing the completed backup failed" >&2
    return 1
  fi
  rm -f "$temporary_sql_file"
  if ! (
    cd "$BACKUP_DIR"
    sha256sum "$(basename "$final_file")" > "$(basename "$final_file").sha256"
  ); then
    echo "Creating the backup checksum failed" >&2
    return 1
  fi
  # A pre-v2 dump contains plaintext account identities. It is removed only
  # after a complete, validated v2 dump and checksum have been published.
  if [ "$identity_protection_version" = "2" ]; then
    if ! find "$BACKUP_DIR" -maxdepth 1 -type f \
      \( -name "$LEGACY_BACKUP_PREFIX-[0-9]*.sql.gz" \
         -o -name "$LEGACY_BACKUP_PREFIX-[0-9]*.sql.gz.sha256" \) \
      -delete; then
      echo "Legacy plaintext backups could not be removed" >&2
      return 1
    fi
  fi

  if ! find "$BACKUP_DIR" -maxdepth 1 -type f \
    \( -name "$BACKUP_PREFIX-*.sql.gz" -o -name "$BACKUP_PREFIX-*.sql.gz.sha256" \) \
    -mtime "+$BACKUP_RETENTION_DAYS" -delete; then
    echo "Warning: pruning expired backups failed" >&2
  fi

  if ! printf '%s\n' "$backup_date" > "$LAST_SUCCESS_FILE"; then
    echo "Writing the backup success marker failed" >&2
    return 1
  fi

  trap - EXIT HUP INT TERM
  echo "Database backup completed: $final_file"
}

case "$BACKUP_ONCE" in
  true|1|yes)
    run_backup
    exit 0
    ;;
  false|0|no|'') ;;
  *)
    echo "BACKUP_ONCE must be true or false" >&2
    exit 1
    ;;
esac

while :; do
  current_date=$(date -u '+%Y-%m-%d')
  current_hour=$(date -u '+%H')
  current_hour=${current_hour#0}
  current_hour=${current_hour:-0}
  last_success_date=''

  if [ -f "$LAST_SUCCESS_FILE" ]; then
    last_success_date=$(cat "$LAST_SUCCESS_FILE")
  fi

  if [ "$current_hour" -ge "$BACKUP_HOUR_UTC" ] && [ "$last_success_date" != "$current_date" ]; then
    if ! run_backup; then
      echo "Backup will be retried in 15 minutes" >&2
      sleep 900
      continue
    fi
  fi

  sleep 300
done
