/*
 * isp_replay: run one raw frame from gc2607-raw-capture.sh through the ISP, offline.
 *
 *   isp_replay RAW_FILE OUT_PREFIX [FRAME]
 *
 * Writes OUT_PREFIX.yuyv (the exact bytes the ISP would send to /dev/video50) and OUT_PREFIX.json
 * (size and the controls used). FRAME defaults to the last frame in the file. The output size follows
 * GC2607_ISP_HALF_RES as in the service (1 = 960x540 binned, otherwise 1920x1080), and so does the
 * lens-shading strength, GC2607_ISP_LSC.
 *
 * White balance is the frame's own grey-world gains. Exposure: the sensor controls are fixed in a
 * capture, so the controller's metering (ae_meter_frame) is iterated on a virtual digital gain, without
 * the hardware's 1..2 limit, until it stops asking for a change: the frame as it looks once the
 * controller has converged on it.
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
    select_output_size();
    lsc_init(lsc_strength_from_env());

    /* Statistics are taken from raw values, so the gains used for this first pass do not matter
     * for white balance. */
    struct frame_stats st;
    float r_rel = 1.0f, b_rel = 1.0f, wb[3], d = 1.0f;
    build_luts(1.0f, 1.0f, 1.0f, d);
    collect_stats(bayer, &st);
    wb_from_stats(&st, &r_rel, &b_rel);
    wb_gains(r_rel, b_rel, wb);

    struct ae_meter mt;
    for (int i = 0; i < 40; i++) {
        build_luts(wb[0], wb[1], wb[2], d);
        collect_stats(bayer, &st);
        float factor = ae_meter_frame(&st, wb[1], d, 1, &mt);
        if (factor == 1.0f)
            break;
        d *= factor;
    }
    process_frame(bayer, wb, d, &st);

    char path[4096];
    snprintf(path, sizeof(path), "%s.yuyv", argv[2]);
    FILE *o = fopen(path, "wb");
    if (!o || fwrite(yuyv_buf, out_bytes(), 1, o) != 1) {
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
    fprintf(o, "{\"width\": %d, \"height\": %d, \"frame\": %ld, \"wb\": [%.3f, %.3f, %.3f], "
               "\"d\": %.3f, \"y\": %.3f, \"p98\": %.3f, \"clipped\": %.4f, \"m\": %.3f}\n",
            out_w, out_h, frame, wb[0], wb[1], wb[2], d, mt.y, mt.p98, mt.clipped, mt.m);
    fclose(o);
    return 0;
}
