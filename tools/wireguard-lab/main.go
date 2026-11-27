// Pureline laboratory transport. A real WireGuard userspace tunnel, not an iOS Network Extension.
package main

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/signal"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

type configuration struct {
	PrivateKey string `json:"private_key"`
	PublicKey  string `json:"public_key"`
	Endpoint   string `json:"endpoint"`
	Address    string `json:"address"`
	DNS        string `json:"dns"`
	MTU        int    `json:"mtu"`
}
type counters struct {
	Requests  atomic.Int64
	Connected atomic.Int64
	Errors    atomic.Int64
	BytesUp   atomic.Int64
	BytesDown atomic.Int64
}

func keyHex(s string) (string, error) {
	b, e := base64.StdEncoding.DecodeString(s)
	if e != nil || len(b) != 32 {
		return "", errors.New("invalid key length")
	}
	return hex.EncodeToString(b), nil
}
func main() {
	configPath := flag.String("config", "", "private runtime configuration, never logged")
	listen := flag.String("listen", "127.0.0.1:18520", "loopback HTTP CONNECT listener")
	flag.Parse()
	host, _, e := net.SplitHostPort(*listen)
	if e != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() {
		log.Fatal("loopback listener required")
	}
	data, e := os.ReadFile(*configPath)
	if e != nil {
		log.Fatal("cannot read configuration")
	}
	var c configuration
	if json.Unmarshal(data, &c) != nil {
		log.Fatal("invalid configuration")
	}
	private, e := keyHex(c.PrivateKey)
	if e != nil {
		log.Fatal(e)
	}
	public, e := keyHex(c.PublicKey)
	if e != nil {
		log.Fatal(e)
	}
	addr, e := netip.ParseAddr(c.Address)
	if e != nil {
		log.Fatal("invalid address")
	}
	dns, e := netip.ParseAddr(c.DNS)
	if e != nil {
		log.Fatal("invalid dns")
	}
	if c.MTU < 576 || c.MTU > 9000 {
		log.Fatal("invalid mtu")
	}
	tun, tnet, e := netstack.CreateNetTUN([]netip.Addr{addr}, []netip.Addr{dns}, c.MTU)
	if e != nil {
		log.Fatal("netstack initialization failed")
	}
	dev := device.NewDevice(tun, conn.NewDefaultBind(), device.NewLogger(device.LogLevelSilent, ""))
	defer dev.Close()
	uapi := fmt.Sprintf("private_key=%s\npublic_key=%s\nallowed_ip=0.0.0.0/0\nendpoint=%s\npersistent_keepalive_interval=25\n", private, public, c.Endpoint)
	if dev.IpcSet(uapi) != nil {
		log.Fatal("WireGuard configuration rejected")
	}
	if dev.Up() != nil {
		log.Fatal("WireGuard startup failed")
	}
	var stats counters
	tr := &http.Transport{DialContext: tnet.DialContext, Proxy: nil, DisableCompression: true, MaxIdleConns: 24, IdleConnTimeout: 30 * time.Second, ResponseHeaderTimeout: 40 * time.Second}
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/__pureline_lab_health" && !r.URL.IsAbs() && r.Method == http.MethodGet {
			runtime, _ := dev.IpcGet()
			fields := map[string]string{}
			for _, line := range strings.Split(runtime, "\n") {
				kv := strings.SplitN(line, "=", 2)
				if len(kv) == 2 && (kv[0] == "last_handshake_time_sec" || kv[0] == "rx_bytes" || kv[0] == "tx_bytes") {
					fields[kv[0]] = kv[1]
				}
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]any{"run_id": "pureline-wg-lab-20261127", "transport": "wireguard-go-netstack", "requests": stats.Requests.Load(), "connected": stats.Connected.Load(), "errors": stats.Errors.Load(), "bytes_up": stats.BytesUp.Load(), "bytes_down": stats.BytesDown.Load(), "wireguard": fields})
			return
		}
		stats.Requests.Add(1)
		if r.Method == http.MethodConnect {
			_, port, e := net.SplitHostPort(r.Host)
			if e != nil || (port != "80" && port != "443") {
				http.Error(w, "unsupported destination", http.StatusBadRequest)
				return
			}
			ctx, cancel := context.WithTimeout(r.Context(), 25*time.Second)
			upstream, e := tnet.DialContext(ctx, "tcp", r.Host)
			cancel()
			if e != nil {
				stats.Errors.Add(1)
				http.Error(w, "tunnel connection unavailable", http.StatusBadGateway)
				return
			}
			hj, ok := w.(http.Hijacker)
			if !ok {
				upstream.Close()
				http.Error(w, "unsupported connection", 500)
				return
			}
			client, buffer, e := hj.Hijack()
			if e != nil {
				upstream.Close()
				return
			}
			defer client.Close()
			defer upstream.Close()
			_, _ = buffer.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n")
			if buffer.Flush() != nil {
				return
			}
			stats.Connected.Add(1)
			deadline := time.Now().Add(2 * time.Minute)
			_ = client.SetDeadline(deadline)
			_ = upstream.SetDeadline(deadline)
			done := make(chan struct{}, 2)
			go func() { n, _ := io.Copy(upstream, buffer); stats.BytesUp.Add(n); done <- struct{}{} }()
			go func() { n, _ := io.Copy(client, upstream); stats.BytesDown.Add(n); done <- struct{}{} }()
			<-done
			return
		}
		if !r.URL.IsAbs() || r.URL.Scheme != "http" {
			http.Error(w, "absolute HTTP URL or CONNECT required", 400)
			return
		}
		port := r.URL.Port()
		if port != "" && port != "80" {
			http.Error(w, "unsupported destination", 400)
			return
		}
		out := r.Clone(r.Context())
		out.RequestURI = ""
		out.Header.Del("Proxy-Connection")
		out.Header.Del("Proxy-Authorization")
		resp, e := tr.RoundTrip(out)
		if e != nil {
			stats.Errors.Add(1)
			http.Error(w, "tunnel request unavailable", 502)
			return
		}
		defer resp.Body.Close()
		for name, values := range resp.Header {
			for _, v := range values {
				w.Header().Add(name, v)
			}
		}
		w.WriteHeader(resp.StatusCode)
		n, _ := io.Copy(w, resp.Body)
		stats.BytesDown.Add(n)
		stats.Connected.Add(1)
	})
	server := &http.Server{Addr: *listen, Handler: handler, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 90 * time.Second, MaxHeaderBytes: 64 * 1024, ErrorLog: log.New(io.Discard, "", 0)}
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-stop
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(ctx)
	}()
	log.Print("Pureline isolated WireGuard CONNECT proxy ready on " + *listen)
	if e = server.ListenAndServe(); e != nil && !errors.Is(e, http.ErrServerClosed) {
		log.Fatal("proxy listener failed")
	}
}
