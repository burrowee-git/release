package register

import (
	"context"
	"fmt"
	"io"
	"sort"
	"strings"
)

// Lister enumerates object keys under a prefix. Satisfied by *r2.Client.
type Lister interface {
	List(ctx context.Context, prefix string) ([]string, error)
}

// Deleter removes a single object key. Satisfied by *r2.Client.
type Deleter interface {
	Delete(ctx context.Context, key string) error
}

// PruneStore is the R2 surface Prune needs (list + delete).
type PruneStore interface {
	Lister
	Deleter
}

// keepFor reports the retention count for comp: relay keeps 3, every public
// component (cli/gateway/edge) keeps 10. The locked operator policy.
func keepFor(comp string) int {
	if comp == "relay" {
		return 3
	}
	return 10
}

// Prune drops all but the newest keepFor(comp) version/stamp prefixes under
// <comp>/ in R2, deleting every object beneath the dropped prefixes. "Newest"
// is decided by the same version ordering the rest of the tooling uses
// (`sort -V`): the version triple dominates and the date+sha stamp suffix
// breaks ties chronologically.
//
// When execute is false (the default) nothing is deleted — the planned
// deletions are written to out as "would delete <key>" lines and counted. The
// destructive drain only runs with execute=true.
//
// Returns the number of objects deleted (execute=true) or that would be
// deleted (execute=false).
func Prune(ctx context.Context, store PruneStore, comp string, execute bool, out io.Writer) (int, error) {
	if out == nil {
		out = io.Discard
	}
	keep := keepFor(comp)
	prefix := comp + "/"

	keys, err := store.List(ctx, prefix)
	if err != nil {
		return 0, err
	}

	// Group keys by their version/stamp dir (the segment right after <comp>/).
	byVersion := map[string][]string{}
	for _, k := range keys {
		rest := strings.TrimPrefix(k, prefix)
		ver, _, ok := strings.Cut(rest, "/")
		if !ok || ver == "" {
			continue // not a <comp>/<version>/<file> key — leave it alone
		}
		byVersion[ver] = append(byVersion[ver], k)
	}

	versions := make([]string, 0, len(byVersion))
	for v := range byVersion {
		versions = append(versions, v)
	}
	sort.Sort(byVersionSort(versions))

	mode := "DRY-RUN"
	if execute {
		mode = "EXECUTE"
	}
	fmt.Fprintf(out, "[%s] %d version(s) under %s — keep newest %d (%s)\n", comp, len(versions), prefix, keep, mode)

	if len(versions) <= keep {
		fmt.Fprintf(out, "[%s] nothing to prune\n", comp)
		return 0, nil
	}

	drop := versions[:len(versions)-keep]
	kept := versions[len(versions)-keep:]
	fmt.Fprintf(out, "[%s] keep: %s\n", comp, strings.Join(kept, " "))

	deleted := 0
	for _, ver := range drop {
		for _, key := range byVersion[ver] {
			if execute {
				if err := store.Delete(ctx, key); err != nil {
					return deleted, err
				}
				fmt.Fprintf(out, "  ✓ deleted %s\n", key)
			} else {
				fmt.Fprintf(out, "  - would delete %s\n", key)
			}
			deleted++
		}
	}
	return deleted, nil
}

// byVersionSort orders version/stamp strings ascending the way `sort -V` does:
// dot-separated fields compared numerically when both are numbers, else
// lexically; a shorter prefix sorts before a longer one. So the newest is last.
type byVersionSort []string

func (s byVersionSort) Len() int           { return len(s) }
func (s byVersionSort) Swap(i, j int)      { s[i], s[j] = s[j], s[i] }
func (s byVersionSort) Less(i, j int) bool { return versionLess(s[i], s[j]) }

func versionLess(a, b string) bool {
	fa := strings.Split(strings.TrimPrefix(a, "v"), ".")
	fb := strings.Split(strings.TrimPrefix(b, "v"), ".")
	for i := 0; i < len(fa) && i < len(fb); i++ {
		if c := compareField(fa[i], fb[i]); c != 0 {
			return c < 0
		}
	}
	return len(fa) < len(fb)
}

// compareField returns -1/0/1. Two all-digit fields compare numerically (by
// length then lexically, avoiding overflow); otherwise lexically.
func compareField(a, b string) int {
	if isDigits(a) && isDigits(b) {
		a = strings.TrimLeft(a, "0")
		b = strings.TrimLeft(b, "0")
		if len(a) != len(b) {
			if len(a) < len(b) {
				return -1
			}
			return 1
		}
	}
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	default:
		return 0
	}
}

func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}
