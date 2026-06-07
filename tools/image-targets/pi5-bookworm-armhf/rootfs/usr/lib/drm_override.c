/*
 * LD_PRELOAD library to override DRM connector properties for HDMI output.
 *
 * Intercepts ioctl() at the syscall level to avoid glibc version
 * dependency issues (Pi has glibc 2.21, dlsym needs 2.34).
 *
 * Monitors DRM_IOCTL_MODE_GETPROPERTY to discover property IDs for
 * "max bpc", "output format", "Colorimetry", "rgb quant range", and
 * "DOVI_OUTPUT_METADATA", then modifies
 * DRM_IOCTL_MODE_ATOMIC, DRM_IOCTL_MODE_SETPROPERTY, and
 * DRM_IOCTL_MODE_OBJ_SETPROPERTY calls to override values from
 * PGenerator.conf.
 *
 * DOLBY VISION BLOB HANDLING:
 * The current PGeneratord.dv already creates DOVI_OUTPUT_METADATA blobs when
 * DV is enabled. Preserve those renderer-provided blobs whenever they are
 * present in an atomic commit. This library only falls back to a fixed blob
 * when a DV commit omits the property entirely.
 *
 * REDUNDANCY SUPPRESSION:
 * PGeneratord re-submits connector properties (output_format, max_bpc,
 * Colorimetry) on every atomic page flip, even when values are unchanged.
 * The vc4 kernel driver re-evaluates the connector state and re-sends
 * AVI/DRM InfoFrames on each such commit, triggering full modesets at
 * ~30ms intervals.  This InfoFrame storm locks up LG TVs.
 *
 * Fix: after applying overrides, we REMOVE redundant connector properties
 * from the atomic commit arrays entirely (compact the arrays and adjust
 * count_props/count_objs).  This ensures page flips only carry plane/CRTC
 * changes and don't trigger InfoFrame re-transmission.
 *
 * NOTE: No CSC (Color Space Converter) override is performed.
 * PGeneratord handles RGB-to-YCbCr conversion in its OpenGL fragment
 * shader, producing bit-perfect limited-range YCbCr output.
 *
 * Cross-compile:
 *   arm-linux-gnueabihf-gcc -shared -fPIC -o drm_override.so drm_override.c
 */
#include <stdarg.h>
#include <stdint.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <errno.h>

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

/* DRM_IOCTL_MODE_GETCONNECTOR = DRM_IOWR(0xA7, ...) */
struct drm_mode_get_connector {
    uint64_t encoders_ptr;
    uint64_t modes_ptr;
    uint64_t props_ptr;
    uint64_t prop_values_ptr;
    uint32_t count_modes;
    uint32_t count_props;
    uint32_t count_encoders;
    uint32_t encoder_id;
    uint32_t connector_id;
    uint32_t connector_type;
    uint32_t connector_type_id;
    uint32_t connection;
    uint32_t mm_width;
    uint32_t mm_height;
    uint32_t subpixel;
    uint32_t pad;
};
#define DRM_IOCTL_MODE_GETCONNECTOR MY_IOWR(DRM_IOCTL_BASE, 0xA7, sizeof(struct drm_mode_get_connector))
#define DRM_MODE_CONNECTED 1

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

/* DRM_IOCTL_MODE_CREATEPROPBLOB = DRM_IOWR(0xBD, ...) */
struct drm_mode_create_blob {
    uint64_t data;
    uint32_t length;
    uint32_t blob_id;
};
#define DRM_IOCTL_MODE_CREATEPROPBLOB MY_IOWR(DRM_IOCTL_BASE, 0xBD, sizeof(struct drm_mode_create_blob))

/* DRM atomic flags */
#define DRM_MODE_ATOMIC_TEST_ONLY     0x0100
#define DRM_MODE_ATOMIC_ALLOW_MODESET (1 << 10)

/* ---- State ---- */
static uint32_t max_bpc_prop_id = 0;
static uint64_t max_bpc_override = 0;
static uint32_t output_fmt_prop_id = 0;
static uint64_t output_fmt_override = 0;
static int output_fmt_found = 0;
static uint32_t colorimetry_prop_id = 0;
static uint64_t colorimetry_override = 0;
static int colorimetry_found = 0;
static int colorimetry_is_colorspace = 0;
static uint32_t rgb_qr_prop_id = 0;
static uint64_t rgb_qr_override = 0;
static int rgb_qr_found = 0;
static int rgb_qr_is_broadcast = 0;
static uint32_t dovi_meta_prop_id = 0;
static uint32_t hdr_meta_prop_id = 0;
static int is_hdr = 0;
static int hdr_eotf = 0;
static uint64_t hdr_primaries = 1;
static uint32_t hdr_min_luma_raw = 0;
static uint16_t hdr_max_luma = 1000;
static uint16_t hdr_max_cll = 1000;
static uint16_t hdr_max_fall = 400;
static int dv_status = 0;
static int dv_interface = 0;     /* 0=Standard, 1=Low-Latency */
static int dv_map_mode = 2;      /* 0=Perceptual, 1=Absolute, 2=Relative */
static int conf_read = 0;

/* DOVI blob injection state */
static uint32_t dovi_blob_id = 0;       /* fallback blob created by us */
static uint32_t hdr_blob_id = 0;        /* HDR static metadata blob */
static uint32_t hdr_injection_count = 0;
static int dovi_injected = 0;           /* 1 after successful fallback injection */
static uint32_t connector_id = 0;       /* discovered from atomic commits */
static int dovi_passthrough_logged = 0; /* log renderer-owned DOVI once */
static int renderer_dovi_seen = 0;      /* renderer supplied DOVI at least once */

/*
 * Redundancy suppression -- track last-committed values.
 * Initial value of (uint64_t)-1 ensures the first real set always passes.
 */
static uint64_t last_output_fmt = (uint64_t)-1;
static uint64_t last_max_bpc = (uint64_t)-1;
static uint64_t last_colorimetry = (uint64_t)-1;
static uint64_t last_rgb_qr = (uint64_t)-1;
static uint64_t last_dovi = (uint64_t)-1;
static uint64_t last_hdr = (uint64_t)-1;
static uint32_t suppressed_commits = 0;

/* ---- Logging to file ---- */
static int log_fd = -2; /* -2 = not yet opened */

static void open_log(void) {
    if (log_fd != -2) return;
    log_fd = open("/tmp/drm_override.log",
                  O_WRONLY | O_CREAT | O_APPEND, 0644);
}

/* Raw syscall wrapper (no glibc version dependency) */
static inline long raw_ioctl(int fd, unsigned long req, void *arg) {
    return syscall(SYS_ioctl, fd, req, arg);
}

static void write_log(const char *msg) {
    open_log();
    if (log_fd >= 0)
        write(log_fd, msg, strlen(msg));
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

static uint64_t parse_uint_value(const char *v) {
    uint64_t out = 0;
    while (*v >= '0' && *v <= '9') {
        out = out * 10 + (*v - '0');
        v++;
    }
    return out;
}

static uint32_t parse_decimal_10000_value(const char *v) {
    uint32_t whole = 0;
    uint32_t frac = 0;
    uint32_t scale = 10000;

    while (*v >= '0' && *v <= '9') {
        whole = whole * 10 + (*v - '0');
        v++;
    }
    if (*v == '.') {
        v++;
        while (*v >= '0' && *v <= '9' && scale > 1) {
            scale /= 10;
            frac += (uint32_t)(*v - '0') * scale;
            v++;
        }
    }
    return whole * 10000 + frac;
}

static void put_le16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v & 0xff);
    p[1] = (uint8_t)((v >> 8) & 0xff);
}

static void put_le32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v & 0xff);
    p[1] = (uint8_t)((v >> 8) & 0xff);
    p[2] = (uint8_t)((v >> 16) & 0xff);
    p[3] = (uint8_t)((v >> 24) & 0xff);
}

static uint64_t effective_colorimetry_override(void) {
    uint64_t fmt = output_fmt_found ? output_fmt_override : 0;

    if (!colorimetry_is_colorspace)
        return colorimetry_override;
    if (colorimetry_override == 2 && fmt == 0)
        return 0;
    if (colorimetry_override == 2)
        return 2;
    if (colorimetry_override == 9 && fmt == 0)
        return 9;
    if (colorimetry_override == 9)
        return 10;
    return colorimetry_override;
}

static uint64_t effective_rgb_qr_override(void) {
    if (!rgb_qr_is_broadcast)
        return rgb_qr_override;
    if (rgb_qr_override == 1)
        return 2;
    if (rgb_qr_override == 2)
        return 1;
    return 0;
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
            max_bpc_override = parse_uint_value(v);
        }
        if (p[0] == 'i' && p[1] == 's' && p[2] == '_' && p[3] == 'h' &&
            p[4] == 'd' && p[5] == 'r' && p[6] == '=') {
            is_hdr = (p[7] - '0');
        }
        if (p[0] == 'e' && p[1] == 'o' && p[2] == 't' && p[3] == 'f' &&
            p[4] == '=') {
            hdr_eotf = (int)parse_uint_value(p + 5);
        }
        if (p[0] == 'p' && p[1] == 'r' && p[2] == 'i' && p[3] == 'm' &&
            p[4] == 'a' && p[5] == 'r' && p[6] == 'i' && p[7] == 'e' &&
            p[8] == 's' && p[9] == '=') {
            hdr_primaries = parse_uint_value(p + 10);
        }
        if (p[0] == 'm' && p[1] == 'i' && p[2] == 'n' && p[3] == '_' &&
            p[4] == 'l' && p[5] == 'u' && p[6] == 'm' && p[7] == 'a' &&
            p[8] == '=') {
            hdr_min_luma_raw = parse_decimal_10000_value(p + 9);
        }
        if (p[0] == 'm' && p[1] == 'a' && p[2] == 'x' && p[3] == '_' &&
            p[4] == 'l' && p[5] == 'u' && p[6] == 'm' && p[7] == 'a' &&
            p[8] == '=') {
            hdr_max_luma = (uint16_t)parse_uint_value(p + 9);
        }
        if (p[0] == 'm' && p[1] == 'a' && p[2] == 'x' && p[3] == '_' &&
            p[4] == 'c' && p[5] == 'l' && p[6] == 'l' && p[7] == '=') {
            hdr_max_cll = (uint16_t)parse_uint_value(p + 8);
        }
        if (p[0] == 'm' && p[1] == 'a' && p[2] == 'x' && p[3] == '_' &&
            p[4] == 'f' && p[5] == 'a' && p[6] == 'l' && p[7] == 'l' &&
            p[8] == '=') {
            hdr_max_fall = (uint16_t)parse_uint_value(p + 9);
        }
        if (p[0] == 'd' && p[1] == 'v' && p[2] == '_' && p[3] == 's' &&
            p[4] == 't' && p[5] == 'a' && p[6] == 't' && p[7] == 'u' &&
            p[8] == 's' && p[9] == '=') {
            dv_status = (p[10] - '0');
        }
        if (p[0] == 'd' && p[1] == 'v' && p[2] == '_' && p[3] == 'i' &&
            p[4] == 'n' && p[5] == 't' && p[6] == 'e' && p[7] == 'r' &&
            p[8] == 'f' && p[9] == 'a' && p[10] == 'c' && p[11] == 'e' &&
            p[12] == '=') {
            dv_interface = (p[13] - '0');
        }
        if (p[0] == 'd' && p[1] == 'v' && p[2] == '_' && p[3] == 'm' &&
            p[4] == 'a' && p[5] == 'p' && p[6] == '_' && p[7] == 'm' &&
            p[8] == 'o' && p[9] == 'd' && p[10] == 'e' && p[11] == '=') {
            dv_map_mode = (int)parse_uint_value(p + 12);
        }
        if (p[0] == 'c' && p[1] == 'o' && p[2] == 'l' && p[3] == 'o' &&
            p[4] == 'r' && p[5] == 'i' && p[6] == 'm' && p[7] == 'e' &&
            p[8] == 't' && p[9] == 'r' && p[10] == 'y' && p[11] == '=') {
            char *v = p + 12;
            colorimetry_override = parse_uint_value(v);
            colorimetry_found = 1;
        }
        if (p[0] == 'r' && p[1] == 'g' && p[2] == 'b' && p[3] == '_' &&
            p[4] == 'q' && p[5] == 'u' && p[6] == 'a' && p[7] == 'n' &&
            p[8] == 't' && p[9] == '_' && p[10] == 'r' && p[11] == 'a' &&
            p[12] == 'n' && p[13] == 'g' && p[14] == 'e' && p[15] == '=') {
            char *v = p + 16;
            rgb_qr_override = parse_uint_value(v);
            rgb_qr_found = 1;
        }
        if (p[0] == 'c' && p[1] == 'o' && p[2] == 'l' && p[3] == 'o' &&
            p[4] == 'r' && p[5] == '_' && p[6] == 'f' && p[7] == 'o' &&
            p[8] == 'r' && p[9] == 'm' && p[10] == 'a' && p[11] == 't' &&
            p[12] == '=') {
            char *v = p + 13;
            output_fmt_override = parse_uint_value(v);
            output_fmt_found = 1;
        }
        while (*p && *p != '\n') p++;
        if (*p == '\n') p++;
    }

    if (dv_status == 1) {
        max_bpc_override = 8;
        output_fmt_override = 0;
        output_fmt_found = 1;
        colorimetry_override = 9;
        colorimetry_found = 1;
        rgb_qr_override = 2;
        rgb_qr_found = 1;
        write_log("DRM_OVERRIDE: Dolby Vision forcing RGB Full 8-bit transport\n");
    }

    if (max_bpc_override > 0) {
        char num[24];
        itoa_simple(max_bpc_override, num);
        write_log("DRM_OVERRIDE: config max_bpc=");
        write_log(num);
        write_log("\n");
    }
    if (output_fmt_found) {
        char num[24];
        itoa_simple(output_fmt_override, num);
        write_log("DRM_OVERRIDE: config color_format=");
        write_log(num);
        write_log("\n");
    }
    if (colorimetry_found) {
        char num[24];
        itoa_simple(colorimetry_override, num);
        write_log("DRM_OVERRIDE: config colorimetry=");
        write_log(num);
        write_log("\n");
    }
    if (rgb_qr_found) {
        char num[24];
        itoa_simple(rgb_qr_override, num);
        write_log("DRM_OVERRIDE: config rgb_quant_range=");
        write_log(num);
        write_log("\n");
    }
    {
        char num[24];
        itoa_simple(is_hdr, num);
        write_log("DRM_OVERRIDE: config is_hdr=");
        write_log(num);
        write_log(" eotf=");
        itoa_simple(hdr_eotf, num);
        write_log(num);
        write_log("\n");
    }
    {
        char num[24];
        itoa_simple(dv_status, num);
        write_log("DRM_OVERRIDE: config dv_status=");
        write_log(num);
        write_log("\n");
    }
    {
        char num[24];
        itoa_simple(dv_interface, num);
        write_log("DRM_OVERRIDE: config dv_interface=");
        write_log(num);
        write_log(" (");
        write_log(dv_interface == 0 ? "Standard" : "Low-Latency");
        write_log(")\n");
    }
}

/* Override helpers -- log only when value actually changes */
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

static void override_colorimetry(uint64_t *value, const char *source) {
    uint64_t desired = effective_colorimetry_override();
    if (colorimetry_prop_id && colorimetry_found && *value != desired) {
        char old_val[24], new_val[24];
        itoa_simple(*value, old_val);
        itoa_simple(desired, new_val);
        write_log("DRM_OVERRIDE: Colorimetry ");
        write_log(old_val);
        write_log(" -> ");
        write_log(new_val);
        if (source) { write_log(" ("); write_log(source); write_log(")"); }
        write_log("\n");
        *value = desired;
    }
}

static void override_rgb_qr(uint64_t *value, const char *source) {
    uint64_t desired = effective_rgb_qr_override();
    if (rgb_qr_prop_id && rgb_qr_found && *value != desired) {
        char old_val[24], new_val[24];
        itoa_simple(*value, old_val);
        itoa_simple(desired, new_val);
        write_log("DRM_OVERRIDE: rgb_quant_range ");
        write_log(old_val);
        write_log(" -> ");
        write_log(new_val);
        if (source) { write_log(" ("); write_log(source); write_log(")"); }
        write_log("\n");
        *value = desired;
    }
}

/*
 * Check if a property ID is one we track for redundancy suppression.
 */
static int is_tracked_prop(uint32_t prop_id) {
    if (max_bpc_prop_id && prop_id == max_bpc_prop_id) return 1;
    if (output_fmt_prop_id && prop_id == output_fmt_prop_id) return 1;
    if (colorimetry_prop_id && prop_id == colorimetry_prop_id) return 1;
    if (rgb_qr_prop_id && prop_id == rgb_qr_prop_id) return 1;
    if (dv_status == 1 && dovi_meta_prop_id && prop_id == dovi_meta_prop_id) return 1;
    return 0;
}

/*
 * Check if a tracked property should be suppressed (value unchanged).
 * Updates last-committed value when not suppressed.
 * Returns 1 to suppress, 0 to keep.
 */
static int should_suppress(uint32_t prop_id, uint64_t value) {
    if (max_bpc_prop_id && prop_id == max_bpc_prop_id) {
        if (value == last_max_bpc) return 1;
        last_max_bpc = value;
        return 0;
    }
    if (output_fmt_prop_id && prop_id == output_fmt_prop_id) {
        if (value == last_output_fmt) return 1;
        last_output_fmt = value;
        return 0;
    }
    if (colorimetry_prop_id && prop_id == colorimetry_prop_id) {
        if (value == last_colorimetry) return 1;
        last_colorimetry = value;
        return 0;
    }
    if (rgb_qr_prop_id && prop_id == rgb_qr_prop_id) {
        if (value == last_rgb_qr) return 1;
        last_rgb_qr = value;
        return 0;
    }
    if (dovi_meta_prop_id && prop_id == dovi_meta_prop_id) {
        if (value == last_dovi) return 1;
        last_dovi = value;
        return 0;
    }
    return 0;
}

static void log_display_prop_update(uint32_t obj_id, uint32_t prop_id,
                                    uint64_t value) {
    char num[24];
    write_log("DRM_OVERRIDE: display prop obj=");
    itoa_simple(obj_id, num);
    write_log(num);
    write_log(" prop=");
    itoa_simple(prop_id, num);
    write_log(num);
    write_log(" value=");
    itoa_simple(value, num);
    write_log(num);
    write_log("\n");
}

static void reset_last_connector_overrides(void) {
    last_output_fmt = (uint64_t)-1;
    last_max_bpc = (uint64_t)-1;
    last_colorimetry = (uint64_t)-1;
    last_rgb_qr = (uint64_t)-1;
    last_dovi = (uint64_t)-1;
    last_hdr = (uint64_t)-1;
    hdr_injection_count = 0;
}

static uint32_t create_hdr_blob(int fd) {
    if (hdr_blob_id) return hdr_blob_id;
    if (!is_hdr || dv_status == 1 || hdr_eotf <= 0)
        return 0;

    uint8_t metadata[32];
    for (int i = 0; i < 32; i++)
        metadata[i] = 0;

    put_le32(metadata + 0, 0);
    metadata[4] = (uint8_t)hdr_eotf;
    metadata[5] = 0;

    if (hdr_eotf != 3) {
        if (hdr_primaries == 2) {
            put_le16(metadata + 6, 13250);
            put_le16(metadata + 8, 34500);
            put_le16(metadata + 10, 7500);
            put_le16(metadata + 12, 3000);
            put_le16(metadata + 14, 34000);
            put_le16(metadata + 16, 16000);
        } else if (hdr_primaries == 0) {
            put_le16(metadata + 6, 15000);
            put_le16(metadata + 8, 30000);
            put_le16(metadata + 10, 7500);
            put_le16(metadata + 12, 3000);
            put_le16(metadata + 14, 32000);
            put_le16(metadata + 16, 16500);
        } else {
            put_le16(metadata + 6, 8500);
            put_le16(metadata + 8, 39850);
            put_le16(metadata + 10, 6550);
            put_le16(metadata + 12, 2300);
            put_le16(metadata + 14, 35400);
            put_le16(metadata + 16, 14600);
        }
        put_le16(metadata + 18, 15635);
        put_le16(metadata + 20, 16450);
        put_le16(metadata + 22, hdr_max_luma);
        put_le16(metadata + 24, (uint16_t)hdr_min_luma_raw);
        put_le16(metadata + 26, hdr_max_cll);
        put_le16(metadata + 28, hdr_max_fall);
    }

    struct drm_mode_create_blob cb;
    cb.data = (uint64_t)(uintptr_t)metadata;
    cb.length = sizeof(metadata);
    cb.blob_id = 0;
    long ret = raw_ioctl(fd, DRM_IOCTL_MODE_CREATEPROPBLOB, &cb);
    if (ret != 0) {
        write_log("DRM_OVERRIDE: HDR CREATEPROPBLOB failed\n");
        return 0;
    }
    hdr_blob_id = cb.blob_id;
    {
        char num[24];
        write_log("DRM_OVERRIDE: created HDR blob_id=");
        itoa_simple(hdr_blob_id, num);
        write_log(num);
        write_log(" eotf=");
        itoa_simple((uint64_t)hdr_eotf, num);
        write_log(num);
        write_log("\n");
    }
    return hdr_blob_id;
}

/*
 * Create the fallback DOVI_OUTPUT_METADATA blob (one-time).
 * Returns blob_id, or 0 on failure.
 *
 * Keep this only as a last-resort fallback for commits that omit
 * DOVI_OUTPUT_METADATA entirely.
 *
 * The Pi5 kernel patch reads this as struct vc4_dovi_output_metadata:
 *   bytes 0-3:  Dolby OUI, little-endian
 *   byte 4:     DV status
 *   byte 5:     interface flag (0=Standard, 1=Low-Latency)
 *   bytes 6-7:  backlight metadata
 *   byte 8:     aux runmode / source mapping mode
 *   bytes 9-10: aux version/debug
 *   byte 11:    struct padding
 */
static uint32_t create_dovi_blob(int fd) {
    if (dovi_blob_id) return dovi_blob_id;

    uint8_t metadata[12] = {
        0x46, 0xD0, 0x00, 0x00, /* Dolby OUI 00-D0-46 (LE u32) -> frame.oui */
        0x01,  /* dv_status */
        0x00,  /* interface flag, filled from config below */
        0x00, 0x00, 0x00, 0x00, 0x00,
        0x00
    };
    metadata[5] = dv_interface ? 0x01 : 0x00;
    metadata[8] = (uint8_t)(dv_map_mode & 0xff);

    struct drm_mode_create_blob cb;
    cb.data = (uint64_t)(uintptr_t)metadata;
    cb.length = sizeof(metadata);
    cb.blob_id = 0;
    long ret = raw_ioctl(fd, DRM_IOCTL_MODE_CREATEPROPBLOB, &cb);
    if (ret != 0) {
        write_log("DRM_OVERRIDE: DOVI CREATEPROPBLOB failed\n");
        return 0;
    }
    dovi_blob_id = cb.blob_id;
    {
        char num[24];
        itoa_simple(dovi_blob_id, num);
        write_log("DRM_OVERRIDE: created DOVI blob_id=");
        write_log(num);
        write_log(dv_interface ? " (Low-Latency)" : " (Standard)");
        write_log(" bytes=");
        for (int i = 0; i < 12; i++) {
            char hex[4];
            hex[0] = "0123456789abcdef"[(metadata[i] >> 4) & 0xF];
            hex[1] = "0123456789abcdef"[metadata[i] & 0xF];
            hex[2] = ' ';
            hex[3] = 0;
            write_log(hex);
        }
        write_log("\n");
    }
    return dovi_blob_id;
}

/*
 * Inject DOVI_OUTPUT_METADATA into an atomic commit in-place.
 *
 * We cannot expand the binary's original arrays, so we copy them into
 * static buffers, add the DOVI entry, and re-point the atomic struct.
 * Max 16 objects / 64 total properties should be more than enough.
 */
#define MAX_ATOMIC_OBJS  16
#define MAX_ATOMIC_PROPS 64
static uint32_t inj_objs[MAX_ATOMIC_OBJS];
static uint32_t inj_count_props[MAX_ATOMIC_OBJS];
static uint32_t inj_props[MAX_ATOMIC_PROPS];
static uint64_t inj_values[MAX_ATOMIC_PROPS];

static int ensure_connector_overrides(struct drm_mode_atomic *atomic,
                                      uint32_t dovi_blob,
                                      uint32_t hdr_blob,
                                      const char *reason) {
    if (!connector_id)
        return 0;

    uint32_t *orig_objs = (uint32_t *)(uintptr_t)atomic->objs_ptr;
    uint32_t *orig_cnts = (uint32_t *)(uintptr_t)atomic->count_props_ptr;
    uint32_t *orig_props = (uint32_t *)(uintptr_t)atomic->props_ptr;
    uint64_t *orig_values = (uint64_t *)(uintptr_t)atomic->prop_values_ptr;
    uint32_t add_props[6];
    uint64_t add_values[6];
    uint32_t add_count = 0;
    uint32_t total = 0;
    int conn_obj_idx = -1;
    uint32_t conn_prop_offset = 0;
    uint32_t prop_offset = 0;
    int has_max_bpc = 0;
    int has_output_fmt = 0;
    int has_colorimetry = 0;
    int has_rgb_qr = 0;
    int has_dovi = 0;
    int has_hdr = 0;

    for (uint32_t i = 0; i < atomic->count_objs; i++)
        total += orig_cnts[i];

    for (uint32_t obj = 0; obj < atomic->count_objs; obj++) {
        if (orig_objs[obj] == connector_id) {
            conn_obj_idx = (int)obj;
            conn_prop_offset = prop_offset;
            for (uint32_t j = 0; j < orig_cnts[obj]; j++) {
                uint32_t prop = orig_props[prop_offset + j];
                if (max_bpc_prop_id && prop == max_bpc_prop_id)
                    has_max_bpc = 1;
                if (output_fmt_prop_id && prop == output_fmt_prop_id)
                    has_output_fmt = 1;
                if (colorimetry_prop_id && prop == colorimetry_prop_id)
                    has_colorimetry = 1;
                if (rgb_qr_prop_id && prop == rgb_qr_prop_id)
                    has_rgb_qr = 1;
                if (dovi_meta_prop_id && prop == dovi_meta_prop_id)
                    has_dovi = 1;
                if (hdr_meta_prop_id && prop == hdr_meta_prop_id)
                    has_hdr = 1;
            }
            break;
        }
        prop_offset += orig_cnts[obj];
    }

    if (!has_max_bpc && max_bpc_prop_id && max_bpc_override > 0 &&
        last_max_bpc != max_bpc_override) {
        add_props[add_count] = max_bpc_prop_id;
        add_values[add_count] = max_bpc_override;
        last_max_bpc = max_bpc_override;
        add_count++;
    }
    if (!has_output_fmt && output_fmt_prop_id && output_fmt_found &&
        last_output_fmt != output_fmt_override) {
        add_props[add_count] = output_fmt_prop_id;
        add_values[add_count] = output_fmt_override;
        last_output_fmt = output_fmt_override;
        add_count++;
    }
    if (!has_colorimetry && colorimetry_prop_id && colorimetry_found) {
        uint64_t desired = effective_colorimetry_override();
        if (last_colorimetry != desired) {
            add_props[add_count] = colorimetry_prop_id;
            add_values[add_count] = desired;
            last_colorimetry = desired;
            add_count++;
        }
    }
    if (!has_rgb_qr && rgb_qr_prop_id && rgb_qr_found) {
        uint64_t desired = effective_rgb_qr_override();
        if (last_rgb_qr != desired) {
            add_props[add_count] = rgb_qr_prop_id;
            add_values[add_count] = desired;
            last_rgb_qr = desired;
            add_count++;
        }
    }
    if (!has_dovi && dovi_blob && dovi_meta_prop_id && last_dovi != dovi_blob) {
        add_props[add_count] = dovi_meta_prop_id;
        add_values[add_count] = dovi_blob;
        last_dovi = dovi_blob;
        add_count++;
        dovi_injected = 1;
    }
    if (!has_hdr && hdr_blob && hdr_meta_prop_id &&
        hdr_injection_count < 16 && add_count < 6) {
        add_props[add_count] = hdr_meta_prop_id;
        add_values[add_count] = hdr_blob;
        last_hdr = hdr_blob;
        add_count++;
        hdr_injection_count++;
    }

    if (add_count == 0)
        return 0;
    if ((conn_obj_idx < 0 && atomic->count_objs >= MAX_ATOMIC_OBJS) ||
        total + add_count >= MAX_ATOMIC_PROPS)
        return 0;

    for (uint32_t i = 0; i < atomic->count_objs; i++) {
        inj_objs[i] = orig_objs[i];
        inj_count_props[i] = orig_cnts[i];
    }

    if (conn_obj_idx >= 0) {
        uint32_t insert_pos = conn_prop_offset + orig_cnts[conn_obj_idx];

        for (uint32_t i = 0; i < insert_pos; i++) {
            inj_props[i] = orig_props[i];
            inj_values[i] = orig_values[i];
        }
        for (uint32_t i = 0; i < add_count; i++) {
            inj_props[insert_pos + i] = add_props[i];
            inj_values[insert_pos + i] = add_values[i];
        }
        for (uint32_t i = insert_pos; i < total; i++) {
            inj_props[i + add_count] = orig_props[i];
            inj_values[i + add_count] = orig_values[i];
        }
        inj_count_props[conn_obj_idx] += add_count;
    } else {
        for (uint32_t i = 0; i < total; i++) {
            inj_props[i] = orig_props[i];
            inj_values[i] = orig_values[i];
        }
        for (uint32_t i = 0; i < add_count; i++) {
            inj_props[total + i] = add_props[i];
            inj_values[total + i] = add_values[i];
        }
        inj_objs[atomic->count_objs] = connector_id;
        inj_count_props[atomic->count_objs] = add_count;
        atomic->count_objs++;
    }

    atomic->objs_ptr = (uint64_t)(uintptr_t)inj_objs;
    atomic->count_props_ptr = (uint64_t)(uintptr_t)inj_count_props;
    atomic->props_ptr = (uint64_t)(uintptr_t)inj_props;
    atomic->prop_values_ptr = (uint64_t)(uintptr_t)inj_values;
    atomic->flags |= DRM_MODE_ATOMIC_ALLOW_MODESET;

    {
        char num[24];
        write_log("DRM_OVERRIDE: added ");
        itoa_simple(add_count, num);
        write_log(num);
        write_log(" connector props");
        if (reason) {
            write_log(" (");
            write_log(reason);
            write_log(")");
        }
        write_log(": ");
        for (uint32_t i = 0; i < add_count; i++) {
            if (i) write_log(" ");
            itoa_simple(add_props[i], num);
            write_log(num);
            write_log("=");
            itoa_simple(add_values[i], num);
            write_log(num);
        }
        write_log("\n");
    }

    return 1;
}

/* ---- Main ioctl interception ---- */
int ioctl(int fd, unsigned long request, ...) {
    va_list ap;
    va_start(ap, request);
    void *arg = va_arg(ap, void *);
    va_end(ap);

    read_config();

    /* Discover the connected HDMI connector before renderer commits start. */
    if (request == DRM_IOCTL_MODE_GETCONNECTOR) {
        long ret = raw_ioctl(fd, request, arg);
        if (ret == 0) {
            struct drm_mode_get_connector *conn =
                (struct drm_mode_get_connector *)arg;
            if (conn->connection == DRM_MODE_CONNECTED && conn->connector_id) {
                if (!connector_id || connector_id != conn->connector_id) {
                    char num[24];
                    connector_id = conn->connector_id;
                    itoa_simple(connector_id, num);
                    write_log("DRM_OVERRIDE: discovered connected connector_id=");
                    write_log(num);
                    write_log("\n");
                }
            }
        }
        return ret;
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
            if (strcmp(prop->name, "Colorimetry") == 0 ||
                strcmp(prop->name, "Colorspace") == 0) {
                colorimetry_prop_id = prop->prop_id;
                colorimetry_is_colorspace =
                    (strcmp(prop->name, "Colorspace") == 0);
                char num[24];
                itoa_simple(prop->prop_id, num);
                write_log("DRM_OVERRIDE: found ");
                write_log(prop->name);
                write_log(" prop_id=");
                write_log(num);
                write_log("\n");
            }
            if (strcmp(prop->name, "rgb quant range") == 0 ||
                strcmp(prop->name, "Broadcast RGB") == 0) {
                rgb_qr_prop_id = prop->prop_id;
                rgb_qr_is_broadcast =
                    (strcmp(prop->name, "Broadcast RGB") == 0);
                char num[24];
                itoa_simple(prop->prop_id, num);
                write_log("DRM_OVERRIDE: found ");
                write_log(prop->name);
                write_log(" prop_id=");
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
            if (strcmp(prop->name, "HDR_OUTPUT_METADATA") == 0) {
                hdr_meta_prop_id = prop->prop_id;
                char num[24];
                itoa_simple(prop->prop_id, num);
                write_log("DRM_OVERRIDE: found HDR_OUTPUT_METADATA prop_id=");
                write_log(num);
                write_log("\n");
            }
        }
        return ret;
    }

    /* Intercept DRM_IOCTL_MODE_ATOMIC -- override and suppress */
    if (request == DRM_IOCTL_MODE_ATOMIC) {
        struct drm_mode_atomic *atomic = (struct drm_mode_atomic *)arg;
        uint32_t *objs = (uint32_t *)(uintptr_t)atomic->objs_ptr;
        uint32_t *count_props = (uint32_t *)(uintptr_t)atomic->count_props_ptr;
        uint32_t *props = (uint32_t *)(uintptr_t)atomic->props_ptr;
        uint64_t *values = (uint64_t *)(uintptr_t)atomic->prop_values_ptr;
        int is_test = (atomic->flags & DRM_MODE_ATOMIC_TEST_ONLY) != 0;
        int dovi_changed = 0;
        int display_prop_changed = 0;
        int renderer_dovi_in_commit = 0;
        int connector_override_added = 0;

        uint32_t total = 0, i;
        uint32_t prop_obj_ids[MAX_ATOMIC_PROPS];
        for (i = 0; i < atomic->count_objs; i++) {
            for (uint32_t j = 0; j < count_props[i] && total < MAX_ATOMIC_PROPS; j++)
                prop_obj_ids[total++] = objs[i];
        }

        /*
         * Pass 0: Discover connector_id from the object that owns tracked
         * connector properties (max_bpc, output_format, Colorimetry).
         */
        if (!connector_id) {
            uint32_t prop_idx = 0;
            for (uint32_t obj = 0; obj < atomic->count_objs; obj++) {
                for (uint32_t j = 0; j < count_props[obj]; j++) {
                    if (is_tracked_prop(props[prop_idx + j])) {
                        connector_id = objs[obj];
                        char num[24];
                        itoa_simple(connector_id, num);
                        write_log("DRM_OVERRIDE: discovered connector_id=");
                        write_log(num);
                        write_log("\n");
                        goto found_conn;
                    }
                }
                prop_idx += count_props[obj];
            }
            found_conn: ;
        }

        /* Pass 1: Apply value overrides (max_bpc, output_format, Colorimetry, DOVI) */
        for (i = 0; i < total; i++) {
            int is_connector_prop = (!connector_id || prop_obj_ids[i] == connector_id);
            if (!is_connector_prop)
                continue;
            if (max_bpc_prop_id && props[i] == max_bpc_prop_id) {
                uint64_t old = values[i];
                override_max_bpc(&values[i], "atomic");
                if (old != values[i] || last_max_bpc != values[i]) {
                    display_prop_changed = 1;
                    log_display_prop_update(prop_obj_ids[i], props[i], values[i]);
                }
            }
            if (output_fmt_prop_id && props[i] == output_fmt_prop_id) {
                uint64_t old = values[i];
                override_output_fmt(&values[i], "atomic");
                if (old != values[i] || last_output_fmt != values[i]) {
                    display_prop_changed = 1;
                    log_display_prop_update(prop_obj_ids[i], props[i], values[i]);
                }
            }
            if (colorimetry_prop_id && props[i] == colorimetry_prop_id) {
                uint64_t old = values[i];
                override_colorimetry(&values[i], "atomic");
                if (old != values[i] || last_colorimetry != values[i]) {
                    display_prop_changed = 1;
                    log_display_prop_update(prop_obj_ids[i], props[i], values[i]);
                }
            }
            if (rgb_qr_prop_id && props[i] == rgb_qr_prop_id) {
                uint64_t old = values[i];
                override_rgb_qr(&values[i], "atomic");
                if (old != values[i] || last_rgb_qr != values[i]) {
                    display_prop_changed = 1;
                    log_display_prop_update(prop_obj_ids[i], props[i], values[i]);
                }
            }
            if (dovi_meta_prop_id && props[i] == dovi_meta_prop_id) {
                if (dv_status == 1 && values[i] != 0) {
                    renderer_dovi_in_commit = 1;
                    renderer_dovi_seen = 1;
                    if (!dovi_passthrough_logged) {
                        write_log("DRM_OVERRIDE: renderer provided DOVI blob\n");
                        dovi_passthrough_logged = 1;
                    }
                }
                if (dv_status == 0 && values[i] != 0) {
                    char old_val[24];
                    itoa_simple(values[i], old_val);
                    write_log("DRM_OVERRIDE: blocking DOVI blob_id=");
                    write_log(old_val);
                    write_log(" -> 0\n");
                    values[i] = 0;
                    dovi_changed = 1;
                }
            }
        }

        /* The vc4 driver only reliably re-programs the Vendor Specific
         * InfoFrame when the atomic commit is allowed to modeset.  Without
         * this, switching away from DV can leave the TV stuck in DV even
         * though the connector property was changed to 0. */
        if (!is_test && dovi_changed
            && !(atomic->flags & DRM_MODE_ATOMIC_ALLOW_MODESET)) {
            atomic->flags |= DRM_MODE_ATOMIC_ALLOW_MODESET;
            write_log("DRM_OVERRIDE: forcing ALLOW_MODESET for DOVI metadata change\n");
        }
        if (!is_test && display_prop_changed
            && !(atomic->flags & DRM_MODE_ATOMIC_ALLOW_MODESET)) {
            atomic->flags |= DRM_MODE_ATOMIC_ALLOW_MODESET;
            write_log("DRM_OVERRIDE: forcing ALLOW_MODESET for HDMI property change\n");
        }

        /*
         * Pass 2: Remove redundant connector properties from the commit.
         *
         * We compact props[] and values[] in-place, adjust count_props[]
         * per object, and drop objects that end up with zero properties.
         * This prevents the vc4 driver from seeing the connector in the
         * commit, avoiding modeset/InfoFrame re-transmission.
         *
         * Skip for TEST_ONLY commits (hypothetical checks).
         */
        if (!is_test && total > 0) {
            uint32_t read_idx = 0;
            uint32_t write_idx = 0;
            uint32_t new_count_objs = 0;
            uint32_t removed_total = 0;

            for (uint32_t obj = 0; obj < atomic->count_objs; obj++) {
                uint32_t orig_count = count_props[obj];
                uint32_t kept = 0;

                for (uint32_t j = 0; j < orig_count; j++) {
                    uint32_t ri = read_idx + j;
                    int suppress = 0;

                    if (is_tracked_prop(props[ri]) &&
                        (!connector_id || objs[obj] == connector_id))
                        suppress = should_suppress(props[ri], values[ri]);

                    if (suppress) {
                        removed_total++;
                    } else {
                        if (write_idx != ri) {
                            props[write_idx] = props[ri];
                            values[write_idx] = values[ri];
                        }
                        write_idx++;
                        kept++;
                    }
                }

                read_idx += orig_count;

                if (kept > 0) {
                    objs[new_count_objs] = objs[obj];
                    count_props[new_count_objs] = kept;
                    new_count_objs++;
                }
            }

            if (removed_total > 0) {
                atomic->count_objs = new_count_objs;
                suppressed_commits += removed_total;

                /* Log periodically */
                if (suppressed_commits <= 3 ||
                    (suppressed_commits % 1000) == 0) {
                    char num[24], num2[24];
                    itoa_simple(suppressed_commits, num);
                    itoa_simple(removed_total, num2);
                    write_log("DRM_OVERRIDE: suppressed ");
                    write_log(num);
                    write_log(" total props (");
                    write_log(num2);
                    write_log(" this commit)\n");
                }
            }
        }

        if (!is_test && connector_id) {
            uint32_t dovi_blob = 0;
            uint32_t hdr_blob = 0;

            if (dv_status == 1 && !dovi_injected && !renderer_dovi_in_commit
                && !renderer_dovi_seen && dovi_meta_prop_id)
                dovi_blob = create_dovi_blob(fd);
            if (dv_status == 0 && is_hdr == 1 && hdr_meta_prop_id &&
                hdr_injection_count < 16)
                hdr_blob = create_hdr_blob(fd);

            connector_override_added =
                ensure_connector_overrides(atomic, dovi_blob, hdr_blob,
                                           dovi_blob ? "DOVI fallback" :
                                           (hdr_blob ? "HDR metadata" :
                                                       "display config"));
        }

        long atomic_ret = raw_ioctl(fd, request, arg);

        if ((display_prop_changed || connector_override_added) && !is_test) {
            char num[24];
            if (atomic_ret != 0)
                reset_last_connector_overrides();
            write_log("DRM_OVERRIDE: display atomic returned ");
            if (atomic_ret == 0) {
                write_log("0");
            } else {
                itoa_simple((uint32_t)(-(int)atomic_ret), num);
                write_log("-");
                write_log(num);
                write_log(" errno=");
                itoa_simple((uint64_t)errno, num);
                write_log(num);
            }
            write_log(" flags=0x");
            {
                char hex[12];
                uint32_t f = atomic->flags;
                for (int h = 7; h >= 0; h--)
                    hex[7-h] = "0123456789abcdef"[(f >> (h*4)) & 0xF];
                hex[8] = 0;
                write_log(hex);
            }
            write_log("\n");
        }

        /* Log return for DOVI-related commits */
        if (dovi_injected && atomic_ret != 0) {
            char num[24];
            itoa_simple((uint32_t)(-(int)atomic_ret), num);
            write_log("DRM_OVERRIDE: atomic commit returned -");
            write_log(num);
            write_log(" (flags=0x");
            {
                char hex[12];
                uint32_t f = atomic->flags;
                for (int h = 7; h >= 0; h--) {
                    hex[7-h] = "0123456789abcdef"[(f >> (h*4)) & 0xF];
                }
                hex[8] = 0;
                write_log(hex);
            }
            write_log(", objs=");
            {
                char num2[24];
                itoa_simple(atomic->count_objs, num2);
                write_log(num2);
            }
            write_log(")\n");
        }

        return atomic_ret;
    }

    /* Intercept DRM_IOCTL_MODE_SETPROPERTY (connector-specific, 0xAB) */
    if (request == DRM_IOCTL_MODE_SETPROPERTY) {
        struct drm_mode_connector_set_property *sp =
            (struct drm_mode_connector_set_property *)arg;
        if (max_bpc_prop_id && sp->prop_id == max_bpc_prop_id)
            override_max_bpc(&sp->value, "setprop_conn");
        if (output_fmt_prop_id && sp->prop_id == output_fmt_prop_id)
            override_output_fmt(&sp->value, "setprop_conn");
        if (colorimetry_prop_id && sp->prop_id == colorimetry_prop_id)
            override_colorimetry(&sp->value, "setprop_conn");
        if (rgb_qr_prop_id && sp->prop_id == rgb_qr_prop_id)
            override_rgb_qr(&sp->value, "setprop_conn");
    }

    /* Intercept DRM_IOCTL_MODE_OBJ_SETPROPERTY (generic object, 0xBA) */
    if (request == DRM_IOCTL_MODE_OBJ_SETPROPERTY) {
        struct drm_mode_obj_set_property *sp =
            (struct drm_mode_obj_set_property *)arg;
        if (max_bpc_prop_id && sp->prop_id == max_bpc_prop_id)
            override_max_bpc(&sp->value, "setprop_obj");
        if (output_fmt_prop_id && sp->prop_id == output_fmt_prop_id)
            override_output_fmt(&sp->value, "setprop_obj");
        if (colorimetry_prop_id && sp->prop_id == colorimetry_prop_id)
            override_colorimetry(&sp->value, "setprop_obj");
        if (rgb_qr_prop_id && sp->prop_id == rgb_qr_prop_id)
            override_rgb_qr(&sp->value, "setprop_obj");
        if (dovi_meta_prop_id && sp->prop_id == dovi_meta_prop_id && dv_status == 0) {
            if (sp->value != 0) {
                write_log("DRM_OVERRIDE: blocking DOVI blob (dv_status=0, setprop_obj)\n");
                sp->value = 0;
            }
        }
        if (dovi_meta_prop_id && sp->prop_id == dovi_meta_prop_id
            && dv_status == 1 && dovi_blob_id && sp->value != dovi_blob_id) {
            sp->value = dovi_blob_id;
        }
    }

    return raw_ioctl(fd, request, arg);
}
