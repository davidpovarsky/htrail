# Pureline isolated WireGuard laboratory

Owner: WireGuard transport lane. Run ID: pureline-wg-lab-20261127.

This tool drives real encrypted WireGuard traffic through the existing Pureline
filter implementation in a separate laboratory mitmproxy process. It does not
implement, emulate, or prove an iOS Network Extension.

## Route

Mac HTTP CONNECT / ordinary HTTP listener 127.0.0.1:18520 -> official wireguard-go
userspace netstack -> loopback UDP 18521 -> framed TCP datagram relay -> pinned
Oracle-to-Mac reverse SSH forward on loopback TCP 18522 -> isolated Oracle
WireGuard server 127.0.0.1:18521 -> Pureline addon -> origin.

There is a real WireGuard handshake and encrypted payload between netstack and
mitmproxy. UDP datagrams use an additional framed TCP/SSH carrier on the interhost
leg. This route deliberately does not test direct internet UDP reachability,
kernel routing, iOS NE activation or arbitrary third-party app interception.

## Isolation

The existing UDP51820 service, its peer keys, CA, firewall, routes, model files,
cache and diagnostics are never edited. Runtime secrets and the test CA private
key live only in /srv/pureline-poc/lab-20261127 (mode0700). The unique laboratory
client credential is transported only via existing pinned SSH to the Mac
runtime directory, mode0600. No raw secret is committed or printed.

All listeners are loopback-only. The proxy supports public-web port80/443
traffic from an explicitly configured test client. It must not be published.
No system-wide proxy or trust settings are changed by this tool.

## Source and dependency

main.go uses golang.zx2c4.com/wireguard pinned in go.mod/go.sum.
Upstream reference:
https://git.zx2c4.com/wireguard-go/plain/tun/netstack/examples/http_client.go

datagram_relay.py uses only Python standard-library asyncio.

Cross compilation (on Oracle, no Apple SDK used):
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -o bin/pureline-wg-proxy-mac .

The exact pinned dependency and source hash are retained in the Git receipt.
Runtime logs must never contain keys, full URLs, headers or image content.

## Consumer contract

HTTP CONNECT proxy: 127.0.0.1:18520 (no proxy transport TLS; loopback only).
Public test CA certificate on Mac:
~/builds/pureline-wireguard-lab-20261127/mitmproxy-ca-cert.pem

For URLSession or WKWebsiteDataStore use ProxyConfiguration(httpCONNECTProxy:
.hostPort(host:"127.0.0.1",port:18520),tlsOptions:nil), with direct failover
disabled. Trust the public lab CA only inside the dedicated test environment.
Do not add the private CA key or client JSON to application bundles.

Health: http://127.0.0.1:18520/__pureline_lab_health
Returns aggregate requests, successful connections, errors, byte counters and
WireGuard last-handshake/tx/rx metadata; never UAPI secret fields.

The Mac UDP relay binds its first client's source address. Restart this isolated
relay when restarting the netstack client, so a new ephemeral UDP port is valid.

## Evidence boundary

A successful HTTP status alone is insufficient. Evidence must include a fresh
WireGuard handshake, bidirectional bytes, HTTP/DNS/TLS tests, actual image filter
response header/body integrity, and browser render evidence owned by the UI lane.
Model accuracy belongs to the independently labelled holdout lane. Neither
substitutes for a physical iOS device test.
