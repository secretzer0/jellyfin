#!/usr/bin/env bash
# Build current jellyfin tree and push to ghcr.io/<owner>/jellyfin
# Tag format: master-<version>-<short-sha>   (plus rolling :master)
# Auth: uses `gh auth token` -- no PAT needed. Run `gh auth login` once first.
# Required gh token scopes: write:packages, read:packages
#   gh auth refresh -h github.com -s write:packages,read:packages
#
# Re-runnable. Idempotent. Restores legacy Dockerfile if missing.

set -euo pipefail

# ---- config (override via env) ----
OWNER="${OWNER:-secretzer0}"
IMAGE_NAME="${IMAGE_NAME:-jellyfin}"
REGISTRY="${REGISTRY:-ghcr.io}"
JELLYFIN_WEB_VERSION="${JELLYFIN_WEB_VERSION:-master}"
PUSH="${PUSH:-1}"            # set PUSH=0 to build only
PLATFORM="${PLATFORM:-linux/amd64}"  # legacy Dockerfile is amd64-only
EXTRA_TAGS="${EXTRA_TAGS:-master}"   # space-separated extra tag suffixes
DOTNET_VERSION="${DOTNET_VERSION:-}"  # auto-derived from global.json if empty
NODE_VERSION="${NODE_VERSION:-24}"   # jellyfin-web master requires >=24
REGENERATE_DOCKERFILE="${REGENERATE_DOCKERFILE:-0}"  # 1 = rewrite from legacy commit (loses plugin stage)

# ---- locate repo root ----
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# ---- preconditions ----
command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }
command -v gh >/dev/null     || { echo "gh CLI not found" >&2; exit 1; }
command -v git >/dev/null    || { echo "git not found" >&2; exit 1; }

if ! gh auth status >/dev/null 2>&1; then
    echo "gh not logged in. Run: gh auth login" >&2
    exit 1
fi

# Verify token has package scopes; if not, prompt refresh.
if ! gh auth status 2>&1 | grep -qE 'write:packages'; then
    echo "Current gh token lacks write:packages scope." >&2
    echo "Run: gh auth refresh -h github.com -s write:packages,read:packages" >&2
    exit 1
fi

# ---- generate Dockerfile from legacy commit + patch ----
# Removed upstream in 78b53a60b ("Remove legacy build utilities"). We rebuild it
# from that commit's parent on every run and patch the node base image so
# current jellyfin-web master (which requires node>=24) builds cleanly.
LEGACY_DOCKERFILE_COMMIT="78b53a60b"
if [[ "${REGENERATE_DOCKERFILE}" == "1" || ! -f Dockerfile ]]; then
    echo "Generating Dockerfile from ${LEGACY_DOCKERFILE_COMMIT}^ (node:${NODE_VERSION}-alpine) ..."
    git show "${LEGACY_DOCKERFILE_COMMIT}^:Dockerfile" > Dockerfile
    sed -i "s|^FROM node:[0-9]\+-alpine|FROM node:${NODE_VERSION}-alpine|" Dockerfile
fi

# ---- compute tag ----
VERSION="$(grep -oP 'AssemblyVersion\("\K[^"]+' SharedVersion.cs)"
SLUG="$(git rev-parse --short=8 HEAD)"
DIRTY=""
if ! git diff --quiet || ! git diff --cached --quiet; then
    DIRTY="-dirty"
fi
PRIMARY_TAG="master-${VERSION}-${SLUG}${DIRTY}"
IMAGE_BASE="${REGISTRY}/${OWNER}/${IMAGE_NAME}"
PRIMARY_REF="${IMAGE_BASE}:${PRIMARY_TAG}"

# Derive DOTNET_VERSION (major.minor) from global.json unless overridden.
if [[ -z "${DOTNET_VERSION}" && -f global.json ]]; then
    SDK_FULL="$(grep -oP '"version"\s*:\s*"\K[^"]+' global.json | head -1)"
    DOTNET_VERSION="${SDK_FULL%.*}"  # strip patch -> 10.0.0 -> 10.0
fi
DOTNET_VERSION="${DOTNET_VERSION:-8.0}"

echo "Building ${PRIMARY_REF}"
echo "  version: ${VERSION}"
echo "  slug:    ${SLUG}${DIRTY}"
echo "  web:     ${JELLYFIN_WEB_VERSION}"
echo "  dotnet:  ${DOTNET_VERSION}"
echo "  node:    ${NODE_VERSION}"
echo "  push:    ${PUSH}"

# ---- assemble -t flags ----
TAG_ARGS=(-t "${PRIMARY_REF}")
for t in ${EXTRA_TAGS}; do
    TAG_ARGS+=(-t "${IMAGE_BASE}:${t}")
done

# ---- login to GHCR via gh token ----
if [[ "${PUSH}" == "1" ]]; then
    GH_USER="$(gh api user -q .login)"
    echo "Logging into ${REGISTRY} as ${GH_USER}"
    gh auth token | docker login "${REGISTRY}" -u "${GH_USER}" --password-stdin
fi

# ---- build ----
BUILD_LOG="$(mktemp -t jellyfin-build-XXXXXX.log)"
trap 'rm -f "$BUILD_LOG"' EXIT

# --progress=plain so plugin-builder logs aren't collapsed into a single status line.
docker build \
    --progress=plain \
    --platform "${PLATFORM}" \
    --build-arg "JELLYFIN_WEB_VERSION=${JELLYFIN_WEB_VERSION}" \
    --build-arg "DOTNET_VERSION=${DOTNET_VERSION}" \
    "${TAG_ARGS[@]}" \
    . 2>&1 | tee "$BUILD_LOG"

# ---- surface plugin build failures ----
if grep -qE 'FAILED plugins \(skipped from image' "$BUILD_LOG"; then
    echo ""
    echo "=========================================================="
    echo " PLUGIN BUILD FAILURES — manual patch required to include "
    echo "=========================================================="
    awk '/FAILED plugins \(skipped from image/{flag=1} flag{print} /^#[0-9]+ DONE|^#[0-9]+ CACHED|^[ \t]*$/{if(flag>1){flag=0}; flag&&flag++}' "$BUILD_LOG" \
        | sed -n '1,40p'
    echo "=========================================================="
fi

# ---- push ----
if [[ "${PUSH}" == "1" ]]; then
    docker push "${PRIMARY_REF}"
    for t in ${EXTRA_TAGS}; do
        docker push "${IMAGE_BASE}:${t}"
    done
    echo "Pushed: ${PRIMARY_REF}"
    for t in ${EXTRA_TAGS}; do
        echo "Pushed: ${IMAGE_BASE}:${t}"
    done
else
    echo "Build complete (push skipped). Local tag: ${PRIMARY_REF}"
fi
