/* Display curve (handover Q2): black, white, mid-grey and shadow levels, monotonicity; saturated raw
 * renders white under any white balance (Q5); and the grey-world balance ignores near-black samples
 * and is held to its range when one colour fills the frame (Q9). */
#define main isp_main
#include "../gc2607_isp.c"
#undef main
#include "check.h"

/* LUT index of a linear fraction of the signal range above black. */
static int raw_of(float linear) { return (int)(BLACK_LEVEL + linear * MAX_SIGNAL + 0.5f); }

static uint16_t bayer[SENSOR_W * SENSOR_H];

/* Fill rows [y0, y1) of the GRBG frame with one colour, given as raw counts above black. */
static void fill_rows(int y0, int y1, int r, int g, int b)
{
    for (int y = y0; y < y1; y++)
        for (int x = 0; x < SENSOR_W; x++)
            bayer[y * SENSOR_W + x] = BLACK_LEVEL + (y % 2 ? (x % 2 ? g : b) : (x % 2 ? r : g));
}

/* Grey-world gains (relative to green) wb_from_stats takes from the frame, and the largest colour
 * error left on a grey card whose raw is GREY_R/G/B: max |R/G - 1|, |B/G - 1| after those gains. */
enum { GREY_R = 150, GREY_G = 300, GREY_B = 170 };   /* a light needing R/G 2.0, B/G 1.76 */
static float grey_cast(float *r_rel, float *b_rel)
{
    struct frame_stats st;
    collect_stats(bayer, &st);
    CHECK(wb_from_stats(&st, r_rel, b_rel), "no white balance from the frame");
    return fmaxf(fabsf(GREY_R * *r_rel / GREY_G - 1.0f), fabsf(GREY_B * *b_rel / GREY_G - 1.0f));
}

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

    /* Q9: half the frame near black, with the red-heavy offset a black-level error gives: the
     * balance is the grey card's alone. */
    float r_rel, b_rel;
    fill_rows(0, SENSOR_H / 2, GREY_R, GREY_G, GREY_B);
    fill_rows(SENSOR_H / 2, SENSOR_H, 3, 1, 1);
    grey_cast(&r_rel, &b_rel);
    CHECK(fabsf(r_rel - 2.0f) < 0.01f && fabsf(b_rel - (float)GREY_G / GREY_B) < 0.01f,
          "near-black samples moved the balance to R/G %.3f B/G %.3f", r_rel, b_rel);

    /* Q9: a blue wall fills 85% of the frame; grey world alone would cut blue to 0.63x and leave
     * the grey card 64% off. The limits keep it closer. */
    fill_rows(0, SENSOR_H * 85 / 100, 80, 250, 450);
    fill_rows(SENSOR_H * 85 / 100, SENSOR_H, GREY_R, GREY_G, GREY_B);
    float cast = grey_cast(&r_rel, &b_rel);
    CHECK(r_rel >= WB_R_MIN && r_rel <= WB_R_MAX && b_rel >= WB_B_MIN && b_rel <= WB_B_MAX,
          "blue wall: gains R/G %.2f B/G %.2f outside the limits", r_rel, b_rel);
    CHECK(cast < 0.45f, "blue wall: grey card off by %.0f%% (unlimited grey world: 64%%)", 100 * cast);
    return check_report("test_lut");
}
