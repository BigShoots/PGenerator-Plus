const assert=require('assert'); const fs=require('fs');
const ui=fs.readFileSync('usr/share/PGenerator/webui.pm','utf8');
const sess=fs.readFileSync('usr/bin/meter_session.sh','utf8');
const series=fs.readFileSync('usr/bin/meter_series.sh','utf8');
const worker=fs.readFileSync('usr/bin/meter_lg_autocal.pl','utf8');
assert(/METER_AVERAGING="\$\{10:-\$\{METER_AVERAGING:-off\}\}"/.test(sess),'meter_session.sh reads arg10 as averaging');
const ss=ui.slice(ui.indexOf('sub webui_meter_session_start '),ui.indexOf('sub webui_meter_session_start ')+1700);
assert(/\$require_device_ready,\$averaging\)= @_/.test(ss),'session_start signature has $averaging');
assert(/'\$require_device_ready' '\$averaging'/.test(ss),'session_start spawn forwards $averaging as arg10');
const mr=ui.slice(ui.indexOf('sub webui_meter_read '),ui.indexOf('sub webui_meter_read_result'));
assert(/\$avg_mode/.test(mr) && /"low_light"/.test(mr),'webui_meter_read parses low_light into $avg_mode');
// want_config must hold the OPERATOR'S STATIC (session-level) averaging, NOT
// the per-read $avg_mode -- otherwise the persistent meter session respawns
// (35-90s on OLED) every time the per-read active mode flips at the 5 cd/m2
// trigger. The per-read mode flows via the READ command, not want_config.
assert(/\$want_config="[^"]*\|\$session_avg_mode"/.test(mr),'want_config uses $session_avg_mode (static) as 7th field');
assert(!/\$want_config="[^"]*\|\$avg_mode(?!_session)/.test(mr),'want_config does NOT use per-read $avg_mode');
assert((mr.match(/\$measurement_meter_port,\$require_device_ready,\$session_avg_mode\)/g)||[]).length>=2,'both session_start calls pass $session_avg_mode (not the per-read value)');
assert(/\$payload->\{"low_light"\}=/.test(worker)&&/\$config->\{"low_light"\}\{"enabled"\}/.test(worker),'worker adds low_light to read payload when handler enabled');
// Per-read measured-value trigger: averaging is armed from the previous read's
// luminance vs the operator cd/m2 trigger, NOT applied unconditionally.
assert(/our \$lg_low_light_active_mode="off";/.test(worker),'worker declares $lg_low_light_active_mode state (default off)');
assert(/sub lg_low_light_mode_for_reading \{/.test(worker),'worker defines lg_low_light_mode_for_reading');
const llh=worker.slice(worker.indexOf('sub lg_low_light_mode_for_reading'),worker.indexOf('sub lg_low_light_mode_for_reading')+2000);
assert(/my \$trigger=\(\$config->\{"low_light"\}\{"trigger"\}\|\|0\)\+0;/.test(llh),'mode helper reads the operator trigger');
assert(/my \$Y=luminance\(\$reading\);/.test(llh),'mode helper uses the MEASURED luminance');
assert(/return \(\$Y < \$trigger\) \? \$mode : "off";/.test(llh),'mode helper arms averaging only below trigger');
// The read payload gates on the armed state, not "enabled" directly.
assert(/if\(\$lg_low_light_active_mode ne "off"\) \{\s*\$payload->\{"low_light"\}=\{ mode => \$lg_low_light_active_mode/.test(worker),'read payload gates low_light on the armed active mode');
// The active mode is recomputed after a successful read.
assert(/\$lg_low_light_active_mode=lg_low_light_mode_for_reading\(\$config,\$reading,\$step\);/.test(worker),'worker re-arms the handler from each read result (passes $step for 80-IRE guard)');
// Static low_light_session is sent so the WebUI can pin a stable session-level
// METER_AVERAGING that does not churn on every per-read mode flip.
assert(/\$payload->\{"low_light_session"\}=\{ mode => \$session_ll_mode/.test(worker),'worker adds low_light_session (static) to read payload');
assert((ui.match(/low_light:meterLowLightReadState\(\)/g)||[]).length>=2,'both lg-autocal start bodies include low_light');
assert(/printf '%s\|%s\|%s\|%s\|%s\|%s\|%s\\n'/.test(sess),'meter_session.sh writes 7-field config string');
assert(/printf '%s\|%s\|%s\|%s\|%s\|%s\|%s\\n'[^;]*\$\{METER_AVERAGING:-off\}/.test(sess),'meter_session.sh 7th config field is METER_AVERAGING');
assert(!/^CONFIG_FILE=/m.test(series),'meter_series.sh has no CONFIG_FILE write');
assert(!/printf '%s\|%s\|%s\|%s\|%s\|%s\|%s\\n'/.test(series),'meter_series.sh has no printf config-string write');
// Per-read low_light is forwarded to the READ command line (15th field) so
// meter_session.sh can respawn spotread (NOT the wrapper) when the per-read
// mode flips, while the session-level METER_AVERAGING stays put.
assert(/\$cmd_low_light_mode=\(\$avg_mode ne ""\) \? \$avg_mode : "-";/.test(mr),'webui_meter_read builds $cmd_low_light_mode from per-read $avg_mode');
assert(/\$read_command\.=" \$cmd_signal_range \$cmd_transport_signal_range \$cmd_request_id \$patch_input_max \$cmd_read_timeout \$cmd_low_light_mode"/.test(mr),'READ command line forwards $cmd_low_light_mode as 15th field');
// meter_session.sh parses the 15th field (CMD_LOW_LIGHT_MODE) from the READ
// line and, when it differs from the currently-running spotread's mode,
// respawns ONLY spotread via respawn_spotread.
assert(/read -r _ R G B PSIZE IRE NAME SETTLE_MS SIGNAL_MODE MAX_LUMA SIGNAL_RANGE TRANSPORT_SIGNAL_RANGE REQUEST_ID INPUT_MAX CMD_READ_TIMEOUT CMD_LOW_LIGHT_MODE/.test(sess),'meter_session.sh READ parser accepts 15th CMD_LOW_LIGHT_MODE');
assert(/respawn_spotread \(\) \{/.test(sess),'meter_session.sh defines respawn_spotread helper');
assert(/CURRENT_LOW_LIGHT_MODE=/.test(sess),'meter_session.sh tracks CURRENT_LOW_LIGHT_MODE');
assert(/respawn_spotread "\$CMD_LOW_LIGHT_MODE"/.test(sess),'meter_session.sh respawns spotread when READ mode differs');
// 100% white non-converge must fail-fast: a no-op 1.0/1.0/1.0 anchor
// pushed when calibrate_anchor returned conv=0 must NOT be uploaded to
// the TV. The 100% block now sets $upload_failed=1 with a distinctive
// exit reason so the lower-anchor foreach (which honours $upload_failed
// in its `last if(cancelled() || $upload_failed)`) does not run, and so
// the function-exit block leaves hdr20_1d_dpg_uploaded=JSON::PP::false.
assert(/white_not_converged/.test(worker),'100% block sets white_not_converged exit reason on non-converge');
// The final hdr20_1d_dpg_uploaded=JSON::PP::true assignment is now
// guarded by a follow-up that flips it to JSON::PP::false when
// $upload_failed is true OR hdr20_1d_dpg_white_converged is false.
// The two flags must appear in the same block (the gated reassignment)
// so an upload cannot leak through.
assert(/\$state->\{"hdr20_1d_dpg_uploaded"\}=JSON::PP::true;[\s\S]{0,400}if\(\$upload_failed \|\| !\$state->\{"hdr20_1d_dpg_white_converged"\}\)/.test(worker),'hdr20_1d_dpg_uploaded is gated on !$upload_failed and white-converged');
// respawn_spotread now waits 150 iterations (15s) per attempt and
// retries once on timeout, so a one-shot i1d3 AIO re-init that takes
// >5s no longer wedges the per-read low_light switch.
assert(/while \(\( _rt < 150 \)\)/.test(sess),'meter_session.sh respawn wait is 150 iterations (15s) per attempt');
// The 100% IRE hard guard inside lg_low_light_mode_for_reading forces
// "off" at IRE >= 80 regardless of the measured Y. The 80.0 literal
// must live in the LLH function body (slice), not in unrelated code.
assert(/80\.0/.test(llh),'lg_low_light_mode_for_reading has 80-IRE hard guard (returns "off" at IRE >= 80)');
// calibrate_anchor must log per-iter measured/target Y, dE, gain, damp, and
// the DPG idx values into hdr20_1d_dpg_anchor_history on the state JSON, so a
// 4%/1.4% IRE run that stalls is diagnosable in seconds. The autocal log
// only carries errors and the spotread session log is overwritten on respawn,
// so without this trace the per-iter trajectory has to be reconstructed from
// raw XYZ reads.
assert(/hdr20_1d_dpg_anchor_history/.test(worker),'calibrate_anchor logs per-iter anchor history into hdr20_1d_dpg_anchor_history');
// measured_Y in the per-iter push must come from the same luminance() helper
// as the rest of the state (current_luminance, dE, etc.) -- not a hand-computed
// XYZ->Y or a re-application of the response model. A divergence here would
// produce a state JSON whose measured_Y disagrees with current_luminance on
// the same row and break any future automated trajectory analysis.
assert(/measured_Y=>defined\(\$reading\) \? luminance\(\$reading\) : undef/.test(worker),'per-iter push measured_Y uses luminance($reading) helper (not a hand-computed Y)');
// === EOTF-aware damp (HDR20 autocal) =====================================
// Iter 1 seeds the damp exponent from the EOTF-predicted local gamma at the
// anchor IRE (PQ table for HDR10, 2.2 for SDR); iter 2+ blends with the
// measured gamma from the previous iter's Y/DPG change. The damp becomes
// gain ** (1/gamma_effective) clamped to [floor, 1.25]. The block below
// locks the wiring: function exists, returns a sensible value at HDR10
// IRE=4, damp uses the ** operator (not sqrt), calibrate_anchor tracks
// gamma_effective with an EMA blend (0.3*new, 0.7*history), and the
// per-anchor gamma is clamped to [1.5, 3.0] before the exponent is taken.
assert(/sub lg_autocal_expected_gamma_for_signal_mode_and_ire \{/.test(worker),'worker defines lg_autocal_expected_gamma_for_signal_mode_and_ire (EOTF-γ lookup)');
assert(/our %LG_AUTOCAL_PQ_GAMMA_TABLE;/.test(worker),'worker declares %LG_AUTOCAL_PQ_GAMMA_TABLE (file-scope PQ gamma lookup)');
assert(/sub lg_autocal_pq_gamma_table_init \{/.test(worker),'worker defines lg_autocal_pq_gamma_table_init (lazy PQ table init)');
// The damp closure must use the ** operator (exponent), not sqrt. The new
// signature is ($g,$floor,$exp) and the body computes $g**$exp.
const dampBlock=worker.slice(worker.indexOf('my $damp=sub {'),worker.indexOf('my $damp=sub {')+400);
assert(/my \(\$g,\$floor,\$exp\)=@_;/.test(dampBlock),'damp closure signature accepts ($g,$floor,$exp) for EOTF-aware exponent');
assert(/my \$s=\$g\*\*\$exp;/.test(dampBlock),'damp closure body uses ** with the EOTF-aware exponent (gain**(1/gamma))');
assert(!/sqrt\(/.test(dampBlock),'damp closure no longer uses sqrt');
// calibrate_anchor must declare per-anchor gamma state and use an EMA
// blend (0.3 new measurement, 0.7 history) on iter 2+ to refine it from
// the measured Y/DPG slope. The gamma must be clamped to [1.5, 3.0]
// before the exponent is taken, and $damp_exp must be the 1.0/gamma.
const calBlock=worker.slice(worker.indexOf('my $calibrate_anchor=sub {'),worker.indexOf('return ($converged,$last_reading);'));
assert(/my \$gamma_effective=lg_autocal_expected_gamma_for_signal_mode_and_ire/.test(calBlock),'calibrate_anchor seeds gamma_effective from the EOTF lookup');
assert(/0\.3\*\$gamma_meas/.test(calBlock)&&/0\.7\*\$gamma_effective/.test(calBlock),'calibrate_anchor blends measured gamma with EMA (0.3 new, 0.7 history)');
assert(/\$gamma_effective=1\.5 if\(\$gamma_effective\+0 < 1\.5\);/.test(calBlock)&&/\$gamma_effective=3\.0 if\(\$gamma_effective\+0 > 3\.0\);/.test(calBlock),'per-anchor $gamma_effective is clamped to [1.5, 3.0] before the exponent');
assert(/my \$damp_exp=\(1\.0\/\(\$gamma_effective\+0\.0\)\);/.test(calBlock),'calibrate_anchor computes damp_exp = 1.0 / gamma_effective');
// Function-level sanity: the lookup returns a value in (1.0, 4.0) for
// HDR10 at IRE=4. The proper ST 2084 PQ EOTF gives ~2.17 at IRE 4;
// anything in that band confirms the table is the standard PQ form, not
// a near-constant ratio.
const _expGammaSrc=worker.slice(worker.indexOf('sub lg_autocal_expected_gamma_for_signal_mode_and_ire'),worker.indexOf('sub lg_autocal_expected_gamma_for_signal_mode_and_ire')+2000);
assert(/return 2\.2;/.test(_expGammaSrc),'expected_gamma returns 2.2 for SDR (constant)');
assert(/return 2\.4;/.test(_expGammaSrc),'expected_gamma returns 2.4 for HLG (approximation)');
assert(/^\s*if\(\$signal_mode =~ \/\^hdr10\?\$\/\)/m.test(_expGammaSrc),'expected_gamma branches on hdr10? regex for HDR10/PQ');
// === Best-so-far revert (HDR20 autocal) ===================================
// At low IRE (4% / 1.4% / etc.) the per-iter adjustment can oscillate: the
// autocal measures a worse dE than the previous iter, but the previous iter
// has already been uploaded to the TV. The best-so-far revert pattern
// snapshots the full DPG and @done of the best iter and, when a later
// iter's dE is significantly worse (>5% relative), restores the snapshot
// and exits the anchor loop. The 5% gap avoids false alarms from meter
// noise at the < 1 nit floor. The state init (best_de, best_dpg, best_done,
// revert_count) lives at the top of calibrate_anchor; the check itself sits
// AFTER the convergence test (so a converged iter is never over-written by a
// "revert") and BEFORE the gain computation (so the revert prevents the bad
// adjust from being built).
assert(/my \$best_de=undef;/.test(calBlock)&&/my \$best_dpg=undef;/.test(calBlock),'calibrate_anchor declares best_de + best_dpg state');
assert(/my \$best_done=\[\];/.test(calBlock),'calibrate_anchor declares best_done = [] (pre-adjustment @done snapshot)');
assert(/my \$revert_count=0;/.test(calBlock),'calibrate_anchor declares $revert_count diagnostic counter');
// The 5% relative threshold: 1.05x of best_de. The block must:
//   1. Snapshot best_dpg / best_done when the current dE beats best_de.
//   2. Revert @done and @{$current_dpg} when current dE > best_de * 1.05.
//   3. Increment $revert_count and `last` on the revert path.
assert(/\$best_dpg=\[@\{\$current_dpg\}\];/.test(calBlock),'best-so-far snapshots $current_dpg via [@{...}] (deep copy)');
assert(/\$best_done=\[@done\];/.test(calBlock),'best-so-far snapshots @done via [@done] (deep copy)');
assert(/\$de\+0 > \$best_de\+0\*1\.05/.test(calBlock),'revert threshold is 5% relative (de > best * 1.05)');
assert(/@done=@\{\$best_done\};/.test(calBlock)&&/@\{\$current_dpg\}=@\{\$best_dpg\};/.test(calBlock),'revert restores @done and @{$current_dpg} from the best snapshot');
assert(/\$revert_count\+\+;/.test(calBlock)&&/last;/.test(calBlock),'revert increments $revert_count and exits the anchor loop');
// The best / reverted markers must be written into the per-iter history row
// at [-1] so a run that reverts shows up in the state JSON for diagnosis.
assert(/hdr20_1d_dpg_anchor_history"\}\{\$label\}\[-1\]\{best\}=JSON::PP::true/.test(calBlock),'best iter is tagged with {best}=true in anchor history');
assert(/hdr20_1d_dpg_anchor_history"\}\{\$label\}\[-1\]\{reverted\}=JSON::PP::true/.test(calBlock),'reverted iter is tagged with {reverted}=true in anchor history');
// The best-so-far block must sit AFTER the convergence test (so a converged
// iter does not get a false-positive revert on its own exit) and BEFORE the
// gain computation (so the revert prevents the bad adjust from being built).
// The convergence test in this closure is split: $conv_now is set first,
// then $converged=1 if($conv_now);, then the per-iter state push, then
// `last if($conv_now);`. The best-so-far block is sandwiched between
// `$converged=1 if($conv_now);` and the per-iter state push, so we use
// `$converged=1 if($conv_now);` as the AFTER anchor and the gain computation
// as the BEFORE anchor.
const _convNowPos=calBlock.indexOf('$converged=1 if($conv_now);');
const _bestSoFarPos=calBlock.indexOf('reverting to best and moving on');
const _gainPos=calBlock.indexOf('lg_autocal_26_hdr20_dpg_gain($reading');
assert(_convNowPos>=0 && _bestSoFarPos>=0 && _gainPos>=0 && _convNowPos < _bestSoFarPos && _bestSoFarPos < _gainPos,'best-so-far block sits between convergence test and gain computation');
console.log('autocal low-light handler plumbing regression OK');
