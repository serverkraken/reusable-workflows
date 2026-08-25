package domain

type OnboardLock struct {
	SchemaVersion   int               `json:"schema_version"`
	CatalogVersion  string            `json:"catalog_version"`
	RenderedAt      string            `json:"rendered_at"`
	RenderedAgainst string            `json:"rendered_against,omitempty"`
	Inputs          *LockInputs       `json:"inputs,omitempty"`
	Files           map[string]string `json:"files"`
}

type LockInputs struct {
	ManifestSHA256 string `json:"manifest_sha256"`
}

type DriftStatus string

const (
	DriftClean          DriftStatus = "clean"
	DriftModified       DriftStatus = "modified"
	DriftBehind         DriftStatus = "behind"
	DriftBehindModified DriftStatus = "behind+modified"
	DriftNoLock         DriftStatus = "no-lock"
	DriftStaleLock      DriftStatus = "stale-lock"
	// DriftError: the comparison could not be carried out. Distinct from
	// "clean" on purpose — a check that did not run must never look like a
	// check that passed. scripts/onboard-drift.sh already emits this value
	// for the case it refuses, and onboard-sweep buckets it as skipped.
	DriftError DriftStatus = "error"
)

type DriftResult struct {
	Status         DriftStatus
	Modified       []string
	LockVersion    string
	CurrentVersion string
	RenderError    string
}
