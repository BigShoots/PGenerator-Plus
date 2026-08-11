PGenerator+ Profile Loader for Windows
======================================

PGenProfileLoader runs in the Windows notification area and verifies the
selected profile for one active display.

1. Run PGenProfileLoader.exe.
2. Select the display and choose an ICC or ICM profile.
3. Click Install and apply. Windows may request administrator permission to
   install the profile in its color profile directory.
4. Profiles already associated with the selected display are shown in the
   display profile list. Select one and click Set as default to switch the
   Windows default without reinstalling it. Current SDR and HDR defaults are
   identified separately.
5. Leave Automatically reapply enabled if you want the loader to restore the
   association after display, HDR, GPU, or Windows setting changes.
6. Enable Start with Windows if you want verification to begin at sign-in.

The PGenerator+ WebUI can also send a completed profile through a connected
Patch Companion. Profile Loader targets the display being used for patches,
installs and applies the ICC through this same controlled path, saves the
monitor/profile pairing, and reports the verification result from the tray
without forcing the Profile Loader window open. Applying a profile also enables
"Use my settings for this device" in Windows Color Management so the per-user
profile list is active.

A green tray icon means Windows reports the selected file as the display's
active default. A red icon means the profile is missing, the display is not
available, or Windows reports another default. Right-click the tray icon to
reapply the profile or open Windows Color Profile settings.

The Windows color settings button opens System > Display > Color management on
supported Windows 11 builds. Older builds fall back to Display settings or the
classic Color Management control panel.

For a profile containing an MHC2 tag, Windows applies the correction through
the Advanced Color system pipeline. For an ordinary ICC profile, the loader
verifies the display association used by color-managed applications. An
ordinary ICC profile is not a system-wide correction.

Windows 10 build 20348 or newer is required for reliable per-display profile
association and verification. Windows 11 is recommended for Advanced Color.

Windows may show a SmartScreen warning because this build is not code-signed.
