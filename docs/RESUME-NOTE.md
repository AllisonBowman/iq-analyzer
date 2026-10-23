# Note for the session writing Allison's resume: citing iq-analyzer

Paste this whole file into that chat. It is written by the Claude Code session that built the
repository, on 2026-10-13 (counts and dates updated 2026-10-23), and every claim below is checkable in
the repo.

## The link

https://github.com/AllisonBowman/iq-analyzer (public, MIT licence)

Put it as a plain URL in the Projects section and in the LinkedIn Featured section. On the resume
use the short form `github.com/AllisonBowman/iq-analyzer`. The README's first screen is the
pitch; the commit history shows the core work was done over three days (Oct 13-15, 2026) with test-first
discipline.

## One-line description (pick one)

- Built an ISO 12233 image-quality analyzer in Python with Claude Code: slanted-edge MTF, noise/SNR,
  dynamic range, ColorChecker ΔE2000 and e-SFR field maps, validated against synthetic ground truth
  (116 tests) and run on 389 of my own captures from 19 cameras.
- Open-source camera image-quality tool (ISO 12233 e-SFR, noise, colour accuracy) with every metric
  pinned to a known-answer test; findings on 389 real photos documented with explicit caveats.

## Three bullets for a project entry (all true, all in the repo)

- Implemented the ISO 12233:2014 slanted-edge SFR method and validated it against analytic ground
  truth including the pixel aperture (MTF50 within 1.5 %); natural-edge detection with validity gates
  on clipping, SNR, shading, straightness and step shape.
- Found and fixed a measurement failure on real data: photographs of screens read as noise; built a
  spectral periodic-texture detector whose threshold comes from measured distributions (no false
  positives on the 389-image library), with the method story documented end to end.
- Added chart mode (OpenCV ColorChecker detection with a homography refit; CIEDE2000 matching all 34
  published test pairs; e-SFR field maps with radial/tangential split) and bootstrap uncertainty on
  every per-image sharpness figure.

## Facts that are safe to state, and ones that are not

Safe: 389 captures, 19 devices, 116 tests, core work over three days (Oct 13-15, 2026), Python 3.12,
OpenCV, numpy/scipy, built with Claude Code including an adversarial review loop whose 13 correctness
findings are each pinned by a test (it also listed 13 methodology caveats, which are documented).

Not yet safe: anything about chart mode on real charts (only validated on rendered charts); any
"X dB better than Y" camera claim (the noise figures compare pipelines, not sensors; see
results/FINDINGS.md section 1). Do not call the library data "benchmark" data; it is her own photos. Do not call the 389 "all" of
her camera captures: they are the ones whose originals were stored on the Mac on 2026-10-13; the
library keeps most of its roughly 54,000 camera captures in iCloud.

## Which role this targets

Apple, Camera & Photos Image Quality Engineer, req 200686669. The posting's named qualifications
and how the repo answers each are in the repo's CLAUDE.md, first section.
