"""Fixes from the adversarial discrepancy sweep (docs/DISCREPANCIES.md, 2026-10-23).

Each test pins one analyzer change that alters a stored value or its accounting:
LW/PH on the short side (F8/F16), gamut clipping on the same pixel set as the native count (F14),
edge-candidate accounting (F16), non-negative surface shares (F19), the format column naming the
container (format-column-jpg-vs-jpeg), and the report's thresholds read from the code (F06/F9).
"""
import numpy as np
import pytest
from PIL import Image

from iqa.analyze import analyze_file
from iqa.synth import synthetic_scene


@pytest.mark.parametrize("portrait", [True, False])
def test_lwph_is_normalised_to_the_short_side(tmp_path, portrait):
    """LW/PH is 2 x MTF50 x picture height in landscape orientation, i.e. the short side, so the
    same optics give the same figure whichever way the camera was held."""
    rgb = synthetic_scene(size=1400, sigma_px=1.2, noise_8bit=2.0)[:, :1000]   # 1400 tall, 1000 wide
    if not portrait:
        rgb = np.ascontiguousarray(rgb.transpose(1, 0, 2))
    p = tmp_path / "scene.png"
    Image.fromarray(rgb).save(p)
    rec = analyze_file(str(p))
    assert rec["edges_measured"] >= 1
    assert min(rec["width"], rec["height"]) == 1000
    assert rec["mtf50_p80_lwph"] == pytest.approx(2.0 * rec["mtf50_p80_cpp"] * 1000, rel=1e-9)


def _even_row_highlights():
    """Blown pixels on even rows only: a [::2, ::2] subsample sees twice the full-resolution share."""
    rgb = np.full((200, 200, 3), 120, dtype=np.uint8)
    rgb[0:40:2, :, :] = 255          # 20 rows of 200: 10 % at full resolution, 20 % on the even rows
    return rgb


def test_gamut_clipping_is_zero_when_nothing_was_converted(tmp_path):
    p = tmp_path / "plain.png"       # no ICC profile: assumed sRGB, no conversion
    Image.fromarray(_even_row_highlights()).save(p)
    rec = analyze_file(str(p))
    assert rec["color_profile"] == "assumed-sRGB"
    assert rec["clip_high_pct"] == pytest.approx(10.0)
    assert rec["clip_gamut_pct"] == 0.0


def test_gamut_clipping_compares_the_same_pixels(tmp_path, monkeypatch):
    """A conversion that changes nothing must report no gamut clipping, whatever the pixel layout."""
    import iqa.imageio as io
    p = tmp_path / "p3.png"
    Image.fromarray(_even_row_highlights()).save(p)
    monkeypatch.setattr(io, "_to_srgb", lambda im: (im, "Display P3 -> sRGB"))
    rec = analyze_file(str(p))
    assert rec["clip_high_pct"] == pytest.approx(10.0)
    assert rec["clip_gamut_pct"] == pytest.approx(0.0, abs=1e-12)


def test_every_edge_candidate_is_accounted_for(monkeypatch):
    """candidates = measured + rejected + unexamined (left over when the ROI cap is reached), and a
    candidate whose ROI falls outside the frame is rejected as out_of_frame, not dropped silently."""
    import iqa.edges as edges
    from iqa.imageio import lin_luma_from_rgb8
    lin = lin_luma_from_rgb8(synthetic_scene(size=1200, sigma_px=1.2, noise_8bit=2.0))

    capped = edges.measure_natural_edges(lin, max_rois=3)
    assert capped.n_measured == 3 and capped.n_unexamined > 0
    assert capped.n_candidates == capped.n_measured + capped.n_rejected + capped.n_unexamined
    assert capped.n_rejected == sum(capped.reject_reasons.values())

    real = edges._candidate_segments
    monkeypatch.setattr(edges, "_candidate_segments",
                        lambda *a, **k: [(300.0, "v", 2.0, 2.0)] + real(*a, **k))   # ROI hangs off the corner
    s = edges.measure_natural_edges(lin)
    assert s.reject_reasons.get("out_of_frame") == 1
    assert s.n_candidates == s.n_measured + s.n_rejected + s.n_unexamined
    d = s.as_dict()
    assert d["edges_unexamined"] == s.n_unexamined


def test_surface_shares_are_never_negative():
    """4 edge blocks and 1 texture block of 5: 1 - 0.8 - 0.2 is -5.6e-17 in floating point."""
    from iqa.structure import surface_shares
    is_edge = np.array([[True, True, True, True, False]])
    is_tex = ~is_edge
    flat, tex, edge = surface_shares(is_edge, is_tex)
    assert flat == 0.0 and tex == pytest.approx(0.2) and edge == pytest.approx(0.8)
    assert min(flat, tex, edge) >= 0.0


@pytest.mark.parametrize("ext,want", [(".jpg", "jpeg"), (".JPG", "jpeg"), (".jpeg", "jpeg"), (".jpe", "jpeg"),
                                      (".png", "png"), (".tif", "tiff")])
def test_format_names_the_container_not_the_file_name(tmp_path, ext, want):
    from iqa.imageio import load_image
    p = tmp_path / f"a{ext}"
    Image.fromarray(np.full((40, 60, 3), 100, dtype=np.uint8)).save(p, format={"jpeg": "JPEG"}.get(want, want.upper()))
    assert load_image(str(p)).meta["format"] == want


def test_report_states_the_thresholds_the_code_uses(tmp_path):
    from iqa import noise
    from iqa.report import write_markdown
    recs = [{"file": "a.jpg", "camera_model": "X", "iso": 100, "edges_measured": 0,
             "edges_reject_reasons": "clipped=2;out_of_frame=1", "edges_rejected": 3},
            {"file": "b.jpg", "camera_model": "Y", "iso": 200, "edges_measured": 0}]
    out = tmp_path / "report.md"
    write_markdown(recs, [], str(out))
    text = out.read_text()
    assert f"above {noise.PERIODIC_PEAK_THRESHOLD:g} (`noise_periodic_suspect`)" in text
    assert f"{noise.WHITENESS_SMOOTHED:g}+ means the noise has been smoothed" in text
    assert f"{noise.WHITENESS_HEAVY:g}+ heavily" in text
    assert "out of frame" in text and "clipped" in text      # the rejection list comes from the stored reasons
