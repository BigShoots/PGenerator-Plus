# PGenerator Deploy Console

A local-only browser dashboard for comparing tracked source files with a
running Pi, uploading selected differences, and restarting the pattern
renderer.

## Run

From the repository root:

```sh
./local-deployer/run.sh
```

The dashboard opens at `http://127.0.0.1:8765`. Use `--no-open` if you do not
want it to launch a browser, or `--port 9000` to choose another local port.

The host computer needs `ssh`, `scp`, and `sshpass` when password
authentication is used. Leave the password blank to use an existing SSH key.

## Safety behaviour

- Only tracked regular files below `etc/`, `lib/`, `usr/`, and `var/` are
  compared. Repository screenshots, build sources, tests, and helper scripts
  are never offered for upload.
- Upload and restart actions are refused while meter, calibration, chartread,
  or colprof processes are active.
- Selected Perl files receive a local `perl -c` syntax check before upload.
- Existing remote files are backed up with their directory structure under
  `/root/pgen-backups/<timestamp>/`.
- Uploading does not restart anything. The separate renderer button calls the
  Pi's `/api/restart` endpoint and verifies that `PGeneratord` returns.
- The web server binds only to `127.0.0.1`; entered credentials are kept in the
  browser tab and are not written to disk.
