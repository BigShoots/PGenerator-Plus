PGenerator+ ICC Tools
=====================

Windows installer: run the downloaded EXE. It installs both the patch
companion and the tray profile loader, with Start Menu shortcuts and an
uninstaller.

Portable packages: extract the ZIP and run the programs from where they land.
Nothing is installed and nothing is written outside that folder.

Pairing
=======

A copy downloaded from a PGenerator+ arrives already paired with that unit and
needs nothing from you.

A copy downloaded from the GitHub releases page is the same file for everyone,
so it pairs itself the first time it runs:

1. It finds your PGenerator+ by resolving the name pgenerator.local.
2. It shows a six-digit code and waits. The same request and code appear in
   the PGenerator+ WebUI beside the Patch Companion status.
3. Approve it there, once. The companion saves the result and never asks
   again.

If the name cannot be resolved -- more than one PGenerator+ on the network, a
routed network, or mDNS blocked -- give the address explicitly instead, either
as a line reading SERVER=http://<address> in PGenICCCompanion.conf beside the
executable, or by starting the companion with --server=http://<address>. A
SERVER set that way always wins over discovery.

PGenerator+ Patch Companion
==========================

1. If a PGenICCCompanion.conf came with this package, keep it beside the
   executable.
2. Enable HDR in the operating system before starting an HDR profile.
3. Run PGeneratorPlusPatchCompanion.exe. It initially opens in a movable, resizable window.
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
HDR10 patches are rendered as the native 10-bit PQ/BT.2020 code values sent by
PGenerator+. The Companion also forwards the configured HDR10 mastering and
content-light metadata to DXGI. It does not add its own PQ encoding or tone-map
roll-off.

For post-profile verification, the WebUI can leave patches unmodified for the
operating-system profile pipeline, apply the active display profile's BToA cLUT
inside the Companion, or apply its matrix and tone-curve fallback. The active
profile is read and evaluated locally on the selected Windows display. It is
never transferred to PGenerator+. Do not leave the same MHC2 system correction
active while using either application-managed mode, because that would apply
two corrections to the measurement patches.

Windows may show a SmartScreen warning because this build is not code-signed.
The application communicates only with the one PGenerator+ it is paired with.

PGenerator+ Profile Loader (Linux)
==================================

The Linux package also contains PGenProfileLoader, the counterpart to the
Windows profile loader. It installs a finished PGenerator+ profile and applies
it to a display, for SDR and HDR alike. Run `chmod +x PGenProfileLoader` if the
executable bit was not preserved, then start it beside the companion; it does
not need PGenICCCompanion.conf.

Pick the display, pick the profile, and press Apply to display. That single
action does the whole job: a profile still sitting in a download folder is
copied into your personal ICC directory (~/.local/share/icc) first, then
assigned to the display. Copy to system folder is only for making a profile
available to every user account, and is the one action that asks for
administrator rights.

On a KDE Plasma Wayland session the compositor owns the display profile, and
the loader applies it through kscreen-doctor. colord is not involved there:
KWin does not register its outputs with it, so colord lists no display device.
That is normal and needs no action. On X11 sessions and other desktops the
loader falls back to colord, and offers to install `colord colord-kde` if it is
missing. Privileged steps go through pkexec; the exact command is always shown
so it can be run by hand instead. The loader itself never needs to run as root.

An HDR profile only describes the display in HDR mode, so enable HDR for that
display before applying one; the loader says so if the two do not match. The
window follows the desktop's colour scheme.

The Windows packages also contain PGenProfileLoader.exe. It is a separate tray
application for installing, applying, and continuously verifying a display
profile. See PROFILE-LOADER-README.txt for setup and status details. The
profile loader needs no pairing at all and can remain running when the patch
generator is closed.
