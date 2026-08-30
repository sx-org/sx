# Miniz-to-stdlib crosswalk

Where each entry point of the Miniz 3.1.2 C API lands in the SX standard
library. The pinned upstream is commit
`77d0dce8627735138c51770d1799a1ef48f2117d`; the SX codecs reimplement it in SX
and produce byte-identical output, so this is a porting map, not a
compatibility layer. The library-level guide is
[Compression, PNG, and ZIP](compression.md).

A row states one of three things: the idiomatic SX operation that does the same
work; that the behavior lives inside the engine with no public spelling; or
that only a C ABI, numeric status, global last-error, `FILE *` adapter, or flag
word is involved, in which case it names the replacement or says there is none.

## Public entry points

| Miniz entry point | SX equivalent |
| --- | --- |
| `mz_adler32` | `zlib.checksum(data, initial)` |
| `mz_compress` | `zlib.encode(data)` |
| `mz_compress2` | `zlib.encode(data, .{ level = ... })` |
| `mz_compressBound` | `zlib.bound(sourceLen)` |
| `mz_crc32` | `gzip.checksum(data, initial)` |
| `mz_deflate` | `zlib.Encoder.write/flush/finish`, returning typed `compress.Progress` |
| `mz_deflateBound` | `zlib.bound(sourceLen)` |
| `mz_deflateEnd` | `zlib.Encoder.deinit()` |
| `mz_deflateInit` | by-value `zlib.Encoder.init()` |
| `mz_deflateInit2` | `zlib.Encoder.init(options)` or raw `deflate.Encoder.init(options)`; numeric method/window/memory arguments are replaced by the selected typed codec |
| `mz_deflateReset` | `zlib.Encoder.reset(options)` |
| `mz_error` | Numeric zlib/miniz codes and string lookup are replaced by `compress.Error`; no global integer-to-string API is exported |
| `mz_free` | Owned results are released through the `Allocator` that created them; a library-global free function would lose ownership identity |
| `mz_inflate` | `zlib.Decoder.read/finish`, returning typed `compress.Progress` |
| `mz_inflateEnd` | `zlib.Decoder.deinit()` |
| `mz_inflateInit` | by-value `zlib.Decoder.init()` |
| `mz_inflateInit2` | `zlib.Decoder.init()` or raw `deflate.Decoder.init()`; framing selection replaces numeric window bits |
| `mz_inflateReset` | `zlib.Decoder.reset(maxOutput)` |
| `mz_uncompress` | strict `zlib.decode`/`zlib.decodeInto` |
| `mz_uncompress2` | `zlib.decodePrefix`/`decodeIntoPrefix`, whose `DecodeResult.consumed` replaces the in/out source-length pointer |
| `mz_version` | This is a pinned implementation source, not a C compatibility library; SX stdlib exposes no Miniz runtime-version symbol |
| `mz_zip_add_mem_to_archive_file_in_place` | `zip.Writer.appendFile`, `add`, and `finish` |
| `mz_zip_add_mem_to_archive_file_in_place_v2` | `zip.Writer.appendFile`, typed `EntryOptions`, explicit archive comment in `finish`, and error channels replace boolean/error-out parameters |
| `mz_zip_clear_last_error` | SX errors are returned/raised on the operation; there is no mutable last-error side channel to clear |
| `mz_zip_end` | `zip.Reader.deinit()` or `zip.Writer.deinit()` supplies cleanup; writer finalization/flush errors must be observed from `Writer.finish`, while deinit-time close failure is not reportable |
| `mz_zip_extract_archive_file_to_heap` | `zip.openFile`, exact `Reader.find`, then allocator-owned `Reader.extract` or `extractCompressed` according to the typed operation |
| `mz_zip_extract_archive_file_to_heap_v2` | Exact-name normal/raw extraction maps to `openFile` plus `find` and `extract`/`extractCompressed`; there is no comment matching, alternate lookup flag, or error-out parameter |
| `mz_zip_get_archive_file_start_offset` | Container offsets are inputs to `zip.openFile(start, size)` or discovered by `openEmbedded`; Reader does not expose C storage-layout state |
| `mz_zip_get_archive_size` | Physical container size is owned by `zip.Source.size`/the file boundary; Reader exposes bounded `readAt` rather than a C archive-state query |
| `mz_zip_get_central_dir_size` | The parser uses central-directory size internally to enforce `openSource(..., maxMetadata)`, but the public C query itself has no SX equivalent |
| `mz_zip_get_cfile` | Borrowed `FILE *` identity is replaced by `zip.Source`, `zip.Sink`, and `std.fs`; native Reader ownership is not recoverable as a C handle |
| `mz_zip_get_error_string` | Numeric ZIP error strings are replaced by the shared typed `compress.Error` channel |
| `mz_zip_get_last_error` | The failing operation returns its error directly; there is no global archive error state to read or clear |
| `mz_zip_get_mode` | Separate `Reader` and `Writer` types make the C runtime mode enum unnecessary |
| `mz_zip_get_type` | Storage backends are interface handles and factories, not a public Miniz storage-type enum |
| `mz_zip_is_zip64` | `zip.Reader.isZip64()` and `zip.Writer.isZip64()` |
| `mz_zip_peek_last_error` | Direct typed errors remove the last-error observation side channel |
| `mz_zip_read_archive_data` | bounded archive-relative `zip.Reader.readAt`; readable writers use `zip.Writer.readAt` |
| `mz_zip_reader_end` | idempotent `zip.Reader.deinit()` |
| `mz_zip_reader_extract_file_iter_new` | Normal mode maps to `zip.Reader.streamName(name)`; raw-compressed mode requires `find(name)` followed by `streamCompressed(index)` |
| `mz_zip_reader_extract_file_to_callback` | `Reader.find(name)` followed by `extractTo` for decoded bytes or `extractCompressedTo` for raw compressed payload |
| `mz_zip_reader_extract_file_to_cfile` | The `FILE *` adapter spelling is replaced by generic `zip.Sink`; after `find`, callers choose `extractTo` or `extractCompressedTo` |
| `mz_zip_reader_extract_file_to_file` | Decoded extraction maps to `find` plus `extractFile`; raw-compressed path output has no file convenience and requires a caller sink with `extractCompressedTo` |
| `mz_zip_reader_extract_file_to_heap` | Normal mode is allocator-owned `extractName`; raw-compressed mode is `find(name)` plus `extractCompressed(index)` |
| `mz_zip_reader_extract_file_to_mem` | Normal mode is caller-buffer `extractNameInto`; raw-compressed mode is `find(name)` plus `extractCompressedInto(index, output)` |
| `mz_zip_reader_extract_file_to_mem_no_alloc` | `extractNameInto` writes into caller-owned output, but the engine may allocate bounded scratch; there is no caller-supplied-scratch, zero-allocation form |
| `mz_zip_reader_extract_iter_free` | `zip.EntryReader.deinit()` |
| `mz_zip_reader_extract_iter_new` | `zip.Reader.stream(index)` or `streamCompressed(index)` |
| `mz_zip_reader_extract_iter_read` | `zip.EntryReader.read(output)` |
| `mz_zip_reader_extract_to_callback` | `zip.Reader.extractTo` emits decoded bytes; `extractCompressedTo` separately emits raw compressed payload |
| `mz_zip_reader_extract_to_cfile` | The `FILE *` sink adapter is replaced by public `zip.Sink` with explicit normal `extractTo` or raw `extractCompressedTo` |
| `mz_zip_reader_extract_to_file` | Decoded extraction maps to `zip.Reader.extractFile`; raw-compressed path output has no file convenience and requires `extractCompressedTo` with a caller sink |
| `mz_zip_reader_extract_to_heap` | `zip.Reader.extract` returns decoded bytes; `extractCompressed` separately returns raw compressed payload |
| `mz_zip_reader_extract_to_mem` | `zip.Reader.extractInto` writes decoded bytes; `extractCompressedInto` separately writes raw compressed payload |
| `mz_zip_reader_extract_to_mem_no_alloc` | `extractInto` writes into caller-owned output, but the engine may allocate bounded scratch; there is no zero-allocation, caller-read-buffer form |
| `mz_zip_reader_file_stat` | typed `zip.Reader.entry(index)` returning `zip.Entry` |
| `mz_zip_reader_get_filename` | `zip.Reader.entry(index).name` |
| `mz_zip_reader_get_num_files` | `zip.Reader.len()` |
| `mz_zip_reader_init` | `zip.openSource(source, maxMetadata, alloc)` |
| `mz_zip_reader_init_cfile` | Borrowed `FILE *` initialization is replaced by a caller-authored `zip.Source` or `zip.openFile` |
| `mz_zip_reader_init_file` | `zip.openFile(path)` |
| `mz_zip_reader_init_file_v2` | `zip.openFile(path, start, size, maxMetadata, alloc)` |
| `mz_zip_reader_init_mem` | `zip.open(data, alloc)` or prefix-detecting `zip.openEmbedded` |
| `mz_zip_reader_is_file_a_directory` | `zip.Reader.entry(index).directory` |
| `mz_zip_reader_is_file_encrypted` | `zip.Reader.entry(index).encrypted` |
| `mz_zip_reader_is_file_supported` | `zip.Reader.entry(index).supported` |
| `mz_zip_reader_locate_file` | exact case-sensitive first-match `zip.Reader.find(name)` |
| `mz_zip_reader_locate_file_v2` | C case/ignore-path/sorted-search flags are not public policy; enumerate `Reader.entry` values to implement alternate lookup rules |
| `mz_zip_set_last_error` | Operations return typed errors directly; callers cannot mutate hidden archive error state |
| `mz_zip_streaming_extract_begin` | `zip.Reader.stream`, `streamName`, or `streamCompressed` constructs a bounded `EntryReader` |
| `mz_zip_streaming_extract_end` | `zip.EntryReader.deinit()` |
| `mz_zip_streaming_extract_get_cur_ofs` | `zip.EntryReader.offset()` |
| `mz_zip_streaming_extract_get_size` | `zip.EntryReader.len()` |
| `mz_zip_streaming_extract_read` | `zip.EntryReader.read(output)` |
| `mz_zip_streaming_extract_seek` | `zip.EntryReader.seek(offset)` with bounded replay for backward seeks |
| `mz_zip_validate_archive` | `zip.Reader.validate(headersOnly, alloc)` |
| `mz_zip_validate_file` | `Reader.validate` validates the archive and extraction/streaming validates selected data, but there is no direct public one-entry validation operation or C validation-flags equivalent |
| `mz_zip_validate_file_archive` | `zip.openFile(path)` followed by `Reader.validate(...)` |
| `mz_zip_validate_mem_archive` | `zip.open(data)` followed by `Reader.validate(...)` |
| `mz_zip_writer_add_cfile` | The `FILE *` source adapter is replaced by `zip.Source` plus `Writer.addSource`, or by `Writer.addFile` for paths |
| `mz_zip_writer_add_file` | `zip.Writer.addFile(name, path, options)` |
| `mz_zip_writer_add_from_zip_reader` | `zip.Writer.addFrom(source, index)` transfers an entry of a valid archive without recompressing it |
| `mz_zip_writer_add_mem` | `zip.Writer.add(name, data)` |
| `mz_zip_writer_add_mem_ex` | Ordinary uncompressed input maps to `zip.Writer.add(name, data, EntryOptions)`; arbitrary caller-supplied precompressed payload plus uncompressed size/CRC has no public path, while valid archive transfer uses `addFrom` |
| `mz_zip_writer_add_mem_ex_v2` | `EntryOptions.extra`, `centralExtra`, metadata, descriptor, method, and level cover the ordinary-input form; there is no path for arbitrary precompressed input with a caller-supplied size and CRC |
| `mz_zip_writer_add_read_buf_callback` | bounded `zip.Writer.addSource(name, source, options)` |
| `mz_zip_writer_end` | `Writer.finish` reports finalization and sink/file flush errors, then `Writer.deinit` releases resources; unlike Miniz's boolean end, deinit cannot report a final close failure |
| `mz_zip_writer_finalize_archive` | `zip.Writer.finish(comment)` |
| `mz_zip_writer_finalize_heap_archive` | `zip.Writer.finish(comment)` followed by ownership-transferring `take()` |
| `mz_zip_writer_init` | `zip.Writer.initSink(target)` maps only `existing_size == 0`; the C callback writer's nonzero existing logical-size contract has no public SX equivalent |
| `mz_zip_writer_init_cfile` | Borrowed `FILE *` output is replaced by `zip.Sink` or `Writer.initFile`; no C handle leaks through stdlib |
| `mz_zip_writer_init_file` | `zip.Writer.initFile(path, .{ reserve = n })` |
| `mz_zip_writer_init_file_v2` | `zip.Writer.initFile(path, .{ reserve = n, zip64 = z }, alloc)`; other C flags map only where a typed `Writer` operation exists |
| `mz_zip_writer_init_from_reader` | True in-place file conversion/append maps to `zip.Writer.appendFile(path)`; `Writer.fromReader(reader)` instead creates a separate memory copy and is not the same storage transition |
| `mz_zip_writer_init_from_reader_v2` | `zip.Writer.appendFile(path, forceZip64, ...)` is the true file-append mapping; `fromReader` is the separate memory-copy alternative |
| `mz_zip_writer_init_heap` | Memory output maps to `zip.Writer.init()` plus `reservePrefix(size)`; the C initial-allocation-capacity hint has no public equivalent |
| `mz_zip_writer_init_heap_v2` | `zip.Writer.init(zip64)` plus `reservePrefix(size)`; there is no initial-capacity hint |
| `mz_zip_writer_init_v2` | `zip.Writer.initSink(target, zip64)` maps only zero `existing_size`; typed operations replace supported flags, but no public operation adopts a pre-existing callback-output prefix |
| `mz_zip_zero_struct` | By-value constructors produce valid initialized `Reader`/`Writer` values; zeroed invalid C state has no spelling |
| `tdefl_compress` | Internal. `std.internal.compress.Deflater.stepFlush` is the resumable state machine behind the public encoders |
| `tdefl_compress_buffer` | Internal. `Deflater.stepFlush` over caller windows; the public entry is `deflate.Encoder.flush` |
| `tdefl_compress_mem_to_heap` | allocator-owned `deflate.encode` |
| `tdefl_compress_mem_to_mem` | caller-buffer `deflate.encodeInto` |
| `tdefl_compress_mem_to_output` | `deflate.Encoder` through `compress.StreamingEncoder` produces into caller-provided output windows; it is not a callback sink adapter, so callers explicitly forward produced windows and sink errors |
| `tdefl_compressor_alloc` | by-value `deflate.Encoder.init(options, alloc)` replaces opaque compressor heap allocation |
| `tdefl_compressor_free` | `deflate.Encoder.deinit()` releases engine allocations; encoder storage itself is caller-owned by value |
| `tdefl_create_comp_flags_from_zip_params` | typed `compress.Options`, `Strategy`, and ZIP `EntryOptions` replace packed numeric flags |
| `tdefl_get_adler32` | running-compressor checksum state is private; callers needing a checksum use `zlib.checksum` |
| `tdefl_get_prev_return_status` | Each streaming operation returns a typed `compress.Progress.status`; there is no mutable numeric-status query |
| `tdefl_init` | Internal. `std.internal.compress.Deflater.initStrategy` under public `deflate.Encoder.init` |
| `tdefl_write_image_to_png_file_in_memory` | `png.encode(Image, EncodeOptions, alloc)` with typed format/stride |
| `tdefl_write_image_to_png_file_in_memory_ex` | `png.encode(Image, EncodeOptions, alloc)`; typed metadata replaces channels/flip/pointer-out parameters |
| `tinfl_decompress` | Internal. `std.internal.compress.Inflater.step` is the coroutine behind the raw/zlib/gzip and ZIP decoders |
| `tinfl_decompress_mem_to_callback` | bounded `deflate.Decoder` via `compress.StreamingDecoder` produces caller-owned windows; callers drive any sink callback themselves, while ZIP `Reader.extractTo` is archive-specific |
| `tinfl_decompress_mem_to_heap` | allocator-owned `deflate.decode`/`zlib.decode` |
| `tinfl_decompress_mem_to_mem` | caller-buffer `deflate.decodeInto`/`zlib.decodeInto` |
| `tinfl_decompressor_alloc` | by-value `deflate.Decoder.init(maxOutput, alloc)` replaces opaque decompressor allocation |
| `tinfl_decompressor_free` | `deflate.Decoder.deinit()` releases engine storage; the decoder value is caller-owned |

## Compile-time configuration

SX uses modules, explicit allocators and interfaces, and dead-code elimination
where Miniz uses the preprocessor.

| Miniz macro | SX equivalent |
| --- | --- |
| `MINIZ_DISABLE_ZIP_READER_CRC32_CHECKS` | Decoded extraction always validates the CRC; raw-compressed payload operations do not decode, so they do not check it. There is no process-wide disable switch. |
| `MINIZ_EXPORT` | SX module visibility controls public names; there is no C export annotation or ABI surface. |
| `MINIZ_HAS_64BIT_REGISTERS` | No equivalent. The engine is a single portable path with no build-time machine selection. |
| `MINIZ_HEADER_FILE_ONLY` | SX modules are single-definition import units; header/implementation amalgamation has no native analogue |
| `MINIZ_LITTLE_ENDIAN` | No equivalent. The engine is a single portable path with no build-time machine selection. |
| `MINIZ_NO_ARCHIVE_APIS` | Import only the codec modules needed; ZIP lives in its own `std.codecs` module and dead code is eliminated |
| `MINIZ_NO_ARCHIVE_WRITING_APIS` | Reader-only consumers do not use Writer declarations; no preprocessor-built alternate library is required |
| `MINIZ_NO_DEFLATE_APIS` | Module imports/dead-code elimination replace compile-time removal of public DEFLATE declarations |
| `MINIZ_NO_INFLATE_APIS` | Module imports/dead-code elimination replace compile-time removal of public inflate declarations |
| `MINIZ_NO_MALLOC` | Every allocating SX operation accepts an explicit `Allocator`; caller-buffer and streaming APIs avoid owned results, so no global malloc mode exists |
| `MINIZ_NO_STDIO` | Core codecs and interface-backed ZIP are filesystem-independent; path operations enter through `std.fs` |
| `MINIZ_NO_TIME` | Timestamps are typed optional metadata and file-time behavior lives in `std.fs`; callers can omit it without rebuilding the codec |
| `MINIZ_NO_ZLIB_APIS` | Raw DEFLATE and zlib are separate modules; importing raw DEFLATE does not require a preprocessor variant |
| `MINIZ_NO_ZLIB_COMPATIBLE_NAME` | SX introduces no ambient zlib-compatible C aliases; names stay within typed modules |
| `MINIZ_NO_ZLIB_COMPATIBLE_NAMES` | Alternate upstream spelling of the same alias-elision policy; SX module namespaces make it unconditional |
| `MINIZ_UNALIGNED_USE_MEMCPY` | No equivalent. The engine is a single portable path with no build-time machine selection. |
| `MINIZ_USE_UNALIGNED_LOADS_AND_STORES` | No equivalent. The engine is a single portable path with no build-time machine selection. |
| `MINIZ_X86_OR_X64_CPU` | No equivalent. The engine is a single portable path with no build-time machine selection. |
