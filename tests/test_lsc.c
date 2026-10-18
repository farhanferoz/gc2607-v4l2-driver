/* Lens-shading correction (handover Q8): a frame shaded exactly as the table describes comes out flat,
 * through the row correction and through every reader of it (statistics, full and half resolution);
 * partial strength scales the luminance part only; a clipped value stays clipped; GC2607_ISP_LSC parsing. */
#define main isp_main
#include "../gc2607_isp.c"
#undef main
#include "check.h"

enum { SIGNAL = 500 };   /* raw counts above black of the flat surface at the centre */

static uint16_t bayer[SENSOR_W * SENSOR_H];
static uint16_t row[SENSOR_W];

static enum lsc_colour colour_at(int y, int x) { return (y & 1) == 0 ? ((x & 1) == 0 ? LSC_GREEN : LSC_RED) : ((x & 1) == 0 ? LSC_BLUE : LSC_GREEN); }

/* The specification, kept apart from lsc_node: only the luminance part is scaled by the strength. */
static float node_ref(int j, int i, enum lsc_colour c, float strength)
{
    float colour = c == LSC_RED ? lsc_red[j][i] : c == LSC_BLUE ? lsc_blue[j][i] : 1.0f;
    return (1.0f + strength * (lsc_luma[j][i] - 1.0f)) * colour;
}

/* Gain at pixel (y, x) in floating point, bilinear between the nodes: the reference for lsc_row. */
static float gain_at(int y, int x, float strength)
{
    float fx = (float)x * (LSC_NX - 1) / (SENSOR_W - 1), fy = (float)y * (LSC_NY - 1) / (SENSOR_H - 1);
    int i = fx < LSC_NX - 1 ? (int)fx : LSC_NX - 2, j = fy < LSC_NY - 1 ? (int)fy : LSC_NY - 2;
    float t = fx - i, u = fy - j;
    enum lsc_colour c = colour_at(y, x);
    return (node_ref(j, i, c, strength) * (1 - t) + node_ref(j, i + 1, c, strength) * t) * (1 - u) +
           (node_ref(j + 1, i, c, strength) * (1 - t) + node_ref(j + 1, i + 1, c, strength) * t) * u;
}

/* Fill bayer with a flat surface of SIGNAL counts as the lens would show it. */
static void fill_shaded(void)
{
    for (int y = 0; y < SENSOR_H; y++)
        for (int x = 0; x < SENSOR_W; x++)
            bayer[y * SENSOR_W + x] = (uint16_t)lroundf(BLACK_LEVEL + SIGNAL / gain_at(y, x, 1.0f));
}

/* Output luma at (y, x) of the current yuyv_buf. */
static int luma_at(int y, int x) { return yuyv_buf[((size_t)y * out_w + x) * 2]; }

/* Largest difference between output luma at the four corners and at the centre. */
static int corner_luma_error(void)
{
    int centre = luma_at(out_h / 2, out_w / 2), err = 0;
    const int ys[2] = { 0, out_h - 1 }, xs[2] = { 0, out_w - 1 };
    for (int a = 0; a < 2; a++)
        for (int b = 0; b < 2; b++) {
            int d = abs(luma_at(ys[a], xs[b]) - centre);
            err = d > err ? d : err;
        }
    return err;
}

static void check_env(const char *value, float want)
{
    if (value)
        setenv("GC2607_ISP_LSC", value, 1);
    else
        unsetenv("GC2607_ISP_LSC");
    float got = lsc_strength_from_env();
    CHECK(got == want, "GC2607_ISP_LSC=%s gives %.2f, want %.2f", value ? value : "(unset)", got, want);
}

int main(void)
{
    fill_shaded();
    const int corner = BLACK_LEVEL + SIGNAL / 3;   /* the table's corner gains are ~5 */
    CHECK(bayer[0] < corner && bayer[SENSOR_W * SENSOR_H - 1] < corner,
          "the synthetic frame is not shaded (corners %d, %d), so nothing below can fail", bayer[0], bayer[SENSOR_W * SENSOR_H - 1]);

    /* Full strength: every corrected value within the rounding of the shaded input (up to ~0.5 x gain). */
    lsc_init(1.0f);
    int worst = 0;
    for (int y = 0; y < SENSOR_H; y++) {
        lsc_row(row, bayer + y * SENSOR_W, y);
        for (int x = 0; x < SENSOR_W; x++) {
            int d = abs(row[x] - (BLACK_LEVEL + SIGNAL));
            worst = d > worst ? d : worst;
        }
    }
    CHECK(worst <= 4, "corrected frame deviates by up to %d counts from flat %d", worst, BLACK_LEVEL + SIGNAL);

    /* Half strength: the luminance part moves halfway, the colour part stays whole. A red pixel at the
     * middle of the left edge: the shaded input times 1 + (luma - 1) / 2, times the colour gain. */
    lsc_init(0.5f);
    int y = SENSOR_H / 2 & ~1, x = 1;
    lsc_row(row, bayer + y * SENSOR_W, y);
    float want = BLACK_LEVEL + (bayer[y * SENSOR_W + x] - BLACK_LEVEL) * gain_at(y, x, 0.5f);
    CHECK(fabsf(row[x] - want) <= 1.0f, "half strength gives %d at the left edge, want %.1f", row[x], want);
    CHECK(row[x] < BLACK_LEVEL + SIGNAL * 0.9f, "half strength corrected the edge fully (%d)", row[x]);

    /* Every reader sees the correction: the statistics, and the corners of both output sizes. */
    const float wb[3] = { 1.0f, 1.0f, 1.0f };
    struct frame_stats st;
    for (int on = 0; on <= 1; on++) {
        lsc_init(on ? 1.0f : -1.0f);
        for (half_res = 0; half_res <= 1; half_res++) {
            out_w = half_res ? HALF_W : SENSOR_W;
            out_h = half_res ? HALF_H : SENSOR_H;
            process_frame(bayer, wb, 1.0f, &st);
            int err = corner_luma_error();
            if (on)
                CHECK(err <= 2, "%s output: corners differ from the centre by %d levels", half_res ? "binned" : "full", err);
            else
                CHECK(err > 40, "%s output without correction: corners within %d levels, so the check above is blind",
                      half_res ? "binned" : "full", err);
        }
        if (on)
            CHECK(fabsf(st.g_mean - SIGNAL) < 0.02f * SIGNAL, "statistics see green %.1f, want %d", st.g_mean, SIGNAL);
    }
    half_res = 0;
    out_w = SENSOR_W;
    out_h = SENSOR_H;

    /* Colour only (strength 0): red is turned down towards the edges, but a clipped red stays clipped. */
    lsc_init(0.0f);
    CHECK(lsc_red[LSC_NY / 2][0] < 1.0f, "no red gain below 1 at the left edge; the clip check needs one");
    bayer[y * SENSOR_W + 1] = LUT_SIZE - 1;
    bayer[y * SENSOR_W + 3] = BLACK_LEVEL + 800;
    lsc_row(row, bayer + y * SENSOR_W, y);
    CHECK(row[1] == LUT_SIZE - 1, "clipped red at the edge became %d", row[1]);
    CHECK(row[3] < BLACK_LEVEL + 800, "red at the edge was not turned down (%d)", row[3]);

    check_env(NULL, LSC_STRENGTH_DEFAULT);
    check_env("off", -1.0f);
    check_env("0", 0.0f);
    check_env("0.5", 0.5f);
    check_env("1", 1.0f);
    check_env("1.5", LSC_STRENGTH_DEFAULT);
    check_env("-0.1", LSC_STRENGTH_DEFAULT);
    check_env("nan", LSC_STRENGTH_DEFAULT);
    check_env("0.5x", LSC_STRENGTH_DEFAULT);
    check_env("", LSC_STRENGTH_DEFAULT);
    return check_report("test_lsc");
}
