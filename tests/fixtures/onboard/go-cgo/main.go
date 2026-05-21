package main

import (
	"database/sql"

	_ "github.com/mattn/go-sqlite3"
)

func main() {
	_, _ = sql.Open("sqlite3", ":memory:")
}
