# vendors/sqlite — SQLite for sx programs

- Version: **3.53.2** (`SQLITE_VERSION` in `c/sqlite3.h`)
- Source: <https://sqlite.org/2026/sqlite-amalgamation-3530200.zip>
- Zip sha256: `8a310d0a16c7a90cacd4c884e70faa51c902afed2a89f63aaa0126ab83558a32`
- Files kept: `c/sqlite3.c`, `c/sqlite3.h` (the amalgamation; `shell.c`
  and `sqlite3ext.h` dropped — no shell, no loadable extensions)
- License: public domain (<https://sqlite.org/copyright.html>)

`#import "vendors/sqlite/sqlite.sx"` gives any sx program SQLite with
no system dependency and no build flags. The bindings declare the
amalgamation as a named `#import c` unit carrying the pinned compile
options (`SQLITE_DQS=0`, `SQLITE_THREADSAFE=1`,
`SQLITE_DEFAULT_MEMSTATUS=0`, `SQLITE_OMIT_DEPRECATED`,
`SQLITE_OMIT_SHARED_CACHE`, `SQLITE_LIKE_DOESNT_MATCH_BLOBS`,
`SQLITE_ENABLE_COLUMN_METADATA`, `SQLITE_ENABLE_FTS5`, `-O2`); sx
compiles the unit through its content-addressed object cache
(`.sx-cache/`), so the 250k-line source builds once per machine.
`sx build` links the objects into the binary; `sx run` loads them as a
PRIORITY symbol-search target ahead of the process images, so an OS
libsqlite3 of a different version can never shadow this copy. In the sx
suite, `examples/vendor/1624-vendor-sqlite-module.sx` pins the version
and a typed round trip, `examples/vendor/1628-vendor-sqlite-fts5.sx`
the full-text round trip.

## Bound surface

`sqlite.sx` maps the full practical C API (~100 functions): connection
lifecycle + open_v2 flags, errors (extended codes included), statements
with the complete bind/column families, parameter and column
introspection (built with `SQLITE_ENABLE_COLUMN_METADATA`), incremental
blob I/O, the online backup API, serialize/deserialize, and the library
utilities. Not bound, by design: callback-taking APIs (hooks, UDFs,
collations, authorizers — they need C→sx callbacks), the
`sqlite3_value_*` family (UDF-coupled), varargs configuration, UTF-16
variants, the mutex/VFS/vtab-authoring layers, and the subsystems this
build omits (sessions/snapshots, deprecated API).

Full-text search needs no bindings: `SQLITE_ENABLE_FTS5` compiles FTS5
in, and it is driven entirely from SQL — `CREATE VIRTUAL TABLE … USING
fts5`, `MATCH`, `bm25()`, the `rank` column.

To upgrade: replace `c/sqlite3.c`/`c/sqlite3.h` with a newer
amalgamation, update this file and the version pins in consuming test
suites, and rebuild (the object cache keys on the source bytes, so the
new amalgamation recompiles automatically).
