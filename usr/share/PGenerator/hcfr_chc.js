(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.PGeneratorHcfrChc = api;
}(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  const FILE_MAGIC = 'COLORHCF';
  const MATRIX_MAGIC = 'taMCCxir';
  const INVALID_XYZ_LIMIT = -99999;
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

  return { ChcParseError, parseHcfrChc, summarizeHcfrChc };
}));
