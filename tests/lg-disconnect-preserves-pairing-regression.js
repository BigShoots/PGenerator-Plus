const assert = require('assert');
const fs = require('fs');

const lg = fs.readFileSync('usr/share/PGenerator/lg.pm', 'utf8');
const webui = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');

assert(
  lg.includes('sub lg_mark_disconnected') &&
    lg.includes('$clients->{"disconnected"}=&lg_json_true();') &&
    lg.includes('$clients->{"disconnected_at"}=time();') &&
    !lg.includes('delete($clients->{"client_key"});'),
  'Disconnect should preserve the saved LG client key while marking a local disconnected state'
);

assert(
  lg.includes('delete($clients->{"disconnected"});') &&
    lg.includes('delete($clients->{"disconnected_at"});'),
  'A successful LG connect or PIN pairing should clear the local disconnected state'
);

assert(
  lg.includes('connected => &lg_json_bool($connected)') &&
    lg.includes('disconnected => &lg_json_bool($disconnected)') &&
    lg.includes('client_key_present => &lg_json_bool(($client_key ne "") && !$pin_pending)'),
  'LG status should expose saved-pairing and connected/disconnected state separately'
);

assert(
  lg.includes('if($path eq "/api/lg/disconnect" && $method eq "POST")') &&
    lg.includes('return &webui_lg_disconnect();') &&
    lg.includes('id="lgDisconnectBtn"') &&
    lg.includes("fetchJSON('/api/lg/disconnect'"),
  'Display card should expose a Disconnect action routed to /api/lg/disconnect'
);

assert(
  lg.includes('function lgStatusConnected(state)') &&
    lg.includes('return !!(lgStatusHasSavedKey(state)&&!state.pinPending&&!state.disconnected);') &&
    lg.includes('function lgDisplayControlConnected()') &&
    lg.includes('return lgStatusConnected(state);'),
  'Frontend LG controls should depend on connected state, not merely a saved key'
);

assert(
  lg.includes('calibrationMode.disabled=lgCalibrationModePending||pinPending||!connected;') &&
    lg.includes('resetButtons.forEach(button=>{button.disabled=pinPending||!connected||lgPictureModePending||lgCalibrationModePending;});') &&
    lg.includes('if(!lgStatusConnected(state)){'),
  'LG picture/calibration controls should be disabled after Disconnect until Connect succeeds again'
);

assert(
  lg.includes('return &lg_encode_json({ status => "error", message => "Connect the LG TV before changing calibration mode." }) if(&lg_clients_disconnected($clients));') &&
    lg.includes('return &lg_encode_json({ status => "error", message => "Connect the LG TV before reading picture settings." }) if(&lg_clients_disconnected($clients));') &&
    lg.includes('return &lg_encode_json({ status => "error", message => "Connect the LG TV before resetting HDR calibration state." }) if(&lg_clients_disconnected($clients));'),
  'Backend LG control endpoints should reject direct calls while locally disconnected'
);

assert(
  webui.includes("(typeof lgStatusConnected==='function')?lgStatusConnected(state)") &&
    webui.includes('!state.disconnected') &&
    webui.includes('function meterGreyTvControlsActive()'),
  'Meter/AutoCal LG availability should respect the connected state after Disconnect'
);

console.log('LG disconnect preserves pairing regression checks passed.');
