PGenerator+ Profile Loader for Windows
======================================

PGenProfileLoader runs in the Windows notification area and verifies the
selected profile for one active display.

1. Run PGenProfileLoader.exe.
2. Select the display and choose an ICC or ICM profile.
3. Click Install and apply. Windows may request administrator permission to
   install the profile in its color profile directory.
4. Leave Automatically reapply enabled if you want the loader to restore the
   association after display, HDR, GPU, or Windows setting changes.
5. Enable Start with Windows if you want verification to begin at sign-in.

A green tray icon means Windows reports the selected file as the display's
active default. A red icon means the profile is missing, the display is not
available, or Windows reports another default. Right-click the tray icon to
reapply the profile or open Windows Color Profile settings.

For a profile containing an MHC2 tag, Windows applies the correction through
the Advanced Color system pipeline. For an ordinary ICC profile, the loader
verifies the display association used by color-managed applications. An
ordinary ICC profile is not a system-wide correction.

Windows 10 build 20348 or newer is required for reliable per-display profile
association and verification. Windows 11 is recommended for Advanced Color.

Windows may show a SmartScreen warning because this build is not code-signed.
