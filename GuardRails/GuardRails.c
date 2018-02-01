// Copyright 2017-2018 Xcalar, Inc. All rights reserved.
//
// No use, or distribution, of this source code is permitted in any form or
// means without a valid, written license agreement with Xcalar, Inc.
// Please refer to the included "COPYING" file for terms and conditions
// regarding the use and redistribution of this software.

#include "GuardRails.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <stdint.h>
#include <stdarg.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <sys/mman.h>
#include <pthread.h>
#include <stdbool.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <locale.h>
#include <sys/syscall.h>
#include <limits.h>

#define UNW_LOCAL_ONLY // Must come before libunwind.h
#include <libunwind.h>

static GRArgs grArgs;
char argStr[ARG_MAX_BYTES];

#define ELM_HDR_SZ (sizeof(ElmHdr) + \
        grArgs.maxTrackFrames * MEMB_SZ(ElmHdr, allocBt[0]) + \
        grArgs.maxTrackFreeFrames * MEMB_SZ(ElmHdr, allocBt[0]))


static bool isInit;

static pthread_mutex_t gMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t initMutex = PTHREAD_MUTEX_INITIALIZER;

static size_t currMemPool = -1;

static const size_t guardSize = NUM_GP * PAGE_SIZE;

// Use to pick a slot round-robin, intentionally racy
static volatile size_t racySlotRr = 0;

static MemPool memPools[MAX_MEM_POOLS];
MemSlot memSlots[MAX_SLOTS];

// Histogram of the -actual- size requested, which differs from what the
// allocator provides due to adjustments needed for the guard page, mprotect
// and alignment.
static MemHisto memHisto[MAX_SLOTS][MAX_ALLOC_POWER];

static void onExit(void);

static void grPrintf(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);

    if (grArgs.verbose) {
        vprintf(fmt, args);
    }

    va_end(args);
}

static ssize_t
getBacktrace (void **buf, const ssize_t maxFrames) {
    unw_cursor_t cursor;
    unw_context_t uc;
    unw_word_t ip;
    size_t currFrame = 0;

    unw_getcontext(&uc);
    unw_init_local(&cursor, &uc);
    while (unw_step(&cursor) > 0 && currFrame < maxFrames) {
        unw_get_reg(&cursor, UNW_REG_IP, &ip);
        buf[currFrame] = (void *)ip;
        currFrame++;
    }

    return currFrame;
}

void
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
    for (int slotNum = 0; slotNum < grArgs.numSlots; slotNum++) {
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

    for (int slotNum = 0; slotNum < grArgs.numSlots; slotNum++) {
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
        slotNum = racySlotRr++ % grArgs.numSlots;
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
    memSlots[slotNum].totalUserRequestedBytes += usrSize;

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
    memSlots[slotNum].totalUserFreedBytes += hdr->usrDataSize;

    rmElm(&bin->headInUse, hdr);

    if (grArgs.useDelay) {
        delayPut(&memSlots[slotNum], hdr);
    } else {
        insertElmHead(&bin->headFree, hdr);
        bin->numFree++;
    }

    bin->frees++;

    ret = pthread_mutex_unlock(&memSlots[slotNum].lock);
    GR_ASSERT_ALWAYS(ret == 0);
}

void sigUsr2Handler(int sig) {
    GR_ASSERT_ALWAYS(sig == SIGUSR2);
    if (sig == SIGUSR2) {
        // XXX: Move this call to a thread CV'd from here
        onExit();
    }
}

int
parseArgs(GRArgs *args) {
    // We get loaded before the loader sets up argv/argc for main.  So read the
    // args from a file instead.
    int fd = open(ARG_FILE, O_RDONLY);
    if (fd < 0) {
        return (0);
    }

    ssize_t bytesRead = read(fd, argStr, ARG_MAX_BYTES - 1);
    GR_ASSERT_ALWAYS(bytesRead >= 0);
    close(fd);
    fd = -1;
    argStr[bytesRead] = '\0';

    if (bytesRead > 0 && argStr[bytesRead - 1] == '\n') {
        argStr[bytesRead - 1] = '\0';
    }

    char argStrTok[ARG_MAX_BYTES];

    strncpy(argStrTok, argStr, sizeof(argStrTok));

    char *argv[ARG_MAX_NUM];
    size_t argc = 0;
    char *cursor = strtok(argStrTok, " ");

    memset(argv, 0, sizeof(argv));
    while (cursor) {
        argv[++argc] = cursor;
        cursor = strtok(NULL, " ");
    }

    int c;
    opterr = 0;

    memset(args, 0, sizeof(*args));
    argv[0] = "GuardRails";
    argc++;

    args->numSlots = 1;
    while ((c = getopt(argc, argv, "ds:t:T:v")) != -1) {
        switch (c) {
            case 'd':
                args->useDelay = true;
                break;
            case 's':
                args->numSlots = atoi(optarg);
                break;
            case 't':
                args->maxTrackFrames = atoi(optarg);
                break;
            case 'T':
                args->maxTrackFreeFrames = atoi(optarg);
                break;
            case 'v':
                args->verbose = true;
                break;
            default:
                GR_ASSERT_ALWAYS(false);
        }
    }

    GR_ASSERT_ALWAYS(args->numSlots < MAX_SLOTS);

    // Ughh, if we don't reset this global state, subsequent calls to getopt
    // (eg in main()) will get messed up in confusing ways.
    optind = 0;
    optopt = 0;
    opterr = 0;
    return (argc);
}

__attribute__((constructor)) static void
initialize(void) {
    if (isInit) {
        return;
    }

    GR_ASSERT_ALWAYS(sysconf(_SC_PAGE_SIZE) == PAGE_SIZE);
    GR_ASSERT_ALWAYS(ELM_HDR_SZ < PAGE_SIZE);
    GR_ASSERT_ALWAYS((ELM_HDR_SZ % sizeof(void *)) == 0);

    int ret = parseArgs(&grArgs);
    GR_ASSERT_ALWAYS(ret >= 0);

    ret = pthread_mutex_lock(&initMutex);
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

        sighandler_t sigRet;

        sigRet = signal(SIGUSR2, sigUsr2Handler);
        GR_ASSERT_ALWAYS(sigRet != SIG_ERR);
    }
    ret = pthread_mutex_unlock(&initMutex);
    GR_ASSERT_ALWAYS(ret == 0);
}

static void *
memalignInt(size_t alignment, size_t usrSize) {
    void *buf;
    void *endBuf;
    void *usrData;
    ElmHdr *hdr;
    int ret;
    uint64_t misalignment;
    // Add space to the request to satisfy header needs, header pointer and
    // alignment request
    const size_t allocSize = ELM_HDR_SZ + sizeof(void *) + usrSize +
        (alignment > 1 ? alignment : 0);

    if (!isInit) {
        initialize();
    }

    buf = getBuf(allocSize, &endBuf, usrSize);
    if (!buf) {
        return(NULL);
    }

    hdr = buf;

    if (grArgs.maxTrackFrames > 0) {
        memset(hdr->allocBt, 0, sizeof(hdr->allocBt[0]) * grArgs.maxTrackFrames);
        ret = getBacktrace(hdr->allocBt, grArgs.maxTrackFrames);
        GR_ASSERT_ALWAYS(ret >= 0);
    }

    GR_ASSERT_ALWAYS(hdr->magic == MAGIC_FREE);
    hdr->magic = MAGIC_INUSE;
    hdr->usrDataSize = usrSize;
    GR_ASSERT_ALWAYS((uint64_t)endBuf > usrSize);

    // Pointer returned to the user is relative to the -end- of the buffer,
    // such that the ending adtdress is as close as possible to the guard page.
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
    return(usrData);
}

void *
memalign(size_t alignment, size_t usrSize) {
    return(memalignInt(alignment, usrSize));
}

void *
malloc(size_t usrSize) {
    // Much stuff (eg atomics) assumes malloc is word aligned, so we retain
    // 8-byte alignment here.  If the data size is not a word multiple, there
    // will be a few trailing bytes of possible undetected corruption between
    // the end of the allocated data and the guard page.  We could catch this
    // by adding/checking some trailing known bytes.  Most allocations seem to
    // be a word size multiple.
    return(memalignInt(sizeof(void *), usrSize));
}

void *
calloc(size_t nmemb, size_t usrSize) {
    size_t totalSize = nmemb * usrSize;
    void *buf = memalignInt(sizeof(void *), totalSize);

    memset(buf, 0, totalSize);
    return(buf);
}

void *
realloc(void *origBuf, size_t newUsrSize) {
    if (origBuf == NULL) {
        return(memalignInt(sizeof(void *), newUsrSize));
    } else {
        ElmHdr *hdr;
        void *newBuf;
        hdr = *(ElmHdr **)(origBuf - sizeof(void *));
        if (!isInit) {
            initialize();
        }

        newBuf = memalignInt(sizeof(void *), newUsrSize);
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

    if (grArgs.maxTrackFreeFrames > 0) {
        void *freeOff = (uint8_t *)hdr->allocBt + sizeof(hdr->allocBt[0]) *
            grArgs.maxTrackFrames;
        memset(freeOff, 0, sizeof(hdr->allocBt[0]) * grArgs.maxTrackFreeFrames);
        int ret = getBacktrace(freeOff, grArgs.maxTrackFreeFrames);
        GR_ASSERT_ALWAYS(ret >= 0);
    }

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
    size_t totalFreedBytesGP = 0;
    size_t totalRequestedPow2Bytes = 0;
    size_t totalUserRequestedBytes = 0;
    size_t totalUserFreedBytes = 0;
    const char *printAllocFmt =
    "Bin %2lu size %12lu, allocs: %11lu, frees: %11lu, leaked allocs: %11lu, leaked bytes: %11lu\n";

    int outfd = -1;

    if (grArgs.maxTrackFrames > 0) {
        pid_t tid = syscall(SYS_gettid);
        char of[NAME_MAX];

        int ret = snprintf(of, NAME_MAX, "%s-%d.txt", TRACKER_FILE_PRE, tid);
        GR_ASSERT_ALWAYS(ret > 0);

        outfd = open(of, O_WRONLY | O_CREAT | O_TRUNC, 0666);
        GR_ASSERT_ALWAYS(outfd > 0);
    }

    printf("================ BEGIN GUARDRAILS OUTPUT ================\n");
    printf("Ran with args: %s\n", argStr);
    // For comma-deliniated integers.
    // Note: setlocale leaks 3,659 user bytes
    char *origLocale = setlocale(LC_NUMERIC, "");
    GR_ASSERT_ALWAYS(origLocale);
    for (size_t slotNum = 0; slotNum < grArgs.numSlots; slotNum++) {
        totalUserRequestedBytes += memSlots[slotNum].totalUserRequestedBytes;
        totalUserFreedBytes += memSlots[slotNum].totalUserFreedBytes;
        printf("Number mem pools used: %lu\n", currMemPool+1);
        grPrintf("Actual allocation bins (slot %lu):\n", slotNum);
        for (size_t i = 0; i < MAX_ALLOC_POWER; i++) {
            MemBin *bin = &memSlots[slotNum].memBins[i];
            const size_t binAllocedBytes = bin->allocs * (1UL << i);
            const size_t binFreedBytes = bin->frees * (1UL << i);
            grPrintf(printAllocFmt, i, 1UL << i,
                    bin->allocs, bin->frees, bin->allocs - bin->frees,
                    binAllocedBytes - binFreedBytes);
            totalAllocedBytes += bin->allocs * (1UL << i);
            totalAllocedBytesGP += bin->allocs * ((1UL << i) + PAGE_SIZE);
            totalFreedBytesGP += bin->frees * ((1UL << i) + PAGE_SIZE);
            struct ElmHdr *headInUse = bin->headInUse;
            while (outfd != -1 && headInUse != NULL) {
                dprintf(outfd, "%lu,", headInUse->usrDataSize);
                for (size_t j = 0; j < grArgs.maxTrackFrames; j++) {
                    if (!headInUse->allocBt[j]) {
                        dprintf(outfd, ",");
                    } else {
                        dprintf(outfd, "%p,", headInUse->allocBt[j]);
                    }
                }
                dprintf(outfd, "\n");
                headInUse = headInUse->next;
            }
        }

        grPrintf("\nRequested user allocation bins (slot %lu):\n", slotNum);
        for (size_t i = 0; i < MAX_ALLOC_POWER; i++) {
            const size_t binAllocedBytes = memHisto[slotNum][i].allocs * (1UL << i);
            const size_t binFreedBytes = memHisto[slotNum][i].frees * (1UL << i);
            grPrintf(printAllocFmt, i, 1UL << i,
                    memHisto[slotNum][i].allocs, memHisto[slotNum][i].frees,
                    memHisto[slotNum][i].allocs - memHisto[slotNum][i].frees,
                    binAllocedBytes - binFreedBytes);
            totalRequestedPow2Bytes += binAllocedBytes;
        }
    }

    if (outfd != -1) {
        close(outfd);
        outfd = -1;
    }

    if (NUM_GP > 0) {
        printf("\nActual allocator efficiency w/guard: %lu%%\n",
                100UL * totalUserRequestedBytes / totalAllocedBytesGP);
    }
    printf("Actual allocator efficiency w/o guard: %lu%%\n",
            100UL * totalUserRequestedBytes / totalAllocedBytes);
    printf("Theoretical allocator efficiency : %lu%%\n",
            100UL * totalUserRequestedBytes / totalRequestedPow2Bytes);

    printf("Total user bytes -- alloced: %'lu, freed: %'lu, leaked: %'lu\n",
            totalUserRequestedBytes, totalUserFreedBytes,
            totalUserRequestedBytes - totalUserFreedBytes);
    printf("Total actual bytes -- alloced: %'lu, freed: %'lu, leaked: %'lu\n",
            totalAllocedBytesGP, totalFreedBytesGP,
            totalAllocedBytesGP - totalFreedBytesGP);

    printf("================== END GUARDRAILS OUTPUT ================\n");
    fflush(stdout);

    setlocale(LC_NUMERIC, origLocale);
}
