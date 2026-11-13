#!/usr/bin/env bash
# Sends signed macOS installers (.pkg) to Apple's notary service, waits for the verdict and staples
# the approval ticket to each file, so Gatekeeper accepts it even when the Mac is offline.
#
# Usage:
#   scripts/macos-notarize.sh [file.pkg ...]
#
#   With no argument it processes every .pkg in target/macos (made by scripts/macos-build-pkg.sh).
#   A file that is already stapled is skipped.
#
# Credentials (environment variables); see scripts/lib/apple-notary-auth.sh. One of:
#   NOTARY_PROFILE                                       a profile from `xcrun notarytool store-credentials`
#   APPLE_ID, APPLE_PASSWORD (app-specific), APPLE_TEAM_ID
#   APPLE_API_KEY, APPLE_API_ISSUER, APPLE_API_KEY_PATH  App Store Connect API key

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/apple-notary-auth.sh
source "$repo_root/scripts/lib/apple-notary-auth.sh"

# Prints the lines of the header comment as the help text.
usage() {
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Prints an error message and stops the script.
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Reads one field of a JSON file written by notarytool. Prints nothing when it is missing.
json_field() {
  plutil -extract "$2" raw -o - "$1" 2>/dev/null || true
}

# Submits one installer, waits for the result and fails with Apple's log when it is not Accepted.
submit() {
  local pkg="$1" result status id
  result="$(mktemp)"
  echo "submitting; Apple usually answers within a few minutes, sometimes longer the first time..."
  xcrun notarytool submit "$pkg" "${NOTARY_AUTH[@]}" --wait --output-format json >"$result" || true
  status="$(json_field "$result" status)"
  id="$(json_field "$result" id)"
  echo "submission id: ${id:-unknown}, status: ${status:-unknown}"
  if [[ "$status" != "Accepted" ]]; then
    cat "$result" >&2
    if [[ -n "$id" ]]; then
      echo "--- Apple's log for $id ---" >&2
      xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" >&2 || true
    fi
    rm -f "$result"
    die "notarization of $pkg was not accepted (see the log above)"
  fi
  rm -f "$result"
}

# Notarizes, staples and checks one installer.
process() {
  local pkg="$1"
  echo "==> $pkg"
  [[ -f "$pkg" ]] || die "no such file: $pkg"
  if xcrun stapler validate "$pkg" >/dev/null 2>&1; then
    echo "already notarized and stapled, skipping"
    return 0
  fi
  pkgutil --check-signature "$pkg" | grep -q 'Developer ID Installer' \
    || die "$pkg is not signed with a Developer ID Installer certificate; build it with scripts/macos-build-pkg.sh"
  submit "$pkg"
  xcrun stapler staple "$pkg"
  xcrun stapler validate "$pkg"
  # Gatekeeper's own verdict for an installer: expect "accepted" and "source=Notarized Developer ID".
  spctl --assess --type install --verbose=4 "$pkg"
}

# Collects the files to process and runs process on each.
main() {
  case "${1:-}" in -h | --help) usage; exit 0 ;; esac
  command -v xcrun >/dev/null || die "xcrun not found (install the Xcode Command Line Tools: xcode-select --install)"
  select_notary_auth || { notary_auth_help; exit 1; }

  local files=() f
  if [[ $# -gt 0 ]]; then
    files=("$@")
  else
    for f in "$repo_root"/target/macos/*.pkg; do
      [[ -e "$f" ]] && files+=("$f")
    done
  fi
  [[ ${#files[@]} -gt 0 ]] || die "no .pkg found; run scripts/macos-build-pkg.sh first"
  for f in "${files[@]}"; do
    process "$f"
  done
}

main "$@"
