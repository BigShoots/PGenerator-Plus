const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

const webui = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');
const helper = fs.readFileSync('usr/bin/meter_series.sh', 'utf8');

function extractFunction(name) {
  const token = `function ${name}(`;
  const start = webui.indexOf(token);
  if (start < 0) throw new Error(`Missing function ${name}`);
  let i = webui.indexOf('{', start);
  let depth = 0;
  for (; i < webui.length; i++) {
    const ch = webui[i];
    if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (depth === 0) return webui.slice(start, i + 1);
    }
  }
  throw new Error(`Failed to extract function ${name}`);
}

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

{
  const context = {};
  vm.createContext(context);
  vm.runInContext([
    'let meterActiveSeriesSignalMode = "dv";',
    'let meterActiveSeriesDvMapMode = "1";',
    `
      function meterReadingIsGreyscale(reading) {
        return reading && String(reading.series_type || '').toLowerCase() === 'greyscale';
      }
    `,
    extractFunction('meterReadingCodesMatchStep'),
    extractFunction('meterReadingNominalSlotMatchesStep'),
    extractFunction('meterReadingUsesAlternateStimulus'),
    extractFunction('meterDvAbsoluteWhiteRefreshMatchesStep'),
    extractFunction('meterReadingMatchesStepForPlot'),
    `
      const staleInitialWhite = {
        ire: 100,
        name: '100%',
        series_type: 'greyscale',
        signal_mode: 'dv',
        dv_map_mode: '1',
        final_white_refresh: true,
        r_code: 235,
        g_code: 235,
        b_code: 235,
        luminance: 734.18
      };
      const rewrittenWhiteStep = {
        ire: 100,
        name: '100%',
        series_type: 'greyscale',
        signal_mode: 'dv',
        dv_map_mode: '1',
        final_white_refresh: true,
        dv_absolute_st2084_precomp: true,
        r: 255,
        g: 255,
        b: 255
      };
      globalThis.dvAbsoluteWhiteMatch = meterReadingMatchesStepForPlot(staleInitialWhite, rewrittenWhiteStep);
      globalThis.plainSdrMismatch = meterReadingMatchesStepForPlot(
        {...staleInitialWhite, signal_mode: 'sdr', dv_map_mode: '0'},
        {...rewrittenWhiteStep, signal_mode: 'sdr', dv_map_mode: '0', dv_absolute_st2084_precomp: false}
      );
    `
  ].join('\n'), context);

  assert.strictEqual(
    context.dvAbsoluteWhiteMatch,
    true,
    'DV absolute final-white refresh should keep the initial 100% read plottable after helper-side step code rewrite'
  );
  assert.strictEqual(
    context.plainSdrMismatch,
    false,
    'The DV absolute identity fallback must not loosen normal greyscale code matching'
  );
}

console.log('meter series final white refresh regression checks passed.');
