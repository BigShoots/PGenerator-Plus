PGenerator ICC Companion
========================

This package is paired with the PGenerator from which it was downloaded.

1. Keep PGenICCCompanion.conf beside the executable.
2. Enable HDR in the operating system before starting an HDR profile.
3. Run PGenICCCompanion. It opens in a movable, resizable window. Each patch
   fills the entire window, so resize the window to set the patch dimensions.
   Use the alignment target shown at startup to center the meter.
4. Return to the PGenerator WebUI from another screen or device and start the
   ICC profile measurements.
5. Press F11 if you want to toggle full-screen. Press Escape to exit.

On KDE/Linux, extract the package with the desktop archive manager. If the
executable bit is not preserved, run `chmod +x PGenICCCompanion` once before
starting it. The Linux build requires a modern x86-64 distribution with
glibc 2.38 or newer.

The companion must remain connected for the entire measurement run. PGenerator
waits for each patch to be presented before it asks the meter to read. The
alignment target returns whenever profiling finishes, is stopped, or fails.

Windows may show a SmartScreen warning because this build is not code-signed.
The application communicates only with the PGenerator address embedded in the
configuration file.
