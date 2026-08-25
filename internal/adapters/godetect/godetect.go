// Package godetect exposes the in-process detect service behind the
// ports.ProfileDetector interface.
//
// Why this exists: the drift service used to detect by shelling out to
// scripts/onboard-detect.sh (through an adapter since removed). That
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
	gh := a.GitHub
	if gh != nil {
		gh = tolerantMetadata{gh}
	}
	res, err := (detect.Service{GitHub: gh}).Detect(ctx, detect.Request{
		RepoPath:   repoPath,
		TargetRepo: targetRepo,
	})
	if err != nil {
		return nil, err
	}
	return json.MarshalIndent(res.Profile, "", "  ")
}

// tolerantMetadata degrades instead of failing when the repo is unreachable.
//
// Detect treats a DefaultBranch error as fatal ("repo not accessible"), which is
// right for onboarding — adopting a repo nobody can read would render against
// guesses. Drift is the other case: it re-renders an ALREADY onboarded repo to
// compare against what is committed, and it runs in jobs that do not mint a
// GitHub token. The Bash engine this replaces degrades in exactly this spot
// (`gh api … || echo "main"` in emit_profile_json), so failing hard here would
// have turned every drift run without a token into a render error.
//
// ALLE vier Methoden brauchen die Behandlung. Frueher stand hier "nur
// DefaultBranch, detect guards the other three with `err == nil`" — genau diese
// Guards waren aber der Fund C-4/C-5: sie liessen einen API-Fehler wie "keine
// Releases" beziehungsweise "keine Topics" aussehen, und daraus wurde die
// Version 0.0.0 geseedet. Beim Onboarding ist das falsch und bricht jetzt ab.
//
// Die Toleranz gehoert damit hierher, wo sie gebraucht wird, statt in den Kern,
// durch den auch das Onboarding laeuft. Der Unterschied ist der Zweck:
// Onboarding rendert ein Repo zum ERSTEN Mal und darf dabei nicht raten; Drift
// rendert ein bereits onboardetes Repo erneut, nur um zu vergleichen, und ein
// fehlendes Token macht den Vergleich nicht wertlos.
//
// Zurueckgegeben werden Nullwerte statt erfundener Vorgaben ("" statt "main"),
// damit detects eigene Defaults zustaendig bleiben.
type tolerantMetadata struct{ inner ports.GitHubMetadata }

func (t tolerantMetadata) DefaultBranch(ctx context.Context, repo string) (string, error) {
	branch, err := t.inner.DefaultBranch(ctx, repo)
	if err != nil {
		return "", nil
	}
	return branch, nil
}

func (t tolerantMetadata) LatestStableRelease(ctx context.Context, repo string) (string, error) {
	v, err := t.inner.LatestStableRelease(ctx, repo)
	if err != nil {
		return "", nil
	}
	return v, nil
}

func (t tolerantMetadata) ReleaseTags(ctx context.Context, repo string) ([]string, error) {
	tags, err := t.inner.ReleaseTags(ctx, repo)
	if err != nil {
		return nil, nil
	}
	return tags, nil
}

func (t tolerantMetadata) Topics(ctx context.Context, repo string) ([]string, error) {
	topics, err := t.inner.Topics(ctx, repo)
	if err != nil {
		return nil, nil
	}
	return topics, nil
}
