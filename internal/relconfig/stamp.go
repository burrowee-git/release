package relconfig

import (
	"context"
	"fmt"

	"github.com/burrowee-git/release-kit/version"
)

// BurroweeScheme renders burrowee's stable stamp: v<semver>.<dateUTC>.<sha>.
// Signature matches version.Scheme (semver, sha, dateUTC).
func BurroweeScheme(semver, sha, dateUTC string) string {
	return fmt.Sprintf("v%s.%s.%s", semver, dateUTC, sha)
}

// BurroweeBetaScheme renders burrowee's beta stamp: v<semver>.beta.<dateUTC>.<sha>
// — the same shape as BurroweeScheme with a ".beta." segment inserted between
// the semver and the date, mirroring tools/version.sh's stamp() for
// --channel beta. Signature matches version.Scheme (semver, sha, dateUTC).
func BurroweeBetaScheme(semver, sha, dateUTC string) string {
	return fmt.Sprintf("v%s.beta.%s.%s", semver, dateUTC, sha)
}

// Stamp reproduces `tools/version.sh <comp> [--channel <channel>] --stamp` for
// srcDir. channel selects BurroweeScheme (stable, and any value other than
// "beta") or BurroweeBetaScheme; the oracle tests
// (TestStampMatchesVersionSh, TestStampMatchesVersionShBeta) confirm each
// reproduces the matching bash stamp byte-for-byte.
func Stamp(ctx context.Context, semverFile, srcDir, channel string) (string, error) {
	scheme := BurroweeScheme
	if channel == "beta" {
		scheme = BurroweeBetaScheme
	}
	return version.Stamp(ctx, semverFile, srcDir, scheme)
}
