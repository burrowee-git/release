package register

// ChannelBeta is the one channel string that selects the beta layout.
const ChannelBeta = "beta"

// KeyPrefix returns the R2 key prefix a component's artifacts live under on
// channel: "<comp>/" for stable, "<comp>/beta/" for beta.
//
// This is the ONE place the bucket layout is expressed. Publish, prune and the
// manifest writer all derive from it, and tools/release.sh asks the binary for
// it (the `key-prefix` verb) rather than rebuilding the string in shell — a
// second copy of a layout is a copy that drifts, and the two halves of a drifted
// layout are a publish that writes where nothing reads.
//
// Only the exact string "beta" selects the beta prefix. An unknown channel
// resolves to stable rather than to beta on purpose: publishing a beta artifact
// under the stable prefix is visible immediately (stable retention counts it),
// while the reverse hides beta artifacts from the pass that is supposed to bound
// them to one.
func KeyPrefix(comp, channel string) string {
	if channel == ChannelBeta {
		return comp + "/beta/"
	}
	return comp + "/"
}
