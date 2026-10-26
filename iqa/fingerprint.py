"""dHash256: a perceptual fingerprint of the displayed picture, for advisory near-duplicate grouping.

Advisory only, never an identity. The memory reuses a measurement only when the SHA-256 of the
file's bytes matches (docs/MEMORY-SPEC.md section 3), because a perceptual match means "the same
picture" precisely when the image-quality numbers differ: on her own photos a sigma-0.7 blur moved
MTF50 by -18.5 % (median) while dHash stayed at distance 0-1, and burst frames taken 0.67 s apart
hash alike. The hash is stored so near-duplicate and burst grouping can be built later.

Method (docs/MEMORY-RESEARCH.md): the display-oriented 8-bit picture is converted to grey with
Pillow's ITU-R 601-2 luma, reduced to 256 x 256 with a box filter (an area average, so the result
does not depend on the decode size), then to 17 x 16 with Lanczos. Each of the 16 rows gives 16
bits, one per pair of horizontal neighbours, set when the left pixel is darker than the right;
rows are read top to bottom, bits most significant first, 64 hex digits in all. Compare hashes
only within one pipeline: a Swift ImageIO thumbnail differs from this full decode by up to 16 bits.

A flat image has no darker-left pairs, so its hash is all zeros: equal neighbours set no bit. Any
low-contrast frame (fog, a blank wall) drifts towards zero, so a match between two such hashes
says little.
"""
from __future__ import annotations

HASH_BITS = 256


def dhash256(rgb8) -> str:
    """dHash256 of an 8-bit RGB (H x W x 3) array or a PIL image, as 64 lowercase hex digits."""
    from PIL import Image
    im = rgb8 if isinstance(rgb8, Image.Image) else Image.fromarray(rgb8)
    grey = im.convert("L").resize((256, 256), Image.Resampling.BOX)
    small = grey.resize((17, 16), Image.Resampling.LANCZOS).tobytes()
    bits = 0
    for y in range(16):
        row = small[17 * y:17 * (y + 1)]
        for x in range(16):
            bits = (bits << 1) | (row[x] < row[x + 1])
    return f"{bits:064x}"


def hamming(a: str, b: str) -> int:
    """Number of differing bits between two hex hashes of the same length."""
    return (int(a, 16) ^ int(b, 16)).bit_count()
