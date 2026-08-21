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
)

type DriftResult struct {
	Status         DriftStatus
	Modified       []string
	LockVersion    string
	CurrentVersion string
	RenderError    string
}
