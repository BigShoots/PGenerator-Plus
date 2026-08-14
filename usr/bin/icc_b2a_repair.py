#!/usr/bin/env python3
"""Repair the top of an HDR display profile's BToA tables from its own data.

An OLED's forward response flattens through its rolloff, so a fitted inverse
is ill-conditioned near and above measured white: it extrapolates device
codes the display cannot render, with arbitrary channel balance. This tool
rebuilds that region from the profile's embedded characterization rows:

1. The neutral corridor from the rolloff knee up follows the measured
   neutral wire-code curve.
2. Everything at and above measured white gets a balanced peak: the limiting
   channel stays at full drive and the other two scale down so full drive
   lands on the calibration white point, solved from the measured full-drive
   primaries and per-channel ramps. The balanced peak luminance is what the
   display can sustain at the correct white, and requests beyond it are the
   display's own tone mapping to perform.

Usage: icc_b2a_repair.py input.icc output.icc [measurements.ti3]
Without a TI3 argument the embedded targ tag is used.
"""
import struct, sys

def read_profile(path):
    d = bytearray(open(path, 'rb').read())
    count = struct.unpack('>I', d[128:132])[0]
    tags = {}
    for i in range(count):
        sig, off, size = struct.unpack('>4sII', bytes(d[132+i*12:144+i*12]))
        tags[sig.decode('latin1')] = (off, size)
    return d, tags

def parse_ti3(text):
    fmt, rows, in_data, take_fmt = None, [], False, False
    for ln in text.splitlines():
        if ln.startswith('BEGIN_DATA_FORMAT'): take_fmt = True; continue
        if take_fmt: fmt = ln.split(); take_fmt = False; continue
        if ln.strip() == 'BEGIN_DATA': in_data = True; continue
        if ln.strip() == 'END_DATA': in_data = False; continue
        if in_data and ln.split(): rows.append(ln.split())
    return fmt, rows

def minv3(m):
    a,b,c,e,f,g,h,i,j = m[0][0],m[0][1],m[0][2],m[1][0],m[1][1],m[1][2],m[2][0],m[2][1],m[2][2]
    det = a*(f*j-g*i)-b*(e*j-g*h)+c*(e*i-f*h)
    return [[(f*j-g*i)/det,(c*i-b*j)/det,(b*g-c*f)/det],
            [(g*h-e*j)/det,(a*j-c*h)/det,(c*e-a*g)/det],
            [(e*i-f*h)/det,(b*h-a*i)/det,(a*f-b*e)/det]]

def analyse_measurements(fmt, rows, target=(0.3127, 0.3290)):
    ri, gi, bi = fmt.index('RGB_R'), fmt.index('RGB_G'), fmt.index('RGB_B')
    xi, yi, zi = fmt.index('XYZ_X'), fmt.index('XYZ_Y'), fmt.index('XYZ_Z')
    f = lambda r, i: float(r[i])
    # monotone neutral wire-code -> luminance curve
    neut = sorted((f(r,ri), f(r,yi)) for r in rows
                  if abs(f(r,ri)-f(r,gi)) < 0.01 and abs(f(r,gi)-f(r,bi)) < 0.01)
    curve = []
    for p, y in neut:
        if curve and abs(p-curve[-1][0]) < 1e-6:
            curve[-1] = (p, max(curve[-1][1], y)); continue
        curve.append((p, y))
    for i in range(1, len(curve)):
        curve[i] = (curve[i][0], max(curve[i][1], curve[i-1][1]))
    ymax = max(y for _, y in curve)
    plateau_pct = next(p for p, y in curve if y >= 0.995*ymax)
    # balanced peak from full-drive primaries + per-channel ramps
    prim, ramps = {}, {}
    for name, idx, others in (('R', ri, (gi, bi)), ('G', gi, (ri, bi)), ('B', bi, (ri, gi))):
        pure = sorted([r for r in rows if f(r,idx) > 0.5 and all(f(r,o) < 0.01 for o in others)],
                      key=lambda r: f(r,idx))
        if not pure:
            return curve, ymax, plateau_pct, None
        prim[name] = [f(pure[-1], xi), f(pure[-1], yi), f(pure[-1], zi)]
        ramps[name] = [(f(r,idx), f(r,yi)) for r in pure]
    M = [[prim[c][row] for c in 'RGB'] for row in range(3)]
    tx, ty = target
    T = [tx/ty, 1.0, (1-tx-ty)/ty]
    Mi = minv3(M)
    s = [sum(Mi[r][k]*T[k] for k in range(3)) for r in range(3)]
    peak_scale = max(s)
    s = [v/peak_scale for v in s]
    def code_for_fraction(ch, frac):
        ramp = ramps[ch]
        peak = max(y for _, y in ramp)
        want = frac*peak
        for i in range(1, len(ramp)):
            if ramp[i][1] >= want - 1e-9:
                c0, y0 = ramp[i-1]; c1, y1 = ramp[i]
                t = 0.0 if y1 == y0 else (want-y0)/(y1-y0)
                return c0 + t*(c1-c0)
        return ramp[-1][0]
    balanced = [code_for_fraction(c, s['RGB'.index(c)])/100.0 for c in 'RGB']
    ybal = sum(M[1][k]*s[k] for k in range(3))
    print(f"balanced peak: scales R={s[0]:.4f} G={s[1]:.4f} B={s[2]:.4f}, "
          f"Y={ybal:.2f}% of native white, codes "
          f"R={balanced[0]*100:.2f}% G={balanced[1]*100:.2f}% B={balanced[2]*100:.2f}%")
    return curve, ymax, plateau_pct, balanced

ENC = 32768.0/65535.0
KNEE = 0.85
D50 = (0.9642, 1.0, 0.8249)

def repair(d, tags, curve, ymax, plateau_pct, balanced):
    def be16(p): return (d[p]<<8)|d[p+1]
    def wbe16(p, v):
        v = max(0, min(65535, int(round(v)))); d[p] = v>>8; d[p+1] = v & 0xFF
    def tinvert(base, count, target):
        lo_i, hi_i = 0, count-1
        lo_v = be16(base)/65535.0; hi_v = be16(base+(count-1)*2)/65535.0
        if target <= lo_v: return 0.0
        if target >= hi_v: return 1.0
        while hi_i-lo_i > 1:
            mid = (lo_i+hi_i)//2; mv = be16(base+mid*2)/65535.0
            if mv <= target: lo_i, lo_v = mid, mv
            else: hi_i, hi_v = mid, mv
        fr = 0.0 if hi_v == lo_v else (target-lo_v)/(hi_v-lo_v)
        return (lo_i+fr)/(count-1)
    def code_for_y(yrel, ch):
        target = min(yrel, 1.0)*ymax
        if target >= 0.995*ymax:
            return balanced[ch] if balanced else plateau_pct/100.0
        for i in range(1, len(curve)):
            if curve[i][1] >= target:
                p0, y0 = curve[i-1]; p1, y1 = curve[i]
                fr = 0.0 if y1 == y0 else (target-y0)/(y1-y0)
                return (p0 + fr*(p1-p0))/100.0
        return plateau_pct/100.0
    for tag in ('B2A0', 'B2A1'):
        if tag not in tags: continue
        o,_ = tags[tag]
        grid = d[o+10]; ine, oute = struct.unpack('>HH', bytes(d[o+48:o+52]))
        inoff = o+52; clutoff = inoff+3*ine*2; outoff = clutoff+grid**3*3*2
        replaced = 0
        for j in range(grid):
            y_rel = tinvert(inoff+1*ine*2, ine, j/(grid-1))/ENC
            if y_rel < KNEE: continue
            wnode = [tinvert(outoff+ch*oute*2, oute, code_for_y(y_rel, ch)) for ch in range(3)]
            for i in range(grid):
                x_rel = tinvert(inoff+0*ine*2, ine, i/(grid-1))/ENC
                if abs(x_rel - D50[0]*y_rel) > 0.25*y_rel: continue
                for k in range(grid):
                    z_rel = tinvert(inoff+2*ine*2, ine, k/(grid-1))/ENC
                    if abs(z_rel - D50[2]*y_rel) > 0.40*y_rel: continue
                    base = clutoff + (((i*grid+j)*grid+k)*3)*2
                    for ch in range(3):
                        wbe16(base+ch*2, wnode[ch]*65535.0)
                    replaced += 1
        print(f"{tag}: corridor nodes replaced={replaced}")

def main():
    src, dst = sys.argv[1], sys.argv[2]
    d, tags = read_profile(src)
    if len(sys.argv) > 3:
        text = open(sys.argv[3], encoding='latin1').read()
    else:
        off, size = tags['targ']
        text = d[off+8:off+size].decode('latin1', 'replace')
    fmt, rows = parse_ti3(text)
    curve, ymax, plateau_pct, balanced = analyse_measurements(fmt, rows)
    print(f"neutral rows={len(curve)} plateau={plateau_pct:.2f}%")
    repair(d, tags, curve, ymax, plateau_pct, balanced)
    open(dst, 'wb').write(bytes(d))
    print(f"wrote {dst}")

if __name__ == '__main__':
    main()
