#!/usr/bin/env node
'use strict';

const fs = require('fs');
const assert = require('assert');

const webui = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');
const lg = fs.readFileSync('usr/share/PGenerator/lg.pm', 'utf8');

// The mode switch is explicit, accessible, local-only and safe on narrow screens.
assert(webui.includes("const PG_LAYOUT_STORAGE_KEY='pgen.ui.layoutMode';"), 'layout preference uses a namespaced localStorage key');
assert(webui.includes('const PG_DESKTOP_MIN_WIDTH=1024;'), 'desktop minimum width is fixed at 1024px');
assert(webui.includes("let pgLayoutPreference='tablet';"), 'tablet remains the default layout');
assert(webui.includes("return saved==='desktop'?'desktop':'tablet';"), 'only a valid persisted desktop preference changes the default');
assert(webui.includes("pgLayoutEffective=(pgLayoutPreference==='desktop'&&pgWideEnoughForDesktop())?'desktop':'tablet';"), 'narrow screens fall back to tablet');
assert(/class="layout-switch"[^>]*role="group"[^>]*aria-label="Interface layout"/.test(webui), 'header exposes an accessible layout switch');
assert((webui.match(/class="layout-switch-btn"/g) || []).length === 2, 'layout switch has exactly two choices');

// Desktop navigation is task-oriented and always begins at Output.
const workspaces = ['output', 'patterns', 'calibration', 'display-control', 'connectivity', 'integrations', 'diagnostics', 'system'];
for (const workspace of workspaces) {
  assert(webui.includes(`data-workspace-target="${workspace}"`), `sidebar contains ${workspace}`);
  const inMain = webui.includes(`data-desktop-workspace="${workspace}"`);
  const inLg = lg.includes(`data-desktop-workspace="${workspace}"`);
  assert(inMain || inLg, `${workspace} has at least one mapped panel`);
}
assert(webui.includes("let pgDesktopWorkspace='output';"), 'Output is the desktop landing workspace');
assert(webui.includes("if(previous!=='desktop'||(options&&options.resetWorkspace)) pgDesktopWorkspace='output';"), 'entering desktop resets to Output');
assert(webui.includes("btn.setAttribute('aria-current','page')"), 'active navigation state is exposed to assistive technology');
assert(webui.includes("'display-control':'LG Display'"), 'Display Control workspace is presented as LG Display');
assert(webui.includes("integrations:'HDMI-CEC'"), 'Integrations workspace is presented as HDMI-CEC');
assert(webui.includes("diagnostics:'HDMI Infoframes'"), 'Diagnostics workspace is presented as HDMI Infoframes');
assert(/data-widget="info" data-desktop-workspace="system" data-desktop-order="10"/.test(webui), 'Device Info is first in System');
assert(/data-widget="resolve" data-desktop-workspace="connectivity" data-desktop-order="40"/.test(webui), 'Resolve Protocol is in Connectivity');
assert(/data-widget="cec" data-desktop-workspace="integrations"/.test(webui), 'HDMI-CEC contains the CEC panel');
assert(/data-widget="infoframes" data-desktop-workspace="diagnostics"/.test(webui), 'HDMI Infoframes contains the infoframe panel');
assert(/id="lgCardTitle"[^>]*>.*LG Display/.test(lg), 'Tablet LG card is titled LG Display');

// The same panels remain in place; desktop only changes presentation and visibility.
assert(webui.includes('body.layout-desktop .dashboard{max-width:none;width:100%'), 'desktop workspace removes the tablet width cap');
assert(/body\.layout-desktop \.desktop-content\{[^}]*min-height:calc\(100vh - var\(--pg-header-height,61px\)\)[^}]*display:flex[^}]*flex-direction:column/.test(webui), 'desktop content fills the viewport below the header');
assert(/body\.layout-desktop \.site-footer\{[^}]*margin:auto 0 0/.test(webui), 'desktop footer is bottom-aligned on short workspaces');
assert(webui.includes('body.layout-desktop .dashboard > .card{display:none;'), 'inactive desktop panels are presentation-hidden');
assert(webui.includes('.dashboard > .card[data-desktop-workspace]'), 'controller addresses the existing direct dashboard panels');
const layoutController = webui.slice(webui.indexOf('// Interface layout controller.'), webui.indexOf('async function loadInfoframes()'));
assert(!layoutController.includes('cloneNode('), 'desktop mode does not clone controls');
assert(webui.includes("if(document.body.classList.contains('layout-desktop')) return;"), 'desktop disables tablet-only collapse/drag interactions');
assert(webui.includes("else card.classList.toggle('collapsed',!!state[card.dataset.collapseKey]);"), 'tablet collapse state is restored after leaving desktop');
assert(webui.includes("localStorage.getItem('cardCollapse')"), 'collapse preferences remain separate from layout preference');
assert(webui.includes("localStorage.setItem('pg_widget_order'"), 'tablet widget ordering remains supported');
assert(webui.includes('body.layout-desktop #chartsGreyscaleFullWrap:not(.lg-calibration-mode){display:grid;grid-template-columns:minmax(0,3fr) minmax(320px,1fr)'), 'desktop greyscale reserves a right chart column');
assert(webui.includes('#meterEotfLuminanceGrid{grid-column:2;grid-row:1 / span 2;display:grid!important;grid-template-columns:minmax(0,1fr)!important'), 'desktop stacks EOTF above luminance');
assert(webui.includes('id="meterGammaBlock"')&&webui.includes('id="meterEotfLuminanceGrid"'), 'greyscale chart regions have stable layout anchors');
assert(webui.includes('function meterSyncGreyscaleDesktopLayout()')&&webui.includes("home.insertAdjacentElement('afterend',live)"), 'live reading moves into the Desktop RGB rail and returns home in Tablet');
assert(webui.includes('meterSyncGreyscaleDesktopLayout();\n pgSyncCardCollapseForLayout();'), 'layout changes synchronize the live reading mount');

// Conditional panels and workflow affordances must stay correct.
assert(webui.includes("const available=panel.style.display!=='none';"), 'workspace selection respects existing conditional panel visibility');
assert(webui.includes('data-desktop-global="dirty-settings"'), 'dirty settings action remains globally reachable in desktop mode');
assert(webui.includes("if(pgDesktopWorkspace==='calibration'&&typeof meterRefreshActiveSeriesCharts==='function')"), 'showing Calibration refreshes its canvases');
const updateRoute = webui.slice(webui.indexOf('function showUpdateCard()'), webui.indexOf('function showUpdateCard()') + 360);
assert(updateRoute.includes("pgSelectDesktopWorkspace('system')"), 'Update Available routes to the System workspace');
assert(webui.includes('body.meter-autocal-active.layout-desktop .desktop-sidebar'), 'AutoCal makes the desktop sidebar inert');
assert(webui.includes('body.apply-settings-active.layout-desktop .desktop-sidebar'), 'Apply Settings makes the desktop sidebar inert');
assert(webui.includes('body.lg-connect-active.layout-desktop .desktop-sidebar'), 'display connection makes the desktop sidebar inert');
assert(webui.includes('body.meter-stop-active.layout-desktop .desktop-sidebar'), 'meter stop makes the desktop sidebar inert');

console.log('webui desktop layout regression OK');
