#!/usr/bin/env python3
"""Stop hook: a `pgen-pi snapshot` of this project is still open, so the
user's signal settings may not be back (CLAUDE.md: "Give the user's signal
settings back at the end of a test"). Blocks the stop once per turn with
what to do; a second stop in the same turn (stop_hook_active) goes through,
so a hand-over in the middle of a test (the user looks at the TV) stays
possible: say so in the reply.

Fails open: an error is reported on stderr (exit 1, non-blocking).
"""
import json, os, sys, time

STATE = os.path.join(os.environ.get("PGEN_PI_STATE_DIR", os.path.expanduser("~/.local/state/pgen-pi")), "state.json")


def main():
    data = json.load(sys.stdin)
    if data.get("stop_hook_active"):
        return
    try:
        with open(STATE) as f:
            snap = json.load(f).get("snapshot")
    except (OSError, ValueError):
        return
    if not snap:
        return
    project = os.path.realpath(os.environ.get("CLAUDE_PROJECT_DIR") or data.get("cwd") or os.getcwd())
    # The checkout pgen-pi names (repo), as pgen-pi and the guard judge it;
    # the directory it ran in only for records without it (a session that
    # cd'd elsewhere and ran pgen-pi by its full path is still this one).
    if snap.get("repo"):
        if os.path.realpath(str(snap["repo"])) != project:
            return
    else:
        where = os.path.realpath(snap.get("cwd") or "")
        if where != project and not where.startswith(project + os.sep):
            return
    print(json.dumps({"decision": "block", "reason": (
        "pi_stop: snapshot %s on the Pi is open (%d min): the user's settings may not be back. "
        "Run `.claude/skills/pi/scripts/pgen-pi restore` (or `pgen-pi diff` to see what changed). "
        "If the test goes on in a later turn (waiting for the user at the TV), say that in the reply and stop again; "
        "if the change is meant to stay, `pgen-pi snapshot --close REASON`."
        % (snap.get("label"), (time.time() - snap.get("time", time.time())) / 60))}))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        sys.stderr.write("pi_stop error: %s: %s\n" % (type(e).__name__, e))
        sys.exit(1)
