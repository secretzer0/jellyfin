#!/usr/bin/env bash
# Jellyfin container entrypoint.
# Syncs image-bundled plugins into the persistent /config/plugins/ volume each start,
# then execs the jellyfin server. Image is source of truth: any drift (manual edits,
# autoUpdate clobber) is reverted on every restart.
set -euo pipefail

BUNDLE_DIR="${BUNDLE_DIR:-/opt/jellyfin-bundled-plugins}"
PLUGINS_DIR="${JELLYFIN_DATA_DIR:-/config}/plugins"

if [[ -d "$BUNDLE_DIR" ]]; then
    mkdir -p "$PLUGINS_DIR"
    for src in "$BUNDLE_DIR"/*/; do
        [[ -d "$src" ]] || continue
        name="$(basename "$src")"
        dst="$PLUGINS_DIR/$name"
        echo "[entrypoint] syncing plugin: $name"
        mkdir -p "$dst"
        # Overwrite every file from the bundle; remove stale companions (.bak from prior installs).
        cp -f "$src"/* "$dst/"
        rm -f "$dst/${name%_*}.dll.bak" 2>/dev/null || true
    done
    if [[ -f "$BUNDLE_DIR/.failed.txt" ]]; then
        echo ""
        echo "######################################################################"
        echo "# WARNING: the following plugins failed to compile against this image #"
        echo "# (left at their previous version on disk, will fail to load at 12.x): #"
        while IFS= read -r line; do echo "#   - $line"; done < "$BUNDLE_DIR/.failed.txt"
        echo "# Patch scripts/build-plugins.sh and rebuild the image to recover.    #"
        echo "######################################################################"
        echo ""
    fi
else
    echo "[entrypoint] no bundle dir at $BUNDLE_DIR, skipping plugin sync"
fi

# Pass datadir/cachedir as CLI flags like the official packaging entrypoint does:
# the XDG fallback in StartupHelpers only honors the CLI flag, not JELLYFIN_DATA_DIR,
# so a fresh volume without config/ would otherwise resolve to $HOME/.config and crash.
exec /jellyfin/jellyfin \
    --datadir "${JELLYFIN_DATA_DIR:-/config}" \
    --cachedir "${JELLYFIN_CACHE_DIR:-/cache}" \
    --ffmpeg /usr/lib/jellyfin-ffmpeg/ffmpeg "$@"
