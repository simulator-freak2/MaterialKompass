#!/bin/sh

# Started with nohup and redirected standard streams by deploy-package.ps1.
# Its lifetime, and thus the installer's parent watchdog, is independent of SSH.
set -eu
umask 077

stage_dir=${1:-}
version=${2:-}
project_dir=${3:-}
case "$project_dir" in
  /*..*|'') echo 'Invalid project directory.' >&2; exit 1 ;;
  /*) ;;
  *) exit 1 ;;
esac
case "$stage_dir" in
  "$project_dir"/.deployments/uploads/upload-*) ;;
  *) echo 'Invalid upload directory.' >&2; exit 1 ;;
esac
run_name=${stage_dir##*/}
case "$run_name" in
  *[!A-Za-z0-9-]*) exit 1 ;;
esac
run_dir="$project_dir/.deployments/runs/$run_name"
# Exclusive creation prevents duplicate installation if a start acknowledgement
# was lost. Logs live outside the upload directory and survive asset publication.
mkdir "$run_dir" || exit 1
printf '%s\n' "$$" > "$run_dir/pid"
exit_code=0
sh "$stage_dir/install-package.sh" \
  "$stage_dir/MaterialKompass-Server.tar.gz" "$version" "$project_dir" \
  > "$run_dir/install.log" 2>&1 || exit_code=$?
printf '%s\n' "$exit_code" > "$run_dir/exit-code.tmp"
mv "$run_dir/exit-code.tmp" "$run_dir/exit-code"
exit "$exit_code"
