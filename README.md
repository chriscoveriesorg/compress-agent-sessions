# compress-agent-sessions

![macOS only](https://img.shields.io/badge/macOS-only-lightgrey) ![best-effort](https://img.shields.io/badge/maintenance-best--effort-yellow)

Apply macOS transparent per-file compression (APFS `UF_COMPRESSED`) to stale
agentic-CLI session-log JSONL archives. Reclaim disk without changing how
apps read the files — the kernel decompresses transparently on read.

Typical ratio on JSONL: **5–50× with LZFSE**.

> This is a focused macOS-only utility, maintained on a best-effort basis.
> See [Scope](#scope) before filing feature requests.

## Related tools for agents

Companion projects in the same tooling family. They are separate tools; links do
not install or run anything automatically:

- **[Foldy](https://github.com/chriscoveries/foldy)** *(private; access required)*: local-first filesystem indexing, duplicate review and disk-space reporting.
- **[Applesauce](https://github.com/chriscoveriesorg/applesauce)**: macOS transparent-compression fork investigating LZRAVEN/LZMESH and native APFS support; existing LZFSE, LZVN and ZLIB operations remain available as a compression backend.
- **[ZGX](https://github.com/chriscoveriesorg/zgx)** *(private; access required)*: agent-oriented local metasearch across literal, indexed and optional semantic sources.

The [modern-codec integration plan](docs/experimental-lzraven.md) keeps the
roles separate: Applesauce owns codec and filesystem support, this script
selects cold files, and search clients keep reading the logical files at
their existing paths. A working LZRAVEN buffer codec alone does not enable
transparent APFS compression.

The [four-tool acceptance guide](https://github.com/chriscoveriesorg/applesauce/blob/main/hack/family-integration.md)
also connects Foldy's hashed inventory and ZGX search receipts to an executable
before/after content contract. The Applesauce backend requests `--verify` on
every file write; it does not change the native Raven/Mesh safety gate.

## Why

Claude Code, Codex CLI, Gemini CLI, and similar agentic tools accumulate
JSONL session transcripts indefinitely. On APFS, macOS's built-in
transparent compression mechanism — the same one Apple uses for OS
binaries — reclaims huge amounts of space with zero runtime cost:
the file looks and reads identically, the disk usage drops.

## Install

    brew install Dr-Emann/homebrew-tap/applesauce
    # then drop the script anywhere in PATH, e.g.:
    ln -s "$(pwd)/bin/compress-agent-sessions" /usr/local/bin/

The script auto-detects the best available tool at runtime:

| Preference | Tool | Notes |
|---|---|---|
| 1 | `applesauce` | Recommended — fastest, safest, atomic rename |
| 2 | `afsctool` | Classic choice; `brew install afsctool` |
| 3 | `ditto --hfsCompression` | Pre-installed but **unreliable on APFS**; avoid if possible |

Force a specific tool with `--tool applesauce|afsctool|ditto`.

## Quick start

    # what's eligible, without touching anything
    compress-agent-sessions estimate

    # show every file with its classification
    compress-agent-sessions list

    # dry run — describe without modifying
    compress-agent-sessions compress --dry-run

    # actually compress
    compress-agent-sessions compress

    # cumulative + recent-run totals
    compress-agent-sessions stats

    # undo (decompress)
    compress-agent-sessions restore ~/.codex/sessions/2026/01

Default discovery scopes (auto-detected):

- Claude Code: `$HOME/.claude/projects/*/*.jsonl`
- Codex CLI:   `$HOME/.codex/sessions/**/*`
- Gemini CLI:  `$HOME/.gemini/sessions/` (if present)

Override with explicit paths:

    compress-agent-sessions compress ~/.codex/sessions/2026/01

## Safety model

The tool will **skip** a file — never silently compressing it — if:

- mtime within `--active-grace-minutes` (default 15) — likely being written
- held open by any process (`lsof`) — someone's reading/writing right now
- in the Codex "current month" directory — today's logs
- already has the `UF_COMPRESSED` flag (idempotent)
- younger than `--age-days` (default 14)
- matches an `--exclude` glob

Every skip has a reason code, surfaced in `list`, `compress`, and the ledger.

All compression is reversible: `compress-agent-sessions restore PATHS`.

## How it works

macOS has had transparent per-file compression since Mac OS X 10.6 Snow
Leopard — the original HFS+ `com.apple.decmpfs` mechanism. APFS kept
backward compatibility and uses the same `UF_COMPRESSED` inode flag.
Modern compressors like `applesauce` use it to store compressed payload
inline (small files) or in an xattr-overflow extent (larger files).

Key property: **writes to a compressed file kill the compression**. The
kernel decompresses the whole file back to uncompressed bytes before
applying the write. That's why this tool only targets cold archives —
compression is stable as long as nobody writes to the file again.

Algorithms (via `--algorithm`):

| Algo | Ratio (JSONL) | Decode speed | Recommended? |
|---|---|---|---|
| `LZFSE` (default) | ~50× | fastest | yes, for new work |
| `ZLIB` | slightly higher at level 9 | ~3× slower than LZFSE | only if you need maximum ratio |
| `LZVN` | in between | fast | no (LZFSE dominates) |

This fork also recognizes `LZRAVEN`, `LZMESH` and `LZBITMAP` for experimental
`compress` requests. Before scanning any session files, it requires the
selected Applesauce backend to pass
`applesauce capabilities --json --require-native <lowercase-codec>`.
Unsupported codecs, older Applesauce binaries and other backends fail without
fallback, including with `--dry-run`. LZRAVEN/LZMESH native support remains
unverified; merely upgrading macOS does not pass this gate. The existing
`estimate` backend does not support these experimental algorithms.
See the [capability contract](docs/experimental-lzraven.md#capability-preflight).

## Ledger

Per-run JSON at `$LEDGER_DIR/runs/<ISO8601>.json`. Cumulative totals in
`$LEDGER_DIR/cumulative.txt`.

`$LEDGER_DIR` defaults to `${XDG_STATE_HOME:-$HOME/.local/state}/compress-agent-sessions`.
Override with `--ledger-dir PATH`.

`compress-agent-sessions stats` prints the cumulative totals + the 10
most recent runs.

## Automation

See `docs/launchd-weekly-example.plist` for a launchd template that runs
the tool weekly. Install with:

    mkdir -p ~/Library/LaunchAgents
    cp docs/launchd-weekly-example.plist ~/Library/LaunchAgents/com.user.compress-agent-sessions.plist
    # edit paths to match your install
    launchctl load ~/Library/LaunchAgents/com.user.compress-agent-sessions.plist

## Scope

Single-script macOS utility. Scope is **frozen** to the current 5 subcommands
(`estimate`, `compress`, `list`, `stats`, `restore`) and the existing 3 backends
(`applesauce`, `afsctool`, `ditto`). PRs adding new subcommands, new compression
backends, or non-macOS platform support **will not be merged** — fork instead.

Bug-fix PRs are welcome when accompanied by a smoke-test assertion. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the contribution policy and the three
hard-close labels (`wontfix:platform`, `wontfix:scope`, `wontfix:ai-generated`).

## Troubleshooting

### No candidates found

Auto-discovery looks under `~/.claude/projects/`, `~/.codex/sessions/`, and
`~/.gemini/sessions/`. If those directories don't exist or all files are
younger than `--age-days` (default 14), zero candidates is correct. Check:

    compress-agent-sessions list                  # see classification
    compress-agent-sessions list --age-days 0     # ignore age (debug)

### `lsof not found on PATH`

Required for active-handle safety detection. `/usr/sbin/lsof` ships with
macOS as part of the base install — it is **not** an Xcode CLT component.
If the script cannot find it, the likely causes are:

- **Asahi Linux / Docker-on-Mac**: the macOS base userspace is absent; lsof
  is genuinely missing and must be installed.
- **Stripped macOS environment**: a minimal container or CI image that
  deliberately excludes base tools.

Workaround:

    brew install lsof

The script aborts hard rather than silently shipping without open-handle
protection — this is intentional.

### `ditto` compresses but `du -sh` shows no change

`ditto --hfsCompression` is documented as best-effort and **frequently no-ops
on APFS** despite returning success. Force a real backend:

    brew install Dr-Emann/homebrew-tap/applesauce  # preferred
    # or
    brew install afsctool                           # fallback

Then re-run with `--tool applesauce` (or let auto-detection pick it).

### chflags truncation — known macOS kernel behavior

> ⚠ **Read this before wrapping the script in other tooling.**
>
> Calling `chflags(1)` or `chflags(2)` on a decmpfs-compressed file will
> **silently truncate it to zero bytes**. This is documented Apple kernel
> behavior, **not** a vulnerability in this tool. The script never calls
> `chflags` on a compressed file, but if you pipe its output into tooling
> that does, decompress first via `applesauce decompress` or
> `compress-agent-sessions restore <path>`.
>
> Reports of this as a CVE will be closed with `wontfix:platform`.

### `restore` aborted — >100 compressed files in scope

`restore` requires `--confirm-destructive` when the target scope contains more
than 100 decmpfs-compressed files. This gate applies to both real restore **and**
`--dry-run`. If you have verified the scope and intend to decompress, re-run with:

    compress-agent-sessions restore --confirm-destructive [PATHS...]

This gate does NOT apply to `compress` (compression is reversible). The error
message includes the exact command to re-run with the flag.

### Before Filing a Bug

Three things make any bug actionable. Include all three:

1. `compress-agent-sessions estimate --verbose 2>&1` (full output)
2. `sw_vers -productVersion` (your macOS version)
3. `which applesauce afsctool ditto` (which backends you have)

The issue template enforces these. Reports without all three will be
closed and reopened once they're added.

## Limitations

- **macOS only.** Uses APFS/HFS+ decmpfs, which doesn't exist on Linux or Windows.
- **Requires applesauce or afsctool for reliable compression.** The `ditto`
  fallback is best-effort and may silently no-op on APFS.
- **Compression is lost on any write.** Do not run this on files you expect
  to modify.
- **Not for non-JSONL content.** Works fine on any file type, but the
  compression ratio is tuned to text/JSONL in the estimator sampling.

## Testing

Portable mocked capability-gate tests (no native compression performed):

    zsh tests/capabilities.zsh

Full macOS native-compression smoke tests, including those portable cases:

    zsh tests/smoke.zsh

Creates a synthetic fixture in `$TMPDIR`, exercises estimate/compress/
list/stats/restore/exclude paths end-to-end, and asserts a 5×+ ratio
on the synthetic payload. No real user data is touched.

## License

MIT — see `LICENSE`.
