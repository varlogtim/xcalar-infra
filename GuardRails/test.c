// Copyright 2017 Xcalar, Inc. All rights reserved.
//
// No use, or distribution, of this source code is permitted in any form or
// means without a valid, written license agreement with Xcalar, Inc.
// Please refer to the included "COPYING" file for terms and conditions
// regarding the use and redistribution of this software.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>
#include <time.h>
#include <stdint.h>

#define IMAX 100
#define JMAX 4000

int
main() {
    srand(time(NULL));
    int i, j;
    const int maxRand = (1 << 16);

    printf("imax:jmax:sz: %d:%d:%d\n", IMAX, JMAX, maxRand);
    for (i = 0; i < IMAX; i++) {
        size_t totalMem = 0;
        void *bufs[JMAX];
        memset(bufs, 0, sizeof(void *)*JMAX);
        for (j = 0; j < JMAX; j++) {
            int randSize = rand() % maxRand;
            // int randSize = (rand() % maxRand) / 8 * 8;
            // printf("%d:%d: %6d\n", i, j, randSize);
            bufs[j] = malloc(randSize);
            memset(bufs[j], 0x5a, randSize);
#if 0
            char *ptr  = (char *)bufs[j] + randSize;
            *(ptr++) = 1;
            *(ptr++) = 1;
            *(ptr++) = 1;
            *(ptr++) = 1;
            *(ptr++) = 1;
            *(ptr++) = 1;
            *(ptr++) = 1;
            *(ptr++) = 1;
#endif
            totalMem += randSize;
        }
        // sleep(5);
        for (j = 0; j < JMAX; j++) {
            free(bufs[j]);
            bufs[j] = NULL;
        }
    }
    return (0);
}
