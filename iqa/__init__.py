"""iqa — image-quality analysis for real photographs.

Modules
-------
imageio   load RAW / JPEG / HEIC / PNG / TIFF into linear and display-referred arrays + EXIF
sfr       ISO 12233-style slanted-edge SFR / MTF (the sharpness measurement)
edges     find natural slanted edges in a photo and measure them
noise     flat-patch noise, SNR, and an output-referred dynamic-range estimate
exposure  clipping, tonal statistics, colorfulness, gray-world white balance
analyze   run everything on one image
memory    the analyzer's memory: every photo measured once, by the SHA-256 of its bytes
report    CSV, charts, and a markdown report for a batch
synth     synthetic images with known ground truth (used by the tests and `iqa demo`)
"""

__version__ = "0.1.0"

# Bump whenever a change to the measurement code (imageio, sfr, edges, noise, exposure, structure,
# uncertainty, analyze, fingerprint) changes any output, so the memory measures every photo again
# instead of reusing numbers from the old method. tests/test_memory_tripwire.py hashes the code of
# those modules and fails on any change until this is bumped or the hash is re-pinned (re-pin only
# after confirming the outputs are identical). Docstrings and comments are not hashed.
MEASUREMENT_VERSION = 1
