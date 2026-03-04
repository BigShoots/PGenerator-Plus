/*
 * fb_player.c — Minimal framebuffer video player for PGenerator
 *
 * Reads raw BGRA frames from stdin (piped from ffmpeg) and displays
 * them on /dev/fb0. Attempts to configure fb0 for 32-bit BGRA,
 * falls back to current mode. Restores original mode on exit.
 *
 * Usage:
 *   ffmpeg -re -stream_loop -1 -i video.mp4 \
 *     -vf "scale=1920:1080" -pix_fmt bgra -f rawvideo pipe:1 \
 *     | fb_player [width height]
 *
 * Compile:
 *   gcc -O2 -o fb_player fb_player.c
 *
 * Note: Uses inline struct definitions to avoid dependency on
 *       linux/fb.h (kernel headers not installed on BiasiLinux).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

/* --- Inline framebuffer definitions (from linux/fb.h) --- */

struct fb_bitfield {
 unsigned int offset;
 unsigned int length;
 unsigned int msb_right;
};

struct fb_var_screeninfo {
 unsigned int xres;
 unsigned int yres;
 unsigned int xres_virtual;
 unsigned int yres_virtual;
 unsigned int xoffset;
 unsigned int yoffset;
 unsigned int bits_per_pixel;
 unsigned int grayscale;
 struct fb_bitfield red;
 struct fb_bitfield green;
 struct fb_bitfield blue;
 struct fb_bitfield transp;
 unsigned int nonstd;
 unsigned int activate;
 unsigned int height;
 unsigned int width;
 unsigned int accel_flags;
 unsigned int pixclock;
 unsigned int left_margin;
 unsigned int right_margin;
 unsigned int upper_margin;
 unsigned int lower_margin;
 unsigned int hsync_len;
 unsigned int vsync_len;
 unsigned int sync;
 unsigned int vmode;
 unsigned int rotate;
 unsigned int colorspace;
 unsigned int reserved[4];
};

struct fb_fix_screeninfo {
 char id[16];
 unsigned long smem_start;
 unsigned int smem_len;
 unsigned int type;
 unsigned int type_aux;
 unsigned int visual;
 unsigned short xpanstep;
 unsigned short ypanstep;
 unsigned short ywrapstep;
 unsigned int line_length;
 unsigned long mmio_start;
 unsigned int mmio_len;
 unsigned int accel;
 unsigned short capabilities;
 unsigned short reserved[2];
};

#define FBIOGET_VSCREENINFO 0x4600
#define FBIOPUT_VSCREENINFO 0x4601
#define FBIOGET_FSCREENINFO 0x4602

/* --- End framebuffer definitions --- */

static int fb_fd = -1;
static void *fb_mem = (void *)-1;
static size_t fb_size = 0;
static struct fb_var_screeninfo orig_vinfo;
static int have_orig = 0;

static void cleanup(void) {
 if (have_orig && fb_fd >= 0) {
  ioctl(fb_fd, FBIOPUT_VSCREENINFO, &orig_vinfo);
 }
 if (fb_mem != (void *)-1) {
  munmap(fb_mem, fb_size);
 }
 if (fb_fd >= 0) {
  close(fb_fd);
 }
}

int main(int argc, char *argv[]) {
 struct fb_var_screeninfo vinfo;
 struct fb_fix_screeninfo finfo;
 int width = 1920, height = 1080;
 size_t frame_size, line_bytes, fb_line_bytes;
 unsigned char *frame_buf = NULL;
 ssize_t nread;
 size_t total;
 int y;

 if (argc >= 3) {
  width = atoi(argv[1]);
  height = atoi(argv[2]);
  if (width <= 0 || height <= 0) {
   fprintf(stderr, "fb_player: invalid dimensions %dx%d\n", width, height);
   return 1;
  }
 }

 atexit(cleanup);

 /* Open framebuffer */
 fb_fd = open("/dev/fb0", O_RDWR);
 if (fb_fd < 0) {
  fprintf(stderr, "fb_player: cannot open /dev/fb0\n");
  return 1;
 }

 /* Save original settings */
 if (ioctl(fb_fd, FBIOGET_VSCREENINFO, &orig_vinfo) == 0) {
  have_orig = 1;
 }

 /* Configure for 32-bit BGRA */
 memset(&vinfo, 0, sizeof(vinfo));
 if (ioctl(fb_fd, FBIOGET_VSCREENINFO, &vinfo) < 0) {
  fprintf(stderr, "fb_player: FBIOGET_VSCREENINFO failed\n");
  return 1;
 }

 vinfo.xres = width;
 vinfo.yres = height;
 vinfo.xres_virtual = width;
 vinfo.yres_virtual = height;
 vinfo.bits_per_pixel = 32;
 vinfo.red.offset = 16;  vinfo.red.length = 8;  vinfo.red.msb_right = 0;
 vinfo.green.offset = 8; vinfo.green.length = 8; vinfo.green.msb_right = 0;
 vinfo.blue.offset = 0;  vinfo.blue.length = 8;  vinfo.blue.msb_right = 0;
 vinfo.transp.offset = 24; vinfo.transp.length = 8; vinfo.transp.msb_right = 0;

 if (ioctl(fb_fd, FBIOPUT_VSCREENINFO, &vinfo) < 0) {
  fprintf(stderr, "fb_player: cannot set 32-bit mode, using current mode\n");
  if (ioctl(fb_fd, FBIOGET_VSCREENINFO, &vinfo) < 0) {
   fprintf(stderr, "fb_player: FBIOGET_VSCREENINFO fallback failed\n");
   return 1;
  }
 }

 /* Re-read to get actual values */
 ioctl(fb_fd, FBIOGET_VSCREENINFO, &vinfo);
 ioctl(fb_fd, FBIOGET_FSCREENINFO, &finfo);

 fprintf(stderr, "fb_player: fb0 %dx%d %dbpp stride=%d\n",
     vinfo.xres, vinfo.yres, vinfo.bits_per_pixel, finfo.line_length);

 /* mmap framebuffer */
 fb_size = (size_t)finfo.line_length * vinfo.yres;
 fb_mem = mmap(NULL, fb_size, PROT_READ | PROT_WRITE, MAP_SHARED, fb_fd, 0);
 if (fb_mem == (void *)-1) {
  fprintf(stderr, "fb_player: mmap failed\n");
  return 1;
 }

 /* Frame buffer for reading from stdin */
 frame_size = (size_t)width * height * (vinfo.bits_per_pixel / 8);
 frame_buf = malloc(frame_size);
 if (!frame_buf) {
  fprintf(stderr, "fb_player: malloc failed\n");
  return 1;
 }

 line_bytes = (size_t)width * (vinfo.bits_per_pixel / 8);
 fb_line_bytes = finfo.line_length;

 fprintf(stderr, "fb_player: reading %dx%d frames (%zu bytes each)\n",
     width, height, frame_size);

 while (1) {
  /* Read one full frame from stdin */
  total = 0;
  while (total < frame_size) {
   nread = read(0, frame_buf + total, frame_size - total);
   if (nread <= 0) {
    if (nread == 0) goto done;  /* EOF */
    continue;                    /* EINTR or other retry */
   }
   total += (size_t)nread;
  }

  /* Copy frame to framebuffer */
  if (line_bytes == fb_line_bytes && width == (int)vinfo.xres) {
   memcpy(fb_mem, frame_buf, frame_size < fb_size ? frame_size : fb_size);
  } else {
   size_t copy_w = line_bytes < fb_line_bytes ? line_bytes : fb_line_bytes;
   int copy_h = height < (int)vinfo.yres ? height : (int)vinfo.yres;
   for (y = 0; y < copy_h; y++) {
    memcpy((unsigned char *)fb_mem + (size_t)y * fb_line_bytes,
        frame_buf + (size_t)y * line_bytes, copy_w);
   }
  }
 }

done:
 free(frame_buf);
 fprintf(stderr, "fb_player: done\n");
 return 0;
}
