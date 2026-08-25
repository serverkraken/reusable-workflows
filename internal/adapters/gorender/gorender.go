// Package gorender exposes the in-process render service behind the
// ports.TemplateRenderer interface.
//
// Why this exists: drift used to render through catalogscripts.Adapter, which
// shells out to scripts/onboard-render.sh. That Bash engine emits SIX files;
// the Go renderer emits SEVEN — it also writes `.github/workflows/e2e.yml`.
// Combined with staleFiles skipping any lock entry the renderer did not
// produce, E2E drift was structurally invisible: the comparison never looked
// at that file, and drift reported `clean` regardless of what the adopter had
// on disk.
//
// The onboarding workflow already defaults to the Go path (`use_go_cli: true`),
// so rendering through it here makes drift compare against what adopters
// actually receive rather than against a narrower Bash approximation.
package gorender

import (
	"context"

	renderapp "github.com/serverkraken/reusable-workflows/internal/app/render"
	"github.com/serverkraken/reusable-workflows/internal/ports"
)

// Adapter satisfies ports.TemplateRenderer using the in-process render service.
type Adapter struct {
	Templates ports.TemplateExecutor
}

// Render writes the full plan into targetPath.
//
// RenderedAgainst is deliberately left empty: drift renders into a scratch
// directory purely to diff against the adopter's files, and the lock it writes
// there is thrown away. Stamping a catalog tag into a lock nobody keeps would
// only invite confusion if that scratch directory were ever inspected.
func (a Adapter) Render(ctx context.Context, catalogPath, targetPath, profilePath, pinVersion string) error {
	return (renderapp.Service{Templates: a.Templates}).Render(ctx, renderapp.Request{
		CatalogPath:     catalogPath,
		TargetPath:      targetPath,
		ProfileJSONPath: profilePath,
		PinVersion:      pinVersion,
	})
}
