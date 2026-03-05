/*
 * drm_hdr_set — Pre-set DRM connector properties for HDR before
 *               the PGeneratord binary starts.
 *
 * Sets max_bpc, Colorimetry, and HDR_OUTPUT_METADATA blob on the
 * first connected HDMI connector in a single atomic commit so the
 * TV sees a consistent HDR signal from the very first frame.
 *
 * Usage:  drm_hdr_set <config_file>
 *         drm_hdr_set /etc/PGenerator/PGenerator.conf
 *
 * Reads: eotf, is_hdr, max_bpc, colorimetry, primaries,
 *        min_luma, max_luma, max_cll, max_fall
 *
 * Copyright (c) 2026 PGenerator+  —  GPLv3+
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>

#include <xf86drm.h>
#include <xf86drmMode.h>
#include <libdrm/drm_mode.h>

/* BT.2020 primaries (CIE 1931 × 50000) */
static const uint16_t bt2020_gx = 8500,  bt2020_gy = 39850;
static const uint16_t bt2020_bx = 6550,  bt2020_by = 2300;
static const uint16_t bt2020_rx = 35400, bt2020_ry = 14600;

/* DCI-P3 D65 primaries */
static const uint16_t p3_gx = 13250, p3_gy = 34500;
static const uint16_t p3_bx = 7500,  p3_by = 3000;
static const uint16_t p3_rx = 34000, p3_ry = 16000;

/* BT.709 primaries */
static const uint16_t bt709_gx = 15000, bt709_gy = 30000;
static const uint16_t bt709_bx = 7500,  bt709_by = 3000;
static const uint16_t bt709_rx = 32000, bt709_ry = 16500;

/* D65 white point */
static const uint16_t wp_x = 15635, wp_y = 16450;

/*
 * Simple key=value config parser.
 */
static int conf_int(const char *buf, const char *key, int def)
{
    char pat[128];
    snprintf(pat, sizeof(pat), "\n%s=", key);
    const char *p = strstr(buf, pat);
    if (!p) {
        /* Try at start of buffer */
        snprintf(pat, sizeof(pat), "%s=", key);
        if (strncmp(buf, pat, strlen(pat)) == 0)
            p = buf;
        else
            return def;
    } else {
        p++; /* skip \n */
    }
    p = strchr(p, '=');
    if (!p) return def;
    return atoi(p + 1);
}

static double conf_double(const char *buf, const char *key, double def)
{
    char pat[128];
    snprintf(pat, sizeof(pat), "\n%s=", key);
    const char *p = strstr(buf, pat);
    if (!p) {
        snprintf(pat, sizeof(pat), "%s=", key);
        if (strncmp(buf, pat, strlen(pat)) == 0)
            p = buf;
        else
            return def;
    } else {
        p++;
    }
    p = strchr(p, '=');
    if (!p) return def;
    return atof(p + 1);
}

/*
 * Find a DRM property ID by name on an object.
 */
static uint32_t find_prop_id(int fd, uint32_t obj_id, uint32_t obj_type,
                             const char *name)
{
    drmModeObjectPropertiesPtr props =
        drmModeObjectGetProperties(fd, obj_id, obj_type);
    if (!props) return 0;

    uint32_t id = 0;
    for (uint32_t i = 0; i < props->count_props; i++) {
        drmModePropertyPtr prop = drmModeGetProperty(fd, props->props[i]);
        if (prop) {
            if (strcmp(prop->name, name) == 0)
                id = prop->prop_id;
            drmModeFreeProperty(prop);
        }
        if (id) break;
    }
    drmModeFreeObjectProperties(props);
    return id;
}

/*
 * Try opening DRM device — try card1 first (display), then card0.
 */
static int open_drm(void)
{
    int fd = open("/dev/dri/card1", O_RDWR | O_CLOEXEC);
    if (fd >= 0) {
        drmModeResPtr res = drmModeGetResources(fd);
        if (res && res->count_connectors > 0) {
            drmModeFreeResources(res);
            return fd;
        }
        if (res) drmModeFreeResources(res);
        close(fd);
    }
    fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (fd >= 0) {
        drmModeResPtr res = drmModeGetResources(fd);
        if (res && res->count_connectors > 0) {
            drmModeFreeResources(res);
            return fd;
        }
        if (res) drmModeFreeResources(res);
        close(fd);
    }
    return -1;
}

/*
 * Find first connected HDMI connector.
 */
static uint32_t find_hdmi_connector(int fd)
{
    drmModeResPtr res = drmModeGetResources(fd);
    if (!res) return 0;

    uint32_t conn_id = 0;
    for (int i = 0; i < res->count_connectors; i++) {
        drmModeConnectorPtr conn = drmModeGetConnector(fd, res->connectors[i]);
        if (!conn) continue;
        if (conn->connection == DRM_MODE_CONNECTED &&
            (conn->connector_type == DRM_MODE_CONNECTOR_HDMIA ||
             conn->connector_type == DRM_MODE_CONNECTOR_HDMIB)) {
            conn_id = conn->connector_id;
            drmModeFreeConnector(conn);
            break;
        }
        drmModeFreeConnector(conn);
    }
    drmModeFreeResources(res);
    return conn_id;
}

int main(int argc, char *argv[])
{
    const char *conf_path = "/etc/PGenerator/PGenerator.conf";
    if (argc > 1) conf_path = argv[1];

    /* Read config file */
    FILE *f = fopen(conf_path, "r");
    if (!f) {
        fprintf(stderr, "drm_hdr_set: cannot open %s: %s\n",
                conf_path, strerror(errno));
        return 1;
    }
    fseek(f, 0, SEEK_END);
    long fsize = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *conf = calloc(1, fsize + 2);
    fread(conf, 1, fsize, f);
    fclose(f);

    int is_hdr      = conf_int(conf, "is_hdr", 0);
    int eotf        = conf_int(conf, "eotf", 0);
    int colorimetry = conf_int(conf, "colorimetry", 0);
    int max_bpc     = conf_int(conf, "max_bpc", 8);
    int primaries   = conf_int(conf, "primaries", 1);
    double min_luma = conf_double(conf, "min_luma", 0.0);
    int max_luma    = conf_int(conf, "max_luma", 1000);
    int max_cll     = conf_int(conf, "max_cll", 1000);
    int max_fall    = conf_int(conf, "max_fall", 400);
    free(conf);

    if (!is_hdr && eotf == 0) {
        /* SDR mode — only set max_bpc, no HDR metadata */
        fprintf(stderr, "drm_hdr_set: SDR mode, setting max_bpc=%d\n", max_bpc);
    }

    /* Open DRM device */
    int fd = open_drm();
    if (fd < 0) {
        fprintf(stderr, "drm_hdr_set: cannot open DRM device\n");
        return 1;
    }

    /* Enable atomic cap */
    if (drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1) != 0) {
        fprintf(stderr, "drm_hdr_set: DRM_CLIENT_CAP_ATOMIC not supported\n");
        close(fd);
        return 1;
    }

    /* Find HDMI connector */
    uint32_t conn_id = find_hdmi_connector(fd);
    if (!conn_id) {
        fprintf(stderr, "drm_hdr_set: no connected HDMI connector found\n");
        close(fd);
        return 1;
    }

    /* Look up property IDs */
    uint32_t pid_max_bpc =
        find_prop_id(fd, conn_id, DRM_MODE_OBJECT_CONNECTOR, "max bpc");
    uint32_t pid_colorimetry =
        find_prop_id(fd, conn_id, DRM_MODE_OBJECT_CONNECTOR, "Colorimetry");
    uint32_t pid_hdr_meta =
        find_prop_id(fd, conn_id, DRM_MODE_OBJECT_CONNECTOR,
                     "HDR_OUTPUT_METADATA");

    if (!pid_max_bpc) {
        fprintf(stderr, "drm_hdr_set: 'max bpc' property not found\n");
        close(fd);
        return 1;
    }

    /* Build atomic request */
    drmModeAtomicReqPtr req = drmModeAtomicAlloc();
    if (!req) {
        fprintf(stderr, "drm_hdr_set: drmModeAtomicAlloc failed\n");
        close(fd);
        return 1;
    }

    /* Always set max_bpc */
    drmModeAtomicAddProperty(req, conn_id, pid_max_bpc, max_bpc);
    fprintf(stderr, "drm_hdr_set: max_bpc=%d on connector %u\n",
            max_bpc, conn_id);

    /* Set colorimetry if available */
    if (pid_colorimetry) {
        drmModeAtomicAddProperty(req, conn_id, pid_colorimetry, colorimetry);
        fprintf(stderr, "drm_hdr_set: colorimetry=%d\n", colorimetry);
    }

    /* Build and set HDR_OUTPUT_METADATA blob if HDR */
    uint32_t blob_id = 0;
    if (is_hdr && eotf > 0 && pid_hdr_meta) {
        struct hdr_output_metadata meta;
        memset(&meta, 0, sizeof(meta));
        meta.metadata_type = 0; /* Type 1 */
        meta.hdmi_metadata_type1.eotf = eotf;
        meta.hdmi_metadata_type1.metadata_type = 0;

        /* Set primaries based on config */
        uint16_t gx, gy, bx, by, rx, ry;
        if (primaries == 1) {
            /* BT.2020 */
            gx = bt2020_gx; gy = bt2020_gy;
            bx = bt2020_bx; by = bt2020_by;
            rx = bt2020_rx; ry = bt2020_ry;
        } else if (primaries == 2) {
            /* DCI-P3 D65 */
            gx = p3_gx; gy = p3_gy;
            bx = p3_bx; by = p3_by;
            rx = p3_rx; ry = p3_ry;
        } else {
            /* BT.709 */
            gx = bt709_gx; gy = bt709_gy;
            bx = bt709_bx; by = bt709_by;
            rx = bt709_rx; ry = bt709_ry;
        }
        /* CTA-861: primaries[0]=Green, [1]=Blue, [2]=Red */
        meta.hdmi_metadata_type1.display_primaries[0].x = gx;
        meta.hdmi_metadata_type1.display_primaries[0].y = gy;
        meta.hdmi_metadata_type1.display_primaries[1].x = bx;
        meta.hdmi_metadata_type1.display_primaries[1].y = by;
        meta.hdmi_metadata_type1.display_primaries[2].x = rx;
        meta.hdmi_metadata_type1.display_primaries[2].y = ry;
        meta.hdmi_metadata_type1.white_point.x = wp_x;
        meta.hdmi_metadata_type1.white_point.y = wp_y;
        meta.hdmi_metadata_type1.max_display_mastering_luminance = max_luma;
        /* min_luma in config is cd/m²; HDMI uses 0.0001 cd/m² units */
        meta.hdmi_metadata_type1.min_display_mastering_luminance =
            (uint16_t)(min_luma * 10000.0);
        meta.hdmi_metadata_type1.max_cll = max_cll;
        meta.hdmi_metadata_type1.max_fall = max_fall;

        if (drmModeCreatePropertyBlob(fd, &meta, sizeof(meta), &blob_id) != 0) {
            fprintf(stderr, "drm_hdr_set: failed to create HDR blob: %s\n",
                    strerror(errno));
            blob_id = 0;
        } else {
            drmModeAtomicAddProperty(req, conn_id, pid_hdr_meta, blob_id);
            fprintf(stderr,
                "drm_hdr_set: HDR blob=%u eotf=%d prim=%d maxL=%d "
                "minL=%.4f maxCLL=%d maxFALL=%d\n",
                blob_id, eotf, primaries, max_luma, min_luma,
                max_cll, max_fall);
        }
    } else if (pid_hdr_meta) {
        /* SDR — clear HDR metadata */
        drmModeAtomicAddProperty(req, conn_id, pid_hdr_meta, 0);
        fprintf(stderr, "drm_hdr_set: cleared HDR metadata (SDR)\n");
    }

    /* Commit — use ALLOW_MODESET so property changes take effect */
    int ret = drmModeAtomicCommit(fd, req,
        DRM_MODE_ATOMIC_ALLOW_MODESET | DRM_MODE_ATOMIC_TEST_ONLY, NULL);
    if (ret == 0) {
        /* Test passed, do it for real */
        ret = drmModeAtomicCommit(fd, req,
            DRM_MODE_ATOMIC_ALLOW_MODESET, NULL);
        if (ret != 0) {
            fprintf(stderr, "drm_hdr_set: atomic commit failed: %s\n",
                    strerror(errno));
        } else {
            fprintf(stderr, "drm_hdr_set: committed successfully\n");
        }
    } else {
        fprintf(stderr, "drm_hdr_set: atomic test failed: %s (trying non-atomic)\n",
                strerror(errno));
        /* Fall back to non-atomic property setting */
        /* max_bpc via legacy connector property */
        drmModeConnectorPtr conn = drmModeGetConnector(fd, conn_id);
        if (conn) {
            for (int i = 0; i < conn->count_props; i++) {
                drmModePropertyPtr prop = drmModeGetProperty(fd, conn->props[i]);
                if (prop) {
                    if (strcmp(prop->name, "max bpc") == 0) {
                        drmModeConnectorSetProperty(fd, conn_id,
                            prop->prop_id, max_bpc);
                    }
                    drmModeFreeProperty(prop);
                }
            }
            drmModeFreeConnector(conn);
        }
        ret = 0; /* partial success */
    }

    /* Cleanup — do NOT destroy the blob; the connector property holds a
     * reference that keeps it alive.  The binary will replace it with its
     * own blob on its first HDR atomic commit. */
    drmModeAtomicFree(req);
    close(fd);

    return ret ? 1 : 0;
}
