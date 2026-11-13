#!/usr/bin/env bash
# Builds, signs and packages the cmd-rest native binary as a signed macOS installer (.pkg).
#
# It does not talk to Apple's notary service; run scripts/macos-notarize.sh on the result for that.
# What it does:
#   1. checks the tools and that both signing certificates are in your keychain
#   2. builds the GraalVM native binary (./mvnw -Pnative clean package -DskipTests), unless
#      --binary or --skip-build is given
#   3. signs the binary with your "Developer ID Application" certificate, with the hardened runtime
#      and a secure timestamp (both are required by the notary service)
#   4. wraps it in an installer that puts it at /usr/local/bin/cmd-rest and signs the installer with
#      your "Developer ID Installer" certificate
#
# Usage:
#   scripts/macos-build-pkg.sh [options]
#
#   --binary PATH   package this already built binary instead of building one (for example the
#                   Intel binary built by the release workflow; see apple-notarize-steps.md, 7)
#   --skip-build    package target/cmd-rest as it is, without building it again
#   --version X.Y.Z version for the installer and its file name (default: from pom.xml, without
#                   -SNAPSHOT)
#   --out DIR       output folder (default: target/macos)
#   -h, --help      show this text
#
# Environment (required):
#   APPLE_SIGNING_IDENTITY    "Developer ID Application: Your Name (TEAMID)"
#   APPLE_INSTALLER_IDENTITY  "Developer ID Installer: Your Name (TEAMID)"
# Environment (optional):
#   MACOSX_DEPLOYMENT_TARGET  oldest macOS the native build should support (default: 12.0)
#
# Output: <out>/cmd-rest-<version>-macos-<aarch64|x86_64|universal>.pkg (the path is printed last)

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pkg_identifier="io.github.snytkine.cmdrest"
install_dir="/usr/local/bin"

binary=""
skip_build=false
version=""
out_dir="$repo_root/target/macos"

# Prints the lines of the header comment as the help text.
usage() {
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Prints a step heading.
step() { printf '\n==> %s\n' "$*"; }

# Prints an error message and stops the script.
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Parses the command line into binary, skip_build, version and out_dir.
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --binary) [[ $# -ge 2 ]] || die "--binary needs a path"; binary="$2"; shift ;;
      --skip-build) skip_build=true ;;
      --version) [[ $# -ge 2 ]] || die "--version needs a value"; version="$2"; shift ;;
      --out) [[ $# -ge 2 ]] || die "--out needs a folder"; out_dir="$2"; shift ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
  done
}

# Reads the project version from pom.xml (the first <version> after the </parent> block) and drops
# a -SNAPSHOT suffix. Prints it.
pom_version() {
  awk '/<\/parent>/ { seen = 1 } seen && /<version>/ { gsub(/.*<version>|<\/version>.*/, ""); print; exit }' \
    "$repo_root/pom.xml" | sed 's/-SNAPSHOT$//'
}

# Checks the tools, the version and that the two signing identities exist in the keychain.
preflight() {
  step "Checking the tools and certificates"
  local tool
  for tool in codesign pkgbuild productbuild pkgutil lipo xcrun security; do
    command -v "$tool" >/dev/null || die "'$tool' is not installed (install the Xcode Command Line Tools: xcode-select --install)"
  done

  [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]] || die "$(
    cat <<'MSG'
APPLE_SIGNING_IDENTITY is not set. Set it to your Developer ID Application certificate:

    security find-identity -v -p codesigning
    export APPLE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
MSG
  )"
  [[ -n "${APPLE_INSTALLER_IDENTITY:-}" ]] || die "$(
    cat <<'MSG'
APPLE_INSTALLER_IDENTITY is not set. Set it to your Developer ID Installer certificate
(not "3rd Party Mac Developer Installer", which is for the Mac App Store only):

    security find-identity -v | grep "Developer ID Installer"
    export APPLE_INSTALLER_IDENTITY="Developer ID Installer: Your Name (TEAMID)"

If the list shows no Developer ID Installer line, create the certificate first:
apple-notarize-steps.md, section 3.
MSG
  )"
  # The installer certificate does not show under `-p codesigning`, so list all identities.
  security find-identity -v | grep -qF "\"$APPLE_SIGNING_IDENTITY\"" \
    || die "'$APPLE_SIGNING_IDENTITY' is not in your keychain (see: security find-identity -v)"
  security find-identity -v | grep -qF "\"$APPLE_INSTALLER_IDENTITY\"" \
    || die "'$APPLE_INSTALLER_IDENTITY' is not in your keychain (see: security find-identity -v)"

  [[ -n "$version" ]] || version="$(pom_version)"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version '$version' is not like 1.2.3; pass --version"
  echo "version: $version"
}

# Builds the native binary with the native Maven profile, or checks that the given one exists.
# Sets the global binary to the file to package.
obtain_binary() {
  if [[ -z "$binary" ]]; then
    if [[ "$skip_build" == false ]]; then
      step "Building the native binary (this takes several minutes)"
      export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
      (cd "$repo_root" && ./mvnw -Pnative clean package -DskipTests -B)
    fi
    binary="$repo_root/target/cmd-rest"
  fi
  [[ -f "$binary" ]] || die "no binary at $binary"
  file "$binary" | grep -q 'Mach-O' || die "$binary is not a macOS (Mach-O) binary"
}

# Prints the architecture label used in the file name: aarch64, x86_64 or universal.
arch_label() {
  local archs
  archs="$(lipo -archs "$1")"
  case "$archs" in
    arm64) echo aarch64 ;;
    x86_64) echo x86_64 ;;
    *x86_64*arm64* | *arm64*x86_64*) echo universal ;;
    *) die "unexpected processor types in $1: $archs" ;;
  esac
}

# Copies the binary into a staging folder laid out like the target disk, signs it and checks it.
# Sets the global stage_root.
sign_binary() {
  step "Signing the binary (hardened runtime, secure timestamp)"
  stage_root="$work_dir/root"
  mkdir -p "$stage_root$install_dir"
  cp "$binary" "$stage_root$install_dir/cmd-rest"
  chmod 755 "$stage_root$install_dir/cmd-rest"
  # Extended attributes (quarantine flag, Finder info) would be packed as stray "._cmd-rest" files.
  xattr -cr "$stage_root"

  codesign --force --options runtime --timestamp \
    --identifier "$pkg_identifier" \
    --sign "$APPLE_SIGNING_IDENTITY" "$stage_root$install_dir/cmd-rest"
  codesign --verify --strict --verbose=2 "$stage_root$install_dir/cmd-rest"
  codesign -dv --verbose=4 "$stage_root$install_dir/cmd-rest" 2>&1 | grep -E 'Authority=Developer ID Application|flags=.*runtime' \
    || die "the signature is missing the Developer ID authority or the hardened runtime flag"

  local minos
  minos="$(otool -l "$stage_root$install_dir/cmd-rest" | awk '/LC_BUILD_VERSION/ { f = 1 } f && /minos/ { print $2; exit }')"
  echo "oldest supported macOS (minos): ${minos:-unknown}"
}

# Builds the component package from the staging folder and signs the final installer.
build_installer() {
  step "Building and signing the installer"
  local arch component
  arch="$(arch_label "$binary")"
  component="$work_dir/cmd-rest-component.pkg"
  pkg_path="$out_dir/cmd-rest-$version-macos-$arch.pkg"

  mkdir -p "$out_dir"
  rm -f "$pkg_path"
  pkgbuild --root "$stage_root" \
    --identifier "$pkg_identifier.pkg" \
    --version "$version" \
    --install-location / \
    --ownership recommended \
    "$component"
  productbuild --package "$component" --sign "$APPLE_INSTALLER_IDENTITY" "$pkg_path"
  pkgutil --check-signature "$pkg_path"
}

# Runs the steps in order, then removes the scratch folder.
main() {
  parse_args "$@"
  preflight
  obtain_binary
  work_dir="$(mktemp -d)"
  trap 'rm -rf "$work_dir"' EXIT
  sign_binary
  build_installer
  step "Done"
  echo "$pkg_path"
}

main "$@"
