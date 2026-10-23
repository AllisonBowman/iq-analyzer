# IQ Coach: Distribution Plan

*Written for Allison Bowman. Prepared 2026-10-15 according to the task brief. This Mac's clock reads 2026-10-23, and every source below was read on 2026-10-23.*
*The repository was only read for this plan. Nothing in it was changed.*

**How claims are marked**
- **Verified**: Apple's documentation, or a check run on this Mac, confirms it.
- **Inferred**: a reasoned conclusion that no source states directly.
- **unverified**: a claim the second review could not confirm. These are marked inline.

---

## 1. Recommendation

1. **Ship IQ Coach first as a notarized Developer ID build (Xcode's "Direct Distribution").** It is the only Apple channel the current design fits. It needs about a day of signing and packaging work and no change to the architecture. The app keeps running the user's own Python venv (`AnalyzerRunner` runs `Process` on a path the user sets). Developer ID does not require the App Sandbox, and notarization only scans what you submit.
2. **The Mac App Store and TestFlight for Mac are blocked by the external-Python design, not by paperwork.** Store apps must be sandboxed (2.4.5(i)) and self-contained (2.4.5(ii), 2.5.2), and must work without another install (4.2.3(i)). A sandboxed app cannot run a Homebrew interpreter outside its bundle or container, and any child process inherits the sandbox. A reviewer would also have no venv, so the app would fail 2.1(a).
3. **Treat the Mac App Store as a separate project (Track B).** It needs either a signed Python runtime bundled in the app (about 275 Mach-O files and roughly 416 MB of wheels to re-sign) or a Swift port of the engine. Decide only if a store listing matters for the application.

---

## 2. Track A: Developer ID and notarization (do this first)

**Where the project stands (verified on disk):**
- `project.yml` sets `CODE_SIGN_IDENTITY "-"`, `CODE_SIGN_STYLE Manual`, `ENABLE_HARDENED_RUNTIME NO` and `ENABLE_APP_SANDBOX NO`, with no `DEVELOPMENT_TEAM`.
- The Debug bundle is ad hoc signed, with no TeamIdentifier and `get-task-allow = true`. It embeds `IQCoach.debug.dylib`, `__preview.dylib` and `IQCoachTests.xctest`.
- Notarization requires all of these:
  - a Developer ID Application signature (not ad hoc, not Apple Development);
  - the hardened runtime;
  - a secure timestamp;
  - no `get-task-allow`;
  - linking against the macOS 10.9 SDK or later (met).

  So the build cannot be notarized as it stands.

Steps marked **[YOU]** need your Apple ID, Account Holder role, passwords or keychain. An agent cannot do them.

### A1. [YOU] Check the certificates and find your Team ID
```sh
security find-identity -v -p codesigning
```
- Run this in a normal Terminal. Inside Claude's sandbox it listed 0 identities, which proves nothing.
- If no `Developer ID Application: Allison Bowman (TEAMID)` appears, create one. Use Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application, or the developer portal with a CSR.
- **Only the Account Holder can create it** (verified). A team can have up to five.
- Apps signed with a timestamp keep running after the certificate expires. Signing updates needs a valid certificate.
- Write down your **Team ID** (Membership details in the portal).

### A2. [YOU] Store the notarization credentials once
Pick one of the two options.
```sh
# Option 1: Apple ID + app-specific password (create it at account.apple.com > Sign-In and Security > App-Specific Passwords)
xcrun notarytool store-credentials iqcoach-notary --apple-id "<your Apple ID>" --team-id <TEAMID>
# prompts for the app-specific password

# Option 2: App Store Connect API **Team** key (Users and Access > Integrations > App Store Connect API > Team Keys)
xcrun notarytool store-credentials iqcoach-notary \
  --key ~/private_keys/AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER-UUID>
```
- `store-credentials` checks the credentials with Apple, then saves them in the login keychain. Add `--sync` to save them to iCloud Keychain instead.
- Use a **Team** key. Apple's API page says Individual keys cannot use notaryTool, but notarytool 1.1.3's own `--help` mentions them. A Team key avoids that conflict.
- The Account Holder or an Admin can create a Team key. You can download the `.p8` only once.
- **unverified:** which App Store Connect role the key needs. One forum report says Developer works.

### A3. Add `mac/IQCoach/Sources/IQCoach.entitlements`
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.personal-information.photos-library</key><true/>
</dict></plist>
```
- **Verified:** this entitlement grants read-write access to the Photos library. It is added under Hardened Runtime > Resource Access, and is needed only because `PhotosImporter` (`--analyze-photos`) uses PhotoKit with `.readWrite`.
- **Inferred, from forum reports:** without it, a hardened app gets `.denied` and no prompt.
- **Leave these out:** `app-sandbox`, `get-task-allow` and every `cs.*` exception (allow-jit, disable-library-validation and the rest).
- **Inferred:** `Process`, Vision, `fileImporter` and PhotosPicker need no hardened-runtime entitlement. Check the file with `plutil -lint`.

### A4. Change `project.yml` (IQCoach target)
```yaml
    entitlements:
      path: Sources/IQCoach.entitlements
      properties:
        com.apple.security.personal-information.photos-library: true
    settings:
      base:
        # ...existing keys...
        DEVELOPMENT_TEAM: <TEAMID>
        INFOPLIST_KEY_NSHumanReadableCopyright: "Copyright © 2026 Allison Bowman. MIT License."
        MARKETING_VERSION: "1.0"
      configs:
        Release:
          CODE_SIGN_IDENTITY: "Developer ID Application"
          ENABLE_HARDENED_RUNTIME: YES
          OTHER_CODE_SIGN_FLAGS: "--timestamp"
          CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO
```
- Debug keeps ad hoc signing with the hardened runtime off. **Inferred:** an ad hoc process under library validation may refuse to load the `IQCoachTests` bundle through `TEST_HOST`.
- XcodeGen's `entitlements` key writes the file and sets `CODE_SIGN_ENTITLEMENTS`. Its `configs` key applies settings to one configuration (verified against the XcodeGen spec).
- Remove `CODE_SIGN_IDENTITY: "-"` from `base` once the Release override is in place.

### A5. Add `mac/IQCoach/ExportOptions.plist`
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>teamID</key><string>TEAMID</string>
</dict></plist>
```
These keys are checked against `xcodebuild -help` on Xcode 27.1 (verified). Xcode's archive and export add the secure timestamp and strip `get-task-allow`.

### A6. Add `mac/IQCoach/scripts/package-mac.sh` (outline)
```sh
#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
VER=$(grep MARKETING_VERSION project.yml | head -1 | awk -F'"' '{print $2}')
OUT=build/release
APP="$OUT/export/IQCoach.app"          # becomes "IQ Coach.app" if PRODUCT_NAME is renamed

xcodegen generate
xcodebuild -project IQCoach.xcodeproj -scheme IQCoach -configuration Release \
  -archivePath "$OUT/IQCoach.xcarchive" archive
xcodebuild -exportArchive -archivePath "$OUT/IQCoach.xcarchive" \
  -exportOptionsPlist ExportOptions.plist -exportPath "$OUT/export"

# Check before uploading
ls "$APP/Contents/MacOS" "$APP/Contents/PlugIns" 2>/dev/null   # no *.debug.dylib, __preview.dylib or .xctest
codesign -vvv --deep --strict "$APP"
codesign -dvv "$APP"                       # Authority=Developer ID Application, a Timestamp= line, runtime flag
codesign -d --entitlements - --xml "$APP" | plutil -p -   # photos-library only; no get-task-allow
lipo -archs "$APP/Contents/MacOS/"*        # decide: universal or arm64 only

# Notarize the app, then staple it
ditto -c -k --keepParent "$APP" "$OUT/IQCoach-upload.zip"
xcrun notarytool submit "$OUT/IQCoach-upload.zip" --keychain-profile iqcoach-notary --wait --timeout 2h
# xcrun notarytool log <submission-id> --keychain-profile iqcoach-notary "$OUT/notary-log.json"  # read it even when Accepted
xcrun stapler staple "$APP" && xcrun stapler validate "$APP"

# Build, sign, notarize and staple the DMG
rm -rf "$OUT/dmg" && mkdir -p "$OUT/dmg"
ditto "$APP" "$OUT/dmg/IQCoach.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname "IQ Coach" -srcfolder "$OUT/dmg" -format UDZO -ov "$OUT/IQCoach-$VER.dmg"
hdiutil verify "$OUT/IQCoach-$VER.dmg"
codesign -s "Developer ID Application" --timestamp -i com.allisonbowman.iqcoach.dmg "$OUT/IQCoach-$VER.dmg"
xcrun notarytool submit "$OUT/IQCoach-$VER.dmg" --keychain-profile iqcoach-notary --wait
xcrun stapler staple "$OUT/IQCoach-$VER.dmg" && xcrun stapler validate "$OUT/IQCoach-$VER.dmg"
spctl -a -vvv -t exec "$APP"
```

**Packaging rules (verified):**
- The notary service accepts UDIF disk images, signed flat packages and ZIP archives, and tickets the items nested inside them.
- `stapler` works on DMGs, code-signed bundles and signed flat packages. It cannot staple a ZIP or a standalone binary.
- With nested containers, sign from the inside out and notarize only the outermost container.
- Without a stapled ticket, Gatekeeper looks the ticket up online, so an offline user may be blocked.
- Notarizing the app first and then the DMG costs two submissions. It means a copied-out app carries its own ticket (inferred, optional).

**Limits (verified):**
- Most submissions finish within 5 minutes and 98 % within 15.
- Apple asks for no more than 75 submissions a day.
- `altool` has been rejected since 2023-11-01.

**unverified:**
- That `spctl` prints `source=Notarized Developer ID`.
- The `spctl --context context:primary-signature` check for DMGs.
- Sparkle's `ditto --sequesterRsrc` variant.

`build/` is already in `.gitignore`.

### A7. Test on a clean Mac (or a new user account), opening a *downloaded* copy
- **Verified:** since macOS 15, users can no longer Control-click past Gatekeeper. A build that is not notarized must be opened through System Settings > Privacy & Security > Open Anyway, and that button stays available for about an hour. **Inferred:** for reviewers, an unnotarized build is as much friction as an unsigned one.
- **Inferred:** your locally built copy opens without a prompt because it has no quarantine attribute. Test a copy downloaded from a web page instead.
- **Inferred, must be tested:**
  - A notarized, hardened app can launch the ad hoc signed venv `python3.12` and its ad hoc `.so` files as a child process. No Apple document says so either way.
  - Photos and Screen Recording permissions will be asked for again, because the designated requirement changes from ad hoc to Developer ID.
  - When the Python child reads `~/Desktop` or `~/Documents`, the permission prompt names IQ Coach.
- **Verified:** Gatekeeper translocates an app opened in place from a DMG or ZIP, on the first launch only. Test the first launch and a later one.

### A8. Updates (optional)
- **Verified:** Apple has no separate approval for update mechanisms outside the store. Every new version must be signed with Developer ID, use the hardened runtime and a timestamp, be notarized, and ideally be stapled.
- **Verified:** macOS 13+ lets an updater signed by the same team modify the app bundle, so an embedded Sparkle needs no `NSUpdateSecurityPolicy` entry.
- **Sparkle 2.10.0** is the latest release, dated 13 Sep; the year (2026) is inferred.
- Setup:
  - Add it with SPM: `packages: Sparkle: {url: https://github.com/sparkle-project/Sparkle, from: 2.10.0}` plus `- package: Sparkle`.
  - Add `SUFeedURL` (HTTPS) and `SUPublicEDKey` to Info.plist.
  - Run `generate_keys` once.
  - Run `generate_appcast` for each release.
  - Increase `CFBundleVersion` every release.
- A non-sandboxed app may remove Sparkle's XPC services.
- An ad hoc Debug build may fail library validation when loading Sparkle.framework. Sign Debug with Apple Development.
- **unverified:** whether Sparkle quarantines the archives it downloads.

### A9. The first-run experience for users who are not you
- **Inferred:** every other user gets a `pythonMissing` error. The defaults point at `~/Developer/iq-analyzer/.venv/bin/python` (AppModel.swift:37).
- Replace the Settings text fields with "Choose…" pickers and leave the defaults empty.
- Show a setup sheet that links to the README install steps.
- Auto-detect `<repo>/.venv/bin/python` once the repo folder is chosen.
- Bundle a sample `results.json` and a few photos with an **Open Sample** item, so the app shows something before Python is set up.

---

## 3. Track B: Mac App Store (a later, separate project)

### B1. The engine decision (this blocks everything else in Track B)

| Option | What it takes | Cost and risk |
|---|---|---|
| **B-1. Bundle Python** | Embed a relocatable CPython. Use **Python-Apple-support**: the official binary made relocatable, with Tkinter, IDLE and turtle removed and the App Store compliance patch applied. Add the runtime wheels and `iqa/`. | 275 Mach-O files (199 MB) to re-sign and about 416 MB in the venv (cv2 119 MB, scipy 98 MB). All are ad hoc signed with no Team ID (verified locally). Needs CPython **3.13+** built with `--with-app-store-compliance`; the venv is 3.12. Bundling OpenSSL (`_ssl`, `_hashlib`) affects the export-compliance answer. Updates follow numpy, opencv and rawpy releases. |
| **B-2. Port the engine to Swift** | Core Image `CIRAWFilter` for RAW, ImageIO for HEIC, EXIF and ICC, Accelerate `vDSP.DiscreteFourierTransform` for FFTs, Vision (already in use). | No runtime to bundle, and sandboxing is easy. The real cost is passing the 102 ground-truth tests again. **Inferred:** `CIRAWFilter` returns demosaiced data rather than LibRaw-level sensor data, so the linear SFR path needs care. |
| **B-3. Stay off the store** | Track A only. | No store listing, no TestFlight, and you host updates yourself. |

**Swift-port effort by module.** Line counts are verified with `wc -l iqa/*.py`. The day estimates are **inferred** and include tests.

| Module | Lines | Port needed? | Estimate |
|---|---|---|---|
| `imageio.py`: RAW, HEIC, EXIF, ICC to sRGB | 251 | yes | 2–4 days (matching rawpy's linear output is the hard part) |
| `sfr.py`: ISO 12233 e-SFR | 358 | yes | 3–4 days |
| `edges.py`: Canny + probabilistic Hough | 227 | yes | 3–5 days (OpenCV has no Swift equivalent; write it yourself or use vImage/Vision contours) |
| `noise.py`: flat patches, spectral periodic-texture detector, DR | 360 | yes | 3–4 days |
| `color.py`: ColorChecker dE00, white balance | 354 | yes (chart mode) | 2–3 days |
| `chart_sfr.py`: e-SFR field map | 226 | yes (chart mode) | 2 days |
| `structure.py`: focus map, thirds, tilt | 184 | yes | 1–2 days |
| `exposure.py` | 65 | yes | 0.5 day |
| `uncertainty.py`: bootstrap CI | 36 | yes | 0.5 day |
| `analyze.py`: orchestration | 49 | yes | 0.5 day |
| `synth.py`: synthetic ground truth | 186 | for the tests | 1–2 days |
| `report.py`: CSV, JSON, charts, Markdown | 337 | partly (the app already renders) | 1 day |
| `cli.py`, `select_captures.py`, `__init__`, `__main__` | 371 | no | — |
| **Total** | **3,004** | | **about 4–6 weeks**, plus revalidating against the Python results on the 389-image library |

The Python engine stays the reference implementation either way. A Swift port would be a second implementation checked against it.

**If you choose B-1, the signing rules are (verified):**
- Put dylibs and frameworks in `Contents/Frameworks`, the interpreter in `Contents/MacOS`, and `.py` files and the stdlib in `Contents/Resources`. Scripts have nowhere to hold a signature, so they are resources.
- Precompile `.pyc` files before signing. At runtime set `PYTHONDONTWRITEBYTECODE=1` or `PYTHONPYCACHEPREFIX`, and set `MPLCONFIGDIR` outside the bundle. Any write into the bundle breaks the signature seal.
- Sign each Mach-O from the inside out, **without `--deep`**. Use `--deep` only to verify.
- Sign the interpreter with **only** `com.apple.security.app-sandbox` and `com.apple.security.inherit`. Any other sandbox entitlement makes the system abort the child.
- Re-sign every `.so` with your own Team ID. Library validation then passes without `disable-library-validation`.
- Remove `com.apple.quarantine` from every file. App Store Connect has required this since 2025-02-18.
- PyInstaller signs the whole app with `--deep`, which conflicts with Apple's advice once the app and the interpreter need different entitlements.
- **Inferred:** delete numpy's two `.a` archives, the `tests/` trees, `_tkinter`, `idlelib` and `ensurepip`.
- **unverified:** the DTS advice against shipping `.a` files (forum thread 765679 could not be fetched).

### B2. Sandbox entitlements (once the engine is inside the bundle)
- `com.apple.security.app-sandbox`
- `com.apple.security.files.user-selected.read-only`: `fileImporter` in RootView.swift:48 and :57 already calls `startAccessingSecurityScopedResource` (AppModel.swift:51). Use read-write only if the Markdown export saves files.
- `com.apple.security.files.bookmarks.app-scope`: keep folder access across launches with `.withSecurityScope` and `.securityScopeAllowOnlyReadAccess`.
- `com.apple.security.personal-information.photos-library`: only if the PhotoKit "newest N" path stays. DTS confirmed this works in a sandboxed app (thread 762839).
- No `network.client`: there is no URLSession. **Inferred:** test that iCloud originals still download under the sandbox (`isNetworkAccessAllowed`).
- **Inferred:** absolute paths in a `results.json` written elsewhere will not open, so ask the user to grant the folder. Application Support moves into `~/Library/Containers/com.allisonbowman.iqcoach`.
- Compile `--snapshot`, `--window-shots` (`/tmp`, `screencapture`) and the hidden `--analyze-photos` out of Release, or turn them into documented menu items. Guidelines 2.3.1(a) and 2.5 forbid hidden features; **unverified:** that the clause is numbered 2.5.19.

### B3. Signing for the store
- **Verified:** the app needs an **Apple Distribution** certificate (DTS says it replaced Mac App Distribution; the portal page still lists both), a **Mac Installer Distribution** certificate for the `.pkg`, and a **Mac App Store Connect** provisioning profile.
- The team gets one certificate of each distribution type.
- Xcode 13+ cloud-signs the app when no local certificate exists. **unverified:** whether cloud signing covers the installer `.pkg`, so create a local Mac Installer Distribution identity **[YOU]**.
- The hardened runtime is optional for store apps (Apple calls it best practice). Notarization is not needed.

### B4. Privacy manifest: `Sources/PrivacyInfo.xcprivacy`
- **Verified:** declaring required-reason APIs is mandatory only on iOS, iPadOS, tvOS, visionOS and watchOS. Declaring collected data applies on all platforms. The keys are available on macOS 14+.
- A minimal manifest costs nothing:
  - `NSPrivacyTracking` false;
  - `NSPrivacyTrackingDomains` and `NSPrivacyCollectedDataTypes` empty;
  - `NSPrivacyAccessedAPITypes` with `NSPrivacyAccessedAPICategoryUserDefaults` and reason `CA92.1`. That reason is verified on Apple's page; it covers `UserDefaults` and `@AppStorage`.
- **Inferred:** a macOS-only app is not rejected without one.
- Make sure XcodeGen copies it as a resource.

### B5. Icon and screenshots
- **Icon (verified):**
  - The layout is a square 1024×1024 canvas. Supply unmasked layers.
  - There are six appearances: default, dark, clear light, clear dark, tinted light and tinted dark.
  - Allowed color spaces: sRGB, Gray Gamma 2.2 or Display P3.
  - Either an Icon Composer `.icon` file (Xcode generates icons for macOS 15 at build time) or an asset catalog, which on macOS needs "an asset for each size".
  - **Inferred:** the asset catalog slots are 16 to 512 pt at 1x and 2x (16 to 1024 px). Set `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`.
  - A forum report (unconfirmed by Apple) shows an upload with no icon failing with error 90236.
- **Screenshots (verified):**
  - Sizes: 1280×800, 1440×900, 2560×1600 or 2880×1800 (16:10). At least 1 and up to 10.
  - Formats: JPEG or PNG with **no alpha channel**.
  - They must show the app in use (2.3.3) and suit a 4+ rating (2.3.8). You need the rights to everything shown, and should use fictional data rather than a real person's (2.3.9).
  - **Inferred:** pad or resize `--window-shots` output to 2880×1800 and flatten it, for example `sips -s format jpeg`. Use your own photos, with no identifiable people unless they agreed.

### B6. App Store Connect **[YOU]**
1. **New App** (Account Holder, Admin or App Manager).
   - Platform: macOS.
   - Name: 2–30 characters. **unverified:** whether "IQ Coach" is still free.
   - Bundle ID `com.allisonbowman.iqcoach`. It cannot change after the first upload.
   - SKU: cannot change later.
   - It is a separate record from your iOS app, unless you want universal purchase.
2. **Category:** Photo & Video. It must match `LSApplicationCategoryType` (`public.app-category.photography`). **Inferred:** those two are the same category.
3. **Copyright:** "2026 Allison Bowman" (separate from `NSHumanReadableCopyright`).
   **Description:** up to 4000 characters. **Keywords:** up to 100 bytes.
   **Support URL:** must lead to real contact details (1.5).
   **Privacy Policy URL:** required for macOS.
4. **App Privacy:** Get Started > "No, we do not collect data from this app" > Save. Then click Publish if it becomes active; Apple's page is ambiguous about this. Processing only on the device is not "collection" (verified).
5. **Age rating:** answer the questionnaire. **Inferred:** all None/No gives 4+. Unrated apps can't be published.
6. **Pricing:** Free. No Paid Apps Agreement is needed (verified). Confirm the per-app **DSA trader status** before choosing EU storefronts; it is set at account level and can be overridden per app.
7. **Export compliance:** add `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO`. No URLSession or crypto imports were found. If B-1 bundles OpenSSL, answer honestly or leave `_ssl` out.
8. **Upload:** Archive > Validate > Distribute App > TestFlight & App Store.
   - Test through **TestFlight for Mac**: up to 100 internal testers with no review; external testers need a review of the first build; builds expire after 90 days.
   - **Inferred** from guidelines 2.2 and 2.4.5(i) plus forum ITMS-90296 reports: TestFlight also requires the sandbox. No Apple page says so in one sentence.
9. **Review Notes:** describe every feature, and say that analysis runs entirely inside the app.

### B7. Guidelines to satisfy (verified text; how they apply is inferred)

| Guideline | What it requires | IQ Coach today |
|---|---|---|
| 2.4.5(i) | Sandboxed | Off: blocker |
| 2.4.5(ii), 2.5.2 | Self-contained; no running code that changes functionality | External venv and repo: blocker |
| 4.2.3(i) | Works without installing another app | Needs Python and a repo checkout: blocker |
| 2.4.5(iv) | No downloading or installing additional code | Never `pip install` at runtime |
| 2.4.5(iii) | No processes that keep running after quit | Make sure the Python child is terminated on quit |
| 2.4.5(vii) | Updates only through the Mac App Store | No Sparkle in the store build |
| 2.4.5(viii), 2.5.1 | Runs on the current shipping OS; public APIs only | Test on macOS 15 and the shipping release. **unverified:** that 27 is current |
| 2.1(a) | Reviewer can use the app; no obvious technical problems | Today the reviewer hits "No Python interpreter" |
| 4.2 | Adequate utility | A viewer that only opens `results.json` is at risk |
| 5.1.1(i) | Privacy policy link in App Store Connect **and in the app** | Add Help > Privacy Policy |
| 5.1.1(ii) | Clear purpose strings | The current string is adequate. Consider: "IQ Coach reads the photos you ask it to measure and copies them into its own folder on this Mac. It never changes your library and nothing leaves your Mac." |
| 5.1.1(iii), (iv) | Prefer the out-of-process picker over full access; offer an alternative when the user declines | Keep PhotosPicker as the default. Full-library access should be optional and started by the user |

---

## 4. This week (cheap, and useful to both tracks)

1. **Hardened runtime and Developer ID signing for Release** (A3–A5). Run `package-mac.sh` once and get a stapled DMG.
2. **App icon:** an Icon Composer `.icon` or `Assets.xcassets/AppIcon.appiconset`, plus `ASSETCATALOG_COMPILER_APPICON_NAME`. A notarized app with the generic icon looks unfinished to a camera-team reviewer.
3. **Versioning:**
   - Set `MARKETING_VERSION "1.0"` for the first public build.
   - Increase `CURRENT_PROJECT_VERSION` on every archive, for example from `git rev-list --count HEAD` in the script.
   - Consider `PRODUCT_NAME: "IQ Coach"` with `PRODUCT_MODULE_NAME: IQCoach`. Then update `TEST_HOST`, the README and the scripts.
4. **Copyright:** change `"MIT licence"` to `"Copyright © 2026 Allison Bowman. MIT License."` and ship `LICENSE` as a resource or show it in an Acknowledgements window.
5. **Privacy manifest:** add the minimal `PrivacyInfo.xcprivacy` (B4).
6. **Usage string:** reword `NSPhotoLibraryUsageDescription` to mention that analysis happens on this Mac. If PhotoKit "newest N" is dropped and only PhotosPicker stays, remove the key, `PhotosImporter.exportNewest`/`authorize` and the entitlement. **Inferred:** PhotosPicker on macOS needs no permission; Apple's statement is in an iOS article.
7. **Application Support cleanup:**
   - Each run writes `~/Library/Application Support/IQCoach/runs/<stamp>/`, and each pick copies up to 20 full-resolution originals into `photos/<stamp>/`. Nothing ever deletes them.
   - Add a **Storage** section in Settings that shows the sizes, with "Delete imported photo copies" and "Delete old runs" buttons.
   - Delete `photos/<stamp>` once its `results.json` is written, or move the copies to `cachesDirectory`.
   - Say where the copies live in the README and the privacy page.
8. **Debug-only hooks:** wrap `--snapshot`, `--window-shots`, `SnapshotRunner.swift` and `WindowShots.swift` in `#if DEBUG`. Make `--open` a real document type (`CFBundleDocumentTypes` for `public.json`), and make `--analyze-photos` a visible menu command.
9. **Help menu:** use `CommandGroup(after: .help)` or add items next to Glossary: IQ Coach Help, Support and Privacy Policy. Publish a one-page privacy policy (for example on GitHub Pages): no data collected, analysis on device, where the copies are stored.
10. **README:** add a Release section (package script, prerequisites, how to install the venv).

---

## 5. Open questions for you

1. Is a **Developer ID Application** certificate already in your keychain, and are you the **Account Holder** of the team that ships your iOS app? What is the Team ID, and does that team use the `com.allisonbowman` prefix?
2. For notarization, do you prefer an **app-specific password** or an **App Store Connect Team API key**?
3. Who is the audience for the download: hiring reviewers only, or the public? That decides whether the external-venv prerequisite is acceptable, or whether even the Developer ID build should bundle Python (python-build-standalone 3.12, 25 MB compressed, already rpath-based; least work outside the store).
4. Do you want a **Mac App Store listing** at all? If yes, is it worth a 4–6 week Swift port (B-2), or a bundled-Python build (B-1, with a move to CPython 3.13+)?
5. Keep the PhotoKit **"newest N photos"** path, or only PhotosPicker? Dropping PhotoKit removes the entitlement, the usage string and the 5.1.1(iii) risk.
6. Ship **universal** (arm64 + x86_64) or **arm64 only**? The current Debug build is arm64 only, and all venv wheels are arm64 only (verified).
7. Rename the bundle to **"IQ Coach.app"** (PRODUCT_NAME), or keep `IQCoach.app`?
8. Where will you host the DMG, the privacy policy and the support page: GitHub Releases plus Pages, or your own site? Do you want Sparkle auto-updates?
9. Is your account's **DSA trader status** set? This applies only to EU storefronts in Track B.

---

## 6. Sources (all read 2026-10-23 by this Mac's clock; the brief's date is 2026-10-15)

**Apple: distribution, signing and notarization**
- https://developer.apple.com/macos/distribution/ (Features and Requirements table)
- https://developer.apple.com/developer-id/
- https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
- https://developer.apple.com/documentation/security/resolving-common-notarization-issues
- https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac
- https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution
- https://developer.apple.com/documentation/security/customizing-the-xcode-archive-process
- https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases (renders no readable text)
- https://developer.apple.com/help/account/certificates/create-developer-id-certificates
- https://developer.apple.com/help/account/certificates/certificates-overview
- https://developer.apple.com/help/account/reference/certificate-types
- https://developer.apple.com/help/account/certificates/cloud-managed-certificates
- https://developer.apple.com/help/account/identifiers/register-an-app-id
- https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile
- https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api
- https://support.apple.com/en-us/102654 (app-specific passwords)
- https://developer.apple.com/news/upcoming-requirements/ (quarantine rule 2025-02-18; SDK rule 2026-04-28; DSA; age-rating deadline)
- https://developer.apple.com/news/?id=saqachfa (Sequoia Gatekeeper change, 2024-08-06)

**Apple: hardened runtime, sandbox and entitlements**
- https://developer.apple.com/documentation/security/hardened-runtime
- https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime
- https://developer.apple.com/documentation/security/app-sandbox
- https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox
- https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox
- https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox
- https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app
- https://developer.apple.com/documentation/xcode/embedding-nonstandard-code-structures-in-a-bundle
- https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle
- https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html (archived)
- Entitlement pages:
  - https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.personal-information.photos-library
  - https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.files.user-selected.read-only
  - https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.assets.pictures.read-only
  - https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation
  - https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-jit
  - https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-unsigned-executable-memory
- https://developer.apple.com/documentation/bundleresources/information-property-list/nsupdatesecuritypolicy
- https://developer.apple.com/documentation/foundation/nsurl/bookmarkcreationoptions/securityscopeallowonlyreadaccess

**Apple: privacy, Info.plist and Photos**
- https://developer.apple.com/documentation/bundleresources/privacy-manifest-files
- https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
- https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype
- https://developer.apple.com/documentation/bundleresources/information-property-list/nsphotolibraryusagedescription
- https://developer.apple.com/documentation/bundleresources/information-property-list/nsappdatausagedescription
- https://developer.apple.com/documentation/bundleresources/information-property-list/nsdesktopfolderusagedescription
- https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption
- https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations
- https://developer.apple.com/documentation/photokit/delivering-an-enhanced-privacy-experience-in-your-photos-app
- https://developer.apple.com/documentation/photosui/photospicker
- https://developer.apple.com/app-store/app-privacy-details/
- https://developer.apple.com/support/third-party-SDK-requirements/

**Apple: App Store, App Store Connect, TestFlight and design**
- https://developer.apple.com/app-store/review/guidelines/ (1.5, 2.1, 2.2, 2.3.x, 2.4.5, 2.5.1, 2.5.2, 4.2, 4.2.3, 5.1.1; the page shows no last-updated date)
- https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview
- https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/
- https://developer.apple.com/help/app-store-connect/reference/app-uploads/app-sandbox-information
- https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app
- https://developer.apple.com/help/app-store-connect/reference/app-information/app-information
- https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information
- https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions
- https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications
- https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy
- https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance
- https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements
- https://developer.apple.com/help/app-store-connect/manage-app-pricing/set-a-price
- https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements
- https://developer.apple.com/app-store/categories/
- https://help.apple.com/xcode/mac/current/en.lproj/devcabdebc27.html (setting the app category on macOS)
- https://developer.apple.com/design/human-interface-guidelines/app-icons (change log 2026-06-08)
- https://developer.apple.com/documentation/xcode/configuring-your-app-icon
- https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer
- https://developer.apple.com/support/volume-purchase-and-custom-apps/
- https://developer.apple.com/programs/enterprise/
- https://developer.apple.com/programs/ and https://developer.apple.com/programs/whats-included/
- https://developer.apple.com/videos/play/wwdc2021/10170/ (Meet TestFlight on Mac)
- https://developer.apple.com/wwdc21/10204 (Xcode creates the app record during upload; read through a search summary)

**Apple: Gatekeeper and user-facing pages**
- https://support.apple.com/en-us/102445 (Safely open apps on your Mac, published 2026-05-27)
- https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/15.0/mac/15.0 (also the /26.0/ and /27.0/ versions)
- https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web

**Apple Developer Forums** (developer reports and DTS replies, not policy)
- https://developer.apple.com/forums/thread/733942 (DTS: provisioning profiles, sandbox for App Store executables)
- https://developer.apple.com/forums/thread/768361 (ITMS-90296; DTS on the hardened runtime)
- https://developer.apple.com/forums/thread/766796 (a non-sandboxed TestFlight build; anecdote)
- https://developer.apple.com/forums/thread/706390 (DTS: sandbox inheritance)
- https://developer.apple.com/forums/thread/762839 (DTS: photos-library entitlement in a sandboxed app)
- https://developer.apple.com/forums/thread/812624 (DTS, Jan 2026: Apple Distribution replaces Mac App Distribution)
- https://developer.apple.com/forums/thread/129980 (DTS: "--deep Considered Harmful", revised 2024-05-06)
- https://developer.apple.com/forums/thread/814674 (DTS: `--deep` verification limits)
- https://developer.apple.com/forums/thread/774181 and https://developer.apple.com/forums/thread/749286 (missing entitlement means silent denial)
- https://developer.apple.com/forums/thread/735420 (error 90236)
- https://developer.apple.com/forums/thread/735286 (CA92.1)
- https://developer.apple.com/forums/thread/133063 (API key role; community report)
- https://developer.apple.com/forums/thread/120647 (child processes and hardened runtime; not from Apple staff)
- https://developer.apple.com/forums/thread/765679 (**could not be fetched**; its claims are unverified)

**Python and third-party tools**
- https://docs.python.org/3/using/mac.html (3.15.1 docs)
- https://docs.python.org/3/using/configure.html (`--with-app-store-compliance`, added in 3.13)
- https://github.com/python/cpython/blob/main/Mac/Resources/app-store-compliance.patch
- https://lwn.net/Articles/979671/ (2024 itms-services rejection)
- https://github.com/beeware/Python-Apple-support (README)
- https://briefcase.beeware.org/en/stable/reference/platforms/macOS/
- https://github.com/astral-sh/python-build-standalone/releases/tag/20261021 and `cpython-unix/build-cpython.sh`
- https://gregoryszorc.com/docs/python-build-standalone/main/quirks.html
- https://pyinstaller.org/en/stable/feature-notes.html and https://pyinstaller.org/en/stable/CHANGES.html
- https://sparkle-project.org/documentation/ and its `/publishing/`, `/sandboxing/`, `/programmatic-setup/` and `/security-and-reliability/` pages
- https://github.com/sparkle-project/Sparkle/releases
- https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md
- https://apps.apple.com/app/id1455811935 (a comparable Mac-only Photo & Video listing)

**Checked locally on this Mac (2026-10-23, read only)**
- `mac/IQCoach/project.yml`
- `Sources/App/{AppModel,IQCoachApp,main,SnapshotRunner,WindowShots}.swift`
- `Sources/Support/{AnalyzerRunner,PhotosImporter}.swift`
- `Sources/Views/{SettingsView,RootView}.swift`
- `codesign`, `plutil` and `lipo` on `build/Build/Products/Debug/IQCoach.app`
- A Mach-O, signature and size audit of `.venv/lib/python3.12/site-packages`
- `wc -l iqa/*.py`
- `xcrun notarytool --help` (1.1.3), `xcodebuild -help` (Xcode 27.1, 27A9275), `xcrun stapler` usage text, `hdiutil create -help`