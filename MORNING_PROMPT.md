Read CLAUDE.md first; it has the project context and conventions.

Set up and verify: `source .venv/bin/activate` (already created with Python 3.12; `pip install -r requirements.txt` if imports fail), then `python -m pytest -q` (51 tests should pass).

Then run the analyzer on my real photos. Build the file list once:

    find "$HOME/Pictures/Photos Library.photoslibrary/originals" -type f \( -iname '*.heic' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.dng' -o -iname '*.png' \) > photo_list.txt

If macOS shows a "would like to access your Photos" dialog, stop and tell me; I will click Allow. Pick a random sample of 60 paths from photo_list.txt (seed 1) and run

    python -m iqa analyze $(shuf -n 60 --random-source=<(yes) photo_list.txt) --out results --title "Allison's library, 60-image sample"

(macOS has no `shuf` by default: `sort -R | head -60` or `python -c` with random.Random(1) are fine). Never modify anything inside the Photos library.

Read results/report.md. Sanity-check five images by eye against their numbers (open the sharpest, the softest, the noisiest, the most clipped, and one mid-pack) with `open`. Then write results/FINDINGS.md: which camera/lens/ISO combinations are sharpest and cleanest, anything surprising, and any metric that looks wrong. Do not change the measurement code to make numbers look better; if a metric is wrong, say so and propose the fix in FINDINGS.md.
