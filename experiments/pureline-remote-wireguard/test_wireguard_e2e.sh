#!/usr/bin/env bash
set -euo pipefail
ROOT=/srv/pureline-poc
NS=purelineprobe
WG=$ROOT/tools/extracted/usr/bin/wg
cleanup() {
 sudo -n ip netns del "$NS" 2>/dev/null || true
 sudo -n ip link del plprobe0 2>/dev/null || true
 rm -f "$ROOT/wg-probe.conf"
}
trap cleanup EXIT
"$ROOT/.venv/bin/python" - <<'PY'
import json,base64
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding,PublicFormat
root=Path('/srv/pureline-poc')
data=json.loads((root/'wg-profile/wireguard.conf').read_text())
priv=X25519PrivateKey.from_private_bytes(base64.b64decode(data['server_key']))
pub=base64.b64encode(priv.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)).decode()
conf=f"""[Interface]
PrivateKey = {data['client_key']}
[Peer]
PublicKey = {pub}
AllowedIPs = 0.0.0.0/0
Endpoint = 172.31.251.1:51820
PersistentKeepalive = 25
"""
p=root/'wg-probe.conf'
p.write_text(conf)
p.chmod(0o600)
PY
sudo -n ip netns add "$NS"
sudo -n ip link add plprobe0 type veth peer name plprobe1
sudo -n ip link set plprobe1 netns "$NS"
sudo -n ip addr add 172.31.251.1/30 dev plprobe0
sudo -n ip link set plprobe0 up
sudo -n ip netns exec "$NS" ip link set lo up
sudo -n ip netns exec "$NS" ip addr add 172.31.251.2/30 dev plprobe1
sudo -n ip netns exec "$NS" ip link set plprobe1 up
sudo -n ip netns exec "$NS" ip link add wgtest type wireguard
sudo -n ip netns exec "$NS" "$WG" setconf wgtest "$ROOT/wg-probe.conf"
sudo -n ip netns exec "$NS" ip addr add 10.0.0.1/32 dev wgtest
sudo -n ip netns exec "$NS" ip link set wgtest up
sudo -n ip netns exec "$NS" ip route add 1.1.1.1/32 dev wgtest
echo "IP route:"; sudo -n ip netns exec "$NS" ip route get 1.1.1.1
echo "HTTPS over tunneled IP:"
sudo -n ip netns exec "$NS" curl -LsS --max-time 30 --cacert "$ROOT/wg-profile/mitmproxy-ca-cert.pem" -o /dev/null -w 'status=%{http_code} total=%{time_total} remote=%{remote_ip}\n' https://1.1.1.1/cdn-cgi/trace || true
echo "Filtered HTTPS image through WireGuard:"
IMAGE_HOST=images.unsplash.com
IMAGE_IP=$(getent ahostsv4 "$IMAGE_HOST" | awk 'NR==1 {print $1}')
sudo -n ip netns exec "$NS" ip route add "$IMAGE_IP"/32 dev wgtest
sudo -n ip netns exec "$NS" curl -LsS --max-time 35 --resolve "$IMAGE_HOST:443:$IMAGE_IP" --cacert "$ROOT/wg-profile/mitmproxy-ca-cert.pem" -D "$ROOT/wg-image-headers.txt" -o "$ROOT/wg-filtered.jpg" -w 'image_http=%{http_code} image_bytes=%{size_download} total_seconds=%{time_total}\n' 'https://images.unsplash.com/photo-1500648767791-00dcc994a43e?w=600'
grep -Ei '^(x-local-image-filter|content-type)' "$ROOT/wg-image-headers.txt" | tail -10
file "$ROOT/wg-filtered.jpg"
echo "WireGuard connection counters:"
sudo -n ip netns exec "$NS" "$WG" show wgtest transfer
echo "WireGuard handshake age (0 means none):"
sudo -n ip netns exec "$NS" "$WG" show wgtest latest-handshakes | awk '{print $2}'
