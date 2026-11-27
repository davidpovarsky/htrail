# Pureline full iOS release 1.0 (602) — 27 November 2026

## Outcome

The full product was archived with the existing Apple distribution identity, exported, verified locally, validated by Apple, uploaded, and independently read back from App Store Connect with processing state **VALID**.

| Identity | Value |
|---|---|
| Source commit | d89d53106d5db87aaa4c9356c9114dbe76daa839 |
| App | Pureline |
| App Store Connect app ID | 6809383144 |
| Bundle ID | com.davidpovarsky.pureline |
| Version / build | 1.0 / 602 |
| Apple build ID | c99a9917-9a8b-4fad-9297-cb6a061b126a |
| Apple processing state | VALID |
| Internal beta state | READY_FOR_BETA_TESTING |
| External beta state | READY_FOR_BETA_SUBMISSION |
| Xcode / SDK | Xcode 27.0 (27A266a), iPhoneOS 27.0 |
| Deployment target | iOS 26.5 |
| Distribution team | NA6HPWARQ2 |

This is the full HTTrailiOS scheme generated from the frozen project.yml. The main app and PacketTunnel extension both contain the production NudeNet and MobileCLIP2-S2 compiled models and their verified JSON resources. The app also contains both ImageFilterCore and EmbeddedImageFilter frameworks. The Remote path remains present alongside Direct local filtering.

## Exact artifact and source evidence

The exported IPA is 170,165,569 bytes, SHA256 **c08dd6284f13270b5a786d1a01c56f2417cc59f30e0cfc917c42df3a817b9c48**.

The retained archive has 318,128,578 logical bytes in 174 files and tree SHA256 **81cf66fb5bd4b0d5ea9032ffe4f61f009a7b7d45a6c9649b7d4badadb470b578**. Tree hashes concatenate sorted relative file paths and file bytes. The archive and all four matching dSYMs remain on the Mac together with the IPA and xcresult evidence.

The Oracle manifest was generated from committed Git blobs for all 894 root and recursively pinned submodule files. The Mac has no Git checkout metadata, so no Mac HEAD is claimed. Before and after archiving, all tracked production source and build-script inputs matched the frozen commit; generated inputs were qualified separately. The archive's 129 repository Swift inputs were checked against those committed hashes. The 682 external Swift inputs came from nine clean resolved package checkouts at exact recorded revisions. Generated Swift, Xcode project and model resources have separate hashes.

The 246 documented differences from the complete repository manifest are noncompiled documentation, deployment/lab material, board/ignore files, the unused validation project specification and the generated main Info.plist. Every explicit generated Info.plist property matches the frozen full project.yml; its privacy strings and file-sharing entries are generator output. No additional source file was present.

Submodules remain pinned to AI-Image-Classifier 5291eedb9b46fa978e36ccec4f5504b017afe809 and WireGuard 2fec12a6e1f6e3460b6ee483aa00ad29cddadab1.

## Validation performed

| Gate | Result |
|---|---|
| Native proxy evidence | 29 distinct core cases accepted |
| Native image/runtime evidence | 27 distinct cases accepted: 25 reused unchanged passes plus 2 final focused passes |
| Model qualification | Original 10 fixtures and numerical thresholds preserved; CPU_ONLY passes |
| Full app and extension archive | Exit 0; 180.505 seconds |
| Archive signature/resource verification | Passed |
| IPA export | Exit 0 |
| Extracted IPA signature/resource verification | Passed |
| Apple validation | Exit 0; VERIFY SUCCEEDED with no errors |
| TestFlight upload and Apple processing | Passed; independent ASC state VALID |

The original repeated-inference smoke now loads both local models and completes three inference calls after the supported CPU Vision policy repair. Its measured prepare time was 982 ms; inference calls were 1190/294/233 ms. Physical footprint was 20,351,280 bytes before preparation and 50,858,408 bytes after inference. These are shared-host simulator observations, not a physical extension memory budget.

Conversion qualification uses the existing iOS27 MobileCLIP CPU-only runtime policy. The original cosine threshold of 0.995, score-difference threshold of 0.03 and all ten fixtures were unchanged. CPU_ONLY achieved minimum cosine 0.9998859455775914 and maximum score difference 0.0008430468728841678. The original ALL result failed the cosine gate and is retained as negative evidence. No lower quality threshold or replacement model variant was introduced.

Both shipping bundles have the expected version/build, arm64 iOS platform, team/app-group entitlements, original App Store profile UUIDs, get-task-allow disabled, and valid code signatures. Their prompt embeddings, model manifest and NudeNet labels match the qualified source resources. The PacketTunnel binary contains the real WireGuard exports. All four app/extension/framework dSYM UUIDs match the corresponding signed binaries.

## Signing environment and storage

The existing identity and profiles were reused. SentinelX's Mac execution context did not expose the certificate to Xcode's unscoped selection. The verified SSH login exposed it; invoking the existing unlock helper within that same SSH security session made private-key signing work. A tiny owned bundle copy was signed and strictly verified before the successful archive. The earlier failed signing preflights remain in separate receipts. No identity, provisioning, keychain search-list, default keychain or trust configuration was replaced.

Release phases were admitted using measured filesystem capacity and their incremental requirements. Existing source, caches and release evidence were retained. Only the newly created temporary IPA verification extraction was removed after verification.

## Scope and remaining device evidence

The build is processed and READY_FOR_BETA_TESTING. An optional read-only request for its beta-group relationships returned HTTP 403 Forbidden; inspection stopped there. Group association and tester installation availability are therefore not established by this receipt. No tester-group changes were made.

The validated Direct local filtering path is PacketTunnelProvider → ImageFilterProxyBridge → ImageFilterCore.DirectImageSafetyAnalyzer → PurelineHumanDetectionService. Remote WireGuard and remote-proxy paths bypass that local analyzer as designed.

The separate EmbeddedImageFilter app-tab and LocalInferenceServer still use the unchanged vendor inference services. The signed full archive proves their compilation and packaging; this runtime repair does not certify their standalone iOS27 inference behavior.

No physical iPad was attached. Physical PacketTunnel peak memory, jetsam behavior, background/network transitions and device acceptance remain distinct from the simulator and Apple distribution gates.

## Retained files

- IPA: /Users/m1/builds/_artifacts/pureline-full-602-20261127/export/IPA/HTTrailiOS.ipa
- Archive: /Users/m1/builds/_artifacts/pureline-full-602-20261127/Pureline-602-ssh-unlocked.xcarchive
- Full receipt bundle: release-receipts.json
- Source manifest: /Users/m1/builds/_preflight/pureline-app-source-manifest-20261127.json
- Native core/runtime and model qualification receipts: referenced by path and SHA256 in the receipt bundle.

The receipt bundle contains the exact commands, source/resource hashes, selected metadata, phase outcomes, preserved failure references and Apple's validation/upload output, with authentication values redacted.
