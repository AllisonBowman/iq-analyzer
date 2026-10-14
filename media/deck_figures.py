"""Figures for the step-by-step slide show: one real photo walked through every stage."""
import os, sys, json
import numpy as np, cv2
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from iqa.imageio import load_image, srgb_decode
from iqa.edges import measure_natural_edges, lw_per_ph
from iqa.noise import analyze_noise, _local_stats, periodic_texture
from iqa.exposure import analyze_exposure
from iqa.uncertainty import bootstrap_ci
from iqa.sfr import gaussian_mtf50
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "build", "deck")
plt.rcParams.update({"font.size": 15, "axes.titlesize": 17, "figure.dpi": 100, "axes.spines.top": False, "axes.spines.right": False})
BG = "#fbfaf6"; INK = "#1f2a33"; ACC = "#d9742b"; BLUE = "#2b6cb0"

prefix = sys.argv[1] if len(sys.argv) > 1 else "C6220E43"
rs = json.load(open("results/results.json"))
rec = [r for r in rs if r["file"].startswith(prefix)][0]
li = load_image(rec["path"])
rgb = li.rgb8; lum = li.lin_luma
H, W = rgb.shape[:2]
print("photo", rec["file"], W, H, rec["camera_model"], "ISO", rec["iso"], "profile", rec.get("color_profile"))

# 1. the photo as loaded + EXIF
s = 1600 / max(H, W)
small = cv2.resize(rgb, (int(W * s), int(H * s)), interpolation=cv2.INTER_AREA)
cv2.imwrite(f"{OUT}/01_photo.jpg", small[..., ::-1], [cv2.IMWRITE_JPEG_QUALITY, 88])
json.dump({k: rec.get(k) for k in ("camera_make", "camera_model", "lens", "iso", "exposure_s", "f_number", "focal_mm", "width", "height", "format", "color_profile")}, open(f"{OUT}/exif.json", "w"), indent=1)

# 2. linear vs display-referred: the two working images
fig, ax = plt.subplots(1, 2, figsize=(14, 5.2), facecolor=BG)
Y8 = (0.2126 * rgb[..., 0] + 0.7152 * rgb[..., 1] + 0.0722 * rgb[..., 2]).astype(np.float32)
ax[0].imshow(cv2.resize(Y8, (small.shape[1], small.shape[0])), cmap="gray", vmin=0, vmax=255); ax[0].set_title("display-referred luminance (sRGB 0-255): noise, clipping"); ax[0].axis("off")
ax[1].imshow(cv2.resize(lum.astype(np.float32), (small.shape[1], small.shape[0])), cmap="gray", vmin=0, vmax=1); ax[1].set_title("scene-linear luminance (0-1): sharpness"); ax[1].axis("off")
fig.tight_layout(); fig.savefig(f"{OUT}/02_two_images.png", facecolor=BG); plt.close(fig)

# 3. edges found: ROIs on the photo
ed = measure_natural_edges(lum)
fig, ax = plt.subplots(figsize=(10, 10 * H / W), facecolor=BG)
ax.imshow(small); ax.axis("off")
for e in ed.edges:
    ax.add_patch(plt.Rectangle((e.x0 * s, e.y0 * s), e.w * s, e.h * s, fill=False, ec="#00e5ff", lw=1.6))
ax.set_title(f"{ed.n_candidates} candidate edges, {ed.n_measured} kept as valid steps (cyan boxes)")
fig.tight_layout(); fig.savefig(f"{OUT}/03_edges.png", facecolor=BG); plt.close(fig)
print("edges", ed.n_candidates, ed.n_measured, ed.reject_reasons, "median", round(ed.mtf50_median, 4), "p80", round(ed.mtf50_p80, 4), "ci", ed.mtf50_median_ci)

# 4. one edge: ROI, ESF, LSF, MTF
best = max(ed.edges, key=lambda e: e.sfr.contrast)
e = best; r = e.sfr
roi = rgb[e.y0:e.y0 + e.h, e.x0:e.x0 + e.w]
fig, ax = plt.subplots(1, 4, figsize=(20, 5), facecolor=BG)
ax[0].imshow(roi if e.orientation == "v" else np.transpose(roi, (1, 0, 2))); ax[0].set_title(f"one ROI, {e.w}x{e.h} px\nedge tilted {abs(r.slope_deg):.1f} deg from vertical"); ax[0].set_xticks([]); ax[0].set_yticks([])
x = np.arange(r.esf.size) / r.oversample
ax[1].plot(x, r.esf, color=INK); ax[1].set_title("ESF: edge spread function\n(brightness across the edge, 4 samples per pixel)"); ax[1].set_xlabel("pixels across the edge")
ax[2].plot(np.arange(r.lsf.size) / r.oversample, r.lsf, color=INK); ax[2].set_title("LSF: line spread function\n(the derivative of the ESF)"); ax[2].set_xlabel("pixels")
sel = r.freq <= 0.5
ax[3].plot(r.freq[sel], r.mtf[sel], color=BLUE, lw=2.5); ax[3].axhline(0.5, ls="--", color="#888"); ax[3].axvline(r.mtf50, color=ACC, lw=2)
ax[3].text(r.mtf50 + 0.01, 0.92, f"MTF50 = {r.mtf50:.3f} c/px", color=ACC, fontsize=14)
ax[3].set_ylim(0, 1.1); ax[3].set_xlim(0, 0.5); ax[3].set_title("MTF: modulation transfer function\n(the Fourier transform of the LSF)"); ax[3].set_xlabel("cycles per pixel (0.5 = Nyquist)"); ax[3].set_ylabel("contrast kept")
fig.tight_layout(); fig.savefig(f"{OUT}/04_one_edge.png", facecolor=BG); plt.close(fig)

# 5. spread of edges + bootstrap
m50 = np.array([x.sfr.mtf50 for x in ed.edges])
rng = np.random.default_rng(0); boots = np.median(m50[rng.integers(0, m50.size, (2000, m50.size))], axis=1)
fig, ax = plt.subplots(1, 2, figsize=(14, 5), facecolor=BG)
ax[0].bar(np.arange(m50.size), np.sort(m50), color=BLUE); ax[0].axhline(ed.mtf50_median, color=ACC, lw=2, label=f"median {ed.mtf50_median:.3f}"); ax[0].axhline(ed.mtf50_p80, color="#2f855a", lw=2, ls="--", label=f"p80 (in-focus) {ed.mtf50_p80:.3f}")
ax[0].set_title(f"MTF50 of all {m50.size} valid edges, sorted"); ax[0].set_ylabel("cycles / pixel"); ax[0].set_xlabel("edge"); ax[0].legend()
ax[1].hist(boots, bins=40, color="#cbd5e0"); lo, hi = ed.mtf50_median_ci
ax[1].axvline(lo, color=ACC); ax[1].axvline(hi, color=ACC); ax[1].axvline(ed.mtf50_median, color=INK, lw=2)
ax[1].set_title(f"2,000 bootstrap resamples of the median\n95 % interval {lo:.3f} to {hi:.3f}"); ax[1].set_xlabel("median MTF50 (c/px)")
fig.tight_layout(); fig.savefig(f"{OUT}/05_spread_bootstrap.png", facecolor=BG); plt.close(fig)

# 6. noise: patches on the photo, residual, curve
nz = analyze_noise(rgb)
f = rgb.astype(np.float32); Y = 0.2126 * f[..., 0] + 0.7152 * f[..., 1] + 0.0722 * f[..., 2]
resid = Y - cv2.GaussianBlur(Y, (0, 0), 8.0)
# recompute the selected patch grid for drawing (same logic as analyze_noise, patch 32 stride 16)
patch, stride = 32, 16
resid_sm = cv2.GaussianBlur(resid, (0, 0), 2.0)
_, stdR = _local_stats(resid, patch); _, stdS = _local_stats(resid_sm, patch)
g8 = np.clip(Y, 0, 255).astype(np.uint8)
edges_m = cv2.Canny(cv2.GaussianBlur(g8, (3, 3), 0), 60, 160); ed_d = cv2.blur((edges_m > 0).astype(np.float32), (patch, patch))
chi = cv2.blur((f.max(axis=2) >= 252).astype(np.float32), (patch, patch)); clo = cv2.blur((f.min(axis=2) <= 3).astype(np.float32), (patch, patch))
half = patch // 2; ys = np.arange(half, H - half, stride); xs = np.arange(half, W - half, stride)
Yg, Xg = np.meshgrid(ys, xs, indexing="ij")
cand = (ed_d[Yg, Xg] == 0) & (chi[Yg, Xg] == 0) & (clo[Yg, Xg] == 0) & (stdR[Yg, Xg] > 0.05)
with np.errstate(all="ignore"): ratio = np.where(stdR[Yg, Xg] > 1e-6, stdS[Yg, Xg] / stdR[Yg, Xg], np.inf)
thr = max(0.30, 1.3 * nz.noise_whiteness); sel = cand & (ratio < thr)
fig, ax = plt.subplots(1, 3, figsize=(20, 6.2), facecolor=BG)
ax[0].imshow(small); ax[0].scatter(Xg[sel] * s, Yg[sel] * s, s=1.2, c="#00e5ff", alpha=0.6); ax[0].axis("off")
ax[0].set_title(f"{int(sel.sum()):,} flat patches kept of {int(cand.sum()):,} candidates (cyan)")
# a flat patch crop + residual
j = np.argmin(np.abs(Y[Yg[sel], Xg[sel]] - 118)); py, px = Yg[sel][j], Xg[sel][j]
crop = rgb[py - 48:py + 48, px - 48:px + 48]; rc = resid[py - 48:py + 48, px - 48:px + 48]
ax[1].imshow(np.hstack([crop, np.repeat(np.clip(128 + 6 * rc, 0, 255)[..., None], 3, axis=2).astype(np.uint8)]))
ax[1].set_title("a 96 px flat patch (left) and its residual x6 (right):\nwhat is left after the smooth gradient is removed = noise"); ax[1].set_xticks([]); ax[1].set_yticks([])
ax[2].plot(nz.bin_centers, nz.luma_noise, "o-", color=BLUE, label="luma noise (8-bit std)"); ax[2].plot(nz.bin_centers, nz.chroma_noise, "s--", color=ACC, label="chroma noise")
ax[2].axvline(118, color="#888", ls=":"); ax[2].text(120, max(nz.luma_noise) * 0.95, f"mid-grey 118:\nSNR {nz.snr_midgrey_db:.1f} dB", fontsize=13)
ax[2].set_xlabel("patch brightness (sRGB 0-255)"); ax[2].set_ylabel("noise std (8-bit levels)"); ax[2].set_title(f"noise floor per brightness bin (15th percentile)\nwhiteness {nz.noise_whiteness:.2f}"); ax[2].legend()
fig.tight_layout(); fig.savefig(f"{OUT}/06_noise.png", facecolor=BG); plt.close(fig)
print("noise", nz.n_patches, nz.candidate_patches, round(nz.snr_midgrey_db, 1), round(nz.noise_whiteness, 2), nz.dr_stops, nz.spectral_peak)

# 7. periodic detector on this photo (spectrum)
cy, cx = Yg[cand], Xg[cand]
from media.figures import mean_spectrum, normalise
Sbar = mean_spectrum(resid, cy, cx); R, _ = normalise(Sbar)
fig, ax = plt.subplots(1, 2, figsize=(12, 5.4), facecolor=BG)
im = ax[0].imshow(np.log10(np.fft.fftshift(Sbar) + 1e-6), cmap="magma", extent=[-0.5, 0.5, 0.5, -0.5]); ax[0].set_title(f"average power spectrum of {cy.size:,} patches (log)"); ax[0].set_xlabel("cycles / px")
im2 = ax[1].imshow(np.fft.fftshift(R), cmap="viridis", vmin=0, vmax=10, extent=[-0.5, 0.5, 0.5, -0.5]); ax[1].set_title(f"peak over baseline: max {np.nanmax(R):.1f} (threshold 6)\nno repeating pattern in this photo"); ax[1].set_xlabel("cycles / px"); plt.colorbar(im2, ax=ax[1], fraction=0.046)
fig.tight_layout(); fig.savefig(f"{OUT}/07_spectrum.png", facecolor=BG); plt.close(fig)

# 8. exposure: histogram, clipping, white balance
ex = analyze_exposure(rgb); d = ex.as_dict()
fig, ax = plt.subplots(1, 2, figsize=(14, 5), facecolor=BG)
for c, col in zip(range(3), ("#c0392b", "#27ae60", "#2980b9")):
    ax[0].hist(rgb[..., c].ravel()[::7], bins=64, range=(0, 255), histtype="step", color=col, lw=1.8, label="RGB"[c])
ax[0].set_yscale("log"); ax[0].set_title(f"histogram: {d['clip_high_pct']:.2f} % of pixels clipped high, {d['clip_low_pct']:.2f} % low"); ax[0].set_xlabel("sRGB level"); ax[0].legend()
ax[1].bar(["R / G", "B / G"], [d["wb_r_over_g_stops"], d["wb_b_over_g_stops"]], color=[ACC, BLUE]); ax[1].axhline(0, color=INK)
ax[1].set_title("gray-world white balance of the rendered scene (stops)\n(a sunset is intent, not error)"); ax[1].set_ylabel("stops from neutral")
fig.tight_layout(); fig.savefig(f"{OUT}/08_exposure.png", facecolor=BG); plt.close(fig)
print("exposure", {k: round(v, 3) for k, v in d.items() if isinstance(v, float)})

# 9. the row in the CSV
row = {k: rec.get(k) for k in ("file", "camera_model", "iso", "edges_measured", "mtf50_median_cpp", "mtf50_p80_cpp", "mtf50_p80_lwph", "snr_midgrey_db", "noise_whiteness", "noise_spectral_peak", "dr_snr4_stops", "clip_high_pct", "wb_r_over_g_stops")}
json.dump(row, open(f"{OUT}/row.json", "w"), indent=1)
print(json.dumps(row))
print("lwph", lw_per_ph(ed.mtf50_p80, H))
