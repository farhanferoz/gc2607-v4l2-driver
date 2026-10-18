/* Output frame: YUYV packing of pixel pairs (handover Q3a) and the full-resolution demosaic (Q3b). */
#define main isp_main
#include "../gc2607_isp.c"
#undef main
#include "check.h"

static uint16_t bayer[SENSOR_W * SENSOR_H];

/* BT.601 limited-range chroma of one RGB colour, with this ISP's chroma gain, in floating point. */
static float ref_u(float r, float g, float b) { return 128.0f + (-38 * r - 74 * g + 112 * b) / 256.0f * CHROMA_GAIN_Q8 / 256.0f; }
static float ref_v(float r, float g, float b) { return 128.0f + (112 * r - 94 * g - 18 * b) / 256.0f * CHROMA_GAIN_Q8 / 256.0f; }

/* Run the ISP on `bayer` with unit white balance and brightness. */
static void run(void)
{
    const float wb[3] = { 1.0f, 1.0f, 1.0f };
    struct frame_stats st;
    process_frame(bayer, wb, 1.0f, &st);
}

static const uint8_t *pair_at(int y, int pair) { return yuyv_buf + ((size_t)y * out_w + pair * 2) * 2; }

int main(void)
{
    /* A red pixel beside a blue one shares one U and one V: they must be the pair's average colour. */
    uint8_t out[4];
    rgb_to_yuyv(255, 0, 0, 0, 0, 255, out);
    float u = ref_u(127.5f, 0, 127.5f), v = ref_v(127.5f, 0, 127.5f);
    CHECK(fabsf(out[1] - u) <= 1.0f, "U %d, want %.1f +/- 1 (the pair's average)", out[1], u);
    CHECK(fabsf(out[3] - v) <= 1.0f, "V %d, want %.1f +/- 1 (the pair's average)", out[3], v);

    CHECK(out_w == SENSOR_W && out_h == SENSOR_H, "default output %dx%d, want full resolution", out_w, out_h);

    /* Uniform GRBG frame: every output pixel identical, borders included. */
    for (int y = 0; y < SENSOR_H; y++)
        for (int x = 0; x < SENSOR_W; x++)
            bayer[y * SENSOR_W + x] = (y & 1) == 0 ? ((x & 1) == 0 ? 300 : 500) : ((x & 1) == 0 ? 200 : 300);
    run();
    int odd = 0;
    for (size_t i = 0; i < out_bytes(); i += 4)
        odd += yuyv_buf[i] != yuyv_buf[0] || yuyv_buf[i + 2] != yuyv_buf[0] || yuyv_buf[i + 1] != yuyv_buf[1] ||
               yuyv_buf[i + 3] != yuyv_buf[3];
    CHECK(odd == 0, "%d of %zu pairs differ from the first in a uniform frame", odd, out_bytes() / 4);

    /* Grey vertical step at source column 960: colour may appear only where the interpolation
     * straddles it, source columns 959 and 960, i.e. output pairs 480 and 479 after the rotation. */
    for (int y = 0; y < SENSOR_H; y++)
        for (int x = 0; x < SENSOR_W; x++)
            bayer[y * SENSOR_W + x] = x < SENSOR_W / 2 ? 200 : 600;
    run();
    int stray = 0, edge = 0;
    for (int y = 0; y < SENSOR_H; y++)
        for (int p = 0; p < SENSOR_W / 2; p++) {
            const uint8_t *q = pair_at(y, p);
            int coloured = q[1] != 128 || q[3] != 128;
            if (p == 479 || p == 480)
                edge += coloured;
            else
                stray += coloured;
        }
    CHECK(stray == 0, "%d pairs away from the edge carry colour", stray);
    CHECK(edge > 0, "the edge pairs carry no colour, so this check cannot see any");
    CHECK(pair_at(0, 0)[0] > pair_at(0, SENSOR_W / 2 - 1)[2], "not rotated: output left is darker than right");
    return check_report("test_output");
}
