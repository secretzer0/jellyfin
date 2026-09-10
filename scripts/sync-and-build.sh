#!/usr/bin/env bash
# One-shot driver: pull latest upstream into the server fork + all plugin forks,
# then build (and push) the GHCR image.
#
#   1. server fork : git fetch upstream, merge upstream/master, push origin master
#   2. plugin forks: scripts/sync-plugin-forks.sh (fetch + rebase 13-compat)
#   3. image       : scripts/build-and-push-ghcr.sh
#
# Stops on the first failure (merge conflict, plugin rebase conflict, build error).
# Env passthrough: PUSH=0 to build without pushing, plus any build-and-push vars.

set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$REPO_ROOT"

echo "==> 1/3  sync server fork with upstream"
git fetch upstream
git checkout master
git merge upstream/master          # stops here on conflict (set -e); resolve in scripts/ then re-run
git push origin master

echo "==> 2/3  sync plugin forks"
bash scripts/sync-plugin-forks.sh  # exits 1 on rebase conflict, halting the driver

echo "==> 3/3  build image"
bash scripts/build-and-push-ghcr.sh "$@"

echo "==> done"
