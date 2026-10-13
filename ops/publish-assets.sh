#!/bin/sh

set -eu

stage_dir=${1:-}
version=${2:-}
publish_web=${3:-0}
publish_releases=${4:-0}
project_dir=$(pwd -P)

case "$stage_dir" in
  "$project_dir"/.deployments/uploads/upload-[A-Za-z0-9-]*) ;;
  *) echo "Invalid staging directory." >&2; exit 1 ;;
esac
if ! printf '%s\n' "$version" \
  | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$'; then
  echo "Invalid release version." >&2
  exit 1
fi
[ "$publish_web" = 0 ] || [ "$publish_web" = 1 ] || exit 1
[ "$publish_releases" = 0 ] || [ "$publish_releases" = 1 ] || exit 1
[ -d "$stage_dir" ] || { echo "Staging directory not found." >&2; exit 1; }

for command_name in docker curl sha256sum unzip awk grep; do
  command -v "$command_name" >/dev/null 2>&1 \
    || { echo "Required command is missing: $command_name" >&2; exit 1; }
done

lock_dir=/tmp/materialkompass-assets.lock
if ! mkdir "$lock_dir" 2>/dev/null; then
  echo "Another asset publication is already running." >&2
  exit 1
fi
trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT HUP INT TERM

release_names='MaterialKompass-Windows.exe MaterialKompass-Linux.deb MaterialKompass-Android.apk MaterialKompass-iOS.ipa MaterialKompass-macOS.dmg'
for staged in "$stage_dir"/*; do
  [ -f "$staged" ] || { echo "Only regular files may be published." >&2; exit 1; }
  name=$(basename "$staged")
  allowed=false
  [ "$publish_web" = 1 ] && [ "$name" = MaterialKompass-Web.zip ] && allowed=true
  if [ "$publish_releases" = 1 ]; then
    for release_name in $release_names; do
      [ "$name" = "$release_name" ] && allowed=true
    done
  fi
  [ "$allowed" = true ] || { echo "Unexpected staged file: $name" >&2; exit 1; }
done

deployment_id=$(date -u '+%Y%m%dT%H%M%SZ')-$$
archive_dir="$project_dir/.deployments/archive/$deployment_id"
mkdir -p "$archive_dir" "$project_dir/releases" "$project_dir/web-current"
chmod 700 "$project_dir/.deployments" "$project_dir/.deployments/archive" "$archive_dir"

web_prepared=
if [ "$publish_web" = 1 ]; then
  web_archive="$stage_dir/MaterialKompass-Web.zip"
  [ -f "$web_archive" ] || { echo "Web archive is missing." >&2; exit 1; }
  if unzip -Z1 "$web_archive" | grep -E '(^/|(^|/)\.\.(/|$)|\\)' >/dev/null; then
    echo "Web archive contains an unsafe path." >&2
    exit 1
  fi
  web_prepared="$project_dir/.deployments/web-$deployment_id"
  mkdir "$web_prepared"
  unzip -q "$web_archive" -d "$web_prepared"
  [ -f "$web_prepared/index.html" ] || { echo "Web archive has no index.html." >&2; exit 1; }
  if find "$web_prepared" -type l | grep -q .; then
    echo "Web archive must not contain symbolic links." >&2
    exit 1
  fi
fi

env_backup="$archive_dir/env.before"
cp -p .env "$env_backup"
if [ "$publish_releases" = 1 ]; then
  for release_name in $release_names; do
    if [ -f "$stage_dir/$release_name" ]; then
      [ ! -f "releases/$release_name" ] || cp -p "releases/$release_name" "$archive_dir/$release_name"
      cp -p "$stage_dir/$release_name" "releases/$release_name.new"
      chmod 0644 "releases/$release_name.new"
    fi
  done
fi

rollback() {
  echo "Asset publication failed; restoring previous files." >&2
  cp -p "$env_backup" .env || true
  if [ -d "$archive_dir/web-current" ]; then
    rm -rf web-current
    mv "$archive_dir/web-current" web-current || true
  fi
  if [ "$publish_releases" = 1 ]; then
    for release_name in $release_names; do
      rm -f "releases/$release_name.new"
      if [ -f "$archive_dir/$release_name" ]; then
        cp -p "$archive_dir/$release_name" "releases/$release_name" || true
      fi
    done
  fi
  docker compose up -d backend web || true
  exit 1
}

if [ "$publish_web" = 1 ]; then
  mv web-current "$archive_dir/web-current"
  mv "$web_prepared" web-current
fi
if [ "$publish_releases" = 1 ]; then
  for release_name in $release_names; do
    [ ! -f "releases/$release_name.new" ] || mv -f "releases/$release_name.new" "releases/$release_name"
  done
  env_tmp=.env.assets.$$
  awk -v value="$version" '
    BEGIN {
      keys["CLIENT_WINDOWS_VERSION"]=1; keys["CLIENT_LINUX_VERSION"]=1;
      keys["CLIENT_ANDROID_VERSION"]=1; keys["CLIENT_IOS_VERSION"]=1;
      keys["CLIENT_MACOS_VERSION"]=1;
    }
    {
      split($0, parts, "="); key=parts[1];
      if (key in keys) { print key "=" value; seen[key]=1 } else { print }
    }
    END { for (key in keys) if (!(key in seen)) print key "=" value }
  ' .env > "$env_tmp" || rollback
  chmod --reference=.env "$env_tmp" 2>/dev/null || chmod 600 "$env_tmp"
  mv "$env_tmp" .env
fi

docker compose up -d backend web || rollback
attempt=1
while [ "$attempt" -le 30 ]; do
  backend_ok=false
  web_ok=false
  curl -fsS -H 'X-Forwarded-Proto: https' http://127.0.0.1:3001/ready >/dev/null \
    && backend_ok=true
  curl -fsS http://127.0.0.1:8080/ >/dev/null && web_ok=true
  [ "$backend_ok" = true ] && [ "$web_ok" = true ] && break
  [ "$attempt" -lt 30 ] || rollback
  attempt=$((attempt + 1))
  sleep 2
done

rm -rf -- "$stage_dir"
printf '%s\tassets\t%s\tweb=%s\treleases=%s\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$version" "$publish_web" "$publish_releases" \
  >> .deployments/history.log
chmod 600 .deployments/history.log
echo "Assets for MaterialKompass $version published successfully."
