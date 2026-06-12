#!/bin/bash
# =============================================================================
# Cookbook Multi-Category — Release-Builder  (läuft auf planlos)
# =============================================================================
# Baut ein FERTIG INSTALLIERBARES, gepatchtes Cookbook-App-Archiv und
# veröffentlicht es als GitHub-Release bei dm7ds/cookbook.
#
# Andere Nutzer installieren das Release dann OHNE Compile (siehe install.sh).
#
# Methode (der einzige Compile = js/, den machen wir):
#   1. Offizielles fertig-gebautes App-Archiv ziehen
#      (christianlupus-nextcloud/cookbook-releases — bringt vendor/, templates, l10n …)
#   2. Patch auf die Source rebasen + js/ frisch bauen (git am + npm build)
#   3. Die 3 Backend-PHP + das gebaute js/ INS offizielle Archiv legen
#   4. Neu packen -> cookbook.tar.gz  (vollständige, gepatchte, installierbare App)
#   5. GitHub-Release bei dm7ds/cookbook erstellen (Tag vX.Y.Z-mcN)
#
# Usage (auf planlos, in ~/cookbook-fork):
#   ./build-release.sh --to v0.11.6              # baut Release für 0.11.6
#   ./build-release.sh --latest                  # neueste Upstream-Version
#   ./build-release.sh --to v0.11.6 --no-publish # nur lokal bauen, kein GitHub-Release
#   ./build-release.sh --to v0.11.6 --mc 2       # Patch-Iteration 2 (Default 1)
# =============================================================================

set -euo pipefail

# --- KONFIG ---
GH_REPO="${GH_REPO:-dm7ds/cookbook}"
OFFICIAL_BASE="https://github.com/christianlupus-nextcloud/cookbook-releases/releases/download"

FORK_DIR="${FORK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_DIR="${FORK_DIR}/source"
PATCHES="${FORK_DIR}/multicategory-patch/patches"
OUT_DIR="${FORK_DIR}/releases"

PHP_FILES=(
    "lib/Db/RecipeDb.php"
    "lib/Service/DbCacheService.php"
    "lib/Helper/Filter/JSON/CleanCategoryFilter.php"
)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info(){ echo -e "${GREEN}[INFO]${NC}  $*"; }
step(){ echo -e "${BLUE}[>>>]${NC}  $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC}  $*"; }
die(){ echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# --- ARGS ---
TARGET=""; USE_LATEST=0; NO_PUBLISH=0; MC=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --to) TARGET="$2"; shift 2 ;;
        --to=*) TARGET="${1#*=}"; shift ;;
        --latest) USE_LATEST=1; shift ;;
        --no-publish) NO_PUBLISH=1; shift ;;
        --mc) MC="$2"; shift 2 ;;
        -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) die "Unbekanntes Argument: $1" ;;
    esac
done

# --- PREFLIGHT ---
echo ""; step "Cookbook Multi-Category Release-Builder"; echo ""
[[ -d "$REPO_DIR/.git" ]] || die "Kein Repo in $REPO_DIR"
ls "$PATCHES"/*.patch >/dev/null 2>&1 || die "Keine Patches in $PATCHES"
command -v node >/dev/null || die "node fehlt"
[[ "$NO_PUBLISH" == "1" ]] || command -v gh >/dev/null || die "gh (GitHub CLI) fehlt — oder mit --no-publish bauen"
mkdir -p "$OUT_DIR"

cd "$REPO_DIR"
# Build-Artefakte (untracked js/css aus vorherigem Build) aufräumen, dann nur TRACKED-Änderungen prüfen
git clean -fd js css >/dev/null 2>&1 || true
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || die "Working tree hat ungespeicherte Änderungen an getrackten Dateien (git stash / checkout)."
git fetch upstream --tags --quiet

# Ziel-Tag
if [[ -n "$TARGET" ]]; then TAG="$TARGET"
elif [[ "$USE_LATEST" == "1" ]]; then TAG="$(git tag -l 'v*' | sort -V | tail -1)"
else die "Bitte --to vX.Y.Z oder --latest angeben."; fi
git rev-parse "$TAG" >/dev/null 2>&1 || die "Tag $TAG fehlt."
VER="${TAG#v}"
RELEASE_TAG="${TAG}-mc${MC}"
info "Upstream-Version: $VER  |  Release-Tag: $RELEASE_TAG"

# --- 1. OFFIZIELLES ARCHIV ZIEHEN ---
echo ""; step "Offizielles fertig-Archiv ziehen ($VER)..."
WORK="$(mktemp -d)"; trap "rm -rf '$WORK'" EXIT
OFFICIAL_URL="${OFFICIAL_BASE}/${TAG}/cookbook-${VER}.tar.gz"
curl -fsSL "$OFFICIAL_URL" -o "$WORK/official.tar.gz" || die "Download fehlgeschlagen: $OFFICIAL_URL"
tar xzf "$WORK/official.tar.gz" -C "$WORK"
[[ -d "$WORK/cookbook" ]] || die "Archiv enthält kein cookbook/ Verzeichnis."
info "Offizielles Archiv entpackt ($(du -sh "$WORK/cookbook" | cut -f1))."

# --- 2. PATCH REBASEN + JS BAUEN ---
echo ""; step "Patch auf $TAG rebasen + Frontend bauen..."
git checkout -B "relbuild-${VER}" "$TAG" --quiet
if ! git am --3way "$PATCHES"/*.patch; then
    git diff --name-only --diff-filter=U | sed 's/^/   KONFLIKT: /' >&2
    git am --abort
    git checkout -f multicategory --quiet 2>/dev/null || true; git clean -fd js css >/dev/null 2>&1 || true
    die "Patch passt nicht auf $TAG (siehe Konfliktdateien). Erst portieren, dann Release bauen."
fi
info "Patch sauber. Baue js/..."
if [[ ! -d node_modules ]] || [[ package-lock.json -nt node_modules/.package-lock.json ]] 2>/dev/null; then npm ci; fi
npm run build
ls js/cookbook-main.* >/dev/null 2>&1 || die "Build erzeugte kein js/cookbook-main.* (Output-Pfad/Build-System geändert?)"
info "Build OK ($(ls js/ | wc -l) Dateien)."

# --- 3. PATCH-ARTEFAKTE INS OFFIZIELLE ARCHIV ---
echo ""; step "Patch über offizielles Archiv legen..."
for f in "${PHP_FILES[@]}"; do
    [[ -f "$WORK/cookbook/$f" ]] || die "Zieldatei im offiziellen Archiv fehlt: $f"
    cp "$f" "$WORK/cookbook/$f"
done
rm -rf "$WORK/cookbook/js"
cp -r js "$WORK/cookbook/js"
# Vite baut auch css/ mit content-gehashten Chunks — komplett ersetzen, damit
# js/-Chunks und css/-Chunks garantiert aus EINEM Build stammen (Hash-Konsistenz).
if [[ -d css ]]; then
    rm -rf "$WORK/cookbook/css"
    cp -r css "$WORK/cookbook/css"
    info "3 PHP + js/ + css/ ersetzt."
else
    info "3 PHP + js/ ersetzt (kein css/ — webpack-Build)."
fi

# Marker in info.xml (sichtbar im NC-Admin, ohne die Version zu brechen)
if ! grep -q "Multi-Category fork" "$WORK/cookbook/appinfo/info.xml"; then
    sed -i "s|</description>|\n\nMULTI-CATEGORY FORK (dm7ds): erlaubt mehrere Kategorien pro Rezept. https://github.com/${GH_REPO}</description>|" \
        "$WORK/cookbook/appinfo/info.xml" 2>/dev/null || true
fi

# --- 4. NEU PACKEN ---
echo ""; step "Release-Archiv packen..."
ARCHIVE="${OUT_DIR}/cookbook-${VER}-mc${MC}.tar.gz"
tar czf "$ARCHIVE" -C "$WORK" cookbook
info "Release-Archiv: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"

git checkout -f multicategory --quiet 2>/dev/null || true; git clean -fd js css >/dev/null 2>&1 || true

# --- 5. GITHUB RELEASE ---
if [[ "$NO_PUBLISH" == "1" ]]; then
    echo ""; info "=== Lokal gebaut (--no-publish). Archiv: $ARCHIVE ==="
    exit 0
fi

echo ""; step "GitHub-Release $RELEASE_TAG bei $GH_REPO erstellen..."
NOTES="Gepatchtes Cookbook **v${VER}** mit Multi-Category-Support (mehrere Kategorien pro Rezept).

Basiert auf dem offiziellen Release [v${VER}](https://github.com/nextcloud/cookbook/releases/tag/${TAG}),
gepatcht weil Upstream Multi-Category wiederholt ablehnt (#277, #2605, PR #3080).

**Installation (ohne Compile):**
\`\`\`
curl -fsSL https://raw.githubusercontent.com/${GH_REPO}/multicategory/install.sh | sudo bash
\`\`\`
oder Archiv \`cookbook-${VER}-mc${MC}.tar.gz\` herunterladen und nach \`apps/\` (bzw. \`custom_apps/\`) entpacken,
dann \`occ app:enable cookbook\`.

Patch-Iteration: mc${MC}."

if gh release view "$RELEASE_TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
    warn "Release $RELEASE_TAG existiert — lade Archiv neu hoch."
    gh release upload "$RELEASE_TAG" "$ARCHIVE" --repo "$GH_REPO" --clobber
else
    gh release create "$RELEASE_TAG" "$ARCHIVE" --repo "$GH_REPO" \
        --title "Cookbook v${VER} + Multi-Category (mc${MC})" --notes "$NOTES"
fi
info "============================================================"
info "  RELEASE VERÖFFENTLICHT: $RELEASE_TAG"
info "  https://github.com/${GH_REPO}/releases/tag/${RELEASE_TAG}"
info "============================================================"
