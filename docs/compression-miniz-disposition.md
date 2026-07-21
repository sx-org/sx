# Miniz migration disposition manifest

This is the mechanical, fail-closed crosswalk from the archived Miniz 3.1.2
port to the idiomatic SX standard-library surface. The pinned upstream is
commit `77d0dce8627735138c51770d1799a1ef48f2117d`. The source inventories are
`sx-zip/tests/upstream_symbols.txt`,
`sx-zip/tests/upstream_declaration_only_symbols.txt`, and
`sx-zip/tests/upstream_config_symbols.txt`; the extraction rule is preserved in
`sx-zip/tests/upstream_surface.sh`.

The inventory equation is exact:

- 118 public entry points: 112 defined exports plus six declaration-only
  streaming-extract entry points;
- 180 function definitions: 112 public definitions plus 68 private
  definitions;
- 186 unique declaration/implementation names: the 180 definitions plus the
  six declaration-only public entry points;
- 18 compile-time configuration identifiers.

Every one of the 186 names appears exactly once in the two function tables
below. Every configuration identifier appears exactly once in the
configuration table. A row is a disposition, not a completion claim. Where
the archived differential proof has not yet been adapted and rerun against
the final stdlib/compiler state, the row says so through its gate key; all
gate keys are now closed (see below).

## Disposition vocabulary

- **Public**: useful behavior is retained through the named idiomatic SX API.
- **Private**: the behavior remains part of the codec/archive engine because
  deterministic bytes, correctness, or performance depends on it; the C
  spelling is intentionally not exported.
- **Superseded**: the identifier represented only a C ABI, numeric status,
  global last-error state, `FILE *` adapter, preprocessor surface, or policy
  spelling that SX deliberately replaces. The row gives the replacement or
  explains why there is no native analogue.

## Evidence gate keys (all closed)

The keys below are concrete. Every key is now **Closed** — either by fresh
final-tree stdlib evidence (named examples at opt 0/3) or by an explicit
supersession: the archived C transcript tests a surface or build permutation
that no longer exists, and the accepted differential is the frozen 110-case
exact-byte matrix plus timed-artifact byte identity recorded in
`docs/benchmarks/compression.md`.

| Key | Current mapping evidence and required final gate |
| --- | --- |
| `G-CHECKSUM` | Example 1731 (`std-zlib-gzip-lifecycle`) pins the u32 checksum functions: empty-input seeds (Adler-32 = 1, CRC-32 = 0), known vectors (`"abc"` = 0x024d0127, `"123456789"` = 0xcbf43926), and incremental-seed equality with one-shot results, at opt 0 and opt 3. **Closed.** |
| `G-ZLIB-HELPER` | 1711 covers the one-shot helpers and strict/prefix decode; 1731 adds `zlib.bound`, a level 0-10 encode/decode round-trip sweep held under the bound, and the invalid-level `InvalidOptions` negative, at opt 0/3. The archived helper transcript is superseded by the frozen 110-case exact level/strategy matrix against pinned miniz C (`docs/benchmarks/compression.md`). **Closed.** |
| `G-ZLIB-LIFECYCLE` | 1731 constructs `zlib.Encoder`/`zlib.Decoder` directly: flush-to-done, `reset` re-arming with deterministic byte equality across streams, decoder reset/re-read, corrupted-payload failure, and gzip truncation, at opt 0/3; 1711 keeps the raw-DEFLATE window/flush legs. The archived per-flush/strategy zlib transcripts are superseded by the 110-case exact matrix. **Closed.** |
| `G-TDEFL` | Public streams pass in 1711/1731; the archived all-level/all-strategy/flush transcripts are superseded by the 110-case exact-byte matrix plus the six timed-artifact byte comparisons, rerun on the final tree and recorded in `docs/benchmarks/compression.md`. **Closed by supersession.** |
| `G-TINFL` | Public bounded decoders pass in 1711; 1731 adds corrupted-payload and truncated-stream negatives at opt 0/3. The archived exhaustive symbol/malformed-tree corpus is superseded: decode byte identity across the accepted corpus and timed artifacts is the accepted differential. **Closed by supersession.** |
| `G-PNG` | 1710 pins complete Miniz bytes for all public pixel formats, stride directions, dimension/format validation, and allocation mapping at opt 0/3. The per-level transcript is superseded by the shared-deflate 110-case matrix. **Closed.** |
| `G-ZIP-INIT` | 1718 covers memory, embedded, bounded-source, and file opens with metadata bounds and teardown, and its `from_reader` failing-allocator sweep forces every init allocation-failure point (including replacement-writer init). Typed `OpenFileOptions` validation replaces the archived sentinel oracles. **Closed.** |
| `G-ZIP-ERROR` | 1718 pins the typed taxonomy (`InvalidOptions` for level/time/extra options, `InvalidArgument` surfaces, poisoning, checksum, limits) plus fallible `Writer.close()`/`EntryReader.finish()` semantics; 1720-1725 pin sampled C-name negatives at opt 0/3; the mechanical final-tree audit finds ZERO historical C spellings in public codec code and every internal C-shaped name `private` (44 public declarations). **Closed.** |
| `G-ZIP-LOOKUP` | The C lookup policy was REMOVED outright — the case-folded/comment-filtered/path-ignoring variants and their sorted-index machinery no longer exist; `find` is a single exact case-sensitive first-match scan pinned by 1718's duplicate/exact-case/missing/unsafe-path coverage. An external policy corpus would test behavior the surface no longer has. **Closed.** |
| `G-ZIP-EXTRACT` | 1718's terminal-checksum tests are PUBLIC negative CRC evidence — stored, deflated, source-backed, and post-seek streams all report checksum failure through the public `EntryReader`, and `finish()` raises on an abandoned stream; 1717 keeps the engine-level CRC/skip distinctions. The archived 75-case matrix is superseded by these plus the exact-byte pinned archive. **Closed.** |
| `G-ZIP-SEEK` | 1718 covers forward/backward/sequential/raw/source-backed streaming, EOF validation, and explicit `finish()` abandonment at opt 0/3. Backward seeks replay decompression through the identical terminal-checksum path, so corruption surfaces regardless of seek history. **Closed.** |
| `G-ZIP-FS` | 1712 covers host modification-time behavior (modification time only is restorable — a documented narrowing); 1713/1716 compile the full fs surface for `x86_64-windows-gnu` in the compile-only corpus mode; the file-backend `add_from` test injects a mid-record failure over a real file and proves ftruncate rollback byte-identical. Stdio failure matrices are superseded by the typed `Io` propagation pinned in 1718. **Closed.** |
| `G-ZIP-WRITE` | 1718 invokes every factory INCLUDING the `create`/`create_file` conveniences (round-tripped through `open_file`), pins one archive byte-for-byte to miniz, and its `add_from` failure tests prove FULL final-archive byte identity against a never-failed control on memory AND file backends — subsuming the local-record transfer gate. Typed factory options replace the archived parameter matrix. **Closed.** |
| `G-ZIP-INPLACE` | 1718 distinguishes `from_reader` memory-copy from `append_file` true update; the update-backend truncate and rollback tests prove partial-write cleanup with byte-identical final archives, and the `add_from` controls prove retained records exactly. **Closed.** |
| `G-DEFLATE-ENGINE` | The C build-variant matrix (endian / unaligned / memcpy / forced-32-bit / less-memory compile permutations) tests configurations that do not exist in the single portable SX engine. The portable path's byte identity across the 110-case matrix and timed artifacts, rerun on the final tree (`docs/benchmarks/compression.md`), is the accepted differential. **Closed by supersession.** |
| `G-INFLATE-ENGINE` | Same disposition as `G-DEFLATE-ENGINE`: the archived machine-variant corpus targets C build permutations the portable SX engine does not have; decode byte identity across the accepted corpus plus 1711/1731's resumable/malformed/truncation negatives is the accepted differential. **Closed by supersession.** |
| `G-ZIP-ENGINE` | 1717/1718 plus the boundary tests added this stream (add_from rollback/poison at the exact post-emission boundary, dual-error precedence, allocation sweeps, fallible finalization) cover the engine surfaces; the archived matrices are superseded per this manifest's per-name dispositions and the exact-byte fixtures. **Closed.** |
| `G-FS` | 1712 is host evidence; 1713/1716 compile the POSIX/Windows surface cross-target in compile-only mode; `File.truncate` (new, backing ZIP rollback) is exercised by the file-backend rollback test; close/flush failure observability is pinned by `Writer.close()` semantics in 1718. **Closed.** |
| `G-SURFACE` | Mechanical final-tree audit: ZERO historical C spellings (`mz_`/`MZ_`/`tdefl_`/`TDEFL_`/`tinfl_`/`TINFL_`/`Mz*`) appear in public codec code, and every internal C-shaped name is declared `private` (file-local under the `private` language feature, commit a864f4fb — never carried by flat import or namespace access). Examples 1720-1725 pin sampled behavioral negatives at opt 0/3; the codec tree has no third-party imports. **Closed.** |

## Public entry points: 118/118 enumerated

| Upstream identifier | Surface | Disposition | Native mapping or supersession rationale | Evidence / gate |
| --- | --- | --- | --- | --- |
| `mz_adler32` | public definition | Public | `zlib.checksum(data, initial)` | `G-CHECKSUM` |
| `mz_compress` | public definition | Public | `zlib.encode(data)` | `G-ZLIB-HELPER` |
| `mz_compress2` | public definition | Public | `zlib.encode(data, .{ level = ... })` | `G-ZLIB-HELPER` |
| `mz_compressBound` | public definition | Public | `zlib.bound(source_len)` | `G-ZLIB-HELPER` |
| `mz_crc32` | public definition | Public | `gzip.checksum(data, initial)` | `G-CHECKSUM` |
| `mz_deflate` | public definition | Public | `zlib.Encoder.write/flush/finish`, returning typed `compress.Progress` | `G-ZLIB-LIFECYCLE` |
| `mz_deflateBound` | public definition | Public | `zlib.bound(source_len)` | `G-ZLIB-HELPER` |
| `mz_deflateEnd` | public definition | Public | `zlib.Encoder.deinit()` | `G-ZLIB-LIFECYCLE` |
| `mz_deflateInit` | public definition | Public | by-value `zlib.Encoder.init()` | `G-ZLIB-LIFECYCLE` |
| `mz_deflateInit2` | public definition | Public | `zlib.Encoder.init(options)` or raw `deflate.Encoder.init(options)`; numeric method/window/memory arguments are replaced by the selected typed codec | `G-ZLIB-LIFECYCLE` |
| `mz_deflateReset` | public definition | Public | `zlib.Encoder.reset(options)` | `G-ZLIB-LIFECYCLE` |
| `mz_error` | public definition | Superseded | Numeric zlib/miniz codes and string lookup are replaced by `compress.Error`; no global integer-to-string API is exported | `G-SURFACE` |
| `mz_free` | public definition | Superseded | Owned results are released through the `Allocator` that created them; a library-global free function would lose ownership identity | `G-SURFACE` |
| `mz_inflate` | public definition | Public | `zlib.Decoder.read/finish`, returning typed `compress.Progress` | `G-ZLIB-LIFECYCLE` |
| `mz_inflateEnd` | public definition | Public | `zlib.Decoder.deinit()` | `G-ZLIB-LIFECYCLE` |
| `mz_inflateInit` | public definition | Public | by-value `zlib.Decoder.init()` | `G-ZLIB-LIFECYCLE` |
| `mz_inflateInit2` | public definition | Public | `zlib.Decoder.init()` or raw `deflate.Decoder.init()`; framing selection replaces numeric window bits | `G-ZLIB-LIFECYCLE` |
| `mz_inflateReset` | public definition | Public | `zlib.Decoder.reset(max_output)` | `G-ZLIB-LIFECYCLE` |
| `mz_uncompress` | public definition | Public | strict `zlib.decode`/`zlib.decode_into` | `G-ZLIB-HELPER` |
| `mz_uncompress2` | public definition | Public | `zlib.decode_prefix`/`decode_into_prefix`, whose `DecodeResult.consumed` replaces the in/out source-length pointer | `G-ZLIB-HELPER` |
| `mz_version` | public definition | Superseded | This is a pinned implementation source, not a C compatibility library; SX stdlib exposes no Miniz runtime-version symbol | `G-SURFACE` |
| `mz_zip_add_mem_to_archive_file_in_place` | public definition | Public | `zip.Writer.append_file`, `add`, and `finish` | `G-ZIP-INPLACE` |
| `mz_zip_add_mem_to_archive_file_in_place_v2` | public definition | Public | `zip.Writer.append_file`, typed `EntryOptions`, explicit archive comment in `finish`, and error channels replace boolean/error-out parameters | `G-ZIP-INPLACE` |
| `mz_zip_clear_last_error` | public definition | Superseded | SX errors are returned/raised on the operation; there is no mutable last-error side channel to clear | `G-ZIP-ERROR` |
| `mz_zip_end` | public definition | Public | `zip.Reader.deinit()` or `zip.Writer.deinit()` supplies cleanup; writer finalization/flush errors must be observed from `Writer.finish`, while deinit-time close failure is not reportable | `G-ZIP-ERROR` |
| `mz_zip_extract_archive_file_to_heap` | public definition | Public | `zip.open_file`, exact `Reader.find`, then allocator-owned `Reader.extract` or `extract_compressed` according to the typed operation | `G-ZIP-FS` |
| `mz_zip_extract_archive_file_to_heap_v2` | public definition | Public | Exact-name normal/raw extraction maps to `open_file` plus `find` and `extract`/`extract_compressed`; comment matching, alternate lookup flags, and error-out parameters are superseded | `G-ZIP-FS` |
| `mz_zip_get_archive_file_start_offset` | public definition | Superseded | Container offsets are inputs to `zip.open_file(start, size)` or discovered by `open_embedded`; Reader does not expose C storage-layout state | `G-ZIP-INIT` |
| `mz_zip_get_archive_size` | public definition | Superseded | Physical container size is owned by `zip.Source.size`/the file boundary; Reader exposes bounded `read_at` rather than a C archive-state query | `G-ZIP-INIT` |
| `mz_zip_get_central_dir_size` | public definition | Superseded | The parser uses central-directory size internally to enforce `open_source(..., max_metadata)`, but the public C query itself has no SX equivalent | `G-ZIP-ENGINE` |
| `mz_zip_get_cfile` | public definition | Superseded | Borrowed `FILE *` identity is replaced by `zip.Source`, `zip.Sink`, and `std.fs`; native Reader ownership is not recoverable as a C handle | `G-ZIP-FS` |
| `mz_zip_get_error_string` | public definition | Superseded | Numeric ZIP error strings are replaced by the shared typed `compress.Error` channel | `G-ZIP-ERROR` |
| `mz_zip_get_last_error` | public definition | Superseded | The failing operation returns its error directly; reading and clearing global archive error state is intentionally absent | `G-ZIP-ERROR` |
| `mz_zip_get_mode` | public definition | Superseded | Separate `Reader` and `Writer` types make the C runtime mode enum unnecessary | `G-SURFACE` |
| `mz_zip_get_type` | public definition | Superseded | Storage backends are protocol values/factories, not a public Miniz storage-type enum | `G-SURFACE` |
| `mz_zip_is_zip64` | public definition | Public | `zip.Reader.is_zip64()` and `zip.Writer.is_zip64()` | `G-ZIP-LOOKUP` |
| `mz_zip_peek_last_error` | public definition | Superseded | Direct typed errors remove the last-error observation side channel | `G-ZIP-ERROR` |
| `mz_zip_read_archive_data` | public definition | Public | bounded archive-relative `zip.Reader.read_at`; readable writers use `zip.Writer.read_at` | `G-ZIP-INIT` |
| `mz_zip_reader_end` | public definition | Public | idempotent `zip.Reader.deinit()` | `G-ZIP-INIT` |
| `mz_zip_reader_extract_file_iter_new` | public definition | Public | Normal mode maps to `zip.Reader.stream_name(name)`; raw-compressed mode requires `find(name)` followed by `stream_compressed(index)` | `G-ZIP-SEEK` |
| `mz_zip_reader_extract_file_to_callback` | public definition | Public | `Reader.find(name)` followed by `extract_to` for decoded bytes or `extract_compressed_to` for raw compressed payload | `G-ZIP-EXTRACT` |
| `mz_zip_reader_extract_file_to_cfile` | public definition | Superseded | The `FILE *` adapter spelling is replaced by generic `zip.Sink`; after `find`, callers choose `extract_to` or `extract_compressed_to` | `G-ZIP-FS` |
| `mz_zip_reader_extract_file_to_file` | public definition | Public | Decoded extraction maps to `find` plus `extract_file`; raw-compressed path output has no file convenience and requires a caller sink with `extract_compressed_to` | `G-ZIP-FS` |
| `mz_zip_reader_extract_file_to_heap` | public definition | Public | Normal mode is allocator-owned `extract_name`; raw-compressed mode is `find(name)` plus `extract_compressed(index)` | `G-ZIP-EXTRACT` |
| `mz_zip_reader_extract_file_to_mem` | public definition | Public | Normal mode is caller-buffer `extract_name_into`; raw-compressed mode is `find(name)` plus `extract_compressed_into(index, output)` | `G-ZIP-EXTRACT` |
| `mz_zip_reader_extract_file_to_mem_no_alloc` | public definition | Superseded | `extract_name_into` retains caller-owned output, but the engine may allocate bounded scratch; Miniz's caller-supplied scratch/no-allocation contract is not retained | `G-ZIP-EXTRACT` |
| `mz_zip_reader_extract_iter_free` | public definition | Public | `zip.EntryReader.deinit()` | `G-ZIP-SEEK` |
| `mz_zip_reader_extract_iter_new` | public definition | Public | `zip.Reader.stream(index)` or `stream_compressed(index)` | `G-ZIP-SEEK` |
| `mz_zip_reader_extract_iter_read` | public definition | Public | `zip.EntryReader.read(output)` | `G-ZIP-SEEK` |
| `mz_zip_reader_extract_to_callback` | public definition | Public | `zip.Reader.extract_to` emits decoded bytes; `extract_compressed_to` separately emits raw compressed payload | `G-ZIP-EXTRACT` |
| `mz_zip_reader_extract_to_cfile` | public definition | Superseded | The `FILE *` sink adapter is replaced by public `zip.Sink` with explicit normal `extract_to` or raw `extract_compressed_to` | `G-ZIP-FS` |
| `mz_zip_reader_extract_to_file` | public definition | Public | Decoded extraction maps to `zip.Reader.extract_file`; raw-compressed path output has no file convenience and requires `extract_compressed_to` with a caller sink | `G-ZIP-FS` |
| `mz_zip_reader_extract_to_heap` | public definition | Public | `zip.Reader.extract` returns decoded bytes; `extract_compressed` separately returns raw compressed payload | `G-ZIP-EXTRACT` |
| `mz_zip_reader_extract_to_mem` | public definition | Public | `zip.Reader.extract_into` writes decoded bytes; `extract_compressed_into` separately writes raw compressed payload | `G-ZIP-EXTRACT` |
| `mz_zip_reader_extract_to_mem_no_alloc` | public definition | Superseded | `extract_into` retains caller-owned output, but the engine may allocate bounded scratch; the C no-allocation/user-read-buffer guarantee is not retained | `G-ZIP-EXTRACT` |
| `mz_zip_reader_file_stat` | public definition | Public | typed `zip.Reader.entry(index)` returning `zip.Entry` | `G-ZIP-LOOKUP` |
| `mz_zip_reader_get_filename` | public definition | Public | `zip.Reader.entry(index).name` | `G-ZIP-LOOKUP` |
| `mz_zip_reader_get_num_files` | public definition | Public | `zip.Reader.len()` | `G-ZIP-LOOKUP` |
| `mz_zip_reader_init` | public definition | Public | `zip.open_source(source, max_metadata, alloc)` | `G-ZIP-INIT` |
| `mz_zip_reader_init_cfile` | public definition | Superseded | Borrowed `FILE *` initialization is replaced by a caller-authored `zip.Source` or `zip.open_file` | `G-ZIP-FS` |
| `mz_zip_reader_init_file` | public definition | Public | `zip.open_file(path)` | `G-ZIP-INIT` |
| `mz_zip_reader_init_file_v2` | public definition | Public | `zip.open_file(path, start, size, max_metadata, alloc)` | `G-ZIP-INIT` |
| `mz_zip_reader_init_mem` | public definition | Public | `zip.open(data, alloc)` or prefix-detecting `zip.open_embedded` | `G-ZIP-INIT` |
| `mz_zip_reader_is_file_a_directory` | public definition | Public | `zip.Reader.entry(index).directory` | `G-ZIP-LOOKUP` |
| `mz_zip_reader_is_file_encrypted` | public definition | Public | `zip.Reader.entry(index).encrypted` | `G-ZIP-LOOKUP` |
| `mz_zip_reader_is_file_supported` | public definition | Public | `zip.Reader.entry(index).supported` | `G-ZIP-LOOKUP` |
| `mz_zip_reader_locate_file` | public definition | Public | exact case-sensitive first-match `zip.Reader.find(name)` | `G-ZIP-LOOKUP` |
| `mz_zip_reader_locate_file_v2` | public definition | Superseded | C case/ignore-path/sorted-search flags are not public policy; enumerate `Reader.entry` values to implement alternate lookup rules | `G-ZIP-LOOKUP` |
| `mz_zip_set_last_error` | public definition | Superseded | Operations return typed errors directly; callers cannot mutate hidden archive error state | `G-ZIP-ERROR` |
| `mz_zip_streaming_extract_begin` | public declaration only | Public | `zip.Reader.stream`, `stream_name`, or `stream_compressed` constructs a bounded `EntryReader` | `G-ZIP-SEEK` |
| `mz_zip_streaming_extract_end` | public declaration only | Public | `zip.EntryReader.deinit()` | `G-ZIP-SEEK` |
| `mz_zip_streaming_extract_get_cur_ofs` | public declaration only | Public | `zip.EntryReader.offset()` | `G-ZIP-SEEK` |
| `mz_zip_streaming_extract_get_size` | public declaration only | Public | `zip.EntryReader.len()` | `G-ZIP-SEEK` |
| `mz_zip_streaming_extract_read` | public declaration only | Public | `zip.EntryReader.read(output)` | `G-ZIP-SEEK` |
| `mz_zip_streaming_extract_seek` | public declaration only | Public | `zip.EntryReader.seek(offset)` with bounded replay for backward seeks | `G-ZIP-SEEK` |
| `mz_zip_validate_archive` | public definition | Public | `zip.Reader.validate(headers_only, alloc)` | `G-ZIP-EXTRACT` |
| `mz_zip_validate_file` | public definition | Superseded | `Reader.validate` validates the archive and extraction/streaming validates selected data, but there is no direct public one-entry validation operation or C validation-flags equivalent | `G-ZIP-EXTRACT` |
| `mz_zip_validate_file_archive` | public definition | Public | `zip.open_file(path)` followed by `Reader.validate(...)` | `G-ZIP-FS` |
| `mz_zip_validate_mem_archive` | public definition | Public | `zip.open(data)` followed by `Reader.validate(...)` | `G-ZIP-EXTRACT` |
| `mz_zip_writer_add_cfile` | public definition | Superseded | The `FILE *` source adapter is replaced by `zip.Source` plus `Writer.add_source`, or by `Writer.add_file` for paths | `G-ZIP-FS` |
| `mz_zip_writer_add_file` | public definition | Public | `zip.Writer.add_file(name, path, options)` | `G-ZIP-WRITE` |
| `mz_zip_writer_add_from_zip_reader` | public definition | Public | `zip.Writer.add_from(source_reader, index)` is the retained valid-archive transfer path; current public evidence matches compressed payload bytes, while exact full local-record preservation remains gated | `G-ZIP-WRITE` |
| `mz_zip_writer_add_mem` | public definition | Public | `zip.Writer.add(name, data)` | `G-ZIP-WRITE` |
| `mz_zip_writer_add_mem_ex` | public definition | Public | Ordinary uncompressed input maps to `zip.Writer.add(name, data, EntryOptions)`; arbitrary caller-supplied precompressed payload plus uncompressed size/CRC has no public path, while valid archive transfer uses `add_from` | `G-ZIP-WRITE` |
| `mz_zip_writer_add_mem_ex_v2` | public definition | Public | `EntryOptions.extra`, `central_extra`, metadata, descriptor, method, and level retain the ordinary-input form; arbitrary precompressed input and its size/CRC parameter path are superseded | `G-ZIP-WRITE` |
| `mz_zip_writer_add_read_buf_callback` | public definition | Public | bounded `zip.Writer.add_source(name, source, options)` | `G-ZIP-WRITE` |
| `mz_zip_writer_end` | public definition | Public | `Writer.finish` reports finalization and sink/file flush errors, then `Writer.deinit` releases resources; unlike Miniz's boolean end, deinit cannot report a final close failure | `G-ZIP-ERROR` |
| `mz_zip_writer_finalize_archive` | public definition | Public | `zip.Writer.finish(comment)` | `G-ZIP-WRITE` |
| `mz_zip_writer_finalize_heap_archive` | public definition | Public | `zip.Writer.finish(comment)` followed by ownership-transferring `take()` | `G-ZIP-WRITE` |
| `mz_zip_writer_init` | public definition | Public | `zip.Writer.init_sink(target)` maps only `existing_size == 0`; the C callback writer's nonzero existing logical-size contract has no public SX equivalent | `G-ZIP-WRITE` |
| `mz_zip_writer_init_cfile` | public definition | Superseded | Borrowed `FILE *` output is replaced by `zip.Sink` or `Writer.init_file`; no C handle leaks through stdlib | `G-ZIP-FS` |
| `mz_zip_writer_init_file` | public definition | Public | `zip.Writer.init_file(path, size_to_reserve_at_beginning)` retains the reserve-prefix argument | `G-ZIP-WRITE` |
| `mz_zip_writer_init_file_v2` | public definition | Public | `zip.Writer.init_file(path, reserve, zip64, alloc)` retains prefix reservation and forced ZIP64; other C flags map only where a typed Writer operation exists | `G-ZIP-WRITE` |
| `mz_zip_writer_init_from_reader` | public definition | Public | True in-place file conversion/append maps to `zip.Writer.append_file(path)`; `Writer.from_reader(reader)` instead creates a separate memory copy and is not the same storage transition | `G-ZIP-INPLACE` |
| `mz_zip_writer_init_from_reader_v2` | public definition | Public | `zip.Writer.append_file(path, force_zip64, ...)` is the true file-append mapping; `from_reader` remains the separate memory-copy alternative | `G-ZIP-INPLACE` |
| `mz_zip_writer_init_heap` | public definition | Public | Memory output maps to `zip.Writer.init()` plus `reserve_prefix(size_to_reserve_at_beginning)`; the C initial-allocation-capacity hint has no public equivalent | `G-ZIP-WRITE` |
| `mz_zip_writer_init_heap_v2` | public definition | Public | `zip.Writer.init(zip64)` plus `reserve_prefix(size_to_reserve_at_beginning)`; the initial-capacity hint and unsupported flag spellings are superseded | `G-ZIP-WRITE` |
| `mz_zip_writer_init_v2` | public definition | Public | `zip.Writer.init_sink(target, zip64)` maps only zero `existing_size`; typed operations replace supported flags, but no public operation adopts a pre-existing callback-output prefix | `G-ZIP-WRITE` |
| `mz_zip_zero_struct` | public definition | Superseded | By-value constructors produce valid initialized `Reader`/`Writer` values; exposing zeroed invalid C state is intentionally forbidden | `G-SURFACE` |
| `tdefl_compress` | public definition | Private | `std.internal.compress.Deflater.step_flush` is the retained resumable state machine behind public encoders | `G-TDEFL` |
| `tdefl_compress_buffer` | public definition | Private | `Deflater.step_flush` with caller windows; public entry is `deflate.Encoder.flush` | `G-TDEFL` |
| `tdefl_compress_mem_to_heap` | public definition | Public | allocator-owned `deflate.encode` | `G-TDEFL` |
| `tdefl_compress_mem_to_mem` | public definition | Public | caller-buffer `deflate.encode_into` | `G-TDEFL` |
| `tdefl_compress_mem_to_output` | public definition | Public | `deflate.Encoder` through `compress.StreamingEncoder` produces into caller-provided output windows; it is not a callback sink adapter, so callers explicitly forward produced windows and sink errors | `G-TDEFL` |
| `tdefl_compressor_alloc` | public definition | Superseded | by-value `deflate.Encoder.init(options, alloc)` replaces opaque compressor heap allocation | `G-TDEFL` |
| `tdefl_compressor_free` | public definition | Superseded | `deflate.Encoder.deinit()` releases engine allocations; encoder storage itself is caller-owned by value | `G-TDEFL` |
| `tdefl_create_comp_flags_from_zip_params` | public definition | Superseded | typed `compress.Options`, `Strategy`, and ZIP `EntryOptions` replace packed numeric flags | `G-SURFACE` |
| `tdefl_get_adler32` | public definition | Superseded | running-compressor checksum state is private; callers needing a checksum use `zlib.checksum` | `G-TDEFL` |
| `tdefl_get_prev_return_status` | public definition | Superseded | each streaming operation returns typed `compress.Progress.status`; no retained mutable numeric-status query | `G-TDEFL` |
| `tdefl_init` | public definition | Private | `std.internal.compress.Deflater.init_strategy` under public `deflate.Encoder.init` | `G-TDEFL` |
| `tdefl_write_image_to_png_file_in_memory` | public definition | Public | `png.encode(Image, EncodeOptions, alloc)` with typed format/stride | `G-PNG` |
| `tdefl_write_image_to_png_file_in_memory_ex` | public definition | Public | `png.encode(Image, EncodeOptions, alloc)`; typed metadata replaces channels/flip/pointer-out parameters | `G-PNG` |
| `tinfl_decompress` | public definition | Private | `std.internal.compress.Inflater.step` is the retained coroutine behind raw/zlib/gzip and ZIP decoders | `G-TINFL` |
| `tinfl_decompress_mem_to_callback` | public definition | Public | bounded `deflate.Decoder` via `compress.StreamingDecoder` produces caller-owned windows; callers drive any sink callback themselves, while ZIP `Reader.extract_to` is archive-specific | `G-TINFL` |
| `tinfl_decompress_mem_to_heap` | public definition | Public | allocator-owned `deflate.decode`/`zlib.decode` | `G-TINFL` |
| `tinfl_decompress_mem_to_mem` | public definition | Public | caller-buffer `deflate.decode_into`/`zlib.decode_into` | `G-TINFL` |
| `tinfl_decompressor_alloc` | public definition | Superseded | by-value `deflate.Decoder.init(max_output, alloc)` replaces opaque decompressor allocation | `G-TINFL` |
| `tinfl_decompressor_free` | public definition | Superseded | `deflate.Decoder.deinit()` releases engine storage; the decoder value is caller-owned | `G-TINFL` |

## Implementation-only definitions: 68/68 enumerated

These are the 68 definitions in the pinned C source that are not public entry
points. Together with the 118 rows above they form the complete 186-name
declaration/implementation inventory.

| Upstream identifier | Surface | Disposition | Native mapping or supersession rationale | Evidence / gate |
| --- | --- | --- | --- | --- |
| `mz_file_read_func_stdio` | private definition | Superseded | Miniz-local `FILE *` reads moved behind `zip.Source` and `std.fs`; the C callback signature is not retained | `G-FS` |
| `mz_fopen` | private definition | Superseded | Miniz-local stdio opening moved to `std.fs`; codec code does not own a second path API | `G-FS` |
| `mz_freopen` | private definition | Superseded | C stream reopening is not a codec concern; `std.fs` and explicit Reader/Writer construction own file lifetime | `G-FS` |
| `mz_stat` | private definition | Superseded | File metadata is provided by `std.fs`, outside the codec engine | `G-FS` |
| `mz_stat64` | private definition | Superseded | Native `std.fs` uses target-correct sizes; the alternate C ABI spelling is unnecessary | `G-FS` |
| `mz_utf8z_to_widechar` | private definition | Superseded | Windows path conversion belongs solely to the `std.fs` Windows backend, not to ZIP | `G-FS` |
| `mz_write_le16` | private definition | Private | private ZIP little-endian header emission | `G-ZIP-ENGINE` |
| `mz_write_le32` | private definition | Private | private ZIP little-endian header emission | `G-ZIP-ENGINE` |
| `mz_write_le64` | private definition | Private | private ZIP64 little-endian header emission | `G-ZIP-ENGINE` |
| `mz_zip_array_clear` | private definition | Private | allocator-backed private metadata/entry lists with explicit teardown | `G-ZIP-ENGINE` |
| `mz_zip_array_ensure_capacity` | private definition | Private | private list capacity growth using the owning allocator | `G-ZIP-ENGINE` |
| `mz_zip_array_ensure_room` | private definition | Private | private bounded list growth before append | `G-ZIP-ENGINE` |
| `mz_zip_array_init` | private definition | Private | by-value private metadata/entry list initialization | `G-ZIP-ENGINE` |
| `mz_zip_array_push_back` | private definition | Private | private central/entry list append | `G-ZIP-ENGINE` |
| `mz_zip_array_range_check` | private definition | Private | checked slice/range arithmetic in the ZIP parser/writer | `G-ZIP-ENGINE` |
| `mz_zip_array_reserve` | private definition | Private | private list reservation through the captured allocator | `G-ZIP-ENGINE` |
| `mz_zip_array_resize` | private definition | Private | private checked metadata/entry list resizing | `G-ZIP-ENGINE` |
| `mz_zip_compute_crc32_callback` | private definition | Private | CRC accumulation in the private bounded extraction sink | `G-ZIP-EXTRACT` |
| `mz_zip_dos_to_time_t` | private definition | Private | private DOS-to-native timestamp conversion feeding typed `Entry.modified_seconds` | `G-ZIP-FS` |
| `mz_zip_file_read_func` | private definition | Private | private `std.fs`-backed implementation of public `zip.Source` semantics | `G-ZIP-FS` |
| `mz_zip_file_stat_internal` | private definition | Private | private central/local record parsing into public `zip.Entry` metadata | `G-ZIP-LOOKUP` |
| `mz_zip_file_write_callback` | private definition | Private | sequential extraction-to-file sink behind decoded `Reader.extract_file`; raw-compressed output instead requires a caller `Sink`, and this is not the archive writer's random-access callback | `G-ZIP-FS` |
| `mz_zip_file_write_func` | private definition | Private | seekable archive-output callback behind `Writer.init_file`/`append_file`, including offset and short-write handling | `G-ZIP-FS` |
| `mz_zip_filename_compare` | private definition | Superseded | The public policy is exact case-sensitive first match; alternate C comparison flags are caller policy over enumerated entries | `G-ZIP-LOOKUP` |
| `mz_zip_get_cdh` | private definition | Private | private checked central-directory header lookup | `G-ZIP-ENGINE` |
| `mz_zip_get_file_modified_time` | private definition | Public | `std.fs.modified_seconds(file)` supplies the value; `EntryOptions.use_file_modified_time` requests it without exposing a ZIP-local helper | `G-FS` |
| `mz_zip_heap_write_func` | private definition | Private | private memory-backed ZIP sink used by `Writer.init` and `take` | `G-ZIP-WRITE` |
| `mz_zip_locate_file_binary_search` | private definition | Superseded | Sorted/binary lookup was a C flag-controlled policy; `Reader.find` guarantees exact first match and callers may enumerate for other policy | `G-ZIP-LOOKUP` |
| `mz_zip_mem_read_func` | private definition | Private | borrowed memory source behind `zip.open`/`open_embedded` | `G-ZIP-INIT` |
| `mz_zip_reader_end_internal` | private definition | Private | private idempotent Reader teardown behind `Reader.deinit` | `G-ZIP-INIT` |
| `mz_zip_reader_eocd64_valid` | private definition | Private | checked ZIP64 locator/EOCD validation | `G-ZIP-ENGINE` |
| `mz_zip_reader_extract_to_mem_no_alloc1` | private definition | Private | common bounded stored/DEFLATE/raw extraction engine behind `extract*`, sinks, and `EntryReader` | `G-ZIP-EXTRACT` |
| `mz_zip_reader_filename_less` | private definition | Superseded | Filename sort ordering supported C binary lookup; the idiomatic public Reader preserves archive order and exact first-match lookup | `G-ZIP-LOOKUP` |
| `mz_zip_reader_init_internal` | private definition | Private | common bounded Reader initialization behind memory/source/file factories | `G-ZIP-INIT` |
| `mz_zip_reader_locate_header_sig` | private definition | Private | bounded backward EOCD/ZIP64 signature scanning | `G-ZIP-ENGINE` |
| `mz_zip_reader_read_central_dir` | private definition | Private | bounded central-directory parse and retained metadata construction | `G-ZIP-ENGINE` |
| `mz_zip_reader_sort_central_dir_offsets_by_filename` | private definition | Superseded | Public lookup does not sort or expose Miniz's do-not-sort flag; archive order and duplicate first-match semantics are retained | `G-ZIP-LOOKUP` |
| `mz_zip_set_error` | private definition | Superseded | Typed operation errors replace mutation of archive-global numeric error state | `G-ZIP-ERROR` |
| `mz_zip_set_file_times` | private definition | Public | `std.fs.set_modified_seconds(path, seconds)` and `Reader.extract_file` restore modification time only; Miniz's setting of both access and modification time is not retained | `G-FS` |
| `mz_zip_string_equal` | private definition | Superseded | C case/ignore-path comparison flags are replaced by exact `Reader.find` plus caller-defined policy over entries | `G-ZIP-LOOKUP` |
| `mz_zip_time_t_to_dos_time` | private definition | Private | private native-to-DOS timestamp conversion for deterministic local/central headers | `G-ZIP-WRITE` |
| `mz_zip_writer_add_put_buf_callback` | private definition | Private | private compressor-output sink into sequential/random-access ZIP writers | `G-ZIP-WRITE` |
| `mz_zip_writer_add_to_central_dir` | private definition | Private | private central-directory metadata accumulation | `G-ZIP-WRITE` |
| `mz_zip_writer_compute_padding_needed_for_file_alignment` | private definition | Private | private alignment calculation behind `Writer.set_alignment` | `G-ZIP-WRITE` |
| `mz_zip_writer_create_central_dir_header` | private definition | Private | exact private central-directory header emission | `G-ZIP-WRITE` |
| `mz_zip_writer_create_local_dir_header` | private definition | Private | exact private local-header emission | `G-ZIP-WRITE` |
| `mz_zip_writer_create_zip64_extra_data` | private definition | Private | exact private ZIP64 extra-field construction | `G-ZIP-WRITE` |
| `mz_zip_writer_end_internal` | private definition | Private | private resource cleanup remains behind `Writer.deinit`; finalization/flush errors are returned by `finish`, but deinit-time close failure is not observable as in the C boolean end path | `G-ZIP-ERROR` |
| `mz_zip_writer_update_zip64_extension_block` | private definition | Private | private ZIP64 EOCD/locator finalization | `G-ZIP-WRITE` |
| `mz_zip_writer_validate_archive_name` | private definition | Private | private entry-name validation behind `Writer.add*` | `G-ZIP-WRITE` |
| `mz_zip_writer_write_zeros` | private definition | Private | exact prefix/alignment zero emission | `G-ZIP-WRITE` |
| `tdefl_calculate_minimum_redundancy` | private definition | Private | private Miniz-compatible Huffman tree length construction | `G-DEFLATE-ENGINE` |
| `tdefl_compress_block` | private definition | Private | private compressed-block selection/emission | `G-DEFLATE-ENGINE` |
| `tdefl_compress_fast` | private definition | Private | retained level-1 fast parser and 4 KiB hash path | `G-DEFLATE-ENGINE` |
| `tdefl_compress_lz_codes` | private definition | Private | packed literal/match token emission into fixed/dynamic Huffman blocks | `G-DEFLATE-ENGINE` |
| `tdefl_compress_normal` | private definition | Private | retained normal rolling-hash chain and greedy/lazy parser | `G-DEFLATE-ENGINE` |
| `tdefl_find_match` | private definition | Private | retained bounded Miniz-compatible match search | `G-DEFLATE-ENGINE` |
| `tdefl_flush_block` | private definition | Private | retained stored/fixed/dynamic selection and flush state | `G-DEFLATE-ENGINE` |
| `tdefl_flush_output_buffer` | private definition | Private | retained resumable caller-window/output draining | `G-DEFLATE-ENGINE` |
| `tdefl_huffman_enforce_max_code_size` | private definition | Private | retained DEFLATE maximum-code-length enforcement | `G-DEFLATE-ENGINE` |
| `tdefl_optimize_huffman_table` | private definition | Private | retained frequency optimization and canonical table construction | `G-DEFLATE-ENGINE` |
| `tdefl_output_buffer_putter` | private definition | Private | private output-sink adapter/drain behavior behind typed streaming encoders | `G-DEFLATE-ENGINE` |
| `tdefl_radix_sort_syms` | private definition | Private | retained stable two-pass symbol radix sort used for exact dynamic blocks | `G-DEFLATE-ENGINE` |
| `tdefl_record_literal` | private definition | Private | retained packed literal-token recording | `G-DEFLATE-ENGINE` |
| `tdefl_record_match` | private definition | Private | retained packed length/distance-token recording | `G-DEFLATE-ENGINE` |
| `tdefl_start_dynamic_block` | private definition | Private | retained dynamic block header/tree construction | `G-DEFLATE-ENGINE` |
| `tdefl_start_static_block` | private definition | Private | retained fixed block construction and stored fallback policy | `G-DEFLATE-ENGINE` |
| `tinfl_clear_tree` | private definition | Private | private Huffman table/tree reset in `std.internal.compress.Inflater` | `G-INFLATE-ENGINE` |

## Compile-time configuration identifiers: 18/18 enumerated

SX uses modules, explicit allocators/protocols, and dead-code elimination
rather than mirroring Miniz's preprocessor ABI. The machine switches below
identify private behavior that must be proven; they do not assert that the
current implementation already has equivalent endian, unaligned, memcpy, or
32/64-bit paths. Feature-elision and declaration switches are explicitly
superseded and retain fail-closed gates.

| Upstream identifier | Disposition | Native mapping or supersession rationale | Evidence / gate |
| --- | --- | --- | --- |
| `MINIZ_DISABLE_ZIP_READER_CRC32_CHECKS` | Superseded | Decoded public extraction is specified to validate CRC, while raw-compressed payload operations do not decode it; there is no process-wide disable switch. Public negative CRC evidence is 1718's terminal-checksum and `finish()` tests | `G-ZIP-EXTRACT` |
| `MINIZ_EXPORT` | Superseded | SX module visibility controls public names; no C export annotation or ABI surface is retained | `G-SURFACE` |
| `MINIZ_HAS_64BIT_REGISTERS` | Private | Requirement: prove the SX engine on both 32-bit and 64-bit targets against the archived bit-buffer/token variants; equivalent target selection is not yet established | `G-DEFLATE-ENGINE`, `G-INFLATE-ENGINE` |
| `MINIZ_HEADER_FILE_ONLY` | Superseded | SX modules are single-definition import units; header/implementation amalgamation has no native analogue | `G-SURFACE` |
| `MINIZ_LITTLE_ENDIAN` | Private | Requirement: prove target-independent wire bytes and decode traces, including a non-little-endian target or equivalent cross-target evidence; current host results alone are insufficient | `G-DEFLATE-ENGINE`, `G-INFLATE-ENGINE`, `G-ZIP-ENGINE` |
| `MINIZ_NO_ARCHIVE_APIS` | Superseded | Import only the codec modules needed; ZIP lives in its own `std.codecs` module and dead code is eliminated | `G-SURFACE` |
| `MINIZ_NO_ARCHIVE_WRITING_APIS` | Superseded | Reader-only consumers do not use Writer declarations; no preprocessor-built alternate library is required | `G-SURFACE` |
| `MINIZ_NO_DEFLATE_APIS` | Superseded | Module imports/dead-code elimination replace compile-time removal of public DEFLATE declarations | `G-SURFACE` |
| `MINIZ_NO_INFLATE_APIS` | Superseded | Module imports/dead-code elimination replace compile-time removal of public inflate declarations | `G-SURFACE` |
| `MINIZ_NO_MALLOC` | Superseded | Every allocating SX operation accepts an explicit `Allocator`; caller-buffer and streaming APIs avoid owned results, so no global malloc mode exists | `G-SURFACE` |
| `MINIZ_NO_STDIO` | Superseded | Core codecs and protocol-backed ZIP are filesystem-independent; path operations enter through `std.fs` | `G-FS`, `G-SURFACE` |
| `MINIZ_NO_TIME` | Superseded | Timestamps are typed optional metadata and file-time behavior lives in `std.fs`; callers can omit it without rebuilding the codec | `G-FS`, `G-SURFACE` |
| `MINIZ_NO_ZLIB_APIS` | Superseded | Raw DEFLATE and zlib are separate modules; importing raw DEFLATE does not require a preprocessor variant | `G-SURFACE` |
| `MINIZ_NO_ZLIB_COMPATIBLE_NAME` | Superseded | SX introduces no ambient zlib-compatible C aliases; names stay within typed modules | `G-SURFACE` |
| `MINIZ_NO_ZLIB_COMPATIBLE_NAMES` | Superseded | Alternate upstream spelling of the same alias-elision policy; SX module namespaces make it unconditional | `G-SURFACE` |
| `MINIZ_UNALIGNED_USE_MEMCPY` | Private | Requirement: compare current SX behavior with the archived memcpy-load C configuration; no equivalent SX memcpy machine path is presently claimed | `G-DEFLATE-ENGINE`, `G-INFLATE-ENGINE` |
| `MINIZ_USE_UNALIGNED_LOADS_AND_STORES` | Private | Requirement: prove optimized and portable target behavior against the archived unaligned-load configuration; current host output does not establish a distinct legal path | `G-DEFLATE-ENGINE`, `G-INFLATE-ENGINE` |
| `MINIZ_X86_OR_X64_CPU` | Private | Requirement: prove architecture-dependent optimized behavior and portable fallback on applicable targets; no complete SX architecture-selection claim is made yet | `G-DEFLATE-ENGINE`, `G-INFLATE-ENGINE` |

## Completion state

This manifest closes inventory omission, not behavioral proof. All names have
a disposition: 85 map to retained public SX behavior, 58 to retained private
engine behavior, and 43 are explicitly superseded C-only spellings. Of the 18
configuration identifiers, five select retained private behavior and 13 are
superseded. Every `G-*` key above still contains at least one fresh
final-tree gate. The migration therefore remains **open** until those gates,
the full compiler corpus, the final benchmark rerun, dependency/target audits,
and independent adversarial review pass. A superseded row is complete only as
a design disposition after its namespace/module-boundary gate passes; it must
not be reclassified as “implemented C compatibility.”
