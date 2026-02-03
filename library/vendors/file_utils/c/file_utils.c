#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef __ANDROID__
#include <android/asset_manager.h>

// Caller-installed AAssetManager pointer. Chess's android_main extracts
// it from `app->activity->assetManager` (via sx-side platform module's
// `g_android_asset_manager` global) and feeds it here once at startup.
// Until the setter has been called, Android falls through to fopen —
// gives a predictable "file not found" rather than a NULL-deref.
static AAssetManager* g_aam = NULL;

void sx_android_set_asset_manager(void* m) {
    g_aam = (AAssetManager*)m;
}
#endif

unsigned char* read_file_bytes(const char* path, int* out_size) {
#ifdef __ANDROID__
    if (g_aam != NULL) {
        // AAssetManager paths are relative to the APK's `assets/`
        // directory. Strip a leading "assets/" so callers can use the
        // same paths across iOS/macOS/Android (those platforms read
        // assets via `assets/...` rooted in the bundle or CWD).
        const char* lookup = path;
        if (strncmp(path, "assets/", 7) == 0) {
            lookup = path + 7;
        }
        AAsset* a = AAssetManager_open(g_aam, lookup, AASSET_MODE_BUFFER);
        if (a != NULL) {
            off_t n = AAsset_getLength(a);
            *out_size = (int)n;
            unsigned char* buf = (unsigned char*)malloc((size_t)n);
            if (buf != NULL) {
                memcpy(buf, AAsset_getBuffer(a), (size_t)n);
            }
            AAsset_close(a);
            return buf;
        }
        // Falls through to fopen — useful when assets land in the data
        // dir via extraction or app updates.
    }
#endif
    FILE* f = fopen(path, "rb");
    if (!f) return 0;
    fseek(f, 0, SEEK_END);
    *out_size = (int)ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char* buf = (unsigned char*)malloc(*out_size);
    fread(buf, 1, *out_size, f);
    fclose(f);
    return buf;
}
