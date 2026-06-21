# HTTrail on iOS

There are two ways to capture traffic with the HTTrail iOS app (`iosapp/`).

## 1. On-device capture (VPN) — captures *this* iPhone

The iOS app ships a **Packet Tunnel network extension**
(`iosapp/PacketTunnel/`). The Setup tab is a two-step flow:

1. **Install VPN + CA Profile.** The app builds a single `.mobileconfig`
   containing the root CA **and** a VPN payload that references the packet-tunnel
   extension, serves it from a loopback HTTP server with the
   `application/x-apple-aspen-config` MIME type, and opens it in Safari. iOS
   prompts to download it; you then **approve it in Settings ▸ General ▸ VPN &
   Device Management** and enable CA trust in *Certificate Trust Settings*. (A
   share sheet cannot install a profile — this is the supported same-device path.)
2. **Start Capturing This Device.** Starts the installed VPN. The extension
   process — which keeps running even when the app is backgrounded — runs the
   HTTrail MITM proxy on `127.0.0.1` and publishes proxy settings that route the
   device's HTTP/HTTPS through it. Captured flows are written to the shared
   **App Group** (`group.com.1moby.httrail`) and the app tails them into the
   Capture tab.

> `NETransparentProxyProvider` is macOS-only, so iOS uses a packet tunnel. It is
> a "proxy-only" tunnel: no raw packets are routed (all IP routes are excluded),
> only the system proxy settings are injected.

**Requirements:** a paid Apple Developer account (the Network Extension /
`packet-tunnel-provider` entitlement is not available to free personal teams),
and the HTTrail **root CA installed & trusted** on the device (Setup ▸ *Install
CA Profile*, then Settings ▸ General ▸ About ▸ Certificate Trust Settings).

Both the app target and the `PacketTunnel` extension target are defined in
`iosapp/project.yml` (run `xcodegen generate`), share the App Group, and carry
the `packet-tunnel-provider` entitlement.

## 2. Configuration profile — captures *another* device through your Mac/iPhone

From the macOS app (**Setup ▸ Export iOS Profile…**) or the iOS app
(**Setup ▸ Share Proxy+CA Profile**) you get a `.mobileconfig` that installs the
root CA and points the device's HTTP/HTTPS proxy at the HTTrail host's LAN IP.

AirDrop/email it to the target device, install it (Settings ▸ Profile
Downloaded), then trust the CA under Settings ▸ General ▸ About ▸ Certificate
Trust Settings. The host's proxy must be running and both devices on the same
Wi-Fi. This path needs no Apple Developer account.
