package main

// Mirrors the skytrack pattern: imports go-sqlite3 as a blank import so the
// driver registers itself, but the adopter's own source contains no
// `import "C"`. CGO_ENABLED=1 is still required at build time because
// go-sqlite3 itself is a cgo package.

import (
	"database/sql"

	_ "github.com/mattn/go-sqlite3"
)

func main() {
	_, _ = sql.Open("sqlite3", ":memory:")
}
