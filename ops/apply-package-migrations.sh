#!/bin/sh

set -eu

baseline_dir=${1:-}
migration_dir=backend/src/db/migrations

if [ ! -d "$migration_dir" ]; then
  echo "Migration directory is missing: $migration_dir" >&2
  exit 1
fi
if [ -n "$baseline_dir" ] && [ ! -d "$baseline_dir" ]; then
  echo "Migration baseline directory is missing: $baseline_dir" >&2
  exit 1
fi

mysql_query() {
  query=$1
  docker compose exec -T db sh -c \
    'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb --batch --skip-column-names --user=root "$MARIADB_DATABASE"' \
    <<EOF
$query
EOF
}

record_migration() {
  name=$1
  checksum=$2
  mysql_query "INSERT INTO schema_migrations (filename, checksum) VALUES ('$name', '$checksum');"
}

mysql_query 'CREATE TABLE IF NOT EXISTS schema_migrations (
  filename VARCHAR(255) PRIMARY KEY,
  checksum CHAR(64) NOT NULL,
  applied_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);'

# On the first package deployment, the migrations from the previously installed
# package form the baseline. This does not require a Git revision.
if [ -n "$baseline_dir" ]; then
  find "$baseline_dir" -maxdepth 1 -type f -name '*.sql' | sort | while IFS= read -r path; do
    name=$(basename "$path")
    checksum=$(sha256sum "$path" | awk '{print $1}')
    existing=$(mysql_query "SELECT checksum FROM schema_migrations WHERE filename = '$name';")
    if [ -z "$existing" ]; then
      record_migration "$name" "$checksum"
      echo "Migration baseline recorded: $name"
    elif [ "$existing" != "$checksum" ]; then
      echo "Migration checksum differs from installed baseline: $name" >&2
      exit 1
    fi
  done
fi

find "$migration_dir" -maxdepth 1 -type f -name '*.sql' | sort | while IFS= read -r path; do
  name=$(basename "$path")
  checksum=$(sha256sum "$path" | awk '{print $1}')
  existing=$(mysql_query "SELECT checksum FROM schema_migrations WHERE filename = '$name';")

  if [ -n "$existing" ]; then
    if [ "$existing" != "$checksum" ]; then
      echo "Applied migration was changed: $name" >&2
      exit 1
    fi
    continue
  fi

  echo "Applying migration: $name"
  docker compose exec -T db sh -c \
    'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb --user=root "$MARIADB_DATABASE"' \
    < "$path"
  record_migration "$name" "$checksum"
done

echo "Database migrations are up to date."
