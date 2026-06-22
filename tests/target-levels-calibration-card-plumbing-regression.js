const assert=require('assert'); const fs=require('fs');
const ui=fs.readFileSync('usr/share/PGenerator/webui.pm','utf8');
const worker=fs.readFileSync('usr/bin/meter_lg_autocal.pl','utf8');
const worker3d=fs.readFileSync('usr/bin/meter_lg_3d_autocal.pl','utf8');

// === Part 1: UI markup present in the meter settings popover ================
assert(/id="meterProfileTargetLevels"/.test(ui),'Target Levels section present in meter settings popover');
assert(/id="meterTargetWhiteUseMeasured"/.test(ui)&&/id="meterTargetWhite"/.test(ui),'Target White checkbox + number input present');
assert(/id="meterTargetBlackUseMeasured"/.test(ui)&&/id="meterTargetBlack"/.test(ui),'Target Black checkbox + number input present');
// Both number inputs start disabled (Use measured checked by default).
const tlSection=ui.slice(ui.indexOf('id="meterProfileTargetLevels"'),ui.indexOf('id="meterProfileTargetLevels"')+2400);
assert(/id="meterTargetWhiteUseMeasured"[^>]*checked/.test(tlSection),'Target White defaults to Use measured (checkbox checked)');
assert(/id="meterTargetBlackUseMeasured"[^>]*checked/.test(tlSection),'Target Black defaults to Use measured (checkbox checked)');
assert(/id="meterTargetWhite"[^>]*disabled/.test(tlSection),'Target White number input is disabled when Use measured is checked');
assert(/id="meterTargetBlack"[^>]*disabled/.test(tlSection),'Target Black number input is disabled when Use measured is checked');

// === Part 2: JS state, persistence, defaults ================================
assert(/const METER_TARGET_LEVELS_KEY='pgen\.meter\.targetLevels';/.test(ui),'METER_TARGET_LEVELS_KEY localStorage constant declared');
assert(/function meterSetTargetLevels\(\)/.test(ui),'meterSetTargetLevels persists + toggles disabled state');
assert(/function meterRestoreTargetLevels\(\)/.test(ui),'meterRestoreTargetLevels restores from localStorage');
assert(/meterRestoreTargetLevels\(\)/.test(ui),'meterRestoreTargetLevels is called during init');
assert(/function meterDisplayTypeIsOledClass\(/.test(ui),'meterDisplayTypeIsOledClass helper defined');
assert(/function meterApplyTargetLevelsDisplayDefaults\(/.test(ui),'meterApplyTargetLevelsDisplayDefaults applies display-type defaults');
// OLED-class detection covers generic OLED + QD-OLED + CCSS technology meta.
const oledFn=ui.slice(ui.indexOf('function meterDisplayTypeIsOledClass'),ui.indexOf('function meterDisplayTypeIsOledClass')+700);
assert(/indexOf\('oled'\)/.test(oledFn),'OLED-class detection checks the value for "oled"');
assert(/meterDisplayTypeMetaText/.test(oledFn),'OLED-class detection consults CCSS meta text for technology');
assert(/qd[-\s]*oled|wrgb[-\s]*oled|rgb[-\s]*oled|woled|amoled|oled/.test(oledFn),'OLED-class detection regex includes qd-oled/wrgb-oled/oled variants');
// Defaults are re-applied on display-type selection.
assert(/meterApplyTargetLevelsDisplayDefaults\(false\)/.test(ui),'display-type selection re-applies Target Levels defaults for non-overridden sides');
// Default logic: OLED-class -> black=0 (manual), else measured.
const defFn=ui.slice(ui.indexOf('function meterApplyTargetLevelsDisplayDefaults'),ui.indexOf('function meterApplyTargetLevelsDisplayDefaults')+900);
assert(/if\(oled\)/.test(defFn),'default function branches on OLED-class');
assert(/bUm\.checked=false; if\(black\) black\.value='0'/.test(defFn),'OLED-class defaults Target Black to 0 (manual)');
assert(/bUm\.checked=true; if\(black\) black\.value=''/.test(defFn),'non-OLED defaults Target Black to measured');
// White always defaults to measured.
assert(/wUm\.checked=true; if\(white\) white\.value=/.test(defFn),'Target White defaults to measured for every display type');

// === Part 3: Chart target-math overrides ====================================
assert(/function meterGreyTargetPeak\(/.test(ui),'meterGreyTargetPeak defined');
const peakFn=ui.slice(ui.indexOf('function meterGreyTargetPeak(refWhite)'),ui.indexOf('function meterGreyTargetPeak(refWhite)')+700);
assert(/meterTargetWhiteLevel/.test(peakFn),'meterGreyTargetPeak consults meterTargetWhiteLevel override');
const blackFn=ui.slice(ui.indexOf('function meterChartBlackLevel(readings)'),ui.indexOf('function meterChartBlackLevel(readings)')+700);
assert(/meterTargetBlackLevel/.test(blackFn),'meterChartBlackLevel consults meterTargetBlackLevel override');

// === Part 4: Client request-body plumbing ===================================
assert(/function meterTargetLevelsPayload\(\)/.test(ui),'meterTargetLevelsPayload builder defined');
const ctxFn=ui.slice(ui.indexOf('function meterMeasurementSignalContext'),ui.indexOf('function meterMeasurementSignalContext')+2200);
assert(/meterTargetLevelsPayload/.test(ctxFn),'meterMeasurementSignalContext injects target levels payload into every meter request');
const pl=ui.slice(ui.indexOf('function meterTargetLevelsPayload'),ui.indexOf('function meterTargetLevelsPayload')+600);
assert(/target_white_luminance/.test(pl)&&/target_black_luminance/.test(pl),'payload emits target_white/target_black_luminance');
assert(/target_white_use_measured/.test(pl)&&/target_black_use_measured/.test(pl),'payload emits use_measured flags');

// === Part 5: Server-side series parsing + stamping (webui.pm) ================
const seriesFn=ui.slice(ui.indexOf('my $series_target_white_y="";'),ui.indexOf('my $series_target_white_y="";')+1600);
assert(/target_white_luminance/.test(seriesFn),'series parser reads target_white_luminance');
assert(/target_black_luminance/.test(seriesFn),'series parser reads target_black_luminance');
assert(/target_white_use_measured/.test(seriesFn)&&/target_black_use_measured/.test(seriesFn),'series parser reads use_measured flags');
assert(/series_target_white_y_num=\$target_white_luminance\+0/.test(seriesFn),'manual white override overrides series_target_white_y_num');
assert(/series_target_black_y_num/.test(seriesFn),'series tracks series_target_black_y_num');
// Black stamping onto steps.
assert(/\\"series_target_black_y\\":\$series_target_black_y_num/.test(ui),'series stamps series_target_black_y onto each step');
// Reading carries the stamped black floor.
assert(/if\(step\.series_target_black_y!=null\) reading\.series_target_black_y=step\.series_target_black_y/.test(ui),'reading carries series_target_black_y from the step');

// === Part 6: Autocal (meter_lg_autocal.pl) overrides ========================
assert(/my \$_target_white_override = undef;/.test(worker),'worker declares $_target_white_override');
assert(/my \$_target_black_override = undef;/.test(worker),'worker declares $_target_black_override');
assert(/sub autocal_set_target_overrides/.test(worker),'worker exposes autocal_set_target_overrides test hook');
assert(/sub autocal_target_overrides/.test(worker),'worker exposes autocal_target_overrides accessor');
const tls=worker.slice(worker.indexOf('sub target_luminance_for_step'),worker.indexOf('sub target_luminance_for_step')+500);
assert(/\$white_y = \$_target_white_override if\(defined\(\$_target_white_override\)\);/.test(tls),'target_luminance_for_step applies white override');
assert(/\$black_y = \$_target_black_override if\(defined\(\$_target_black_override\)\);/.test(tls),'target_luminance_for_step applies black override');
// Config load populates the globals.
assert(/\$_target_white_override = \$config->\{"target_white_luminance"\}\+0/.test(worker),'config load sets $_target_white_override from target_white_luminance');
assert(/\$_target_black_override = \$config->\{"target_black_luminance"\}\+0/.test(worker),'config load sets $_target_black_override from target_black_luminance');

// === Part 7: 3D autocal (meter_lg_3d_autocal.pl) overrides ==================
assert(/\$config->\{"fixture_white_y"\} = \$config->\{"target_white_luminance"\}\+0/.test(worker3d),'3D config load maps target_white_luminance to fixture_white_y');
assert(/\$config->\{"fixture_black_y"\} = \$config->\{"target_black_luminance"\}\+0/.test(worker3d),'3D config load maps target_black_luminance to fixture_black_y');
const mfr=worker3d.slice(worker3d.indexOf('sub model_from_readings'),worker3d.indexOf('sub model_from_readings')+3000);
assert(/\$profile_white_y = \$config->\{"target_white_luminance"\}\+0/.test(mfr),'model_from_readings overrides profile_white_y from target_white_luminance');
assert(/\$black_y = \$config->\{"target_black_luminance"\}\+0/.test(mfr),'model_from_readings overrides black_y from target_black_luminance');

console.log('target levels (white/black) calibration-card plumbing regression OK');
