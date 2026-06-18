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
const llh=worker.slice(worker.indexOf('sub lg_low_light_mode_for_reading'),worker.indexOf('sub lg_low_light_mode_for_reading')+700);
assert(/my \$trigger=\(\$config->\{"low_light"\}\{"trigger"\}\|\|0\)\+0;/.test(llh),'mode helper reads the operator trigger');
assert(/my \$Y=luminance\(\$reading\);/.test(llh),'mode helper uses the MEASURED luminance');
assert(/return \(\$Y < \$trigger\) \? \$mode : "off";/.test(llh),'mode helper arms averaging only below trigger');
// The read payload gates on the armed state, not "enabled" directly.
assert(/if\(\$lg_low_light_active_mode ne "off"\) \{\s*\$payload->\{"low_light"\}=\{ mode => \$lg_low_light_active_mode/.test(worker),'read payload gates low_light on the armed active mode');
// The active mode is recomputed after a successful read.
assert(/\$lg_low_light_active_mode=lg_low_light_mode_for_reading\(\$config,\$reading\);/.test(worker),'worker re-arms the handler from each read result');
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
console.log('autocal low-light handler plumbing regression OK');
