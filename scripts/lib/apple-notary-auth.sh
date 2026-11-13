#!/usr/bin/env bash
# Shared helper for the macOS notarization scripts. Source it, do not run it.
#
# Chooses the credential flags for `xcrun notarytool` from environment variables, in this order:
#   1. NOTARY_PROFILE                a profile saved with `xcrun notarytool store-credentials`
#   2. APPLE_API_KEY, APPLE_API_ISSUER, APPLE_API_KEY_PATH   an App Store Connect API key
#   3. APPLE_ID, APPLE_PASSWORD (app-specific password), APPLE_TEAM_ID
# The names in 2 and 3 are the same ones the netlet-app scripts use, so one shell setup serves both.

# Fills the global array NOTARY_AUTH with the notarytool flags. Returns 1 when no complete set of
# credentials is present in the environment. The array is only read after this function succeeds.
select_notary_auth() {
  NOTARY_AUTH=()
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
  elif [[ -n "${APPLE_API_KEY:-}" && -n "${APPLE_API_ISSUER:-}" && -n "${APPLE_API_KEY_PATH:-}" ]]; then
    NOTARY_AUTH=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY" --issuer "$APPLE_API_ISSUER")
  elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    NOTARY_AUTH=(--apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID")
  else
    return 1
  fi
}

# Prints the explanation shown when select_notary_auth fails.
notary_auth_help() {
  cat >&2 <<'MSG'
error: no notarization credentials found. Set one of these in your shell:

  NOTARY_PROFILE                                  (a profile from `xcrun notarytool store-credentials`)
  APPLE_ID, APPLE_PASSWORD, APPLE_TEAM_ID         (APPLE_PASSWORD is an app-specific password)
  APPLE_API_KEY, APPLE_API_ISSUER, APPLE_API_KEY_PATH   (App Store Connect API key)

See apple-notarize-steps.md, section 4.
MSG
}
