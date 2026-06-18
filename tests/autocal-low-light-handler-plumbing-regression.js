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
console.log('autocal low-light handler plumbing regression OK');
