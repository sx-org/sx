# Compression, PNG, and ZIP

SX ships dependency-free implementations of raw DEFLATE, zlib, gzip, PNG
encoding, and ZIP32/ZIP64 archives. Import `modules/std.sx` and use the
separate `deflate`, `zlib`, `gzip`, `png`, and `zip` namespaces.
`std.compress` is only their shared contract layer; it is not another codec.

```sx
#import "modules/std.sx";

packed := try gzip.encode("hello");
defer context.allocator.dealloc_bytes(packed.ptr);

plain := try gzip.decode(packed, 1024);
defer context.allocator.dealloc_bytes(plain.ptr);
```

The implementation does not import a C codec or use a system compression
library. Its deterministic output is pinned to miniz 3.1.2 commit
`77d0dce8627735138c51770d1799a1ef48f2117d`.

## Shared contracts

`compress.Options` selects a compression `level` from 0 through 10 and a
`Strategy`. The default is level 6 with the default strategy. Invalid levels
raise `error.InvalidOptions`; there is no C-style `-1` default or numeric flag
word.

DEFLATE, zlib, gzip, and ZIP reuse `compress.Error` directly:

- `InvalidArgument` and `InvalidOptions` reject caller mistakes (a negative
  limit or size, a null sink function, an out-of-range or contradictory
  option) before any work happens;
- `InvalidData`, `UnexpectedEnd`, and `ChecksumMismatch` describe malformed
  ENCODED input — they are never raised for argument or option errors;
- `Unsupported` describes a format feature the codec can inspect but cannot
  process;
- `OutputLimit` and `TooLarge` enforce caller-selected and format limits;
- `NotFound`, `Finished`, and `Io` describe archive/lifecycle/I/O failures;
- `AllocationFailed` reports allocator failure.

`compress.Progress` reports how much of the caller's input and output windows
was consumed or initialized, followed by `need_input`, `need_output`, or
`done`. `compress.StreamingEncoder` and `StreamingDecoder` provide the common
bounded streaming behavior implemented by each concrete codec state.

## Ownership and limits

Allocating codec operations return storage owned by the allocator passed to
the call, defaulting to `context.allocator`. Release `result.ptr` through that
same allocator. An allocating operation never uses a null string as its public
failure result; allocation failure uses the error channel.

Functions ending in `_into` initialize a prefix of caller-owned storage and
return a borrowed slice into that storage. Do not deallocate that slice.

Decoding and extraction operations default to a 1 GiB output limit. Pass a
smaller application-specific limit for untrusted input. ZIP source/file opens
also take a metadata limit, which defaults to 64 MiB and bounds retained
central-directory, name, extra, and comment data. Streaming codec state owns
bounded working memory and must be released with `deinit`; repeated `deinit`
is safe. Initialized encoder, decoder, reader, writer, and entry-reader values
own or borrow state and must not be copied; pass pointers when sharing them.

## DEFLATE, zlib, and gzip

Each format exposes `Encoder`, `Decoder`, `encode`, `encode_into`, `decode`,
`decode_into`, and `bound`. Raw DEFLATE and zlib additionally expose prefix
decoding. Their ordinary `decode` and `decode_into` operations reject trailing
bytes; the corresponding `decode_prefix` and `decode_into_prefix` operations
return both the decoded bytes and the compressed byte count when a stream is
embedded in a larger input.

`zlib.checksum` is Adler-32 and `gzip.checksum` is CRC-32; both take and
return `u32` and accept an optional prior checksum for incremental updates.
`gzip.Header` describes gzip-only metadata such as filename, comment, extra
bytes, timestamp, operating-system identifier, text flag, and the optional
FHCRC header checksum (`header_checksum`). Its
string fields are borrowed for an `encode` call; `Encoder.init` and `reset`
copy them into encoder-owned state before returning.

A streaming state operates only on the windows supplied to each call:

```sx
encoder := try deflate.Encoder.init(.{ level = 6 });
defer encoder.deinit();

input_at := 0;
output_at := 0;
while true {
    input : string = "";
    if input_at < source.len { input = source[input_at..]; }
    output := destination[output_at..];
    progress := try encoder.flush(input, output, .finish);
    input_at += progress.consumed;
    output_at += progress.produced;
    if progress.status == .done { break; }
    if progress.status == .need_output and output_at == destination.len {
        raise error.OutputLimit;
    }
}
compressed := destination[..output_at];
```

Use `.none` while more independent input windows are expected. Raw DEFLATE
and zlib also accept `.sync` and `.full`; `.finish` ends the stream. A state
that has reached `done` is terminal until `reset`.

## PNG

`png.encode` writes 8-bit grayscale, grayscale-alpha, RGB, or RGBA PNG data.
The input pixels are borrowed for the call and the returned PNG is owned by
the chosen allocator.

```sx
image : png.Image = .{
    pixels = rgba,
    width = 64,
    height = 64,
    format = .rgba,
};
bytes := try png.encode(image, .{ level = 6 });
defer context.allocator.dealloc_bytes(bytes.ptr);
```

A zero stride means tightly packed rows. Positive strides describe top-down
storage and negative strides describe bottom-up storage. Dimensions, stride,
pixel coverage, and format limits are validated before encoding. PNG-specific
validation uses `png.Error` so callers can distinguish image-layout errors
from compression failure.

## ZIP ownership and I/O

`zip.open` and `zip.open_embedded` borrow their input archive bytes. Those
bytes must outlive the `zip.Reader`. Entries and their name/comment/extra
views borrow the reader. `extract` and `extract_compressed` return owned
storage; `_into` variants return borrowed caller-buffer prefixes.

For bounded random-access input, implement `zip.Source`:

```sx
#import "modules/std/compress.sx";

ArchiveSource :: struct { bytes: string; }

impl zip.Source for ArchiveSource {
    size :: (self: *ArchiveSource) -> i64 { self.bytes.len }

    read_at :: (self: *ArchiveSource, offset: i64, output: string) ->
        (string, !Error) {
        if offset < 0 or offset > self.bytes.len { raise error.InvalidData; }
        take := self.bytes.len - offset;
        if take > output.len { take = output.len; }
        i := 0;
        while i < take { output[i] = self.bytes[offset + i]; i += 1; }
        output[..take]
    }
}
```

`size` is authoritative. `read_at` must return an initialized prefix of the
supplied output window, may return a partial prefix, and returns an empty
prefix at end of input. The returned slice must point at that window rather
than unrelated storage. The source object must outlive a reader opened with
`zip.open_source`.

`zip.Sink.write` either accepts the supplied bytes or raises an error. A sink
writer is poisoned after an error because already-emitted archive bytes cannot
be rolled back.

`Reader.stream`, `stream_name`, and `stream_compressed` return a bounded,
seekable `zip.EntryReader`. It borrows the archive reader. `read` returns an
initialized borrowed prefix; read again after the last non-empty chunk to get
the empty end marker and complete checksum validation, or call the explicit
`finish()` — it validates stream completion plus the entry checksum, raising
when the stream was abandoned early or corrupt, and is idempotent after the
terminal read. Seeking backwards replays decompression without materializing
the whole entry.

```sx
archive := try zip.open_source(xx source, .{ max_metadata = 8 * 1024 * 1024 });
defer archive.deinit();

entry := try archive.stream_name("assets/data.bin", 16 * 1024 * 1024);
defer entry.deinit();

buffer : [16384]u8 = ---;
while true {
    part := try entry.read(buffer[..]);
    if part.len == 0 { break; }
    try consume(part);
}
```

`zip.Writer.init` accumulates an owned memory archive; after `finish`, `take`
transfers that ownership to the caller. `init_sink` emits incrementally,
`init_file` writes a path, `from_reader` preserves existing local records
without recompression, and `append_file` updates an existing archive. Every
factory takes a typed options struct (`WriterOptions`, `FileWriterOptions`,
`FromReaderOptions`, `AppendOptions`; readers take `OpenOptions` /
`OpenFileOptions`, whose null `size` means "to the end of the file") — no
positional booleans or zero sentinels. `close()` is the fallible
finalization: it flushes and closes the underlying file or target and raises
`Io` when that fails; memory writers `take()` first. `deinit` stays the
infallible cleanup and is a no-op after `close`.

Entry options select store or DEFLATE, level, deterministic metadata,
separate local/central extras, data descriptors, UTF-8 naming, attributes,
and timestamps without exposing miniz flag words. Archive-wide entry alignment
is configured separately with `Writer.set_alignment`. ZIP64 may be forced and
is selected automatically when ZIP32 limits are exceeded. Raw compressed entry
streaming and `Writer.add_from` support lossless archive transfer.

ZIP can inspect encrypted entries, unknown methods, and unsafe paths, but it
does not decrypt archives. Multi-disk archives, encryption, and writing or
decoding methods other than store and DEFLATE are unsupported. `safe_path` is
inspection metadata only; applications must still choose and enforce their
own extraction root.

## Representation boundary

Construct codec state only through the documented `init`, `open`, and writer
factory operations. SX currently has no module-private struct fields; issue
0321 tracks representation privacy for the by-value public wrappers. Their
state fields are provisional implementation details and are not part of the
supported stdlib contract.
