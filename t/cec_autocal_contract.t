#
# Contract: CEC power is advisory, not a reachability gate.
#
# A TV can remain reachable through WebOS while CEC is unknown, stale, or
# reporting standby, so a CEC reading must not decide whether an AutoCal
# request reaches the real transport and picture-setting preflights.
#
# The corollary this file also has to protect: CEC was doing a second,
# unrelated job on the read-only picture-settings poll -- keeping a dark panel
# from occupying the single serialized WebUI worker for a full helper wrapper.
# Dropping the CEC gate is a deliberate design choice; dropping that bound is
# not. See "read-only poll" below.
#
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$FindBin::Bin/lib";
use PGenSource qw(repo_root slurp_source code_only slice_between code_lines_between scan_tree);

my $root=repo_root($Bin);
my $webui=slurp_source($root,"usr/share/PGenerator/webui.pm");
my $lg=slurp_source($root,"usr/share/PGenerator/lg.pm");
my $worker=slurp_source($root,"usr/bin/meter_lg_autocal.pl");

# A CEC power reading, in any of the spellings this codebase uses for one.
my $CEC_POWER=qr/\bcec\b|tv_power|tv_off|powered\s+off|\bstandby\b|powering-o[nf]/i;

#############################################################################
# 1. No launch path gains a preflight of any kind between "is an LG selected"
#    and its existing transport checks.
#
# These assert the FULL expected statement sequence rather than the absence of
# CEC keywords. A keyword blacklist is defeated by naming a gate something
# else -- require_lg_panel_awake() contains no CEC term at all. An exact
# sequence cannot be: any inserted statement fails, whatever it is called.
#
# When a launch path legitimately gains a step, update the expected list here.
# That edit is the point: it forces the change to be deliberate and reviewed.
#############################################################################

my @launch_paths=(
 {
  name     => "browser greyscale AutoCal launch",
  source   => $webui,
  style    => "js",
  start    => qr/if\(!meterAutoCalAvailable\(\)\) return fail\(/,
  end      => qr/if\(!meterEnsureAppliedGeneratorSettings\(\)\)/,
  expected => [
   "meterAutoCalWizardContextActive=true;",
   "if(!(await meterEnsureLgAutoCalTransport(fullWorkflow?'Full Auto Cal':'LG Greyscale Auto Cal'))) return fail('');",
   "if(!meterEnsureLgAutoCalExtendedVideoTransport()) return fail('');",
  ],
 },
 {
  name     => "browser Full AutoCal launch",
  source   => $webui,
  style    => "js",
  start    => qr/if\(!meterFullAutoCalAvailable\(\)\)\{toast\(/,
  end      => qr/if\(!meterEnsureAppliedGeneratorSettings\(\)\)/,
  expected => [
   "if(!(await meterEnsureLgAutoCalTransport('Full Auto Cal'))) return;",
   "if(!meterEnsureLgAutoCalExtendedVideoTransport()) return;",
  ],
 },
 {
  name     => "server AutoCal launch",
  source   => $webui,
  style    => "perl",
  start    => qr/LG 3D LUT AutoCal is already running/,
  end      => qr/&webui_meter_stop\(\);/,
  expected => [],
 },
 {
  name     => "worker AutoCal preflight",
  source   => $worker,
  style    => "perl",
  start    => qr/die "No greyscale steps were supplied"/,
  end      => qr/my \$picture_response=read_initial_picture_settings\(/,
  expected => [
   'my $level_restore_error=restore_factory_levels_for_autocal($config,$state);',
   'die $level_restore_error if($level_restore_error);',
   'my $reset_error=reset_ddc_baseline_for_autocal($config,$state);',
   'die $reset_error if($reset_error);',
   'my $hdr_lum_reset_error=reset_hdr20_luminance_baseline_if_needed($config,$state);',
   'die $hdr_lum_reset_error if($hdr_lum_reset_error);',
  ],
 },
);

foreach my $path (@launch_paths) {
 my $lines=code_lines_between($path->{"source"},$path->{"start"},$path->{"end"},$path->{"style"});
 if(!defined($lines)) {
  fail("$path->{name}: both anchors still present");
  next;
 }
 is_deeply($lines,$path->{"expected"},
  "$path->{name}: reaches its preflights with no interposed check");
}

#############################################################################
# 2. The read-only picture-settings poll does not gate on CEC -- and is still
#    bounded so a dark panel cannot hold the single WebUI worker.
#############################################################################

my $picture_read=slice_between($lg,qr/sub webui_lg_picture_settings \(\@\) \{/,qr/action => "picture_get"/);
ok(defined($picture_read),"picture-settings read: anchors still present");

SKIP: {
 skip "picture-settings read not locatable",4 if(!defined($picture_read));
 my $code=code_only($picture_read,"perl");
 unlike($code,$CEC_POWER,"picture-settings read is not short-circuited by a CEC power reading");

 # Name-independent form of the same contract: this handler reaches the helper
 # through exactly four early returns -- the PIN-pairing guard and the three
 # "Connect the LG TV" guards. Any interposed gate adds a fifth, whatever it
 # is called and whether or not it mentions CEC.
 my $returns=()=($code=~/^\s*return\b/mg);
 is($returns,4,"picture-settings read still has exactly its four pairing/connection guards");

 # The regression this bound exists to prevent: /api/lg/picture-settings is on
 # the general WebUI lane, which is one serialized worker, and lg_helper_run is
 # a synchronous backtick. A powered-off panel drops SYNs rather than refusing,
 # so an unbounded read parks that worker for ~20s per poll against a ~30s
 # panel refresh. A healthy read answers in under a second.
 my ($default)=($code=~/\$helper_timeout\s*=\s*(\d+)\s*if\(\s*\$helper_timeout\s*<=\s*0\s*\)/);
 ok(defined($default),"picture-settings read applies a default helper timeout when the caller sends none");
 cmp_ok($default||0,"<=",20,"that default keeps the serialized WebUI worker bounded");
}

# A helper timeout equal to the browser timeout is not genuinely bounded from
# the caller's point of view: the outer fetch wins the race before the helper's
# timeout response can traverse the daemon. Keep a small response margin.
my @bounded_browser_reads=(
 ["display-control refresh",$lg,qr/async function lgDisplayControlRefresh\(force\)/,qr/async function lgDisplayControlCommit\(key\)/],
 ["AutoCal clip-control refresh",$webui,qr/async function meterAutoCalLoadClipControls\(\)/,qr/async function meterAutoCalWriteClipControl\(key,value,pictureMode\)/],
);
foreach my $case (@bounded_browser_reads) {
 my ($name,$source,$start,$end)=@$case;
 my $region=slice_between($source,$start,$end);
 ok(defined($region),"$name: caller is locatable");
 next if(!defined($region));
 my ($helper)=($region=~/helper_timeout\s*:\s*(\d+)/);
 my ($fetch)=($region=~/_timeoutMs\s*:\s*(\d+)/);
 ok(defined($helper) && defined($fetch) && ($helper*1000)<$fetch,
  "$name: helper deadline leaves time for the HTTP response");
}

#############################################################################
# 3. lg_helper_timeout behaviour, executed rather than grepped.
#
# The sub is pure, so it can be lifted into a sandbox package and called. This
# is the only part of this file that tests behaviour instead of text.
#############################################################################

my ($timeout_src)=($lg=~/(sub lg_helper_timeout \(\@\) \{.*?\n\})/s);
ok(defined($timeout_src),"lg_helper_timeout source is extractable");

SKIP: {
 skip "lg_helper_timeout not extractable",5 if(!defined($timeout_src));
 my $ok=eval "package PGenTimeoutSandbox; $timeout_src; 1";
 ok($ok,"lg_helper_timeout evaluates in isolation") or diag($@);
 skip "lg_helper_timeout did not compile",4 if(!$ok);

 is(PGenTimeoutSandbox::lg_helper_timeout({action=>"picture_get"}),60,
  "picture_get keeps its 60s budget for callers that do not bound themselves");
 is(PGenTimeoutSandbox::lg_helper_timeout({action=>"picture_get",helper_timeout=>8}),8,
  "an explicit helper_timeout overrides the per-action budget");
 is(PGenTimeoutSandbox::lg_helper_timeout({action=>"3d_lut_upload"}),180,
  "long-running panel writes keep their generous budgets");
 is(PGenTimeoutSandbox::lg_helper_timeout({action=>"something_new"}),90,
  "an unrecognised action falls back to the default budget");
}

#############################################################################
# 4. The removed helpers are gone from the whole tree, not just three files.
#
# This is the one grep-shaped assertion with no rename escape hatch: paired
# with t/00-compile.t, "this identifier appears nowhere" cannot be satisfied by
# renaming, because a renamed caller of a deleted sub still has to compile.
#############################################################################

my @removed=qw(
 lg_tv_off_gate
 lg_tv_powered_off
 lg_cec_power_state_cached
 lg_calibration_run_active
 LG_CEC_POWER_CACHE_FILE
 LG_TV_OFF_GATE_MAX_AGE
 verify_lg_tv_power_for_autocal
 meterEnsureLgTvReadyForAutoCal
);

my %orphans=map { $_ => [] } @removed;
scan_tree($root,"usr",sub {
 my ($relative,$contents)=@_;
 # Comments first, in both styles: this tree keeps its browser JS inside Perl
 # strings, so a single file can carry either. A comment naming a helper that
 # was removed is documentation, not a dangling caller, and must not fail.
 my $code=code_only(code_only($contents,"perl"),"js");
 foreach my $symbol (@removed) {
  push(@{$orphans{$symbol}},$relative) if($code=~/\Q$symbol\E/);
 }
});

foreach my $symbol (@removed) {
 is(scalar(@{$orphans{$symbol}}),0,"$symbol has no remaining references under usr/")
  or diag("still referenced in: ".join(", ",@{$orphans{$symbol}}));
}

#############################################################################
# 5. CEC survives as an integration. Status display, explicit controls,
#    discovery and HDMI input selection stay useful even though they no longer
#    gate anything.
#############################################################################

like($webui,qr/sub webui_cec \(\@\)/,"CEC API remains available");
like($webui,qr/async function cecCmd\(cmd\)/,"CEC controls remain available in the browser");
like($lg,qr/sub lg_cec_status \(\@\)/,"LG status still exposes CEC information");
like($lg,qr/tv_input\s*=>\s*&lg_input_from_cec\(\)/,"LG requests still use CEC-derived HDMI input information");

done_testing();
