PGenerator+ ICC Tools for Windows
=================================

Windows installer: run the downloaded EXE. It contains its PGenerator+ pairing
information and installs both the patch companion and the tray profile loader.
Start Menu shortcuts and an uninstaller are included.

Portable Windows patch companion: extract the ZIP and keep
PGenICCCompanion.conf beside PGenICCCompanion.exe. This package does not
contain the Profile Loader.

PGenerator+ ICC Companion
=========================

This package is paired with the PGenerator+ from which it was downloaded.

1. Keep PGenICCCompanion.conf beside the executable.
2. Enable HDR in the operating system before starting an HDR profile.
3. Run PGenICCCompanion. It initially opens in a movable, resizable window.
   Use the ICC Profile workspace to switch it live between a resizable window
   and borderless fullscreen output. In fullscreen mode, the WebUI Patch Size
   setting controls centered window and APL patterns.
   Use the white crosshair on the black alignment screen to center the meter.
4. Return to the PGenerator+ WebUI from another screen or device and start the
   ICC profile measurements.
5. Press F11 if you need to override fullscreen locally. Press Escape to exit.

On KDE/Linux, extract the package with the desktop archive manager. If the
executable bit is not preserved, run `chmod +x PGenICCCompanion` once before
starting it. The Linux build requires a modern x86-64 distribution with
glibc 2.38 or newer. KDE HDR profiles require Plasma 6.7 or newer, a Wayland
session, HDR enabled for the display, and an HDR-capable SDL renderer. While an
HDR patch is displayed, the WebUI connection status must report native HDR as
active. The measurement stops instead of silently profiling an SDR conversion
if the companion cannot create a native HDR output surface.

The companion must remain connected for the entire measurement run. PGenerator+
waits for each patch to be presented before it asks the meter to read. The
alignment target returns whenever profiling finishes, is stopped, or fails.

For post-profile verification, the WebUI can leave patches unmodified for the
operating-system profile pipeline, apply a selected profile's BToA cLUT inside
the Companion, or apply its matrix and tone-curve fallback. Do not leave the
same system correction active while using either application-managed mode,
because that would apply two corrections to the measurement patches.

Windows may show a SmartScreen warning because this build is not code-signed.
The application communicates only with the PGenerator+ address embedded in the
configuration file.

The Windows package also contains PGenProfileLoader.exe. It is a separate tray
application for installing, applying, and continuously verifying a display
profile. See PROFILE-LOADER-README.txt for setup and status details. The
profile loader does not need PGenICCCompanion.conf and can remain running when
the patch generator is closed.
