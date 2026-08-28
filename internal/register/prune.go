package register

import (
	"context"
	"fmt"
	"io"
	"regexp"
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

// keepFor reports the retention count for comp on channel: beta keeps only
// the latest — 1 — regardless of comp, because the beta track is disposable
// (a cycle is opened, cut, promoted, superseded and dropped, and nothing on
// it is worth carrying history for); on stable, relay keeps 3 and every
// public component (cli/gateway/edge/agent) keeps 10. The locked operator
// policy (spec §5.5). Consequence: cutting a new beta expires the previous
// one and prunes its artifacts immediately — an invite link minted against
// the older beta stops resolving, and there is no artifact-level rollback to
// a prior beta.
func keepFor(comp, channel string) int {
	if channel == "beta" {
		return 1
	}
	if comp == "relay" {
		return 3
	}
	return 10
}

// channelPatterns compiles comp's stable and beta stamp regexes, reusing
// register.go's stableStampPattern/betaStampPattern (spec §4.1) so this file
// carries no second copy of the shape.
func channelPatterns(comp string) (stableRe, betaRe *regexp.Regexp) {
	q := regexp.QuoteMeta(comp)
	return regexp.MustCompile(fmt.Sprintf(stableStampPattern, q)),
		regexp.MustCompile(fmt.Sprintf(betaStampPattern, q))
}

// chOf reports the channel comp+"/"+ver belongs to, validating its FULL
// shape against the anchored patterns from channelPatterns — not a ".beta."
// substring probe, which would misclassify anything merely lacking that
// marker as "stable" (a legacy directory, a manual upload, a typo'd stamp).
// A version matching neither pattern belongs to neither channel: chOf
// returns "" so the caller's `!= channel` check excludes it from every
// channel's count and delete list, per spec §4.1 "a tag matching neither is
// ignored everywhere".
func chOf(stableRe, betaRe *regexp.Regexp, comp, ver string) string {
	full := comp + "/" + ver
	switch {
	case betaRe.MatchString(full):
		return "beta"
	case stableRe.MatchString(full):
		return "stable"
	default:
		return ""
	}
}

// Prune drops all but the newest keepFor(comp, channel) version/stamp
// prefixes under <comp>/ in R2 ON THE GIVEN CHANNEL ONLY, deleting every
// object beneath the dropped prefixes. A stable prune never counts or deletes
// a beta version, and vice versa — versions on the other channel (or matching
// neither channel pattern) are left untouched, not just unlisted. "Newest" is
// decided by the same version ordering the rest of the tooling uses
// (`sort -V`): the version triple dominates and the date+sha stamp suffix
// breaks ties chronologically.
//
// When execute is false (the default) nothing is deleted — the planned
// deletions are written to out as "would delete <key>" lines and counted. The
// destructive drain only runs with execute=true.
//
// Returns the number of objects deleted (execute=true) or that would be
// deleted (execute=false).
func Prune(ctx context.Context, store PruneStore, comp, channel string, execute bool, out io.Writer) (int, error) {
	if out == nil {
		out = io.Discard
	}
	keep := keepFor(comp, channel)
	prefix := comp + "/"

	keys, err := store.List(ctx, prefix)
	if err != nil {
		return 0, err
	}

	stableRe, betaRe := channelPatterns(comp)

	// Group keys by their version/stamp dir (the segment right after <comp>/),
	// skipping any version whose channel doesn't match — this is what keeps a
	// stable prune from ever counting or deleting a beta version (and back),
	// and a version matching NEITHER shape is excluded from both.
	byVersion := map[string][]string{}
	for _, k := range keys {
		rest := strings.TrimPrefix(k, prefix)
		ver, _, ok := strings.Cut(rest, "/")
		if !ok || ver == "" {
			continue // not a <comp>/<version>/<file> key — leave it alone
		}
		if chOf(stableRe, betaRe, comp, ver) != channel {
			continue // other channel, or neither — never counted or touched by this prune
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

// byVersionSort orders version/stamp strings ascending the way GNU `sort -V`
// does, so the newest is last. This matches tools/prune-releases.sh (real
// `sort -V`) on which stamps are the newest-N — including the trailing git-sha
// tie-break, where alpha-leading and numeric-leading shas interleave in a way
// that field-wise lexical comparison gets wrong.
type byVersionSort []string

func (s byVersionSort) Len() int           { return len(s) }
func (s byVersionSort) Swap(i, j int)      { s[i], s[j] = s[j], s[i] }
func (s byVersionSort) Less(i, j int) bool { return versionLess(s[i], s[j]) }

// versionLess reports whether a sorts before b the way GNU `sort -V` does,
// matching it for our stamp shapes (vX.Y.Z[.date.sha], no '~'). `sort -V` strips
// a trailing file suffix from each string, compares the prefixes with the
// coreutils version comparator (verrevcmp), and breaks a tie with a plain byte
// comparison of the original strings. That suffix handling is what makes the
// trailing git-sha tie-break agree with `sort -V`: an alpha-leading sha forms a
// strippable ".<sha>" suffix (so the prefixes tie and the byte order of the full
// stamp decides), while a numeric-leading sha does not — which a naive
// field-wise comparison gets wrong. Our stamps are never empty and never start
// with '.' / '~', so filevercmp's leading-dot/empty special cases are omitted.
func versionLess(a, b string) bool { return filevercmp(a, b) < 0 }

func filevercmp(a, b string) int {
	if c := verrevcmp(a[:filePrefixLen(a)], b[:filePrefixLen(b)]); c != 0 {
		return c
	}
	return strings.Compare(a, b)
}

// filePrefixLen returns the length of the prefix of s left after removing the
// longest trailing file suffix matching (\.[A-Za-z~][A-Za-z0-9~]*)*$, never
// consuming all of a non-empty s. Port of coreutils file_prefixlen.
func filePrefixLen(s string) int {
	n := len(s)
	prefixLen := 0
	for i := 0; ; {
		if i == n {
			return prefixLen
		}
		i++
		prefixLen = i
		for i+1 < n && s[i] == '.' && (isASCIILetter(s[i+1]) || s[i+1] == '~') {
			for i += 2; i < n && (isASCIIAlnum(s[i]) || s[i] == '~'); i++ {
			}
		}
	}
}

// order maps the byte at pos to its non-digit-phase sort weight, per coreutils
// filevercmp.c order: past-the-end is -1, '~' is -2, a digit weighs 0, a letter
// keeps its byte value, and any other byte is pushed above the letters (+256).
// The digit weight of 0 (vs -1 for end-of-string) is what makes a longer string
// sort after a shorter one when the extra run starts with a digit.
func order(s string, pos int) int {
	if pos == len(s) {
		return -1
	}
	c := s[pos]
	switch {
	case isASCIIDigit(c):
		return 0
	case isASCIILetter(c):
		return int(c)
	case c == '~':
		return -2
	default:
		return int(c) + 256
	}
}

func isASCIIDigit(c byte) bool  { return c >= '0' && c <= '9' }
func isASCIILetter(c byte) bool { return c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' }
func isASCIIAlnum(c byte) bool  { return isASCIIDigit(c) || isASCIILetter(c) }

// verrevcmp returns -1/0/1 comparing a and b as GNU version strings. Port of
// coreutils filevercmp.c verrevcmp.
func verrevcmp(a, b string) int {
	i, j := 0, 0
	for i < len(a) || j < len(b) {
		firstDiff := 0
		// Non-digit phase: compare byte by byte by order weight until both sides
		// reach a digit (or end). A digit weighs 0 and end weighs -1, so the loop
		// stops when both are at digits, and a shorter side that ends here sorts
		// before a longer side continuing with a digit.
		for (i < len(a) && !isASCIIDigit(a[i])) || (j < len(b) && !isASCIIDigit(b[j])) {
			ac := order(a, i)
			bc := order(b, j)
			if ac != bc {
				return sign(ac - bc)
			}
			i++
			j++
		}
		// Digit phase: skip leading zeros, then compare digit runs by length
		// (longer run is the larger number) with a tie broken by the first
		// differing digit.
		for i < len(a) && a[i] == '0' {
			i++
		}
		for j < len(b) && b[j] == '0' {
			j++
		}
		for i < len(a) && j < len(b) && isASCIIDigit(a[i]) && isASCIIDigit(b[j]) {
			if firstDiff == 0 {
				firstDiff = int(a[i]) - int(b[j])
			}
			i++
			j++
		}
		if i < len(a) && isASCIIDigit(a[i]) {
			return 1
		}
		if j < len(b) && isASCIIDigit(b[j]) {
			return -1
		}
		if firstDiff != 0 {
			return sign(firstDiff)
		}
	}
	return 0
}

func sign(n int) int {
	switch {
	case n < 0:
		return -1
	case n > 0:
		return 1
	default:
		return 0
	}
}
