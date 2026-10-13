"""Failure modes a camera-team reviewer found on the first pass. Each test pins one.

Clipped plateaus, shading, sharpening halos, off-centre edges, correlated
(noise-reduced) noise, non-monotonic SNR curves, extrapolated mid-grey and the
pixel-aperture ground truth.
"""
import cv2
import numpy as np

from iqa.edges import measure_natural_edges
from iqa.imageio import lin_luma_from_rgb8, srgb_encode
from iqa.noise import analyze_noise
from iqa.sfr import compute_sfr, gaussian_mtf50, gaussian_pixel_mtf, gaussian_pixel_mtf50
from iqa.synth import slanted_edge, synthetic_scene


# ---------------------------------------------------------------- SFR validity

def test_pixel_aperture_ground_truth():
    """A real sensor integrates over its pixel: MTF = gaussian x sinc(f). The code recovers that, not just the Gaussian."""
    for sigma in (0.5, 0.7, 1.0, 1.5):
        r = compute_sfr(slanted_edge(h=120, w=80, angle_deg=5.0, sigma_px=sigma, pixel_aperture=True))
        expected = gaussian_pixel_mtf50(sigma)
        assert abs(r.mtf50 - expected) / expected < 0.015, (sigma, r.mtf50, expected)
        sel = (r.freq > 0.02) & (r.freq < 0.45)
        assert np.abs(r.mtf[sel] - gaussian_pixel_mtf(r.freq[sel], sigma)).max() < 0.02


def test_clipped_plateau_is_flagged_not_measured():
    """A blown highlight truncates the ESF and inflates MTF50 ~2x; clipped_frac must expose it."""
    clean = compute_sfr(slanted_edge(sigma_px=1.5, low=0.1, high=0.9))
    assert clean.clipped_frac == 0.0
    clipped = compute_sfr(np.clip(slanted_edge(sigma_px=1.5, low=0.1, high=2.0), 0, 1))
    assert clipped.clipped_frac > 0.2          # the whole bright plateau sits at 1.0
    assert clipped.mtf50 > clean.mtf50 * 1.3   # ... and the number IS wrong, which is why it must be rejected


def test_shading_is_removed():
    """A gradient across the ROI (sky, vignetting) biased MTF50 down 8-43 % before de-shading."""
    expected = gaussian_mtf50(1.0)
    for shading, tol in ((0.2, 0.03), (0.5, 0.05)):
        r = compute_sfr(slanted_edge(sigma_px=1.0, shading=shading, noise=0.003))
        assert abs(r.mtf50 - expected) / expected < tol, (shading, r.mtf50, expected)
        assert r.shading > 0.1 * shading           # ... and reported
    assert compute_sfr(slanted_edge(sigma_px=1.0)).shading < 0.02


def test_sharpening_halo_shows_in_overshoot_and_mtf50p():
    plain = compute_sfr(slanted_edge(sigma_px=1.0))
    sharp = compute_sfr(slanted_edge(sigma_px=1.0, sharpen=2.0))
    assert plain.overshoot_pct < 0.5
    assert sharp.overshoot_pct > 4.0
    assert sharp.mtf50p < sharp.mtf50          # MTF50P discounts the >1 peak
    assert abs(plain.mtf50p - plain.mtf50) < 1e-6


def test_off_centre_edge_and_slant_limits():
    expected = gaussian_mtf50(1.0)
    for off in (-12.0, 12.0):
        r = compute_sfr(slanted_edge(sigma_px=1.0, offset_px=off, noise=0.01))
        assert abs(r.mtf50 - expected) / expected < 0.04, (off, r.mtf50)
    for ang in (1.5, 14.0):
        r = compute_sfr(slanted_edge(h=120, w=90, sigma_px=1.0, angle_deg=ang, noise=0.005))
        assert abs(r.mtf50 - expected) / expected < 0.04, (ang, r.mtf50)
        assert abs(r.slope_deg - ang) < 0.3


def test_rise_width_is_unbiased_and_unquantised():
    for sigma in (0.5, 0.7, 1.0, 2.5):
        r = compute_sfr(slanted_edge(sigma_px=sigma))
        assert abs(r.rise_10_90_px - 2.563 * sigma) / (2.563 * sigma) < 0.08, (sigma, r.rise_10_90_px)
    flat = np.full((60, 40), 0.5) + np.random.default_rng(0).normal(0, 1e-3, (60, 40))
    try:
        r = compute_sfr(flat)
        assert not np.isfinite(r.rise_10_90_px) or r.step < 0.01
    except ValueError:
        pass                                        # no edge at all is an acceptable refusal too


def test_mtf50_only_below_nyquist_and_nyquist_floor():
    r = compute_sfr(slanted_edge(sigma_px=0.3, sharpen=3.0))    # absurdly sharp: no crossing below 0.5
    assert not np.isfinite(r.mtf50) or r.mtf50 <= 0.5
    soft = compute_sfr(slanted_edge(sigma_px=1.5))
    assert not np.isfinite(soft.mtf_nyquist)        # true value 2e-5 is below the leakage floor
    crisp = compute_sfr(slanted_edge(sigma_px=0.5))
    assert abs(crisp.mtf_nyquist - np.exp(-2 * np.pi ** 2 * 0.25 * 0.25)) < 0.02


# ---------------------------------------------------------- natural-edge gates

def _scene_with_blown_square(sigma_px=1.0):
    rgb = synthetic_scene(size=1400, sigma_px=sigma_px, noise_8bit=2.0)
    return rgb


def test_edge_finder_rejects_clipped_and_tiny_steps():
    lin = lin_luma_from_rgb8(_scene_with_blown_square())
    # Paint a blown-out slanted square whose edges would be the highest-contrast candidates.
    yy, xx = np.mgrid[0:lin.shape[0], 0:lin.shape[1]].astype(np.float64)
    th = np.radians(6.0)
    u = (xx - 700) * np.cos(th) + (yy - 1150) * np.sin(th)
    v = -(xx - 700) * np.sin(th) + (yy - 1150) * np.cos(th)
    lin[(np.abs(u) < 90) & (np.abs(v) < 90)] = 1.0
    summ = measure_natural_edges(lin)
    assert summ.reject_reasons.get("clipped", 0) >= 1
    assert all(e.sfr.clipped_frac <= 0.005 for e in summ.edges)
    assert all(e.sfr.step >= 0.04 for e in summ.edges)
    assert all(e.sfr.contrast <= 1.0 for e in summ.edges)


def test_rois_do_not_overlap():
    summ = measure_natural_edges(lin_luma_from_rgb8(synthetic_scene(sigma_px=1.0)))
    boxes = [(e.x0, e.y0, e.x0 + e.w, e.y0 + e.h) for e in summ.edges]
    for i, a in enumerate(boxes):
        for b in boxes[i + 1:]:
            ox = max(0, min(a[2], b[2]) - max(a[0], b[0]))
            oy = max(0, min(a[3], b[3]) - max(a[1], b[1]))
            assert ox * oy < 0.25 * (a[2] - a[0]) * (a[3] - a[1])


# ------------------------------------------------------------------ noise

def _gradient(sigma8, corr=0.0, size=900, seed=0, jpeg=None, lo=0.02, hi=0.92):
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float64)
    lin = lo + (hi - lo) * (xx / size) ** 2.2
    srgb = srgb_encode(np.repeat(lin[..., None], 3, axis=2)) * 255.0
    nz = rng.normal(0.0, sigma8, srgb.shape)
    if corr > 0:
        for ch in range(3):
            nz[..., ch] = cv2.GaussianBlur(nz[..., ch], (0, 0), corr)
            nz[..., ch] *= sigma8 / nz[..., ch].std()
    img = np.clip(np.round(srgb + nz), 0, 255).astype(np.uint8)
    if jpeg:
        ok, buf = cv2.imencode(".jpg", img[..., ::-1], [cv2.IMWRITE_JPEG_QUALITY, jpeg])
        img = cv2.imdecode(buf, 1)[..., ::-1]
    return np.ascontiguousarray(img)


def test_correlated_noise_is_still_measured():
    """Noise-reduced output has spatially correlated noise; the texture gate must not void it."""
    for corr in (0.8, 1.2, 1.6):
        r = analyze_noise(_gradient(5.0, corr=corr))
        assert r.n_patches > 500, (corr, r.n_patches, r.candidate_patches)
        assert np.isfinite(r.snr_midgrey_db)
        assert r.noise_whiteness > 0.25                 # and the correlation is reported
        assert abs(r.luma_noise_midgrey - 3.75) / 3.75 < 0.2
    white = analyze_noise(_gradient(5.0))
    assert white.noise_whiteness < 0.2


def test_mid_grey_extrapolation_is_flagged():
    dark = analyze_noise(_gradient(3.0, lo=0.001, hi=0.03))     # night frame: nothing near mid-grey
    assert dark.snr_midgrey_extrapolated
    assert dark.nearest_bin_level < 60
    normal = analyze_noise(_gradient(3.0))
    assert not normal.snr_midgrey_extrapolated


def test_dr_floor_is_the_first_failing_level_from_the_top():
    """A bad mid-tone bin must not be skipped: DR stops at the first level, from white down, that fails."""
    from iqa import noise as N
    rng = np.random.default_rng(1)
    size = 1000
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float64)
    lin = 0.003 + 0.9 * (xx / size) ** 2.2
    srgb = srgb_encode(np.repeat(lin[..., None], 3, axis=2)) * 255.0
    nz = rng.normal(0.0, 2.0, srgb.shape)
    band = (srgb[..., 0] > 60) & (srgb[..., 0] < 90)            # a noisy mid-tone band (still edge-free)
    nz[band] *= 4.5
    img = np.clip(np.round(srgb + nz), 0, 255).astype(np.uint8)
    r = N.analyze_noise(img)
    assert np.isfinite(r.dr_stops["snr10"])
    assert not r.dr_is_lower_bound["snr10"]
    # The floor at SNR 10 must sit at or above the noisy band, not below it.
    white = float(N.srgb_decode(np.array(250.0 / 255.0)))
    floor_level = white / 2 ** r.dr_stops["snr10"]
    assert floor_level >= float(N.srgb_decode(np.array(60.0 / 255.0))) * 0.9


def test_quantisation_ceiling_is_reported_sanely():
    r = analyze_noise(_gradient(0.0))
    assert 48.0 < r.snr_midgrey_db < 56.0        # 8-bit quantisation noise 1/sqrt(12) -> ~52 dB
