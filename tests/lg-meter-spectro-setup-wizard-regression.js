const assert = require('assert');
const fs = require('fs');

const session = fs.readFileSync('usr/bin/meter_session.sh', 'utf8');
const series = fs.readFileSync('usr/bin/meter_series.sh', 'utf8');
const webui = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');
const ccss = fs.readFileSync('usr/bin/ccss_create.py', 'utf8');

// --- Behavior mirror of the step-ID ack protocol -----------------------------
// The session advances only when the acked id equals the current step id;
// stale/duplicate acks are discarded and the wait continues.
function makeStepWaiter() {
  let currentId = 0;
  let ackFile = null; // contents of /tmp/meter_session.ack, or null when absent
  return {
    present(/* step, message */) { currentId += 1; ackFile = null; return currentId; },
    writeAck(id) { ackFile = String(id); },
    // returns true once a matching ack arrives; false while still waiting
    poll() {
      if (ackFile == null) return false;
      const acked = ackFile.replace(/[^0-9]/g, '');
      ackFile = null;               // consumed (rm -f)
      return acked === String(currentId);
    },
  };
}

const w = makeStepWaiter();
const id1 = w.present('calibrate_tile', 'Place on tile');
assert.strictEqual(w.poll(), false, 'no ack yet -> keep waiting');
w.writeAck(id1 - 1);                       // stale ack for a previous step
assert.strictEqual(w.poll(), false, 'stale ack ignored');
w.writeAck(id1);                           // correct ack
assert.strictEqual(w.poll(), true, 'matching ack advances');
const id2 = w.present('position_screen', 'Aim at screen');
assert.strictEqual(id2, id1 + 1, 'step id is monotonic');
w.writeAck(id1);                           // duplicate of the passed step
assert.strictEqual(w.poll(), false, 'duplicate ack for passed step ignored');

// --- Source-slice: the session implements await_setup_step with id matching ---
assert(session.includes('ACK_FILE="/tmp/meter_session.ack"'), 'ack file path defined');
assert(session.includes('await_setup_step()'), 'await_setup_step defined');
assert(
  session.includes('SETUP_STEP_ID=$((SETUP_STEP_ID + 1))') &&
    session.includes('\\"status\\":\\"setup\\",\\"step_id\\"') &&
    session.includes('[ "$acked" = "$sid" ] && break'),
  'await_setup_step emits a setup state and advances only on a matching id'
);

// Calibrate step is surfaced through the step-ID protocol during init.
assert(
  session.includes('await_setup_step "calibrate_tile"'),
  'init surfaces calibrate_tile via await_setup_step'
);
// A spectro is positioned once after init, not per read.
assert(
  session.includes('await_setup_step "position_screen"'),
  'position_screen is a one-time post-init step'
);
// Calibration failure is surfaced as a retry step, not a silent loop.
assert(
  session.includes('await_setup_step "calibrate_retry"'),
  'calibration failure surfaces calibrate_retry'
);
// The per-read position prompt is gone (positioning is one-time).
assert(
  !session.includes('wait_for_device_ready "initial_measurement"'),
  'no per-read initial_measurement prompt remains'
);

assert(webui.includes('$_meter_session_ack_file="/tmp/meter_session.ack"'), 'ack file var defined in webui');
assert(webui.includes('sub webui_meter_setup_ack'), 'setup ack sub defined');
assert(
  webui.includes('"/api/meter/setup/ack"') && webui.includes('&webui_meter_setup_ack('),
  'setup ack route wired'
);

assert(webui.includes('id="meterSpectroSetupModal"'), 'setup modal markup present');
assert(webui.includes('id="meterSpectroSetupBtn"') && webui.includes('onclick="meterSpectroSetupAck()"'), 'setup modal action button wired');

// Per-step button label mapping (mirror).
function setupBtnLabel(step) {
  return ({calibrate_tile:'Calibrate', position_screen:'Ready', calibrate_retry:'Retry'})[step] || 'Continue';
}
assert.strictEqual(setupBtnLabel('calibrate_tile'), 'Calibrate');
assert.strictEqual(setupBtnLabel('position_screen'), 'Ready');
assert.strictEqual(setupBtnLabel('calibrate_retry'), 'Retry');
assert.strictEqual(setupBtnLabel('whatever'), 'Continue');

// Source-slices for the wizard JS.
assert(webui.includes('function meterSpectroSetupApply'), 'setup apply fn present');
assert(webui.includes('function meterSpectroSetupAck'), 'setup ack fn present');
assert(webui.includes("'/api/meter/setup/ack'"), 'ack fn posts the endpoint');
assert(webui.includes("meterSpectroSetupApply(r,'/api/meter/setup/ack')"), 'read poll feeds setup state to the wizard');
assert(
  webui.includes('function meterSeriesSpectroSetupApplyFromStatus') &&
    webui.includes("String(r.status||'').toLowerCase()==='setup'") &&
    webui.includes("meterSpectroSetupApply(r,'/api/meter/series/ready')") &&
    webui.includes("meterSpectroSetupApply({keepBusy:true,message:r.message},'/api/meter/series/ready')") &&
    webui.includes("meterSpectroSetupApply(setup,'/api/meter/series/ready')") &&
    webui.includes('meterSeriesSpectroSetupApplyFromStatus(r);'),
  'Read Series should map spectro setup, setup-busy, and awaiting-ready states into the shared setup wizard'
);
assert(
  webui.includes('!meterSeriesSpectroSetupActive') &&
    webui.includes('const readyVisible=meterSeriesAwaitingReady&&meterSelectedMeasurementRequiresReady()&&!meterSeriesSpectroSetupActive;'),
  'legacy Device Ready button should be hidden while the series spectro wizard is active'
);
assert(
  webui.includes("meterSpectroSetupAckEndpoint==='/api/meter/series/ready'||meterSeriesSpectroSetupActive") &&
    webui.includes('await meterStop();') &&
    webui.includes("if(!meterSeriesRunning&&r.status!=='cleared')"),
  'cancelling the series spectro setup popup should stop polling before stale setup status can reopen it'
);
assert(
  webui.includes('async function meterStop()') &&
    webui.includes("await fetchJSON('/api/meter/stop'") &&
    webui.includes('meterActionPending=hadSeriesStop||hadContinuousStop'),
  'explicit Stop should wait for backend cleanup before re-enabling Read Series'
);
assert(
  webui.includes('"status"\\s*:\\s*"(?:running|setup)"') &&
    webui.includes('"status":"cancelled"') &&
    webui.includes('"awaiting_ready"\\s*:\\s*true') &&
    webui.includes('"awaiting_ready_reason"\\s*:\\s*"[^"]*"'),
  'backend meter stop should cancel setup-state series and remove ready prompts'
);
assert(
  !webui.includes('!r.awaiting_ready||!meterSelectedMeasurementRequiresReady()'),
  'series backend wait states should not be hidden by stale client-side meter classification'
);
assert(
  series.includes('series_setup_step()') &&
    series.includes('STOP_FILE="/tmp/meter_series_stop_${SERIES_ID}.signal"') &&
    series.includes('series_stop_requested()') &&
    series.includes('series_cancel_exit()') &&
    series.includes('series_stop_requested && series_cancel_exit') &&
    series.includes('spectrophotometer selected: skipping CCSS') &&
    series.includes('&& "$REQUIRE_DEVICE_READY" != "1"') &&
    series.includes('series_setup_step "calibrate_tile"') &&
    series.includes('series_setup_step "position_screen"') &&
    series.includes('series_setup_step "calibrate_retry"') &&
    series.includes('"awaiting_ready":true,"awaiting_ready_reason":"$ready_reason"') &&
    series.includes('NEW_OUT=$(clean_output_since "$HANDLED_OFFSET")') &&
    series.includes('INITIAL_READY_PENDING=0'),
  'meter_series should surface spectro startup calibration and screen-positioning through setup states'
);
assert(
  webui.includes('$_meter_series_stop_glob="/tmp/meter_series_stop_*.signal"') &&
    webui.includes('sub webui_meter_series_pids') &&
    webui.includes('(?:^|\\0)\\/usr\\/bin\\/meter_series\\.sh(?:\\0|$)') &&
    webui.includes('sub webui_meter_series_signal_stop') &&
    webui.includes('&webui_meter_series_signal_stop();') &&
    webui.includes('sub webui_meter_series_kill') &&
    webui.includes('sub webui_meter_series_cancel_state') &&
    webui.includes('my $series_id="${type}_".int(Time::HiRes::time()*1000)."_".int(rand(1000000));'),
  'backend meter stop should signal the active series to quit cleanly and use collision-resistant series ids'
);
assert(
  webui.includes('sub webui_meter_port_is_spectro') &&
    webui.includes('$require_device_ready=1 if(!$require_device_ready && &webui_meter_port_is_spectro($measurement_meter_port));'),
  'backend should force the setup workflow when a series/read request targets a known spectro port'
);
assert(
  webui.includes('$json=~/"awaiting_ready"\\s*:\\s*true/i || $json=~/"status"\\s*:\\s*"setup"/i'),
  'series ready endpoint should accept setup-state wizard acks as well as legacy awaiting-ready prompts'
);

// --- Create-Custom-CCSS reuse of the same step-ID wizard ---------------------
// The CCSS-create runner surfaces the same setup steps via await_setup_step.
assert(ccss.includes('def await_setup_step'), 'ccss_create defines await_setup_step');
assert(
  ccss.includes('self.setup_step_id += 1') &&
    ccss.includes('"setup"') &&
    ccss.includes('step_id=sid'),
  'await_setup_step emits a numbered setup state'
);
assert(ccss.includes('"calibrate_tile"'), 'ccss_create surfaces calibrate_tile step');
assert(ccss.includes('"position_screen"'), 'ccss_create surfaces position_screen step');
assert(ccss.includes('"calibrate_retry"'), 'ccss_create surfaces calibrate_retry step');
// Positioning is one-time: only the first screen prompt becomes a step.
assert(ccss.includes('self.positioned'), 'ccss_create gates position_screen to a one-shot flag');
// The single-button awaiting_continue scheme is gone.
assert(!ccss.includes('awaiting_continue'), 'old single Continue scheme removed from ccss_create');

// webui ack endpoint + route + shared-modal wiring for CCSS create.
assert(webui.includes('sub webui_ccss_create_setup_ack'), 'ccss create setup ack sub defined');
assert(
  webui.includes('"/api/ccss/create/setup/ack"') && webui.includes('&webui_ccss_create_setup_ack('),
  'ccss create setup ack route wired'
);
// CCSS runs the wizard INSIDE its own modal (single popup), acking via a
// dedicated handler -- it must NOT reuse the shared spectro setup popup.
assert(
  webui.includes('async function meterCcssCreateSetupAck(') &&
    webui.includes("fetchJSON('/api/ccss/create/setup/ack'"),
  'CCSS setup ack handled in-modal via meterCcssCreateSetupAck'
);
assert(
  !webui.includes("meterSpectroSetupApply(r,'/api/ccss/create/setup/ack')"),
  'CCSS does not overlay the shared spectro setup popup'
);

console.log('Spectro setup wizard regression checks passed.');
