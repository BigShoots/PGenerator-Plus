#!/usr/bin/perl
# Regression (issue #51): the Deploy Console API had no auth and SSH host-key
# checking was disabled. Now:
#   * every POST (except /api/health, a GET) requires the X-Deployer-Session
#     token; a wrong/missing token is 401, a non-loopback Host or a
#     cross-origin Origin is 403;
#   * /session.js hands the page a fresh token, no-store;
#   * ssh_base() uses StrictHostKeyChecking=yes and paramiko_client() rejects
#     unknown hosts (no AutoAddPolicy, no trust-on-first-use).
# The auth cases run against a real throwaway server on an ephemeral port;
# the host-key cases are static assertions because they need an actual Pi.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;
use IO::Socket::INET;

my $deployer = File::Spec->catdir($FindBin::Bin, '..', 'github-deployer');
my $server = File::Spec->catfile($deployer, 'server.py');
plan skip_all => "github-deployer/server.py not present" unless -f $server;

# --- live server -------------------------------------------------------------
# Started BEFORE any assertion so 'server did not start' can be a single
# plan skip_all: a second plan() once TAP output exists only survives while
# the planned count equals the number of tests already printed (the static
# block used to run first, making that skip shape load-bearing on counts).
my $port = do {
    my $sock = IO::Socket::INET->new(LocalAddr => '127.0.0.1', Listen => 1)
        or die "cannot allocate probe port: $!";
    my $p = $sock->sockport;
    $sock->close;
    $p;
};
my $token = 'probe-token-' . ('x' x 24);
local $ENV{PGEN_DEPLOYER_TOKEN} = $token;
my $pid = open my $SERVER, '-|', 'python3', $server, '--port', $port, '--no-open'
    or die "fork: $!";

sub wait_ready {
    for (1 .. 50) {
        my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 1);
        if ($s) { $s->close; return 1 }
        select undef, undef, undef, 0.2;
    }
    return 0;
}
plan skip_all => 'server did not start' unless wait_ready();

# --- static assertions -------------------------------------------------------
my $py = do {
    open my $fh, '<', $server or die "open $server: $!";
    local $/; <$fh>;
};
unlike($py, qr/StrictHostKeyChecking=no/, 'ssh: StrictHostKeyChecking=no gone');
like($py,   qr/StrictHostKeyChecking=yes/, 'ssh: StrictHostKeyChecking=yes set');
unlike($py, qr/AutoAddPolicy\(\)/,         'paramiko: AutoAddPolicy gone');
like($py,   qr/load_host_keys\(KNOWN_HOSTS\)/, 'paramiko: known_hosts loaded');
like($py,   qr/ssh-keyscan/,               'host-key error names ssh-keyscan');
like($py,   qr/check_local_request\(self\.headers/, 'POST gate runs in do_POST');

# host_name() must strip only a numeric port. urlsplit() reads a schemeless
# "localhost:8766" as scheme:path and empties it, which 403'd every POST and
# blocked /session.js when the console was opened as http://localhost:PORT;
# a bare IPv6 Host ("::1") must likewise survive for the loopback check.
{
    my $probe = join "\n",
        q{import importlib.util, sys},
        q{spec = importlib.util.spec_from_file_location('s', sys.argv[1])},
        q{m = importlib.util.module_from_spec(spec)},
        q{spec.loader.exec_module(m)},
        q{assert m.host_name('localhost:8766') == 'localhost'},
        q{assert m.host_name('::1') == '::1'},
        q{assert m.host_name('127.0.0.1:8766') == '127.0.0.1'},
        q{assert m.host_name('[::1]:8766') == '::1'},
        q{assert m.host_name('http://localhost:8766') == 'localhost'};
    # Probe travels in the environment: no shell quoting layer to eat the
    # single quotes (backtick-interpolated quotes get stripped and SyntaxError).
    local $ENV{PGEN_PROBE} = $probe;
    my $out = `python3 -c 'import os; exec(os.environ["PGEN_PROBE"])' '$server' 2>&1`;
    is($? >> 8, 0, 'host_name strips ports (localhost:PORT, bare ::1 survive)')
        or diag $out;
}

# paramiko_client() must survive a missing known_hosts file: packages ship
# only known_hosts.example, so load_host_keys() raising IOError into the
# generic handler would greet every fresh Windows install with an
# "Unexpected server error" naming a raw [Errno 2]. And a changed key must
# not fall into the transport catch-all: BadHostKeyException is a subclass of
# SSHException, so its arm must sit first or the operator loses the
# replace-the-line hint (appending a second key does not fix a mismatch).
{
    my ($pfn) = $py =~ /(def paramiko_client\b.*?)(?=\ndef )/s;
    ok($pfn, 'paramiko_client extracted for static guards') or die;
    my $try   = index($pfn, 'try:');
    my $load  = index($pfn, 'client.load_host_keys(KNOWN_HOSTS)');
    my $guard = index($pfn, 'except OSError');
    ok($load >= 0 && $try >= 0 && $try < $load && $guard > $load,
       'paramiko: missing known_hosts guarded around load_host_keys')
        or diag "try=$try load=$load guard=$guard";
    ok(index($pfn, 'known_hosts.example') >= 0 || index($py, 'host_key_hint') >= 0,
       'paramiko: missing-file path raises the operator hint');
    my $bad = index($pfn, 'except paramiko.BadHostKeyException');
    my $gen = index($pfn, 'except (paramiko.SSHException');
    ok($bad >= 0 && $gen > $bad, 'paramiko: changed-key arm precedes the generic SSH wrap')
        or diag "bad=$bad gen=$gen";
}

# Bundle freshness (PR-63 review): the committed downloadable bundles each
# carry their own copy of the console files. If they drift behind the repo,
# installs from the download run the UN-GATED server.py, silently undoing
# issue #51 for every zip user. Compare every non-runtime bundle member
# against its repo file. (The DMG wraps the same folder but is not
# content-readable here; its rebuild rides the same release choreography.)
{
    my $probe = join "\n",
        q{import hashlib, os, sys, zipfile},
        q{deployer = sys.argv[1]},
        q{bad = []},
        q{def zf_read(zp, name):},
        q{    with zipfile.ZipFile(zp) as zf: return zf.read(name)},
        q{for zn in ("PGenerator-GitHub-Deployer-Windows.zip", "PGenerator-GitHub-Deployer-macOS.zip"):},
        q{    zp = os.path.join(deployer, zn)},
        q{    if not os.path.isfile(zp): continue},
        q{    with zipfile.ZipFile(zp) as zf: names = zf.namelist()},
        q{    for name in names:},
        q{        if not name.startswith("PGenerator-GitHub-Deployer/") or "/runtime/" in name: continue},
        q{        if name.endswith("/"): continue},
        q{        rel = name[len("PGenerator-GitHub-Deployer/"):].rstrip("/")},
        q{        if not rel: continue},
        q{        repo = os.path.join(deployer, rel)},
        q{        data = zf_read(zp, name)},
        q{        if not os.path.isfile(repo): bad.append(zn + ":" + rel + " not in repo"); continue},
        q{        rb = open(repo, "rb").read()},
        q{        if hashlib.sha256(data).digest() != hashlib.sha256(rb).digest():},
        q{            bad.append(zn + ":" + rel + " differs from repo")},
        q{print("\n".join(bad))};
    local $ENV{PGEN_BUNDLE_PROBE} = $probe;
    my $out = `python3 -c 'import os; exec(os.environ["PGEN_BUNDLE_PROBE"])' '$deployer' 2>&1`;
    chomp $out;   # the probe's print() adds a trailing newline even with zero drift
    is($out, '', 'committed deployer bundles match the repo console files');
}

# raw_request(body, headers) -> (status, header_block, body)
sub raw_request {
    my ($method, $path, %opt) = @_;
    my $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1:' . $port, Timeout => 10)
        or return (0, '', '');
    my $body = $opt{body} // '';
    my @headers = ("Host: $opt{host}" , "Connection: close");
    push @headers, "Origin: $opt{origin}" if defined $opt{origin};
    push @headers, "X-Deployer-Session: $opt{token}" if defined $opt{token};
    if ($method eq 'POST') {
        push @headers, 'Content-Type: application/json', "Content-Length: " . length($body);
    }
    my $req = "$method $path HTTP/1.0\r\n" . join("\r\n", @headers) . "\r\n\r\n$body";
    print $s $req;
    local $/;
    my $res = <$s>;
    $s->close;
    $res //= '';
    my ($head, $resp_body) = split /\r\n\r\n/, $res, 2;
    my ($status) = $head =~ m{^HTTP/1\.[01] (\d{3})};
    return ($status // 0, $head, $resp_body // '');
}

my ($status) = raw_request('GET', '/api/health', host => "127.0.0.1:$port");
is($status, 200, 'health still open on loopback');

($status) = raw_request('POST', '/api/restart', host => "127.0.0.1:$port",
                        body => '{}');
is($status, 401, 'POST without session token rejected');

($status) = raw_request('POST', '/api/restart', host => "127.0.0.1:$port",
                        token => 'wrong-token-aaaaaaaaaaaaaaaa', body => '{}');
is($status, 401, 'POST with wrong session token rejected');

($status) = raw_request('POST', '/api/refs', host => "attacker.example:$port",
                        token => $token, body => '{"repository":"owner/repo"}');
is($status, 403, 'DNS-rebinding Host rejected even with the token');

($status) = raw_request('POST', '/api/refs', host => "127.0.0.1:$port",
                        origin => 'http://evil.example', token => $token,
                        body => '{"repository":"owner/repo"}');
is($status, 403, 'cross-origin request rejected even with the token');

# A non-ASCII session header must be a clean 401. compare_digest() raises
# TypeError on non-ASCII str inputs, so str/str comparison turned this into
# a 500; the gate must compare bytes.
($status) = raw_request('POST', '/api/restart', host => "127.0.0.1:$port",
                        token => "wrong\x{e9}-token-\x{fc}", body => '{}');
is($status, 401, 'non-ASCII session header is a clean 401, not a 500');

# A schemeless Host carrying a non-IP hostname with port (browsers send this
# for http://localhost:PORT) must reach the token check, not the Host gate.
($status) = raw_request('POST', '/api/restart', host => "localhost:$port",
                        origin => "http://localhost:$port", token => $token,
                        body => '{}');
isnt($status, 403, 'Host localhost:PORT is not rejected as non-loopback');

# Browsers send Origin on same-origin GET fetches and script loads, so the
# /session.js gate sees http://localhost:PORT too — it must serve, not 403.
($status) = raw_request('GET', '/session.js', host => "localhost:$port",
                        origin => "http://localhost:$port");
is($status, 200, 'session.js served for a localhost:PORT origin');

# The token itself is valid auth: /api/refs with a bogus repo must fail later
# in the pipeline (400 from validation), proving the gate passed it through.
($status) = raw_request('POST', '/api/refs', host => "127.0.0.1:$port",
                        token => $token, body => '{"repository":"not a repo"}');
is($status, 400, 'correct token passes the gate (fails later on validation)');

my ($s2, $head, $sess_body) = raw_request('GET', '/session.js', host => "127.0.0.1:$port");
is($s2, 200, 'session.js served');
like($sess_body, qr/\Q$token\E/, 'session.js carries the startup token');
like($head,      qr/[Cc]ache-[Cc]ontrol: no-store/, 'session.js is no-store');

($s2, $head) = raw_request('GET', '/', host => "127.0.0.1:$port");
like($sess_body, qr/__PGEN_SESSION__/, 'session.js defines the token global');

# kill the throwaway server
kill 'TERM', $pid;
close $SERVER;
waitpid $pid, 0;

done_testing();
