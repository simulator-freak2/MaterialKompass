#!/bin/sh

set -eu
umask 077

branch=${1:-main}
project_dir=${2:-/opt/materialkompass}
lock_dir=/tmp/materialkompass-update.lock
health_url=http://127.0.0.1:3001/ready

case "$branch" in
  ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._/-]*|*..*|*//*|*/)
    echo "Invalid deployment branch: $branch" >&2
    exit 1
    ;;
esac

case "$project_dir" in
  /*..*)
    echo "Project directory must not contain '..'." >&2
    exit 1
    ;;
  /*) ;;
  *)
    echo "Project directory must be an absolute path." >&2
    exit 1
    ;;
esac

if ! mkdir "$lock_dir" 2>/dev/null; then
  echo "Another MaterialKompass update is already running." >&2
  exit 1
fi
trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT HUP INT TERM

cd "$project_dir"

for command_name in git docker curl sha256sum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command is missing: $command_name" >&2
    exit 1
  fi
done

if [ ! -f .env ]; then
  echo "Missing production configuration: $project_dir/.env" >&2
  exit 1
fi

mkdir -p .deployments/uploads .deployments/archive releases web-current
chmod 700 .deployments .deployments/uploads .deployments/archive
if [ ! -f .deployments/public-messages.json ]; then
  printf '%s\n' '{"schemaVersion":1,"messages":[]}' \
    > .deployments/public-messages.json
  chmod 0644 .deployments/public-messages.json
fi
if [ ! -f web-current/index.html ]; then
  printf '%s\n' '<!doctype html><html lang="de"><meta charset="utf-8"><title>MaterialKompass</title><body>MaterialKompass wird bereitgestellt.</body></html>' \
    > web-current/index.html
  chmod 0644 web-current/index.html
fi

current_branch=$(git symbolic-ref --quiet --short HEAD || true)
if [ "$current_branch" != "$branch" ]; then
  echo "Expected branch '$branch', but the server checkout is on '$current_branch'." >&2
  exit 1
fi

if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
  echo "The server checkout contains local changes. Update cancelled:" >&2
  git status --short >&2
  exit 1
fi

old_ref=$(git rev-parse HEAD)
git fetch --prune origin "$branch"
target_ref=$(git rev-parse "origin/$branch")

if ! git merge-base --is-ancestor "$old_ref" "$target_ref"; then
  echo "The update is not a fast-forward from $old_ref to $target_ref." >&2
  exit 1
fi

rollback() {
  reason=$1
  echo "Update failed: $reason" >&2
  echo "Rolling the application back to $old_ref (database backup is retained)." >&2
  git reset --hard "$old_ref"
  docker compose up -d --build --remove-orphans || true
  exit 1
}

if [ "$old_ref" != "$target_ref" ]; then
  git merge --ff-only "origin/$branch"
fi

docker compose config --quiet || rollback "invalid Compose configuration"
docker compose build --pull || rollback "container build failed"

if [ "$old_ref" != "$target_ref" ]; then
  docker compose run --rm \
    -e BACKUP_ONCE=true \
    -e ALLOW_LEGACY_BACKUP=true \
    backup \
    || rollback "pre-update database backup failed"

  docker compose stop -t 30 backend || rollback "backend could not be stopped"
  sh ops/apply-migrations.sh "$old_ref" \
    || rollback "database migration failed; inspect the backup before retrying"
fi

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

mkdir -p .deployments
chmod 700 .deployments
deployed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
printf '%s\t%s\t%s\t%s\n' "$deployed_at" "$old_ref" "$target_ref" "$branch" \
  >> .deployments/history.log
printf '%s\n' "$target_ref" > .deployments/last-successful
chmod 600 .deployments/history.log .deployments/last-successful

docker compose ps
echo "MaterialKompass is ready at commit $target_ref."
