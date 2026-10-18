# Media-graph discovery and pipeline setup for the GC2607, sourced by gc2607-service.sh and
# gc2607-raw-capture.sh (installed beside the service script in /opt/gc2607 by gc2607-setup-service.sh).
#
# The chain is found by following the graph's links from the sensor, not by fixed names:
# sensor "gc2607 <bus>-<addr>" pad 0 -> "Intel IPU6 CSI2 N" pad 0; CSI2 pad 1 -> "Intel IPU6 ISYS Capture M".
# Retried, because at boot the sensor joins the graph some time after the IPU6 modules load.

# media_links_from MEDIA_DEV ENTITY PAD: names of the entities that ENTITY's pad PAD links to, one per line.
media_links_from() {
    media-ctl -d "$1" -p 2>/dev/null | awk -v ent="$2" -v pad="pad$3:" '
        /^- entity [0-9]+: / {
            name = $0; sub(/^- entity [0-9]+: /, "", name); sub(/ \([0-9]+ pads?,.*$/, "", name)
            in_ent = (name == ent); in_pad = 0; next
        }
        in_ent && $1 ~ /^pad[0-9]+:$/ { in_pad = ($1 == pad); next }
        in_ent && in_pad && $1 == "->" { t = $0; sub(/^[^"]*"/, "", t); sub(/".*$/, "", t); print t }'
}

# media_discover_once: set MEDIA_DEV, SENSOR, CSI, CAPTURE (entity names) and CAPTURE_DEV, SENSOR_SUBDEV
# (device nodes); return 1 if any is missing.
media_discover_once() {
    local dev
    MEDIA_DEV="" SENSOR="" CSI="" CAPTURE="" CAPTURE_DEV="" SENSOR_SUBDEV=""
    for dev in /dev/media*; do
        [ -e "$dev" ] || continue
        SENSOR=$(media-ctl -d "$dev" -p 2>/dev/null | sed -n 's/^- entity [0-9]*: \(gc2607 [^ ]*\) (.*/\1/p' | head -1)
        if [ -n "$SENSOR" ]; then MEDIA_DEV="$dev"; break; fi
    done
    [ -n "$MEDIA_DEV" ] || return 1
    CSI=$(media_links_from "$MEDIA_DEV" "$SENSOR" 0 | head -1)
    [ -n "$CSI" ] || return 1
    CAPTURE=$(media_links_from "$MEDIA_DEV" "$CSI" 1 | head -1)
    [ -n "$CAPTURE" ] || return 1
    CAPTURE_DEV=$(media-ctl -d "$MEDIA_DEV" -e "$CAPTURE" 2>/dev/null)
    SENSOR_SUBDEV=$(media-ctl -d "$MEDIA_DEV" -e "$SENSOR" 2>/dev/null)
    [ -c "$CAPTURE_DEV" ] && [ -c "$SENSOR_SUBDEV" ]
}

# media_discover [TIMEOUT_SECONDS=20]: media_discover_once, retried every 0.5 s.
media_discover() {
    local deadline=$((SECONDS + ${1:-20}))
    until media_discover_once; do
        [ "$SECONDS" -lt "$deadline" ] || return 1
        sleep 0.5
    done
}

# media_configure: 1920x1080 SGRBG10 through CSI2 into the capture node, with the CSI2 -> capture link on.
media_configure() {
    media-ctl -d "$MEDIA_DEV" -V "\"$CSI\":0 [fmt:SGRBG10_1X10/1920x1080]" &&
        media-ctl -d "$MEDIA_DEV" -V "\"$CSI\":1 [fmt:SGRBG10_1X10/1920x1080]" &&
        media-ctl -d "$MEDIA_DEV" -l "\"$CSI\":1 -> \"$CAPTURE\":0[1]" &&
        v4l2-ctl -d "$CAPTURE_DEV" --set-fmt-video=width=1920,height=1080,pixelformat=BA10
}
