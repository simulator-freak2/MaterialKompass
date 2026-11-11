#!/bin/sh

# Keep publication alive while backend recreation interrupts SSH.
set -eu
umask 077
stage_dir=${1:-}
version=${2:-}
project_dir=${3:-}
publish_web=${4:-0}
publish_releases=${5:-0}
case "$project_dir" in
  /*..*|'') exit 1 ;;
  /*) ;;
  *) exit 1 ;;
esac
case "$stage_dir" in
  "$project_dir"/.deployments/uploads/upload-*) ;;
  *) exit 1 ;;
esac
run_name=${stage_dir##*/}
case "$run_name" in *[!A-Za-z0-9-]*) exit 1 ;; esac
run_dir="$project_dir/.deployments/runs/$run_name-assets"
mkdir "$run_dir" || exit 1
printf '%s\n' "$$" > "$run_dir/pid"
# publish-assets accepts only actual release files and removes the stage. Keep
# this running wrapper and its status outside that directory before publication.
exit_code=0
(
  mv "$stage_dir/run-asset-publication.sh" "$run_dir/runner.sh" || exit $?
  cd "$project_dir" || exit $?
  sh ops/publish-assets.sh "$stage_dir" "$version" "$publish_web" "$publish_releases"
) > "$run_dir/install.log" 2>&1 || exit_code=$?
printf '%s\n' "$exit_code" > "$run_dir/exit-code.tmp"
mv "$run_dir/exit-code.tmp" "$run_dir/exit-code"
exit "$exit_code"
