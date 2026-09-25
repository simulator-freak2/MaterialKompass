#!/bin/sh

set -eu

backup_file=${1:?"Aufruf: ops/restore-test.sh backups/materialkompass-<zeit>.sql.gz"}
test_database=${RESTORE_TEST_DB:-materialkompass_restore_test}

case "$test_database" in
  materialkompass_restore_test|materialkompass_restore_test_[a-z0-9_]*) ;;
  *)
    echo "RESTORE_TEST_DB muss mit materialkompass_restore_test beginnen." >&2
    exit 1
    ;;
esac

case "$(basename "$backup_file")" in
  materialkompass-*.sql.gz) ;;
  *)
    echo "Nur MaterialKompass-Dumps mit dem erwarteten Dateinamen sind zulässig." >&2
    exit 1
    ;;
esac

if [ ! -f "$backup_file" ] || [ ! -f "$backup_file.sha256" ]; then
  echo "Dump oder zugehörige SHA-256-Datei fehlt." >&2
  exit 1
fi

backup_dir=$(CDPATH= cd -- "$(dirname "$backup_file")" && pwd)
backup_name=$(basename "$backup_file")
(cd "$backup_dir" && sha256sum -c "$backup_name.sha256")
gzip -t "$backup_file"

cleanup() {
  docker compose exec -T db sh -c \
    "MYSQL_PWD=\"\$MARIADB_ROOT_PASSWORD\" mariadb -u root -e 'DROP DATABASE IF EXISTS $test_database'" \
    >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

cleanup
docker compose exec -T db sh -c \
  "MYSQL_PWD=\"\$MARIADB_ROOT_PASSWORD\" mariadb -u root -e 'CREATE DATABASE $test_database CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci'"
gzip -cd "$backup_file" | docker compose exec -T db sh -c \
  "MYSQL_PWD=\"\$MARIADB_ROOT_PASSWORD\" exec mariadb -u root $test_database"

table_count=$(docker compose exec -T db sh -c \
  "MYSQL_PWD=\"\$MARIADB_ROOT_PASSWORD\" mariadb -N -u root -e \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$test_database'\"")
case "$table_count" in
  ''|*[!0-9]*)
    echo "Tabellenanzahl konnte nicht geprüft werden." >&2
    exit 1
    ;;
esac
if [ "$table_count" -lt 3 ]; then
  echo "Restore enthält unerwartet wenige Tabellen: $table_count" >&2
  exit 1
fi

docker compose exec -T db sh -c \
  "MYSQL_PWD=\"\$MARIADB_ROOT_PASSWORD\" mariadb -N -u root $test_database -e 'SELECT COUNT(*) FROM users; SELECT COUNT(*) FROM application_collections;'"
echo "Restore-Test erfolgreich: $table_count Tabellen wurden in $test_database geprüft."
