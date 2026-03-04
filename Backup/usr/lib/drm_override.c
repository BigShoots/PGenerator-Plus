/*
 * LD_PRELOAD library to override DRM connector properties for HDMI output.
 *
 * Intercepts ioctl() at the syscall level to avoid glibc version
 * dependency issues (Pi has glibc 2.21, dlsym needs 2.34).
 *
 * Monitors DRM_IOCTL_MODE_GETPROPERTY to discover property IDs for
 * "max bpc", "output format", and "DOVI_OUTPUT_METADATA", then modifies
 * DRM_IOCTL_MODE_ATOMIC, DRM_IOCTL_MODE_SETPROPERTY, and
 * DRM_IOCTL_MODE_OBJ_SETPROPERTY calls to override values from
 * PGenerator.conf.
 *
 * CSC (Color Space Converter) override:
 * After each atomic modeset, the HDMI encoder's hardware CSC is disabled
 * to prevent double range conversion.  PGeneratord handles all color
 * conversion (RGB->YCbCr, limited range mapping) in its OpenGL fragment
 * shader.  Calibration software (CalMAN, HCFR) sends code values that
 * are already in the correct range for the selected quantization mode.
 * If the vc4 kernel driver's CSC is left active (e.g. when
 * rgb_quant_range=Limited), it applies a redundant full->limited
 * conversion on top of the already-limited-range values, causing
 * elevated blacks and compressed highlights.
 *
 * 10-bit HDR runtime binary patch:
 * PGeneratord has three window setup functions:
 *   HDRWindowSetup()      -> GBM_FORMAT_ARGB2101010 (10-bit)
 *   Bit10_16WindowSetup() -> GBM_FORMAT_ABGR16161616H (16-bit half-float)
 *   SDRWindowSetup()      -> GBM_FORMAT_ARGB8888 (8-bit)
 * The dispatch in setup() checks internal bit_depth and avi_info fields
 * that InitDRM() sets to 8 (bug: ignores max_bpc=10 from config).
 * Additionally, is_panel_hdr_dovi() fails to detect HDR from EDID on
 * some TVs.  When max_bpc >= 10 in config, we patch two instructions
 * at load time to force the HDR 10-bit path:
 *   1. Bypass is_panel_hdr_dovi check (beq -> unconditional branch)
 *   2. Match avi_info bpc=8 for the 10-bit path (cmp #10 -> cmp #8)
 * This is safe because the binary is EXEC (fixed addresses, not PIE).
 *
 * The PGeneratord binary has bugs:
 *  - Always sets max_bpc to 8 regardless of config
 *  - Always creates 8-bit framebuffer despite having 10-bit support
 *  - EDID HDR detection fails on some TVs
 *  - May force output format to undesired value for some modes
 *
 * Cross-compile:
 *   arm-linux-gnueabihf-gcc -shared -fPIC -o drm_override.so drm_override.c
 */
#include <stdarg.h>
#include <stdint.h>
#include <sys/syscall.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>

/* ---- DRM ioctl definitions (from drm.h / drm_mode.h) ---- */
#define DRM_IOCTL_BASE 'd'

#define MY_IOC(dir,type,nr,size) \
    (((dir)  << 30) | \
     ((type) << 8)  | \
     ((nr)   << 0)  | \
     ((size) << 16))
#define MY_IOWR(type,nr,sz) MY_IOC(3,(type),(nr),(sz))

/* DRM_IOCTL_MODE_GETPROPERTY = DRM_IOWR(0xAA, ...) */
struct drm_mode_get_property {
    uint64_t values_ptr;
    uint64_t enum_blob_ptr;
    uint32_t prop_id;
    uint32_t flags;
    char name[32];
    uint32_t count_values;
    uint32_t count_enum_blobs;
};
#define DRM_IOCTL_MODE_GETPROPERTY MY_IOWR(DRM_IOCTL_BASE, 0xAA, sizeof(struct drm_mode_get_property))

/* DRM_IOCTL_MODE_ATOMIC = DRM_IOWR(0xBC, ...) */
struct drm_mode_atomic {
    uint32_t flags;
    uint32_t count_objs;
    uint64_t objs_ptr;
    uint64_t count_props_ptr;
    uint64_t props_ptr;
    uint64_t prop_values_ptr;
    uint64_t reserved;
    uint64_t user_data;
};
#define DRM_IOCTL_MODE_ATOMIC MY_IOWR(DRM_IOCTL_BASE, 0xBC, sizeof(struct drm_mode_atomic))

/* DRM_IOCTL_MODE_SETPROPERTY = DRM_IOWR(0xAB, ...) - connector-specific */
struct drm_mode_connector_set_property {
    uint64_t value;
    uint32_t prop_id;
    uint32_t connector_id;
};
#define DRM_IOCTL_MODE_SETPROPERTY MY_IOWR(DRM_IOCTL_BASE, 0xAB, sizeof(struct drm_mode_connector_set_property))

/* DRM_IOCTL_MODE_OBJ_SETPROPERTY = DRM_IOWR(0xBA, ...) - generic object */
struct drm_mode_obj_set_property {
    uint64_t value;
    uint32_t prop_id;
    uint32_t obj_id;
};
#define DRM_IOCTL_MODE_OBJ_SETPROPERTY MY_IOWR(DRM_IOCTL_BASE, 0xBA, sizeof(struct drm_mode_obj_set_property))

/* DRM_IOCTL_MODE_ADDFB2 = DRM_IOWR(0xB8, ...) - add framebuffer with format */
struct drm_mode_fb_cmd2 {
    uint32_t fb_id;
    uint32_t width, height;
    uint32_t pixel_format;
    uint32_t flags;
    uint32_t handles[4];
    uint32_t pitches[4];
    uint32_t offsets[4];
    uint64_t modifier[4];
};
#define DRM_IOCTL_MODE_ADDFB2 MY_IOWR(DRM_IOCTL_BASE, 0xB8, sizeof(struct drm_mode_fb_cmd2))

/* ---- HDMI CSC register definitions (BCM2711 HDMI0) ---- */
/* ARM physical address of the CSC block in the HDMI encoder */
#define CSC_BASE        0xFEF00200

/* DRM atomic flags */
#define DRM_MODE_ATOMIC_TEST_ONLY 0x0100

/*
 * CSC override is DISABLED.  PGeneratord already performs RGB→YCbCr
 * conversion in its OpenGL fragment shader (RGBtoYCbCr function),
 * producing bit-perfect limited-range YCbCr output.  The kernel's
 * default CSC (identity matrix) passes this through unchanged.
 * Applying an additional hardware CSC would double-convert.
 *
 * The matrices and helper code below are preserved for reference
 * in case a future PGeneratord version changes behavior.
 */
#if 0  /* --- CSC override (disabled — shader handles conversion) --- */

/* RGB-to-YCbCr matrices, S2.13 fixed-point, CSC_CTL ORDER=3 (RBG):
 *   Rows = [Cr, Cb, Y], Columns = [R, B, G] */
static const uint32_t csc_bt709[6] = {
    0xFEB70E00, 0x2000F349, 0x0E00FCCB,
    0x2000F535, 0x01FA05D2, 0x04001394
};
static const uint32_t csc_bt2020[6] = {
    0xFEE00E00, 0x2000F320, 0x0E00FC17,
    0x2000F5E9, 0x01A00731, 0x0400128F
};
static int colorimetry = 0;
static int csc_active_format = -1;

#define WRITE_CSC_PATH "/usr/sbin/write_csc"
static void apply_csc_for_format(uint64_t format) {
    if (format == 0) { csc_active_format = 0; return; }
    const char *arg = colorimetry ? "bt2020" : "bt709";
    const char *name = colorimetry ? "BT.2020" : "BT.709";
    int pid = fork();
    if (pid == 0) {
        if (fork() == 0) {
            int i; for (i = 3; i < 64; i++) close(i);
            sleep(2);
            execl(WRITE_CSC_PATH, "write_csc", arg, (char *)0);
            _exit(127);
        }
        _exit(0);
    }
    if (pid > 0) { int status = 0; waitpid(pid, &status, 0); }
    csc_active_format = (int)format;
    write_log("DRM_OVERRIDE: CSC -> ");
    write_log(name);
    write_log(" YCbCr (deferred 2s)\n");
}

#endif /* --- end CSC override --- */

/* ---- CSC bypass via setuid helper ---- */
/* Forward declarations for utilities defined below */
static void write_log(const char *msg);
static void itoa_simple(uint64_t val, char *buf);
/*
 * The BCM2711 HDMI0 encoder has a hardware CSC at physical address
 * 0xFEF00200.  The vc4 kernel driver programs this CSC based on the
 * "rgb quant range" connector property:
 *   - Full (2):    identity matrix (passthrough)
 *   - Limited (1): full→limited range conversion (scale ≈ 0.856, offset ≈ 64)
 *   - Default (0): mode-dependent (CEA = Limited, IT = Full)
 *
 * PGeneratord and calibration software (CalMAN, LightSpace, HCFR) send
 * code values that are already in the correct range.  The hardware CSC
 * must be identity to avoid double conversion.
 *
 * Since PGeneratord runs as user pgenerator (no /dev/mem access),
 * we fork+exec a setuid-root helper (/usr/sbin/disable_csc) that
 * clears CSC_CTL bit 0 to bypass the CSC.  A double-fork with a
 * 1-second delay ensures the kernel has finished programming the CSC
 * registers before we override them.
 */
#define DISABLE_CSC_PATH "/usr/sbin/disable_csc"

static int csc_disable_done = 0;

static void csc_disable(void) {
    /* Fork → double-fork → sleep → exec helper.
     * The intermediate child exits immediately so the grandchild
     * is reparented to init, avoiding zombies. */
    int pid = fork();
    if (pid == 0) {
        if (fork() == 0) {
            int i;
            for (i = 3; i < 64; i++) close(i);
            usleep(500000); /* 500 ms — let kernel finish CSC programming */
            execl(DISABLE_CSC_PATH, "disable_csc", (char *)0);
            _exit(127);
        }
        _exit(0);
    }
    if (pid > 0) {
        int status = 0;
        waitpid(pid, &status, 0);
    }
    if (!csc_disable_done) {
        write_log("DRM_OVERRIDE: CSC disable scheduled (deferred 500ms)\n");
        csc_disable_done = 1;
    }
}

/* ---- State ---- */
static uint32_t max_bpc_prop_id = 0;
static uint64_t max_bpc_override = 0;
static uint32_t output_fmt_prop_id = 0;
static uint64_t output_fmt_override = 0;
static int output_fmt_found = 0;
static uint32_t dovi_meta_prop_id = 0;
static int dv_status = 0;
static int conf_read = 0;

/* ---- 10-bit HDR runtime binary patch ---- */
/*
 * PGeneratord is a non-PIE EXEC binary — all code and data addresses
 * are fixed.  We patch instructions in setup() at library load time
 * (constructor) to force the HDR 10-bit rendering path when max_bpc >= 10.
 *
 * Gate 1 — is_panel_hdr_dovi() EDID check:
 *   At 0x1ce684, a conditional branch (beq) skips to the HDR path only
 *   when the function returns 1.  The function fails on some TVs despite
 *   valid HDR Static Metadata in the EDID.  We patch beq -> unconditional
 *   branch (b) to always take the HDR path (0x1ce898).
 *
 * Gate 2 — isDoVi global variable check:
 *   At 0x1ce8c8, after logging "HDR panel detected", the code checks
 *   the isDoVi BSS variable.  When isDoVi==0 (EDID DV detection failed),
 *   it branches to 0x1ce950 which clears DV flags and calls
 *   SDRWindowSetup() — even though the panel supports HDR.  We patch
 *   the beq to NOP so the code falls through to the DV-off path, where
 *   is_std_DoVi==0 and dv_status==0 let it reach the avi_info check.
 *
 * Gate 3 — avi_info bpc check:
 *   At 0x1ce910, the code checks if the negotiated output bpc
 *   (avi_info[2]) equals 10 or 12.  Since PGeneratord forces max_bpc=8
 *   internally, this value is always 8.  We patch "cmp r3, #10" to
 *   "cmp r3, #8" so the 8-bit value triggers the 10-bit HDR path,
 *   which calls HDRWindowSetup() -> ARGB2101010 GBM surface.
 *
 * The ioctl hook does NOT write bit_depth or avi_info.  bit_depth
 * must stay at 8 (a value of 10 would redirect the dispatch to
 * 0x1ce9b8 which has a second unpatched avi_info check that fails).
 * avi_info[2] must stay at 8 to match the patched "cmp r3, #8".
 */

/* Fixed addresses in PGeneratord (EXEC, not PIE) */
#define PGEND_PANEL_CHECK_ADDR  ((volatile uint32_t *)0x001ce684)
#define PGEND_ISDOVI_CHECK_ADDR ((volatile uint32_t *)0x001ce8c8)
#define PGEND_BPC_CMP_ADDR     ((volatile uint32_t *)0x001ce910)
#define PGEND_BIT_DEPTH_ADDR   ((volatile int *)0x0021ABA4)
#define PGEND_AVI_BPC_ADDR     ((volatile int *)0x0021AB88)

/* Literal pool addresses containing GBM format constants */
#define PGEND_SDR_FMT_POOL     ((volatile uint32_t *)0x001cb560) /* SDRWindowSetup: gbm_surface_create format */
#define PGEND_SETUP_FMT_POOL   ((volatile uint32_t *)0x001cefe4) /* setup(): FindModifiers format arg */

/* GBM format constants */
#define GBM_FORMAT_ARGB8888    0x34325241  /* AR24 */
#define GBM_FORMAT_ARGB2101010 0x30334241  /* AB30 */

/* ARM instruction encodings */
#define ARM_BEQ_PANEL_HDR  0x0a000083  /* beq 0x1ce898 */
#define ARM_B_PANEL_HDR    0xea000083  /* b   0x1ce898 (unconditional) */
#define ARM_BEQ_ISDOVI     0x0a000020  /* beq 0x1ce950 */
#define ARM_NOP            0xe1a00000  /* mov r0, r0 (NOP) */
#define ARM_CMP_R3_10      0xe353000a  /* cmp r3, #10  */
#define ARM_CMP_R3_8       0xe3530008  /* cmp r3, #8   */

static int hdr_patched = 0;
static int setup_complete = 0;  /* set after first atomic commit succeeds */

static void patch_for_10bit_hdr(void) {
    if (max_bpc_override < 10 || hdr_patched) return;
    hdr_patched = 1;

    /* Both addresses are on the same 4K page (0x1ce000) */
    uintptr_t page = (uintptr_t)PGEND_PANEL_CHECK_ADDR & ~0xFFFu;

    if (mprotect((void *)page, 4096, PROT_READ | PROT_WRITE | PROT_EXEC) != 0) {
        write_log("DRM_OVERRIDE: mprotect failed for HDR patch\n");
        return;
    }

    /* Patch 1: bypass is_panel_hdr_dovi check — beq -> b (unconditional) */
    if (*PGEND_PANEL_CHECK_ADDR == ARM_BEQ_PANEL_HDR) {
        *PGEND_PANEL_CHECK_ADDR = ARM_B_PANEL_HDR;
        write_log("DRM_OVERRIDE: patched panel HDR bypass at 0x1ce684\n");
    } else {
        write_log("DRM_OVERRIDE: SKIP panel patch (unexpected insn)\n");
    }

    /* Patch 2: bypass isDoVi check — beq -> NOP
     * When isDoVi==0 (no DV detected from EDID), the beq at 0x1ce8c8
     * jumps to SDRWindowSetup.  We NOP it so the code falls through
     * to the DV-flag checks (is_std_DoVi==0, dv_status==0 pass)
     * and reaches the avi_info bpc check at 0x1ce910. */
    if (*PGEND_ISDOVI_CHECK_ADDR == ARM_BEQ_ISDOVI) {
        *PGEND_ISDOVI_CHECK_ADDR = ARM_NOP;
        write_log("DRM_OVERRIDE: patched isDoVi bypass at 0x1ce8c8\n");
    } else {
        write_log("DRM_OVERRIDE: SKIP isDoVi patch (unexpected insn)\n");
    }

    /* Patch 3: avi_info bpc — cmp r3, #10 -> cmp r3, #8
     * During initial setup, avi_info[2] is 8 (InitDRM sets it).
     * We patch the comparison to match the actual value (8),
     * directing to HDRWindowSetup() -> ARGB2101010. */
    if (*PGEND_BPC_CMP_ADDR == ARM_CMP_R3_10) {
        *PGEND_BPC_CMP_ADDR = ARM_CMP_R3_8;
        write_log("DRM_OVERRIDE: patched avi bpc check at 0x1ce910\n");
    } else {
        write_log("DRM_OVERRIDE: SKIP bpc patch (unexpected insn)\n");
    }

    /* Restore page protection */
    mprotect((void *)page, 4096, PROT_READ | PROT_EXEC);

    /* Flush instruction cache (ARM requirement) */
    __builtin___clear_cache((char *)page, (char *)page + 4096);

    /* Note: GBM format constant patches (SDRWindowSetup @ 0x1cb560,
     * FindModifiers @ 0x1cefe4) were removed — Mesa 21.2.4 vc4/v3d
     * doesn't support ARGB2101010 GBM surface allocation, causing
     * gbm_surface_create to return NULL and a SIGSEGV.
     * Native 10-bit is now handled by pgeneratord_10bit which uses
     * DRM dumb buffers with XRGB2101010, bypassing OpenGL entirely. */

    write_log("DRM_OVERRIDE: instruction patches applied\n");
}

/* Raw syscall wrapper (no glibc version dependency) */
static inline long raw_ioctl(int fd, unsigned long req, void *arg) {
    return syscall(SYS_ioctl, fd, req, arg);
}

static void write_log(const char *msg) {
    write(2, msg, strlen(msg));
}

static void itoa_simple(uint64_t val, char *buf) {
    char tmp[24];
    int i = 0;
    if (val == 0) { buf[0] = '0'; buf[1] = 0; return; }
    while (val > 0) { tmp[i++] = '0' + (val % 10); val /= 10; }
    int j = 0;
    while (i > 0) { buf[j++] = tmp[--i]; }
    buf[j] = 0;
}

/* Read config values from PGenerator.conf */
static void read_config(void) {
    if (conf_read) return;
    conf_read = 1;
    int fd = open("/etc/PGenerator/PGenerator.conf", O_RDONLY);
    if (fd < 0) return;
    char buf[4096];
    int n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return;
    buf[n] = 0;

    char *p = buf;
    while (*p) {
        if (p[0] == 'm' && p[1] == 'a' && p[2] == 'x' && p[3] == '_' &&
            p[4] == 'b' && p[5] == 'p' && p[6] == 'c' && p[7] == '=') {
            char *v = p + 8;
            max_bpc_override = 0;
            while (*v >= '0' && *v <= '9') {
                max_bpc_override = max_bpc_override * 10 + (*v - '0');
                v++;
            }
        }
        if (p[0] == 'd' && p[1] == 'v' && p[2] == '_' && p[3] == 's' &&
            p[4] == 't' && p[5] == 'a' && p[6] == 't' && p[7] == 'u' &&
            p[8] == 's' && p[9] == '=') {
            dv_status = (p[10] - '0');
        }
        if (p[0] == 'c' && p[1] == 'o' && p[2] == 'l' && p[3] == 'o' &&
            p[4] == 'r' && p[5] == '_' && p[6] == 'f' && p[7] == 'o' &&
            p[8] == 'r' && p[9] == 'm' && p[10] == 'a' && p[11] == 't' &&
            p[12] == '=') {
            char *v = p + 13;
            output_fmt_override = 0;
            while (*v >= '0' && *v <= '9') {
                output_fmt_override = output_fmt_override * 10 + (*v - '0');
                v++;
            }
            output_fmt_found = 1;
        }
        while (*p && *p != '\n') p++;
        if (*p == '\n') p++;
    }

    if (max_bpc_override > 0) {
        char num[24];
        itoa_simple(max_bpc_override, num);
        write_log("DRM_OVERRIDE: max_bpc=");
        write_log(num);
        write_log("\n");
    }
    if (output_fmt_found) {
        char num[24];
        itoa_simple(output_fmt_override, num);
        write_log("DRM_OVERRIDE: color_format=");
        write_log(num);
        write_log("\n");
    }
    {
        char num[24];
        itoa_simple(dv_status, num);
        write_log("DRM_OVERRIDE: dv_status=");
        write_log(num);
        write_log("\n");
    }
}

/* Constructor: runs before main() — apply config and binary patches */
__attribute__((constructor))
static void drm_override_init(void) {
    read_config();
    patch_for_10bit_hdr();
}

/* Override helpers — log only when value actually changes */
static void override_max_bpc(uint64_t *value, const char *source) {
    if (max_bpc_prop_id && max_bpc_override > 0 && *value != max_bpc_override) {
        char old_val[24], new_val[24];
        itoa_simple(*value, old_val);
        itoa_simple(max_bpc_override, new_val);
        write_log("DRM_OVERRIDE: max_bpc ");
        write_log(old_val);
        write_log(" -> ");
        write_log(new_val);
        if (source) { write_log(" ("); write_log(source); write_log(")"); }
        write_log("\n");
        *value = max_bpc_override;
    }
}

static void override_output_fmt(uint64_t *value, const char *source) {
    if (output_fmt_prop_id && output_fmt_found && *value != output_fmt_override) {
        char old_val[24], new_val[24];
        itoa_simple(*value, old_val);
        itoa_simple(output_fmt_override, new_val);
        write_log("DRM_OVERRIDE: output_format ");
        write_log(old_val);
        write_log(" -> ");
        write_log(new_val);
        if (source) { write_log(" ("); write_log(source); write_log(")"); }
        write_log("\n");
        *value = output_fmt_override;
    }
}

/* ---- Main ioctl interception ---- */
int ioctl(int fd, unsigned long request, ...) {
    va_list ap;
    va_start(ap, request);
    void *arg = va_arg(ap, void *);
    va_end(ap);

    read_config();

    /* DO NOT write bit_depth or avi_info here.
     *
     * bit_depth: Must stay at 8 (set by InitDRM).  When bit_depth==10,
     * the dispatch at 0x1ce648 jumps to 0x1ce9b8 which has a SECOND
     * avi_info[2]==10 check (at 0x1ce9c4) that we haven't patched.
     * With bit_depth=8, Gate 1 falls through to 0x1ce670 where:
     *   - Gate 2 (panel bypass, patched) always jumps to HDR path
     *   - Gate 3 (cmp patched to #8) matches avi_info[2]=8
     *   → HDRWindowSetup() creates 10-bit ARGB2101010 surface.
     *
     * avi_info[2]: Must stay at 8 to match the patched "cmp r3, #8"
     * at 0x1ce910.  Once HDRWindowSetup creates the 10-bit GBM
     * surface, the EGL/OpenGL pipeline handles 10-bit natively. */

    /* Log framebuffer creation to diagnose GBM surface format */
    if (request == DRM_IOCTL_MODE_ADDFB2) {
        struct drm_mode_fb_cmd2 *fb = (struct drm_mode_fb_cmd2 *)arg;
        char fmt[5];
        fmt[0] = (fb->pixel_format >>  0) & 0xFF;
        fmt[1] = (fb->pixel_format >>  8) & 0xFF;
        fmt[2] = (fb->pixel_format >> 16) & 0xFF;
        fmt[3] = (fb->pixel_format >> 24) & 0xFF;
        fmt[4] = 0;
        char w_s[24], h_s[24];
        itoa_simple(fb->width, w_s);
        itoa_simple(fb->height, h_s);
        write_log("DRM_OVERRIDE: ADDFB2 ");
        write_log(w_s); write_log("x"); write_log(h_s);
        write_log(" fmt="); write_log(fmt);
        write_log("\n");
    }

    /* Intercept DRM_IOCTL_MODE_GETPROPERTY to discover property IDs */
    if (request == DRM_IOCTL_MODE_GETPROPERTY) {
        long ret = raw_ioctl(fd, request, arg);
        if (ret == 0) {
            struct drm_mode_get_property *prop = (struct drm_mode_get_property *)arg;
            if (strcmp(prop->name, "max bpc") == 0) {
                max_bpc_prop_id = prop->prop_id;
                char num[24];
                itoa_simple(prop->prop_id, num);
                write_log("DRM_OVERRIDE: found max_bpc prop_id=");
                write_log(num);
                write_log("\n");
            }
            if (strcmp(prop->name, "output format") == 0) {
                output_fmt_prop_id = prop->prop_id;
                char num[24];
                itoa_simple(prop->prop_id, num);
                write_log("DRM_OVERRIDE: found output_format prop_id=");
                write_log(num);
                write_log("\n");
            }
            if (strcmp(prop->name, "DOVI_OUTPUT_METADATA") == 0) {
                dovi_meta_prop_id = prop->prop_id;
                char num[24];
                itoa_simple(prop->prop_id, num);
                write_log("DRM_OVERRIDE: found DOVI_OUTPUT_METADATA prop_id=");
                write_log(num);
                write_log("\n");
            }
        }
        return ret;
    }

    /* Intercept DRM_IOCTL_MODE_ATOMIC — override property values */
    if (request == DRM_IOCTL_MODE_ATOMIC) {
        struct drm_mode_atomic *atomic = (struct drm_mode_atomic *)arg;
        uint32_t *count_props = (uint32_t *)(uintptr_t)atomic->count_props_ptr;
        uint32_t *props = (uint32_t *)(uintptr_t)atomic->props_ptr;
        uint64_t *values = (uint64_t *)(uintptr_t)atomic->prop_values_ptr;

        uint32_t total = 0, i;
        for (i = 0; i < atomic->count_objs; i++)
            total += count_props[i];

        /* Apply overrides */
        for (i = 0; i < total; i++) {
            if (max_bpc_prop_id && props[i] == max_bpc_prop_id)
                override_max_bpc(&values[i], "atomic");
            if (output_fmt_prop_id && props[i] == output_fmt_prop_id)
                override_output_fmt(&values[i], "atomic");
            /* Block DOVI_OUTPUT_METADATA when dv_status=0 */
            if (dovi_meta_prop_id && props[i] == dovi_meta_prop_id && dv_status == 0) {
                if (values[i] != 0) {
                    char old_val[24];
                    itoa_simple(values[i], old_val);
                    write_log("DRM_OVERRIDE: blocking DOVI blob_id=");
                    write_log(old_val);
                    write_log(" -> 0 (dv_status=0, atomic)\n");
                    values[i] = 0;
                }
            }
        }

        long ret = raw_ioctl(fd, request, arg);

        /* After successful non-test commit, disable hardware CSC to
         * prevent double range conversion.  The kernel may have just
         * reprogrammed the CSC for limited range — clear the enable
         * bit so pixel values pass through unchanged. */
        if (ret == 0 && !(atomic->flags & DRM_MODE_ATOMIC_TEST_ONLY)) {
            if (!setup_complete) {
                setup_complete = 1;
                write_log("DRM_OVERRIDE: setup complete — enabling avi_info writes\n");
            }
            csc_disable();
        }

        return ret;
    }

    /* Intercept DRM_IOCTL_MODE_SETPROPERTY (connector-specific, 0xAB) */
    if (request == DRM_IOCTL_MODE_SETPROPERTY) {
        struct drm_mode_connector_set_property *sp =
            (struct drm_mode_connector_set_property *)arg;
        if (max_bpc_prop_id && sp->prop_id == max_bpc_prop_id)
            override_max_bpc(&sp->value, "setprop_conn");
        if (output_fmt_prop_id && sp->prop_id == output_fmt_prop_id)
            override_output_fmt(&sp->value, "setprop_conn");
    }

    /* Intercept DRM_IOCTL_MODE_OBJ_SETPROPERTY (generic object, 0xBA) */
    if (request == DRM_IOCTL_MODE_OBJ_SETPROPERTY) {
        struct drm_mode_obj_set_property *sp =
            (struct drm_mode_obj_set_property *)arg;
        if (max_bpc_prop_id && sp->prop_id == max_bpc_prop_id)
            override_max_bpc(&sp->value, "setprop_obj");
        if (output_fmt_prop_id && sp->prop_id == output_fmt_prop_id)
            override_output_fmt(&sp->value, "setprop_obj");
        if (dovi_meta_prop_id && sp->prop_id == dovi_meta_prop_id && dv_status == 0) {
            if (sp->value != 0) {
                write_log("DRM_OVERRIDE: blocking DOVI blob (dv_status=0, setprop_obj)\n");
                sp->value = 0;
            }
        }
    }

    return raw_ioctl(fd, request, arg);
}
