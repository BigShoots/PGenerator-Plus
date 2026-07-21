(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.PGeneratorHcfrChc = api;
}(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  const FILE_MAGIC = 'COLORHCF';
  const MATRIX_MAGIC = 'taMCCxir';
  const INVALID_XYZ_LIMIT = -99999;
  const INVALID_XYZ = -99999.99;
  // Serialized current-HCFR document objects following the measurement block.
  // This tail comes from a v17 document using HCFR's simulated sensor. It is
  // deliberately kept opaque: the measurement writer never modifies it.
  const V17_DOCUMENT_TAIL_BASE64 = '//8BABAAQ1NpbXVsYXRlZFNlbnNvcnRhTUNDeGlyAQAAAAMAAAADAAAAAAAAAAAA8D8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADwPwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPA/AQAAAAAAAAADAAAAAADIQgEAAAABAAAAAQAAAA8AAAB0YU1DQ3hpcgEAAAADAAAAAwAAAHsUrkfheuQ/H4XrUbge1T+gHoXrUbiePzMzMzMzM9M/MzMzMzMz4z+YmZmZmZm5PzMzMzMzM8M/uB6F61G4rj9I4XoUrkfpP3RhTUNDeGlyAQAAAAEAAAADAAAAiGNd3EYD1D91kxgEVg7VPwMJih9j7tY/AAACAAAAAAAAAAAA8D8CAAAAAQAAAAMAAAABAAAAAQAAAHsUrkfheoQ/AQAAAOxRuB6F67E///8BAA0AQ0dESUdlbmVyYXRvcgYAAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAADAAAAAAAAAAAAAAAKAAAAAAAAAGQAAAAAAAAABgAAAAEAAAAAAAAAAQAAAAEAAAADAAAA///////////4////4f///wAAAAAAAAAAtgMAANoCAAAAAAAAAQAAAAEAAADpoQAAARUABQ==';
  const DEFAULT_LIMITS = Object.freeze({
    maxFileBytes: 32 * 1024 * 1024,
    maxArrayItems: 100000,
    maxMatrixElements: 1000000,
    maxSpectrumBands: 65536,
    maxStringBytes: 1024 * 1024
  });

  class ChcParseError extends Error {
    constructor(message, offset) {
      super(offset == null ? message : message + ' at byte ' + offset);
      this.name = 'ChcParseError';
      this.offset = offset == null ? null : offset;
    }
  }

  class Reader {
    constructor(input, options) {
      let bytes;
      if (input instanceof Uint8Array) bytes = input;
      else if (input instanceof ArrayBuffer) bytes = new Uint8Array(input);
      else if (ArrayBuffer.isView(input)) bytes = new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
      else throw new TypeError('CHC input must be an ArrayBuffer or byte array');
      this.limits = Object.assign({}, DEFAULT_LIMITS, options && options.limits);
      if (bytes.byteLength > this.limits.maxFileBytes) throw new ChcParseError('CHC file exceeds size limit', 0);
      this.bytes = bytes;
      this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
      this.offset = 0;
    }

    remaining() { return this.bytes.byteLength - this.offset; }
    require(size, label) {
      if (!Number.isSafeInteger(size) || size < 0 || size > this.remaining()) {
        throw new ChcParseError('Unexpected end of CHC while reading ' + label, this.offset);
      }
    }
    skip(size, label) { this.require(size, label || 'data'); this.offset += size; }
    u8(label) { this.require(1, label || 'byte'); return this.view.getUint8(this.offset++); }
    u16(label) { this.require(2, label || 'uint16'); const v = this.view.getUint16(this.offset, true); this.offset += 2; return v; }
    u32(label) { this.require(4, label || 'uint32'); const v = this.view.getUint32(this.offset, true); this.offset += 4; return v; }
    i32(label) { this.require(4, label || 'int32'); const v = this.view.getInt32(this.offset, true); this.offset += 4; return v; }
    f64(label) {
      this.require(8, label || 'double');
      const v = this.view.getFloat64(this.offset, true);
      this.offset += 8;
      if (!Number.isFinite(v)) throw new ChcParseError('Non-finite number in ' + (label || 'double'), this.offset - 8);
      return v;
    }
    ascii(size, label) {
      this.require(size, label || 'text');
      let out = '';
      for (let i = 0; i < size; i++) out += String.fromCharCode(this.bytes[this.offset + i]);
      this.offset += size;
      return out;
    }
    count(label, limit) {
      const at = this.offset;
      const value = this.u32(label);
      if (value > (limit == null ? this.limits.maxArrayItems : limit)) {
        throw new ChcParseError((label || 'Array') + ' count exceeds safety limit', at);
      }
      return value;
    }
  }

  class Writer {
    constructor() { this.bytes = []; }
    u8(v) { this.bytes.push(v & 255); }
    u16(v) { this.u8(v); this.u8(v >>> 8); }
    u32(v) { v = Number(v) >>> 0; this.u16(v); this.u16(v >>> 16); }
    i32(v) { this.u32(Number(v) | 0); }
    f64(v) {
      const b = new ArrayBuffer(8);
      new DataView(b).setFloat64(0, Number(v), true);
      this.raw(new Uint8Array(b));
    }
    ascii(s) { for (let i = 0; i < s.length; i++) this.u8(s.charCodeAt(i)); }
    raw(a) { for (const b of a) this.u8(b); }
    finish() { return Uint8Array.from(this.bytes); }
  }

  function base64Bytes(value) {
    if (typeof Buffer !== 'undefined') return new Uint8Array(Buffer.from(value, 'base64'));
    const binary = atob(value);
    return Uint8Array.from(binary, c => c.charCodeAt(0));
  }

  function finite(value, fallback) {
    const n = Number(value);
    return Number.isFinite(n) ? n : fallback;
  }

  function normalizeColor(value) {
    if (!value || value.valid === false) return { valid: false, X: INVALID_XYZ, Y: INVALID_XYZ, Z: INVALID_XYZ };
    let X = finite(value.X, NaN), Y = finite(value.Y != null ? value.Y : value.luminance, NaN), Z = finite(value.Z, NaN);
    const x = finite(value.x, NaN), y = finite(value.y, NaN);
    if ((!Number.isFinite(X) || !Number.isFinite(Z)) && Number.isFinite(Y) && Number.isFinite(x) && Number.isFinite(y) && y > 0) {
      X = x * Y / y;
      Z = (1 - x - y) * Y / y;
    }
    if (![X, Y, Z].every(Number.isFinite)) return { valid: false, X: INVALID_XYZ, Y: INVALID_XYZ, Z: INVALID_XYZ };
    return { valid: true, X, Y, Z };
  }

  function writeMatrix(writer, rows, columns, values) {
    writer.ascii(MATRIX_MAGIC); writer.u32(1); writer.u32(columns); writer.u32(rows);
    for (let column = 0; column < columns; column++) for (let row = 0; row < rows; row++) writer.f64(values[row][column]);
  }

  function writeColor(writer, value) {
    const c = normalizeColor(value);
    writer.u32(1);
    writeMatrix(writer, 3, 1, [[c.X], [c.Y], [c.Z]]);
    const zero = [[0,0,0],[0,0,0],[0,0,0]];
    writeMatrix(writer, 3, 3, zero); writeMatrix(writer, 3, 3, zero);
  }

  function writeColorArray(writer, items) {
    const list = Array.isArray(items) ? items : [];
    writer.u32(list.length); list.forEach(item => writeColor(writer, item));
  }

  function writeSparseColorArray(writer, group, defaultDeclaredCount) {
    const source = group && Array.isArray(group.items) ? group.items : [];
    const declared = Math.max(1, finite(group && group.declaredCount, defaultDeclaredCount) | 0);
    writer.u32(declared);
    source.forEach((entry, serialIndex) => {
      const index = finite(entry && entry.index, serialIndex) | 0;
      if (index < 0 || index >= declared) throw new RangeError('Sparse color index is outside declared array');
      writeColor(writer, entry); writer.u32(index);
    });
    writeColor(writer, { X: 0.123, Y: 0.456, Z: 0.789 });
  }

  function cp1252Bytes(value) {
    const replacements = {'€':0x80,'‚':0x82,'ƒ':0x83,'„':0x84,'…':0x85,'†':0x86,'‡':0x87,'ˆ':0x88,'‰':0x89,'Š':0x8a,'‹':0x8b,'Œ':0x8c,'Ž':0x8e,'‘':0x91,'’':0x92,'“':0x93,'”':0x94,'•':0x95,'–':0x96,'—':0x97,'˜':0x98,'™':0x99,'š':0x9a,'›':0x9b,'œ':0x9c,'ž':0x9e,'Ÿ':0x9f};
    return Uint8Array.from(Array.from(String(value == null ? '' : value)), ch => replacements[ch] != null ? replacements[ch] : (ch.charCodeAt(0) <= 255 ? ch.charCodeAt(0) : 0x3f));
  }

  function writeMfcString(writer, value) {
    const bytes = cp1252Bytes(value);
    if (bytes.length < 0xff) writer.u8(bytes.length);
    else if (bytes.length < 0xfffe) { writer.u8(0xff); writer.u16(bytes.length); }
    else { writer.u8(0xff); writer.u16(0xffff); writer.u32(bytes.length); }
    writer.raw(bytes);
  }

  function defaultPreferences(overrides) {
    return Object.assign({
      bt2390BlackStart:1, bt2390WhiteStart:0, bt2390WhiteStart1:25, targetSystemGamma:1.2,
      masterMinLuminance:0, masterMaxLuminance:1000, targetMinLuminance:0,
      targetMaxLuminance:100, contentMaxLuminance:1000, frameAverageMaxLuminance:400,
      useToneMap:false, overrideTargets:false, diffuseLuminance:94.3784,
      nearWhiteClipColumn:101, whiteTarget:0, colorCheckerMode:0, colorStandard:2,
      deltaEFormula:3, grayscaleDeltaE:3, grayWorldWeight:0, gammaOffsetType:4,
      gammaReference:2.4, gammaRelative:0, gammaSplit:100,
      manualWhiteX:0.3127, manualWhiteY:0.3290, useMeasuredGamma:false,
      manualBlueX:0.15, manualRedX:0.64, manualGreenX:0.30,
      manualBlueY:0.06, manualRedY:0.33, manualGreenY:0.60,
      overrideBlack:false, userBlack:null
    }, overrides || {});
  }

  function writePreferences(writer, input) {
    const p = defaultPreferences(input);
    ['bt2390BlackStart','bt2390WhiteStart','bt2390WhiteStart1','targetSystemGamma','masterMinLuminance','masterMaxLuminance','targetMinLuminance','targetMaxLuminance','contentMaxLuminance','frameAverageMaxLuminance'].forEach(k=>writer.f64(finite(p[k],0)));
    writer.i32(p.useToneMap?1:0); writer.i32(p.overrideTargets?1:0); writer.f64(finite(p.diffuseLuminance,94.3784));
    writer.i32(finite(p.nearWhiteClipColumn,101));
    ['whiteTarget','colorCheckerMode','colorStandard','deltaEFormula','grayscaleDeltaE','grayWorldWeight','gammaOffsetType'].forEach(k=>writer.i32(finite(p[k],0)));
    ['gammaReference','gammaRelative','gammaSplit','manualWhiteX','manualWhiteY'].forEach(k=>writer.f64(finite(p[k],0)));
    writer.i32(p.useMeasuredGamma?1:0);
    ['manualBlueX','manualRedX','manualGreenX','manualBlueY','manualRedY','manualGreenY'].forEach(k=>writer.f64(finite(p[k],0)));
    writer.i32(p.overrideBlack?1:0); writeColor(writer, p.userBlack || {X:0,Y:0,Z:0});
  }

  function serializeHcfrChc(model, options) {
    model = model || {}; options = options || {};
    const groups = model.groups || {}, fixed = model.fixed || {}, writer = new Writer();
    writer.ascii(FILE_MAGIC); writer.u32(3); writer.u32(17); writePreferences(writer, model.preferences);
    writeColorArray(writer, groups.grayscale);
    writeColorArray(writer, groups.nearBlack || Array(5).fill(null));
    writeColorArray(writer, groups.nearWhite || Array(5).fill(null));
    ['redSaturation','greenSaturation','blueSaturation','yellowSaturation','cyanSaturation','magentaSaturation'].forEach(k=>writeColorArray(writer, groups[k] || Array(5).fill(null)));
    writeSparseColorArray(writer, groups.colorChecker, 1000);
    writeSparseColorArray(writer, groups.colorCheckerMaster, 5000);
    writeColorArray(writer, groups.freeMeasurements || []);
    ['redPrimary','greenPrimary','bluePrimary','yellowSecondary','cyanSecondary','magentaSecondary','onOffBlack','onOffWhite','ansiBlack','ansiWhite','primeWhite'].forEach(k=>writeColor(writer, fixed[k]));
    writeMfcString(writer, model.notes || 'Calibration by: \r\nDisplay: \r\nNote: Exported from PGenerator+\r\n');
    writer.i32(model.ireScaleMode?1:0);
    writer.raw(options.documentTail || base64Bytes(V17_DOCUMENT_TAIL_BASE64));
    const bytes = writer.finish();
    if (options.validate !== false) {
      const parsed = parseHcfrChc(bytes);
      if (parsed.fileVersion !== 3 || parsed.measurementVersion !== 17 || parsed.measurementEndOffset + parsed.trailingObjectBytes !== bytes.length) throw new Error('Generated CHC failed validation');
    }
    return bytes;
  }

  function readMatrix(reader, label) {
    const start = reader.offset;
    if (reader.ascii(8, label + ' magic') !== MATRIX_MAGIC) throw new ChcParseError('Invalid matrix signature for ' + label, start);
    const version = reader.u32(label + ' version');
    if (version !== 1) throw new ChcParseError('Unsupported matrix version ' + version, start + 8);
    const columns = reader.count(label + ' columns', reader.limits.maxMatrixElements);
    const rows = reader.count(label + ' rows', reader.limits.maxMatrixElements);
    const elements = rows * columns;
    if (!Number.isSafeInteger(elements) || elements > reader.limits.maxMatrixElements) {
      throw new ChcParseError(label + ' dimensions exceed safety limit', start + 12);
    }
    reader.require(elements * 8, label + ' values');
    const values = Array.from({ length: rows }, () => Array(columns).fill(0));
    for (let column = 0; column < columns; column++) {
      for (let row = 0; row < rows; row++) values[row][column] = reader.f64(label + ' value');
    }
    return { version, rows, columns, values };
  }

  function readSpectrum(reader, oldBandwidth) {
    const bands = reader.count('spectrum bands', reader.limits.maxSpectrumBands);
    const wavelengthMin = reader.u32('spectrum minimum wavelength');
    const wavelengthMax = reader.u32('spectrum maximum wavelength');
    const bandwidth = oldBandwidth ? reader.u32('spectrum bandwidth') : reader.f64('spectrum bandwidth');
    const version = reader.u32('spectrum version');
    if (version !== 1) throw new ChcParseError('Unsupported spectrum version ' + version, reader.offset - 4);
    const matrix = readMatrix(reader, 'spectrum matrix');
    if (matrix.rows * matrix.columns !== bands) throw new ChcParseError('Spectrum band count does not match its matrix', reader.offset);
    return { bands, wavelengthMin, wavelengthMax, bandwidth, values: matrix.values.flat() };
  }

  function readColor(reader, label) {
    const start = reader.offset;
    const version = reader.u32(label + ' color version');
    if (version < 1 || version > 6) throw new ChcParseError('Unsupported color version ' + version, start);
    const xyzMatrix = readMatrix(reader, label + ' XYZ');
    readMatrix(reader, label + ' legacy transform 1');
    readMatrix(reader, label + ' legacy transform 2');
    if (xyzMatrix.rows !== 3 || xyzMatrix.columns !== 1) throw new ChcParseError(label + ' XYZ matrix is not 3x1', start);
    let spectrum = null;
    let lux = null;
    if ([2, 4, 5, 6].includes(version)) spectrum = readSpectrum(reader, version === 2 || version === 4);
    if ([3, 4, 6].includes(version)) lux = reader.f64(label + ' lux');
    const X = xyzMatrix.values[0][0];
    const Y = xyzMatrix.values[1][0];
    const Z = xyzMatrix.values[2][0];
    const sum = X + Y + Z;
    const valid = X > INVALID_XYZ_LIMIT && Y > INVALID_XYZ_LIMIT && Z > INVALID_XYZ_LIMIT;
    return {
      version, X, Y, Z,
      x: valid && sum > 0 ? X / sum : null,
      y: valid && sum > 0 ? Y / sum : null,
      luminance: valid ? Y : null,
      valid, spectrum, lux,
      byteOffset: start,
      byteLength: reader.offset - start
    };
  }

  function readColorArray(reader, name) {
    const declaredCount = reader.count(name + ' count');
    const items = [];
    for (let i = 0; i < declaredCount; i++) items.push(readColor(reader, name + '[' + i + ']'));
    return { name, declaredCount, items, validItems: items.filter(item => item.valid) };
  }

  function isSparseMarker(color) {
    return color.X === 0.123 && color.Y === 0.456 && color.Z === 0.789;
  }

  function readSparseColorArray(reader, name) {
    const declaredCount = reader.count(name + ' count');
    const items = [];
    let markerFound = false;
    for (let serialIndex = 0; serialIndex <= declaredCount; serialIndex++) {
      const color = readColor(reader, name + ' sparse item');
      if (isSparseMarker(color)) { markerFound = true; break; }
      const indexOffset = reader.offset;
      const index = reader.u32(name + ' sparse index');
      if (index >= declaredCount) throw new ChcParseError(name + ' sparse index is outside declared array', indexOffset);
      items.push(Object.assign({ index }, color));
    }
    if (!markerFound) throw new ChcParseError(name + ' sparse terminator was not found', reader.offset);
    return { name, declaredCount, sparse: true, items, validItems: items.filter(item => item.valid) };
  }

  function readMfcString(reader) {
    const start = reader.offset;
    let length = reader.u8('string length');
    let unicode = false;
    if (length === 0xff) {
      length = reader.u16('extended string length');
      if (length === 0xfffe) {
        unicode = true;
        length = reader.u32('Unicode string length');
      } else if (length === 0xffff) {
        length = reader.u32('long string length');
      }
    }
    if (length > reader.limits.maxStringBytes) throw new ChcParseError('String exceeds safety limit', start);
    const byteLength = unicode ? length * 2 : length;
    reader.require(byteLength, 'string contents');
    let value = '';
    if (unicode) {
      for (let i = 0; i < length; i++) value += String.fromCharCode(reader.u16('Unicode character'));
    } else {
      const bytes = reader.bytes.subarray(reader.offset, reader.offset + length);
      reader.offset += length;
      if (typeof TextDecoder !== 'undefined') value = new TextDecoder('windows-1252').decode(bytes);
      else for (let i = 0; i < bytes.length; i++) value += String.fromCharCode(bytes[i]);
    }
    return value;
  }

  function readPreferences(reader, version) {
    const p = {};
    if (version > 16) {
      p.bt2390BlackStart = reader.f64('BT.2390 black start');
      p.bt2390WhiteStart = reader.f64('BT.2390 white start');
      p.bt2390WhiteStart1 = reader.f64('BT.2390 white start 1');
    }
    if (version > 15) p.targetSystemGamma = reader.f64('target system gamma');
    if (version > 14) {
      p.masterMinLuminance = reader.f64('master minimum luminance');
      p.masterMaxLuminance = reader.f64('master maximum luminance');
      p.targetMinLuminance = reader.f64('target minimum luminance');
      p.targetMaxLuminance = reader.f64('target maximum luminance');
      p.contentMaxLuminance = reader.f64('content maximum luminance');
      p.frameAverageMaxLuminance = reader.f64('frame average maximum luminance');
      p.useToneMap = !!reader.i32('use tone map');
      p.overrideTargets = !!reader.i32('override targets');
      p.diffuseLuminance = reader.f64('diffuse luminance');
    }
    if (version > 13) p.nearWhiteClipColumn = reader.i32('near-white clipping column');
    if (version > 11) {
      p.whiteTarget = reader.i32('white target');
      p.colorCheckerMode = reader.i32('color checker mode');
      p.colorStandard = reader.i32('color standard');
      p.deltaEFormula = reader.i32('Delta E formula');
      p.grayscaleDeltaE = reader.i32('grayscale Delta E');
      p.grayWorldWeight = reader.i32('gray world weight');
      p.gammaOffsetType = reader.i32('gamma offset type');
      p.gammaReference = reader.f64('gamma reference');
      p.gammaRelative = reader.f64('relative gamma');
      p.gammaSplit = reader.f64('gamma split');
      p.manualWhiteX = reader.f64('manual white x');
      p.manualWhiteY = reader.f64('manual white y');
      p.useMeasuredGamma = !!reader.i32('use measured gamma');
      p.manualBlueX = reader.f64('manual blue x');
      p.manualRedX = reader.f64('manual red x');
      p.manualGreenX = reader.f64('manual green x');
      p.manualBlueY = reader.f64('manual blue y');
      p.manualRedY = reader.f64('manual red y');
      p.manualGreenY = reader.f64('manual green y');
    }
    if (version > 10) {
      p.overrideBlack = !!reader.i32('override black');
      p.userBlack = readColor(reader, 'user black');
    }
    return p;
  }

  function parseHcfrChc(input, options) {
    const reader = new Reader(input, options || {});
    const magic = reader.ascii(8, 'file signature');
    if (magic !== FILE_MAGIC) throw new ChcParseError('Not an HCFR CHC file', 0);
    const fileVersion = reader.u32('file version');
    if (fileVersion < 1 || fileVersion > 3) throw new ChcParseError('Unsupported CHC file version ' + fileVersion, 8);
    const measurementVersion = reader.u32('measurement version');
    if (measurementVersion < 1 || measurementVersion > 17) throw new ChcParseError('Unsupported CHC measurement version ' + measurementVersion, 12);

    const preferences = readPreferences(reader, measurementVersion);
    const groups = {};
    groups.grayscale = readColorArray(reader, 'grayscale');
    if (measurementVersion > 2) {
      groups.nearBlack = readColorArray(reader, 'nearBlack');
      groups.nearWhite = readColorArray(reader, 'nearWhite');
    }
    if (measurementVersion > 1) {
      for (const name of ['redSaturation', 'greenSaturation', 'blueSaturation', 'yellowSaturation', 'cyanSaturation', 'magentaSaturation']) {
        groups[name] = readColorArray(reader, name);
      }
      if (measurementVersion >= 8) {
        groups.colorChecker = measurementVersion <= 12 ? readColorArray(reader, 'colorChecker') : readSparseColorArray(reader, 'colorChecker');
        if (measurementVersion >= 10) {
          groups.colorCheckerMaster = measurementVersion <= 12 ? readColorArray(reader, 'colorCheckerMaster') : readSparseColorArray(reader, 'colorCheckerMaster');
        }
      }
    }
    groups.freeMeasurements = readColorArray(reader, 'freeMeasurements');

    const fixed = {};
    for (const name of ['redPrimary', 'greenPrimary', 'bluePrimary', 'yellowSecondary', 'cyanSecondary', 'magentaSecondary',
      'onOffBlack', 'onOffWhite', 'ansiBlack', 'ansiWhite']) fixed[name] = readColor(reader, name);
    if (measurementVersion > 8) fixed.primeWhite = readColor(reader, 'primeWhite');

    const notes = readMfcString(reader);
    if (measurementVersion > 4 && measurementVersion < 7) {
      reader.i32('legacy adjustment matrix enabled');
      readMatrix(reader, 'legacy adjustment matrix');
      readMfcString(reader);
    }
    const ireScaleMode = measurementVersion > 5 ? !!reader.i32('IRE scale mode') : false;
    const measurementEndOffset = reader.offset;
    const validCount = Object.values(groups).reduce((sum, group) => sum + group.validItems.length, 0) +
      Object.values(fixed).filter(color => color.valid).length;

    return {
      format: 'hcfr-chc', magic, fileVersion, measurementVersion,
      preferences, groups, fixed, notes, ireScaleMode,
      validMeasurementCount: validCount,
      byteLength: reader.bytes.byteLength,
      measurementEndOffset,
      trailingObjectBytes: reader.bytes.byteLength - measurementEndOffset
    };
  }

  function summarizeHcfrChc(parsed) {
    const groups = {};
    for (const [name, group] of Object.entries(parsed.groups)) {
      groups[name] = { declared: group.declaredCount, stored: group.items.length, valid: group.validItems.length };
    }
    const fixed = {};
    for (const [name, color] of Object.entries(parsed.fixed)) fixed[name] = color.valid;
    return {
      format: parsed.format,
      fileVersion: parsed.fileVersion,
      measurementVersion: parsed.measurementVersion,
      validMeasurementCount: parsed.validMeasurementCount,
      groups, fixed,
      preferences: parsed.preferences,
      notes: parsed.notes,
      ireScaleMode: parsed.ireScaleMode,
      byteLength: parsed.byteLength,
      measurementEndOffset: parsed.measurementEndOffset,
      trailingObjectBytes: parsed.trailingObjectBytes
    };
  }

  return { ChcParseError, parseHcfrChc, summarizeHcfrChc, serializeHcfrChc, defaultPreferences, normalizeColor };
}));
