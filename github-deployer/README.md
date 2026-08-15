# PGenerator GitHub Deploy Console

A local browser dashboard that downloads a pinned GitHub repository snapshot,
compares its deployable files with a running PGenerator Pi, and uploads selected
updates.

## Run on Linux

```sh
./github-deployer/run.sh
```

The dashboard opens at `http://127.0.0.1:8766`. Pass `--no-open` to prevent the
browser from opening or `--port 9001` to use another port.

Stop a running dashboard with:

```sh
./github-deployer/kill-server.sh
```

The Linux computer running the dashboard needs Python 3, `ssh`, `scp`, and `sshpass`.
The standard PGenerator root password is prefilled. Clear it to use an existing
SSH key instead.

## Run on Windows

Extract `PGenerator-GitHub-Deployer-Windows.zip`, then double-click
`run-windows.bat`. The Windows x64 package includes its own Python runtime and
SSH support. Windows does not need a Python installation, `sshpass`, PuTTY, WSL,
Perl, or Git.

Stop it with `kill-server-windows.bat`. See `README-WINDOWS.md` for the complete
Windows instructions.

## Run on macOS

Open `PGenerator-GitHub-Deployer-macOS.dmg`, drag the folder anywhere (the
Desktop is fine), then double-click `run-macos.command` (right-click and Open on the first launch, since the
package is not notarized). The Apple Silicon package includes its own Python
runtime and SSH support; macOS needs no Python installation, Homebrew, or
`sshpass`. Stop it with `kill-server-macos.command`. See `README-MACOS.md`
for the complete macOS instructions. Rebuild the package from this directory
with `./build-macos-package.sh`, and the disk image with
`./build-macos-dmg.sh`. The zip remains available for command-line use.

## GitHub access

The default source is `BigShoots/PGenerator-Plus` on `main`. Public repositories
do not require a token. A token can be entered for private repositories or to
avoid unauthenticated API rate limits. Tokens are used for the current request
only and are never written to disk or browser storage.

Each scan resolves the requested branch, tag, or commit to one exact commit.
Uploads continue using that pinned snapshot even if the branch changes later.
Scan again to fetch newer GitHub files.

## Safety behavior

- Only regular files below `etc/`, `lib/`, `usr/`, and `var/` are considered.
- Device configuration, first-boot markers, runtime command files, and
  repository placeholders are protected from upload.
- Existing Pi ownership and permissions are preserved.
- Existing Pi files are backed up under `/root/pgen-backups/<timestamp>-github/`.
- Downloaded Perl files receive a `perl -c` check before upload. It runs on the
  computer hosting this dashboard, not on the Pi, so Perl must be installed
  here and a file that `use`s a module missing locally will fail the check even
  though the Pi has it.
- Uploading does not restart services. Use Restart daemon for Perl modules and
  Restart renderer for renderer-only changes.
- The server binds only to `127.0.0.1`.
- The last Pi address is saved in browser local storage. The standard SSH
  password is built into this private tool. GitHub tokens are never saved.

This directory is excluded through `.git/info/exclude` and remains untracked.
