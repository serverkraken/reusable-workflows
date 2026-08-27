package defaultsfs

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/serverkraken/reusable-workflows/internal/domain"
)

type Store struct{}

func (Store) ReadDefaults(catalogPath string) (domain.RepoDefaults, error) {
	path := filepath.Join(catalogPath, "catalog", "onboard-defaults.json")
	content, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return domain.RepoDefaults{}, fmt.Errorf("config not found: %s", path)
		}
		return domain.RepoDefaults{}, err
	}
	var cfg domain.RepoDefaults
	if err := json.Unmarshal(content, &cfg); err != nil {
		return domain.RepoDefaults{}, fmt.Errorf("invalid JSON in %s: %w", path, err)
	}
	// Gueltiges JSON ist nicht genug: `{}` parst fehlerfrei zum Nullwert, und
	// der bedeutet hier "alle Schutzschalter aus". Siehe die Herleitung an
	// domain.SupportedDefaultsSchema.
	if cfg.SchemaVersion != domain.SupportedDefaultsSchema {
		return domain.RepoDefaults{}, fmt.Errorf(
			"%s: _schema_version ist %d, unterstuetzt wird %d — die Datei ist leer, abgeschnitten oder aus einer anderen Fassung",
			path, cfg.SchemaVersion, domain.SupportedDefaultsSchema)
	}
	return cfg, nil
}

func (Store) TargetExists(targetPath string) (bool, error) {
	info, err := os.Stat(targetPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return false, nil
		}
		return false, err
	}
	return info.IsDir(), nil
}

func (Store) LockExists(targetPath string) (bool, error) {
	_, err := os.Stat(lockPath(targetPath))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

func (Store) UpdateLockDefaultsMarker(targetPath, marker string) error {
	path := lockPath(targetPath)
	content, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var lock map[string]any
	if err := json.Unmarshal(content, &lock); err != nil {
		return err
	}
	// `null` ist gueltiges JSON und laesst die Map NIL zurueck — der
	// Schreibzugriff darunter paniked dann mit "assignment to entry in nil
	// map" (Audit C-11). Gemessen an vier Inhalten:
	//
	//	null      PANIC
	//	{}        ok
	//	[]        sauberer Fehler
	//	"text"    sauberer Fehler
	//
	// Nur `null` faellt aus der Reihe: Unmarshal MELDET keinen Fehler.
	//
	// Das wiegt hier schwerer als ein Absturz an anderer Stelle: dieser
	// Schritt laeuft NACH den GitHub-Mutationen. Ein Panic hinterlaesst die
	// Repo-Defaults gesetzt, den Lock aber unmarkiert — beim naechsten Lauf
	// sieht es aus, als waere nie etwas passiert.
	if lock == nil {
		return fmt.Errorf("%s contains JSON null, not an object — the lock is corrupt; restore it or delete it and re-onboard", path)
	}
	lock["schema_version"] = 2
	lock["defaults_applied_at"] = marker
	next, err := json.MarshalIndent(lock, "", "  ")
	if err != nil {
		return err
	}
	next = append(next, '\n')
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".onboard.lock.*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	if _, err := tmp.Write(next); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpPath)
		return err
	}
	if err := os.Rename(tmpPath, path); err != nil {
		_ = os.Remove(tmpPath)
		return err
	}
	return nil
}

func lockPath(targetPath string) string {
	return filepath.Join(targetPath, ".github", "onboard.lock.json")
}
