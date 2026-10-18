/* Shared helpers for the ISP timing harness (tools/bench_isp.c). */
#ifndef GC2607_BENCH_COMMON_H
#define GC2607_BENCH_COMMON_H

#include <stdint.h>
#include <stdlib.h>
#include <time.h>

#define ITER 200

static double now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static int cmpd(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static double median_ms(double *t)
{
    qsort(t, ITER, sizeof(double), cmpd);
    return t[ITER / 2];
}

/* Deterministic pseudo-random 10-bit Bayer frame (black level 64 upwards). */
static void fill_bayer(uint16_t *b, int n)
{
    unsigned s = 12345;
    for (int i = 0; i < n; i++) {
        s = s * 1103515245u + 12345u;
        b[i] = 64 + ((s >> 16) % 800);
    }
}

#endif
