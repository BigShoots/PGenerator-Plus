# PGenerator GitHub Deploy Console for macOS

## Requirements

- macOS 11 or newer on Apple Silicon
- Internet access when fetching GitHub files
- Network access to the PGenerator Pi

Python and the SSH support are included inside the package. macOS does not
need a Python installation, Homebrew, `sshpass`, or Git for this deployer.
Connections to the Pi use the bundled SSH library, so the prefilled root
password works without any extra tools.

## Start

Open the disk image and drag the `PGenerator-GitHub-Deployer` folder to any
location, such as the Desktop. The dashboard writes its PID file next to
`server.py`, so it must run from a normal folder rather than inside the
read-only disk image. Then double-click `run-macos.command`.

Because the package is not notarized, the first launch may be blocked by
Gatekeeper. Either right-click `run-macos.command` and choose Open, or clear
the quarantine flag once from Terminal:

```sh
xattr -dr com.apple.quarantine "PGenerator-GitHub-Deployer"
```

The dashboard opens at `http://127.0.0.1:8766`.

To use another port from Terminal:

```sh
./run-macos.command --port 9001
```

Keep the Terminal window open while using the dashboard. Closing it normally
stops the dashboard.

## Stop

Double-click `kill-server-macos.command`. It can stop the dashboard even if
its original Terminal window is no longer open.

## Notes

- The Pi address has no default. It is remembered by the browser after entry.
- The standard PGenerator root password is prefilled.
- Public GitHub repositories do not need a token.
- GitHub tokens are used only for the current request and are not saved.
- Perl files are syntax-checked on the Pi before any existing file is replaced.
