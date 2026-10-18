/*
 * Per-frame timing of the ISP's processing on a synthetic 1920x1080 frame.
 * Run through `make bench`, which pins it to a performance, an efficiency and a
 * low-power core (cpus 0, 12, 20 on this laptop). A 30 fps frame allows 33 ms.
 */
#define main isp_main
#include "../gc2607_isp.c"
#undef main
#include "bench_common.h"

static uint16_t bayer[SENSOR_W * SENSOR_H];

int main(void)
{
    const float wb[3] = { 2.0f, 1.0f, 1.6f };
    struct frame_stats st;
    double t[ITER], a;

    fill_bayer(bayer, SENSOR_W * SENSOR_H);
    for (half_res = 0; half_res <= 1; half_res++)
        for (int lsc = 0; lsc <= 1; lsc++) {
            lsc_init(lsc ? LSC_STRENGTH_DEFAULT : -1.0f);
            for (int k = 0; k < 20; k++)
                process_frame(bayer, wb, 1.3f, &st);
            for (int k = 0; k < ITER; k++) {
                a = now_ms();
                process_frame(bayer, wb, 1.3f, &st);
                t[k] = now_ms() - a;
            }
            printf("process_frame (%s, lens shading %s): %.2f ms\n", half_res ? "960x540 binned" : "1920x1080 demosaic",
                   lsc ? "on" : "off", median_ms(t));
        }

    for (int k = 0; k < ITER; k++) {
        a = now_ms();
        chroma_median_filter(yuyv_buf, HALF_W, HALF_H);
        t[k] = now_ms() - a;
    }
    printf("  of which (binned) chroma_median_filter: %.2f ms\n", median_ms(t));
    return 0;
}
