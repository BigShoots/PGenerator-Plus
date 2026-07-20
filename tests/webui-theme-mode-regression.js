#!/usr/bin/env node
'use strict';

const assert=require('assert');
const fs=require('fs');
const source=fs.readFileSync('usr/share/PGenerator/webui.pm','utf8');

assert(source.includes("localStorage.getItem('pgen.ui.themeMode')"),'theme is restored in the head bootstrap');
assert(source.indexOf("localStorage.getItem('pgen.ui.themeMode')")<source.indexOf('<style>'),'saved theme is applied before CSS and paint');
assert(source.includes("const PG_THEME_STORAGE_KEY='pgen.ui.themeMode';"),'runtime controller uses the namespaced key');
assert(/return saved==='light'\|\|saved==='dark'\?saved:'dark'/.test(source),'invalid storage falls back to dark');
assert(source.includes("catch(e){ return 'dark'; }"),'inaccessible storage falls back to dark');
assert(source.includes('[data-theme="light"]{color-scheme:light'),'light mode sets native color-scheme');
assert(source.includes(':root,[data-theme="dark"]{color-scheme:dark'),'dark remains the CSS default');
assert(source.includes("new CustomEvent('pgen:themechange'"),'runtime changes emit a dedicated event');
assert(source.includes('pgRedrawChartsForTheme();'),'runtime changes redraw charts');
assert(!/function pgRedrawChartsForTheme\([\s\S]{0,700}meterRefreshActiveSeriesCharts/.test(source),'theme redraw does not rebuild measurement state');

const uiCard=(source.match(/id="uiSettingsCard"/g)||[]).length;
assert.strictEqual(uiCard,1,'UI Settings card has one ID');
assert(source.includes('data-desktop-workspace="ui-settings"'),'UI Settings is a tablet card and desktop workspace');
assert(source.indexOf('data-workspace-target="ui-settings"')<source.indexOf('data-workspace-target="system"'),'UI Settings navigation precedes System');
for(const mode of ['tablet','desktop']){
 const controls=(source.match(new RegExp('<button[^>]+data-layout-mode="'+mode+'"','g'))||[]).length;
 assert.strictEqual(controls,2,mode+' has exactly a header shortcut and settings tile');
}
for(const mode of ['dark','light']){
 assert.strictEqual((source.match(new RegExp('data-theme-mode="'+mode+'"','g'))||[]).length,1,mode+' has one appearance tile');
}
assert(source.includes("document.querySelectorAll('.layout-switch-btn[data-layout-mode]')"),'header and card layout controls share synchronization');
assert(source.includes("btn.disabled=unavailable"),'all Desktop controls respect width eligibility');
assert(source.includes("note.classList.toggle('is-visible',!pgWideEnoughForDesktop())"),'width restriction has a visible explanation');
assert(source.includes("btn.setAttribute('aria-pressed',btn.getAttribute('data-theme-mode')===pgThemeMode?'true':'false')"),'theme selected state is accessible');
assert(source.includes('body.layout-tablet .ui-choice::before'),'tablet preferences use compact switch tracks');
assert(source.includes("body.layout-tablet .ui-choice-title::after{content:'?'"),'tablet preferences expose help affordances');
assert(source.includes('body.layout-tablet .ui-choice:hover .ui-choice-description'),'tablet help copy appears on hover');
assert(source.includes('#meterSeriesTabRow [data-series-tab].btn-primary'),'series tabs share the selected blue treatment');
assert(source.includes('.pat-btn.active,#meterSeriesTabRow'),'pattern selections share the selected blue treatment');
assert(source.includes('box-shadow:inset 4px 0 0 var(--accent)'),'selected controls use the wider left accent rail');
assert(source.includes('[data-theme="light"] select,[data-theme="light"] textarea'),'light theme overrides stylesheet-authored form backgrounds');
assert(source.includes('[data-theme="light"] .pat-btn'),'light theme overrides diagnostic button backgrounds');
assert(source.includes('[data-theme="light"] .diag-asset-icon-btn{color:var(--text-primary)!important}'),'light theme keeps icon buttons visible');
assert(source.includes('body.layout-tablet #uiSettingsCard{order:1000!important'),'UI Settings defaults near the bottom of Tablet mode');
assert(source.includes('body.layout-tablet .ui-settings-sections{grid-template-columns:repeat(2,minmax(0,1fr))'),'Tablet layout and theme settings stay side by side');
assert(source.includes('<h3>Theme</h3>'),'appearance group is named Theme');
assert(source.includes('[data-theme="light"] #meterThumbsRow'),'measurement scrollbars use light-theme tokens');
assert(source.includes('[data-theme="light"] .meter-pattern-insert-gear'),'gear buttons have an explicit light treatment');
assert(source.includes("document.querySelectorAll('.dashboard > [data-widget]').forEach(panel=>{panel.style.order='';});"),'returning to Tablet clears Desktop inline order so drag reorder remains effective');

console.log('webui theme mode regression OK');
