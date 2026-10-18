/*
 * isp_replay: run one raw frame from gc2607-raw-capture.sh through the ISP, offline.
 *
 *   isp_replay RAW_FILE OUT_PREFIX [FRAME]
 *
 * Writes OUT_PREFIX.yuyv (the exact bytes the ISP would send to /dev/video50) and OUT_PREFIX.json
 * (size and the controls used). FRAME defaults to the last frame in the file.
 *
 * White balance and software brightness are the values today's streaming loop settles at for this
 * frame: grey-world gains, and min(mean target, highlight cap) from the frame's own statistics (both
 * targets are independent of the current brightness, so the steady state has a closed form). When the
 * exposure controller is rewritten (handover Q1), call the new controller here instead.
 */
#define main isp_main
#include "../gc2607_isp.c"
#undef main

static uint16_t bayer[FRAME_PIXELS];

int main(int argc, char **argv)
{
    if (argc < 3 || argc > 4) {
        fprintf(stderr, "usage: %s RAW_FILE OUT_PREFIX [FRAME]\n", argv[0]);
        return 2;
    }
    FILE *f = fopen(argv[1], "rb");
    if (!f) {
        perror(argv[1]);
        return 1;
    }
    fseek(f, 0, SEEK_END);
    long frames = ftell(f) / (long)sizeof(bayer);
    long frame = argc == 4 ? atol(argv[3]) : frames - 1;
    if (frames < 1 || frame < 0 || frame >= frames) {
        fprintf(stderr, "%s holds %ld frames; frame %ld is out of range\n", argv[1], frames, frame);
        return 1;
    }
    fseek(f, frame * (long)sizeof(bayer), SEEK_SET);
    if (fread(bayer, sizeof(bayer), 1, f) != 1) {
        perror("read frame");
        return 1;
    }
    fclose(f);

    float r_mean, g_mean, b_mean;
    uint32_t hist[HISTOGRAM_BINS];
    int hist_total, stat_count;

    /* Pass 1: statistics only (they are taken from raw values, so gains do not matter). */
    process_frame(bayer, 1.0f, 1.0f, 1.0f, &r_mean, &g_mean, &b_mean, hist, &hist_total, &stat_count);
    float g_target = compute_ae_zone_target();

    float r_gain = 1.0f, b_gain = 1.0f;
    if (r_mean > 1.0f && g_mean > 1.0f && b_mean > 1.0f) {
        r_gain = fminf(fmaxf(g_mean / r_mean, 0.25f), 4.0f);
        b_gain = fminf(fmaxf(g_mean / b_mean, 0.25f), 4.0f);
    }

    float bright_for_mean = g_target > 0.0f ? AE_TARGET * MAX_SIGNAL / (g_target * 255.0f) : BRIGHTNESS_MAX;
    float bright_for_cap = BRIGHTNESS_MAX;
    if (hist_total > 0) {
        int threshold = (int)(hist_total * AE_HIGHLIGHT_PCTILE), cum = 0, p_bin = HISTOGRAM_BINS - 1;
        for (int b = 0; b < HISTOGRAM_BINS; b++) {
            cum += hist[b];
            if (cum >= threshold) {
                p_bin = b;
                break;
            }
        }
        float pctile_raw = fmaxf((p_bin + 0.5f) * (float)HIST_BIN_WIDTH - BLACK_LEVEL, 1.0f);
        bright_for_cap = AE_HIGHLIGHT_CAP * MAX_SIGNAL / (pctile_raw * 255.0f);
    }
    float brightness = fminf(fmaxf(fminf(bright_for_mean, bright_for_cap), BRIGHTNESS_MIN), BRIGHTNESS_MAX);

    /* Pass 2: the frame as the ISP would output it. */
    process_frame(bayer, r_gain, b_gain, brightness, &r_mean, &g_mean, &b_mean, hist, &hist_total, &stat_count);

    char path[4096];
    snprintf(path, sizeof(path), "%s.yuyv", argv[2]);
    FILE *o = fopen(path, "wb");
    if (!o || fwrite(yuyv_buf, sizeof(yuyv_buf), 1, o) != 1) {
        perror(path);
        return 1;
    }
    fclose(o);
    snprintf(path, sizeof(path), "%s.json", argv[2]);
    o = fopen(path, "w");
    if (!o) {
        perror(path);
        return 1;
    }
    fprintf(o, "{\"width\": %d, \"height\": %d, \"frame\": %ld, \"r_gain\": %.3f, \"b_gain\": %.3f, "
               "\"brightness\": %.3f, \"bright_for_mean\": %.3f, \"bright_for_cap\": %.3f}\n",
            OUT_W, OUT_H, frame, r_gain, b_gain, brightness, bright_for_mean, bright_for_cap);
    fclose(o);
    return 0;
}
