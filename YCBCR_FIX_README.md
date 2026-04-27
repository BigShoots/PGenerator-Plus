# YCbCr Full-Range Black Crush Fix
**Status:** Source code patched, awaiting rebuild

## Issues Fixed
1. **YCbCr 4:4:4 SDR Full Range** - 5% blacks crushed to 0% (ΔE=0)
2. **YCbCr 4:2:2 SDR Full Range** - Shows blue instead of black (wrong chroma offset)

## Root Cause
The shader was missing `rgb_quant_range` parameter needed to select proper scalar values for full-range YCbCr encoding:
- **Full range needs:** scalar1=256, scalar2=255, offset=128
- **Limited range uses:** scalar1=224, scalar2=219, offset=128

Without this, Cb/Cr were calculated incorrectly, causing color artifacts and black crush.

## Solution
Updated `rgb2ycbcr_shader()` to:
1. ✅ Accept `rgb_quant_range` uniform from DRM property  
2. ✅ Set scalar1/scalar2 based on range mode
3. ✅ Apply proper offset to Cb/Cr for both 4:2:2 and 4:4:4 formats

## Files Modified
- `src/ofxRPI4Window/src/ofxRPI4Window.cpp` (lines 1614-1720)

## Patch File
- `full_range_ycbcr_shader_fix.patch` (124 lines, ready to apply)

## How to Rebuild (REQUIRED)

### On Prior USB Drive (Has Build Tools)
```bash
# Mount prior USB, navigate to source
cd PGenerator_plus
git apply full_range_ycbcr_shader_fix.patch

# Build for ARMv6 (Pi4)
cd src/pattern_generator
make clean
make pgeneratord_armv6l -j4

# Binary output: bin/pgeneratord_armv6l
```

### Deployment
```bash
# Stop service
/etc/init.d/PGenerator stop

# Transfer new binary
scp bin/pgeneratord_armv6l root@192.168.1.177:/usr/sbin/PGeneratord

# Start service
/etc/init.d/PGenerator start
```

## Validation
After rebuild, test both formats:
- **4:4:4:** Greyscale 21pt - 5% should be noticeably brighter than 0%
- **4:2:2:** 0% black - should be neutral grey (x≈0.312, y≈0.329), not blue

## Known Issues
- Golden USB lacks build tools
- Rebuild must occur on prior USB or local machine with openFrameworks cross-compile

