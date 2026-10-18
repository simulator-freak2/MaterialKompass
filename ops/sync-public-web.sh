#!/bin/sh

set -eu
umask 022

mode=${1:-}
backup_dir=${2:-}
project_dir=$(pwd -P)
source_dir="$project_dir/web-current"
target_dir=/var/www/materialkompass
archive_root="$project_dir/.deployments/archive"

case "$mode" in
  publish|restore) ;;
  *) echo "Usage: sync-public-web.sh publish|restore BACKUP_DIR" >&2; exit 1 ;;
esac
case "$backup_dir" in
  "$archive_root"/*/public-web) ;;
  *) echo "Invalid public web backup directory." >&2; exit 1 ;;
esac
case "$backup_dir" in
  *..*) echo "Public web backup directory must not contain '..'." >&2; exit 1 ;;
esac

[ -d "$target_dir" ] && [ ! -L "$target_dir" ] \
  || { echo "Public web root is missing or unsafe: $target_dir" >&2; exit 1; }
[ -d "$backup_dir" ] && [ ! -L "$backup_dir" ] \
  || { echo "Public web backup directory is missing or unsafe." >&2; exit 1; }

# Der bestehende öffentliche Build enthält sowohl root- als auch www-data-
# Dateien. Der isolierte Container erhält deshalb ausschließlich das Recht,
# Dateiberechtigungen innerhalb der drei expliziten Mounts zu übergehen.
container_common="--rm --network none --read-only --cap-drop ALL --cap-add DAC_OVERRIDE --security-opt no-new-privileges:true --pids-limit 64 --memory 128m --user 0:0"

if [ "$mode" = publish ]; then
  [ -f "$source_dir/index.html" ] && [ -f "$source_dir/main.dart.js" ] \
    || { echo "Verified web build is incomplete." >&2; exit 1; }
  [ ! -e "$backup_dir/site.tar" ] \
    || { echo "Public web backup already exists." >&2; exit 1; }
  if find "$source_dir" -type l | grep -q .; then
    echo "Verified web build must not contain symbolic links." >&2
    exit 1
  fi

  # shellcheck disable=SC2086
  docker run $container_common \
    --entrypoint /bin/sh \
    -v "$source_dir:/source:ro" \
    -v "$target_dir:/target" \
    -v "$backup_dir:/backup" \
    nginx:1.28-alpine -eu -c '
      test -r /source/index.html
      test -r /source/main.dart.js
      test -w /target
      test -w /backup
      tar -cf /backup/site.tar -C /target .
      succeeded=false
      restore_on_failure() {
        [ "$succeeded" = true ] && return
        for restore_item in /target/* /target/.[!.]* /target/..?*; do
          [ -e "$restore_item" ] || continue
          rm -rf "$restore_item"
        done
        tar -xf /backup/site.tar -C /target
      }
      trap restore_on_failure EXIT HUP INT TERM
      for item in /target/* /target/.[!.]* /target/..?*; do
        [ -e "$item" ] || continue
        [ "$(basename "$item")" = .well-known ] && continue
        rm -rf "$item"
      done
      cp -R /source/. /target/
      find /target -mindepth 1 -type d -exec chmod 0755 {} \;
      find /target -mindepth 1 -type f -exec chmod 0644 {} \;
      test "$(sha256sum /source/index.html | cut -d " " -f 1)" = \
        "$(sha256sum /target/index.html | cut -d " " -f 1)"
      test "$(sha256sum /source/main.dart.js | cut -d " " -f 1)" = \
        "$(sha256sum /target/main.dart.js | cut -d " " -f 1)"
      succeeded=true
    '
  echo "Public web root synchronized successfully."
  exit 0
fi

[ -f "$backup_dir/site.tar" ] \
  || { echo "Public web rollback archive is missing." >&2; exit 1; }
# shellcheck disable=SC2086
docker run $container_common \
  --entrypoint /bin/sh \
  -v "$target_dir:/target" \
  -v "$backup_dir:/backup:ro" \
  nginx:1.28-alpine -eu -c '
    test -r /backup/site.tar
    test -w /target
    for item in /target/* /target/.[!.]* /target/..?*; do
      [ -e "$item" ] || continue
      rm -rf "$item"
    done
    tar -xf /backup/site.tar -C /target
  '
echo "Previous public web root restored."
