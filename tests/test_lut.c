/* Display curve (handover Q2): black, white, mid-grey and shadow levels, monotonicity; and saturated
 * raw renders white under any white balance (Q5). */
#define main isp_main
#include "../gc2607_isp.c"
#undef main
#include "check.h"

/* LUT index of a linear fraction of the signal range above black. */
static int raw_of(float linear) { return (int)(BLACK_LEVEL + linear * MAX_SIGNAL + 0.5f); }

int main(void)
{
    build_luts(1.0f, 1.0f, 1.0f, 1.0f);

    CHECK(lut_g[BLACK_LEVEL] == 0, "black renders %d", lut_g[BLACK_LEVEL]);
    CHECK(lut_g[LUT_SIZE - 1] == 255, "white renders %d", lut_g[LUT_SIZE - 1]);
    int grey = lut_g[raw_of(0.18f)], shadow = lut_g[raw_of(0.05f)];
    CHECK(grey >= 114 && grey <= 118, "18%% grey renders %d, want 116 +/- 2", grey);
    CHECK(shadow >= 54 && shadow <= 60, "5%% renders %d, want 57 +/- 3", shadow);
    for (int i = 1; i < LUT_SIZE; i++)
        CHECK(lut_g[i] >= lut_g[i - 1], "LUT decreases at %d: %d -> %d", i, lut_g[i - 1], lut_g[i]);
    for (int i = 0; i < LUT_SIZE; i++)
        CHECK(lut_r[i] == lut_g[i] && lut_b[i] == lut_g[i], "unit gains differ by channel at %d", i);

    /* Saturated raw stays white whatever the white balance (Q5): gains are normalised so none is
     * below 1, and the controller never sets digital gain below 1. */
    const float rel[][2] = { { 2.2f, 1.65f }, { 0.9f, 1.4f } };
    for (int k = 0; k < 2; k++) {
        float wb[3];
        wb_gains(rel[k][0], rel[k][1], wb);
        build_luts(wb[0], wb[1], wb[2], 1.0f);
        int r = lut_r[LUT_SIZE - 1], g = lut_g[LUT_SIZE - 1], b = lut_b[LUT_SIZE - 1];
        CHECK(r == 255 && g == 255 && b == 255, "R/G %.2f B/G %.2f: saturated renders (%d, %d, %d)",
              rel[k][0], rel[k][1], r, g, b);
    }
    return check_report("test_lut");
}
