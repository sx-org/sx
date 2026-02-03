#ifndef FILE_UTILS_H
#define FILE_UTILS_H

unsigned char* read_file_bytes(const char* path, int* out_size);

#ifdef __ANDROID__
// Install the AAssetManager that `read_file_bytes` consults for paths
// rooted inside the APK. Caller is responsible for passing the manager
// from `ANativeActivity->assetManager` before any read_file_bytes call.
void sx_android_set_asset_manager(void* m);
#endif

#endif
