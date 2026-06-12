#!/usr/bin/env php
<?php
/**
 * Nextcloud Cookbook — Keyword-zu-Kategorie Migration
 *
 * Findet alle Rezepte die ein bestimmtes Keyword haben aber NICHT
 * die entsprechende Kategorie, und fuegt die Kategorie hinzu.
 *
 * Aktualisiert BEIDES: JSON-Dateien (Source of Truth) + DB-Cache.
 *
 * Usage:
 *   sudo -u www-data php migrate-keyword-to-category.php [--dry-run] [--keyword=X] [--nc-path=/var/www/nextcloud]
 *
 * Beispiele:
 *   # Trockentest (aendert nichts):
 *   sudo -u www-data php migrate-keyword-to-category.php --dry-run
 *
 *   # Ausfuehren mit Default "Hauptgericht":
 *   sudo -u www-data php migrate-keyword-to-category.php
 *
 *   # Anderes Keyword:
 *   sudo -u www-data php migrate-keyword-to-category.php --keyword=Dessert
 *
 *   # Mehrere Keywords auf einmal:
 *   sudo -u www-data php migrate-keyword-to-category.php --keyword=Hauptgericht
 *   sudo -u www-data php migrate-keyword-to-category.php --keyword=Dessert
 *   sudo -u www-data php migrate-keyword-to-category.php --keyword=Vorspeise
 */

// --- CLI-Argumente ---
$opts = getopt('', ['dry-run', 'debug', 'keyword:', 'nc-path:', 'help']);

if (isset($opts['help'])) {
    echo file_get_contents(__FILE__);
    exit(0);
}

$dryRun   = isset($opts['dry-run']);
$debug    = isset($opts['debug']);
$keyword  = $opts['keyword'] ?? 'Hauptgericht';
$ncPath   = $opts['nc-path'] ?? '/var/www/nextcloud';

echo "=== Cookbook: Keyword → Kategorie Migration ===\n";
echo "  Keyword:    {$keyword}\n";
echo "  Kategorie:  {$keyword}\n";
echo "  NC-Pfad:    {$ncPath}\n";
echo "  Modus:      " . ($dryRun ? "DRY RUN (keine Aenderungen)" : "LIVE") . "\n";
echo "\n";

// --- Nextcloud Config laden ---
$configFile = "{$ncPath}/config/config.php";
if (!file_exists($configFile)) {
    fwrite(STDERR, "ERROR: config.php nicht gefunden: {$configFile}\n");
    fwrite(STDERR, "  Nutze --nc-path=/pfad/zu/nextcloud\n");
    exit(1);
}

$CONFIG = [];
include $configFile;

$dbType   = $CONFIG['dbtype'] ?? 'sqlite3';
$dbName   = $CONFIG['dbname'] ?? 'nextcloud';
$dbHost   = $CONFIG['dbhost'] ?? 'localhost';
$dbUser   = $CONFIG['dbuser'] ?? '';
$dbPass   = $CONFIG['dbpassword'] ?? '';
$dbPrefix = $CONFIG['dbtableprefix'] ?? 'oc_';
$dataDir  = $CONFIG['datadirectory'] ?? "{$ncPath}/data";

echo "  DB-Typ:     {$dbType}\n";
echo "  Daten-Dir:  {$dataDir}\n";
echo "\n";

// --- DB-Verbindung ---
try {
    switch ($dbType) {
        case 'sqlite3':
        case 'sqlite':
            $dbFile = "{$dataDir}/owncloud.db";
            if (!file_exists($dbFile)) {
                $dbFile = "{$dataDir}/nextcloud.db";
            }
            if (!file_exists($dbFile)) {
                fwrite(STDERR, "ERROR: SQLite-DB nicht gefunden in {$dataDir}\n");
                exit(1);
            }
            $pdo = new PDO("sqlite:{$dbFile}");
            break;

        case 'mysql':
            // Handle socket vs TCP
            if (strpos($dbHost, ':') !== false) {
                $parts = explode(':', $dbHost, 2);
                if (file_exists($parts[1])) {
                    $dsn = "mysql:unix_socket={$parts[1]};dbname={$dbName};charset=utf8mb4";
                } else {
                    $dsn = "mysql:host={$parts[0]};port={$parts[1]};dbname={$dbName};charset=utf8mb4";
                }
            } else {
                $dsn = "mysql:host={$dbHost};dbname={$dbName};charset=utf8mb4";
            }
            $pdo = new PDO($dsn, $dbUser, $dbPass);
            break;

        case 'pgsql':
            $dsn = "pgsql:host={$dbHost};dbname={$dbName}";
            $pdo = new PDO($dsn, $dbUser, $dbPass);
            break;

        default:
            fwrite(STDERR, "ERROR: Unbekannter DB-Typ: {$dbType}\n");
            exit(1);
    }
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
} catch (PDOException $e) {
    fwrite(STDERR, "ERROR: DB-Verbindung fehlgeschlagen: {$e->getMessage()}\n");
    exit(1);
}

echo "DB-Verbindung OK.\n\n";

// Tabellennamen
$tKeywords   = "{$dbPrefix}cookbook_keywords";
$tCategories = "{$dbPrefix}cookbook_categories";
$tFilecache  = "{$dbPrefix}filecache";
$tStorages   = "{$dbPrefix}storages";

// --- Schritt 1: Betroffene Rezepte finden ---
echo "=== Schritt 1: Rezepte mit Keyword '{$keyword}' OHNE Kategorie '{$keyword}' suchen ===\n";

$sql = "
    SELECT k.recipe_id, k.user_id
    FROM {$tKeywords} k
    WHERE k.name = :keyword
    AND NOT EXISTS (
        SELECT 1 FROM {$tCategories} c
        WHERE c.recipe_id = k.recipe_id
        AND c.user_id = k.user_id
        AND c.name = :keyword2
    )
    ORDER BY k.user_id, k.recipe_id
";

$stmt = $pdo->prepare($sql);
$stmt->execute([':keyword' => $keyword, ':keyword2' => $keyword]);
$affected = $stmt->fetchAll(PDO::FETCH_ASSOC);

if (empty($affected)) {
    echo "\nKeine Rezepte gefunden die migriert werden muessen.\n";
    echo "Alle Rezepte mit Keyword '{$keyword}' haben bereits die Kategorie.\n";
    exit(0);
}

echo "Gefunden: " . count($affected) . " Rezept(e)\n\n";

// --- Schritt 2: Rezeptnamen und Dateipfade ermitteln ---
echo "=== Schritt 2: Rezeptdetails und Dateipfade ermitteln ===\n";

$recipes = [];
foreach ($affected as $row) {
    $rid = $row['recipe_id'];
    $uid = $row['user_id'];

    // Rezeptname aus cookbook_names
    $nameStmt = $pdo->prepare("SELECT name FROM {$dbPrefix}cookbook_names WHERE recipe_id = :rid AND user_id = :uid");
    $nameStmt->execute([':rid' => $rid, ':uid' => $uid]);
    $nameRow = $nameStmt->fetch(PDO::FETCH_ASSOC);
    $recipeName = $nameRow ? $nameRow['name'] : '(unbekannt)';

    // Bestehende Kategorien
    $catStmt = $pdo->prepare("SELECT name FROM {$tCategories} WHERE recipe_id = :rid AND user_id = :uid");
    $catStmt->execute([':rid' => $rid, ':uid' => $uid]);
    $existingCats = $catStmt->fetchAll(PDO::FETCH_COLUMN);

    // Dateipfad ueber filecache (recipe_id = folder_id in Nextcloud)
    $pathStmt = $pdo->prepare("
        SELECT fc.path, s.id AS storage_id
        FROM {$tFilecache} fc
        JOIN {$tStorages} s ON fc.storage = s.numeric_id
        WHERE fc.fileid = :fid
    ");
    $pathStmt->execute([':fid' => $rid]);
    $pathRow = $pathStmt->fetch(PDO::FETCH_ASSOC);

    $jsonPath = null;
    if ($pathRow) {
        $storagePath = $pathRow['path'];
        $storageId   = $pathRow['storage_id'];

        // Storage-Owner aus storage_id extrahieren (home::username)
        $storageOwner = $uid;
        if (preg_match('/^home::(.+)$/', $storageId, $m)) {
            $storageOwner = $m[1];
        }

        // Basis-Ordner bestimmen
        $baseDirs = [
            "{$dataDir}/{$storageOwner}/{$storagePath}",
        ];
        // Falls storage_owner != user_id (Share), auch den Owner-Pfad probieren
        if ($storageOwner !== $uid) {
            // Beim Share: Datei liegt beim Owner, nicht beim Share-Empfaenger
            // (uid-Pfad nicht probieren — die Datei existiert dort nicht)
        } else {
            $baseDirs[] = "{$dataDir}/{$storagePath}";
        }
        // local:: Storage
        if (strpos($storageId, 'local::') === 0) {
            $localRoot = substr($storageId, 7);
            $baseDirs[] = "{$localRoot}{$storagePath}";
        }

        // In jedem Basis-Ordner: erst recipe.json, dann *.json (alte Struktur)
        foreach ($baseDirs as $baseDir) {
            // 1) recipe.json (Standard)
            $candidate = "{$baseDir}/recipe.json";
            if (file_exists($candidate)) {
                $jsonPath = $candidate;
                break;
            }
            // 2) Beliebige .json Datei im Ordner (alte Struktur: Rezeptname.json)
            if (is_dir($baseDir)) {
                $jsonFiles = glob("{$baseDir}/*.json");
                if (!empty($jsonFiles)) {
                    $jsonPath = $jsonFiles[0];
                    break;
                }
            }
        }

        if ($debug) {
            echo "  DEBUG [{$rid}] storage_id={$storageId} owner={$storageOwner} user={$uid} path={$storagePath}\n";
            foreach ($baseDirs as $i => $bd) {
                $recipeExists = file_exists("{$bd}/recipe.json") ? 'EXISTS' : 'MISSING';
                echo "    base[{$i}]: {$bd}/recipe.json → {$recipeExists}\n";
                if ($recipeExists === 'MISSING' && is_dir($bd)) {
                    $files = scandir($bd);
                    $files = array_diff($files, ['.', '..']);
                    $jsonFiles = array_filter($files, fn($f) => str_ends_with($f, '.json'));
                    if (!empty($jsonFiles)) {
                        echo "    base[{$i}]: Alternatives JSON: " . implode(', ', $jsonFiles) . "\n";
                    }
                }
            }
            if ($jsonPath) {
                echo "    → Gewaehlt: {$jsonPath}\n";
            }
        }
    } else {
        if ($debug) {
            echo "  DEBUG [{$rid}] KEIN Eintrag in filecache gefunden!\n";
        }
    }

    $recipes[] = [
        'recipe_id'     => $rid,
        'user_id'       => $uid,
        'name'          => $recipeName,
        'existing_cats'  => $existingCats,
        'json_path'     => $jsonPath,
    ];

    $catStr = empty($existingCats) ? '(keine)' : implode(', ', $existingCats);
    $pathStr = $jsonPath && file_exists($jsonPath) ? 'OK' : 'NICHT GEFUNDEN';
    echo "  [{$rid}] {$recipeName}\n";
    echo "        User: {$uid} | Kategorien: {$catStr} | JSON: {$pathStr}\n";
}

echo "\n";

// --- Bestaetigung ---
if (!$dryRun) {
    echo "Soll '{$keyword}' als Kategorie zu diesen " . count($recipes) . " Rezept(en) hinzugefuegt werden?\n";
    echo "Eingabe 'j' zum Fortfahren: ";
    $handle = fopen("php://stdin", "r");
    $input = trim(fgets($handle));
    fclose($handle);

    if (!in_array(strtolower($input), ['j', 'ja', 'y', 'yes'])) {
        echo "Abgebrochen.\n";
        exit(0);
    }
    echo "\n";
}

// --- Schritt 3: JSON-Dateien aktualisieren ---
echo "=== Schritt 3: JSON-Dateien aktualisieren ===\n";

$jsonUpdated = 0;
$jsonFailed  = 0;
$jsonAlreadyDone = []; // Track bereits aktualisierte Dateien (Shares!)

foreach ($recipes as &$r) {
    $path = $r['json_path'];

    if (!$path || !file_exists($path)) {
        // Bei Shares: JSON liegt beim Owner, nicht beim Empfaenger.
        // Wenn dieselbe recipe_id schon via Owner aktualisiert wurde → nur DB
        if (isset($jsonAlreadyDone[$path ?? $r['recipe_id']])) {
            $r['migrated'] = true; // DB-Insert trotzdem machen
            echo "  SHARE [{$r['recipe_id']}] {$r['name']} (User: {$r['user_id']}) — JSON bereits via Owner aktualisiert, nur DB\n";
            continue;
        }
        echo "  SKIP [{$r['recipe_id']}] {$r['name']} (User: {$r['user_id']}) — JSON nicht gefunden\n";
        $jsonFailed++;
        continue;
    }

    // Duplikat-Check: selbe Datei schon geschrieben? (Share-Szenario)
    $realPath = realpath($path);
    if (isset($jsonAlreadyDone[$realPath])) {
        $r['migrated'] = true; // DB-Insert trotzdem machen
        echo "  SHARE [{$r['recipe_id']}] {$r['name']} (User: {$r['user_id']}) — JSON bereits aktualisiert, nur DB\n";
        continue;
    }

    $content = file_get_contents($path);
    $json = json_decode($content, true);

    if (!$json) {
        echo "  SKIP [{$r['recipe_id']}] {$r['name']} — JSON parse error\n";
        $jsonFailed++;
        continue;
    }

    // recipeCategory lesen und normalisieren
    $cats = [];
    if (isset($json['recipeCategory'])) {
        if (is_array($json['recipeCategory'])) {
            $cats = $json['recipeCategory'];
        } elseif (is_string($json['recipeCategory']) && strlen(trim($json['recipeCategory'])) > 0) {
            $cats = array_map('trim', explode(',', $json['recipeCategory']));
        }
    }

    // Pruefen ob Keyword schon als Kategorie drin ist (Sicherheitscheck)
    if (in_array($keyword, $cats)) {
        echo "  SKIP [{$r['recipe_id']}] {$r['name']} — Kategorie bereits vorhanden\n";
        continue;
    }

    // Kategorie hinzufuegen
    $cats[] = $keyword;
    $cats = array_filter($cats, function($c) { return strlen(trim($c)) > 0; });
    $cats = array_values(array_unique($cats));

    // Als Komma-String speichern (kompatibel mit gepatchtem Filter)
    $json['recipeCategory'] = implode(',', $cats);

    if ($dryRun) {
        echo "  DRY  [{$r['recipe_id']}] {$r['name']} — wuerde zu: {$json['recipeCategory']}\n";
    } else {
        // Backup der JSON-Datei
        copy($path, $path . '.bak');

        // Schreiben
        $newContent = json_encode($json, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        file_put_contents($path, $newContent);
        echo "  OK   [{$r['recipe_id']}] {$r['name']} → Kategorien: {$json['recipeCategory']}\n";
    }

    $jsonUpdated++;
    $r['migrated'] = true;
    $jsonAlreadyDone[$realPath] = true;
}
unset($r);

echo "\nJSON: {$jsonUpdated} aktualisiert, {$jsonFailed} uebersprungen\n\n";

// --- Schritt 4: DB-Cache aktualisieren ---
echo "=== Schritt 4: DB-Cache aktualisieren ===\n";

$dbInserted = 0;

if (!$dryRun) {
    $insertStmt = $pdo->prepare("
        INSERT INTO {$tCategories} (recipe_id, name, user_id)
        VALUES (:rid, :name, :uid)
    ");

    foreach ($recipes as $r) {
        if (!isset($r['migrated']) || !$r['migrated']) {
            continue;
        }

        try {
            $insertStmt->execute([
                ':rid'  => $r['recipe_id'],
                ':name' => $keyword,
                ':uid'  => $r['user_id'],
            ]);
            echo "  DB   [{$r['recipe_id']}] {$r['name']} — Kategorie '{$keyword}' eingefuegt\n";
            $dbInserted++;
        } catch (PDOException $e) {
            echo "  FAIL [{$r['recipe_id']}] {$r['name']} — {$e->getMessage()}\n";
        }
    }
} else {
    foreach ($recipes as $r) {
        if (isset($r['migrated']) && $r['migrated']) {
            echo "  DRY  [{$r['recipe_id']}] {$r['name']} — DB INSERT wuerde ausgefuehrt\n";
            $dbInserted++;
        }
    }
}

echo "\nDB: {$dbInserted} Zeilen " . ($dryRun ? "wuerden eingefuegt" : "eingefuegt") . "\n\n";

// --- Zusammenfassung ---
echo "=== Zusammenfassung ===\n";
echo "  Keyword:            {$keyword}\n";
echo "  Rezepte gefunden:   " . count($recipes) . "\n";
echo "  JSON aktualisiert:  {$jsonUpdated}\n";
echo "  DB-Zeilen:          {$dbInserted}\n";

if ($dryRun) {
    echo "\n  Dies war ein DRY RUN. Keine Aenderungen vorgenommen.\n";
    echo "  Zum Ausfuehren: Ohne --dry-run starten.\n";
}

if (!$dryRun && $jsonFailed > 0) {
    echo "\n  WARNUNG: {$jsonFailed} JSON-Datei(en) konnten nicht aktualisiert werden!\n";
    echo "  Diese Rezepte haben die Kategorie nur in der DB, nicht in der JSON-Datei.\n";
    echo "  Beim naechsten Cache-Rebuild koennten die DB-Eintraege verloren gehen.\n";
    echo "  Loesung: Rezept im Editor oeffnen, Kategorie manuell hinzufuegen, speichern.\n";
}

if (!$dryRun && $jsonUpdated > 0) {
    echo "\n  JSON-Backups liegen neben den Originalen als *.bak\n";
    echo "  Zum Aufraeumen spaeter: find {$dataDir} -name 'recipe.json.bak' -delete\n";
}

echo "\nFertig.\n";
