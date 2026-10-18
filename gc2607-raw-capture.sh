#!/bin/bash
#
# Capture raw Bayer frames from the GC2607 for offline ISP work, or measure how many frames the
# sensor takes to apply a control change (docs/reviews/2026-10-18-camera-fix-handover.md, T0.2-T0.4).
# Stops the camera service for the duration and always starts it again.
# TURNS THE CAMERA ON (privacy light): run only with the owner present.
#
#   sudo ./gc2607-raw-capture.sh --session          guided corpus: prompts for each scene, then --latency
#   sudo ./gc2607-raw-capture.sh [--frames N] SCENE EXP:GAIN[:VBLANK] [EXP:GAIN[:VBLANK] ...]
#   sudo ./gc2607-raw-capture.sh --latency
#   sudo ./gc2607-raw-capture.sh --fps VBLANK [VBLANK ...]   frame rate at each vertical blanking (D1)
#   add --dry-run to any form to only discover devices and check arguments
#
# SCENE: a short label ([a-z0-9_-]). EXP: exposure lines; GAIN: analogue gain table index (0-16);
# VBLANK: vertical blanking lines (only once the driver makes it writable).
# Frames: 1920x1080 little-endian uint16 (10-bit data, 3840 bytes per row), 10 skipped first, with a
# JSON sidecar, in /home/ff235/cache/gc2607/raw/<date>/<scene>_e<EXP>_g<GAIN>[_vb<VBLANK>].raw.
# The camera work runs as ff235 (in the video group); root only stops and starts the service.
# --latency and --session need `make build/ae_latency` first.
#
set -euo pipefail

REPO="/home/ff235/dev/gc2607-v4l2-driver"
OWNER="ff235"
OUT_ROOT="/home/ff235/cache/gc2607/raw"
FRAME_BYTES=$((1920 * 1080 * 2))
SERVICE="gc2607-camera.service"

# The corpus (handover T0.3): scene, what the owner sets up, settings.
SESSION=(
    "normal|you at the desk, room lights on|600:4 1200:0"
    "backlit|a window or bright lamp behind you, in view|600:4 300:0"
    "dim|room lights low or off (a screen glow is fine)|2000:8 2000:4"
    "texture|a finely patterned grey/white fabric or small print ~30 cm from the camera|600:4"
    "flat|white paper ~3 cm in front of the lens, room lights on|600:4 450:4"
    "dark|a finger over the lens|600:4 2000:16"
)

frames=5
dry_run=0
mode=capture
while [ $# -gt 0 ]; do
    case "$1" in
        --frames) frames="${2:-}"; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        --latency) mode=latency; shift ;;
        --session) mode=session; shift ;;
        --fps) mode=fps; shift ;;
        *) break ;;
    esac
done

die() { echo "[raw-capture] ERROR: $*" >&2; exit 1; }
log() { echo "[raw-capture] $*"; }
as_owner() { runuser -u "$OWNER" -- "$@"; }

check_setting() {
    [[ "$1" =~ ^([0-9]{1,4}):([0-9]{1,2})(:([0-9]{1,4}))?$ ]] || die "bad setting '$1' (want EXP:GAIN[:VBLANK])"
    [ "${BASH_REMATCH[2]}" -le 16 ] || die "gain index must be 0..16 in '$1'"
}

[ "$(id -u)" -eq 0 ] || die "run with sudo (it stops and starts $SERVICE)"
[[ "$frames" =~ ^[0-9]+$ ]] && [ "$frames" -ge 1 ] && [ "$frames" -le 60 ] || die "--frames must be 1..60"
case "$mode" in
    capture)
        [ $# -ge 2 ] || die "usage: $0 [--frames N] [--dry-run] SCENE EXP:GAIN[:VBLANK] ..."
        [[ "$1" =~ ^[a-z0-9_-]{1,32}$ ]] || die "SCENE must match [a-z0-9_-]{1,32}"
        for s in "${@:2}"; do check_setting "$s"; done ;;
    fps)
        [ $# -ge 1 ] || die "usage: $0 --fps VBLANK [VBLANK ...]"
        for v in "$@"; do [[ "$v" =~ ^[0-9]{1,4}$ ]] || die "bad VBLANK '$v'"; done ;;
    latency|session)
        [ -x "$REPO/build/ae_latency" ] || die "build it first: make build/ae_latency" ;;
esac

# Refuse while an app is streaming: the ISP's last word about consumers must not be "starting stream".
last=$(journalctl -u "$SERVICE" -b -o cat --no-pager 2>/dev/null \
    | grep -E 'starting stream|stopping stream|Idle, waiting for consumers|Starting with lazy' | tail -1 || true)
case "$last" in *"starting stream"*) die "an app is using the camera; close it first" ;; esac

# Media device and capture node: the same discovery as gc2607-service.sh.
MEDIA_DEV=""
for dev in /dev/media*; do
    if media-ctl -d "$dev" --print-topology 2>/dev/null | grep -qi "gc2607"; then MEDIA_DEV="$dev"; break; fi
done
[ -n "$MEDIA_DEV" ] || die "GC2607 not in the media topology"
CAPTURE_DEV=$(media-ctl -d "$MEDIA_DEV" --print-topology 2>/dev/null \
    | grep -A3 "Intel IPU6 ISYS Capture 0" | grep -o "/dev/video[0-9]*" | head -1) || true
[ -n "$CAPTURE_DEV" ] || die "capture node not found"
SUBDEV=""
for d in /dev/v4l-subdev*; do
    if v4l2-ctl -d "$d" --list-ctrls 2>/dev/null | grep -qw exposure; then SUBDEV="$d"; break; fi
done
[ -n "$SUBDEV" ] || die "sensor subdev (the one with an exposure control) not found"
log "media $MEDIA_DEV, capture $CAPTURE_DEV, sensor $SUBDEV"
if [ "$dry_run" -eq 1 ]; then
    log "dry run ($mode): would stop $SERVICE and stream the camera"
    v4l2-ctl -d "$SUBDEV" --list-ctrls | grep -E 'exposure|analogue_gain|vertical_blanking|pixel_rate'
    exit 0
fi

out_dir="$OUT_ROOT/$(date +%F)"

# capture SCENE SETTING...: stream each setting to <scene>_e<EXP>_g<GAIN>[_vb<VB>].raw plus a JSON sidecar.
capture() {
    local scene="$1" s exp gain vb name ctrls size readback
    shift
    as_owner mkdir -p "$out_dir"
    for s in "$@"; do
        IFS=: read -r exp gain vb <<< "$s"
        name="${scene}_e${exp}_g${gain}${vb:+_vb${vb}}"
        ctrls="exposure=${exp},analogue_gain=${gain}${vb:+,vertical_blanking=${vb}}"
        as_owner v4l2-ctl -d "$SUBDEV" --set-ctrl="$ctrls"
        as_owner v4l2-ctl -d "$CAPTURE_DEV" --set-fmt-video=width=1920,height=1080,pixelformat=BA10 \
            --stream-mmap=4 --stream-skip=10 --stream-count="$frames" --stream-to="$out_dir/$name.raw"
        size=$(stat -c %s "$out_dir/$name.raw")
        [ "$size" -eq $((frames * FRAME_BYTES)) ] || die "$name.raw is $size bytes, expected $((frames * FRAME_BYTES))"
        readback=$(as_owner v4l2-ctl -d "$SUBDEV" --get-ctrl=exposure,analogue_gain | tr '\n' ' ')
        as_owner tee "$out_dir/$name.json" > /dev/null <<EOF
{"scene": "$scene", "exposure": $exp, "gain_index": $gain, "vblank": ${vb:-null}, "frames": $frames,
 "width": 1920, "height": 1080, "format": "SGRBG10 in uint16 LE", "skipped": 10,
 "captured": "$(date -Is)", "readback": "$readback"}
EOF
        log "wrote $out_dir/$name.raw ($frames frames)"
    done
}

# fps VBLANK...: stream 300 frames at each vertical blanking without saving them; print the rate
# v4l2-ctl measured, the exposure maximum the driver now allows, and new CSI errors in the kernel log.
fps() {
    local vb before csi_errors='(csi|crc).*(err|fail)|(err|fail).*(csi|crc)'
    for vb in "$@"; do
        before=$(dmesg | grep -ciE "$csi_errors" || true)
        as_owner v4l2-ctl -d "$SUBDEV" --set-ctrl="vertical_blanking=$vb"
        log "vertical_blanking=$vb: $(as_owner v4l2-ctl -d "$SUBDEV" --list-ctrls | grep -E '^ *(exposure|vertical_blanking) ' | tr -s ' ' | tr '\n' ';')"
        as_owner v4l2-ctl -d "$CAPTURE_DEV" --set-fmt-video=width=1920,height=1080,pixelformat=BA10 \
            --stream-mmap=4 --stream-count=300 2>&1 | grep -oE '[0-9.]+ fps' | tail -1 | sed 's/^/[raw-capture] measured: /'
        log "new CSI error lines in the kernel log: $(( $(dmesg | grep -ciE "$csi_errors" || true) - before ))"
    done
}

latency() {
    local what
    for what in exposure gain; do as_owner "$REPO/build/ae_latency" "$CAPTURE_DEV" "$SUBDEV" "$what" || true; done
}

systemctl stop "$SERVICE"
trap 'systemctl start "$SERVICE" && log "$SERVICE started again"' EXIT
media-ctl -d "$MEDIA_DEV" -V '"Intel IPU6 CSI2 0":0 [fmt:SGRBG10_1X10/1920x1080]'
media-ctl -d "$MEDIA_DEV" -V '"Intel IPU6 CSI2 0":1 [fmt:SGRBG10_1X10/1920x1080]'
media-ctl -d "$MEDIA_DEV" -l '"Intel IPU6 CSI2 0":1 -> "Intel IPU6 ISYS Capture 0":0[1]' 2>/dev/null || true

case "$mode" in
    capture) capture "$@" ;;
    latency) latency ;;
    fps) fps "$@" ;;
    session)
        n=0
        for entry in "${SESSION[@]}"; do
            n=$((n + 1))
            IFS='|' read -r scene setup settings <<< "$entry"
            read -r -p "Scene $n/${#SESSION[@]} '$scene': $setup. Press Enter when ready (s = skip) " ans < /dev/tty
            [ "$ans" = "s" ] && { log "skipped $scene"; continue; }
            # shellcheck disable=SC2086  # settings is a space-separated list by design
            capture "$scene" $settings
        done
        read -r -p "Last: sit normally for the latency test (~5 s). Press Enter when ready " _ < /dev/tty
        latency ;;
esac
