# 3D LUT profile capture (hybrid)

- Captured: 2026-07-17T15:05:01-0500
- Run status: complete phase=complete
- Method: hybrid
- Signal: sdr / bt709 / bt1886
- Profile patches stored: 63 (of 63)

## Files

- hybrid_profile_capture.json — full capture (readings + config + meta)
- solve_only_payload.json — body for re-solve via /api/3d-lut/solve
- lattice_readings.csv — XYZ by patch name
- meter_lg_3d_autocal.json — last raw worker state
- meter_lg_3d_autocal_config.json — worker config
- meter_lg_3d_autocal.log — worker log

## Re-solve without re-measuring

```bash
curl -sS -X POST http://PI/api/3d-lut/solve \
  -H 'Content-Type: application/json' \
  --data-binary @solve_only_payload.json
curl -sS http://PI/api/3d-lut/solve/status
```

Corner requirements for residual solve: 100/100/100, 100/0/0, 0/100/0, 0/0/100 (and ideally 0/0/0).
