/*
 * ae_latency: measure how many frames the GC2607 takes to apply an exposure or gain change.
 *
 *   ae_latency CAPTURE_DEV SENSOR_SUBDEV exposure|gain
 *
 * Streams raw frames, writes a 2x step (exposure 500 -> 1000 lines, or gain index 4 -> 8) right
 * after frame WRITE_AFTER is dequeued, and prints the mean green level of each frame around it.
 * K = frames after the write that still show the old value (0 = the very next frame changed).
 * The exposure controller (handover Q1) needs K. Run by gc2607-raw-capture.sh --latency, with
 * the camera service stopped; it turns the camera on.
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define W 1920
#define H 1080
#define NBUF 4
#define FRAMES 40
#define WRITE_AFTER 20
#define CHANGED 0.30 /* a 2x step moves the signal far more than this */
#define BLACK_LEVEL 64 /* compare signal above black: in a dark room the black level dominates the raw mean */

static int xioctl(int fd, unsigned long req, void *arg)
{
    int r;
    do {
        r = ioctl(fd, req, arg);
    } while (r == -1 && errno == EINTR);
    return r;
}

static int set_ctrl(int fd, uint32_t id, int value)
{
    struct v4l2_control c = { .id = id, .value = value };
    return xioctl(fd, VIDIOC_S_CTRL, &c);
}

/* Mean of the Gr samples (even rows, even columns of GRBG), every 4th one each way. */
static double mean_green(const uint16_t *b)
{
    double s = 0;
    long n = 0;
    for (int y = 0; y < H; y += 8)
        for (int x = 0; x < W; x += 8) {
            s += b[y * W + x];
            n++;
        }
    return s / n;
}

int main(int argc, char **argv)
{
    if (argc != 4 || (strcmp(argv[3], "exposure") && strcmp(argv[3], "gain"))) {
        fprintf(stderr, "usage: %s CAPTURE_DEV SENSOR_SUBDEV exposure|gain\n", argv[0]);
        return 2;
    }
    int gain_test = !strcmp(argv[3], "gain");
    int cap = open(argv[1], O_RDWR);
    int sd = open(argv[2], O_RDWR);
    if (cap < 0 || sd < 0) {
        perror("open");
        return 1;
    }

    /* Starting point; the driver stores these and applies them at stream start. */
    if (set_ctrl(sd, V4L2_CID_EXPOSURE, 500) || set_ctrl(sd, V4L2_CID_ANALOGUE_GAIN, 4)) {
        perror("set start controls");
        return 1;
    }

    struct v4l2_format fmt = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE };
    fmt.fmt.pix.width = W;
    fmt.fmt.pix.height = H;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_SGRBG10;
    fmt.fmt.pix.field = V4L2_FIELD_NONE;
    if (xioctl(cap, VIDIOC_S_FMT, &fmt) || fmt.fmt.pix.bytesperline != W * 2) {
        fprintf(stderr, "capture format not 1920x1080 SGRBG10 with stride 3840\n");
        return 1;
    }
    struct v4l2_requestbuffers req = { .count = NBUF, .type = V4L2_BUF_TYPE_VIDEO_CAPTURE,
                                       .memory = V4L2_MEMORY_MMAP };
    if (xioctl(cap, VIDIOC_REQBUFS, &req) || req.count < 2 || req.count > NBUF) {
        fprintf(stderr, "REQBUFS failed or granted %u buffers\n", req.count);
        return 1;
    }
    void *mem[NBUF];
    for (unsigned i = 0; i < req.count; i++) {
        struct v4l2_buffer b = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE, .memory = V4L2_MEMORY_MMAP, .index = i };
        if (xioctl(cap, VIDIOC_QUERYBUF, &b) || b.length < (unsigned)(W * H * 2))
            return 1;
        mem[i] = mmap(NULL, b.length, PROT_READ | PROT_WRITE, MAP_SHARED, cap, b.m.offset);
        if (mem[i] == MAP_FAILED || xioctl(cap, VIDIOC_QBUF, &b))
            return 1;
    }
    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (xioctl(cap, VIDIOC_STREAMON, &type)) {
        perror("STREAMON");
        return 1;
    }

    double mean[FRAMES];
    unsigned seq[FRAMES];
    for (int f = 0; f < FRAMES; f++) {
        struct v4l2_buffer b = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE, .memory = V4L2_MEMORY_MMAP };
        if (xioctl(cap, VIDIOC_DQBUF, &b)) {
            perror("DQBUF");
            return 1;
        }
        mean[f] = mean_green(mem[b.index]);
        seq[f] = b.sequence;
        if (f == WRITE_AFTER &&
            (gain_test ? set_ctrl(sd, V4L2_CID_ANALOGUE_GAIN, 8) : set_ctrl(sd, V4L2_CID_EXPOSURE, 1000))) {
            perror("step write");
            return 1;
        }
        if (xioctl(cap, VIDIOC_QBUF, &b))
            return 1;
    }
    xioctl(cap, VIDIOC_STREAMOFF, &type);

    int first = -1;
    for (int f = WRITE_AFTER - 5; f < FRAMES; f++) {
        double rel = (mean[f] - BLACK_LEVEL) / (mean[WRITE_AFTER] - BLACK_LEVEL) - 1.0;
        printf("frame %2d seq %4u mean %7.1f (%+5.0f%%)%s\n", f, seq[f], mean[f], 100 * rel,
               f == WRITE_AFTER ? "  <- step written after this frame" : "");
        if (f > WRITE_AFTER && first < 0 && fabs(rel) > CHANGED)
            first = f;
    }
    int dropped = (int)(seq[FRAMES - 1] - seq[0]) - (FRAMES - 1);
    if (first < 0) {
        printf("%s: no change above %.0f%% within %d frames (dropped frames: %d)\n", argv[3], 100 * CHANGED,
               FRAMES - WRITE_AFTER - 1, dropped);
        return 1;
    }
    printf("%s: K = %d (first changed frame %d; dropped frames: %d)\n", argv[3], first - WRITE_AFTER - 1,
           first, dropped);
    return 0;
}
