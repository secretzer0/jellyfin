#!/usr/bin/env bash
# Build Jellyfin plugins against local server source.
# Runs inside plugin-builder Docker stage.
#
# Inputs:
#   /repo  — full jellyfin server source (provides MediaBrowser.* csproj for ProjectReference)
# Outputs:
#   /work/out/<DisplayName>_<Version>/  — plugin dir ready to copy into /config/plugins/

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/repo}"
OUT="${OUT:-/work/out}"
SRC_DIR="${SRC_DIR:-/work/src}"
mkdir -p "$OUT" "$SRC_DIR"

FAILED=()

TARGET_FRAMEWORK="net10.0"
# Match server version. SharedVersion.cs holds "12.0.0"; jellyfin appends ".0" for ABI.
SERVER_VERSION="$(grep -oP 'AssemblyVersion\("\K[^"]+' "$REPO_ROOT/SharedVersion.cs")"
TARGET_ABI="${SERVER_VERSION}.0"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%S.0000000Z)"

echo "Plugin build: framework=$TARGET_FRAMEWORK abi=$TARGET_ABI"

# Map upstream "Jellyfin.*" PackageReferences to local ProjectReferences.
patch_csproj() {
    local csproj="$1"
    python3 - "$csproj" "$REPO_ROOT" <<'PY'
import sys, re, pathlib
csproj_path, repo = sys.argv[1], sys.argv[2]
text = pathlib.Path(csproj_path).read_text()

# Bump target framework
text = re.sub(r'<TargetFramework>[^<]+</TargetFramework>',
              '<TargetFramework>net10.0</TargetFramework>', text)

# Loosen warnings-as-errors so plugin builds tolerate API drift in server
text = re.sub(r'<TreatWarningsAsErrors>\s*true\s*</TreatWarningsAsErrors>',
              '<TreatWarningsAsErrors>false</TreatWarningsAsErrors>', text)

# Map Jellyfin.* PackageReference -> local ProjectReference
pkg_to_proj = {
    "Jellyfin.Controller": f"{repo}/MediaBrowser.Controller/MediaBrowser.Controller.csproj",
    "Jellyfin.Common":     f"{repo}/MediaBrowser.Common/MediaBrowser.Common.csproj",
    "Jellyfin.Model":      f"{repo}/MediaBrowser.Model/MediaBrowser.Model.csproj",
    "Jellyfin.Data":       f"{repo}/Jellyfin.Data/Jellyfin.Data.csproj",
}

inject_lines = []
for pkg, proj in pkg_to_proj.items():
    pattern = re.compile(
        r'<PackageReference\s+Include="' + re.escape(pkg) + r'"[^/>]*?(?:/>|>.*?</PackageReference>)\s*',
        flags=re.DOTALL)
    if pattern.search(text):
        text = pattern.sub('', text)
        inject_lines.append(f'    <ProjectReference Include="{proj}" />')

if inject_lines:
    inject_block = "\n".join(inject_lines) + "\n"
    # Insert into the first ItemGroup that originally held the Jellyfin.* PackageReferences.
    # After removal, find any FrameworkReference/PackageReference ItemGroup to inject into.
    if '<FrameworkReference Include="Microsoft.AspNetCore.App" />' in text:
        text = text.replace(
            '<FrameworkReference Include="Microsoft.AspNetCore.App" />',
            inject_block + '    <FrameworkReference Include="Microsoft.AspNetCore.App" />', 1)
    else:
        # No AspNetCore framework ref — add new ItemGroup before </Project>
        text = text.replace(
            '</Project>',
            f'  <ItemGroup>\n{inject_block}    <FrameworkReference Include="Microsoft.AspNetCore.App" />\n  </ItemGroup>\n</Project>', 1)

pathlib.Path(csproj_path).write_text(text)
print(f"Patched: {csproj_path}")
PY
}

# Per-plugin source patches to bridge 10.11 → 12.0 API drift.
apply_source_patches() {
    local repo="$1" src="$2"
    case "$repo" in
        jellyfin-plugin-playbackreporting)
            # IUserManager.Users property removed in 12.x; replaced by GetUsers() method.
            grep -rl "_userManager\.Users\b" "$src" 2>/dev/null \
                | xargs -r sed -i 's/_userManager\.Users\b/_userManager.GetUsers()/g'
            ;;
        jellyfin-plugin-tmdbboxsets)
            # Video.PrimaryVersionId changed string -> Guid? (server commit ChangePrimaryVersionIdToGuid, 2026-02-15).
            grep -rl "string\.IsNullOrEmpty(m\.PrimaryVersionId)" "$src" 2>/dev/null \
                | xargs -r sed -i 's/string\.IsNullOrEmpty(m\.PrimaryVersionId)/!m.PrimaryVersionId.HasValue/g'
            ;;
    esac
}

# build_plugin <repo> <proj_dir> <dll_name> <display_name> <guid> <version> <category> <overview> <description> <image_filename>
build_plugin() {
    local repo="$1" proj_dir="$2" dll_name="$3" display_name="$4"
    local guid="$5" version="$6" category="$7" overview="$8" description="$9" image_filename="${10:-}"

    local src="$SRC_DIR/$proj_dir"
    echo ""
    echo "==> Building $display_name ($repo)"
    rm -rf "$src"
    git clone --depth 1 "https://github.com/jellyfin/$repo.git" "$src"

    local csproj="$src/$proj_dir/$proj_dir.csproj"
    [[ -f "$csproj" ]] || { echo "csproj not found: $csproj" >&2; FAILED+=("$display_name (no csproj)"); return 0; }
    patch_csproj "$csproj"
    apply_source_patches "$repo" "$src"

    local publish_dir="$src/publish"
    if ! dotnet publish "$csproj" \
        --configuration Release \
        --framework "$TARGET_FRAMEWORK" \
        --output "$publish_dir" \
        -p:DebugSymbols=false -p:DebugType=none \
        -p:GenerateDocumentationFile=false \
        -p:TreatWarningsAsErrors=false 2>&1; then
        echo "BUILD FAILED: $display_name"
        FAILED+=("$display_name")
        return 0
    fi

    local pdir="$OUT/${display_name}_${version}"
    rm -rf "$pdir"
    mkdir -p "$pdir"
    cp "$publish_dir/$dll_name" "$pdir/"

    # Copy plugin image if upstream ships one (loose file in repo root or proj dir)
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

# ---- Plugin manifest (display_name, guid, version, category, overview, description, image) ----
# Versions kept identical to the previously-installed jellyfin community catalog entries.

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
# Persist failure list into image so the runtime entrypoint can announce broken plugins.
if [[ ${#FAILED[@]} -gt 0 ]]; then
    printf "%s\n" "${FAILED[@]}" > "$OUT/.failed.txt"
    echo ""
    echo "!!! FAILED plugins (skipped from image, written to .failed.txt):"
    for f in "${FAILED[@]}"; do echo "  - $f"; done
else
    echo "All plugins built successfully."
fi
