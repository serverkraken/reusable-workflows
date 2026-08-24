package domain

type Profile struct {
	SchemaVersion  int               `json:"schema_version"`
	TargetRepo     string            `json:"target_repo"`
	DefaultBranch  string            `json:"default_branch"`
	CurrentVersion string            `json:"current_version"`
	Monorepo       bool              `json:"monorepo"`
	Components     []Component       `json:"components"`
	LegacyCI       []LegacyCI        `json:"legacy_ci"`
	Topics         []string          `json:"topics"`
	Warnings       []Warning         `json:"warnings"`
	GitOps         *GitOpsSignal     `json:"gitops,omitempty"`
	ManifestSHA256 string            `json:"manifest_sha256,omitempty"`
	Workflows      *WorkflowsSpec    `json:"workflows,omitempty"`
	Release        *ReleaseSpec      `json:"release,omitempty"`
	Consumers      []GitOpsConsumer  `json:"gitops_consumers,omitempty"`
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
	Unittest          bool          `json:"unittest,omitempty"`
	Version           string        `json:"version,omitempty"`
	AppVersion        bool          `json:"app_version,omitempty"`
}

type Dockerfile struct {
	Path            string `json:"path"`
	ImageName       string `json:"image_name"`
	ImageNameSource string `json:"image_name_source"`
	ReleaseEligible bool   `json:"release_eligible"`
	Context         string `json:"context,omitempty"`
	Platforms       string `json:"platforms,omitempty"`
	// Scanners and UploadSARIF feed the per-image scan job. They are pointers
	// to nothing but the atom's own defaults when unset, so omitting them keeps
	// every existing adopter's render byte-identical.
	Scanners    string `json:"scanners,omitempty"`
	UploadSARIF *bool  `json:"upload_sarif,omitempty"`
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

type WorkflowsSpec struct {
	E2E *E2ESpec `json:"e2e,omitempty"`
}

type E2ESpec struct {
	Script   string `json:"script"`
	Schedule string `json:"schedule,omitempty"`
}

type ReleaseSpec struct {
	DispatchTrigger bool           `json:"dispatch_trigger"`
	Badges          bool           `json:"badges,omitempty"`
	ChartPins       *ChartPinsSpec `json:"chart_pins,omitempty"`
}

// ChartPinsSpec drives the chart-image-bump job: after a release built new
// images, their tags are pinned in the chart that ships in the same repo.
type ChartPinsSpec struct {
	Values string `json:"values"`
	Key    string `json:"key"`
}

type GitOpsConsumer struct {
	Repo  string   `json:"repo"`
	Scope []string `json:"scope,omitempty"`
	Mode  string   `json:"mode"`
}
