package main

import (
	"context"
	"io"
	"os"

	"github.com/serverkraken/reusable-workflows/internal/adapters/cli"
)

var exit = os.Exit

func main() {
	exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	return cli.Run(context.Background(), args, stdout, stderr)
}
