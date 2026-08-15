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

BRAD_M = [[0.8951,0.2664,-0.1614],[-0.7502,1.7135,0.0367],[0.0389,-0.0685,1.0296]]
def mmul_b(m, v): return [sum(m[r][k]*v[k] for k in range(3)) for r in range(3)]

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
        # Aim just under the plateau so measurement jitter between plateau
        # rows resolves to the EARLIEST code that reaches it.
        want = min(frac, 0.995)*peak
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
KNEE = 0.70
D50 = (0.9642, 1.0, 0.8249)

def a2b_evaluator(d, tags):
    if 'A2B0' not in tags:
        return None
    o,_ = tags['A2B0']
    grid = d[o+10]; ine, oute = struct.unpack('>HH', bytes(d[o+48:o+52]))
    inoff = o+52; clutoff = inoff+3*ine*2; outoff = clutoff+grid**3*3*2
    def be16(p): return (d[p]<<8)|d[p+1]
    def ts(base, count, v):
        v = max(0.0, min(1.0, v))*(count-1); lo = min(int(v), count-2); fr = v-lo
        return (be16(base+lo*2)*(1-fr)+be16(base+(lo+1)*2)*fr)/65535.0
    def ev(rgb):
        co = [ts(inoff+ch*ine*2, ine, rgb[ch]) for ch in range(3)]
        b=[0]*3; f=[0.0]*3
        for r in range(3):
            p=max(0.0,min(1.0,co[r]))*(grid-1); b[r]=min(int(p),grid-2); f[r]=p-b[r]
        out=[0.0]*3
        for ch in range(3):
            a=0.0
            for rr in range(2):
                for gg in range(2):
                    for bb in range(2):
                        w=(f[0] if rr else 1-f[0])*(f[1] if gg else 1-f[1])*(f[2] if bb else 1-f[2])
                        a+=be16(clutoff+((((b[0]+rr)*grid+(b[1]+gg))*grid+(b[2]+bb))*3+ch)*2)/65535.0*w
            out[ch]=a
        return [ts(outoff+ch*oute*2, oute, out[ch])*2.0 for ch in range(3)]
    return ev

def refine_balance_with_a2b(d, tags, balanced, plateau_dev, native_white_xy, target=(0.3127, 0.3290)):
    """Newton-refine the balanced peak through the profile's forward model.

    The additive primary solve over-corrects when channels interact near full
    drive. The fitted A2B saw every near-white mixture row, so solving the
    white point through it captures that non-additivity. The lightest channel
    stays at the plateau code; the other two adjust until the modelled
    chromaticity meets the calibration target.
    """
    ev = a2b_evaluator(d, tags)
    if ev is None or not balanced:
        return balanced
    # The A2B output is media-relative PCS: the display's native white maps to
    # D50. A stimulus that MEASURES absolute D65 therefore maps to D65 pushed
    # through the profile's native-to-D50 adaptation, not to raw D65.
    nx, ny = native_white_xy
    nat = [nx/ny, 1.0, (1-nx-ny)/ny]
    d50 = [0.9642, 1.0, 0.8249]
    d65 = [target[0]/target[1], 1.0, (1-target[0]-target[1])/target[1]]
    cs, cd = mmul_b(BRAD_M, nat), mmul_b(BRAD_M, d50)
    sc = [[cd[r]/cs[r]*BRAD_M[r][k] for k in range(3)] for r in range(3)]
    ib = minv3(BRAD_M)
    AD = [[sum(ib[r][k]*sc[k][c] for k in range(3)) for c in range(3)] for r in range(3)]
    txyz = mmul_b(AD, d65)
    ts_ = sum(txyz)
    tx, ty = txyz[0]/ts_, txyz[1]/ts_
    print(f"PCS target for absolute D65: xy ({tx:.4f},{ty:.4f}) [native white {nx:.4f},{ny:.4f}]")
    lock = balanced.index(max(balanced))
    free = [ch for ch in range(3) if ch != lock]
    codes = list(balanced)
    codes[lock] = plateau_dev
    for _ in range(24):
        xyz = ev(codes)
        s = sum(xyz)
        if s <= 0: break
        ex, ey = xyz[0]/s - tx, xyz[1]/s - ty
        if abs(ex) < 2e-5 and abs(ey) < 2e-5: break
        step = 0.004
        jac = []
        for ch in free:
            probe = list(codes); probe[ch] = min(1.0, probe[ch] + step)
            pxyz = ev(probe); ps = sum(pxyz)
            jac.append(((pxyz[0]/ps - xyz[0]/s)/step, (pxyz[1]/ps - xyz[1]/s)/step))
        det = jac[0][0]*jac[1][1] - jac[1][0]*jac[0][1]
        if abs(det) < 1e-9: break
        d0 = (-ex*jac[1][1] + ey*jac[1][0])/det
        d1 = (-ey*jac[0][0] + ex*jac[0][1])/det
        codes[free[0]] = min(plateau_dev, max(0.5, codes[free[0]] + max(-0.01, min(0.01, d0))))
        codes[free[1]] = min(plateau_dev, max(0.5, codes[free[1]] + max(-0.01, min(0.01, d1))))
    print(f"A2B-refined balance: R={codes[0]*100:.2f}% G={codes[1]*100:.2f}% B={codes[2]*100:.2f}% "
          f"(model xy {xyz[0]/s:.4f},{xyz[1]/s:.4f})")
    return codes

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
            return (balanced[ch] if ch is not None and balanced else plateau_pct/100.0)
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
        plateau_dev = plateau_pct/100.0
        for j in range(grid):
            y_rel = tinvert(inoff+1*ine*2, ine, j/(grid-1))/ENC
            if y_rel < KNEE: continue
            # Phase the balanced per-channel offsets in across the corridor so
            # luminance follows the measured neutral curve while the channel
            # ratio approaches the balanced peak.
            w = max(0.0, min(1.0, (y_rel - KNEE)/(0.95 - KNEE)))
            def corridor_code(ch):
                base = code_for_y(min(y_rel, 1.0), None) if y_rel < 1.0 else plateau_dev
                if balanced:
                    return base + (balanced[ch] - plateau_dev)*w
                return base
            wnode = [tinvert(outoff+ch*oute*2, oute, corridor_code(ch)) for ch in range(3)]
            # Select corridor nodes in NODE space: every interpolation cell a
            # neutral query can touch must have all its corners owned by the
            # corridor, regardless of how wide the shaper-domain node spacing
            # becomes near white.
            def axis_node(ch, rel):
                table_pos = 0.0
                lo, hi = 0.0, 1.0
                enc = min(1.0, max(0.0, rel*ENC))
                # forward through the input table, then to node coordinate
                v = enc*(ine-1)
                lo_i = min(int(v), ine-2); fr = v-lo_i
                base = inoff+ch*ine*2
                t = (be16(base+lo_i*2)*(1-fr)+be16(base+(lo_i+1)*2)*fr)/65535.0
                return t*(grid-1)
            fx = axis_node(0, D50[0]*min(y_rel, 1.9))
            fz = axis_node(2, D50[2]*min(y_rel, 1.9))
            SPAN = 2
            for i in range(max(0, int(fx)-SPAN), min(grid, int(fx)+SPAN+2)):
                for k in range(max(0, int(fz)-SPAN), min(grid, int(fz)+SPAN+2)):
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
    ri2, gi2, bi2 = fmt.index('RGB_R'), fmt.index('RGB_G'), fmt.index('RGB_B')
    xi2, yi2, zi2 = fmt.index('XYZ_X'), fmt.index('XYZ_Y'), fmt.index('XYZ_Z')
    wr = [r for r in rows if float(r[ri2]) == 100 and float(r[gi2]) == 100 and float(r[bi2]) == 100]
    wx = sum(float(r[xi2]) for r in wr)/len(wr); wy = sum(float(r[yi2]) for r in wr)/len(wr)
    wz = sum(float(r[zi2]) for r in wr)/len(wr); ws = wx+wy+wz
    import os
    override = os.environ.get('PGEN_BALANCE_OVERRIDE', '')
    if override:
        balanced = [float(v)/100.0 for v in override.split(',')]
        print(f"balance override: R={balanced[0]*100:.2f}% G={balanced[1]*100:.2f}% B={balanced[2]*100:.2f}%")
    elif os.environ.get('PGEN_BALANCE') == '1':
        balanced = refine_balance_with_a2b(d, tags, balanced, plateau_pct/100.0, (wx/ws, wy/ws))
    else:
        # Default: continue the corridor to the earliest measured plateau with
        # equal channels. Peak white balancing needs knee-band characterization
        # samples; without them the solve overshoots on cliff-type panels.
        balanced = None
    repair(d, tags, curve, ymax, plateau_pct, balanced)
    open(dst, 'wb').write(bytes(d))
    print(f"wrote {dst}")

if __name__ == '__main__':
    main()
