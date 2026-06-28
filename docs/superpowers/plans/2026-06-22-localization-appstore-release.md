# HTTrail Localization And App Store Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Localize HTTrail's app UI and App Store metadata for English, Simplified Chinese, Hindi, Spanish, Arabic, French, Bangla, Portuguese, Russian, Urdu, and Thai, then submit fresh iOS and macOS builds for review.

**Architecture:** Keep translations in generated `.lproj` resource folders so SwiftUI string literals resolve through standard Apple localization. Extend the existing App Store Connect helper to create missing localizations before patching metadata, and reuse the existing screenshot assets for each new locale so every metadata localization is review-ready.

**Tech Stack:** SwiftUI, Swift Package Manager, xcodegen, `.strings` localization resources, App Store Connect API, `xcodebuild`, `altool`, repo-local `scripts/appstore/asc.py`.

---

### Task 1: Inventory And Plan The Locale Set

**Files:**
- Read: `Package.swift`
- Read: `iosapp/project.yml`
- Read: `scripts/make_app.sh`
- Read: `scripts/make_mas.sh`
- Read: `scripts/appstore/asc.py`
- Read: `docs/appstore/metadata/en-US/*.txt`
- Read: `docs/appstore/metadata/th/*.txt`

- [x] **Step 1: Confirm current localization state**

Run:
```bash
find . -maxdepth 4 \( -name '*.xcstrings' -o -name 'Localizable.strings' -o -name '*.lproj' -o -path './docs/appstore/metadata/*' \) -print | sort
```

Expected: metadata exists for `en-US` and `th`; no UI localization resources exist yet.

- [x] **Step 2: Confirm supported App Store locales**

Use Apple's App Store localization reference and choose one metadata locale per requested language:
`en-US`, `zh-Hans`, `hi`, `es-MX`, `ar-SA`, `fr-FR`, `bn-BD`, `pt-BR`, `ru`, `ur-PK`, `th`.

### Task 2: Add Resource Plumbing For UI Localizations

**Files:**
- Modify: `iosapp/project.yml`
- Modify: `scripts/make_app.sh`
- Modify: `scripts/make_mas.sh`
- Create: `Resources/<locale>.lproj/Localizable.strings`
- Create: `Resources/<locale>.lproj/InfoPlist.strings`

- [ ] **Step 1: Add iOS resource folder to xcodegen**

Add `../Resources/Localizations` or the generated `.lproj` directories to `HTTrailiOS.sources` with `buildPhase: resources`.

- [ ] **Step 2: Copy localization folders into macOS bundles**

Update both macOS packaging scripts so every `Resources/*.lproj` directory lands in `Contents/Resources/`.

- [ ] **Step 3: Regenerate the iOS Xcode project**

Run:
```bash
cd iosapp && xcodegen generate
```

Expected: `HTTrailiOS.xcodeproj` includes the localization resources.

### Task 3: Generate UI Translation Resources

**Files:**
- Create: `scripts/localization/generate_localizations.py`
- Create/Update: `Resources/*.lproj/Localizable.strings`
- Create/Update: `Resources/*.lproj/InfoPlist.strings`

- [ ] **Step 1: Define the locale list**

Use this exact ordered list:
```python
LOCALES = ["en-US", "zh-Hans", "hi", "es-MX", "ar-SA", "fr-FR", "bn-BD", "pt-BR", "ru", "ur-PK", "th"]
```

- [ ] **Step 2: Generate Apple `.strings` files**

The generator must escape quotes, backslashes, and newlines, then write UTF-8 `.strings` files in every locale directory.

- [ ] **Step 3: Verify generated resources parse**

Run:
```bash
for f in Resources/*.lproj/*.strings; do plutil -lint "$f"; done
```

Expected: every file reports `OK`.

### Task 4: Add Localized App Store Metadata

**Files:**
- Create/Update: `docs/appstore/metadata/<locale>/*.txt`
- Modify: `scripts/appstore/asc.py`

- [ ] **Step 1: Generate metadata directories**

Each locale directory must contain:
`name.txt`, `subtitle.txt`, `promotional_text.txt`, `description.txt`, `keywords.txt`, `support_url.txt`, `marketing_url.txt`, `privacy_url.txt`, and `copyright.txt`.

- [ ] **Step 2: Enforce App Store length limits**

Run a validator that confirms:
name <= 30 characters, subtitle <= 30 characters, promotional text <= 170 characters, keywords <= 100 characters, description <= 4000 characters.

- [ ] **Step 3: Teach `asc.py` to create missing localizations**

Before patching text or uploading screenshots, if an `appStoreVersionLocalization` or `appInfoLocalization` for the requested locale does not exist, POST it with the requested locale relationship.

### Task 5: Upload Metadata And Screenshots For Every Locale

**Files:**
- Read: `docs/appstore/ios/marketing/iphone/en/*.png`
- Read: `docs/appstore/ios/marketing/ipad/en/*.png`
- Read: `docs/appstore/mac/marketing/en/*.png`

- [ ] **Step 1: Apply text metadata to iOS and macOS**

Run `set-text-files` for every locale once with default `ASC_PLATFORM=IOS`, then once with `ASC_PLATFORM=MAC_OS`.

- [ ] **Step 2: Upload screenshot sets for every locale**

For iOS, upload the English iPhone and iPad screenshot sets to every locale. For macOS, upload the English desktop screenshot set to every locale.

- [ ] **Step 3: Confirm App Store Connect status lists every locale**

Run:
```bash
python3 scripts/appstore/asc.py status
ASC_PLATFORM=MAC_OS python3 scripts/appstore/asc.py status
```

Expected: all 11 locales appear with description, keywords, and required screenshot counts.

### Task 6: Build, Upload, Attach, And Submit New Versions

**Files:**
- Modify: `iosapp/project.yml`
- Generated: `iosapp/HTTrailiOS.xcodeproj/project.pbxproj`
- Generated: `iosapp/build/export/HTTrailiOS.ipa`
- Generated: `dist/mas/HTTrail.pkg`

- [ ] **Step 1: Cancel current review submissions**

Cancel current iOS and macOS `WAITING_FOR_REVIEW` review submissions before attaching new builds.

- [ ] **Step 2: Bump build numbers only**

Use build numbers above the current shared maximum. Keep marketing version `1.0`.

- [ ] **Step 3: Archive/export/upload iOS**

Run the existing archive/export/upload path and wait until the build is `VALID`.

- [ ] **Step 4: Build/upload macOS MAS package**

Run:
```bash
DISTRIBUTION=1 BUNDLE_ID=com.1moby.httrail BUILD_NUMBER=<new-mac-build> ./scripts/make_mas.sh
```

Validate, upload, and wait until the macOS build is `VALID`.

- [ ] **Step 5: Attach and submit both platforms**

Run `encryption`, `attach-build`, and `submit` for iOS and macOS. Final status must be `WAITING_FOR_REVIEW` for both platforms.

### Task 7: Verification

**Files:**
- Read: generated `.strings`
- Read: generated metadata directories
- Read: App Store Connect status output

- [ ] **Step 1: Build/test verification**

Run:
```bash
swift test
cd iosapp && xcodegen generate
```

Expected: tests pass and project generation succeeds.

- [ ] **Step 2: Localization coverage verification**

Confirm every requested locale has app UI strings and metadata files, and every metadata field passes length validation.

- [ ] **Step 3: App Store review verification**

Confirm both current review submissions are new submissions with fresh build IDs and state `WAITING_FOR_REVIEW`.
