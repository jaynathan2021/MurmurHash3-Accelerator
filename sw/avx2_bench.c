// =============================================================================
// avx2_bench.c  —  Scalar C and AVX2 SIMD MurmurHash3 CPU throughput benchmark
//
// Build (Linux x86 with AVX2):
//   gcc -O3 -mavx2 -lm -o avx2_bench avx2_bench.c
//
// Build (ARM Linux / no AVX2):
//   gcc -O3 -DNO_AVX2 -lm -o avx2_bench avx2_bench.c
//
// Run:
//   ./avx2_bench
//
// Output lines (grep for "CPU_RESULT"):
//   CPU_RESULT impl=scalar  n_keys=10000000 elapsed_s=... throughput_mhps=...
//   CPU_RESULT impl=avx2x8  n_keys=10000000 elapsed_s=... throughput_mhps=...
//
// Energy estimate: throughput / TDP (upper-bound approximation, per proposal).
// =============================================================================

#define _POSIX_C_SOURCE 200809L   /* clock_gettime, CLOCK_MONOTONIC */

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if !defined(NO_AVX2) && defined(__AVX2__)
#  include <immintrin.h>
#  define HAVE_AVX2 1
#else
#  define HAVE_AVX2 0
#endif

// ---------------------------------------------------------------------------
// Portable 32-bit rotate-left
// ---------------------------------------------------------------------------
static inline uint32_t rotl32(uint32_t x, int r)
{
    return (x << r) | (x >> (32 - r));
}

// ---------------------------------------------------------------------------
// MurmurHash3 fmix32
// ---------------------------------------------------------------------------
static inline uint32_t fmix32(uint32_t h)
{
    h ^= h >> 16; h *= 0x85ebca6bu;
    h ^= h >> 13; h *= 0xc2b2ae35u;
    return h ^ (h >> 16);
}

// ---------------------------------------------------------------------------
// Scalar MurmurHash3_x86_32 — fixed 16-byte key (4 blocks, no tail)
// ---------------------------------------------------------------------------
static inline uint32_t murmur3_scalar(const uint32_t key[4], uint32_t seed)
{
    const uint32_t c1 = 0xcc9e2d51u;
    const uint32_t c2 = 0x1b873593u;
    uint32_t h = seed;

    for (int b = 0; b < 4; b++) {
        uint32_t k = key[b];
        k *= c1; k = rotl32(k, 15); k *= c2;
        h ^= k;  h = rotl32(h, 13); h = h * 5u + 0xe6546b64u;
    }
    h ^= 16u;
    return fmix32(h);
}

// ---------------------------------------------------------------------------
// AVX2 SIMD: 8 keys in parallel
// ---------------------------------------------------------------------------
#if HAVE_AVX2

static inline __m256i rotl32_avx2(__m256i v, int r)
{
    return _mm256_or_si256(_mm256_slli_epi32(v, r),
                           _mm256_srli_epi32(v, 32 - r));
}

// Process 8 independent 128-bit keys (each key = 4 x uint32) simultaneously.
// keys[k][b] = block b of key k   (k in 0..7, b in 0..3)
// seeds: one per key
static void murmur3_avx2_x8(const uint32_t keys[8][4],
                             const uint32_t seeds[8],
                                   uint32_t out[8])
{
    const __m256i c1  = _mm256_set1_epi32((int)0xcc9e2d51u);
    const __m256i c2  = _mm256_set1_epi32((int)0x1b873593u);
    const __m256i f1  = _mm256_set1_epi32((int)0x85ebca6bu);
    const __m256i f2  = _mm256_set1_epi32((int)0xc2b2ae35u);
    const __m256i c5  = _mm256_set1_epi32(5);
    const __m256i add = _mm256_set1_epi32((int)0xe6546b64u);
    const __m256i len = _mm256_set1_epi32(16);

    __m256i h = _mm256_loadu_si256((const __m256i *)seeds);

    for (int b = 0; b < 4; b++) {
        // Gather block b from each of the 8 keys
        uint32_t blk[8];
        for (int k = 0; k < 8; k++) blk[k] = keys[k][b];
        __m256i kv = _mm256_loadu_si256((const __m256i *)blk);

        kv = _mm256_mullo_epi32(kv, c1);
        kv = rotl32_avx2(kv, 15);
        kv = _mm256_mullo_epi32(kv, c2);

        h = _mm256_xor_si256(h, kv);
        h = rotl32_avx2(h, 13);
        h = _mm256_add_epi32(_mm256_mullo_epi32(h, c5), add);
    }

    h = _mm256_xor_si256(h, len);

    // fmix32 on all 8 lanes
    h = _mm256_xor_si256(h, _mm256_srli_epi32(h, 16));
    h = _mm256_mullo_epi32(h, f1);
    h = _mm256_xor_si256(h, _mm256_srli_epi32(h, 13));
    h = _mm256_mullo_epi32(h, f2);
    h = _mm256_xor_si256(h, _mm256_srli_epi32(h, 16));

    _mm256_storeu_si256((__m256i *)out, h);
}
#endif  // HAVE_AVX2

// ---------------------------------------------------------------------------
// Timer helper — returns seconds
// ---------------------------------------------------------------------------
static double now_sec(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(void)
{
#define N_KEYS  10000000
#define N_RUNS  10
    // Published TDP used as upper-bound energy denominator (see proposal §3.4)
    const double TDP_WATTS = 65.0;  // typical desktop CPU TDP — edit for your machine

    printf("============================================================\n");
    printf(" MurmurHash3 CPU Throughput Benchmark\n");
    printf(" N_KEYS=%d  N_RUNS=%d  TDP=%.0f W (upper bound)\n",
           N_KEYS, N_RUNS, TDP_WATTS);
    printf("============================================================\n");

    // Allocate key array — use a simple LCG to fill with deterministic data
    uint32_t (*keys)[4] = malloc((size_t)N_KEYS * sizeof(*keys));
    uint32_t  *results  = malloc((size_t)N_KEYS * sizeof(uint32_t));
    if (!keys || !results) { fprintf(stderr, "OOM\n"); return 1; }

    uint32_t prng = 0xDEAD1234u;
    for (int i = 0; i < N_KEYS; i++) {
        for (int b = 0; b < 4; b++) {
            prng = prng * 0x0019660du + 0x3c6ef35fu;
            keys[i][b] = prng;
        }
    }

    // -----------------------------------------------------------------------
    // Scalar benchmark
    // -----------------------------------------------------------------------
    {
        double times[N_RUNS];
        for (int r = 0; r < N_RUNS; r++) {
            double t0 = now_sec();
            volatile uint32_t sink = 0;
            for (int i = 0; i < N_KEYS; i++)
                sink ^= murmur3_scalar(keys[i], 0u);
            times[r] = now_sec() - t0;
            (void)sink;
        }
        // Sort, drop min/max
        for (int i = 0; i < N_RUNS - 1; i++)
            for (int j = i+1; j < N_RUNS; j++)
                if (times[j] < times[i]) { double t=times[i]; times[i]=times[j]; times[j]=t; }
        double sum = 0;
        for (int r = 1; r < N_RUNS - 1; r++) sum += times[r];
        double avg = sum / (N_RUNS - 2);
        double mhps = (double)N_KEYS / avg / 1e6;
        double std_sum = 0;
        for (int r = 1; r < N_RUNS - 1; r++) {
            double d = (double)N_KEYS / times[r] / 1e6 - mhps;
            std_sum += d * d;
        }
        double std_dev = (N_RUNS > 4) ? sqrt(std_sum / (N_RUNS - 3)) : 0.0;
        double hpj = mhps * 1e6 / TDP_WATTS;
        printf("\n=== Scalar C ===\n");
        printf("  avg_elapsed : %.4f s  (over %d middle runs)\n", avg, N_RUNS-2);
        printf("  throughput  : %.2f Mhash/s  (std=%.2f)\n", mhps, std_dev);
        printf("  energy eff  : %.2f Mhash/J  (upper bound, TDP=%.0f W)\n", hpj/1e6, TDP_WATTS);
        printf("CPU_RESULT impl=scalar n_keys=%d elapsed_s=%.6f throughput_mhps=%.4f stddev_mhps=%.4f hashpj=%.2f\n",
               N_KEYS, avg, mhps, std_dev, hpj);
    }

    // -----------------------------------------------------------------------
    // AVX2 x8 benchmark
    // -----------------------------------------------------------------------
#if HAVE_AVX2
    {
        double times[N_RUNS];
        for (int r = 0; r < N_RUNS; r++) {
            double t0 = now_sec();
            volatile uint32_t sink = 0;
            uint32_t seeds[8] = {0,0,0,0,0,0,0,0};
            uint32_t out[8];
            // Process 8 keys at a time
            for (int i = 0; i + 7 < N_KEYS; i += 8) {
                murmur3_avx2_x8((const uint32_t (*)[4])&keys[i], seeds, out);
                sink ^= out[0] ^ out[7];
            }
            times[r] = now_sec() - t0;
            (void)sink;
        }
        for (int i = 0; i < N_RUNS - 1; i++)
            for (int j = i+1; j < N_RUNS; j++)
                if (times[j] < times[i]) { double t=times[i]; times[i]=times[j]; times[j]=t; }
        double sum = 0;
        for (int r = 1; r < N_RUNS - 1; r++) sum += times[r];
        double avg = sum / (N_RUNS - 2);
        double mhps = (double)N_KEYS / avg / 1e6;
        double std_sum = 0;
        for (int r = 1; r < N_RUNS - 1; r++) {
            double d = (double)N_KEYS / times[r] / 1e6 - mhps;
            std_sum += d * d;
        }
        double std_dev = (N_RUNS > 4) ? sqrt(std_sum / (N_RUNS - 3)) : 0.0;
        double hpj = mhps * 1e6 / TDP_WATTS;
        printf("\n=== AVX2 x8 ===\n");
        printf("  avg_elapsed : %.4f s  (over %d middle runs)\n", avg, N_RUNS-2);
        printf("  throughput  : %.2f Mhash/s  (std=%.2f)\n", mhps, std_dev);
        printf("  energy eff  : %.2f Mhash/J  (upper bound, TDP=%.0f W)\n", hpj/1e6, TDP_WATTS);
        printf("CPU_RESULT impl=avx2x8 n_keys=%d elapsed_s=%.6f throughput_mhps=%.4f stddev_mhps=%.4f hashpj=%.2f\n",
               N_KEYS, avg, mhps, std_dev, hpj);
    }
#else
    printf("\n=== AVX2 x8 ===\n");
    printf("  SKIPPED — build with -mavx2 on an x86 CPU to enable\n");
    printf("CPU_RESULT impl=avx2x8 n_keys=0 elapsed_s=0 throughput_mhps=0 stddev_mhps=0 hashpj=0\n");
#endif

    printf("\n============================================================\n");
    printf(" Note: energy efficiency = throughput / TDP is an UPPER BOUND.\n");
    printf(" Actual power draw is <= TDP in most workloads.\n");
    printf("============================================================\n");

    free(keys);
    free(results);
    return 0;
}
