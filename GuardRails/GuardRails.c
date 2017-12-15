// Copyright 2017 Xcalar, Inc. All rights reserved.
//
// No use, or distribution, of this source code is permitted in any form or
// means without a valid, written license agreement with Xcalar, Inc.
// Please refer to the included "COPYING" file for terms and conditions
// regarding the use and redistribution of this software.

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <sys/mman.h>
#include <pthread.h>
#include <stdbool.h>
#include <assert.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>


static volatile bool isInit;

static pthread_mutex_t gMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t initMutex = PTHREAD_MUTEX_INITIALIZER;

#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define IS_POW2(val) ((val) != 0 && (((val) & ((val) - 1)) == 0))

#define likely(condition)   __builtin_expect(!!(condition), 1)
#define unlikely(condition) __builtin_expect(!!(condition), 0)

#define MALLOC(size) memalignInt(sizeof(void *), size,\
        __builtin_return_address(0))

// Avoids any formatted output which can lead to malloc faults
#define GR_ASSERT_ALWAYS(cond) \
    do {\
        if (unlikely(!(cond))) {\
            abort();\
        }\
    }\
    while (0);

typedef struct ElmHdr {
    uint64_t magic;
    size_t binNum;
    size_t slotNum;
    // Pointer returned to user
    void *usrData;
    // Allocation size requested by user
    size_t usrDataSize;
    void *ra[1];
    struct ElmHdr *next;
    struct ElmHdr *prev;
} ElmHdr;

typedef struct MemPool {
    size_t totalSizeBytes;
    size_t remainingSizeBytes;
    // Start of this memory pool
    void *start;
    // Start of this pools free space
    void *startFree;
    // Last valid address; somewhat redundant
    void *end;
} MemPool;

typedef struct MemBin {
    size_t allocs;
    size_t frees;
    size_t highWater;
    size_t lowWater;
    size_t numFree;
    struct ElmHdr *headFree;
    struct ElmHdr *headInUse;
    // TODO: Add delayed free list with PROT_NONE to catch user-after-frees
} MemBin;

typedef struct MemHisto {
    size_t allocs;
    size_t frees;
} MemHisto;

#define KB (1024ULL)
#define MB (1024ULL * 1024ULL)
#define GB (1024ULL * 1024ULL * 1024ULL)

#define MAX_MEM_POOLS 256
#define MEMPOOL_MIN_EXPAND_SIZE (1000ULL * MB)
#define MAX_ALLOC_POWER 40
#define MAX_PREALLOC_POWER 18

// Multiplier for amount of pool to allocate over and above the amount requierd
// to meet all high water marks during init
#define START_POOL_MULT 2

// The maximum allocation that's allowed to be round-robined amongst all the
// slots.  Allocations exceeding this will all go to slot 0 to prevent
// scattering very large freed blocks across different slots.
#define MAX_FLOATING_SIZE (1 * MB)

#define MAGIC_INUSE 0xf005ba11
#define MAGIC_FREE  0xbedabb1e

static size_t currMemPool = -1;

// #define NUM_GP 0
#define NUM_GP 1

#define PAGE_SIZE 4096
static const size_t guardSize = NUM_GP * PAGE_SIZE;

// Use to pick a slot round-robin, intentionally racy
static volatile size_t racySlotRr = 0;

#define NUM_SLOTS 16
typedef struct MemSlot {
    MemBin memBins[MAX_ALLOC_POWER];
    pthread_mutex_t lock; // = PTHREAD_MUTEX_INITIALIZER;
} MemSlot;

static MemPool memPools[MAX_MEM_POOLS];
//static MemBin memBins[MAX_ALLOC_POWER];
MemSlot memSlots[NUM_SLOTS];

// Histogram of the -actual- size requested, which differs from what the
// allocator provides due to adjustments needed for the guard page, mprotect
// and alignment.
static MemHisto memHisto[NUM_SLOTS][MAX_ALLOC_POWER];

// Actual number of bytes requested by user, used to track allocator efficiency
static size_t totalUserRequestedBytes;
static size_t totalUserFreedBytes;

static void
insertElmHead(struct ElmHdr **head, struct ElmHdr *elm) {
    if (*head) {
        (*head)->prev = elm;
    }

    elm->next = *head;
    elm->prev = NULL;
    *head = elm;
}

static struct ElmHdr *
rmElm(struct ElmHdr **head, struct ElmHdr *elm) {
    if (*head == elm) {
        *head = elm->next;
    }

    if (elm->prev) {
        elm->prev->next = elm->next;
    }

    if(elm->next) {
        elm->next->prev = elm->prev;
    }

    elm->prev = NULL;
    elm->next = NULL;
    return(elm);
}

static inline int
log2fast(uint64_t val) {
    if (unlikely(val == 0)) {
        return(0);
    }

    if (IS_POW2(val)) {
        return((8 * sizeof(uint64_t)) - __builtin_clzll(val) - 1);
    } else {
        return((8 * sizeof(uint64_t)) - __builtin_clzll(val));
    }
}

static int
addNewMemPool(const size_t poolSizeReq) {
    const size_t poolSize = (poolSizeReq / PAGE_SIZE + 1) * PAGE_SIZE;

    GR_ASSERT_ALWAYS(pthread_mutex_trylock(&gMutex));
    GR_ASSERT_ALWAYS((poolSize % PAGE_SIZE) == 0);

    void *mapStart = mmap(NULL, poolSize, PROT_READ|PROT_WRITE,
                                MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    if (mapStart == MAP_FAILED) {
        return(-1);
    }
    GR_ASSERT_ALWAYS(((uint64_t)mapStart % PAGE_SIZE) == 0);

    currMemPool++;
    GR_ASSERT_ALWAYS(currMemPool < MAX_MEM_POOLS);
    memPools[currMemPool].totalSizeBytes = poolSize;
    memPools[currMemPool].remainingSizeBytes = poolSize;
    memPools[currMemPool].start = mapStart;
    memPools[currMemPool].startFree = mapStart;
    // Last valid free address
    memPools[currMemPool].end = memPools[currMemPool].start + poolSize - 1;

    return(0);
}

// Pool memory is already initialized to zero by mmap
static void *
getFromPool(const size_t size) {
    const size_t binTotalSize = size + guardSize;

    int ret = pthread_mutex_lock(&gMutex);
    GR_ASSERT_ALWAYS(ret == 0);
    if (memPools[currMemPool].remainingSizeBytes < binTotalSize) {
        // Dynamically grow by adding new pools and also support small number
        // of huge allocs (eg malloc backed b$)
        ret = addNewMemPool(MAX(MEMPOOL_MIN_EXPAND_SIZE, size));
        if (ret) {
            ret = pthread_mutex_unlock(&gMutex);
            GR_ASSERT_ALWAYS(ret == 0);
            return(NULL);
        }
    }

    ElmHdr *hdr = (ElmHdr *)memPools[currMemPool].startFree;

    GR_ASSERT_ALWAYS(memPools[currMemPool].remainingSizeBytes >= binTotalSize);
    memPools[currMemPool].startFree += binTotalSize;
    memPools[currMemPool].remainingSizeBytes -= binTotalSize;

    if (NUM_GP > 0) {
        GR_ASSERT_ALWAYS(((uint64_t)hdr % PAGE_SIZE) == 0);
        void *guardStart = (void *)hdr + size;
        GR_ASSERT_ALWAYS(((uint64_t)guardStart % PAGE_SIZE) == 0);

        // This will result in a TLB invalidation.  Also splits the mapping
        // likely requiring setting max maps like so:
        //      echo 10000000 | sudo tee /proc/sys/vm/max_map_count
        int ret = mprotect(guardStart, guardSize, PROT_NONE);
        GR_ASSERT_ALWAYS(ret == 0);
    }

    ret = pthread_mutex_unlock(&gMutex);
    GR_ASSERT_ALWAYS(ret == 0);
    return(hdr);
}

static int
replenishBin(const size_t slotNum, const size_t binNum) {
    const size_t binSize = (1UL << binNum);

    GR_ASSERT_ALWAYS(pthread_mutex_trylock(&memSlots[slotNum].lock));
    MemBin *bin = &memSlots[slotNum].memBins[binNum];
    // When using guard pages minimum alloc size must be one page
    if (NUM_GP > 0 && binSize < PAGE_SIZE) {
        return(0);
    }

    if (!bin->headFree ||
            bin->numFree < bin->lowWater) {
        // Handle ad-hoc request for a bin with high/low setting of zero
        do {
            ElmHdr *hdr = (ElmHdr *)getFromPool(binSize);
            if (!hdr) {
                return(-1);
            }

            hdr->slotNum = slotNum;
            hdr->binNum = binNum;
            hdr->magic = MAGIC_FREE;
            insertElmHead(&bin->headFree, hdr);
            bin->numFree++;
        } while (bin->numFree < bin->highWater);
    }
    return(0);
}

static int
replenishBins(const size_t slotNum) {
    GR_ASSERT_ALWAYS(pthread_mutex_trylock(&memSlots[slotNum].lock));
    for (int binNum = 0; binNum < MAX_PREALLOC_POWER; binNum++) {
        int ret = replenishBin(slotNum, binNum);
        if (ret != 0) {
            return(ret);
        }
    }
    return(0);
}

static int
replenishSlots(void) {
    for (int slotNum = 0; slotNum < NUM_SLOTS; slotNum++) {
        int ret = pthread_mutex_lock(&memSlots[slotNum].lock);
        GR_ASSERT_ALWAYS(ret == 0);
        replenishBins(slotNum);
        ret = pthread_mutex_unlock(&memSlots[slotNum].lock);
        GR_ASSERT_ALWAYS(ret == 0);
    }
    return(0);
}

static size_t
initBinsMeta(void) {
    int startBuf = log2fast(PAGE_SIZE);
    size_t initSize = 0;

    for (int slotNum = 0; slotNum < NUM_SLOTS; slotNum++) {
        pthread_mutex_init(&memSlots[slotNum].lock, NULL);

        // When the low water mark is hit for a bin, batch allocate from the pool
        // until hitting high-water.
        // Because of the guard page strategy, most allocation activity will be of
        // PAGE_SIZE, so put some big numbers here.
        memSlots[slotNum].memBins[startBuf].lowWater = 100;
        memSlots[slotNum].memBins[startBuf].highWater = 200;

        initSize += memSlots[slotNum].memBins[startBuf].highWater * ((1 << startBuf) + guardSize);

        for (int binNum = startBuf + 1; binNum < 18; binNum++) {
            memSlots[slotNum].memBins[binNum].lowWater = 100;
            memSlots[slotNum].memBins[binNum].highWater = 200;
            initSize += memSlots[slotNum].memBins[binNum].highWater * ((1 << binNum) + guardSize);
        }
    }

    return(initSize);
}

static void *
getBuf(size_t allocSize, void **end, size_t usrSize) {
    size_t reqSize;

    if (NUM_GP > 0) {
        reqSize = MAX(PAGE_SIZE, allocSize);
    } else {
        reqSize = allocSize;
    }

    const size_t binNum = log2fast(reqSize);
    const size_t binSize = (1UL << binNum);

    size_t slotNum = 0;
    if (likely(usrSize < MAX_FLOATING_SIZE)) {
        slotNum = racySlotRr++ % NUM_SLOTS;
    }

    // Used only for stats
    const int usrSizeBin = log2fast(usrSize);

    int ret = pthread_mutex_lock(&memSlots[slotNum].lock);
    GR_ASSERT_ALWAYS(ret == 0);

    ret = replenishBin(slotNum, binNum);
    if (ret) {
        ret = pthread_mutex_unlock(&memSlots[slotNum].lock);
        GR_ASSERT_ALWAYS(ret == 0);
        return(NULL);
    }

    MemBin *bin = &memSlots[slotNum].memBins[binNum];

    ElmHdr *hdr = bin->headFree;
    rmElm(&bin->headFree, hdr);
    insertElmHead(&bin->headInUse, hdr);
    bin->numFree--;
    bin->allocs++;

    GR_ASSERT_ALWAYS(usrSizeBin < MAX_ALLOC_POWER);
    memHisto[slotNum][usrSizeBin].allocs++;
    totalUserRequestedBytes += usrSize;

    ret = pthread_mutex_unlock(&memSlots[slotNum].lock);
    GR_ASSERT_ALWAYS(ret == 0);

    GR_ASSERT_ALWAYS(hdr->magic == MAGIC_FREE);
    // First invalid byte address after buffer
    *end = (void *)hdr + binSize;
    return(hdr);
}

static void
putBuf(void *buf) {
    ElmHdr *hdr = buf;
    GR_ASSERT_ALWAYS(hdr->magic == MAGIC_INUSE);
    hdr->magic = MAGIC_FREE;

    const size_t slotNum = hdr->slotNum;

    int ret = pthread_mutex_lock(&memSlots[slotNum].lock);
    const int binNum = hdr->binNum;
    MemBin *bin = &memSlots[slotNum].memBins[binNum];
    GR_ASSERT_ALWAYS(ret == 0);

    const int usrSizeBin = log2fast(hdr->usrDataSize);
    GR_ASSERT_ALWAYS(usrSizeBin < MAX_ALLOC_POWER);
    memHisto[slotNum][usrSizeBin].frees++;
    totalUserFreedBytes += hdr->usrDataSize;

    rmElm(&bin->headInUse, hdr);
    insertElmHead(&bin->headFree, hdr);
    bin->numFree++;
    bin->frees++;

    ret = pthread_mutex_unlock(&memSlots[slotNum].lock);
    GR_ASSERT_ALWAYS(ret == 0);
}

__attribute__((constructor)) static void
initialize(void) {
    if (isInit) {
        return;
    }

    GR_ASSERT_ALWAYS(sysconf(_SC_PAGE_SIZE) == PAGE_SIZE);
    GR_ASSERT_ALWAYS((sizeof(ElmHdr) % sizeof(void *)) == 0);

    int ret = pthread_mutex_lock(&initMutex);
    GR_ASSERT_ALWAYS(ret == 0);
    if (!isInit) {
        size_t initSize;
        // Allocate memory to accomodate all bins at their high water mark plus
        // additional preallocated memory for the first backing pool.
        initSize = START_POOL_MULT * initBinsMeta();

        printf("Initializing GuardRails with %lu byte starting pool\n", initSize);
        ret = pthread_mutex_lock(&gMutex);
        GR_ASSERT_ALWAYS(ret == 0);
        ret = addNewMemPool(initSize);
        GR_ASSERT_ALWAYS(ret == 0);
        ret = pthread_mutex_unlock(&gMutex);
        GR_ASSERT_ALWAYS(ret == 0);

        ret = replenishSlots();
        GR_ASSERT_ALWAYS(ret == 0);

        isInit = true;
    }
    ret = pthread_mutex_unlock(&initMutex);
    GR_ASSERT_ALWAYS(ret == 0);
}

static void *
memalignInt(size_t alignment, size_t usrSize, void *ra) {
    void *buf;
    void *endBuf;
    void *usrData;
    ElmHdr *hdr;
    uint64_t misalignment;
    // Add space to the request to satisfy header needs, header pointer and
    // alignment request
    const size_t allocSize = sizeof(ElmHdr) + sizeof(void *) + usrSize +
        (alignment > 1 ? alignment : 0);

    if (!isInit) {
        initialize();
    }

    buf = getBuf(allocSize, &endBuf, usrSize);
    if (!buf) {
        return(NULL);
    }

    hdr = buf;
    GR_ASSERT_ALWAYS(hdr->magic == MAGIC_FREE);
    hdr->magic = MAGIC_INUSE;
    hdr->usrDataSize = usrSize;
    GR_ASSERT_ALWAYS((uint64_t)endBuf > usrSize);

    // Pointer returned to the user is relative to the -end- of the buffer,
    // such that the ending address is as close as possible to the guard page.
    // Leaves wasted space between the header and start of the user data.
    usrData = endBuf - usrSize;
    GR_ASSERT_ALWAYS(usrData > buf);
    if (alignment > 1) {
        // TODO: due to alignment there can be a few extra bytes between the
        // end of the user data and the guard page.  Should set them to known
        // values to check on free.
        misalignment = (((uint64_t)usrData) % alignment);
        if (misalignment > 0) {
            usrData -= misalignment;
            GR_ASSERT_ALWAYS(((uint64_t)usrData % alignment) == 0);
        }
    }
    // Pointer to the start of the metadata one word before the user memory
    *(void **)(usrData - sizeof(void *)) = buf;
    hdr->usrData = usrData;
    // TODO: use libc backtrace here for larger allocations
    hdr->ra[0] = ra;
    return(usrData);
}

void *
memalign(size_t alignment, size_t usrSize) {
    return(memalignInt(alignment, usrSize, __builtin_return_address(0)));
}

void *
malloc(size_t usrSize) {
    // Much stuff (eg atomics) assumes malloc is word aligned, so we retain
    // 8-byte alignment here.  If the data size is not a word multiple, there
    // will be a few trailing bytes of possible undetected corruption between
    // the end of the allocated data and the guard page.  We could catch this
    // by adding/checking some trailing known bytes.  Most allocations seem to
    // be a word size multiple.
    return(MALLOC(usrSize));
}

void *
calloc(size_t nmemb, size_t usrSize) {
    size_t totalSize = nmemb * usrSize;
    void *buf = MALLOC(totalSize);

    memset(buf, 0, totalSize);
    return(buf);
}

void *
realloc(void *origBuf, size_t newUsrSize) {
    if (origBuf == NULL) {
        return(MALLOC(newUsrSize));
    } else {
        ElmHdr *hdr;
        void *newBuf;
        hdr = *(ElmHdr **)(origBuf - sizeof(void *));
        if (!isInit) {
            initialize();
        }

        newBuf = MALLOC(newUsrSize);
        memcpy(newBuf, origBuf, MIN(newUsrSize, hdr->usrDataSize));
        free(origBuf);

        return(newBuf);
    }
}

void
free(void *ptr) {
    ElmHdr *hdr;

    if (ptr == NULL) {
        return;
    }

    hdr = *(ElmHdr **)(ptr - sizeof(void *));
    GR_ASSERT_ALWAYS(hdr->magic == MAGIC_INUSE);

    putBuf(hdr);
}

int
posix_memalign(void **memptr, size_t alignment, size_t usrSize) {
    if (!IS_POW2(alignment) || (alignment % sizeof(void *))) {
        return(EINVAL);
    }

    void *tmpPtr = memalign(alignment, usrSize);
    if (tmpPtr == NULL) {
        return(ENOMEM);
    }

    *memptr = tmpPtr;
    return(0);
}

void *
valloc (size_t usrSize) {
    GR_ASSERT_ALWAYS(false);
    return(memalign(PAGE_SIZE, usrSize));
}

void *
pvalloc (size_t usrSize) {
    GR_ASSERT_ALWAYS(false);
    if (usrSize < PAGE_SIZE) {
        usrSize = PAGE_SIZE;
    } else if (!IS_POW2(usrSize)) {
        usrSize = (usrSize / PAGE_SIZE + 1) * PAGE_SIZE;
    }

    return(valloc(usrSize));
}

void *aligned_alloc(size_t alignment, size_t usrSize) {
    GR_ASSERT_ALWAYS(false);
    if (usrSize % alignment) {
        return(NULL);
    }

    return(memalign(alignment, usrSize));
}

__attribute__((destructor)) static void
onExit(void) {
    size_t totalAllocedBytes = 0;
    size_t totalAllocedBytesGP = 0;
    size_t totalRequestedPow2Bytes = 0;
    const char *printAllocFmt =
    "Bin %2lu size %12lu, allocs: %11lu, frees: %11lu, leaked bytes: %11lu\n";

    for (size_t slotNum = 0; slotNum < NUM_SLOTS; slotNum++) {
        printf("Number mem pools used: %lu\n", currMemPool+1);
        printf("Actual allocation bins (slot %lu):\n", slotNum);
        for (size_t i = 0; i < MAX_ALLOC_POWER; i++) {
            MemBin *bin = &memSlots[slotNum].memBins[i];
            const size_t binAllocedBytes = bin->allocs * (1UL << i);
            const size_t binFreedBytes = bin->frees * (1UL << i);
            printf(printAllocFmt, i, 1UL << i,
                    bin->allocs, bin->frees,
                    binAllocedBytes - binFreedBytes);
            totalAllocedBytes += bin->allocs * (1UL << i);
            totalAllocedBytesGP += bin->allocs * ((1UL << i) + PAGE_SIZE);
        }

        printf("\nRequested user allocation bins (slot %lu):\n", slotNum);
        for (size_t i = 0; i < MAX_ALLOC_POWER; i++) {
            const size_t binAllocedBytes = memHisto[slotNum][i].allocs * (1UL << i);
            const size_t binFreedBytes = memHisto[slotNum][i].frees * (1UL << i);
            printf(printAllocFmt, i, 1UL << i,
                    memHisto[slotNum][i].allocs, memHisto[slotNum][i].frees,
                    binAllocedBytes - binFreedBytes);
            totalRequestedPow2Bytes += binAllocedBytes;
        }
    }

    if (NUM_GP > 0) {
        printf("\nActual allocator efficiency w/guard: %lu%%\n",
                100UL * totalUserRequestedBytes / totalAllocedBytesGP);
    }
    printf("Actual allocator efficiency w/o guard: %lu%%\n",
            100UL * totalUserRequestedBytes / totalAllocedBytes);
    printf("Theoretical allocator efficiency : %lu%%\n",
            100UL * totalUserRequestedBytes / totalRequestedPow2Bytes);

    printf("Total user bytes -- alloced: %lu, freed: %lu, leaked: %lu\n",
            totalUserRequestedBytes, totalUserFreedBytes,
            totalUserRequestedBytes - totalUserFreedBytes);

#if 0
    // XXX: Dump this to a file or something
    for (size_t i = 0; i < MAX_ALLOC_POWER; i++) {
        ElmHdr *elm = memBins[i].headInUse;
        while (elm) {
            printf("LEAK: Bin %2lu size %10lu, usrSize: %8lu, allocator: %p\n",
                    i, 1UL << i, elm->usrDataSize, elm->ra[0]);
            elm = elm->next;
        }
    }
#endif
}
