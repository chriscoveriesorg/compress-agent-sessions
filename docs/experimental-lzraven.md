# Experimental LZRAVEN/LZMESH support and search compatibility

**Status:** Design gate only. This fork's current production CLI still uses
native APFS LZFSE/LZVN/ZLIB through Applesauce, afsctool or ditto. No new
LZRAVEN filesystem mode is enabled.

## Goal

Use higher-ratio compression for **cold** Claude Code, Codex and Gemini JSONL
sessions while preserving ordinary reads, restore, file metadata and search
index compatibility.

The [Applesauce capability experiment](https://github.com/chriscoveriesorg/applesauce/pull/1)
determines the backend. macOS 27 provides Apple's LZRAVEN and LZMESH
`compression_encode_buffer` and `compression_decode_buffer` APIs. Their
algorithm constants are not automatically APFS `com.apple.decmpfs` IDs.

## Backend decision

| Result on macOS 27.2+ | Implementation in this repository |
| --- | --- |
| A verified native APFS decoder and framing exists | Allow experimental `--algorithm LZRAVEN` (or LZMESH) **only** when the installed Applesauce backend positively supports it |
| The native APFS decoder is unavailable | Keep the native LZFSE policy. Investigate a separately mounted FSKit-based archive for optional LZRAVEN reads |
| Buffer codec works but native kernel status is unknown | Benchmark only; preserve existing production CLI behaviour |

The private-type tests must run on generated data and a disposable APFS image.
The image limits file risk, but the host kernel still handles decoding. An
undocumented type could cause a kernel fault.

## CLI integration after native support is proven

1. Preserve existing subcommands (`estimate`, `compress`, `list`, `stats`,
   `restore`) and their age/open-handle/path safety gates.
2. Extend `--algorithm` validation with `LZRAVEN` only when a compatible
   Applesauce binary and macOS decoder have been positively identified.
   Reject incompatible `afsctool` and `ditto` combinations before editing
   files. Keep LZFSE as the default.
3. Benchmark physical allocated bytes, compression time and decode time
   against LZFSE and LZMESH. Report real savings after exact readback, with
   no automatic adoption based solely on an encoder's reported byte count.
4. Make unsupported operations return an explicit reason and leave files
   unchanged. Require `restore` and agent-session resume/write tests to pass.

## Search/indexing contract

Native APFS transparent compression returns the original JSONL bytes through
ordinary `open()`, `read()` and `stat()` calls. Search tools should therefore
index the logical files at their existing paths. There is no special codec
plugin needed for a native APFS-compressed file.

Test with a synthetic corpus before/after compression:

- Normal `rg` matches and an external indexed search client return the
  same logical paths, passages and source spans.
- A fresh index build and an incremental index refresh both see identical
  content and do not duplicate entries after atomic replacement.
- Stale result caches are invalidated only when the session contents change.
  Compression alone should not trigger expensive re-embedding.
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
