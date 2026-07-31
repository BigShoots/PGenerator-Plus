#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif

#define DRM_IOCTL_BASE 'd'
#define DRM_IOWR(nr, type) _IOWR(DRM_IOCTL_BASE, nr, type)

#define DRM_DISPLAY_MODE_LEN 32
#define DRM_PROP_NAME_LEN 32

#define DRM_MODE_CONNECTED 1
#define DRM_MODE_CONNECTOR_HDMIA 11
#define DRM_MODE_CONNECTOR_HDMIB 12
#define DRM_MODE_OBJECT_CONNECTOR 0xc0c0c0c0

struct drm_mode_modeinfo {
 uint32_t clock;
 uint16_t hdisplay;
 uint16_t hsync_start;
 uint16_t hsync_end;
 uint16_t htotal;
 uint16_t hskew;
 uint16_t vdisplay;
 uint16_t vsync_start;
 uint16_t vsync_end;
 uint16_t vtotal;
 uint16_t vscan;
 uint32_t vrefresh;
 uint32_t flags;
 uint32_t type;
 char name[DRM_DISPLAY_MODE_LEN];
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
 uint32_t min_width;
 uint32_t max_width;
 uint32_t min_height;
 uint32_t max_height;
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
 uint32_t mm_width;
 uint32_t mm_height;
 uint32_t subpixel;
 uint32_t pad;
};

struct drm_mode_property_enum {
 uint64_t value;
 char name[DRM_PROP_NAME_LEN];
};

struct drm_mode_get_property {
 uint64_t values_ptr;
 uint64_t enum_blob_ptr;
 uint32_t prop_id;
 uint32_t flags;
 char name[DRM_PROP_NAME_LEN];
 uint32_t count_values;
 uint32_t count_enum_blobs;
};

struct drm_mode_obj_get_properties {
 uint64_t props_ptr;
 uint64_t prop_values_ptr;
 uint32_t count_props;
 uint32_t obj_id;
 uint32_t obj_type;
};

struct drm_mode_obj_set_property {
 uint64_t value;
 uint32_t prop_id;
 uint32_t obj_id;
 uint32_t obj_type;
};

struct drm_mode_create_blob {
 uint64_t data;
 uint32_t length;
 uint32_t blob_id;
};

struct drm_mode_destroy_blob {
 uint32_t blob_id;
};

struct hdr_metadata_infoframe {
 uint8_t eotf;
 uint8_t metadata_type;
 struct {
  uint16_t x;
  uint16_t y;
 } display_primaries[3];
 struct {
  uint16_t x;
  uint16_t y;
 } white_point;
 uint16_t max_display_mastering_luminance;
 uint16_t min_display_mastering_luminance;
 uint16_t max_cll;
 uint16_t max_fall;
};

struct hdr_output_metadata {
 uint32_t metadata_type;
 union {
  struct hdr_metadata_infoframe hdmi_metadata_type1;
 };
};

#define DRM_IOCTL_MODE_GETRESOURCES DRM_IOWR(0xA0, struct drm_mode_card_res)
#define DRM_IOCTL_MODE_GETCONNECTOR DRM_IOWR(0xA7, struct drm_mode_get_connector)
#define DRM_IOCTL_MODE_GETPROPERTY DRM_IOWR(0xAA, struct drm_mode_get_property)
#define DRM_IOCTL_MODE_OBJ_GETPROPERTIES DRM_IOWR(0xB9, struct drm_mode_obj_get_properties)
#define DRM_IOCTL_MODE_OBJ_SETPROPERTY DRM_IOWR(0xBA, struct drm_mode_obj_set_property)
#define DRM_IOCTL_MODE_CREATEPROPBLOB DRM_IOWR(0xBD, struct drm_mode_create_blob)
#define DRM_IOCTL_MODE_DESTROYPROPBLOB DRM_IOWR(0xBE, struct drm_mode_destroy_blob)
/* Linux UAPI for DRM master:
 *   #define DRM_IOCTL_SET_MASTER    _IO('d', 0x1e)
 *   #define DRM_IOCTL_DROP_MASTER   _IO('d', 0x1f)
 * On 32-bit ARM (Pi4) the direction bits are 0, so:
 *   _IO('d', 0x1e) = ('d' << 8) | 0x1e = 0x641e
 *   _IO('d', 0x1f) = ('d' << 8) | 0x1f = 0x641f
 * On 64-bit x86, the direction bits would be (0 << 30), still 0x641e, but
 * the kernel normalizes to 0x2001001e because of the no-size _IO encoding.
 * This works on 32-bit ARM and matches the kernel's expectation. */
#define DRM_IOCTL_SET_MASTER 0x641e
#define DRM_IOCTL_DROP_MASTER 0x641f

struct config_state {
 int is_hdr;
 int dv_status;
 int eotf;
 int primaries;
 int max_luma;
 double min_luma;
 int max_cll;
 int max_fall;
};

static int parse_int(const char *path, const char *key, int *out) {
 FILE *fh = fopen(path, "r");
 char line[256];
 size_t key_len = strlen(key);
 if (!fh) return -1;
 while (fgets(line, sizeof(line), fh)) {
  if (strncmp(line, key, key_len) == 0 && line[key_len] == '=') {
   *out = atoi(line + key_len + 1);
   fclose(fh);
   return 0;
  }
 }
 fclose(fh);
 return -1;
}

static int parse_double(const char *path, const char *key, double *out) {
 FILE *fh = fopen(path, "r");
 char line[256];
 size_t key_len = strlen(key);
 if (!fh) return -1;
 while (fgets(line, sizeof(line), fh)) {
  if (strncmp(line, key, key_len) == 0 && line[key_len] == '=') {
   *out = atof(line + key_len + 1);
   fclose(fh);
   return 0;
  }
 }
 fclose(fh);
 return -1;
}

static void read_config(struct config_state *cfg) {
 memset(cfg, 0, sizeof(*cfg));
 cfg->primaries = 1;
 cfg->eotf = 0;
 cfg->max_luma = 1000;
 cfg->min_luma = 0.005;
 cfg->max_cll = 1000;
 cfg->max_fall = 400;
 parse_int("/etc/PGenerator/PGenerator.conf", "is_hdr", &cfg->is_hdr);
 parse_int("/etc/PGenerator/PGenerator.conf", "dv_status", &cfg->dv_status);
 parse_int("/etc/PGenerator/PGenerator.conf", "eotf", &cfg->eotf);
 parse_int("/etc/PGenerator/PGenerator.conf", "primaries", &cfg->primaries);
 parse_int("/etc/PGenerator/PGenerator.conf", "max_luma", &cfg->max_luma);
 parse_double("/etc/PGenerator/PGenerator.conf", "min_luma", &cfg->min_luma);
 parse_int("/etc/PGenerator/PGenerator.conf", "max_cll", &cfg->max_cll);
 parse_int("/etc/PGenerator/PGenerator.conf", "max_fall", &cfg->max_fall);
}

static uint16_t coord_to_u16(double value) {
 if (value < 0.0) value = 0.0;
 if (value > 1.0) value = 1.0;
 return (uint16_t)((value / 0.00002) + 0.5);
}

static uint16_t min_luma_to_u16(double value) {
 if (value < 0.0) value = 0.0;
 if (value > 6.5535) value = 6.5535;
 return (uint16_t)((value / 0.0001) + 0.5);
}

static uint16_t clamp_u16_int(int value) {
 if (value < 0) value = 0;
 if (value > 65535) value = 65535;
 return (uint16_t)value;
}

static int ioctl_retry(int fd, unsigned long req, void *arg) {
 int ret;
 do {
  ret = ioctl(fd, req, arg);
 } while (ret < 0 && errno == EINTR);
 return ret;
}

static int open_vc4_card(void) {
 int idx;
 char sys_path[128];
 char drv_path[256];
 char dev_path[64];
 ssize_t len;

 for (idx = 0; idx < 16; idx++) {
  snprintf(sys_path, sizeof(sys_path), "/sys/class/drm/card%d/device/driver", idx);
  len = readlink(sys_path, drv_path, sizeof(drv_path) - 1);
  if (len <= 0) continue;
  drv_path[len] = '\0';
  if (strstr(drv_path, "vc4-drm") == NULL) continue;
  snprintf(dev_path, sizeof(dev_path), "/dev/dri/card%d", idx);
  return open(dev_path, O_RDWR | O_CLOEXEC);
 }

 return open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
}

static int find_connector_and_hdr_prop(uint32_t *connector_id, uint32_t *prop_id) {
 FILE *fp;
 char line[512];
 int in_connected_hdmi = 0;

 *connector_id = 0;
 *prop_id = 0;
 fp = popen("modetest -M vc4 -c 2>/dev/null", "r");
 if (!fp) return -1;

 while (fgets(line, sizeof(line), fp)) {
  unsigned int maybe_id = 0;
  unsigned int maybe_enc = 0;
  char status[64];
  char name[64];
  unsigned int maybe_prop = 0;
  char prop_name[128];

  if (sscanf(line, "%u %u %63s %63s", &maybe_id, &maybe_enc, status, name) == 4) {
   if (strcmp(status, "connected") == 0 && strncmp(name, "HDMI", 4) == 0) {
    *connector_id = maybe_id;
    in_connected_hdmi = 1;
   } else {
    in_connected_hdmi = 0;
   }
   continue;
  }

  if (in_connected_hdmi && sscanf(line, " %u %127[^:]", &maybe_prop, prop_name) == 2) {
   if (strcmp(prop_name, "HDR_OUTPUT_METADATA") == 0) {
    *prop_id = maybe_prop;
    pclose(fp);
    return 0;
   }
  }
 }

 pclose(fp);
 return -1;
}

static void set_bt2020_primaries(struct hdr_output_metadata *meta) {
 meta->hdmi_metadata_type1.display_primaries[0].x = coord_to_u16(0.7080);
 meta->hdmi_metadata_type1.display_primaries[0].y = coord_to_u16(0.2920);
 meta->hdmi_metadata_type1.display_primaries[1].x = coord_to_u16(0.1700);
 meta->hdmi_metadata_type1.display_primaries[1].y = coord_to_u16(0.7970);
 meta->hdmi_metadata_type1.display_primaries[2].x = coord_to_u16(0.1310);
 meta->hdmi_metadata_type1.display_primaries[2].y = coord_to_u16(0.0460);
 meta->hdmi_metadata_type1.white_point.x = coord_to_u16(0.3127);
 meta->hdmi_metadata_type1.white_point.y = coord_to_u16(0.3290);
}

static void set_bt709_primaries(struct hdr_output_metadata *meta) {
 meta->hdmi_metadata_type1.display_primaries[0].x = coord_to_u16(0.6400);
 meta->hdmi_metadata_type1.display_primaries[0].y = coord_to_u16(0.3300);
 meta->hdmi_metadata_type1.display_primaries[1].x = coord_to_u16(0.3000);
 meta->hdmi_metadata_type1.display_primaries[1].y = coord_to_u16(0.6000);
 meta->hdmi_metadata_type1.display_primaries[2].x = coord_to_u16(0.1500);
 meta->hdmi_metadata_type1.display_primaries[2].y = coord_to_u16(0.0600);
 meta->hdmi_metadata_type1.white_point.x = coord_to_u16(0.3127);
 meta->hdmi_metadata_type1.white_point.y = coord_to_u16(0.3290);
}

static void set_p3_primaries(struct hdr_output_metadata *meta) {
 meta->hdmi_metadata_type1.display_primaries[0].x = coord_to_u16(0.6800);
 meta->hdmi_metadata_type1.display_primaries[0].y = coord_to_u16(0.3200);
 meta->hdmi_metadata_type1.display_primaries[1].x = coord_to_u16(0.2650);
 meta->hdmi_metadata_type1.display_primaries[1].y = coord_to_u16(0.6900);
 meta->hdmi_metadata_type1.display_primaries[2].x = coord_to_u16(0.1500);
 meta->hdmi_metadata_type1.display_primaries[2].y = coord_to_u16(0.0600);
 meta->hdmi_metadata_type1.white_point.x = coord_to_u16(0.3127);
 meta->hdmi_metadata_type1.white_point.y = coord_to_u16(0.3290);
}

static void fill_hdr_metadata(struct hdr_output_metadata *meta, const struct config_state *cfg) {
 memset(meta, 0, sizeof(*meta));
 meta->metadata_type = 0;
 meta->hdmi_metadata_type1.metadata_type = 0;
 meta->hdmi_metadata_type1.eotf = (uint8_t)cfg->eotf;
 if (cfg->primaries == 0) set_bt709_primaries(meta);
 else if (cfg->primaries == 2) set_p3_primaries(meta);
 else set_bt2020_primaries(meta);
 meta->hdmi_metadata_type1.max_display_mastering_luminance = clamp_u16_int(cfg->max_luma);
 meta->hdmi_metadata_type1.min_display_mastering_luminance = min_luma_to_u16(cfg->min_luma);
 meta->hdmi_metadata_type1.max_cll = clamp_u16_int(cfg->max_cll);
 meta->hdmi_metadata_type1.max_fall = clamp_u16_int(cfg->max_fall);
}

static int set_connector_property(int fd, uint32_t connector_id, uint32_t prop_id, uint64_t value) {
 struct drm_mode_obj_set_property sp;
 memset(&sp, 0, sizeof(sp));
 sp.value = value;
 sp.prop_id = prop_id;
 sp.obj_id = connector_id;
 sp.obj_type = DRM_MODE_OBJECT_CONNECTOR;
 return ioctl_retry(fd, DRM_IOCTL_MODE_OBJ_SETPROPERTY, &sp);
}

int main(void) {
 struct config_state cfg;
 struct hdr_output_metadata meta;
 struct drm_mode_create_blob create_blob;
 struct drm_mode_destroy_blob destroy_blob;
 uint32_t connector_id = 0;
 uint32_t hdr_prop_id = 0;
 uint32_t blob_id = 0;
 int fd;

 read_config(&cfg);
 fd = open_vc4_card();
 if (fd < 0) {
  fprintf(stderr, "pgsethdr: open vc4 DRM card failed: %s\n", strerror(errno));
  return 1;
 }
 /* The renderer (PGeneratord) is the DRM master while running. pgsethdr
  * needs to set the connector's HDR_OUTPUT_METADATA property, which is a
  * master-only operation. Acquire the master (which steals it from the
  * renderer), do the work, then drop the master so the renderer can
  * reclaim it on its next open/ioctl. If the renderer is not running,
  * SET_MASTER succeeds unconditionally and the DROP_MASTER is a no-op. */
 {
  int r = ioctl_retry(fd, DRM_IOCTL_SET_MASTER, 0);
  if (r < 0) {
   fprintf(stderr, "pgsethdr: SET_MASTER failed: %s (continuing without master)\n", strerror(errno));
  }
 }
  if (find_connector_and_hdr_prop(&connector_id, &hdr_prop_id) < 0) {
   fprintf(stderr, "pgsethdr: could not locate connected HDMI connector or HDR_OUTPUT_METADATA property\n");
   (void)ioctl_retry(fd, DRM_IOCTL_DROP_MASTER, 0);
   close(fd);
   return 1;
  }

  if (cfg.dv_status == 1 || cfg.is_hdr != 1 || cfg.eotf < 2) {
   if (set_connector_property(fd, connector_id, hdr_prop_id, 0) < 0) {
    fprintf(stderr, "pgsethdr: clearing HDR_OUTPUT_METADATA failed: %s\n", strerror(errno));
    (void)ioctl_retry(fd, DRM_IOCTL_DROP_MASTER, 0);
    close(fd);
    return 1;
   }
   printf("pgsethdr: connector=%u cleared HDR metadata\n", connector_id);
   (void)ioctl_retry(fd, DRM_IOCTL_DROP_MASTER, 0);
   close(fd);
   return 0;
  }

  fill_hdr_metadata(&meta, &cfg);
  memset(&create_blob, 0, sizeof(create_blob));
  create_blob.data = (uint64_t)(uintptr_t)&meta;
  create_blob.length = sizeof(meta);
  if (ioctl_retry(fd, DRM_IOCTL_MODE_CREATEPROPBLOB, &create_blob) < 0) {
   fprintf(stderr, "pgsethdr: CREATEPROPBLOB failed: %s\n", strerror(errno));
   (void)ioctl_retry(fd, DRM_IOCTL_DROP_MASTER, 0);
   close(fd);
   return 1;
  }
  blob_id = create_blob.blob_id;

  if (set_connector_property(fd, connector_id, hdr_prop_id, blob_id) < 0) {
   fprintf(stderr, "pgsethdr: setting HDR_OUTPUT_METADATA blob %u failed: %s\n", blob_id, strerror(errno));
   (void)ioctl_retry(fd, DRM_IOCTL_DROP_MASTER, 0);
   close(fd);
   return 1;
  }

 memset(&destroy_blob, 0, sizeof(destroy_blob));
 destroy_blob.blob_id = blob_id;
 if (ioctl_retry(fd, DRM_IOCTL_MODE_DESTROYPROPBLOB, &destroy_blob) < 0) {
  fprintf(stderr, "pgsethdr: warning: destroy blob %u failed: %s\n", blob_id, strerror(errno));
 }

 printf("pgsethdr: connector=%u eotf=%d primaries=%d blob=%u applied\n",
  connector_id, cfg.eotf, cfg.primaries, blob_id);
 (void)ioctl_retry(fd, DRM_IOCTL_DROP_MASTER, 0);
 close(fd);
 return 0;
}
