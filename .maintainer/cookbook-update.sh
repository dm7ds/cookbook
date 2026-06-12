#!/bin/bash
# =============================================================================
# Cookbook Multi-Category — Knopfdruck-Update-Script  (LÄUFT AUF SERVER)
# =============================================================================
# Bringt den Multi-Category-Patch auf eine (neue) Cookbook-Version und deployt
# ihn lokal auf diesem Server. Ein Knopfdruck: rebase -> build -> deploy -> verify.
#
# Dieses Script läuft AUF dem server-Server (nicht auf dem Windows-Rechner).
# Es klont/aktualisiert den Fork, baut das Frontend lokal (node), und legt den
# Patch über die offiziell installierte Cookbook-App.
#
# Strategie "patch-on-top": Wir ersetzen NICHT die ganze App, sondern legen den
# Patch (3 PHP + gebautes js/) über die offizielle Version. vendor/ und alles
# andere kommt vom offiziellen Nextcloud-Store-Release.
#
# Ablauf:
#   1. Ziel-Version bestimmen (--to, Server-Version, oder --latest)
#   2. Upstream-Tags holen, Konflikt-Frühwarnung
#   3. Patch auf Ziel-Version rebasen via `git am --3way`  -> HARTER STOPP bei Konflikt
#   4. Build lokal (npm ci + npm run build)
#   5. Patch lokal über apps/cookbook/ deployen (Backup + Rollback)
#   6. Verifikation (HTTP)
#
# Struktur auf server (Tools NEBEN dem Repo, damit branch-Wechsel sie nicht stören):
#   ~/cookbook-fork/
#     cookbook-update.sh            <- dieses Script
#     multicategory-patch/{deploy-multicategory.sh, patches/, migrate-...php}
#     source/                       <- git clone von dm7ds/cookbook (wird zum Bauen genutzt)
#
# Usage (auf server):
#   cd ~/cookbook-fork && ./cookbook-update.sh            # Ziel = Server-Version
#   ./cookbook-update.sh --to v0.12.0
#   ./cookbook-update.sh --latest
#   ./cookbook-update.sh --dry-run     # rebase+build testen, kein Deploy
#   ./cookbook-update.sh --update-app  # vorher `occ app:update cookbook` (zieht offizielle Version)
# =============================================================================

set -euo pipefail

# --- KONFIGURATION ---
NC_PATH="${NC_PATH:-/var/www/nextcloud}"
WEB_USER="${WEB_USER:-www-data}"
NC_URL="${NC_URL:-https://cloud.example.invalid}"

# Tools liegen im Script-Verzeichnis, das Repo darunter in source/
FORK_DIR="${FORK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_DIR="${FORK_DIR}/source"
PATCHES="${FORK_DIR}/multicategory-patch/patches"
DEPLOY_SCRIPT="${FORK_DIR}/multicategory-patch/deploy-multicategory.sh"
ARCHIVE="${FORK_DIR}/multicategory-patch/cookbook-multicategory.tar.gz"

PHP_FILES=(
    "lib/Db/RecipeDb.php"
    "lib/Service/DbCacheService.php"
    "lib/Helper/Filter/JSON/CleanCategoryFilter.php"
)

# --- FARBEN ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
step()  { echo -e "${BLUE}[>>>]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$*"; exit 1; }

# --- ARGS ---
TARGET=""; USE_LATEST=0; DRY_RUN=0; NO_DEPLOY=0; UPDATE_APP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --to)         TARGET="$2"; shift 2 ;;
        --to=*)       TARGET="${1#*=}"; shift ;;
        --latest)     USE_LATEST=1; shift ;;
        --dry-run)    DRY_RUN=1; NO_DEPLOY=1; shift ;;
        --no-deploy)  NO_DEPLOY=1; shift ;;
        --update-app) UPDATE_APP=1; shift ;;
        -h|--help)    grep -E '^#( |$)' "$0" | sed 's/^# \?//'; exit 0 ;;
        *)            die "Unbekanntes Argument: $1 (siehe --help)" ;;
    esac
done

server_version() { grep -oP '<version>\K[^<]+' "${NC_PATH}/apps/cookbook/appinfo/info.xml" 2>/dev/null; }
occ() { sudo -u "$WEB_USER" php "${NC_PATH}/occ" "$@"; }

# --- PREFLIGHT ---
echo ""; step "Cookbook Multi-Category Update (server)"; echo ""
[[ -d "$REPO_DIR/.git" ]] || die "Kein Git-Repo in $REPO_DIR (erst klonen: git clone https://github.com/dm7ds/cookbook ~/cookbook-fork)"
ls "$PATCHES"/*.patch >/dev/null 2>&1 || die "Keine .patch-Dateien in $PATCHES"
command -v node >/dev/null || die "node nicht gefunden"
command -v npm  >/dev/null || die "npm nicht gefunden"
[[ -d "${NC_PATH}/apps/cookbook" ]] || die "Cookbook nicht installiert in ${NC_PATH}/apps/cookbook"

cd "$REPO_DIR"
[[ -z "$(git status --porcelain)" ]] || die "Working tree nicht sauber. (git stash / git checkout -- .)"

# Optional: offizielle App-Version vom Store ziehen
if [[ "$UPDATE_APP" == "1" ]]; then
    step "Ziehe offizielle Cookbook-Version aus dem Nextcloud-Store..."
    occ app:update cookbook 2>&1 || warn "app:update meldete nichts Neues (evtl. schon aktuell)."
fi

# --- ZIEL-VERSION ---
step "Upstream-Tags holen..."
git fetch upstream --tags --quiet

if [[ -n "$TARGET" ]]; then
    TAG="$TARGET"
elif [[ "$USE_LATEST" == "1" ]]; then
    TAG="$(git tag -l 'v*' | sort -V | tail -1)"
    info "Neuestes Upstream-Release: $TAG"
else
    SV="$(server_version)"; [[ -n "$SV" ]] || die "Server-Version nicht lesbar. Nutze --to / --latest."
    TAG="v${SV}"; info "Server hat Cookbook v${SV} -> Ziel-Tag $TAG"
fi
git rev-parse "$TAG" >/dev/null 2>&1 || die "Tag '$TAG' fehlt. Verfügbar: $(git tag -l 'v*' | sort -V | tail -5 | tr '\n' ' ')"
TARGET_VERSION="${TAG#v}"
info "Ziel-Version: $TARGET_VERSION ($TAG)"

# --- KONFLIKT-FRÜHWARNUNG ---
echo ""; step "Prüfe ob Upstream die Patch-Dateien bis $TAG angefasst hat..."
RISK=0
for f in "${PHP_FILES[@]}" "src/components/RecipeEdit.vue"; do
    if git diff --quiet "v0.11.6" "$TAG" -- "$f" 2>/dev/null; then
        info "  $f — unverändert"
    else
        warn "  $f — GEÄNDERT ($(git rev-list --count v0.11.6..$TAG -- "$f" 2>/dev/null) Commits upstream)"
        RISK=1
    fi
done
[[ "$RISK" == "1" ]] && warn "Konflikt-Risiko beim Rebase (PR #3080 entfernt Multi-Select in RecipeEdit.vue)."

if [[ "$DRY_RUN" != "1" && "$NO_DEPLOY" != "1" ]]; then
    echo ""; read -p "Patch auf $TAG bauen UND lokal deployen? (j/N) " -n 1 -r; echo ""
    [[ $REPLY =~ ^[jJyY]$ ]] || { info "Abgebrochen."; exit 0; }
fi

# --- REBASE ---
echo ""; step "Patch auf $TAG anwenden (git am --3way)..."
git checkout -B "build-${TARGET_VERSION}" "$TAG" --quiet
if ! git am --3way "$PATCHES"/*.patch; then
    echo ""
    error "================================================================"
    error " MERGE-KONFLIKT — Patch passt nicht sauber auf $TAG"
    error "================================================================"
    git diff --name-only --diff-filter=U | sed 's/^/   - /' >&2
    error " Auflösen:  cd $REPO_DIR"
    error "   <Konflikte fixen>  &&  git add <dateien>  &&  git am --continue"
    error "   rm $PATCHES/*.patch"
    error "   git format-patch ${TAG}..HEAD -o $PATCHES/   # Patch dauerhaft aktualisieren"
    error "   dann Script erneut starten.   Abbrechen: git am --abort"
    error "================================================================"
    exit 2
fi
info "Patch sauber angewendet."
for f in "${PHP_FILES[@]}" "src/components/RecipeEdit.vue"; do [[ -f "$f" ]] || die "Datei fehlt nach Patch: $f"; done

# --- BUILD ---
echo ""; step "Frontend bauen..."
if [[ ! -d node_modules ]] || [[ package-lock.json -nt node_modules/.package-lock.json ]] 2>/dev/null; then
    info "npm ci..."; npm ci
else
    info "node_modules aktuell."
fi
info "Build..."; npm run build
# Output-Verzeichnis: webpack UND vite bauen nach js/ (in dieser App konfiguriert)
ls js/cookbook-main.* >/dev/null 2>&1 || die "Build erzeugte kein js/cookbook-main.* (Output-Pfad geändert? Build-System geprüft?)"
info "Build OK ($(ls js/ | wc -l) Dateien in js/)."

# --- ARCHIV ---
echo ""; step "Deploy-Archiv packen..."
TMP="$(mktemp -d)"; trap "rm -rf '$TMP'" EXIT
for f in "${PHP_FILES[@]}"; do mkdir -p "$TMP/$(dirname "$f")"; cp "$f" "$TMP/$f"; done
cp -r js "$TMP/js"
tar czf "$ARCHIVE" -C "$TMP" .
info "Archiv: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"

if [[ "$NO_DEPLOY" == "1" ]]; then
    echo ""
    [[ "$DRY_RUN" == "1" ]] && info "=== DRY-RUN OK — Patch baut sauber auf $TAG. ===" || info "=== Archiv gebaut (--no-deploy). ==="
    git checkout multicategory --quiet 2>/dev/null || true
    exit 0
fi

# --- DEPLOY (lokal) ---
echo ""; step "Deploy lokal über apps/cookbook/..."
chmod +x "$DEPLOY_SCRIPT"
sudo ASSUME_YES=1 EXPECTED_VERSION="$TARGET_VERSION" NC_PATH="$NC_PATH" WEB_USER="$WEB_USER" \
    PATCH_ARCHIVE="$ARCHIVE" "$DEPLOY_SCRIPT"

# --- VERIFY ---
echo ""; step "Verifikation..."
HTTP="$(curl -s -o /dev/null -w '%{http_code}' "${NC_URL}/apps/cookbook/" 2>/dev/null || echo '000')"
[[ "$HTTP" =~ ^(200|302|303)$ ]] && info "Cookbook erreichbar (HTTP $HTTP)." || warn "HTTP $HTTP — bitte manuell prüfen."

git checkout multicategory --quiet 2>/dev/null || true
echo ""
info "============================================================"
info "  FERTIG — Cookbook v${TARGET_VERSION} + Multi-Category"
info "  Browser: ${NC_URL}/apps/cookbook/  (Hard-Reload Strg+Shift+R)"
info "  Rollback: sudo ${DEPLOY_SCRIPT} --rollback"
info "============================================================"
