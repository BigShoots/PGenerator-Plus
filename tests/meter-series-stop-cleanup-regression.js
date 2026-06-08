const fs = require('fs');

const webui = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');
const helper = fs.readFileSync('usr/bin/meter_series.sh', 'utf8');

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

assert(
  webui.includes('sub webui_meter_series_processes') &&
    webui.includes('$series_ids{$series_id}=1 if($series_id ne "");') &&
    webui.includes('foreach my $proc (&webui_meter_series_processes())'),
  'meter stop should signal every live meter_series helper, not only the id in state'
);

assert(
  webui.includes('sub webui_proc_pgrp') &&
    webui.includes('$targets{"-$pgrp"}=1') &&
    webui.includes('sudo kill $signal $target_list'),
  'meter stop should target the detached helper process group when forcing cleanup'
);

assert(
  webui.includes('system("sudo pkill -9 -x spotread 2>/dev/null");') &&
    webui.includes('system("sudo pkill -9 -f \'script.*spotread\' 2>/dev/null");') &&
    !webui.includes('if(&webui_meter_series_alive() || !$series_was_alive) {'),
  'meter stop should always run the spotread/script backstop after stopping a series'
);

assert(
  webui.includes('Previous meter series is still stopping'),
  'series start should refuse to overlap a helper that survived stop cleanup'
);

assert(
  helper.includes('SERIES_STATE_CLAIM_LOST=0') &&
    helper.includes('series_state_claim_lost()') &&
    helper.includes('series_state_claim_lost && return 0') &&
    helper.includes('series state ownership moved'),
  'meter_series should stop if another helper takes ownership of the shared state file'
);

assert(
  helper.includes('series_process_tree()') &&
    helper.includes('tree=$(series_process_tree "$BG_PID")') &&
    helper.includes('kill -9 $tree'),
  'cancel cleanup should kill the script/spotread child tree instead of waiting indefinitely'
);

assert(
  helper.includes('curl -s --max-time 8') &&
    helper.includes('invalid series step: index=$i'),
  'helper should bound patch posts and fail fast on missing step metadata'
);

console.log('meter series stop cleanup regression passed');
