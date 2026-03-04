/*
 * dv_helper.c - Force DV VSIF on Pi 4 by doing an atomic DRM commit
 * that includes both mode set and DOVI_OUTPUT_METADATA.
 *
 * Usage: dv_helper [connector_id] [crtc_id]
 *   Default: connector 46, crtc 68  (HDMI-A-2 on Pi 400)
 *
 * Must run as root or have DRM master.
 *
 * Cross-compile: arm-linux-gnueabihf-gcc -o dv_helper dv_helper.c -ldrm
 * Or on Pi:      gcc -o dv_helper dv_helper.c -ldrm
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

/* DRM ioctl definitions */
#define DRM_IOCTL_BASE 'd'
#define DRM_IOWR(nr, type) _IOWR(DRM_IOCTL_BASE, nr, type)
#define DRM_IOW(nr, type)  _IOW(DRM_IOCTL_BASE, nr, type)
#define DRM_IOR(nr, type)  _IOR(DRM_IOCTL_BASE, nr, type)
#define DRM_IO(nr)         _IO(DRM_IOCTL_BASE, nr)

/* ioctl numbers */
#define DRM_IOCTL_SET_CLIENT_CAP    DRM_IOW(0x0d, struct drm_set_client_cap)
#define DRM_IOCTL_MODE_GETRESOURCES DRM_IOWR(0xa0, struct drm_mode_card_res)
#define DRM_IOCTL_MODE_GETCONNECTOR DRM_IOWR(0xa7, struct drm_mode_get_connector)
#define DRM_IOCTL_MODE_GETPROPERTY  DRM_IOWR(0xaa, struct drm_mode_get_property)
#define DRM_IOCTL_MODE_GETPROPBLOB  DRM_IOWR(0xac, struct drm_mode_get_blob)
#define DRM_IOCTL_MODE_OBJ_GETPROPERTIES DRM_IOWR(0xb9, struct drm_mode_obj_get_properties)
#define DRM_IOCTL_MODE_ATOMIC       DRM_IOWR(0xbc, struct drm_mode_atomic)
#define DRM_IOCTL_MODE_CREATEPROPBLOB DRM_IOWR(0xbd, struct drm_mode_create_blob)
#define DRM_IOCTL_MODE_DESTROYPROPBLOB DRM_IOWR(0xbe, struct drm_mode_destroy_blob)
#define DRM_IOCTL_SET_MASTER        DRM_IO(0x1e)
#define DRM_IOCTL_DROP_MASTER       DRM_IO(0x1f)

/* Client capabilities */
#define DRM_CLIENT_CAP_ATOMIC 3

/* Atomic flags */
#define DRM_MODE_ATOMIC_ALLOW_MODESET (1 << 10)
#define DRM_MODE_ATOMIC_TEST_ONLY     (1 << 8)

/* Object types */
#define DRM_MODE_OBJECT_CONNECTOR 0xc0c0c0c0

struct drm_set_client_cap {
    uint64_t capability;
    uint64_t value;
};

struct drm_mode_card_res {
    uint64_t fb_id_ptr;
    uint64_t crtc_id_ptr;
    uint64_t connector_id_ptr;
    uint64_t encoder_id_ptr;
    uint32_t count_fbs;
    uint32_t count_crtcs;
    uint32_t count_connectors;
    uint32_t count_encoders;
    uint32_t min_width, max_width;
    uint32_t min_height, max_height;
};

struct drm_mode_modeinfo {
    uint32_t clock;
    uint16_t hdisplay, hsync_start, hsync_end, htotal, hskew;
    uint16_t vdisplay, vsync_start, vsync_end, vtotal, vscan;
    uint32_t vrefresh;
    uint32_t flags;
    uint32_t type;
    char name[32];
};

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
    uint32_t mm_width, mm_height;
    uint32_t subpixel;
    uint32_t pad;
};

struct drm_mode_get_property {
    uint64_t values_ptr;
    uint64_t enum_blob_ptr;
    uint32_t prop_id;
    uint32_t flags;
    char name[32];
    uint32_t count_values;
    uint32_t count_enum_blobs;
};

struct drm_mode_get_blob {
    uint32_t blob_id;
    uint32_t length;
    uint64_t data;
};

struct drm_mode_obj_get_properties {
    uint64_t props_ptr;
    uint64_t prop_values_ptr;
    uint32_t count_props;
    uint32_t obj_id;
    uint32_t obj_type;
};

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

struct drm_mode_create_blob {
    uint64_t data;
    uint32_t length;
    uint32_t blob_id;
};

struct drm_mode_destroy_blob {
    uint32_t blob_id;
};

/* DV Low-Latency metadata - 12 bytes matching what PGeneratord sends */
static uint8_t dovi_metadata[] = {
    0x00, 0x00, 0x00, 0x00,  /* header */
    0x01,                     /* low_latency = 1 */
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  /* reserved */
    0xb6                      /* some DV param */
};

static int find_prop_id(int fd, uint32_t obj_id, uint32_t obj_type, const char *name)
{
    struct drm_mode_obj_get_properties props = {0};
    props.obj_id = obj_id;
    props.obj_type = obj_type;

    /* First call to get count */
    if (ioctl(fd, DRM_IOCTL_MODE_OBJ_GETPROPERTIES, &props) < 0) {
        return -1;
    }

    uint32_t count = props.count_props;
    if (count == 0) return -1;

    uint32_t *prop_ids = calloc(count, sizeof(uint32_t));
    uint64_t *prop_values = calloc(count, sizeof(uint64_t));
    props.props_ptr = (uint64_t)(uintptr_t)prop_ids;
    props.prop_values_ptr = (uint64_t)(uintptr_t)prop_values;

    if (ioctl(fd, DRM_IOCTL_MODE_OBJ_GETPROPERTIES, &props) < 0) {
        free(prop_ids);
        free(prop_values);
        return -1;
    }

    int result = -1;
    for (uint32_t i = 0; i < count; i++) {
        struct drm_mode_get_property prop = {0};
        prop.prop_id = prop_ids[i];
        if (ioctl(fd, DRM_IOCTL_MODE_GETPROPERTY, &prop) == 0) {
            if (strcmp(prop.name, name) == 0) {
                result = prop_ids[i];
                break;
            }
        }
    }

    free(prop_ids);
    free(prop_values);
    return result;
}

static uint64_t get_prop_value(int fd, uint32_t obj_id, uint32_t obj_type, uint32_t prop_id)
{
    struct drm_mode_obj_get_properties props = {0};
    props.obj_id = obj_id;
    props.obj_type = obj_type;

    if (ioctl(fd, DRM_IOCTL_MODE_OBJ_GETPROPERTIES, &props) < 0)
        return 0;

    uint32_t count = props.count_props;
    uint32_t *prop_ids = calloc(count, sizeof(uint32_t));
    uint64_t *prop_values = calloc(count, sizeof(uint64_t));
    props.props_ptr = (uint64_t)(uintptr_t)prop_ids;
    props.prop_values_ptr = (uint64_t)(uintptr_t)prop_values;

    ioctl(fd, DRM_IOCTL_MODE_OBJ_GETPROPERTIES, &props);

    uint64_t result = 0;
    for (uint32_t i = 0; i < count; i++) {
        if (prop_ids[i] == (uint32_t)prop_id) {
            result = prop_values[i];
            break;
        }
    }
    free(prop_ids);
    free(prop_values);
    return result;
}

int main(int argc, char *argv[])
{
    int fd;
    int ret;
    uint32_t conn_id = 46;   /* HDMI-A-2 default */
    uint32_t crtc_id = 68;   /* CRTC for HDMI-A-2 default */

    if (argc > 1) conn_id = atoi(argv[1]);
    if (argc > 2) crtc_id = atoi(argv[2]);

    /* Try card1 first (Pi 400 KMS), then card0 */
    fd = open("/dev/dri/card1", O_RDWR);
    if (fd < 0) {
        fd = open("/dev/dri/card0", O_RDWR);
        if (fd < 0) {
            perror("open /dev/dri/card*");
            return 1;
        }
    }

    /* Try to become DRM master */
    ret = ioctl(fd, DRM_IOCTL_SET_MASTER, 0);
    if (ret < 0) {
        fprintf(stderr, "Warning: couldn't become DRM master: %s\n", strerror(errno));
        fprintf(stderr, "This may fail. Kill PGeneratord first or run as root.\n");
    }

    /* Enable atomic */
    struct drm_set_client_cap cap = { .capability = DRM_CLIENT_CAP_ATOMIC, .value = 1 };
    ret = ioctl(fd, DRM_IOCTL_SET_CLIENT_CAP, &cap);
    if (ret < 0) {
        perror("set atomic cap");
        close(fd);
        return 1;
    }

    /* Find connector property IDs */
    int dovi_prop = find_prop_id(fd, conn_id, DRM_MODE_OBJECT_CONNECTOR, "DOVI_OUTPUT_METADATA");
    int crtc_prop = find_prop_id(fd, conn_id, DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID");

    printf("Connector %u: DOVI_OUTPUT_METADATA prop=%d, CRTC_ID prop=%d\n",
           conn_id, dovi_prop, crtc_prop);

    if (dovi_prop < 0) {
        fprintf(stderr, "ERROR: DOVI_OUTPUT_METADATA property not found on connector %u\n", conn_id);
        close(fd);
        return 1;
    }

    /* Create DOVI metadata blob */
    struct drm_mode_create_blob create_blob = {
        .data = (uint64_t)(uintptr_t)dovi_metadata,
        .length = sizeof(dovi_metadata)
    };
    ret = ioctl(fd, DRM_IOCTL_MODE_CREATEPROPBLOB, &create_blob);
    if (ret < 0) {
        perror("create dovi blob");
        close(fd);
        return 1;
    }
    printf("Created DOVI blob id=%u (size=%zu bytes)\n",
           create_blob.blob_id, sizeof(dovi_metadata));

    /* Do atomic commit: set DOVI_OUTPUT_METADATA on connector */
    /* This forces ALLOW_MODESET which triggers full mode set */
    uint32_t obj_ids[] = { conn_id };
    uint32_t count_props[] = { 1 };
    uint32_t prop_ids[] = { (uint32_t)dovi_prop };
    uint64_t prop_values[] = { create_blob.blob_id };

    struct drm_mode_atomic atomic = {
        .flags = DRM_MODE_ATOMIC_ALLOW_MODESET,
        .count_objs = 1,
        .objs_ptr = (uint64_t)(uintptr_t)obj_ids,
        .count_props_ptr = (uint64_t)(uintptr_t)count_props,
        .props_ptr = (uint64_t)(uintptr_t)prop_ids,
        .prop_values_ptr = (uint64_t)(uintptr_t)prop_values,
    };

    /* First try test-only */
    struct drm_mode_atomic test_atomic = atomic;
    test_atomic.flags |= DRM_MODE_ATOMIC_TEST_ONLY;
    ret = ioctl(fd, DRM_IOCTL_MODE_ATOMIC, &test_atomic);
    printf("Atomic test: %s (ret=%d, errno=%d)\n",
           ret == 0 ? "OK" : "FAIL", ret, ret < 0 ? errno : 0);

    /* Now do real commit */
    ret = ioctl(fd, DRM_IOCTL_MODE_ATOMIC, &atomic);
    printf("Atomic commit: %s (ret=%d, errno=%d)\n",
           ret == 0 ? "OK" : "FAIL", ret, ret < 0 ? errno : 0);

    if (ret == 0) {
        printf("DOVI_OUTPUT_METADATA set successfully with ALLOW_MODESET\n");
        printf("Check dmesg for DV Vendor Specific InfoFrame\n");
    } else {
        fprintf(stderr, "Atomic commit failed: %s\n", strerror(errno));
        /* Clean up blob */
        struct drm_mode_destroy_blob destroy = { .blob_id = create_blob.blob_id };
        ioctl(fd, DRM_IOCTL_MODE_DESTROYPROPBLOB, &destroy);
    }

    /* Drop master so PGeneratord can reclaim */
    ioctl(fd, DRM_IOCTL_DROP_MASTER, 0);
    close(fd);
    return ret == 0 ? 0 : 1;
}
