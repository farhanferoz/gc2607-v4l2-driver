/*
 * gc2607_isp.c — Lightweight userspace ISP for GC2607 camera sensor
 *
 * Captures raw 10-bit Bayer GRBG from V4L2, applies:
 *   - Bilinear demosaic to 1920x1080 (2x2 binning to 960x540 with GC2607_ISP_HALF_RES=1)
 *   - Black level subtraction
 *   - Gray-world auto white balance
 *   - Auto-exposure: one controller over exposure, analogue gain, frame length and digital gain
 *   - sRGB encoding + mild contrast via per-channel LUT
 *   - 180° rotation
 * Outputs YUYV to v4l2loopback.
 *
 * Lazy activation: the ISP waits in poll() until an application streams from
 * /dev/video50 (v4l2loopback's client-usage event). When the last one stops,
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
#include <poll.h>
#include <unistd.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/videodev2.h>

/* Sensor parameters */
#define SENSOR_W        1920
#define SENSOR_H        1080
#define HALF_W          (SENSOR_W / 2)  /* 960: 2x2-binned output and the statistics grid */
#define HALF_H          (SENSOR_H / 2)  /* 540 */
#define FRAME_PIXELS    (SENSOR_W * SENSOR_H)
#define LUT_SIZE        1024  /* 10-bit sensor values 0..1023 */

/* ISP parameters */
#define BLACK_LEVEL     64    /* Sensor hardware black level */
#define MAX_SIGNAL      959.0f  /* 1023 - 64 = usable range */
#define LUT_CONTRAST    0.25f /* share of a smoothstep mixed into the display curve */

/* Auto white balance */
#define WB_SMOOTHING    0.85f   /* Temporal smoothing (higher = more stable) */
#define WB_SUBSAMPLE    8       /* Sample every Nth pixel for WB stats */
/* WB skips samples whose brightest channel is within this of black. 4, not more: on the corpus's
 * low-signal neutral captures 16 left them less neutral (centre chroma 9.25 -> 9.79, 9.39 -> 10.22) and
 * 4 changed nothing (+/-0.04); the black level itself is accurate (64.0-64.3 measured). */
#define WB_MIN_SIGNAL   4
/* Grey-world gains relative to green are held to the range logged in 60 days of use (red 1.53-2.45,
 * blue 1.49-2.18, 4,520 status lines to 2026-10-18) widened by 20% each way, so a scene filled by
 * one colour cannot pull the balance far from any real light (handover Q9). */
#define WB_R_MIN        1.27f
#define WB_R_MAX        2.94f
#define WB_B_MIN        1.24f
#define WB_B_MAX        2.62f

/*
 * Exposure control (camera-fix handover Q1): one controller owns the total exposure
 * T = exposure lines x analogue gain x digital gain d, meters every frame, and spreads T over
 * the sensor in a fixed order (see ae_allocate()). Until 2026-10-18 a software brightness loop
 * and a separate hardware loop fought each other, and exposure was never lowered in 60 days.
 *
 * Metering: the display mean luma Y aims at AE_TARGET_Y; the linear 98th percentile of green
 * may not pass AE_CAP_P98 (or the total drops by AE_CAP_CLIPPED while >= AE_CLIP_FRACTION of
 * samples sit in the top raw bin); but Y never goes below AE_FLOOR_Y, so a backlit subject
 * stays visible and the window clips instead.
 */
#define AE_TARGET_Y         0.45f
#define AE_FLOOR_Y          0.30f
#define AE_CAP_P98          0.92f
#define AE_CAP_CLIPPED      0.80f
#define AE_CLIP_FRACTION    0.02f
#define AE_PCTILE           0.98f
#define AE_STEP_MIN         0.5f    /* largest single correction, down and up */
#define AE_STEP_MAX         2.0f
#define AE_DEADBAND_LOG2    0.05f   /* ignore corrections under ~3.5% */
#define AE_DAMPING          0.3f    /* share of each correction applied per update */
/* Per-update linear step. Display luma moves up to ~1.15x as fast in the deep shadows (the
 * contrast term), so 1.10 keeps any one frame within 12%. */
#define AE_UPDATE_MAX       1.10f
#define AE_FAST_FRAMES      10      /* undamped corrections at the start of a session */
#define AE_LATENCY_FRAMES   1       /* frames still taken with the old controls after a write (T0.4) */
#define AE_GAMMA            2.2f    /* display-to-linear exponent for metering */

/* Sensor timing from the driver (D1): 29.97 us per line, frame length 1116..2232 lines. */
#define LINE_US             29.97f
#define FLL_MIN             1116
#define FLL_MAX             2232
#define EXPOSURE_MARGIN     8       /* exposure stays this far below the frame length */
#define EXPOSURE_30FPS      1002    /* 30 ms, the longest exposure at full frame rate */
#define EXPOSURE_15FPS      2004    /* 60 ms, frame length 2012 */
#define GAIN_30FPS          8       /* 3.95x: the gain used before the frame rate drops */
#define DIGITAL_MAX         2.0f
#define FLICKER_HZ_DEFAULT  50      /* GC2607_ISP_FLICKER_HZ: 50, 60, or 0 = off */

/* Green-channel histogram for the highlight cap. */
#define HISTOGRAM_BINS      64
#define HIST_BIN_WIDTH      (LUT_SIZE / HISTOGRAM_BINS)

/* Sensor hardware limits */
#define EXPOSURE_MIN    4
#define GAIN_MAX        16

/* Real analogue gain of each driver gain index, x64: the vendor calibration (CMC) for this
 * register table, as decoded in AlexDaichendt/gc2607-camera-linux FINDINGS.md "Gain model". */
static const uint16_t gain_x64[GAIN_MAX + 1] = {
    64, 76, 93, 111, 130, 156, 184, 221, 253, 304, 367, 434, 510, 607, 717, 847, 1012,
};

static inline float gain_of(int index) { return gain_x64[index] / 64.0f; }

/* V4L2 capture buffers */
#define NUM_BUFFERS     4
#define CHROMA_GAIN_Q8  320 /* 1.25x colour strength (256 = off); added 2026-09-23 */
#define CAPTURE_STALL_S 5   /* seconds without a frame before the capture is reset */
#define MAX_STREAM_FAILS 5  /* consecutive failed sessions before exiting for systemd */

/* Lazy activation: how often to write standby frames while idle (ms) */
#define STANDBY_INTERVAL_MS  2000

/* After the last reader stops streaming, how long to keep the sensor on in case one returns (s) */
#define READER_GRACE_S  3.0

/*
 * v4l2loopback's client-usage event; its header is not installed. From v4l2loopback 0.15.4,
 * v4l2loopback.c ~line 818 (/usr/src/akmods/v4l2loopback-kmod-0.15.4-1.fc44.src.rpm): `count` is 1
 * while a reader holds the capture stream. It is queued on a reader's STREAMON and STREAMOFF and on
 * close (close calls REQBUFS(0), which calls STREAMOFF), so a crashed reader ends it too, and the
 * device's poll reports it as POLLPRI on every opener, including this writer.
 */
#define V4L2_EVENT_PRI_CLIENT_USAGE  (V4L2_EVENT_PRIVATE_START + 0x08E00000 + 1)
struct v4l2_event_client_usage {
    __u32 count;
};

static volatile sig_atomic_t running = 1;

struct buffer {
    void   *start;
    size_t  length;
};

/* Per-channel LUTs: input 10-bit value -> output 8-bit value */
static uint8_t lut_r[LUT_SIZE];
static uint8_t lut_g[LUT_SIZE];
static uint8_t lut_b[LUT_SIZE];

/* Output: full 1920x1080 YUYV, or the 960x540 binned fallback with GC2607_ISP_HALF_RES=1. */
static int half_res;
static int out_w = SENSOR_W, out_h = SENSOR_H;
static uint8_t yuyv_buf[SENSOR_W * SENSOR_H * 2];   /* the first out_w * out_h * 2 bytes are used */

static void select_output_size(void)
{
    const char *v = getenv("GC2607_ISP_HALF_RES");
    half_res = v && strcmp(v, "1") == 0;
    out_w = half_res ? HALF_W : SENSOR_W;
    out_h = half_res ? HALF_H : SENSOR_H;
}

static size_t out_bytes(void) { return (size_t)out_w * out_h * 2; }

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

static double seconds_between(const struct timespec *a, const struct timespec *b)
{
    return (b->tv_sec - a->tv_sec) + (b->tv_nsec - a->tv_nsec) / 1e9;
}

/* sRGB encoding (IEC 61966-2-1) of a linear value in [0, 1]. */
static inline float srgb_encode(float v)
{
    return v <= 0.0031308f ? 12.92f * v : 1.055f * powf(v, 1.0f / 2.4f) - 0.055f;
}

/*
 * Build per-channel LUTs that encode the per-pixel pipeline:
 *   black_level_subtract -> WB_gain -> digital gain -> sRGB encoding -> mild contrast
 *
 * The contrast mixes LUT_CONTRAST of a smoothstep into the ENCODED value. Until 2026-10-18
 * the smoothstep ran on linear values before a 1/2.2 gamma, which rendered 18% grey at
 * 83/255 instead of ~117 and crushed the shadows (handover Q2).
 *
 * Called once per frame with updated WB gains and digital gain.
 */
static void build_luts(float r_gain, float g_gain, float b_gain, float digital)
{
    const float gains[3] = { r_gain, g_gain, b_gain };
    uint8_t *luts[3] = { lut_r, lut_g, lut_b };

    for (int c = 0; c < 3; c++) {
        float scale = gains[c] * digital / MAX_SIGNAL;
        for (int i = 0; i < LUT_SIZE; i++) {
            float v = fminf(fmaxf((float)(i - BLACK_LEVEL) * scale, 0.0f), 1.0f);
            float e = srgb_encode(v);
            float s = e + LUT_CONTRAST * (e * e * (3.0f - 2.0f * e) - e);
            luts[c][i] = (uint8_t)(s * 255.0f + 0.5f);
        }
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
    static uint8_t above_u[HALF_W / 2], above_v[HALF_W / 2];
    static uint8_t current_u[HALF_W / 2], current_v[HALF_W / 2];

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
    /* BT.601 limited ("studio") range: Y 16-235, U/V 16-240, what YUYV consumers assume. */
    int y0 = ((66 * r0 + 129 * g0 + 25 * b0 + 128) >> 8) + 16;
    int y1 = ((66 * r1 + 129 * g1 + 25 * b1 + 128) >> 8) + 16;
    /* The pair shares one U and V: take them from the pair's average colour (sums, >> 9),
     * not from the first pixel alone, which coloured every edge from one side. */
    int r = r0 + r1, g = g0 + g1, b = b0 + b1;
    int u  = ((-38 * r - 74 * g + 112 * b + 256) >> 9);
    int v  = ((112 * r - 94 * g - 18 * b + 256) >> 9);
    /* Stand-in for the colour-correction matrix this ISP never had (recorded as the open
     * colour-accuracy gap in docs/archive/PROJECT_HISTORY.md): a raw sensor's colours are
     * muddier than the eye's, and the missing CCM is mostly a saturation lift. */
    u = (u * CHROMA_GAIN_Q8) / 256 + 128;
    v = (v * CHROMA_GAIN_Q8) / 256 + 128;

    out[0] = (uint8_t)(y0 < 16 ? 16 : (y0 > 235 ? 235 : y0));
    out[1] = (uint8_t)(u  < 16 ? 16 : (u  > 240 ? 240 : u));
    out[2] = (uint8_t)(y1 < 16 ? 16 : (y1 > 235 ? 235 : y1));
    out[3] = (uint8_t)(v  < 16 ? 16 : (v  > 240 ? 240 : v));
}

/* Per-frame statistics for white balance and exposure, filled by collect_stats(). */
struct frame_stats {
    float r_mean, g_mean, b_mean;    /* raw above black, over samples neither saturated nor near black */
    int count;                        /* samples in those means */
    float y_mean;                     /* display luma of every sample after the LUTs, 0..1 */
    uint32_t g_hist[HISTOGRAM_BINS];  /* raw green of every sample, saturated included */
    int hist_total;
};

/*
 * Statistics from every WB_SUBSAMPLE-th 2x2 Bayer block in each direction (the half-resolution
 * sampling, whatever the output size). Needs this frame's LUTs for the display luma.
 */
static void collect_stats(const uint16_t *bayer, struct frame_stats *st)
{
    double r_sum = 0, g_sum = 0, b_sum = 0;
    uint64_t y_sum = 0;
    int stat_count = 0;
    int hist_total = 0;
    memset(st->g_hist, 0, sizeof(st->g_hist));

    for (int oy = 0; oy < HALF_H; oy += WB_SUBSAMPLE) {
        const uint16_t *row0 = bayer + (oy * 2) * SENSOR_W;
        const uint16_t *row1 = row0 + SENSOR_W;

        for (int ox = 0; ox < HALF_W; ox += WB_SUBSAMPLE) {
            int r = row0[ox * 2 + 1], b = row1[ox * 2];
            int g = (row0[ox * 2] + row1[ox * 2 + 1]) >> 1;
            if (r >= LUT_SIZE) r = LUT_SIZE - 1;
            if (g >= LUT_SIZE) g = LUT_SIZE - 1;
            if (b >= LUT_SIZE) b = LUT_SIZE - 1;

            /* Histogram and display luma: every sampled pixel including saturated ones —
             * the highlight cap explicitly needs to see clipped values. */
            st->g_hist[g / HIST_BIN_WIDTH]++;
            hist_total++;
            y_sum += 77 * lut_r[r] + 150 * lut_g[g] + 29 * lut_b[b];   /* BT.601 luma x256 */

            /* WB / mean stats: skip saturated — clipped values hide the
             * true channel ratio, causing AWB to underestimate green
             * dominance in bright scenes — and near-black, where noise and
             * any black-level error outweigh the colour. */
            int peak = r > g ? (r > b ? r : b) : (g > b ? g : b);
            if (r < 1020 && g < 1020 && b < 1020 && peak >= BLACK_LEVEL + WB_MIN_SIGNAL) {
                float rv = fmaxf((float)r - BLACK_LEVEL, 0.0f);
                float gv = fmaxf((float)g - BLACK_LEVEL, 0.0f);
                float bv = fmaxf((float)b - BLACK_LEVEL, 0.0f);
                r_sum += rv;
                g_sum += gv;
                b_sum += bv;
                stat_count++;
            }
        }
    }

    if (stat_count > 0) {
        st->r_mean = (float)(r_sum / stat_count);
        st->g_mean = (float)(g_sum / stat_count);
        st->b_mean = (float)(b_sum / stat_count);
    } else {
        st->r_mean = st->g_mean = st->b_mean = 0.0f;
    }
    st->count = stat_count;
    st->hist_total = hist_total;
    st->y_mean = hist_total ? (float)y_sum / (256.0f * 255.0f * hist_total) : 0.0f;
}

/*
 * Copy one Bayer row into a line buffer with one extra column each side, clamped to 10 bits.
 * Column -1 reflects to column 1 and column W to W-2, which keep the Bayer colour.
 */
static inline void load_padded_row(uint16_t *dst, const uint16_t *src)
{
    for (int c = 0; c < SENSOR_W; c++)
        dst[c + 1] = src[c] < LUT_SIZE ? src[c] : LUT_SIZE - 1;
    dst[0] = dst[2];
    dst[SENSOR_W + 1] = dst[SENSOR_W - 1];
}

/*
 * Full-resolution bilinear demosaic of GRBG straight into the 1920x1080 YUYV output, rotated
 * 180 degrees in the same pass. The interpolation follows demosaic_full() in
 * github.com/antonbiluta/gc2607-driver (fd3ea57); this version reads three padded line buffers
 * instead of clamping every access, and reflects rows and columns by two so the outermost
 * pixels interpolate from the right colour.
 *
 *   even rows: G R G R ...     odd rows: B G B G ...
 */
static void demosaic_full(const uint16_t *bayer)
{
    static uint16_t lines[3][SENSOR_W + 2];

    load_padded_row(lines[0], bayer);
    load_padded_row(lines[1], bayer + SENSOR_W);
    for (int r = 0; r < SENSOR_H; r++) {
        if (r >= 1 && r + 1 < SENSOR_H)
            load_padded_row(lines[(r + 1) % 3], bayer + (r + 1) * SENSOR_W);
        /* Row -1 reflects to row 1 and row H to row H-2 (same parity). */
        const uint16_t *U = lines[(r == 0 ? 1 : r - 1) % 3] + 1;
        const uint16_t *C = lines[r % 3] + 1;
        const uint16_t *D = lines[(r + 1 < SENSOR_H ? r + 1 : r - 1) % 3] + 1;
        uint8_t *out_row = yuyv_buf + (SENSOR_H - 1 - r) * SENSOR_W * 2;

        /* Source pixels c and c+1 land at output x W-1-c and W-2-c: one YUYV pair, swapped. */
        if ((r & 1) == 0) {
            for (int c = 0; c < SENSOR_W; c += 2) {
                int g0 = C[c];
                int r0 = (C[c - 1] + C[c + 1] + 1) >> 1;
                int b0 = (U[c] + D[c] + 1) >> 1;
                int r1 = C[c + 1];
                int g1 = (C[c] + C[c + 2] + U[c + 1] + D[c + 1] + 2) >> 2;
                int b1 = (U[c] + U[c + 2] + D[c] + D[c + 2] + 2) >> 2;
                rgb_to_yuyv(lut_r[r1], lut_g[g1], lut_b[b1], lut_r[r0], lut_g[g0], lut_b[b0],
                            out_row + (SENSOR_W - 2 - c) * 2);
            }
        } else {
            for (int c = 0; c < SENSOR_W; c += 2) {
                int b0 = C[c];
                int g0 = (C[c - 1] + C[c + 1] + U[c] + D[c] + 2) >> 2;
                int r0 = (U[c - 1] + U[c + 1] + D[c - 1] + D[c + 1] + 2) >> 2;
                int g1 = C[c + 1];
                int r1 = (U[c + 1] + D[c + 1] + 1) >> 1;
                int b1 = (C[c] + C[c + 2] + 1) >> 1;
                rgb_to_yuyv(lut_r[r1], lut_g[g1], lut_b[b1], lut_r[r0], lut_g[g0], lut_b[b0],
                            out_row + (SENSOR_W - 2 - c) * 2);
            }
        }
    }
}

/*
 * 2x2 binning to the 960x540 fallback output (GC2607_ISP_HALF_RES=1), with 180 degree rotation.
 * Each 2x2 GRBG block -> one output pixel (R, avg(G1,G2), B).
 * Output row (HALF_H-1-oy) col (HALF_W-1-ox) maps to Bayer block at (oy*2, ox*2).
 */
static void bin_half(const uint16_t *bayer)
{
    for (int oy = 0; oy < HALF_H; oy++) {
        /* Bayer row pointers for this 2x2 block row */
        const uint16_t *row0 = bayer + (oy * 2) * SENSOR_W;
        const uint16_t *row1 = bayer + (oy * 2 + 1) * SENSOR_W;

        /* Output row (flipped) */
        int out_y = HALF_H - 1 - oy;
        uint8_t *out_row = yuyv_buf + out_y * HALF_W * 2;

        /* Process pairs of output pixels for YUYV packing */
        for (int ox = 0; ox < HALF_W; ox += 2) {
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
            int out_x = HALF_W - 2 - ox;
            /* Swap pixel order within the pair for horizontal flip */
            rgb_to_yuyv(R1, G1, B1, R0, G0, B0, out_row + out_x * 2);
        }
    }

    /* False-colour suppression: 3x3 chroma median over the YUYV buffer.
     * Y is untouched so luma sharpness is preserved. */
    chroma_median_filter(yuyv_buf, HALF_W, HALF_H);
}

/*
 * Process one Bayer frame -> YUYV in yuyv_buf (out_w x out_h, rotated 180 degrees) with white
 * balance wb[3] and digital gain d, and fill the statistics for white balance and exposure.
 */
static void process_frame(const uint16_t *bayer, const float wb[3], float d, struct frame_stats *st)
{
    build_luts(wb[0], wb[1], wb[2], d);
    collect_stats(bayer, st);
    if (half_res)
        bin_half(bayer);
    else
        demosaic_full(bayer);
}

/*
 * Grey-world white-balance gains relative to green, divided by the smallest so that none is
 * below 1.0. A gain below 1 keeps that channel short of 255 when the sensor saturates, which
 * tinted clipped highlights pink (handover Q5).
 */
static void wb_gains(float r_rel, float b_rel, float wb[3])
{
    float lo = fminf(fminf(r_rel, 1.0f), b_rel);
    wb[0] = r_rel / lo;
    wb[1] = 1.0f / lo;
    wb[2] = b_rel / lo;
}

/* Grey-world gains relative to green from one frame, within WB_R_* and WB_B_*. Returns 0 (keep the
 * previous balance) when under 1% of the samples are usable or a channel is too dark to measure. */
static int wb_from_stats(const struct frame_stats *st, float *r_rel, float *b_rel)
{
    if (st->count * 100 < st->hist_total || st->r_mean <= 1.0f || st->g_mean <= 1.0f || st->b_mean <= 1.0f)
        return 0;
    *r_rel = fminf(fmaxf(st->g_mean / st->r_mean, WB_R_MIN), WB_R_MAX);
    *b_rel = fminf(fmaxf(st->g_mean / st->b_mean, WB_B_MIN), WB_B_MAX);
    return 1;
}

/* Sensor controls plus the digital gain d the LUTs apply. */
struct ae_hw {
    int exposure;   /* lines */
    int gain;       /* driver gain index 0..GAIN_MAX */
    int fll;        /* frame length, lines */
    float d;
};

struct ae_state {
    struct ae_hw cur;      /* last controls written; d is what the current frame is rendered with */
    float next_d;          /* d for the first frame taken with the last write */
    int skip;              /* frames still taken with the controls before the last write */
    int session_frames;
    int flicker_lines;     /* exposure quantum against mains flicker, 0 = off */
};

/* One frame's metering, kept for the status line. */
struct ae_meter {
    float y, p98, clipped, m;
};

static double ae_total(const struct ae_hw *h) { return h->exposure * (double)gain_of(h->gain) * h->d; }

/* Lines per flicker period (lamps flicker at twice the mains frequency) from GC2607_ISP_FLICKER_HZ. */
static int flicker_lines_from_env(void)
{
    const char *v = getenv("GC2607_ISP_FLICKER_HZ");
    int hz = v ? atoi(v) : FLICKER_HZ_DEFAULT;
    if (hz != 0 && hz != 50 && hz != 60)
        hz = FLICKER_HZ_DEFAULT;
    return hz ? (int)lroundf(1e6f / (2.0f * hz) / LINE_US) : 0;
}

/* Largest gain index up to `cap` with exposure x gain <= total. */
static int gain_for(double total, int exposure, int cap)
{
    int g = 0;
    while (g < cap && exposure * (double)gain_of(g + 1) <= total)
        g++;
    return g;
}

/*
 * Spread a total exposure over the sensor, least noise first (and release in reverse): exposure
 * up to 30 ms at unity gain; then analogue gain up to 3.95x; then a longer frame, down to 15 fps,
 * with exposure up to 60 ms; then gain up to 15.8x; then digital gain up to 2x. d covers what
 * the integer steps leave. Once the exposure spans a flicker period it is rounded down to whole
 * periods, so mains-powered lights cannot band, and d makes up the rest.
 */
static struct ae_hw ae_allocate(double total, int flicker)
{
    total = fmin(fmax(total, EXPOSURE_MIN), EXPOSURE_15FPS * (double)gain_of(GAIN_MAX) * DIGITAL_MAX);
    struct ae_hw h;
    int cap;
    if (total <= EXPOSURE_30FPS) {
        h.exposure = (int)total;
        cap = 0;
    } else if (total <= EXPOSURE_30FPS * (double)gain_of(GAIN_30FPS)) {
        h.exposure = EXPOSURE_30FPS;
        cap = GAIN_30FPS;
    } else if (total <= EXPOSURE_15FPS * (double)gain_of(GAIN_30FPS)) {
        h.exposure = (int)(total / gain_of(GAIN_30FPS));
        cap = GAIN_30FPS;
    } else {
        h.exposure = EXPOSURE_15FPS;
        cap = GAIN_MAX;
    }
    if (flicker && h.exposure >= flicker)
        h.exposure -= h.exposure % flicker;
    h.gain = gain_for(total, h.exposure, cap);
    h.d = (float)fmin(fmax(total / (h.exposure * (double)gain_of(h.gain)), 1.0), DIGITAL_MAX);
    h.fll = h.exposure + EXPOSURE_MARGIN > FLL_MIN ? h.exposure + EXPOSURE_MARGIN : FLL_MIN;
    return h;
}

/*
 * Meter one frame rendered with green white-balance gain wb_g and digital gain d. Returns the
 * factor to move the total exposure by: 1.0 inside the deadband, the full correction while
 * `fast` (a session's first frames), otherwise a damped share of it.
 */
static float ae_meter_frame(const struct frame_stats *st, float wb_g, float d, int fast, struct ae_meter *mt)
{
    int threshold = (int)(st->hist_total * AE_PCTILE), cum = 0, bin = HISTOGRAM_BINS - 1;
    for (int b = 0; b < HISTOGRAM_BINS; b++) {
        cum += st->g_hist[b];
        if (cum >= threshold) {
            bin = b;
            break;
        }
    }
    mt->p98 = fmaxf(((bin + 0.5f) * HIST_BIN_WIDTH - BLACK_LEVEL) / MAX_SIGNAL, 0.001f) * wb_g * d;
    mt->clipped = st->hist_total ? (float)st->g_hist[HISTOGRAM_BINS - 1] / st->hist_total : 0.0f;
    mt->y = st->y_mean;

    float y = fmaxf(mt->y, 0.001f);
    float m = fminf(powf(AE_TARGET_Y / y, AE_GAMMA),
                    mt->clipped >= AE_CLIP_FRACTION ? AE_CAP_CLIPPED : AE_CAP_P98 / mt->p98);
    if (y * powf(m, 1.0f / AE_GAMMA) < AE_FLOOR_Y)   /* backlight: keep the subject visible */
        m = powf(AE_FLOOR_Y / y, AE_GAMMA);
    m = fminf(fmaxf(m, AE_STEP_MIN), AE_STEP_MAX);
    mt->m = m;
    if (fabsf(log2f(m)) < AE_DEADBAND_LOG2)
        return 1.0f;
    return fast ? m : fminf(fmaxf(powf(m, AE_DAMPING), 1.0f / AE_UPDATE_MAX), AE_UPDATE_MAX);
}

/*
 * Advance the controller by one processed frame. Returns 1 when `*write` holds new sensor
 * controls to apply now. The next AE_LATENCY_FRAMES frames were already taken with the old
 * controls: they keep the old d and are not metered, and d switches with the first new frame.
 */
static int ae_step(struct ae_state *s, float factor, struct ae_hw *write)
{
    if (s->skip > 0) {
        if (--s->skip == 0)
            s->cur.d = s->next_d;
        return 0;
    }
    if (factor == 1.0f)
        return 0;
    struct ae_hw h = ae_allocate(ae_total(&s->cur) * factor, s->flicker_lines);
    if (h.exposure == s->cur.exposure && h.gain == s->cur.gain && h.fll == s->cur.fll) {
        s->cur.d = h.d;   /* software only: takes effect on the next frame */
        return 0;
    }
    s->next_d = h.d;
    h.d = s->cur.d;
    *write = h;
    s->cur = h;
    s->skip = AE_LATENCY_FRAMES;
    return 1;
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

/*
 * Write sensor controls so the exposure never exceeds the frame: a longer frame (VBLANK) is
 * written before the exposure, a shorter one after it. Returns the number of failed writes.
 */
static int set_sensor_controls(int fd, const struct ae_hw *h, int longer_frame)
{
    struct v4l2_control vblank = { .id = V4L2_CID_VBLANK, .value = h->fll - SENSOR_H };
    struct v4l2_control ctrls[3] = {
        { .id = V4L2_CID_EXPOSURE, .value = h->exposure },
        { .id = V4L2_CID_ANALOGUE_GAIN, .value = h->gain },
        vblank,
    };
    if (longer_frame) {
        ctrls[2] = ctrls[1];
        ctrls[1] = ctrls[0];
        ctrls[0] = vblank;
    }
    int failed = 0;
    for (int i = 0; i < 3; i++)
        failed += xioctl(fd, VIDIOC_S_CTRL, &ctrls[i]) < 0;
    return failed;
}

/*
 * Open the capture device, set format, request and map buffers,
 * and start streaming. Returns the fd on success, -1 on failure.
 */
static int open_capture(const char *dev, struct buffer *buffers, int *n_buffers)
{
    /* Non-blocking, so the frame wait in streaming_loop() can time out on a stalled
     * sensor instead of sleeping in DQBUF forever (and past SIGTERM). */
    int fd = open(dev, O_RDWR | O_NONBLOCK);
    if (fd < 0) {
        perror("open capture device");
        return -1;
    }
    int mapped = 0;
    int have_bufs = 0;

    /* Set format, then check what the driver actually granted: process_frame()
     * reads rows at a fixed SENSOR_W stride, so any adjustment would read the
     * wrong pixels or past the end of the buffer. */
    struct v4l2_format fmt = {0};
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width = SENSOR_W;
    fmt.fmt.pix.height = SENSOR_H;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_SGRBG10;
    fmt.fmt.pix.field = V4L2_FIELD_NONE;
    if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
        perror("VIDIOC_S_FMT");
        goto fail;
    }
    if (fmt.fmt.pix.width != SENSOR_W || fmt.fmt.pix.height != SENSOR_H ||
        fmt.fmt.pix.pixelformat != V4L2_PIX_FMT_SGRBG10 ||
        fmt.fmt.pix.bytesperline != SENSOR_W * 2) {
        fprintf(stderr, "[gc2607_isp] capture format %ux%u stride %u is not the %dx%d SGRBG10 "
                "stride %d this ISP reads\n", fmt.fmt.pix.width, fmt.fmt.pix.height,
                fmt.fmt.pix.bytesperline, SENSOR_W, SENSOR_H, SENSOR_W * 2);
        goto fail;
    }

    /* Request buffers. buffers[] holds NUM_BUFFERS; the driver may grant a
     * different count, so refuse rather than overflow it. */
    struct v4l2_requestbuffers req = {0};
    req.count = NUM_BUFFERS;
    req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = V4L2_MEMORY_MMAP;
    if (xioctl(fd, VIDIOC_REQBUFS, &req) < 0) {
        perror("VIDIOC_REQBUFS");
        goto fail;
    }
    have_bufs = 1;
    if (req.count < 2 || req.count > NUM_BUFFERS) {
        fprintf(stderr, "[gc2607_isp] driver granted %u buffers, need 2..%d\n",
                req.count, NUM_BUFFERS);
        goto fail;
    }

    /* Map buffers */
    for (int i = 0; i < (int)req.count; i++) {
        struct v4l2_buffer buf = {0};
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index = i;
        if (xioctl(fd, VIDIOC_QUERYBUF, &buf) < 0) {
            perror("VIDIOC_QUERYBUF");
            goto fail;
        }
        if (buf.length < (unsigned)FRAME_PIXELS * 2) {
            fprintf(stderr, "[gc2607_isp] buffer %d is %u bytes, a frame needs %d\n",
                    i, buf.length, FRAME_PIXELS * 2);
            goto fail;
        }

        buffers[i].length = buf.length;
        buffers[i].start = mmap(NULL, buf.length, PROT_READ | PROT_WRITE,
                                MAP_SHARED, fd, buf.m.offset);
        if (buffers[i].start == MAP_FAILED) {
            perror("mmap");
            goto fail;
        }
        mapped++;
    }

    /* Queue buffers */
    for (int i = 0; i < (int)req.count; i++) {
        struct v4l2_buffer buf = {0};
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index = i;
        if (xioctl(fd, VIDIOC_QBUF, &buf) < 0) {
            perror("VIDIOC_QBUF");
            goto fail;
        }
    }

    /* Start streaming */
    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (xioctl(fd, VIDIOC_STREAMON, &type) < 0) {
        perror("VIDIOC_STREAMON");
        goto fail;
    }

    *n_buffers = req.count;
    return fd;

fail:
    /* Undo everything: a live mapping keeps the file (and so the buffer queue)
     * owned after close(), and every retry would then fail with EBUSY. */
    for (int i = 0; i < mapped; i++)
        munmap(buffers[i].start, buffers[i].length);
    if (have_bufs) {
        struct v4l2_requestbuffers none = {0};
        none.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        none.memory = V4L2_MEMORY_MMAP;
        xioctl(fd, VIDIOC_REQBUFS, &none);
    }
    close(fd);
    return -1;
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
    fmt.fmt.pix.width = out_w;
    fmt.fmt.pix.height = out_h;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
    fmt.fmt.pix.field = V4L2_FIELD_NONE;
    fmt.fmt.pix.sizeimage = out_bytes();
    if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
        perror("VIDIOC_S_FMT output");
        close(fd);
        return -1;
    }

    return fd;
}

/* Ask for the client-usage event on the output fd, with the current state sent at once. */
static int subscribe_reader_events(int out_fd)
{
    struct v4l2_event_subscription sub = {
        .type = V4L2_EVENT_PRI_CLIENT_USAGE,
        .flags = V4L2_EVENT_SUB_FL_SEND_INITIAL,
    };
    return xioctl(out_fd, VIDIOC_SUBSCRIBE_EVENT, &sub);
}

/*
 * Dequeue the pending client-usage events and return the latest reader count (`readers` if none).
 * Call only after poll() reported POLLPRI: the fd is blocking, so DQEVENT with nothing queued
 * would wait for the next event.
 */
static int take_reader_events(int out_fd, int readers)
{
    struct v4l2_event ev;
    do {
        if (xioctl(out_fd, VIDIOC_DQEVENT, &ev) < 0)
            break;
        if (ev.type == V4L2_EVENT_PRI_CLIENT_USAGE)
            readers = ((const struct v4l2_event_client_usage *)&ev.u)->count;
    } while (ev.pending > 0);
    return readers;
}

/* Fill the output with black (YUYV limited range), the frame idle readers and the next app see. */
static void fill_standby(void)
{
    for (size_t i = 0; i < out_bytes(); i += 4) {
        yuyv_buf[i] = 16;
        yuyv_buf[i + 1] = 128;
        yuyv_buf[i + 2] = 16;
        yuyv_buf[i + 3] = 128;
    }
}

/*
 * Run the streaming loop: capture frames from the sensor, process them
 * through the ISP pipeline, and write to the output device.
 *
 * Exits when: running becomes 0 (signal), or no reader has been streaming for READER_GRACE_S.
 *
 * Returns: 0 on a clean exit, -1 on error.
 */
static int streaming_loop(const char *capture_dev, int out_fd,
                          const char *subdev_path, int has_subdev)
{
    struct buffer buffers[NUM_BUFFERS];
    int n_buffers = 0;

    /*
     * Exposure and white-balance state persist across streaming sessions, so a new session
     * starts from the last exposure instead of reconverging. First start: 30 ms, unity gain.
     */
    static struct ae_state ae = {
        .cur = { .exposure = EXPOSURE_30FPS, .gain = 0, .fll = FLL_MIN, .d = 1.0f },
    };
    static float wb_r_rel = 1.0f, wb_b_rel = 1.0f;   /* grey-world gains relative to green */
    if (ae.skip) {   /* the last session ended inside a write's latency: its controls stand */
        ae.cur.d = ae.next_d;
        ae.skip = 0;
    }
    ae.session_frames = 0;
    ae.flicker_lines = flicker_lines_from_env();

    /* Restore the controls; the sensor is off, so writing the frame length first always fits. */
    int sub_fd = has_subdev ? open(subdev_path, O_RDWR) : -1;
    int ctrl_failures = sub_fd >= 0 ? set_sensor_controls(sub_fd, &ae.cur, 1) : 0;

    int cap_fd = open_capture(capture_dev, buffers, &n_buffers);
    if (cap_fd < 0) {
        if (sub_fd >= 0)
            close(sub_fd);
        return -1;
    }

    printf("[gc2607_isp] Streaming started (output %dx%d YUYV, exp=%d gain=%d fll=%d d=%.2f, flicker %d lines)\n",
           out_w, out_h, ae.cur.exposure, ae.cur.gain, ae.cur.fll, ae.cur.d, ae.flicker_lines);

    int frame_count = 0;
    int readers = 1;           /* a streaming reader started this session */
    int reader_left = 0;       /* stopped because no reader streamed for READER_GRACE_S */

    struct timespec now, last_frame, idle_since, last_status;
    clock_gettime(CLOCK_MONOTONIC, &last_frame);
    last_status = idle_since = last_frame;

    while (running) {
        /* Frames arrive on the capture fd and reader changes as POLLPRI on the output fd. Wait at
         * most a second, so a stalled sensor or a SIGTERM is noticed instead of blocking for ever. */
        struct pollfd pfd[2] = { { .fd = cap_fd, .events = POLLIN }, { .fd = out_fd, .events = POLLPRI } };
        int pr = poll(pfd, 2, 1000);
        if (pr < 0) {
            if (errno == EINTR) continue;
            perror("poll capture");
            break;
        }
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (pfd[1].revents & POLLPRI) {
            int was = readers;
            readers = take_reader_events(out_fd, readers);
            if (was > 0 && readers == 0)
                idle_since = now;
        }
        if (readers == 0 && seconds_between(&idle_since, &now) >= READER_GRACE_S) {
            printf("[gc2607_isp] No reader streaming, stopping stream (%d frames)\n", frame_count);
            reader_left = 1;
            break;
        }
        if (!(pfd[0].revents & POLLIN)) {
            if (seconds_between(&last_frame, &now) >= CAPTURE_STALL_S) {
                printf("[gc2607_isp] No frame for %ds, restarting capture\n", CAPTURE_STALL_S);
                break;
            }
            continue;
        }
        last_frame = now;

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

        float wb[3];
        wb_gains(wb_r_rel, wb_b_rel, wb);
        struct frame_stats st;
        process_frame(bayer, wb, ae.cur.d, &st);

        /* White balance: grey world, unsmoothed for a session's first frames */
        float r_rel, b_rel;
        if (wb_from_stats(&st, &r_rel, &b_rel)) {
            float sm = frame_count < 10 ? 0.0f : WB_SMOOTHING;
            wb_r_rel = sm * wb_r_rel + (1.0f - sm) * r_rel;
            wb_b_rel = sm * wb_b_rel + (1.0f - sm) * b_rel;
        }

        /* Exposure: meter, then move the total and write the sensor when its share changes */
        struct ae_meter mt;
        float factor = ae_meter_frame(&st, wb[1], ae.cur.d, ae.session_frames < AE_FAST_FRAMES, &mt);
        ae.session_frames++;
        struct ae_hw next;
        int old_fll = ae.cur.fll;
        if (ae_step(&ae, factor, &next) && sub_fd >= 0)
            ctrl_failures += set_sensor_controls(sub_fd, &next, next.fll > old_fll);

        /* Write YUYV to v4l2loopback */
        ssize_t written = write(out_fd, yuyv_buf, out_bytes());
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
            printf("[gc2607_isp] %d frames | %.1f fps | WB: R=%.2f G=%.2f B=%.2f | exp=%d gain=%d fll=%d d=%.2f"
                   " | Y=%.3f P98=%.2f clip=%.1f%% m=%.2f | ctrl_fail=%d\n",
                   frame_count, 150 / seconds_between(&last_status, &now), wb[0], wb[1], wb[2],
                   ae.cur.exposure, ae.cur.gain, ae.cur.fll, ae.cur.d,
                   mt.y, mt.p98, 100.0f * mt.clipped, mt.m, ctrl_failures);
            last_status = now;
        }
    }

    close_capture(cap_fd, buffers, n_buffers);
    if (sub_fd >= 0)
        close(sub_fd);
    if (reader_left)
        return 0;
    printf("[gc2607_isp] Shutting down (%d frames total)\n", frame_count);
    return running ? -1 : 0;
}

int main(int argc, char *argv[])
{
    const char *capture_dev = argc > 1 ? argv[1] : "/dev/video1";
    const char *output_dev  = argc > 2 ? argv[2] : "/dev/video50";

    /* Line-buffered stdout so logs appear in journald */
    setvbuf(stdout, NULL, _IOLBF, 0);

    select_output_size();
    printf("[gc2607_isp] Starting with lazy activation (capture=%s output=%s %dx%d)\n",
           capture_dev, output_dev, out_w, out_h);

    /* sigaction without SA_RESTART: glibc's signal() restarts interrupted calls,
     * which is how a SIGTERM used to wait out the whole stop timeout. */
    struct sigaction sa = {0};
    sa.sa_handler = signal_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

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

    if (subscribe_reader_events(out_fd) < 0) {
        perror("[gc2607_isp] VIDIOC_SUBSCRIBE_EVENT (v4l2loopback client usage)");
        close(out_fd);
        return 1;
    }

    /*
     * Idle until a reader starts streaming from /dev/video50 (v4l2loopback's client-usage
     * event), writing a black standby frame every STANDBY_INTERVAL_MS so PipeWire and camera
     * apps can discover and probe the device; then stream until no reader is left.
     */
    fill_standby();
    write(out_fd, yuyv_buf, out_bytes());
    printf("[gc2607_isp] Idle, waiting for consumers on %s...\n", output_dev);

    int readers = 0, stream_fails = 0;
    while (running) {
        struct pollfd pfd = { .fd = out_fd, .events = POLLPRI };
        if (poll(&pfd, 1, STANDBY_INTERVAL_MS) > 0 && (pfd.revents & POLLPRI))
            readers = take_reader_events(out_fd, readers);
        if (readers == 0) {
            write(out_fd, yuyv_buf, out_bytes());
            continue;
        }

        printf("[gc2607_isp] A reader is streaming, starting stream...\n");
        int ret = streaming_loop(capture_dev, out_fd, subdev_path, has_subdev);
        readers = 0;   /* the loop consumed the events up to its exit */
        stream_fails = (ret < 0) ? stream_fails + 1 : 0;
        if (ret < 0 && running && stream_fails >= MAX_STREAM_FAILS) {
            /* Retrying in-process has stopped helping; exit non-zero so
             * Restart=on-failure starts from a clean process. */
            printf("[gc2607_isp] %d streaming failures in a row, exiting\n", stream_fails);
            close(out_fd);
            return 1;
        }
        if (ret < 0 && running) {
            printf("[gc2607_isp] Streaming error, retrying in 2s...\n");
            sleep(2);
        }
        fill_standby();   /* never leave the last camera frame on the device */
        if (running)
            printf("[gc2607_isp] Idle, waiting for consumers on %s...\n", output_dev);
    }

    printf("[gc2607_isp] Exiting\n");
    close(out_fd);

    return 0;
}
