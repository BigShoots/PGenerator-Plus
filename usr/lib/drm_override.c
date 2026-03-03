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
 * NOTE: No CSC (Color Space Converter) override is performed.
 * PGeneratord handles RGB→YCbCr conversion in its OpenGL fragment
 * shader, producing bit-perfect limited-range YCbCr output.
 * The kernel's default CSC identity matrix passes this through.
 *
 * The PGeneratord binary has bugs:
 *  - Always sets max_bpc to 8 regardless of config
 *  - May force output format to undesired value for some modes
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

/* ---- State ---- */
static uint32_t max_bpc_prop_id = 0;
static uint64_t max_bpc_override = 0;
static uint32_t output_fmt_prop_id = 0;
static uint64_t output_fmt_override = 0;
static int output_fmt_found = 0;
static uint32_t dovi_meta_prop_id = 0;
static int dv_status = 0;
static int conf_read = 0;

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

        return raw_ioctl(fd, request, arg);
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
