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
 * Auto exposure — dual-constraint AGC (libcamera AgcMeanLuminance pattern).
 *
 * Each frame computes two independent brightness targets and takes the
 * smaller (= more restrictive). This is the production-standard approach
 * used on Raspberry Pi / IPU3 — a plain mean target alone cannot tell
 * "few clipped pixels" from "lots of clipped pixels", which is why bright
 * scenes with white walls blow out even when the mean lands on target.
 *
 *  1. Mean target (centre-weighted): aim for AE_TARGET on the subject area.
 *  2. Highlight cap: the AE_HIGHLIGHT_PCTILE percentile of green must stay
 *     at or below AE_HIGHLIGHT_CAP in 8-bit output. Walls/ceiling can no
 *     longer pin at 255.
 */
#define AE_TARGET           100.0f  /* mean (0-255) for centre-weighted subject */
#define AE_HIGHLIGHT_PCTILE 0.98f   /* upper 2% of pixels are the "highlight" set */
#define AE_HIGHLIGHT_CAP    220.0f  /* their value must not exceed this (0-255) */
#define AE_SMOOTHING        0.92f   /* temporal smoothing */
#define AE_INTERVAL_S       1.5     /* hardware AE adjustment interval */
#define BRIGHTNESS_MIN      0.5f
#define BRIGHTNESS_MAX      3.5f

/* Green-channel histogram for highlight detection: 1024/64 = 16 raw per bin. */
#define HISTOGRAM_BINS      64
#define HIST_BIN_WIDTH      (LUT_SIZE / HISTOGRAM_BINS)  /* = 16 */

/* Centre region for AE mean (typical webcam framing: subject middle of frame).
 * Centre pixels weighted 2x in the green mean; edges 1x. Boundaries in OUTPUT
 * coordinates (0..OUT_W, 0..OUT_H). */
#define CENTRE_X_LO   (OUT_W * 25 / 100)   /* 25% to 75% horizontally */
#define CENTRE_X_HI   (OUT_W * 75 / 100)
#define CENTRE_Y_LO   (OUT_H * 15 / 100)   /* 15% to 85% vertically */
#define CENTRE_Y_HI   (OUT_H * 85 / 100)

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
 * Build per-channel LUTs that encode the entire per-pixel pipeline:
 *   black_level_subtract -> WB_gain -> brightness_scale -> S-curve -> gamma
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
        vr = vr * vr * (3.0f - 2.0f * vr);       /* S-curve contrast */
        vr = powf(vr, 1.0f / 2.2f);                /* sRGB gamma */
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
static float process_frame(const uint16_t *bayer, float r_gain, float b_gain,
                           float brightness, float *out_r_sum, float *out_g_sum,
                           float *out_b_sum, float *out_g_mean_centre,
                           uint32_t *out_g_hist, int *out_hist_total,
                           int *out_count)
{
    /* Green gain is always 1.0 in gray-world WB */
    build_luts(r_gain, 1.0f, b_gain, brightness);

    double r_sum = 0, g_sum = 0, b_sum = 0;
    double g_sum_centre = 0, weight_total = 0;
    int stat_count = 0;
    int hist_total = 0;
    for (int i = 0; i < HISTOGRAM_BINS; i++) out_g_hist[i] = 0;

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

                    /* Centre-weighted green mean for AE — push the subject
                     * toward AE_TARGET rather than the whole frame, so a
                     * bright background does not pull the subject dark. */
                    int in_centre = (out_x >= CENTRE_X_LO && out_x < CENTRE_X_HI
                                  && out_y >= CENTRE_Y_LO && out_y < CENTRE_Y_HI);
                    float w = in_centre ? 2.0f : 1.0f;
                    g_sum_centre += gv * w;
                    weight_total += w;
                }
            }
        }
    }

    if (stat_count > 0) {
        *out_r_sum = (float)(r_sum / stat_count);
        *out_g_sum = (float)(g_sum / stat_count);
        *out_b_sum = (float)(b_sum / stat_count);
    } else {
        *out_r_sum = *out_g_sum = *out_b_sum = 0.0f;
    }
    *out_g_mean_centre = (weight_total > 0) ? (float)(g_sum_centre / weight_total) : *out_g_sum;
    *out_count = stat_count;
    *out_hist_total = hist_total;

    return *out_g_sum;
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
        float r_mean, g_mean, b_mean, g_mean_centre;
        uint32_t g_hist[HISTOGRAM_BINS];
        int stat_count, hist_total;
        process_frame(bayer, wb_r_gain, wb_b_gain, brightness,
                      &r_mean, &g_mean, &b_mean, &g_mean_centre,
                      g_hist, &hist_total, &stat_count);

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

        /* (a) Mean target on the centre-weighted subject */
        float cur_centre_8bit = g_mean_centre * brightness / MAX_SIGNAL * 255.0f;
        float bright_for_mean = (cur_centre_8bit > 1.0f)
            ? brightness * AE_TARGET / cur_centre_8bit
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
            printf("[gc2607_isp] %d frames | WB: R=%.2f B=%.2f | bright=%.2f | exp=%d gain=%d | means: R=%.1f G=%.1f Gctr=%.1f B=%.1f | AE: mean=>%.2f cap=>%.2f\n",
                   frame_count, wb_r_gain, wb_b_gain, brightness, cur_exposure, cur_gain,
                   r_mean, g_mean, g_mean_centre, b_mean,
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
