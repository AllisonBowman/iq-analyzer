"""Natural-edge detection and the full pipeline on a synthetic scene with known blur."""
import os

import numpy as np
from PIL import Image

from iqa.analyze import analyze_file
from iqa.edges import measure_natural_edges
from iqa.imageio import lin_luma_from_rgb8, load_image
from iqa.report import write_charts, write_csv, write_json, write_markdown
from iqa.sfr import gaussian_mtf50
from iqa.synth import synthetic_scene


def test_natural_edges_recover_scene_blur():
    for sigma in (0.9, 1.4, 2.0):
        rgb = synthetic_scene(size=1400, sigma_px=sigma, noise_8bit=2.0)
        summ = measure_natural_edges(lin_luma_from_rgb8(rgb))
        assert summ.n_measured >= 8, summ.n_measured
        expected = gaussian_mtf50(sigma)
        assert abs(summ.mtf50_median - expected) / expected < 0.08, (sigma, summ.mtf50_median, expected)
        assert all(1.0 <= abs(e.sfr.slope_deg) <= 16.0 for e in summ.edges)


def test_blurrier_scene_measures_softer():
    sharp = measure_natural_edges(lin_luma_from_rgb8(synthetic_scene(sigma_px=0.9)))
    soft = measure_natural_edges(lin_luma_from_rgb8(synthetic_scene(sigma_px=2.2)))
    assert sharp.mtf50_p80 > soft.mtf50_p80 * 1.8


def test_end_to_end_on_png_and_jpeg(tmp_path):
    rgb = synthetic_scene(size=1200, sigma_px=1.2, noise_8bit=3.0)
    p_png = tmp_path / "scene.png"
    p_jpg = tmp_path / "scene.jpg"
    Image.fromarray(rgb).save(p_png)
    Image.fromarray(rgb).save(p_jpg, quality=95)

    img = load_image(str(p_png))
    assert img.rgb8.shape == rgb.shape and img.lin_luma.shape == rgb.shape[:2]
    assert img.meta["width"] == 1200 and img.meta["format"] == "png"

    records = [analyze_file(str(p_png)), analyze_file(str(p_jpg))]
    for r in records:
        assert r["edges_measured"] >= 6
        assert np.isfinite(r["mtf50_p80_cpp"])
        assert np.isfinite(r["snr_midgrey_db"])
        assert 1.0 < r["clip_high_pct"] < 2.0

    out = tmp_path / "out"
    out.mkdir()
    write_csv(records, str(out / "results.csv"))
    write_json(records, str(out / "results.json"))
    charts = write_charts(records, str(out / "charts"))
    write_markdown(records, charts, str(out / "report.md"))
    assert (out / "results.csv").read_text().count("\n") == 3   # header + 2 rows
    assert "## Summary" in (out / "report.md").read_text()
    assert os.path.getsize(out / "results.json") > 1000
