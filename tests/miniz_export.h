#pragma once

// The pinned miniz CMake build normally generates this visibility header.
// The local benchmark links a private executable, so no export annotation is
// required.
#define MINIZ_EXPORT
