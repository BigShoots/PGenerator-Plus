const assert = require('assert');
const fs = require('fs');

const webui = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');
const helper = fs.readFileSync('usr/bin/meter_series.sh', 'utf8');

assert(
  webui.includes('$extra.=",\\"final_white_refresh\\":true" if($points==21 && !$lg_greyscale_21 && !$lg_autocal_26 && abs($v-100)<0.001);'),
  'Regular 21pt greyscale should mark its 100% step for a final warmed-white refresh'
);

assert(
  helper.includes('"final_white_refresh"') &&
    helper.includes('[[ "$SIGNAL_MODE" != "dv" ]] && return 0') &&
    helper.includes('final_white_refresh=$(get_step_field 0 final_white_refresh)') &&
    helper.includes('[[ "$final_white_refresh" == "True" || "$final_white_refresh" == "true" || "$final_white_refresh" == "1" ]]'),
  'meter_series.sh should allow marked DV 21pt greyscale through the final white refresh path'
);

assert(
  !helper.includes('[[ "$SIGNAL_MODE" == "dv" ]] && return 1'),
  'DV greyscale should no longer be categorically blocked from final white refresh'
);

assert(
  helper.includes('if replace_series_reading "$FIRST_IRE" "$FIRST_NAME" "$REFRESH_READING"; then') &&
    helper.includes('WHITE_READING="$REFRESH_READING"'),
  'Final white refresh should replace the first 100% read and update the active white reference'
);

console.log('meter series final white refresh regression checks passed.');
