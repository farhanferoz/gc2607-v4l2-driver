# ISP Image Quality — What We Tried, What Worked, What Didn't

**Scope.** Software ISP (`gc2607_isp.c`) image-quality work, May 2026. The
hardware ISP path is closed (see `docs/native_hal_investigation.md`), so
all image-quality improvements happen in this binary. The driving
problem set across this session was: backlit scenes (face dim, wall
bright), chroma moiré on textured fabric (corduroy), and general
overexposure on white walls/ceilings.

The pre-session baseline was a dual-constraint AGC: a centre-weighted
mean target plus a green-channel highlight-percentile cap (commit
`0b450a7`). That clamped wall blowout in most scenes but still
mis-exposed backlit subjects when the face was outside the centre crop
or when the centre frame contained the bright background.

## Current shipped state (commit `0a6bdeb`)

| Component | Status | Notes |
|-----------|--------|-------|
| Multi-zone AE (16×16, shadow-priority on darkest 25%) | **Active** | Replaced centre-weighted target |
| Highlight percentile cap (98th pctile of G ≤ 240) | **Active** | Loosened from 220 when LTM was on; revisit |
| Chroma denoise (3×3 median on U/V) | **Active** | From prior work; replaced linear blur |
| Local tone mapping (LTM, bilateral-smoothed grid) | **Gated off** | Code present but call site disabled |
| Global tone curves (ACES Narkowicz, hyperbolic knee, smoothstep) | Abandoned | Made walls too bright in tests |
| Bayer demosaic — current 2×2 binning | **Active** | Fundamental aliasing source for fabric moiré |
| Bayer demosaic — Malvar-He-Cutler 5×5 | **Deferred** | Real fix for corduroy moiré (~150 LoC, +2-3% CPU) |

## What worked

### Multi-zone shadow-priority AE
- **Mechanism.** 16×16 zone grid over the output frame. Per-frame, take
  the mean green of the darkest `AE_DARK_FRACTION = 0.25` of zones, and
  use that as the target for `AE_TARGET = 100`. Skips empty zones (sparse
  WB sampling can leave some unfilled).
- **Why it works.** Backlit faces always land in the dark fraction
  regardless of where the subject is in the frame. The bright wall/window
  zones are excluded from the target calculation entirely, so they can't
  drag exposure down. This is the same pattern used by libcamera
  (`AgcMeanLuminance` with weighted zones) and RPi IPA.
- **Evidence.** Telemetry shows `AE: mean=>4.16 cap=>1.00` on a backlit
  scene — the shadow target asked for 4.16× more exposure, the highlight
  cap clamped it at 1.00×. AGC settles within a couple of seconds, no
  oscillation. Implementation: `compute_ae_zone_target()` at
  `gc2607_isp.c:484`.
- **Cost.** Partial selection sort O(m·n) with n=256, m=64 ≈ 16k
  compares/frame. Negligible.

### Highlight percentile cap
- **Mechanism.** 64-bin green histogram → invert to find the 98th
  percentile green value → bound it to `AE_HIGHLIGHT_CAP = 240`. The
  smaller of (mean-target ratio, highlight-cap ratio) wins.
- **Why it works.** A plain mean target can't distinguish "a few clipped
  pixels" from "lots of clipped pixels", which is the whole reason
  bright-wall scenes blow out at the mean target. The percentile cap
  hard-bounds the bright tail. This is the libcamera/IPU3-IPA
  dual-constraint pattern; it predates this session and is preserved as
  the second leg of the AGC.
- **Note.** Cap was tightened to 220 in pre-session baseline (commit
  `0b450a7`), then loosened to 240 when LTM was added to do final
  highlight compression in display space. With LTM now gated off, the
  240 value is arguably too loose. Tightening back to 220 is a
  one-line tuning change — try if walls clip in real use.

### Chroma denoise via 3×3 median (pre-session)
- **Mechanism.** Per-pixel 3×3 median on U and V (luma untouched).
- **Why it works.** False colour from demosaic ringing and per-pixel
  noise is high-frequency in chroma; median preserves edges where a
  linear blur smears them.
- **Limit.** Does *not* fix corduroy moiré — that artefact is
  low-frequency chroma aliasing baked into the 2×2 binning before any
  chroma processing sees it. The median can't unscramble pre-aliased UV.

## What didn't work

### Global tone curves
Four shapes tried in sequence, all abandoned:
- **ACES Narkowicz** — standard film-style S-curve `(x(ax+b))/(x(cx+d)+e)`.
  Result: walls visibly too bright per user inspection.
- **Asymmetric hyperbolic knee** — identity below 0.5, hyperbolic
  compression above. Result: same — knee crossing happens at face skin Y,
  not just at highlights.
- **Half-strength smoothstep** — gentler version of the above. Result:
  same complaint, just weaker.
- **Common failure mode.** Any global curve that compresses bright Y must
  also touch the face's bright spots (forehead, cheekbones) because those
  Y values overlap with wall Y values in a backlit scene. There is no
  global luma threshold that separates "skin highlight" from
  "wall highlight" in a single shot — they have similar Y, and global
  curves operate on Y alone.
- **Conclusion.** Tone mapping for backlit scenes is **inherently
  spatial**, not global. This motivated the LTM attempt.

### Local tone mapping (LTM) — both variants
The LTM implementation is in `apply_ltm()` at `gc2607_isp.c:531`. It builds a
60×34 (`~16×16 cells`) downsampled Y-mean grid, derives a per-cell
compression factor (identity below `LTM_KNEE = 120`, hyperbolic above),
smooths the grid, and bilinearly upsamples the factor for per-pixel
Y scaling. Two grid-smoothing strategies were tried; both shipped briefly
in active state, both subsequently disabled.

**Variant A — 3×3 box blur on the grid.**
- Symptom: visible halo at the head/wall silhouette. The box blur
  averages a bright-wall cell with a shadowed-face cell across the
  silhouette boundary, producing a "mixed" factor on the boundary cells.
  Bilinear upsample then renders that as a glow ring around the head.
- Why: averaging across a sharp luma edge violates the local-luminance
  assumption (cells inside a region should share a factor, cells across
  a boundary shouldn't).

**Variant B — 5×5 joint bilateral filter on the grid.**
- Constants: `LTM_BF_RADIUS = 2`, `LTM_BF_SIGMA_S = 1.5` (cells),
  `LTM_BF_SIGMA_R = 30` (Y units). Spatial weights precomputed once;
  range weights computed per cell from `expf(-diff²/2σ_r²)`.
- The bilateral *did* solve the halo: at the face/wall boundary, the
  centre-vs-neighbour luma diff is ≈80-120 Y, far beyond σ_r=30, so the
  range weight collapses to ~0 and the filter refuses to average across
  the silhouette. Verified by inspection — no halo around the head.
- **New artefact: face-internal patch.** A new symptom appeared on the
  forehead: a flat, brighter patch with a sharp boundary roughly at the
  hairline / above the eyebrows. Mechanism:
  - Well-lit forehead cells: mean Y ≈ 170 → factor = 128 / (128 + 50·0.7)
    = 0.79 (heavy compression).
  - Cheek/jaw cells: mean Y ≈ 110 → factor = 1.0 (below knee, no
    compression).
  - Luma diff between these is ≈ 60 Y, again >> σ_r=30, so the
    bilateral correctly *preserves* the boundary instead of averaging.
  - The bilinear upsample of factors 0.79 vs 1.0 renders that
    preserved boundary as a sharp tonal step inside skin.
- **Root cause.** A fixed knee at `LTM_KNEE = 120` segments well-lit skin
  itself into compressed/uncompressed regions. The bilateral correctly
  refuses to smooth that segmentation away (it's a true luma boundary, by
  σ_r), so the cell-grid step becomes visible inside the face. This is
  not fixable by tweaking the bilateral; it's a knee placement problem.
- Status: call site gated off via `(void)apply_ltm;` in the main loop.
  Code preserved for future revisit.

### Telegram /dev/video0 contention (one-off, documented for future)
Earlier in the session, the Telegram desktop client held `/dev/video0`
open in the background and blocked the ISP from acquiring it on restart
(`VIDIOC_REQBUFS: Device or resource busy`). `fuser /dev/video0`
identified the holder; killing the Telegram process freed the device.
Not an ISP bug, but worth knowing for future debugging.

## Options to pick up later

Listed in order of likely effort-to-payoff.

### A. Tighten highlight cap back to 220
- One-line change: `AE_HIGHLIGHT_CAP = 220.0f` in `gc2607_isp.c`. Restores
  the pre-session highlight protection level. Try first if walls clip in
  real use now that LTM isn't there to compress them in display space.

### B. ~~Raise `LTM_KNEE` to ≥ 200 and re-enable~~ — TESTED, FAILED
- Theory was: face skin (even well-lit forehead) tops out around Y=180;
  setting `LTM_KNEE = 200` means face cells never trigger compression,
  so no face-internal patch should be possible.
- Reality: tested at `LTM_KNEE = 200`. Forehead patches **still appear
  when the user moves**, because well-lit skin transients (cheekbones,
  forehead highlights, motion-induced exposure shifts) cross Y=200
  intermittently. Each frame the patch boundary lands on a different
  set of cells and renders as a flickering compressed region.
- Lesson: the artefact isn't about *where* the knee is — it's that any
  knee on a 60×34 grid against a textured signal will produce visible
  cell-boundary jumps whenever the threshold crossing isn't aligned
  with a natural luma edge. Cell-grid LTM with a hard knee is
  fundamentally incompatible with face skin in this pipeline.

### C. Highlight-only LTM (threshold gate)
- Modify the per-cell factor function: factor = 1.0 unless mean Y >
  `LTM_HIGHLIGHT_THRESHOLD` (say 220), then apply compression. Hard gate,
  no soft knee.
- Skin is guaranteed untouched. Walls/sky get pulled down. The boundary
  between gated and ungated cells is still bridged by the bilateral, so
  no patch on partially-bright cells.
- More invasive than (B) but the most robust against face-luma drift.

### D. Malvar-He-Cutler demosaic (corduroy moiré)
- Current pipeline uses 2×2 binning for demosaic, which aliases
  high-frequency fabric textures (corduroy especially) into low-frequency
  false-colour bands. The chroma median can't fix this — the aliasing is
  already in the binned luma.
- MHC 5×5 gradient-corrected demosaic + 2×2 downsample replaces the
  inner `process_frame` loop. ~150-200 LoC, +2-3% CPU expected.
- Open the day someone shoots fine-pinstripe / corduroy / sharp screens
  and wants those textures clean. Not load-bearing for general use.

### E. Temporal smoothing of LTM grid
- Currently `LTM_TEMPORAL_BLEND = 1.0` (no EMA — fresh grid every frame).
  The lower-blend versions were rejected because they ghost during
  motion (old face-shaped factor patch lingers as the face moves). Only
  revisit *if* future LTM-on work shows per-frame flicker on static
  scenes — otherwise leave at 1.0.

## Pointers

- ISP source: `gc2607_isp.c` (build with `make isp` → `/opt/gc2607/gc2607_isp`).
- Multi-zone AE: `compute_ae_zone_target()` ~line 484.
- LTM (gated off): `apply_ltm()` ~line 565; gating at `~line 1069`.
- Install + restart: `sudo /home/ff235/dev/gc2607-v4l2-driver/gc2607-install-isp.sh`
  (idempotent, with auto-rollback; sudoers entry preserves passwordless).
- Snapshot for QA: `bash /home/ff235/dev/gc2607-v4l2-driver/gc2607-snap.sh
  /tmp/foo.png` (captures one frame + adjacent telemetry).
- Telemetry format in `journalctl -u gc2607-camera.service`:
  `bright=X.XX | exp=N gain=N | means: R=… G=… Gdark=… B=… | AE:
  mean=>X.XX cap=>X.XX`. `Gdark` is the dark-zones AE target output.
- Pre-session related commits: `0b450a7` (dual-constraint AGC),
  `cb8ffae` (recovery script).
- This session: `0a6bdeb` (multi-zone AE + gated-off LTM).
