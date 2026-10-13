"""Real-data figures for the explainer video (media/make_explainer.py). Reads the Photos library read-only."""
import os, sys, glob
import numpy as np, cv2
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from iqa.imageio import load_image
from iqa.noise import (_annular_baseline, _local_baseline, _local_stats, periodic_texture,
                       PERIODIC_PEAK_THRESHOLD, PERIODIC_MIN_RADIUS)

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "build", "assets")
LIB = os.path.expanduser("~/Pictures/Photos Library.photoslibrary/originals")
SCREEN = f"{LIB}/6/6721B8DA-E5D3-4B54-B807-8DB95C9B4FCE.jpeg"
D850 = f"{LIB}/0/014D71F2-10CD-43AD-AF2F-AC5430B122AF.jpeg"
N = 32
plt.rcParams.update({"font.size": 13, "figure.dpi": 110})

def candidates(rgb8, max_side=4000):
    img = rgb8; h, w = img.shape[:2]
    if max(h, w) > max_side:
        y0, x0 = (h - min(h, max_side)) // 2, (w - min(w, max_side)) // 2
        img = img[y0:y0 + min(h, max_side), x0:x0 + min(w, max_side)]; h, w = img.shape[:2]
    f = img.astype(np.float32); Y = 0.2126 * f[..., 0] + 0.7152 * f[..., 1] + 0.0722 * f[..., 2]
    resid = Y - cv2.GaussianBlur(Y, (0, 0), 8.0)
    _, stdR = _local_stats(resid, N)
    g8 = np.clip(Y, 0, 255).astype(np.uint8)
    ed = cv2.blur((cv2.Canny(cv2.GaussianBlur(g8, (3, 3), 0), 60, 160) > 0).astype(np.float32), (N, N))
    chi = cv2.blur((f.max(axis=2) >= 252).astype(np.float32), (N, N)); clo = cv2.blur((f.min(axis=2) <= 3).astype(np.float32), (N, N))
    half = N // 2; ys = np.arange(half, h - half, 16); xs = np.arange(half, w - half, 16)
    Yg, Xg = np.meshgrid(ys, xs, indexing="ij")
    cand = (ed[Yg, Xg] == 0) & (chi[Yg, Xg] == 0) & (clo[Yg, Xg] == 0) & (stdR[Yg, Xg] > 0.05)
    return img, resid, Yg[cand], Xg[cand]

def mean_spectrum(resid, cy, cx):
    acc = np.zeros((N, N)); half = N // 2; ar = np.arange(N)
    for i in range(0, cy.size, 2048):
        yy, xx = cy[i:i + 2048], cx[i:i + 2048]
        iy = (yy[:, None] - half) + ar[None, :]; ix = (xx[:, None] - half) + ar[None, :]
        P = resid[iy[:, :, None], ix[:, None, :]]; P = P - P.mean(axis=(1, 2), keepdims=True)
        S = np.abs(np.fft.fft2(P)) ** 2; S = S / (S.sum(axis=(1, 2), keepdims=True) / (N * N))
        acc += S.sum(axis=0)
    return acc / cy.size

def normalise(Sbar):
    k = np.fft.fftfreq(N) * N; KY, KX = np.meshgrid(k, k, indexing="ij"); rad = np.sqrt(KY ** 2 + KX ** 2)
    rbin = np.rint(rad).astype(int)
    nyq = ((np.abs(KY) == N // 2) & (KX == 0)) | ((np.abs(KX) == N // 2) & (KY == 0))
    valid = (rad >= PERIODIC_MIN_RADIUS) & ~nyq
    R = Sbar / _annular_baseline(Sbar, rbin); R = R / _local_baseline(R, valid)
    return np.where(valid, R, np.nan), valid

def fig_crops_and_spectra():
    panels = []
    for name, path in (("Screen photo (iPhone 17 Pro Max, ISO 125)", SCREEN), ("Nikon D850 JPEG, ISO 100", D850)):
        li = load_image(path); img, resid, cy, cx = candidates(li.rgb8)
        peak, freq, excl = periodic_texture(resid, cy, cx, N)
        if excl.any():
            j = int(np.flatnonzero(excl)[len(np.flatnonzero(excl)) // 2])
        else:
            j = int(len(cy) // 2)
        y, x = int(cy[j]), int(cx[j]); s = 96
        crop = img[y - s:y + s, x - s:x + s]; rcrop = resid[y - s:y + s, x - s:x + s]
        Sbar = mean_spectrum(resid, cy, cx); R, valid = normalise(Sbar)
        panels.append((name, crop, rcrop, Sbar, R, peak, freq, len(cy)))
        np.save(os.path.join(OUT, f"Sbar_{'screen' if 'Screen' in name else 'd850'}.npy"), Sbar)
    fig, ax = plt.subplots(2, 4, figsize=(19, 9))
    for r, (name, crop, rcrop, Sbar, R, peak, freq, M) in enumerate(panels):
        ax[r, 0].imshow(crop); ax[r, 0].set_title(f"{name}\n192 px crop of a flat patch region", fontsize=12)
        v = np.percentile(np.abs(rcrop), 99)
        ax[r, 1].imshow(rcrop, cmap="gray", vmin=-v, vmax=v); ax[r, 1].set_title("Residual after sigma-8 high-pass\n(what the noise estimator sees)", fontsize=12)
        im = ax[r, 2].imshow(np.log10(np.fft.fftshift(Sbar) + 1e-6), cmap="magma", extent=[-0.5, 0.5, 0.5, -0.5])
        ax[r, 2].set_title(f"Mean normalised power spectrum\nlog10, averaged over {M:,} patches", fontsize=12); ax[r, 2].set_xlabel("cycles / px"); 
        Rs = np.fft.fftshift(R)
        im2 = ax[r, 3].imshow(Rs, cmap="viridis", vmin=0, vmax=max(10, np.nanmax(Rs)), extent=[-0.5, 0.5, 0.5, -0.5])
        ax[r, 3].set_title(f"Peak over annular + local baseline\nmax = {peak:.1f}  (threshold {PERIODIC_PEAK_THRESHOLD:.0f})" + (f"   f = {freq:.3f} c/px" if np.isfinite(freq) else ""), fontsize=12)
        ax[r, 3].set_xlabel("cycles / px"); plt.colorbar(im2, ax=ax[r, 3], fraction=0.046)
        for a in ax[r, :2]: a.set_xticks([]); a.set_yticks([])
    plt.tight_layout(); fig.savefig(os.path.join(OUT, "fig_crops_spectra.png")); plt.close(fig)

def fig_peak_distribution():
    rows = []
    for f in sorted(glob.glob(os.path.join(OUT, "*.npy"))):
        base = os.path.basename(f)[:-4]
        if base.startswith("Sbar_"): continue
        Sbar = np.load(f); R, _ = normalise(Sbar); pk = float(np.nanmax(R))
        if base.startswith("SYN_"):
            cat = "synthetic negative" if any(base.startswith("SYN_" + k) for k in ("white", "pink", "smooth", "aniso", "jpeg")) else "synthetic positive"
        else:
            cat = "screen photo" if base.startswith("6721B8DA") else "ordinary library file"
        rows.append((cat, base.replace("SYN_", ""), pk))
    cats = ["synthetic negative", "ordinary library file", "synthetic positive", "screen photo"]
    colors = {"synthetic negative": "#4C78A8", "ordinary library file": "#72B7B2", "synthetic positive": "#F58518", "screen photo": "#E45756"}
    fig, ax = plt.subplots(figsize=(14, 6.5))
    rng = np.random.default_rng(0)
    for i, c in enumerate(cats):
        vals = [pk for cat, _, pk in rows if cat == c]
        ax.scatter(i + rng.uniform(-0.18, 0.18, len(vals)), vals, s=70, color=colors[c], edgecolor="k", linewidth=0.5, zorder=3, label=f"{c} (n={len(vals)})")
    ax.axhline(PERIODIC_PEAK_THRESHOLD, color="k", ls="--", lw=1.5); ax.text(3.45, PERIODIC_PEAK_THRESHOLD * 1.08, f"threshold = {PERIODIC_PEAK_THRESHOLD:.0f}", ha="right")
    ax.set_yscale("log"); ax.set_xticks(range(len(cats))); ax.set_xticklabels(cats); ax.set_ylabel("spectral peak (1 = noise)")
    ax.set_title("Where the spectral peak lands: negatives below 8, positives above, with a factor of two each side")
    ax.grid(axis="y", alpha=0.3, which="both"); ax.legend(loc="upper left")
    plt.tight_layout(); fig.savefig(os.path.join(OUT, "fig_peaks.png")); plt.close(fig)
    for c in cats:
        vals = sorted(pk for cat, _, pk in rows if cat == c)
        print(c, [round(v, 1) for v in vals])

if __name__ == "__main__":
    fig_crops_and_spectra(); fig_peak_distribution(); print("ok")
