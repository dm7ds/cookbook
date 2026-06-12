#!/bin/bash
# =============================================================================
# Cookbook Multi-Category — Installer / Updater  (läuft als root auf dem NC-Server)
# =============================================================================
# Installiert oder aktualisiert die gepatchte Cookbook-App (Multi-Category)
# aus den GitHub-Releases von dm7ds/cookbook. KEIN Compile nötig.
#
# Was es tut:
#   1. Neuestes (oder gewähltes) Release von dm7ds/cookbook ermitteln
#   2. Wenn schon aktuell -> nichts tun
#   3. Backup der aktuellen Cookbook-App + DB-Cookbook-Tabellen
#   4. Release-Archiv herunterladen, prüfen, nach apps/cookbook/ entpacken
#   5. Permissions setzen, occ upgrade + Cache leeren
#
# Usage (auf dem Nextcloud-Server):
#   sudo ./install.sh                       # neuestes Release
#   sudo ./install.sh --version v0.11.6-mc1 # bestimmtes Release
#   sudo ./install.sh --nc-path /var/www/nextcloud
#   sudo ./install.sh --check               # nur prüfen ob Update da ist
#
# Einzeiler (frische Installation):
#   curl -fsSL https://raw.githubusercontent.com/dm7ds/cookbook/multicategory/install.sh | sudo bash
# =============================================================================

set -euo pipefail

GH_REPO="${GH_REPO:-dm7ds/cookbook}"
NC_PATH="${NC_PATH:-}"
WEB_USER="${WEB_USER:-www-data}"
WANT_VERSION=""
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) WANT_VERSION="$2"; shift 2 ;;
        --nc-path) NC_PATH="$2"; shift 2 ;;
        --check) CHECK_ONLY=1; shift ;;
        -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unbekanntes Argument: $1"; exit 1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info(){ echo -e "${GREEN}[INFO]${NC}  $*"; }
step(){ echo -e "${BLUE}[>>>]${NC}  $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC}  $*"; }
die(){ echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Bitte als root ausführen (sudo)."
command -v curl >/dev/null || die "curl fehlt."
command -v tar  >/dev/null || die "tar fehlt."

# --- Nextcloud finden ---
if [[ -z "$NC_PATH" ]]; then
    for p in /var/www/nextcloud /var/www/html/nextcloud /var/www/html /srv/nextcloud /usr/share/nextcloud; do
        [[ -f "$p/occ" ]] && { NC_PATH="$p"; break; }
    done
fi
[[ -n "$NC_PATH" && -f "$NC_PATH/occ" ]] || die "Nextcloud nicht gefunden. Nutze --nc-path /pfad/zu/nextcloud"
info "Nextcloud: $NC_PATH"

# apps-Verzeichnis (custom_apps bevorzugt falls vorhanden + beschreibbar)
APPS_DIR="$NC_PATH/apps"
[[ -d "$NC_PATH/custom_apps" ]] && APPS_DIR="$NC_PATH/custom_apps"
COOKBOOK_DIR="$APPS_DIR/cookbook"

occ(){ sudo -u "$WEB_USER" php "$NC_PATH/occ" "$@"; }

# --- Versionen ermitteln ---
installed_ver=""
[[ -f "$COOKBOOK_DIR/appinfo/info.xml" ]] && installed_ver="$(grep -oP '<version>\K[^<]+' "$COOKBOOK_DIR/appinfo/info.xml" 2>/dev/null || true)"
# Multi-Cat-Marker?
is_mc=0
[[ -f "$COOKBOOK_DIR/appinfo/info.xml" ]] && grep -q "Multi-Category fork" "$COOKBOOK_DIR/appinfo/info.xml" 2>/dev/null && is_mc=1

step "Neuestes Release von $GH_REPO ermitteln..."
if [[ -n "$WANT_VERSION" ]]; then
    REL_TAG="$WANT_VERSION"
else
    REL_TAG="$(curl -fsSL "https://api.github.com/repos/${GH_REPO}/releases/latest" | grep -oP '"tag_name":\s*"\K[^"]+' || true)"
fi
[[ -n "$REL_TAG" ]] || die "Konnte kein Release ermitteln (Repo/Netz prüfen)."
info "Verfügbar: $REL_TAG   |   Installiert: ${installed_ver:-(keins)}$([[ $is_mc == 1 ]] && echo ' [multi-cat]' || echo '')"

# Schon aktuell? (Tag enthält die Upstream-Version; simple Heuristik)
if [[ "$is_mc" == "1" && "$REL_TAG" == "v${installed_ver}-mc"* ]]; then
    # exakte Übereinstimmung von Tag mit installiertem multi-cat-Stand prüfen
    if [[ -f "$COOKBOOK_DIR/.mc-release" ]] && [[ "$(cat "$COOKBOOK_DIR/.mc-release")" == "$REL_TAG" ]]; then
        info "Bereits auf $REL_TAG — nichts zu tun."
        exit 0
    fi
fi

if [[ "$CHECK_ONLY" == "1" ]]; then
    info "Update verfügbar: $REL_TAG (installiert: ${installed_ver:-keins})"
    exit 0
fi

# --- Download ---
step "Lade Release $REL_TAG..."
TMP="$(mktemp -d)"; trap "rm -rf '$TMP'" EXIT
ASSET_URL="$(curl -fsSL "https://api.github.com/repos/${GH_REPO}/releases/tags/${REL_TAG}" \
    | grep -oP '"browser_download_url":\s*"\K[^"]+\.tar\.gz' | head -1)"
[[ -n "$ASSET_URL" ]] || die "Kein .tar.gz-Asset in Release $REL_TAG gefunden."
curl -fsSL "$ASSET_URL" -o "$TMP/cookbook.tar.gz"
tar tzf "$TMP/cookbook.tar.gz" | grep -q "^cookbook/appinfo/info.xml" || die "Archiv sieht nicht wie eine Cookbook-App aus."
info "Heruntergeladen ($(du -h "$TMP/cookbook.tar.gz" | cut -f1))."

# --- Backup ---
if [[ -d "$COOKBOOK_DIR" ]]; then
    step "Backup der aktuellen Installation..."
    BK="/root/cookbook-backups/install_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BK"
    tar czf "$BK/cookbook-app.tar.gz" -C "$APPS_DIR" cookbook
    # DB-Cookbook-Tabellen (best effort)
    DB="$(grep -oP "'dbname'\s*=>\s*'\K[^']+" "$NC_PATH/config/config.php" 2>/dev/null || echo '')"
    DBU="$(grep -oP "'dbuser'\s*=>\s*'\K[^']+" "$NC_PATH/config/config.php" 2>/dev/null || echo '')"
    DBP="$(grep -oP "'dbpassword'\s*=>\s*'\K[^']+" "$NC_PATH/config/config.php" 2>/dev/null || echo '')"
    if [[ -n "$DB" && -n "$DBU" ]]; then
        mysqldump -u "$DBU" -p"$DBP" "$DB" $(mysql -u "$DBU" -p"$DBP" -N -e "SHOW TABLES LIKE 'oc_cookbook_%'" "$DB" 2>/dev/null) \
            > "$BK/cookbook-db.sql" 2>/dev/null && info "DB-Tabellen gesichert." || warn "DB-Backup übersprungen."
    fi
    info "Backup: $BK"
fi

# --- Maintenance an, deployen ---
step "App deployen..."
occ maintenance:mode --on >/dev/null 2>&1 || true
rm -rf "$COOKBOOK_DIR"
tar xzf "$TMP/cookbook.tar.gz" -C "$APPS_DIR"
echo "$REL_TAG" > "$COOKBOOK_DIR/.mc-release"
chown -R "${WEB_USER}:${WEB_USER}" "$COOKBOOK_DIR"
find "$COOKBOOK_DIR" -type d -exec chmod 755 {} \;
find "$COOKBOOK_DIR" -type f -exec chmod 644 {} \;
info "Entpackt nach $COOKBOOK_DIR"

# --- Aktivieren + Upgrade + Cache ---
step "Aktivieren + Upgrade..."
occ maintenance:mode --off >/dev/null 2>&1 || true
occ app:enable cookbook >/dev/null 2>&1 || true
occ upgrade >/dev/null 2>&1 || true
occ maintenance:repair >/dev/null 2>&1 || true

# OPcache/FPM reload
if systemctl is-active --quiet apache2 2>/dev/null; then systemctl reload apache2
elif systemctl list-units --type=service --state=running 2>/dev/null | grep -qoP 'php[\d.]+-fpm'; then
    systemctl reload "$(systemctl list-units --type=service --state=running | grep -oP 'php[\d.]+-fpm\.service' | head -1)" 2>/dev/null || true
fi

echo ""
info "============================================================"
info "  COOKBOOK MULTI-CATEGORY INSTALLIERT: $REL_TAG"
info "  Ein Rezept kann jetzt mehreren Kategorien zugewiesen werden."
info "  Browser: Cookbook öffnen, Hard-Reload (Strg+Shift+R)"
[[ -n "${BK:-}" ]] && info "  Rollback: tar xzf $BK/cookbook-app.tar.gz -C $APPS_DIR"
info "============================================================"
