package defaultsfs

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestStoreReadDefaults(t *testing.T) {
	catalog := t.TempDir()
	path := filepath.Join(catalog, "catalog", "onboard-defaults.json")
	writeFile(t, path, `{
	  "_schema_version": 1,
	  "branch_protection": {"required_status_checks": null, "restrictions": null},
	  "merge_hygiene": {"delete_branch_on_merge": true},
	  "repo_settings": {"has_issues": true},
	  "topics_additive": ["serverkraken-onboarded"]
	}`)
	cfg, err := (Store{}).ReadDefaults(catalog)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.SchemaVersion != 1 || !cfg.MergeHygiene.DeleteBranchOnMerge || len(cfg.TopicsAdditive) != 1 {
		t.Fatalf("cfg=%+v", cfg)
	}
	if _, err := (Store{}).ReadDefaults(t.TempDir()); err == nil || !strings.Contains(err.Error(), "config not found") {
		t.Fatalf("missing err=%v", err)
	}
	bad := t.TempDir()
	writeFile(t, filepath.Join(bad, "catalog", "onboard-defaults.json"), "{")
	if _, err := (Store{}).ReadDefaults(bad); err == nil || !strings.Contains(err.Error(), "invalid JSON") {
		t.Fatalf("invalid err=%v", err)
	}
}

func TestStoreTargetAndLock(t *testing.T) {
	store := Store{}
	target := t.TempDir()
	ok, err := store.TargetExists(target)
	if err != nil || !ok {
		t.Fatalf("target exists=%v err=%v", ok, err)
	}
	ok, err = store.TargetExists(filepath.Join(target, "missing"))
	if err != nil || ok {
		t.Fatalf("missing target exists=%v err=%v", ok, err)
	}
	fileTarget := filepath.Join(target, "file")
	writeFile(t, fileTarget, "not a dir")
	ok, err = store.TargetExists(fileTarget)
	if err != nil || ok {
		t.Fatalf("file target exists=%v err=%v", ok, err)
	}
	lock, err := store.LockExists(target)
	if err != nil || lock {
		t.Fatalf("lock exists=%v err=%v", lock, err)
	}
	lockPath := filepath.Join(target, ".github", "onboard.lock.json")
	writeFile(t, lockPath, `{"schema_version":1,"catalog_version":"v4"}`)
	lock, err = store.LockExists(target)
	if err != nil || !lock {
		t.Fatalf("lock exists=%v err=%v", lock, err)
	}
	if err := store.UpdateLockDefaultsMarker(target, "2026-06-02T12:00:00Z"); err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(lockPath)
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal(content, &got); err != nil {
		t.Fatal(err)
	}
	if got["schema_version"].(float64) != 2 || got["defaults_applied_at"] != "2026-06-02T12:00:00Z" {
		t.Fatalf("lock=%v", got)
	}
}

func TestStoreUpdateLockErrors(t *testing.T) {
	target := t.TempDir()
	if err := (Store{}).UpdateLockDefaultsMarker(target, "x"); err == nil {
		t.Fatal("expected missing lock error")
	}
	writeFile(t, filepath.Join(target, ".github", "onboard.lock.json"), "{")
	if err := (Store{}).UpdateLockDefaultsMarker(target, "x"); err == nil {
		t.Fatal("expected invalid lock error")
	}
	blocked := t.TempDir()
	writeFile(t, filepath.Join(blocked, ".github", "onboard.lock.json"), `{"schema_version":1}`)
	if err := os.Chmod(filepath.Join(blocked, ".github"), 0o500); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = os.Chmod(filepath.Join(blocked, ".github"), 0o700) }()
	if err := (Store{}).UpdateLockDefaultsMarker(blocked, "x"); err == nil {
		t.Fatal("expected temp file creation error")
	}
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// Audit C-11. `null` ist gueltiges JSON und laesst die Map NIL zurueck —
// Unmarshal meldet dabei KEINEN Fehler, und der Schreibzugriff danach paniked
// mit "assignment to entry in nil map". Gemessen an vier Inhalten fiel nur
// `null` aus der Reihe: [] und "text" liefern saubere Fehler, {} geht durch.
//
// Das wiegt schwerer als ein Absturz an anderer Stelle: dieser Schritt laeuft
// NACH den GitHub-Mutationen. Ein Panic hinterlaesst die Repo-Defaults gesetzt,
// den Lock aber unmarkiert — beim naechsten Lauf sieht es aus, als waere nie
// etwas passiert.
func TestUpdateLockDefaultsMarkerRejectsJSONNull(t *testing.T) {
	dir := t.TempDir()
	gh := filepath.Join(dir, ".github")
	if err := os.MkdirAll(gh, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(gh, "onboard.lock.json"), []byte("null\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("erwartet: Fehler, bekommen: Panic %v", r)
		}
	}()
	err := (Store{}).UpdateLockDefaultsMarker(dir, "2026-01-01T00:00:00Z")
	if err == nil {
		t.Fatal("erwartet: Fehler bei einem Lock, der nur `null` enthaelt")
	}
	if !strings.Contains(err.Error(), "JSON null") {
		t.Fatalf("Grund fehlt in der Meldung: %v", err)
	}
}

// Gegenprobe: ein leeres OBJEKT ist ein legitimer Lock-Anfang und muss weiter
// durchgehen. Ohne diese Zusicherung koennte die Nil-Pruefung stillschweigend
// zu weit greifen.
func TestUpdateLockDefaultsMarkerAcceptsEmptyObject(t *testing.T) {
	dir := t.TempDir()
	gh := filepath.Join(dir, ".github")
	if err := os.MkdirAll(gh, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(gh, "onboard.lock.json"), []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := (Store{}).UpdateLockDefaultsMarker(dir, "2026-01-01T00:00:00Z"); err != nil {
		t.Fatalf("ein leeres Objekt muss durchgehen: %v", err)
	}
}
