// C-to-sx callback FFI baseline. C takes a function pointer + a value,
// invokes the callback with the value, and returns whatever the callback
// returned. Mirrors the `app->onInputEvent` pattern in
// library/modules/platform/android.sx where sx installs a handler that
// native_app_glue invokes from its input-event loop.

int ffi_apply_callback(int (*cb)(int), int value);

// Two-arg variant — the actual chess-on-Android shape:
// the callback receives a pointer + a value (mirrors
// onInputEvent(app, event) where both are opaque pointers from
// the C caller's point of view).
int ffi_apply_callback2(int (*cb)(void *ctx, int v), void *ctx, int v);
