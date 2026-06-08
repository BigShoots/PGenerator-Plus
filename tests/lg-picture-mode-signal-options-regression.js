const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync('usr/share/PGenerator/lg.pm', 'utf8');
const match = source.match(/return <<'LG_JS';\n([\s\S]*?)\nLG_JS\n}/);
assert(match, 'LG card JavaScript heredoc should be extractable');

const elements = {
  signal_mode: { value: 'sdr', dataset: {}, addEventListener() {} },
  lgPictureMode: { innerHTML: '', value: '', disabled: true },
};
const storage = new Map();
const context = {
  window: {},
  document: {
    activeElement: null,
    body: { classList: { toggle() {} } },
    getElementById(id) {
      return elements[id] || null;
    },
    querySelector() {
      return null;
    },
    querySelectorAll() {
      return [];
    },
  },
  localStorage: {
    getItem(key) {
      return storage.get(key) || '';
    },
    setItem(key, value) {
      storage.set(key, value);
    },
    removeItem(key) {
      storage.delete(key);
    },
  },
  setTimeout() {},
  clearTimeout() {},
  setInterval() {},
  clearInterval() {},
  fetch() {},
  console,
};

vm.createContext(context);
vm.runInContext(match[1], context);
context.window.lgStatusState = { connected: true };

assert.strictEqual(
  context.lgPictureModeSignalForValue('hdrFilmMaker'),
  'hdr10',
  'LG HDR camelCase picture mode aliases should be classified as HDR'
);
assert.strictEqual(
  context.lgPictureModeLabel('hdrFilmMaker'),
  'Filmmaker',
  'LG HDR picture mode aliases should reuse canonical labels'
);

context.lgPopulatePictureModeSelect('hdrFilmMaker');

assert.strictEqual(
  elements.lgPictureMode.value,
  'hdr_filmMaker',
  'Dropdown should select the canonical HDR mode for a TV-returned alias'
);
assert(
  elements.lgPictureMode.innerHTML.includes('value="hdr_cinema"') &&
    elements.lgPictureMode.innerHTML.includes('value="hdr_filmMaker"') &&
    elements.lgPictureMode.innerHTML.includes('value="hdr_game"'),
  'Dropdown should show HDR picture modes when the TV is currently in an HDR picture mode'
);
assert(
  !elements.lgPictureMode.innerHTML.includes('value="expert1"') &&
    !elements.lgPictureMode.innerHTML.includes('value="expert2"'),
  'Dropdown should not fall back to SDR picture modes for an active HDR picture mode'
);

elements.signal_mode.value = 'hlg';
context.lgPopulatePictureModeSelect('hdrFilmMaker');
assert(
  elements.lgPictureMode.innerHTML.includes('value="hdr_filmMaker"') &&
    !elements.lgPictureMode.innerHTML.includes('value="expert1"'),
  'HLG should use the HDR picture-mode family when the TV reports HDR-style modes'
);

console.log('LG picture-mode signal options regression checks passed.');
