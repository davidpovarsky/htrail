# Distribution & Release

HTTrail ships two ways. Build/run/test basics are in the root `README.md` and
`CLAUDE.md`; this doc covers packaging and release.

> The App Store **signing + submission tooling** (API keys, `asc.py`, the full
> submission runbook) is intentionally kept **out of the public tree** under
> `scripts/appstore/` and `docs/appstore/` (both git-ignored). This doc only
> describes the parts that are safe to publish — it never contains key material
> or key IDs; those live in encrypted GitHub secrets.

## 1. Direct download (GitHub release)

The full-feature, **un-sandboxed** macOS build, distributed as a `.zip` on the
GitHub Releases page. It is ad-hoc signed (no paid *Developer ID* cert), so
macOS quarantines it on first launch.

**Build & publish:**

```bash
./scripts/make_app.sh release                      # base bundle (Info.plist, icons, fonts)
# make it universal (Apple Silicon + Intel):
swift build -c release --product HTTrail --arch arm64 --arch x86_64
cp .build/apple/Products/Release/HTTrail dist/HTTrail.app/Contents/MacOS/HTTrail
codesign --force --deep --sign - dist/HTTrail.app
mkdir -p dist/release
ditto -c -k --sequesterRsrc --keepParent dist/HTTrail.app dist/release/HTTrail-macOS.zip

gh release create vX.Y dist/release/HTTrail-macOS.zip \
  --repo anusoft/htrail --title "HTTrail X.Y — macOS" --latest \
  --notes-file docs/appstore/release-notes-vX.Y.md
```

Keep the asset named **`HTTrail-macOS.zip`** — the site links the stable
`releases/latest/download/HTTrail-macOS.zip` URL, which auto-follows the newest
release.

**First-launch caveat (tell users):** the ad-hoc build is Gatekeeper-quarantined.
Clear it once:

```bash
xattr -dr com.apple.quarantine /Applications/HTTrail.app
```

A no-prompt direct build would need a *Developer ID Application* cert +
notarization (`notarytool`) — not currently provisioned.

## 2. App Store (macOS + iOS)

iOS TestFlight builds are built, signed, validated, and optionally uploaded by
`.github/workflows/build-ios-testflight.yml` (**Build Signed iOS IPA and Upload
to TestFlight**). This path builds directly from the selected branch and uploads
the IPA as a workflow artifact; it does not require a GitHub Release.

The older `.github/workflows/deploy.yml` (**Deploy to App Store**) remains
available for uploading an already-signed iOS or macOS binary from a draft
GitHub Release and optionally submitting it for App Store review.

### Secrets (set once, encrypted, write-only)

| Secret | Contents |
|---|---|
| `ASC_KEY_P8` | base64 of the App Store Connect API key `.p8` |
| `ASC_KEY_ID` | the API key id |
| `ASC_ISSUER_ID` | the team's API issuer id |
| `ASC_PY_B64` | base64 of `scripts/appstore/asc.py` (so CI runs the private deploy script without it living in the repo) |

The signed iOS workflow uses these additional secrets:

| Secret | Required | Contents |
|---|---|---|
| `APPLE_CERTIFICATE_P12_B64` | Every signed build | Base64-encoded Apple Distribution `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | Every signed build | Plain-text password used when exporting that `.p12` |
| `APPLE_MAIN_PROVISIONING_PROFILE_B64` | Every signed build | Base64 App Store profile for `com.davidpovarsky.pureline` |
| `APPLE_TUNNEL_PROVISIONING_PROFILE_B64` | Every signed build | Base64 App Store profile for `com.davidpovarsky.pureline.PacketTunnel` |
| `APPLE_TEAM_ID` | Every signed build | Plain-text Apple Developer Team ID |
| `ASC_KEY_P8` | TestFlight upload only | Base64-encoded App Store Connect API key `.p8` |
| `ASC_KEY_ID` | TestFlight upload only | App Store Connect API key ID |
| `ASC_ISSUER_ID` | TestFlight upload only | App Store Connect API issuer ID |

`ASC_PY_B64` is not needed by the signed iOS/TestFlight workflow. It remains a
requirement only for the older review-submission workflow.

Set/rotate them with `gh secret set <NAME> --repo anusoft/htrail`. **Re-sync
`ASC_PY_B64` whenever `asc.py` changes** (it is vendored as a secret, not checked out):

```bash
base64 -i scripts/appstore/asc.py | gh secret set ASC_PY_B64 --repo anusoft/htrail
```

### Signed iOS/TestFlight build

In GitHub Actions, run **Build Signed iOS IPA and Upload to TestFlight** from the
branch to distribute. Leave `upload_to_testflight` enabled to validate and
upload automatically, or disable it to produce and retain only the signed IPA
artifact. CI derives `CFBundleVersion` as `GITHUB_RUN_NUMBER * 100 +
GITHUB_RUN_ATTEMPT`, so reruns have a distinct TestFlight build number.

Before spending time on the archive, upload-enabled runs use the App Store
Connect API to confirm an app record exists for `com.davidpovarsky.pureline`.
Apple requires this record before the first upload. If it is absent, the workflow
stops with instructions to create it using that Bundle ID plus the app name,
primary language, SKU, and user-access choice required by App Store Connect.

The workflow decodes signing assets only into runner-temporary storage, imports
the certificate into a temporary keychain, installs both provisioning profiles,
and deletes those assets at the end of the job. Never add decoded signing files
to the repository.

### Existing release-based upload & dispatch

```bash
# macOS — sandboxed Mac App Store variant:
DISTRIBUTION=1 ./scripts/make_mas.sh        # -> dist/mas/HTTrail.pkg
# iOS can also use an already-signed IPA from another trusted build path.

# stage the signed binary on a DRAFT release (not publicly visible; the Actions
# token can still read it):
gh release create appstore-macos-X.Y dist/mas/HTTrail.pkg \
  --repo anusoft/htrail --draft --notes "App Store build"

# dispatch upload (+ submit):
gh workflow run deploy.yml --repo anusoft/htrail \
  -f platform=macos -f tag=appstore-macos-X.Y -f asset=HTTrail.pkg \
  -f build_version=<CFBundleVersion> -f submit=true
```

`platform=ios` maps to an `.ipa` upload (`altool -t ios`, `ASC_PLATFORM=IOS`);
`platform=macos` maps to the `.pkg` (`altool -t macos`, `ASC_PLATFORM=MAC_OS`).
With `submit=true` the workflow waits for Apple processing, attaches the build,
and submits for review via `asc.py`.

### Existing deploy workflow limitations

- **Signing.** `deploy.yml` still does upload/submit only. Use the signed iOS
  workflow above for end-to-end iOS CI signing and TestFlight delivery.
- `altool` can exit non-zero on a benign post-upload precheck note; the step
  warns instead of failing — confirm the build appears in App Store Connect.

The end-to-end manual procedure, the App Store Connect gotchas (per-platform
review submissions, copyright/sign-in/availability fields, asset-catalog intake
rejection), and the macOS MAS-variant notes are in the **private** runbook at
`docs/appstore/submission-runbook.md`.
