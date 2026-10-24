#!/bin/bash
# Test certificate-selection gates without building, signing, or using credentials.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/OtterClip-signing-check.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
mkdir "$FIXTURE/bin"
cat > "$FIXTURE/bin/security" <<'SCRIPT'
#!/bin/bash
cat "$SIGNING_FIXTURE_IDENTITIES"
SCRIPT
cat > "$FIXTURE/bin/swift" <<'SCRIPT'
#!/bin/bash
touch "$SIGNING_FIXTURE_SWIFT_CALLED"
exit 73
SCRIPT
chmod 700 "$FIXTURE/bin/security" "$FIXTURE/bin/swift"
export PATH="$FIXTURE/bin:$PATH"
export SIGNING_FIXTURE_IDENTITIES="$FIXTURE/identities"
export SIGNING_FIXTURE_SWIFT_CALLED="$FIXTURE/swift-called"
TEAM=TEAMID1234
IDENTITY='Developer ID Application: Fixture Developer (TEAMID1234)'
HASH=1111111111111111111111111111111111111111
printf '  1) %s "%s"\n' "$HASH" "$IDENTITY" > "$SIGNING_FIXTURE_IDENTITIES"
passed=0
run_case() {
  local description="$1" expected="$2" result=0
  shift 2
  rm -f "$SIGNING_FIXTURE_SWIFT_CALLED"
  "$@" > "$FIXTURE/output" 2>&1 || result=$?
  if [[ "$expected" == accepted ]]; then
    [[ "$result" == 73 && -f "$SIGNING_FIXTURE_SWIFT_CALLED" ]] || { cat "$FIXTURE/output"; printf 'FAIL %s\n' "$description"; exit 1; }
  else
    [[ "$result" != 0 && ! -e "$SIGNING_FIXTURE_SWIFT_CALLED" ]] || { cat "$FIXTURE/output"; printf 'FAIL %s\n' "$description"; exit 1; }
  fi
  passed=$((passed + 1))
  printf 'PASS %s\n' "$description"
}
run_case 'formal mode rejects ad-hoc before build' rejected env RELEASE_SIGNING=formal CODE_SIGN_IDENTITY=- EXPECTED_TEAM_ID="$TEAM" "$ROOT/scripts/build-app.sh"
run_case 'formal mode requires a Team ID' rejected env -u EXPECTED_TEAM_ID RELEASE_SIGNING=formal CODE_SIGN_IDENTITY="$IDENTITY" "$ROOT/scripts/build-app.sh"
run_case 'formal mode rejects malformed Team ID' rejected env RELEASE_SIGNING=formal CODE_SIGN_IDENTITY="$IDENTITY" EXPECTED_TEAM_ID='wrong"team' "$ROOT/scripts/build-app.sh"
run_case 'formal mode rejects an identity from another team' rejected env RELEASE_SIGNING=formal CODE_SIGN_IDENTITY="$IDENTITY" EXPECTED_TEAM_ID=OTHERTEAM01 "$ROOT/scripts/build-app.sh"
run_case 'formal mode accepts exact Developer ID name' accepted env RELEASE_SIGNING=formal CODE_SIGN_IDENTITY="$IDENTITY" EXPECTED_TEAM_ID="$TEAM" "$ROOT/scripts/build-app.sh"
run_case 'formal mode accepts an exact certificate hash' accepted env RELEASE_SIGNING=formal CODE_SIGN_IDENTITY="$HASH" EXPECTED_TEAM_ID="$TEAM" "$ROOT/scripts/build-app.sh"
printf '  2) 2222222222222222222222222222222222222222 "%s"\n' "$IDENTITY" >> "$SIGNING_FIXTURE_IDENTITIES"
run_case 'formal mode rejects ambiguous certificate names' rejected env RELEASE_SIGNING=formal CODE_SIGN_IDENTITY="$IDENTITY" EXPECTED_TEAM_ID="$TEAM" "$ROOT/scripts/build-app.sh"
printf '  0 valid identities found\n' > "$SIGNING_FIXTURE_IDENTITIES"
run_case 'formal mode rejects unavailable certificates' rejected env RELEASE_SIGNING=formal CODE_SIGN_IDENTITY="$IDENTITY" EXPECTED_TEAM_ID="$TEAM" "$ROOT/scripts/build-app.sh"
run_case 'formal packaging requires a notary profile before build' rejected env -u NOTARY_KEYCHAIN_PROFILE RELEASE_SIGNING=formal CODE_SIGN_IDENTITY="$IDENTITY" EXPECTED_TEAM_ID="$TEAM" "$ROOT/scripts/package-release.sh" "$FIXTURE/release"
run_case 'development mode still supports local builds' accepted env RELEASE_SIGNING=development CODE_SIGN_IDENTITY=- "$ROOT/scripts/build-app.sh"
printf '%s/%s signing preflight checks passed (mock metadata only)\n' "$passed" "$passed"
