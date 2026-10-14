# Handoff: shooting the real charts to validate chart mode

Written 2026-10-14 by the Claude Code session that built chart mode. Chart mode (`iqa chart`,
`iqa/color.py`, `iqa/chart_sfr.py`) has only ever seen charts it rendered itself. This document is
what a person needs to photograph real ones, run the tool, and judge the result. Everything the
tool expects is stated with the file that expects it.

## What to acquire

**A ColorChecker Classic** (24 patches, X-Rite / Calibrite). The "Classic Mini" or "Passport" versions
carry the same 24 patches and work. The reference values in `iqa/color.py` (`COLORCHECKER_LAB`) are
X-Rite's published L\*a\*b\* for charts made **before November 2014**; a newer chart differs by up to
about 2 dE00 on a few patches. If the chart is new, replace that table with the values printed on
its certificate or Calibrite's current published set before trusting absolute dE figures; the
white-balance error and the relative patch ranking are unaffected.

**An e-SFR target.** The ISO 12233:2014 chart is a commercial print (Imatest, Applied Image, DxO).
A home print works for validation if it is sharp, matte and flat: a 5 x 5 grid of dark squares on a
light field, each square rotated about 5 degrees, squares at least 80 px across in the photo
(`iqa/chart_sfr.py`, `find_slanted_squares(min_side_px=40)`; 80 px gives margin). Contrast should
be modest (the ISO recommends about 4:1, e.g. a 20 % grey on an 80 % field) so neither side clips.
The synthetic chart the tests use is `render_esfr_chart` in `iqa/synth.py`; printing it at A3 on
matte paper from `python -c "..."` is the quickest route (see "Printing a target" below).

## Shooting

Same rules for both charts:

- **Even light, no gloss.** Two lamps at 45 degrees or open shade. Check the chart for reflections
  in the viewfinder; matte paper, no glass.
- **Square to the camera.** The chart plane perpendicular to the lens axis. A small tilt is fine
  (the ColorChecker detector handles perspective; the e-SFR detector expects squares, so keep the
  tilt under about 10 degrees).
- **Base ISO, tripod, timer or remote.** ISO 100 or the camera's base; 2-second timer on a phone.
- **Fill the frame to a tenth or more** for the ColorChecker; fill most of the frame for the e-SFR
  chart so the squares cover the field (that is what the field map measures).
- **Focus on the chart**, then do not refocus between frames.
- **Shoot every format the camera offers**: HEIC and RAW (ProRAW on the iPhone), JPEG and NEF on the
  D850. Chart mode on the JPEG/HEIC measures the whole pipeline; on the RAW with a neutral decode it
  measures sensor plus optics. Both are interesting, and the pair is the "matched RAW/HEIC" item the
  findings have been asking for.
- **A bracket of three exposures** (0, -0.7, +0.7 EV) on the ColorChecker: the white patch must not
  clip (`sample_patches` reads the mean; a clipped white reads as a colour error).
- **For a lens map**: the e-SFR chart at each aperture the lens has (DSLR), and on the phone with
  each of the three lenses.

Keep the originals out of the Photos library's edited state: export "unmodified originals" or
AirDrop the files; the analyzer reads files, not the library.

## Running

```bash
source .venv/bin/activate
python -m iqa chart IMG_0001.heic --plot chart.png --json chart.json
```

The command finds both chart types in one image and prints what it found. `--cc-only` or
`--esfr-only` restricts it. The plot shows the detection on the photo and, for the ColorChecker,
measured-vs-reference swatches with dE00 per patch; for the e-SFR chart, the MTF50 map across the
field. Example of the output on a synthetic frame is in `media/build/assets/cc.png` and `esfr.png`
after running `media/figures.py`.

## What to expect, and what to do if it does not happen

**ColorChecker not found.** The detector is OpenCV's `mcc` module (`find_colorchecker`). It wants the
chart reasonably large and the patches clean. Try a tighter crop first (`iqa chart` on a cropped
export). If a well-lit, frame-filling chart is still not found, look at `det.process(bgr, 1)`: the
`1` is the number of charts; the chart type is set through `setColorChartType` (OpenCV 5 changed
this signature, which cost an hour on the synthetic run).

**Centres off the patches.** `_refine_centres` segments each patch around the detector's box and
refits a homography. The 50 % inner sample (`sample_patches(inner=0.5)`) tolerates a few pixels of
error. If the yellow dots on the plot sit on the gutters, the box orientation test
(`_orientation_ok`, which expects the neutral row to run white to black) may have chosen the wrong
rotation; check which patch is reported as "white".

**dE00 numbers.** A phone JPEG shot under daylight typically lands at a mean dE00 of 3 to 6 against the
reference, with neutrals near 1 to 2 and saturated patches (blue, orange, cyan) highest. Cyan is
outside the sRGB gamut and reads 2 to 4 even from a perfect rendering (`OUT_OF_SRGB_GAMUT`). A mean
above 8 means either the lighting was not neutral (check the white-balance error in stops: above
0.3 says the illuminant, not the camera) or the reference table does not match the chart.

**e-SFR squares not found.** `find_slanted_squares` thresholds with Otsu and keeps convex quads whose
sides agree within 15 % and whose rotation is 2 to 15 degrees. A chart shot with perspective
makes the far squares non-square; keep it flat. If the print's squares have soft or rounded corners,
`approxPolyDP` may give 5+ vertices: raise its epsilon (0.03 of the perimeter) a little. Glossy paper
produces highlights inside squares that break them into two contours.

**MTF50 values.** Expect 0.25 to 0.40 c/px on a phone's main camera at base ISO (sharpened), 0.20 to
0.30 on a DSLR JPEG, lower on a RAW decoded without sharpening. Compare with the natural-edge figures
in `results/results.csv` for the same camera: the chart should sit at or above the natural-edge p80,
never far below (if it does, the chart is out of focus or the print is soft).

**Radial vs tangential.** On a good lens the two medians agree within 10 % in the centre and diverge
toward the corners. A big gap everywhere means the chart was not square to the camera.

## Printing a target

```bash
python - <<'EOF'
import numpy as np, cv2
from iqa.synth import render_esfr_chart
from iqa.imageio import srgb_encode
lin, _ = render_esfr_chart(size=3508, cols=5, rows=5, angle_deg=5.0, sigma_px=0.3, low=0.2, high=0.8)
u8 = np.clip(srgb_encode(lin) * 255, 0, 255).astype(np.uint8)
cv2.imwrite("esfr_a3.png", u8)      # 3508 px = A3 at 300 dpi; print at 100 %, matte paper
EOF
```

Print at 100 % on matte paper, let it dry flat, tape it to a board. Photograph it so the squares
are 100 px or more across.

## Recording the result

Put the chart photos in a folder outside the repo (they carry no privacy concern, but the repo is
public and they are large). Add a section to `results/FINDINGS.md` with: the camera, format and
lighting; the mean/max dE00 and the WB error; the e-SFR centre/outer and radial/tangential medians;
one sentence on whether the detector needed any threshold changed, and which. If a threshold did
change, add a test that pins the new behaviour before committing, per `CLAUDE.md`.
