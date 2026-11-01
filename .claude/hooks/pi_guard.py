#!/usr/bin/env python3
"""PreToolUse guard for Bash: the rules of CLAUDE.md ("Working on the Pi",
"Rules that bite", "Git and releases") enforced before a command runs,
instead of remembered. Reads the hook JSON on stdin; prints a deny or ask
decision, or nothing (the normal permission flow goes on).

The command is read the way a shell reads it: quotes, $'..', $(..),
backticks, <(..), backslash-newline, comments only at the start of a word,
heredocs. Each simple command is judged by its program and arguments, and
what it runs in turn is judged too: $(..) and backticks, `sh -c`, `eval`,
`xargs`, wrappers (sudo, env, timeout, busybox ...), a heredoc fed to a
shell or an interpreter, the code of `python -c` / `perl -e`, and the text
given to `pgen-pi ssh` (judged as what runs on the Pi). A heredoc fed to
anything else (cat > file, a script reading stdin) is data.

Deny (the reason goes back to Claude):
  - the Pi's root password written out in a command;
  - the Pi reached without pgen-pi (pi.exp, ssh/scp/sshpass/rsync/expect);
  - a Pi command that changes the picture, signal, daemon or device while
    the last `pgen-pi busy` (for that host) is not FREE or older than 10 min;
  - `{}`, empty or missing bodies to the API, any POST to /api/meter/settings;
  - writes to /usr, /etc, /lib, /boot, /bin, /sbin on the Pi without a
    backup of that same file into /root/pgen-backups in the command (use
    `pgen-pi deploy`), and any edit of /etc/PGenerator behind the daemon;
  - an init-script stop/restart in a command that names a path the init
    script pkills (it would kill its own shell);
  - writing pgen-pi's busy state by hand;
  - pushes to origin (upstream BigShoots).
Ask (the user confirms in the prompt): reboot/shutdown (also POST
/api/reboot and /api/power), push, release.

A net for slips, not a sandbox: a command built to hide what it does (a
copied script, a host read from a file) can get past it.

Fails open: an error inside the guard is reported on stderr (exit 1, a
non-blocking hook error) and the command goes on.
"""
import json, os, posixpath, re, sys, time

HOSTS = ("192.168.1.235", "pgenerator.local")
DEFAULT_HOST = "192.168.1.235"
BUSY_FRESH = 600
STATE = os.path.join(os.environ.get("PGEN_PI_STATE_DIR", os.path.expanduser("~/.local/state/pgen-pi")), "state.json")
PGEN_SUBS = {"busy", "status", "ssh", "scp", "fetch", "snapshot", "diff", "restore", "deploy", "restart", "reboot", "probes", "wait"}
# What the init script pkills (etc/init.d/PGenerator, stop).
PKILLED = ("/usr/sbin/PGeneratord", "/usr/bin/PGenerator_cmd.pl", "/usr/bin/PGenerator_serial.pl")
SYSTEM = re.compile(r"^/(?:(?:usr|etc|lib|boot|bin|sbin)(?:/|$)|$)")
CONF_DIR = "/etc/PGenerator"
BACKUPS = "/root/pgen-backups"
DEV_OK = {"/dev/null", "/dev/stdout", "/dev/stderr", "/dev/tty", "/dev/zero"}
# Scripts that drive patterns, the signal or the daemon when run.
DRIVERS = {"pgprobe.py", "pitpgprobe.py", "pi_hdmi_run.py", "pi_scale_check.py", "pi_port85_check.py",
           "pgen_selftest.pl", "signal_audit.pl", "dv_vsif_ab.pl", "restore.sh", "pi_deploy.sh", "deploy.sh",
           "pi_state.py"}
# Arguments that look like pgprobe commands (a copied or renamed probe).
# Pi tools that drive patterns, the meter, CEC/the TV or the system.
DEVICE_TOOLS = {"pkill", "killall", "modprobe", "rmmod", "insmod", "pgsethdr", "tvservice", "pgenerator-lg", "pgcec",
                "cec-ctl", "cec-client", "PGenerator_cmd.pl", "pgen_test_edid", "pgen_cec_remote.py",
                "resize_PGenerator_disk", "pgenerator_system_backup.py", "spotread", "spotread_wrapper.sh",
                "spotread_measure.py", "chartread", "ccxxmake", "ccxxmake_interactive", "fbset"}
DEVICE_PREFIX = ("pgenerator-update", "pgenerator-cec", "meter_")
HELP = {"-h", "--help", "--version", "-V"}
PROBE_ARG = re.compile(r"^(?:RGB_[SA]|RGB|CONF_[A-Z]+|post|PATTERN|WINDOW|BG|TEXT)[: =]")
SHELLS = {"sh", "bash", "dash", "zsh", "ksh", "ash"}
SSH_FAMILY = {"ssh", "scp", "sshpass", "rsync", "sftp", "ssh-copy-id", "autossh", "mosh"}
NET = {"nc", "ncat", "netcat", "socat", "telnet"}
NET_PORTS = ("80", "85", "2100", "2101")
POWER = {"reboot", "shutdown", "poweroff", "halt"}
KEYWORDS = {"if", "then", "else", "elif", "fi", "do", "done", "while", "until", "!", "case", "esac",
            "export", "local", "readonly", "declare", "typeset"}
ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)
# Wrappers that run the rest of their arguments, with the options that take a value.
WRAP = {
    "sudo": {"-u", "-g", "-C", "-h", "-p", "-r", "-t", "-U", "-D", "-T", "--user", "--group"},
    "doas": {"-u", "-C"},
    "env": {"-u", "-C", "-S", "--unset", "--chdir", "--split-string"},
    "nice": {"-n", "--adjustment"},
    "ionice": {"-c", "-n", "-p"},
    "nohup": set(), "setsid": set(), "exec": {"-a"}, "command": set(), "time": {"-f", "-o"},
    "stdbuf": {"-i", "-o", "-e"}, "busybox": set(),
    "timeout": {"-s", "-k", "--signal", "--kill-after"},
    "xargs": {"-I", "-n", "-P", "-L", "-d", "-E", "-s", "-a", "-l", "--max-args", "--max-procs",
              "--delimiter", "--arg-file", "--replace", "--max-lines", "--eof"},
    "watch": {"-n", "--interval"},
    "flock": {"-w", "-E", "--timeout", "--conflict-exit-code"},
}
CURL_SHORT = set("AbcCdDeEFHKmoPQrTuUwxXyYz")
CURL_LONG = {"--data", "--data-raw", "--data-binary", "--data-urlencode", "--data-ascii", "--json", "--request",
             "--output", "--header", "--form", "--form-string", "--upload-file", "--url", "--user", "--user-agent",
             "--referer", "--cookie", "--cookie-jar", "--config", "--max-time", "--connect-timeout", "--output-dir",
             "--write-out", "--proxy", "--resolve", "--cacert", "--cert", "--key", "--retry", "--range",
             "--continue-at", "--interface", "--dump-header", "--trace", "--trace-ascii", "--stderr"}
WGET_SHORT = set("OoatTwPUiBQlARDIXe")
WGET_LONG = {"--post-data", "--post-file", "--body-data", "--body-file", "--method", "--output-document",
             "--directory-prefix", "--header", "--user-agent", "--tries", "--timeout", "--output-file",
             "--user", "--password"}
CURL_BODY = {"-d", "--data", "--data-raw", "--data-binary", "--data-ascii", "--data-urlencode", "--json"}
POST_METHODS = {"POST", "PUT", "DELETE", "PATCH"}
# Code of python -c / perl -e / a heredoc fed to an interpreter, read as text.
CODE_RISK = re.compile(r"init\.d/PGenerator|\bservice\s+PGenerator|invoke-rc\.d|\b(?:pkill|killall|reboot|shutdown|"
                       r"poweroff|telinit|pgsethdr|vcgencmd|tvservice|modprobe|rmmod|insmod|pgprobe|pitpgprobe|"
                       r"pgenerator-update\w*)\b|sysrq|operations\.txt|running/return|['\"]/sys/|os\.kill\b|"
                       r"PGTVMenu|webui_pattern|PGenerator_cmd")
CODE_POST = re.compile(r"data\s*=|json\s*=|\bPOST\b|\bPUT\b|\bDELETE\b|method\s*=|--data|--post|"
                       r"\.(?:post|put|patch|delete)\s*\(|Request\s*\([^(),]{0,300},")
CODE_WRITE = re.compile(r"open\s*\([^(),]{0,300},\s*['\"][wax+]|\.write\s*\(|write_(?:text|bytes)|shutil\.|"
                        r"json\.dump\b|os\.(?:replace|rename|remove|unlink)|(?<![.\w])(?:copy|move|rename|unlink)\s*\(|"
                        r"(?<![=\-])>\s*['\"]?/")
CODE_DUMMY = re.compile(r"data\s*=\s*b?(['\"])\s*(?:\{\s*\})?\s*\1")
CODE_SOCKET = re.compile(r"\bsocket\b|\.connect\s*\(|\bcreate_connection\b|\btelnetlib\b|\bnc\b")
CODE_REMOTE = re.compile(r"\b(?:ssh|scp|sftp|rsync|spawn|paramiko|pexpect)\b")
# A string in code that is a command line worth judging as one.
CODE_CMDLINE = re.compile(r"pgen-pi\s+[a-z$]|pi\.exp\s+(?:ssh|scp)|(?:^|[\s;&|])(?:ssh|scp|sshpass|rsync|curl|wget)\s")
POWER_API = re.compile(r"/api/(?:reboot|power)\b")
MAX_DEPTH = 40
CODE_SYS = re.compile(r"['\"{ ]/+(?:usr|etc|lib|boot|bin|sbin)/")
LITERAL = re.compile(r"'((?:[^'\\]|\\.)*)'|\"((?:[^\"\\]|\\.)*)\"|\bq[qx]?\{([^}]*)\}", re.S)

# Which reason wins when several rules deny one command.
P_PASSWORD, P_RAW, P_PKILL, P_CONF, P_METER, P_DUMMY, P_SYS, P_STATE, P_ORIGIN = 100, 90, 80, 70, 65, 60, 50, 45, 40
PASSWORD = ("the Pi's root password is written out in this command (it lands in the transcript). "
            "Use .claude/skills/pi/scripts/pgen-pi: it reads the password from README.md itself.")
RAW = ("reach the Pi through .claude/skills/pi/scripts/pgen-pi (ssh, scp, busy, deploy, snapshot, restore, "
       "restart, reboot): it handles the password, the busy state and the backups.")
CONF_WRITE = ("writing %s behind the daemon: change settings with partial /api/config bodies, give them back "
              "with `pgen-pi restore`.")
SYS_WRITE = ("writes to %s on the Pi without a backup of that file into /root/pgen-backups in this command: use "
             "`pgen-pi deploy` (it backs up, guards empty files, compares md5 and writes a restore.sh).")
DUMMY = ("empty or `{}` body to the API: never POST dummy bodies to settings endpoints (CLAUDE.md). "
         "Send a partial body with exactly the keys to change.")
METER = ("POST to /api/meter/settings: an earlier body wiped the meter settings. Read the handler (webui.pm) "
         "and ask the maintainer before writing them.")
STATE_WRITE = "pgen-pi's busy state is written by `pgen-pi busy` only, after it checked the Pi."


def password(project):
    try:
        with open(os.path.join(project, "README.md"), encoding="utf-8") as f:
            m = re.search(r"\*\*SSH\*\* \(`root` / `([^`]+)`\)", f.read())
        return m.group(1) if m else None
    except OSError:
        return None


def busy_state(project=None):
    """The busy result pgen-pi recorded for this checkout; {} when missing or
    malformed. Another checkout's result does not count here: what it found
    leaves its own snapshot and actions out (2026-11-01 review: a FREE of
    checkout A let B restart the daemon while A's snapshot was open)."""
    try:
        with open(STATE) as f:
            st = json.load(f)
    except (OSError, ValueError):
        return {}
    if not isinstance(st, dict):
        return {}
    here = os.path.realpath(project) if project else None
    by = st.get("busy_by_repo")
    b = by.get(here) if (here and isinstance(by, dict)) else None
    if b is None:
        b = st.get("busy")
        # Only a record that names this checkout counts; one without the repo
        # field comes from an older pgen-pi in some checkout (fails closed).
        if isinstance(b, dict) and here and (not b.get("repo") or os.path.realpath(str(b["repo"])) != here):
            return {"result": "OTHER", "time": 0.0, "repo": b.get("repo") or "a pgen-pi that does not record its checkout"}
    if not isinstance(b, dict):
        return {}
    t = b.get("time")
    b["time"] = float(t) if isinstance(t, (int, float)) and not isinstance(t, bool) else 0.0
    return b


def foreign_snapshot(project):
    """The open snapshot of another checkout, or None."""
    try:
        with open(STATE) as f:
            st = json.load(f)
    except (OSError, ValueError):
        return None
    s = st.get("snapshot") if isinstance(st, dict) else None
    if not isinstance(s, dict) or not project:
        return None
    here = os.path.realpath(project)
    if s.get("repo"):
        return None if os.path.realpath(str(s["repo"])) == here else s
    c = os.path.realpath(str(s.get("cwd") or ""))
    return None if (c == here or c.startswith(here + os.sep)) else s


# --- reading the command like a shell --------------------------------------

def match_paren(s, j):
    """s[j] == "(": the index after its matching ")", quotes honoured."""
    depth, i, n = 0, j, len(s)
    while i < n:
        c = s[i]
        if c == "\\":
            i += 2
            continue
        if c == "'":
            k = s.find("'", i + 1)
            i = n if k < 0 else k + 1
            continue
        if c == '"':
            i += 1
            while i < n and s[i] != '"':
                i += 2 if s[i] == "\\" else 1
            i += 1
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


OPS = sorted([";;", "&&", "||", "|&", "&>>", "&>", ">>", ">&", "<&", ">|", "<>", "<<<", "<<-", "<<", "<(", ">(",
              ";", "&", "|", "(", ")", "<", ">"], key=len, reverse=True)
DELIM_END = set(" \t\n;&|()<>")


def lex(text):
    """Items: ("w", word, [substitutions]), ("op", op), ("hd", heredoc body), ("sub", text)."""
    out, i, n = [], 0, len(text)
    st = {"word": None, "subs": []}           # word: a list of pieces, None outside a word
    pending = []

    def end():
        if st["word"] is not None:
            out.append(("w", "".join(st["word"]), st["subs"]))
        st["word"], st["subs"] = None, []

    def add(s):
        if st["word"] is None:
            st["word"] = []
        st["word"].append(s)

    while i < n:
        c = text[i]
        if c == "\\" and i + 1 < n and text[i + 1] == "\n":
            i += 2
        elif c in " \t\r":
            end()
            i += 1
        elif c == "\n":
            end()
            i += 1
            for delim, strip in pending:
                body = []
                while i < n:
                    e = text.find("\n", i)
                    line = text[i:] if e < 0 else text[i:e]
                    i = n if e < 0 else e + 1
                    if (line.lstrip("\t") if strip else line) == delim:
                        break
                    body.append(line)
                out.append(("hd", "\n".join(body)))
            pending = []
            out.append(("op", ";"))
        elif c == "#" and st["word"] is None:
            e = text.find("\n", i)
            i = n if e < 0 else e
        elif c == "'":
            k = text.find("'", i + 1)
            k = n if k < 0 else k
            add(text[i + 1:k])
            i = k + 1
        elif text.startswith("$'", i):
            j, buf = i + 2, ""
            while j < n and text[j] != "'":
                if text[j] == "\\" and j + 1 < n:
                    buf += {"n": "\n", "t": "\t"}.get(text[j + 1], text[j + 1])
                    j += 2
                else:
                    buf += text[j]
                    j += 1
            add(buf)
            i = j + 1
        elif c == '"':
            j, buf = i + 1, ""
            while j < n and text[j] != '"':
                if text[j] == "\\" and j + 1 < n:
                    if text[j + 1] != "\n":
                        buf += text[j + 1] if text[j + 1] in '"\\$`' else "\\" + text[j + 1]
                    j += 2
                elif text.startswith("$((", j):
                    k = text.find("))", j)
                    k = n if k < 0 else k + 2
                    buf += text[j:k]
                    j = k
                elif text.startswith("$(", j):
                    k = match_paren(text, j + 1)
                    st["subs"].append(text[j + 2:k - 1])
                    buf += text[j:k]
                    j = k
                elif text[j] == "`":
                    k = text.find("`", j + 1)
                    k = n if k < 0 else k
                    st["subs"].append(text[j + 1:k])
                    buf += text[j:k + 1]
                    j = k + 1
                else:
                    buf += text[j]
                    j += 1
            add(buf)
            i = j + 1
        elif c == "`":
            k = text.find("`", i + 1)
            k = n if k < 0 else k
            st["subs"].append(text[i + 1:k])
            add(text[i:k + 1])
            i = k + 1
        elif text.startswith("$((", i):
            k = text.find("))", i)
            k = n if k < 0 else k + 2
            add(text[i:k])
            i = k
        elif text.startswith("$(", i):
            k = match_paren(text, i + 1)
            st["subs"].append(text[i + 2:k - 1])
            add(text[i:k])
            i = k
        elif text.startswith("${", i):
            k = text.find("}", i)
            k = n if k < 0 else k + 1
            add(text[i:k])
            i = k
        elif c == "\\":
            add(text[i + 1:i + 2])
            i += 2
        elif c in ";&|()<>":
            if c in "<>" and st["word"] is not None and "".join(st["word"]).isdigit() and not st["subs"]:
                st["word"] = None                     # 2>&1: an fd number
            end()
            op = next(o for o in OPS if text.startswith(o, i))
            if op in ("<(", ">("):
                k = match_paren(text, i + 1)
                out.append(("sub", text[i + 2:k - 1]))
                i = k
                continue
            out.append(("op", op))
            i += len(op)
            if op in ("<<", "<<-"):
                while i < n and text[i] in " \t":
                    i += 1
                d = ""
                while i < n and text[i] not in DELIM_END:
                    if text[i] in "'\"":
                        k = text.find(text[i], i + 1)
                        k = n if k < 0 else k
                        d += text[i + 1:k]
                        i = k + 1
                    elif text[i] == "\\":
                        d += text[i + 1:i + 2]
                        i += 2
                    else:
                        d += text[i]
                        i += 1
                if d:
                    pending.append((d, op == "<<-"))
        else:
            add(c)
            i += 1
    end()
    return out


class Cmd(object):
    def __init__(self):
        self.argv, self.redir, self.subs, self.heredocs = [], [], [], []


def commands(text):
    res, cur, target = [], Cmd(), None
    for item in lex(text):
        kind = item[0]
        if kind == "hd":
            cur.heredocs.append(item[1])
        elif kind == "sub":
            cur.subs.append(item[1])
        elif kind == "w":
            cur.subs.extend(item[2])
            if target:
                if target == "out" or (target == "dup" and not re.match(r"^(?:\d+-?|-)$", item[1])):
                    cur.redir.append(item[1])
                target = None
            elif item[1] in ("{", "}"):
                res.append(cur)
                cur = Cmd()
            else:
                cur.argv.append(item[1])
        else:
            op = item[1]
            if op in (">", ">>", ">|", "&>", "&>>", "<>"):
                target = "out"
            elif op == ">&":
                target = "dup"
            elif op in ("<", "<&", "<<<"):
                target = "in"
            elif op not in ("<<", "<<-"):
                res.append(cur)
                cur = Cmd()
    res.append(cur)
    return [c for c in res if c.argv or c.redir or c.subs or c.heredocs]


# --- judging ----------------------------------------------------------------

class St(object):
    """What the whole command does, collected over all its parts."""
    def __init__(self, cmd, hosts, host, pw):
        self.cmd, self.hosts, self.host, self.pw = cmd, hosts, host, pw
        self.denials, self.asks, self.pi_text, self.vars = [], [], [], {}
        self.mutating = self.power = self.init_stop = self.xargs = False
        self.cwd = ""

    def deny(self, prio, reason):
        self.denials.append((prio, reason))

    def mentions_host(self, s):
        s = s.lower()
        return any(h in s for h in self.hosts)


class Loc(object):
    """Where a command list runs: the Mac or the Pi, its cwd, its backups."""
    def __init__(self, ctx):
        self.ctx, self.saved = ctx, set()
        self.cwd = "/root" if ctx == "pi" else MAC_CWD[0]


MAC_CWD = [""]


def prog(a):
    return os.path.basename(a[0]) if a else ""


def expand(w, st, ctx):
    home = "/root" if ctx == "pi" else os.path.expanduser("~")

    def var(m):
        name = m.group(1) or m.group(2)
        return home if name == "HOME" else st.vars.get(name, m.group(0))
    w = re.sub(r"\$\{([A-Za-z_]\w*)\}|\$([A-Za-z_]\w*)", var, w)
    if w == "~" or w.startswith("~/"):
        w = home + w[1:]
    return w


def norm(path, loc):
    if not path or path.startswith("$"):
        return path
    if not path.startswith("/"):
        if not loc.cwd:
            return path
        path = loc.cwd + "/" + path
    return posixpath.normpath("/" + path.lstrip("/"))


def strip_opts(a, valopts):
    i = 0
    while i < len(a) and a[i].startswith("-") and a[i] != "-":
        if a[i] == "--":
            i += 1
            break
        i += 2 if a[i] in valopts else 1
    return a[i:]


def core(argv, st):
    """argv without assignments, keywords and wrappers (sudo, env, timeout ...)."""
    a = list(argv)
    while a:
        m = ASSIGN.match(a[0])
        if m:
            st.vars[m.group(1)] = m.group(2)
            a = a[1:]
            continue
        if a[0] in KEYWORDS:
            a = a[1:]
            continue
        b = os.path.basename(a[0])
        if b in WRAP:
            st.xargs = st.xargs or b == "xargs"
            if b == "command" and any(x in ("-v", "-V") for x in a[1:3]):
                return []
            rest = strip_opts(a[1:], WRAP[b])
            if b == "timeout" and rest:
                rest = rest[1:]
            a = rest
            continue
        break
    return a


def parse_opts(args, short, long_):
    """[(option, value)] of a curl/wget command line; short clusters (-sXPOST, -d{}) split."""
    opts, i = [], 0
    while i < len(args):
        x = args[i]
        if x.startswith("--") and len(x) > 2:
            if "=" in x:
                opts.append(tuple(x.split("=", 1)))
            elif x in long_ and i + 1 < len(args):
                opts.append((x, args[i + 1]))
                i += 1
            else:
                opts.append((x, None))
        elif x.startswith("-") and len(x) > 1:
            for j in range(1, len(x)):
                if x[j] in short:
                    if j + 1 < len(x):
                        opts.append(("-" + x[j], x[j + 1:]))
                    else:
                        opts.append(("-" + x[j], args[i + 1] if i + 1 < len(args) else ""))
                        i += 1
                    break
                opts.append(("-" + x[j], None))
        i += 1
    return opts


def http(a):
    """(POST/PUT/DELETE, [bodies], [files written]) of a curl/wget command."""
    p = prog(a)
    if p == "curl":
        opts = parse_opts(a[1:], CURL_SHORT, CURL_LONG)
        post = any(k in ("-X", "--request") and (v or "").upper() in POST_METHODS for k, v in opts) or \
            any(k in CURL_BODY or k in ("-F", "--form", "--form-string", "-T", "--upload-file") for k, v in opts)
        bodies = [v or "" for k, v in opts if k in CURL_BODY]
        outs = [v for k, v in opts if k in ("-o", "--output") and v and v != "-"]
        return post, bodies, outs
    if p == "wget":
        opts = parse_opts(a[1:], WGET_SHORT, WGET_LONG)
        post = any(k in ("--post-data", "--post-file", "--body-data", "--body-file") for k, v in opts) or \
            any(k == "--method" and (v or "").upper() in POST_METHODS for k, v in opts)
        bodies = [v or "" for k, v in opts if k in ("--post-data", "--body-data")]
        outs = [v for k, v in opts if k in ("-O", "--output-document", "-P", "--directory-prefix") and v and v != "-"]
        return post, bodies, outs
    return False, [], []


def empty_body(b):
    return b.strip() == "@/dev/null" or re.match(r"^\s*(?:\{\s*\})?\s*$", b) is not None


def check_api(a, st):
    post, bodies, _ = http(a)
    args = " ".join(a)
    if post and "/api/meter/settings" in args:
        st.deny(P_METER, METER)
    if post and "/api/" in args:
        if not bodies and "/api/config" in args:
            st.deny(P_DUMMY, "POST to /api/config without a body: never POST dummy bodies (CLAUDE.md); send "
                    "exactly the keys to change.")
        if any(empty_body(b) for b in bodies):
            st.deny(P_DUMMY, DUMMY)
    if post:
        st.mutating = True
        if POWER_API.search(args):
            st.power = True


def stdin_body(remote, body, st, depth):
    """A heredoc fed to `pgen-pi ssh REMOTE`: judged by what REMOTE does with
    its stdin. A shell (or no command: the login shell) runs it, an
    interpreter reading stdin runs it as code, anything else gets data."""
    cmds = commands(remote)
    a = core([expand(x, st, "pi") for x in cmds[0].argv], st) if cmds else []
    p = prog(a)
    if not a or (p in SHELLS and (len(a) == 1 or "-s" in a[1:] or all(x.startswith("-") for x in a[1:]))):
        judge(body, "pi", st, depth)
    elif is_interp(p) and code_of(a) == (None, None):
        scan_code(body, Loc("pi"), st, depth)


def write_targets(a, redir, loc):
    """Paths a simple command writes, normalised."""
    hits = list(redir)
    p, args = prog(a), a[1:]
    plain = [x for x in args if not x.startswith("-")]
    if p in ("cp", "mv", "install", "ln", "rsync", "scp"):
        t = None
        for j, x in enumerate(args):
            if x in ("-t", "--target-directory") and j + 1 < len(args):
                t = args[j + 1]
            elif x.startswith("--target-directory="):
                t = x.split("=", 1)[1]
        if t:
            hits.append(t)
        elif plain:
            hits.append(plain[-1])
    elif p == "tee":
        hits.extend(plain)
    elif p == "dd":
        hits.extend(x[3:] for x in args if x.startswith("of="))
    elif p == "sed":
        if any(x == "--in-place" or x.startswith("--in-place=") or re.match(r"^-[a-zA-Z]*i", x) for x in args):
            given = any(x in ("-e", "--expression", "-f", "--file") or x.startswith("--expression=") for x in args)
            hits.extend(plain if given else plain[1:])
    elif p == "perl":
        if any(re.match(r"^-[a-zA-Z]*i", x) for x in args):
            files, j, code = [], 0, False
            while j < len(args):
                x = args[j]
                if re.match(r"^-[a-zA-Z]*[eE]$", x) or x in ("-I", "-M", "-m"):
                    code = code or x.endswith(("e", "E"))
                    j += 2
                    continue
                if not x.startswith("-"):
                    files.append(x)
                j += 1
            hits.extend(files if code else files[1:])
    elif p in ("rm", "unlink", "rmdir", "mkdir", "touch", "shred"):
        hits.extend(plain)
    elif p == "truncate":
        hits.extend(strip_opts(args, {"-s", "--size", "-r", "--reference"}))
    elif p in ("chmod", "chown", "chgrp"):
        hits.extend(plain[1:])
    elif p == "tar":
        extract = any(x in ("--extract", "--get") for x in args) or \
            (args and not args[0].startswith("--") and re.match(r"^-?[A-Za-z]*x", args[0]) is not None) or \
            any(re.match(r"^-[A-Za-z]*x[A-Za-z]*$", x) for x in args)
        if extract:
            dirs = [args[j + 1] for j, x in enumerate(args) if x == "-C" and j + 1 < len(args)]
            dirs += [x[2:] for x in args if x.startswith("-C") and len(x) > 2]
            dirs += [x.split("=", 1)[1] for x in args if x.startswith("--directory=")]
            hits.extend(dirs or ["."])
    elif p == "unzip":
        d = [args[j + 1] for j, x in enumerate(args) if x == "-d" and j + 1 < len(args)]
        hits.extend(d or ["."])
    elif p in ("curl", "wget"):
        hits.extend(http(a)[2])
    return [norm(h, loc) for h in hits if h]


def is_interp(p):
    return re.match(r"^(?:python[0-9.]*|perl|node|ruby|php|expect)$", p) is not None


def code_of(a):
    """(code of -c/-e, index of the script argument) of an interpreter
    command; both None: the code comes from stdin."""
    p, args, j = prog(a), a[1:], 0
    while j < len(args):
        x = args[j]
        if x == "-":
            return None, None
        if not x.startswith("-"):
            return None, j + 1
        if (p.startswith("python") or p == "expect") and x == "-c" or p == "perl" and re.match(r"^-[a-zA-Z]*[eE]$", x) \
                or p in ("node", "ruby", "php") and x in ("-e", "-r", "--eval", "-p"):
            return (args[j + 1] if j + 1 < len(args) else ""), None
        if p.startswith("python") and x.startswith("-c") and len(x) > 2:
            return x[2:], None
        if p.startswith("python") and x == "-m":
            return None, j + 2
        j += 2 if x in ("-I", "-M", "-W", "-X") else 1
    return None, None


def scan_code(code, loc, st, depth):
    """Interpreter code: what it would do, read from its text."""
    if loc.ctx == "mac":
        if st.mentions_host(code):
            if CODE_REMOTE.search(code):
                st.deny(P_RAW, RAW)
            if ("/api/" in code and CODE_POST.search(code)) or CODE_SOCKET.search(code):
                st.mutating = True
            if POWER_API.search(code) and CODE_POST.search(code):
                st.power = True
        lits = [next(g for g in m.groups() if g is not None) for m in LITERAL.finditer(code)]
        for k, s in enumerate(lits):
            if CODE_CMDLINE.search(s):
                judge(s, "mac", st, depth + 1)
            elif os.path.basename(s) == "pgen-pi" and k + 1 < len(lits):
                # an argv list: pgen-pi, then its arguments as separate strings
                judge_mac([s] + lits[k + 1:k + 3], [], st, depth + 1)
        if "state.json" in code and "pgen-pi" in code and CODE_WRITE.search(code):
            st.deny(P_STATE, STATE_WRITE)
    else:
        if CODE_RISK.search(code) or ("/api/" in code and CODE_POST.search(code)) or \
                (re.search(r"\b(?:85|2100|2101)\b", code) and CODE_SOCKET.search(code)):
            st.mutating = True
        if CODE_WRITE.search(code):
            if CONF_DIR in code:
                st.deny(P_CONF, CONF_WRITE % CONF_DIR)
            elif CODE_SYS.search(code):
                st.deny(P_SYS, SYS_WRITE % "a system path (from code)")
            if "/var/lib/PGenerator/running" in code or "/sys/" in code:
                st.mutating = True
        if "sysrq" in code or (POWER_API.search(code) and CODE_POST.search(code)):
            st.power = st.mutating = True
    if "/api/meter/settings" in code and CODE_POST.search(code):
        st.deny(P_METER, METER)
    if "/api/" in code and CODE_DUMMY.search(code):
        st.deny(P_DUMMY, DUMMY)


def judge(text, ctx, st, depth=0):
    if depth > MAX_DEPTH:
        st.deny(P_RAW, "nested too deeply to check (more than %d levels): write it plainly." % MAX_DEPTH)
        return
    if ctx == "pi":
        st.pi_text.append(text)
    loc = Loc(ctx)
    for c in commands(text):
        for s in c.subs:
            judge(s, ctx, st, depth + 1)
        argv = [expand(x, st, ctx) for x in c.argv]
        redir = [expand(x, st, ctx) for x in c.redir]
        if st.pw and any(st.pw in x for x in argv + redir):
            st.deny(P_PASSWORD, PASSWORD)
        st.xargs = False
        judge_one(core(argv, st), redir, c.heredocs, loc, st, depth)


def judge_one(a, redir, heredocs, loc, st, depth):
    if depth > MAX_DEPTH:
        st.deny(P_RAW, "nested too deeply to check (more than %d levels): write it plainly." % MAX_DEPTH)
        return
    p, ctx = prog(a), loc.ctx
    writes = write_targets(a, redir, loc)
    if ctx == "pi" and p in ("cp", "mv", "install") and writes:
        # cp FILE DIR/ writes DIR/FILE: the backup of that file counts.
        srcs = [norm(x, loc) for x in a[1:] if not x.startswith("-")][:-1]
        joined = [norm(writes[-1] + "/" + posixpath.basename(x), loc) for x in srcs]
        if joined and all(j in loc.saved for j in joined):
            writes = writes[:-1] + joined
    for w in writes:
        if ctx == "pi":
            if w == CONF_DIR or w.startswith(CONF_DIR + "/"):
                st.deny(P_CONF, CONF_WRITE % w)
            elif SYSTEM.match(w) and w not in loc.saved:
                st.deny(P_SYS, SYS_WRITE % w)
            if w.startswith(("/var/lib/PGenerator/running", "/sys/", "/proc/")) or SYSTEM.match(w) \
                    or (w.startswith("/dev/") and w not in DEV_OK):
                st.mutating = True
            if w == "/proc/sysrq-trigger":
                st.power = True
        elif w == STATE or w.endswith("/pgen-pi/state.json"):
            st.deny(P_STATE, STATE_WRITE)
        elif w.startswith(("/dev/tcp/", "/dev/udp/")) and st.mentions_host(w):
            st.mutating = True
    if ctx == "pi" and p == "cp":
        plain = [norm(x, loc) for x in a[1:] if not x.startswith("-")]
        if len(plain) >= 2 and (plain[-1] == BACKUPS or plain[-1].startswith(BACKUPS + "/")):
            loc.saved.update(plain[:-1])
    if not a:
        return
    # What runs something else: a shell, eval, an interpreter.
    if p in SHELLS or p == "su":
        for j, x in enumerate(a[1:]):
            if (p in SHELLS and re.match(r"^-[a-zA-Z]*c[a-zA-Z]*$", x)) or (p == "su" and x in ("-c", "--command")):
                judge(a[j + 2] if j + 2 < len(a) else "", ctx, st, depth + 1)
                return
        if p in SHELLS:
            rest = strip_opts(a[1:], {"-o", "-O", "--rcfile", "--init-file"})
            if rest and "-s" not in a[1:]:
                return judge_one(rest, [], [], loc, st, depth + 1)
            for body in heredocs:
                judge(body, ctx, st, depth + 1)
        return
    if p == "eval":
        judge(" ".join(a[1:]), ctx, st, depth + 1)
        return
    if is_interp(p):
        code, script = code_of(a)
        if p == "expect" and ctx == "mac" and (any(st.mentions_host(x) for x in a[1:] + heredocs) or
                                               any(x.endswith("pi.exp") for x in a[1:]) or
                                               ("pi.exp" in st.cmd and any(x in ("ssh", "scp") for x in a[1:])) or
                                               (script is not None and st.mentions_host(st.cmd))):
            st.deny(P_RAW, RAW)
            return
        if code is not None:
            scan_code(code, loc, st, depth)
        elif script is None:
            for body in heredocs:
                scan_code(body, loc, st, depth)
        if ctx == "pi":
            if any(re.match(r"^post:\s*(?:\{\s*\})?\s*$", x) for x in a):
                st.deny(P_DUMMY, "pgprobe `post:{}`: never POST dummy bodies (CLAUDE.md); give the keys to change.")
            if any(PROBE_ARG.match(x) for x in a[1:]):
                st.mutating = True
        if script is not None and script < len(a):
            return judge_one(a[script:], [], [], loc, st, depth + 1)
        return
    if ctx == "mac":
        if p in ("cd", "pushd"):
            loc.cwd = norm(a[1], loc) if len(a) > 1 and not a[1].startswith("-") else os.path.expanduser("~")
            return
        judge_mac(a, heredocs, st, depth, loc)
    else:
        judge_pi(a, loc, st)


def judge_mac(a, heredocs, st, depth, loc=None):
    p = prog(a)
    if p == "pgen-pi" or (a[0].startswith("$") and len(a) > 1 and a[1] in PGEN_SUBS):
        sub = a[1] if len(a) > 1 else ""
        if sub == "ssh":
            remote = " ".join(a[2:])
            judge(remote, "pi", st, depth + 1)
            for body in heredocs:
                stdin_body(remote, body, st, depth + 1)
        elif sub == "scp":
            dest = expand(a[-1], st, "pi") if len(a) > 3 else ""
            dest = re.sub(r"^(?:[^@/:]+@)?[^/:]+:", "", dest)
            home = os.path.expanduser("~")
            if dest == home or dest.startswith(home + "/"):
                dest = "/root" + dest[len(home):]     # a ~ the Mac side expanded is the Pi's /root
            dest = norm(dest, Loc("pi"))
            if dest.startswith(("/var/lib/PGenerator/running", "/sys/", "/proc/")):
                st.mutating = True
            if dest == CONF_DIR or dest.startswith(CONF_DIR + "/"):
                st.deny(P_CONF, CONF_WRITE % dest)
            elif SYSTEM.match(dest):
                st.deny(P_SYS, "copy straight into %s on the Pi: use `pgen-pi deploy LOCAL:%s` (Pi file against "
                        "the branch, backup, md5, restore.sh)." % (dest, dest))
        elif sub == "fetch" and len(a) > 3:
            # LOCAL on the Mac: pgen-pi's state is written by pgen-pi only
            dest = norm(expand(a[-1], st, "mac"), loc or Loc("mac"))
            sdir = os.path.dirname(STATE)
            if dest in (STATE, sdir) or dest.startswith(sdir + "/") or \
                    re.search(r"/pgen-pi(?:/(?:state\.json|log\.jsonl))?$", dest):
                st.deny(P_STATE, STATE_WRITE)
        elif sub == "reboot":
            st.power = st.mutating = True
        elif sub not in PGEN_SUBS and (sub.startswith("$") or st.xargs):
            st.mutating = True                        # "$@", from xargs: unknown
        return
    if p == "pi.exp":
        st.deny(P_RAW, RAW)
        return
    if p in SSH_FAMILY and (any(st.mentions_host(x) or re.search(r"(?:^|@)pgenerator(?:\.local)?(?::|$)", x, re.I)
                                for x in a[1:]) or (st.xargs and st.mentions_host(st.cmd))):
        st.deny(P_RAW, RAW)
        return
    if p in ("curl", "wget") and any(st.mentions_host(x) for x in a[1:]):
        check_api(a, st)
    if p in NET and "-z" not in a and any(st.mentions_host(x) for x in a[1:]):
        st.mutating = True
    if p in ("http", "https", "xh") and any(st.mentions_host(x) for x in a[1:]):
        # httpie: an explicit method or request items (key=value, key:=json) send a body
        if any(x.upper() in POST_METHODS for x in a[1:3]) or any(re.match(r"^[\w.-]+:?=", x) for x in a[1:]):
            st.mutating = True
            if any("/api/meter/settings" in x for x in a[1:]):
                st.deny(P_METER, METER)
    if p == "git":
        j, pushdefault = 1, False
        while j < len(a) and a[j].startswith("-"):
            if a[j] in ("-C", "-c", "--git-dir", "--work-tree", "--namespace") and j + 1 < len(a):
                pushdefault = pushdefault or (a[j] == "-c" and a[j + 1].lower() == "remote.pushdefault=origin")
                j += 2
            else:
                j += 1
        if j < len(a) and a[j] == "push":
            rest = a[j + 1:]
            k, remote = 0, ""
            while k < len(rest):
                if rest[k] in ("-o", "--push-option", "--repo", "--receive-pack", "--exec"):
                    k += 2
                elif rest[k].startswith("-"):
                    k += 1
                else:
                    remote = rest[k]
                    break
            repo = [rest[k + 1] for k, x in enumerate(rest) if x == "--repo" and k + 1 < len(rest)]
            if remote == "origin" or pushdefault or "origin" in repo or \
                    any("bigshoots" in x.lower() or x == "--repo=origin" for x in rest):
                st.deny(P_ORIGIN, "push to origin = upstream BigShoots. Push only with `git push fork main` (CLAUDE.md).")
            st.asks.append("git push %s: pushes need the maintainer's OK (CLAUDE.md)." % " ".join(rest)[:80])
    if p == "gh" and len(a) > 2:
        if a[1] == "release" and a[2] in ("create", "upload", "edit", "delete"):
            st.asks.append("gh release %s: releases need the maintainer's OK (CLAUDE.md)." % a[2])
        rest = a[2:]
        method = [rest[k + 1].upper() for k, x in enumerate(rest) if x in ("-X", "--method") and k + 1 < len(rest)]
        if a[1] == "api" and any("releases" in x for x in rest) and \
                (set(method) & POST_METHODS or any(x in ("-f", "-F", "--field", "--raw-field", "--input") for x in rest)):
            st.asks.append("gh api on releases: releases need the maintainer's OK (CLAUDE.md).")
    if p in ("release-ota.sh", "release-action.sh"):
        st.asks.append("release script: releases need the maintainer's OK (CLAUDE.md).")


def judge_pi(a, loc, st):
    p, args = prog(a), a[1:]
    if p in ("cd", "pushd"):
        loc.cwd = norm(args[0], loc) if args and not args[0].startswith("-") else "/root"
        return
    if args and all(x in HELP for x in args):
        return
    verb = next((x for x in args if not x.startswith("-")), "")
    if p in POWER or (p in ("init", "telinit") and args[:1] in (["0"], ["6"])) or \
            (p == "systemctl" and verb in POWER | {"kexec"}):
        st.power = st.mutating = True
    elif p == "systemctl" and verb in ("start", "stop", "restart", "reload", "try-restart",
                                       "reload-or-restart", "kill", "isolate", "mask"):
        st.mutating = True
    elif p in ("service", "invoke-rc.d") and len(args) > 1:
        if args[1] in ("start", "stop", "restart", "reload", "force-reload"):
            st.mutating = True
            st.init_stop = st.init_stop or (args[0] == "PGenerator" and args[1] != "start")
    elif p == "PGenerator" and args[:1] and args[0] in ("start", "stop", "restart", "reload", "force-reload"):
        st.mutating = True
        st.init_stop = st.init_stop or args[0] != "start"
    elif p == "kill":
        sig0 = any(x in ("-0", "-s0", "-n0", "-l", "-L") for x in args) or \
            any(x in ("-s", "-n") and args[k + 1:k + 2] == ["0"] for k, x in enumerate(args))
        if not sig0:
            st.mutating = True
    elif p in DEVICE_TOOLS or p.startswith(DEVICE_PREFIX) or (p == "modetest" and "-s" in args):
        st.mutating = True
    elif p.endswith((".py", ".pl", ".sh")) and any(PROBE_ARG.match(x) for x in args):
        st.mutating = True                            # a copied or renamed probe
    elif p == "vcgencmd" and "display_power" in args:
        st.mutating = True
    elif p in DRIVERS:
        if not (p == "pi_state.py" and args[:1] in (["show"], ["diff"])) and \
                not (args and all(x in ("-h", "--help") for x in args)):
            st.mutating = True
        if any(re.match(r"^post:\s*(?:\{\s*\})?\s*$", x) for x in args):
            st.deny(P_DUMMY, "pgprobe `post:{}`: never POST dummy bodies (CLAUDE.md); give the keys to change.")
    elif p in NET and "-z" not in args and any(x in NET_PORTS or x.endswith(tuple(":" + q for q in NET_PORTS)) for x in args):
        st.mutating = True
    if p in ("curl", "wget"):
        check_api(a, st)


def check(cmd, project):
    """(decision, reason) for one Bash command; (None, None) lets it through."""
    pw = password(project)
    host = os.environ.get("PI_HOST") or DEFAULT_HOST
    hosts = set(HOSTS) | {host.lower()}
    for h in re.findall(r"\bPI_HOST=['\"]?([^\s;&|'\"]+)", cmd):
        hosts.add(h.lower())
        host = h
    st = St(cmd, hosts, host, pw)
    if pw and pw in cmd:
        st.deny(P_PASSWORD, PASSWORD)
    judge(cmd, "mac", st)
    if st.init_stop:
        named = [x for x in PKILLED if any(x in t for t in st.pi_text)]
        if named:
            st.deny(P_PKILL, "this command runs the init script's stop and names %s: the stop pkills -f that "
                    "path and would kill this shell half-way. Split it (stop, then copy, then start) or use "
                    "`pgen-pi deploy`." % named[0])
    if st.denials:
        return "deny", max(st.denials, key=lambda d: d[0])[1]
    if st.mutating:
        fs = foreign_snapshot(project)
        if fs:
            return "deny", ("this command changes the picture, signal, daemon or device on the Pi, and another "
                            "checkout holds snapshot %s open (%s): that session is testing on the Pi. Ask the user "
                            "(CLAUDE.md)." % (fs.get("label", "?"), fs.get("repo") or fs.get("cwd", "?")))
        b = busy_state(project)
        age = time.time() - b.get("time", 0)
        same_host = not b.get("host") or b.get("host") == host
        # a time ahead of the clock (clock stepped back, a bad record) is no fresh check
        if b.get("result") != "FREE" or age > BUSY_FRESH or age < -60 or not same_host:
            last = "never run" if not b else \
                "never run in this checkout (the last one was from %s)" % b["repo"] if b.get("result") == "OTHER" else \
                "%s, %d s ago%s" % (b.get("result"), age, "" if same_host else ", for %s" % b.get("host"))
            return "deny", ("this command changes the picture, signal, daemon or device on the Pi, and the last "
                            "busy check is not a fresh FREE (%s). Run `pgen-pi busy` as its own step first; if it "
                            "says BUSY, read the reasons and do not touch the device (CLAUDE.md)." % last)
    asks = list(st.asks)
    if st.power:
        asks.insert(0, "reboot/shutdown of the Pi: needs the maintainer's OK (CLAUDE.md).")
    if asks:
        return "ask", " ".join(asks)
    return None, None


def main():
    data = json.load(sys.stdin)
    if not isinstance(data, dict) or data.get("tool_name") != "Bash":
        return
    ti = data.get("tool_input")
    cmd = ti.get("command") if isinstance(ti, dict) else None
    if not isinstance(cmd, str):
        cmd = "" if cmd is None else str(cmd)
    project = os.environ.get("CLAUDE_PROJECT_DIR") or data.get("cwd") or os.getcwd()
    MAC_CWD[0] = data.get("cwd") if isinstance(data.get("cwd"), str) else os.getcwd()
    try:
        kind, reason = check(cmd, project)
    except RecursionError:
        kind, reason = "deny", "nested too deeply to check: write it plainly."
    if kind:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                                 "permissionDecision": kind,
                                                 "permissionDecisionReason": "pi_guard: " + reason}}))


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        sys.stderr.write("pi_guard error (command not checked): %s: %s\n" % (type(e).__name__, e))
        sys.exit(1)
