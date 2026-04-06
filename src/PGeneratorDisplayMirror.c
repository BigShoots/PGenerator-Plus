/*
 * Copyright (c) 2017-2018 Biasiotto Riccardo
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.

 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.

 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * See the File README and COPYING for more detail about License
 *
*/

/*
  ########################################
  #               Include                #
  ########################################
*/
#include <stdio.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <assert.h>
#include <sys/mman.h>
#include <bcm_host.h>
#include <signal.h>

/*
  ########################################
  #              Variables               #
  ########################################
*/
#define FB_SECONDARY "/dev/fb1"
#define DISPLAY_PRIMARY 0
#define SLEEP 25
#define IMAGE_TYPE_D VC_IMAGE_RGB565
#define IMAGE_TYPE_I VC_IMAGE_RGB888
#define FILE_IMAGE "/var/lib/PGenerator/running/screen.ppm"
#define FILE_PNG "/var/lib/PGenerator/running/screen"
#define FILE_IMAGE_TMP "/var/lib/PGenerator/running/screen.ppm.tmp"

/*
  ########################################
  #        Signal Handler Function       #
  ########################################
*/
void signal_handler(int sig) {
 printf("\nProgram Terminated\n\n");
 exit(0);
}

/*
  ########################################
  #                Copy FB               #
  ########################################
*/
int copy_fb() {
 /*
   Variables
 */
 void *image;
 DISPMANX_DISPLAY_HANDLE_T display;
 DISPMANX_MODEINFO_T display_info;
 DISPMANX_RESOURCE_HANDLE_T screen_resource_d,screen_resource_i;
 VC_IMAGE_TRANSFORM_T transform;
 uint32_t image_ptr_d,image_ptr_i;
 VC_RECT_T rect_d,rect_i;
 int ret,fbfd=0;
 char *fbp = 0;
 struct fb_var_screeninfo vinfo;
 struct fb_fix_screeninfo finfo;
 char command[100],src[100],dst[100];

 /*
   Init
 */
 printf("\nInit for Copy Snapshot Service\n");
 bcm_host_init();

 /*
   Primary Display 
 */
 display = vc_dispmanx_display_open(DISPLAY_PRIMARY);
 if (!display) {
  printf("Unable to open primary display");
  return -1;
 }
 ret = vc_dispmanx_display_get_info(display, &display_info);
 if (ret) {
  printf("Unable to get primary display information");
  return -1;
 }
 printf("Display\tPrimary: %d x %d\n", display_info.width, display_info.height);

 /*
   Secondary Display 
 */
 fbfd = open(FB_SECONDARY, O_RDWR);
 if (fbfd == -1) {
  printf("Unable to open secondary display\n");
  return -1;
 }
 if (ioctl(fbfd, FBIOGET_FSCREENINFO, &finfo)) {
  printf("Unable to get secondary display information (FSCREENINFO)\n");
  return -1;
 }
 if (ioctl(fbfd, FBIOGET_VSCREENINFO, &vinfo)) {
  printf("Unable to get secondary display information (VSCREENINFO)\n");
  return -1;
 }
 printf("Display\tSecondary: %d x %d %dbps\n", vinfo.xres, vinfo.yres, vinfo.bits_per_pixel);

 /* 
   Screen Buffer for Display
 */
 screen_resource_d = vc_dispmanx_resource_create(IMAGE_TYPE_D, vinfo.xres, vinfo.yres, &image_ptr_d);
 if (!screen_resource_d) {
  printf("Unable to create screen buffer for display\n");
  close(fbfd);
  vc_dispmanx_display_close(display);
  return -1;
 }

 /* 
   Screen Buffer for Image
 */
 screen_resource_i = vc_dispmanx_resource_create( IMAGE_TYPE_I,display_info.width,display_info.height,&image_ptr_i);
 if (!screen_resource_i) {
  printf("Unable to create screen buffer for image\n");
  vc_dispmanx_display_close(display);
  return -1;
 }

 /* 
   Memory Mapping Buffer
 */
 fbp = (char*) mmap(0, finfo.smem_len, PROT_READ | PROT_WRITE, MAP_SHARED, fbfd, 0);
 if (fbp <= 0) {
  printf("Unable to create memory mapping\n");
  close(fbfd);
  ret = vc_dispmanx_resource_delete(screen_resource_d);
  vc_dispmanx_display_close(display);
  return -1;
 }

 /*
   Preparing for Display Snapshot
 */
 printf("Copying snapshot to %s\n",FB_SECONDARY);
 vc_dispmanx_rect_set(&rect_d, 0, 0, vinfo.xres, vinfo.yres);

 /*
   Preparing for Image Snapshot
 */
 printf("Copying snapshot to %s\n",FILE_IMAGE);
 image = calloc( 1, display_info.width * 3 * display_info.height );
 assert(image);
 vc_dispmanx_rect_set(&rect_i, 0, 0, display_info.width, display_info.height);

 while (1) {
  /* Snapshot Display */
  ret = vc_dispmanx_snapshot(display, screen_resource_d, 0);
  vc_dispmanx_resource_read_data(screen_resource_d, &rect_d, fbp, vinfo.xres * vinfo.bits_per_pixel / 8);

  /* Snapshot Image */
  vc_dispmanx_snapshot(display, screen_resource_i, 0);
  vc_dispmanx_resource_read_data(screen_resource_i, &rect_i, image, display_info.width*3);
  FILE *fp = fopen(FILE_IMAGE_TMP, "wb");
  fprintf(fp, "P6\n%d %d\n255\n", display_info.width, display_info.height);
  fwrite(image, display_info.width*3*display_info.height, 1, fp);
  fclose(fp);
  rename(FILE_IMAGE_TMP,FILE_IMAGE);
  sprintf(command,"convert %s png:%s.png.tmp",FILE_IMAGE,FILE_PNG);
  system(command);
  unlink(FILE_IMAGE);
  sprintf(src,"%s.png.tmp",FILE_PNG);
  sprintf(dst,"%s.png",FILE_PNG);
  rename(src,dst);

  /* Sleep */
  usleep(SLEEP * 1000);
 }

 /*
   Clean
 */
 munmap(fbp, finfo.smem_len);
 close(fbfd);
 ret = vc_dispmanx_resource_delete(screen_resource_d);
 vc_dispmanx_display_close(display);
}

/*
  ########################################
  #                Main                  #
  ########################################
*/
int main(int argc, char **argv) {
 signal(SIGINT,signal_handler);
 return copy_fb();
}

