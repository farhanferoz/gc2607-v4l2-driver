/* Output frame: YUYV packing of pixel pairs (handover Q3a). */
#define main isp_main
#include "../gc2607_isp.c"
#undef main
#include "check.h"

/* BT.601 limited-range chroma of one RGB colour, with this ISP's chroma gain, in floating point. */
static float ref_u(float r, float g, float b) { return 128.0f + (-38 * r - 74 * g + 112 * b) / 256.0f * CHROMA_GAIN_Q8 / 256.0f; }
static float ref_v(float r, float g, float b) { return 128.0f + (112 * r - 94 * g - 18 * b) / 256.0f * CHROMA_GAIN_Q8 / 256.0f; }

int main(void)
{
    /* A red pixel beside a blue one shares one U and one V: they must be the pair's average colour. */
    uint8_t out[4];
    rgb_to_yuyv(255, 0, 0, 0, 0, 255, out);
    float u = ref_u(127.5f, 0, 127.5f), v = ref_v(127.5f, 0, 127.5f);
    CHECK(fabsf(out[1] - u) <= 1.0f, "U %d, want %.1f +/- 1 (the pair's average)", out[1], u);
    CHECK(fabsf(out[3] - v) <= 1.0f, "V %d, want %.1f +/- 1 (the pair's average)", out[3], v);
    return check_report("test_output");
}
