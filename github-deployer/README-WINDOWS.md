# PGenerator GitHub Deploy Console for Windows

## Requirements

- Windows 10 or Windows 11
- 64-bit Intel or AMD processor
- Internet access when fetching GitHub files
- Network access to the PGenerator Pi

Python and the Windows SSH dependencies are included inside the package.
Windows does not need a Python installation, `sshpass`, PuTTY, WSL, Perl, or
Git for this deployer.

## Start

Double-click `run-windows.bat`.

The dashboard opens at `http://127.0.0.1:8766`.

To use another port from Command Prompt:

```bat
run-windows.bat --port 9001
```

Keep the console window open while using the dashboard. Closing the console
normally stops the dashboard.

## Stop

Double-click `kill-server-windows.bat`. It can stop the dashboard even if its
original console window is no longer open.

## Notes

- The Pi address has no default. It is remembered by the browser after entry.
- The standard PGenerator root password is prefilled.
- Before the first deploy, add the Pi's SSH host key so the console can verify
  it. Verify the fingerprint on the Pi (`ssh-keygen -lf
  /etc/ssh/ssh_host_ed25519_key.pub`), then in the app folder run:

  ```bat
  copy known_hosts.example known_hosts
  ssh-keyscan <pi-address> >> known_hosts
  ```

  `ssh-keyscan` ships with the OpenSSH Client (Windows Settings > Optional
  features). If it is not installed, run the command on any other machine and
  paste its output into `known_hosts`. Unknown or changed host keys are
  refused, never auto-accepted.
- Public GitHub repositories do not need a token.
- GitHub tokens are used only for the current request and are not saved.
- Perl files are syntax-checked on the Pi before any existing file is replaced.
