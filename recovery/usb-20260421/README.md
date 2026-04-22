USB recovery artifacts copied from /media/jordan/__PG on 2026-04-21.

DV chart code findings

- webui-backups/webui.pm.bak.20260419_175603 contains the old DV target-selection path:
  - meterGreyStimulusFraction keeps the gamma-2.2 DV tunnel-code generation.
  - meterGreyTargetSignal uses nominal IRE for DV: if(meterChartIsDv()) return nominal;
  - meterGreyTargetLuminance uses meterChartTargetLuminance(signal, peak, Lb || 0).
- webui-backups/webui.pm.bak.1776744163 contains the older DV tracking/plotting branch:
  - meterChartTrackingLuminance uses Math.min(meterChartPqDecodeNormalized(clamped), peak) for DV.
  - meterGreyTargetEotfValue and meterGreyMeasuredEotfValue include DV in the PQ-encoded path.
- No single USB webui backup in this image contained all of the desired old DV chart behaviors in one file. The useful logic is split across these two snapshots.

CalMAN range binary preservation

- binaries/PGeneratord.pre-dv-range-binary-fix.20260421_045944 is the strongest candidate by name and timestamp.
- binaries/PGeneratord.rebuilt_869563d4.backup was also preserved because it has the same reduced size class and may be the same or adjacent rebuild.
- Both binaries are ARM ELF executables with debug info and not stripped.

Next use

- Use the webui backups as authoritative USB references when reconciling DV EOTF, luminance, gamma target, and plotting behavior.
- Use the preserved binaries for diffing or extracting the CalMAN range-support implementation later.
