package main

import (
	"flag"
	"log"
	"net/http"

	"github.com/burrowee-git/release/internal/gate"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:8077", "TCP address to listen on")
	registry := flag.String("registry", "/var/lib/burrowee-relay-gate/registry.db", "path to the pubkey registry sqlite database")
	releases := flag.String("releases", "/srv/relay-releases", "directory containing gated release files")
	flag.Parse()

	reg, err := gate.OpenRegistry(*registry)
	if err != nil {
		log.Fatalf("relay-gate: open registry: %v", err)
	}
	defer reg.Close()

	log.Printf("relay-gate: listening on %s (registry=%s releases=%s)", *listen, *registry, *releases)

	if err := http.ListenAndServe(*listen, gate.NewServer(reg, *releases).Handler()); err != nil {
		log.Fatalf("relay-gate: %v", err)
	}
}
