#!/usr/bin/perl

use strict;
use warnings;

BEGIN {
    my $dir = __FILE__;
    $dir =~ s{/[^/]+$}{};
    $dir =~ s{/bin$}{/share/PGenerator};
    $dir = '/usr/share/PGenerator' if $dir eq '';
    unshift @INC, $dir;
}

use Fcntl qw(:flock);
use Encode qw(encode);
use File::Path qw(make_path);
use HTTP::Tiny;
use IO::Select;
use JSON::PP ();
use POSIX qw(strftime);
use Time::HiRes qw(time);
use PGAutomation ();
use PGCalibrationLog ();
use PGAutomationETA ();
use PGAutomationLaunch ();
use PGAutomationPlan ();
use PGMath ();
use PGSignalCode ();
use PGLGCapabilities qw(lg_setting_values_agree lg_scoped_request_payload lg_setting_write_accepted lg_readback_unavailable_reason lg_picture_mode_read_forbidden);

my ($RUN_ID, $TOKEN, $LAUNCH_ATTEMPT) = @ARGV;
$TOKEN=PGAutomationLaunch::read_launch_token($RUN_ID,$LAUNCH_ATTEMPT) if defined($TOKEN) && $TOKEN eq '--launch';
my $LAUNCH_ACCEPTED = 0;
die "usage: pgen_automation_runner.pl RUN_ID TOKEN\n"
    if !defined($RUN_ID) || !defined($TOKEN)
    || !PGAutomation::safe_component($RUN_ID)
    || $TOKEN !~ /^[A-Za-z0-9_.:-]{8,200}$/;

my $RUN_DIR = PGAutomation::run_dir($RUN_ID);
my $RUN_FILE = $RUN_DIR . '/run.json';
my $CONTROL_FILE = $RUN_DIR . '/control.json';
my $EXECUTION_FILE = PGAutomation::base_dir() . '/execution.json';
my $RUNNER_LOCK_FILE = PGAutomation::base_dir() . '/runner.lock';
my $HTTP = HTTP::Tiny->new(
    agent   => 'PGenerator-automation/1',
    timeout => 45,
);
my $API_RETRY_INTERVAL = 5;
my $API_RETRY_WINDOW = 300;
# Stop and finish cleanup: every call is idempotent (worker stop/kill, meter
# session stop, CAL_END, run/end, status, idle pattern), so a transport
# failure gets a bounded retry instead of parking the batch as "cleanup
# required" with the TV possibly still in calibration mode. Each call may
# retry for up to $CLEANUP_RETRY_WINDOW, but one cleanup pass shares a single
# $CLEANUP_RETRY_BUDGET so a daemon that is down outright cannot stretch a
# stop to thirteen windows; once the budget is spent every call is a single
# attempt, as before.
my $CLEANUP_RETRY_WINDOW = 30;
my $CLEANUP_RETRY_BUDGET = 120;
my $CLEANUP_DEADLINE = 0;
sub _cleanup_window {
    $CLEANUP_DEADLINE = time() + $CLEANUP_RETRY_BUDGET if !$CLEANUP_DEADLINE;
    my $left = $CLEANUP_DEADLINE - time();
    return 0 if $left <= 0;
    return $left < $CLEANUP_RETRY_WINDOW ? $left : $CLEANUP_RETRY_WINDOW;
}
# The heartbeat rewrites run.json (0.9 s to decode on the appliance) and
# execution.json. At 2 s it kept the runner at 75 % CPU and slowed every
# helper spawn; the daemon reaps by pid, not heartbeat age, and the UI warns
# only after 60 s, so 10 s is well inside every consumer.
my $HEARTBEAT_INTERVAL = 10;
# How often a measuring worker's progress reaches the manifest (its timing
# feeds the duration estimates there); every tick reaches the live status.
our $WORKER_MANIFEST_INTERVAL = 60;
# A healthy /api/lg/status answer is reused for this long before the next LG
# action re-probes it; any LG connection failure drops it immediately.
my $LG_STATUS_CACHE_SECONDS = 10;
my $LG_STATUS_HEALTHY_AT = 0;
# Set when a reconnect has failed once Stop/failure cleanup has started
# (_stop_active, then the TPC/GSR and hazard restore after it). Each reconnect
# to a TV that does not answer costs about a minute, so the rest of that cleanup
# sends its LG requests without reconnecting first instead of retrying per call.
# Normal end-of-batch restoration runs without $STOP_HANDLED and is not affected.
my $LG_CLEANUP_UNREACHABLE = 0;
# Settings passes whose pre-read is known to be pointless: a full SDR picture
# reset has just restored factory values, so c4 must write regardless.
my %SKIP_PREREAD;

my $STOP_REQUESTED = 0;
my $PAUSE_REQUESTED = 0;
my $STOP_HANDLED = 0;
my $STOPPING = 0;
my $RESTORING_PREFLIGHT = 0;
my $ACTIVE_ITEM;
my $ACTIVE_STAGE = '';
my $ACTIVE_WORKER = '';
my $ACTIVE_WORKER_ID = '';
my ($ACTIVE_SERIES_KEY, $ACTIVE_SERIES_PHASE);
my $ETA_HISTORY=[];
my $LAST_CONTROL_POLL = 0;
my $LAST_HEARTBEAT = 0;
my $RUNNER_LOCK;
my $SETUP_WHITE_SEQUENCE = 0;

$SIG{TERM} = sub { $STOP_REQUESTED = 1; };
$SIG{INT}  = sub { $STOP_REQUESTED = 1; };

sub _log {
    my ($message, $event_time) = @_;
    $message = '' if !defined($message);
    my $stamp = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(defined($event_time) ? $event_time : time()));
    # JSON status text is decoded characters. Raw STDERR otherwise emits
    # Latin-1-range characters (e.g. the cube's superscript 3) as invalid UTF-8.
    print STDERR encode('UTF-8', "[$stamp] $message\n");
}

sub _log_action {
    my ($message) = @_;
    my $number = _active_item_number();
    $message =~ s/[\r\n]+/ /g;
    _log((defined($number) ? 'Job '.($number+1).' | ' : '').$message);
}

# Deliberately sparse: one notice after 20 seconds, then at most every 30.
# No payload values, pairing keys or worker debug dumps in routine output.
sub _log_wait {
    my ($label, $started, $last, $now) = @_;
    $now = time() if !defined($now);
    return if $now-$started<20 || (defined($$last) && $now-$$last<30);
    _log_action('Waiting for '.$label.' ('.int($now-$started).' s elapsed)');
    $$last=$now;
}

sub _api_wait_label {
    my ($path, $payload) = @_;
    if ($path eq '/api/lg/picture-settings/set') {
        my $settings=ref($payload) eq 'HASH' && ref($payload->{settings}) eq 'HASH' ? $payload->{settings} : {};
        return 'TV to accept picture mode '.$settings->{pictureMode} if defined($settings->{pictureMode}) && !ref($settings->{pictureMode});
        return 'TV to apply picture settings';
    }
    return {
        '/api/automation/readiness'=>'TV and meter readiness checks',
        '/api/lg/connect'=>'the saved TV connection',
        '/api/lg/picture-settings'=>'TV settings readback',
        '/api/lg/picture-settings/reset'=>'picture-mode reset',
        '/api/lg/sdr-calman-reset'=>'SDR calibration reset',
        '/api/lg/hdr-calman-reset'=>'HDR10 calibration reset',
        '/api/lg/dv-calman-reset'=>'Dolby Vision calibration reset',
        '/api/lg/3d-lut/reset'=>'3D LUT reset',
        '/api/lg/calibration-mode'=>'TV calibration-mode change',
        '/api/meter/read'=>'meter preparation and measurement',
        '/api/config'=>'generator output change',
        '/api/pattern'=>'the requested test pattern',
    }->{$path} || 'the generator response';
}

sub _run {
    return PGAutomation::read_json_file($RUN_FILE) || {};
}

sub _active_item_number {
    return undef if ref($ACTIVE_ITEM) ne 'HASH';
    return undef if !defined($ACTIVE_ITEM->{item_number}) || $ACTIVE_ITEM->{item_number} !~ /^\d+$/;
    return int($ACTIVE_ITEM->{item_number});
}

sub _worker_summary {
    my ($status) = @_;
    return {} if ref($status) ne 'HASH';
    my %summary;
    foreach my $key (qw(status phase current_name current_step total_steps current_delta_e message error_code debug)) {
        $summary{$key} = $status->{$key} if exists($status->{$key});
    }
    return \%summary;
}

sub _write_run {
    my ($run) = @_;
    return PGAutomation::write_json_atomic($RUN_FILE, $run, 0664);
}

sub _write_artifact {
    my ($path, $value) = @_;
    return 0 if !defined($path) || !defined($value);
    if (!PGAutomation::write_json_atomic($path, $value, 0664)) {
        $::LAST_ERROR = "Unable to write automation artifact $path";
        _log($::LAST_ERROR);
        return 0;
    }
    return 1;
}

# Declared ahead of _update_run, which overlays and publishes them.
my $STATUS_FILE = $RUN_DIR . '/status.json';
my @LIVE_KEYS = @PGAutomation::RUN_LIVE_KEYS;
my %LIVE;
my $STATUS_BASE;
my $STATUS_BASE_MTIME;
my $ETA_CONTEXT;

sub _update_run {
    my ($callback) = @_;
    my ($ok, $value, $error) = PGAutomation::with_lock($RUN_FILE, sub {
        my ($run) = @_;
        # Never replace an unreadable manifest with a skeleton: that would
        # silently drop the items, token and checkpoints.
        die "run manifest unreadable\n" if ref($run) ne 'HASH';
        die "Runner launch no longer owns this run\n" if $LAUNCH_ACCEPTED
            && (($run->{token}||'') ne $TOKEN || ($run->{launch_attempt}||'') ne ($LAUNCH_ATTEMPT||''));
        $callback->($run);
        # Advisory only: ETA failure must never stop or change calibration.
        eval { PGAutomationETA::update($run,time(),$ETA_HISTORY); 1 } or delete $run->{time_estimate};
        return $run;
    });
    _log("run state update failed: $error") if !$ok && $error;
    if ($ok && ref($value) eq 'HASH') {
        # What the manifest now says about the live fields is the latest word,
        # including a deletion; the next heartbeat or progress tick overlays
        # it. Liveness is the exception: the manifest's heartbeat is the last
        # forced one, so it must never roll a fresher tick back.
        $LIVE{$_} = $value->{$_} for grep { !/^heartbeat/ } @LIVE_KEYS;
        _publish_status($value, PGAutomation::file_mtime($RUN_FILE));
    }
    return $ok ? $value : undef;
}

# The live status file. The manifest carries every job's plan, contracts and
# evidence and grows with each checkpoint; on this appliance JSON::PP needs
# seconds to decode it, and the daemon used to do exactly that for every
# status poll while the runner rewrote it every few seconds. status.json is
# the compact copy the daemon serves instead: the run's state, progress and
# per-job outcomes, never evidence, capability catalogues or check lists. It
# is republished after every manifest write, and heartbeats and progress
# ticks update only it, so neither the daemon nor the runner pays for the
# manifest's size on the fast path.
sub _compact_run { return PGAutomation::compact_run($_[0]); }

# How far a worker_timing record has advanced, including solve/upload after
# the last measured point. A tail can start within the same clock tick.
sub _timing_stamp {
    my ($timing) = @_;
    return -1 if ref($timing) ne 'HASH';
    my $stamp = 0;
    for my $key (qw(started_at point_started_at tail_started_at)) {
        $stamp = $timing->{$key} if ($timing->{$key} || 0) > $stamp;
    }
    return $stamp;
}

sub _publish_status {
    my ($run, $manifest_mtime) = @_;
    if (ref($run) eq 'HASH') {
        $STATUS_BASE = _compact_run($run);
        $ETA_CONTEXT = PGAutomationETA::context($run,$ETA_HISTORY);
        # The progress tick owns worker_timing just as it owns the heartbeat.
        # This republish may be driven by the daemon's manifest write, which
        # carries the last durable copy; adopting it would roll a fresher
        # tick's point clock back and make the live estimate read the current
        # point as overdue.
        my $incoming = _timing_stamp($run->{worker_timing});
        my $live = _timing_stamp($LIVE{worker_timing});
        $LIVE{worker_timing} = $run->{worker_timing}
            if $incoming > $live || ($incoming == $live
                && (!(($LIVE{worker_timing} || {})->{tail_started_at})
                    || ($run->{worker_timing} || {})->{tail_started_at}));
        $STATUS_BASE_MTIME = defined($manifest_mtime) ? $manifest_mtime : PGAutomation::file_mtime($RUN_FILE);
    }
    return 0 if ref($STATUS_BASE) ne 'HASH';
    # Only the live keys overlay the compact manifest: a progress callback
    # may set other fields (worker_timing) that belong to the manifest alone.
    my %status = (%$STATUS_BASE, map { exists($LIVE{$_}) ? ($_ => $LIVE{$_}) : () } @LIVE_KEYS);
    if (ref($ETA_CONTEXT) eq 'HASH') {
        my %timing=(%$ETA_CONTEXT,map {exists($LIVE{$_}) ? ($_=>$LIVE{$_}) : ()} (@LIVE_KEYS,'worker_timing'));
        my $ok = eval {PGAutomationETA::update(\%timing,time(),$ETA_HISTORY);1};
        if ($ok && defined($timing{time_estimate})) {
            $status{time_estimate}=$LIVE{time_estimate}=$timing{time_estimate};
        } else {
            delete $LIVE{time_estimate};
            delete $status{time_estimate};
            # Running estimates may fall back to durable evidence. Paused,
            # stopping and terminal runs must not regain a live countdown,
            # even when the advisory calculation fails before clearing it.
            $status{time_estimate}=$STATUS_BASE->{time_estimate}
                if !$ok && ($status{status}||'') eq 'running' && defined($STATUS_BASE->{time_estimate});
        }
    }
    $status{published_at} = time();
    return PGAutomation::write_json_atomic($STATUS_FILE, \%status, 0600) ? 1 : 0;
}

# A fast-path update: heartbeat, worker progress and operation progress
# change the live status only. The manifest keeps the last durable state the
# runner wrote; anything a restart or resume must find still goes through
# _update_run.
sub _update_live {
    my ($callback) = @_;
    # The same ownership rule as _update_run, answered by the small launch
    # journal instead of the manifest: a cancelled or superseded launch must
    # not keep publishing its heartbeat and progress as the run's state.
    return 0 if $LAUNCH_ACCEPTED && defined($LAUNCH_ATTEMPT)
        && PGAutomationLaunch::read_launch_token($RUN_ID, $LAUNCH_ATTEMPT) ne $TOKEN;
    $callback->(\%LIVE);
    # The daemon writes the manifest too (a queue edit while running, a
    # control action). A tick must republish from that, not from the copy
    # taken before it, or the live view would hide the daemon's write until
    # the runner's next manifest write.
    # A daemon write also retires status.json, so a missing file is proof of
    # one even when its mtime cannot be trusted or landed inside the moment
    # between the runner's own write and its stat.
    my $manifest_mtime = PGAutomation::file_mtime($RUN_FILE);
    my $stale = ref($STATUS_BASE) ne 'HASH' || !-e $STATUS_FILE
        || (defined($manifest_mtime) && (!defined($STATUS_BASE_MTIME) || $manifest_mtime > $STATUS_BASE_MTIME));
    _publish_status($stale ? _run() : undef, $manifest_mtime);
    return 1;
}

# The TV capability profile a job or restoration context keeps. The daemon's
# reply also carries the whole settings capability table and picture-mode
# catalogue (about 50 KB); nothing in the runner reads them, and every copy
# on a job or in its evidence made the manifest that much slower to rewrite.
sub _slim_profile {
    my ($profile) = @_;
    return $profile if ref($profile) ne 'HASH';
    my %slim = %$profile;
    delete @slim{qw(settings_capabilities picture_mode_catalogue)};
    return \%slim;
}

sub _control {
    my $control = PGAutomation::read_json_file($CONTROL_FILE);
    return ref($control) eq 'HASH' ? $control : { request => 'none' };
}

sub _refresh_control {
    my $now = time();
    return if $now - $LAST_CONTROL_POLL < 0.5 && !$STOP_REQUESTED;
    $LAST_CONTROL_POLL = $now;
    my $request = _control()->{request} || 'none';
    $STOP_REQUESTED = 1 if $request eq 'stop';
    $PAUSE_REQUESTED = 1 if $request eq 'pause';
}

sub _write_execution {
    my ($run) = @_;
    $run = _run() if ref($run) ne 'HASH';
    my $value = {
        owner     => 'automation',
        run_id    => $RUN_ID,
        token     => $TOKEN,
        pid       => ($run->{status}||'') =~ /^(?:paused|interrupted)$/ ? 0 : $$,
        launch_attempt => $LAUNCH_ATTEMPT,
        updated_at => time(),
        status    => $run->{status} || 'running',
    };
    my ($ok) = PGAutomation::with_lock($EXECUTION_FILE, sub {
        my ($current) = @_;
        die "Automation execution belongs to another launch\n" if $LAUNCH_ACCEPTED
            && (ref($current) ne 'HASH' || ($current->{run_id}||'') ne $RUN_ID
                || ($current->{token}||'') ne $TOKEN || ($current->{launch_attempt}||'') ne ($LAUNCH_ATTEMPT||''));
        return $value;
    });
    return $ok;
}

sub _release_execution {
    my ($ok) = PGAutomation::with_lock($EXECUTION_FILE, sub {
        my ($current) = @_;
        return undef if ref($current) ne 'HASH'
            || ($current->{run_id} || '') ne $RUN_ID
            || ($current->{token} || '') ne $TOKEN
            || ($LAUNCH_ACCEPTED && ($current->{launch_attempt}||'') ne ($LAUNCH_ATTEMPT||''));
        return { __pg_automation_delete => 1 };
    });
    _log('execution lock release failed') if !$ok;
    return $ok;
}

sub _heartbeat {
    my ($force) = @_;
    my $now = time();
    return if !$force && $now - $LAST_HEARTBEAT < $HEARTBEAT_INTERVAL;
    $LAST_HEARTBEAT = $now;
    if (!$force) {
        # Routine liveness goes to the live status only; the manifest keeps
        # the pid and stage from the forced heartbeat at start and resume.
        _update_live(sub {
            my ($live) = @_;
            $live->{heartbeat} = $now;
            $live->{heartbeat_at} = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($now));
            $live->{runner_pid} = $$;
            my $active_item = _active_item_number();
            $live->{active_item} = $active_item if defined($active_item);
            $live->{active_stage} = $ACTIVE_STAGE if $ACTIVE_STAGE ne '';
        });
        # The small execution claim keeps its updated_at and status as before.
        eval { _write_execution({status=>(ref($STATUS_BASE) eq 'HASH' ? $STATUS_BASE->{status} : undef)}); 1 }
            or _log('execution heartbeat skipped: '.($@||'unknown'));
        return;
    }
    my $saved = _update_run(sub {
        my ($run) = @_;
        $run->{heartbeat} = $now;
        $run->{heartbeat_at} = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($now));
        $run->{runner_pid} = $$;
        my $active_item = _active_item_number();
        $run->{active_item} = $active_item if defined($active_item);
        delete($run->{active_grey_state});
        $run->{active_stage} = $ACTIVE_STAGE if $ACTIVE_STAGE ne '';
    });
    die 'Unable to persist automation heartbeat' if !ref($saved);
    die 'Unable to write automation execution heartbeat' if !_write_execution($saved);
}

sub _sleep_controlled {
    my ($seconds, $ignore_stop) = @_;
    $seconds = 0 if !defined($seconds) || $seconds < 0;
    my $deadline = time() + $seconds;
    while (time() < $deadline) {
        _refresh_control();
        return 0 if $STOP_REQUESTED && !$RESTORING_PREFLIGHT && !$ignore_stop;
        _heartbeat(0);
        select(undef, undef, undef, 0.5);
    }
    return 1;
}

sub _trace_context {
    my $number=_active_item_number();
    return {run=>$RUN_ID,stage=>$ACTIVE_STAGE,worker=>$ACTIVE_WORKER_ID,
        (defined($number)?(job=>$number+1):()),%{PGCalibrationLog::context($PGCalibrationLog::CONTEXT)}};
}

sub _api_once {
    my @args=@_;
    return PGCalibrationLog::api_call('Runner',_trace_context(),$args[0],$args[1],$args[2],undef,
        sub {_api_once_impl(@args)});
}

sub _api_once_impl {
    my ($method, $path, $payload, $allow_stop) = @_;
    $payload=lg_scoped_request_payload($path,$payload,$ACTIVE_ITEM);
    my $url = 'http://127.0.0.1' . $path;
    my %options = (
        headers => {
            Accept => 'application/json',
            'X-PGenerator-Trace' => PGCalibrationLog::header_value(),
        },
    );
    if ($method eq 'POST') {
        my $body = ref($payload) eq 'HASH' ? PGAutomation::clone($payload) : {};
        $body->{automation_token} = $TOKEN;
        $body->{automation_cleanup} = JSON::PP::true if $STOPPING || $allow_stop;
        $options{headers}{'Content-Type'} = 'application/json';
        $options{content} = PGAutomation::encode_json($body);
    }
    # Poll controls and maintain the heartbeat even while a reset or readiness
    # request holds the TV lane for several minutes.
    pipe(my $reader, my $writer) or die "Unable to create HTTP response pipe: $!";
    my $child = fork();
    die "Unable to launch HTTP request: $!" if !defined($child);
    if (!$child) {
        close($reader);
        # The child inherits the runner.lock descriptor; flock is only released
        # when every copy is closed, so a child stuck to its timeout would keep
        # a relaunched runner out. Drop it before the request.
        close($RUNNER_LOCK) if $RUNNER_LOCK;
        $SIG{TERM} = 'DEFAULT'; $SIG{INT} = 'DEFAULT';
        my $timeout = ref($payload) eq 'HASH' && $payload->{helper_timeout}
            ? $payload->{helper_timeout} + 20 : 60;
        # An LG action runs a helper the daemon may retry once after a
        # connect refusal; the child must outlive the daemon's worst case or
        # a still-running write gets re-posted. Without an explicit helper
        # timeout the daemon's largest per-action default (180 s) applies.
        if (_lg_action_path($path)) {
            $timeout = ref($payload) eq 'HASH' && $payload->{helper_timeout}
                ? 2 * $payload->{helper_timeout} + 25 : 2 * 180 + 25;
        }
        $timeout = 300 if $path eq '/api/automation/readiness';
        my $client = HTTP::Tiny->new(agent => 'PGenerator-automation/1', timeout => $timeout);
        my $response = eval { $client->request($method, $url, \%options) };
        print {$writer} PGAutomation::encode_json($response || {});
        close($writer);
        POSIX::_exit(0);
    }
    close($writer);
    my $select = IO::Select->new($reader);
    my $raw = '';
    my $wait_started=time();
    my $last_wait_log;
    while (1) {
        _refresh_control();
        _heartbeat(0);
        if ($STOP_REQUESTED && !$STOPPING && !$allow_stop) {
            kill('TERM', $child); close($reader); waitpid($child, 0);
            return {status => 'error', error_code => 'stopped', message => 'Automation stop requested'};
        }
        if (!$select->can_read(0.5)) {
            _log_wait(_api_wait_label($path,$payload),$wait_started,\$last_wait_log);
            next;
        }
        my $read = sysread($reader, my $chunk, 65536);
        last if !defined($read) || !$read;
        $raw .= $chunk;
    }
    close($reader); waitpid($child, 0);
    my $response = PGAutomation::decode_json($raw);
    if (!$response || !$response->{success}) {
        my $status = $response ? ($response->{status} || 0) : 0;
        my $reason = $response ? ($response->{reason} || 'HTTP request failed') : ($@ || 'HTTP request failed');
        return {
            status => 'error',
            error_code => 'daemon-unreachable',
            http_status => $status,
            message => $reason,
            _transport_error => 1,
        };
    }
    my $decoded = PGAutomation::decode_json($response->{content} || '');
    return $decoded if ref($decoded) eq 'HASH';
    return {
        status => 'error',
        error_code => 'invalid-daemon-response',
        message => 'The daemon returned invalid JSON',
        raw_response => substr($response->{content} || '', 0, 500),
    };
}

sub _ensure_lg_connection {
    my ($force) = @_;
    # _stop_active() runs once per runner; after it only cleanup follows.
    my $stop_cleanup = $STOP_HANDLED ? 1 : 0;
    return 0 if $stop_cleanup && $LG_CLEANUP_UNREACHABLE;
    my $ok = _reconnect_lg($force);
    if (!$ok && $stop_cleanup) {
        $LG_CLEANUP_UNREACHABLE = 1;
        _log('the paired LG TV did not answer during cleanup; skipping further LG reconnects for this cleanup: '
            . ($::LAST_ERROR || 'unknown error'));
    }
    return $ok;
}

sub _reconnect_lg {
    my ($force) = @_;
    return 1 if !$force && $LG_STATUS_HEALTHY_AT
        && time() - $LG_STATUS_HEALTHY_AT < $LG_STATUS_CACHE_SECONDS;
    $LG_STATUS_HEALTHY_AT = 0;
    my $status = _api_once('GET', '/api/lg/status', undef);
    if (!$force && ref($status) eq 'HASH' && $status->{connected} && !$status->{disconnected}) {
        $LG_STATUS_HEALTHY_AT = time();
        return 1;
    }
    my $ip = ref($status) eq 'HASH'
        ? ($status->{stored_ip} || $status->{manual_ip} || $status->{ip} || '') : '';
    if ($ip !~ /^[A-Za-z0-9_.:-]{1,120}$/) {
        $::LAST_ERROR = 'The paired LG TV has no reconnectable address';
        return 0;
    }
    for my $attempt (1..3) {
        my $connect = _api_once('POST', '/api/lg/connect', { ip => $ip });
        if (ref($connect) eq 'HASH' && $connect->{connected} && !$connect->{disconnected}) {
            _log($force ? 'refreshed the paired LG TV connection for automation'
                : 'reconnected the paired LG TV for automation');
            $LG_STATUS_HEALTHY_AT = time();
            return 1;
        }
        my $check = _api_once('GET', '/api/lg/status', undef);
        if (ref($check) eq 'HASH' && $check->{connected} && !$check->{disconnected}) {
            _log($force ? 'refreshed the paired LG TV connection for automation'
                : 'reconnected the paired LG TV for automation');
            $LG_STATUS_HEALTHY_AT = time();
            return 1;
        }
        _sleep_controlled(1) or return 0;
    }
    $::LAST_ERROR = 'The paired LG TV could not be reconnected';
    return 0;
}

sub _lg_action_path {
    my ($path) = @_;
    return 0 if !defined($path) || $path !~ m{\A/api/lg/};
    return 0 if $path =~ m{\A/api/lg/(?:status|connect|disconnect)\z};
    # Stopping the DV worker signals a local process; it never reaches the TV.
    return 0 if $path =~ m{\A/api/lg/dv-profile/(?:stop|kill)\z};
    return 1;
}

sub _lg_connection_failure {
    my ($response) = @_;
    return 0 if ref($response) ne 'HASH' || ($response->{status} || '') ne 'error';
    my $code = lc($response->{error_code} || '');
    return 1 if $code =~ /(?:lg|tv)[_-](?:unreachable|disconnected|connection)/;
    my $message = lc(join(' ', map { defined($_) ? "$_" : '' }
        @{$response}{qw(message error raw_error)}));
    return 1 if $message =~ /unable to connect to lg webos tv/;
    return 1 if $message =~ /connect the lg tv before/;
    # A helper that ran out of time ("LG TV did not finish ... within Ns") is
    # not a refusal: the TV was reached. Treating it as one cost three pairing
    # refreshes per settings pass.
    return 1 if $message =~ /lg webos tv.*(?:websocket|connection)/;
    return 0;
}

# Seconds per control observed on recent batched writes, each with 50%
# headroom. The budget follows the slowest of the last three samples, so one
# quick refusal cannot discard a correctly learned figure. A sample comes
# only from a write that reached the TV (a reply, or a helper that ran out
# of time) and is clamped to the budget that was requested, so a daemon
# outage or a pairing refresh cannot pin the figure at the cap. Samples are
# kept in the manifest so a resumed run starts from what its TV measured,
# not from the floor that ran out on 18-19 Sep 2026.
my @LG_CONTROL_SAMPLES;
# The 30 s session allowance in every budget is not a per-control cost, and
# a sample never exceeds what the 300 s ceiling allows the largest group the
# runner writes (18 controls), so consecutive timeouts converge there rather
# than growing by half each time.
my $LG_CONTROL_SESSION_SECONDS = 30;
my $LG_CONTROL_TIMEOUT_CAP = 300;
my $LG_CONTROL_LARGEST_GROUP = 18;
# Keys the daemon reads when a readback names none (lg_picture_default_keys).
my $LG_DEFAULT_READ_KEYS = 26;
my $LG_CONTROL_SAMPLE_CAP = ($LG_CONTROL_TIMEOUT_CAP - $LG_CONTROL_SESSION_SECONDS) / $LG_CONTROL_LARGEST_GROUP;
my $LG_CONTROL_STAMP_WARNED = 0;
sub _lg_control_seconds {
    my $slowest = 0;
    foreach my $sample (@LG_CONTROL_SAMPLES) { $slowest = $sample if $sample > $slowest; }
    return $slowest;
}
sub _reset_lg_control_seconds {
    $LG_CONTROL_STAMP_WARNED = 0;
    # A seeded sample obeys the same cap as a measured one, whatever runner
    # stamped it.
    @LG_CONTROL_SAMPLES = map { $_ > $LG_CONTROL_SAMPLE_CAP ? $LG_CONTROL_SAMPLE_CAP : $_ }
        grep { defined($_) && !ref($_) && $_ =~ /^\d+(?:\.\d+)?$/ && $_ > 0 } @_;
    shift @LG_CONTROL_SAMPLES while @LG_CONTROL_SAMPLES > 3;
    return scalar(@LG_CONTROL_SAMPLES);
}
sub _note_lg_control_seconds {
    my ($count, $elapsed, $budget) = @_;
    # Small groups measure mostly the session allowance; only a group of
    # four or more says anything about the per-control cost, and a write
    # that finished inside the allowance says nothing either.
    return if !$count || $count < 4 || !defined($elapsed) || $elapsed <= 0;
    $elapsed = $budget if defined($budget) && $budget > 0 && $elapsed > $budget;
    my $per_control = ($elapsed - $LG_CONTROL_SESSION_SECONDS) / $count;
    return if $per_control <= 0;
    my $sample = 1.5 * $per_control;
    $sample = $LG_CONTROL_SAMPLE_CAP if $sample > $LG_CONTROL_SAMPLE_CAP;
    push @LG_CONTROL_SAMPLES, $sample;
    shift @LG_CONTROL_SAMPLES while @LG_CONTROL_SAMPLES > 3;
    my @samples = @LG_CONTROL_SAMPLES;
    my $stamped = eval { ref(_update_run(sub { $_[0]{lg_control_samples} = [@samples]; })) ? 1 : 0 };
    if (!$stamped && !$LG_CONTROL_STAMP_WARNED++) {
        my $why = $@ || '';
        $why =~ s/[\r\n]+/ /g;
        _log('Unable to record the measured control write time in the manifest; a resumed run starts from the default budget'.($why ne '' ? ": $why" : ''));
    }
    return _lg_control_seconds();
}
sub _seed_lg_control_seconds {
    my ($run) = @_;
    return 0 if ref($run) ne 'HASH' || ref($run->{lg_control_samples}) ne 'ARRAY';
    return _reset_lg_control_seconds(@{$run->{lg_control_samples}});
}

# Helper timeouts the runner asks the daemon for. Only paths whose daemon
# action is known are filled in; anything else keeps the daemon's own
# per-action default and gets the widest child timeout instead.
sub _lg_helper_timeout_for {
    my ($path, $payload) = @_;
    $payload = {} if ref($payload) ne 'HASH';
    # The per-control figure starts at the 5-7 s measured on the G3 on 16 Sep
    # 2026 with headroom, and follows what this run's batched writes
    # actually took: at 10 s per control (18-19 Sep 2026, slow readbacks)
    # the constant 174 s budget ran out and every SDR job fell back to one
    # write at a time.
    my $measured = _lg_control_seconds();
    my $per_control = $measured > 8 ? $measured : 8;
    if ($path eq '/api/lg/picture-settings') {
        # A 19-key readback took 59 s on the G3 (18 Sep 2026, c1 of job 1)
        # with a 60 s budget: one second from failing a job during setup.
        # Reads follow the same measured figure per key, never below the
        # 120 s that covered that readback.
        # Without a key list the daemon reads its whole default set.
        my $keys = ref($payload->{keys}) eq 'ARRAY' && @{$payload->{keys}} ? scalar(@{$payload->{keys}}) : $LG_DEFAULT_READ_KEYS;
        my $read = $LG_CONTROL_SESSION_SECONDS + int($per_control + 0.5) * $keys;
        $read = 120 if $read < 120;
        $read = $LG_CONTROL_TIMEOUT_CAP if $read > $LG_CONTROL_TIMEOUT_CAP;
        return $read;
    }
    return undef if $path ne '/api/lg/picture-settings/set';
    my $settings = ref($payload->{settings}) eq 'HASH' ? $payload->{settings} : {};
    # White-balance arrays are the DDC path with its own daemon default.
    return undef if grep { ref($settings->{$_}) } keys %$settings;
    # The helper writes and reads back each control inside one session.
    my $timeout = $LG_CONTROL_SESSION_SECONDS + int($per_control + 0.5) * scalar(keys %$settings);
    $timeout = 45 if $timeout < 45;
    $timeout = $LG_CONTROL_TIMEOUT_CAP if $timeout > $LG_CONTROL_TIMEOUT_CAP;
    return $timeout;
}

# Which LG actions may be re-posted after a transport error. Reads and
# absolute-value control writes are idempotent (a retry queues behind the
# still-running first request on the daemon's single TV lane). Everything
# else, resets, uploads, run begin, panel-protection disable (a second reply
# would overwrite the restore baseline) and CAL_START, gets one attempt; an
# unlisted LG path fails closed to one attempt.
sub _lg_retry_window {
    my ($path, $payload) = @_;
    $payload = {} if ref($payload) ne 'HASH';
    if ($path eq '/api/lg/picture-settings/set') {
        return 0 if $payload->{reset_ddc_baseline} || $payload->{clear_ddc_baseline} || $payload->{force_ddc_white_balance};
        my $settings = ref($payload->{settings}) eq 'HASH' ? $payload->{settings} : {};
        return 0 if grep { /^(?:whiteBalance|adjustingLuminance)/ && ref($settings->{$_}) } keys %$settings;
        return $API_RETRY_WINDOW;
    }
    return $API_RETRY_WINDOW if $path eq '/api/lg/picture-settings';
    # CAL_END is idempotent and Stop cleanup depends on it; CAL_START is not.
    return $payload->{enabled} ? 0 : 30 if $path eq '/api/lg/calibration-mode';
    return 0;
}

# Only a transport's explicit pre-send classification or the helper's
# connection-establishment refusal proves that a mutation was not delivered.
sub _request_not_sent {
    my ($response) = @_;
    return 0 if ref($response) ne 'HASH';
    return 1 if ($response->{delivery_state}||'') eq 'not-sent';
    return 0 if ($response->{delivery_state}||'') eq 'outcome-unknown';
    return ($response->{message}||'') =~ /\A(?:Unable to connect to LG WebOS TV|Connect the LG TV before)/i ? 1 : 0;
}

sub _api {
    my ($method, $path, $payload, $allow_stop, $retry_window) = @_;
    # A Stop may arrive during normal end-of-batch restoration. Finish the
    # request already on the wire, then abandon further mode/settings work.
    die "Original mode restoration cancelled by Stop\n"
        if $RESTORING_PREFLIGHT && _current_mode_stop_requested();
    $allow_stop = $RESTORING_PREFLIGHT ? 1 : 0 if !defined($allow_stop);
    $allow_stop = 1 if $RESTORING_PREFLIGHT;
    my $lg_action = _lg_action_path($path);
    if ($lg_action && $method eq 'POST') {
        $payload = {} if ref($payload) ne 'HASH';
        if (!$payload->{helper_timeout}) {
            my $helper_timeout = _lg_helper_timeout_for($path, $payload);
            $payload = { %$payload, helper_timeout => $helper_timeout } if $helper_timeout;
        }
    }
    $retry_window = $lg_action ? _lg_retry_window($path, $payload) : $API_RETRY_WINDOW if !defined($retry_window);
    $retry_window = 0 if $retry_window < 0;
    my $last;
    my $started = time();
    my $attempt = 0;
    # LG reconnects stay enabled while stopping or restoring preflight
    # context: those paths must reach the TV to release ownership, and the
    # retry is bounded (three pairing refreshes, and none once a Stop/failure
    # cleanup reconnect has failed; see $LG_CLEANUP_UNREACHABLE), so a transient websocket
    # refusal right after a picture-mode switch no longer turns a fully
    # checked queue into a "cleanup required" interruption.
    my $lg_preflighted = 0;
    my $lg_reconnects = 0;
    while (1) {
        $attempt++;
        die "Original mode restoration cancelled by Stop\n"
            if $RESTORING_PREFLIGHT && _current_mode_stop_requested();
        _refresh_control() unless $allow_stop;
        if ($STOP_REQUESTED && !$allow_stop) {
            return { status => 'error', error_code => 'stopped', message => 'Automation stop requested' };
        }
        _heartbeat(0);
        if ($lg_action && !$lg_preflighted) {
            $lg_preflighted = 1;
            _ensure_lg_connection();
        }
        $last = _api_once($method, $path, $payload, $allow_stop);
        if (!$last->{_transport_error}) {
            if ($lg_action && _lg_connection_failure($last) && $lg_reconnects < 3
                && (_lg_retry_window($path,$payload)>0 || _request_not_sent($last))) {
                $LG_STATUS_HEALTHY_AT = 0;
                $lg_reconnects++;
                _log("LG request $method $path reported a connection failure; refreshing the pairing (attempt $lg_reconnects)");
                if (_ensure_lg_connection(1)) {
                    next;
                }
            }
            $::LAST_ERROR_CODE = (($last->{status} || '') eq 'error' && $last->{error_code})
                ? $last->{error_code} : '';
            return $last;
        }
        my $remaining = $retry_window - (time() - $started);
        last if $remaining <= 0;
        my $delay = $remaining < $API_RETRY_INTERVAL ? $remaining : $API_RETRY_INTERVAL;
        _log("daemon request $method $path failed; retrying in ${API_RETRY_INTERVAL} seconds (attempt $attempt, ${retry_window}s window)");
        # A cleanup call (allow_stop) keeps its retry window even though a stop
        # is what started it; the plain sleep would return at once.
        last if !_sleep_controlled($delay, $allow_stop);
    }
    $::LAST_ERROR_CODE = 'daemon-unreachable';
    return $last || { status => 'error', error_code => 'daemon-unreachable' };
}

sub _ping_ok {
    my ($ping) = @_;
    return 0 if ref($ping) ne 'HASH' || $ping->{_transport_error} || ($ping->{status} || '') eq 'error';
    return ($ping->{ok} || ($ping->{status} || '') ne '') ? 1 : 0;
}

sub _response_ok {
    my ($response) = @_;
    return ref($response) eq 'HASH' && (($response->{status} || '') eq 'ok'
        || ($response->{status} || '') eq 'started'
        || ($response->{status} || '') eq 'measuring'
        || ($response->{status} || '') eq 'running');
}

sub _item_snapshot {
    my ($item) = @_;
    return $item if ref($item) eq 'HASH';
    return {};
}

sub _signal {
    my ($item) = @_;
    my $signal = lc($item->{signal_format} || $item->{signal_mode} || $item->{format} || 'sdr');
    $signal = 'hdr10' if $signal eq 'hdr';
    return $signal =~ /^(?:sdr|hdr10|hlg|dv)$/ ? $signal : 'sdr';
}

sub _picture_mode {
    my ($item) = @_;
    return $item->{picture_mode} || $item->{pictureMode} || '';
}

sub _stages {
    my ($item) = @_;
    my $stages = ref($item->{stages}) eq 'HASH' ? $item->{stages} : {};
    my $pre = exists($stages->{pre_readings}) ? $stages->{pre_readings}
        : exists($item->{pre_readings}) ? $item->{pre_readings} : 0;
    my $cal = exists($stages->{calibration}) ? $stages->{calibration}
        : exists($item->{calibration}) ? $item->{calibration} : 1;
    my $post = exists($stages->{post_readings}) ? $stages->{post_readings}
        : exists($item->{post_readings}) ? $item->{post_readings} : 0;
    return {
        pre => $pre ? 1 : 0,
        calibration => $cal ? 1 : 0,
        post => $post ? 1 : 0,
        apply_all => exists($stages->{apply_all}) ? ($stages->{apply_all} ? 1 : 0)
            : exists($item->{apply_all}) ? ($item->{apply_all} ? 1 : 0) : 1,
    };
}

sub _series_selection {
    my ($item, $which) = @_;
    my $field = $which eq 'post' ? 'post_series' : 'pre_series';
    my $selection = $item->{$field};
    $selection = $item->{series} if ref($selection) ne 'ARRAY';
    $selection = ['greyscale-21', 'colors-30', 'saturations-24']
        if ref($selection) ne 'ARRAY' || !@$selection;
    my %valid = map { $_ => 1 } qw(greyscale-21 colors-30 saturations-24);
    my @keys;
    foreach my $key (@$selection) {
        next if !defined($key) || !$valid{$key};
        push @keys, $key if !grep { $_ eq $key } @keys;
    }
    return @keys;
}

sub _series_info {
    my ($key) = @_;
    return ('greyscale', 21) if $key eq 'greyscale-21';
    return ('colors', 30) if $key eq 'colors-30';
    return ('saturations', 24) if $key eq 'saturations-24';
    return ('greyscale', 21);
}

sub _default_range {
    my ($item) = @_;
    return "$item->{signal_range}" if defined($item->{signal_range}) && $item->{signal_range} =~ /^[12]$/;
    return "$item->{pattern_signal_range}" if defined($item->{pattern_signal_range}) && $item->{pattern_signal_range} =~ /^[12]$/;
    return '2';
}

sub _measurement_options {
    my ($item) = @_;
    return map { $_ => $item->{$_} } grep {
        /^patch_insert/ || /^(?:measurement_meter_port|measurement_meter_usb_id|observer|low_light)$/
    } keys %$item;
}

# The step builder and every worker must see the same transport. In particular,
# omitting color_format makes the SDR DPG worker default to RGB even when its
# supplied steps describe the YCbCr 99/105/109 ladder.
sub _transport_options {
    my ($item) = @_;
    my $cal = ref($item->{calibration}) eq 'HASH' ? $item->{calibration} : {};
    return (
        color_format => $item->{color_format} // '0',
        max_bpc => $item->{max_bpc} || $cal->{max_bpc} || (_signal($item) eq 'dv' ? 8 : 10),
    );
}

sub _series_payload {
    my ($item, $key, $run_id) = @_;
    my ($type, $points) = _series_info($key);
    my $signal = _signal($item);
    my $cal = ref($item->{calibration}) eq 'HASH' ? $item->{calibration} : {};
    my $target_gamma = $item->{target_gamma} || $cal->{target_gamma}
        || ($signal eq 'sdr' ? 'bt1886' : $signal eq 'hlg' ? 'hlg' : 'st2084');
    $target_gamma = 'st2084' if $signal eq 'dv';
    my $payload = {
        _transport_options($item),
        type => $type,
        points => $points,
        display_type => $item->{display_type} || 'lcd',
        ccss_override => $item->{ccss_override} || '',
        delay_ms => int($item->{delay_ms} // 1000),
        patch_size => int($item->{patch_size} || 10),
        signal_mode => $signal,
        signal_range => _default_range($item),
        pattern_signal_range => _default_range($item),
        transport_signal_range => $item->{transport_signal_range} || _default_range($item),
        max_luma => 0 + ($item->{max_luma} || 1000),
        target_gamma => $target_gamma,
        target_gamut => $signal eq 'dv' ? 'p3d65' : ($item->{target_gamut} || 'auto'),
        dv_map_mode => $signal eq 'dv' ? '1' : '',
        requested_signal_mode => $signal,
        refresh_rate => $item->{refresh_rate} || '',
        measurement_meter_port => $item->{measurement_meter_port} || '',
        measurement_meter_usb_id => $item->{measurement_meter_usb_id} || '',
        observer => '1931_2',
        pattern_provider => $item->{pattern_provider} || 'local',
        target_white_use_measured => JSON::PP::true,
        custom_d65_enabled => JSON::PP::true,
        target_white_x => ($item->{target_white} || $cal->{target_white} || {})->{x} // 0.3127,
        target_white_y => ($item->{target_white} || $cal->{target_white} || {})->{y} // 0.3290,
        series_report_key => $key,
        full_autocal_run_id => $run_id,
        require_device_ready => JSON::PP::false,
    };
    foreach my $key (keys %$item) {
        $payload->{$key} = $item->{$key} if $key =~ /^patch_insert/ || $key eq 'low_light';
    }
    return $payload;
}

sub _grey_code {
    my ($signal, $ire, $range, $max_bpc) = @_;
    $max_bpc = 10 if !defined($max_bpc) || $max_bpc !~ /^(?:8|10|12)$/;
    my $max = $max_bpc == 12 ? 4095 : $max_bpc == 10 ? 1023 : 255;
    if ($signal eq 'dv') {
        return int(256 + ($ire / 100.0) * 3504 + 0.5);
    }
    if ($range eq '1') {
        my $min = $max_bpc == 10 ? 64 : $max_bpc == 12 ? 256 : 16;
        my $span = $max_bpc == 10 ? 876 : $max_bpc == 12 ? 3504 : 219;
        return int($min + ($ire / 100.0) * $span + 0.5);
    }
    return int(($ire / 100.0) * $max + 0.5);
}

sub _grey_steps {
    my ($item) = @_;
    my $signal = _signal($item);
    my $range = _default_range($item);
    my $cal = ref($item->{calibration}) eq 'HASH' ? $item->{calibration} : {};
    my %transport = _transport_options($item);
    my $max_bpc = $transport{max_bpc};
    my @ires;
    if ($signal eq 'hdr10' || $signal eq 'dv') {
        @ires = (100, 0, 90, 80, 70, 60, 50, 45, 40, 35, 30, 25, 20, 15, 10, 7, 5, 4, 2.7, 2, 1.4);
    } elsif ($range eq '1' && ($item->{color_format} || '0') =~ /^(?:1|2)$/) {
        @ires = (100, 0, 2.3, 3, 4, 5, 7, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 99, 105, 109);
    } else {
        @ires = (100, 0, 2.3, 3, 4, 5, 7, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95);
    }
    if ($cal->{dark_detail}) {
        my @fillers = ($signal eq 'hdr10' || $signal eq 'dv')
            ? (1,2.3,3,3.7,6,8,55,65,75,85,95) : (2,2.7,3.7,6,8,9);
        my %seen = map { $_ => 1 } @ires;
        push @ires, grep { !$seen{$_}++ } @fillers;
    }
    # Use the same signal-code policy as the guided series path. In particular,
    # HDR20 has a slot table. Standard DV authors 12-bit Limited components
    # inside an 8-bit Full HDMI tunnel, just like the manual wizard. The link's
    # range/bit depth must not become the source-code range/bit depth.
    my $code_policy = PGSignalCode::signal_code_policy({
        signal_mode=>$signal, pattern_range=>$range, max_bpc=>$max_bpc,
        color_format=>$item->{color_format} || '0',
        ($signal eq 'sdr' ? (autocal_26_codes=>1)
         : $signal eq 'hdr10' ? (hdr20_codes=>1,hdr20_use_limited=>1,hdr20_full=>($range ne '1' ? 1 : 0))
         : (dv_series=>1,dv_series_code_bits=>12,dv_series_full_range=>0)),
    });
    die "Unable to build greyscale signal-code policy\n" if !defined($code_policy);
    my @steps;
    foreach my $ire (@ires) {
        my $encoded = PGSignalCode::signal_percent_to_code($code_policy,$ire);
        die "Unable to encode greyscale step $ire\n" if ref($encoded) ne 'HASH';
        my $code = $encoded->{code};
        my $step = {
            name => sprintf('%.4g%%', $ire),
            ire => 0 + $ire,
            stimulus => 0 + $ire,
            nominal_ire => 0 + $ire,
            r => $code,
            g => $code,
            b => $code,
            r_code => $code,
            g_code => $code,
            b_code => $code,
            input_max => $encoded->{input_max},
            signal_r_pct => 0 + $ire,
            signal_g_pct => 0 + $ire,
            signal_b_pct => 0 + $ire,
            target_ire => 0 + $ire,
            autocal_white_reference => abs($ire - 100) < 0.001 ? JSON::PP::true : undef,
            ddc_layout => $signal eq 'sdr' ? 'sdr26' : 'hdr20',
        };
        if (abs($ire) < 0.001) {
            $step->{autocal_reference_only} = JSON::PP::true;
            $step->{autocal_read_only} = JSON::PP::true;
        }
        if (abs($ire - 100) < 0.001) {
            $step->{read_delay_ms} = 3000;
            if ($signal eq 'sdr' && $range eq '1'
                && ($item->{color_format} || '0') =~ /^(?:1|2)$/) {
                $step->{autocal_reference_only} = JSON::PP::true;
                $step->{autocal_read_only} = JSON::PP::true;
                $step->{autocal_legal_white_anchor} = JSON::PP::true;
                $step->{ddc_target_ire} = 99;
                $step->{autocal_order_ire} = 98.95;
            }
        } elsif ($signal eq 'sdr' && $ire > 0 && $ire <= 25) {
            $step->{read_delay_ms} = $ire <= 10 ? 6000 : 3200;
        }
        push @steps, $step;
    }
    return \@steps;
}

sub _grey_payload {
    my ($item) = @_;
    my $signal = _signal($item);
    my $cal = ref($item->{calibration}) eq 'HASH' ? $item->{calibration} : {};
    my $steps = _grey_steps($item);
    my $target_gamma = $cal->{target_gamma} || $item->{target_gamma} || 'bt1886';
    $target_gamma = '2.2' if $signal eq 'hdr10' || $signal eq 'dv';
    my $body = {
        _measurement_options($item),
        _transport_options($item),
        type => 'greyscale',
        points => 26,
        display_type => $item->{display_type} || 'lcd',
        ccss_override => $item->{ccss_override} || '',
        delay_ms => int($item->{delay_ms} // 1000),
        patch_size => int($item->{patch_size} || 10),
        signal_mode => $signal,
        signal_range => _default_range($item),
        pattern_signal_range => _default_range($item),
        transport_signal_range => $item->{transport_signal_range} || _default_range($item),
        ($signal eq 'dv' ? (dv_map_mode => '2') : ()),
        target_delta_e => 0 + ($cal->{target_delta_e} || $item->{target_delta_e} || 0.5),
        delta_e_formula => $cal->{delta_e_formula} || $item->{delta_e_formula} || 'deitp',
        target_gamma => $target_gamma,
        target_white => $cal->{target_white} || $item->{target_white} || { x => 0.3127, y => 0.3290 },
        target_luminance => ($signal eq 'sdr' ? 0 + ($item->{target_luminance} || $cal->{target_luminance} || 100) : undef),
        setup_luminance_reference => ($signal eq 'sdr' ? 0 + ($cal->{setup_luminance_reference} || $item->{target_luminance} || 100) : undef),
        headroom_target_luminance => ($signal eq 'sdr' ? 0 + ($cal->{headroom_target_luminance} || 0) : undef),
        picture_mode => _picture_mode($item),
        tv_input => $item->{tv_input}||'',
        force_ddc_white_balance => JSON::PP::true,
        preflight_generation_profile => $item->{generation_profile},
        lg_autocal_sdr_1d_dpg_upload_enabled => JSON::PP::true,
        lg_autocal_26 => JSON::PP::true,
        lg_greyscale_21 => JSON::PP::false,
        lg_autocal_26_full_ddc_spine => JSON::PP::true,
        lg_extended_sdr_16_255 => $signal eq 'sdr' ? JSON::PP::true : JSON::PP::false,
        dark_detail => $cal->{dark_detail} ? 1 : 0,
        restore_factory_levels => JSON::PP::false,
        reset_ddc_baseline => JSON::PP::false,
        full_workflow => JSON::PP::true,
        full_autocal_run_id => $RUN_ID,
        full_autocal_phase => 'first-greyscale',
        max_iterations => int($cal->{max_iterations} || 36),
        headroom_max_iterations => int($cal->{headroom_max_iterations} || 60),
        max_polish_iterations => int($cal->{max_polish_iterations} // 16),
        precision_polish_iterations => int($cal->{precision_polish_iterations} // 18),
        low_light => ref($item->{low_light}) eq 'HASH' ? $item->{low_light} : {},
        refresh_rate => $item->{refresh_rate} || '',
        require_device_ready => JSON::PP::false,
        steps => $steps,
    };
    delete $body->{$_} for grep { !defined($body->{$_}) } keys %$body;
    return $body;
}

sub _lattice_patches {
    my ($item) = @_;
    my $cal = ref($item->{calibration}) eq 'HASH' ? $item->{calibration} : {};
    if (ref($cal->{lattice_patches}) eq 'ARRAY' && @{$cal->{lattice_patches}}) {
        # Older queued snapshots used r/g/b instead of the worker's percent keys.
        return [map { ref($_) eq 'HASH' && !defined($_->{name}) && defined($_->{r})
            ? {%$_, r_pct=>$_->{r}, g_pct=>$_->{g}, b_pct=>$_->{b}} : $_ } @{$cal->{lattice_patches}}];
    }
    my $method = $cal->{method} || 'hybrid';
    my $size = $cal->{lattice_size} || 5;
    $size = $1 if ($cal->{profile_source} || '') =~ /^hybrid([359])$/;
    $size = 5 if $size !~ /^(?:3|5|9)$/;
    my @levels = map { 100 * $_ / ($size - 1) } 0..($size - 1);
    my @patches;
    my %seen;
    my $add = sub {
        my $name = join('/',map { sprintf('%.6g',$_) } @_);
        push @patches,{name=>$name} if !$seen{$name}++;
    };
    if ($method eq 'skeleton' || $method eq 'hybrid') {
        $add->(0,0,0);
        for my $level (5,10,20,30,40,50,60,70,80,90,100) {
            $add->($level,$level,$level);$add->($level,0,0);$add->(0,$level,0);$add->(0,0,$level);
        }
    }
    return \@patches if $method eq 'skeleton';
    foreach my $r (@levels) {
        foreach my $g (@levels) {
            foreach my $b (@levels) {
                $add->($r,$g,$b);
            }
        }
    }
    return \@patches;
}

sub _three_d_payload {
    my ($item, $run, $item_number) = @_;
    my $automatic_settings=_item_settings($item);
    my $signal = _signal($item);
    my $cal = ref($item->{calibration}) eq 'HASH' ? $item->{calibration} : {};
    my $method = lc($cal->{method} || $item->{method} || ($signal eq 'hdr10' ? 'matrix' : 'hybrid'));
    $method = 'matrix' if $signal eq 'hdr10' && $method ne 'imported';
    $method = 'hybrid' if $method !~ /^(?:matrix|ramp|lattice|skeleton|hybrid|imported)$/;
    my $grey = {};
    if (defined($item_number)) {
        my $saved = PGAutomation::read_json_file(
            PGAutomation::item_dir($RUN_ID, $item_number) . '/calibration/grey-state.json'
        );
        $grey = $saved if ref($saved) eq 'HASH';
    }
    $grey = {} if ref($grey) ne 'HASH';
    my $body = {
        _measurement_options($item),
        _transport_options($item),
        method => $method,
        type => 'lg-3d-lut',
        display_type => $item->{display_type} || 'lcd',
        ccss_override => $item->{ccss_override} || '',
        delay_ms => int($item->{delay_ms} // 1000),
        patch_size => int($item->{patch_size} || 10),
        signal_mode => $signal,
        requested_signal_mode => $signal,
        signal_range => _default_range($item),
        pattern_signal_range => _default_range($item),
        transport_signal_range => $item->{transport_signal_range} || _default_range($item),
        target_gamma => $signal eq 'hdr10' ? 'st2084' : ($cal->{target_gamma} || $item->{target_gamma} || 'bt1886'),
        target_gamut => $signal eq 'hdr10' ? ($item->{target_gamut} || 'p3d65') : ($cal->{target_gamut} || $item->{target_gamut} || 'bt709'),
        picture_mode => _picture_mode($item),
        tv_input => $item->{tv_input}||'',
        upload => JSON::PP::true,
        full_workflow => JSON::PP::true,
        full_autocal_run_id => $RUN_ID,
        full_autocal_phase => '3d-lut',
        automation_processing_settings => {map {$_=>$automatic_settings->{$_}} grep {_processing_setting($_)} keys %$automatic_settings},
        lattice_patches => ($method =~ /^(?:lattice|skeleton|hybrid)$/ ? _lattice_patches($item) : undef),
        solve_matrix_only => $cal->{lattice_residuals} ? JSON::PP::false : JSON::PP::true,
        solve_cube_size => int($cal->{solve_cube_size} || 17),
        refresh_rate => $item->{refresh_rate} || '',
        require_device_ready => JSON::PP::false,
        post_check => JSON::PP::false,
        preflight_lg_generation => $item->{lg_generation},
        preflight_generation_profile => $item->{generation_profile},
        lg_autocal_hdr20_postcal_shadow_enable => $cal->{shadow_fix} ? 1 : 0,
        low_light => ref($item->{low_light}) eq 'HASH' ? $item->{low_light} : {},
    };
    if ($signal eq 'hdr10') {
        $body->{upload_command} = 'BT2020_3D_LUT_DATA';
        $body->{get_command} = 'GET_3D_LUT_DATA';
        $body->{full_workflow_peak_luminance} = $grey->{hdr20_1d_tonemap_peak_luminance}
            || $grey->{hdr_tone_map_peak_luminance} || $grey->{hdr20_1d_dpg_white_ref}
            || $grey->{calibrated_white_luminance} if ref($grey) eq 'HASH';
        $body->{full_workflow_dpg_data} = $grey->{hdr20_1d_dpg_data}
            if ref($grey->{hdr20_1d_dpg_data}) eq 'ARRAY' && @{$grey->{hdr20_1d_dpg_data}} == 3072;
    }
    $body->{full_workflow_dpg_data} = $grey->{sdr_1d_dpg_data}
        if $signal eq 'sdr' && ref($grey->{sdr_1d_dpg_data}) eq 'ARRAY' && @{$grey->{sdr_1d_dpg_data}} == 3072;
    delete $body->{$_} for grep { !defined($body->{$_}) } keys %$body;
    return $body;
}

sub _dv_payload {
    my ($item) = @_;
    my $cal = ref($item->{calibration}) eq 'HASH' ? $item->{calibration} : {};
    my $range = _default_range($item);
    return {
        _measurement_options($item),
        _transport_options($item),
        signal_mode => 'dv',
        dv_map_mode => '2',
        input_max => 4095,
        display_type => $item->{display_type} || 'lcd',
        ccss_override => $item->{ccss_override} || '',
        delay_ms => int($item->{delay_ms} // 1000),
        pattern_signal_range => $range,
        signal_range => $range,
        transport_signal_range => $range,
        picture_mode => _picture_mode($item),
        tv_input => $item->{tv_input}||'',
        patch_size => int($item->{patch_size} || 10),
        refresh_rate => $item->{refresh_rate} || '',
        upload => JSON::PP::false,
        keep_calibration_mode => JSON::PP::true,
        calibration_mode_active => JSON::PP::true,
        full_autocal_run_id => $RUN_ID,
        require_device_ready => JSON::PP::false,
        max_luma => 1000,
        preflight_generation_profile => $item->{generation_profile},
    };
}

sub _status_terminal {
    my ($status) = @_;
    return defined($status) && $status =~ /^(?:complete|error|failed|cancelled|stopped|idle)$/;
}

sub _clear_active_worker {
    $ACTIVE_WORKER = '';
    $ACTIVE_WORKER_ID = '';
}

sub _start_worker {
    my ($path, $status_path, $payload) = @_;
    $ACTIVE_WORKER_ID=$RUN_ID.'-'.(_active_item_number()//0).'-'.PGAutomation::new_id();
    $payload={%$payload,automation_worker_id=>$ACTIVE_WORKER_ID,calibration_trace=>_trace_context()};
    my $result;
    for my $attempt (1..6) {
        $result = _api('POST', $path, $payload, 0, 0);
        return $result if ($result->{status} || '') eq 'started';
        return $result if $STOP_REQUESTED;
        my $probe = _api('GET', $status_path, undef, 0, 0);
        if (PGAutomation::worker_id($probe) eq $ACTIVE_WORKER_ID
            && (($probe->{status}||'') eq 'running' || _status_terminal($probe->{status}))) {
            return {status => 'started', adopted => JSON::PP::true};
        }
        last if !$result->{retryable} && !$result->{_transport_error}
            && ($result->{error_code} || '') !~ /finishing/;
        my $delay = ($result->{retry_after_ms} || 1000) / 1000;
        $delay = 3 if $delay > 3; $delay = 0.25 if $delay < 0.25;
        _sleep_controlled($delay) or last;
    }
    return $result;
}

sub _worker_progress {
    my ($status) = @_;
    my $message=$status->{message} || '';
    # Sample counters belong in live status. Save point transitions once,
    # plus actual measurements/events and exceptional state changes.
    $message='' if $message =~ /^Reading\b/i;
    $message='' if $status->{activity_sequence} && $message =~ / uploaded \((?:max|point) dE=/;
    $message='' if $message eq ($status->{current_name}||'');
    return join(' | ', grep { defined($_) && !ref($_) && $_ ne '' }
        $status->{status}, $status->{current_name}, $message,
        defined($status->{current_step}) && ($status->{status}||'') ne 'complete'
            ? 'Patch '.$status->{current_step}.' / '.($status->{total_steps}||'?') : undef);
}

sub _log_worker_events {
    my ($status,$last) = @_;
    return if ref($status->{activity_events}) ne 'ARRAY';
    my @events=sort {$a->{seq}<=>$b->{seq}} grep {
        ref($_) eq 'HASH' && defined($_->{seq}) && $_->{seq}=~/^\d+$/ && $_->{seq}>$$last
        && defined($_->{message}) && !ref($_->{message})
    } @{$status->{activity_events}};
    _log_action('Worker activity gap: earlier detail events expired before collection; see saved worker log')
        if @events && $events[0]{seq}>$$last+1;
    for my $event (@events) {
        next if $event->{seq}<=$$last;
        my $message=substr($event->{message},0,1500);$message=~s/[\r\n]+/ /g;
        my $number=_active_item_number();
        my $timestamp=defined($event->{time}) && !ref($event->{time}) && $event->{time}=~/^\d+(?:\.\d+)?$/ ? $event->{time} : undef;
        _log((defined($number)?'Job '.($number+1).' | ':'').'1D LUT | '.$message,$timestamp);
        $$last=$event->{seq};
    }
}

# Status routes with a summary view (?view=summary&after=N). The projection
# carries every key the wait loop reads, at a few KB instead of the full state
# (160 KB late in a greyscale stage, half a second to decode on the appliance
# every two seconds). The full state is fetched once at the end, so callers
# and the archive still see the whole result. Each route maps to the
# worker's state file, read directly when the daemon cannot serve it.
my %WORKER_SUMMARY_STATUS_PATHS = (
    '/api/meter/lg-autocal/status'    => '/tmp/meter_lg_autocal.json',
    '/api/meter/lg-3d-autocal/status' => '/tmp/meter_lg_3d_autocal.json',
    '/api/lg/dv-profile/status'       => '/tmp/meter_lg_dv_profile.json',
);

# The worker's own state file, the same file the archive step reads. Tests
# replace this to keep off the appliance paths.
sub _worker_state_file_read {
    my ($status_path) = @_;
    my $file = $WORKER_SUMMARY_STATUS_PATHS{$status_path} || '';
    return undef if $file eq '';
    return PGAutomation::read_json_file($file);
}

# A state file stands in for a failed full read only when it is this
# attempt's finished state: a hash, terminal, stamped with the summary's id.
sub _worker_state_file_usable {
    my ($summary, $saved) = @_;
    return 0 if ref($saved) ne 'HASH' || !_status_terminal($saved->{status} || '');
    return PGAutomation::worker_id($saved) eq PGAutomation::worker_id($summary) ? 1 : 0;
}

sub _worker_status_poll_path {
    my ($status_path, $after) = @_;
    return $status_path if !$WORKER_SUMMARY_STATUS_PATHS{$status_path};
    $after = 0 if !defined($after) || $after !~ /^\d+$/;
    return $status_path . '?view=summary&after=' . $after;
}

# After a terminal summary the full state is read once. A read that failed
# (transport error, undecodable or stopped reply, no reply) or that belongs
# to another worker is not this worker's result, so the summary stands. A
# same-worker or unstamped read is adopted even when it is not terminal: the
# daemon's own liveness check may have seen the worker again after the
# summary flipped it, and the loop then keeps polling.
sub _worker_full_status_usable {
    my ($summary, $full) = @_;
    return 0 if ref($full) ne 'HASH' || $full->{_transport_error};
    return 0 if ($full->{error_code} || '') =~ /^(?:daemon-unreachable|invalid-daemon-response|stopped)$/;
    # The full read must belong to the same attempt as the summary. An
    # unstamped read after a stamped summary is not this attempt's state
    # (only outside interference with /tmp produces one); the terminal
    # summary stands rather than adopting an idle that would end the wait
    # as a worker-identity mismatch for a stage that had finished.
    return PGAutomation::worker_id($full) eq PGAutomation::worker_id($summary) ? 1 : 0;
}

sub _wait_worker {
    my ($status_path, $kind, $item) = @_;
    my $started = time();
    my $last_keepalive = 0;
    my $last_log_progress = '';
    my $last_activity_sequence = 0;
    my $summary_view = $WORKER_SUMMARY_STATUS_PATHS{$status_path} ? 1 : 0;
    my $full_read_warned = 0;
    my ($timing_started,$timing_base,$timing_last)=($started,0,0);
    my $point_started=$started;
    my @point_seconds;
    my @point_elapsed=(0);
    my $timing_reset=0;
    my $tail_started;
    my ($last_progress_write, $last_progress_digest, $last_manifest_write) = (0, '', time());
    my ($owned_pid, $owned_ticks) = (0, '');
    # A worker has not stamped its pid yet right after launch. Tolerate an
    # unstamped idle for a bounded window then, never by global process match.
    my $idle_startup_grace = 30;
    while (time() - $started < 21600) {
        _refresh_control();
        if ($STOP_REQUESTED) {
            _log("$kind interrupted by stop request before worker status became terminal");
            return undef;
        }
        my $status = _api('GET', _worker_status_poll_path($status_path, $last_activity_sequence), undef);
        return $status if $status->{error_code} && $status->{error_code} eq 'daemon-unreachable';
        if ($summary_view && _status_terminal($status->{status} || '')
            && !(($status->{status} || '') eq 'idle' && PGAutomation::worker_id($status) eq '')) {
            # The summary is a projection; callers and the archive need the
            # full state, so read it once now the worker has reached an end.
            # An unstamped idle is a transient poll, not worth the request.
            my $full = _api('GET', $status_path, undef);
            if (_worker_full_status_usable($status, $full)) {
                $status = $full;
            } else {
                # The daemon could not serve the full state. The worker's own
                # state file carries the measurements, curves and export paths
                # the stage callers and the archive need, so adopt it when it
                # is this attempt's finished state; only then does the summary
                # stand, and the archived evidence is a projection.
                my $saved = _worker_state_file_read($status_path);
                if (_worker_state_file_usable($status, $saved)) {
                    $status = $saved;
                    _log("$kind finished but its full status could not be read; using the worker's state file as written, without the daemon's terminal fix-ups")
                        if !$full_read_warned++;
                } elsif (!$full_read_warned++) {
                    _log("$kind finished but its full status could not be read and its state file is not this attempt's finished state; keeping the summary, so the archived evidence is a projection");
                }
            }
        }
        my $state = $status->{status} || '';
        my $status_id = PGAutomation::worker_id($status);
        # A transient idle poll carries no attempt id. It is never adopted as a
        # result; it is only tolerated below while the owned worker is alive.
        my $idle_unstamped = $state eq 'idle' && $status_id eq '';
        if ($ACTIVE_WORKER_ID && $status_id ne $ACTIVE_WORKER_ID && !$idle_unstamped) {
            return {status=>'error',error_code=>'worker-identity-mismatch',message=>'Worker status belongs to a different run/job/stage attempt; refusing to adopt or archive it'};
        }
        if ($ACTIVE_WORKER_ID && $status_id eq $ACTIVE_WORKER_ID && $status->{worker_pid}) {
            ($owned_pid, $owned_ticks) = ($status->{worker_pid}, $status->{worker_start_ticks} || '');
        }
        my $now = time();
        if ($now - $last_keepalive >= 60) {
            $last_keepalive = $now;
            my $tv = _api('GET', '/api/lg/status', undef);
            if (ref($tv) eq 'HASH' && $tv->{disconnected}) {
                _ensure_lg_connection();
                $tv = _api('GET', '/api/lg/status', undef, 0, 0);
            }
            if (ref($tv) ne 'HASH' || ($tv->{status} || '') eq 'error' || $tv->{disconnected}
                || lc($tv->{tv_power} || $tv->{power} || '') =~ /^(?:off|standby|powering-off)$/) {
                $status = {
                    status => 'error',
                    error_code => 'tv-unreachable',
                    message => 'The LG TV stopped answering or entered standby',
                };
                return $status;
            }
        }
        my $step=0+($status->{current_step}||0);
        $tail_started=$now if !defined($tail_started) && $ACTIVE_WORKER eq '3d'
            && ($status->{phase}||'') =~ /^(?:building|upload|upload_probe|tone_map_upload|postcal_shadow.*|post_check|dpg_shadow_smoothing)$/;
        if ($state eq 'running' && $step<$timing_last) {
            ($timing_started,$timing_base)=($now,$step>0?$step-1:0);
            @point_seconds=();$point_started=$now;
            @point_elapsed=(0);$timing_reset=1;
        } elsif ($state eq 'running' && $step>$timing_last) {
            if ($timing_last>0 && $now>$point_started) {
                push @point_seconds,($now-$point_started)/($step-$timing_last);
                shift @point_seconds while @point_seconds>5;
                for my $point ($timing_last..$step-1) {
                    $point_elapsed[$point]=$point_started-$timing_started+($now-$point_started)*($point-$timing_last+1)/($step-$timing_last);
                }
            }
            $point_started=$now;
        }
        $timing_last=$step;
        _log_worker_events($status,\$last_activity_sequence);
        my $progress = _worker_progress($status);
        if ($progress ne $last_log_progress) {
            $last_log_progress = $progress;
            my $number = _active_item_number();
            _log((defined($number) ? 'Job '.($number+1).' | ' : '')."$kind | $progress");
        }
        my $digest = PGAutomation::encode_json(_worker_summary($status));
        if (_status_terminal($state) || $now-$last_progress_write >= 10
            || ($step != $timing_base && $digest ne $last_progress_digest && $now-$last_progress_write >= 5)) {
        my $progress_update = sub {
            my ($run) = @_;
            $run->{worker_status} = _worker_summary($status);
            $run->{worker_timing}={started_at=>$timing_started,start_step=>$timing_base,kind=>$ACTIVE_WORKER,stage=>$ACTIVE_STAGE,series_key=>$ACTIVE_SERIES_KEY||'',recent_point_seconds=>[@point_seconds],point_started_at=>$point_started,tail_started_at=>$tail_started};
            $run->{active_stage} = $ACTIVE_STAGE;
            my $active_item = _active_item_number();
            $run->{active_item} = $active_item if defined($active_item);
        };
        # Every tick reaches the live status; the manifest (which the ETA
        # reads its timing from) only at the end of the stage and once a
        # minute, so a long sweep is not spent re-encoding job evidence.
        if (_status_terminal($state) || $now-$last_manifest_write >= $WORKER_MANIFEST_INTERVAL) {
            die 'Unable to persist worker progress' if !ref(_update_run($progress_update));
            $last_manifest_write = $now;
        } else {
            _update_live($progress_update);
        }
        ($last_progress_write,$last_progress_digest)=($now,$digest);
        }
        if ($state eq 'idle') {
            if (_idle_worker_alive($status, $owned_pid, $owned_ticks)
                || ($idle_unstamped && !$owned_pid && time() - $started < $idle_startup_grace)) {
                _sleep_controlled(2) or return undef;
                next;
            }
            # An unstamped idle with no live owned worker is not this attempt's
            # result. Fail fast with the same refusal a foreign status gets.
            return {status=>'error',error_code=>'worker-identity-mismatch',message=>'Worker status is idle without this attempt\'s identity and no worker this attempt launched is alive; refusing to adopt or archive it'}
                if $idle_unstamped && $ACTIVE_WORKER_ID;
        }
        if (_status_terminal($state)) {
            $status->{timing_tail_seconds}=$now-$tail_started if $state eq 'complete' && defined($tail_started) && $now>$tail_started;
            # Save complete trajectories only. A reset/retry is not the same
            # ordered pass, and must not train the next job's point weights.
            if ($state eq 'complete' && !$timing_reset && $ACTIVE_WORKER eq 'grey'
                && ($status->{total_steps}||0)>0 && $now>$timing_started) {
                my $n=$status->{total_steps};
                $point_elapsed[$n]=$now-$timing_started;
                if (@point_elapsed==$n+1 && !grep {!defined($_)} @point_elapsed) {
                    $status->{timing_curve}={total_steps=>0+$n,fractions=>[map {$_/($now-$timing_started)} @point_elapsed]};
                }
            }
            return $status;
        }
        return { status => 'error', error_code => 'worker-timeout', message => "$kind exceeded six hours" }
            if time() - $started >= 21600;
        _sleep_controlled(2) or return undef;
    }
    return { status => 'error', error_code => 'worker-timeout', message => "$kind exceeded six hours" };
}

# The batch and per-job readiness passes both report a job's manual checks.
# Keep one entry per (job, outcome, level, message), or per name for a passing
# global check whose wording varies between passes.
sub _push_preflight_check {
    my ($result,$check,$seen)=@_;
    return if ref($check) ne 'HASH';
    # Passing global equipment checks are identified by name: their text can
    # vary between passes (free disk space, "reconnected") without being new.
    # A failure keeps its own text, so a different reason in a later job pass
    # is still listed.
    my $global=$check->{ok} && !defined($check->{item_number}) && defined($check->{name}) && $check->{name} ne '';
    my $key=join("\0",$check->{item_number}//'',$check->{ok}?1:0,$check->{level}//'',$global ? "name:$check->{name}" : ($check->{message}//$check->{name}//''));
    return if $seen->{$key}++;
    push @{$result->{checks}},$check;
}

# Idle tolerance: keep waiting while the worker this attempt launched is still
# running. A stamped status proves ownership by id. An unstamped idle poll
# cannot, so only the pid this attempt already recorded from a stamped status
# counts: its start ticks where the kernel exposes them, else a pid liveness
# probe. Without that evidence there is nothing to wait for, and the global
# kind-pattern probe is never used as ownership (see _worker_process_alive).
# _wait_worker separately allows a bounded 30 s startup grace before the first
# stamped status has recorded a pid.
sub _idle_worker_alive {
    my ($status, $owned_pid, $owned_ticks) = @_;
    return _worker_process_alive($ACTIVE_WORKER) if !$ACTIVE_WORKER_ID;
    return _owned_worker_alive($status) if PGAutomation::worker_id($status) eq $ACTIVE_WORKER_ID;
    return 0 if !$owned_pid;
    my $birth = PGAutomation::process_start_ticks($owned_pid);
    return ($birth eq $owned_ticks ? 1 : 0) if $birth ne '' && defined($owned_ticks) && $owned_ticks ne '';
    return kill(0, $owned_pid) ? 1 : 0;
}

sub _owned_worker_alive {
    my ($status)=@_;
    return 0 if ref($status) ne 'HASH' || !$ACTIVE_WORKER_ID || PGAutomation::worker_id($status) ne $ACTIVE_WORKER_ID;
    my $birth=PGAutomation::process_start_ticks($status->{worker_pid});
    return $birth ne '' && $birth eq ($status->{worker_start_ticks}||'');
}

# Emergency Stop audits every worker sharing the physical TV/meter. This is
# deliberately broader than result adoption, which always requires an attempt ID.
sub _worker_process_alive {
    my ($kind) = @_;
    my %pattern = (
        series => '[m]eter_series\\.sh',
        grey   => '[m]eter_lg_autocal\\.pl',
        '3d'   => '[m]eter_lg_3d_autocal\\.pl',
        dv     => '[m]eter_lg_dv_profile\\.pl',
    );
    my $needle = $pattern{$kind} || '';
    return 0 if $needle eq '';
    my $alive = `pgrep -f '$needle' 2>/dev/null`;
    return $alive =~ /\d/ ? 1 : 0;
}

sub _copy_worker_files {
    my ($item_number, $kind, $state) = @_;
    my $dir = PGAutomation::item_dir($RUN_ID, $item_number) . '/calibration';
    return 0 if $dir eq '';
    if (!-d $dir && !eval { make_path($dir, { mode => 0700 }); 1 }) {
        _log("unable to create calibration artifact directory $dir");
        return 0;
    }
    # The daemon deliberately leaves user files alone, so a previous guided
    # run may still have state in /tmp. Capture only a worker state supplied by
    # the current wait, or a partial state while that worker is still active;
    # later checkpoints preserve the copy already made for this item.
    my $capture_current = ref($state) eq 'HASH' || $ACTIVE_WORKER eq $kind;
    return 1 if !$capture_current;
    my $copy_if_present = sub {
        my ($source, $destination) = @_;
        return 1 if !-f $source;
        if (!PGAutomation::copy_artifact($source, $destination)) {
            _log("unable to copy automation artifact $source to $destination");
            return 0;
        }
        return 1;
    };
    my %status_files=(grey=>['/tmp/meter_lg_autocal.json','grey-state.json'],
        '3d'=>['/tmp/meter_lg_3d_autocal.json','3d-state.json'],dv=>['/tmp/meter_lg_dv_profile.json','dv-profile-state.json']);
    my $owned_state=ref($state) eq 'HASH' ? $state : PGAutomation::read_json_file($status_files{$kind}[0]);
    if ($ACTIVE_WORKER_ID && (ref($owned_state) ne 'HASH' || PGAutomation::worker_id($owned_state) ne $ACTIVE_WORKER_ID)) {
        # Preserve a transport/TV failure generated by the waiting runner,
        # but never store it as though it came from the calibration worker.
        $::LAST_ERROR=ref($state) eq 'HASH' && ($state->{status}||'') eq 'error'
            ? ($state->{message}||'Worker result could not be verified')
            : 'Refusing to archive worker evidence from a different attempt';
        $::LAST_ERROR_CODE=$state->{error_code} if ref($state) eq 'HASH' && $state->{error_code};
        return 0;
    }
    my $ok = 1;
    $ok &&= _write_artifact($dir.'/'.$status_files{$kind}[1],$owned_state) if ref($owned_state) eq 'HASH';
    if ($kind eq 'grey') {
        $ok &&= $copy_if_present->('/tmp/meter_lg_autocal.log', "$dir/grey-log.txt");
        $ok &&= _write_artifact("$dir/grey-state.json", $state) if ref($state) eq 'HASH' && !-f "$dir/grey-state.json";
    } elsif ($kind eq '3d') {
        $ok &&= $copy_if_present->('/tmp/meter_lg_3d_autocal.log', "$dir/3d-log.txt");
        $ok &&= _write_artifact("$dir/3d-state.json", $state) if ref($state) eq 'HASH' && !-f "$dir/3d-state.json";
        if (ref($state) eq 'HASH' && ref($state->{export}) eq 'HASH') {
            foreach my $key (qw(cube_path payload_path)) {
                my $source = $state->{export}{$key} || '';
                next if $source eq '' || $source !~ m{/var/lib/PGenerator/lg/luts/[A-Za-z0-9_.-]+$};
                my ($name) = $source =~ m{/([^/]+)$};
                $ok &&= $copy_if_present->($source, "$dir/$name") if $name;
            }
        }
    } elsif ($kind eq 'dv') {
        $ok &&= $copy_if_present->('/tmp/meter_lg_dv_profile.log', "$dir/dv-profile-log.txt");
        $ok &&= _write_artifact("$dir/dv-profile-state.json", $state) if ref($state) eq 'HASH' && !-f "$dir/dv-profile-state.json";
        my $measurements = ref($state) eq 'HASH'
            ? ($state->{measurements} || $state->{dv_profile_measurements}) : undef;
        $ok &&= _write_artifact("$dir/dv-profile-measurements.json", $measurements)
            if ref($measurements) eq 'HASH';
    }
    return $ok;
}

sub _snapshot_series {
    my ($item_number, $which, $key, $status) = @_;
    if ($ACTIVE_WORKER_ID && PGAutomation::worker_id($status) ne $ACTIVE_WORKER_ID) {
        $::LAST_ERROR = $status->{message} || 'Refusing to archive series evidence from another worker attempt';
        $::LAST_ERROR_CODE = $status->{error_code} || 'worker-identity-mismatch';
        return undef;
    }
    my $directory = PGAutomation::item_dir($RUN_ID, $item_number) . '/' . $which;
    if (!-d $directory && !eval { make_path($directory, { mode => 0700 }); 1 }) {
        $::LAST_ERROR = "Unable to create series artifact directory $directory";
        return undef;
    }
    my %snapshot;
    foreach my $field (qw(type points steps readings white_reading black_reading signal_mode target_gamma target_gamut calibration_target_context max_luma dv_map_mode color_format max_bpc signal_range pattern_signal_range transport_signal_range status report_key automation_worker_id full_autocal_run_id worker_pid worker_start_ticks)) {
        $snapshot{$field} = $status->{$field} if exists($status->{$field});
    }
    $snapshot{type} = (_series_info($key))[0] if !exists($snapshot{type});
    $snapshot{points} = (_series_info($key))[1] if !exists($snapshot{points});
    $snapshot{steps} = [] if ref($snapshot{steps}) ne 'ARRAY';
    $snapshot{readings} = [] if ref($snapshot{readings}) ne 'ARRAY';
    my $context = _series_payload(_item_snapshot($ACTIVE_ITEM), $key, $RUN_ID);
    foreach my $field (qw(signal_mode target_gamma target_gamut max_luma dv_map_mode color_format max_bpc signal_range pattern_signal_range transport_signal_range)) {
        $snapshot{$field} = $context->{$field} if !defined($snapshot{$field});
    }
    $snapshot{status} = $status->{status} || 'error' if !defined($snapshot{status});
    $snapshot{report_key} = $key;
    return undef if !_write_artifact("$directory/$key.json", \%snapshot);
    return \%snapshot;
}

sub _run_series {
    my ($item_number, $item, $which) = @_;
    my @keys = _series_selection($item, $which);
    my $item_dir = PGAutomation::item_dir($RUN_ID, $item_number);
    make_path("$item_dir/$which", { mode => 0700 }) if !-d "$item_dir/$which";
    foreach my $key (@keys) {
        _refresh_control();
        return 0 if $STOP_REQUESTED;
        _log("launching meter worker series $key for $which readings");
        $ACTIVE_WORKER = 'series';
        ($ACTIVE_SERIES_KEY, $ACTIVE_SERIES_PHASE) = ($key, $which);
        _update_run(sub { $_[0]{active_series} = {key=>$key, phase=>$which}; });
        # Series are workers too: give each sweep a fresh attempt and reconcile
        # lost start replies through the same ownership-fenced launch path.
        my $started = _start_worker('/api/meter/series', '/api/meter/series/status',
            _series_payload($item, $key, $RUN_ID));
        if (!$started || ($started->{status} || '') ne 'started') {
            _clear_active_worker();
            $::LAST_ERROR = $started->{message} || 'Unable to start meter series';
            return 0;
        }
        my $status = _wait_worker('/api/meter/series/status', "series $key", $item);
        if ($STOP_REQUESTED) {
            _log("meter worker series $key retained for stop cleanup");
            return 0;
        }
        return 0 if !ref($status);
        my $snapshot = _snapshot_series($item_number, $which, $key, $status);
        if (!ref($snapshot)) {
            _clear_active_worker();
            return 0;
        }
        if (($status->{status} || '') ne 'complete') {
            $::LAST_ERROR = _series_failure_message($key, $status);
            $::LAST_ERROR_CODE = $status->{error_code} || $status->{error} || 'meter-series-failed';
            return 0;
        }
        _clear_active_worker();
        _update_run(sub {
            my ($run) = @_;
            $run->{last_series} = { item => $item_number, phase => $which, key => $key };
        });
    }
    undef $ACTIVE_SERIES_KEY; undef $ACTIVE_SERIES_PHASE;
    return 1;
}

sub _series_failure_message {
    my ($key, $status) = @_;
    my $message = $status->{message} || $status->{current_name} || 'Worker returned ' . ($status->{status} || 'no status');
    my $step = defined($status->{current_step}) ? ' at patch ' . $status->{current_step}
        . ($status->{total_steps} ? '/' . $status->{total_steps} : '') : '';
    return "Series $key failed$step: $message"
        . ($status->{debug} ? ' Driver: ' . $status->{debug} : '');
}

sub _observed_settings {
    my ($response) = @_;
    return {} if ref($response) ne 'HASH';
    foreach my $key (qw(picture_settings settings)) {
        return $response->{$key} if ref($response->{$key}) eq 'HASH';
    }
    return {};
}

sub _mode_agrees {
    my ($expected, $observed) = @_;
    return 0 if !defined($expected) || $expected eq '' || !defined($observed) || $observed eq '';
    my $e = lc("$expected");
    my $o = lc("$observed");
    $e =~ s/[\s_-]+//g;
    $o =~ s/[\s_-]+//g;
    # Match the helper's TV wire aliases in both directions. Keep the Dolby
    # prefix so an SDR Filmmaker token can never verify a Dolby Vision mode.
    foreach my $mode ($e, $o) {
        $mode =~ s/^dolbyvision/dolbyhdr/;
        $mode = 'dolbyhdrcinema' if $mode =~ /^dolbyhdr(?:filmmaker(?:mode)?|cinemadark)$/;
        $mode = 'dolbyhdrcinemabright' if $mode eq 'dolbyhdrcinemahome';
        $mode = 'normal' if $mode eq 'standard';
    }
    return $e eq $o ? 1 : 0;
}

sub _signal_mode_compatible {
    my ($signal, $observed) = @_;
    return 0 if !defined($observed) || $observed eq '';
    my $mode = lc("$observed");
    $mode =~ s/[\s_-]+//g;
    return $mode !~ /^(?:hdr|dolby)/ if ($signal || '') eq 'sdr';
    return $mode =~ /^hdr/ if ($signal || '') eq 'hdr10' || ($signal || '') eq 'hlg';
    return $mode =~ /^dolby(?:vision|hdr)/ if ($signal || '') eq 'dv';
    return 0;
}

sub _tv_gamma_value {
    my ($value) = @_;
    return $value if !defined($value) || ref($value);
    my %aliases = ('1.9'=>'low', '2.2'=>'medium', '2.4'=>'high1', bt1886=>'high2', 'bt.1886'=>'high2');
    return $aliases{lc($value)} || $value;
}

sub _value_agrees {
    my ($expected, $observed, $key) = @_;
    return _mode_agrees($expected, $observed) if ($key || '') eq 'pictureMode';
    return 0 if !defined($observed);
    ($expected, $observed) = map { _tv_gamma_value($_) } ($expected, $observed) if ($key || '') eq 'gamma';
    if (!ref($expected) && !ref($observed) && "$expected" =~ /^-?\d+(?:\.\d+)?$/
        && "$observed" =~ /^-?\d+(?:\.\d+)?$/) {
        return abs(($expected + 0) - ($observed + 0)) <= 0.1;
    }
    return lc("$expected") eq lc("$observed") if !ref($expected) && !ref($observed);
    return PGAutomation::encode_json($expected) eq PGAutomation::encode_json($observed);
}

sub _append_setting_check {
    my ($item_number, $point, $record) = @_;
    my $path = PGAutomation::item_dir($RUN_ID, $item_number) . '/settings-checks.ndjson';
    $record->{checkpoint} = $point;
    $record->{timestamp} = time();
    return PGAutomation::append_line_locked($path, PGAutomation::encode_json($record) . "\n");
}

sub _best_available_manual {
    my ($item)=@_;
    my $plan=$item->{best_available_settings}||{};
    my $context=$plan->{context}||{};
    return {} if !$plan->{active} || !($plan->{capability_profile_hash}||'')
        || ($plan->{capability_profile_hash}||'') ne ($item->{capability_profile}{hash}||'')
        || ($context->{tv_input}||'') ne ($item->{tv_input}||'')
        || ($context->{picture_mode}||'') ne lc(_picture_mode($item))
        || ($context->{signal_mode}||'') ne _signal($item);
    return {} if ref($plan->{manual}) ne 'HASH';
    return {map {$_=>$plan->{manual}{$_}} grep {
        exists($item->{settings}{$_}) && _value_agrees($item->{settings}{$_},$plan->{manual}{$_}{value},$_)
    } keys %{$plan->{manual}}};
}

sub _item_settings {
    my ($item) = @_;
    my $settings = ref($item->{settings}) eq 'HASH' ? PGAutomation::clone($item->{settings}) : {};
    my $hazards = ref($item->{hazards}) eq 'ARRAY' ? $item->{hazards} : [];
    my $capabilities = ref($item->{hazard_capabilities}) eq 'HASH' ? $item->{hazard_capabilities} : {};
    foreach my $default_key (qw(energySaving aiPicture)) {
        my $capability = ref($capabilities->{$default_key}) eq 'HASH' ? $capabilities->{$default_key} : {};
        $settings->{$default_key} = 'off'
            if !exists($settings->{$default_key}) && $capability->{controllable} && $capability->{supported};
    }
    foreach my $hazard (@$hazards) {
        next if ref($hazard) ne 'HASH' || !$hazard->{controllable};
        next if !defined($hazard->{key}) || $hazard->{key} eq '';
        my $category = $hazard->{category} || 'picture';
        $item->{hazard_restore}{$hazard->{key}} = {
            value => $hazard->{value},
            category => $category,
        } if exists($hazard->{value}) && !exists($item->{hazard_restore}{$hazard->{key}});
        next if ($hazard->{key} eq 'energySaving' || $hazard->{key} eq 'aiPicture')
            && exists($settings->{$hazard->{key}});
        $settings->{$hazard->{key}} = $hazard->{disabled_value}
            if exists($hazard->{disabled_value});
    }
    delete @$settings{keys %{_best_available_manual($item)}};
    return $settings;
}

sub _setting_category {
    my ($item, $key) = @_;
    return 'picture' if !defined($key) || $key eq 'pictureMode';
    my $capabilities = ref($item->{hazard_capabilities}) eq 'HASH' ? $item->{hazard_capabilities} : {};
    return $capabilities->{$key}{category}
        if ref($capabilities->{$key}) eq 'HASH' && $capabilities->{$key}{category};
    foreach my $hazard (@{$item->{hazards} || []}) {
        next if ref($hazard) ne 'HASH' || ($hazard->{key} || '') ne $key;
        return $hazard->{category} || 'picture';
    }
    return 'picture';
}

sub _apply_one_setting {
    my ($item, $key, $value, $category, $calibration_active) = @_;
    $value = _tv_gamma_value($value) if $key eq 'gamma';
    $category = 'picture' if !defined($category) || $category eq '';
    my $result = _api('POST', '/api/lg/picture-settings/set', {
        settings => { $key => $value },
        readback_keys => [$key, 'pictureMode'],
        picture_mode => _picture_mode($item),
        tv_input => $item->{tv_input}||'',
        signal_mode => _signal($item),
        category => $category,
        keep_calibration_mode => $calibration_active ? JSON::PP::true : JSON::PP::false,
        calibration_mode_active => $calibration_active ? JSON::PP::true : JSON::PP::false,
    });
    return $result;
}

sub _calibration_manages_setting {
    my ($item, $key, $point) = @_;
    # The resume-time passes (resume-setup, resume-profile-baseline) carry
    # the same ownership as the post-1D points: a restored or kept LUT must
    # not have its gamut or gamma rewritten before profiling. The checkpoint
    # guards below decide whether a LUT actually owns the control.
    if ($key eq 'gamma') {
        return 0 if _signal($item) ne 'sdr' || !_stages($item)->{calibration}
            || ($point || '') !~ /^(?:(?:resume-)?c(?:6|7|8|9|10)(?:-(?:confirm|repair|stable|recovery))?|resume-(?:setup|profile-baseline)(?:-pre)?)$/;
        return 0 if (_tv_gamma_value($item->{settings}{$key}) || '') !~ /^(?:low|medium|high1|high2)$/;
        # Uploaded 1D LUT data bypasses LG's menu gamma. Only this job's
        # completed, verified upload owns it; a later reset invalidates that.
        # (Third-party LG calibration clients document that LUT uploads grey out the menu control.)
        my $grey;
        for my $record (@{$item->{checkpoints} || []}) {
            next if ref($record) ne 'HASH';
            $grey = undef if ($record->{name} || '') eq 'reset-and-reapply-verified';
            $grey = $record if ($record->{name} || '') eq 'greyscale-done';
        }
        return $grey && ($grey->{status} || '') eq 'done' && ($grey->{verified} // '') eq '1' ? 1 : 0;
    }
    return 0 if $key ne 'colorGamut' || ($point || '') !~ /^(?:(?:resume-)?c(?:7|8|9|10)(?:-(?:confirm|repair|stable|recovery))?|resume-(?:setup|profile-baseline)(?:-pre)?)$/;
    return 0 if _signal($item) !~ /^(?:sdr|hdr10)$/ || !_stages($item)->{calibration};
    return 0 if ($item->{settings}{$key} || '') !~ /^(?:auto|native|wide|extended)$/i;
    # Only a committed 3D LUT owns the post-calibration gamut control. Never
    # waive baseline checks, failed uploads, or a later invalidated checkpoint.
    # (Per the LG LUT-upload guidance in the reference calibration documentation.)
    my ($commit) = reverse grep { ref($_) eq 'HASH' && ($_->{name} || '') eq 'volume-done' } @{$item->{checkpoints} || []};
    return $commit && ($commit->{status} || '') eq 'done' && ($commit->{verified} // '') eq '1' ? 1 : 0;
}

sub _read_and_verify_settings {
    my ($item_number, $item, $point) = @_;
    my $settings = _item_settings($item);
    my %expected = %$settings;
    $expected{pictureMode} = _picture_mode($item) if _picture_mode($item) ne '';
    my @keys = sort keys %expected;
    _log_action('Reading back picture mode and TV settings ('.$point.')');
    my %by_category;
    foreach my $key (@keys) {
        push @{$by_category{_setting_category($item, $key)}}, $key;
    }
    my %observed;
    my %meta;
    my @responses;
    foreach my $category (sort keys %by_category) {
        my $response = _api('POST', '/api/lg/picture-settings', {
            keys => $by_category{$category},
            picture_mode => _picture_mode($item),
            tv_input => $item->{tv_input}||'',
            signal_mode => _signal($item),
            include_current_input => JSON::PP::true,
            category => $category,
        });
        if(($item->{tv_input}||'') ne '' && (ref($response) ne 'HASH' || ($response->{current_input}||'') ne $item->{tv_input})) {
            $response={status=>'error',error_code=>'lg-input-context-changed',message=>'The active LG input changed or could not be confirmed against job readiness.'};
        }
        push @responses, { category => $category, response => $response };
        my $category_observed = _observed_settings($response);
        foreach my $key (keys %$category_observed) {
            $observed{$key} = $category_observed->{$key};
        }
        my $unverifiable = ref($response) eq 'HASH' && ($response->{virtual_picture_settings}
            || $response->{manual_confirmation_required}
            || lg_picture_mode_read_forbidden($response));
        my $unsupported = ref($response) eq 'HASH' && ref($response->{unsupported_picture_keys}) eq 'HASH'
            ? $response->{unsupported_picture_keys} : {};
        my %native=map {$_=>1} @{$response->{supported_picture_keys}||[]};
        foreach my $key (@{$by_category{$category}}) {
            $meta{$key} = {
                unverifiable => $unverifiable && !$native{$key} ? 1 : 0,
                unsupported => exists($unsupported->{$key}) ? 1 : 0,
                unavailable_reason => exists($unsupported->{$key}) ? $unsupported->{$key} : 'No value returned by TV',
                error => (ref($response) ne 'HASH' || ($response->{status} || '') eq 'error') ? 1 : 0,
                reason => ref($response) eq 'HASH' ? ($response->{message} || $response->{error} || '') : 'TV returned no settings response',
                error_code => ref($response) eq 'HASH' ? ($response->{error_code} || '') : '',
                contract => ref($response->{setting_contracts}) eq 'HASH' ? $response->{setting_contracts}{$key} : undef,
                mode_readback_unavailable => $key eq 'pictureMode' && $unverifiable
                    && $response->{generation_profile}{capability_library_valid}
                    && $response->{generation_profile}{capability_platform_profile_applied}
                    && exists($response->{generation_profile}{picturemode_readable})
                    && !$response->{generation_profile}{picturemode_readable},
            };
        }
    }
    my $response = @responses == 1 ? $responses[0]{response} : {
        status => (grep { ref($_->{response}) ne 'HASH' || ($_->{response}{status} || '') eq 'error' } @responses) ? 'error' : 'ok',
        responses => \@responses,
    };
    my $all = 1;
    my $any_unverifiable = 0;
    my @readback_warnings;
    my $hard_failure = 0;
    my $storage_failure = 0;
    my %values;
    my $mode_verified = _mode_agrees(_picture_mode($item), $observed{pictureMode})
        && !$meta{pictureMode}{error} && !$meta{pictureMode}{unverifiable} && !$meta{pictureMode}{unsupported};
    foreach my $key (@keys) {
        my $has = exists($observed{$key});
        my $ok = $has ? _value_agrees($expected{$key}, $observed{$key}, $key) : 0;
        my $meta = $meta{$key} || {};
        $ok = lg_setting_values_agree($meta->{contract}, $expected{$key}, $observed{$key})
            if $has && $key ne 'pictureMode' && ref($meta->{contract}) eq 'HASH';
        my $ack=$item->{best_available_write_ack}{$key};
        my $ack_missing=!$has && $meta->{contract}{allow_unverified_readback} && ref($ack) eq 'HASH'
            && lg_readback_unavailable_reason($meta->{unavailable_reason})
            && ($ack->{profile_hash}||'') eq ($item->{capability_profile}{hash}||'')
            && _value_agrees($expected{$key},$ack->{expected},$key);
        my $can_be_unverifiable = !$meta->{error} && ($meta->{unsupported} || $meta->{unverifiable} || $ack_missing);
        my $unverifiable_permitted=$meta->{mode_readback_unavailable} || $ack_missing;
        my $expected_transition = $mode_verified && $has && !$meta->{error} && !$can_be_unverifiable
            && _expected_calibration_gamut_state($item, $key, $point)
            && _lg_gamut_readback_warning($key, $expected{$key}, $observed{$key});
        my $managed = $expected_transition || ($mode_verified && $has && !$meta->{error} && !$can_be_unverifiable
            && _calibration_manages_setting($item, $key, $point)
            && defined($observed{$key}) && ($key eq 'gamma'
                ? _tv_gamma_value($observed{$key}) =~ /^(?:low|medium|high1|high2)$/
                : $observed{$key} =~ /^(?:auto|native|wide|extended)$/i));
        my $warning = !$managed && $mode_verified && !$meta->{error} && !$can_be_unverifiable
            && _lg_gamut_readback_warning($key, $expected{$key}, $observed{$key});
        my $warning_reason = 'Requested Auto; LG reported Wide. LG LUT/reset transitions can change or bypass the gamut menu. This is a warning, not a verified match or proof that Auto and Wide are equivalent; check the TV menu if needed.';
        $ok = 0 if $can_be_unverifiable || $meta->{error} || $managed;
        $values{$key} = {
            expected => $expected{$key},
            observed => $has ? $observed{$key} : undef,
            matched => $ok ? JSON::PP::true : JSON::PP::false,
            unverifiable => $can_be_unverifiable ? JSON::PP::true : JSON::PP::false,
            calibration_managed => $managed ? JSON::PP::true : JSON::PP::false,
            expected_calibration_state => $expected_transition ? JSON::PP::true : JSON::PP::false,
            readback_warning => $warning ? JSON::PP::true : JSON::PP::false,
            read_failed => $meta->{error} || !$has ? JSON::PP::true : JSON::PP::false,
            reason => $meta->{reason} || (!$has ? 'TV response omitted this setting' : ''),
        };
        $all = 0 if !$ok && !$managed;
        $any_unverifiable = 1 if $can_be_unverifiable || $warning;
        $hard_failure = 1 if !$ok && !$can_be_unverifiable && !$managed && !$warning;
        $hard_failure = 1 if $can_be_unverifiable && !$unverifiable_permitted;
        push @readback_warnings, $warning_reason if $warning;
        my $check_saved = _append_setting_check($item_number, $point, {
            key => $key,
            expected => $expected{$key},
            observed => $has ? $observed{$key} : undef,
            verified => $ok ? JSON::PP::true : JSON::PP::false,
            result => $expected_transition ? 'expected-calibration-state' : $managed ? 'lut-managed' : $warning ? 'readback-warning' : $ok ? 'verified' : ($can_be_unverifiable ? 'unverifiable' : 'mismatch'),
            category => _setting_category($item, $key),
            reason => $expected_transition ? 'Expected LG calibration state: Auto was requested for setup; the TV reports Wide after the completed 1D calibration and combined LUT baseline reset. This is retained as diagnostic evidence, not a settings warning or a claim that Auto and Wide are interchangeable. No gamut rewrite is required.'
                : $managed ? ($key eq 'gamma'
                    ? 'The verified 1D LUT controls gamma after calibration; the TV Gamma menu is bypassed. The requested menu value applies to setup, not the uploaded LUT curve.'
                    : 'The verified 3D LUT controls gamut after calibration; the TV gamut menu is bypassed. The requested value applies to the pre-calibration setup, not the uploaded LUT.')
                : $warning ? $warning_reason
                : $ok ? 'TV readback matches the requested value'
                : $meta->{error} ? ($meta->{reason} || 'TV settings read failed; no driver reason was returned')
                : $meta->{unsupported} ? 'This TV API does not support reading this setting; verify it in the TV menu'
                : $meta->{unverifiable} ? 'Readback is unavailable in this signal/picture mode; verify it in the TV menu'
                : !$has ? 'TV response omitted this setting; its value could not be verified'
                : 'TV-reported value differs from the requested value',
            error_code => $meta->{error_code},
            operation => 'readback',
            capability_profile_id => ref($meta->{contract}) eq 'HASH' ? $meta->{contract}{capability_profile_id} : undef,
            capability_profile_hash => ref($meta->{contract}) eq 'HASH' ? $meta->{contract}{capability_profile_hash} : undef,
        });
        $storage_failure = 1 if !$check_saved;
    }
    my $manual=_best_available_manual($item);
    for my $key (sort keys %$manual) {
        my $entry=$manual->{$key};
        $values{$key}={expected=>$entry->{value},observed=>undef,matched=>JSON::PP::false,
            unverifiable=>JSON::PP::true,manual_required=>JSON::PP::true,reason=>$entry->{message}};
        $storage_failure=1 if !_append_setting_check($item_number,$point,{
            key=>$key,expected=>$entry->{value},result=>'manual-required',verified=>JSON::PP::false,
            operation=>'manual',category=>'picture',reason=>$entry->{message},
        });
        $all=0;$any_unverifiable=1;
    }
    if ($storage_failure) {
        $::LAST_ERROR = 'Unable to persist LG settings verification evidence';
        $hard_failure = 1;
    }
    my $matched=grep { $values{$_}{matched} } @keys;
    my $managed=grep { $values{$_}{calibration_managed} } @keys;
    my $gamma_managed=$values{gamma} && $values{gamma}{calibration_managed} ? 1 : 0;
    my $expected_transitions=grep { $values{$_}{expected_calibration_state} } @keys;
    foreach my $warning (@readback_warnings) {
        _log_action('Warning: colorGamut: '.$warning.' ('.$point.')');
        $item->{warnings} ||= [];
        push @{$item->{warnings}}, $warning if !grep { $_ eq $warning } @{$item->{warnings}};
    }
    _log_action('TV settings readback: '.$matched.'/'.scalar(@keys).' matched'
        .($gamma_managed ? '; TV Gamma controlled by the verified 1D LUT' : '')
        .($managed > $expected_transitions+$gamma_managed ? '; '.($managed-$expected_transitions-$gamma_managed).' controlled by the verified 3D LUT' : '')
        .($expected_transitions ? '; expected LG calibration state: Auto requested, Wide reported (no gamut rewrite needed)' : '')
        .($hard_failure ? '; mismatch or failed read - see setting checks' : $any_unverifiable ? '; warning: some controls cannot be verified - see setting checks' : '')
        .' ('.$point.')');
    return {
        verified => $storage_failure ? 0 : ($all ? 1 : ($any_unverifiable && !$hard_failure ? 'unverifiable' : 0)),
        values => \%values,
        response => $response,
        storage_failure => $storage_failure,
    };
}

sub _expected_calibration_gamut_state {
    my ($item, $key, $point) = @_;
    return 0 if $key ne 'colorGamut' || ($point || '') !~ /^(?:(?:resume-)?c6(?:-(?:confirm|repair|stable|recovery))?|resume-(?:setup|profile-baseline)(?:-pre)?)$/;
    return 0 if _signal($item) !~ /^(?:sdr|hdr10)$/ || !_stages($item)->{calibration};
    return 0 if lc($item->{settings}{$key} || '') ne 'auto';
    # Our SDR/HDR reset stage includes BOTH the 1D and 3D baseline reset.
    # A completed, verified 1D stage after that reset can leave Auto reported
    # as Wide. This is a phase-specific state, not a global Auto/Wide alias.
    # In particular, isolated 1D workflows can retain normal gamut management:
    # (LG LUT-upload guidance in the reference calibration documentation.)
    # Use the latest records so failed/superseded stages cannot grant a waiver.
    my ($reset, $grey);
    for my $record (@{$item->{checkpoints} || []}) {
        next if ref($record) ne 'HASH';
        if (($record->{name} || '') eq 'reset-and-reapply-verified') {
            $reset = $record;
            $grey = undef;
        } elsif (($record->{name} || '') eq 'greyscale-done') {
            $grey = $record;
        }
    }
    return 0 if !$reset || !$grey;
    return !grep { ($_->{status} || '') ne 'done' || ($_->{verified} // '') ne '1' } ($reset, $grey);
}

sub _lg_gamut_readback_warning {
    my ($key, $expected, $observed) = @_;
    # Deliberately not an alias in _value_agrees: these are distinct settings.
    # Only this known LG readback direction is non-blocking; missing values,
    # failed writes/reads and other gamut values retain their normal errors.
    return $key eq 'colorGamut' && defined($expected) && !ref($expected)
        && defined($observed) && !ref($observed)
        && lc($expected) eq 'auto' && lc($observed) eq 'wide';
}

sub _boundary_evidence {
    my ($item, $name) = @_;
    my ($record) = reverse grep { ($_->{name} || '') eq $name } @{$item->{checkpoints} || []};
    return {} if !$record || ($record->{status} || '') ne 'done';
    return $record->{evidence} || {};
}

sub _processing_setting {
    # Do not generalise this to luminance, gamma, gamut, white balance, input
    # or picture mode. Their effects cannot be bounded by a menu read alone.
    return ($_[0] || '') =~ /^(?:smoothGradation|noiseReduction|mpegNoiseReduction|superResolution|sharpness|realCinema)$/;
}

sub _settings_evidence_only_gamut_warning {
    my ($evidence) = @_;
    return 0 if ref($evidence) ne 'HASH' || ($evidence->{verified} || '') ne 'unverifiable';
    my $values = $evidence->{values};
    return 0 if ref($values) ne 'HASH' || ref($values->{pictureMode}) ne 'HASH' || !$values->{pictureMode}{matched};
    my $warning = 0;
    for my $key (keys %$values) {
        my $v = $values->{$key};
        return 0 if ref($v) ne 'HASH' || $v->{read_failed} || $v->{unverifiable};
        next if $v->{matched};
        return 0 if !$v->{readback_warning}
            || !_lg_gamut_readback_warning($key, $v->{expected}, $v->{observed});
        $warning = 1;
    }
    return $warning;
}

sub _settings_boundary_pause {
    my ($item, $point, $resume_from, $detail, $read_failure) = @_;
    my %next = (
        'greyscale-done' => 'repeat 1D calibration and the dependent profile/LUT stages',
        'volume-done' => 'repeat only the profile/LUT stage, retaining the verified 1D result',
        'greyscale-settings-verified' => 'retry the settings check after 1D calibration',
        'volume-settings-verified' => 'retry the settings check after profile/LUT upload',
        'session-closed' => 'retry calibration exit and its settings check',
    );
    my $message = "Settings review required at $point: $detail. Saved results are retained; no automatic recalibration. Resume will $next{$resume_from}.";
    $item->{settings_recovery} = {point=>$point, resume_from=>$resume_from, message=>$message, at=>time()};
    $::LAST_ERROR = $message;
    $::LAST_ERROR_CODE = $read_failure ? 'settings-readback-unavailable' : 'settings-review-required';
    _log_action($message);
    return 0;
}

sub _calibration_settings_boundary {
    my ($number, $item, $point, $before_exit) = @_;
    my %gates = (c6=>'greyscale-settings-verified', c7=>'volume-settings-verified', c8=>'session-closed');
    my $check = _read_and_verify_settings($number, $item, $point);
    my $summary = sub {
        my ($result, $mode) = @_;
        return _settings_boundary_pause($item, $point, $gates{$point},
            'Calibration mode could not be verified; no controls were rewritten', 1) if !defined($mode);
        return {verified=>$result->{verified}, values=>$result->{values}, point=>$point,
            checked_at=>time(), calibration_mode=>$mode};
    };
    my $mode_state = sub {
        my $s = _api('GET', '/api/lg/status', undef);
        return undef if ref($s) ne 'HASH' || ($s->{status} || '') ne 'ok' || $s->{disconnected}
            || !exists($s->{calibration_mode});
        return $s->{calibration_mode} ? 1 : 0;
    };
    return $summary->($check, $mode_state->()) if $check->{verified};
    _log_action("Settings differ at $point; confirming with a fresh read before changing anything");
    return 0 if !_sleep_controlled(1);
    my $confirmed = _read_and_verify_settings($number, $item, "$point-confirm");
    if ($confirmed->{verified}) {
        _log_action("Settings matched on confirmation at $point; no settings rewritten or calibration repeated");
        return $summary->($confirmed, $mode_state->());
    }
    my @keys = sort grep {
        my $v = $confirmed->{values}{$_};
        !$v->{matched} && !$v->{unverifiable} && !$v->{calibration_managed} && !$v->{readback_warning}
    } keys %{$confirmed->{values} || {}};
    my $reason = _settings_failure_message($point, $confirmed, 1);
    my $unreadable = $confirmed->{storage_failure} || !@keys
        || grep { $confirmed->{values}{$_}{read_failed} } @keys;
    if ($unreadable) {
        my @details = grep { $_ } map { $confirmed->{values}{$_}{reason} } @keys;
        return _settings_boundary_pause($item, $point, $gates{$point},
            $reason.(@details ? '; '.join('; ', @details) : '; settings evidence could not be verified'), 1);
    }
    my $processing_only = !grep { !_processing_setting($_) } @keys;
    my $grey = _boundary_evidence($item, 'greyscale-settings-verified');
    my $grey_clean = (($grey->{verified} || '') eq '1' || _settings_evidence_only_gamut_warning($grey))
        && !grep { !$grey->{values}{$_}{matched} } @keys;
    my $resume_from = $point ne 'c6' && $processing_only && $grey_clean ? 'volume-done' : 'greyscale-done';
    my $mode = $mode_state->();
    my $stable_mismatch = !grep {
        my $v = $check->{values}{$_} || {};
        $v->{read_failed} || $v->{unverifiable} || !defined($v->{observed})
            || !_value_agrees($v->{observed}, $confirmed->{values}{$_}{observed}, $_)
    } @keys;
    if (!$stable_mismatch || !defined($mode) || !$confirmed->{values}{pictureMode}{matched}) {
        return _settings_boundary_pause($item, $point, $resume_from,
            "$reason; settings or calibration/picture mode are unstable or unconfirmed, so no controls were rewritten", 0);
    }
    # Only a fresh, successful check immediately before CAL_END can establish
    # an exit-only processing change. Historical checkpoints cannot authorise
    # retaining measurements after a restart. Other changes require review.
    my $exit_only = $point eq 'c8' && $processing_only && $mode == 0
        && (_boundary_evidence($item, 'volume-done')->{verified} || '') eq '1'
        && ref($before_exit) eq 'HASH' && ($before_exit->{verified} || '') eq '1'
        && defined($before_exit->{calibration_mode}) && $before_exit->{calibration_mode} == 1
        && !grep { !$before_exit->{values}{$_}{matched}
            || !_value_agrees($before_exit->{values}{$_}{expected}, $confirmed->{values}{$_}{expected}, $_) } @keys;
    # DV's upload helper always sends CAL_END itself. A fresh check made after
    # profiling and immediately before that upload isolates this transition:
    # processing changes happened AFTER the measured profile, not during it.
    # This proof is passed from the just-executed stage, never loaded on Resume.
    my $upload_only = $point eq 'c7' && _signal($item) eq 'dv' && $processing_only && $mode == 0
        && (_boundary_evidence($item, 'volume-done')->{verified} || '') eq '1'
        && ref($before_exit) eq 'HASH' && ($before_exit->{transition} || '') eq 'dv-profile-upload'
        && ($before_exit->{verified} || '') eq '1'
        && defined($before_exit->{calibration_mode})
        && !grep { !$before_exit->{values}{$_}{matched}
            || !_value_agrees($before_exit->{values}{$_}{expected}, $confirmed->{values}{$_}{expected}, $_) } @keys;
    _log_action("Confirmed settings change at $point: $reason; restoring only ".join(', ', @keys));
    foreach my $key (@keys) {
        my $value = $confirmed->{values}{$key}{expected};
        my $result = _apply_one_setting($item, $key, $value, _setting_category($item, $key), $mode);
        my $accepted = ref($result) eq 'HASH' && ($result->{status} || '') =~ /^(?:ok|started)$/;
        return _settings_boundary_pause($item, $point, $resume_from, 'Unable to save setting-repair evidence', 1)
            if !_append_setting_check($number, "$point-repair", {key=>$key, expected=>$value,
                operation=>'write', result=>$accepted ? 'applied' : 'apply-failed', verified=>JSON::PP::false,
                reason=>$accepted ? 'Targeted restoration; awaiting fresh readback' : ($result->{message} || 'TV rejected setting repair')});
        return _settings_boundary_pause($item, $point, $resume_from,
            "Could not restore $key: ".($result->{message} || 'TV rejected setting repair'), 0) if !$accepted;
    }
    my $restored = _read_and_verify_settings($number, $item, "$point-repair");
    return 0 if !_sleep_controlled(1);
    my $stable = _read_and_verify_settings($number, $item, "$point-stable");
    if (!$restored->{verified} || !$stable->{verified}) {
        return _settings_boundary_pause($item, $point, $resume_from,
            _settings_failure_message("$point-stable", $stable->{verified} ? $restored : $stable, 1).'; repaired settings did not remain verified', 0);
    }
    my $after_mode = $mode_state->();
    return _settings_boundary_pause($item, $point, $resume_from,
        'Calibration mode changed or became unverified during setting repair', 0)
        if !defined($after_mode) || $after_mode != $mode;
    if (($exit_only || $upload_only) && ($restored->{verified} || '') eq '1' && ($stable->{verified} || '') eq '1') {
        my $message = $upload_only
            ? 'Restored after Dolby Vision profile upload: '.join(', ', @keys).'; settings matched after measurement and immediately before upload, calibration results retained'
            : 'Restored after calibration exit: '.join(', ', @keys).'; pre-exit settings verified, calibration results retained';
        _log_action($message);
        $item->{warnings} ||= [];
        push @{$item->{warnings}}, $message if !grep { $_ eq $message } @{$item->{warnings}};
        return {%{$summary->($stable, 0)}, recovery=>$upload_only ? 'upload-only-restored' : 'exit-only-restored', repaired_keys=>\@keys};
    }
    return _settings_boundary_pause($item, $point, $resume_from,
        "$reason; requested settings restored, but their effect on measurements is not established", 0);
}

# A pre-read the mode selector may act on: an independent, no-echo read of
# the active picture mode (no requested picture_mode, calibration mode
# ignored, item context cleared so the daemon cannot echo the queued
# selector). _preflight_read_mode's snapshot qualifies: it refused anything
# that was not independently readable.
sub _normalise_mode_read {
    my ($pre) = @_;
    # Only a read stamped no_echo qualifies; an automation item has the same
    # fields and must never be mistaken for a readback of the TV.
    return ref($pre) eq 'HASH' && $pre->{no_echo} ? $pre : undef;
}

sub _mode_read_from_response {
    my ($live) = @_;
    my $mode = ref($live) eq 'HASH' ? (_observed_settings($live)->{pictureMode} || '') : '';
    my $trusted = ref($live) eq 'HASH' && _response_ok($live) && $mode ne ''
        && !$live->{virtual_picture_settings} && !lg_picture_mode_read_forbidden($live)
        && !$live->{manual_confirmation_required} ? 1 : 0;
    return { no_echo => 1, verified => $trusted, picture_mode => $mode,
        current_input => ref($live) eq 'HASH' ? ($live->{current_input}||'') : '', response => $live };
}

sub _read_active_mode {
    my ($item) = @_;
    my $saved_item = $ACTIVE_ITEM; $ACTIVE_ITEM = undef;
    my $live = eval { _api('POST', '/api/lg/picture-settings', {
        keys => ['pictureMode'], include_current_input => JSON::PP::true,
        ignore_calibration_picture_mode => JSON::PP::true, signal_mode => _signal($item),
    }) };
    my $error = $@; $ACTIVE_ITEM = $saved_item; die $error if $error;
    return _mode_read_from_response($live);
}

sub _select_item_picture_mode {
    my ($item_number,$item,$point,$pre)=@_;
    return 1 if _picture_mode($item) eq '';
    # A mode the TV already reports on the expected input needs no write, no
    # settle and no second read: the independent read is the verification.
    # DV and ddc-only generations answer virtual settings, never verify here
    # and always take the write path.
    $pre = _normalise_mode_read($pre) || _read_active_mode($item);
    if (($pre->{verified}||'') eq '1' && _mode_agrees(_picture_mode($item),$pre->{picture_mode})
        && ($item->{tv_input}||'') ne '' && ($pre->{current_input}||'') eq $item->{tv_input}) {
        _log_action('Picture mode '._picture_mode($item).' already active on '.$item->{tv_input}.'; confirmed by readback, no mode write needed ('.$point.'-mode)');
        my $saved=_append_setting_check($item_number,$point.'-mode',{
            key=>'pictureMode',expected=>_picture_mode($item),observed=>$pre->{picture_mode},
            verified=>JSON::PP::true,result=>'verified',operation=>'readback',category=>'picture',
            reason=>'TV reported the requested picture mode on the expected input before any write; no mode write was needed',
            capability_profile_id=>$item->{capability_profile}{id},capability_profile_hash=>$item->{capability_profile}{hash},
        });
        if(!$saved) { $::LAST_ERROR='Unable to persist LG settings verification evidence'; return 0; }
        return 1;
    }
    _log_action('Selecting '.uc(_signal($item)).' picture mode '._picture_mode($item));
    # Journal before the write: restoration only needs to walk the signals
    # whose picture mode this run actually changed.
    my $signal=_signal($item);
    # Preflight and job writes are marked separately: a preflight restoration
    # returns only what the preflight changed, so it must not erase a job's
    # mark that a later viewing restoration still needs. Restoration writes
    # move back toward the original and are not journalled.
    my $phase=$point eq 'queue-preflight' ? 'preflight' : $point eq 'preflight-restore' ? '' : 'job';
    if ($phase ne '' && !ref(_update_run(sub {
        $_[0]{mode_written_signals}={} if ref($_[0]{mode_written_signals}) ne 'HASH';
        my $entry=$_[0]{mode_written_signals}{$signal};
        $entry=ref($entry) eq 'HASH' ? {%$entry} : $entry ? {preflight=>JSON::PP::true,job=>JSON::PP::true} : {};
        $entry->{$phase}=JSON::PP::true;
        $_[0]{mode_written_signals}{$signal}=$entry;
    }))) {
        $::LAST_ERROR='Unable to journal the picture-mode change before writing it';
        return 0;
    }
    my $result=_apply_one_setting($item,'pictureMode',_picture_mode($item),'picture');
    if (!$result || (($result->{status}||'') ne 'ok' && ($result->{status}||'') ne 'started')) {
        $::LAST_ERROR=$result->{message}||'Unable to select LG picture mode';
        _append_setting_check($item_number,$point,{key=>'pictureMode',expected=>_picture_mode($item),result=>'apply-failed',operation=>'write',reason=>$::LAST_ERROR,error_code=>$result->{error_code}});
        return 0;
    }
    my $settle=0+($item->{settle_seconds}//8);
    _log_action('Picture-mode write accepted; allowing '.$settle.' s to settle before settings') if $settle>0;
    return 0 if !_sleep_controlled($settle);
    # Confirm the mode BEFORE any of this job's control writes. A successful
    # mode write alone does not establish which picture mode is now active.
    my $check_item = {%$item, settings=>{}, hazards=>[], hazard_capabilities=>{}};
    my $check = _read_and_verify_settings($item_number, $check_item, $point.'-mode');
    if (!$check->{verified}) {
        $::LAST_ERROR = _settings_failure_message($point.'-mode', $check, 1);
        return 0;
    }
    _log_action($check->{verified} eq 'unverifiable'
        ? 'Warning: picture-mode readback unavailable; proceeding with accepted mode write, not a verified mode'
        : 'Picture mode confirmed: '._picture_mode($item).'; queued settings can now be applied');
    return 1;
}

# Write a job's controls category by category in one TV session each. A
# group whose write is refused or comes back unverified is left for the
# per-control path, which keeps its per-key evidence and best-available
# handling. Returns the keys written and verified together.
sub _apply_settings_batched {
    my ($item_number,$item,$point,$keys,$settings,$calibration_active)=@_;
    my %by_category;
    push @{$by_category{_setting_category($item,$_)}},$_ for @$keys;
    my %done;
    for my $category (sort keys %by_category) {
        my @group=@{$by_category{$category}};
        next if @group<2;
        _update_live(sub {$_[0]{operation_progress}={stage=>$ACTIVE_STAGE,completed=>scalar(keys %done),total=>scalar(@$keys)+1,unit=>'settings and verification',message=>'Applying '.scalar(@group).' '.$category.' controls together'};});
        delete $item->{best_available_write_ack}{$_} for @group;
        my %values=map { $_=>($_ eq 'gamma' ? _tv_gamma_value($settings->{$_}) : $settings->{$_}) } @group;
        my $budget=_lg_helper_timeout_for('/api/lg/picture-settings/set',{settings=>\%values});
        my $write_started=time();
        my $result=_api('POST','/api/lg/picture-settings/set',{
            settings=>\%values,
            ($budget ? (helper_timeout=>$budget) : ()),
            readback_keys=>[@group,'pictureMode'],
            picture_mode=>_picture_mode($item),
            tv_input=>$item->{tv_input}||'',
            signal_mode=>_signal($item),
            category=>$category,
            keep_calibration_mode=>$calibration_active ? JSON::PP::true : JSON::PP::false,
            calibration_mode_active=>$calibration_active ? JSON::PP::true : JSON::PP::false,
        });
        # Only a write that reached the TV measures the TV: an accepted
        # write, or the daemon's helper running out of its budget. A TV-side
        # error reply, a refused connection or an unreachable daemon
        # measures nothing.
        my $reached=ref($result) eq 'HASH' && !_lg_connection_failure($result)
            && (($result->{status}||'') =~ /^(?:ok|started)$/ || ($result->{message}||'') =~ /did not finish/i);
        _note_lg_control_seconds(scalar(@group),time()-$write_started,$budget) if $reached;
        my $ok=ref($result) eq 'HASH' && (($result->{status}||'') eq 'ok' || ($result->{status}||'') eq 'started')
            && (!exists($result->{verification_state}) || ($result->{verification_state}||'') eq 'verified');
        if (!$ok) {
            # A readback mismatch still carries per-key verification; keep
            # what verified and rewrite only the rest. A refused write carries
            # nothing, so every control takes the per-control path.
            my $verification=ref($result) eq 'HASH' && ref($result->{setting_verification}) eq 'HASH' ? $result->{setting_verification} : {};
            my @kept=grep { ref($verification->{$_}) eq 'HASH' && ($verification->{$_}{status}||'') eq 'verified' } @group;
            $done{$_}=1 for @kept;
            _log_action('Batched write of '.scalar(@group).' '.$category.' controls was not confirmed; '
                .(@kept ? scalar(@kept).' verified, applying the rest one at a time' : 'applying them one at a time'));
            next;
        }
        $done{$_}=1 for @group;
        _log_action('Applied '.scalar(@group).' '.$category.' controls in one TV session');
    }
    return \%done;
}

sub _apply_and_verify {
    my ($item_number, $item, $point, $mode_selected, $calibration_active) = @_;
    my $settings = _item_settings($item);
    my @keys = sort grep { !_calibration_manages_setting($item, $_, $point)
        && !_expected_calibration_gamut_state($item, $_, $point) } keys %$settings;
    _log_action('Leaving LUT-managed picture controls unchanged during settings recovery') if @keys < keys %$settings;
    my $last;
    my $profile_confirmed = 0;
    for my $cycle (1..3) {
        _log_action('Retrying TV settings after readback mismatch (attempt '.$cycle.'/3)') if $cycle>1;
        if (!$mode_selected || $cycle>1) {
            # One no-echo read serves both the compatibility check that must
            # precede any write and the selector's "already active" decision.
            my $pre_mode = _read_active_mode($item);
            return 0 if !$profile_confirmed && !_verify_live_capability_profile($item, $pre_mode->{response});
            $profile_confirmed = 1;
            return 0 if !_select_item_picture_mode($item_number,$item,$point,$pre_mode);
        }
        # Read before writing: a control the TV already reports at the queued
        # value is verified by that readback and never rewritten. After the
        # HDR10 and DV calibration resets, which leave menu values alone, and
        # at the panel-light pass this turns a full write pass into one read.
        my @write_keys = @keys;
        if ($cycle == 1 && @keys && !delete($SKIP_PREREAD{$item_number.':'.$point})) {
            # The pre-read observes the TV before the write: a gamut left
            # Wide by an earlier calibration is corrected below, so it must
            # not become a job warning; only the post-write read records what
            # still stands.
            my @warnings_before = @{$item->{warnings} || []};
            my $pre = _read_and_verify_settings($item_number, $item, $point.'-pre');
            $item->{warnings} = \@warnings_before;
            return 0 if !$profile_confirmed && !_verify_live_capability_profile($item, $pre->{response});
            $profile_confirmed = 1;
            my $values = $pre->{values} || {};
            # @keys already excludes LUT-managed controls for this point; a
            # matched readback is the only reason to leave a control unwritten.
            @write_keys = grep { my $v = $values->{$_}; !(ref($v) eq 'HASH' && $v->{matched}) } @keys;
            # A fresh matching readback supersedes any earlier accepted-
            # without-readback acknowledgement; it must not license a later
            # unverifiable read.
            delete $item->{best_available_write_ack}{$_} for grep { !$values->{$_} || $values->{$_}{matched} } @keys;
            if (!@write_keys && $pre->{verified}) {
                _log_action('All '.scalar(@keys).' queued TV settings already match; nothing to write ('.$point.')');
                return $pre->{verified};
            }
            _log_action((scalar(@keys)-scalar(@write_keys)).' of '.scalar(@keys).' queued TV settings already match; writing the other '.scalar(@write_keys).' ('.$point.')')
                if @write_keys && @write_keys < @keys;
        }
        return 0 if !$profile_confirmed && !_verify_live_capability_profile($item);
        $profile_confirmed = 1;
        _log_action('Applying '.scalar(@write_keys).' queued TV settings to '._picture_mode($item)) if @write_keys;
        my $applied=0;
        my $next_setting_log=time()+15;
        # First pass: each category's controls in one TV session, confirmed by
        # the readback below; only controls that do not verify take the
        # per-control path. Every helper call registers a fresh TV session
        # (3-14 s on the G3), so 18 single writes made TV setup the slowest
        # stage of a job.
        my %batched=$cycle==1 ? %{_apply_settings_batched($item_number,$item,$point,\@write_keys,$settings,$calibration_active)} : ();
        $applied+=scalar(keys %batched);
        foreach my $key (@write_keys) {
            next if $batched{$key};
            _update_live(sub {$_[0]{operation_progress}={stage=>$ACTIVE_STAGE,completed=>$applied,total=>scalar(@write_keys)+1,unit=>'settings and verification',message=>'Applying '.$key.' ('.($applied+1).'/'.scalar(@write_keys).')'};});
            delete $item->{best_available_write_ack}{$key};
            my $category = _setting_category($item, $key);
            my $result = _apply_one_setting($item, $key, $settings->{$key}, $category, $calibration_active);
            if (!$result || (($result->{status} || '') ne 'ok' && ($result->{status} || '') ne 'started')) {
                _append_setting_check($item_number, $point, {key=>$key, category=>$category, expected=>$settings->{$key}, result=>'apply-failed', operation=>'write', reason=>$result->{message} || 'TV did not accept the setting write', error_code=>$result->{error_code}});
                $::LAST_ERROR = $result->{message} || "Unable to set LG picture key $key";
                return 0;
            }
            if (exists($result->{verification_state}) && ($result->{verification_state} || '') ne 'verified') {
                my $reason = $result->{message} || "LG accepted $key but did not return a verified readback";
                my $saved=_append_setting_check($item_number, $point, {
                    key=>$key, category=>$category, expected=>$settings->{$key}, result=>'unverified',
                    operation=>'write', reason=>$reason, verification_state=>$result->{verification_state}||'unknown',
                    setting_verification=>$result->{setting_verification},
                });
                if(!$saved) {
                    $::LAST_ERROR='Unable to persist LG write acknowledgement evidence';
                    return 0;
                }
                if(lg_setting_write_accepted($result,$key,$settings->{$key})) {
                    $item->{best_available_write_ack}{$key}={expected=>$settings->{$key},profile_hash=>$item->{capability_profile}{hash}||''};
                    _log_action("Warning: $key write accepted without readback under the TV matrix; not verified");
                    push @{$item->{warnings}},"$key write accepted without readback; verify in the TV menu"
                        if !grep {$_ eq "$key write accepted without readback; verify in the TV menu"} @{$item->{warnings}||[]};
                } else {
                    $::LAST_ERROR = $reason;
                    return 0;
                }
            }
            $applied++;
            if (time()>=$next_setting_log && $applied<@write_keys) {
                _log_action('Applied '.$applied.'/'.scalar(@write_keys).' TV settings; last control: '.$key);
                $next_setting_log=time()+15;
            }
        }
        _update_live(sub {$_[0]{operation_progress}={stage=>$ACTIVE_STAGE,completed=>$applied,total=>scalar(@write_keys)+1,unit=>'settings and verification',message=>'Verifying all TV settings after writes'};});
        $last = _read_and_verify_settings($item_number, $item, $point);
        if ($last->{verified}) {
            return $last->{verified};
        }
    }
    $::LAST_ERROR = _settings_failure_message($point, $last);
    return 0;
}

sub _settings_failure_message {
    my ($point, $last, $single_read) = @_;
    my @mismatches;
    foreach my $key (sort keys %{$last->{values} || {}}) {
        my $value = $last->{values}{$key};
        next if $value->{matched} || $value->{unverifiable} || $value->{calibration_managed} || $value->{readback_warning};
        my @text = map { !defined($_) ? '(not returned)' : ref($_) ? PGAutomation::encode_json($_) : "$_" }
            @{$value}{qw(expected observed)};
        push @mismatches, "$key: requested $text[0], TV reported $text[1]";
    }
    return "LG settings did not verify at $point" . ($single_read ? '' : ' after three cycles')
        . (@mismatches ? ': ' . join('; ', @mismatches) : ' (TV readback unavailable)');
}

# Is the generator already outputting exactly what $wanted would configure?
# Then a config write only restarts the renderer and costs the 35 s signal
# detection wait for nothing: the TV never saw a format change.
sub _signal_already_applied {
    my ($signal, $wanted) = @_;
    my $current = _api('GET', '/api/config', undef);
    return 0 if ref($current) ne 'HASH' || ($current->{status} || '') eq 'error';
    my $reported = lc($current->{signal_mode} || '');
    return 0 if !($reported eq $signal || $signal eq 'hdr10' && $reported eq 'hdr');
    foreach my $key (grep { $_ ne 'signal_mode' && $_ ne 'requested_signal_mode' } keys %$wanted) {
        return 0 if !defined($current->{$key}) || "$current->{$key}" ne "$wanted->{$key}";
    }
    return 1;
}

sub _apply_signal {
    my ($item) = @_;
    my $signal = _signal($item);
    my $config = {
        signal_mode => $signal,
        requested_signal_mode => $signal,
        eotf => $signal eq 'sdr' ? '0' : $signal eq 'hlg' ? '3' : '2',
        primaries => $signal eq 'sdr' ? '0' : $signal eq 'dv' ? '1' : '2',
        colorimetry => $signal eq 'sdr' ? '2' : '9',
    };
    $config->{dv_map_mode} = $item->{dv_map_mode} || '1' if $signal eq 'dv';
    foreach my $key (qw(color_format rgb_quant_range max_bpc eotf primaries colorimetry)) {
        $config->{$key} = $item->{$key} if exists($item->{$key}) && defined($item->{$key});
    }
    if (_signal_already_applied($signal, $config)) {
        _log_action('Generator output is already '.uc($signal).'; no output change needed');
        my $pattern = _api('POST', '/api/pattern', {
            name => 'gray50',
            signal_mode => $signal,
            max_luma => $item->{max_luma} || 1000,
        });
        return 1 if ($pattern->{status} || '') eq 'ok';
        # The pattern could not be shown: fall through to a full switch, whose
        # detection loop keeps retrying the pattern.
    }
    _log_action('Switching generator output to '.uc($signal));
    my $result = _api('POST', '/api/config', $config);
    if (!$result || ($result->{status} || '') ne 'ok') {
        $::LAST_ERROR = $result->{message} || 'Unable to apply signal format';
        return 0;
    }
    my $deadline = time() + 35;
    my $pattern_sent = 0;
    my $pattern_announced = 0;
    _log_action('Output change accepted; waiting for renderer and TV signal detection (up to 35 s)');
    while (time() < $deadline) {
        my $ping = _api('GET', '/api/ping', undef);
        my $config = _api('GET', '/api/config', undef);
        my $reported = lc($config->{signal_mode} || '');
        if (_ping_ok($ping) && ($reported eq $signal || $signal eq 'hdr10' && $reported eq 'hdr')) {
            if (!$pattern_sent) {
                _log_action('Displaying a neutral grey pattern for TV signal detection') if !$pattern_announced++;
                my $pattern = _api('POST', '/api/pattern', {
                    name => 'gray50',
                    signal_mode => $signal,
                    max_luma => $item->{max_luma} || 1000,
                });
                $pattern_sent = 1 if ($pattern->{status} || '') eq 'ok';
            }
            if ($pattern_sent && _picture_mode($item) ne '') {
                my $tv = _api('POST', '/api/lg/picture-settings', {
                    keys => ['pictureMode'],
                    picture_mode => _picture_mode($item),
                    tv_input => $item->{tv_input}||'',
                    signal_mode => $signal,
                    include_current_input => JSON::PP::true,
                    category => 'picture',
                }, 0, 0);
                my $observed = _observed_settings($tv);
                if (ref($observed) eq 'HASH' && _signal_mode_compatible($signal, $observed->{pictureMode})) {
                    _log_action('TV signal path ready; reported picture mode '.$observed->{pictureMode});
                    return 1;
                }
            } elsif ($pattern_sent) {
                _log_action('Generator signal ready');
                return 1;
            }
        }
        _sleep_controlled(2) or return 0;
    }
    $::LAST_ERROR = 'Renderer did not settle on the queued signal format';
    return 0;
}

sub _set_dv_map {
    my ($item, $mode) = @_;
    return 1 if _signal($item) ne 'dv';
    my $current = _api('GET', '/api/config', undef);
    return 1 if "$current->{dv_map_mode}" eq "$mode";
    _log_action('Switching Dolby Vision map to '.($mode eq '1'?'Absolute':'Relative'));
    my $result = _api('POST', '/api/config', { dv_map_mode => "$mode", signal_mode => 'dv' });
    return 0 if !$result || ($result->{status} || '') ne 'ok';
    my $deadline = time() + 30;
    while (time() < $deadline) {
        my $ping = _api('GET', '/api/ping', undef);
        my $config = _api('GET', '/api/config', undef);
        if (_ping_ok($ping) && "$config->{dv_map_mode}" eq "$mode") {
            my $pattern = _api('POST', '/api/pattern', {
                name => 'gray50',
                signal_mode => 'dv',
                max_luma => $item->{max_luma} || 1000,
            });
            if (($pattern->{status} || '') eq 'ok') {
                # A renderer ping proves the Pi is ready, not that the TV has
                # reacquired Dolby Vision after the HDMI restart. Keep this
                # short transition wait cancellable; it is not panel warm-up.
                _log_action('Dolby Vision output restored; allowing 8 s for TV signal acquisition');
                return 0 if !_sleep_controlled(8);
                _log_action('Dolby Vision map ready');
                return 1;
            }
        }
        _sleep_controlled(1) or return 0;
    }
    return 0;
}

sub _begin_run {
    my ($item) = @_;
    my $result = _api('POST', '/api/lg/autocal/run/begin', {
        workflow => 'automation',
        controller_id => 'automation-runner',
        client_run_token => $TOKEN,
        config => {
            signal_mode => _signal($item),
            picture_mode => _picture_mode($item),
            tv_input => $item->{tv_input}||'',
            target_gamma => $item->{target_gamma} || '',
            target_gamut => $item->{target_gamut} || '',
            luminance_target => $item->{target_luminance} || undef,
        },
    });
    return $result;
}

sub _verify_live_capability_profile {
    my ($item, $live) = @_;
    my $expected = ref($item->{capability_profile}) eq 'HASH'
        ? ($item->{capability_profile}{hash} || '') : '';
    $expected ||= ref($item->{generation_profile}) eq 'HASH'
        ? ($item->{generation_profile}{capability_profile_hash} || '') : '';
    # Legacy manifests have no signature to compare. New readiness always
    # supplies one; an absent live signature must not waive its protection.
    if($expected eq '') {
        return 1 if !_stages($item)->{calibration};
        $::LAST_ERROR='Calibration has no frozen LG compatibility signature. Run job readiness before changing TV calibration data.';
        return 0;
    }
    if(_stages($item)->{calibration} && ($item->{tv_input}||'') !~ /^hdmi[1-4](?:_pc)?$/) {
        $::LAST_ERROR='Calibration has no confirmed HDMI input. Run job readiness before changing TV calibration data.';
        return 0;
    }
    # A read the caller already holds (the settings pre-read or the no-echo
    # mode read) carries the same signature; only spawn a helper without one.
    $live = _api('POST', '/api/lg/picture-settings', {
        keys => ['pictureMode'], picture_mode => _picture_mode($item),
        signal_mode => _signal($item), include_current_input => JSON::PP::true,
        tv_input => $item->{tv_input}||'',
    }) if ref($live) ne 'HASH' || ref($live->{generation_profile}) ne 'HASH';
    my $actual = ref($live) eq 'HASH' && ref($live->{generation_profile}) eq 'HASH'
        ? ($live->{generation_profile}{capability_profile_hash} || '') : '';
    if (ref($live) ne 'HASH' || ($live->{status} || '') ne 'ok' || $actual eq '' || $actual ne $expected
        || (($item->{tv_input}||'') ne '' && ($live->{current_input}||'') ne $item->{tv_input})) {
        $::LAST_ERROR = 'The LG compatibility signature changed or could not be confirmed after readiness. Refresh readiness before changing TV settings or calibration data.';
        _log_action($::LAST_ERROR);
        return 0;
    }
    return 1;
}

sub _reset_for_calibration {
    my ($item_number, $item) = @_;
    return 0 if !_verify_live_capability_profile($item);
    my $signal = _signal($item);
    my $mode = _picture_mode($item);
    _log_action('Opening TV calibration session for '.$mode);
    my $begin = _begin_run($item);
    if (!$begin || (($begin->{status} || '') ne 'ok' && ($begin->{status} || '') ne 'started')) {
        $::LAST_ERROR = $begin->{message} || 'Unable to begin the LG automation run';
        return 0;
    }
    _update_run(sub { $_[0]{lg_run_id} = $begin->{run_id} if $begin->{run_id}; });
    my @responses;
    if ($signal eq 'sdr') {
        _log_action('Resetting SDR picture mode and white balance; existing calibration will be replaced');
        my $picture = _api('POST', '/api/lg/picture-settings/reset', {
            picture_mode => $mode,
            signal_mode => 'sdr',
            require_white_balance_reset => JSON::PP::true,
            helper_timeout => 170,
        });
        push @responses, { picture_reset => $picture };
        if (!$picture || ($picture->{status} || '') ne 'ok') {
            $::LAST_ERROR = $picture->{message} || 'Unable to reset the LG picture mode';
            return 0;
        }
        # Factory values are back on every menu control: the c4 pre-read
        # would only confirm that, so c4 writes without it.
        $SKIP_PREREAD{$item_number.':c4'} = 1;
        my $slots = [ (0) x 22 ];
        _log_action('Picture reset complete; resetting the SDR greyscale controls');
        my $ddc = _api('POST', '/api/lg/picture-settings/set', {
            settings => {
                whiteBalanceMethod => '22',
                whiteBalanceIre => '109',
                ddc_layout => 'sdr26',
                whiteBalanceRed => $slots,
                whiteBalanceGreen => $slots,
                whiteBalanceBlue => $slots,
                adjustingLuminance => $slots,
            },
            picture_mode => $mode,
            signal_mode => 'sdr',
            reset_ddc_baseline => JSON::PP::true,
            force_ddc_white_balance => JSON::PP::true,
            lg_autocal_sdr_1d_dpg_upload_enabled => JSON::PP::true,
            readback_keys => [qw(whiteBalanceMethod whiteBalanceIre adjustingLuminance)],
        });
        push @responses, { ddc_reset => $ddc };
        if (!$ddc || ($ddc->{status} || '') ne 'ok') {
            $::LAST_ERROR = $ddc->{message} || 'Unable to reset the SDR DDC baseline';
            return 0;
        }
        _log_action('Resetting the SDR calibration baseline');
        my $reference = _api('POST', '/api/lg/sdr-calman-reset', {
            picture_mode => $mode,
            action => 'sdr_calman_reset',
            ddc_layout => 'sdr26',
            helper_timeout => 170,
        });
        push @responses, { sdr_calman_reset => $reference };
        if (!$reference || ($reference->{status} || '') ne 'ok') {
            $::LAST_ERROR = $reference->{message} || 'Unable to complete the SDR calibration reset';
            return 0;
        }
    } else {
        _log_action('Resetting '.uc($signal).' calibration for '.$mode);
        my $endpoint = $signal eq 'dv' ? '/api/lg/dv-calman-reset' : '/api/lg/hdr-calman-reset';
        my $reset = _api('POST', $endpoint, {
            picture_mode => $mode,
            signal_mode => $signal,
            action => $signal eq 'dv' ? 'dv_calman_reset' : 'hdr_calman_reset',
            ddc_layout => 'hdr20',
            helper_timeout => 170,
        });
        push @responses, { hdr_calman_reset => $reset };
        if (!$reset || ($reset->{status} || '') ne 'ok') {
            $::LAST_ERROR = $reset->{message} || 'Unable to complete the HDR calibration reset';
            return 0;
        }
    }
    if ($signal ne 'dv') {
        _log_action('Resetting the 3D LUT baseline');
        my $lut = _api('POST', '/api/lg/3d-lut/reset', {
            picture_mode => $mode,
            signal_mode => $signal,
            upload_command => $signal eq 'hdr10' ? 'BT2020_3D_LUT_DATA' : '',
            get_command => $signal eq 'hdr10' ? 'GET_3D_LUT_DATA' : '',
            keep_calibration_mode => JSON::PP::false,
            calibration_mode_active => JSON::PP::false,
            helper_timeout => 220,
        });
        push @responses, { lut_reset => $lut };
        if (!$lut || ($lut->{status} || '') ne 'ok') {
            $::LAST_ERROR = $lut->{message} || 'Unable to reset the LG 3D LUT baseline';
            return 0;
        }
    }
    # Carry the exact TV signature selected by the reset helper into the
    # worker. The 3D worker resolves payload geometry from this data and will
    # fail closed if it is absent or unknown.
    my $preflight_profile_hash = ref($item->{capability_profile}) eq 'HASH'
        ? ($item->{capability_profile}{hash} || '') : '';
    $preflight_profile_hash ||= ref($item->{generation_profile}) eq 'HASH'
        ? ($item->{generation_profile}{capability_profile_hash} || '') : '';
    foreach my $envelope (reverse @responses) {
        next if ref($envelope) ne 'HASH';
        foreach my $response (values %$envelope) {
            next if ref($response) ne 'HASH';
            my $live_profile_hash = ref($response->{generation_profile}) eq 'HASH'
                ? ($response->{generation_profile}{capability_profile_hash} || '') : '';
            if ($preflight_profile_hash ne '' && $live_profile_hash ne ''
                && $preflight_profile_hash ne $live_profile_hash) {
                $::LAST_ERROR = 'The connected LG TV or firmware changed during calibration reset; calibration was stopped before measurement and generated LUT upload.';
                _log_action($::LAST_ERROR);
                return 0;
            }
            $item->{lg_generation} = $response->{lg_generation}
                if ref($response->{lg_generation}) eq 'HASH';
            $item->{generation_profile} = _slim_profile($response->{generation_profile})
                if ref($response->{generation_profile}) eq 'HASH';
        }
    }
    _log_action('Calibration resets complete; queued TV settings will be reapplied next');
    return 0 if !_write_artifact(PGAutomation::item_dir($RUN_ID, $item_number) . '/calibration/reset.json', {
        completed_at => time(),
        responses => \@responses,
        lg_generation => $item->{lg_generation},
        generation_profile => $item->{generation_profile},
        calibration_session_unconfirmed => scalar(grep {
            my $response = $_;
            grep { ref($_) eq 'HASH' && $_->{calibration_session_unconfirmed} } values %$response
        } @responses) ? JSON::PP::true : JSON::PP::false,
    });
    return 1;
}

sub _setup_white_error {
    ($::LAST_ERROR) = @_;
    _log_action($::LAST_ERROR);
    return undef;
}

sub _read_white {
    my ($item) = @_;
    $::LAST_ERROR = '';
    my $range = _default_range($item);
    my $max_bpc = $item->{max_bpc} || 10;
    my $code = _grey_code('sdr', 100, $range, $max_bpc);
    _log_action('Displaying 100% white and preparing the meter for setup luminance');
    my $pattern = _api('POST', '/api/pattern', {
        name => 'patch',
        r => $code, g => $code, b => $code,
        input_max => $max_bpc == 12 ? 4095 : $max_bpc >= 10 ? 1023 : 255,
        size => int($item->{patch_size} || 10),
        signal_mode => 'sdr',
        signal_range => $range,
    });
    if (!$pattern || ($pattern->{status} || '') ne 'ok') {
        return _setup_white_error('Setup white pattern failed: '.($pattern->{message}||$pattern->{status}||'no response'));
    }
    my $read_started = time();
    my $request_id = sprintf('automation-white-%d-%.0f-%d', $$, int($read_started*1000), ++$SETUP_WHITE_SEQUENCE);
    my $read = _api('POST', '/api/meter/read', {
        _measurement_options($item),
        display_type => $item->{display_type} || 'lcd',
        ccss_override => $item->{ccss_override} || '',
        refresh_rate => $item->{refresh_rate} || '',
        name => 'panel-light-white',
        patch_name => 'panel-light-white',
        patch_r => $code, patch_g => $code, patch_b => $code,
        ire => 100,
        request_id => $request_id,
        input_max => $max_bpc == 12 ? 4095 : $max_bpc >= 10 ? 1023 : 255,
        size => int($item->{patch_size} || 10),
        patch_size => int($item->{patch_size} || 10),
        signal_mode => 'sdr',
        signal_range => $range,
        transport_signal_range => $range,
        delay_ms => int($item->{delay_ms} // 1000),
    });
    if (!$read || (($read->{status} || '') ne 'measuring' && ($read->{status} || '') ne 'starting' && ($read->{status} || '') ne 'ok')) {
        return _setup_white_error('Setup white measurement was not accepted: '.($read->{message}||$read->{status}||'no response'));
    }
    _log_action('Meter request accepted; waiting for the setup white reading');
    my $deadline = time() + 240;
    my $wait_started=time();
    my $last_wait_log;
    my $stale_logged = 0;
    while (time() < $deadline) {
        my $result = _api('GET', '/api/meter/read/result', undef);
        my $state = lc($result->{status} || '');
        if ($state eq 'complete' || $state eq 'ok') {
            # The meter returns an envelope containing readings, not a reading
            # itself. Match the physical request before using its luminance.
            return _setup_white_error('Setup white response has no reading (status '.$state.')')
                if ref($result->{readings}) ne 'ARRAY' || ref($result->{readings}[0]) ne 'HASH';
            my $reading = $result->{readings}[0];
            my $stamp = $reading->{timestamp};
            my $stale = ($result->{request_id} || '') ne $request_id
                || (($reading->{request_id} || '') ne '' && $reading->{request_id} ne $request_id)
                || (defined($stamp) && "$stamp" =~ /^\d+(?:\.\d+)?$/ && $stamp > 0 && $stamp+1 < $read_started);
            if (!$stale) {
                foreach my $key (qw(r_code g_code b_code)) {
                    return _setup_white_error('Setup white response reports a different patch; luminance was not used')
                        if exists($reading->{$key}) && (!defined($reading->{$key}) || "$reading->{$key}" !~ /^\d+$/ || $reading->{$key} != $code);
                }
                my $luma = _luminance($reading);
                return _setup_white_error('Setup white response has no luminance value') if !defined($luma);
                return _setup_white_error('Setup white luminance must be positive; meter reported '.$luma.' cd/m2') if $luma <= 0;
                _log_action(sprintf('Setup white reading: %.2f cd/m2', $luma));
                return $reading;
            }
            _log_action('Ignoring an older or mismatched meter result; waiting for this setup white reading') if !$stale_logged++;
        } elsif ($state eq 'error' || $state eq 'cancelled') {
            return _setup_white_error('Setup white measurement '.$state.': '.($result->{message}||$result->{error_code}||'no reason returned'))
                if !($result->{request_id} || '') || $result->{request_id} eq $request_id;
        }
        _log_wait('the setup white reading',$wait_started,\$last_wait_log);
        _sleep_controlled(1) or return undef;
    }
    return _setup_white_error('Setup white measurement timed out after 240 s without a matching reading');
}

sub _luminance {
    my ($reading) = @_;
    return undef if ref($reading) ne 'HASH';
    foreach my $key (qw(luminance Y luminance_nits Y_nits white_luminance)) {
        return 0 + $reading->{$key} if defined($reading->{$key}) && "$reading->{$key}" =~ /^-?\d+(?:\.\d+)?$/;
    }
    foreach my $key (qw(reading result data)) {
        my $nested = $reading->{$key};
        my $value = _luminance($nested);
        return $value if defined($value);
    }
    return undef;
}

sub _panel_light_key {
    my ($item) = @_;
    return $item->{panel_light_key} if $item->{panel_light_key};
    my $panel = ref($item->{panel_light}) eq 'HASH' ? $item->{panel_light} : {};
    return $panel->{key} if $panel->{key};
    my $settings = ref($item->{settings}) eq 'HASH' ? $item->{settings} : {};
    foreach my $key (qw(oledPixelBrightness oledLight backlight)) {
        return $key if exists($settings->{$key});
    }
    return '';
}

sub _record_setup_luminance {
    my ($item,$luminance) = @_;
    return 0 if !defined($luminance) || $luminance <= 0;
    my $cal = $item->{calibration} ||= {};
    my $setup = $luminance < 10 ? 10 : $luminance > 10000 ? 10000 : $luminance;
    my $gamma = $cal->{target_gamma} || $item->{target_gamma} || 'bt1886';
    my $headroom = _default_range($item) eq '1' && ($item->{color_format} || '0') =~ /^(?:1|2)$/;
    my $fraction = $headroom ? (($item->{max_bpc} || 10) == 8 ? 239/219 : 959/876) : 1;
    my $ratio = $gamma eq 'srgb' ? (($fraction+0.055)/1.055)**2.4 : $fraction**($gamma eq '2.2' ? 2.2 : 2.4);
    $cal->{setup_luminance_reference} = $setup;
    $cal->{target_luminance} = $setup;
    $cal->{headroom_target_luminance} = $setup * $ratio;
    $item->{target_luminance} = $setup;
    return 1;
}

sub _panel_light_stage {
    my ($item_number, $item) = @_;
    my $panel = ref($item->{panel_light}) eq 'HASH' ? $item->{panel_light} : {};
    my $policy = lc($panel->{policy} || $item->{panel_light_policy} || 'fixed');
    my $key = _panel_light_key($item);
    if ($policy ne 'target') {
        my $verified = _apply_and_verify($item_number, $item, 'c5');
        return 0 if !$verified && $verified ne 'unverifiable';
        my ($reading,$luminance);
        if (_signal($item) eq 'sdr') {
            _sleep_controlled(2) or return 0;
            $reading = _read_white($item);
            $luminance = _luminance($reading);
            if (!_record_setup_luminance($item,$luminance)) {
                $::LAST_ERROR ||= 'Fixed panel light did not produce a valid setup white measurement';
                return 0;
            }
        }
        return 0 if !_write_artifact(PGAutomation::item_dir($RUN_ID, $item_number) . '/panel-light.json', {
            policy => 'fixed',
            key => $key,
            value => $key && ref($item->{settings}) eq 'HASH' ? $item->{settings}{$key} : undef,
            verified => $verified,
            setup_white_reading => $reading,
            setup_white_luminance => $luminance,
            completed_at => time(),
        });
        return _update_item_snapshot($item_number,$item);
    }
    if (!$key) {
        $::LAST_ERROR = 'Target panel-light policy requires a supported LG panel-light setting';
        return 0;
    }
    my $target = 0 + ($panel->{target_luminance} || $item->{target_luminance} || 100);
    $item->{settings} = {} if ref($item->{settings}) ne 'HASH';
    my $observed = _observed_settings(_api('POST', '/api/lg/picture-settings', {
        keys => [$key], picture_mode => _picture_mode($item), signal_mode => _signal($item),
    }));
    my $start = $item->{settings}{$key} // $panel->{initial_value} // $observed->{$key};
    my $start_assumed = 0;
    if (!defined($start) || $start !~ /^-?\d+(?:\.\d+)?$/) {
        # Some sets refuse to read the panel-light key while still accepting
        # writes. The loop converges from any start, so assume mid-range, but
        # record that the starting value was never read from the TV.
        _log("panel-light start value for $key could not be read; assuming 50");
        $start = 50; $start_assumed = 1;
    }
    my $current = int($start);
    $current = 0 if $current < 0; $current = 100 if $current > 100;
    my $initial = _apply_one_setting($item, $key, $current, 'picture');
    if (!_response_ok($initial)) { $::LAST_ERROR = $initial->{message} || 'Unable to set initial panel light'; return 0; }
    $item->{settings}{$key} = $current;
    _sleep_controlled(2) or return 0;
    my (@iterations, %measured);
    my ($best, $lower, $upper, $last_read);
    my ($converged, $reason, $detail) = (0, '', '');
    my $budget = 8;
    my $tolerance = $target * 0.03;
    $tolerance = 2 if $tolerance < 2;
    my $final_check = {verified => 'unverifiable'};
    for my $iteration (1..$budget) {
        my $reading = _read_white($item);
        my $luma = _luminance($reading);
        my $entry = {iteration=>$iteration, value=>$current, reading=>$reading, luminance=>$luma};
        push @iterations, $entry;
        my $prefix = sprintf('Panel light | Attempt %d/%d | Setting %d | ', $iteration, $budget, $current);
        if (!defined($luma) || $luma <= 0) {
            $reason = 'measurement-failed';
            $detail = $::LAST_ERROR || 'No valid white luminance measurement';
            $entry->{result} = $reason;
            _log_action($prefix.$detail);
            last;
        }
        $last_read = $luma;
        $measured{$current} = $entry;
        $best = $entry if !$best || abs($luma-$target) < abs($best->{luminance}-$target);
        $prefix .= sprintf('Y %.2f cd/m2; target %.2f +/-%.2f | ', $luma, $target, $tolerance);
        if (abs($luma-$target) <= $tolerance) {
            $entry->{result} = 'converged';
            $converged = 1;
            $reason = 'converged';
            _log_action($prefix.'Target reached');
            last;
        }
        # Bounds come from actual measurements. Never revisit a setting or
        # call the target unreachable merely because arithmetic rounded flat.
        $lower = $current if $luma < $target && (!defined($lower) || $current > $lower);
        $upper = $current if $luma > $target && (!defined($upper) || $current < $upper);
        if (defined($lower) && defined($upper) && $upper-$lower == 1) {
            $reason = 'resolution-limit';
            $detail = sprintf('Adjacent settings %d (%.2f cd/m2) and %d (%.2f cd/m2) straddle the target; neither meets tolerance',
                $lower, $measured{$lower}{luminance}, $upper, $measured{$upper}{luminance});
        } elsif (($current == 0 && $luma > $target) || ($current == 100 && $luma < $target)) {
            $reason = 'control-limit';
            $detail = 'Measured control boundary cannot reach the target';
        } elsif ($iteration == $budget) {
            $reason = 'attempt-limit';
            $detail = 'Measurement budget exhausted; target reachability unknown';
        }
        if ($reason) {
            $entry->{result} = $reason;
            _log_action($prefix.$detail);
            last;
        }
        my $next = int(($current || 1) * $target / $luma + 0.5);
        $next = 0 if $next < 0; $next = 100 if $next > 100;
        my $decision = 'Trying '.$next;
        if (defined($lower) && defined($upper)) {
            $next = int(($lower+$upper)/2);
            $decision = "Measured bracket $lower..$upper; trying $next";
        } elsif ($next == $current || exists($measured{$next})) {
            $next = $current + ($luma > $target ? -1 : 1);
            $decision = "Rounded adjustment unchanged or already measured; trying $next";
        }
        if ($next < 0 || $next > 100 || exists($measured{$next})) {
            $reason = 'search-stalled';
            $detail = 'No unmeasured candidate in the search direction; target reachability unknown';
            $entry->{result} = $reason;
            _log_action($prefix.$detail);
            last;
        }
        $entry->{next_value} = $next;
        _log_action($prefix.$decision);
        my $result = _apply_one_setting($item, $key, $next, 'picture');
        if (!_response_ok($result)) {
            $reason = $entry->{result} = 'set-failed';
            $detail = $result->{message} || "Unable to adjust panel light $key";
            last;
        }
        $current = $next;
        $item->{settings}{$key} = $current;
        $final_check = _read_and_verify_settings($item_number, $item, 'c5-panel-iteration');
        if (!$final_check->{verified} && $final_check->{verified} ne 'unverifiable') {
            $reason = $entry->{result} = 'set-unverified';
            $detail = 'Panel-light adjustment did not verify against the LG TV';
            last;
        }
        if (!_sleep_controlled(2)) { $reason = 'cancelled'; last; }
    }
    _refresh_control();
    if ($STOP_REQUESTED && $reason ne 'cancelled') {
        # Stop supersedes the search outcome but must not erase it.
        $detail = 'Stop requested'.($reason ? "; search outcome was $reason".($detail ? ": $detail" : '') : '');
        $reason = 'cancelled';
    }
    $converged = 0 if $reason eq 'cancelled';
    my $best_restore = 'not-needed';
    if (!$converged && $best && $reason ne 'cancelled' && $current != $best->{value}) {
        my $restore = _apply_one_setting($item, $key, $best->{value}, 'picture');
        $best_restore = 'failed';
        if (_response_ok($restore)) {
            $current = $best->{value};
            $item->{settings}{$key} = $current;
            $final_check = _read_and_verify_settings($item_number, $item, 'c5-panel-best');
            $best_restore = $final_check->{verified} eq '1' ? 'verified'
                : $final_check->{verified} eq 'unverifiable' ? 'unverifiable' : 'failed';
        }
        _log_action(sprintf('Panel light | Restore best setting %d; measured Y %.2f cd/m2 | %s',
            $best->{value}, $best->{luminance}, $best_restore));
    }
    if ($converged) {
        $final_check = _read_and_verify_settings($item_number, $item, 'c5');
        if (!$final_check->{verified} && $final_check->{verified} ne 'unverifiable') {
            $converged = 0;
            $reason = 'set-unverified';
            $detail = 'Panel-light stage settings did not verify against the LG TV';
        }
    }
    if (!$converged) {
        $::LAST_ERROR = sprintf('Panel light stopped after %d/%d measurements: %s; target %.2f +/-%.2f cd/m2',
            scalar(@iterations), $budget, $detail || $reason, $target, $tolerance);
        $::LAST_ERROR .= sprintf('; best setting %d measured %.2f cd/m2', $best->{value}, $best->{luminance}) if $best;
        $::LAST_ERROR .= '; best-setting restore '.$best_restore if $best_restore ne 'not-needed';
        _log_action($::LAST_ERROR);
    }
    my $result = {
        policy=>'target', key=>$key, target_luminance=>$target, tolerance=>$tolerance,
        iterations=>\@iterations, attempts=>scalar(@iterations), attempt_budget=>$budget,
        settled_value=>$current, last_luminance=>$last_read,
        best_value=>$best ? $best->{value} : undef, best_luminance=>$best ? $best->{luminance} : undef,
        best_restore=>$best_restore, outcome=>$reason,
        start_value_assumed=>$start_assumed ? JSON::PP::true : JSON::PP::false,
        converged=>$converged ? JSON::PP::true : JSON::PP::false,
        settings_verified=>$final_check->{verified}, completed_at=>time(),
    };
    $result->{failure} = $::LAST_ERROR if !$converged;
    return 0 if !_write_artifact(PGAutomation::item_dir($RUN_ID, $item_number) . '/panel-light.json', $result);
    return 0 if !_update_item_snapshot($item_number, $item);
    return 0 if !$converged;
    return 0 if !_record_setup_luminance($item, $last_read);
    $item->{warnings} ||= [];
    push @{$item->{warnings}}, 'panel-light-start-assumed'
        if $start_assumed && !grep { !ref($_) && $_ eq 'panel-light-start-assumed' } @{$item->{warnings}};
    return _update_item_snapshot($item_number, $item);
}

sub _update_item_snapshot {
    my ($item_number, $item) = @_;
    my $path = PGAutomation::item_dir($RUN_ID, $item_number) . '/item.json';
    my ($ok) = PGAutomation::with_lock($path, sub { return $item; });
    _log("item $item_number snapshot update failed") if !$ok;
    return $ok;
}

sub _calibration_greyscale_stage {
    my ($item_number, $item) = @_;
    return 0 if !_set_dv_map($item, '2');
    _log('launching LG greyscale AutoCal worker');
    $ACTIVE_WORKER = 'grey';
    my $grey_start = _start_worker('/api/meter/lg-autocal', '/api/meter/lg-autocal/status', _grey_payload($item));
    if (!$grey_start || ($grey_start->{status} || '') ne 'started') {
        _clear_active_worker();
        $::LAST_ERROR = $grey_start->{message} || 'Unable to start LG greyscale AutoCal';
        return 0;
    }
    my $grey = _wait_worker('/api/meter/lg-autocal/status', 'greyscale AutoCal', $item);
    my $copied = _copy_worker_files($item_number, 'grey', $grey);
    if ($STOP_REQUESTED) {
        _log('LG greyscale AutoCal worker retained for stop cleanup');
        return 0 if !$copied || $STOP_REQUESTED;
    }
    return 0 if !$copied;
    if (!ref($grey) || ($grey->{status} || '') ne 'complete') {
        $::LAST_ERROR = $grey->{message} || $grey->{error} || 'Greyscale worker did not complete';
        $::LAST_ERROR_DETAIL = $grey->{failure_detail} if ref($grey->{failure_detail}) eq 'HASH';
        return 0;
    }
    _clear_active_worker();
    # The greyscale worker reports an unknown outcome (a near-black patch it
    # could not measure and left uncorrected) as a processing warning; lift it
    # onto the item as the 3D stage does, so the item finishes
    # complete-with-warnings instead of reading as fully converged.
    for my $warning (@{$grey->{automation_processing_warnings} || []}) {
        push @{$item->{warnings}}, $warning if !grep {$_ eq $warning} @{$item->{warnings}||[]};
    }
    my $verified = $grey->{ddc_upload_verified} || $grey->{final_1d_lut_upload_verified};
    return {verified => $verified ? JSON::PP::true : 'unverifiable',
        timing_curve => $grey->{timing_curve},
        final_1d_lut_upload_verified => $grey->{final_1d_lut_upload_verified},
        ddc_upload_verified => $grey->{ddc_upload_verified}};
}

sub _calibration_volume_stage {
    my ($item_number, $item) = @_;
    my $signal = _signal($item);
    if ($signal eq 'dv') {
        # A new attempt starts with no dispatch marker and no accepted
        # artifact from an earlier attempt.
        my @previous = map { PGAutomation::item_dir($RUN_ID, $item_number) . "/calibration/$_" } qw(dv-profile-upload-dispatched.json dv-profile-upload.json);
        unlink(@previous);
        if (my @left = grep { -e $_ } @previous) {
            $::LAST_ERROR = 'Unable to clear the previous Dolby Vision upload record: ' . join(', ', @left);
            return 0;
        }
        return 0 if !_set_dv_map($item, '2');
        _log('launching Dolby Vision profile worker');
        $ACTIVE_WORKER = 'dv';
        my $start = _start_worker('/api/lg/dv-profile/start', '/api/lg/dv-profile/status', _dv_payload($item));
        if (!$start || ($start->{status} || '') ne 'started') {
            _clear_active_worker();
            $::LAST_ERROR = $start->{message} || 'Unable to start Dolby Vision profile measurement';
            return 0;
        }
        my $dv = _wait_worker('/api/lg/dv-profile/status', 'Dolby Vision profile', $item);
        my $copied = _copy_worker_files($item_number, 'dv', $dv);
        if ($STOP_REQUESTED) {
            _log('Dolby Vision profile worker retained for stop cleanup');
            return 0 if !$copied || $STOP_REQUESTED;
        }
        return 0 if !$copied;
        if (!ref($dv) || ($dv->{status} || '') ne 'complete') {
            $::LAST_ERROR = (ref($dv) && ($dv->{message} || $dv->{error})) || 'Dolby Vision profile worker did not complete';
            return 0;
        }
        _clear_active_worker();
        my $measurements = $dv->{measurements} || $dv->{dv_profile_measurements} || $dv->{result};
        if (ref($measurements) ne 'HASH') {
            $::LAST_ERROR = 'Dolby Vision profile did not return measurements';
            return 0;
        }
        my $before_upload = _read_and_verify_settings($item_number, $item, 'dv-profile-before-upload');
        if (!$before_upload->{verified}) {
            my $read_failed = $before_upload->{storage_failure}
                || grep { $_->{read_failed} } values %{$before_upload->{values} || {}};
            return _settings_boundary_pause($item, 'dv-profile-before-upload', 'volume-done',
                _settings_failure_message('dv-profile-before-upload', $before_upload, 1), $read_failed);
        }
        my $mode = _api('GET', '/api/lg/status', undef);
        return _settings_boundary_pause($item, 'dv-profile-before-upload', 'volume-done',
            'Calibration mode is unavailable before profile upload; no profile was uploaded', 1)
            if ref($mode) ne 'HASH' || ($mode->{status} || '') ne 'ok' || $mode->{disconnected}
                || !exists($mode->{calibration_mode});
        my $proof = {transition=>'dv-profile-upload', verified=>$before_upload->{verified},
            values=>$before_upload->{values}, calibration_mode=>$mode->{calibration_mode} ? 1 : 0, checked_at=>time()};
        _log_action('Uploading measured Dolby Vision profile; TV calibration mode currently '.($proof->{calibration_mode} ? 'on' : 'off'));
        return 0 if !_write_artifact(PGAutomation::item_dir($RUN_ID, $item_number) . '/calibration/dv-profile-upload-dispatched.json',
            {dispatched_at => time(), picture_mode => _picture_mode($item)});
        my $upload = _api('POST', '/api/lg/dv-profile/upload', {
            picture_mode => _picture_mode($item),
            tv_input => $item->{tv_input}||'',
            signal_mode => 'dv',
            measurements => $measurements,
            keep_calibration_mode => JSON::PP::false,
            calibration_mode_active => $proof->{calibration_mode} ? JSON::PP::true : JSON::PP::false,
        });
        if (!$upload || ($upload->{status} || '') ne 'ok') {
            $::LAST_ERROR = $upload->{message} || 'Dolby Vision profile upload failed';
            return 0;
        }
        return 0 if !_write_artifact(PGAutomation::item_dir($RUN_ID, $item_number) . '/calibration/dv-profile-upload.json', $upload);
        # The helper reports cal_end_tolerated when the TV rejected CAL_END in a
        # known-harmless way. The profile write was accepted but CAL_END was
        # never confirmed, so the stage is recorded as unverifiable (a warning
        # on the item), not verified.
        return {verified => 'unverifiable', cal_end_tolerated => JSON::PP::true} if $upload->{cal_end_tolerated};
        return {verified => JSON::PP::true, cal_end_tolerated => JSON::PP::false, settings_before_upload=>$proof};
    }
    _log('launching LG 3D LUT AutoCal worker');
    $ACTIVE_WORKER = '3d';
    my $start = _start_worker('/api/meter/lg-3d-autocal/start', '/api/meter/lg-3d-autocal/status', _three_d_payload($item, _run(), $item_number));
    if (!$start || ($start->{status} || '') ne 'started') {
        _clear_active_worker();
        $::LAST_ERROR = $start->{message} || 'Unable to start LG 3D LUT AutoCal';
        return 0;
    }
    my $three_d = _wait_worker('/api/meter/lg-3d-autocal/status', '3D LUT AutoCal', $item);
    if (ref($three_d) eq 'HASH' && ($three_d->{status} || '') eq 'error' && $three_d->{upload_retry_available}) {
        my $retry = _api('POST', '/api/meter/lg-3d-autocal/retry-upload', { run_id => $RUN_ID });
        if ($retry && ($retry->{status} || '') eq 'started') {
            $three_d = _wait_worker('/api/meter/lg-3d-autocal/status', '3D LUT upload retry', $item);
        }
    }
    my $copied = _copy_worker_files($item_number, '3d', $three_d);
    if (ref($three_d) eq 'HASH') {
        for my $check (@{$three_d->{automation_processing_checks} || []}) {
            if (!PGAutomation::append_line_locked(
                PGAutomation::item_dir($RUN_ID,$item_number).'/settings-checks.ndjson',
                PGAutomation::encode_json($check)."\n")) {
                $copied = 0;
                $::LAST_ERROR = 'Unable to save 3D processing-setting verification evidence';
            }
        }
        for my $warning (@{$three_d->{automation_processing_warnings} || []}) {
            push @{$item->{warnings}}, $warning if !grep {$_ eq $warning} @{$item->{warnings}||[]};
        }
    }
    if ($STOP_REQUESTED) {
        _log('LG 3D LUT AutoCal worker retained for stop cleanup');
        return 0 if !$copied || $STOP_REQUESTED;
    }
    return 0 if !$copied;
    if (!ref($three_d) || ($three_d->{status} || '') ne 'complete') {
        $::LAST_ERROR = $three_d->{message} || '3D LUT AutoCal did not complete';
        return 0;
    }
    _clear_active_worker();
    return {verified => ($three_d->{terminal_commit_verified} || $three_d->{upload_verified})
        ? JSON::PP::true : 'unverifiable', terminal_commit_verified => $three_d->{terminal_commit_verified},
        timing_tail_seconds=>$three_d->{timing_tail_seconds}};
}

# 1 when a Dolby Vision profile upload was dispatched in the latest attempt
# without an accepted result written after it: the TV may carry that profile,
# so the 1D result is not reused without the calibration reset. The marker is
# removed when the profile stage starts and written just before the upload.
sub _dv_upload_unresolved {
    my ($number,$item)=@_;
    return 0 if _signal($item) ne 'dv';
    my $dir=PGAutomation::item_dir($RUN_ID,$number).'/calibration';
    return 0 if !-f "$dir/dv-profile-upload-dispatched.json";
    # The stage start removes the previous attempt's accepted artifact with
    # the marker, so an ok artifact beside a marker is this attempt's (the
    # appliance has no clock worth ordering files by).
    my $upload=PGAutomation::read_json_file("$dir/dv-profile-upload.json");
    return (ref($upload) eq 'HASH' && ($upload->{status}||'') eq 'ok') ? 0 : 1;
}

# 1 when the committed 1D result carries the 3072-value curve the baseline
# restore re-uploads (Dolby Vision jobs have no 3D baseline to restore).
sub _profile_baseline_data_ok {
    my ($number,$item)=@_;
    return 1 if _signal($item) eq 'dv';
    my $grey=PGAutomation::read_json_file(PGAutomation::item_dir($RUN_ID,$number).'/calibration/grey-state.json');
    my $dpg=ref($grey) eq 'HASH' ? $grey->{_signal($item) eq 'hdr10'?'hdr20_1d_dpg_data':'sdr_1d_dpg_data'} : undef;
    return ref($dpg) eq 'ARRAY' && @$dpg==3072 ? 1 : 0;
}

sub _restore_profile_baseline {
    my ($number,$item)=@_;
    return 1 if _signal($item) eq 'dv';
    my $grey=PGAutomation::read_json_file(PGAutomation::item_dir($RUN_ID,$number).'/calibration/grey-state.json');
    my $dpg=ref($grey) eq 'HASH' ? $grey->{_signal($item) eq 'hdr10'?'hdr20_1d_dpg_data':'sdr_1d_dpg_data'} : undef;
    die 'Cannot restore profile baseline: verified 1D data is missing' if !_resume_calibration_artifacts_ok($number,$item,'grey')
        || ref($dpg) ne 'ARRAY' || @$dpg!=3072;
    _log_action('Restoring saved 1D curve and unity 3D baseline before repeating the profile; no 1D remeasurement');
    die 'Unable to close calibration before restoring profile baseline' if !_ensure_calibration_mode_off($item);
    my $reset=_api('POST','/api/lg/3d-lut/reset',{
        picture_mode=>_picture_mode($item),signal_mode=>_signal($item),
        upload_command=>_signal($item) eq 'hdr10'?'BT2020_3D_LUT_DATA':'BT709_3D_LUT_DATA',
        keep_calibration_mode=>JSON::PP::true,calibration_mode_active=>JSON::PP::false,
    });
    die((ref($reset) eq 'HASH' && $reset->{message})||'Unity profile baseline reset failed') if ref($reset) ne 'HASH'
        || ($reset->{status}||'') ne 'ok' || !$reset->{upload_verified};
    my $upload=_api('POST','/api/lg/1d-dpg/upload',{
        picture_mode=>_picture_mode($item),signal_mode=>_signal($item),dpg_data=>$dpg,
        ddc_layout=>_signal($item) eq 'hdr10'?'hdr20':'sdr26',
        keep_calibration_mode=>JSON::PP::true,calibration_mode_active=>JSON::PP::true,
    });
    die((ref($upload) eq 'HASH' && $upload->{message})||'Saved 1D curve restore failed') if ref($upload) ne 'HASH'
        || ($upload->{status}||'') ne 'ok' || !$upload->{dpg_uploaded};
    die($::LAST_ERROR||'Profile baseline settings did not verify')
        if !_apply_and_verify($number,$item,'resume-profile-baseline',1,1);
    my $mode=_api('GET','/api/lg/status',undef);
    die 'Profile baseline did not retain a confirmed calibration session' if ref($mode) ne 'HASH'
        || ($mode->{status}||'') ne 'ok' || $mode->{disconnected} || !$mode->{calibration_mode};
    die 'Unable to save restored profile baseline evidence' if !_write_artifact(
        PGAutomation::item_dir($RUN_ID,$number).'/calibration/profile-baseline-restore.json',
        {restored_at=>time(),picture_mode=>_picture_mode($item),verified=>JSON::PP::true,
         source=>'grey-state.json',data_count=>scalar @$dpg,unity_reset=>$reset,dpg_upload=>$upload});
    delete $item->{profile_baseline_needs_restore};
    delete $item->{profile_baseline_restore_failures};
    return 1;
}

sub _close_calibration {
    my ($item) = @_;
    my ($closed, $off, $status);
    for my $attempt (1..3) {
        $off = _api('POST', '/api/lg/calibration-mode', {
            enabled => JSON::PP::false,
            picture_mode => _picture_mode($item),
            tv_input => $item->{tv_input}||'',
            signal_mode => _signal($item),
        });
        $status = _api('GET', '/api/lg/status', undef);
        $closed = ref($status) eq 'HASH' && ($status->{status} || '') eq 'ok'
            && !$status->{disconnected} && exists($status->{calibration_mode}) && !$status->{calibration_mode};
        last if $closed;
        _sleep_controlled(1) or last;
    }
    # Close the live LG autocal session by the run id that run/begin returned,
    # not the automation run id: the daemon ignores a mismatched id but still
    # answers ok, which would leave the workflow flags set for the next tab.
    # With no stored id (begin timed out after the daemon created the run, or
    # run.json was momentarily unreadable) send an empty id so the daemon
    # attributes the call by client_run_token instead of a queue id that can
    # never match.
    my $end = _api('POST', '/api/lg/autocal/run/end', {
        status => 'complete',
        note => 'Automation calibration stage complete',
        run_id => _run()->{lg_run_id} || '',
        client_run_token => $TOKEN,
    });
    my $end_ok = ref($end) eq 'HASH' && ($end->{status} || '') eq 'ok'
        && !$end->{stale_run_ignored};
    $::LAST_ERROR = 'Another autocal session owns the live LG run, so this job could not close it'
        if ref($end) eq 'HASH' && $end->{stale_run_ignored};
    return ($closed && $end_ok, $off, $status, $end);
}

sub _ensure_calibration_mode_off {
    my ($item) = @_;
    _log_action('Closing TV calibration mode before measurements');
    for my $attempt (1..3) {
        my $off = _api('POST', '/api/lg/calibration-mode', {
            enabled => JSON::PP::false,
            picture_mode => _picture_mode($item),
            tv_input => $item->{tv_input}||'',
            signal_mode => _signal($item),
        });
        my $status = _api('GET', '/api/lg/status', undef);
        if (ref($status) eq 'HASH' && ($status->{status} || '') eq 'ok'
            && !$status->{disconnected} && exists($status->{calibration_mode}) && !$status->{calibration_mode}) {
            _log_action('TV calibration mode confirmed off');
            return 1;
        }
        _sleep_controlled(1) or return 0;
    }
    $::LAST_ERROR = 'LG calibration mode could not be confirmed off';
    return 0;
}

sub _quality_contract {
    my ($item)=@_;
    my $intent={map {$_=>PGAutomation::clone($item->{$_})}
        qw(quality post_series target_white target_gamma target_gamut delta_e_formula signal_format picture_mode)};
    # A quality proof belongs to this calibration, not just the same recipe.
    # Canonicalise numeric strings as the queue contract does: comparisons by
    # older JSON::PP builds can otherwise change scalar flags during scoring.
    $intent->{calibration_epoch}=[map {{name=>$_->{name},status=>$_->{status},completed_at=>$_->{completed_at}}}
        grep {ref($_) eq 'HASH' && ($_->{name}||'')=~/\A(?:greyscale-done|volume-done|session-closed)\z/}
        @{$item->{checkpoints}||[]}];
    return PGAutomation::encode_json({intent_hash=>PGAutomationPlan::intent_hash($intent),
        tv_input=>$item->{tv_input}||'',profile_hash=>$item->{capability_profile}{hash}||''});
}

sub _enforce_quality {
    my ($item)=@_;
    return ref($item->{quality}) eq 'HASH' && ($item->{quality}{policy}||'audit') eq 'enforce';
}

sub _quality_admits_apply {
    my ($number,$item)=@_;
    return 1 if !_enforce_quality($item);
    my $result=PGAutomation::read_json_file(PGAutomation::item_dir($RUN_ID,$number).'/quality.json');
    return 0 if !$item->{quality}{enabled} || !_stages($item)->{post} || ref($result) ne 'HASH'
        || !$result->{enabled} || ($result->{contract}||'') ne _quality_contract($item);
    for my $key (_series_selection($item,'post')) {
        my $series=$result->{series}{$key};
        return 0 if ref($series) ne 'HASH' || !defined($series->{passed}) || !$series->{passed};
    }
    return 1;
}

sub _quality_stage {
    my ($item_number, $item) = @_;
    my $quality = ref($item->{quality}) eq 'HASH' ? $item->{quality} : {};
    my $result = {
        enabled => $quality->{enabled} ? JSON::PP::true : JSON::PP::false,
        formula => $quality->{dE_formula} || $item->{delta_e_formula} || 'deitp',
        policy => $quality->{policy} || 'audit',
        contract => _quality_contract($item),
        series => {},
        warnings => [],
        completed_at => time(),
    };
    if ($quality->{enabled}) {
        my $limits = ref($quality->{limits}) eq 'HASH' ? $quality->{limits} : {};
        foreach my $key (_series_selection($item, 'post')) {
            my $snapshot = PGAutomation::read_json_file(PGAutomation::item_dir($RUN_ID, $item_number) . "/post/$key.json") || {};
            my ($average, $max, $count, $missing) = PGAutomation::quality_summary(
                $snapshot, $result->{formula}, $item->{target_white});
            my $limit = ref($limits->{$key}) eq 'HASH' ? $limits->{$key} : {};
            my $expected=ref($snapshot->{steps}) eq 'ARRAY' ? scalar(@{$snapshot->{steps}}) : 0;
            $missing++ if ($snapshot->{status}||'') ne 'complete' || !$expected || $count<$expected;
            $missing++ if _enforce_quality($item) && !defined($limit->{avg}) && !defined($limit->{max});
            my $miss = (defined($average) && defined($limit->{avg}) && $average > $limit->{avg})
                || (defined($max) && defined($limit->{max}) && $max > $limit->{max});
            $result->{series}{$key} = {
                average => $average,
                maximum => $max,
                readings => $count,
                limits => $limit,
                missing_readings => $missing,
                passed => !$count || $missing ? undef : ($miss ? JSON::PP::false : JSON::PP::true),
            };
            push @{$result->{warnings}}, {
                code => 'quality-limit',
                series => $key,
                average => $average,
                maximum => $max,
            } if $miss;
            push @{$result->{warnings}}, {code => 'quality-unverifiable', series => $key,
                message => 'Missing measurements or target metadata; quality was not verified'}
                if !$count || $missing;
        }
    }
    return undef if !_write_artifact(PGAutomation::item_dir($RUN_ID, $item_number) . '/quality.json', $result);
    return $result;
}

sub _apply_all {
    my ($item_number, $item) = @_;
    if (!_quality_admits_apply($item_number,$item)) {
        $::LAST_ERROR_CODE='quality-gate-blocked';
        $::LAST_ERROR='Apply to All Inputs blocked: enforced quality limits were not independently passed for this job. Results are retained for review.';
        return 0;
    }
    my $fault = PGAutomation::read_json_file(PGAutomation::base_dir() . '/fault.json');
    if (ref($fault) eq 'HASH' && ($fault->{stage} || '') eq 'apply-all' && ($fault->{mode} || '') eq 'error') {
        unlink(PGAutomation::base_dir() . '/fault.json');
        $item->{fault_injected} = JSON::PP::true;
        if (!_write_artifact(PGAutomation::item_dir($RUN_ID, $item_number) . '/apply-all.json', {
            status => 'error',
            error_code => 'fault-injected',
            fault_injected => JSON::PP::true,
            completed_at => time(),
        })) {
            return 0;
        }
        $::LAST_ERROR = 'Test fault injected at apply-all';
        return 0;
    }
    my $check = _read_and_verify_settings($item_number, $item, 'c9')->{verified};
    return 0 if !$check && $check ne 'unverifiable';
    my $response = _api('POST', '/api/lg/picture-settings/apply-all-inputs', {
        picture_mode => _picture_mode($item),
        tv_input => $item->{tv_input}||'',
        signal_mode => _signal($item),
    });
    my $outcome = 'failed';
    my $confirmation_unavailable = ref($response) eq 'HASH' && ($response->{status} || '') eq 'ok'
        && !$response->{error_code} && !$response->{confirmed} && $response->{confirmation_unavailable}
        && ($response->{transport} || '') =~ /^(?:ssap|luna)$/;
    if (ref($response) eq 'HASH' && ($response->{status} || '') eq 'ok') {
        # Successful dispatch is not proof of a completed copy. Distinguish a
        # known unsupported confirmation read from other unconfirmed results.
        $outcome = $response->{confirmed} ? 'confirmed' : $confirmation_unavailable ? 'sent-unconfirmed' : 'unverified';
    }
    my $record = {
        %{$response || {}},
        outcome => $outcome,
        completed_at => time(),
    };
    return 0 if !_write_artifact(PGAutomation::item_dir($RUN_ID, $item_number) . '/apply-all.json', $record);
    my $error_code = ref($response) eq 'HASH' ? ($response->{error_code} || '') : '';
    if ($outcome eq 'failed' || $error_code =~ /^(?:lg-calibration-session-held|apply-all-inputs-unsupported)$/) {
        $::LAST_ERROR = (ref($response) eq 'HASH' ? $response->{message} : undef) || 'LG apply-to-all-inputs failed';
        return 0;
    }
    $item->{warnings} ||= [];
    push @{$item->{warnings}}, 'apply-all-unverified' if $outcome eq 'unverified';
    _log_action('Apply to All Inputs sent - confirmation unavailable on this TV') if $confirmation_unavailable;
    return {verified => $outcome eq 'confirmed' && $check eq '1' ? JSON::PP::true : 'unverifiable', outcome => $outcome,
        confirmation_unavailable => $confirmation_unavailable ? JSON::PP::true : JSON::PP::false,
        settings_verified => $check};
}

# Panel protection (TPC/GSR) is the OLED's static-brightness limiter. LG's
# calibration mode already suspends it while the 1D/3D data is measured, and
# the grey-field insertion breaks up static patches for the readings taken
# outside it, so switching it off is an explicit opt-in per job. The TV
# offers no readback: a sent request is evidence of a dispatch only, and an
# opted-in run re-enables both controls when it ends (boot recovery retries
# the restore after a crash) because the factory state is the only state
# this runner can know.
sub _panel_protection_wanted {
    my ($item) = @_;
    my $config = ref($item->{panel_protection}) eq 'HASH' ? $item->{panel_protection} : {};
    return 0 if !$config->{disable};
    # Readiness stamps the matrix verdict; without that review nothing is sent.
    return 0 if !defined($item->{panel_protection_supported}) || "$item->{panel_protection_supported}" ne '1';
    return 1;
}

sub _panel_protection_disable {
    my ($item_number, $item) = @_;
    return { skipped => JSON::PP::true } if !_panel_protection_wanted($item);
    die 'Unable to journal panel protection restoration; no disable request sent'
        if !ref(_update_run(sub {
            my ($run) = @_;
            $run->{panel_protection} ||= {};
            @{$run->{panel_protection}}{qw(restore_pending disabled_at item_number verification_state)} =
                (JSON::PP::true, time(), $item_number, 'dispatch-pending');
        }));
    my $response = _api('POST', '/api/lg/panel-protection', {
        enable => JSON::PP::false,
        picture_mode => _picture_mode($item), tv_input => $item->{tv_input} || '', signal_mode => _signal($item),
    });
    my $ok = ref($response) eq 'HASH' && ($response->{status} || '') eq 'ok';
    my $record = { %{ref($response) eq 'HASH' ? $response : {}}, outcome => $ok ? 'sent-unverified' : 'failed', completed_at => time() };
    # A rejected compound request can have disabled one of TPC/GSR. A lost
    # reply proves even less. Keep the obligation for every dispatched attempt.
    return 0 if !_write_artifact(PGAutomation::item_dir($RUN_ID, $item_number) . '/panel-protection.json', $record);
    die 'Unable to save panel protection evidence; restoration remains pending'
        if !ref(_update_run(sub {
            $_[0]{panel_protection}{controls} = ref($response) eq 'HASH' ? ($response->{controls} || {}) : {};
            $_[0]{panel_protection}{verification_state} = $ok ? ($response->{verification_state} || 'acknowledged_unverified') : 'outcome-unknown';
        }));
    if ($ok) {
        _log_action('Panel protection (TPC/GSR) disable sent - the TV offers no readback, so it stays unverified');
    } else {
        $item->{warnings} ||= [];
        push @{$item->{warnings}}, 'panel-protection-failed'
            if !grep { !ref($_) && $_ eq 'panel-protection-failed' } @{$item->{warnings}};
        _log_action('Panel protection disable failed or was partial; re-enable remains required');
    }
    return $record;
}

sub _restore_panel_protection {
    my ($run) = @_;
    my $latest = eval { _run() } || {};
    my $state = ref($latest) eq 'HASH' && ref($latest->{panel_protection}) eq 'HASH' ? $latest->{panel_protection}
        : (ref($run) eq 'HASH' && ref($run->{panel_protection}) eq 'HASH' ? $run->{panel_protection} : undef);
    return undef if !$state || !$state->{restore_pending};
    my $response = _api('POST', '/api/lg/panel-protection', { enable => JSON::PP::true }, 1, 0);
    my $ok = ref($response) eq 'HASH' && ($response->{status} || '') eq 'ok';
    my $message = (ref($response) eq 'HASH' && $response->{message}) || 'restoration request failed';
    my $saved = _update_run(sub {
        my ($state) = @_;
        $state->{panel_protection} = {} if ref($state->{panel_protection}) ne 'HASH';
        $state->{panel_protection}{restore_pending} = $ok ? JSON::PP::false : JSON::PP::true;
        $state->{panel_protection}{restore_attempted_at} = time();
        $state->{panel_protection}{restore_outcome} = $ok ? 'sent-unverified' : 'failed';
        $state->{panel_protection}{restore_message} = $message;
        $state->{panel_protection}{restored_at} = time() if $ok;
    });
    die 'Unable to persist panel protection restoration; ownership retained' if !ref($saved);
    if ($ok) {
        _log_action('Panel protection (TPC/GSR) re-enable sent - the TV offers no readback, so it stays unverified');
        return undef;
    }
    _log("Panel protection restoration failed: $message");
    return { key => 'panel_protection', value => 'enabled', message => $message };
}

sub _checkpoint_record {
    my ($item_number, $item, $name, $verified, $evidence, $status) = @_;
    $status = 'done' if !defined($status);
    my $record = {
        name => $name,
        status => $status,
        verified => $verified,
        evidence => $evidence || {},
        completed_at => time(),
    };
    if ($status eq 'done' && ($item->{active_stage}||'') eq $name && $item->{stage_started_at}) {
        $record->{duration_seconds}=time()-$item->{stage_started_at};
        $record->{timing_curve}=$evidence->{timing_curve} if ref($evidence->{timing_curve}) eq 'HASH';
        $record->{timing_tail_seconds}=$evidence->{timing_tail_seconds} if defined($evidence->{timing_tail_seconds});
    }
    $item->{checkpoints} ||= [];
    push @{$item->{checkpoints}}, $record;
    $item->{checkpoint} = $name;
    $item->{checkpoint_status} = $status;
    $item->{active_stage} = '';
    my $item_saved = _update_item_snapshot($item_number, $item);
    # Hide the old cache before the manifest advances, but retain it for a
    # failed commit. Holding the manifest open prevents inode reuse while we
    # check whether write_json_atomic published a replacement before failing.
    my $timing_cache = "$RUN_DIR/timing.json";
    my $timing_previous = "$timing_cache.previous";
    my ($timing_manifest, $timing_staged);
    if (-e $timing_cache) {
        $timing_manifest = undef if !open($timing_manifest, '<', $RUN_FILE);
        $timing_staged = rename($timing_cache, $timing_previous);
        if (!$timing_staged) {
            _log('Unable to retain previous optional calibration timing history: '.$!);
            _log('Unable to invalidate optional calibration timing history: '.$!) if !unlink($timing_cache);
        }
    }
    my $run_saved = _update_run(sub {
        my ($run) = @_;
        $run->{active_stage} = '';
        $run->{checkpoint} = $name;
        $run->{last_checkpoint} = $record;
        $run->{items}[$item_number] = $item if ref($run->{items}) eq 'ARRAY';
    });
    if (ref($run_saved) eq 'HASH') {
        my $timings={version=>1,samples=>PGAutomationETA::samples($run_saved)};
        if (!PGAutomation::write_json_atomic($timing_cache,$timings,0600)) {
            # An older index must not hide this checkpoint on the next run.
            unlink $timing_cache;
            _log('Unable to save optional calibration timing history; using manifest fallback');
        } else {
            _log('Unable to remove previous optional calibration timing history: '.$!)
                if -e $timing_previous && !unlink($timing_previous);
        }
    } elsif ($timing_staged && $timing_manifest) {
        my @before = stat($timing_manifest);
        my @after = stat($RUN_FILE);
        # A failed directory sync can report failure after the new checkpoint
        # became visible. Never put its predecessor's cache back in that case.
        if (@before && @after && $before[0] == $after[0] && $before[1] == $after[1]) {
            _log('Unable to restore previous optional calibration timing history: '.$!)
                if !rename($timing_previous, $timing_cache);
        }
    }
    close($timing_manifest) if $timing_manifest;
    my $artifacts_saved = _copy_worker_files($item_number, 'grey', undef)
        && _copy_worker_files($item_number, '3d', undef)
        && _copy_worker_files($item_number, 'dv', undef);
    if (!$item_saved || !$run_saved || !$artifacts_saved) {
        $::LAST_ERROR = 'Unable to persist automation checkpoint evidence';
        _log($::LAST_ERROR);
        return undef;
    }
    _log('Job '.($item_number+1).' | Saved checkpoint: '.$name.' ('.$status.')');
    return $record;
}

sub _checkpoint_exists {
    my ($item, $name) = @_;
    return 0 if ref($item->{checkpoints}) ne 'ARRAY';
    foreach my $record (@{$item->{checkpoints}}) {
        return 1 if ref($record) eq 'HASH' && ($record->{name} || '') eq $name
            && ($record->{status} || '') eq 'done';
    }
    return 0;
}

sub _last_checkpoint {
    my ($item) = @_;
    return undef if ref($item->{checkpoints}) ne 'ARRAY' || !@{$item->{checkpoints}};
    my @records = grep { ($_->{status} || '') ne 'skipped' } @{$item->{checkpoints}};
    return $records[-1];
}

sub _skip_stage {
    my ($item_number, $item, $name) = @_;
    return if grep { ($_->{name} || '') eq $name && ($_->{status} || '') eq 'skipped' } @{$item->{checkpoints} || []};
    die($::LAST_ERROR || "Unable to persist skipped checkpoint $name")
        if !ref(_checkpoint_record($item_number, $item, $name, 'unverifiable', { skipped => JSON::PP::true }, 'skipped'));
}

sub _stage_label {
    my ($name) = @_;
    return {
        'item-started'=>'Job readiness', 'tv-setup-verified'=>'TV setup',
        'pre-readings-done'=>'Before measurements', 'reset-and-reapply-verified'=>'Calibration reset and settings reapply',
        'panel-light-settled'=>'Panel brightness setup', 'greyscale-done'=>'1D LUT calibration',
        'greyscale-settings-verified'=>'Post-1D TV settings check', 'volume-done'=>'Color calibration',
        'volume-settings-verified'=>'Post-color TV settings check', 'session-closed'=>'Calibration-mode exit',
        'apply-all-done'=>'Apply to All Inputs', 'post-readings-done'=>'After measurements',
    }->{$name || ''} || $name || '';
}

sub _stage {
    my ($number,$item,$name,$callback)=@_;
    local $PGCalibrationLog::CONTEXT=PGCalibrationLog::child_context({run=>$RUN_ID,job=>$number+1,stage=>$name});
    if (_checkpoint_exists($item,$name)) {
        PGCalibrationLog::event('Runner','stage-skipped',{reason=>'saved checkpoint',stage=>$name});
        return 1;
    }
    my $started=PGCalibrationLog::monotonic();
    PGCalibrationLog::event('Runner','stage-start',{stage=>$name});
    my $ok=eval {_stage_impl(@_)}; my $error=$@;
    my $ms=PGCalibrationLog::elapsed_ms($started);
    PGCalibrationLog::event('Runner','stage-end',{elapsed_ms=>$ms,status=>$ok?'complete':$STOP_REQUESTED?'stopped':'failed',
        ($error || !$ok ? (reason=>$error||$::LAST_ERROR||'stage did not complete') : ())});
    _log('Job '.($number+1).' | '._stage_label($name).' complete | '.sprintf('%.1f s',$ms/1000)) if $ok;
    die $error if $error;
    return $ok;
}

sub _stage_impl {
    my ($item_number, $item, $name, $callback) = @_;
    return 1 if _checkpoint_exists($item, $name);
    _refresh_control();
    return 0 if $STOP_REQUESTED;
    $::LAST_ERROR = '';
    $::LAST_ERROR_CODE = '';
    $::LAST_ERROR_DETAIL = undef;
    $ACTIVE_STAGE = $name;
    $item->{active_stage} = $name;
    $item->{stage_started_at} = time();
    _log('Job '.($item_number+1).' | '._stage_label($name).' started');
    _update_item_snapshot($item_number, $item);
    _update_run(sub {
        my ($run) = @_;
        $run->{active_item} = $item_number;
        $run->{active_stage} = $name;
        $run->{stage_started_at} = $item->{stage_started_at};
        $run->{worker_status} = {};
        delete $run->{operation_progress};
        $run->{items}[$item_number] = $item if ref($run->{items}) eq 'ARRAY';
    });
    my $ok = eval { $callback->(); };
    # Capture the exception now: _refresh_control() decodes JSON inside its
    # own eval, which resets $@ before the failure path below reads it.
    my $exception = $@;
    my $one_line = sub {
        my ($text) = @_;
        return '' if !defined($text);
        $text =~ s/\s+$//;
        # One line: runner.log timestamps lines and the UI splits on newlines.
        $text =~ s/\s*[\r\n]+\s*/ | /g;
        return $text;
    };
    my $raw_exception = '';
    if (defined($exception)) {
        # The raw text is kept in the failure record and runner.log to locate
        # real crashes; the operator sees the reason without the location.
        ($exception,$raw_exception) = _clean_exception($exception);
    }
    $ok = 0 if !$ok || $exception;
    _refresh_control();
    if ($STOP_REQUESTED) {
        _log("stage $name interrupted by stop request for item $item_number");
        return 0;
    }
    if (!$ok) {
        # The exception is what actually stopped the stage. A $::LAST_ERROR
        # recorded earlier in the stage may be stale (an inner operation that
        # recovered), so it is kept as context but never replaces the cause.
        my $last_error = $one_line->($::LAST_ERROR);
        my $message = $exception
            ? ($last_error ne '' && index($exception, $last_error) < 0 ? "$exception (last recorded error: $last_error)" : $exception)
            : ($last_error ne '' ? $last_error : "Stage $name failed");
        # Worker and daemon messages can be multi-line too; keep one log line.
        $message =~ s/\s*[\r\n]+\s*/ | /g;
        my $resumable = 1;
        $item->{status} = $resumable ? 'interrupted' : 'failed';
        $item->{failure} = { stage => $name, message => "$message", at => time() };
        $item->{failure}{raw_exception} = $raw_exception if $raw_exception ne '' && $raw_exception ne $exception;
        $item->{failure}{error_code} = $::LAST_ERROR_CODE if $::LAST_ERROR_CODE;
        $item->{failure}{detail} = PGAutomation::clone($::LAST_ERROR_DETAIL) if ref($::LAST_ERROR_DETAIL) eq 'HASH';
        _update_item_snapshot($item_number, $item);
        _update_run(sub {
            my ($run) = @_;
            $run->{status} = $resumable ? 'interrupted' : 'failed';
            $run->{failure} = $item->{failure};
            $run->{items}[$item_number] = $item if ref($run->{items}) eq 'ARRAY';
        });
        _log("$name failed: $message".($raw_exception ne '' && $raw_exception ne $exception ? " [raw: $raw_exception]" : ''));
        return 0;
    }
    my $verified = ref($ok) eq 'HASH' ? ($ok->{verified} // 1) : 1;
    # This action is allowed to finish without a capability the TV does not
    # expose. Keep its evidence unverified, but do not turn that expected
    # limitation into a job warning. No other stage/read failure is exempt.
    my $informational_apply = $name eq 'apply-all-done' && ref($ok) eq 'HASH'
        && ($ok->{outcome} || '') eq 'sent-unconfirmed' && $ok->{confirmation_unavailable}
        && ($ok->{settings_verified} // '') eq '1';
    if (defined($verified) && $verified eq 'unverifiable' && !$informational_apply) {
        $item->{warnings} ||= [];
        push @{$item->{warnings}}, "$name-unverified"
            if !grep { !ref($_) && $_ eq "$name-unverified" } @{$item->{warnings}};
    }
    my $evidence = ref($ok) eq 'HASH' ? $ok : { result => $ok };
    my $checkpoint = _checkpoint_record($item_number, $item, $name, $verified, $evidence);
    if (!ref($checkpoint)) {
        my $message = $::LAST_ERROR || "Unable to persist checkpoint $name";
        $item->{status} = 'failed';
        $item->{failure} = { stage => $name, message => $message, at => time() };
        _update_item_snapshot($item_number, $item);
        _update_run(sub {
            my ($run) = @_;
            $run->{status} = 'failed';
            $run->{failure} = $item->{failure};
            $run->{items}[$item_number] = $item if ref($run->{items}) eq 'ARRAY';
        });
        _log("$name checkpoint failed: $message");
        return 0;
    }
    $ACTIVE_STAGE = '';
    _clear_active_worker();
    _refresh_control();
    return 1;
}

sub _pause_after_checkpoint {
    _refresh_control();
    return 0 if !$PAUSE_REQUESTED || $STOP_REQUESTED;
    die 'Unable to journal safe pause; ownership retained' if !ref(_update_run(sub {
        $_[0]{pause_park_pending} = JSON::PP::true;
    }));
    _stop_active(1);
    _restore_run_hazards(_run(), _run()->{items});
    _finish('paused');
    _log('Pause parked devices safely; committed checkpoints retained');
    return 1;
}

sub _park_interrupted {
    my ($stage) = @_;
    # Explicit Pause retains its viewing-restoration contract. A failed job
    # keeps the current mode and owes only worker, meter and panel cleanup.
    my $before = _run();
    my $parking = $before->{pause_park_pending} && ($before->{pending_terminal_status}||'') eq 'paused';
    $before = _keep_current_mode_on_stop('failure') if !$parking;
    my $cleanup = ref($before) eq 'HASH' ? $before->{stop_cleanup} : undef;
    if (ref($before) eq 'HASH' && $before->{viewing_restore_required}
            && !(ref($cleanup) eq 'HASH' && !$cleanup->{verified})) {
        _restore_preflight_context('viewing')
            or _log_action('Original viewing context restoration still pending: '.($::LAST_ERROR||'unconfirmed'));
    }
    my $saved = _update_run(sub {
        my ($run) = @_;
        $run->{status} = 'interrupted';
        # _finish latches cleanup for failures that are not restoration
        # problems (for example the meter release after a failed Pause) and
        # records them in cleanup_failure; those latches stay until a retry.
        if (@{PGAutomation::restoration_problems($run)} || $run->{cleanup_failure}) {
            $run->{cleanup_required} = JSON::PP::true;
        } else {
            delete $run->{cleanup_required};
        }
        # Resume must recreate the temporary calibration/protection state.
        $run->{pause_context_released} = JSON::PP::true;
        $run->{runner_pid} = 0;
        $run->{active_stage} = $stage if defined($stage) && $stage ne '';
        $run->{updated_at} = time();
    });
    die 'Unable to persist interrupted state; ownership retained' if !ref($saved);
    if ($saved->{cleanup_required}) {
        die 'Unable to retain cleanup ownership' if !_write_execution($saved);
    } else {
        _release_execution();
    }
    unlink($RUN_DIR . '/runner.pid');
    $ACTIVE_STAGE = '';
    _clear_active_worker();
    _log('runner parked an interrupted run for resume');
}

sub _current_mode_stop_requested {
    _refresh_control();
    return 0 if !$STOP_REQUESTED;
    my $run=_run();
    # Retry cleanup for a failed Pause still preserves that Pause's intent.
    return !($run->{pause_park_pending} && ($run->{pending_terminal_status}||'') eq 'paused');
}

sub _keep_current_mode_on_stop {
    my ($reason)=@_;
    $reason ||= 'stop';
    my $run=_run();
    return $run if ($run->{stop_restore_policy}||'') eq 'current-mode-only'
        && !$run->{preflight_restore_required} && !$run->{viewing_restore_required};
    my $saved=_update_run(sub {
        my ($state)=@_;
        $state->{stop_restore_policy}='current-mode-only';
        for my $kind (qw(preflight viewing)) {
            next if !$state->{$kind.'_restore_required'};
            $state->{$kind.'_restore_required'}=JSON::PP::false;
            $state->{$kind.'_restore_outcome'}='skipped-on-'.$reason;
        }
        # Stop and failure owe CAL_END and panel protection, not the batch's
        # saved picture preferences or a tour of checked signals.
        $state->{hazard_restore_outcome}='skipped-on-'.$reason;
        $state->{skipped_hazard_restore_failures}=$state->{hazard_restore_failures}
            if @{$state->{hazard_restore_failures}||[]};
        $state->{hazard_restore_failures}=[];
        $state->{hazard_restore_pending}=JSON::PP::false;
    });
    die 'Unable to persist cleanup policy; ownership retained' if !ref($saved);
    _log_action(($reason eq 'stop' ? 'Stop' : 'Failure cleanup').' | Keeping current signal and picture mode; skipping original settings restoration');
    return $saved;
}

sub _stop_progress {
    my ($message)=@_;
    my $saved=eval {_update_run(sub {
        $_[0]{worker_status}={message=>$message};
    })};
    _log('Stop progress could not be saved; continuing required cleanup') if !ref($saved);
    _log_action($message);
}

sub _stop_active {
    my ($parking) = @_;
    return if $STOP_HANDLED++;
    $STOPPING = 1;
    $LG_CLEANUP_UNREACHABLE = 0;
    $CLEANUP_DEADLINE = time() + $CLEANUP_RETRY_BUDGET;
    _keep_current_mode_on_stop(_current_mode_stop_requested() ? 'stop' : 'failure') if !$parking;
    # Journal an unfinished cleanup before issuing device commands. A process
    # interruption or a failed result write must not expose an older successful
    # cleanup as proof that this attempt safely released the TV and meter.
    my $pending = _update_run(sub {
        $_[0]{status}='stopping';
        $_[0]{stop_cleanup}={verified=>JSON::PP::false,completed_at=>time(),
            message=>'Cleanup started but fresh worker, meter and TV exit verification is still required'};
        $_[0]{worker_status}={message=>'Stopping all workers and closing TV calibration mode'};
    });
    die 'Unable to persist pending cleanup; ownership retained' if !ref($pending);
    _stop_progress('Stop 1/4 | Stopping measurement and calibration workers');
    my %paths = (
        series=>'/api/meter/series', grey=>'/api/meter/lg-autocal',
        '3d'=>'/api/meter/lg-3d-autocal', dv=>'/api/lg/dv-profile',
    );
    # The stage pointer can be empty/stale during startup and handoffs.
    # Signal every worker first; never rely on that pointer for safety.
    foreach my $worker (sort keys %paths) {
        _api('POST',$paths{$worker}.'/stop',{automation_graceful=>JSON::PP::true},1,_cleanup_window());
    }
    my $deadline=time()+5;
    while (time()<$deadline && grep { _worker_process_alive($_) } keys %paths) {
        select(undef,undef,undef,0.25);
    }
    foreach my $worker (sort keys %paths) {
        next if !_worker_process_alive($worker);
        _log_action("Force stopping $worker worker after cancellation grace period");
        _api('POST',$paths{$worker}.'/kill',{automation_force=>JSON::PP::true},1,_cleanup_window());
    }
    my @alive=grep { _worker_process_alive($_) } sort keys %paths;
    if ($ACTIVE_WORKER eq 'series' && $ACTIVE_ITEM && $ACTIVE_SERIES_KEY && $ACTIVE_SERIES_PHASE) {
        my $partial = PGAutomation::read_json_file('/tmp/meter_series.json');
        _snapshot_series($ACTIVE_ITEM->{item_number} || 0, $ACTIVE_SERIES_PHASE, $ACTIVE_SERIES_KEY, $partial)
            if ref($partial) eq 'HASH';
    }
    _stop_progress('Stop 2/4 | Releasing meter');
    my $meter_session=_api('POST','/api/meter/session/stop',{},1,_cleanup_window());
    my $item=ref($ACTIVE_ITEM) eq 'HASH' ? $ACTIVE_ITEM : {};
    _stop_progress('Stop 3/4 | Exiting calibration mode on the current picture mode');
    # Reconnect using the saved pairing when needed; never initiate pairing.
    _ensure_lg_connection();
    # CAL_END is the call that releases the TV: it keeps its own idempotent
    # window even after the worker stops have spent the shared budget.
    my $off=_api('POST','/api/lg/calibration-mode',{
        enabled=>JSON::PP::false,
        current_picture_mode=>JSON::PP::true,
        picture_mode=>_picture_mode($item),signal_mode=>_signal($item),
    },1,_cleanup_window() || $CLEANUP_RETRY_WINDOW);
    my $saved=_run();
    my $end=$parking ? {} : _api('POST','/api/lg/autocal/run/end',{
        status=>'aborted',note=>'Automation stopped',
        current_picture_mode=>JSON::PP::true,
        run_id=>$saved->{lg_run_id}||'',client_run_token=>$TOKEN,
    },1,_cleanup_window());
    my $status=_api('GET','/api/lg/status',undef,1,_cleanup_window());
    my $exit_ack=_response_ok($off) || (_response_ok($end) && exists($end->{calibration_mode}) && !$end->{calibration_mode} && !$end->{stale_run_ignored});
    my $closed=$exit_ack && _response_ok($status)
        && !$status->{disconnected} && exists($status->{calibration_mode}) && !$status->{calibration_mode};
    my @problems;
    push @problems,'Workers still alive: '.join(', ',@alive) if @alive;
    push @problems,'Meter release failed: '.($meter_session->{message}||'no acknowledgement') if !_response_ok($meter_session);
    push @problems,'TV calibration exit unconfirmed: '.($off->{message}||$status->{message}||'TV did not acknowledge CAL_END') if !$closed;
    my $cleanup={verified=>@problems?JSON::PP::false:JSON::PP::true,completed_at=>time(),
        calibration_mode=>$off,run_end=>{map {exists($end->{$_})?($_=>$end->{$_}):()} qw(status error_code message calibration_mode stale_run_ignored)},tv_status=>$status,workers_alive=>\@alive,
        message=>@problems?join('; ',@problems):'All workers stopped; meter released; TV acknowledged calibration exit'};
    my $verified_cleanup = _update_run(sub {
        $_[0]{stop_cleanup}=$cleanup;
        $_[0]{worker_status}={message=>($cleanup->{verified}?'Cleanup complete: ':'Cleanup failed: ').$cleanup->{message}};
    });
    die 'Unable to persist cleanup verification; ownership retained' if !ref($verified_cleanup);
    _log_action(($cleanup->{verified}?'Worker, meter and calibration cleanup complete: ':'Stop cleanup FAILED: ').$cleanup->{message});
    if (!$parking && ref($ACTIVE_ITEM) eq 'HASH') {
        my $number=$item->{item_number}||0;
        my $preserve_failure=ref($item->{failure}) eq 'HASH' && !$STOP_REQUESTED;
        my $interrupted_stage=$ACTIVE_STAGE||$item->{active_stage}||'unknown';
        _write_artifact(PGAutomation::item_dir($RUN_ID,$number).'/calibration/stop-cleanup.json',$cleanup);
        push @{$item->{warnings}},$cleanup->{message} if !$cleanup->{verified};
        # A Stop during final cleanup must not rewrite a completed result.
        if (!$preserve_failure && ($item->{status}||'') !~ /^complete/) {
            $item->{status}='stopped';
            $item->{failure}={stage=>$interrupted_stage,status=>'interrupted',at=>time()};
            _checkpoint_record($number,$item,$interrupted_stage,JSON::PP::false,{interrupted=>JSON::PP::true},'interrupted')
                if $interrupted_stage ne 'unknown';
        }
        _update_item_snapshot($number,$item);
    }
    if (_run()->{preflight_restore_required} && !_restore_preflight_context()) {
        _log_action('Preflight restoration still requires cleanup: '.($::LAST_ERROR||'unconfirmed'));
    }
    # End on the idle frame (black, or stabilisation when a meter is set up for
    # it) so the idle information card can take over once the delay passes.
    my $visible=_api('POST','/api/pattern',{name=>'stop'},1,_cleanup_window());
    _log_action('Stop idle pattern: '.($visible->{status}||'unavailable'));
    $STOPPING = 0;
}

sub _finish {
    my ($status, $failure) = @_;
    if ($status eq 'failed') {
        _keep_current_mode_on_stop('failure');
        _stop_active() if !$STOP_HANDLED;
        _restore_run_hazards(_run(),_run()->{items});
    }
    if (_current_mode_stop_requested() && !$STOP_HANDLED) {
        _stop_active();
        _restore_run_hazards(_run(),_run()->{items});
        $status='stopped';
    }
    _keep_current_mode_on_stop() if $status eq 'stopped';
    my $meter = _api('POST', '/api/meter/session/stop', {}, 1, _cleanup_window());
    my $run = _run();
    my $cleanup = $run->{stop_cleanup};
    # Do not switch signal while CAL_END is still unconfirmed. Keep the saved
    # viewing context for the next cleanup attempt instead.
    if ($run->{viewing_restore_required} && !(ref($cleanup) eq 'HASH' && !$cleanup->{verified})) {
        _restore_preflight_context('viewing');
        $run = _run();
    }
    # Stop can interrupt a normal finish while it is restoring modes. Run
    # the same safety cleanup instead of reporting normal completion.
    if (_current_mode_stop_requested()) {
        _keep_current_mode_on_stop();
        if (!$STOP_HANDLED) {
            return _finish('stopped',$failure);
        }
        $status='stopped';
        $run=_run();
    }
    my @problems = @{PGAutomation::restoration_problems($run)};
    push @problems, 'Meter release failed: '.(ref($meter) eq 'HASH' ? ($meter->{message}||'no acknowledgement') : 'no acknowledgement')
        if !_response_ok($meter);
    if (@problems) {
        my $message = join('; ', @problems);
        my $saved = _update_run(sub {
            my ($state) = @_;
            $state->{original_failure} ||= $failure || $state->{failure};
            $state->{pending_terminal_status} ||= $status;
            $state->{status} = 'interrupted';
            $state->{cleanup_required} = JSON::PP::true;
            $state->{preflight_in_progress} = JSON::PP::false;
            $state->{runner_pid} = 0;
            $state->{active_stage} = 'stop-cleanup';
            delete $state->{completed_at};
            $state->{failure} = {stage=>'stop-cleanup', error_code=>'stop-cleanup-unverified', message=>$message, at=>time()};
            $state->{cleanup_failure} = {completed_at=>time(), message=>$message};
            $state->{worker_status} = {message=>'Cleanup required: '.$message.'. Use Retry cleanup.'};
        });
        die 'Unable to persist required cleanup; ownership retained' if !ref($saved);
        die 'Unable to retain cleanup ownership' if !_write_execution();
        unlink($RUN_DIR . '/runner.pid');
        _log('Cleanup remains required; retaining automation ownership: '.$message);
        return 0;
    }
    # Restoration that had to be abandoned or cannot be read back is a
    # warning the operator must see, not a clean completion.
    $status = 'complete-with-warnings'
        if $status eq 'complete' && ((grep { ($run->{$_.'_restore_outcome'}||'') eq 'abandoned-tv-changed' } qw(viewing preflight))
            || @{$run->{hazard_restore_unverified}||[]});
    my $saved = _update_run(sub {
        my ($state) = @_;
        $state->{status} = $status;
        $state->{completed_at} = time() if $status =~ /^(?:complete(?:-with-warnings)?|failed|stopped)$/;
        $state->{runner_pid} = 0;
        $state->{active_stage} = '';
        if ($status eq 'stopped') {
            my $panel=$state->{panel_protection}||{};
            $state->{worker_status}={message=>'Stopped | Calibration mode off; meter released'
                .(($panel->{restore_outcome}||'') eq 'sent-unverified' ? '; TPC/GSR re-enable sent (no readback)' : '')};
        }
        $state->{failure} = $failure if ref($failure) eq 'HASH';
        delete $state->{failure} if ($status eq 'stopped' || $status eq 'paused') && $state->{cleanup_required};
        $state->{preflight_in_progress} = JSON::PP::false;
        delete $state->{cleanup_required};
        delete $state->{pending_terminal_status};
        delete $state->{cleanup_failure};
        if ($status eq 'paused') {
            $state->{paused_at} = time();
            $state->{pause_context_released} = JSON::PP::true;
            delete $state->{pause_park_pending};
        }
    });
    die 'Unable to persist terminal state; ownership retained' if !ref($saved);
    unlink($RUN_DIR . '/runner.pid');
    return _write_execution($saved) if $status eq 'paused';
    return _release_execution();
}

sub _restore_hazards {
    my ($item, $unverified) = @_;
    my $restore = ref($item->{hazard_restore}) eq 'HASH' ? $item->{hazard_restore} : {};
    my @failed;
    foreach my $key (keys %$restore) {
        last if _current_mode_stop_requested();
        my $record = $restore->{$key};
        next if $key eq 'energySaving' || $key eq 'aiPicture';
        my ($value,$category);
        if (ref($record) eq 'HASH') {
            $value = $record->{value};
            $category = $record->{category} || 'picture';
        } else {
            $value = $record;
            $category = _setting_category($item, $key);
        }
        next if !defined($value);
        my $result = _api('POST', '/api/lg/picture-settings/set', {
            settings => { $key => $value }, category => $category,
            picture_mode => _picture_mode($item), signal_mode => _signal($item),
        }, 1, 0);
        if (_response_ok($result) && ($result->{verification_state} || '') eq 'acknowledged_unverified'
                && lg_setting_write_accepted($result, $key, $value)) {
            # The TV accepted the write but offers no readback for this
            # control. Retrying can never verify it, so it must not hold the
            # TV; record it for the operator instead (like panel protection).
            _log("Hazard restoration for $key was accepted but cannot be read back");
            push @$unverified, { key => $key, value => $value } if ref($unverified) eq 'ARRAY';
            next;
        }
        if (!_response_ok($result) || ($result->{verification_state} || '') ne 'verified') {
            my $message = (ref($result) eq 'HASH' && $result->{message}) || 'restoration was not verified';
            _log("Hazard restoration failed for $key: $message");
            push @failed, { key => $key, value => $value, message => $message };
        }
    }
    return \@failed;
}

sub _restore_run_hazards {
    my ($run, $items) = @_;
    # Callers may hold the manifest from before _stop_active journalled policy.
    my $latest = _run();
    $run = $latest if ($latest->{stop_restore_policy}||'') eq 'current-mode-only';
    $run=_keep_current_mode_on_stop() if _current_mode_stop_requested();
    my %restore;
    if (ref($run) eq 'HASH' && ref($run->{hazard_restore}) eq 'HASH') {
        %restore = %{$run->{hazard_restore}};
    }
    if (!%restore) {
        foreach my $item (@{$items || []}) {
            next if ref($item) ne 'HASH';
            foreach my $key (keys %{$item->{hazard_restore} || {}}) {
                $restore{$key} = $item->{hazard_restore}{$key}
                    if !exists($restore{$key});
            }
        }
    }
    my $context = ref($ACTIVE_ITEM) eq 'HASH' ? $ACTIVE_ITEM
        : (ref($items) eq 'ARRAY' && ref($items->[0]) eq 'HASH' ? $items->[0] : {});
    my @unverified;
    my $current_only=($run->{stop_restore_policy}||'') eq 'current-mode-only';
    my $failed = %restore && !$current_only ? _restore_hazards({ %$context, hazard_restore => \%restore }, \@unverified) : [];
    _stop_progress('Stop 4/4 | Restoring TPC/GSR') if $current_only;
    my $panel_failure = _restore_panel_protection($run);
    push @$failed, $panel_failure if $panel_failure;
    # A TV left with its power-off, screen-saver or panel protection disabled
    # must be visible in history, not only in runner.log.
    die 'Unable to persist protection restoration; ownership retained' if !ref(_update_run(sub {
        $_[0]{hazard_restore_failures} = $failed;
        $_[0]{hazard_restore_pending} = @$failed ? JSON::PP::true : JSON::PP::false;
        my %still=map {($_->{key}=>1)} @unverified;
        # A later pass that verified a key retires its earlier warning.
        $_[0]{warnings}=[grep { ref($_) || !/^(\S+) was restored to .*, but this TV cannot read the setting back\. Confirm it in the TV menu\.$/ || $still{$1} } @{$_[0]{warnings}}]
            if ref($_[0]{warnings}) eq 'ARRAY';
        $_[0]{hazard_restore_unverified} = \@unverified;
        _add_run_warning($_[0], "$_->{key} was restored to $_->{value}, but this TV cannot read the setting back. Confirm it in the TV menu.")
            for @unverified;
    }));
    return $failed;
}

sub _drop_resume_checkpoints {
    my ($item, $names) = @_;
    # A calibration that restarts from its reset owes no baseline restore
    # and starts the restore-failure count afresh.
    delete $item->{profile_baseline_restore_failures} if $names->{'reset-and-reapply-verified'};
    # A boundary proof belongs to the calibration immediately before it.
    $names->{'greyscale-settings-verified'} = 1 if $names->{'greyscale-done'};
    $names->{'volume-settings-verified'} = 1 if $names->{'volume-done'};
    $item->{checkpoints} = [grep {
        ref($_) eq 'HASH' && !$names->{$_->{name} || ''}
    } @{$item->{checkpoints} || []}];
}

sub _resume_series_artifacts_ok {
    my ($item_number, $item, $which) = @_;
    foreach my $key (_series_selection($item, $which)) {
        my $path = PGAutomation::item_dir($RUN_ID, $item_number) . "/$which/$key.json";
        my $snapshot = PGAutomation::read_json_file($path);
        return 0 if ref($snapshot) ne 'HASH' || ($snapshot->{status} || '') ne 'complete';
    }
    return 1;
}

sub _resume_calibration_artifacts_ok {
    my ($item_number, $item, $kind) = @_;
    my $dir = PGAutomation::item_dir($RUN_ID, $item_number) . '/calibration';
    if ($kind eq 'grey') {
        my $state = PGAutomation::read_json_file($dir . '/grey-state.json');
        return ref($state) eq 'HASH' && ($state->{status} || '') eq 'complete'
            && ($state->{ddc_upload_verified} || $state->{final_1d_lut_upload_verified});
    }
    if (_signal($item) eq 'dv') {
        my $state = PGAutomation::read_json_file($dir . '/dv-profile-state.json');
        my $upload = PGAutomation::read_json_file($dir . '/dv-profile-upload.json');
        return ref($state) eq 'HASH' && ($state->{status} || '') eq 'complete'
            && ref($upload) eq 'HASH' && ($upload->{status} || '') eq 'ok';
    }
    my $state = PGAutomation::read_json_file($dir . '/3d-state.json');
    return 0 if ref($state) ne 'HASH' || ($state->{status} || '') ne 'complete';
    my $export = ref($state->{export}) eq 'HASH' ? $state->{export} : {};
    my @files;
    foreach my $source (map { $export->{$_} || '' } qw(cube_path payload_path)) {
        next if $source !~ m{/([A-Za-z0-9_.-]+)$};
        push @files, $dir . '/' . $1;
    }
    my $files_exist = @files >= 2 && !grep { !-f $_ } @files;
    return ($state->{terminal_commit_verified} || $state->{upload_verified}) && $files_exist;
}

sub _gamut_warning_only_recovery {
    my ($number, $item) = @_;
    return 0 if ($item->{settings_recovery}{point} || '') ne 'c6'
        || ($item->{settings_recovery}{resume_from} || '') ne 'greyscale-done'
        || !_checkpoint_exists($item, 'greyscale-done')
        || !_resume_calibration_artifacts_ok($number, $item, 'grey');
    my $path = PGAutomation::item_dir($RUN_ID, $number).'/settings-checks.ndjson';
    open(my $fh, '<', $path) or return 0;
    my %checks;
    while (my $line = <$fh>) {
        my $c = PGAutomation::decode_json($line);
        if (ref($c) ne 'HASH') { close($fh); return 0; }
        my $point = $c->{checkpoint} || '';
        next if $point !~ /^c6(?:-confirm|-repair|-stable)?$/;
        if (($c->{operation} || '') eq 'write') {
            if ($c->{key} ne 'colorGamut' || ($c->{result} || '') ne 'applied') { close($fh); return 0; }
            next;
        }
        $checks{$point}{$c->{key}} = $c;
    }
    close($fh);
    my %expected = (%{_item_settings($item)}, pictureMode=>_picture_mode($item));
    for my $point (qw(c6 c6-confirm)) {
        my $warning = 0;
        for my $key (keys %expected) {
            my $c = $checks{$point}{$key} || return 0;
            return 0 if !_value_agrees($expected{$key}, $c->{expected}, $key);
            next if $c->{verified};
            return 0 if ($c->{result} || '') ne 'mismatch' || ($c->{error_code} || '') ne ''
                || !_lg_gamut_readback_warning($key, $c->{expected}, $c->{observed});
            $warning = 1;
        }
        return 0 if !$warning;
    }
    return 1;
}

sub _prepare_resume {
    my ($item_number, $item, $context_ready) = @_;
    die($::LAST_ERROR || 'Unable to restore the queued signal format') if !$context_ready && !_apply_signal($item);
    # Only this resume's decision arms the baseline restore; a flag left by an
    # earlier attempt that then failed at job readiness must not stall every
    # later resume on the same missing curve.
    delete $item->{profile_baseline_needs_restore};
    # A resume that reacquired a released TV claim cannot trust any committed
    # checkpoint: another run may have recalibrated this TV while the job was
    # interrupted, so the installed LUT is no longer proof of this job's result.
    # Recalibrate from reset rather than keep results and skip to Apply to All.
    if ($item->{resume_recalibrate}) {
        delete $item->{resume_recalibrate};
        _log_action('The TV was released to another run since this job was interrupted; recalibrating from reset because the installed calibration can no longer be trusted');
        _drop_resume_checkpoints($item, { map { $_ => 1 } qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete) });
        delete $item->{settings_recovery};
        delete $item->{drift_recovery_pending};
        return;
    }
    if ($item->{profile_baseline_restore_failed}) {
        delete $item->{profile_baseline_restore_failed};
        delete $item->{profile_baseline_restore_failures};
        _log_action('The 1D baseline could not be restored on the previous resumes; the calibration restarts from its reset');
        _drop_resume_checkpoints($item, { map { $_ => 1 } qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete) });
        delete $item->{settings_recovery};
        delete $item->{drift_recovery_pending};
        return;
    }
    my $last = _last_checkpoint($item);
    return if !ref($last);
    if (ref($item->{settings_recovery}) eq 'HASH') {
        my $from = $item->{settings_recovery}{resume_from} || '';
        if (_gamut_warning_only_recovery($item_number, $item)) {
            $from = 'greyscale-settings-verified';
            _log_action('Resuming Auto requested / Wide reported pause: retaining the verified 1D upload and rechecking the expected LG calibration state before profiling');
        }
        my @order = qw(reset-and-reapply-verified panel-light-settled greyscale-done greyscale-settings-verified volume-done volume-settings-verified session-closed apply-all-done post-readings-done item-complete);
        my %allowed = map { $_=>1 } qw(greyscale-done greyscale-settings-verified volume-done volume-settings-verified session-closed);
        die 'Invalid saved settings recovery plan; review this job before starting again' if !$allowed{$from};
        # A saved plan cannot stand in for the actual committed result files.
        if ($from ne 'greyscale-done' && !_resume_calibration_artifacts_ok($item_number, $item, 'grey')) {
            $from = 'greyscale-done';
        } elsif ($from =~ /^(?:volume-settings-verified|session-closed)$/
            && !_resume_calibration_artifacts_ok($item_number, $item, 'volume')) {
            $from = 'volume-done';
        }
        # Reusing the 1D result means restoring its curve before profiling.
        if ($from =~ /^(?:greyscale-settings-verified|volume-done)$/ && !_profile_baseline_data_ok($item_number, $item)) {
            _log_action('The saved 1D curve is missing, so the calibration restarts from its reset instead of resuming at '._stage_label($from));
            $from = 'greyscale-done';
        }
        # Recheck before reusing a completed 1D stage, even if its prior menu
        # proof survived the interruption. A reboot/cleanup can change settings.
        my $drop = $from eq 'greyscale-done' ? 'reset-and-reapply-verified' : $from;
        my %names; my $started = 0;
        for my $name (@order) { $started = 1 if $name eq $drop; $names{$name}=1 if $started; }
        $names{'greyscale-settings-verified'}=1 if $from eq 'volume-done';
        _drop_resume_checkpoints($item, \%names);
        $item->{profile_baseline_needs_restore}=1 if _signal($item) ne 'dv'
            && $from =~ /^(?:volume-done|greyscale-settings-verified)$/;
        _log_action('Resuming saved settings review at '.$from.'; earlier valid results are retained');
        delete $item->{settings_recovery};
        delete $item->{drift_recovery_pending};
        return;
    }
    my $failure_stage = ref($item->{failure}) eq 'HASH' ? ($item->{failure}{stage} || '') : '';
    # A failure in the profile stage (volume-done) or while closing the
    # session leaves a committed, verified 1D result on disk. Keep it:
    # recheck its settings, restore the unity 3D baseline and retry from the
    # profile stage, the path a saved settings-recovery resume already takes.
    # The 18 Sep 2026 batch repeated a 95-minute greyscale after a restore
    # write timed out in the 3D stage. An earlier failure, a drift recovery
    # or a job whose 1D artifacts do not verify still resets.
    if (!$item->{drift_recovery_pending} && $failure_stage =~ /^(?:volume-done|session-closed)$/
        && _checkpoint_exists($item, 'greyscale-done')
        && _resume_calibration_artifacts_ok($item_number, $item, 'grey')) {
        my $label = _stage_label($failure_stage);
        if (_dv_upload_unresolved($item_number, $item)) {
            _log_action('Resuming after a failure in '.$label.': a Dolby Vision profile upload was dispatched without an accepted result, so the calibration restarts from its reset');
        }
        # A session that failed to close after a verified profile keeps the
        # profile as well: only the exit and what follows are repeated.
        elsif ($failure_stage eq 'session-closed' && _checkpoint_exists($item, 'volume-done')
            && _resume_calibration_artifacts_ok($item_number, $item, 'volume')) {
            _drop_resume_checkpoints($item, { map { $_ => 1 } qw(session-closed apply-all-done post-readings-done item-complete) });
            _log_action('Resuming after a failure in '.$label.': retaining the verified 1D and profile results');
            return;
        }
        # The baseline restore re-uploads the saved 1D curve. Without it the
        # restore would fail at job readiness on every later resume, so a
        # result that lacks it takes the full reset instead.
        elsif (_profile_baseline_data_ok($item_number, $item)) {
            _drop_resume_checkpoints($item, { map { $_ => 1 } qw(greyscale-settings-verified volume-done session-closed apply-all-done post-readings-done item-complete) });
            $item->{profile_baseline_needs_restore}=1 if _signal($item) ne 'dv';
            _log_action('Resuming after a failure in '.$label.': retaining the verified 1D result; its settings are rechecked'
                .(_signal($item) ne 'dv' ? ' and the unity 3D baseline restored' : '').' before profiling');
            return;
        }
        else {
            _log_action('Resuming after a failure in '.$label.': the saved 1D curve is missing, so the calibration restarts from its reset');
        }
    }
    if ($item->{drift_recovery_pending} || $failure_stage =~ /^(?:reset-and-reapply-verified|panel-light-settled|greyscale-done|volume-done|session-closed)$/) {
        _drop_resume_checkpoints($item, { map { $_ => 1 } qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete) });
        return;
    }
    my $name = $last->{name} || '';
    if (($last->{status} || '') ne 'done') {
        if ($name eq 'apply-all-done') {
            _drop_resume_checkpoints($item, { 'apply-all-done' => 1 });
        } else {
            _drop_resume_checkpoints($item, { map { $_ => 1 } qw(
                reset-and-reapply-verified panel-light-settled greyscale-done
                volume-done session-closed apply-all-done post-readings-done item-complete
            ) });
        }
        return;
    }
    if ($name eq 'pre-readings-done' && !_resume_series_artifacts_ok($item_number, $item, 'pre')) {
        _drop_resume_checkpoints($item, { map { $_ => 1 } qw(pre-readings-done reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete) });
        return;
    }
    if ($name =~ /^(?:greyscale-done|greyscale-settings-verified)$/
        && (!_resume_calibration_artifacts_ok($item_number, $item, 'grey') || !_profile_baseline_data_ok($item_number, $item))) {
        _drop_resume_checkpoints($item, { map { $_ => 1 } qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete) });
        return;
    }
    # A successful 1D checkpoint may have been followed by pause cleanup or a
    # failed baseline restoration. Recreate the held unity/1D context on every
    # such resume, not only when consuming a settings-recovery plan.
    $item->{profile_baseline_needs_restore}=1 if _signal($item) ne 'dv'
        && $name =~ /^(?:greyscale-done|greyscale-settings-verified)$/;
    if ($name =~ /^(?:volume-done|volume-settings-verified)$/ && !_resume_calibration_artifacts_ok($item_number, $item, 'volume')) {
        _drop_resume_checkpoints($item, { map { $_ => 1 } qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete) });
        return;
    }
    # Re-enter the lightweight check, not the calibration, after pausing at a
    # successful settings checkpoint. Fresh c7 is also collected before exit.
    _drop_resume_checkpoints($item, {'greyscale-settings-verified'=>1}) if $name eq 'greyscale-settings-verified';
    if ($name eq 'panel-light-settled' && !-f(PGAutomation::item_dir($RUN_ID, $item_number) . '/panel-light.json')) {
        _drop_resume_checkpoints($item, { map { $_ => 1 } qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete) });
        return;
    }
    if ($name eq 'apply-all-done' && !-f(PGAutomation::item_dir($RUN_ID, $item_number) . '/apply-all.json')) {
        _drop_resume_checkpoints($item, { map { $_ => 1 } qw(apply-all-done post-readings-done item-complete) });
        return;
    }
    my %verification_point = (
        'tv-setup-verified' => 'resume-c1',
        'reset-and-reapply-verified' => 'resume-c4',
        'panel-light-settled' => 'resume-c5',
        'session-closed' => 'resume-c8',
        'apply-all-done' => 'resume-c9',
        'post-readings-done' => 'resume-c10',
    );
    if (exists($verification_point{$name})) {
        my $check = _read_and_verify_settings($item_number, $item, $verification_point{$name});
        if (!$check->{verified} && $check->{verified} ne 'unverifiable') {
            my %drop_from = (
                'tv-setup-verified' => [qw(tv-setup-verified warmup-done pre-readings-done reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete)],
                'reset-and-reapply-verified' => [qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete)],
                'panel-light-settled' => [qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete)],
                'session-closed' => [qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete)],
                'apply-all-done' => [qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete)],
                'post-readings-done' => [qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete)],
            );
            _drop_resume_checkpoints($item, { map { $_ => 1 } @{$drop_from{$name} || []} });
        }
    }
}

sub _save_job_readiness {
    my ($number,$item,$readiness)=@_;
    $item->{readiness}={ready=>$readiness->{ready}?1:0,checked_at=>time(),checks=>$readiness->{checks}||[],message=>$readiness->{message}||''};
    foreach my $check (@{$item->{readiness}{checks}}) {
        $check->{item_number}=$number;
        _log_action(($check->{level}||'info').': '.$check->{message}) if !$check->{ok};
    }
    _update_item_snapshot($number,$item);
    _update_run(sub {$_[0]{items}[$number]=$item;});
}

# Readiness runs its own TV conversations inside the daemon, so the runner's
# LG reconnect logic never sees a refusal that happens there. A readiness
# verdict is idempotent: reconnect and ask once more. A daemon-internal helper
# timeout ("LG TV did not answer ... within Ns") also earns one more check
# here, although elsewhere a timeout is no longer treated as a refusal.
sub _readiness_with_reconnect {
    my ($payload)=@_;
    my $result=_api('POST','/api/automation/readiness',$payload,0,0);
    my $errors=sub { [map {$_->{message}||$_->{name}} grep {ref($_) eq 'HASH' && !$_->{ok} && ($_->{level}||'error') eq 'error'} @{$_[0]{checks}||[]}] };
    my $retryable=sub { my ($m)=@_; return 1 if _lg_connection_failure({status=>'error',message=>$m}); return $m=~/LG TV did not (?:answer|finish)/i ? 1 : 0; };
    if (ref($result) eq 'HASH' && !$result->{ready} && grep { $retryable->($_) } @{$errors->($result)}) {
        _log_action('TV connection was refused during readiness checks; reconnecting and checking again');
        $result=_api('POST','/api/automation/readiness',$payload,0,0) if _ensure_lg_connection(1);
    }
    return $result;
}

# The power/screen-saver values a job must put back, derived from the hazards
# its queue-preflight readiness pass observed on the TV. Same rule as the
# readiness endpoint's own hazard_restore: controllable, with a value, and
# never the two picture-side hazards the recipe itself sets.
sub _item_hazard_restore {
    my ($item)=@_;
    my %restore;
    foreach my $hazard (@{ref($item->{hazards}) eq 'ARRAY' ? $item->{hazards} : []}) {
        next if ref($hazard) ne 'HASH' || !$hazard->{controllable} || !defined($hazard->{key}) || !defined($hazard->{value});
        next if $hazard->{key} eq 'energySaving' || $hazard->{key} eq 'aiPicture';
        $restore{$hazard->{key}}={value=>$hazard->{value},category=>$hazard->{category}||'picture'}
            if !exists($restore{$hazard->{key}});
    }
    return \%restore;
}

sub _freeze_job_lg_context {
    my ($item)=@_;
    # No-echo read: item context cleared and calibration mode ignored, so the
    # daemon reports the active mode rather than the queued selector. The
    # result doubles as the mode selector's pre-read.
    my $saved_item=$ACTIVE_ITEM;$ACTIVE_ITEM=undef;
    my $live=eval { _api('POST','/api/lg/picture-settings',{keys=>['pictureMode'],include_current_input=>JSON::PP::true,
        ignore_calibration_picture_mode=>JSON::PP::true,signal_mode=>_signal($item)}) };
    my $read_error=$@;$ACTIVE_ITEM=$saved_item;die $read_error if $read_error;
    my $profile=_slim_profile(ref($live->{generation_profile}) eq 'HASH' ? $live->{generation_profile} : {});
    my $input=$live->{current_input}||'';
    die 'Unable to confirm LG input and compatibility profile before selecting picture mode'
        if (($live->{status}||'') ne 'ok' || $input!~/^hdmi[1-4](?:_pc)?$/ || ($profile->{capability_profile_hash}||'')!~/^[0-9a-f]{64}$/);
    die 'No reviewed LG platform is available for calibration'
        if ($item->{stages}{calibration} && (!$profile->{capability_library_valid} || !$profile->{capability_platform_profile_applied}));
    my $contract=$item->{preflight_contract};
    die 'Queue preflight is stale: TV input or compatibility changed; recheck the whole pending queue'
        if ref($contract) eq 'HASH' && (($contract->{tv_input}||'') ne $input
            || ($contract->{profile_hash}||'') ne ($profile->{capability_profile_hash}||''));
    $item->{tv_input}=$input;
    $item->{generation_profile}=$profile;
    $item->{capability_profile}={id=>$profile->{capability_profile_id},hash=>$profile->{capability_profile_hash}};
    return _mode_read_from_response($live);
}

# Job start trusts the whole-queue check: every pending job's TV controls,
# meter, storage and calibration-mode state were verified before any
# calibration began, and the TV controls it found are on the item. What a job
# start must still do is put the generator and TV on this job's signal and
# mode; the one no-echo read that precedes the mode write is where a changed
# input or TV is caught (the frozen preflight contract).
sub _prepare_job_context {
    my ($number,$item)=@_;
    $ACTIVE_STAGE='job-readiness';
    _update_run(sub {
        $_[0]{active_item}=$number;$_[0]{active_stage}=$ACTIVE_STAGE;$_[0]{stage_started_at}=time();
        $_[0]{worker_status}={message=>'Selecting this job\'s signal and picture mode'};
    });
    _log_action('Preparing '.($item->{name}||'this job').'; its TV controls and meter were checked with the whole queue');
    # The batch owes the operator their original viewing context under either
    # finish policy: restore-original returns every signal, keep-last returns
    # only the signals the queue check changed and no job ever selected.
    if (-f $RUN_DIR.'/viewing-context.json') {
        die 'Unable to journal original viewing context restoration' if !ref(_update_run(sub {
            $_[0]{viewing_restore_required}=JSON::PP::true;
            # An outcome from an earlier Pause must not contradict the new obligation.
            delete @{$_[0]}{qw(viewing_restore_outcome viewing_context_restored_at viewing_restore_abandoned_at)};
        }));
    }
    die($::LAST_ERROR||'Unable to activate job signal') if !_apply_signal($item);
    my $frozen=_freeze_job_lg_context($item);
    die($::LAST_ERROR||'Unable to select job picture mode') if !_select_item_picture_mode($number,$item,'job-start',$frozen);
    die 'Queue preflight is stale: the resolved job settings or device identity changed; no calibration was started'
        if ref($item->{preflight_contract}) eq 'HASH'
            && !PGAutomationPlan::job_start_matches(PGAutomationPlan::intent_hash($item),$item,$item->{preflight_contract});
    # A limited contract was frozen before the job's mode existed. Once job start
    # has verified the plan, pin it so a claim after Pause or Resume matches
    # without a whole-queue re-check.
    $item->{preflight_contract}{intent_hash}=PGAutomationPlan::intent_hash($item)
        if ref($item->{preflight_contract}) eq 'HASH' && $item->{preflight_contract}{limited};
    # Global power/screen-saver restoration values come from the queue check,
    # which read every job before any job disabled them; keep the first seen.
    my $hazard_restore=_item_hazard_restore($item);
    die 'Unable to journal protective settings restoration' if !ref(_update_run(sub {
        my ($run)=@_;$run->{hazard_restore}||={};
        foreach my $key (keys %$hazard_restore) {
            $run->{hazard_restore}{$key}=$hazard_restore->{$key} if !exists($run->{hazard_restore}{$key});
        }
        $run->{hazard_restore_pending} = JSON::PP::true
            if grep {$_ ne 'energySaving' && $_ ne 'aiPicture'} keys %{$run->{hazard_restore}};
        $run->{items}[$number]=$item;
    }));
    _update_item_snapshot($number,$item);
    _log_action('Signal and picture mode confirmed; applying and verifying queued settings next');
    return 1;
}

# The full-queue check runs under the same execution claim as calibration,
# before _run_item can reset or measure anything. Only generator output and
# picture-mode selection may change; every changed context is journalled
# before mutation and restored on success, failure, Stop and cleanup retry.
sub _preflight_progress {
    my ($result,$number,$message) = @_;
    $result->{message}=$message;
    die 'Unable to persist queue preflight progress' if !ref(_update_run(sub {
        $_[0]{active_stage}='queue-preflight';$_[0]{active_item}=$number;
        $_[0]{worker_status}={message=>$message};
        $_[0]{preflight_result}=_preflight_result_summary($result);
    }));
    _log_action($message);
    my $state={id=>$RUN_ID,run_id=>$RUN_ID,intent=>_run()->{preflight_only}?'readiness':'start',
        scope=>'queue',status=>'checking',started_at=>$result->{started_at},updated_at=>time(),
        active_item=>$number,total_items=>$result->{total_items},items=>$result->{jobs},
        checks=>$result->{checks},issues=>[grep {!$_->{ok}} @{$result->{checks}}],message=>$message,
        progress_done=>$result->{progress_done},progress_total=>$result->{progress_total}};
    die 'Unable to persist visible queue preflight progress'
        if !PGAutomation::write_json_atomic(PGAutomation::base_dir().'/preflight.json',$state,0664);
}

# What the manifest keeps of a whole-queue check: the verdict, counts and
# per-job outcomes. The check list itself is in preflight-plan.json and the
# saved preflight status; copying its tens of kilobytes into the manifest on
# every progress step made each later manifest write slower.
sub _preflight_result_summary {
    my ($result) = @_;
    return $result if ref($result) ne 'HASH';
    my %summary = %$result;
    delete $summary{checks};
    return PGAutomation::clone(\%summary);
}

sub _preflight_read_mode {
    my ($signal, $allow_limited) = @_;
    # lg_scoped_request_payload normally supplies the queued picture_mode.
    # A restoration snapshot must instead observe the actual mode, never an
    # echoed requested selector. Temporarily omit only that item context.
    my $saved_item=$ACTIVE_ITEM;$ACTIVE_ITEM=undef;
    my $live=eval { _api('POST','/api/lg/picture-settings',{
        keys=>['pictureMode'],include_current_input=>JSON::PP::true,
        ignore_calibration_picture_mode=>JSON::PP::true,signal_mode=>$signal,
    },$RESTORING_PREFLIGHT,0) };
    my $read_error=$@;$ACTIVE_ITEM=$saved_item;
    die $read_error if $read_error;
    die 'No independent current-mode response' if ref($live) ne 'HASH';
    my $mode=_observed_settings($live)->{pictureMode}||'';
    my $profile=_slim_profile($live->{generation_profile}||{});
    my $generation=ref($live->{lg_generation}) eq 'HASH' ? $live->{lg_generation} : {};
    my $limited=$allow_limited && _response_ok($live)
        && $profile->{capability_library_valid} && $profile->{capability_platform_profile_applied}
        && lg_picture_mode_read_forbidden($live);
    die 'Cannot safely probe modes: the current TV mode cannot be read independently. No unverified mode will be used for restoration.'
        if !$limited && (!_response_ok($live) || $live->{virtual_picture_settings} || lg_picture_mode_read_forbidden($live)
            || !$mode || !_signal_mode_compatible($signal,$mode));
    $mode='' if $limited; # Never retain an echoed selector as a restoration target.
    die 'Cannot safely probe modes: TV input or compatibility signature is unavailable'
        if ($live->{current_input}||'') !~ /^hdmi[1-4](?:_pc)?$/ || ($profile->{capability_profile_hash}||'') !~ /^[a-f0-9]{64}$/;
    # Stamped as an independent no-echo read so the mode selector may act on
    # it; verified only because every unreadable case died above.
    return {picture_mode=>$mode,signal_format=>$signal,tv_input=>$live->{current_input},
        capability_profile=>{hash=>$profile->{capability_profile_hash},id=>$profile->{capability_profile_id}},
        generation_profile=>$profile,settle_seconds=>1,stages=>{calibration=>0},
        no_echo=>1,verified=>$limited?0:1,mode_readback_unavailable=>$limited?1:0,current_input=>$live->{current_input}};
}

sub _preflight_save_context {
    my ($context) = @_;
    die 'Unable to save reversible preflight context; no further mode changes are allowed'
        if !_write_artifact($RUN_DIR.'/preflight-context.json',$context);
    return if _run()->{preflight_only};
    my $path=$RUN_DIR.'/viewing-context.json';
    my $stored=PGAutomation::read_state($path);
    die 'Original viewing context is unreadable; no further mode changes are allowed' if $stored->{state} eq 'error';
    my $original=$stored->{state} eq 'ok' ? $stored->{value} : PGAutomation::clone($context);
    for my $signal (@{$context->{order}||[]}) {
        next if exists($original->{modes}{$signal});
        $original->{modes}{$signal}=PGAutomation::clone($context->{modes}{$signal});
        push @{$original->{order}},$signal;
    }
    die 'Unable to retain original viewing context' if !_write_artifact($path,$original);
}

# P13: walking every pending job through its signal and picture mode takes
# minutes. When nothing it proved can have changed, a Resume (or a Run queue
# straight after Check Readiness) reuses that proof. A Resume reuses it for
# as long as the queue and the TV identity still match; each job's start
# freezes the live input and compatibility profile against its plan
# contract, so a TV that changed while the run was parked is still refused.
# A Check Readiness pointer is only trusted for a few minutes, because that
# run returned the TV to the operator and anyone may have used it since.
our $PREFLIGHT_REUSE_READINESS_SECONDS=15*60;

sub _preflight_identity_matches {
    my ($context,$require_mode)=@_;
    return 0 if ref($context) ne 'HASH' || ref($context->{original}) ne 'HASH' || ref($context->{config}) ne 'HASH';
    my $live=eval { _preflight_read_mode($context->{config}{signal_mode},$context->{mode_readback_unavailable}) };
    return 0 if ref($live) ne 'HASH';
    return 0 if ($live->{tv_input}||'') eq '' || ($live->{tv_input}||'') ne ($context->{original}{tv_input}||'');
    return 0 if (($live->{capability_profile}||{})->{hash}||'') ne (($context->{original}{capability_profile}||{})->{hash}||'');
    return 0 if $require_mode && !$context->{mode_readback_unavailable}
        && !_mode_agrees($live->{picture_mode},$context->{original}{picture_mode});
    return 1;
}

sub _reusable_preflight {
    my ($run)=@_;
    return undef if ref($run) ne 'HASH' || $run->{preflight_only};
    my $revision=$run->{queue_revision}||0;
    my ($result,$source);
    if ($run->{resumed_at}) {
        my $previous=$run->{preflight_result};
        return undef if ref($previous) ne 'HASH' || !$previous->{ready}
            || !defined($run->{preflight_revision}) || $run->{preflight_revision}!=$revision;
        return undef if !_preflight_identity_matches(PGAutomation::read_json_file($RUN_DIR.'/preflight-context.json'),0);
        # The manifest keeps the verdict; the check list lives in the plan.
        my $plan=PGAutomation::read_json_file($RUN_DIR.'/preflight-plan.json');
        my @checks=ref($plan) eq 'HASH' && ref($plan->{result}) eq 'HASH' && ref($plan->{result}{checks}) eq 'ARRAY' ? @{$plan->{result}{checks}} : ();
        $result={%{PGAutomation::clone($previous)},(@checks ? (checks=>\@checks) : ()),reused=>JSON::PP::true,reused_at=>time(),
            message=>'Resumed on the same TV with an unchanged queue, so the earlier whole-queue check still applies.'};
        $source='resume';
    } else {
        my $pointer_path=PGAutomation::base_dir().'/last-readiness.json';
        my $pointer=PGAutomation::read_json_file($pointer_path);
        # Single use, whether or not it is fresh or matches this queue.
        unlink($pointer_path) if -e $pointer_path;
        return undef if ref($pointer) ne 'HASH' || !PGAutomation::safe_component($pointer->{run_id}||'')
            || time()-($pointer->{completed_at}||0) > $PREFLIGHT_REUSE_READINESS_SECONDS;
        my $dir=PGAutomation::run_dir($pointer->{run_id});
        my $plan=PGAutomation::read_json_file($dir.'/preflight-plan.json');
        my $context=PGAutomation::read_json_file($dir.'/preflight-context.json');
        my $items=ref($run->{items}) eq 'ARRAY' ? $run->{items} : [];
        return undef if ref($plan) ne 'HASH' || ref($plan->{result}) ne 'HASH' || !$plan->{result}{ready}
            || ref($plan->{items}) ne 'ARRAY' || !@$items || @$items!=@{$plan->{items}};
        for my $i (0..$#$items) {
            my $checked=$plan->{items}[$i];
            return undef if ref($items->[$i]) ne 'HASH' || ($items->[$i]{status}||'queued') ne 'queued'
                || ref($checked) ne 'HASH' || ref($checked->{preflight_contract}) ne 'HASH'
                || PGAutomationPlan::intent_hash($items->[$i]) ne ($checked->{preflight_contract}{queue_intent_hash}||'');
        }
        # The readiness run returned the TV to its original modes and output;
        # that is only still true if nobody has changed them since.
        return undef if !_preflight_identity_matches($context,1);
        my $config=_api('GET','/api/config',undef,0,0);
        return undef if ref($config) ne 'HASH' || grep {!defined($config->{$_}) || "$config->{$_}" ne "$context->{config}{$_}"} keys %{$context->{config}};
        return undef if !eval { _preflight_save_context($context); 1 };
        $result={%{PGAutomation::clone($plan->{result})},reused=>JSON::PP::true,reused_at=>time(),reused_from=>$pointer->{run_id},
            message=>'Check Readiness passed moments ago for this exact queue on the same TV, so its whole-queue check is reused.'};
        my $checked_items=PGAutomation::clone($plan->{items});
        # Adoption is an optimisation: if it cannot be recorded, run the full check.
        # This run's own plan file keeps the check list a later Resume reads.
        return undef if !_write_artifact($RUN_DIR.'/preflight-plan.json',{revision=>$revision,items=>$checked_items,result=>$plan->{result}});
        my $adopted=eval { _update_run(sub {
            die 'Queue changed while adopting the readiness check' if ($_[0]{queue_revision}||0)!=$revision;
            $_[0]{items}=$checked_items;$_[0]{preflight_revision}=$revision;
        }) };
        return undef if !ref($adopted);
        $source='readiness';
    }
    die 'Unable to publish the reused queue check' if !ref(_update_run(sub {
        $_[0]{preflight_in_progress}=JSON::PP::false;$_[0]{preflight_result}=_preflight_result_summary($result);
        $_[0]{worker_status}={message=>$result->{message}};
    }));
    # Keep the startup status the web UI shows in step with the reuse.
    PGAutomation::write_json_atomic(PGAutomation::base_dir().'/preflight.json',{
        id=>$RUN_ID,run_id=>$RUN_ID,scope=>'queue',status=>'ready',intent=>'start',%$result,updated_at=>time(),
        items=>$result->{jobs},issues=>[grep {!$_->{ok}} @{$result->{checks}||[]}],
    },0664);
    _log_action('Skipping the whole-queue check ('.$source.'): '.$result->{message});
    return $result;
}

sub _preflight_snapshot {
    my $config=_api('GET','/api/config',undef,0,0);
    die 'Generator configuration is unavailable for preflight restoration'
        if ref($config) ne 'HASH' || ($config->{status}||'') eq 'error'
            || ($config->{signal_mode}||'') !~ /^(?:sdr|hdr10|hlg|dv)$/;
    my $saved=_preflight_config_subset($config);
    my $mode=_preflight_read_mode($config->{signal_mode},1);
    my $limited=$mode->{mode_readback_unavailable};
    my $context={config=>$saved,original=>$mode,mode_readback_unavailable=>$limited?1:0,
        modes=>$limited?{}:{$config->{signal_mode}=>$mode},order=>$limited?[]:[$config->{signal_mode}]};
    _preflight_save_context($context);
    return $context;
}

sub _preflight_wait_config {
    my ($config,$reply) = @_;
    die($reply->{message}||'Generator restoration was rejected') if !_response_ok($reply);
    my $until=time()+45;
    while (time()<$until) {
        my $restart_ok=1;
        if ($reply->{restart_id}) {
            my $r=_api('GET','/api/restart/status?id='.$reply->{restart_id},undef,1,0);
            die($r->{message}||'Renderer restoration failed') if ($r->{state}||'') eq 'error';
            $restart_ok=($r->{state}||'') eq 'ready';
        }
        my $actual=_api('GET','/api/config',undef,1,0);
        my @different=grep {!defined($actual->{$_}) || "$actual->{$_}" ne "$config->{$_}"} keys %$config;
        return 1 if $restart_ok && !@different;
        _sleep_controlled(0.25);
    }
    die 'Generator output restoration did not verify';
}

# A batch that passed its whole-queue check keeps the TV where the check left
# it: on the first job's signal and picture mode. Returning every signal to its
# original mode now, only for job 1 to switch away again a minute later, cost
# this appliance about five minutes per batch. The viewing context the check
# saved holds each signal's original mode and the mode journal keeps the
# check's marks, so the batch's own end-of-run restoration walks both: the
# obligation moves to the batch rather than disappearing.
sub _defer_preflight_restore {
    return 1 if !_run()->{preflight_restore_required};
    if (!-f $RUN_DIR.'/viewing-context.json') {
        $::LAST_ERROR='Original viewing context was not saved; ownership retained';
        return 0;
    }
    my $saved=_update_run(sub {
        $_[0]{preflight_restore_required}=JSON::PP::false;
        $_[0]{preflight_restore_outcome}='deferred-to-batch';
        $_[0]{viewing_restore_required}=JSON::PP::true;
        delete @{$_[0]}{qw(viewing_restore_outcome viewing_context_restored_at viewing_restore_abandoned_at)};
    });
    if (!ref($saved)) {
        $::LAST_ERROR='Unable to hand restoration over to the batch; ownership retained';
        return 0;
    }
    _log_action('Queue checks passed; the TV stays on the first job\'s mode and the original modes are restored when the batch finishes');
    return 1;
}

# The generator settings a restoration returns, as read from /api/config.
my @PREFLIGHT_CONFIG_KEYS=qw(signal_mode eotf primaries colorimetry color_format rgb_quant_range max_bpc
    dv_map_mode dv_transport dv_interface dv_profile dv_metadata dv_color_space dv_status is_ll_dovi is_std_dovi);
sub _preflight_config_subset {
    my ($config)=@_;
    return {map {exists($config->{$_}) && !ref($config->{$_}) ? ($_=>$config->{$_}) : ()} @PREFLIGHT_CONFIG_KEYS};
}

sub _restore_preflight_context {
    my ($kind)=@_; $kind='preflight' if !defined($kind);
    die 'Invalid restoration context' if $kind ne 'preflight' && $kind ne 'viewing';
    if (_current_mode_stop_requested()) { _keep_current_mode_on_stop(); return 1; }
    my $flag=$kind.'_restore_required';
    return 1 if !_run()->{$flag};
    my $context=PGAutomation::read_json_file($RUN_DIR.'/'.$kind.'-context.json');
    if (ref($context) ne 'HASH' || ref($context->{original}) ne 'HASH' || ref($context->{config}) ne 'HASH') {
        $::LAST_ERROR='Saved preflight restoration context is missing; ownership retained';
        return 0;
    }
    # keep-last leaves the generator and TV as the last job left them. What it
    # still owes are the signals the queue check switched to a job's mode and
    # no job ever selected: a batch that stopped early would otherwise leave a
    # mode the operator never chose on a signal nothing calibrated.
    my $keep_last=$kind eq 'viewing' && (_run()->{finish_policy}||'restore-original') eq 'keep-last';
    my $marks_kind=$keep_last ? 'keep-last' : $kind;
    if ($keep_last && !grep {_journal_marks(_run()->{mode_written_signals},$_,'keep-last')} @{$context->{order}||[]}) {
        my $saved=_update_run(sub {
            $_[0]{$flag}=JSON::PP::false;
            $_[0]{mode_written_signals}=_journal_after_restore($_[0]{mode_written_signals},$kind);
            $_[0]{$kind.'_context_restored_at'}=time();
            $_[0]{$kind.'_restore_outcome'}='kept-last';
        });
        if (!ref($saved)) { $::LAST_ERROR='Unable to persist completed context restoration'; return 0; }
        _log_action('Keeping the last job\'s output and picture mode; the queue check changed no other signal');
        return 1;
    }
    my ($old_item,$old_stopping,$old_restoring)=($ACTIVE_ITEM,$STOPPING,$RESTORING_PREFLIGHT);
    $STOPPING=1;$RESTORING_PREFLIGHT=1;
    my $identity_changed='';
    my $ok=eval {
        # Return each signal's selected mode to its original value, with the
        # initially active signal restored last. Never restore TV settings/LUTs.
        # A run journals the signals it wrote a mode on; the others were never
        # changed, so switching the output through them only flashed patterns
        # and HDMI format changes on the TV. Older runs have no journal and
        # keep walking every saved signal.
        # Identity first, read on the signal the generator is outputting now. A
        # changed TV refuses reads that carry the saved context, so switching
        # the output first would only time out and keep the TV locked (P16).
        my $now=_api('GET','/api/config',undef,1,0);
        my $now_signal=ref($now) eq 'HASH' ? ($now->{signal_mode}||'') : '';
        $now_signal='' if $now_signal !~ /^(?:sdr|hdr10|hlg|dv)$/;
        # Input and profile only: another source or an app can show a mode
        # that does not fit the generator's signal, and that must still count.
        $identity_changed=_restore_identity_changed($context->{original},$now_signal);
        die 'TV input or compatibility changed during preflight restoration' if $identity_changed;
        # Any later failure is checked the same way before it is treated as a
        # retryable restore failure: a refused switch or read may be the TV
        # having changed, and one odd read must never abandon a restore.
        my $confirm_identity=sub {
            my ($saved,$signal,$live,$error)=@_;
            $identity_changed=_restore_identity_changed($saved,$signal,$live);
            die 'TV input or compatibility changed during preflight restoration' if $identity_changed;
            die $error if defined($error);
        };
        my $written=_run()->{mode_written_signals};
        my $switched=0;
        for my $signal (reverse @{$context->{order}||[]}) {
            if ($keep_last ? !_journal_marks($written,$signal,'keep-last')
                    : ref($written) eq 'HASH' && !_journal_marks($written,$signal,$kind) && $signal ne ($context->{config}{signal_mode}||'')) {
                _log_action($keep_last && ref($written) eq 'HASH' && _journal_marks($written,$signal,'viewing')
                    ? 'Keeping the picture mode a job selected on '.uc($signal)
                    : 'No picture mode was changed on '.uc($signal).'; leaving that signal alone during restoration');
                next;
            }
            $switched++;
            my $item=$context->{modes}{$signal};
            $ACTIVE_ITEM=$item;
            $confirm_identity->($item,$signal,undef,($::LAST_ERROR||'Unable to restore preflight signal')."\n") if !_apply_signal($item);
            my $live=eval { _preflight_read_mode($signal) };
            $confirm_identity->($item,$signal,undef,$@||"No independent current-mode response\n") if ref($live) ne 'HASH';
            if ($live->{tv_input} ne $item->{tv_input}
                    || $live->{capability_profile}{hash} ne $item->{capability_profile}{hash}) {
                $confirm_identity->($item,$signal,$live);
                $live=_preflight_read_mode($signal);
                die 'TV identity reads disagree during preflight restoration; ownership retained'
                    if $live->{tv_input} ne $item->{tv_input} || $live->{capability_profile}{hash} ne $item->{capability_profile}{hash};
            }
            if (!_mode_agrees($item->{picture_mode},$live->{picture_mode})) {
                # A refused write or an unreadable verification read may also
                # be the TV having changed under the restore (P16).
                $confirm_identity->($item,$signal,undef,($::LAST_ERROR||'Unable to restore picture mode')."\n")
                    if !_select_item_picture_mode(0,$item,'preflight-restore',$live);
                $live=eval { _preflight_read_mode($signal) };
                $confirm_identity->($item,$signal,undef,$@||"No independent current-mode response\n") if ref($live) ne 'HASH';
                die 'Original picture mode restoration was not independently verified'
                    if !_mode_agrees($item->{picture_mode},$live->{picture_mode});
            }
        }
        if ($keep_last) {
            # Back to the output the last job left, not the original one.
            my $last=_preflight_config_subset($now);
            if ($switched && $now_signal ne '') {
                $ACTIVE_ITEM=$context->{modes}{$now_signal}||$context->{original};
                _preflight_wait_config($last,_api('POST','/api/config',$last,1,0));
                my $pattern=_api('POST','/api/pattern',{name=>'stop',signal_mode=>$now_signal},1,0);
                die 'Unable to display the idle pattern after preflight restoration' if !_response_ok($pattern);
            }
            die 'Unable to persist completed context restoration' if !ref(_update_run(sub {
                $_[0]{$flag}=JSON::PP::false;
                $_[0]{mode_written_signals}=_journal_after_restore($_[0]{mode_written_signals},$kind);
                $_[0]{$kind.'_context_restored_at'}=time();
                $_[0]{$kind.'_restore_outcome'}='kept-last';
            }));
            return 1;
        }
        $ACTIVE_ITEM=$context->{original};
        _preflight_wait_config($context->{config},_api('POST','/api/config',$context->{config},1,0));
        my $pattern=_api('POST','/api/pattern',{name=>'stop',signal_mode=>$context->{config}{signal_mode}},1,0);
        die 'Unable to display the idle pattern after preflight restoration' if !_response_ok($pattern);
        my $final_signal=$context->{config}{signal_mode};
        my $live=eval { _preflight_read_mode($final_signal,$context->{mode_readback_unavailable}) };
        $confirm_identity->($context->{original},$final_signal,undef,$@||"No independent current-mode response\n") if ref($live) ne 'HASH';
        if ($live->{tv_input} ne $context->{original}{tv_input}
                || $live->{capability_profile}{hash} ne $context->{original}{capability_profile}{hash}) {
            $confirm_identity->($context->{original},$final_signal,$live);
            $live=_preflight_read_mode($final_signal,$context->{mode_readback_unavailable});
            die 'Original viewing context did not restore'
                if $live->{tv_input} ne $context->{original}{tv_input} || $live->{capability_profile}{hash} ne $context->{original}{capability_profile}{hash};
        }
        die 'Original viewing context did not restore'
            if !$context->{mode_readback_unavailable} && !_mode_agrees($live->{picture_mode},$context->{original}{picture_mode});
        die 'Unable to persist completed context restoration' if !ref(_update_run(sub {
            $_[0]{$flag}=JSON::PP::false;
            $_[0]{mode_written_signals}=_journal_after_restore($_[0]{mode_written_signals},$kind);
            $_[0]{$kind.'_context_restored_at'}=time();
            $_[0]{$kind.'_restore_outcome'}=$context->{mode_readback_unavailable} ? 'output-restored-mode-unavailable' : 'verified';
        }));
        1;
    };
    my $error=$@;
    if (_current_mode_stop_requested()) {
        ($ACTIVE_ITEM,$STOPPING,$RESTORING_PREFLIGHT)=($old_item,$old_stopping,$old_restoring);
        _keep_current_mode_on_stop();
        return 1;
    }
    if (!$ok && $identity_changed) {
        # A different input or a changed TV (firmware, capability library,
        # device) can never match the saved context again, so retrying would
        # hold the TV forever. Mode restoration is a courtesy, not a safety
        # obligation: return the generator output, record why the modes were
        # left alone, and discharge the obligation with a visible warning.
        $ACTIVE_ITEM=$context->{original};
        my $output_restored=eval {
            _preflight_wait_config($context->{config},_api('POST','/api/config',$context->{config},1,0));
            _api('POST','/api/pattern',{name=>'stop',signal_mode=>$context->{config}{signal_mode}},1,0);
            1;
        };
        my $warning="Original picture modes were not restored because $identity_changed since the batch started. Check each signal's picture mode on the TV."
            .($output_restored ? '' : ' The generator output could not be returned to its original settings either; check the Output page.');
        my $saved=_update_run(sub {
            $_[0]{$flag}=JSON::PP::false;
            $_[0]{mode_written_signals}=_journal_after_restore($_[0]{mode_written_signals},$kind);
            $_[0]{$kind.'_restore_outcome'}='abandoned-tv-changed';
            $_[0]{$kind.'_restore_abandoned_at'}=time();
            _add_run_warning($_[0],$warning);
        });
        ($ACTIVE_ITEM,$STOPPING,$RESTORING_PREFLIGHT)=($old_item,$old_stopping,$old_restoring);
        if (ref($saved)) {
            _log_action($warning);
            return 1;
        }
        $::LAST_ERROR='Unable to persist abandoned context restoration; ownership retained';
        return 0;
    }
    ($ACTIVE_ITEM,$STOPPING,$RESTORING_PREFLIGHT)=($old_item,$old_stopping,$old_restoring);
    $::LAST_ERROR=$error||'Preflight restoration failed' if !$ok;
    return $ok?1:0;
}

# Does the mode-write journal say this restoration kind must return $signal?
# Entries from before phase marks (a plain true) count for both kinds.
# 'keep-last' asks the opposite of the others: only a signal the queue check
# changed and no job then selected is owed; without a journal nothing is.
sub _journal_marks {
    my ($written,$signal,$kind)=@_;
    return $kind eq 'keep-last' ? 0 : 1 if ref($written) ne 'HASH';
    my $entry=$written->{$signal};
    return 0 if !$entry;
    return $kind eq 'keep-last' ? 0 : 1 if ref($entry) ne 'HASH';
    return ($entry->{preflight} && !$entry->{job}) ? 1 : 0 if $kind eq 'keep-last';
    return $kind eq 'preflight' ? ($entry->{preflight}?1:0) : (($entry->{preflight}||$entry->{job})?1:0);
}

sub _journal_after_restore {
    my ($written,$kind)=@_;
    return {} if $kind ne 'preflight' || ref($written) ne 'HASH';
    my %kept;
    foreach my $signal (keys %$written) {
        my $entry=$written->{$signal};
        next if !$entry;
        my %marks=ref($entry) eq 'HASH' ? %$entry : (preflight=>JSON::PP::true,job=>JSON::PP::true);
        delete $marks{preflight};
        $kept{$signal}=\%marks if grep {$marks{$_}} keys %marks;
    }
    return \%kept;
}

# ($message,$raw) for an exception: both on one line (runner.log timestamps
# lines and the UI splits on newlines); the message also drops the runner's
# " at FILE line N." (with Perl's ", <FH> line M" variant), which is noise for
# the operator. The raw text keeps the location for diagnosing real crashes.
sub _clean_exception {
    my ($text)=@_;
    $text='' if !defined($text);
    $text="$text";
    $text=~s/\s+$//;
    $text=~s/\s*[\r\n]+\s*/ | /g;
    my $message=$text;
    $message=~s/ at \S+ line \d+(?:, <[^>]*> (?:line|chunk) \d+)?\.?$//;
    return ($message,$text);
}

# The TV's input and compatibility hash, read without the saved context (a
# changed TV refuses scoped reads) and without requiring a picture mode that
# fits the signal. A built-in app reports no HDMI input, only its app id, and
# that is a different input. Undef when the TV cannot be read or reports no
# identity. The profile flags let a partial read (for example firmware
# information that timed out) be told apart from a real change.
sub _restore_identity_read {
    my ($signal)=@_;
    my $saved_item=$ACTIVE_ITEM;$ACTIVE_ITEM=undef;
    my $live=eval { _api('POST','/api/lg/picture-settings',{
        keys=>['pictureMode'],include_current_input=>JSON::PP::true,ignore_calibration_picture_mode=>JSON::PP::true,
        ($signal ? (signal_mode=>$signal) : ()),
    },1,0) };
    $ACTIVE_ITEM=$saved_item;
    return undef if ref($live) ne 'HASH' || !_response_ok($live);
    my $input=$live->{current_input}||'';
    $input='app:'.$live->{current_app_id} if $input eq '' && ($live->{current_app_id}||'') ne '';
    my $profile=ref($live->{generation_profile}) eq 'HASH' ? $live->{generation_profile} : {};
    my $hash=$profile->{capability_profile_hash}||'';
    return undef if $input eq '' || $hash !~ /^[a-f0-9]{64}$/;
    return {tv_input=>$input,capability_profile=>{hash=>$hash},
        platform_profile_applied=>$profile->{capability_platform_profile_applied}?1:0,
        library_valid=>$profile->{capability_library_valid}?1:0};
}

# Text naming the change when the TV no longer matches $saved, else ''. A
# difference must be seen on two reads two seconds apart; an unreadable TV is
# not a change (that stays a retryable failure).
sub _restore_identity_changed {
    my ($saved,$signal,$first)=@_;
    my $saved_profile=ref($saved->{generation_profile}) eq 'HASH' ? $saved->{generation_profile} : {};
    my $differs=sub {
        my ($live)=@_;
        return 0 if ref($live) ne 'HASH';
        return 1 if ($live->{tv_input}||'') ne ($saved->{tv_input}||'');
        return 0 if (($live->{capability_profile}||{})->{hash}||'') eq (($saved->{capability_profile}||{})->{hash}||'');
        # A hash computed from a partial read (model table or capability
        # library missing where the saved context had them) is not evidence
        # the TV changed: treat it as unreadable, never as a change.
        return 0 if $saved_profile->{capability_platform_profile_applied} && defined($live->{platform_profile_applied}) && !$live->{platform_profile_applied};
        return 0 if $saved_profile->{capability_library_valid} && defined($live->{library_valid}) && !$live->{library_valid};
        return 1;
    };
    $first=_restore_identity_read($signal) if ref($first) ne 'HASH';
    return '' if !$differs->($first);
    _sleep_controlled(2);
    my $second=_restore_identity_read($signal);
    return $differs->($second) ? _identity_change_text($saved,$second) : '';
}

sub _identity_change_text {
    my ($saved,$live)=@_;
    my @changes;
    push @changes,'the TV input changed ('.($saved->{tv_input}||'unknown').' to '.($live->{tv_input}||'unknown').')'
        if ($saved->{tv_input}||'') ne ($live->{tv_input}||'');
    push @changes,"the TV's compatibility profile changed (firmware, capability library or TV identity)"
        if (($saved->{capability_profile}||{})->{hash}||'') ne (($live->{capability_profile}||{})->{hash}||'');
    return join(' and ',@changes) || 'the TV identity changed';
}

sub _add_run_warning {
    my ($run,$warning)=@_;
    $run->{warnings}=[] if ref($run->{warnings}) ne 'ARRAY';
    push @{$run->{warnings}},$warning if !grep {!ref($_) && $_ eq $warning} @{$run->{warnings}};
    return $run;
}

sub _preflight_queue {
    $ACTIVE_STAGE='queue-preflight';
    my $run=_update_run(sub {$_[0]{preflight_in_progress}=JSON::PP::true;$_[0]{stage_started_at}=time();delete $_[0]{operation_progress};
        $_[0]{mode_written_signals}={} if ref($_[0]{mode_written_signals}) ne 'HASH';});
    die 'Unable to reserve queue preflight' if !ref($run);
    my $revision=$run->{queue_revision}||0;
    my $items=PGAutomation::clone($run->{items}||[]);
    my @pending=grep {($items->[$_]{status}||'') !~ /^complete(?:-with-warnings)?$/} 0..$#$items;
    my $result={scope=>'queue',ready=>0,started_at=>time(),total_items=>scalar(@pending),checked_items=>0,progress_done=>0,progress_total=>3+3*scalar(@pending),
        jobs=>[map {{name=>$_->{name}||'Job',status=>(($_->{status}||'')=~/^complete/ ? 'previously-completed' : 'unchecked')}} @$items],checks=>[]};
    my $context;
    my %preflight_seen;
    my $setup=eval {
        _preflight_progress($result,undef,'Checking every pending job before any calibration begins');
        if (@pending) {
            # Establish idle devices/confirmed CAL_END under our execution claim.
            my $base=_api('POST','/api/automation/readiness',{scope=>'batch',items=>[map {$items->[$_]} @pending]},0,0);
            # The batch pass numbers jobs by position in the pending list; report
            # them by their position in the queue, like the per-job pass does.
            for my $check (@{$base->{checks}||[]}) {
                next if ref($check) ne 'HASH';
                $check->{item_number}=$pending[$check->{item_number}]
                    if defined($check->{item_number}) && $check->{item_number}=~/^\d+$/ && defined($pending[$check->{item_number}]);
                _push_preflight_check($result,$check,\%preflight_seen);
            }
            die($base->{message}||'Equipment is not ready') if !$base->{ready};
            $result->{progress_done}++;
            _preflight_progress($result,undef,'Equipment ready; saving original signal and picture mode');
            $ACTIVE_ITEM=undef;
            $context=_preflight_snapshot();
            $result->{progress_done}++;
        }
        1;
    };
    if (!$setup) {
        my ($error,$raw)=_clean_exception($@||'Unable to capture preflight context');
        _log("queue preflight context failed: $error".($raw ne $error ? " [raw: $raw]" : ''));
        push @{$result->{checks}},{ok=>0,level=>'error',name=>'queue-preflight-context',message=>$error,
            ($raw ne $error ? (raw_exception=>$raw) : ())};
    } else {
        # Last job first: a real run keeps the TV where the check leaves it,
        # so ending on the first job's signal and mode lets that job start
        # without switching the output or writing the mode again.
        for my $number (reverse @pending) {
            _refresh_control();last if $STOP_REQUESTED;
            my $item=$items->[$number];$ACTIVE_ITEM=$item;$item->{item_number}=$number;
            $result->{jobs}[$number]{status}='checking';
            my $ok=eval {
                _preflight_progress($result,$number,'Checking job '.($number+1).' of '.scalar(@$items).': '.($item->{name}||_picture_mode($item)));
                if (!$context->{mode_readback_unavailable}) {
                die 'Unable to save preflight mutation guard' if !ref(_update_run(sub {$_[0]{preflight_restore_required}=JSON::PP::true;}));
                # Ignore old job context during transitions; freeze the actual
                # connected input/profile afresh, then require the same TV.
                delete @$item{qw(capability_profile generation_profile tv_input preflight_contract)};
                die($::LAST_ERROR||'Unable to select preflight signal') if !_apply_signal($item);
                $result->{progress_done}++;
                _preflight_progress($result,$number,'Signal ready; selecting and verifying picture mode');
                my $signal=_signal($item);
                my $before=_preflight_read_mode($signal);
                die 'TV input or compatibility changed during queue preflight'
                    if $before->{tv_input} ne $context->{original}{tv_input}
                        || $before->{capability_profile}{hash} ne $context->{original}{capability_profile}{hash};
                if (!exists($context->{modes}{$signal})) {
                    $context->{modes}{$signal}=$before;push @{$context->{order}},$signal;
                    _preflight_save_context($context);
                }
                my $frozen=_freeze_job_lg_context($item);
                die($::LAST_ERROR||'Unable to select preflight picture mode')
                    if !_select_item_picture_mode($number,$item,'queue-preflight',$frozen);
                my $selected=_preflight_read_mode($signal);
                die 'Target picture mode was not independently confirmed during preflight'
                    if !_mode_agrees(_picture_mode($item),$selected->{picture_mode});
                $result->{progress_done}++;
                _preflight_progress($result,$number,'Picture mode confirmed; checking TV controls and meter');
                } else {
                    delete @$item{qw(capability_profile generation_profile tv_input preflight_contract)};
                    $result->{verification_state}='limited';
                    $result->{progress_done}+=2;
                    push @{$result->{checks}},{ok=>0,level=>'warning',name=>'queue-preflight-mode-unavailable',item_number=>$number,
                        message=>'This reviewed TV cannot independently read its picture mode. Checking scoped controls without changing modes; the actual job will select its signal and mode with accepted-write evidence. No guessed mode will be restored.'};
                    _preflight_progress($result,$number,'Limited mode readback: checking scoped controls without changing the viewing mode');
                }
                my $ready=_readiness_with_reconnect({scope=>'job',items=>[$item]});
                # Only job-scoped checks belong to this job; equipment checks
                # repeated by every job pass stay global and are listed once.
                for my $check (@{$ready->{checks}||[]}) {$check->{item_number}=$number if ref($check) eq 'HASH' && defined($check->{item_number});_push_preflight_check($result,$check,\%preflight_seen);}
                die($ready->{message}||'Job failed TV compatibility checks') if !$ready->{ready}
                    || ref($ready->{items}) ne 'ARRAY' || ref($ready->{items}[0]) ne 'HASH';
                # The queue's own intent, before readiness adds derived fields
                # (panel_protection_supported, lg_generation, hazard settings);
                # Run queue after Check Readiness compares against this.
                my $queue_intent=PGAutomationPlan::intent_hash($item);
                %$item=(%$item,%{$ready->{items}[0]});
                # The readiness reply carries the full TV capability profile
                # again; the job keeps only what identifies the TV.
                $item->{generation_profile}=_slim_profile($item->{generation_profile}) if ref($item->{generation_profile}) eq 'HASH';
                die 'Job preflight did not return a confirmed input and compatibility signature'
                    if ($item->{tv_input}||'') ne $context->{original}{tv_input}
                        || ($item->{capability_profile}{hash}||'') !~ /^[a-f0-9]{64}$/;
                $item->{preflight_contract}=PGAutomationPlan::contract($item);
                $item->{preflight_contract}{queue_intent_hash}=$queue_intent;
                $item->{preflight_contract}{limited}=JSON::PP::true if $context->{mode_readback_unavailable};
                # This is the job's readiness evidence; job start does not
                # ask again, so the item-started checkpoint records this pass.
                # Only the checks that need a look are kept on the job; the
                # full list is in the saved preflight plan.
                my @job_checks=grep {ref($_) eq 'HASH'} @{$ready->{checks}||[]};
                $item->{readiness}={ready=>1,checked_at=>time(),scope=>'queue-preflight',
                    checks=>[grep {!$_->{ok}} @job_checks],passed=>scalar(grep {$_->{ok}} @job_checks),message=>$ready->{message}||''};
                $result->{jobs}[$number]{status}=$context->{mode_readback_unavailable}?'checked-limited':'checked';$result->{checked_items}++;
                $result->{progress_done}++;
                _preflight_progress($result,$number,'Job '.($number+1).' readiness checks passed');
                1;
            };
            if (!$ok) {
                my ($error,$raw)=_clean_exception($@||$::LAST_ERROR||'Job preflight failed');
                _log('queue preflight job '.($number+1)." failed: $error".($raw ne $error ? " [raw: $raw]" : ''));
                $result->{jobs}[$number]{status}='blocked';
                push @{$result->{checks}},{ok=>0,level=>'error',name=>'queue-preflight-job',item_number=>$number,message=>$error,
                    ($raw ne $error ? (raw_exception=>$raw) : ())};
            }
        }
    }
    # A batch that passed keeps the TV where the check left it (on the first
    # job's signal and mode) and restores the original modes when it finishes.
    # A successful check-only run restores now. Failed checks and Stop keep
    # the current mode, like failure or Stop during calibration.
    my $passed=!$STOP_REQUESTED && @pending && $result->{checked_items}==@pending
        && !grep {!$_->{ok} && ($_->{level}||'error') eq 'error'} @{$result->{checks}};
    my $restored;
    if ($passed && !$run->{preflight_only}) {
        $restored=_defer_preflight_restore();
        $result->{restore_deferred}=1 if $restored;
        push @{$result->{checks}},{ok=>0,level=>'error',name=>'queue-preflight-restore',message=>$::LAST_ERROR||'Unable to hand restoration over to the batch'} if !$restored;
    } elsif (@pending && !$passed && !$STOP_REQUESTED) {
        # Only a job that actually failed its check owes the failure policy;
        # a queue with nothing pending restores like a check-only pass.
        _keep_current_mode_on_stop('failure');
        $restored = 1; # The restoration obligation was explicitly skipped.
        $result->{restore_skipped} = 'failure';
    } else {
        # A display-state write failure must not prevent restoration.
        eval {_preflight_progress($result,undef,$STOP_REQUESTED
            ? 'Stopping queue checks; keeping current signal and picture mode'
            : 'Restoring original output and picture modes after queue checks');};
        $restored=_restore_preflight_context();
        $result->{restore_skipped}='stop' if $STOP_REQUESTED;
        # Restoration abandoned because the TV changed under the check: the queue
        # was not checked against the TV it will run on (P16).
        push @{$result->{checks}},{ok=>0,level=>'error',name=>'queue-preflight-tv-changed',
            message=>'The TV input or compatibility profile changed during the queue check. Check the queue again.'}
            if $restored && (_run()->{preflight_restore_abandoned_at}||0) >= ($result->{started_at}||0);
        push @{$result->{checks}},{ok=>0,level=>'error',name=>'queue-preflight-restore',message=>$::LAST_ERROR||'Preflight restoration failed'} if !$restored;
    }
    $result->{progress_done}++ if $restored;
    push @{$result->{checks}},{ok=>0,level=>'error',name=>'queue-preflight-cancelled',message=>'Queue preflight stopped; unchecked jobs are not ready'} if $STOP_REQUESTED;
    my @errors=grep {!$_->{ok} && ($_->{level}||'error') eq 'error'} @{$result->{checks}};
    my @warnings=grep {!$_->{ok} && ($_->{level}||'') eq 'warning'} @{$result->{checks}};
    $result->{ready}=!@errors && $restored && $result->{checked_items}==@pending ? 1 : 0;
    $result->{restored}=$restored && !$result->{restore_skipped}?1:0;$result->{completed_at}=time();
    $result->{message}=$result->{ready}
        ? (($result->{verification_state}||'') eq 'limited'
            ? 'All '.scalar(@pending).' pending jobs passed limited scoped checks. Signal and picture modes were not changed or independently verified.'
            : $result->{restore_deferred}
            ? 'All '.scalar(@pending).' pending jobs passed live preflight. The TV stays on the first job\'s signal and picture mode; the original modes are restored when the batch finishes.'
            : 'All '.scalar(@pending).' pending jobs passed live preflight. Original output and picture modes restored.')
            .(@warnings?' Review '.scalar(@warnings).' manual or limited-verification warnings.':'')
        : 'Queue blocked before calibration: '.$result->{checked_items}.'/'.scalar(@pending).' pending jobs checked successfully.';
    die 'Unable to persist full-queue preflight result' if !_write_artifact($RUN_DIR.'/preflight-plan.json',
        {revision=>$revision,items=>$items,result=>$result});
    die 'Unable to publish full-queue preflight result' if !ref(_update_run(sub {
        my ($state)=@_;
        die 'Queue changed during preflight' if ($state->{queue_revision}||0)!=$revision;
        $state->{preflight_in_progress}=JSON::PP::false;
        $state->{preflight_result}=_preflight_result_summary($result);
        if($result->{ready}) {$state->{items}=$items;$state->{preflight_revision}=$revision;}
        else {delete $state->{preflight_revision};}
        $state->{active_item}=undef;$state->{active_stage}='queue-preflight';
        $state->{worker_status}={message=>$result->{message}};
    }));
    if ($run->{preflight_only}) {
        my $pointer=PGAutomation::base_dir().'/last-readiness.json';
        if ($result->{ready}) { PGAutomation::write_json_atomic($pointer,{run_id=>$RUN_ID,completed_at=>$result->{completed_at},revision=>$revision}); }
        else { unlink($pointer); }
    }
    PGAutomation::write_json_atomic(PGAutomation::base_dir().'/preflight.json',{
        id=>$RUN_ID,run_id=>$RUN_ID,scope=>'queue',status=>$result->{ready}?'ready':'blocked',
        intent=>$run->{preflight_only}?'readiness':'start',%$result,updated_at=>time(),items=>$result->{jobs},
        issues=>[grep {!$_->{ok}} @{$result->{checks}}],
    },0664) or die 'Unable to publish final preflight status';
    $ACTIVE_ITEM=undef;$ACTIVE_STAGE='';
    return $result;
}

sub _run_item {
    my ($item_number, $item) = @_;
    $ACTIVE_ITEM = $item;
    $item->{item_number} = $item_number;
    $item->{status} = 'running';
    my $has_prior_checkpoint = ref($item->{checkpoints}) eq 'ARRAY' && @{$item->{checkpoints}};
    # Deliberately outside _stage: a saved checkpoint cannot skip fresh device
    # checks or signal restoration after a pause, process restart or reboot.
    my $prepared=eval {
        _prepare_job_context($item_number,$item);
        _prepare_resume($item_number,$item,1) if $has_prior_checkpoint;
        my $baseline_restored = 0;
        if ($item->{profile_baseline_needs_restore}) {
            $baseline_restored = eval { _restore_profile_baseline($item_number,$item) } || 0;
            if (!$baseline_restored) {
                my $error = $@ || $::LAST_ERROR || 'Profile baseline restore failed';
                # Recorded with the failure so the next resume takes the
                # reset instead of arming the same restore again. A restore
                # cut short by a stop request is not a refusal, and one
                # transient refusal earns a single retry before the latch.
                if (!$STOP_REQUESTED && ($::LAST_ERROR_CODE || '') ne 'stopped' && $error !~ /\bstop requested\b/i) {
                    $item->{profile_baseline_restore_failures} = ($item->{profile_baseline_restore_failures} || 0) + 1;
                    $item->{profile_baseline_restore_failed} = 1 if $item->{profile_baseline_restore_failures} >= 2;
                }
                die $error;
            }
        }
        if ($has_prior_checkpoint && (_run()->{pause_context_released} || _run()->{stop_cleanup})) {
            # The baseline restore has just applied and verified every queued
            # control; a second full pass would only repeat it.
            my $verified = $baseline_restored ? 1 : _apply_and_verify($item_number,$item,'resume-setup',1);
            die($::LAST_ERROR||'Unable to restore paused settings') if !$verified && $verified ne 'unverifiable';
            die 'Unable to restore paused panel protection context' if !_panel_protection_disable($item_number,$item);
            die 'Unable to save resumed device context' if !ref(_update_run(sub {delete $_[0]{pause_context_released};}));
        }
        1;
    };
    if (!$prepared) {
        my $message=$@||$::LAST_ERROR||'Job preparation failed';
        $item->{status}='interrupted';
        $item->{failure}={stage=>'job-readiness',message=>"$message",at=>time()};
        _update_item_snapshot($item_number,$item);
        _update_run(sub {$_[0]{status}='interrupted';$_[0]{failure}=$item->{failure};$_[0]{items}[$item_number]=$item;});
        _log_action('Job preparation failed: '.$message);
        return 0;
    }
    delete $item->{failure};
    _update_item_snapshot($item_number, $item);
    _update_run(sub {
        my ($run) = @_;
        $run->{items}[$item_number] = $item if ref($run->{items}) eq 'ARRAY';
        $run->{active_item} = $item_number;
    });
    my $stages = _stages($item);
    return 0 if !_stage($item_number, $item, 'item-started', sub {
        return {readiness=>$item->{readiness}};
    });
    return 0 if _pause_after_checkpoint();
    return 0 if !_stage($item_number, $item, 'tv-setup-verified', sub {
        my $verified = _apply_and_verify($item_number, $item, 'c1', 1);
        die($::LAST_ERROR || 'TV settings failed') if !$verified && $verified ne 'unverifiable';
        my $panel_protection = _panel_protection_disable($item_number, $item);
        die($::LAST_ERROR || 'Unable to persist panel-protection evidence') if !$panel_protection;
        my $settle=0+($item->{settle_seconds}//8);
        _log_action('TV setup applied; settling for '.$settle.' s before measurements') if $settle>0;
        _sleep_controlled($settle) or die('Automation stopped');
        return { verified => $verified, signal_mode => _signal($item), picture_mode => _picture_mode($item), panel_protection => $panel_protection };
    });
    return 0 if _pause_after_checkpoint();
    if ($stages->{pre}) {
        return 0 if !_stage($item_number, $item, 'pre-readings-done', sub {
            die($::LAST_ERROR || 'Calibration mode did not close before pre-readings')
                if !_ensure_calibration_mode_off($item);
            die('Unable to switch DV to Absolute map') if !_set_dv_map($item, '1');
            die($::LAST_ERROR || 'Pre-readings failed') if !_run_series($item_number, $item, 'pre');
            return 1;
        });
    } else {
        _skip_stage($item_number, $item, 'pre-readings-done');
    }
    return 0 if _pause_after_checkpoint();
    if ($stages->{calibration}) {
            return 0 if !_stage($item_number, $item, 'reset-and-reapply-verified', sub {
                die($::LAST_ERROR || 'Calibration reset failed') if !_reset_for_calibration($item_number, $item);
                my $verified = _apply_and_verify($item_number, $item, 'c4');
                die($::LAST_ERROR || 'Settings did not survive reset') if !$verified && $verified ne 'unverifiable';
                return { verified => $verified };
            });
            return 0 if _pause_after_checkpoint();
            return 0 if !_stage($item_number, $item, 'panel-light-settled', sub {
                my $panel = ref($item->{panel_light}) eq 'HASH' ? $item->{panel_light} : {};
                die('Panel light is only targetable on SDR') if lc($panel->{policy} || $item->{panel_light_policy} || 'fixed') eq 'target' && _signal($item) ne 'sdr';
                die($::LAST_ERROR || 'Calibration mode did not close before panel-light control')
                    if !_ensure_calibration_mode_off($item);
                die($::LAST_ERROR || 'Panel-light stage failed') if !_panel_light_stage($item_number, $item);
                my $evidence = PGAutomation::read_json_file(PGAutomation::item_dir($RUN_ID, $item_number) . '/panel-light.json') || {};
                return {verified => $evidence->{settings_verified} // $evidence->{verified} // 'unverifiable',
                    panel_light => $evidence};
            });
            return 0 if _pause_after_checkpoint();
            return 0 if !_stage($item_number, $item, 'greyscale-done', sub {
                my $result = _calibration_greyscale_stage($item_number, $item);
                if (!$result) {
                    return 0 if $STOP_REQUESTED;
                    die($::LAST_ERROR || 'Greyscale calibration failed');
                }
                return $result;
            });
            return 0 if _pause_after_checkpoint();
            # Check the completed 1D result before spending time profiling.
            # Once a volume LUT is committed its menu ownership differs, so a
            # later resume goes directly to the post-upload check instead.
            if (!_checkpoint_exists($item, 'volume-done')) {
                return 0 if !_stage($item_number, $item, 'greyscale-settings-verified', sub {
                    _calibration_settings_boundary($item_number, $item, 'c6');
                });
                return 0 if _pause_after_checkpoint();
            }
            my $before_profile_upload;
            return 0 if !_stage($item_number, $item, 'volume-done', sub {
                my $result = _calibration_volume_stage($item_number, $item);
                if (!$result) {
                    return 0 if $STOP_REQUESTED;
                    die($::LAST_ERROR || 'Volume calibration failed');
                }
                $before_profile_upload = $result->{settings_before_upload};
                return $result;
            });
            return 0 if _pause_after_checkpoint();
            my $before_exit;
            if (!_checkpoint_exists($item, 'session-closed')) {
                # Fresh evidence on every entry (including Resume), not a
                # pre-exit snapshot from before a reboot or another writer.
                _drop_resume_checkpoints($item, {'volume-settings-verified'=>1});
                return 0 if !_stage($item_number, $item, 'volume-settings-verified', sub {
                    $before_exit = _calibration_settings_boundary($item_number, $item, 'c7', $before_profile_upload);
                    return $before_exit;
                });
                return 0 if _pause_after_checkpoint();
            }
            return 0 if !_stage($item_number, $item, 'session-closed', sub {
                my ($closed, $off, $status, $end) = _close_calibration($item);
                my $end_message = ref($end) eq 'HASH' ? $end->{message} : undef;
                die(($end_message || $::LAST_ERROR || 'LG calibration session could not be closed'))
                    if !$closed;
                my $checked = _calibration_settings_boundary($item_number, $item, 'c8', $before_exit);
                return 0 if !$checked;
                return {%$checked, calibration_status=>$status};
            });
        return 0 if _pause_after_checkpoint();
        if ($stages->{apply_all} && !_enforce_quality($item)) {
            return 0 if !_stage($item_number, $item, 'apply-all-done', sub {
                my $result = _apply_all($item_number, $item);
                die($::LAST_ERROR || 'Apply-to-all failed') if !$result;
                return $result;
            });
        } elsif (!$stages->{apply_all}) {
            _skip_stage($item_number, $item, 'apply-all-done');
        }
    } else {
        foreach my $stage (qw(reset-and-reapply-verified panel-light-settled greyscale-done greyscale-settings-verified volume-done volume-settings-verified session-closed apply-all-done)) {
            _skip_stage($item_number, $item, $stage);
        }
    }
        return 0 if _pause_after_checkpoint();
        if ($stages->{post}) {
        return 0 if !_stage($item_number, $item, 'post-readings-done', sub {
            die($::LAST_ERROR || 'Calibration mode did not close before post-readings')
                if !_ensure_calibration_mode_off($item);
            die('Unable to switch DV to Absolute map') if !_set_dv_map($item, '1');
            my $verified = _read_and_verify_settings($item_number, $item, 'c10')->{verified};
            die($::LAST_ERROR || 'Settings did not verify before post-readings') if !$verified && $verified ne 'unverifiable';
            die($::LAST_ERROR || 'Post-readings failed') if !_run_series($item_number, $item, 'post');
            my $quality = _quality_stage($item_number, $item);
            die($::LAST_ERROR || 'Unable to persist quality results') if ref($quality) ne 'HASH';
            push @{$item->{warnings}}, @{$quality->{warnings} || []} if @{$quality->{warnings} || []};
            return { verified => $verified, quality => $quality };
        });
    } else {
        _skip_stage($item_number, $item, 'post-readings-done');
    }
    return 0 if _pause_after_checkpoint();
    if ($stages->{calibration} && $stages->{apply_all} && _enforce_quality($item)) {
        return 0 if !_stage($item_number,$item,'apply-all-done',sub {
            my $result=_apply_all($item_number,$item);
            die($::LAST_ERROR||'Quality-gated Apply to All Inputs failed') if !$result;
            return $result;
        });
        return 0 if _pause_after_checkpoint();
    }
    my $warnings = ref($item->{warnings}) eq 'ARRAY' && @{$item->{warnings}};
    $item->{status} = $warnings ? 'complete-with-warnings' : 'complete';
    my $complete_checkpoint = _checkpoint_record($item_number, $item, 'item-complete', $warnings ? 'unverifiable' : JSON::PP::true, {
        warnings => $item->{warnings} || [],
    });
    if (!ref($complete_checkpoint)) {
        my $message = $::LAST_ERROR || 'Unable to persist item completion';
        $item->{status} = 'failed';
        $item->{failure} = { stage => 'item-complete', message => $message, at => time() };
        _update_item_snapshot($item_number, $item);
        _update_run(sub {
            my ($run) = @_;
            $run->{status} = 'failed';
            $run->{failure} = $item->{failure};
            $run->{items}[$item_number] = $item if ref($run->{items}) eq 'ARRAY';
        });
        return 0;
    }
    return 0 if !_update_item_snapshot($item_number, $item);
    $ACTIVE_ITEM = undef;
    return 1;
}

# Atomically admit a pending job only from the verified queue revision. This
# closes the edit-vs-claim race after the optimistic check in _main.
sub _claim_queue_item {
    my ($number)=@_;
    my $changed=0;
    my $claimed=_update_run(sub {
        my ($state)=@_;
        if (!defined($state->{preflight_revision}) || $state->{preflight_revision}!=($state->{queue_revision}||0)) {
            $changed=1;return;
        }
        if ($number>=@{$state->{items}}) {$state->{status}='completing';return;}
        my $item=$state->{items}[$number];
        return if ($item->{status}||'') =~ /^complete(?:-with-warnings)?$/;
        # A job that has already run stages carries what those stages measured
        # (the settled panel-light target luminance, the calibration headroom),
        # so its frozen intent hash can never match again. Re-admitting it after
        # a Pause is not a plan change: an operator edit bumps queue_revision,
        # which the check above catches, and the queue editor only offers
        # pending jobs. Verify the TV it was planned for instead, or the reused
        # whole-queue check is thrown away on every Resume (P13).
        my $started=ref($item->{checkpoints}) eq 'ARRAY' && @{$item->{checkpoints}};
        if (!($started ? PGAutomationPlan::identity_matches($item,$item->{preflight_contract})
                       : PGAutomationPlan::matches($item,$item->{preflight_contract}))) {
            delete $state->{preflight_revision};$changed=1;return;
        }
        $state->{active_item}=$number;$item->{status}='running';
    });
    die 'Unable to claim next queue item' if !ref($claimed);
    return ($claimed,$changed);
}

# A claim that fails right after a full preflight means the saved job and its
# plan disagree on disk, not that the operator edited the queue. Allow two
# re-checks per job, then stop: on 16 Sep 2026 the appliance's JSON::PP
# rewrote two numeric recipe values as strings inside the manifest write and
# the runner re-checked the whole queue every seven minutes for an hour.
my %REPLANS;
sub _replan_exhausted {
    my ($index) = @_;
    return ++$REPLANS{$index} > 2 ? 1 : 0;
}

sub _main {
    die "automation store unavailable\n" if !PGAutomation::ensure_store() || !-d $RUN_DIR;
    if (!open($RUNNER_LOCK, '>>', $RUNNER_LOCK_FILE) || !flock($RUNNER_LOCK, LOCK_EX | LOCK_NB)) {
        _log('another automation runner owns the runner lock');
        return;
    }
    # No device API, cleanup, or execution-state write is allowed before the
    # launcher commits this unique attempt. A cancelled/delayed child exits
    # without touching a different run or resurrecting a failed launch.
    # The handshake comes before the manifest is decoded: the launcher's
    # start window must cover interpreter startup only, not a JSON::PP parse
    # of a large run.json on the appliance. The launcher has already verified
    # this token against the manifest and refuses paused or finished runs.
    die "Runner launch was cancelled, expired, or superseded\n"
        if !PGAutomationLaunch::worker_handshake($RUN_ID, $TOKEN, $LAUNCH_ATTEMPT);
    $LAUNCH_ACCEPTED = 1;
    my $run = _run();
    die "run manifest unavailable\n" if ref($run) ne 'HASH' || ($run->{token} || '') ne $TOKEN;
    return if ($run->{status} || '') eq 'paused';
    return if ($run->{status} || '') =~ /^(?:complete(?:-with-warnings)?|failed|stopped)$/;
    _seed_lg_control_seconds($run);
    _heartbeat(1);
    $ETA_HISTORY=eval {PGAutomationETA::history($RUN_ID,sub {_heartbeat();_refresh_control();return !$STOP_REQUESTED;})} || [];
    $ETA_CONTEXT=PGAutomationETA::context($run,$ETA_HISTORY);
    _log_action('Automation runner started');
    if (_control()->{request} eq 'stop') {
        $STOP_REQUESTED = 1;
        my $number = $run->{active_item};
        $number = $number->{item_number} if ref($number) eq 'HASH';
        if (defined($number) && ref($run->{items}[$number]) eq 'HASH') {
            $ACTIVE_ITEM = $run->{items}[$number];
            $ACTIVE_ITEM->{item_number} = $number;
            $ACTIVE_STAGE = $run->{active_stage} || $ACTIVE_ITEM->{active_stage} || '';
            my %workers = ('greyscale-done'=>'grey','volume-done'=>_signal($ACTIVE_ITEM) eq 'dv'?'dv':'3d',
                'pre-readings-done'=>'series','post-readings-done'=>'series');
            $ACTIVE_WORKER = $workers{$ACTIVE_STAGE} || '';
            if (ref($run->{active_series}) eq 'HASH') {
                ($ACTIVE_SERIES_KEY, $ACTIVE_SERIES_PHASE) = @{$run->{active_series}}{qw(key phase)};
            }
        }
        # Retrying a failed safe Pause must not discard its verified progress.
        # The UI still routes cleanup through Stop; its saved terminal intent
        # distinguishes that retry from an ordinary operator Stop.
        my $parking = ($run->{pending_terminal_status}||'') eq 'paused' && $run->{pause_park_pending};
        _stop_active($parking);
        _restore_run_hazards($run, $run->{items});
        _finish($parking ? 'paused' : 'stopped');
        return;
    }
    # A resumed job starts a new device context; prior cleanup policy must
    # not suppress normal completion or explicit Pause restoration.
    if ($run->{stop_restore_policy}) {
        die 'Unable to reset resumed cleanup policy' if !ref(_update_run(sub {delete $_[0]{stop_restore_policy};}));
    }
    my $preflight=_reusable_preflight(_run()) || _preflight_queue();
    if (!$preflight->{ready} || $run->{preflight_only}) {
        _finish($STOP_REQUESTED?'stopped':$preflight->{ready}?'complete':'failed',
            $preflight->{ready}?undef:{stage=>'queue-preflight',message=>$preflight->{message},error_code=>'queue-preflight-blocked'});
        return;
    }
    my $items=_run()->{items}||[];
    my $aborted = 0;
    for (my $i = 0; ; $i++) {
        my $current=_run();
        if (!defined($current->{preflight_revision}) || $current->{preflight_revision}!=($current->{queue_revision}||0)) {
            my $checked=_preflight_queue();
            if (!$checked->{ready}) {
                _finish('failed',{stage=>'queue-preflight',message=>$checked->{message},error_code=>'queue-preflight-blocked'});
                return;
            }
        }
        my ($claimed,$queue_changed)=_claim_queue_item($i);
        if ($queue_changed) {
            if (_replan_exhausted($i)) {
                _finish('failed',{stage=>'queue-preflight',error_code=>'queue-plan-mismatch',
                    message=>'Job '.($i+1).' kept failing to match the plan it had just passed. Stopping rather than re-checking the queue indefinitely; see the activity log.'});
                return;
            }
            $i--;next; # Retry this index after full preflight.
        }
        delete $REPLANS{$i};
        $items = $claimed->{items};
        last if $i >= @$items;
        _refresh_control();
        last if $STOP_REQUESTED;
        my $item = ref($items->[$i]) eq 'HASH' ? $items->[$i] : {};
        next if ($item->{status} || '') =~ /^complete(?:-with-warnings)?$/;
        $::LAST_ERROR = '';
        my $ok = _run_item($i, $item);
        if (!$ok || $STOP_REQUESTED) {
            $aborted = 1 if !$ok;
            last;
        }
        _update_run(sub { $_[0]{items}[$i] = $item; });
    }
    if ($STOP_REQUESTED) {
        _stop_active();
        _restore_run_hazards(_run(), $items);
        _finish('stopped', { stage => $ACTIVE_STAGE || 'unknown', message => 'Automation stopped' });
        return;
    }
    my $latest = _run();
    if (($latest->{status} || '') eq 'paused') {
        return;
    }
    if (($latest->{status} || '') eq 'interrupted') {
        my $failure_stage = ref($latest->{failure}) eq 'HASH' ? ($latest->{failure}{stage} || '') : '';
        _stop_active();
        _restore_run_hazards($latest, $items);
        _park_interrupted($latest->{active_stage} || $failure_stage || 'interrupted');
        return;
    }
    if (($latest->{status} || '') eq 'failed') {
        _stop_active();
        _restore_run_hazards($latest, $items);
        _finish('failed', $latest->{failure});
        return;
    }
    my @unfinished = grep { ref($_) eq 'HASH' && ($_->{status} || '') !~ /^complete(?:-with-warnings)?$/ } @{$latest->{items} || []};
    if ($aborted || @unfinished) {
        # _run_item returned without persisting interrupted/failed (for example
        # a snapshot write failed). Never report that as complete.
        _stop_active();
        _restore_run_hazards($latest, $items);
        _finish('failed', { stage => $ACTIVE_STAGE || 'item', message => $::LAST_ERROR || 'An item stopped without recording its outcome' });
        return;
    }
    _restore_run_hazards($latest, $items);
    _refresh_control();
    if ($STOP_REQUESTED) { _stop_active(); _restore_run_hazards(_run(),$items); _finish('stopped'); return; }
    _update_run(sub {
        my ($state) = @_;
        $state->{active_item} = undef;
        $state->{active_stage} = '';
    });
    my $warned=grep {($_->{status}||'') eq 'complete-with-warnings'} @{$latest->{items}||[]};
    _finish($warned?'complete-with-warnings':'complete');
}

# Guarded so a test can `do` this file (with @ARGV set) and call its subs
# without starting a run; both AutoCal workers and pgenerator-lg do the same.
if (!caller()) {
eval { _main(); 1 } or do {
    my $error = $@ || 'automation runner failed';
    _log($error);
    # A child which never received startup acceptance must not issue Stop,
    # CAL_END, or any other device command as an error-handler side effect.
    exit 1 if !$LAUNCH_ACCEPTED;
    my $run = eval { _run() } || {};
    _stop_active();
    _restore_run_hazards($run, ref($run->{items}) eq 'ARRAY' ? $run->{items} : []);
    my $failure = { stage => $ACTIVE_STAGE || 'startup', message => "$error" };
    $failure->{error_code} = $::LAST_ERROR_CODE if $::LAST_ERROR_CODE;
    # Release the execution claim for every status this runner can die in
    # while it owns the run: 'starting' (a die before the startup update),
    # running, and the completing/stopping tail. A paused or interrupted run
    # is already parked in a resumable state and must stay resumable. Only a
    # manifest carrying our own token is ours to finish.
    _finish('failed', $failure)
        if ref($run) eq 'HASH' && ($run->{token} || '') eq $TOKEN
        && ($run->{status} || '') =~ /^(?:starting|running|completing|stopping)$/;
    exit 1;
};

exit 0;
}
