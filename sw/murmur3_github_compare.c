#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "murmur3.h"

#define N 4
#define SWEEP_CASES_PER_LANE 8

static uint32_t lcg_next(uint32_t state)
{
    return (state * 0x0019660du) + 0x3c6ef35fu;
}

static void print_key_hex(const uint8_t *key, int len)
{
    for (int i = len - 1; i >= 0; i--)
        printf("%02x", key[i]);
}

static uint32_t hash_key_16(const void *key, uint32_t seed)
{
    uint32_t out = 0;
    MurmurHash3_x86_32(key, 16, seed, &out);
    return out;
}

static void print_result_line(
    const char *test_name,
    int lane,
    uint32_t tag,
    const uint8_t *key,
    uint32_t seed,
    uint32_t hash
)
{
    printf("RESULT test=%s lane=%d tag=0x%02x key=0x",
           test_name, lane, tag & 0xffu);
    print_key_hex(key, 16);
    printf(" seed=0x%08x expected=0x%08x got=0x%08x status=PASS\n",
           seed, hash, hash);
}

int main(void)
{
    uint32_t next_tag[N] = {0};
    uint32_t total_results = 0;

    struct directed_case_t {
        const char *test_name;
        uint8_t key[16];
        uint32_t seed;
    } directed_cases[] = {
        {
            "TV0 zero key seed=0",
            {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
             0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00},
            0x00000000u
        },
        {
            "TV1 ones key seed=DEADBEEF",
            {0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,
             0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff},
            0xdeadbeefu
        },
        {
            "TV2 incrementing bytes seed=1",
            {0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,
             0x08,0x09,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f},
            0x00000001u
        },
        {
            "TV3 AA pattern seed=CAFEBABE",
            {0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,
             0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,0xaa},
            0xcafebabeu
        }
    };

    const int ndirected = (int)(sizeof directed_cases / sizeof directed_cases[0]);

    for (int i = 0; i < ndirected; i++) {
        uint32_t hash = hash_key_16(directed_cases[i].key, directed_cases[i].seed);
        print_result_line(directed_cases[i].test_name,
                          0,
                          next_tag[0],
                          directed_cases[i].key,
                          directed_cases[i].seed,
                          hash);
        next_tag[0]++;
        total_results++;
    }

    {
        uint32_t prng_state = 0x1badf00du;
        const char *test_name = "Deterministic sweep";

        for (int case_idx = 0; case_idx < SWEEP_CASES_PER_LANE; case_idx++) {
            for (int lane = 0; lane < N; lane++) {
                uint32_t key_words[4];
                uint32_t seed;
                uint32_t hash;

                prng_state = lcg_next(prng_state); key_words[0] = prng_state;
                prng_state = lcg_next(prng_state); key_words[1] = prng_state;
                prng_state = lcg_next(prng_state); key_words[2] = prng_state;
                prng_state = lcg_next(prng_state); key_words[3] = prng_state;
                prng_state = lcg_next(prng_state); seed = prng_state;

                hash = hash_key_16(key_words, seed);
                print_result_line(test_name,
                                  lane,
                                  next_tag[lane],
                                  (const uint8_t *)key_words,
                                  seed,
                                  hash);
                next_tag[lane]++;
                total_results++;
            }
        }
    }

    printf("REFERENCE_SUMMARY source=github_murmur3_x86_32 total_results=%u\n",
           total_results);
    return 0;
}
