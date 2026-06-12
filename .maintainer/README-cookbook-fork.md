# Cookbook Multi-Category Fork — Anleitung

Privat gepflegter Fork von [nextcloud/cookbook](https://github.com/nextcloud/cookbook)
mit **Multi-Category-Support** (Rezepte mehreren Kategorien zuweisen).

> ## Warum dieser Fork existiert
>
> Multiple Kategorien pro Rezept werden von der Community **seit Jahren** gewünscht
> und vom Upstream-Projekt **wiederholt abgelehnt**:
>
> - **#277** (2020) „Multiple categories for each recipe" — geschlossen, nie umgesetzt
> - **#2605** „Allow for multiple categories" — offen, ignoriert
> - **#2550 / #3018** „mehrere wählbar, nur eine gespeichert" — als „COMPLETED" geschlossen,
>   aber die „Lösung" war **PR #3080 „Do not allow multiple categories in the frontend"**
>   (merged 2026-04-02): Statt das Backend zu reparieren wurde das Multi-Select
>   **bewusst aus dem Frontend entfernt**.
>
> Wer ein Feature jahrelang ablehnt obwohl schema.org `recipeCategory` explizit als
> Array erlaubt und die halbe Userbase danach fragt, darf sich nicht wundern wenn man
> es **selbst baut**. Genau das ist hier passiert. Der Patch ist offen, dokumentiert
> und reproduzierbar — falls jemand beim Upstream doch mal Lust bekommt.

## Was liegt wo

| Pfad | Inhalt |
|---|---|
| `source/` | Git-Checkout. `upstream` = nextcloud/cookbook, `origin` = dm7ds/cookbook (privat). Branch `multicategory` trägt den Patch-Commit. |
| `cookbook-update.sh` | **Das Knopfdruck-Script** — rebase → build → deploy → verify |
| `multicategory-patch/patches/*.patch` | Der Patch als Format-Patch (SSOT des Deltas, versionsunabhängig) |
| `multicategory-patch/deploy-multicategory.sh` | Server-Deploy (Backup + Rollback + Cache-Clear), non-interaktiv via `ASSUME_YES=1` |
| `multicategory-patch/migrate-keyword-to-category.php` | DB-Migration Keyword→Category (selten gebraucht) |

## Der Patch = 4 Dateien

- `lib/Db/RecipeDb.php` — Multi-Category DB-Operationen
- `lib/Service/DbCacheService.php` — Diff-basiertes Category-Update
- `lib/Helper/Filter/JSON/CleanCategoryFilter.php` — Kategorie-Array nicht auf 1 reduzieren
- `src/components/RecipeEdit.vue` — Multi-Select-UI (wird zu `js/` kompiliert)

## Updaten — der normale Fall

Wenn Nextcloud die Cookbook-App aktualisiert hat (oder du es willst), bringt **ein Befehl**
den Patch wieder drauf:

```bash
cd D:/Development/nextcloud-cookbook
./cookbook-update.sh              # Ziel = die Version die auf dem Server liegt
```

Das Script:
1. liest die Cookbook-Version vom Server
2. rebased den Patch auf diese Version (`git am --3way`)
3. baut das Frontend lokal (`npm ci` + `npm run build`)
4. packt das Deploy-Archiv und deployt es auf den Server
5. verifiziert (HTTP 200)

**Vor dem Deploy auf eine neue Version testen:**
```bash
./cookbook-update.sh --to v0.12.0 --dry-run   # rebase + build prüfen, NICHT deployen
```

Weitere Optionen: `--latest` (neuestes Upstream-Release), `--no-deploy` (nur bauen).

## Wenn ein Konflikt kommt (der #3080-Fall)

Sobald du auf eine Version ≥ dem #3080-Release gehst, fasst Upstream `RecipeEdit.vue`
so an, dass der Patch nicht mehr sauber passt. Das Script **stoppt hart** und zeigt:

```
cd source
# Konflikte in den genannten Dateien manuell auflösen, dann:
git add <dateien> && git am --continue
# Patch neu exportieren, damit der Fix dauerhaft drin ist:
git format-patch v0.11.6..HEAD -o ../multicategory-patch/patches/
# dann ./cookbook-update.sh erneut starten
```

Nichts wird deployt solange der Konflikt nicht gelöst ist.

## Rollback

Das Deploy-Script legt vor jedem Patch ein vollständiges Backup an
(`/root/cookbook-backups/`). Zurück geht's auf dem Server mit:

```bash
sudo ./deploy-multicategory.sh --rollback
```

## Off-Site-Backup

Der komplette Patch ist auf GitHub gesichert: **dm7ds/cookbook** (privat),
Branch `multicategory`, Tag `patch-base-v0.11.6`. Plus die `.patch`-Datei lokal.
Selbst bei Totalverlust von `source/` ist die Logik reproduzierbar.

## Server

`ssh -i ~/.ssh/claude_planlos_key -p 2222 ubuntu@planlos.net`
App: `/var/www/nextcloud/apps/cookbook/` · Backups: `/root/cookbook-backups/`
