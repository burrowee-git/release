package relconfig

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"

	"github.com/burrowee-git/release-kit/version"
)

// BurroweeScheme renders burrowee's stamp: v<semver>.<dateUTC>.<sha>.
// Signature matches version.Scheme (semver, sha, dateUTC).
func BurroweeScheme(semver, sha, dateUTC string) string {
	return fmt.Sprintf("v%s.%s.%s", semver, dateUTC, sha)
}

// Stamp reproduces `tools/version.sh <comp> --stamp` for srcDir. It first tries
// release-kit's version.Stamp with BurroweeScheme; Task 1 Step 4 pins whether
// that matches bash. computeDirect is the fallback if it doesn't.
func Stamp(ctx context.Context, semverFile, srcDir string) (string, error) {
	return version.Stamp(ctx, semverFile, srcDir, BurroweeScheme)
}

// computeDirect mirrors version.sh: semver from file, sha = rev-parse --short=8,
// date = UTC %Y.%m.%d. Used only if version.Stamp's derivation diverges.
func computeDirect(ctx context.Context, semver, srcDir string) (string, error) {
	out, err := exec.CommandContext(ctx, "git", "-C", srcDir, "rev-parse", "--short=8", "HEAD").Output()
	if err != nil {
		return "", fmt.Errorf("src sha: %w", err)
	}
	sha := strings.TrimSpace(string(out))
	date := time.Now().UTC().Format("2006.01.02")
	return BurroweeScheme(semver, sha, date), nil
}
