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
static uint32_t rgb_qr_prop_id = 0;
static uint64_t rgb_qr_override = 0;
static int rgb_qr_found = 0;
static uint32_t dovi_meta_prop_id = 0;
static int dv_status = 0;
static int dv_interface = 0;     /* 0=Standard, 1=Low-Latency */
static int conf_read = 0;

/* DOVI blob injection state */
static uint32_t dovi_blob_id = 0;       /* fallback blob created by us */
static int dovi_injected = 0;           /* 1 after successful fallback injection */
static uint32_t connector_id = 0;       /* discovered from atomic commits */
static int first_modeset_done = 0;      /* track first ALLOW_MODESET commit */
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
        if (p[0] == 'd' && p[1] == 'v' && p[2] == '_' && p[3] == 'i' &&
            p[4] == 'n' && p[5] == 't' && p[6] == 'e' && p[7] == 'r' &&
            p[8] == 'f' && p[9] == 'a' && p[10] == 'c' && p[11] == 'e' &&
            p[12] == '=') {
            dv_interface = (p[13] - '0');
        }
        if (p[0] == 'c' && p[1] == 'o' && p[2] == 'l' && p[3] == 'o' &&
            p[4] == 'r' && p[5] == 'i' && p[6] == 'm' && p[7] == 'e' &&
            p[8] == 't' && p[9] == 'r' && p[10] == 'y' && p[11] == '=') {
            char *v = p + 12;
            colorimetry_override = 0;
            while (*v >= '0' && *v <= '9') {
                colorimetry_override = colorimetry_override * 10 + (*v - '0');
                v++;
            }
            colorimetry_found = 1;
        }
        if (p[0] == 'r' && p[1] == 'g' && p[2] == 'b' && p[3] == '_' &&
            p[4] == 'q' && p[5] == 'u' && p[6] == 'a' && p[7] == 'n' &&
            p[8] == 't' && p[9] == '_' && p[10] == 'r' && p[11] == 'a' &&
            p[12] == 'n' && p[13] == 'g' && p[14] == 'e' && p[15] == '=') {
            char *v = p + 16;
            rgb_qr_override = 0;
            while (*v >= '0' && *v <= '9') {
                rgb_qr_override = rgb_qr_override * 10 + (*v - '0');
                v++;
            }
            rgb_qr_found = 1;
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
    if (colorimetry_prop_id && colorimetry_found && *value != colorimetry_override) {
        char old_val[24], new_val[24];
        itoa_simple(*value, old_val);
        itoa_simple(colorimetry_override, new_val);
        write_log("DRM_OVERRIDE: Colorimetry ");
        write_log(old_val);
        write_log(" -> ");
        write_log(new_val);
        if (source) { write_log(" ("); write_log(source); write_log(")"); }
        write_log("\n");
        *value = colorimetry_override;
    }
}

static void override_rgb_qr(uint64_t *value, const char *source) {
    if (rgb_qr_prop_id && rgb_qr_found && *value != rgb_qr_override) {
        char old_val[24], new_val[24];
        itoa_simple(*value, old_val);
        itoa_simple(rgb_qr_override, new_val);
        write_log("DRM_OVERRIDE: rgb_quant_range ");
        write_log(old_val);
        write_log(" -> ");
        write_log(new_val);
        if (source) { write_log(" ("); write_log(source); write_log(")"); }
        write_log("\n");
        *value = rgb_qr_override;
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

/*
 * Create the fallback DOVI_OUTPUT_METADATA blob (one-time).
 * Returns blob_id, or 0 on failure.
 *
 * The 12-byte blob format matches the legacy low-latency blob previously
 * synthesized here. Keep it only as a last-resort fallback for commits that
 * omit DOVI_OUTPUT_METADATA entirely.
 *
 * For drm_hdmi_infoframe_set_dovi_source_metadata():
 *   bytes 0-3: header (zeroes)
 *   byte 4:   low_latency flag (0=Standard, 1=LL)
 *   bytes 5-10: reserved (zeroes)
 *   byte 11:  DV param (0xb6)
 */
static uint32_t create_dovi_blob(int fd) {
    if (dovi_blob_id) return dovi_blob_id;

    uint8_t metadata[12] = {
        0x46, 0xD0, 0x00, 0x00, /* Dolby OUI 00-D0-46 (LE u32) → frame.oui */
        0x01,  /* always Low-Latency — RPi4 can't do Standard DV */
        0x01,  /* DV version (vc4 requires == 1 to write VSIF) */
        0x00, 0x00, 0x00, 0x00, 0x00,
        0xb6
    };

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
        write_log(" (LL)");
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

static int inject_dovi_into_commit(int fd, struct drm_mode_atomic *atomic) {
    if (!dovi_meta_prop_id || !connector_id) return 0;

    uint32_t *orig_objs = (uint32_t *)(uintptr_t)atomic->objs_ptr;
    uint32_t *orig_cnts = (uint32_t *)(uintptr_t)atomic->count_props_ptr;
    uint32_t *orig_props = (uint32_t *)(uintptr_t)atomic->props_ptr;
    uint64_t *orig_values = (uint64_t *)(uintptr_t)atomic->prop_values_ptr;

    uint32_t total = 0;
    for (uint32_t i = 0; i < atomic->count_objs; i++)
        total += orig_cnts[i];

    /* Safety check */
    if (atomic->count_objs >= MAX_ATOMIC_OBJS || total + 1 >= MAX_ATOMIC_PROPS)
        return 0;

    /* Find connector object index and check if DOVI is already present */
    int conn_obj_idx = -1;
    uint32_t prop_offset = 0;
    for (uint32_t obj = 0; obj < atomic->count_objs; obj++) {
        if (orig_objs[obj] == connector_id) {
            conn_obj_idx = (int)obj;
            /* Check if DOVI already in this object's props */
            for (uint32_t j = 0; j < orig_cnts[obj]; j++) {
                if (orig_props[prop_offset + j] == dovi_meta_prop_id) {
                    renderer_dovi_seen = 1;
                    if (!dovi_passthrough_logged) {
                        write_log("DRM_OVERRIDE: renderer provided DOVI blob, leaving commit unchanged\n");
                        dovi_passthrough_logged = 1;
                    }
                    return 0;
                }
            }
            break;
        }
        prop_offset += orig_cnts[obj];
    }

    uint32_t blob = create_dovi_blob(fd);
    if (!blob) return 0;

    /* Copy arrays and inject DOVI */
    uint32_t new_total = total + 1;
    uint32_t new_count_objs = atomic->count_objs;

    /* Copy object IDs and property counts */
    for (uint32_t i = 0; i < atomic->count_objs; i++) {
        inj_objs[i] = orig_objs[i];
        inj_count_props[i] = orig_cnts[i];
    }

    if (conn_obj_idx >= 0) {
        /* Connector is already in the commit — add DOVI to its props */
        /* Copy props/values, inserting DOVI at the end of connector's block */
        uint32_t insert_pos = 0;
        for (int i = 0; i <= conn_obj_idx; i++)
            insert_pos += inj_count_props[i];

        /* Copy props before insert point */
        for (uint32_t i = 0; i < insert_pos; i++) {
            inj_props[i] = orig_props[i];
            inj_values[i] = orig_values[i];
        }
        /* Insert DOVI */
        inj_props[insert_pos] = dovi_meta_prop_id;
        inj_values[insert_pos] = (uint64_t)blob;
        /* Copy rest */
        for (uint32_t i = insert_pos; i < total; i++) {
            inj_props[i + 1] = orig_props[i];
            inj_values[i + 1] = orig_values[i];
        }
        inj_count_props[conn_obj_idx]++;
    } else {
        /* Connector not in the commit — add it as a new object */
        /* Copy all existing props */
        for (uint32_t i = 0; i < total; i++) {
            inj_props[i] = orig_props[i];
            inj_values[i] = orig_values[i];
        }
        /* Append DOVI */
        inj_props[total] = dovi_meta_prop_id;
        inj_values[total] = (uint64_t)blob;
        /* Add connector as new object */
        inj_objs[new_count_objs] = connector_id;
        inj_count_props[new_count_objs] = 1;
        new_count_objs++;
    }

    /* Swap pointers in atomic struct */
    atomic->objs_ptr = (uint64_t)(uintptr_t)inj_objs;
    atomic->count_props_ptr = (uint64_t)(uintptr_t)inj_count_props;
    atomic->props_ptr = (uint64_t)(uintptr_t)inj_props;
    atomic->prop_values_ptr = (uint64_t)(uintptr_t)inj_values;
    atomic->count_objs = new_count_objs;
    /* Ensure ALLOW_MODESET so the kernel processes the DV metadata */
    atomic->flags |= DRM_MODE_ATOMIC_ALLOW_MODESET;

    dovi_injected = 1;
    {
        char num[24];
        itoa_simple(connector_id, num);
        write_log("DRM_OVERRIDE: injected DOVI blob into commit on connector ");
        write_log(num);
        write_log(" (objs=");
        itoa_simple(new_count_objs, num);
        write_log(num);
        write_log(", flags=0x");
        {
            char hex[12];
            uint32_t f = atomic->flags;
            for (int h = 7; h >= 0; h--)
                hex[7-h] = "0123456789abcdef"[(f >> (h*4)) & 0xF];
            hex[8] = 0;
            write_log(hex);
        }
        write_log(")\n");
        /* Dump all props in final commit */
        uint32_t pidx = 0;
        for (uint32_t oi = 0; oi < new_count_objs; oi++) {
            itoa_simple(inj_objs[oi], num);
            write_log("  obj=");
            write_log(num);
            write_log(" props=");
            itoa_simple(inj_count_props[oi], num);
            write_log(num);
            write_log(": ");
            for (uint32_t pi = 0; pi < inj_count_props[oi]; pi++) {
                itoa_simple(inj_props[pidx + pi], num);
                write_log(num);
                write_log("=");
                itoa_simple((uint32_t)inj_values[pidx + pi], num);
                write_log(num);
                write_log(" ");
            }
            write_log("\n");
            pidx += inj_count_props[oi];
        }
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
            if (strcmp(prop->name, "Colorimetry") == 0) {
                colorimetry_prop_id = prop->prop_id;
                char num[24];
                itoa_simple(prop->prop_id, num);
                write_log("DRM_OVERRIDE: found Colorimetry prop_id=");
                write_log(num);
                write_log("\n");
            }
            if (strcmp(prop->name, "rgb quant range") == 0) {
                rgb_qr_prop_id = prop->prop_id;
                char num[24];
                itoa_simple(prop->prop_id, num);
                write_log("DRM_OVERRIDE: found rgb_quant_range prop_id=");
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

    /* Intercept DRM_IOCTL_MODE_ATOMIC -- override and suppress */
    if (request == DRM_IOCTL_MODE_ATOMIC) {
        struct drm_mode_atomic *atomic = (struct drm_mode_atomic *)arg;
        uint32_t *objs = (uint32_t *)(uintptr_t)atomic->objs_ptr;
        uint32_t *count_props = (uint32_t *)(uintptr_t)atomic->count_props_ptr;
        uint32_t *props = (uint32_t *)(uintptr_t)atomic->props_ptr;
        uint64_t *values = (uint64_t *)(uintptr_t)atomic->prop_values_ptr;
        int is_test = (atomic->flags & DRM_MODE_ATOMIC_TEST_ONLY) != 0;
        int dovi_changed = 0;

        uint32_t total = 0, i;
        for (i = 0; i < atomic->count_objs; i++)
            total += count_props[i];

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
            if (max_bpc_prop_id && props[i] == max_bpc_prop_id)
                override_max_bpc(&values[i], "atomic");
            if (output_fmt_prop_id && props[i] == output_fmt_prop_id)
                override_output_fmt(&values[i], "atomic");
            if (colorimetry_prop_id && props[i] == colorimetry_prop_id)
                override_colorimetry(&values[i], "atomic");
            if (rgb_qr_prop_id && props[i] == rgb_qr_prop_id)
                override_rgb_qr(&values[i], "atomic");
            if (dovi_meta_prop_id && props[i] == dovi_meta_prop_id
                && dv_status == 0 && values[i] != 0) {
                char old_val[24];
                itoa_simple(values[i], old_val);
                write_log("DRM_OVERRIDE: blocking DOVI blob_id=");
                write_log(old_val);
                write_log(" -> 0\n");
                values[i] = 0;
                dovi_changed = 1;
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

                    if (is_tracked_prop(props[ri]))
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

        /*
         * DOVI fallback injection: before the atomic commit goes to the
         * kernel, synthesize DOVI_OUTPUT_METADATA only if the renderer did
         * not already include it in this commit.
         */
        if (!is_test && dv_status == 1 && !dovi_injected && !renderer_dovi_seen
            && dovi_meta_prop_id && connector_id) {
            inject_dovi_into_commit(fd, atomic);
        }

        long atomic_ret = raw_ioctl(fd, request, arg);

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
