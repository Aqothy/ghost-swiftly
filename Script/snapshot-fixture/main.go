// Command snapshot-fixture writes the GhosttyVT test fixture: a snapshot
// encoded by the Go binding (the encoder maiD's daemon uses) at the pinned
// Ghostty commit, with the encoder side's own formatter output and cursor as
// the expected values.
//
// Run from the repository root after Script/build-xcframework.sh:
//
//	PKG_CONFIG_PATH=$PWD/.build/ghostty/zig-out/share/pkgconfig \
//	    go -C Script/snapshot-fixture run . ../../Tests/GhosttyVTTests/Fixtures
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"

	libghostty "go.mitchellh.com/libghostty"
)

const (
	columns = 80
	rows    = 24
	// maiD's attach model keeps 2 MiB of scrollback.
	scrollbackBytes = 2 << 20
	historyLines    = 3000
)

// tail completes the CSI left unfinished at the end of the snapshot input.
const tail = "1mRED\x1b[0m after"

type expected struct {
	Commit          string `json:"commit"`
	Columns         uint16 `json:"columns"`
	Rows            uint16 `json:"rows"`
	ScrollbackBytes uint   `json:"scrollbackBytes"`
	ScrollbackRows  uint   `json:"scrollbackRows"`
	CursorX         uint16 `json:"cursorX"`
	CursorY         uint16 `json:"cursorY"`
	BracketedPaste  bool   `json:"bracketedPaste"`
	Title           string `json:"title"`
	// Plain is the plain-text formatter output of the encoded terminal.
	Plain string `json:"plain"`
	// Tail is fed after restore; PlainAfterTail is the formatter output once
	// the encoding terminal has been fed it too.
	Tail           string `json:"tail"`
	PlainAfterTail string `json:"plainAfterTail"`
}

func main() {
	if len(os.Args) != 2 {
		log.Fatal("usage: snapshot-fixture <output dir>")
	}
	out := os.Args[1]

	info, err := libghostty.GetBuildInfo()
	if err != nil {
		log.Fatal(err)
	}
	if info.VersionBuild == "" {
		log.Fatal("libghostty-vt was built without its commit in -Dlib-version-string")
	}

	term, err := libghostty.NewTerminal(
		libghostty.WithSize(columns, rows),
		libghostty.WithMaxScrollbackBytes(scrollbackBytes),
		libghostty.WithContinuationMaxBytes(64*1024),
	)
	if err != nil {
		log.Fatal(err)
	}
	defer term.Close()

	var input strings.Builder
	input.WriteString("\x1b]2;fixture title\x07")
	for i := range historyLines {
		switch i % 4 {
		case 0:
			fmt.Fprintf(&input, "history %05d plain\r\n", i)
		case 1:
			fmt.Fprintf(&input, "history %05d \x1b[1;31mbold red\x1b[0m \x1b[38;2;10;200;30mtruecolor\x1b[0m\r\n", i)
		case 2:
			fmt.Fprintf(&input, "history %05d 日本語 wide 🚀 emoji\r\n", i)
		case 3:
			fmt.Fprintf(&input, "history %05d \x1b[48;5;202m256 bg\x1b[0m\r\n", i)
		}
	}
	input.WriteString("\x1b[?2004h")
	input.WriteString("$ echo visible\r\nvisible\r\n$ ")
	input.WriteString("\x1b[10;5Hcursor here ")
	// Leave a CSI unfinished so the snapshot carries a parser continuation.
	input.WriteString("\x1b[3")
	if _, err := term.Write([]byte(input.String())); err != nil {
		log.Fatal(err)
	}

	snapshot, err := term.Snapshot()
	if err != nil {
		log.Fatal(err)
	}

	want := expected{
		Commit:          info.VersionBuild,
		Columns:         columns,
		Rows:            rows,
		ScrollbackBytes: scrollbackBytes,
		Tail:            tail,
	}
	if want.ScrollbackRows, err = term.ScrollbackRows(); err != nil {
		log.Fatal(err)
	}
	if want.CursorX, err = term.CursorX(); err != nil {
		log.Fatal(err)
	}
	if want.CursorY, err = term.CursorY(); err != nil {
		log.Fatal(err)
	}
	if want.BracketedPaste, err = term.Mode(libghostty.ModeBracketedPaste); err != nil {
		log.Fatal(err)
	}
	if want.Title, err = term.Title(); err != nil {
		log.Fatal(err)
	}
	if want.Plain, err = plain(term); err != nil {
		log.Fatal(err)
	}
	if _, err := term.Write([]byte(tail)); err != nil {
		log.Fatal(err)
	}
	if want.PlainAfterTail, err = plain(term); err != nil {
		log.Fatal(err)
	}

	if err := os.WriteFile(filepath.Join(out, "snapshot.ghostsnp"), snapshot, 0o644); err != nil {
		log.Fatal(err)
	}
	encoded, err := json.MarshalIndent(want, "", "  ")
	if err != nil {
		log.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(out, "snapshot.json"), append(encoded, '\n'), 0o644); err != nil {
		log.Fatal(err)
	}
	fmt.Printf("snapshot: %d bytes, %d scrollback rows, commit %s\n", len(snapshot), want.ScrollbackRows, want.Commit)
}

func plain(term *libghostty.Terminal) (string, error) {
	formatter, err := libghostty.NewFormatter(term,
		libghostty.WithFormatterFormat(libghostty.FormatterFormatPlain),
		libghostty.WithFormatterTrim(true),
	)
	if err != nil {
		return "", err
	}
	defer formatter.Close()
	return formatter.FormatString()
}
