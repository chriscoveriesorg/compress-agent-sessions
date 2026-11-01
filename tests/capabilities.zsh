#!/usr/bin/env zsh
# Portable contract tests. No real compressor or APFS file is ever invoked.
set -euo pipefail

readonly CAP_TEST_DIR="${0:A:h}"
readonly CAP_BIN="${CAP_TEST_DIR:h}/bin/compress-agent-sessions"
readonly CAP_FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cas-capabilities.XXXXXXXX")"
readonly CAP_TRACE="$CAP_FIXTURE_ROOT/calls"

cleanup_capabilities() {
  local rc=$?
  if (( rc == 0 )); then
    rm -rf -- "$CAP_FIXTURE_ROOT"
  else
    printf '[capabilities] fixture retained: %s\n' "$CAP_FIXTURE_ROOT" >&2
  fi
  return $rc
}
trap cleanup_capabilities EXIT

# --help returns before the platform gate, leaving the real functions loaded.
# This does not add a production environment switch that could bypass safety.
source "$CAP_BIN" --help >/dev/null

cap_passed=0
cap_output=""
cap_status=0
mock_exit=1
mock_report='{"schema_version":1,"codecs":[{"name":"lzraven","apple_buffer":{"available":true,"verified_roundtrip":true},"native_decmpfs":{"writable":false,"decmpfs_types":[],"reason":"not verified"}}]}'

cap_fail() {
  printf '[FAIL] %s\n%s\n' "$1" "$cap_output" >&2
  exit 1
}
cap_pass() {
  cap_passed=$((cap_passed + 1))
  printf '[PASS] %s\n' "$1"
}
cap_run() {
  : > "$CAP_TRACE"
  cap_status=0
  cap_output=$("$@" 2>&1) || cap_status=$?
}

applesauce() {
  printf '%s\n' "$*" >> "$CAP_TRACE"
  if [[ $# != 4 || "$1" != capabilities || "$2" != --json || "$3" != --require-native ]]; then
    printf 'unexpected mock Applesauce call\n' >&2
    return 97
  fi
  printf '%s\n' "$mock_report"
  return "$mock_exit"
}

# Old/default codecs must work with an old binary (or without capabilities).
for ALGORITHM in LZFSE LZVN ZLIB; do
  cap_run require_native_algorithm_support applesauce
  (( cap_status == 0 )) && [[ ! -s "$CAP_TRACE" ]] \
    || cap_fail "$ALGORITHM unexpectedly required capability discovery"
  cap_pass "$ALGORITHM does not call capabilities"
done

# Every modern name makes exactly the attesting command, never compress.
for ALGORITHM in LZRAVEN LZMESH LZBITMAP; do
  cap_run require_native_algorithm_support applesauce
  (( cap_status != 0 )) \
    && [[ "$(< "$CAP_TRACE")" == "capabilities --json --require-native ${(L)ALGORITHM}" ]] \
    && [[ "$cap_output" == *"No session files were changed"* ]] \
    || cap_fail "$ALGORITHM did not fail closed with its exact capability command"
  cap_pass "$ALGORITHM refuses an unverified native backend despite buffer availability"
done

ALGORITHM=lZrAvEn
validate_algorithm || cap_fail "mixed-case algorithm validation failed"
[[ "$ALGORITHM" == LZRAVEN ]] || cap_fail "algorithm was not canonicalized"
cap_run require_native_algorithm_support applesauce
[[ "$(< "$CAP_TRACE")" == 'capabilities --json --require-native lzraven' ]] \
  || cap_fail "capability name and dispatch name differ"
cap_pass "mixed-case requests use the exact lowercase capability name"

# A future/compatible native backend owns this decision. LZBITMAP's known
# decmpfs identifiers are fixture data here; these tests do not run the codec.
ALGORITHM=LZBITMAP
mock_exit=0
mock_report='{"schema_version":1,"codecs":[{"name":"lzbitmap","native_decmpfs":{"writable":true,"decmpfs_types":[13,14],"reason":"mock supported backend"}}]}'
cap_run require_native_algorithm_support applesauce
(( cap_status == 0 )) && [[ "$(< "$CAP_TRACE")" == 'capabilities --json --require-native lzbitmap' ]] \
  || cap_fail "positive backend attestation was not accepted"
cap_pass "successful native attestation permits the selected codec"

for backend in afsctool ditto arbitrary-command; do
  cap_run require_native_algorithm_support "$backend"
  (( cap_status != 0 )) && [[ ! -s "$CAP_TRACE" ]] \
    && [[ "$cap_output" == *"selected backend: $backend"* ]] \
    || cap_fail "$backend was allowed for an experimental codec"
  cap_pass "$backend cannot receive an experimental compression request"
done

ALGORITHM=LZRAVEN
mock_exit=2
mock_report="error: unrecognized subcommand 'capabilities'"
cap_run require_native_algorithm_support applesauce
(( cap_status != 0 )) && [[ "$cap_output" == *"unrecognized subcommand"* ]] \
  || cap_fail "old Applesauce did not fail with an actionable reason"
cap_pass "old Applesauce failure is preserved without fallback"

mock_report="error: unexpected argument '--require-native'"
cap_run require_native_algorithm_support applesauce
(( cap_status != 0 )) && [[ "$cap_output" == *"unexpected argument"* ]] \
  || cap_fail "a binary lacking the attestation flag was accepted"
cap_pass "capabilities without the native-attestation flag is insufficient"

mock_exit=139
mock_report=""
cap_run require_native_algorithm_support applesauce
(( cap_status != 0 )) && [[ "$cap_output" == *"exit 139"* ]] \
  || cap_fail "failed/signal-killed capability discovery was accepted"
cap_pass "capability process failure remains a hard refusal"

ALGORITHM='not-a-codec'
cap_run validate_algorithm
(( cap_status == 64 )) && [[ ! -s "$CAP_TRACE" ]] \
  || cap_fail "unknown algorithm reached a backend"
cap_pass "unknown algorithms are rejected before backend dispatch"

cap_run main compress --algorithm not-a-codec
(( cap_status == 64 )) && [[ ! -s "$CAP_TRACE" ]] \
  || cap_fail "the CLI did not validate the algorithm before platform/backend work"
cap_pass "the CLI validates algorithms before platform/backend work"

# Command-level ordering: an unsupported codec must refuse before discovery,
# classification, dry-run reporting or any mutating compressor call.
mock_selected_tool=applesauce
detect_tool() { printf '%s\n' "$mock_selected_tool"; }
_loud_chflags_warning() { :; }
resolve_roots() {
  printf 'scan-start\n' >> "$CAP_TRACE"
  printf '%s\n' "$CAP_FIXTURE_ROOT/nonexistent-corpus"
}
prefetch_for_classification() {
  printf 'classify-start\n' >> "$CAP_TRACE"
  return 1
}
compress_file() {
  printf 'compress-start\n' >> "$CAP_TRACE"
  return 1
}

ALGORITHM=LZRAVEN
mock_exit=1
mock_report='native decmpfs support not verified'
for DRY_RUN in 0 1; do
  cap_run cmd_compress
  (( cap_status != 0 )) \
    && [[ "$(< "$CAP_TRACE")" == 'capabilities --json --require-native lzraven' ]] \
    || cap_fail "compress (dry-run=$DRY_RUN) scanned or dispatched after refusal"
  cap_pass "compress dry-run=$DRY_RUN gates before scanning or mutation"
done

ALGORITHM=LZFSE
cap_run cmd_compress
(( cap_status != 0 )) \
  && [[ "$(< "$CAP_TRACE")" == $'scan-start\nclassify-start' ]] \
  || cap_fail "default compression did not retain its existing scan path"
cap_pass "default compression reaches its existing safety scan without capabilities"

ALGORITHM=LZBITMAP
mock_exit=0
mock_report='mock native attestation succeeded'
cap_run cmd_compress
(( cap_status != 0 )) \
  && [[ "$(< "$CAP_TRACE")" == $'capabilities --json --require-native lzbitmap\nscan-start\nclassify-start' ]] \
  || cap_fail "positive attestation did not retain the existing safety scan"
cap_pass "attested compression still passes through the existing safety scan"

# Model auto detection selecting an installed legacy backend, with no Apple
# binary available. The selected backend must not silently receive the codec.
TOOL=auto
mock_selected_tool=afsctool
cap_run cmd_compress
(( cap_status != 0 )) && [[ ! -s "$CAP_TRACE" ]] \
  || cap_fail "auto detection fell back to a non-Applesauce codec writer"
cap_pass "auto detection cannot fall back to a different codec backend"

mock_exit=1

for ALGORITHM in LZRAVEN LZMESH LZBITMAP; do
  cap_run cmd_estimate
  (( cap_status != 0 )) && [[ ! -s "$CAP_TRACE" ]] \
    && [[ "$cap_output" == *"estimate does not support"* ]] \
    || cap_fail "$ALGORITHM estimate reached compression_tool or scanned files"
  cap_pass "$ALGORITHM estimate refuses the unrelated compression_tool path"
done

# Restore is not a new compression request and must remain usable even when
# the modern encoder is unavailable. Stop at its existing open-handle guard.
mock_selected_tool=applesauce
ALGORITHM=LZRAVEN
build_open_handle_set() {
  printf 'restore-open-handle-check\n' >> "$CAP_TRACE"
  return 1
}
cap_run cmd_restore
(( cap_status != 0 )) \
  && [[ "$(< "$CAP_TRACE")" == $'scan-start\nrestore-open-handle-check' ]] \
  || cap_fail "restore was incorrectly gated on modern compression capability"
cap_pass "restore remains independent of modern compression capability"

printf '[capabilities] %d portable assertions passed; no APFS writes performed\n' "$cap_passed"
