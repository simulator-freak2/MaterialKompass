#!/bin/sh

set -eu
umask 077

bundle=${1:-}
version=${2:-}
project_dir=${3:-/opt/materialkompass}
lock_dir=/tmp/materialkompass-update.lock
health_url=http://127.0.0.1:3001/ready

case "$project_dir" in
  /*..*) echo "Project directory must not contain '..'." >&2; exit 1 ;;
  /*) ;;
  *) echo "Project directory must be absolute." >&2; exit 1 ;;
esac
case "$bundle" in
  "$project_dir"/.deployments/uploads/upload-*/MaterialKompass-Server.tar.gz) ;;
  *) echo "Invalid server bundle path." >&2; exit 1 ;;
esac
if ! printf '%s\n' "$version" \
  | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$'; then
  echo "Invalid release version." >&2
  exit 1
fi

prepared_dir=
watchdog_pid=
lock_owned=false
cleanup() {
  [ -z "$watchdog_pid" ] || kill "$watchdog_pid" 2>/dev/null || true
  [ -z "$prepared_dir" ] || rm -rf -- "$prepared_dir"
  if [ "$lock_owned" = true ]; then
    rm -f -- "$lock_dir/pid"
    rmdir "$lock_dir" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

if ! mkdir "$lock_dir" 2>/dev/null; then
  existing_pid=
  [ ! -f "$lock_dir/pid" ] || existing_pid=$(cat "$lock_dir/pid" 2>/dev/null || true)
  case "$existing_pid" in
    ''|*[!0-9]*)
      echo "An update lock without a valid owner exists. Inspect $lock_dir before retrying." >&2
      exit 1
      ;;
  esac
  if kill -0 "$existing_pid" 2>/dev/null; then
    echo "Another MaterialKompass update is already running (PID $existing_pid)." >&2
    exit 1
  fi
  rm -f -- "$lock_dir/pid"
  rmdir "$lock_dir" 2>/dev/null \
    || { echo "A stale update lock could not be removed." >&2; exit 1; }
  mkdir "$lock_dir"
fi
lock_owned=true
printf '%s\n' "$$" > "$lock_dir/pid"
chmod 600 "$lock_dir/pid"

ssh_parent_pid=$PPID
deployment_pid=$$
if [ "$ssh_parent_pid" -gt 1 ] 2>/dev/null; then
  (
    while kill -0 "$ssh_parent_pid" 2>/dev/null; do sleep 5; done
    kill -TERM "-$deployment_pid" 2>/dev/null \
      || kill -TERM "$deployment_pid" 2>/dev/null \
      || true
  ) &
  watchdog_pid=$!
fi

cd "$project_dir"
for command_name in docker curl sha256sum tar find awk grep id sed od tr; do
  command -v "$command_name" >/dev/null 2>&1 \
    || { echo "Required command is missing: $command_name" >&2; exit 1; }
done
[ -f .env ] || { echo "Missing production configuration: $project_dir/.env" >&2; exit 1; }
[ -f "$bundle" ] || { echo "Server bundle is missing." >&2; exit 1; }

backup_uid=$(id -u)
backup_gid=$(id -g)
case "$backup_uid:$backup_gid" in
  *[!0-9:]*|:*|*:) echo "Could not determine a safe backup UID/GID." >&2; exit 1 ;;
esac
export BACKUP_UID="$backup_uid"
export BACKUP_GID="$backup_gid"

upsert_env_value() {
  key=$1
  value=$2
  temporary_env="$project_dir/.deployments/.env-$deployment_id.tmp"
  awk -v key="$key" -v value="$value" '
    BEGIN { found=0 }
    index($0, key "=") == 1 {
      if (!found) print key "=" value
      found=1
      next
    }
    { print }
    END { if (!found) print key "=" value }
  ' "$project_dir/.env" > "$temporary_env"
  chmod 600 "$temporary_env"
  mv "$temporary_env" "$project_dir/.env"
}

normalize_code_permissions() {
  root=$1

  for directory in backend backend/src mailbox-provisioner ops; do
    [ ! -d "$root/$directory" ] || chmod 0755 "$root/$directory"
  done
  if [ -d "$root/backend/src" ]; then
    find "$root/backend/src" -type d -exec chmod 0755 {} \;
    find "$root/backend/src" -type f -exec chmod 0644 {} \;
  fi
  for file in \
    backend/Dockerfile backend/package.json backend/package-lock.json backend/server.js \
    mailbox-provisioner/Dockerfile mailbox-provisioner/server.js \
    compose.yaml CHANGELOG.md; do
    [ ! -f "$root/$file" ] || chmod 0644 "$root/$file"
  done
  if [ -d "$root/ops" ]; then
    find "$root/ops" -maxdepth 1 -type f -exec chmod 0644 {} \;
  fi
  if [ -d "$root/web-current" ]; then
    find "$root/web-current" -type d -exec chmod 0755 {} \;
    find "$root/web-current" -type f -exec chmod 0644 {} \;
  fi
}

mkdir -p .deployments/uploads .deployments/archive releases web-current
chmod 700 .deployments .deployments/uploads .deployments/archive
if [ ! -f .deployments/public-messages.json ]; then
  printf '%s\n' '{"schemaVersion":1,"messages":[]}' > .deployments/public-messages.json
  chmod 0644 .deployments/public-messages.json
fi
if [ ! -f web-current/index.html ]; then
  printf '%s\n' '<!doctype html><html lang="de"><meta charset="utf-8"><title>MaterialKompass</title><body>MaterialKompass wird bereitgestellt.</body></html>' \
    > web-current/index.html
  chmod 0644 web-current/index.html
fi

deployment_id=$(date -u '+%Y%m%dT%H%M%SZ')-$$
archive_dir="$project_dir/.deployments/archive/package-$deployment_id"
prepared_dir="$project_dir/.deployments/prepared-$deployment_id"
listing_file="$project_dir/.deployments/package-$deployment_id.list"
mkdir -p "$archive_dir/code" "$prepared_dir"
chmod 700 "$archive_dir" "$archive_dir/code" "$prepared_dir"

tar -tzf "$bundle" > "$listing_file"
[ -s "$listing_file" ] || { echo "Server bundle is empty." >&2; exit 1; }
while IFS= read -r raw_path; do
  path=${raw_path#./}
  [ -n "$path" ] || continue
  printf '%s\n' "$path" | grep -Eq '^[A-Za-z0-9._/+@=-]+$' \
    || { echo "Unsafe character in bundle path: $path" >&2; exit 1; }
  case "/$path/" in
    *'/../'*|*'/./'*) echo "Unsafe bundle path: $path" >&2; exit 1 ;;
  esac
  case "$path" in
    backend|backend/*|mailbox-provisioner|mailbox-provisioner/*|ops|ops/*|compose.yaml|CHANGELOG.md) ;;
    *) echo "Unexpected bundle path: $path" >&2; exit 1 ;;
  esac
  case "/$path/" in
    *'/.git/'*|*'/node_modules/'*|*'/.env/'*|*'/.env.'*)
      echo "Forbidden bundle path: $path" >&2; exit 1 ;;
  esac
done < "$listing_file"
rm -f "$listing_file"

if tar -tvzf "$bundle" | awk '
  substr($1, 1, 1) == "l" || substr($1, 1, 1) == "h" { found=1 }
  END { exit found ? 0 : 1 }
'; then
  echo "Server bundle must not contain links." >&2
  exit 1
fi

tar -xzf "$bundle" --no-same-owner --no-same-permissions -C "$prepared_dir"
if find "$prepared_dir" -type l | grep -q .; then
  echo "Extracted server bundle contains a symbolic link." >&2
  exit 1
fi
for required in \
  backend/package.json backend/package-lock.json backend/Dockerfile \
  mailbox-provisioner/Dockerfile mailbox-provisioner/server.js \
  ops/install-package.sh ops/apply-package-migrations.sh ops/backup-mariadb.sh \
  ops/publish-assets.sh \
  compose.yaml CHANGELOG.md; do
  [ -f "$prepared_dir/$required" ] \
    || { echo "Required bundle file is missing: $required" >&2; exit 1; }
done
find "$prepared_dir/ops" -type f -name '*.sh' -exec sed -i 's/\r$//' {} \;
find "$prepared_dir/backend/src/db/migrations" -type f -name '*.sql' \
  -exec sed -i 's/\r$//' {} \;
normalize_code_permissions "$prepared_dir"

package_sha=$(sha256sum "$bundle" | awk '{print $1}')
if [ "${MATERIALKOMPASS_VALIDATE_ONLY:-0}" = 1 ]; then
  rm -rf -- "$prepared_dir"
  prepared_dir=
  rmdir "$archive_dir/code" "$archive_dir" 2>/dev/null || true
  echo "Server bundle is valid: $package_sha"
  exit 0
fi

normalize_code_permissions "$project_dir"
upsert_env_value BACKUP_UID "$backup_uid"
upsert_env_value BACKUP_GID "$backup_gid"
identity_key=$(awk -F= '$1 == "IDENTITY_KEYRING_MASTER_KEY" { print substr($0, index($0, "=") + 1); exit }' .env)
case "$identity_key" in
  ''|replace-*)
    identity_key=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
    upsert_env_value IDENTITY_KEYRING_MASTER_KEY "$identity_key"
    ;;
  *)
    printf '%s' "$identity_key" | grep -Eq '^[A-Fa-f0-9]{64}$' \
      || { echo "IDENTITY_KEYRING_MASTER_KEY in .env is invalid." >&2; exit 1; }
    ;;
esac
docker compose config --quiet
docker compose run --rm \
  --user "$backup_uid:$backup_gid" \
  -e BACKUP_ONCE=true \
  -e ALLOW_LEGACY_BACKUP=true \
  --entrypoint /bin/sh \
  -v "$prepared_dir/ops/backup-mariadb.sh:/usr/local/bin/materialkompass-backup-once.sh:ro" \
  backup /usr/local/bin/materialkompass-backup-once.sh

activated=false
restore_archived_code() {
  for item in backend mailbox-provisioner ops compose.yaml CHANGELOG.md; do
    if [ -e "$archive_dir/code/$item" ]; then
      rm -rf -- "$project_dir/$item"
      mv "$archive_dir/code/$item" "$project_dir/$item" || true
    fi
  done
}

rollback() {
  reason=$1
  echo "Package update failed: $reason" >&2
  if [ "$activated" = true ]; then
    restore_archived_code
  fi
  docker compose up -d --build --remove-orphans || true
  echo "Previous code restored. The database backup is retained." >&2
  exit 1
}

for item in backend mailbox-provisioner ops compose.yaml CHANGELOG.md; do
  if [ -e "$project_dir/$item" ] && ! mv "$project_dir/$item" "$archive_dir/code/$item"; then
    restore_archived_code
    echo "Could not archive the currently installed code." >&2
    exit 1
  fi
done
activated=true
for item in backend mailbox-provisioner ops compose.yaml CHANGELOG.md; do
  mv "$prepared_dir/$item" "$project_dir/$item" || rollback "new code could not be activated"
done

docker compose config --quiet || rollback "invalid Compose configuration"
docker compose build --pull || rollback "container build failed"
docker compose stop -t 30 backend || rollback "backend could not be stopped"
baseline_dir="$archive_dir/code/backend/src/db/migrations"
sh ops/apply-package-migrations.sh "$baseline_dir" \
  || rollback "database migration failed; inspect the backup before retrying"
docker compose up -d --remove-orphans || rollback "containers did not start"

attempt=1
while [ "$attempt" -le 30 ]; do
  if curl --silent --show-error --fail \
    -H 'X-Forwarded-Proto: https' "$health_url" >/dev/null; then
    break
  fi
  if [ "$attempt" -eq 30 ]; then
    docker compose logs --tail=100 backend >&2 || true
    rollback "readiness check failed"
  fi
  attempt=$((attempt + 1))
  sleep 2
done

deployed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
printf '%s\tpackage\t%s\t%s\t%s\n' "$deployed_at" "$version" "$package_sha" "$archive_dir" \
  >> .deployments/history.log
printf '%s\t%s\n' "$version" "$package_sha" > .deployments/last-successful
chmod 600 .deployments/history.log .deployments/last-successful
docker compose ps
echo "MaterialKompass $version is ready from verified package $package_sha."
