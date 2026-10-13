"""iqa — image-quality analysis for real photographs.

Modules
-------
imageio   load RAW / JPEG / HEIC / PNG / TIFF into linear and display-referred arrays + EXIF
sfr       ISO 12233-style slanted-edge SFR / MTF (the sharpness measurement)
edges     find natural slanted edges in a photo and measure them
noise     flat-patch noise, SNR, and an output-referred dynamic-range estimate
exposure  clipping, tonal statistics, colorfulness, gray-world white balance
analyze   run everything on one image
report    CSV, charts, and a markdown report for a batch
synth     synthetic images with known ground truth (used by the tests and `iqa demo`)
"""

__version__ = "0.1.0"
