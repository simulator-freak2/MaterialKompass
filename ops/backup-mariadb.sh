#!/bin/sh

set -eu

BACKUP_DIR=${BACKUP_DIR:-/backups}
BACKUP_HOUR_UTC=${BACKUP_HOUR_UTC:-2}
BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-30}
BACKUP_PREFIX=${BACKUP_PREFIX:-materialkompass}
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
  final_file="$BACKUP_DIR/$BACKUP_PREFIX-$timestamp.sql.gz"
  temporary_sql_file="$BACKUP_DIR/.$BACKUP_PREFIX-$timestamp.sql.tmp"
  temporary_gzip_file="$BACKUP_DIR/.$BACKUP_PREFIX-$timestamp.sql.gz.tmp"

  remove_temporary_files() {
    rm -f "$temporary_sql_file" "$temporary_gzip_file"
  }
  trap remove_temporary_files EXIT HUP INT TERM

  echo "Creating database backup $final_file"
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
  if ! printf '%s\n' "$backup_date" > "$LAST_SUCCESS_FILE"; then
    echo "Writing the backup success marker failed" >&2
    return 1
  fi

  if ! find "$BACKUP_DIR" -maxdepth 1 -type f \
    \( -name "$BACKUP_PREFIX-*.sql.gz" -o -name "$BACKUP_PREFIX-*.sql.gz.sha256" \) \
    -mtime "+$BACKUP_RETENTION_DAYS" -delete; then
    echo "Warning: pruning expired backups failed" >&2
  fi

  trap - EXIT HUP INT TERM
  echo "Database backup completed: $final_file"
}

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
