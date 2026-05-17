#!/usr/bin/env bash
# Pull latest from upstream into each plugin fork and rebase 12-compat on top.
# Fails loud and stops on any rebase conflict so the human can resolve.
#
# What this does per plugin:
#   git fetch upstream
#   git checkout master && git merge --ff-only upstream/master && git push origin master
#   git checkout 12-compat && git rebase master
#     ↳ if conflict: stop, leave the work tree in mid-rebase state, report.
#   git push origin 12-compat --force-with-lease   (only if rebase clean)
#
# Pushes only to origin (secretzer0). Upstream is fetched, never pushed to.

set -euo pipefail

FORK_OWNER="${FORK_OWNER:-secretzer0}"
WORK_ROOT="${WORK_ROOT:-/tmp/plugin-forks}"

PLUGINS=(
    jellyfin-plugin-opensubtitles
    jellyfin-plugin-playbackreporting
    jellyfin-plugin-reports
    jellyfin-plugin-tmdbboxsets
    jellyfin-plugin-tvdb
)

mkdir -p "$WORK_ROOT"

CLEAN=()
CONFLICTS=()
UNCHANGED=()

sync_repo() {
    local repo="$1"
    local dir="$WORK_ROOT/$repo"

    echo ""
    echo "==> $repo"

    if [[ ! -d "$dir/.git" ]]; then
        git clone "https://github.com/${FORK_OWNER}/${repo}.git" "$dir"
        cd "$dir"
        git remote add upstream "https://github.com/jellyfin/${repo}.git"
    else
        cd "$dir"
        git remote get-url upstream >/dev/null 2>&1 \
            || git remote add upstream "https://github.com/jellyfin/${repo}.git"
    fi

    git fetch upstream --quiet
    git fetch origin --quiet

    local upstream_sha master_sha
    upstream_sha=$(git rev-parse upstream/master)
    master_sha=$(git rev-parse origin/master)

    git checkout master >/dev/null 2>&1
    git reset --hard origin/master >/dev/null 2>&1

    if [[ "$upstream_sha" == "$master_sha" ]]; then
        echo "    master already at upstream tip ($upstream_sha)"
        UNCHANGED+=("$repo")
    else
        echo "    merging upstream/master ($upstream_sha) into master ($master_sha)"
        if ! git merge --ff-only upstream/master 2>/dev/null; then
            # Non-FF — should be impossible unless our master diverged.
            echo "    !! master is not fast-forwardable to upstream/master." >&2
            echo "       Manual review required in $dir." >&2
            CONFLICTS+=("$repo (non-FF master)")
            cd "$WORK_ROOT"
            return 0
        fi
        git push origin master
    fi

    git checkout 12-compat >/dev/null 2>&1 || git checkout -b 12-compat origin/12-compat
    git reset --hard origin/12-compat >/dev/null 2>&1

    if git merge-base --is-ancestor master HEAD; then
        echo "    12-compat already contains current master; nothing to rebase"
        UNCHANGED+=("$repo (12-compat)")
        cd "$WORK_ROOT"
        return 0
    fi

    echo "    rebasing 12-compat onto master"
    if git rebase master 2>&1; then
        echo "    REBASE CLEAN — pushing 12-compat"
        git push origin 12-compat --force-with-lease
        CLEAN+=("$repo")
    else
        echo "    !! REBASE CONFLICT in $repo. Work tree paused mid-rebase in $dir." >&2
        echo "    !! To resolve:" >&2
        echo "       cd $dir" >&2
        echo "       # fix conflicted files, then:" >&2
        echo "       git add -A && git rebase --continue" >&2
        echo "       # or abort with:  git rebase --abort" >&2
        CONFLICTS+=("$repo")
    fi

    cd "$WORK_ROOT"
}

for r in "${PLUGINS[@]}"; do
    sync_repo "$r" || true
done

echo ""
echo "================================================================"
echo "Plugin fork sync summary"
echo "================================================================"
if [[ ${#CLEAN[@]} -gt 0 ]]; then
    echo "Cleanly rebased (12-compat updated):"
    for r in "${CLEAN[@]}"; do echo "  + $r"; done
fi
if [[ ${#UNCHANGED[@]} -gt 0 ]]; then
    echo "No change (already current):"
    for r in "${UNCHANGED[@]}"; do echo "  = $r"; done
fi
if [[ ${#CONFLICTS[@]} -gt 0 ]]; then
    echo ""
    echo "!!! CONFLICTS — manual resolution required:"
    for r in "${CONFLICTS[@]}"; do echo "  X $r"; done
    echo ""
    echo "Resolve each conflicted repo in $WORK_ROOT, then re-run this script."
    exit 1
fi
echo "================================================================"
