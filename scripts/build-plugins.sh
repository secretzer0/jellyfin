#!/usr/bin/env bash
# Build Jellyfin plugins from our fork's 12-compat branch.
#
# Each plugin lives at secretzer0/<repo> with two branches:
#   master    — tracks upstream jellyfin/<repo>
#   12-compat — master + git commits carrying our build/source patches
#
# This script clones the 12-compat branch and runs dotnet publish. No sed
# patching — patches are real commits in the fork. To audit drift, diff
# 12-compat against master; to rebase onto new upstream, see
# scripts/sync-plugin-forks.sh.
#
# Runs inside the plugin-builder Docker stage with /repo populated.

set -euo pipefail

FORK_OWNER="${FORK_OWNER:-secretzer0}"
PLUGIN_BRANCH="${PLUGIN_BRANCH:-12-compat}"
REPO_ROOT="${REPO_ROOT:-/repo}"
OUT="${OUT:-/work/out}"
SRC_DIR="${SRC_DIR:-/work/src}"
mkdir -p "$OUT" "$SRC_DIR"

FAILED=()

TARGET_FRAMEWORK="net10.0"
SERVER_VERSION="$(grep -oP 'AssemblyVersion\("\K[^"]+' "$REPO_ROOT/SharedVersion.cs")"
TARGET_ABI="${SERVER_VERSION}.0"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%S.0000000Z)"

echo "Plugin build: branch=$PLUGIN_BRANCH framework=$TARGET_FRAMEWORK abi=$TARGET_ABI"

# build_plugin <repo> <proj_dir> <dll_name> <display_name> <guid> <version> <category> <overview> <description> <image_filename>
build_plugin() {
    local repo="$1" proj_dir="$2" dll_name="$3" display_name="$4"
    local guid="$5" version="$6" category="$7" overview="$8" description="$9" image_filename="${10:-}"

    local src="$SRC_DIR/$proj_dir"
    echo ""
    echo "==> Building $display_name ($FORK_OWNER/$repo@$PLUGIN_BRANCH)"
    rm -rf "$src"
    if ! git clone --depth 1 --branch "$PLUGIN_BRANCH" \
            "https://github.com/${FORK_OWNER}/${repo}.git" "$src" 2>&1; then
        echo "CLONE FAILED: $display_name (branch $PLUGIN_BRANCH may not exist)"
        FAILED+=("$display_name (clone)")
        return 0
    fi

    local csproj="$src/$proj_dir/$proj_dir.csproj"
    [[ -f "$csproj" ]] || { echo "csproj not found: $csproj" >&2; FAILED+=("$display_name (no csproj)"); return 0; }

    local publish_dir="$src/publish"
    if ! dotnet publish "$csproj" \
        --configuration Release \
        --framework "$TARGET_FRAMEWORK" \
        --output "$publish_dir" \
        -p:DebugSymbols=false -p:DebugType=none \
        -p:GenerateDocumentationFile=false \
        -p:TreatWarningsAsErrors=false 2>&1; then
        echo "BUILD FAILED: $display_name"
        FAILED+=("$display_name (compile)")
        return 0
    fi

    local pdir="$OUT/${display_name}_${version}"
    rm -rf "$pdir"
    mkdir -p "$pdir"
    cp "$publish_dir/$dll_name" "$pdir/"

    # Third-party dependency assemblies (e.g. Tvdb.Sdk) must ship alongside the plugin
    # or it fails to load with FileNotFoundException. Jellyfin.*/MediaBrowser.*/Emby.*
    # come from the server and Microsoft.*/System.* from the shared framework, so skip
    # those to avoid loading a second copy.
    for dep in "$publish_dir"/*.dll; do
        local depname
        depname="$(basename "$dep")"
        case "$depname" in
            Jellyfin.*|MediaBrowser.*|Emby.*|Microsoft.*|System.*|netstandard.dll) continue ;;
        esac
        [[ "$depname" == "$dll_name" ]] && continue
        echo "    bundling dependency: $depname"
        cp "$dep" "$pdir/"
    done

    local image_path_field=""
    if [[ -n "$image_filename" ]]; then
        for candidate in "$src/$image_filename" "$src/$proj_dir/$image_filename"; do
            if [[ -f "$candidate" ]]; then
                cp "$candidate" "$pdir/"
                image_path_field="/config/plugins/${display_name}_${version}/${image_filename}"
                break
            fi
        done
    fi

    python3 - "$pdir/meta.json" "$category" "$description" "$guid" "$display_name" \
                                "$overview" "$TARGET_ABI" "$TIMESTAMP" "$version" "$image_path_field" <<'PY'
import json, sys
path, category, description, guid, name, overview, abi, ts, version, image_path = sys.argv[1:]
meta = {
    "category": category,
    "description": description,
    "guid": guid,
    "name": name,
    "overview": overview,
    "owner": "jellyfin",
    "targetAbi": abi,
    "timestamp": ts,
    "version": version,
    "status": "Active",
    "autoUpdate": False,
    "imagePath": image_path,
    "assemblies": []
}
with open(path, "w") as f:
    json.dump(meta, f, indent=2)
PY
    echo "Built: $pdir"
    ls -la "$pdir"
}

# ---- Plugin manifest ----
build_plugin "jellyfin-plugin-opensubtitles" "Jellyfin.Plugin.OpenSubtitles" \
    "Jellyfin.Plugin.OpenSubtitles.dll" "Open Subtitles" \
    "4b9ed42f-5185-48b5-9803-6ff2989014c4" "24.0.0.0" "Subtitles" \
    "Download subtitles for your media" \
    "Download subtitles from the internet to use with your media files. (Requires configuration)" \
    "jellyfin-plugin-opensubtitles.png"

build_plugin "jellyfin-plugin-playbackreporting" "Jellyfin.Plugin.PlaybackReporting" \
    "Jellyfin.Plugin.PlaybackReporting.dll" "Playback Reporting" \
    "5c534381-91a3-43cb-907a-35aa02eb9d2c" "17.0.0.0" "Administration" \
    "Collect and show user play statistics" \
    "Show reports for playback activity" \
    "jellyfin-plugin-playbackreporting.png"

build_plugin "jellyfin-plugin-reports" "Jellyfin.Plugin.Reports" \
    "Jellyfin.Plugin.Reports.dll" "Reports" \
    "d4312cd9-5c90-4f38-82e8-51da566790e8" "18.0.0.0" "Administration" \
    "Generate reports of your media library" \
    "Generate Reports" \
    "jellyfin-plugin-reports.png"

build_plugin "jellyfin-plugin-tmdbboxsets" "Jellyfin.Plugin.TMDbBoxSets" \
    "Jellyfin.Plugin.TMDbBoxSets.dll" "TMDb Box Sets" \
    "bc4aad2e-d3d0-4725-a5e2-fd07949e5b42" "13.0.0.0" "MoviesAndShows" \
    "Automatically create movie box sets based on TMDb collections" \
    "Automatically create movie box sets based on TMDb collections" \
    ""

build_plugin "jellyfin-plugin-tvdb" "Jellyfin.Plugin.Tvdb" \
    "Jellyfin.Plugin.Tvdb.dll" "TheTVDB" \
    "a677c0da-fac5-4cde-941a-7134223f14c8" "22.0.0.0" "MoviesAndShows" \
    "Get TV metadata from TheTvdb" \
    "Get TV metadata from TheTvdb" \
    "jellyfin-plugin-tvdb.png"

echo ""
echo "=== Plugin build summary ==="
echo "Bundled plugins:"
ls -la "$OUT"
if [[ ${#FAILED[@]} -gt 0 ]]; then
    printf "%s\n" "${FAILED[@]}" > "$OUT/.failed.txt"
    echo ""
    echo "!!! FAILED plugins (skipped from image, written to .failed.txt):"
    for f in "${FAILED[@]}"; do echo "  - $f"; done
else
    echo "All plugins built successfully."
fi
