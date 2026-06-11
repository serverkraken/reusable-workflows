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
		tmp.Close()
		os.Remove(tmpPath)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpPath)
		return err
	}
	if err := os.Rename(tmpPath, path); err != nil {
		os.Remove(tmpPath)
		return err
	}
	return nil
}

func lockPath(targetPath string) string {
	return filepath.Join(targetPath, ".github", "onboard.lock.json")
}
