// murmurhash3_ref.c
//
// C reference implementation of MurmurHash3_x86_32 for fixed 16-byte keys.
// Used to generate golden test vectors for tb_murmurhash3.sv.
//
// Build:  gcc -O2 -o murmurhash3_ref murmurhash3_ref.c
// Run:    ./murmurhash3_ref
//
// The printed TV0_GOLDEN and TV1_GOLDEN values should be copy-pasted into
// tb/tb_murmurhash3.sv to replace the 32'hXXXXXXXX placeholders.

#include <stdint.h>
#include <stdio.h>
#include <string.h>

// ---------------------------------------------------------------------------
// Portable rotate-left
// ---------------------------------------------------------------------------
static inline uint32_t rotl32(uint32_t x, int r)
{
    return (x << r) | (x >> (32 - r));
}

// ---------------------------------------------------------------------------
// fmix32 — avalanche finalizer
// ---------------------------------------------------------------------------
static inline uint32_t fmix32(uint32_t h)
{
    h ^= h >> 16;
    h *= 0x85ebca6bu;
    h ^= h >> 13;
    h *= 0xc2b2ae35u;
    h ^= h >> 16;
    return h;
}

// ---------------------------------------------------------------------------
// MurmurHash3_x86_32
//
// key  : pointer to input bytes
// len  : byte length (this program always calls it with len=16)
// seed : 32-bit seed
//
// Returns the 32-bit hash.
// ---------------------------------------------------------------------------
uint32_t MurmurHash3_x86_32(const void *key, int len, uint32_t seed)
{
    const uint8_t *data   = (const uint8_t *)key;
    const int      nblocks = len / 4;   // number of 32-bit blocks

    uint32_t h1 = seed;

    const uint32_t c1 = 0xcc9e2d51u;
    const uint32_t c2 = 0x1b873593u;

    // -------------------------------------------------------------------------
    // Body — process 4-byte blocks
    // -------------------------------------------------------------------------
    const uint32_t *blocks = (const uint32_t *)(data);
    for (int i = 0; i < nblocks; i++) {
        uint32_t k1;
        memcpy(&k1, blocks + i, 4);   // safe unaligned read via memcpy

        k1 *= c1;
        k1  = rotl32(k1, 15);
        k1 *= c2;

        h1 ^= k1;
        h1  = rotl32(h1, 13);
        h1  = h1 * 5 + 0xe6546b64u;
    }

    // -------------------------------------------------------------------------
    // Tail — remaining bytes after the last full block
    // For len=16 there are exactly 0 tail bytes, so this loop is a no-op.
    // Kept for correctness if called with other lengths.
    // -------------------------------------------------------------------------
    const uint8_t *tail = data + nblocks * 4;
    uint32_t k1 = 0;
    switch (len & 3) {
        case 3: k1 ^= (uint32_t)tail[2] << 16; /* fall through */
        case 2: k1 ^= (uint32_t)tail[1] <<  8; /* fall through */
        case 1: k1 ^= (uint32_t)tail[0];
                k1 *= c1;
                k1  = rotl32(k1, 15);
                k1 *= c2;
                h1 ^= k1;
    }

    // -------------------------------------------------------------------------
    // Finalization
    // -------------------------------------------------------------------------
    h1 ^= (uint32_t)len;
    h1  = fmix32(h1);

    return h1;
}

// ---------------------------------------------------------------------------
// Print a 16-byte key as a 128-bit hex string (matches SV 128'h... format)
// ---------------------------------------------------------------------------
static void print_key(const uint8_t *key, int len)
{
    for (int i = len - 1; i >= 0; i--)
        printf("%02x", key[i]);
}

// ---------------------------------------------------------------------------
// main — compute and print all golden vectors used by tb_murmurhash3.sv
// ---------------------------------------------------------------------------
int main(void)
{
    // -------------------------------------------------------------------------
    // TV0: all-zero key, seed = 0
    // -------------------------------------------------------------------------
    uint8_t  tv0_key[16];
    uint32_t tv0_seed = 0x00000000u;
    memset(tv0_key, 0x00, sizeof tv0_key);
    uint32_t tv0_hash = MurmurHash3_x86_32(tv0_key, 16, tv0_seed);

    printf("=== Test Vector 0 ===\n");
    printf("  key  (128-bit hex, big-endian display): 0x");
    print_key(tv0_key, 16);
    printf("\n");
    printf("  seed : 0x%08x\n", tv0_seed);
    printf("  hash : 0x%08x\n", tv0_hash);
    printf("  SV   : localparam logic [31:0] TV0_GOLDEN = 32'h%08x;\n\n", tv0_hash);

    // -------------------------------------------------------------------------
    // TV1: all-ones key, seed = 0xDEADBEEF
    // -------------------------------------------------------------------------
    uint8_t  tv1_key[16];
    uint32_t tv1_seed = 0xdeadbeef;
    memset(tv1_key, 0xff, sizeof tv1_key);
    uint32_t tv1_hash = MurmurHash3_x86_32(tv1_key, 16, tv1_seed);

    printf("=== Test Vector 1 ===\n");
    printf("  key  (128-bit hex, big-endian display): 0x");
    print_key(tv1_key, 16);
    printf("\n");
    printf("  seed : 0x%08x\n", tv1_seed);
    printf("  hash : 0x%08x\n", tv1_hash);
    printf("  SV   : localparam logic [31:0] TV1_GOLDEN = 32'h%08x;\n\n", tv1_hash);

    // -------------------------------------------------------------------------
    // Extra spot-check vectors (useful for manual waveform inspection)
    // -------------------------------------------------------------------------
    printf("=== Extra spot-check vectors ===\n");
    struct { const char *label; uint8_t key[16]; uint32_t seed; } extras[] = {
        { "incrementing bytes, seed=1",
          {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15}, 0x00000001u },
        { "0xAA pattern, seed=0xCAFEBABE",
          {0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,
           0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,0xaa}, 0xcafebabeu },
    };
    int nextra = (int)(sizeof extras / sizeof extras[0]);
    for (int i = 0; i < nextra; i++) {
        uint32_t h = MurmurHash3_x86_32(extras[i].key, 16, extras[i].seed);
        printf("  [%s]\n", extras[i].label);
        printf("    key : 0x"); print_key(extras[i].key, 16); printf("\n");
        printf("    seed: 0x%08x\n", extras[i].seed);
        printf("    hash: 0x%08x\n\n", h);
    }

    return 0;
}
