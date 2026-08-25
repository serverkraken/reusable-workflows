// Package godetect exposes the in-process detect service behind the
// ports.ProfileDetector interface.
//
// Why this exists: the drift service used to detect through
// catalogscripts.Adapter, which shells out to scripts/onboard-detect.sh. That
// Bash engine refuses any repo carrying an adopter manifest — deliberately, it
// has no parser for one and mis-detecting the layout the manifest exists to
// correct would be worse than failing. The refusal surfaced as
// `render_error=detect-failed:…` while `status` stayed `clean`, so the
// render-and-compare safety net silently did nothing for exactly the repos the
// manifest was built for. scripts/onboard-drift.sh guards against that shape
// explicitly; the Go path had no equivalent.
//
// The Go detector understands manifests, so wiring it here makes
// render-and-compare work for those repos instead of reporting a failure
// behind a clean status.
package godetect

import (
	"context"
	"encoding/json"

	"github.com/serverkraken/reusable-workflows/internal/app/detect"
	"github.com/serverkraken/reusable-workflows/internal/ports"
)

// Adapter satisfies ports.ProfileDetector using the in-process detect service.
type Adapter struct {
	GitHub ports.GitHubMetadata
}

// ProfileJSON detects repoPath and marshals the resulting profile. catalogPath
// is unused: detection reads only the target repo, unlike the Bash engine which
// sourced helpers from the catalog checkout.
func (a Adapter) ProfileJSON(ctx context.Context, _ string, repoPath, targetRepo string) ([]byte, error) {
	res, err := (detect.Service{GitHub: a.GitHub}).Detect(ctx, detect.Request{
		RepoPath:   repoPath,
		TargetRepo: targetRepo,
	})
	if err != nil {
		return nil, err
	}
	return json.MarshalIndent(res.Profile, "", "  ")
}
