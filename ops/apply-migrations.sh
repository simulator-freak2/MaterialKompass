#!/bin/sh

set -eu

baseline_ref=${1:-}
migration_dir=backend/src/db/migrations

if [ ! -d "$migration_dir" ]; then
  echo "Migration directory is missing: $migration_dir" >&2
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

checksum_from_ref() {
  ref=$1
  path=$2
  git show "$ref:$path" | sha256sum | awk '{print $1}'
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

# The first run on an existing installation treats every migration contained in
# the previously deployed revision as the baseline. New files in the target
# revision are then executed normally. This prevents historical, non-idempotent
# migrations from being run a second time.
if [ -n "$baseline_ref" ]; then
  git ls-tree -r --name-only "$baseline_ref" -- "$migration_dir" | sort | while IFS= read -r path; do
    [ -n "$path" ] || continue
    name=$(basename "$path")
    checksum=$(checksum_from_ref "$baseline_ref" "$path")
    existing=$(mysql_query "SELECT checksum FROM schema_migrations WHERE filename = '$name';")
    if [ -z "$existing" ]; then
      record_migration "$name" "$checksum"
      echo "Migration baseline recorded: $name"
    elif [ "$existing" != "$checksum" ]; then
      echo "Migration checksum differs from recorded baseline: $name" >&2
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
