You are reviewing the repository iq-analyzer. Read CLAUDE.md and README.md first.

Act as a senior camera image-quality engineer reading this as a job-application portfolio piece. Review for correctness and methodology:
1. iqa/sfr.py against ISO 12233:2014 e-SFR: edge localisation, line fit, 4x oversampled ESF binning, Hamming window, derivative correction, the MTF50 / MTF50P / MTF30 definitions, and the Gaussian ground-truth formula in gaussian_mtf50.
2. iqa/noise.py: gradient removal, the texture-rejection ratio, the lower-envelope noise floor, SNR at mid-grey, chroma noise, and the dynamic-range estimate through the sRGB EOTF slope.
3. iqa/edges.py: candidate detection and the quality filters; whether the 80th-percentile "in-focus" summary is defensible.
4. tests/: whether the tests would actually catch the bugs that matter; what is untested.

Run the tests with: .venv/bin/python -m pytest -q

Write your findings to REVIEW.md in the repo root with three sections: (1) Correctness issues, ranked by severity, each with file and line and a concrete fix; (2) Methodology caveats a reviewer would raise; (3) The five changes that would most increase credibility with a hiring engineer. Be specific and brief. Do not modify any file other than REVIEW.md.
