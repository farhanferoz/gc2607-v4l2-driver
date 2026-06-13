/*
 * gc2607_isp.c — Lightweight userspace ISP for GC2607 camera sensor
 *
 * Captures raw 10-bit Bayer GRBG from V4L2, applies:
 *   - 2x2 Bayer binning (demosaic to half resolution)
 *   - Black level subtraction
 *   - Gray-world auto white balance
 *   - Auto-exposure (software + hardware)
 *   - S-curve contrast + sRGB gamma via per-channel LUT
 *   - 180° rotation
 * Outputs YUYV to v4l2loopback.
 *
 * Lazy activation: the ISP idles with zero CPU usage until a consumer
 * application opens /dev/video50. When all consumers close the device,
 * the ISP stops streaming and releases the sensor hardware.
 *
 * Usage: gc2607_isp <capture_dev> <output_dev>
 *   e.g. gc2607_isp /dev/video1 /dev/video50
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <signal.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/inotify.h>
#include <sys/select.h>
#include <dirent.h>
#include <limits.h>
#include <linux/videodev2.h>

/* Sensor parameters */
#define SENSOR_W        1920
#define SENSOR_H        1080
#define OUT_W           (SENSOR_W / 2)  /* 960 */
#define OUT_H           (SENSOR_H / 2)  /* 540 */
#define FRAME_PIXELS    (SENSOR_W * SENSOR_H)
#define LUT_SIZE        1024  /* 10-bit sensor values 0..1023 */

/* ISP parameters */
#define BLACK_LEVEL     64    /* Sensor hardware black level */
#define MAX_SIGNAL      959.0f  /* 1023 - 64 = usable range */

/* Auto white balance */
#define WB_SMOOTHING    0.85f   /* Temporal smoothing (higher = more stable) */
#define WB_SUBSAMPLE    8       /* Sample every Nth pixel for WB stats */

/*
 * Auto exposure — multi-zone AE with shadow-priority metering, plus
 * percentile highlight cap. Models what hardware ISPs (Intel IPU6, RPi
 * IPA) do: divide the frame into a grid, compute per-zone luma, and pick
 * an exposure target that exposes the *darker* regions. This handles
 * backlit subjects correctly regardless of where the subject is in the
 * frame — centre weighting fails when the subject isn't centred or the
 * centre contains the bright background (e.g. window).
 *
 *  1. Mean target: AE_TARGET applied to the mean of the AE_DARK_FRACTION
 *     darkest zones. Backlit face gets exposed; bright window/wall doesn't
 *     drag exposure down.
 *  2. Highlight cap: the AE_HIGHLIGHT_PCTILE percentile of green must stay
 *     at or below AE_HIGHLIGHT_CAP — this is now the *only* line of
 *     defence against wall blowout (LTM is permanently disabled — see
 *     main loop) so the cap is held tight.
 */
#define AE_TARGET           100.0f  /* mean (0-255) for the dark-zones target */
#define AE_HIGHLIGHT_PCTILE 0.98f
#define AE_HIGHLIGHT_CAP    220.0f  /* 98th-pctile green ceiling — sole defence against wall blowout */
#define AE_SMOOTHING        0.92f
#define AE_INTERVAL_S       1.5
#define BRIGHTNESS_MIN      0.5f
#define BRIGHTNESS_MAX      3.5f

/* Multi-zone AE grid over the output frame. */
#define AE_ZONES_X          16
#define AE_ZONES_Y          16
#define AE_ZONES            (AE_ZONES_X * AE_ZONES_Y)
#define AE_DARK_FRACTION    0.25f   /* expose for the darkest 25% of zones */

/* Green-channel histogram for highlight cap. */
#define HISTOGRAM_BINS      64
#define HIST_BIN_WIDTH      (LUT_SIZE / HISTOGRAM_BINS)

/*
 * Local tone mapping (LTM) — per-pixel Y compression based on local
 * luminance. The same tool the IPU6 hardware ISP uses for WDR; we do it
 * in software at the end of the pipeline. Bright local regions (window,
 * walls) get scaled toward LTM_TARGET_Y; dark regions (face in shadow)
 * pass through unchanged. Decouples exposure choice from output dynamic
 * range, which is the only reliable way to handle bright-background +
 * shadowed-subject scenes without a multi-shot HDR sensor.
 *
 * Grid is OUT_W/OUT_H downsampled by ~16; bilinearly upsampled when
 * applied. Temporal EMA prevents per-frame flicker.
 */
#define LTM_GRID_X          60          /* ~OUT_W/16 */
#define LTM_GRID_Y          34          /* ~OUT_H/16 (rounded up) */
#define LTM_CELL_W          (OUT_W / LTM_GRID_X)
#define LTM_CELL_H          ((OUT_H + LTM_GRID_Y - 1) / LTM_GRID_Y)
#define LTM_TARGET_Y        128.0f      /* compress bright cells toward this Y */
#define LTM_KNEE            120.0f      /* cells with mean Y below this: identity */
#define LTM_STRENGTH        0.7f        /* 0=no compression, 1=hard */
/* Temporal blend = 1.0 means no EMA — fresh grid every frame. The lower
 * values that seem theoretically nicer in fact carry the previous frame's
 * grid into the current frame, and when the subject moves the old grid
 * leaves a ghost (cells that were "face/low compression" stay low while
 * the wall has moved into them, leaving a face-shaped bright patch).
 * Webcam scenes are static enough that fresh-each-frame is stable. */
#define LTM_TEMPORAL_BLEND  1.0f
/* Bilateral filter on the grid. Spatial sigma in cells; range sigma in Y
 * units. The range term is what kills the halo: cells across a face/wall
 * boundary differ by ~80-120 Y, far beyond LTM_BF_SIGMA_R, so the filter
 * refuses to average them — each side keeps its own compression factor. */
#define LTM_BF_RADIUS       2           /* 5x5 kernel */
#define LTM_BF_SIGMA_S      1.5f
#define LTM_BF_SIGMA_R      30.0f

/* Sensor hardware limits */
#define EXPOSURE_MIN    4
#define EXPOSURE_MAX    2002
#define GAIN_MIN        0
#define GAIN_MAX        16

/* V4L2 capture buffers */
#define NUM_BUFFERS     4

/* Lazy activation: how often to write standby frames while idle (ms) */
#define STANDBY_INTERVAL_MS  2000

/* During streaming, how often to check if consumers are still present (s) */
#define CONSUMER_CHECK_INTERVAL_S  2.0

static volatile sig_atomic_t running = 1;

/* inotify-based consumer tracking */
static int inotify_fd = -1;
static int inotify_wd = -1;
static int consumer_count = 0;

struct buffer {
    void   *start;
    size_t  length;
};

/* Per-channel LUTs: input 10-bit value -> output 8-bit value */
static uint8_t lut_r[LUT_SIZE];
static uint8_t lut_g[LUT_SIZE];
static uint8_t lut_b[LUT_SIZE];

/* Output YUYV buffer (960x540x2 bytes) */
static uint8_t yuyv_buf[OUT_W * OUT_H * 2];

static void signal_handler(int sig)
{
    (void)sig;
    running = 0;
}

static int xioctl(int fd, unsigned long request, void *arg)
{
    int r;
    do {
        r = ioctl(fd, request, arg);
    } while (r == -1 && errno == EINTR);
    return r;
}

/*
 * The earlier ACES + asymmetric tone shape stack is removed: with LTM
 * doing the dynamic-range compression in display space, the global LUT
 * just needs to do exposure scaling, mild midtone contrast, and sRGB
 * gamma encoding. The smoothstep gives a small S-curve in midtones; LTM
 * handles the bright regions per-pixel based on local luminance, which
 * a global curve cannot do regardless of how it's shaped.
 */

/*
 * Build per-channel LUTs that encode the per-pixel pipeline:
 *   black_level_subtract -> WB_gain -> exposure -> smoothstep -> sRGB gamma
 *
 * Smoothstep gives mild midtone contrast (was the original behaviour
 * before the ACES experiments). Highlight handling is now LTM's job, so
 * this LUT can stay simple: clamp to [0,1], smoothstep, gamma.
 *
 * Called once per frame with updated WB gains and brightness.
 */
static void build_luts(float r_gain, float g_gain, float b_gain, float brightness)
{
    float scale_r = r_gain * brightness / MAX_SIGNAL;
    float scale_g = g_gain * brightness / MAX_SIGNAL;
    float scale_b = b_gain * brightness / MAX_SIGNAL;

    for (int i = 0; i < LUT_SIZE; i++) {
        float raw = (float)(i - BLACK_LEVEL);
        if (raw < 0.0f) raw = 0.0f;

        /* R channel */
        float vr = raw * scale_r;
        if (vr > 1.0f) vr = 1.0f;
        vr = vr * vr * (3.0f - 2.0f * vr);       /* smoothstep midtone contrast */
        vr = powf(vr, 1.0f / 2.2f);              /* sRGB gamma */
        lut_r[i] = (uint8_t)(vr * 255.0f + 0.5f);

        /* G channel */
        float vg = raw * scale_g;
        if (vg > 1.0f) vg = 1.0f;
        vg = vg * vg * (3.0f - 2.0f * vg);
        vg = powf(vg, 1.0f / 2.2f);
        lut_g[i] = (uint8_t)(vg * 255.0f + 0.5f);

        /* B channel */
        float vb = raw * scale_b;
        if (vb > 1.0f) vb = 1.0f;
        vb = vb * vb * (3.0f - 2.0f * vb);
        vb = powf(vb, 1.0f / 2.2f);
        lut_b[i] = (uint8_t)(vb * 255.0f + 0.5f);
    }
}

/*
 * Chroma denoise: 3x3 median filter on U and V only (Y untouched).
 *
 * Why a median, not a linear blur: this output suffers from Bayer chroma
 * moiré — false colour from fine repeating textures (e.g. corduroy ribs)
 * beating against our 2x2 binning grid. The artifact appears as outlier
 * U/V values relative to local neighbours, not as zero-mean noise. A
 * linear blur (which we tried) attenuates outliers proportionally but
 * spreads them across neighbours; a median rejects them outright while
 * preserving real colour edges. This is the standard false-colour-
 * suppression pass in production raw processors (see darktable
 * "color smoothing", and Lukac/Plataniotis 2004, "False Color Suppression
 * in Demosaiced Color Images").
 *
 * The kernel reaches across two pixels horizontally (one chroma sample =
 * one YUYV pair) and two rows vertically, so it covers a 6x3 pixel area
 * with 9 chroma samples — enough to dominate moiré stripes wider than
 * one chroma sample.
 *
 * Implementation: process top-to-bottom keeping the previous row's
 * original U/V in a small ring buffer so the median sees pre-modification
 * neighbours. Uses Smith's 19-comparator network for the median of 9.
 */

/* Branchless min/max swap of two uint8_t values. */
#define MMSWAP(a, b) do { \
    uint8_t _mn = (a) < (b) ? (a) : (b); \
    uint8_t _mx = (a) + (b) - _mn;        \
    (a) = _mn; (b) = _mx;                 \
} while (0)

static inline uint8_t median9(uint8_t *v)
{
    /* Smith 1996, "Fast Median Search": 19-comparator network.
     * Sorts only enough to leave the median at v[4]. */
    MMSWAP(v[1], v[2]); MMSWAP(v[4], v[5]); MMSWAP(v[7], v[8]);
    MMSWAP(v[0], v[1]); MMSWAP(v[3], v[4]); MMSWAP(v[6], v[7]);
    MMSWAP(v[1], v[2]); MMSWAP(v[4], v[5]); MMSWAP(v[7], v[8]);
    MMSWAP(v[0], v[3]); MMSWAP(v[5], v[8]); MMSWAP(v[4], v[7]);
    MMSWAP(v[3], v[6]); MMSWAP(v[1], v[4]); MMSWAP(v[2], v[5]);
    MMSWAP(v[4], v[7]); MMSWAP(v[4], v[2]); MMSWAP(v[6], v[4]);
    MMSWAP(v[4], v[2]);
    return v[4];
}

static void chroma_median_filter(uint8_t *buf, int width, int height)
{
    int row_bytes = width * 2;
    int npairs = width / 2;

    /* Two saved rows of pre-modification chroma so the median sees the
     * original neighbours regardless of in-place writes above. ~1.9 KB. */
    static uint8_t above_u[OUT_W / 2], above_v[OUT_W / 2];
    static uint8_t current_u[OUT_W / 2], current_v[OUT_W / 2];

    /* Seed: above = row 0 (left untouched), current = row 1 (about to be processed). */
    for (int i = 0; i < npairs; i++) {
        above_u[i]   = buf[0 * row_bytes + i * 4 + 1];
        above_v[i]   = buf[0 * row_bytes + i * 4 + 3];
        current_u[i] = buf[1 * row_bytes + i * 4 + 1];
        current_v[i] = buf[1 * row_bytes + i * 4 + 3];
    }

    for (int y = 1; y < height - 1; y++) {
        uint8_t *row       = buf + y * row_bytes;
        uint8_t *row_below = buf + (y + 1) * row_bytes;

        for (int i = 1; i < npairs - 1; i++) {
            uint8_t u9[9] = {
                above_u[i - 1],   above_u[i],   above_u[i + 1],
                current_u[i - 1], current_u[i], current_u[i + 1],
                row_below[(i - 1) * 4 + 1], row_below[i * 4 + 1], row_below[(i + 1) * 4 + 1],
            };
            uint8_t v9[9] = {
                above_v[i - 1],   above_v[i],   above_v[i + 1],
                current_v[i - 1], current_v[i], current_v[i + 1],
                row_below[(i - 1) * 4 + 3], row_below[i * 4 + 3], row_below[(i + 1) * 4 + 3],
            };
            row[i * 4 + 1] = median9(u9);
            row[i * 4 + 3] = median9(v9);
        }

        /* Roll buffers: above <= current; current <= original of row y+1. */
        if (y + 1 < height - 1) {
            uint8_t *next = buf + (y + 1) * row_bytes;
            for (int i = 0; i < npairs; i++) {
                above_u[i]   = current_u[i];
                above_v[i]   = current_v[i];
                current_u[i] = next[i * 4 + 1];
                current_v[i] = next[i * 4 + 3];
            }
        }
    }
}

/*
 * RGB to YUYV conversion for a pair of pixels.
 * YUYV packs two pixels as: Y0 U Y1 V
 */
static inline void rgb_to_yuyv(uint8_t r0, uint8_t g0, uint8_t b0,
                                uint8_t r1, uint8_t g1, uint8_t b1,
                                uint8_t *out)
{
    /* BT.601 full-range coefficients */
    int y0 = ((66 * r0 + 129 * g0 + 25 * b0 + 128) >> 8) + 16;
    int y1 = ((66 * r1 + 129 * g1 + 25 * b1 + 128) >> 8) + 16;
    int u  = ((-38 * r0 - 74 * g0 + 112 * b0 + 128) >> 8) + 128;
    int v  = ((112 * r0 - 94 * g0 - 18 * b0 + 128) >> 8) + 128;

    out[0] = (uint8_t)(y0 < 16 ? 16 : (y0 > 235 ? 235 : y0));
    out[1] = (uint8_t)(u  < 16 ? 16 : (u  > 240 ? 240 : u));
    out[2] = (uint8_t)(y1 < 16 ? 16 : (y1 > 235 ? 235 : y1));
    out[3] = (uint8_t)(v  < 16 ? 16 : (v  > 240 ? 240 : v));
}

/*
 * Process one Bayer frame -> YUYV output with 180 degree rotation.
 *
 * Bayer GRBG pattern:
 *   Row 0: G R G R G R ...
 *   Row 1: B G B G B G ...
 *
 * 2x2 binning: each 2x2 block -> one output pixel (R, avg(G1,G2), B).
 * 180 degree rotation: output rows/cols are reversed.
 *
 * Returns the subsampled green mean for AE.
 */
/*
 * Per-frame multi-zone AE accumulators. Populated during process_frame's
 * stat-pixel sweep; consumed by compute_ae_zone_target() in the main loop.
 */
static uint64_t ae_zone_g_sum[AE_ZONES];
static uint32_t ae_zone_g_count[AE_ZONES];

static float process_frame(const uint16_t *bayer, float r_gain, float b_gain,
                           float brightness, float *out_r_sum, float *out_g_sum,
                           float *out_b_sum,
                           uint32_t *out_g_hist, int *out_hist_total,
                           int *out_count)
{
    /* Green gain is always 1.0 in gray-world WB */
    build_luts(r_gain, 1.0f, b_gain, brightness);

    double r_sum = 0, g_sum = 0, b_sum = 0;
    int stat_count = 0;
    int hist_total = 0;
    for (int i = 0; i < HISTOGRAM_BINS; i++) out_g_hist[i] = 0;
    for (int i = 0; i < AE_ZONES; i++) {
        ae_zone_g_sum[i] = 0;
        ae_zone_g_count[i] = 0;
    }

    /*
     * Iterate output pixels in reverse for 180 degree rotation.
     * Output row (OUT_H-1-oy) col (OUT_W-1-ox) maps to Bayer block at (oy*2, ox*2).
     */
    for (int oy = 0; oy < OUT_H; oy++) {
        /* Bayer row pointers for this 2x2 block row */
        const uint16_t *row0 = bayer + (oy * 2) * SENSOR_W;
        const uint16_t *row1 = bayer + (oy * 2 + 1) * SENSOR_W;

        /* Output row (flipped) */
        int out_y = OUT_H - 1 - oy;
        uint8_t *out_row = yuyv_buf + out_y * OUT_W * 2;

        /* Process pairs of output pixels for YUYV packing */
        for (int ox = 0; ox < OUT_W; ox += 2) {
            int bx0 = ox * 2;
            int bx1 = (ox + 1) * 2;

            /* Extract Bayer values for pixel 0 */
            uint16_t g1_0 = row0[bx0];       /* G at (0,0) */
            uint16_t r_0  = row0[bx0 + 1];   /* R at (0,1) */
            uint16_t b_0  = row1[bx0];        /* B at (1,0) */
            uint16_t g2_0 = row1[bx0 + 1];   /* G at (1,1) */

            /* Extract Bayer values for pixel 1 */
            uint16_t g1_1 = row0[bx1];
            uint16_t r_1  = row0[bx1 + 1];
            uint16_t b_1  = row1[bx1];
            uint16_t g2_1 = row1[bx1 + 1];

            /* Clamp to 10-bit range */
            if (r_0  >= LUT_SIZE) r_0  = LUT_SIZE - 1;
            if (b_0  >= LUT_SIZE) b_0  = LUT_SIZE - 1;
            if (r_1  >= LUT_SIZE) r_1  = LUT_SIZE - 1;
            if (b_1  >= LUT_SIZE) b_1  = LUT_SIZE - 1;

            /* Green average via LUT: average the two raw greens, then LUT */
            uint16_t gavg_0 = (g1_0 + g2_0) >> 1;
            uint16_t gavg_1 = (g1_1 + g2_1) >> 1;
            if (gavg_0 >= LUT_SIZE) gavg_0 = LUT_SIZE - 1;
            if (gavg_1 >= LUT_SIZE) gavg_1 = LUT_SIZE - 1;

            /* Apply LUTs */
            uint8_t R0 = lut_r[r_0],  G0 = lut_g[gavg_0], B0 = lut_b[b_0];
            uint8_t R1 = lut_r[r_1],  G1 = lut_g[gavg_1], B1 = lut_b[b_1];

            /* Write YUYV (flipped horizontally too for 180 degree rotation) */
            int out_x = OUT_W - 2 - ox;
            /* Swap pixel order within the pair for horizontal flip */
            rgb_to_yuyv(R1, G1, B1, R0, G0, B0, out_row + out_x * 2);

            /* Accumulate WB + AE statistics (subsampled). */
            if ((oy & (WB_SUBSAMPLE - 1)) == 0 && (ox & (WB_SUBSAMPLE - 1)) == 0) {
                /* Histogram: every sampled pixel including saturated ones —
                 * the highlight cap explicitly needs to see clipped values. */
                int hbin = gavg_0 / HIST_BIN_WIDTH;
                if (hbin >= HISTOGRAM_BINS) hbin = HISTOGRAM_BINS - 1;
                out_g_hist[hbin]++;
                hist_total++;

                /* WB / mean stats: skip saturated — clipped values hide the
                 * true channel ratio, causing AWB to underestimate green
                 * dominance in bright scenes. */
                if (r_0 < 1020 && gavg_0 < 1020 && b_0 < 1020) {
                    float rv = (float)r_0 - BLACK_LEVEL;
                    float gv = (float)gavg_0 - BLACK_LEVEL;
                    float bv = (float)b_0 - BLACK_LEVEL;
                    if (rv < 0) rv = 0;
                    if (gv < 0) gv = 0;
                    if (bv < 0) bv = 0;
                    r_sum += rv;
                    g_sum += gv;
                    b_sum += bv;
                    stat_count++;

                    /* Multi-zone AE: accumulate green into the right zone.
                     * Output coordinates (out_x in [0, OUT_W), out_y in
                     * [0, OUT_H)) get mapped to a 16x16 grid. */
                    int zx = out_x * AE_ZONES_X / OUT_W;
                    int zy = out_y * AE_ZONES_Y / OUT_H;
                    if (zx >= AE_ZONES_X) zx = AE_ZONES_X - 1;
                    if (zy >= AE_ZONES_Y) zy = AE_ZONES_Y - 1;
                    int zidx = zy * AE_ZONES_X + zx;
                    ae_zone_g_sum[zidx] += (uint64_t)gv;
                    ae_zone_g_count[zidx]++;
                }
            }
        }

    }

    /* False-colour suppression: 3x3 chroma median over the YUYV buffer.
     * Y is untouched so luma sharpness is preserved. */
    chroma_median_filter(yuyv_buf, OUT_W, OUT_H);

    if (stat_count > 0) {
        *out_r_sum = (float)(r_sum / stat_count);
        *out_g_sum = (float)(g_sum / stat_count);
        *out_b_sum = (float)(b_sum / stat_count);
    } else {
        *out_r_sum = *out_g_sum = *out_b_sum = 0.0f;
    }
    *out_count = stat_count;
    *out_hist_total = hist_total;

    return *out_g_sum;
}

/*
 * Compute the multi-zone AE target: mean green of the AE_DARK_FRACTION
 * darkest zones. Skips empty zones (sparse stat sampling can leave some).
 * This is the shadow-priority metering that gives backlit subjects the
 * right exposure regardless of where they are in the frame.
 */
static float compute_ae_zone_target(void)
{
    float means[AE_ZONES];
    int n = 0;
    for (int z = 0; z < AE_ZONES; z++) {
        if (ae_zone_g_count[z] > 0) {
            means[n++] = (float)ae_zone_g_sum[z] / (float)ae_zone_g_count[z];
        }
    }
    if (n == 0) return 0;

    int m = (int)(n * AE_DARK_FRACTION);
    if (m < 1) m = 1;

    /* Partial selection sort: bring the m smallest to the front of the
     * array, then average them. O(m*n) — for n=256, m=64, ~16k compares
     * per frame which is negligible. */
    for (int i = 0; i < m; i++) {
        int min_idx = i;
        for (int j = i + 1; j < n; j++) {
            if (means[j] < means[min_idx]) min_idx = j;
        }
        if (min_idx != i) {
            float t = means[i]; means[i] = means[min_idx]; means[min_idx] = t;
        }
    }
    float sum = 0;
    for (int i = 0; i < m; i++) sum += means[i];
    return sum / (float)m;
}

/*
 * Local Tone Mapping: compress bright local regions of the YUYV buffer
 * while preserving dark regions. Operates on Y only (UV untouched).
 *
 * Algorithm (Reinhard local with Gaussian-instead-of-bilateral):
 *   1. Build a downsampled Y mean per LTM_GRID cell.
 *   2. EMA-blend with the previous frame's grid for temporal stability.
 *   3. Per cell, derive a compression FACTOR (1.0 below LTM_KNEE, falling
 *      hyperbolically above).
 *   4. Per output pixel, bilinearly sample the factor grid and scale Y.
 *
 * This is the same approach used in libcamera/RPi software ISPs and in
 * IPU6 hardware WDR — local-luma-driven compression of bright regions
 * without touching the local contrast (the multiplicative scale keeps
 * pixel-to-pixel variation intact).
 */
static void apply_ltm(uint8_t *buf, int w, int h)
{
    static uint64_t cell_sum[LTM_GRID_Y * LTM_GRID_X];
    static uint32_t cell_count[LTM_GRID_Y * LTM_GRID_X];
    static float ltm_grid[LTM_GRID_Y * LTM_GRID_X];
    static float factor_grid[LTM_GRID_Y * LTM_GRID_X];
    static int ltm_initialized = 0;

    int row_bytes = w * 2;  /* YUYV: 2 bytes per pixel */

    /* 1. Downsample: sum Y values into grid cells. */
    for (int i = 0; i < LTM_GRID_Y * LTM_GRID_X; i++) {
        cell_sum[i] = 0;
        cell_count[i] = 0;
    }
    for (int y = 0; y < h; y++) {
        int gy = y / LTM_CELL_H;
        if (gy >= LTM_GRID_Y) gy = LTM_GRID_Y - 1;
        const uint8_t *row = buf + y * row_bytes;
        int gy_base = gy * LTM_GRID_X;
        for (int x = 0; x < w; x++) {
            int gx = x / LTM_CELL_W;
            if (gx >= LTM_GRID_X) gx = LTM_GRID_X - 1;
            int idx = gy_base + gx;
            cell_sum[idx] += row[x * 2];   /* Y is at byte offset 2*x */
            cell_count[idx]++;
        }
    }

    /* 2a. Per-cell mean with temporal EMA. */
    for (int i = 0; i < LTM_GRID_Y * LTM_GRID_X; i++) {
        float mean = cell_count[i] > 0
                        ? (float)cell_sum[i] / (float)cell_count[i]
                        : 128.0f;
        if (!ltm_initialized) {
            ltm_grid[i] = mean;
        } else {
            ltm_grid[i] = (1.0f - LTM_TEMPORAL_BLEND) * ltm_grid[i]
                        + LTM_TEMPORAL_BLEND * mean;
        }
    }
    ltm_initialized = 1;

    /* 2b. Joint bilateral smoothing of the grid. A plain blur (box or
     * Gaussian) averages bright-wall cells with shadowed-face cells
     * across the silhouette boundary; the per-pixel bilinear upsample
     * then renders that mixed factor as a visible halo. The bilateral
     * weight kernel multiplies the spatial Gaussian by a range Gaussian
     * on the centre-vs-neighbour luma difference, so cells across a
     * sharp luma edge contribute ~0 weight. Smoothing remains aggressive
     * inside flat regions, but stops at edges — no halo. */
    static float bf_spatial[(2 * LTM_BF_RADIUS + 1) * (2 * LTM_BF_RADIUS + 1)];
    static int bf_initialized = 0;
    if (!bf_initialized) {
        float two_ss = 2.0f * LTM_BF_SIGMA_S * LTM_BF_SIGMA_S;
        for (int dy = -LTM_BF_RADIUS; dy <= LTM_BF_RADIUS; dy++) {
            for (int dx = -LTM_BF_RADIUS; dx <= LTM_BF_RADIUS; dx++) {
                float d2 = (float)(dx * dx + dy * dy);
                int k = (dy + LTM_BF_RADIUS) * (2 * LTM_BF_RADIUS + 1)
                      + (dx + LTM_BF_RADIUS);
                bf_spatial[k] = expf(-d2 / two_ss);
            }
        }
        bf_initialized = 1;
    }
    static float smooth_grid[LTM_GRID_Y * LTM_GRID_X];
    float two_sr = 2.0f * LTM_BF_SIGMA_R * LTM_BF_SIGMA_R;
    for (int gy = 0; gy < LTM_GRID_Y; gy++) {
        for (int gx = 0; gx < LTM_GRID_X; gx++) {
            float centre = ltm_grid[gy * LTM_GRID_X + gx];
            float wsum = 0, vsum = 0;
            for (int dy = -LTM_BF_RADIUS; dy <= LTM_BF_RADIUS; dy++) {
                int yy = gy + dy;
                if (yy < 0 || yy >= LTM_GRID_Y) continue;
                for (int dx = -LTM_BF_RADIUS; dx <= LTM_BF_RADIUS; dx++) {
                    int xx = gx + dx;
                    if (xx < 0 || xx >= LTM_GRID_X) continue;
                    float v = ltm_grid[yy * LTM_GRID_X + xx];
                    float diff = v - centre;
                    int k = (dy + LTM_BF_RADIUS) * (2 * LTM_BF_RADIUS + 1)
                          + (dx + LTM_BF_RADIUS);
                    float w = bf_spatial[k] * expf(-(diff * diff) / two_sr);
                    wsum += w;
                    vsum += w * v;
                }
            }
            smooth_grid[gy * LTM_GRID_X + gx] = vsum / wsum;
        }
    }

    /* 2c. Derive per-cell compression factors from the smoothed grid. */
    for (int i = 0; i < LTM_GRID_Y * LTM_GRID_X; i++) {
        float L = smooth_grid[i];
        float factor;
        if (L <= LTM_KNEE) {
            factor = 1.0f;
        } else {
            float over = L - LTM_KNEE;
            factor = LTM_TARGET_Y / (LTM_TARGET_Y + over * LTM_STRENGTH);
        }
        factor_grid[i] = factor;
    }

    /* 3. Apply per-pixel: bilinearly sample factor grid, multiply Y. */
    for (int y = 0; y < h; y++) {
        float fy = (y + 0.5f) / (float)LTM_CELL_H - 0.5f;
        if (fy < 0) fy = 0;
        if (fy > LTM_GRID_Y - 1) fy = LTM_GRID_Y - 1;
        int gy0 = (int)fy;
        int gy1 = gy0 + 1;
        if (gy1 >= LTM_GRID_Y) gy1 = LTM_GRID_Y - 1;
        float wy = fy - gy0;
        float iwy = 1.0f - wy;

        uint8_t *row = buf + y * row_bytes;
        for (int x = 0; x < w; x++) {
            float fx = (x + 0.5f) / (float)LTM_CELL_W - 0.5f;
            if (fx < 0) fx = 0;
            if (fx > LTM_GRID_X - 1) fx = LTM_GRID_X - 1;
            int gx0 = (int)fx;
            int gx1 = gx0 + 1;
            if (gx1 >= LTM_GRID_X) gx1 = LTM_GRID_X - 1;
            float wx = fx - gx0;
            float iwx = 1.0f - wx;

            float f00 = factor_grid[gy0 * LTM_GRID_X + gx0];
            float f01 = factor_grid[gy0 * LTM_GRID_X + gx1];
            float f10 = factor_grid[gy1 * LTM_GRID_X + gx0];
            float f11 = factor_grid[gy1 * LTM_GRID_X + gx1];
            float factor = iwx * iwy * f00 + wx * iwy * f01
                         + iwx * wy  * f10 + wx * wy  * f11;

            int y_old = row[x * 2];
            int y_new = (int)(y_old * factor + 0.5f);
            if (y_new < 16) y_new = 16;
            if (y_new > 235) y_new = 235;
            row[x * 2] = (uint8_t)y_new;
        }
    }
}

/* Find the V4L2 subdevice that has exposure control (the sensor) */
static int find_sensor_subdev(char *path, size_t pathlen)
{
    char devpath[64];
    for (int i = 0; i < 16; i++) {
        snprintf(devpath, sizeof(devpath), "/dev/v4l-subdev%d", i);
        int fd = open(devpath, O_RDWR);
        if (fd < 0) continue;

        struct v4l2_queryctrl qc = { .id = V4L2_CID_EXPOSURE };
        if (xioctl(fd, VIDIOC_QUERYCTRL, &qc) == 0) {
            close(fd);
            snprintf(path, pathlen, "%s", devpath);
            return 0;
        }
        close(fd);
    }
    return -1;
}

static void set_sensor_controls(const char *subdev_path, int exposure, int gain)
{
    int fd = open(subdev_path, O_RDWR);
    if (fd < 0) return;

    struct v4l2_control ctrl;
    ctrl.id = V4L2_CID_EXPOSURE;
    ctrl.value = exposure;
    xioctl(fd, VIDIOC_S_CTRL, &ctrl);

    ctrl.id = V4L2_CID_ANALOGUE_GAIN;
    ctrl.value = gain;
    xioctl(fd, VIDIOC_S_CTRL, &ctrl);

    close(fd);
}

/*
 * Open the capture device, set format, request and map buffers,
 * and start streaming. Returns the fd on success, -1 on failure.
 */
static int open_capture(const char *dev, struct buffer *buffers, int *n_buffers)
{
    int fd = open(dev, O_RDWR);
    if (fd < 0) {
        perror("open capture device");
        return -1;
    }

    /* Set format */
    struct v4l2_format fmt = {0};
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width = SENSOR_W;
    fmt.fmt.pix.height = SENSOR_H;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_SGRBG10;
    fmt.fmt.pix.field = V4L2_FIELD_NONE;
    if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
        perror("VIDIOC_S_FMT");
        close(fd);
        return -1;
    }

    /* Request buffers */
    struct v4l2_requestbuffers req = {0};
    req.count = NUM_BUFFERS;
    req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = V4L2_MEMORY_MMAP;
    if (xioctl(fd, VIDIOC_REQBUFS, &req) < 0) {
        perror("VIDIOC_REQBUFS");
        close(fd);
        return -1;
    }

    *n_buffers = req.count;

    /* Map buffers */
    for (int i = 0; i < (int)req.count; i++) {
        struct v4l2_buffer buf = {0};
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index = i;
        if (xioctl(fd, VIDIOC_QUERYBUF, &buf) < 0) {
            perror("VIDIOC_QUERYBUF");
            close(fd);
            return -1;
        }

        buffers[i].length = buf.length;
        buffers[i].start = mmap(NULL, buf.length, PROT_READ | PROT_WRITE,
                                MAP_SHARED, fd, buf.m.offset);
        if (buffers[i].start == MAP_FAILED) {
            perror("mmap");
            close(fd);
            return -1;
        }
    }

    /* Queue buffers */
    for (int i = 0; i < (int)req.count; i++) {
        struct v4l2_buffer buf = {0};
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index = i;
        if (xioctl(fd, VIDIOC_QBUF, &buf) < 0) {
            perror("VIDIOC_QBUF");
            close(fd);
            return -1;
        }
    }

    /* Start streaming */
    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (xioctl(fd, VIDIOC_STREAMON, &type) < 0) {
        perror("VIDIOC_STREAMON");
        close(fd);
        return -1;
    }

    return fd;
}

/*
 * Stop streaming and close the capture device, unmapping all buffers.
 */
static void close_capture(int cap_fd, struct buffer *buffers, int n_buffers)
{
    if (cap_fd < 0)
        return;

    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    xioctl(cap_fd, VIDIOC_STREAMOFF, &type);

    for (int i = 0; i < n_buffers; i++)
        munmap(buffers[i].start, buffers[i].length);

    close(cap_fd);
}

static int open_output(const char *dev)
{
    int fd = open(dev, O_RDWR);
    if (fd < 0) {
        perror("open output device");
        return -1;
    }

    struct v4l2_format fmt = {0};
    fmt.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    fmt.fmt.pix.width = OUT_W;
    fmt.fmt.pix.height = OUT_H;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
    fmt.fmt.pix.field = V4L2_FIELD_NONE;
    fmt.fmt.pix.sizeimage = OUT_W * OUT_H * 2;
    if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
        perror("VIDIOC_S_FMT output");
        close(fd);
        return -1;
    }

    return fd;
}

/*
 * Initialise inotify watch on the output device.
 * Watches for IN_OPEN and IN_CLOSE events so we know when consumers
 * attach/detach without scanning /proc (which is fragile and slow).
 *
 * Must be called AFTER the ISP opens out_fd, so that our own open()
 * is not counted.
 */
static int init_inotify(const char *output_dev)
{
    inotify_fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (inotify_fd < 0) {
        perror("inotify_init1");
        return -1;
    }

    inotify_wd = inotify_add_watch(inotify_fd, output_dev,
                                    IN_OPEN | IN_CLOSE);
    if (inotify_wd < 0) {
        perror("inotify_add_watch");
        close(inotify_fd);
        inotify_fd = -1;
        return -1;
    }

    consumer_count = 0;
    return 0;
}

/*
 * Drain all pending inotify events and update consumer_count.
 * Call this periodically (it is non-blocking).
 */
static void drain_inotify(void)
{
    char buf[4096] __attribute__((aligned(__alignof__(struct inotify_event))));

    for (;;) {
        ssize_t len = read(inotify_fd, buf, sizeof(buf));
        if (len <= 0)
            break;

        const struct inotify_event *ev;
        for (char *ptr = buf; ptr < buf + len;
             ptr += sizeof(struct inotify_event) + ev->len) {
            ev = (const struct inotify_event *)ptr;

            if (ev->mask & IN_OPEN)
                consumer_count++;
            if (ev->mask & (IN_CLOSE_WRITE | IN_CLOSE_NOWRITE)) {
                consumer_count--;
                if (consumer_count < 0)
                    consumer_count = 0;
            }
        }
    }
}

static void cleanup_inotify(void)
{
    if (inotify_wd >= 0) {
        inotify_rm_watch(inotify_fd, inotify_wd);
        inotify_wd = -1;
    }
    if (inotify_fd >= 0) {
        close(inotify_fd);
        inotify_fd = -1;
    }
}

/*
 * Count how many processes currently have output_dev open by scanning
 * /proc/<PID>/fd/<N> symlinks. Used as a fallback when inotify misses
 * IN_OPEN/IN_CLOSE events on V4L2 character devices.
 *
 * Resolves the real path of output_dev once (via realpath) then compares
 * symlink targets. Gracefully skips entries we cannot read.
 */
static int count_proc_consumers(const char *output_dev)
{
    static char real_dev[PATH_MAX];
    static int resolved;
    if (!resolved) {
        if (!realpath(output_dev, real_dev))
            return 0;
        resolved = 1;
    }

    DIR *proc = opendir("/proc");
    if (!proc)
        return 0;

    int count = 0;
    pid_t self = getpid();
    struct dirent *pid_ent;
    while ((pid_ent = readdir(proc)) != NULL) {
        /* Only numeric entries (PIDs) */
        if (pid_ent->d_name[0] < '1' || pid_ent->d_name[0] > '9')
            continue;

        /* Skip our own process — we hold out_fd open permanently */
        if (atoi(pid_ent->d_name) == self)
            continue;

        char fd_dir[PATH_MAX];
        snprintf(fd_dir, sizeof(fd_dir), "/proc/%s/fd", pid_ent->d_name);

        DIR *fds = opendir(fd_dir);
        if (!fds)
            continue;

        struct dirent *fd_ent;
        while ((fd_ent = readdir(fds)) != NULL) {
            if (fd_ent->d_name[0] == '.')
                continue;

            char link_path[PATH_MAX];
            snprintf(link_path, sizeof(link_path), "/proc/%s/fd/%s",
                     pid_ent->d_name, fd_ent->d_name);

            char target[PATH_MAX];
            ssize_t n = readlink(link_path, target, sizeof(target) - 1);
            if (n > 0) {
                target[n] = '\0';
                if (strcmp(target, real_dev) == 0)
                    count++;
            }
        }
        closedir(fds);
    }
    closedir(proc);
    return count;
}

/*
 * Return the best estimate of the current consumer count.
 * inotify is the fast path; /proc is the ground-truth fallback.
 * We trust whichever reports more consumers, except when /proc says
 * zero we always believe it (inotify missed a close).
 */
static int get_consumer_count(const char *output_dev)
{
    drain_inotify();
    int proc_count = count_proc_consumers(output_dev);

    if (proc_count == 0) {
        /* Ground truth: nobody has the device open */
        consumer_count = 0;
        return 0;
    }
    /* Trust the higher of the two */
    if (proc_count > consumer_count)
        consumer_count = proc_count;
    return consumer_count;
}

/*
 * Run the streaming loop: capture frames from the sensor, process them
 * through the ISP pipeline, and write to the output device.
 *
 * Exits when: running becomes 0 (signal), or no consumers remain for
 * several consecutive poll intervals.
 *
 * Returns: 0 on clean consumer-loss exit, -1 on error.
 */
static int streaming_loop(const char *capture_dev, int out_fd,
                          const char *subdev_path, int has_subdev,
                          const char *output_dev)
{
    struct buffer buffers[NUM_BUFFERS];
    int n_buffers = 0;

    /*
     * ISP state is static so it persists across streaming sessions.
     * Without this, each session resets exposure/gain/WB to defaults,
     * causing overexposed frames until hardware AE reconverges (~15s).
     */
    static int cur_exposure = 600;
    static int cur_gain = 4;
    static float wb_r_gain = 1.0f;
    static float wb_b_gain = 1.0f;
    static float brightness = 1.0f;

    /* Restore hardware exposure/gain from previous session */
    if (has_subdev)
        set_sensor_controls(subdev_path, cur_exposure, cur_gain);

    int cap_fd = open_capture(capture_dev, buffers, &n_buffers);
    if (cap_fd < 0)
        return -1;

    printf("[gc2607_isp] Streaming started (output %dx%d YUYV, exp=%d gain=%d bright=%.2f)\n",
           OUT_W, OUT_H, cur_exposure, cur_gain, brightness);

    int frame_count = 0;
    int no_consumer_count = 0;

    struct timespec last_ae_time, last_consumer_check;
    clock_gettime(CLOCK_MONOTONIC, &last_ae_time);
    clock_gettime(CLOCK_MONOTONIC, &last_consumer_check);

    while (running) {
        /* Dequeue a capture buffer */
        struct v4l2_buffer buf = {0};
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;
        if (xioctl(cap_fd, VIDIOC_DQBUF, &buf) < 0) {
            if (errno == EAGAIN) continue;
            perror("VIDIOC_DQBUF");
            break;
        }

        const uint16_t *bayer = (const uint16_t *)buffers[buf.index].start;

        /* Process frame */
        float r_mean, g_mean, b_mean;
        uint32_t g_hist[HISTOGRAM_BINS];
        int stat_count, hist_total;
        process_frame(bayer, wb_r_gain, wb_b_gain, brightness,
                      &r_mean, &g_mean, &b_mean,
                      g_hist, &hist_total, &stat_count);

        /* Multi-zone AE target: mean green of the darkest 25% of zones. */
        float g_target = compute_ae_zone_target();

        /* LTM permanently disabled. Both KNEE=120 (Y-threshold inside
         * skin midtones) and KNEE=200 (only true highlights) produce
         * visible forehead patches when the user moves — any frame in
         * which skin luma crosses the knee shifts the cell-grid factor
         * boundary, which the bilinear factor upsample renders as a
         * moving artefact. The bilateral grid smoothing fixes silhouette
         * halos but is powerless against this in-skin transition. The
         * fundamental problem is "hard threshold on a coarse grid against
         * a textured signal" — no knee value escapes it on face skin. */
        (void)apply_ltm;

        /* Update white balance (gray-world, no offsets) */
        if (r_mean > 1.0f && g_mean > 1.0f && b_mean > 1.0f) {
            float new_r_gain = g_mean / r_mean;
            float new_b_gain = g_mean / b_mean;

            /* Clamp gains to reasonable range */
            if (new_r_gain > 4.0f) new_r_gain = 4.0f;
            if (new_r_gain < 0.25f) new_r_gain = 0.25f;
            if (new_b_gain > 4.0f) new_b_gain = 4.0f;
            if (new_b_gain < 0.25f) new_b_gain = 0.25f;

            /* First few frames: no smoothing for fast convergence */
            float sm = frame_count < 10 ? 0.0f : WB_SMOOTHING;
            wb_r_gain = sm * wb_r_gain + (1.0f - sm) * new_r_gain;
            wb_b_gain = sm * wb_b_gain + (1.0f - sm) * new_b_gain;
        }

        /*
         * Auto-exposure: dual-constraint AGC.
         *  (a) Mean target (centre-weighted) keeps the subject around AE_TARGET.
         *  (b) Highlight cap keeps the AE_HIGHLIGHT_PCTILE percentile of green
         *      below AE_HIGHLIGHT_CAP — protects bright walls/ceilings from
         *      saturating, which a mean-only AE cannot detect.
         * Take the more restrictive (smaller) brightness; smooth temporally.
         */
        float target_brightness = brightness;

        /* (a) Mean target on the dark-zones average (shadow-priority). */
        float cur_target_8bit = g_target * brightness / MAX_SIGNAL * 255.0f;
        float bright_for_mean = (cur_target_8bit > 1.0f)
            ? brightness * AE_TARGET / cur_target_8bit
            : BRIGHTNESS_MAX;

        /* (b) Highlight cap from green histogram */
        float bright_for_cap = BRIGHTNESS_MAX;
        if (hist_total > 0) {
            int threshold = (int)(hist_total * AE_HIGHLIGHT_PCTILE);
            int cum = 0;
            int p_bin = HISTOGRAM_BINS - 1;
            for (int b = 0; b < HISTOGRAM_BINS; b++) {
                cum += g_hist[b];
                if (cum >= threshold) { p_bin = b; break; }
            }
            /* Centre of bin in raw 10-bit space */
            float pctile_raw = (p_bin + 0.5f) * (float)HIST_BIN_WIDTH - BLACK_LEVEL;
            if (pctile_raw < 1.0f) pctile_raw = 1.0f;
            bright_for_cap = AE_HIGHLIGHT_CAP * MAX_SIGNAL / (pctile_raw * 255.0f);
        }

        target_brightness = bright_for_mean < bright_for_cap ? bright_for_mean : bright_for_cap;

        brightness = AE_SMOOTHING * brightness + (1.0f - AE_SMOOTHING) * target_brightness;
        if (brightness < BRIGHTNESS_MIN) brightness = BRIGHTNESS_MIN;
        if (brightness > BRIGHTNESS_MAX) brightness = BRIGHTNESS_MAX;

        /* Hardware AE: adjust sensor exposure/gain when software gain is railing */
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double elapsed = (
            (now.tv_sec - last_ae_time.tv_sec)
            + (now.tv_nsec - last_ae_time.tv_nsec) / 1e9
        );

        if (has_subdev && elapsed >= AE_INTERVAL_S) {
            if (brightness > 2.5f) {
                if (cur_exposure < EXPOSURE_MAX) {
                    cur_exposure = (int)(cur_exposure * 1.5);
                    if (cur_exposure > EXPOSURE_MAX) cur_exposure = EXPOSURE_MAX;
                } else if (cur_gain < GAIN_MAX) {
                    /* Exposure maxed: step gain up by 2 for faster convergence */
                    cur_gain += 2;
                    if (cur_gain > GAIN_MAX) cur_gain = GAIN_MAX;
                }
                set_sensor_controls(subdev_path, cur_exposure, cur_gain);
                brightness = 1.0f;
            } else if (brightness < 0.8f && (cur_exposure > EXPOSURE_MIN || cur_gain > GAIN_MIN)) {
                cur_exposure = (int)(cur_exposure * 0.7);
                if (cur_exposure < EXPOSURE_MIN) cur_exposure = EXPOSURE_MIN;
                if (cur_exposure == EXPOSURE_MIN && cur_gain > GAIN_MIN)
                    cur_gain = cur_gain - 1 >= GAIN_MIN ? cur_gain - 1 : GAIN_MIN;
                set_sensor_controls(subdev_path, cur_exposure, cur_gain);
                brightness = 1.0f;
            }
            last_ae_time = now;
        }

        /* Write YUYV to v4l2loopback */
        ssize_t written = write(out_fd, yuyv_buf, sizeof(yuyv_buf));
        if (written < 0 && errno != EAGAIN) {
            perror("write output");
            break;
        }

        /* Re-queue capture buffer */
        if (xioctl(cap_fd, VIDIOC_QBUF, &buf) < 0) {
            perror("VIDIOC_QBUF requeue");
            break;
        }

        frame_count++;
        if (frame_count % 150 == 0) {
            printf("[gc2607_isp] %d frames | WB: R=%.2f B=%.2f | bright=%.2f | exp=%d gain=%d | means: R=%.1f G=%.1f Gdark=%.1f B=%.1f | AE: mean=>%.2f cap=>%.2f\n",
                   frame_count, wb_r_gain, wb_b_gain, brightness, cur_exposure, cur_gain,
                   r_mean, g_mean, g_target, b_mean,
                   bright_for_mean, bright_for_cap);
        }

        /*
         * Periodically check if consumers are still attached.
         * If no consumers for 5 consecutive checks (~10s), stop streaming
         * to release the hardware and save power.
         */
        double since_check = (
            (now.tv_sec - last_consumer_check.tv_sec)
            + (now.tv_nsec - last_consumer_check.tv_nsec) / 1e9
        );
        if (since_check >= CONSUMER_CHECK_INTERVAL_S) {
            last_consumer_check = now;
            if (get_consumer_count(output_dev) <= 0) {
                no_consumer_count++;
                if (no_consumer_count >= 5) {
                    printf("[gc2607_isp] No consumers detected, stopping stream (%d frames)\n",
                           frame_count);
                    close_capture(cap_fd, buffers, n_buffers);
                    return 0;
                }
            } else {
                no_consumer_count = 0;
            }
        }
    }

    printf("[gc2607_isp] Shutting down (%d frames total)\n", frame_count);
    close_capture(cap_fd, buffers, n_buffers);
    return running ? -1 : 0;
}

int main(int argc, char *argv[])
{
    const char *capture_dev = argc > 1 ? argv[1] : "/dev/video1";
    const char *output_dev  = argc > 2 ? argv[2] : "/dev/video50";

    /* Line-buffered stdout so logs appear in journald */
    setvbuf(stdout, NULL, _IOLBF, 0);

    printf("[gc2607_isp] Starting with lazy activation (capture=%s output=%s)\n",
           capture_dev, output_dev);

    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    /* Find sensor subdevice for exposure/gain control */
    char subdev_path[64] = {0};
    int has_subdev = (find_sensor_subdev(subdev_path, sizeof(subdev_path)) == 0);
    if (has_subdev)
        printf("[gc2607_isp] Sensor subdev: %s\n", subdev_path);
    else
        printf("[gc2607_isp] Warning: no sensor subdev found (no AE control)\n");

    /* Open output device (kept open for the lifetime of the process) */
    int out_fd = open_output(output_dev);
    if (out_fd < 0)
        return 1;

    /* Set up inotify AFTER opening out_fd so our own open isn't counted */
    if (init_inotify(output_dev) < 0) {
        fprintf(stderr, "[gc2607_isp] Failed to set up inotify, exiting\n");
        close(out_fd);
        return 1;
    }
    printf("[gc2607_isp] Consumer detection via inotify on %s\n", output_dev);

    /*
     * Main idle/stream loop:
     *   - While idle: write a black standby frame periodically so that
     *     PipeWire/wireplumber sees the device as active and camera apps
     *     can discover it. Use select() on inotify_fd to wake instantly
     *     when a consumer opens the device.
     *   - When a consumer opens /dev/video50: start capturing from the
     *     sensor, process frames through the ISP, and write to output.
     *   - When all consumers close: stop streaming and return to idle.
     */

    /* Prepare a black standby frame (Y=16, U=128, V=128 = black in YUYV) */
    memset(yuyv_buf, 0, sizeof(yuyv_buf));
    for (size_t i = 0; i < sizeof(yuyv_buf); i += 4) {
        yuyv_buf[i]     = 16;   /* Y0 */
        yuyv_buf[i + 1] = 128;  /* U  */
        yuyv_buf[i + 2] = 16;   /* Y1 */
        yuyv_buf[i + 3] = 128;  /* V  */
    }
    /* Write initial standby frame so wireplumber can probe successfully */
    write(out_fd, yuyv_buf, sizeof(yuyv_buf));

    printf("[gc2607_isp] Idle, waiting for consumers on %s...\n", output_dev);

    while (running) {
        /*
         * Wait for inotify events (consumer open) with a timeout.
         * The timeout ensures we periodically write standby frames
         * to keep v4l2loopback alive for PipeWire device discovery.
         */
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(inotify_fd, &rfds);
        struct timeval tv;
        tv.tv_sec = STANDBY_INTERVAL_MS / 1000;
        tv.tv_usec = (STANDBY_INTERVAL_MS % 1000) * 1000;

        int sel = select(inotify_fd + 1, &rfds, NULL, NULL, &tv);

        if (sel > 0)
            drain_inotify();

        if (get_consumer_count(output_dev) > 0) {
            printf("[gc2607_isp] %d consumer(s) detected, starting stream...\n",
                   consumer_count);
            int ret = streaming_loop(capture_dev, out_fd,
                                     subdev_path, has_subdev, output_dev);
            if (ret < 0 && running) {
                printf("[gc2607_isp] Streaming error, retrying in 2s...\n");
                sleep(2);
            }
            if (running)
                printf("[gc2607_isp] Idle, waiting for consumers on %s...\n",
                       output_dev);
        } else {
            /* Write standby frame to keep v4l2loopback alive */
            write(out_fd, yuyv_buf, sizeof(yuyv_buf));
        }
    }

    printf("[gc2607_isp] Exiting\n");
    cleanup_inotify();
    close(out_fd);

    return 0;
}
