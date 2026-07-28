package relconfig

import (
	"reflect"
	"testing"

	"github.com/burrowee-git/release-kit/build"
)

func TestBinsCLI(t *testing.T) {
	got, err := Bins("cli", "v1.0.0.2026.07.13.deadbeef", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	want := []build.BinSpec{
		{Name: "burrowee-cli", Package: "./cmd/burrowee-cli", Ldflags: "-X main.version=v1.0.0.2026.07.13.deadbeef"},
		{Name: "burrowee-cli-updater", Package: "./cmd/burrowee-cli-updater", Ldflags: "-X main.version=v1.0.0.2026.07.13.deadbeef"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Bins(cli)=\n%+v\nwant\n%+v", got, want)
	}
}

func TestBinsAgentStampsCommandVar(t *testing.T) {
	got, _ := Bins("agent", "vSTAMP", "", "", "")
	want := "-X main.version=vSTAMP -X github.com/burrowee-git/agent/internal/agent/command.version=vSTAMP"
	if got[0].Ldflags != want {
		t.Fatalf("agent ldflags=%q want %q", got[0].Ldflags, want)
	}
}

func TestBinsEdgeBakesConsolePubHex(t *testing.T) {
	got, _ := Bins("edge", "vSTAMP", "abc123", "", "")
	for _, b := range got {
		want := "-X main.version=vSTAMP -X main.consolePubHexProd=abc123"
		if b.Ldflags != want {
			t.Fatalf("edge %s ldflags=%q want %q", b.Name, b.Ldflags, want)
		}
	}
}

func TestBinsGateway(t *testing.T) {
	got, err := Bins("gateway", "vSTAMP", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	want := []build.BinSpec{
		{Name: "burrowee-gateway", Package: "./cmd/burrowee-gateway", Ldflags: "-X main.version=vSTAMP"},
		{Name: "burrowee-gateway-cli", Package: "./cmd/burrowee-gateway-cli", Ldflags: "-X main.version=vSTAMP"},
		{Name: "burrowee-gateway-console", Package: "./cmd/burrowee-gateway-console", Ldflags: "-X main.version=vSTAMP"},
		{Name: "burrowee-register", Package: "./cmd/burrowee-register", Ldflags: "-X main.version=vSTAMP"},
		{Name: "burrowee-gateway-updater", Package: "./cmd/burrowee-gateway-updater", Ldflags: "-X main.version=vSTAMP"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Bins(gateway)=\n%+v\nwant\n%+v", got, want)
	}
}

func TestBinsBurrowee(t *testing.T) {
	got, err := Bins("burrowee", "vSTAMP", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	want := []build.BinSpec{
		{Name: "burrowee", Package: ".", Ldflags: "-X main.version=vSTAMP"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Bins(burrowee)=\n%+v\nwant\n%+v", got, want)
	}
}

func TestBinsRelayConsoleIdentityOnCliAndUpdaterOnly(t *testing.T) {
	got, _ := Bins("relay", "vSTAMP", "abc123", "wss://relay-api.burrowee.com", "")
	byName := map[string]build.BinSpec{}
	for _, b := range got {
		byName[b.Name] = b
	}
	// serve binary: version only, no console identity, no nested-module fields
	relaySrv := byName["burrowee-relay"]
	if relaySrv.Ldflags != "-X main.version=vSTAMP" {
		t.Fatalf("relay serve ldflags=%q", relaySrv.Ldflags)
	}
	if relaySrv.SubDir != "" || relaySrv.GoWork != "" {
		t.Fatalf("relay serve spec wrong: %+v", relaySrv)
	}
	// cli: nested module + gowork off + console identity
	cli := byName["burrowee-relay-cli"]
	if cli.SubDir != "cli" || cli.GoWork != "off" || cli.Package != "." {
		t.Fatalf("relay-cli spec wrong: %+v", cli)
	}
	wantCli := "-X main.version=vSTAMP -X main.consoleURLProd=wss://relay-api.burrowee.com -X main.consolePubHexProd=abc123"
	if cli.Ldflags != wantCli {
		t.Fatalf("relay-cli ldflags=%q want %q", cli.Ldflags, wantCli)
	}
	upd := byName["burrowee-relay-updater"]
	if upd.SubDir != "cli" || upd.GoWork != "off" || upd.Package != "./cmd/burrowee-relay-updater" {
		t.Fatalf("relay-updater spec wrong: %+v", upd)
	}
}
