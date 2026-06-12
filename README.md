<div align="center">

# 🍲 Nextcloud Cookbook — Multi-Category Fork

**Ein Rezept, mehrere Kategorien.** Genau das, was das Upstream-Projekt nicht will.

</div>

---

## Was ist das?

Ein Fork von [nextcloud/cookbook](https://github.com/nextcloud/cookbook) mit einer Änderung:
Rezepte können **mehreren Kategorien** zugewiesen werden, statt nur einer.

- **Editor:** Das Kategorie-Feld ist ein Multi-Select — beliebig viele Kategorien pro Rezept.
- **Rezept-Ansicht:** Die Kategorien erscheinen als dezent getönte, klickbare Chips direkt unter
  dem Rezeptnamen (über den Keywords). Klick führt zur jeweiligen Kategorie-Übersicht.

Alles andere ist die unveränderte, offizielle Cookbook-App. Wir ziehen jede neue Upstream-Version,
legen den Patch drüber, bauen ein fertiges Archiv und veröffentlichen es als Release — **du musst
nichts kompilieren.**

## Warum ein Fork?

Multiple Kategorien pro Rezept werden seit Jahren gewünscht und **wiederholt abgelehnt**, obwohl
schema.org `recipeCategory` ausdrücklich eine Liste erlaubt:

| Issue | Status |
|---|---|
| [#277](https://github.com/nextcloud/cookbook/issues/277) (2020) „Multiple categories for each recipe" | geschlossen, nie umgesetzt |
| [#2605](https://github.com/nextcloud/cookbook/issues/2605) „Allow for multiple categories" | offen, ignoriert |
| [#2550](https://github.com/nextcloud/cookbook/issues/2550) / [#3018](https://github.com/nextcloud/cookbook/issues/3018) „mehrere wählbar, nur eine gespeichert" | „COMPLETED" — gelöst durch **[PR #3080](https://github.com/nextcloud/cookbook/pull/3080) „Do not allow multiple categories in the frontend"** (2026-04-02): Multi-Select **absichtlich entfernt** statt das Backend zu reparieren |

Wenn ein sinnvolles Feature lange genug abgelehnt wird, baut es eben jemand selbst.

## Installation (ohne Compile)

Auf dem Nextcloud-Server, als root:

```bash
curl -fsSL https://raw.githubusercontent.com/dm7ds/cookbook/multicategory/install.sh | sudo bash
```

Das Script erkennt deine Nextcloud-Installation, sichert die aktuelle Cookbook-App + DB,
lädt das neueste Release, deployt es und aktiviert die App. **Upgrade = dasselbe Script nochmal.**

Alternativ manuell: aktuelles [Release](https://github.com/dm7ds/cookbook/releases) herunterladen,
nach `apps/` (bzw. `custom_apps/`) entpacken, `occ app:enable cookbook`.

> ⚠️ Es wird vorher automatisch ein Backup nach `/root/cookbook-backups/` angelegt. Rollback-Pfad
> steht am Ende der Installer-Ausgabe.

## Der Patch

Fünf Dateien (Branch [`multicategory`](https://github.com/dm7ds/cookbook/tree/multicategory),
ein Commit auf dem jeweiligen Upstream-Tag):

- `lib/Db/RecipeDb.php` — Multi-Category-DB-Operationen
- `lib/Service/DbCacheService.php` — diff-basiertes Category-Update
- `lib/Helper/Filter/JSON/CleanCategoryFilter.php` — Kategorie-Array nicht auf eins reduzieren
- `src/components/RecipeEdit.vue` — Multi-Select-UI im Editor
- `src/components/RecipeView/RecipeView.vue` — Kategorie-Chips in der Rezept-Ansicht

Die komplette Fork-Infrastruktur (Build-/Deploy-Scripts + Patch) liegt versioniert unter
[`.maintainer/`](https://github.com/dm7ds/cookbook/tree/multicategory/.maintainer).

## Lizenz & Credits

Dies ist ein Fork. Die gesamte Cookbook-App stammt vom
[Nextcloud-Cookbook-Team](https://github.com/nextcloud/cookbook) und steht unter **AGPL-3.0**
(siehe [`LICENSE`](LICENSE) / [`COPYING`](COPYING)). Wir beanspruchen nur den Multi-Category-Patch.
Falls Upstream das Feature doch mal aufnimmt, ist dieser Fork überflüssig — gern.
