// Package migrations embeds the SQL migration files so they ship inside the
// server binary and can be applied automatically on startup.
package migrations

import "embed"

//go:embed *.sql
var FS embed.FS
