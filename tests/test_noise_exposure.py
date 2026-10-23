"""Noise, dynamic range and exposure statistics on images with known properties."""
import numpy as np

from iqa.exposure import analyze_exposure
from iqa.imageio import srgb_encode
from iqa.noise import analyze_noise
from iqa.synth import synthetic_scene


def _noisy_gradient(sigma8: float, size: int = 900, seed: int = 0) -> np.ndarray:
    """A smooth linear-luminance ramp with Gaussian noise of ``sigma8`` 8-bit units per channel."""
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float64)
    lin = 0.02 + 0.9 * (xx / size) ** 2.2
    srgb = srgb_encode(np.repeat(lin[..., None], 3, axis=2)) * 255.0
    srgb = srgb + rng.normal(0.0, sigma8, srgb.shape)
    return np.clip(np.round(srgb), 0, 255).astype(np.uint8)


def test_noise_recovers_injected_sigma():
    for sigma in (2.0, 5.0, 10.0):
        res = analyze_noise(_noisy_gradient(sigma))
        assert res.n_patches > 200
        # Per-channel sigma -> luminance sigma is 0.75x (sqrt of sum of squared luma weights).
        expected = 0.75 * sigma
        assert abs(res.luma_noise_midgrey - expected) / expected < 0.12, (sigma, res.luma_noise_midgrey)
        # Chroma noise of independent channels: std(R-G) = sqrt(2) sigma.
        assert abs(res.chroma_noise_midgrey - np.sqrt(2) * sigma) / (np.sqrt(2) * sigma) < 0.12


def test_noise_curve_is_flat_for_additive_noise_and_dr_decreases_with_noise():
    quiet = analyze_noise(_noisy_gradient(2.0))
    loud = analyze_noise(_noisy_gradient(12.0))
    assert quiet.luma_noise.size >= 6
    assert np.std(quiet.luma_noise) / np.mean(quiet.luma_noise) < 0.15
    assert quiet.snr_midgrey_db > loud.snr_midgrey_db + 10
    assert quiet.dr_stops["snr4"] > loud.dr_stops["snr4"] + 1.5


def test_texture_is_not_counted_as_noise():
    rgb = synthetic_scene(size=1400, sigma_px=1.1, noise_8bit=3.0)
    res = analyze_noise(rgb)
    # Injected 3.0 per channel => 2.25 luma. The fine-texture patch must not inflate this.
    assert abs(res.luma_noise_midgrey - 2.25) < 0.35


def test_exposure_clipping_counts():
    rgb = synthetic_scene(size=1400)
    x = analyze_exposure(rgb, step=1)
    # The scene has a 150x200 clipped-white block and a 150x200 black block in a 1400x1400 image
    # (1.53 % each). Noise (sigma 3) pushes some black-block pixels above 1 in at least one channel,
    # so the "all channels <= 1" count is about a third of the block.
    assert 1.2 < x.clip_high_pct < 1.9
    assert 0.3 < x.clip_low_pct < 1.0
    assert 0.95 < x.wb_r_over_g < 1.05
    assert x.wb_b_over_g > 1.02  # the scene is slightly blue


def test_clipping_is_measured_before_the_profile_conversion(tmp_path, monkeypatch):
    """A wide-gamut colour that saturates only after conversion to sRGB is not a blown highlight."""
    from PIL import Image
    import iqa.imageio as io
    from iqa.analyze import analyze_file
    rgb = np.full((200, 200, 3), 120, dtype=np.uint8)
    rgb[:100, :, :] = (230, 40, 40)          # saturated but not clipped in the file's own encoding
    rgb[150:, 150:, :] = 255                  # a genuinely blown block: 6.25 % of pixels
    path = tmp_path / "p3.png"
    Image.fromarray(rgb).save(path)

    def fake_to_srgb(im):                     # stand-in for a Display P3 -> sRGB conversion that clips red
        a = np.asarray(im).copy()
        red = (a[..., 0] > 200) & (a[..., 1] < 100)
        a[red, 0] = 255
        return Image.fromarray(a), "Display P3 -> sRGB"
    monkeypatch.setattr(io, "_to_srgb", fake_to_srgb)
    rec = analyze_file(str(path))
    assert abs(rec["clip_high_pct"] - 6.25) < 0.01, rec["clip_high_pct"]
    assert abs(rec["clip_gamut_pct"] - 50.0) < 0.01, rec["clip_gamut_pct"]   # the red half clipped only in sRGB
    assert rec["clip_low_pct"] == 0.0


def test_native_shadow_clipping_needs_every_channel_at_the_floor():
    """(0, 0, 200) is a saturated blue, not a crushed shadow; (1, 1, 1) is crushed; (255, 0, 0)
    is a blown highlight (any channel at the top)."""
    from iqa.imageio import native_clip_stats
    a = np.full((10, 10, 3), 120, dtype=np.uint8)
    a[0, :5] = (0, 0, 200)      # 5 % of pixels: one channel at zero, must not count as crushed
    a[1, :3] = (1, 1, 1)        # 3 %: crushed
    a[2, :2] = (255, 0, 0)      # 2 %: blown (any channel >= 254)
    hi, lo = native_clip_stats(a)
    assert abs(hi - 2.0) < 1e-9, hi
    assert abs(lo - 3.0) < 1e-9, lo
