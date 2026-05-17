#!/usr/bin/env bash
# One-time bootstrap: for each forked plugin under secretzer0/, set up:
#   master    — tracks upstream jellyfin/<plugin>
#   12-compat — branched from master, with proper git commits for
#               (1) build config targeting server 12.0.0 / .NET 10
#               (2) source patches bridging 10.11 → 12.0 API drift
#
# Re-runnable: skips work that is already in place. Use sync-plugin-forks.sh
# afterwards to keep master + rebase 12-compat as upstream evolves.
#
# Pushes ONLY go to secretzer0 (origin). Upstream remote is fetch-only by
# convention (we never run `git push upstream`).

set -euo pipefail

FORK_OWNER="${FORK_OWNER:-secretzer0}"
WORK_ROOT="${WORK_ROOT:-/tmp/plugin-forks}"
# Path used INSIDE the docker plugin-builder when ProjectReference resolves.
# /repo is where the Dockerfile copies the server source.
SERVER_REPO_PATH="${SERVER_REPO_PATH:-/repo}"

mkdir -p "$WORK_ROOT"

setup_repo() {
    local repo="$1"
    local proj="$2"          # e.g. Jellyfin.Plugin.OpenSubtitles
    local deps_csv="$3"      # comma list: Common,Controller,Data,Model

    local dir="$WORK_ROOT/$repo"
    echo ""
    echo "==> $repo"

    if [[ ! -d "$dir/.git" ]]; then
        git clone "https://github.com/${FORK_OWNER}/${repo}.git" "$dir"
    fi
    cd "$dir"

    git remote get-url upstream >/dev/null 2>&1 \
        || git remote add upstream "https://github.com/jellyfin/${repo}.git"

    git fetch upstream --quiet
    git fetch origin --quiet

    # Sync master from upstream (fast-forward only; if non-FF, prefer upstream)
    git checkout master
    git pull --ff-only origin master 2>/dev/null || true
    if ! git merge-base --is-ancestor upstream/master master; then
        git merge --ff-only upstream/master 2>/dev/null \
            || git merge upstream/master -m "Sync with upstream master"
    fi
    git push origin master

    # Create or update 12-compat
    if git show-ref --verify --quiet refs/remotes/origin/12-compat; then
        git checkout -B 12-compat origin/12-compat
        if ! git merge-base --is-ancestor master 12-compat; then
            git rebase master \
                || { echo "Rebase CONFLICT on $repo 12-compat. Resolve in $dir and re-run." >&2; cd "$WORK_ROOT"; return 1; }
        fi
    else
        git checkout -B 12-compat master
    fi

    # Idempotent: skip patching if our patch commits are already present.
    if git log --format=%s master..HEAD | grep -q "^build: target Jellyfin server 12.0.0"; then
        echo "    Patches already applied at 12-compat tip; pushing branch."
        git push -u origin 12-compat --force-with-lease
        cd "$WORK_ROOT"
        return 0
    fi

    # ---- Patch 1: csproj for 12.0.0 / net10.0 / local ProjectReferences ----
    local csproj="$proj/$proj.csproj"
    [[ -f "$csproj" ]] || { echo "csproj not found at $csproj" >&2; cd "$WORK_ROOT"; return 1; }

    python3 - "$csproj" "$SERVER_REPO_PATH" "$deps_csv" <<'PY'
import sys, re, pathlib
csproj_path, server_repo, deps_csv = sys.argv[1], sys.argv[2], sys.argv[3]
deps = [d.strip() for d in deps_csv.split(",") if d.strip()]
text = pathlib.Path(csproj_path).read_text()

text = re.sub(r'<TargetFramework>[^<]+</TargetFramework>',
              '<TargetFramework>net10.0</TargetFramework>', text)

text = re.sub(r'<TreatWarningsAsErrors>\s*true\s*</TreatWarningsAsErrors>',
              '<TreatWarningsAsErrors>false</TreatWarningsAsErrors>', text)

pkg_to_proj = {
    "Common":     f"{server_repo}/MediaBrowser.Common/MediaBrowser.Common.csproj",
    "Controller": f"{server_repo}/MediaBrowser.Controller/MediaBrowser.Controller.csproj",
    "Model":      f"{server_repo}/MediaBrowser.Model/MediaBrowser.Model.csproj",
    "Data":       f"{server_repo}/Jellyfin.Data/Jellyfin.Data.csproj",
}

inject_lines = []
for dep in deps:
    pkg = f"Jellyfin.{dep}"
    proj = pkg_to_proj[dep]
    pattern = re.compile(
        r'\s*<PackageReference\s+Include="' + re.escape(pkg) + r'"[^/>]*?(?:/>|>.*?</PackageReference>)',
        flags=re.DOTALL)
    if pattern.search(text):
        text = pattern.sub('', text)
        inject_lines.append(f'    <ProjectReference Include="{proj}" />')

if inject_lines:
    inject_block = "\n".join(inject_lines) + "\n"
    if '<FrameworkReference Include="Microsoft.AspNetCore.App" />' in text:
        text = text.replace(
            '<FrameworkReference Include="Microsoft.AspNetCore.App" />',
            inject_block + '    <FrameworkReference Include="Microsoft.AspNetCore.App" />', 1)
    else:
        text = text.replace(
            '</Project>',
            f'  <ItemGroup>\n{inject_block}    <FrameworkReference Include="Microsoft.AspNetCore.App" />\n  </ItemGroup>\n</Project>', 1)

pathlib.Path(csproj_path).write_text(text)
PY

    git add "$csproj"
    git commit -m "build: target Jellyfin server 12.0.0 (.NET 10)

Switch from upstream Jellyfin.* NuGet packages (10.*) to local
ProjectReferences against the secretzer0/jellyfin fork at /repo/.
Bump TargetFramework to net10.0 to match server.
Disable TreatWarningsAsErrors to tolerate API drift while patches land."

    # ---- Patch 2: per-plugin source code patches ----
    case "$repo" in
        jellyfin-plugin-playbackreporting)
            grep -rl "_userManager\.Users\b" . 2>/dev/null \
                | xargs -r sed -i 's/_userManager\.Users\b/_userManager.GetUsers()/g'
            if ! git diff --quiet; then
                git add -A
                git commit -m "fix: IUserManager.Users property removed in server 12.x

Use the GetUsers() method instead. The property accessor was dropped
when the user repository switched to async-only enumeration."
            fi
            ;;
        jellyfin-plugin-tmdbboxsets)
            grep -rl "string\.IsNullOrEmpty(m\.PrimaryVersionId)" . 2>/dev/null \
                | xargs -r sed -i 's/string\.IsNullOrEmpty(m\.PrimaryVersionId)/!m.PrimaryVersionId.HasValue/g'
            if ! git diff --quiet; then
                git add -A
                git commit -m "fix: PrimaryVersionId changed from string to Guid? in server 12.x

Server migration ChangePrimaryVersionIdToGuid (2026-02-15) altered the
Video.PrimaryVersionId column from string to Guid?. Replace the
string.IsNullOrEmpty checks with a HasValue check."
            fi
            ;;
    esac

    git push -u origin 12-compat --force-with-lease
    cd "$WORK_ROOT"
}

setup_repo "jellyfin-plugin-opensubtitles"       "Jellyfin.Plugin.OpenSubtitles"      "Common,Controller"
setup_repo "jellyfin-plugin-playbackreporting"   "Jellyfin.Plugin.PlaybackReporting"  "Data,Controller"
setup_repo "jellyfin-plugin-reports"             "Jellyfin.Plugin.Reports"            "Data,Controller"
setup_repo "jellyfin-plugin-tmdbboxsets"         "Jellyfin.Plugin.TMDbBoxSets"        "Controller"
setup_repo "jellyfin-plugin-tvdb"                "Jellyfin.Plugin.Tvdb"               "Data,Controller,Common,Model"

echo ""
echo "All forks set up. 12-compat branches pushed to ${FORK_OWNER}."
