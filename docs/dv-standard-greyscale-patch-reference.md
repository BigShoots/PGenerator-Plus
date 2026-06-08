# DV Standard Greyscale Patch Reference

Captured DV standard absolute and relative greyscale runs used 8-bit RGB tunnel patch codes in legal/video range.

## 21-point greyscale ramp

| Stimulus | Raw 10-bit RGB | Scaled 8-bit RGB |
| --- | --- | --- |
| 0% | 64 | 16 |
| 5% | 108 | 27 |
| 10% | 152 | 38 |
| 15% | 196 | 49 |
| 20% | 240 | 60 |
| 25% | 284 | 71 |
| 30% | 328 | 82 |
| 35% | 372 | 93 |
| 40% | 416 | 104 |
| 45% | 460 | 115 |
| 50% | 504 | 126 |
| 55% | 544 | 136 |
| 60% | 588 | 147 |
| 65% | 632 | 158 |
| 70% | 676 | 169 |
| 75% | 720 | 180 |
| 80% | 764 | 191 |
| 85% | 808 | 202 |
| 90% | 852 | 213 |
| 95% | 896 | 224 |
| 100% | 940 | 235 |

## Notes

- Absolute mode keeps ST 2084 as the target curve; the values above are the RGB tunnel patch codes sent over HDMI.
- Relative mode uses the same legal RGB tunnel patch ramp, with relative/gamma-style target analysis.
- Full-screen pattern insertion/background events appeared between windowed greyscale patches and should not be treated as greyscale ramp values.
- Absolute capture path: `/tmp/pgen-calman-absolute-precal-20260607-231852/calman-patches.delta.log`.
- Relative capture path: `/tmp/pgen-calman-relative-calibration-20260607-232411/calman-patches.delta.log`.
