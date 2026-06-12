#!/bin/bash
# =============================================================================
# Nextcloud Cookbook Multi-Category Patch — Deploy Script
# =============================================================================
# Patcht die Cookbook-App v0.11.6 auf dem Server fuer Multi-Kategorie-Support.
#
# Was es tut:
#   1. Erstellt ein vollstaendiges Backup der aktuellen Cookbook-App
#   2. Patcht 3 PHP-Dateien (Backend: Multi-Category Support)
#   3. Ersetzt die kompilierten JS-Dateien (Frontend: Multi-Select UI)
#   4. Setzt Datei-Permissions korrekt
#   5. Leert den Nextcloud-Cache (OPcache + App)
#
# Rollback: ./deploy-multicategory.sh --rollback
# =============================================================================

set -euo pipefail

# --- KONFIGURATION (ANPASSEN!) ---
NC_PATH="${NC_PATH:-/var/www/nextcloud}"
COOKBOOK_REL="apps/cookbook"
WEB_USER="${WEB_USER:-www-data}"
BACKUP_DIR="${BACKUP_DIR:-/root/cookbook-backups}"

# Erwartete Cookbook-Version (vom cookbook-update.sh gesetzt, default 0.11.6).
EXPECTED_VERSION="${EXPECTED_VERSION:-0.11.6}"
# Non-interaktiver Modus (ASSUME_YES=1) — vom cookbook-update.sh fuer
# vollautomatischen Deploy genutzt. Ueberspringt alle Bestaetigungs-Prompts.
ASSUME_YES="${ASSUME_YES:-0}"

# --- FARBEN ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

COOKBOOK_PATH="${NC_PATH}/${COOKBOOK_REL}"
PATCH_ARCHIVE="${PATCH_ARCHIVE:-$(cd "$(dirname "$0")" && pwd)/cookbook-multicategory.tar.gz}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="${BACKUP_DIR}/cookbook_backup_${TIMESTAMP}"

# --- ROLLBACK-MODUS ---
if [[ "${1:-}" == "--rollback" ]]; then
    echo ""
    info "=== ROLLBACK MODUS ==="
    echo ""

    # Neuestes Backup finden
    if [[ ! -d "$BACKUP_DIR" ]]; then
        error "Kein Backup-Verzeichnis gefunden: $BACKUP_DIR"
        exit 1
    fi

    LATEST_BACKUP=$(ls -dt "${BACKUP_DIR}"/cookbook_backup_* 2>/dev/null | head -1)
    if [[ -z "$LATEST_BACKUP" ]]; then
        error "Kein Backup gefunden in $BACKUP_DIR"
        exit 1
    fi

    info "Neuestes Backup: $LATEST_BACKUP"
    echo ""
    read -p "Dieses Backup wiederherstellen? (j/N) " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[jJyY]$ ]]; then
        info "Abgebrochen."
        exit 0
    fi

    # PHP-Dateien wiederherstellen
    for f in \
        "lib/Helper/Filter/JSON/CleanCategoryFilter.php" \
        "lib/Db/RecipeDb.php" \
        "lib/Service/DbCacheService.php"; do
        if [[ -f "${LATEST_BACKUP}/${f}" ]]; then
            cp -v "${LATEST_BACKUP}/${f}" "${COOKBOOK_PATH}/${f}"
        fi
    done

    # JS-Dateien wiederherstellen
    if [[ -d "${LATEST_BACKUP}/js" ]]; then
        rm -rf "${COOKBOOK_PATH}/js"
        cp -r "${LATEST_BACKUP}/js" "${COOKBOOK_PATH}/js"
        info "JS-Verzeichnis wiederhergestellt."
    fi

    # Permissions
    chown -R "${WEB_USER}:${WEB_USER}" "${COOKBOOK_PATH}/lib" "${COOKBOOK_PATH}/js"

    # Cache leeren
    if command -v php &>/dev/null; then
        sudo -u "${WEB_USER}" php "${NC_PATH}/occ" maintenance:repair --include-expensive 2>/dev/null || true
    fi

    info "=== ROLLBACK ABGESCHLOSSEN ==="
    exit 0
fi

# --- PREFLIGHT CHECKS ---
echo ""
info "=== Nextcloud Cookbook Multi-Category Patch ==="
info "=== Preflight Checks ==="
echo ""

# Cookbook-App vorhanden?
if [[ ! -d "$COOKBOOK_PATH" ]]; then
    error "Cookbook-App nicht gefunden: $COOKBOOK_PATH"
    error "Passe NC_PATH an: NC_PATH=/pfad/zu/nextcloud $0"
    exit 1
fi
info "Cookbook gefunden: $COOKBOOK_PATH"

# Version pruefen
APPINFO="${COOKBOOK_PATH}/appinfo/info.xml"
if [[ -f "$APPINFO" ]]; then
    VERSION=$(grep -oP '<version>\K[^<]+' "$APPINFO" 2>/dev/null || echo "unbekannt")
    info "Installierte Version: $VERSION"
    if [[ "$VERSION" != "$EXPECTED_VERSION" ]]; then
        warn "WARNUNG: Erwartet v${EXPECTED_VERSION}, gefunden v${VERSION}!"
        warn "Der Patch wurde fuer v${EXPECTED_VERSION} gebaut."
        if [[ "$ASSUME_YES" == "1" ]]; then
            error "Versions-Mismatch im non-interaktiven Modus — Abbruch."
            error "Patch wurde gegen v${EXPECTED_VERSION} gebaut, Server hat v${VERSION}."
            exit 1
        fi
        read -p "Trotzdem fortfahren? (j/N) " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[jJyY]$ ]]; then
            info "Abgebrochen."
            exit 0
        fi
    fi
fi

# Patch-Archiv vorhanden?
if [[ ! -f "$PATCH_ARCHIVE" ]]; then
    error "Patch-Archiv nicht gefunden: $PATCH_ARCHIVE"
    error "Stelle sicher, dass cookbook-multicategory.tar.gz neben diesem Script liegt."
    exit 1
fi
info "Patch-Archiv: $PATCH_ARCHIVE"

# Zu patchende Dateien existieren?
for f in \
    "lib/Helper/Filter/JSON/CleanCategoryFilter.php" \
    "lib/Db/RecipeDb.php" \
    "lib/Service/DbCacheService.php" \
    "js"; do
    if [[ ! -e "${COOKBOOK_PATH}/${f}" ]]; then
        error "Erwartete Datei/Verzeichnis fehlt: ${COOKBOOK_PATH}/${f}"
        exit 1
    fi
done
info "Alle Zieldateien vorhanden."

# Disk-Space pruefen (mindestens 100MB frei)
AVAIL_KB=$(df -k "${COOKBOOK_PATH}" | awk 'NR==2{print $4}')
if (( AVAIL_KB < 102400 )); then
    error "Weniger als 100MB freier Speicher! Abbruch."
    exit 1
fi
info "Freier Speicher: $((AVAIL_KB / 1024)) MB"

echo ""
info "=== Zusammenfassung ==="
info "  Nextcloud:    $NC_PATH"
info "  Cookbook:      $COOKBOOK_PATH"
info "  Backup nach:  $BACKUP_PATH"
info "  Web-User:     $WEB_USER"
echo ""
info "Aenderungen:"
info "  - CleanCategoryFilter.php: Array nicht mehr auf 1 Kategorie reduzieren"
info "  - RecipeDb.php:            Multi-Category DB-Operationen"
info "  - DbCacheService.php:      Diff-basiertes Category-Update"
info "  - js/*:                    Frontend mit Multi-Select fuer Kategorien"
echo ""
if [[ "$ASSUME_YES" == "1" ]]; then
    info "ASSUME_YES=1 — Patch wird ohne Rueckfrage angewendet."
    REPLY="j"
else
    read -p "Patch anwenden? (j/N) " -n 1 -r
    echo ""
fi

if [[ ! $REPLY =~ ^[jJyY]$ ]]; then
    info "Abgebrochen."
    exit 0
fi

# --- BACKUP ---
info "=== Schritt 1/5: Backup erstellen ==="
mkdir -p "$BACKUP_PATH"

# PHP-Dateien sichern
for f in \
    "lib/Helper/Filter/JSON/CleanCategoryFilter.php" \
    "lib/Db/RecipeDb.php" \
    "lib/Service/DbCacheService.php"; do
    mkdir -p "$(dirname "${BACKUP_PATH}/${f}")"
    cp -v "${COOKBOOK_PATH}/${f}" "${BACKUP_PATH}/${f}"
done

# JS-Verzeichnis komplett sichern
cp -r "${COOKBOOK_PATH}/js" "${BACKUP_PATH}/js"
info "JS-Verzeichnis gesichert ($(du -sh "${BACKUP_PATH}/js" | cut -f1))"

# Backup-Metadaten
cat > "${BACKUP_PATH}/BACKUP_INFO.txt" <<METAEOF
Backup erstellt: $(date)
Cookbook-Version: ${VERSION:-unbekannt}
Nextcloud-Pfad:  ${NC_PATH}
Patch:           Multi-Category Support
Rollback:        $(basename "$0") --rollback
METAEOF

info "Backup abgeschlossen: $BACKUP_PATH"

# --- PATCH ANWENDEN ---
info "=== Schritt 2/5: PHP-Dateien patchen ==="

# Temporaeres Verzeichnis fuer Entpacken
TMP_DIR=$(mktemp -d)
trap "rm -rf '$TMP_DIR'" EXIT

tar xzf "$PATCH_ARCHIVE" -C "$TMP_DIR"

# PHP-Dateien kopieren
for f in \
    "lib/Helper/Filter/JSON/CleanCategoryFilter.php" \
    "lib/Db/RecipeDb.php" \
    "lib/Service/DbCacheService.php"; do
    cp -v "${TMP_DIR}/${f}" "${COOKBOOK_PATH}/${f}"
done
info "PHP-Dateien gepatcht."

# --- JS ERSETZEN ---
info "=== Schritt 3/5: Frontend-Dateien ersetzen ==="
rm -rf "${COOKBOOK_PATH}/js"
cp -r "${TMP_DIR}/js" "${COOKBOOK_PATH}/js"
info "JS-Verzeichnis ersetzt ($(ls "${COOKBOOK_PATH}/js" | wc -l) Dateien)"

# --- PERMISSIONS ---
info "=== Schritt 4/5: Permissions setzen ==="
chown -R "${WEB_USER}:${WEB_USER}" \
    "${COOKBOOK_PATH}/lib/Helper/Filter/JSON/CleanCategoryFilter.php" \
    "${COOKBOOK_PATH}/lib/Db/RecipeDb.php" \
    "${COOKBOOK_PATH}/lib/Service/DbCacheService.php" \
    "${COOKBOOK_PATH}/js"
chmod 644 \
    "${COOKBOOK_PATH}/lib/Helper/Filter/JSON/CleanCategoryFilter.php" \
    "${COOKBOOK_PATH}/lib/Db/RecipeDb.php" \
    "${COOKBOOK_PATH}/lib/Service/DbCacheService.php"
find "${COOKBOOK_PATH}/js" -type f -exec chmod 644 {} \;
info "Permissions gesetzt."

# --- CACHE LEEREN ---
info "=== Schritt 5/5: Cache leeren ==="

# OPcache invalidieren (falls PHP-FPM / mod_php)
if command -v php &>/dev/null; then
    # Nextcloud Maintenance
    sudo -u "${WEB_USER}" php "${NC_PATH}/occ" maintenance:repair 2>/dev/null && \
        info "occ maintenance:repair ausgefuehrt." || \
        warn "occ maintenance:repair fehlgeschlagen (nicht kritisch)."

    # OPcache Reset via CLI (wirkt nur fuer CLI, aber schadet nicht)
    php -r 'if(function_exists("opcache_reset")){opcache_reset();echo "OPcache reset.\n";}' 2>/dev/null || true
fi

# Apache/Nginx Reload fuer OPcache Reset
if systemctl is-active --quiet apache2 2>/dev/null; then
    systemctl reload apache2
    info "Apache2 reloaded (OPcache invalidiert)."
elif systemctl is-active --quiet nginx 2>/dev/null; then
    # Bei PHP-FPM muss der FPM-Pool restartet werden
    if systemctl is-active --quiet php*-fpm 2>/dev/null; then
        FPM_SERVICE=$(systemctl list-units --type=service --state=running | grep -oP 'php[\d.]+-fpm\.service' | head -1)
        if [[ -n "$FPM_SERVICE" ]]; then
            systemctl reload "$FPM_SERVICE"
            info "$FPM_SERVICE reloaded (OPcache invalidiert)."
        fi
    fi
fi

echo ""
info "============================================="
info "  PATCH ERFOLGREICH ANGEWENDET!"
info "============================================="
info ""
info "  Was sich geaendert hat:"
info "  - Rezepte koennen jetzt MEHREREN Kategorien zugeordnet werden"
info "  - Das Kategorie-Feld im Editor ist jetzt Multi-Select"
info "  - Rezepte tauchen in ALLEN zugewiesenen Kategorien in der Sidebar auf"
info "  - Bestehende Rezepte behalten ihre bisherige Einzelkategorie"
info ""
info "  Rollback bei Problemen:"
info "    sudo $0 --rollback"
info ""
info "  Backup liegt in:"
info "    $BACKUP_PATH"
info "============================================="
