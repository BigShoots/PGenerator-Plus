"""Extended-region repair, v3: measured neutral corridor + MHC2 top cap.

a) From the embedded characterization rows, build the monotone neutral
   wire-code -> luminance curve and its plateau point.
b) B2A cLUT: every near-neutral node from the rolloff knee up gets its device
   triple from the measured curve inverse; at and above measured white it
   gets the earliest-plateau code. No node in the neutral corridor can emit
   a code the display cannot render.
c) MHC2 curves: scale the region that exceeds plateau drive so the top ends
   at plateau level with the calibration's channel ratio intact. Codes above
   the display plateau would otherwise be clamped per channel by the
   compositor, which discards the white balance and shows native white.
"""
import struct, sys

src_path, dst_path = sys.argv[1], sys.argv[2]
d = bytearray(open(src_path,'rb').read())
n = struct.unpack('>I', d[128:132])[0]
tags = {}
for i in range(n):
    sig, off, size = struct.unpack('>4sII', bytes(d[132+i*12:144+i*12]))
    tags[sig.decode('latin1')] = (off, size)
def be16(p): return (d[p]<<8)|d[p+1]
def wbe16(p, v):
    v = max(0, min(65535, int(round(v)))); d[p] = v>>8; d[p+1] = v & 0xFF
def s15(p): return struct.unpack('>i', bytes(d[p:p+4]))[0]/65536.0
def ws15(p, v): d[p:p+4] = struct.pack('>i', int(round(v*65536.0)))
ENC = 32768.0/65535.0

# --- measured neutral curve -------------------------------------------------
off, size = tags['targ']
lines = d[off+8:off+size].decode('latin1','replace').splitlines()
fmt, rows, in_data = [], [], False
for i, ln in enumerate(lines):
    if ln.startswith('BEGIN_DATA_FORMAT'): fmt = lines[i+1].split()
    elif ln.strip() == 'BEGIN_DATA': in_data = True
    elif ln.strip() == 'END_DATA': in_data = False
    elif in_data and ln.split(): rows.append(ln.split())
ri, gi, bi, yi = (fmt.index(k) for k in ('RGB_R','RGB_G','RGB_B','XYZ_Y'))
neut = sorted((float(r[ri]), float(r[yi])) for r in rows
              if abs(float(r[ri])-float(r[gi]))<0.01 and abs(float(r[gi])-float(r[bi]))<0.01)
# collapse duplicates, force monotone luminance
curve = []
for p, y in neut:
    if curve and abs(p-curve[-1][0]) < 1e-6: curve[-1] = (p, max(curve[-1][1], y)); continue
    curve.append((p, y))
ymax = max(y for _, y in curve)
for i in range(1, len(curve)):
    curve[i] = (curve[i][0], max(curve[i][1], curve[i-1][1]))
plateau_pct = next(p for p, y in curve if y >= 0.995*ymax)
def code_for_y(yrel):
    """measured wire %% producing yrel*ymax, linear interp, capped at plateau"""
    target = min(yrel, 1.0)*ymax
    if target >= 0.995*ymax: return plateau_pct/100.0
    for i in range(1, len(curve)):
        if curve[i][1] >= target:
            p0, y0 = curve[i-1]; p1, y1 = curve[i]
            fr = 0.0 if y1 == y0 else (target-y0)/(y1-y0)
            return (p0 + fr*(p1-p0))/100.0
    return plateau_pct/100.0
print(f"neutral curve rows={len(curve)} plateau={plateau_pct:.2f}%")

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

D50 = (0.9642, 1.0, 0.8249)
KNEE = 0.85   # relative luminance where the corridor rebuild starts
for tag in ('B2A0','B2A1'):
    if tag not in tags: continue
    o,_ = tags[tag]
    grid = d[o+10]; ine, oute = struct.unpack('>HH', bytes(d[o+48:o+52]))
    inoff = o+52; clutoff = inoff+3*ine*2; outoff = clutoff+grid**3*3*2
    replaced = 0
    for j in range(grid):
        y_rel = tinvert(inoff+1*ine*2, ine, j/(grid-1))/ENC
        if y_rel < KNEE: continue
        dev = code_for_y(y_rel)
        wnode = [tinvert(outoff+ch*oute*2, oute, dev) for ch in range(3)]
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

# --- MHC2 top cap ------------------------------------------------------------
if 'MHC2' in tags:
    o,_ = tags['MHC2']
    count = struct.unpack('>I', bytes(d[o+8:o+12]))[0]
    offs = [struct.unpack('>I', bytes(d[o+24+c*4:o+28+c*4]))[0] for c in range(3)]
    ends = [s15(o+offs[c]+8+(count-1)*4) for c in range(3)]
    plateau_dev = plateau_pct/100.0
    scale = plateau_dev / max(ends)
    if scale < 1.0:
        capped = 0
        caps = [e*scale for e in ends]
        for c in range(3):
            for idx in range(count):
                p = o+offs[c]+8+idx*4
                v = s15(p)
                # soft-limit: leave the sub-plateau region alone, compress the top
                if v > caps[c]*0.985:
                    nv = caps[c]*0.985 + (v - caps[c]*0.985)*0.15
                    ws15(p, min(nv, caps[c]))
                    capped += 1
        print(f"MHC2: ends {['%.4f'%e for e in ends]} -> caps {['%.4f'%c for c in caps]} ({capped} entries)")
open(dst_path,'wb').write(bytes(d))
print(f"wrote {dst_path}")
