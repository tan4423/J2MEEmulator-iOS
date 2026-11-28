#ifndef JARBOX_STRING_INDEX_CACHE_H
#define JARBOX_STRING_INDEX_CACHE_H

#include <stdint.h>
#include <string.h>

/* A bounded UTF-16 char -> first-index table for repeatedly searched short
 * alphabets (font glyph maps). The table is a pure lookup accelerator: it
 * preserves String.indexOf's first-match and -1 semantics. */
#define JARBOX_STRING_INDEX_CACHE_MAX_COUNT 256u
#define JARBOX_STRING_INDEX_CACHE_MAX_CAPACITY 512u

typedef struct {
    uint32_t slots[JARBOX_STRING_INDEX_CACHE_MAX_CAPACITY];
    uint16_t capacity;
    uint16_t count;
} JarBoxStringIndexMap;

static inline uint16_t jarbox_string_index_capacity(unsigned count) {
    if (count <= 64u) return 128u;
    if (count <= 128u) return 256u;
    return 512u;
}

static inline int jarbox_string_index_map_build(JarBoxStringIndexMap *map,
        const uint16_t *chars, int offset, int count) {
    if (!map || !chars || offset < 0 || count < 16 ||
        count > (int)JARBOX_STRING_INDEX_CACHE_MAX_COUNT) return 0;
    const uint16_t capacity = jarbox_string_index_capacity((unsigned)count);
    memset(map->slots, 0, (size_t)capacity * sizeof(map->slots[0]));
    const uint32_t mask = (uint32_t)capacity - 1u;
    for (int i = 0; i < count; ++i) {
        const uint16_t ch = chars[offset + i];
        uint32_t slot = ((uint32_t)ch * 40503u) & mask;
        unsigned probes = 0;
        for (; probes < capacity; ++probes) {
            const uint32_t old = map->slots[slot];
            if (!old) {
                map->slots[slot] = ((uint32_t)ch << 16) | (uint32_t)(i + 1);
                break;
            }
            if ((uint16_t)(old >> 16) == ch) break; /* preserve first index */
            slot = (slot + 1u) & mask;
        }
        if (probes == capacity) {
            map->capacity = 0;
            map->count = 0;
            return 0;
        }
    }
    map->capacity = capacity;
    map->count = (uint16_t)count;
    return 1;
}

static inline int jarbox_string_index_map_lookup(const JarBoxStringIndexMap *map,
                                                  uint16_t ch) {
    if (!map || !map->capacity) return -1;
    const uint32_t mask = (uint32_t)map->capacity - 1u;
    uint32_t slot = ((uint32_t)ch * 40503u) & mask;
    for (unsigned probes = 0; probes < map->capacity; ++probes) {
        const uint32_t entry = map->slots[slot];
        if (!entry) return -1;
        if ((uint16_t)(entry >> 16) == ch)
            return (int)(entry & 0xffffu) - 1;
        slot = (slot + 1u) & mask;
    }
    return -1;
}

#endif
