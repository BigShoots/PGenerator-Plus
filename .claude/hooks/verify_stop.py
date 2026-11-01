#!/usr/bin/env python3
"""Stop hook: the fast checks of CLAUDE.md "Verify after a change" on the
files changed in this session, before a turn ends.

1. Syntax: a file changed in this session does not parse. Only checks that
   run nothing from the tree: WebUI JavaScript (compiled by vm.Script, not
   run), Python (ast and tokenize inside this process), shell (bash -n).
   The hook runs outside the Bash sandbox, so it never runs code a sandboxed
   command could have written: no Perl on the tree (perl -c runs BEGIN
   blocks and `use`), no git (the repo config can name commands:
   core.fsmonitor, filters), no symlinked files. Perl is left to 2.
2. Tests: a code file under usr/, src/, etc/ or the project's hook and pi
   scripts was changed in this turn after the last test run (a `prove` or a
   tools/repro_old_new.sh command in a Bash call of this session; text in
   quotes or a heredoc does not count); changed Perl files are named with
   the perl -c they still need. The transcript can lag at stop time, so it
   is read again once before the hint is given.

Both go into one block, once per turn: a stop with stop_hook_active goes
through, so a turn can end with an explained reason ("waiting for the
user", "half-done on purpose"). What is still open (files that do not
parse, code changed after the last test run) is then named in a
systemMessage for the user, as are checks that could not run (no node, a
timeout).

"Changed in this session" is an mtime after the transcript's first entry;
"this turn" starts at the first transcript entry of the hook's prompt_id.
Without a readable transcript nothing is checked. Python under usr/ and
pi_state.py (pgen-pi runs it on the Pi) are checked as Python 3.5:
ast.parse(feature_version=(3,5)) plus a token scan for f-/t-strings, which
ast on a new Python accepts. ast on a new Python also accepts some other
post-3.5 syntax (async generators, await in comprehensions, parenthesised
context managers, relaxed decorators, a trailing comma after **kwargs,
`return 1, *a`, `a[*b]`, `continue` in finally) and no stdlib use is checked: py_compile on the Pi stays
the binding check.

An error of the hook itself goes to stderr (exit 1, non-blocking), so a
broken hook never holds a turn; settings.json maps a missing hook file
(python3 exits 2, which on Stop would block) to exit 1 as well.
"""
import ast, calendar, io, json, os, re, subprocess, sys, tempfile, time, tokenize

WALK = ("usr", "src", "etc", ".claude/hooks", ".claude/skills/pi/scripts")
CODE_PREFIXES = ("usr/", "src/", "etc/", ".claude/hooks/", ".claude/skills/pi/scripts/")
SYNTAX_PREFIXES = ("usr/", "etc/", ".claude/hooks/", ".claude/skills/pi/scripts/")
PI_PYTHON = (".claude/skills/pi/scripts/pi_state.py",)  # pgen-pi runs it on the Pi
SKIP_DIRS = {".git", "__pycache__", "node_modules"}
TIMEOUT = 20
SEGMENT_SPLIT = re.compile(r"&&|\|\||[;|&\n()`]|\$\(")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
QUOTED = re.compile(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"")


def strip_text(command):
    """The command without heredoc bodies and quoted strings: `prove` in a
    commit message, an echo or a script fed to python is no test run."""
    lines, out, end = command.split("\n"), [], None
    for line in lines:
        if end is not None:
            if line.strip() == end:
                end = None
            continue
        m = HEREDOC.search(line)
        if m:
            end = m.group(2)
        out.append(line)
    return QUOTED.sub("''", "\n".join(out))


def runs_tests(command):
    """True if a segment of a shell command starts `prove` or the repro script."""
    for seg in SEGMENT_SPLIT.split(strip_text(command or "")):
        words = seg.split()
        while words and (ASSIGNMENT.match(words[0]) or words[0] in ("env", "time", "nice", "exec")):
            words.pop(0)
        if not words:
            continue
        first = os.path.basename(words[0])
        if first == "prove" or first == "repro_old_new.sh":
            return True
        if first in ("bash", "sh") and len(words) > 1 and os.path.basename(words[1]) == "repro_old_new.sh":
            return True
    return False


def changed_since(root, since):
    """Regular files (not symlinks) under WALK with an mtime after `since`."""
    files = []
    for top in WALK:
        base = os.path.join(root, top)
        if os.path.islink(base) or not os.path.isdir(base):
            continue
        for d, dirs, names in os.walk(base):
            dirs[:] = [x for x in dirs if x not in SKIP_DIRS and not os.path.islink(os.path.join(d, x))]
            for n in names:
                p = os.path.join(d, n)
                try:
                    if os.path.islink(p) or not os.path.isfile(p) or os.path.getmtime(p) <= since:
                        continue
                except OSError:
                    continue
                files.append(os.path.relpath(p, root).replace(os.sep, "/"))
    return sorted(set(files))


def first_line(path):
    try:
        with open(path, "rb") as f:
            return f.readline(256).decode("latin-1")
    except OSError:
        return ""


def kind_of(rel, path):
    head = first_line(path)
    shebang = head if head.startswith("#!") else ""
    if rel.endswith(".pm") or re.search(r"perl", shebang):
        return "perl"
    if not rel.startswith(SYNTAX_PREFIXES):
        return None
    if rel.endswith(".js") and rel.startswith("usr/"):
        return "js"
    if rel.endswith(".py") or re.search(r"python", shebang):
        return "py35" if rel.startswith("usr/") or rel in PI_PYTHON else "py"
    if re.search(r"/(ba)?sh\b|env (ba)?sh\b", shebang):
        return "sh"
    return None


def run(cmd):
    # cwd outside the tree: nothing there is picked up by node or bash.
    p = subprocess.run(cmd, cwd=tempfile.gettempdir(), stdin=subprocess.DEVNULL,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=TIMEOUT)
    return p.returncode, p.stdout.decode("utf-8", "replace")


def first_error_line(text):
    for line in text.splitlines():
        if line.strip():
            return line.strip()
    return text.strip()


JS_PARSE = ("new (require('vm').Script)(require('fs').readFileSync(process.argv[1],'utf8'),"
            "{filename:process.argv[1]})")


def check_js(path):
    try:
        rc, out = run(["node", "-e", JS_PARSE, path])
    except FileNotFoundError:
        return ("note", "not checked, node not found")
    if rc == 0:
        return None
    lines = [l for l in out.splitlines() if "Error" in l]
    return ("error", (lines[0] if lines else first_error_line(out)).strip())


def check_py35(path):
    with open(path, "rb") as f:
        src = f.read()
    try:
        ast.parse(src, filename=path, feature_version=(3, 5))
    except SyntaxError as e:
        return ("error", "line %s: %s (Python 3.5)" % (e.lineno, e.msg))
    except ValueError as e:
        return ("error", str(e))
    # ast on a new Python accepts f-strings even with feature_version=(3,5).
    try:
        for t in tokenize.tokenize(io.BytesIO(src).readline):
            name = tokenize.tok_name.get(t.type, "")
            if name in ("FSTRING_START", "TSTRING_START"):
                return ("error", "line %d: f-/t-string, not Python 3.5" % t.start[0])
            if t.type == tokenize.STRING:
                m = re.match(r"([A-Za-z]*)['\"]", t.string)
                if m and re.search(r"[fFtT]", m.group(1)):
                    return ("error", "line %d: f-/t-string, not Python 3.5" % t.start[0])
    except (tokenize.TokenError, SyntaxError) as e:
        return ("error", "tokenize: %s" % e)
    return None


def check_py(path):
    with open(path, "rb") as f:
        src = f.read()
    try:
        ast.parse(src, filename=path)
    except SyntaxError as e:
        return ("error", "line %s: %s" % (e.lineno, e.msg))
    except ValueError as e:
        return ("error", str(e))
    return None


def check_sh(path):
    # /bin/sh is bash on the Pi image (see the release check).
    rc, out = run(["bash", "-n", path])
    return ("error", first_error_line(out) or "bash -n exited %d" % rc) if rc != 0 else None


CHECKS = {"js": check_js, "py35": check_py35, "py": check_py, "sh": check_sh}


def syntax(root, files):
    """([(file, message)] parse errors, [text] checks that could not run, [perl files])."""
    errors, notes, perl = [], [], []
    for rel in files:
        path = os.path.join(root, rel)
        kind = kind_of(rel, path)
        if kind == "perl":
            perl.append(rel)
            continue
        if not kind:
            continue
        try:
            res = CHECKS[kind](path)
        except subprocess.TimeoutExpired:
            res = ("note", "not checked, timed out after %ds" % TIMEOUT)
        except OSError as e:
            res = ("note", "not checked, %s" % e)
        if res and res[0] == "error":
            errors.append((rel, res[1]))
        elif res:
            notes.append("%s: %s" % (rel, res[1]))
    return errors, notes, perl


def iso_time(s):
    m = re.match(r"(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(\.\d+)?Z?$", s or "")
    if not m:
        return None
    t = calendar.timegm(tuple(int(x) for x in m.groups()[:6]))
    return t + (float(m.group(7)) if m.group(7) else 0.0)


def transcript_times(path, prompt_id):
    """(session start, turn start, start of the last test run) as epoch
    seconds; None for what the transcript does not show."""
    start, turn, last_run = None, None, None
    if not path or not os.path.isfile(path):
        return None, None, None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if not isinstance(d, dict):
                continue
            ts = iso_time(d.get("timestamp"))
            if ts is None:
                continue
            if start is None or ts < start:
                start = ts
            if prompt_id and d.get("promptId") == prompt_id and (turn is None or ts < turn):
                turn = ts
            if d.get("type") != "assistant":
                continue
            content = (d.get("message") or {}).get("content")
            if not isinstance(content, list):
                continue
            for c in content:
                if (isinstance(c, dict) and c.get("type") == "tool_use" and c.get("name") == "Bash"
                        and runs_tests(str((c.get("input") or {}).get("command", "")))):
                    if last_run is None or ts > last_run:
                        last_run = ts
    return start, turn, last_run


def main_checkout(root):
    """The main checkout of a worktree (read from .git, without running git)."""
    dotgit = os.path.join(root, ".git")
    try:
        if os.path.isfile(dotgit):
            with open(dotgit) as f:
                m = re.match(r"gitdir:\s*(.+)", f.read().strip())
            gitdir = os.path.join(root, m.group(1)) if m else None
            with open(os.path.join(gitdir, "commondir")) as f:
                common = os.path.normpath(os.path.join(gitdir, f.read().strip()))
            return os.path.dirname(common)
    except (OSError, TypeError, AttributeError):
        pass
    return root


def listed(items, limit=8):
    return ", ".join(items[:limit]) + (" (+%d more)" % (len(items) - limit) if len(items) > limit else "")


def main():
    data = json.load(sys.stdin)
    root = os.path.realpath(os.environ.get("CLAUDE_PROJECT_DIR") or data.get("cwd") or os.getcwd())
    active = bool(data.get("stop_hook_active"))
    transcript, prompt_id = data.get("transcript_path"), data.get("prompt_id")
    start, turn, last_run = transcript_times(transcript, prompt_id)
    if start is None:
        return
    files = changed_since(root, start)
    if not files:
        return
    errors, notes, _ = syntax(root, files)

    def stale_now():
        since = max(turn or start, last_run or 0)
        return [f for f in files if f.startswith(CODE_PREFIXES) and os.path.getmtime(os.path.join(root, f)) > since]
    stale = stale_now()
    if stale and not errors:
        time.sleep(1)  # the transcript is written asynchronously
        start, turn, last_run = transcript_times(transcript, prompt_id)
        stale = stale_now() if start is not None else []

    out, messages, reasons = {}, [], []
    if errors:
        reasons.append("files changed in this session do not parse (CLAUDE.md \"Verify after a change\"):\n  "
                       + "\n  ".join("%s: %s" % e for e in errors)
                       + "\nFix them. If the turn has to end with them broken, say why in the reply and stop again.")
    if stale:
        # Also next to a parse error: the fix is one more change to test.
        perl = [f for f in stale if kind_of(f, os.path.join(root, f)) == "perl"]
        repro = os.path.join(main_checkout(root), "tools", "repro_old_new.sh")
        reasons.append(
            "code changed in this turn after the last test run: %s. "
            "Run `prove -r t` on a fresh copy (in a worktree: the tree plus the main checkout's t/, "
            "see .claude/agents/pgen-reviewer.md), and for a fix `bash %s t/<test>.t` "
            "(fails on the old code, passes on the new).%s "
            "If tests just ran or do not apply, say so in the reply and stop again."
            % (listed(stale), repro,
               (" Perl, not parsed by this hook: `perl -I usr/share/PGenerator -c` for scripts, "
                "pgen_release_check_runtime_syntax for modules: %s." % listed(perl)) if perl else ""))
    if reasons and not active:
        out = {"decision": "block", "reason": "verify_stop: " + "\n\nverify_stop: ".join(reasons)}
    else:
        if errors:
            messages.append("still do not parse: " + "; ".join("%s: %s" % e for e in errors))
        if stale:
            messages.append("no test run after the last change to " + listed(stale))
    messages.extend(notes)
    if messages:
        out["systemMessage"] = "verify_stop: " + "; ".join(messages)
    if out:
        print(json.dumps(out))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        sys.stderr.write("verify_stop error: %s: %s\n" % (type(e).__name__, e))
        sys.exit(1)
