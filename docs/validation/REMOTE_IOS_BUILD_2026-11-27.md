# Pureline Remote: full iOS application and native verification

Date: 2026-11-27 UTC

## Outcome

The full existing HTTrail/Pureline application builds for arm64 iOS and arm64
iOS Simulator without the missing local CoreML assets. The normal
iosapp/project.yml retains its local model targets and resources.

The latest native fixes are committed as
245f67ecbcb59ee52aa047d6ead84ee4b47d62ca. The final Release archive finished at
02:38:42 UTC; the full-app UI test build finished at 02:33:13 UTC. Both returned
exit code 0. The affected native unit suite passed all 13 tests with zero
failures at 02:31:02 UTC.

## Product composition

The Remote edition keeps the original app entry point, AppModel, API
composition, rules, realtime tools, saved captures, settings, fonts and
translations. Its Image Filter tab opens the production WireGuard controls.

The conditional changes in CaptureView.swift and SetupView.swift show saved
captures and remote setup while hiding unavailable local capture, local CA,
local proxy and Bonjour controls. The normal build path remains intact.

The Remote extension delegates to the same official WireGuard transport used
by the normal product and rejects profiles selecting local capture. The local
classifier UI, inference services and model resources are excluded.
ImageFilterCore contains only the existing configuration schema needed for
legacy diagnostic exports.

A Remote-only post-build phase updates the display-name and bundle-name keys
in copied localized InfoPlist.strings files. All 11 built localizations say
Pureline Remote; upstream localization source files remain unchanged.

The generated UI target PurelineRemoteWireGuardUITests uses the existing
WireGuardUITests source and targets HTTrailiOS / PurelineRemote.app. It does not
import the focused host's unit-test target.

## Native correctness and credential review

The Remote profile parser now accepts exactly one peer. A distinct second peer
is rejected before upstream configuration construction, preventing the server
label from disagreeing with the peer receiving the IPv4 default route.

Mutation-time preference reads now throw and stop the operation on failure.
The controller clears its manager, profile flag, endpoint, IPv6 indicator,
connection status and counters. UI reload remains nonthrowing. Failed profile
replacement also discards its mutated in-memory object before any best-effort
refresh.

Two regression tests cover distinct-peer ambiguity and a failed preferences
read after a previously loaded profile. The latter injects only a preferences
reader and an unsaved synthetic manager; it does not enable Simulator VPN or
call preference-save or VPN-start APIs.

Credentials remain in the already entitled App Group Keychain, with
AfterFirstUnlockThisDeviceOnly accessibility and synchronization disabled.
Only persistent references enter VPN preferences. Adapter logging omits raw
backend messages, and the statistics projection returns only counters and
handshake time. This follows the pinned official WireGuard pattern and
[Apple's documented App Group keychain support](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps/).

## Reproduce the project

From the repository root:

    python3 scripts/generate_remote_ios_project.py
    python3 scripts/generate_remote_ios_project.py --check
    cd iosapp
    xcodegen generate --spec project.remote.yml

The generator uses PyYAML when available and otherwise macOS system
Ruby/Psych. Both paths passed --check against the current base project.
The committed derived spec uses JSON syntax, which is valid YAML.

Generated project: PurelineRemote.xcodeproj.
Application scheme: PurelineRemote.
Full-app UI scheme: PurelineRemoteWireGuardUI.

Generated plist and entitlement files have separate RemoteIntegration paths.
The bundle identifier, extension identifier, App Group and signing settings
remain those of the full product. This is an alternate edition with the same
application identity.

## Build and test commands

Final unsigned device archive:

    xcodebuild \
      -project iosapp/PurelineRemote.xcodeproj \
      -scheme PurelineRemote -configuration Release \
      -destination 'generic/platform=iOS' \
      -derivedDataPath /Users/m1/caches/DerivedData/pureline-wireguard-20261127/Remote \
      -archivePath /Users/m1/builds/_artifacts/pureline-remote-20261127/PurelineRemote-245f67e.xcarchive \
      -jobs 2 CODE_SIGNING_ALLOWED=NO archive

Full-app arm64 simulator UI runner, including SVG and high-resolution cases:

    xcodebuild \
      -project iosapp/PurelineRemote.xcodeproj \
      -scheme PurelineRemoteWireGuardUI -configuration Debug \
      -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath /Users/m1/caches/DerivedData/pureline-wireguard-20261127/Remote \
      -jobs 2 ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build-for-testing

Affected unit suite, on the dedicated simulator:

    xcodebuild \
      -project iosapp/PurelineWireGuardValidation.xcodeproj \
      -scheme PurelineWireGuardValidation -configuration Debug \
      -destination 'id=6A58D1EB-9CA4-4714-9151-2FE8B54214D7' \
      -derivedDataPath /Users/m1/caches/DerivedData/pureline-wireguard-20261127/Validation \
      -jobs 2 -collect-test-diagnostics never \
      CODE_SIGNING_ALLOWED=NO test

The Remote Go bridge also uses two workers. Its source checks, native linkage
and platform-specific output paths are documented in
WIREGUARD_BRIDGE_2026-11-27.md.

## Latest artifacts and receipts

| Check | Result |
|---|---|
| Native parser/preferences unit suite | 13 passed, 0 failures |
| Full-app UI runner | Build-for-testing succeeded; execution belongs to the UI owner |
| Device Release archive | Succeeded; unsigned |
| Device extension native linkage | wgTurnOn, wgTurnOff, wgGetConfig and wgSetConfig present |
| Mach-O platforms | IOS and IOSSIMULATOR; minimum 26.5, SDK 27.0 |
| Local model payloads | Zero .mlmodel, .mlmodelc or .mlpackage items |
| Embedded framework | Schema-only ImageFilterCore.framework |
| Localized product names | All 11 locales verified as Pureline Remote |

Final device archive:

    /Users/m1/builds/_artifacts/pureline-remote-20261127/PurelineRemote-245f67e.xcarchive

Device app: 17,684 KiB. Complete archive: 80,652 KiB.

Simulator app:

    /Users/m1/caches/DerivedData/pureline-wireguard-20261127/Remote/Build/Products/Debug-iphonesimulator/PurelineRemote.app

Simulator app: 44,976 KiB.

Full-app UI runner manifest:

    /Users/m1/caches/DerivedData/pureline-wireguard-20261127/Remote/Build/Products/PurelineRemoteWireGuardUI_iphonesimulator27.0-arm64.xctestrun

Unit result bundle:

    /Users/m1/builds/_artifacts/pureline-remote-20261127/WGGuardRegressions-20261127T023048Z.xcresult

Artifact SHA-256 values:

| Artifact | SHA-256 |
|---|---|
| Device app executable | 1d5d176176699dc02287056edc5f267ca6919fa841830725597c0496d6f862d1 |
| Device extension executable | a32581423600394aa0179505c87a23912aee36e9c94ddac1219b51b4c06240b9 |
| Simulator app code dylib | 995e583f1f0d1ec1d030763b0a5843a081755035075260cfc562c902a17a6520 |
| Simulator extension code dylib | ae4a3f425fb04e8a46c09621aa1b9c7e55b7c674d48e2138eae760d6b147ef24 |
| Archive content manifest, 58 files | 273e29c15a205fc31f36aa8cf160bdb58684e78133adcd4a15d0f4c9075dc9b3 |

The archive manifest hash covers a canonical JSON map of relative paths to
file-content SHA-256 values, with sorted keys and compact separators. It is
not a tar-file hash. Detailed source hashes, commands, timestamps, platform
inspection and the complete map are in REMOTE_IOS_BUILD_2026-11-27.json.

Operational receipts and earlier build attempts are preserved under:

    /Users/m1/builds/_preflight/pureline-remote-20261127

The initial device archive and the later branding archive are also preserved.
The first attempt ended at a remote execution timeout after package resolution;
all subsequent reported successes have explicit zero-exit receipts.

## Runtime boundary

The build owner ran only the affected native unit suite and released the
dedicated simulator afterward. Full-app UI execution and filtering acceptance
belong to the coordinating test owner.

These unsigned archives establish compilation and packaging. They do not
establish physical-device packet-tunnel activation, signed Keychain access,
internet UDP reachability, or image-filter accuracy. iOS Simulator cannot run
the packet-tunnel VPN; browser/URLSession tests use the separately configured
Mac WireGuard route. A connected VPN alone is not an image-classification
accuracy result. The default local-model build still requires its generated
CoreML assets.
