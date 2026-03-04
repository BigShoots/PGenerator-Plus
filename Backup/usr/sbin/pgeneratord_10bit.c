/*
 * pgeneratord_10bit — 10-bit DRM dumb-buffer pattern generator
 *
 * Renders calibration test patterns (rectangles) at native 10-bit
 * precision using DRM dumb buffers in XRGB2101010 (XR30) format.
 * Bypasses OpenGL entirely — Mesa 21.2.4 vc4/v3d doesn't support
 * 10-bit render targets, but the DRM/KMS display controller CAN
 * scan out 10-bit buffers.
 *
 * Usage: pgeneratord_10bit WIDTH HEIGHT
 *
 * Reads: /var/lib/PGenerator/running/operations.txt
 * Watches for changes via inotify and re-renders.
 *
 * Build: arm-linux-gnueabihf-gcc -O2 -o pgeneratord_10bit pgeneratord_10bit.c
 *
 * Pattern file format (operations.txt):
 *   BITS=8|10|12
 *   DRAW=RECTANGLE
 *   DIM=width,height
 *   RGB=r,g,b           (0-255 for 8-bit, 0-1023 for 10-bit, 0-4095 for 12-bit)
 *   BG=r,g,b            (background color, same range)
 *   POSITION=x,y        (center position of the rectangle)
 *   FRAME=1              (commit frame)
 *   END=1                (end marker)
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdarg.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <linux/limits.h>

/* DRM headers */
#include <drm/drm.h>
#include <drm/drm_mode.h>
#include <drm/drm_fourcc.h>

/* ------------------------------------------------------------------ */
/* Constants                                                          */
/* ------------------------------------------------------------------ */

#define OPS_FILE    "/var/lib/PGenerator/running/operations.txt"
#define CONF_FILE   "/etc/PGenerator/PGenerator.conf"
#define LUT_FILE    "/etc/PGenerator/lut.txt"
#define DRM_DEVICE  "/dev/dri/card0"   /* vc4 display controller */
#define DRM_DEVICE0 "/dev/dri/card1"   /* fallback (v3d render) */

/* DRM_FORMAT_XRGB2101010 from drm_fourcc.h */
#ifndef DRM_FORMAT_XRGB2101010
#define DRM_FORMAT_XRGB2101010 0x30335258  /* fourcc('X','R','3','0') */
#endif

/* DRM ioctl numbers (in case headers are old) */
#ifndef DRM_IOCTL_MODE_CREATE_DUMB
#define DRM_IOCTL_MODE_CREATE_DUMB   0xC02064B2
#endif
#ifndef DRM_IOCTL_MODE_MAP_DUMB
#define DRM_IOCTL_MODE_MAP_DUMB      0xC01064B3
#endif
#ifndef DRM_IOCTL_MODE_DESTROY_DUMB
#define DRM_IOCTL_MODE_DESTROY_DUMB  0xC00464B4
#endif

/* DRM connector properties we want to set */
#define PROP_MAX_BPC          "max bpc"

/* ------------------------------------------------------------------ */
/* Pixel packing                                                      */
/* ------------------------------------------------------------------ */

/* Pack 10-bit RGB into XRGB2101010:
 * [31:30]=XX  [29:20]=R  [19:10]=G  [9:0]=B */
static inline uint32_t pack_xr30(uint16_t r, uint16_t g, uint16_t b)
{
    return (3u << 30)
         | ((uint32_t)(r & 0x3FF) << 20)
         | ((uint32_t)(g & 0x3FF) << 10)
         | ((uint32_t)(b & 0x3FF));
}

/* ------------------------------------------------------------------ */
/* Logging                                                            */
/* ------------------------------------------------------------------ */

static FILE *g_logfp = NULL;

static void logmsg(const char *fmt, ...)
{
    if (!g_logfp) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_logfp, fmt, ap);
    va_end(ap);
    fflush(g_logfp);
}

/* ------------------------------------------------------------------ */
/* DRM helpers (raw ioctl, no libdrm dependency)                      */
/* ------------------------------------------------------------------ */

static int drm_fd = -1;

static int drm_ioctl(unsigned long req, void *arg)
{
    int ret;
    do {
        ret = ioctl(drm_fd, req, arg);
    } while (ret == -1 && errno == EINTR);
    return ret;
}

/* Find the first connected HDMI connector and its CRTC */
struct drm_state {
    uint32_t conn_id;
    uint32_t crtc_id;
    uint32_t crtc_idx;
    struct drm_mode_modeinfo mode;
    uint32_t width;
    uint32_t height;
};

static int drm_find_connector(struct drm_state *st)
{
    struct drm_mode_card_res res;
    memset(&res, 0, sizeof(res));

    /* First call: get counts */
    if (drm_ioctl(DRM_IOCTL_MODE_GETRESOURCES, &res) < 0)
        return -1;

    uint32_t *conn_ids = calloc(res.count_connectors, sizeof(uint32_t));
    uint32_t *crtc_ids = calloc(res.count_crtcs, sizeof(uint32_t));
    uint32_t *enc_ids  = calloc(res.count_encoders, sizeof(uint32_t));
    res.connector_id_ptr = (uint64_t)(uintptr_t)conn_ids;
    res.crtc_id_ptr      = (uint64_t)(uintptr_t)crtc_ids;
    res.encoder_id_ptr   = (uint64_t)(uintptr_t)enc_ids;

    if (drm_ioctl(DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) {
        free(conn_ids); free(crtc_ids); free(enc_ids);
        return -1;
    }

    /* Iterate connectors looking for connected HDMI */
    for (uint32_t i = 0; i < res.count_connectors; i++) {
        struct drm_mode_get_connector conn;
        memset(&conn, 0, sizeof(conn));
        conn.connector_id = conn_ids[i];

        /* First call: get counts */
        if (drm_ioctl(DRM_IOCTL_MODE_GETCONNECTOR, &conn) < 0)
            continue;

        if (conn.connection != 1) /* not connected */
            continue;

        /* Check connector type (HDMI-A=11, HDMI-B=12) or any connected */
        if (conn.count_modes == 0)
            continue;

        /* Get modes */
        struct drm_mode_modeinfo *modes = calloc(conn.count_modes, sizeof(*modes));
        uint32_t *encoders = calloc(conn.count_encoders, sizeof(uint32_t));
        uint64_t *props = calloc(conn.count_props, sizeof(uint64_t));
        uint32_t *prop_ids = calloc(conn.count_props, sizeof(uint32_t));

        conn.modes_ptr    = (uint64_t)(uintptr_t)modes;
        conn.encoders_ptr = (uint64_t)(uintptr_t)encoders;
        conn.props_ptr    = (uint64_t)(uintptr_t)prop_ids;
        conn.prop_values_ptr = (uint64_t)(uintptr_t)props;

        if (drm_ioctl(DRM_IOCTL_MODE_GETCONNECTOR, &conn) < 0) {
            free(modes); free(encoders); free(props); free(prop_ids);
            continue;
        }

        /* Find the encoder and CRTC */
        uint32_t enc_id = conn.encoder_id;
        uint32_t target_crtc = 0;

        if (enc_id) {
            struct drm_mode_get_encoder enc;
            memset(&enc, 0, sizeof(enc));
            enc.encoder_id = enc_id;
            if (drm_ioctl(DRM_IOCTL_MODE_GETENCODER, &enc) >= 0) {
                target_crtc = enc.crtc_id;
            }
        }

        if (!target_crtc && conn.count_encoders > 0) {
            /* Try first encoder's possible CRTCs */
            struct drm_mode_get_encoder enc;
            memset(&enc, 0, sizeof(enc));
            enc.encoder_id = encoders[0];
            if (drm_ioctl(DRM_IOCTL_MODE_GETENCODER, &enc) >= 0) {
                /* Pick first possible CRTC */
                for (uint32_t c = 0; c < res.count_crtcs; c++) {
                    if (enc.possible_crtcs & (1u << c)) {
                        target_crtc = crtc_ids[c];
                        break;
                    }
                }
            }
        }

        if (target_crtc) {
            st->conn_id = conn.connector_id;
            st->crtc_id = target_crtc;
            /* Find CRTC index */
            for (uint32_t c = 0; c < res.count_crtcs; c++) {
                if (crtc_ids[c] == target_crtc) {
                    st->crtc_idx = c;
                    break;
                }
            }
            /* Use first preferred mode, or first mode */
            st->mode = modes[0];
            for (uint32_t m = 0; m < conn.count_modes; m++) {
                if (modes[m].type & DRM_MODE_TYPE_PREFERRED) {
                    st->mode = modes[m];
                    break;
                }
            }
            st->width  = st->mode.hdisplay;
            st->height = st->mode.vdisplay;
            logmsg("Found connector %u CRTC %u mode %ux%u@%u\n",
                   st->conn_id, st->crtc_id, st->width, st->height,
                   st->mode.vrefresh);
            free(modes); free(encoders); free(props); free(prop_ids);
            free(conn_ids); free(crtc_ids); free(enc_ids);
            return 0;
        }

        free(modes); free(encoders); free(props); free(prop_ids);
    }

    free(conn_ids); free(crtc_ids); free(enc_ids);
    return -1;
}

/* ------------------------------------------------------------------ */
/* Dumb buffer management                                             */
/* ------------------------------------------------------------------ */

struct dumb_buf {
    uint32_t handle;
    uint32_t fb_id;
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    uint64_t size;
    uint32_t *map;
};

static int dumb_create(struct dumb_buf *buf, uint32_t w, uint32_t h)
{
    struct drm_mode_create_dumb creq;
    memset(&creq, 0, sizeof(creq));
    creq.width  = w;
    creq.height = h;
    creq.bpp    = 32;

    if (drm_ioctl(DRM_IOCTL_MODE_CREATE_DUMB, &creq) < 0) {
        logmsg("CREATE_DUMB failed: %s\n", strerror(errno));
        return -1;
    }

    buf->handle = creq.handle;
    buf->width  = w;
    buf->height = h;
    buf->stride = creq.pitch;
    buf->size   = creq.size;

    /* ADDFB2 with XRGB2101010 */
    struct drm_mode_fb_cmd2 fb;
    memset(&fb, 0, sizeof(fb));
    fb.width  = w;
    fb.height = h;
    fb.pixel_format = DRM_FORMAT_XRGB2101010;
    fb.handles[0]   = buf->handle;
    fb.pitches[0]   = buf->stride;
    fb.offsets[0]   = 0;

    if (drm_ioctl(DRM_IOCTL_MODE_ADDFB2, &fb) < 0) {
        logmsg("ADDFB2 XR30 failed: %s\n", strerror(errno));
        /* Destroy the dumb buffer */
        struct drm_mode_destroy_dumb dreq = { .handle = buf->handle };
        drm_ioctl(DRM_IOCTL_MODE_DESTROY_DUMB, &dreq);
        return -1;
    }
    buf->fb_id = fb.fb_id;

    /* Map the buffer */
    struct drm_mode_map_dumb mreq;
    memset(&mreq, 0, sizeof(mreq));
    mreq.handle = buf->handle;

    if (drm_ioctl(DRM_IOCTL_MODE_MAP_DUMB, &mreq) < 0) {
        logmsg("MAP_DUMB failed: %s\n", strerror(errno));
        return -1;
    }

    buf->map = mmap(NULL, buf->size, PROT_READ | PROT_WRITE, MAP_SHARED,
                    drm_fd, mreq.offset);
    if (buf->map == MAP_FAILED) {
        logmsg("mmap failed: %s\n", strerror(errno));
        buf->map = NULL;
        return -1;
    }

    logmsg("Created %ux%u XR30 dumb buffer (fb=%u stride=%u size=%lu)\n",
           w, h, buf->fb_id, buf->stride, (unsigned long)buf->size);
    return 0;
}

static void dumb_destroy(struct dumb_buf *buf)
{
    if (buf->map) {
        munmap(buf->map, buf->size);
        buf->map = NULL;
    }
    if (buf->fb_id) {
        struct drm_mode_fb_cmd2 fb;
        /* Use RMFB ioctl */
        uint32_t id = buf->fb_id;
        ioctl(drm_fd, DRM_IOCTL_MODE_RMFB, &id);
        buf->fb_id = 0;
    }
    if (buf->handle) {
        struct drm_mode_destroy_dumb dreq = { .handle = buf->handle };
        drm_ioctl(DRM_IOCTL_MODE_DESTROY_DUMB, &dreq);
        buf->handle = 0;
    }
}

/* ------------------------------------------------------------------ */
/* Connector property helpers                                         */
/* ------------------------------------------------------------------ */

static uint32_t find_prop_id(uint32_t conn_id, const char *name)
{
    struct drm_mode_get_connector conn;
    memset(&conn, 0, sizeof(conn));
    conn.connector_id = conn_id;

    if (drm_ioctl(DRM_IOCTL_MODE_GETCONNECTOR, &conn) < 0)
        return 0;

    uint32_t *prop_ids = calloc(conn.count_props, sizeof(uint32_t));
    uint64_t *prop_vals = calloc(conn.count_props, sizeof(uint64_t));
    conn.props_ptr = (uint64_t)(uintptr_t)prop_ids;
    conn.prop_values_ptr = (uint64_t)(uintptr_t)prop_vals;
    conn.modes_ptr = 0; conn.count_modes = 0;
    conn.encoders_ptr = 0; conn.count_encoders = 0;

    if (drm_ioctl(DRM_IOCTL_MODE_GETCONNECTOR, &conn) < 0) {
        free(prop_ids); free(prop_vals);
        return 0;
    }

    uint32_t result = 0;
    for (uint32_t i = 0; i < conn.count_props; i++) {
        struct drm_mode_get_property prop;
        memset(&prop, 0, sizeof(prop));
        prop.prop_id = prop_ids[i];
        if (drm_ioctl(DRM_IOCTL_MODE_GETPROPERTY, &prop) >= 0) {
            if (strcmp(prop.name, name) == 0) {
                result = prop_ids[i];
                break;
            }
        }
    }

    free(prop_ids); free(prop_vals);
    return result;
}

static int set_conn_prop(uint32_t conn_id, uint32_t prop_id, uint64_t value)
{
    struct drm_mode_connector_set_property sp;
    memset(&sp, 0, sizeof(sp));
    sp.connector_id = conn_id;
    sp.prop_id = prop_id;
    sp.value = value;
    return drm_ioctl(DRM_IOCTL_MODE_OBJ_SETPROPERTY, &sp);
}

/* ------------------------------------------------------------------ */
/* Pattern parsing                                                    */
/* ------------------------------------------------------------------ */

struct pattern {
    int      bits;        /* 8, 10, or 12 */
    char     draw[32];    /* RECTANGLE */
    uint32_t dim_w;       /* pattern width */
    uint32_t dim_h;       /* pattern height */
    uint16_t rgb[3];      /* foreground color */
    uint16_t bg[3];       /* background color */
    uint32_t pos_x;       /* center X */
    uint32_t pos_y;       /* center Y */
    int      frame;       /* 1 = commit */
    int      valid;
};

static int read_conf_int(const char *key, int def)
{
    FILE *fp = fopen(CONF_FILE, "r");
    if (!fp) return def;
    char line[256];
    while (fgets(line, sizeof(line), fp)) {
        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = '\0';
        if (strcmp(line, key) == 0) {
            fclose(fp);
            return atoi(eq + 1);
        }
    }
    fclose(fp);
    return def;
}

static void parse_rgb(const char *s, uint16_t out[3])
{
    out[0] = out[1] = out[2] = 0;
    sscanf(s, "%hu,%hu,%hu", &out[0], &out[1], &out[2]);
}

static int parse_ops(struct pattern *pat)
{
    FILE *fp = fopen(OPS_FILE, "r");
    if (!fp) return -1;

    memset(pat, 0, sizeof(*pat));
    pat->bits = read_conf_int("bits_default", 8);
    strcpy(pat->draw, "RECTANGLE");

    char line[512];
    while (fgets(line, sizeof(line), fp)) {
        /* Strip newline */
        char *nl = strchr(line, '\n');
        if (nl) *nl = '\0';
        nl = strchr(line, '\r');
        if (nl) *nl = '\0';

        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = '\0';
        char *key = line;
        char *val = eq + 1;

        if (strcmp(key, "BITS") == 0) {
            pat->bits = atoi(val);
        } else if (strcmp(key, "DRAW") == 0) {
            strncpy(pat->draw, val, sizeof(pat->draw) - 1);
        } else if (strcmp(key, "DIM") == 0) {
            sscanf(val, "%u,%u", &pat->dim_w, &pat->dim_h);
        } else if (strcmp(key, "RGB") == 0) {
            parse_rgb(val, pat->rgb);
        } else if (strcmp(key, "BG") == 0) {
            parse_rgb(val, pat->bg);
        } else if (strcmp(key, "POSITION") == 0) {
            sscanf(val, "%u,%u", &pat->pos_x, &pat->pos_y);
        } else if (strcmp(key, "FRAME") == 0) {
            pat->frame = atoi(val);
        } else if (strcmp(key, "END") == 0) {
            pat->valid = 1;
        }
    }
    fclose(fp);
    return pat->valid ? 0 : -1;
}

/* ------------------------------------------------------------------ */
/* Scale value to 10-bit                                              */
/* ------------------------------------------------------------------ */

static uint16_t scale_to_10bit(uint16_t val, int bits)
{
    if (bits == 10) return val > 1023 ? 1023 : val;
    if (bits == 12) return val > 4095 ? 1023 : (uint16_t)(val * 1023.0 / 4095.0 + 0.5);
    /* 8-bit: scale 0-255 to 0-1023 */
    return val > 255 ? 1023 : (uint16_t)(val * 1023.0 / 255.0 + 0.5);
}

/* ------------------------------------------------------------------ */
/* LUT support                                                        */
/* ------------------------------------------------------------------ */

/* LUT correction table: delta for each 10-bit R,G,B input value */
/* We store deltas for specific entries, apply linearly */
#define MAX_LUT_ENTRIES 1100

struct lut_entry {
    uint16_t in_r, in_g, in_b;      /* input value or 0xFFFF for ALL */
    int16_t  delta_r, delta_g, delta_b;
};

static struct lut_entry g_lut[MAX_LUT_ENTRIES];
static int g_lut_count = 0;
static int g_lut_has_all = 0; /* has ALL wildcard entries */

static void load_lut(void)
{
    g_lut_count = 0;
    g_lut_has_all = 0;

    FILE *fp = fopen(LUT_FILE, "r");
    if (!fp) return;

    char line[256];
    while (fgets(line, sizeof(line), fp) && g_lut_count < MAX_LUT_ENTRIES) {
        char *nl = strchr(line, '\n');
        if (nl) *nl = '\0';
        if (line[0] == '#' || line[0] == '\0') continue;

        /* Format: R,G,B=Rd,Gd,Bd  or  ALL=Rd,Gd,Bd */
        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = '\0';

        struct lut_entry *e = &g_lut[g_lut_count];
        int16_t dr, dg, db;
        if (sscanf(eq + 1, "%hd,%hd,%hd", &dr, &dg, &db) != 3) continue;
        e->delta_r = dr;
        e->delta_g = dg;
        e->delta_b = db;

        if (strcmp(line, "ALL") == 0) {
            e->in_r = e->in_g = e->in_b = 0xFFFF;
            g_lut_has_all = 1;
        } else {
            unsigned r, g, b;
            if (sscanf(line, "%u,%u,%u", &r, &g, &b) != 3) continue;
            e->in_r = r; e->in_g = g; e->in_b = b;
        }
        g_lut_count++;
    }
    fclose(fp);
    logmsg("LUT: loaded %d entries (has_all=%d)\n", g_lut_count, g_lut_has_all);
}

static void apply_lut(uint16_t *r, uint16_t *g, uint16_t *b)
{
    if (g_lut_count == 0) return;

    for (int i = 0; i < g_lut_count; i++) {
        struct lut_entry *e = &g_lut[i];
        if (e->in_r == 0xFFFF) {
            /* ALL wildcard: apply to any input */
            int32_t nr = (int32_t)*r + e->delta_r;
            int32_t ng = (int32_t)*g + e->delta_g;
            int32_t nb = (int32_t)*b + e->delta_b;
            *r = nr < 0 ? 0 : (nr > 1023 ? 1023 : nr);
            *g = ng < 0 ? 0 : (ng > 1023 ? 1023 : ng);
            *b = nb < 0 ? 0 : (nb > 1023 ? 1023 : nb);
            return;
        }
        if (e->in_r == *r && e->in_g == *g && e->in_b == *b) {
            int32_t nr = (int32_t)*r + e->delta_r;
            int32_t ng = (int32_t)*g + e->delta_g;
            int32_t nb = (int32_t)*b + e->delta_b;
            *r = nr < 0 ? 0 : (nr > 1023 ? 1023 : nr);
            *g = ng < 0 ? 0 : (ng > 1023 ? 1023 : ng);
            *b = nb < 0 ? 0 : (nb > 1023 ? 1023 : nb);
            return;
        }
    }
}

/* ------------------------------------------------------------------ */
/* Pattern rendering                                                  */
/* ------------------------------------------------------------------ */

static void render_pattern(struct dumb_buf *buf, struct pattern *pat,
                           uint32_t scr_w, uint32_t scr_h)
{
    if (!buf->map) return;

    /* Scale colors to 10-bit */
    uint16_t fg_r = scale_to_10bit(pat->rgb[0], pat->bits);
    uint16_t fg_g = scale_to_10bit(pat->rgb[1], pat->bits);
    uint16_t fg_b = scale_to_10bit(pat->rgb[2], pat->bits);
    uint16_t bg_r = scale_to_10bit(pat->bg[0], pat->bits);
    uint16_t bg_g = scale_to_10bit(pat->bg[1], pat->bits);
    uint16_t bg_b = scale_to_10bit(pat->bg[2], pat->bits);

    /* Apply LUT correction */
    apply_lut(&fg_r, &fg_g, &fg_b);
    apply_lut(&bg_r, &bg_g, &bg_b);

    uint32_t bg_pixel = pack_xr30(bg_r, bg_g, bg_b);
    uint32_t fg_pixel = pack_xr30(fg_r, fg_g, fg_b);

    uint32_t stride_px = buf->stride / 4;

    logmsg("Render: bits=%d fg=%u,%u,%u (10b: %u,%u,%u) bg=%u,%u,%u (10b: %u,%u,%u)\n",
           pat->bits,
           pat->rgb[0], pat->rgb[1], pat->rgb[2], fg_r, fg_g, fg_b,
           pat->bg[0], pat->bg[1], pat->bg[2], bg_r, bg_g, bg_b);
    logmsg("  dim=%ux%u pos=%u,%u scr=%ux%u\n",
           pat->dim_w, pat->dim_h, pat->pos_x, pat->pos_y, scr_w, scr_h);

    /* Full-field pattern: dim matches screen or no position */
    if (pat->dim_w >= scr_w && pat->dim_h >= scr_h) {
        /* Full screen foreground — fast fill */
        for (uint32_t y = 0; y < scr_h; y++) {
            uint32_t *row = buf->map + y * stride_px;
            for (uint32_t x = 0; x < scr_w; x++)
                row[x] = fg_pixel;
        }
    } else {
        /* Windowed pattern: background + foreground rectangle */
        /* First fill background */
        for (uint32_t y = 0; y < scr_h; y++) {
            uint32_t *row = buf->map + y * stride_px;
            for (uint32_t x = 0; x < scr_w; x++)
                row[x] = bg_pixel;
        }

        /* Calculate rectangle position (POSITION is center) */
        uint32_t rw = pat->dim_w < scr_w ? pat->dim_w : scr_w;
        uint32_t rh = pat->dim_h < scr_h ? pat->dim_h : scr_h;
        int32_t rx = (int32_t)pat->pos_x - rw / 2;
        int32_t ry = (int32_t)pat->pos_y - rh / 2;
        if (rx < 0) rx = 0;
        if (ry < 0) ry = 0;
        if (rx + rw > scr_w) rx = scr_w - rw;
        if (ry + rh > scr_h) ry = scr_h - rh;

        /* Draw foreground rectangle */
        for (uint32_t y = ry; y < (uint32_t)(ry + rh) && y < scr_h; y++) {
            uint32_t *row = buf->map + y * stride_px;
            for (uint32_t x = rx; x < (uint32_t)(rx + rw) && x < scr_w; x++)
                row[x] = fg_pixel;
        }
    }
}

/* ------------------------------------------------------------------ */
/* CRTC set                                                           */
/* ------------------------------------------------------------------ */

static int set_crtc(struct drm_state *st, uint32_t fb_id)
{
    struct drm_mode_crtc crtc;
    memset(&crtc, 0, sizeof(crtc));
    crtc.crtc_id = st->crtc_id;

    /* Get existing CRTC state */
    if (drm_ioctl(DRM_IOCTL_MODE_GETCRTC, &crtc) < 0) {
        logmsg("GETCRTC failed: %s\n", strerror(errno));
    }

    /* Set our framebuffer */
    crtc.fb_id = fb_id;
    crtc.set_connectors_ptr = (uint64_t)(uintptr_t)&st->conn_id;
    crtc.count_connectors = 1;
    crtc.mode = st->mode;
    crtc.mode_valid = 1;

    if (drm_ioctl(DRM_IOCTL_MODE_SETCRTC, &crtc) < 0) {
        logmsg("SETCRTC failed: %s (fb=%u crtc=%u conn=%u)\n",
               strerror(errno), fb_id, st->crtc_id, st->conn_id);
        return -1;
    }
    logmsg("SETCRTC ok: fb=%u crtc=%u mode=%ux%u\n",
           fb_id, st->crtc_id, st->width, st->height);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Page flip for vsync                                                */
/* ------------------------------------------------------------------ */

static int page_flip(struct drm_state *st, uint32_t fb_id)
{
    struct drm_mode_crtc_page_flip flip;
    memset(&flip, 0, sizeof(flip));
    flip.crtc_id = st->crtc_id;
    flip.fb_id = fb_id;
    flip.flags = 0; /* no async, no event */

    if (drm_ioctl(DRM_IOCTL_MODE_PAGE_FLIP, &flip) < 0) {
        /* PAGE_FLIP may fail if mode not set — fall back to SETCRTC */
        return set_crtc(st, fb_id);
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* DRM master management                                              */
/* ------------------------------------------------------------------ */

static int become_drm_master(void)
{
    /* Try to become DRM master */
    if (drm_ioctl(DRM_IOCTL_SET_MASTER, NULL) < 0) {
        /* If we can't become master, try to drop/re-acquire */
        drm_ioctl(DRM_IOCTL_DROP_MASTER, NULL);
        if (drm_ioctl(DRM_IOCTL_SET_MASTER, NULL) < 0) {
            logmsg("Cannot become DRM master: %s\n", strerror(errno));
            return -1;
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* Signal handling                                                    */
/* ------------------------------------------------------------------ */

static volatile sig_atomic_t g_running = 1;
static volatile sig_atomic_t g_reload  = 0;

static void sig_handler(int sig)
{
    if (sig == SIGUSR1)
        g_reload = 1;
    else
        g_running = 0;
}

/* ------------------------------------------------------------------ */
/* max_bpc property set                                               */
/* ------------------------------------------------------------------ */

static void set_max_bpc(uint32_t conn_id, int bpc)
{
    uint32_t pid = find_prop_id(conn_id, PROP_MAX_BPC);
    if (pid) {
        struct drm_mode_obj_set_property sp;
        memset(&sp, 0, sizeof(sp));
        sp.value = bpc;
        sp.prop_id = pid;
        sp.obj_id = conn_id;
        sp.obj_type = DRM_MODE_OBJECT_CONNECTOR;
        if (drm_ioctl(DRM_IOCTL_MODE_OBJ_SETPROPERTY, &sp) >= 0) {
            logmsg("Set max_bpc=%d on connector %u\n", bpc, conn_id);
        }
    }
}

/* ------------------------------------------------------------------ */
/* Disable hardware CSC via setuid helper                             */
/* ------------------------------------------------------------------ */

static void disable_csc(void)
{
    int ret = system("/usr/sbin/disable_csc");
    if (ret == 0) {
        logmsg("CSC disabled via helper\n");
    } else {
        logmsg("CSC disable failed (ret=%d)\n", ret);
    }
}

/* ------------------------------------------------------------------ */
/* Main                                                               */
/* ------------------------------------------------------------------ */

int main(int argc, char *argv[])
{
    uint32_t screen_w = 1920, screen_h = 1080;

    if (argc >= 3) {
        screen_w = atoi(argv[1]);
        screen_h = atoi(argv[2]);
    }

    /* Open log */
    g_logfp = fopen("/tmp/pgeneratord_10bit.log", "a");
    logmsg("\n=== pgeneratord_10bit start (%ux%u) ===\n", screen_w, screen_h);

    /* Load LUT */
    load_lut();

    /* Install signal handlers */
    signal(SIGINT,  sig_handler);
    signal(SIGTERM, sig_handler);
    signal(SIGUSR1, sig_handler);

    /* Read config */
    int max_bpc = read_conf_int("max_bpc", 10);

    /* Open DRM device */
    drm_fd = open(DRM_DEVICE, O_RDWR | O_CLOEXEC);
    if (drm_fd < 0) {
        drm_fd = open(DRM_DEVICE0, O_RDWR | O_CLOEXEC);
        if (drm_fd < 0) {
            logmsg("Cannot open DRM device: %s\n", strerror(errno));
            return 1;
        }
        logmsg("Using %s\n", DRM_DEVICE0);
    } else {
        logmsg("Using %s\n", DRM_DEVICE);
    }

    /* Become DRM master */
    if (become_drm_master() < 0) {
        logmsg("Cannot become DRM master, trying without...\n");
    }

    /* Set capabilities - universal planes */
    {
        struct drm_set_client_cap cap;
        cap.capability = DRM_CLIENT_CAP_UNIVERSAL_PLANES;
        cap.value = 1;
        drm_ioctl(DRM_IOCTL_SET_CLIENT_CAP, &cap);

        cap.capability = DRM_CLIENT_CAP_ATOMIC;
        cap.value = 1;
        drm_ioctl(DRM_IOCTL_SET_CLIENT_CAP, &cap);
    }

    /* Find connector and CRTC */
    struct drm_state st;
    memset(&st, 0, sizeof(st));
    if (drm_find_connector(&st) < 0) {
        logmsg("No connected display found\n");
        close(drm_fd);
        return 1;
    }

    /* Override screen size if mode differs from requested */
    if (st.width != screen_w || st.height != screen_h) {
        logmsg("Adjusting to mode %ux%u (requested %ux%u)\n",
               st.width, st.height, screen_w, screen_h);
        screen_w = st.width;
        screen_h = st.height;
    }

    /* Set max_bpc */
    set_max_bpc(st.conn_id, max_bpc);

    /* Create double-buffered dumb buffers */
    struct dumb_buf bufs[2];
    memset(bufs, 0, sizeof(bufs));
    int cur_buf = 0;

    if (dumb_create(&bufs[0], screen_w, screen_h) < 0) {
        logmsg("Failed to create dumb buffer 0\n");
        close(drm_fd);
        return 1;
    }
    if (dumb_create(&bufs[1], screen_w, screen_h) < 0) {
        logmsg("Failed to create dumb buffer 1\n");
        dumb_destroy(&bufs[0]);
        close(drm_fd);
        return 1;
    }

    /* Render initial black screen */
    struct pattern pat;
    memset(&pat, 0, sizeof(pat));
    pat.bits = 10;
    pat.dim_w = screen_w;
    pat.dim_h = screen_h;
    pat.valid = 1;
    render_pattern(&bufs[cur_buf], &pat, screen_w, screen_h);

    /* Set CRTC to display our buffer */
    if (set_crtc(&st, bufs[cur_buf].fb_id) < 0) {
        logmsg("Initial SETCRTC failed\n");
        dumb_destroy(&bufs[0]);
        dumb_destroy(&bufs[1]);
        close(drm_fd);
        return 1;
    }

    /* Disable CSC after modeset */
    disable_csc();

    logmsg("Display initialized, entering main loop\n");

    /* Main loop: watch for operations.txt changes */
    struct timespec last_mtime = {0, 0};

    while (g_running) {
        /* Check if operations.txt was modified */
        struct stat st_ops;
        int need_render = g_reload;
        g_reload = 0;

        if (stat(OPS_FILE, &st_ops) == 0) {
            if (st_ops.st_mtim.tv_sec != last_mtime.tv_sec ||
                st_ops.st_mtim.tv_nsec != last_mtime.tv_nsec) {
                last_mtime = st_ops.st_mtim;
                need_render = 1;
            }
        }

        if (need_render) {
            if (parse_ops(&pat) == 0) {
                /* Render to back buffer */
                int back = 1 - cur_buf;
                render_pattern(&bufs[back], &pat, screen_w, screen_h);

                /* Flip */
                if (page_flip(&st, bufs[back].fb_id) == 0) {
                    cur_buf = back;
                }

                /* Disable CSC after every flip (modeset re-enables it) */
                disable_csc();
            }
        }

        /* Sleep 50ms between polls (20 Hz check rate, adequate for calibration) */
        usleep(50000);
    }

    logmsg("Shutting down...\n");

    /* Cleanup */
    dumb_destroy(&bufs[0]);
    dumb_destroy(&bufs[1]);

    drm_ioctl(DRM_IOCTL_DROP_MASTER, NULL);
    close(drm_fd);

    if (g_logfp) fclose(g_logfp);
    return 0;
}
