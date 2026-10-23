"""Build the narrated explainer video for iq-analyzer.

Slides are rendered with matplotlib from the repo's own figures, narration is spoken by the
Mac's text-to-speech (``say``), and the pieces are stitched with the ffmpeg binary bundled in
``imageio-ffmpeg``.  Run ``python media/figures.py`` first (it reads the Photos library,
read-only) so ``media/build/assets`` holds the real-data figures.

    python media/make_explainer.py            -> media/build/iq-analyzer-explainer.mp4
    python media/make_explainer.py --script   -> only print the narration

Everything stated here is pinned to the repo: numbers come from results/FINDINGS.md and the
test suite as of the commit that added the periodic-texture detector.
"""
import argparse, os, subprocess, sys, textwrap
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.image as mpimg

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "media", "build")
ASSETS = os.path.join(BUILD, "assets")
CHARTS = os.path.join(ROOT, "results", "charts")
VOICE, RATE = "Samantha", 178
W, H = 1920, 1080

# --------------------------------------------------------------------------------------------
# Slides: (title, bullets, image or None, narration)
# --------------------------------------------------------------------------------------------
SLIDES = [
("iq-analyzer",
 ["ISO image-quality metrics measured on 389 of Allison's own camera captures",
  "Slanted-edge MTF (ISO 12233 e-SFR), noise, SNR, output-referred dynamic range, exposure",
  "73 tests, every metric validated against synthetic ground truth",
  "Built with Claude Code as a portfolio for Apple, Camera & Photos, Image Quality Engineer"],
 None,
 "This is iq-analyzer, a Python tool that measures ISO image-quality metrics on real photographs. "
 "It was built in two days with Claude Code as the portfolio piece for the Apple Camera and Photos "
 "image quality engineer role. This video explains how it works, walks through the periodic-texture "
 "detector added today as a worked example of the method, and then covers what you need to know "
 "cold for the interview. Everything I say is pinned to a file in the repository, so you can check it."),

("Why this project exists",
 ["The posting asks for: automation with coding harnesses, Python, photography, pipeline familiarity, ISO IQ metrics",
  "The one gap was ISO metrics, so the repo turns it into a demonstrated strength",
  "Measured on 389 captures from 19 devices: iPhone 17 Pro Max, iPhone 13, Nikon D850, older iPhones, compacts",
  "Audience: a camera-team engineer will read the code, so correctness and honest caveats beat features"],
 None,
 "The job posting lists automation built with coding harnesses, Python, photography knowledge, imaging "
 "pipeline familiarity, and ISO image-quality metrics. The one gap in the background was the ISO metrics, "
 "so the project measures them, on a library you actually shot: three hundred eighty-nine captures from "
 "nineteen devices, dominated by the iPhone seventeen Pro Max, the iPhone thirteen, and the Nikon D eight fifty. "
 "The audience is a camera-team engineer reading the code, which shaped every decision: correctness and "
 "clearly stated caveats over feature count."),

("Architecture: one pass per image",
 ["imageio: RAW via rawpy, HEIC via pillow-heif, EXIF, ICC profiles converted to sRGB (328 of 389 were Display P3)",
  "edges: Canny plus probabilistic Hough finds natural slanted edges, 1.5 to 12 degrees, with quality gates",
  "sfr: ISO 12233 e-SFR on each edge, on linear luminance",
  "noise: flat-patch noise, SNR, dynamic range, on display-referred sRGB",
  "exposure and report: clipping, white balance, CSV, JSON, charts, report.md with a how-to-read section"],
 None,
 "The pipeline is one pass per image. The image loader handles RAW through rawpy and HEIC through pillow "
 "heif, reads EXIF, and converts ICC profiles to sRGB, which mattered: three hundred twenty-eight of the "
 "three hundred eighty-nine files carried a Display P3 profile. The edge finder uses Canny and a "
 "probabilistic Hough transform to find natural slanted edges between one and a half and twelve degrees. "
 "The SFR module runs the ISO twelve two thirty-three slanted-edge method on each one, on linear luminance. "
 "The noise module measures flat patches on display-referred sRGB. That split is deliberate: sharpness is a "
 "property of the optical and sampling chain, so it is measured in linear light; noise is compared across RAW "
 "and JPEG, so it is measured where they are comparable, in the output encoding."),

("Slanted-edge MTF, the ISO 12233 e-SFR method",
 ["Fit the edge line, project pixels onto the edge normal to build a supersampled edge spread function",
  "Differentiate to the line spread function, Hamming window, FFT: the magnitude is the MTF",
  "MTF50: the frequency, in cycles per pixel, where contrast falls to half. 0.25 to 0.35 is very sharp, 0.10 to 0.15 soft",
  "Validated against an analytic Gaussian MTF (within 4 %, 6 % with 1 % noise) and against the pixel-aperture truth Gaussian times sinc (MTF50 within 1.5 %)",
  "Compare cameras in line widths per picture height, not cycles per pixel, because sensor sizes differ"],
 os.path.join(CHARTS, "mtf50_hist.png"),
 "Here is the slanted-edge method in plain words. You fit a line to the edge, then project every pixel "
 "near it onto the edge normal. Because the edge is tilted, pixels land at fractional distances and you get "
 "a finely supersampled edge spread function. Differentiate it and you have the line spread function; "
 "window it, take the Fourier transform, and the magnitude is the modulation transfer function. MTF fifty "
 "is the spatial frequency where contrast has fallen to half. The implementation was validated two ways: "
 "against an analytic Gaussian blur, within four percent, and against the pixel-aperture ground truth, "
 "a Gaussian times a sinc, where MTF fifty agrees within one and a half percent. Two robustness details "
 "worth knowing: per-row edge location uses the signed derivative inside a window scaled to the edge width, "
 "because unsigned centroids bias the slope, and MTF fifty is searched only below Nyquist. When you compare "
 "cameras, convert to line widths per picture height, since a D eight fifty pixel and an iPhone pixel cover "
 "different fractions of the frame."),

("Noise, SNR and dynamic range from a single frame",
 ["High-pass the luminance with a sigma-8 Gaussian so gradients do not count as noise",
  "Scan 32-pixel patches, keep edge-free, unclipped ones whose residual looks like noise, not texture",
  "noise_whiteness: smoothed over raw residual std; 0.14 is white noise, 0.4 plus is heavily noise-reduced",
  "Noise floor per brightness bin is a low percentile: texture can only raise the std, so the lower envelope is the estimate",
  "SNR at mid-grey (sRGB 118) in dB; output-referred DR as stops between near-white and the level where linear SNR drops below 1, 2, 4, 10"],
 os.path.join(CHARTS, "snr_vs_iso_by_camera.png"),
 "Noise is harder, because a single photograph gives you no second exposure to subtract. The tool high-passes "
 "the luminance with a wide Gaussian so smooth gradients do not count, scans thirty-two pixel patches, and keeps "
 "those with no edges, no clipping, and a residual that looks like noise rather than texture. The texture test "
 "is a ratio: smooth the residual with a sigma-two Gaussian and compare the standard deviation to the raw one. "
 "White noise shrinks to about zero point one four; texture survives. That ratio, reported as noise whiteness, "
 "turned out to be a readout of noise reduction strength. The headline finding on this library is on the chart: "
 "the D eight fifty's SNR falls about two decibels per ISO doubling, like a sensor, while the iPhone seventeen Pro "
 "Max holds output noise roughly constant and is actually cleaner at mid ISO than at base ISO, because its noise "
 "reduction scales with ISO. So output-referred SNR across cameras compares pipelines, not sensors. Say that "
 "sentence in the interview; it shows you understand what you measured."),

("Today's problem: photographs of screens read as noise",
 ["A monitor's pixel grid is a periodic texture; the single-frame estimator cannot tell it from noise",
  "The whiteness gate (ratio above 0.7) caught 21 screen photos but missed one with a fine stripe pattern at whiteness 0.12",
  "It sat in the noisiest-valid list at 21 dB, ISO 125",
  "FINDINGS.md section 5, item 1 said: a proper fix is spectral, flag patches whose residual spectrum has sharp peaks"],
 None,
 "Now the worked example. Before today, the two noisiest images in the whole library were photographs of a "
 "monitor. The pixel grid and its moire are a periodic texture that the estimator counts as noise. The whiteness "
 "gate caught twenty-one of them, but one screen photo with a fine, white-looking stripe pattern passed at "
 "whiteness zero point one two and sat in the noisiest-valid list at twenty-one decibels. The findings document "
 "already said what the fix should be: look at the spectrum, and flag sharp peaks."),

("The detector: average thousands of normalised spectra",
 ["Take the 2-D power spectrum of every candidate patch, normalise each to unit mean power, average them",
  "A pattern that repeats at one frequency adds coherently; noise averages to a flat 1",
  "Screen photo: two bright spots at plus and minus 0.25 cycles per pixel, a 4-pixel stripe period",
  "Nikon D850 water: a smooth radial blob, nothing sharp",
  "Per-image cost about one second; 6,597 patches on the screen photo, 50,895 on the D850 frame",
  "Normalised peak: 15 for the screen, 1.7 for the Nikon, threshold 6"],
 os.path.join(ASSETS, "fig_crops_spectra.png"),
 "Here is what it does, with the two real files. The top row is the screen photo, the bottom row the Nikon. "
 "The first column is a crop; the second is the residual the estimator actually sees, and you can already make "
 "out the vertical striping in the screen photo. The third column is the key move: the two-dimensional power "
 "spectrum of every candidate patch, each normalised to unit mean power, then averaged. A single thirty-two pixel "
 "patch cannot reliably see a pattern whose power is a fraction of the noise, but the pattern sits at the same "
 "frequency in every patch, so it adds coherently, while the noise averages toward a flat one. The screen photo "
 "shows two bright spots at plus and minus a quarter cycle per pixel, a four-pixel stripe period. The Nikon frame "
 "is a smooth radial blob. The fourth column is the normalised peak statistic: fifteen for the screen, one "
 "point seven for the Nikon, against a threshold of six."),

("Four things that did not work, and the fix",
 ["Max over median of all bins: explodes on noise-reduced images, because the high-frequency median is near zero. Smoothed noise scored 430,000",
  "Annular median only: every ordinary file peaked at exactly Nyquist on an axis, up to 9x. Demosaicing and JPEG make the spectrum stronger along the axes than the diagonals; a ridge is not a peak",
  "Local neighbourhood only: every file peaked at the lowest valid radius, the 1/f slope of natural texture against a flatter neighbourhood",
  "Annulus then 7x7 block median: good on 28 files, but the full library produced four false positives at 8 to 12: a D850 water frame with a vertical-axis ridge at the lowest radius, a compact camera with demosaic energy on the Nyquist row and column, two iPhones with axis ridges next to Nyquist",
  "Fix: divide by the annulus median (radial envelope), then by the larger of the row and column medians at 2 to 4 bins (a ridge is high along one axis, a spot along neither); exclude the whole Nyquist row and column. Only a sharp spot survives"],
 None,
 "This slide is the part an interviewer will care about most, because it shows judgment. The obvious statistic, "
 "the maximum over the median of all spectral bins, exploded on noise-reduced images: the high-frequency median is "
 "near zero, so smoothed noise scored four hundred thousand. Normalising each bin by the median of its annulus "
 "fixed that, but then every ordinary file peaked at exactly Nyquist on one axis, up to nine times, D eight fifty "
 "included. That is not periodicity; demosaicing and JPEG quantisation leave more power along the axes than along "
 "the diagonals, and the annulus median under-estimates axis bins. A ridge is not a peak. Normalising by the local "
 "neighbourhood instead failed differently: every file peaked at the lowest valid radius, which is just the one "
 "over f slope of natural texture against a flatter neighbourhood. Combining the annulus with a seven by seven block "
 "median looked right on twenty-eight files, and then the full library produced four false positives between eight "
 "and twelve. Looking at them was the whole job: a D eight fifty water frame with a vertical ridge at the lowest "
 "searched radius, a compact camera with demosaic energy on the Nyquist row and column, and two iPhones with axis "
 "ridges next to Nyquist. A block median cannot tell a ridge from a spot. A directional one can: divide by the larger "
 "of the row median and the column median at two to four bins away. A ridge is high along one axis and scores about "
 "one; a spot is high along neither. Exclude the whole Nyquist row and column, and only a sharp spot survives."),

("Threshold from measured distributions, not a guess",
 ["Synthetic negatives (white, pink, smoothed, anisotropic noise, JPEG q50 and q75 blocking): 1.0 to 1.8",
  "34 ordinary library files, five cameras, HEIC and JPEG, including the four former false positives: 1.3 to 3.2",
  "Half-noise-amplitude sinusoids: 15 to 48. Noise-strength grid on 11 % of the frame: 16. The library's screen photos: 11, 15 and 127",
  "Threshold 6 is the geometric midpoint of 3.2 and 11.3, a factor of 1.9 on each side",
  "Excluded from the search: radius below 3 cycles per patch (the high-pass still shapes it) and the Nyquist row and column (a 2-pixel alternation along either axis)"],
 os.path.join(ASSETS, "fig_peaks.png"),
 "The threshold is six, and it is not a guess. Synthetic negatives, white, pink, smoothed, anisotropic, and "
 "JPEG-blocked noise, score between one and one point eight. Thirty-four ordinary library files from five cameras, "
 "including the four former false positives, score between one point three and three point two. On the positive "
 "side, sinusoids at half the noise amplitude score fifteen to forty-eight, a noise-strength grid covering just "
 "eleven percent of the frame scores sixteen, and the library's four screen photos score eleven to one hundred "
 "twenty-seven. Six is the geometric midpoint of three point two and eleven point three, a factor of one point nine "
 "on each side. Two kinds of bins are excluded from the search: anything below three cycles per patch, where the "
 "sigma-eight high-pass still shapes the spectrum, and the whole Nyquist row and column, because a two-pixel "
 "alternation along either axis is something sampling and sharpening produce, not scene texture."),

("What the flag does, and a surprise from the test suite",
 ["noise_spectral_peak, noise_periodic_suspect, noise_periodic_freq_cpp, noise_periodic_fraction in the CSV",
  "Flagged images leave the SNR medians and rankings, like the whiteness flag",
  "Patches carrying the pattern are excluded only while they are a minority of the selection: a screen in a room is cut out, a full-frame screen keeps its number and the flag speaks",
  "A noise-free gradient quantised to 8 bits is a staircase: contour lines every 4 pixels. The detector flagged it, and the first version excluded every patch. The minority rule came from that failing test"],
 None,
 "The flag feeds four columns into the CSV, and flagged images leave the SNR medians and the rankings, the same "
 "way the whiteness flag already worked. There is one more rule. Patches carrying the pattern are excluded from the "
 "noise floor only while they are a minority of the selected patches. A television in a living room gets cut out "
 "and the rest of the frame measures cleanly; a full-frame screen keeps its number and the flag does the talking, "
 "because the leftover patches would not be representative. That rule came from a failing test. An existing "
 "adversarial test feeds a noise-free gradient quantised to eight bits and expects fifty-two decibels, the "
 "quantisation ceiling. A quantised gradient is a staircase, with contour lines every four pixels, so the detector "
 "correctly called it periodic, and the first version excluded every patch and returned nothing. That is exactly "
 "what the test suite is for."),

("Test first: nine ground-truth tests, 73 in total",
 ["Negatives: white, Gaussian-smoothed, anisotropic, and JPEG q50 noise must not flag",
  "Positives: a 4-pixel grid at noise amplitude, a slanted sinusoid at half amplitude, a near-Nyquist sinusoid: flagged, with the frequency recovered within one bin",
  "Partial frame: a screen on 11 % of the frame is flagged and the noise figure recovers to within 5 % of the clean value",
  "Unflagged images: selection and figures are exactly what the old code produced",
  "Rule from CLAUDE.md: never change measurement code to make a number look better; fix the method, with a synthetic test first"],
 None,
 "The tests were written before the detector, which is the rule in the project: every new metric gets a synthetic "
 "ground-truth test first, and you never change measurement code to make a number look better. Four negatives, "
 "three positives that also check the recovered frequency, a partial-frame case that checks the noise figure "
 "recovers to within five percent of the clean value after exclusion, and a guard that unflagged images produce "
 "exactly the old selection. Seventy-three tests pass in about twelve seconds."),

("How to tell this story in the interview",
 ["The arc: a stated gap, a tool that measures the metric, validation against ground truth, findings on real data, caveats you found yourself",
  "Lead with a finding, not a feature: phones hold output noise flat against ISO; the DSLR falls 2 dB per doubling",
  "Then a method story: the periodic detector, three failed normalisations, a threshold from measured distributions",
  "Then honesty: FINDINGS section 5 lists six things you do not trust, with reasons",
  "Close with what you would do with a lab: an e-SFR chart, a ColorChecker, matched RAW and HEIC pairs"],
 None,
 "When you talk about this, use the arc. There was a stated gap; you built a tool that measures the metric; you "
 "validated it against ground truth; you ran it on real data and found something; and you listed what you do not "
 "trust, yourself, before anyone asked. Lead with a finding, not a feature list: phones hold output noise flat "
 "against ISO while the DSLR falls two decibels per doubling. Then tell the method story you just watched, the three "
 "normalisations that failed and why. Then the caveats. And close with what you would do with a lab and a chart, "
 "which is exactly what the role has."),

("Questions to expect, and the answers in the repo",
 ["Why natural edges instead of a chart? Every figure is a scene-dependent lower bound; it is consistent across cameras, and chart mode, now built, gives the absolute figure on a printed chart",
  "Why output-referred? RAW and JPEG are only comparable in the output encoding; the cost is that you compare pipelines, not sensors",
  "How do you know the SFR is right? Analytic Gaussian within 4 %; pixel-aperture truth within 1.5 %; MTF50 only below Nyquist",
  "What is wrong with your numbers? Few valid edges per natural image; DR is mostly lower bounds; HEIC vs JPEG in a Photos library is not original vs processed",
  "How would you measure noise reduction properly? Matched RAW and HEIC pairs of the same shot on a grey patch"],
 None,
 "Expect these questions. Why natural edges instead of a chart: because a real edge is never a perfect step, every "
 "figure is a scene-dependent lower bound on the system MTF, consistent across cameras, and chart mode, now built, "
 "measures the absolute figure on a printed chart. Why output-referred: because RAW and JPEG are only comparable in the output encoding, and the price "
 "is that you compare pipelines, not sensors. How do you know the SFR code is right: analytic Gaussian within four "
 "percent, pixel-aperture truth within one and a half percent, MTF fifty searched below Nyquist only. What is wrong "
 "with your numbers: natural scenes give about five valid edges per image where any exist, dynamic range is mostly "
 "a lower bound because few frames contain near-black flat areas, and the HEIC versus JPEG split in a Photos library "
 "is not camera-original versus processed, because the JPEGs are likely shared copies. How would you measure noise "
 "reduction properly: matched RAW and HEIC pairs of the same shot, compared on a grey patch."),

("More questions, on the detector and on process",
 ["Why average spectra across patches? A single 32x32 patch cannot see a pattern at a fraction of the noise power; coherent averaging over thousands of patches can",
  "Why is the periodogram noisy? Each bin of a white-noise periodogram is chi-squared with 2 degrees of freedom; max over median of ~500 bins is about 6, and up to 14",
  "Why exclude the Nyquist row and column? A 2-pixel alternation along either axis is a sampling and demosaic artefact; a compact camera put its strongest energy there",
  "What about JPEG blocking? Periodic at 1/8 cycle per pixel on the axes; measured 1.6 to 1.7 synthetic, far below threshold",
  "How did you use Claude Code? Test-first, an adversarial review run that found 13 correctness issues, each pinned by a test; the model proposed, the tests decided"],
 None,
 "On the detector itself. Why average spectra across patches: a single patch cannot see a pattern whose power is a "
 "fraction of the noise, but coherent averaging over thousands of patches can. Why is a single periodogram noisy: "
 "each bin of a white-noise periodogram is chi-squared with two degrees of freedom, so the maximum over the median "
 "of five hundred bins is about six on a typical patch and up to fourteen; that is why a per-patch threshold would "
 "never work. Why exclude the Nyquist row and column: a two-pixel alternation along either axis is a sampling and "
 "demosaic artefact, and a compact camera in the library put its strongest spectral energy exactly there. What about "
 "JPEG blocking: it is periodic at one eighth cycle per pixel on the axes, and it measured below two on synthetic q "
 "fifty and q seventy-five files. And on process: Claude Code worked "
 "test-first, an adversarial review run found thirteen correctness issues that were each pinned by a test, and the "
 "model proposed while the tests decided."),

("Definitions to know cold",
 ["MTF50 and MTF50P: frequency at half of 1.0, and at half of the MTF peak; MTF50P is robust to sharpening halos. Overshoot measures the halo directly",
  "Nyquist: 0.5 cycles per pixel. Line widths per picture height: 2 x cycles per pixel x image height",
  "SNR in dB: 20 log10 of signal over noise std, at sRGB 118, the encoding of 18 % reflectance. 8-bit quantisation caps it near 52 dB",
  "sRGB EOTF: the noise in encoded units is converted to linear with the local slope of the curve before the dynamic-range SNR is computed",
  "Bayer and demosaicing: why the spectrum is anisotropic. JPEG: 8x8 DCT blocks, so blocking lives at multiples of 1/8 cycle per pixel"],
 None,
 "Definitions to have cold. MTF fifty is where the MTF reaches a half of one; MTF fifty P is where it reaches half of "
 "its own peak, which makes it robust to sharpening halos, and the overshoot metric measures the halo directly. "
 "Nyquist is half a cycle per pixel. Line widths per picture height is two times cycles per pixel times the image "
 "height. SNR in decibels is twenty log ten of signal over noise standard deviation, taken at sRGB one eighteen, the "
 "encoding of eighteen percent reflectance, and eight-bit quantisation alone caps it near fifty-two decibels. The "
 "dynamic range computation converts encoded noise to linear with the local slope of the sRGB curve. And know why the "
 "spectrum is anisotropic: Bayer sampling and demosaicing, plus JPEG's eight by eight DCT blocks, which put blocking "
 "energy at multiples of one eighth cycle per pixel."),

("What is next, and what to say about it",
 ["Done since the first cut: public repo without file paths, chart mode (ColorChecker dE00, e-SFR field map), bootstrap intervals, the in-focus/background split, structure analysis",
  "Next: photograph a real ColorChecker and e-SFR chart; chart mode has only seen rendered charts",
  "Next: matched RAW and HEIC pairs of the same shot, to measure what the phone pipeline does to noise and sharpening",
  "Say what is not done as plainly as what is; that is the habit the findings file already shows"],
 None,
 "Finally, what is next, because an interviewer will ask. Since the first cut the repository went public without file "
 "paths, chart mode was built for a ColorChecker and an e-SFR chart, every sharpness figure gained a bootstrap interval, "
 "and shallow depth-of-field frames get an in-focus and a background figure. What remains is the part that needs a "
 "camera: photograph a real ColorChecker and a real e-SFR chart, because chart mode has only seen rendered charts, and "
 "shoot matched RAW and HEIC pairs to measure what the phone pipeline does. Say what is not done as plainly as what is. "
 "That habit is already in the findings file, and it is "
 "the strongest thing in this project."),
]


def render_slide(i, title, bullets, image):
    fig = plt.figure(figsize=(W / 100, H / 100), dpi=100, facecolor="#101418")
    fig.text(0.05, 0.92, title, fontsize=34, fontweight="bold", color="#F5F5F0", va="top")
    fig.text(0.05, 0.035, f"iq-analyzer   {i + 1:02d} / {len(SLIDES):02d}", fontsize=14, color="#8A94A0")
    if image and os.path.exists(image):
        img = mpimg.imread(image)
        ih, iw = img.shape[:2]
        # image on the right half, bullets on the left
        box_w, box_h = 0.50, 0.70
        scale = min(box_w * W / iw, box_h * H / ih)
        fw, fh = iw * scale / W, ih * scale / H
        ax = fig.add_axes([0.47, 0.12 + (box_h - fh) / 2, fw, fh])
        ax.imshow(img); ax.axis("off")
        text_w, wrap = 0.40, 52
    else:
        text_w, wrap = 0.90, 118
    y = 0.80
    for b in bullets:
        lines = textwrap.wrap(b, wrap)
        fig.text(0.06, y, "•", fontsize=22, color="#F58518", va="top")
        fig.text(0.085, y, "\n".join(lines), fontsize=20, color="#E6E6E0", va="top", linespacing=1.35)
        y -= 0.045 * len(lines) + 0.03
    out = os.path.join(BUILD, f"slide_{i:02d}.png")
    fig.savefig(out, dpi=100, facecolor=fig.get_facecolor()); plt.close(fig)
    return out


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--script", action="store_true"); a = ap.parse_args()
    if a.script:
        for i, (t, _, _, n) in enumerate(SLIDES):
            print(f"\n## {i + 1}. {t}\n\n{n}")
        return
    import imageio_ffmpeg
    ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
    os.makedirs(BUILD, exist_ok=True)
    with open(os.path.join(BUILD, "narration.md"), "w") as fh:
        for i, (t, _, _, n) in enumerate(SLIDES):
            fh.write(f"\n## {i + 1}. {t}\n\n{n}\n")
    segs = []
    for i, (title, bullets, image, narration) in enumerate(SLIDES):
        png = render_slide(i, title, bullets, image)
        aiff = os.path.join(BUILD, f"slide_{i:02d}.aiff")
        subprocess.run(["say", "-v", VOICE, "-r", str(RATE), "-o", aiff, narration], check=True)
        seg = os.path.join(BUILD, f"seg_{i:02d}.mp4")
        subprocess.run([ffmpeg, "-y", "-loglevel", "error", "-loop", "1", "-i", png, "-i", aiff,
                        "-af", "apad=pad_dur=0.9", "-c:v", "libx264", "-tune", "stillimage", "-pix_fmt", "yuv420p",
                        "-r", "24", "-c:a", "aac", "-b:a", "128k", "-shortest", seg], check=True)
        segs.append(seg); print(f"slide {i + 1}/{len(SLIDES)} done", flush=True)
    lst = os.path.join(BUILD, "concat.txt")
    with open(lst, "w") as fh:
        for s in segs: fh.write(f"file '{s}'\n")
    out = os.path.join(BUILD, "iq-analyzer-explainer.mp4")
    subprocess.run([ffmpeg, "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", lst, "-c", "copy", out], check=True)
    print(out)


if __name__ == "__main__":
    main()
