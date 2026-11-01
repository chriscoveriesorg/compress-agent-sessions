# Experimental LZRAVEN/LZMESH support and search compatibility

**Status:** Fail-closed integration plumbing, not a working LZRAVEN filesystem
mode. LZFSE remains the production default. Experimental LZRAVEN, LZMESH and
LZBITMAP compression requests are accepted only when the installed Applesauce
backend positively attests native filesystem support for the exact codec.
LZRAVEN/LZMESH native support remains unverified.

## Goal

Use higher-ratio compression for **cold** Claude Code, Codex and Gemini JSONL
sessions while preserving ordinary reads, restore, file metadata and search
index compatibility.

The [Applesauce roadmap](https://github.com/chriscoveriesorg/applesauce/blob/main/hack/roadmap-lzraven.md)
defines the backend work. macOS 27 provides Apple's LZRAVEN and LZMESH
`compression_encode_buffer` and `compression_decode_buffer` APIs. Their
algorithm constants are not automatically APFS `com.apple.decmpfs` IDs.
The capability and benchmark CLI contract is implemented in
[Applesauce PR #2](https://github.com/chriscoveriesorg/applesauce/pull/2).

## Backend decision

| Result on the tested host | Implementation in this repository |
| --- | --- |
| A verified native APFS decoder and framing exists | Allow experimental `--algorithm LZRAVEN` (or LZMESH) **only** when the installed Applesauce backend positively supports it |
| The native APFS decoder is unavailable | Keep the native LZFSE policy. Investigate a separately mounted FSKit-based archive for optional LZRAVEN reads |
| Buffer codec works but native kernel status is unknown | Benchmark only; preserve existing production CLI behaviour |

The private-type tests must run on generated data and a disposable APFS image.
The image limits file risk, but the host kernel still handles decoding. An
undocumented type could cause a kernel fault.

## Capability preflight

The Applesauce fork separates Apple buffer-codec availability from native
filesystem capability:

```sh
applesauce capabilities --json
applesauce capabilities --json --require-native lzraven
```

The report uses `schema_version: 1` and a `codecs` array with lowercase names.
Each codec has an `apple_buffer` entry (`available`, `reason`,
`verified_roundtrip`) and a `native_decmpfs` entry (`writable`,
`decmpfs_types`, `reason`). Buffer encoding or a verified buffer round trip
does **not** authorize transparent file compression.

`--require-native CODEC` is the machine gate: it prints the report and exits
zero only if that exact codec is natively writable with known decmpfs types.
The session script delegates this check to Applesauce, so it needs no extra
JSON parser. Missing commands or flags on older binaries, a failed probe, or
unsupported native codecs all return nonzero and stop the operation before
session discovery or mutation. There is no fallback to another tool or codec.

The gate applies to `compress`, including `--dry-run`, for `LZRAVEN`, `LZMESH`
and `LZBITMAP`. A selected `afsctool` or `ditto` backend is refused. Existing
`LZFSE`, `LZVN` and `ZLIB` requests do not call this command, and `restore`
does not require a modern encoder to be available.

`estimate` deliberately refuses experimental algorithms: its existing
`compression_tool` backend is not Applesauce and a buffer-size estimate is
not a native APFS result. Use the Applesauce experiment for buffer benchmarks.
No macOS version string alone establishes native compatibility.

For a read-only buffer benchmark, use a stable copy of a log, no larger than
64 MiB, with the compatible Applesauce fork:

```sh
applesauce benchmark-codecs --codec lzraven,lzmesh --file STABLE-COPY --json
```

Replace `STABLE-COPY` with that local file path, not a live session being
written. A successful buffer round trip measures codec behavior, not native
APFS support or allocated-block savings. It does not override the preflight.

## Rollout after native support is proven

1. Preserve existing subcommands (`estimate`, `compress`, `list`, `stats`,
   `restore`) and their age/open-handle/path safety gates.
2. Permit the selected experimental algorithm only after the capability
   preflight passes. Keep LZFSE as the default, and keep the age/open-handle/
   path safety checks in place after a successful preflight.
3. Benchmark physical allocated bytes, compression time and decode time
   against LZFSE and LZMESH. Report real savings after exact readback, with
   no automatic adoption based solely on an encoder's reported byte count.
4. Make unsupported operations return an explicit reason and leave files
   unchanged. Require `restore` and agent-session resume/write tests to pass.

## Search/indexing contract

Native APFS transparent compression returns the original JSONL bytes through
ordinary file reads; `stat()` still reports the logical file size. Search tools
should therefore index the logical files at their existing paths. There is no
special codec plugin needed for a native APFS-compressed file.

Test with a synthetic corpus before/after compression:

- Normal `rg` matches and an external indexed search client return the
  same logical paths, passages and source spans.
- A fresh index build and an incremental index refresh both see identical
  content and do not duplicate entries after atomic replacement.
- Content changes still invalidate stale search results. A compression-only
  metadata change may conservatively miss a cache, but must not require blanket
  re-embedding. Compare stable results, not timing, cache-age or inode fields.
- Active session files remain uncompressed; tools reading them must not be
  interrupted by the compression job.
- If using a separate FSKit mount, index the **mounted logical JSONL path**,
  never its compressed backing chunks. Test mount reattachment and path
  relocation explicitly.

Search integration belongs in the search consumer's own tests. Do not copy
private search-engine code or personal chatlogs into this public fork.

## Acceptance for the first release

- Runs only on a positively supported macOS + Applesauce combination.
- No file changes on unsupported machines or failing preflight checks.
- Normal `cat`, `tail`, search and session-viewer reads are byte-identical.
- `restore` returns the exact original bytes and metadata.
- The existing safety skips, dry-run estimates and ledger remain correct.
- An actual reduction in allocated blocks is verified on realistic test logs.

References:

- <https://developer.apple.com/documentation/compression/compression_lzraven>
- <https://developer.apple.com/documentation/compression/compression_lzmesh>
- <https://github.com/chriscoveriesorg/applesauce>
