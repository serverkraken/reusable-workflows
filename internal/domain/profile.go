package domain

type Profile struct {
	SchemaVersion  int           `json:"schema_version"`
	TargetRepo     string        `json:"target_repo"`
	DefaultBranch  string        `json:"default_branch"`
	CurrentVersion string        `json:"current_version"`
	Monorepo       bool          `json:"monorepo"`
	Components     []Component   `json:"components"`
	LegacyCI       []LegacyCI    `json:"legacy_ci"`
	Topics         []string      `json:"topics"`
	Warnings       []Warning     `json:"warnings"`
	GitOps         *GitOpsSignal `json:"gitops,omitempty"`
}

type Component struct {
	Path              string        `json:"path"`
	Languages         []string      `json:"languages"`
	PrimaryLanguage   string        `json:"primary_language"`
	ReleasePleaseType string        `json:"release_please_type"`
	Role              string        `json:"role"`
	Dockerfiles       []Dockerfile  `json:"dockerfiles"`
	ReleaseSignals    ReleaseSignal `json:"release_signals"`
	CGO               bool          `json:"cgo"`
}

type Dockerfile struct {
	Path            string `json:"path"`
	ImageName       string `json:"image_name"`
	ImageNameSource string `json:"image_name_source"`
	ReleaseEligible bool   `json:"release_eligible"`
}

type ReleaseSignal struct {
	GoReleaserConfig *string `json:"goreleaser_config"`
	ChartYAML        *string `json:"chart_yaml"`
	FlutterAndroid   bool    `json:"flutter_android"`
}

type LegacyCI struct {
	Path       string   `json:"path"`
	Summary    string   `json:"summary"`
	ReplacedBy []string `json:"replaced_by"`
}

type Warning struct {
	Code            string `json:"code"`
	Path            string `json:"path,omitempty"`
	PrimaryLanguage string `json:"primary_language,omitempty"`
	Message         string `json:"message"`
}

type GitOpsSignal struct {
	ManifestPaths       []string `json:"manifests_paths"`
	HasKubeLinterConfig bool     `json:"has_kube_linter_config"`
	HasGitleaksConfig   bool     `json:"has_gitleaks_config"`
	SOPS                bool     `json:"sops"`
}

type LegacyOutputs struct {
	Language       string
	ReleaseType    string
	CurrentVersion string
	DefaultBranch  string
}
