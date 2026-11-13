#!/usr/bin/env bash
# Builds, signs, notarizes and publishes the macOS installer for a release tag.
#
# Run it after release-please has created the tag and the GitHub Release. The release workflow
# (.github/workflows/release.yml) attaches the plain binaries; this script adds the notarized
# installer and its checksum to the same release. Steps:
#   1. checks the tools, the Apple credentials and certificates, gh access and a clean working tree
#   2. checks out the tag and runs scripts/macos-build-pkg.sh (build, sign, package)
#   3. runs scripts/macos-notarize.sh (notarize, staple)
#   4. writes the .sha256 file next to the installer
#   5. uploads both to the release (replacing files of the same name)
#   6. downloads the installer from the public release page, compares its SHA-256 and checks that
#      the notarization ticket survived the upload
#
# Usage:
#   scripts/release-macos.sh [options] [tag]
#
#   tag             the release tag, for example v2.1.0 (asked for when left out)
#   --binary PATH   package this binary instead of building one (for example the Intel binary
#                   downloaded from the release); the installer is named after its processor type
#   --skip-build    reuse the installer already built and notarized for the tag
#   --verify-only   only download the published installer(s) and check them (step 6)
#   -h, --help      show this text
#
# Environment:
#   REPO                       GitHub repository of the release (default: snytkine/cmd-rest)
#   APPLE_SIGNING_IDENTITY     "Developer ID Application: Your Name (TEAMID)"
#   APPLE_INSTALLER_IDENTITY   "Developer ID Installer: Your Name (TEAMID)"
#   notarization credentials   see scripts/lib/apple-notary-auth.sh
#
# It never rewrites git history and never pushes. It returns to the branch you started on.

set -euo pipefail

REPO="${REPO:-snytkine/cmd-rest}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/apple-notary-auth.sh
source "$repo_root/scripts/lib/apple-notary-auth.sh"

tag=""
binary=""
skip_build=false
verify_only=false
original_ref="" # branch or commit to return to; set once the tag is checked out
tmp_dir=""      # scratch folder for the verification download

# Runs when the script ends for any reason: returns to the original branch, removes scratch files.
on_exit() {
  local code=$?
  if [[ -n "$original_ref" ]]; then
    (cd "$repo_root" && git checkout --quiet "$original_ref") || echo "warning: could not return to $original_ref" >&2
  fi
  [[ -z "$tmp_dir" ]] || rm -rf "$tmp_dir"
  return "$code"
}

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

# Parses the command line into binary, skip_build, verify_only and tag.
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --binary) [[ $# -ge 2 ]] || die "--binary needs a path"; binary="$2"; shift ;;
      --skip-build) skip_build=true ;;
      --verify-only) verify_only=true ;;
      -h | --help) usage; exit 0 ;;
      -*) die "unknown option: $1 (see --help)" ;;
      *) [[ -z "$tag" ]] || die "more than one tag given"; tag="$1" ;;
    esac
    shift
  done
  if [[ -z "$tag" ]]; then
    read -r -p "Release tag (for example v2.1.0): " tag
  fi
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "'$tag' is not a release tag like v2.1.0"
  [[ -z "$binary" ]] || binary="$(cd "$(dirname "$binary")" && pwd)/$(basename "$binary")"
}

# Checks the tools, gh access, the release, and (when building) the credentials and certificates.
preflight() {
  step "Checking the tools and credentials"
  local tool
  for tool in git gh shasum curl xcrun; do
    command -v "$tool" >/dev/null || die "'$tool' is not installed"
  done
  gh auth status --hostname github.com >/dev/null 2>&1 \
    || die "you are not signed in to GitHub with gh; run: gh auth login"
  gh release view "$tag" --repo "$REPO" >/dev/null 2>&1 \
    || die "no release $tag on $REPO (is the release PR merged and the release created?)"
  if [[ "$verify_only" == false && "$skip_build" == false ]]; then
    select_notary_auth || { notary_auth_help; exit 1; }
  fi
}

# Checks out the tag, builds and signs the installer, then notarizes it. Sets pkgs (the installers
# for the tag). original_ref makes on_exit return to the starting branch.
build_and_notarize() {
  cd "$repo_root"
  [[ -z "$(git status --porcelain)" ]] || die "the working tree has uncommitted changes; commit or stash them first"
  original_ref="$(git symbolic-ref --quiet --short HEAD || git rev-parse HEAD)"

  step "Checking out $tag"
  git fetch --tags --quiet
  git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null || die "tag $tag does not exist"
  git checkout --quiet "$tag"

  local version="${tag#v}"
  if [[ "$skip_build" == false ]]; then
    step "Building and signing the installer"
    local args=(--version "$version")
    [[ -z "$binary" ]] || args+=(--binary "$binary")
    "$repo_root/scripts/macos-build-pkg.sh" "${args[@]}"
  fi
  step "Notarizing"
  "$repo_root/scripts/macos-notarize.sh" "$repo_root"/target/macos/cmd-rest-"$version"-macos-*.pkg
}

# Writes the .sha256 file for every installer of the tag and uploads both to the release.
publish() {
  local version="${tag#v}" pkg dir files=()
  step "Writing the checksums and uploading to $REPO $tag"
  for pkg in "$repo_root"/target/macos/cmd-rest-"$version"-macos-*.pkg; do
    [[ -e "$pkg" ]] || die "no installer for $version in target/macos"
    xcrun stapler validate "$pkg" >/dev/null || die "$pkg is not notarized and stapled"
    dir="$(dirname "$pkg")"
    # Run inside the folder so the checksum file holds the bare file name, not a path.
    (cd "$dir" && shasum -a 256 "$(basename "$pkg")" >"$(basename "$pkg").sha256")
    cat "$pkg.sha256"
    files+=("$pkg" "$pkg.sha256")
  done
  gh release upload "$tag" "${files[@]}" --repo "$REPO" --clobber
  echo "installers now on the release:"
  gh release view "$tag" --repo "$REPO" --json assets --jq '.assets[].name' | grep -E '\.pkg' | sed 's/^/  /'
}

# Downloads each macOS installer from the public release page, compares its SHA-256 with the
# .sha256 file and checks that it still has a valid notarization ticket.
verify_downloads() {
  step "Verifying the public downloads"
  local name url expected actual failed=0 found=0
  tmp_dir="$(mktemp -d)"
  while IFS= read -r name; do
    found=1
    url="https://github.com/$REPO/releases/download/$tag/$name"
    curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors -o "$tmp_dir/$name" "$url" || die "cannot download $url"
    curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors -o "$tmp_dir/$name.sha256" "$url.sha256" || die "cannot download $url.sha256"
    expected="$(awk 'NR == 1 { print $1 }' "$tmp_dir/$name.sha256")"
    actual="$(shasum -a 256 "$tmp_dir/$name" | awk '{ print $1 }')"
    if [[ "$expected" == "$actual" ]]; then echo "ok       $name"; else echo "MISMATCH $name"; failed=1; fi
    if xcrun stapler validate "$tmp_dir/$name" >/dev/null 2>&1; then
      echo "ok       $name has a valid notarization ticket"
    else
      echo "FAILED   $name has no valid notarization ticket"
      failed=1
    fi
  done < <(gh release view "$tag" --repo "$REPO" --json assets --jq '.assets[].name' | grep -E '^cmd-rest-.*-macos-.*\.pkg$' || true)
  [[ "$found" -eq 1 ]] || die "the release has no macOS .pkg installer"
  [[ "$failed" -eq 0 ]] || die "verification failed"
  echo "all downloads match their checksums"
}

# Runs the steps in order.
main() {
  trap on_exit EXIT
  parse_args "$@"
  preflight
  if [[ "$verify_only" == false ]]; then
    build_and_notarize
    publish
  fi
  verify_downloads
  step "Done"
  echo "https://github.com/$REPO/releases/tag/$tag"
}

main "$@"
