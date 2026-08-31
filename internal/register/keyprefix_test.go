package register

import "testing"

func TestKeyPrefix(t *testing.T) {
	for _, tc := range []struct {
		comp, channel, want string
	}{
		{"edge", "stable", "edge/"},
		{"edge", "beta", "edge/beta/"},
		{"relay", "stable", "relay/"},
		{"relay", "beta", "relay/beta/"},
		{"cli", "", "cli/"}, // empty channel means stable, as in the register payload
	} {
		if got := KeyPrefix(tc.comp, tc.channel); got != tc.want {
			t.Errorf("KeyPrefix(%q, %q) = %q, want %q", tc.comp, tc.channel, got, tc.want)
		}
	}
}

// A beta prefix must not be reachable by any channel string other than "beta" —
// a typo'd or unknown channel resolving to the beta prefix would publish beta
// artifacts where stable retention can see them.
func TestKeyPrefixUnknownChannelIsStable(t *testing.T) {
	for _, ch := range []string{"Beta", "BETA", "prerelease", "b", "beta "} {
		if got := KeyPrefix("edge", ch); got != "edge/" {
			t.Errorf("KeyPrefix(edge, %q) = %q, want the stable prefix edge/", ch, got)
		}
	}
}
