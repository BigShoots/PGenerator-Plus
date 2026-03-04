/*
 * drm_player.c — Minimal DRM/KMS video player for PGenerator
 *
 * Uses raw DRM ioctls — no libdrm dependency. Builds as a fully
 * static binary so it runs on any ARM Linux regardless of glibc version.
 *
 * Reads XRGB8888 frames from stdin (piped from ffmpeg) and displays
 * via DRM/KMS on /dev/dri/card0 with double-buffered dumb buffers.
 *
 * Must be run when PGeneratord is NOT active (needs DRM master).
 *
 * Usage:
 *   ffmpeg -re -stream_loop -1 -i video.mp4 \
 *     -vf "scale=1920:1080" -pix_fmt bgr0 -f rawvideo pipe:1 \
 *     | drm_player [width height [connector_id]]
 *
 * Compile (cross, static):
 *   arm-linux-gnueabihf-gcc -static -O2 \
 *     -I/tmp/drm_headers/libdrm \
 *     -o drm_player drm_player.c
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <stdint.h>
#include <errno.h>

/*
 * Include only the kernel DRM headers for struct definitions.
 * We call ioctl() directly instead of using libdrm wrapper functions.
 */
#include <drm.h>
#include <drm_mode.h>

/* DRM ioctl helpers — define only if not already in drm.h */
#ifndef DRM_IOCTL_SET_MASTER
#define DRM_IOCTL_SET_MASTER        DRM_IO(0x1e)
#endif
#ifndef DRM_IOCTL_DROP_MASTER
#define DRM_IOCTL_DROP_MASTER       DRM_IO(0x1f)
#endif
#ifndef DRM_IOCTL_MODE_GETRESOURCES
#define DRM_IOCTL_MODE_GETRESOURCES DRM_IOWR_NR(0xA0, struct drm_mode_card_res)
#endif
#ifndef DRM_IOCTL_MODE_GETCRTC
#define DRM_IOCTL_MODE_GETCRTC      DRM_IOWR_NR(0xA1, struct drm_mode_crtc)
#endif
#ifndef DRM_IOCTL_MODE_SETCRTC
#define DRM_IOCTL_MODE_SETCRTC      DRM_IOWR_NR(0xA2, struct drm_mode_crtc)
#endif
#ifndef DRM_IOCTL_MODE_GETCONNECTOR
#define DRM_IOCTL_MODE_GETCONNECTOR DRM_IOWR_NR(0xA7, struct drm_mode_get_connector)
#endif
#ifndef DRM_IOCTL_MODE_GETENCODER
#define DRM_IOCTL_MODE_GETENCODER   DRM_IOWR_NR(0xA6, struct drm_mode_get_encoder)
#endif
#ifndef DRM_IOCTL_MODE_ADDFB
#define DRM_IOCTL_MODE_ADDFB        DRM_IOWR_NR(0xAE, struct drm_mode_fb_cmd)
#endif
#ifndef DRM_IOCTL_MODE_RMFB
#define DRM_IOCTL_MODE_RMFB         DRM_IOWR_NR(0xAF, unsigned int)
#endif
#ifndef DRM_IOCTL_MODE_CREATE_DUMB
#define DRM_IOCTL_MODE_CREATE_DUMB  DRM_IOWR_NR(0xB2, struct drm_mode_create_dumb)
#endif
#ifndef DRM_IOCTL_MODE_MAP_DUMB
#define DRM_IOCTL_MODE_MAP_DUMB     DRM_IOWR_NR(0xB3, struct drm_mode_map_dumb)
#endif
#ifndef DRM_IOCTL_MODE_DESTROY_DUMB
#define DRM_IOCTL_MODE_DESTROY_DUMB DRM_IOWR_NR(0xB4, struct drm_mode_destroy_dumb)
#endif

/* Connector types */
#define DRM_MODE_CONNECTOR_HDMIA    11
#define DRM_MODE_CONNECTOR_HDMIB    12
#define DRM_MODE_CONNECTED          1

static int drm_fd = -1;

static int drm_ioctl(int fd, unsigned long req, void *arg) {
 int ret;
 do {
  ret = ioctl(fd, req, arg);
 } while (ret == -1 && (errno == EINTR || errno == EAGAIN));
 return ret;
}

/* ---- Resource fetching (replaces libdrm functions) ---- */

struct my_resources {
 uint32_t count_crtcs;
 uint32_t *crtc_ids;
 uint32_t count_connectors;
 uint32_t *connector_ids;
};

static int get_resources(struct my_resources *r) {
 struct drm_mode_card_res res;
 memset(&res, 0, sizeof(res));
 memset(r, 0, sizeof(*r));

 /* First call: get counts */
 if (drm_ioctl(drm_fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0)
  return -1;

 r->count_crtcs = res.count_crtcs;
 r->count_connectors = res.count_connectors;
 r->crtc_ids = calloc(res.count_crtcs, sizeof(uint32_t));
 r->connector_ids = calloc(res.count_connectors, sizeof(uint32_t));

 /* Also need encoder/fb arrays for ioctl but we don't use them */
 uint32_t *enc_ids = calloc(res.count_encoders ? res.count_encoders : 1, sizeof(uint32_t));
 uint32_t *fb_ids = calloc(res.count_fbs ? res.count_fbs : 1, sizeof(uint32_t));

 res.crtc_id_ptr = (uint64_t)(uintptr_t)r->crtc_ids;
 res.connector_id_ptr = (uint64_t)(uintptr_t)r->connector_ids;
 res.encoder_id_ptr = (uint64_t)(uintptr_t)enc_ids;
 res.fb_id_ptr = (uint64_t)(uintptr_t)fb_ids;

 if (drm_ioctl(drm_fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) {
  free(enc_ids); free(fb_ids);
  return -1;
 }
 free(enc_ids); free(fb_ids);
 return 0;
}

struct my_connector {
 uint32_t connector_id;
 uint32_t connector_type;
 uint32_t connection;  /* 1=connected */
 uint32_t encoder_id;
 int count_modes;
 struct drm_mode_modeinfo *modes;
 int count_encoders;
 uint32_t *encoders;
};

static int get_connector(uint32_t id, struct my_connector *c) {
 struct drm_mode_get_connector gc;
 memset(&gc, 0, sizeof(gc));
 memset(c, 0, sizeof(*c));
 gc.connector_id = id;

 /* First call: get counts */
 if (drm_ioctl(drm_fd, DRM_IOCTL_MODE_GETCONNECTOR, &gc) < 0)
  return -1;

 c->connector_id = gc.connector_id;
 c->connector_type = gc.connector_type;
 c->connection = gc.connection;
 c->encoder_id = gc.encoder_id;
 c->count_modes = gc.count_modes;
 c->count_encoders = gc.count_encoders;

 c->modes = calloc(gc.count_modes ? gc.count_modes : 1, sizeof(struct drm_mode_modeinfo));
 c->encoders = calloc(gc.count_encoders ? gc.count_encoders : 1, sizeof(uint32_t));
 uint32_t *props = calloc(gc.count_props ? gc.count_props : 1, sizeof(uint32_t));
 uint64_t *prop_vals = calloc(gc.count_props ? gc.count_props : 1, sizeof(uint64_t));

 gc.modes_ptr = (uint64_t)(uintptr_t)c->modes;
 gc.encoders_ptr = (uint64_t)(uintptr_t)c->encoders;
 gc.props_ptr = (uint64_t)(uintptr_t)props;
 gc.prop_values_ptr = (uint64_t)(uintptr_t)prop_vals;

 if (drm_ioctl(drm_fd, DRM_IOCTL_MODE_GETCONNECTOR, &gc) < 0) {
  free(props); free(prop_vals);
  return -1;
 }
 free(props); free(prop_vals);

 c->connection = gc.connection;
 c->encoder_id = gc.encoder_id;
 c->count_modes = gc.count_modes;
 return 0;
}

static uint32_t get_encoder_crtc(uint32_t enc_id) {
 struct drm_mode_get_encoder enc;
 memset(&enc, 0, sizeof(enc));
 enc.encoder_id = enc_id;
 if (drm_ioctl(drm_fd, DRM_IOCTL_MODE_GETENCODER, &enc) < 0)
  return 0;
 return enc.crtc_id;
}

static uint32_t get_encoder_possible_crtcs(uint32_t enc_id) {
 struct drm_mode_get_encoder enc;
 memset(&enc, 0, sizeof(enc));
 enc.encoder_id = enc_id;
 if (drm_ioctl(drm_fd, DRM_IOCTL_MODE_GETENCODER, &enc) < 0)
  return 0;
 return enc.possible_crtcs;
}

/* ---- Buffer management ---- */

struct drm_buf {
 uint32_t width, height, stride, size;
 uint32_t handle, fb_id;
 void *map;
};

static void destroy_buf(struct drm_buf *b) {
 if (b->map) {
  munmap(b->map, b->size);
  b->map = NULL;
 }
 if (b->fb_id) {
  drm_ioctl(drm_fd, DRM_IOCTL_MODE_RMFB, &b->fb_id);
  b->fb_id = 0;
 }
 if (b->handle) {
  struct drm_mode_destroy_dumb dreq;
  memset(&dreq, 0, sizeof(dreq));
  dreq.handle = b->handle;
  drm_ioctl(drm_fd, DRM_IOCTL_MODE_DESTROY_DUMB, &dreq);
  b->handle = 0;
 }
}

static int create_buf(struct drm_buf *b, uint32_t w, uint32_t h) {
 struct drm_mode_create_dumb creq;
 struct drm_mode_map_dumb mreq;
 struct drm_mode_fb_cmd fb;

 memset(b, 0, sizeof(*b));
 b->width = w;
 b->height = h;

 /* Create dumb buffer */
 memset(&creq, 0, sizeof(creq));
 creq.width = w;
 creq.height = h;
 creq.bpp = 32;
 if (drm_ioctl(drm_fd, DRM_IOCTL_MODE_CREATE_DUMB, &creq) < 0) {
  fprintf(stderr, "drm_player: CREATE_DUMB failed: %s\n", strerror(errno));
  return -1;
 }
 b->handle = creq.handle;
 b->stride = creq.pitch;
 b->size = creq.size;

 /* Create FB */
 memset(&fb, 0, sizeof(fb));
 fb.width = w;
 fb.height = h;
 fb.depth = 24;
 fb.bpp = 32;
 fb.pitch = b->stride;
 fb.handle = b->handle;
 if (drm_ioctl(drm_fd, DRM_IOCTL_MODE_ADDFB, &fb) < 0) {
  fprintf(stderr, "drm_player: ADDFB failed: %s\n", strerror(errno));
  return -1;
 }
 b->fb_id = fb.fb_id;

 /* Map */
 memset(&mreq, 0, sizeof(mreq));
 mreq.handle = b->handle;
 if (drm_ioctl(drm_fd, DRM_IOCTL_MODE_MAP_DUMB, &mreq) < 0) {
  fprintf(stderr, "drm_player: MAP_DUMB failed: %s\n", strerror(errno));
  return -1;
 }
 b->map = mmap(NULL, b->size, PROT_READ | PROT_WRITE, MAP_SHARED,
        drm_fd, mreq.offset);
 if (b->map == MAP_FAILED) {
  b->map = NULL;
  fprintf(stderr, "drm_player: mmap failed: %s\n", strerror(errno));
  return -1;
 }
 memset(b->map, 0, b->size);
 return 0;
}

/* ---- Main ---- */

static struct drm_buf bufs[2];
static int cur_buf = 0;
static struct drm_mode_crtc saved_crtc;
static int have_saved_crtc = 0;
static uint32_t saved_conn_id = 0;

static void cleanup(void) {
 /* Restore saved CRTC */
 if (have_saved_crtc && drm_fd >= 0) {
  struct drm_mode_crtc c;
  memset(&c, 0, sizeof(c));
  c.crtc_id = saved_crtc.crtc_id;
  c.fb_id = saved_crtc.fb_id;
  c.x = saved_crtc.x;
  c.y = saved_crtc.y;
  c.mode = saved_crtc.mode;
  c.mode_valid = saved_crtc.mode_valid;
  c.set_connectors_ptr = (uint64_t)(uintptr_t)&saved_conn_id;
  c.count_connectors = saved_conn_id ? 1 : 0;
  drm_ioctl(drm_fd, DRM_IOCTL_MODE_SETCRTC, &c);
 }
 destroy_buf(&bufs[0]);
 destroy_buf(&bufs[1]);
 if (drm_fd >= 0) {
  drm_ioctl(drm_fd, DRM_IOCTL_DROP_MASTER, NULL);
  close(drm_fd);
  drm_fd = -1;
 }
}

int main(int argc, char *argv[]) {
 int width = 1920, height = 1080;
 uint32_t want_conn_id = 0;
 struct my_resources res;
 struct my_connector conn;
 int found_conn = 0;
 struct drm_mode_modeinfo *mode = NULL;
 size_t frame_line, buf_line, frame_size;
 unsigned char *frame_buf = NULL;
 ssize_t nread;
 size_t total;
 int i;
 uint32_t crtc_id = 0;

 if (argc >= 3) {
  width = atoi(argv[1]);
  height = atoi(argv[2]);
 }
 if (argc >= 4) {
  want_conn_id = (uint32_t)atoi(argv[3]);
 }

 atexit(cleanup);

 /* Open DRM */
 drm_fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
 if (drm_fd < 0) {
  fprintf(stderr, "drm_player: cannot open /dev/dri/card0: %s\n", strerror(errno));
  return 1;
 }

 if (drm_ioctl(drm_fd, DRM_IOCTL_SET_MASTER, NULL) < 0) {
  fprintf(stderr, "drm_player: cannot become DRM master: %s\n"
      "  (is PGeneratord still running?)\n", strerror(errno));
  return 1;
 }

 if (get_resources(&res) < 0) {
  fprintf(stderr, "drm_player: get_resources failed\n");
  return 1;
 }

 /* Find connector */
 for (i = 0; i < (int)res.count_connectors; i++) {
  if (get_connector(res.connector_ids[i], &conn) < 0) continue;

  if (want_conn_id && conn.connector_id == want_conn_id) { found_conn = 1; break; }
  if (!want_conn_id) {
   if (conn.connection == DRM_MODE_CONNECTED) { found_conn = 1; break; }
   if (conn.connector_type == DRM_MODE_CONNECTOR_HDMIA ||
     conn.connector_type == DRM_MODE_CONNECTOR_HDMIB) { found_conn = 1; break; }
  }
  free(conn.modes); free(conn.encoders);
 }

 if (!found_conn) {
  fprintf(stderr, "drm_player: no suitable connector found\n");
  return 1;
 }

 fprintf(stderr, "drm_player: connector %u type=%u %s, %d modes\n",
     conn.connector_id, conn.connector_type,
     conn.connection == DRM_MODE_CONNECTED ? "connected" : "disconnected",
     conn.count_modes);

 /* Find matching mode */
 for (i = 0; i < conn.count_modes; i++) {
  if ((int)conn.modes[i].hdisplay == width &&
    (int)conn.modes[i].vdisplay == height) {
   mode = &conn.modes[i];
   break;
  }
 }

 /* Fallback: first mode */
 if (!mode && conn.count_modes > 0) {
  mode = &conn.modes[0];
  width = mode->hdisplay;
  height = mode->vdisplay;
  fprintf(stderr, "drm_player: no %dx%d mode, using %dx%d\n",
      width, height, mode->hdisplay, mode->vdisplay);
 }

 /* Synthetic mode for disconnected connector with no modes */
 static struct drm_mode_modeinfo synth;
 if (!mode) {
  memset(&synth, 0, sizeof(synth));
  synth.hdisplay = width;
  synth.vdisplay = height;
  if (width == 3840 && height == 2160) {
   /* 4K@30 mode timings */
   synth.clock = 297000;
   synth.hsync_start = 3840 + 176;
   synth.hsync_end = 3840 + 176 + 88;
   synth.htotal = 3840 + 176 + 88 + 296;
   synth.vsync_start = 2160 + 8;
   synth.vsync_end = 2160 + 8 + 10;
   synth.vtotal = 2160 + 8 + 10 + 72;
   synth.vrefresh = 30;
  } else {
   /* 1080p@60 timings */
   synth.clock = 148500;
   synth.hsync_start = width + 88;
   synth.hsync_end = width + 88 + 44;
   synth.htotal = width + 88 + 44 + 148;
   synth.vsync_start = height + 4;
   synth.vsync_end = height + 4 + 5;
   synth.vtotal = height + 4 + 5 + 36;
   synth.vrefresh = 60;
  }
  synth.type = DRM_MODE_TYPE_DRIVER;
  snprintf(synth.name, sizeof(synth.name), "%dx%d", width, height);
  mode = &synth;
  fprintf(stderr, "drm_player: using synthetic mode %s@%dHz\n",
      synth.name, synth.vrefresh);
 }

 /* Find CRTC */
 if (conn.encoder_id) {
  crtc_id = get_encoder_crtc(conn.encoder_id);
 }
 if (!crtc_id) {
  for (i = 0; i < conn.count_encoders; i++) {
   uint32_t possible = get_encoder_possible_crtcs(conn.encoders[i]);
   int j;
   for (j = 0; j < (int)res.count_crtcs; j++) {
    if (possible & (1u << j)) {
     crtc_id = res.crtc_ids[j];
     break;
    }
   }
   if (crtc_id) break;
  }
 }
 if (!crtc_id && res.count_crtcs > 0) {
  crtc_id = res.crtc_ids[0];
 }
 if (!crtc_id) {
  fprintf(stderr, "drm_player: no CRTC available\n");
  return 1;
 }

 /* Save current CRTC */
 memset(&saved_crtc, 0, sizeof(saved_crtc));
 saved_crtc.crtc_id = crtc_id;
 if (drm_ioctl(drm_fd, DRM_IOCTL_MODE_GETCRTC, &saved_crtc) == 0) {
  have_saved_crtc = 1;
  saved_conn_id = conn.connector_id;
 }

 fprintf(stderr, "drm_player: mode %s %dx%d@%dHz, crtc %u\n",
     mode->name, mode->hdisplay, mode->vdisplay,
     mode->vrefresh, crtc_id);

 /* Create double buffers */
 if (create_buf(&bufs[0], mode->hdisplay, mode->vdisplay) < 0 ||
   create_buf(&bufs[1], mode->hdisplay, mode->vdisplay) < 0) {
  fprintf(stderr, "drm_player: buffer creation failed\n");
  return 1;
 }

 /* Set CRTC */
 {
  struct drm_mode_crtc c;
  memset(&c, 0, sizeof(c));
  c.crtc_id = crtc_id;
  c.fb_id = bufs[0].fb_id;
  c.x = 0;
  c.y = 0;
  c.set_connectors_ptr = (uint64_t)(uintptr_t)&conn.connector_id;
  c.count_connectors = 1;
  c.mode = *mode;
  c.mode_valid = 1;
  if (drm_ioctl(drm_fd, DRM_IOCTL_MODE_SETCRTC, &c) < 0) {
   fprintf(stderr, "drm_player: SETCRTC failed: %s\n", strerror(errno));
   return 1;
  }
 }

 frame_line = (size_t)width * 4;
 buf_line = bufs[0].stride;
 frame_size = (size_t)width * height * 4;
 frame_buf = malloc(frame_size);
 if (!frame_buf) {
  fprintf(stderr, "drm_player: malloc failed\n");
  return 1;
 }

 fprintf(stderr, "drm_player: playing %dx%d XRGB8888 (stride=%u, frame=%zu)\n",
     width, height, bufs[0].stride, frame_size);

 while (1) {
  struct drm_buf *buf = &bufs[cur_buf];
  struct drm_mode_crtc c;

  /* Read one full frame */
  total = 0;
  while (total < frame_size) {
   nread = read(0, frame_buf + total, frame_size - total);
   if (nread <= 0) {
    if (nread == 0) goto done;
    continue;
   }
   total += (size_t)nread;
  }

  /* Copy to DRM buffer */
  if (frame_line == buf_line) {
   memcpy(buf->map, frame_buf, frame_size);
  } else {
   int y, ch = height < (int)buf->height ? height : (int)buf->height;
   size_t cw = frame_line < buf_line ? frame_line : buf_line;
   for (y = 0; y < ch; y++) {
    memcpy((unsigned char *)buf->map + (size_t)y * buf_line,
        frame_buf + (size_t)y * frame_line, cw);
   }
  }

  /* Flip */
  memset(&c, 0, sizeof(c));
  c.crtc_id = crtc_id;
  c.fb_id = buf->fb_id;
  c.set_connectors_ptr = (uint64_t)(uintptr_t)&conn.connector_id;
  c.count_connectors = 1;
  c.mode = *mode;
  c.mode_valid = 1;
  drm_ioctl(drm_fd, DRM_IOCTL_MODE_SETCRTC, &c);

  cur_buf ^= 1;
 }

done:
 free(frame_buf);
 free(conn.modes); free(conn.encoders);
 free(res.crtc_ids); free(res.connector_ids);
 fprintf(stderr, "drm_player: done\n");
 return 0;
}
