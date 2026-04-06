/*
 * Copyright (c) 2017-2021 Biasiotto Riccardo
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

#pragma once
#include <boost/algorithm/string.hpp>
#include <boost/lexical_cast.hpp>
#include <boost/date_time/posix_time/posix_time.hpp>

/* Start Include RPI p4 header file */
#include "ofxRPI4Window.h"
#define GL_RGB10 0x8052
#define GL_RGB10_A2 0x8059
#define GL_RGBA16F  0x881A
#define GL_RGBA8    0x8058
/* End Include RPI p4 header file */

#include "ofMain.h"

class ofApp : public ofBaseApp{
 public:
  char path[100]="/var/lib/PGenerator/operations.txt";
  char DOLOG[100]="/var/log/PGenerator/DOLOG";
  char save_frame_file[100]="/var/lib/PGenerator/save";
  char pid_file[100]="/var/run/PGenerator/PGeneratord.pid";
  char tmp_dir[100]="/var/lib/PGenerator/";
  char text_font[100]="/var/lib/PGenerator/fonts/PGenerator.ttf";
  ofTrueTypeFont myfont;
  ofImage img;
  /* Start Patch For RPI 4 */
  ofFloatImage float_img;
  ofShortImage short_img;
  ofFbo fbo8;
  ofFbo fbo10;
  ofFbo fbo_dovi;
  int arr_bits[2048][2048];
  int bits;
  std::string previous_draw_type;
  std::string previous_image; 
  /* End Patch For RPI 4 */

  string image_save;
  string movie_name;
  int sleep_time;
  int first_done=0;
  std::string draw_type;
  std::string p_name;
  std::string name;
  std::string m_name;
  std::string text_to_write;
  std::string arr_text[2048][2048];
  std::string img_file;
  int save_images=0;
  int position_x;
  int img_rotate=0;
  int entered;
  int open_file=1;
  int i;
  int def_r=0;
  int def_g=0;
  int def_b=0;
  int n_frame;
  unsigned long long last_frame_time;
  int to_draw;
  int position_y;
  int arr_resolution[2048][2048];
  std::string arr_image[2048][2048];
  int arr_rotate[2048][2048];
  int arr_draw[2048][2048];
  std::string arr_name[2048];
  int arr_red[2048][2048];
  int arr_green[2048][2048];
  int arr_blue[2048][2048];
  int arr_redbg[2048][2048];
  int arr_greenbg[2048][2048];
  int arr_bluebg[2048][2048];
  int arr_dim1[2048][2048];
  int arr_dim2[2048][2048];
  int arr_posx[2048][2048];
  int arr_posy[2048][2048];
  unsigned long long arr_frame_time[2048];
  unsigned long long arr_frame_duration[2048];
  int dim1;
  int dim2;
  int width;
  int height;
  int resolution;
  int red;
  int green;
  int blue;
  int redb;
  int greenb;
  int blueb;
  int duration;
  int frame;
  int n_draw[2048];
  int frame_to_draw;
  ofVideoPlayer myPlayer;
  void setup();
  void update();
  void draw();
  void rectangle();
  void circle();
  void triangle();
  void text();
  void image();
  void set_values();
  void log(std::string);
  /* Start Patch For RPI 4 */
  void setColor(int red, int green, int blue);
  void setBackground(int redbg, int greenbg, int bluebg);
  void setDoViBackground(int redbg, int greenbg, int bluebg);
  void shader_begin(int is_image);
  void shader_end(int is_image);
  void YCbCr2RGB();
  static int dv_map_mode;
  static int dv_minpq;
  static int dv_maxpq;
  static int dv_diagonal;
  static int dv_color_space;
  int dv_meta_update=0;
  void dovi_rpu_inject();
  void dovi_metadata_mux();
  void dovi_metadata_create();
//  void dovi_metadata_inject(int bit_depth);
  struct dv_metadata {
//		unsigned char dv_meta8_2[128];
	//base profile 8.2 dv metadata
	unsigned char dv_meta8_2[128] = {0x00, 0x00, 0x00, 0x00, 0x5d, 0x00, 0x00, 0x25, 0x66, 0x00, 0x00, 0x39, 0x93, 0x25, 0x66, 0xf9,
									0x27, 0xee, 0xe2, 0x25, 0x66, 0x43, 0xd9, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00,
									0x00, 0x08, 0x00, 0x00, 0x00, 0x16, 0xd5, 0x25, 0xe6, 0x03, 0x45, 0x0a, 0x08, 0x2f, 0xe0, 0x06,
									0x19, 0x00, 0x00, 0x02,	0xa7, 0x3d, 0x59, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
									0x00, 0x0c, 0x01, 0x01, 0x01, 0x00, 0x3e, 0x0e, 0x70, 0x00, 0x2a, 0x02, 0x00, 0x00, 0x00, 0x06, 
									0x01, 0x00, 0x3e, 0x0e, 0x70, 0x07, 0x57, 0x00,	0x00, 0x00, 0x06, 0xff, 0x02, 0x00, 0x00, 0x00,
									0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,	0x00, 0x00, 0x00, 0x00,
									0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,	0xf3, 0xc2, 0xac, 0x67};
	//base profile 8.1 dv metadata								
	unsigned char dv_meta8_1[128] = {0x00, 0x00, 0x00, 0x00, 0x5d, 0x00, 0x00, 0x25, 0x66, 0x00, 0x00, 0x35, 0xea, 0x25, 0x66, 0xf9,
									0xfc, 0xeb, 0x1c, 0x25, 0x66, 0x44, 0xca, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00,
									0x00, 0x08, 0x00, 0x00, 0x00, 0x1c, 0x36, 0x22, 0x43, 0x01, 0x86, 0x0a, 0x5e, 0x30, 0x8e, 0x05,
									0x14, 0x00, 0x00, 0x01, 0xa6, 0x3e, 0x5a, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
									0x00, 0x0c, 0x01, 0x01, 0x01, 0x00, 0x3e, 0x0e, 0x70, 0x00, 0x2a, 0x02, 0x00, 0x00, 0x00, 0x06,
									0x01, 0x00, 0x02, 0x0d, 0x37, 0x03, 0x33, 0x00, 0x00, 0x00, 0x06, 0xff, 0x02, 0x00, 0x00, 0x00,
									0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
									0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x98, 0xbf, 0x4c, 0xad};

	int dv_profile=0;
	int dv_map_mode=2;
	int dv_minpq=62;
	int dv_maxpq=3696;
	int dv_diagonal=42;
	int dv_color_space=1;
  };
  struct dv_metadata dv_metadata;
  unsigned char dv_metadata_active[128];
  void dovi_metadata_update();

  unsigned int crc32mpeg(unsigned char *message, size_t l);
  void dovi_dump();
  void fbo_allocate();
  int loop_count=0;
  /* End Patch For RPI 4 */
};
