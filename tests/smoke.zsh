#!/usr/bin/env zsh
set -euo pipefail

readonly TEST_DIR="${0:A:h}"
readonly REPO_ROOT="${TEST_DIR:h}"
readonly BIN="${REPO_ROOT}/bin/compress-agent-sessions"

# Portable capability-gate cases run here too, before native APFS smoke tests.
zsh "${TEST_DIR}/capabilities.zsh"

readonly FIXTURE_ROOT="$(mktemp -d -t cas-smoke.XXXXXX)"
readonly LEDGER_ROOT="${FIXTURE_ROOT}/ledger"
readonly FAKE_CODEX="${FIXTURE_ROOT}/fake-codex-sessions"

pass_count=0
fail_count=0

pass() {
  pass_count=$((pass_count + 1))
  printf '[PASS] %s\n' "$1"
}

fail() {
  fail_count=$((fail_count + 1))
  printf '[FAIL] %s\n' "$1" >&2
  exit 1
}

cleanup() {
  local rc=$?
  if (( rc != 0 )); then
    printf '[smoke] ABORTED (exit %d); fixture preserved at %s\n' "$rc" "$FIXTURE_ROOT" >&2
  else
    rm -rf -- "$FIXTURE_ROOT"
  fi
  return $rc
}
trap cleanup EXIT

printf '[smoke] bin: %s\n' "$BIN"
printf '[smoke] fixture: %s\n' "$FIXTURE_ROOT"

[[ -x "$BIN" ]] || fail "bin not executable: $BIN"

# ---- fixture: 3 synthetic cold JSONL files ---------------------------------

mkdir -p "$FAKE_CODEX/20"
for i in 1 2 3; do
  for j in {1..1500}; do
    printf '{"role":"assistant","seq":%d,"content":"The quick brown fox jumps over the lazy dog. Lorem ipsum dolor sit amet consectetur adipiscing elit."}\n' "$j"
  done > "$FAKE_CODEX/20/session-$i.jsonl"
done

# Backdate mtime 60 days for all fixture files so they pass the age filter.
local old_ts
old_ts=$(date -v-60d +%Y%m%d%H%M)
for f in "$FAKE_CODEX/20/"*.jsonl; do
  touch -t "$old_ts" -- "$f"
done

printf '[smoke] 3 synthetic cold files created (~200KB each):\n'
ls -la "$FAKE_CODEX/20/"
printf '\n'

# ---- test 1: estimate reports candidates ------------------------------------

estimate_out=$("$BIN" estimate --age-days 14 --ledger-dir "$LEDGER_ROOT" "$FAKE_CODEX" 2>&1)
if echo "$estimate_out" | grep -q 'candidates: 3 files'; then
  pass "estimate reports 3 candidates"
else
  printf '%s\n' "$estimate_out"
  fail "estimate did not report 3 candidates"
fi

# ---- test 2: compress shrinks physical size, keeps content identical --------

reference="${FIXTURE_ROOT}/reference.jsonl"
cp -- "$FAKE_CODEX/20/session-1.jsonl" "$reference"
ref_apparent=$(stat -f '%z' -- "$reference")

compress_out=$("$BIN" compress --age-days 14 --ledger-dir "$LEDGER_ROOT" "$FAKE_CODEX" 2>&1)
printf '%s\n' "$compress_out" | sed 's/^/  /'

after_apparent=$(stat -f '%z' -- "$FAKE_CODEX/20/session-1.jsonl")
after_blocks=$(stat -f '%b' -- "$FAKE_CODEX/20/session-1.jsonl")
after_physical=$((after_blocks * 512))

[[ "$after_apparent" == "$ref_apparent" ]] \
  && pass "compressed apparent size unchanged ($after_apparent bytes)" \
  || fail "compressed apparent size changed: $ref_apparent -> $after_apparent"

(( after_physical < after_apparent )) \
  && pass "physical size shrunk: $after_apparent -> $after_physical bytes" \
  || fail "physical size NOT smaller: apparent=$after_apparent physical=$after_physical"

diff -q -- "$reference" "$FAKE_CODEX/20/session-1.jsonl" >/dev/null \
  && pass "compressed file content is byte-identical to reference" \
  || fail "compressed file content differs from reference"

compressed_flags=$(stat -f '%Sf' -- "$FAKE_CODEX/20/session-1.jsonl" 2>/dev/null)
if [[ "$compressed_flags" == *compressed* ]]; then
  pass "UF_COMPRESSED flag present on compressed file (flags=$compressed_flags)"
else
  fail "UF_COMPRESSED flag missing from compressed file (flags=$compressed_flags)"
fi

# ---- test 3: re-compress skips already-compressed files ---------------------

second_out=$("$BIN" compress --age-days 14 --ledger-dir "$LEDGER_ROOT" "$FAKE_CODEX" 2>&1)
if echo "$second_out" | grep -q 'skip:already-compressed = 3'; then
  pass "re-compress skips 3 already-compressed files"
else
  printf '%s\n' "$second_out"
  fail "re-compress did not skip already-compressed"
fi

# ---- test 4: restore removes decmpfs xattr ----------------------------------

restore_out=$("$BIN" restore --ledger-dir "$LEDGER_ROOT" "$FAKE_CODEX" 2>&1)
printf '%s\n' "$restore_out" | sed 's/^/  /'

restored_flags=$(stat -f '%Sf' -- "$FAKE_CODEX/20/session-1.jsonl" 2>/dev/null)
if [[ "$restored_flags" == *compressed* ]]; then
  fail "restore left compressed flag present (flags=$restored_flags)"
else
  pass "restore cleared compressed flag"
fi

diff -q -- "$reference" "$FAKE_CODEX/20/session-1.jsonl" >/dev/null \
  && pass "restored file content is byte-identical to reference" \
  || fail "restored file content differs from reference"

# ---- test 5: stats reflects at least one compress run -----------------------

stats_out=$("$BIN" stats --ledger-dir "$LEDGER_ROOT" 2>&1)
if echo "$stats_out" | grep -Eq 'runs:[[:space:]]+[1-9]'; then
  pass "stats reports >= 1 run"
else
  printf '%s\n' "$stats_out"
  fail "stats did not report any runs"
fi

# ---- test 6: --exclude honors glob ------------------------------------------

exclude_out=$("$BIN" list --age-days 14 --exclude '*session-2.jsonl' --ledger-dir "$LEDGER_ROOT" "$FAKE_CODEX" 2>&1)
if echo "$exclude_out" | grep -q 'skip:excluded-glob = 1'; then
  pass "exclude glob honored"
else
  printf '%s\n' "$exclude_out"
  fail "exclude glob not honored"
fi

# ---- test 7: list reports too-young files via pruned-by-find summary --------
# Approach C (v0.2.0+) pushes the age filter into find itself, so files that
# are too young are pruned at the kernel level and don't appear as per-row
# `skip:too-young` lines — they show up in the summary's pruned-by-find tally.

list_out=$("$BIN" list --age-days 99999 --ledger-dir "$LEDGER_ROOT" "$FAKE_CODEX" 2>&1)
if echo "$list_out" | grep -Eq 'pruned-by-find: 3 files \(too-young=3'; then
  pass "list reports too-young files via pruned-by-find summary"
else
  printf '%s\n' "$list_out"
  fail "list did not report too-young files via pruned-by-find summary"
fi

# ---- test 8: --help advertises new flags + env overrides ------------------
help_out=$("$BIN" --help 2>&1)
if echo "$help_out" | grep -q -- '--confirm-destructive' \
   && echo "$help_out" | grep -q -- '--allow-system-paths' \
   && echo "$help_out" | grep -q 'COMPRESSION_TOOL_BIN'; then
  pass "--help advertises new flags and env overrides"
else
  printf '%s\n' "$help_out"
  fail "--help missing one of: --confirm-destructive, --allow-system-paths, COMPRESSION_TOOL_BIN"
fi

# ---- test 9: non-Darwin platform refusal via fake-uname executable --------
# IMPORTANT: a PATH-shadowed `uname` shell function does NOT survive across
# a shebang invocation — the child zsh inherits no parent functions. Use a
# fake executable prepended to PATH instead. Codex-corrected approach.
fake_bin="$FIXTURE_ROOT/cas-fake-bin.$$"
mkdir -p "$fake_bin"
cat > "$fake_bin/uname" <<'FAKE_UNAME'
#!/bin/sh
echo Linux
FAKE_UNAME
chmod +x "$fake_bin/uname"

set +e; non_darwin_out=$(PATH="$fake_bin:$PATH" "$BIN" estimate --age-days 14 --ledger-dir "$LEDGER_ROOT" "$FAKE_CODEX" 2>&1); non_darwin_status=$?; set -e
if (( non_darwin_status != 0 )) && echo "$non_darwin_out" | grep -qi 'requires macOS\|Darwin'; then
  pass "non-Darwin host rejected with diagnostic (kernel: Linux)"
else
  printf '%s\n' "$non_darwin_out"
  fail "non-Darwin host check did not refuse (status=$non_darwin_status)"
fi

# Bonus: --help must still work even with fake-uname Linux on PATH.
fake_help_out=$(PATH="$fake_bin:$PATH" "$BIN" --help 2>&1)
if echo "$fake_help_out" | grep -q -- '--confirm-destructive'; then
  pass "--help works under fake-uname Linux (early-return ordering)"
else
  printf '%s\n' "$fake_help_out"
  fail "--help broke under fake-uname Linux"
fi

rm -rf -- "$fake_bin"

# ---- test 10: missing compression_tool via env override -------------------
# PATH manipulation alone is defeated by line 7 of the script which appends
# /usr/bin to PATH unconditionally. Use the new COMPRESSION_TOOL_BIN env
# indirection.
set +e; missing_ct_out=$(COMPRESSION_TOOL_BIN=/var/empty/no-such-compression-tool "$BIN" estimate --age-days 14 --ledger-dir "$LEDGER_ROOT" "$FAKE_CODEX" 2>&1); missing_ct_status=$?; set -e
if (( missing_ct_status != 0 )) && echo "$missing_ct_out" | grep -q 'compression_tool not executable'; then
  pass "missing compression_tool refused with diagnostic"
else
  printf '%s\n' "$missing_ct_out"
  fail "missing compression_tool check did not refuse (status=$missing_ct_status)"
fi

# ---- test 11: system-path denylist (positive AND negative) ----------------
# Positive: passing /Library as a target path must refuse.
set +e; sys_path_out=$("$BIN" list --age-days 14 --ledger-dir "$LEDGER_ROOT" /Library 2>&1); sys_path_status=$?; set -e
if (( sys_path_status != 0 )) && echo "$sys_path_out" | grep -q 'refusing to operate on system path'; then
  pass "system-path denylist refused /Library"
else
  printf '%s\n' "$sys_path_out"
  fail "system-path denylist did NOT refuse /Library (status=$sys_path_status)"
fi

# Negative: a user path containing the substring "Library" must NOT match.
user_lib="$FIXTURE_ROOT/Users-test/Library/cas-test-data"
mkdir -p "$user_lib"
touch -t "$old_ts" -- "$user_lib/.placeholder.jsonl"
set +e; user_lib_out=$("$BIN" list --age-days 14 --ledger-dir "$LEDGER_ROOT" "$user_lib" 2>&1); user_lib_status=$?; set -e
if (( user_lib_status == 0 )) && ! echo "$user_lib_out" | grep -q 'refusing to operate on system path'; then
  pass "system-path denylist accepted user path containing 'Library'"
else
  printf '%s\n' "$user_lib_out"
  fail "system-path denylist false-positive on user path with 'Library' substring"
fi

# Override: --allow-system-paths must permit /Library.
set +e; override_out=$("$BIN" list --age-days 99999 --allow-system-paths --ledger-dir "$LEDGER_ROOT" /Library 2>&1); override_status=$?; set -e
if (( override_status == 0 )); then
  pass "--allow-system-paths bypasses denylist"
else
  printf '%s\n' "$override_out"
  fail "--allow-system-paths did NOT bypass denylist (status=$override_status)"
fi

# ---- test 12: --confirm-destructive gating with LIVE decmpfs flag count ---
flag_fixture="$FIXTURE_ROOT/flag-101"
mkdir -p "$flag_fixture/sessions"
for k in {1..101}; do
  for j in {1..150}; do
    printf '{"seq":%d,"content":"the quick brown fox jumps over the lazy dog"}\n' "$j"
  done > "$flag_fixture/sessions/file-$k.jsonl"
done
for f in "$flag_fixture/sessions/"*.jsonl; do
  touch -t "$old_ts" -- "$f"
done

"$BIN" compress --age-days 14 --ledger-dir "$LEDGER_ROOT" "$flag_fixture" >/dev/null 2>&1 \
  || fail "fixture compress (precondition for test 12) failed"

# Sanity: count flagged files. If <101, the compress backend silently no-op'd
# and the gate test below would be meaningless.
flagged_count=0
for f in "$flag_fixture/sessions/"*.jsonl; do
  flags=$(stat -f '%Sf' -- "$f" 2>/dev/null) || continue
  [[ "$flags" == *compressed* ]] && flagged_count=$((flagged_count + 1))
done
if (( flagged_count < 101 )); then
  printf '[smoke] only %d of 101 fixture files acquired decmpfs flag — backend may have no-opd\n' "$flagged_count" >&2
  fail "test 12 precondition: need 101 flagged files, got $flagged_count"
fi

# Gate must REFUSE without --confirm-destructive.
set +e; gate_refuse_out=$("$BIN" restore --ledger-dir "$LEDGER_ROOT" "$flag_fixture" 2>&1); gate_refuse_status=$?; set -e
if (( gate_refuse_status != 0 )) && echo "$gate_refuse_out" | grep -q '>100 decmpfs-compressed files'; then
  pass "restore gated without --confirm-destructive (>100 flagged files)"
else
  printf '%s\n' "$gate_refuse_out"
  fail "restore did NOT gate on >100 flagged files (status=$gate_refuse_status)"
fi

# Gate must ALSO refuse for --dry-run.
set +e; dry_refuse_out=$("$BIN" restore --dry-run --ledger-dir "$LEDGER_ROOT" "$flag_fixture" 2>&1); dry_refuse_status=$?; set -e
if (( dry_refuse_status != 0 )) && echo "$dry_refuse_out" | grep -q '>100 decmpfs-compressed files'; then
  pass "restore --dry-run respects gate (no mutation, still gated)"
else
  printf '%s\n' "$dry_refuse_out"
  fail "restore --dry-run did NOT respect gate (status=$dry_refuse_status)"
fi

# Gate must PASS with --confirm-destructive.
set +e; gate_pass_out=$("$BIN" restore --confirm-destructive --ledger-dir "$LEDGER_ROOT" "$flag_fixture" 2>&1); gate_pass_status=$?; set -e
if (( gate_pass_status == 0 )); then
  pass "restore proceeds with --confirm-destructive"
else
  printf '%s\n' "$gate_pass_out"
  fail "restore failed even with --confirm-destructive (status=$gate_pass_status)"
fi

# ---- test 13: non-destructive subcommands smoke (cross-coupling guard) ----
for cmd in estimate list stats; do
  case "$cmd" in
    stats) extra_args=() ;;
    *)     extra_args=("$FAKE_CODEX") ;;
  esac
  set +e; rd_out=$("$BIN" "$cmd" --age-days 14 --ledger-dir "$LEDGER_ROOT" "${extra_args[@]}" 2>&1); rd_status=$?; set -e
  if (( rd_status == 0 )); then
    pass "non-destructive subcommand smoke: $cmd"
  else
    printf '%s\n' "$rd_out"
    fail "non-destructive subcommand $cmd failed (status=$rd_status)"
  fi
done

# ---- summary ---------------------------------------------------------------

printf '\n====================\n'
printf '[smoke] %d passed, %d failed\n' "$pass_count" "$fail_count"
(( fail_count == 0 )) && exit 0
exit 1
