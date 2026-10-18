/* Minimal assertion helpers for the ISP unit tests: print each failure, exit 1 at the end. */
#ifndef GC2607_TESTS_CHECK_H
#define GC2607_TESTS_CHECK_H

#include <stdio.h>

static int check_failures;

#define CHECK(cond, ...)                                                        \
    do {                                                                        \
        if (!(cond)) {                                                          \
            check_failures++;                                                   \
            printf("FAIL %s:%d: %s: ", __FILE__, __LINE__, #cond);              \
            printf(__VA_ARGS__);                                                \
            printf("\n");                                                       \
        }                                                                       \
    } while (0)

/* Return the process exit status and print the verdict. */
static int check_report(const char *name)
{
    printf("%s: %s (%d failure%s)\n", name, check_failures ? "FAILED" : "ok", check_failures,
           check_failures == 1 ? "" : "s");
    return check_failures ? 1 : 0;
}

#endif
