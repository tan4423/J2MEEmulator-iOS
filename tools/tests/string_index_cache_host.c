#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "jarbox_string_index_cache.h"

static int linear(const uint16_t *s, unsigned n, uint16_t ch) {
    for (unsigned i = 0; i < n; ++i) if (s[i] == ch) return (int)i;
    return -1;
}

static uint32_t rng = 0x71c3a5d9u;
static uint32_t next_random(void) {
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
}

int main(void) {
    uint16_t chars[JARBOX_STRING_INDEX_CACHE_MAX_COUNT];
    JarBoxStringIndexMap map;

    /* Boundary sizes, duplicate glyphs, NUL and non-ASCII UTF-16 units. */
    const unsigned sizes[] = {16, 17, 64, 65, 128, 129, 255, 256};
    for (unsigned s = 0; s < sizeof(sizes) / sizeof(sizes[0]); ++s) {
        const unsigned n = sizes[s];
        for (unsigned i = 0; i < n; ++i) {
            uint16_t value = (uint16_t)next_random();
            chars[i] = value;
        }
        chars[0] = 0;
        chars[1] = 0x00e9;
        chars[2] = 0x4e2d;
        if (n > 8) chars[7] = chars[1]; /* first occurrence must win */
        memset(&map, 0, sizeof(map));
        assert(jarbox_string_index_map_build(&map, chars, 0, (int)n));
        assert(map.count == n);
        assert(map.capacity == jarbox_string_index_capacity(n));
        for (unsigned ch = 0; ch <= 0xffffu; ++ch)
            assert(jarbox_string_index_map_lookup(&map, (uint16_t)ch) ==
                   linear(chars, n, (uint16_t)ch));
    }

    /* Slices use absolute backing-array offsets but return String-relative indices. */
    uint16_t sliced[] = {0x7777, 'A', 'B', 'A', 0x8888};
    memset(&map, 0, sizeof(map));
    assert(jarbox_string_index_map_build(&map, sliced, 1, 3));
    assert(jarbox_string_index_map_lookup(&map, 'A') == 0);
    assert(jarbox_string_index_map_lookup(&map, 'B') == 1);
    assert(jarbox_string_index_map_lookup(&map, 'Z') == -1);

    memset(&map, 0, sizeof(map));
    assert(!jarbox_string_index_map_build(&map, sliced, 1, 15));
    assert(map.capacity == 0);
    assert(!jarbox_string_index_map_build(&map, sliced, -1, 16));
    assert(!jarbox_string_index_map_build(&map, NULL, 0, 16));

    puts("UTF-16 String.indexOf cache differential PASS");
    return 0;
}
