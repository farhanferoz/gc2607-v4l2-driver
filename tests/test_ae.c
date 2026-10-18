/*
 * Exposure controller (handover Q1) against a simulated sensor: raw = black + radiance x exposure
 * x gain, clipped at 1023, with controls taking effect AE_LATENCY_FRAMES frames after a write.
 */
#define main isp_main
#include "../gc2607_isp.c"
#undef main
#include "check.h"

#define FRAMES 240

static uint16_t bayer[SENSOR_W * SENSOR_H];
static float radiance[HALF_H][HALF_W];   /* grey scene, per 2x2 block */

static float y_trace[FRAMES];
static struct ae_hw hw_trace[FRAMES];    /* controls each frame was taken with */

/* Horizontal gradient 0.2..1.0; `backlit` adds a window at 50x covering 2.2% of the frame (just over
 * AE_CLIP_FRACTION once sampled, so it clips). */
static void make_scene(int backlit)
{
    for (int y = 0; y < HALF_H; y++)
        for (int x = 0; x < HALF_W; x++)
            radiance[y][x] = 0.2f + 0.8f * x / HALF_W;
    if (backlit)
        for (int y = 0; y < 80; y++)
            for (int x = 0; x < 144; x++)
                radiance[y][x] *= 50.0f;
}

static void expose(float light, const struct ae_hw *h)
{
    float k = light * h->exposure * gain_of(h->gain);   /* radiance 1 at 30 ms, unity gain: ~full scale */
    for (int y = 0; y < HALF_H; y++)
        for (int x = 0; x < HALF_W; x++) {
            uint16_t v = (uint16_t)(BLACK_LEVEL + fminf(radiance[y][x] * k, MAX_SIGNAL));
            uint16_t *p = bayer + (2 * y) * SENSOR_W + 2 * x;
            p[0] = p[1] = p[SENSOR_W] = p[SENSOR_W + 1] = v;
        }
}

/* Run the controller for `n` frames at `light`, recording each frame's display Y and controls. */
static void simulate(struct ae_state *s, float light, int n)
{
    struct ae_hw sensor = s->cur, pending = s->cur;
    int pending_in = 0;
    for (int f = 0; f < n; f++) {
        if (pending_in > 0 && --pending_in == 0)
            sensor = pending;
        expose(light, &sensor);
        struct frame_stats st;
        struct ae_meter mt;
        build_luts(1.0f, 1.0f, 1.0f, s->cur.d);
        collect_stats(bayer, &st);
        float factor = ae_meter_frame(&st, 1.0f, s->cur.d, s->session_frames++ < AE_FAST_FRAMES, &mt);
        y_trace[f] = st.y_mean;
        hw_trace[f] = sensor;
        hw_trace[f].d = s->cur.d;
        struct ae_hw w;
        if (ae_step(s, factor, &w)) {
            pending = w;
            pending_in = AE_LATENCY_FRAMES + 1;
        }
    }
}

static struct ae_state start(int exposure, int gain, float d)
{
    struct ae_state s = { .cur = { exposure, gain, FLL_MIN, d }, .flicker_lines = 334 };
    if (exposure + EXPOSURE_MARGIN > FLL_MIN)
        s.cur.fll = exposure + EXPOSURE_MARGIN;
    return s;
}

static int converged(int f) { return fabsf(y_trace[f] - AE_TARGET_Y) <= 0.1f * AE_TARGET_Y; }

/* Frame-to-frame Y steps from `from` to `to`: none over `limit` (relative). */
static void check_steps(const char *what, int from, int to, float limit)
{
    for (int f = from + 1; f < to; f++) {
        float step = fabsf(y_trace[f] / y_trace[f - 1] - 1.0f);
        CHECK(step <= limit, "%s: Y moved %.1f%% at frame %d (limit %.0f%%)", what, 100 * step, f, 100 * limit);
    }
}

int main(void)
{
    make_scene(0);

    /* (1) Convergence from a dark and from a saturated start, (5) then stability. */
    const struct { const char *name; int e, g; float d; } starts[] = {
        { "dark start", EXPOSURE_MIN, 0, 1.0f }, { "bright start", EXPOSURE_15FPS, GAIN_MAX, DIGITAL_MAX } };
    for (int i = 0; i < 2; i++) {
        struct ae_state s = start(starts[i].e, starts[i].g, starts[i].d);
        simulate(&s, 1.0f, 120);
        CHECK(converged(59), "%s: Y %.3f at frame 60, want %.3f +/- 10%%", starts[i].name, y_trace[59], AE_TARGET_Y);
        /* The last full-strength start-up write shows AE_LATENCY_FRAMES + 1 frames later. */
        check_steps(starts[i].name, AE_FAST_FRAMES + AE_LATENCY_FRAMES + 1, 60, 0.12f);
        check_steps(starts[i].name, 60, 120, 0.03f);
    }

    /* (2) The ratchet: settle in dim light (gain up), then 8x brighter must give the gain back. */
    struct ae_state s = start(EXPOSURE_30FPS, 0, 1.0f);
    simulate(&s, 1.0f / 20, 150);
    int dim_exposure = hw_trace[149].exposure;
    CHECK(hw_trace[149].gain > 0, "dim light settled without gain (exposure %d)", dim_exposure);
    simulate(&s, 8.0f / 20, 90);
    CHECK(hw_trace[89].gain == 0, "8x brighter: gain index still %d after 90 frames", hw_trace[89].gain);
    CHECK(hw_trace[89].exposure < dim_exposure, "8x brighter: exposure %d not below %d", hw_trace[89].exposure, dim_exposure);
    check_steps("8x brighter", 1, 90, 0.12f);

    /* (3) Much darker: exposure, then gain to 3.95x, then a longer frame, then more gain. */
    s = start(EXPOSURE_30FPS, 0, 1.0f);
    simulate(&s, 1.0f, 120);
    simulate(&s, 1.0f / 40, FRAMES);
    for (int f = 0; f < FRAMES; f++) {
        const struct ae_hw *h = &hw_trace[f];
        CHECK(h->gain == 0 || h->exposure == EXPOSURE_30FPS || h->gain >= GAIN_30FPS,
              "frame %d: gain %d before the exposure reached 30 ms (%d)", f, h->gain, h->exposure);
        CHECK(h->fll == FLL_MIN || h->gain >= GAIN_30FPS, "frame %d: frame length %d at gain %d", f, h->fll, h->gain);
        CHECK(h->gain <= GAIN_30FPS || h->exposure == EXPOSURE_15FPS,
              "frame %d: gain %d before the exposure reached 60 ms (%d)", f, h->gain, h->exposure);
    }
    CHECK(hw_trace[FRAMES - 1].gain > GAIN_30FPS && converged(FRAMES - 1),
          "40x darker: ended at gain %d, Y %.3f", hw_trace[FRAMES - 1].gain, y_trace[FRAMES - 1]);
    check_steps("40x darker", 1, FRAMES, 0.12f);

    /* (4) Backlight: the window may clip, but the subject keeps Y >= AE_FLOOR_Y. */
    make_scene(1);
    s = start(EXPOSURE_30FPS, 0, 1.0f);
    simulate(&s, 1.0f, 120);
    CHECK(y_trace[119] >= AE_FLOOR_Y - 0.01f, "backlit: Y %.3f, floor %.2f", y_trace[119], AE_FLOOR_Y);

    /* (6) Allocation over the whole range, at 50 Hz. */
    double max_total = EXPOSURE_15FPS * (double)gain_of(GAIN_MAX) * DIGITAL_MAX;
    for (double t = EXPOSURE_MIN; t <= max_total; t *= 1.01) {
        struct ae_hw h = ae_allocate(t, 334);
        double got = h.exposure * (double)gain_of(h.gain) * h.d;
        CHECK(fabs(got / t - 1) <= 0.01, "total %.1f allocated as %.1f", t, got);
        CHECK(t > EXPOSURE_30FPS || h.gain == 0, "total %.1f uses gain %d", t, h.gain);
        CHECK(h.exposure < 334 || h.exposure % 334 == 0, "total %.1f: exposure %d not whole 10 ms", t, h.exposure);
        CHECK(h.fll == (h.exposure > FLL_MIN - EXPOSURE_MARGIN ? h.exposure + EXPOSURE_MARGIN : FLL_MIN),
              "total %.1f: frame length %d for exposure %d", t, h.fll, h.exposure);
        CHECK(h.d >= 1.0f && h.d <= DIGITAL_MAX, "total %.1f: digital gain %.3f", t, h.d);
    }
    return check_report("test_ae");
}
