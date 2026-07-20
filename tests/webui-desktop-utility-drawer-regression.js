#!/usr/bin/env node
'use strict';

const fs = require('fs');
const assert = require('assert');

const source = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');

assert(/id="desktopUtilityToggle"[^>]*aria-controls="desktopUtilityDrawer"[^>]*aria-expanded="false"/.test(source),
  'collapsed drawer exposes an accessible edge toggle');
assert(/id="desktopUtilityDrawer"[^>]*aria-hidden="true"/.test(source), 'drawer is hidden by default');
assert(source.includes('body.layout-desktop .desktop-utility-toggle{display:flex;position:fixed;right:4px'),
  'slim drawer arrow appears only in desktop mode at the right edge');
assert(source.includes('body.layout-desktop.desktop-utility-open .desktop-utility-drawer{transform:translateX(0)}'),
  'open state slides the drawer onscreen');
assert(source.includes("pgSetDesktopUtilityDrawer(false);\n  document.querySelectorAll('.dashboard"),
  'switching to tablet closes the desktop-only drawer');

['desktopUtilityOutput', 'desktopUtilityMetadata', 'desktopUtilityAvi', 'desktopUtilityDrm',
  'desktopUtilityCecStatus', 'desktopUtilityCecDevices', 'desktopUtilityDevice'].forEach(id => {
  assert(source.includes(`id="${id}"`), `${id} display exists`);
});

assert(source.includes("['Resolution',pgUtilityControlText('mode_idx_text')]"), 'drawer mirrors resolution');
assert(source.includes("['Signal Mode',pgUtilityControlText('signal_mode')]"), 'drawer mirrors signal mode');
assert(source.includes("metadataTitle.textContent='Dolby Vision Metadata'"), 'drawer switches to Dolby Vision metadata');
assert(source.includes("metadataTitle.textContent='HDR Metadata'"), 'drawer switches to HDR metadata');
assert(source.includes("pgUtilityInfoframeText('aviDecoded','aviIF')"), 'drawer mirrors decoded and raw AVI data');
assert(source.includes("pgUtilityInfoframeText('drmDecoded','drmIF')"), 'drawer mirrors decoded and raw DRM data');
assert(source.includes("['CPU Usage'"), 'drawer mirrors CPU usage');
assert(source.includes("['Memory Usage'"), 'drawer mirrors memory usage');
assert(source.includes("info.querySelectorAll('.info-item')"), 'drawer mirrors Device Info including interface addresses');

for (const command of ['on', 'off', 'volup', 'voldown', 'mute']) {
  assert(source.includes(`onclick="cecCmd('${command}')"`), `drawer provides CEC ${command}`);
}
assert(source.includes('onclick="cecScan()"'), 'drawer provides the shared CEC scan action');
assert(!/desktopUtility(?:Output|Metadata|Device)"[^>]*(?:select|input)/.test(source),
  'mirrored data does not create duplicate form controls');
assert(source.includes("setInterval(()=>{if(document.body.classList.contains('desktop-utility-open')) pgSyncDesktopUtilityDrawer();},1500);"),
  'live data refreshes only while the drawer is open');

console.log('webui desktop utility drawer regression OK');
