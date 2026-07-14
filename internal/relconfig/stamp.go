package relconfig

import (
	"context"
	"fmt"

	"github.com/burrowee-git/release-kit/version"
)

// BurroweeScheme renders burrowee's stamp: v<semver>.<dateUTC>.<sha>.
// Signature matches version.Scheme (semver, sha, dateUTC).
func BurroweeScheme(semver, sha, dateUTC string) string {
	return fmt.Sprintf("v%s.%s.%s", semver, dateUTC, sha)
}

// Stamp reproduces `tools/version.sh <comp> --stamp` for srcDir. It wraps
// release-kit's version.Stamp with BurroweeScheme, which the oracle test
// (TestStampMatchesVersionSh) confirms reproduces the bash stamp byte-for-byte.
func Stamp(ctx context.Context, semverFile, srcDir string) (string, error) {
	return version.Stamp(ctx, semverFile, srcDir, BurroweeScheme)
}
