# vendors/file_utils — in-house asset-read helper

Not third-party: a small in-house C helper kept under vendors/ because
it ships as a `#import c` unit like the rest.

- `read_file_bytes(path, *out_size)` — whole-file read, malloc'd bytes.
- On Android, paths rooted inside the APK resolve through the
  `AAssetManager` installed via `sx_android_set_asset_manager`
  (modules/platform/android.sx calls it during activity startup; the
  hook only exists in the `__ANDROID__` build of the unit).
