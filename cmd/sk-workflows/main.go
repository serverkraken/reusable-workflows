package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/serverkraken/reusable-workflows/internal/adapters/cli"
)

var exit = os.Exit

func main() {
	exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

// DefaultTimeout begrenzt einen CLI-Lauf insgesamt (Audit C-12).
//
// Vorher lief alles unter context.Background(), also ohne jede Frist. Haengt
// ein Unterprozess — `gh` an einer nicht antwortenden API, `git` an einem
// Credential-Prompt —, dann haengt die CLI, bis der Runner den ganzen Job
// abraeumt. Statt eines Fehlers, den jemand lesen kann, gibt es dann nur ein
// Job-Timeout ohne Hinweis auf die Ursache.
//
// Grosszuegig gewaehlt: kein echter Lauf dauert annaehernd so lange
// (Onboarding rendert eine Handvoll Dateien und ruft `gh` ein paar Mal), und
// ein Waechter, der legitime Laeufe abschneidet, waere schlimmer als der Fund.
// Ueber SK_WORKFLOWS_TIMEOUT anhebbar, damit ein Sonderfall keinen Release
// braucht.
const DefaultTimeout = 30 * time.Minute

func run(args []string, stdout, stderr io.Writer) int {
	timeout := DefaultTimeout
	if raw := os.Getenv("SK_WORKFLOWS_TIMEOUT"); raw != "" {
		d, err := time.ParseDuration(raw)
		if err != nil || d <= 0 {
			// Ein unlesbarer Wert darf NICHT stillschweigend auf die Vorgabe
			// zurueckfallen: wer die Frist setzt, will sie geaendert haben.
			fmt.Fprintf(stderr, "::error::SK_WORKFLOWS_TIMEOUT=%q is not a positive Go duration (e.g. 45m)\n", raw)
			return 2
		}
		timeout = d
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	return cli.Run(ctx, args, stdout, stderr)
}
