package detect

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
)

// Audit C-4 und C-5: ReleaseTags-, LatestStableRelease- und Topics-Fehler
// wurden mit `err == nil &&` verschluckt und sahen danach aus wie "das Repo hat
// keine Releases" beziehungsweise "keine Topics".
//
// Aus `version` wird `.release-please-manifest.json` geseedet. Ein Repo auf
// 1.10.0, dessen Abfrage an einem Rate-Limit scheitert, haette dort 0.0.0
// bekommen — release-please rechnet die naechste Version daraus und haette
// rueckwaerts versioniert.
//
// Topics steuern Opt-ins, allen voran `sk-prerelease-on-push`. "Keine Topics"
// heisst "das Opt-in gilt nicht", also faellt prerelease-on-push.yml aus dem
// Rendering.
//
// Ein Repo OHNE Releases beziehungsweise OHNE Topics ist etwas anderes: die API
// antwortet dann erfolgreich mit einer leeren Liste. Der letzte Test unten
// haelt fest, dass dieser Fall gueltig bleibt.

// partialMetadata antwortet auf alles ausser den benannten Aufrufen erfolgreich.
type partialMetadata struct {
	failReleaseTags   bool
	failLatestRelease bool
	failTopics        bool
}

func (m partialMetadata) DefaultBranch(context.Context, string) (string, error) {
	return "main", nil
}

func (m partialMetadata) LatestStableRelease(context.Context, string) (string, error) {
	if m.failLatestRelease {
		return "", os.ErrPermission
	}
	return "", nil
}

func (m partialMetadata) ReleaseTags(context.Context, string) ([]string, error) {
	if m.failReleaseTags {
		return nil, os.ErrPermission
	}
	return nil, nil
}

func (m partialMetadata) Topics(context.Context, string) ([]string, error) {
	if m.failTopics {
		return nil, os.ErrPermission
	}
	return []string{}, nil
}

func TestReleaseTagsFailureIsNotAnEmptyReleaseList(t *testing.T) {
	_, err := (Service{GitHub: partialMetadata{failReleaseTags: true}}).
		Detect(context.Background(), Request{RepoPath: fixture(t, "go-repo"), TargetRepo: "owner/repo"})
	if err == nil {
		t.Fatal("erwartet: Abbruch, bekommen: Erfolg — ein Fehlschlag darf nicht als 'keine Releases' gelten")
	}
	if !strings.Contains(err.Error(), "could not list releases") {
		t.Fatalf("Grund fehlt im Fehler: %v", err)
	}
	if !errors.Is(err, os.ErrPermission) {
		t.Fatalf("die Ursache muss durchgereicht werden, sonst steht im Log nur die Huelle: %v", err)
	}
}

func TestLatestStableReleaseFailureIsFatal(t *testing.T) {
	// Wird nur erreicht, wenn ReleaseTags keinen Root-Tag lieferte — genau der
	// Zweig, der die Version sonst auf 0.0.0 stehen liess.
	_, err := (Service{GitHub: partialMetadata{failLatestRelease: true}}).
		Detect(context.Background(), Request{RepoPath: fixture(t, "go-repo"), TargetRepo: "owner/repo"})
	if err == nil || !strings.Contains(err.Error(), "latest release") {
		t.Fatalf("erwartet: Abbruch mit Grund, bekommen: %v", err)
	}
}

func TestTopicsFailureIsNotAnEmptyTopicList(t *testing.T) {
	_, err := (Service{GitHub: partialMetadata{failTopics: true}}).
		Detect(context.Background(), Request{RepoPath: fixture(t, "go-repo"), TargetRepo: "owner/repo"})
	if err == nil || !strings.Contains(err.Error(), "could not read topics") {
		t.Fatalf("erwartet: Abbruch mit Grund, bekommen: %v", err)
	}
}

func TestRepoWithoutReleasesOrTopicsStaysValid(t *testing.T) {
	// Gegenprobe zu den drei Abbruechen: der legitime Fall darf nicht
	// mitgerissen werden. Ein Repo vor seinem ersten Release liefert eine
	// leere Liste OHNE Fehler.
	res, err := (Service{GitHub: partialMetadata{}}).
		Detect(context.Background(), Request{RepoPath: fixture(t, "go-repo"), TargetRepo: "owner/repo"})
	if err != nil {
		t.Fatalf("ein Repo ohne Releases ist kein Fehler: %v", err)
	}
	if res.Profile.CurrentVersion != "0.0.0" {
		t.Fatalf("current_version=%q, erwartet 0.0.0", res.Profile.CurrentVersion)
	}
	if len(res.Profile.Topics) != 0 {
		t.Fatalf("topics=%v, erwartet leer", res.Profile.Topics)
	}
}
