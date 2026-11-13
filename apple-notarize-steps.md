# Notarizing cmd-rest for macOS (signed installer, scanned by Apple)

Step-by-step guide to ship the `cmd-rest` native binary to Mac users **signed, scanned by Apple (notarized) and stapled**, so Gatekeeper opens it without the "developer cannot be verified" warning. It follows the process already working for the `netlet-app` project (`../netlet-app/apple-appstore-setup.md`, Part B) and reuses the same Apple Developer account, the same Developer ID Application certificate and the same notarization credentials. Items marked **(you)** need your Apple account and cannot be done from the repository. Items marked **(repo)** are files in this repository.

## 1. What is different from netlet-app

| | netlet-app | cmd-rest |
| --- | --- | --- |
| What is shipped | A Tauri `.app` inside a `.dmg` | A single command-line binary (GraalVM native image) |
| Who signs and notarizes | Tauri does it from `APPLE_*` variables, a script handles the `.dmg` | Our scripts do it (there is no Tauri) |
| Download format | `.dmg` | `.pkg` installer that puts the binary at `/usr/local/bin/cmd-rest` |
| Certificates | Developer ID Application | Developer ID Application **and Developer ID Installer** (new) |
| Sandbox, provisioning profile, App Store record | Not needed (direct download) | Not needed |

**Why a `.pkg`.** Apple can scan a bare binary (inside a zip), but a bare binary or a zip **cannot be stapled**: the approval ticket cannot be attached, so Gatekeeper has to look it up online on first run. A `.pkg` (or `.dmg`) can be stapled and works offline. A `.pkg` also installs the command straight onto the user's `PATH`, which a `.dmg` would not. That is the "installer" this guide produces.

**Why no entitlements file.** A GraalVM native image is ahead-of-time compiled: no JIT, no runtime code generation, no loading of unsigned libraries. It runs fine under the hardened runtime (required by Apple) with no entitlements. This was checked by signing the existing `target/cmd-rest` with `--options runtime` and starting the interactive shell in a terminal (`help` and `exit` work).

## 2. What you already have, and what is missing

From `security find-identity -v` on this Mac:

| Item | Status |
| --- | --- |
| Apple Developer Program membership, Team ID | Have (used for netlet-app) |
| **Developer ID Application** certificate (signs the binary) | Have |
| App-specific password or App Store Connect API key (notary login) | Have, if you still know it; otherwise create a new one (section 4) |
| **Developer ID Installer** certificate (signs the `.pkg`) | **Missing: create it (section 3)** |
| `3rd Party Mac Developer Installer` | Have, but it is for the Mac App Store only. Apple's notary service rejects installers signed with it. Do not use it. |

## 3. One-time: create the Developer ID Installer certificate (you)

Only the **Account Holder** can create Developer ID certificates.

1. Open Keychain Access > menu Keychain Access > Certificate Assistant > **Request a Certificate from a Certificate Authority**. Select the **login** keychain first, enter your email, a common name (for example `cmd-rest installer`), choose **Saved to disk**, and save the `.certSigningRequest` file. Do **not** reuse the request file made for another certificate (such as netlet-app's): the portal refuses it with "The uploaded CSR file has already been used to generate another certificate".
2. Go to <https://developer.apple.com/account> > Certificates, Identifiers & Profiles > Certificates > **+**.
3. Under **Software**, choose **Developer ID Installer** (not "Developer ID Application", and not "Mac Installer Distribution") and continue. Upload the request file.
4. Download the `.cer` file and double-click it to install it in your **login** keychain. It must appear in Keychain Access with a private key under it (the key comes from the request made in step 1 on this same Mac; a certificate made from a request created on another Mac needs that Mac's key exported as `.p12`).
5. Confirm and copy the exact name:

   ```bash
   security find-identity -v | grep "Developer ID"
   # 1) ... "Developer ID Application: Your Name (TEAMID)"
   # 2) ... "Developer ID Installer: Your Name (TEAMID)"
   ```

   The installer certificate is not shown by `security find-identity -v -p codesigning`; leave the `-p codesigning` out to see it.

## 4. Notarization credentials (you)

The scripts accept the same variables as the netlet-app scripts, so if they are already in your shell profile nothing more is needed. Pick **one** way:

- **Apple ID + app-specific password.** Create the password at <https://account.apple.com> > Sign-In and Security > App-Specific Passwords (it is not your Apple ID password).

  ```bash
  export APPLE_ID="you@example.com"
  export APPLE_PASSWORD="<app-specific password>"
  export APPLE_TEAM_ID="TEAMID"
  ```

- **App Store Connect API key** (best for CI). App Store Connect > Users and Access > Integrations > Team Keys; create a key with the **Developer** role and download the `.p8` once.

  ```bash
  export APPLE_API_KEY="<key id>"
  export APPLE_API_ISSUER="<issuer id>"
  export APPLE_API_KEY_PATH="/path/to/AuthKey_XXXX.p8"
  ```

- **A saved keychain profile** (nothing secret in your shell profile). Run once, then use the profile name:

  ```bash
  xcrun notarytool store-credentials "cmd-rest-notary" --apple-id "you@example.com" --team-id "TEAMID"   # asks for the app-specific password
  export NOTARY_PROFILE="cmd-rest-notary"
  ```

Never put any of these in the repository. `.gitignore` already excludes `*.p8`, `*.p12`, `*.cer` and `*.pkg`.

Also set the two signing names from section 3 (and the Application one you already used for netlet):

```bash
export APPLE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export APPLE_INSTALLER_IDENTITY="Developer ID Installer: Your Name (TEAMID)"
```

## 5. Build, sign, notarize (you, on a Mac)

Prerequisites: Xcode Command Line Tools (`xcode-select --install`) and a GraalVM JDK 25 on `PATH` (see `native-build-support.md`).

Run the scripts in `scripts/` (all **(repo)**):

| Script | What it does |
| --- | --- |
| `scripts/macos-build-pkg.sh` | Builds the native binary (`./mvnw -Pnative clean package -DskipTests`), signs it with the hardened runtime and a secure timestamp, wraps it in an installer for `/usr/local/bin/cmd-rest`, signs the installer. Output: `target/macos/cmd-rest-<version>-macos-<aarch64\|x86_64\|universal>.pkg`. |
| `scripts/macos-notarize.sh` | Uploads each `.pkg` in `target/macos` (or the files you name) to Apple, waits for the verdict, staples the ticket and runs Gatekeeper's check. Prints Apple's log when the answer is not "Accepted". Skips a file that is already stapled. |
| `scripts/release-macos.sh <tag>` | The whole release: checks out the tag, runs both scripts above, writes the `.sha256`, uploads both files to the GitHub Release, downloads them again and verifies checksum and ticket. See section 8. |
| `scripts/lib/apple-notary-auth.sh` | Shared helper: picks the credential flags from the variables in section 4. |

Typical local run:

```bash
scripts/macos-build-pkg.sh        # add --skip-build to reuse target/cmd-rest
scripts/macos-notarize.sh
```

Options of `macos-build-pkg.sh`: `--binary PATH` (package a binary you already have), `--skip-build`, `--version X.Y.Z` (default: the version in `pom.xml` without `-SNAPSHOT`), `--out DIR`. Run any script with `--help` for the full text.

The first notarization of an account sometimes takes longer than a few minutes; the script just waits.

### Minimum macOS version

A native image records the macOS version it was built on as its minimum. The binary currently in `target/` reports `minos 26.0`, which means it would **refuse to start on any Mac older than macOS 26**. The build script sets `MACOSX_DEPLOYMENT_TARGET=12.0` before building and prints the resulting `minos` after signing. If it still prints your own macOS version, the setting had no effect on your GraalVM version: the safest fix is to build the released binaries on an older macOS (the CI runners `macos-latest` and `macos-15-intel` are the ones used for the current downloads), and use `--binary` (section 7) to package them. Check any binary yourself with:

```bash
otool -l target/cmd-rest | grep -A4 LC_BUILD_VERSION
```

## 6. Verify (you)

```bash
PKG=target/macos/cmd-rest-<version>-macos-aarch64.pkg

pkgutil --check-signature "$PKG"           # expect "signed by a developer certificate issued by Apple for distribution" and Developer ID Installer
xcrun stapler validate "$PKG"              # expect "The validate action worked!"
spctl --assess --type install -vv "$PKG"   # expect "accepted" and "source=Notarized Developer ID"

# Look inside without installing:
pkgutil --payload-files "$PKG"

# After installing (sudo installer -pkg "$PKG" -target /), check the installed binary:
codesign --verify --strict --verbose=2 /usr/local/bin/cmd-rest
codesign -dv --verbose=4 /usr/local/bin/cmd-rest 2>&1 | grep -E "Authority|flags|TeamIdentifier"   # flags=0x10000(runtime)
cmd-rest
```

Then test like a real user: copy the `.pkg` to a **different Mac**, or download it through a browser so it carries the quarantine flag, and double-click it. The installer should open with no "unidentified developer" or "damaged" warning. To uninstall: `sudo rm /usr/local/bin/cmd-rest && sudo pkgutil --forget io.github.snytkine.cmdrest.pkg`.

## 7. Apple Silicon and Intel

GraalVM cannot cross-compile, so a native binary is for the processor of the machine that built it. The installer's file name says which it is (`aarch64`, `x86_64`, or `universal`).

- **Apple Silicon:** run the scripts on an Apple Silicon Mac.
- **Intel:** either run the scripts on an Intel Mac, or take the Intel binary built by the release workflow (asset `cmd-rest-macos-intel_x86` on the GitHub Release) and package it on your Mac. Packaging only signs and wraps it, which works for either processor type:

  ```bash
  gh release download v<version> --repo snytkine/cmd-rest --pattern 'cmd-rest-macos-intel_x86' --dir /tmp/intel
  chmod +x /tmp/intel/cmd-rest-macos-intel_x86
  scripts/release-macos.sh --binary /tmp/intel/cmd-rest-macos-intel_x86 v<version>
  ```

  Only do this for a binary your own workflow built from the tag.
- **Universal:** `lipo -create arm64-binary x86_64-binary -output cmd-rest-universal`, then `--binary cmd-rest-universal`. One installer for both, a larger file.

Note: GitHub has announced the end of Intel macOS runners in August 2027 (see the comments in `.github/workflows/release.yml`). After that, the Intel binary has to come from an Intel Mac, or be dropped.

## 8. Releasing (you)

The version, tag and GitHub Release come from release-please as before. The release workflow keeps attaching the plain binaries (including the unsigned macOS ones). The signed installer is **added** to the same release:

1. Merge the release PR; release-please creates the tag `v<version>` and the release; the release workflow attaches the binaries.
2. On your Mac, with the variables from section 4 set, a clean working tree and `gh auth login` done:

   ```bash
   scripts/release-macos.sh v<version>
   ```

   It checks out the tag (and returns to your branch afterwards), builds, signs, notarizes, staples, writes `cmd-rest-<version>-macos-<arch>.pkg.sha256`, uploads both with `gh release upload --clobber`, downloads them from the public page and checks the SHA-256 and the notarization ticket. It never pushes or rewrites history.

Options: `--skip-build` (reuse the installer already built and notarized, for example after a failed upload), `--verify-only` (only the download check), `--binary PATH` (section 7).

After the first notarized release, also update the macOS install instructions (see section 11).

## 9. If notarization fails

`macos-notarize.sh` prints Apple's log automatically. To fetch one later:

```bash
xcrun notarytool history --keychain-profile "cmd-rest-notary"      # or: --apple-id ... --team-id ... --password ...
xcrun notarytool log <submission-id> --keychain-profile "cmd-rest-notary"
```

Typical causes:

| Message in the log | Cause and fix |
| --- | --- |
| "The signature of the binary is invalid" / "not signed with a valid Developer ID certificate" | Signed with the wrong certificate (Apple Distribution, or ad hoc). Check `APPLE_SIGNING_IDENTITY`. |
| "The signature does not include a secure timestamp" | Signed with `--timestamp=none` or offline. The script always uses `--timestamp`; rerun with network access. |
| "The executable does not have the hardened runtime enabled" | Binary not signed with `--options runtime`. Use the script. |
| "The binary uses an SDK older than 10.9" | Unusual for a GraalVM build; rebuild with a current Xcode Command Line Tools. |
| Package signing errors, or "invalid" for the installer | Signed with `3rd Party Mac Developer Installer` instead of `Developer ID Installer`. The scripts refuse it before upload. |
| 401 / "Invalid credentials" / agreement not accepted | Wrong app-specific password or team id, or an updated agreement in your developer account that must be accepted at <https://developer.apple.com/account>. |

Other errors:

- `security find-identity` shows the certificate but with `CSSMERR_TP_NOT_TRUSTED`: install the "Developer ID Certification Authority" intermediate from <https://www.apple.com/certificateauthority/>.
- The build script says an identity is "not in your keychain": copy the name exactly from `security find-identity -v`, including the Team ID in parentheses.
- If `codesign` prompts for keychain access in a loop, choose **Always Allow**, or unlock the keychain first: `security unlock-keychain ~/Library/Keychains/login.keychain-db`.

## 10. Optional: do it in GitHub Actions

Today the workflow only uploads unsigned macOS binaries. To sign and notarize in CI instead of on your Mac, add the following to the macOS matrix entries of `.github/workflows/release.yml` (not done here, because it moves your signing keys into GitHub):

1. Export both certificates with their private keys from Keychain Access as one `.p12` with a password; store it base64-encoded (`base64 -i certs.p12 | pbcopy`) as the secret `MACOS_CERTIFICATES_P12`, with `MACOS_CERTIFICATES_PASSWORD`, plus `APPLE_API_KEY`, `APPLE_API_ISSUER` and the `.p8` contents as secrets.
2. In the job, create a temporary keychain, import the `.p12` into it, write the `.p8` to a temporary file, set `APPLE_SIGNING_IDENTITY`, `APPLE_INSTALLER_IDENTITY`, `APPLE_API_KEY_PATH`, then run `scripts/macos-build-pkg.sh --skip-build` and `scripts/macos-notarize.sh` after the "Build native image" step and upload the `.pkg`.
3. This also fixes the minimum-version question from section 5 and the Intel build, because each runner builds and signs its own processor type.

Use an API key (not an app-specific password) in CI, and delete the temporary keychain at the end of the job.

## 11. Documentation to update after the first notarized release (repo)

`CLAUDE.md` requires user-facing docs to match the shipped behaviour. This guide only adds the tooling; the public docs still describe unsigned binaries. When the first notarized installer is published, update:

- `../cmdrest-web/src/docs/getting-started.md`: today it tells macOS users to run `xattr -d com.apple.quarantine`. Replace that with "download the `.pkg` for your Mac, double-click it, and run `cmd-rest`", keeping the chip-selection advice (Apple Silicon `aarch64`, Intel `x86_64`) and the file names.
- The download page of `cmdrest-web`, if it lists the macOS asset names.
- `README.md` here, if it mentions the macOS download.

## 12. Housekeeping

- The Developer ID certificates are valid for five years. Renew before they expire; already notarized software keeps working.
- Each release needs a fresh sign, notarize, staple cycle: a new version means a new binary.
- Keep `.p12`, `.p8`, `.cer` and `.pkg` files out of git (already in `.gitignore`).
- Signing happens locally with the keychain; nothing in the scripts uploads anything to Apple except the installer being notarized.

## Checklist

- [ ] Apple Developer Program membership active; agreements accepted
- [ ] Developer ID Application certificate installed (already done for netlet-app)
- [ ] **Developer ID Installer** certificate created and installed (section 3)
- [ ] Notarization credentials set: app-specific password, API key, or `NOTARY_PROFILE` (section 4)
- [ ] `APPLE_SIGNING_IDENTITY` and `APPLE_INSTALLER_IDENTITY` exported
- [ ] `scripts/macos-build-pkg.sh` produces a `.pkg`; `minos` is acceptable (section 5)
- [ ] `scripts/macos-notarize.sh` finishes with "accepted" and a stapled ticket
- [ ] `spctl` reports "Notarized Developer ID"; tested on a second Mac with the quarantine flag
- [ ] Intel installer produced (section 7), or Intel dropped from the downloads
- [ ] `scripts/release-macos.sh v<version>` uploaded the installers and the verification passed
- [ ] `cmdrest-web` install instructions updated (section 11)
