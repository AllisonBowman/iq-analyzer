# iqa demo on synthetic scenes

Generated 2026-10-13 02:03 by iqa on 4 images.

## Summary

| metric | median | min | max | n |
| --- | --- | --- | --- | --- |
| In-focus sharpness, MTF50 (cycles/px) | 0.171 | 0.120 | 0.236 | 3 |
| Overall sharpness, MTF50 (cycles/px) | 0.169 | 0.118 | 0.233 | 3 |
| Edge 10-90 % rise (px) | 3.25 | 2.38 | 4.25 | 3 |
| SNR at mid-grey (dB) | 31.6 | 24.2 | 40.5 | 4 |
| Luma noise at mid-grey (8-bit std) | 3.29 | 1.12 | 7.31 | 4 |
| Chroma noise at mid-grey (8-bit std) | 6.24 | 2.12 | 13.87 | 4 |
| Dynamic range @ SNR 4 (stops, output-referred) | 5.5 | 4.6 | 5.5 | 4 |
| Highlight clipping (% pixels) | 1.46 | 1.41 | 1.53 | 4 |
| Shadow clipping (% pixels) | 0.42 | 0.26 | 0.92 | 4 |
| Colorfulness (Hasler-Suesstrunk) | 11.3 | 6.5 | 21.1 | 4 |

Edges were found and measured in 3 of 4 images. Images without usable slanted edges (open water, sky, bokeh) have no sharpness figure.

## Sharpest images (MTF50, 80th percentile of edges)

| file | MTF50 c/px | camera | ISO |
| --- | --- | --- | --- |
| scene_sigma0.8_noise1.5.png | 0.236 |  |  |
| scene_sigma1.1_noise3.0.png | 0.171 |  |  |
| scene_sigma1.6_noise6.0.png | 0.120 |  |  |

## Softest images

| file | MTF50 c/px | camera | ISO |
| --- | --- | --- | --- |
| scene_sigma1.6_noise6.0.png | 0.120 |  |  |
| scene_sigma1.1_noise3.0.png | 0.171 |  |  |
| scene_sigma0.8_noise1.5.png | 0.236 |  |  |

## Cleanest images (SNR at mid-grey)

| file | SNR dB | camera | ISO |
| --- | --- | --- | --- |
| scene_sigma0.8_noise1.5.png | 40.5 |  |  |
| scene_sigma1.1_noise3.0.png | 34.6 |  |  |
| scene_sigma1.6_noise6.0.png | 28.6 |  |  |
| scene_sigma2.4_noise10.0.png | 24.2 |  |  |

## Noisiest images

| file | SNR dB | camera | ISO |
| --- | --- | --- | --- |
| scene_sigma2.4_noise10.0.png | 24.2 |  |  |
| scene_sigma1.6_noise6.0.png | 28.6 |  |  |
| scene_sigma1.1_noise3.0.png | 34.6 |  |  |
| scene_sigma0.8_noise1.5.png | 40.5 |  |  |

## Most highlight clipping

| file | % clipped | camera | ISO |
| --- | --- | --- | --- |
| scene_sigma0.8_noise1.5.png | 1.53 |  |  |
| scene_sigma1.1_noise3.0.png | 1.49 |  |  |
| scene_sigma1.6_noise6.0.png | 1.44 |  |  |
| scene_sigma2.4_noise10.0.png | 1.41 |  |  |

## Charts

![mtf50_hist.png](charts/mtf50_hist.png)

![snr_hist.png](charts/snr_hist.png)

![clip_hist.png](charts/clip_hist.png)

![noise_curves.png](charts/noise_curves.png)

## How to read these numbers

- **MTF50** is the spatial frequency (cycles per pixel) at which contrast falls to 50 %. Higher is sharper; 0.25-0.35 is very sharp (often sharpened), 0.10-0.15 is soft. Measured on natural slanted edges with the ISO 12233 e-SFR method, so treat it as a consistent *relative* measure rather than a chart-grade absolute.
- **SNR at mid-grey** is 20·log10(118 / noise std) on the 8-bit luminance of flat patches; 35+ dB is clean, below 25 dB is visibly noisy.
- **Dynamic range** is output-referred: the stops between near-white and the darkest level whose scene-linear SNR still exceeds the threshold. A JPEG's tone curve bounds it; a 'lower bound' flag means the image had no shadows dark enough to find the floor.
- **Clipping** is the share of pixels at the top (any channel >= 254) or bottom (all channels <= 1) of the range.
