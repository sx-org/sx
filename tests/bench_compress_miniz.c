#define _POSIX_C_SOURCE 200809L

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "miniz.h"

#define BENCH_WARMUPS 3u
#define BENCH_SAMPLES 15u

static uint64_t mono_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}

static uint64_t median(uint64_t samples[BENCH_SAMPLES]) {
    size_t i;
    for (i = 1; i < BENCH_SAMPLES; ++i) {
        uint64_t value = samples[i];
        size_t j = i;
        while (j && samples[j - 1] > value) {
            samples[j] = samples[j - 1];
            --j;
        }
        samples[j] = value;
    }
    return samples[BENCH_SAMPLES / 2u];
}

static int write_artifact(const char *label, int level,
                          const unsigned char *data, size_t size) {
    char path[160];
    FILE *file;
    snprintf(path, sizeof(path), ".sx-tmp/bench-compress/c-%s-%d.zlib",
             label[0] == 'r' ? "repeat" : "random", level);
    file = fopen(path, "wb");
    if (!file) return 0;
    if (fwrite(data, 1, size, file) != size) {
        fclose(file);
        return 0;
    }
    return fclose(file) == 0;
}

static int run_case(const char *label, const unsigned char *data,
                    size_t size, int level) {
    const mz_uint flags = tdefl_create_comp_flags_from_zip_params(
        level, 15, MZ_DEFAULT_STRATEGY);
    uint64_t encode_samples[BENCH_SAMPLES];
    uint64_t decode_samples[BENCH_SAMPLES];
    size_t packed_size = 0, plain_size = 0;
    unsigned char *packed = NULL;
    uint64_t encode_ns, decode_ns;
    size_t run;

    for (run = 0; run < BENCH_WARMUPS; ++run) {
        unsigned char *value = (unsigned char *)tdefl_compress_mem_to_heap(
            data, size, &packed_size, (int)flags);
        if (!value) return 0;
        mz_free(value);
    }
    for (run = 0; run < BENCH_SAMPLES; ++run) {
        uint64_t started = mono_ns();
        unsigned char *value = (unsigned char *)tdefl_compress_mem_to_heap(
            data, size, &packed_size, (int)flags);
        uint64_t finished = mono_ns();
        if (!value) return 0;
        if (!started || finished < started) {
            mz_free(value);
            return 0;
        }
        encode_samples[run] = finished - started;
        mz_free(value);
    }
    encode_ns = median(encode_samples);
    if (!encode_ns) return 0;

    packed = (unsigned char *)tdefl_compress_mem_to_heap(
        data, size, &packed_size, (int)flags);
    if (!packed) return 0;

    for (run = 0; run < BENCH_WARMUPS; ++run) {
        unsigned char *plain = (unsigned char *)tinfl_decompress_mem_to_heap(
            packed, packed_size, &plain_size, TINFL_FLAG_PARSE_ZLIB_HEADER);
        if (!plain) goto fail;
        if (plain_size != size || memcmp(data, plain, size) != 0) {
            mz_free(plain);
            goto fail;
        }
        mz_free(plain);
    }
    for (run = 0; run < BENCH_SAMPLES; ++run) {
        uint64_t started = mono_ns();
        unsigned char *plain = (unsigned char *)tinfl_decompress_mem_to_heap(
            packed, packed_size, &plain_size, TINFL_FLAG_PARSE_ZLIB_HEADER);
        uint64_t finished = mono_ns();
        if (!plain) goto fail;
        if (!started || finished < started) {
            mz_free(plain);
            goto fail;
        }
        decode_samples[run] = finished - started;
        if (plain_size != size || memcmp(data, plain, size) != 0) {
            mz_free(plain);
            goto fail;
        }
        mz_free(plain);
    }
    decode_ns = median(decode_samples);
    if (!decode_ns) goto fail;

    printf("%s level=%d input=%zu packed=%zu ratio_permille=%zu "
           "encode_ns=%llu decode_ns=%llu encode_KiB_s=%llu decode_KiB_s=%llu\n",
           label, level, size, packed_size,
           size ? packed_size * 1000u / size : 0u,
           (unsigned long long)encode_ns,
           (unsigned long long)decode_ns,
           (unsigned long long)(encode_ns ? size * 1000000000u / 1024u / encode_ns : 0u),
           (unsigned long long)(decode_ns ? size * 1000000000u / 1024u / decode_ns : 0u));

    if (!write_artifact(label, level, packed, packed_size)) goto fail;
    mz_free(packed);
    return 1;

fail:
    mz_free(packed);
    return 0;
}

static int append_exact_record(FILE *file, unsigned corpus, unsigned level,
                               unsigned strategy, const unsigned char *packed,
                               size_t packed_size) {
    unsigned char header[16] = {0};
    uint64_t length = (uint64_t)packed_size;
    unsigned i;
    header[0] = (unsigned char)corpus;
    header[1] = (unsigned char)level;
    header[2] = (unsigned char)strategy;
    for (i = 0; i < 8; ++i)
        header[8 + i] = (unsigned char)((length >> (i * 8u)) & 0xffu);
    return fwrite(header, 1, sizeof(header), file) == sizeof(header) &&
           fwrite(packed, 1, packed_size, file) == packed_size;
}

static int run_exact_corpus(FILE *file, const char *label, unsigned corpus,
                            const unsigned char *data, size_t size) {
    static const char *const strategy_names[5] = {
        "default", "filtered", "huffman_only", "rle", "fixed"
    };
    unsigned level, strategy;
    for (level = 0; level <= 10; ++level) {
        for (strategy = 0; strategy < 5; ++strategy) {
            mz_uint flags = tdefl_create_comp_flags_from_zip_params(
                (int)level, 15, (int)strategy);
            size_t packed_size = 0;
            unsigned char *packed = (unsigned char *)tdefl_compress_mem_to_heap(
                data, size, &packed_size, (int)flags);
            int ok;
            if (!packed) return 0;
            printf("exact corpus=%s level=%u strategy=%s packed=%zu\n",
                   label, level, strategy_names[strategy], packed_size);
            ok = append_exact_record(file, corpus, level, strategy,
                                     packed, packed_size);
            mz_free(packed);
            if (!ok) return 0;
        }
    }
    return 1;
}

static int run_exact_matrix(void) {
    const size_t size = 1024u * 1024u;
    unsigned char *data = (unsigned char *)malloc(size);
    FILE *file = fopen(".sx-tmp/bench-compress/c-exact.matrix", "wb");
    uint32_t state;
    size_t i;
    int ok;
    if (!data || !file) {
        free(data);
        if (file) fclose(file);
        return 0;
    }

    for (i = 0; i < size; ++i)
        data[i] = (unsigned char)('a' + ((i / 97u + i) % 11u));
    ok = run_exact_corpus(file, "repetitive", 0, data, size);

    state = 0x12345678u;
    for (i = 0; ok && i < size; ++i) {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        data[i] = (unsigned char)(state & 0xffu);
    }
    if (ok) ok = run_exact_corpus(file, "incompressible", 1, data, size);
    if (fclose(file) != 0) ok = 0;
    free(data);
    return ok;
}

int main(int argc, char **argv) {
    const size_t size = 1024u * 1024u;
    unsigned char *data;
    uint32_t state;
    size_t i;
    int ok;
    if (argc == 2 && strcmp(argv[1], "--exact") == 0)
        return run_exact_matrix() ? 0 : 1;
    if (argc != 1) return 2;
    data = (unsigned char *)malloc(size);
    if (!data) return 1;

    for (i = 0; i < size; ++i)
        data[i] = (unsigned char)('a' + ((i / 97u + i) % 11u));
    ok = run_case("repetitive", data, size, 1) &&
         run_case("repetitive", data, size, 6) &&
         run_case("repetitive", data, size, 9);

    state = 0x12345678u;
    for (i = 0; i < size; ++i) {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        data[i] = (unsigned char)(state & 0xffu);
    }
    ok = ok && run_case("incompressible", data, size, 1) &&
         run_case("incompressible", data, size, 6) &&
         run_case("incompressible", data, size, 9);

    free(data);
    return ok ? 0 : 1;
}
