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

#include "ofApp.h"

/* Start Patch RPI P4 */
#include "rgb2ycbcr.h"
/* End Patch RPI P4 */

/*
 ##########################################################
 #                           Setup                        #
 ##########################################################
*/
void ofApp::setup(){
 ofSetBackgroundAuto(true); 
 /* Start Patch RPI P4 */
 setBackground(def_r,def_g,def_b);
 /* End Patch RPI P4 */
 ofHideCursor();

 /* Pid Creation */
 std::ofstream pidfile (pid_file);
 pidfile << getpid();
 pidfile.close();
}

/*
 ##########################################################
 #                           Update                       #
 ##########################################################
*/
void ofApp::update(){
 std::vector<std::string> dimensions;
 std::vector<std::string> rgb;
 std::vector<std::string> rgbb;
 std::vector<std::string> positions;
 std::string str; 

 if(open_file) {
  frame=frame_to_draw=entered=0;
  p_name=m_name="";
  n_draw[frame]=0;
  ofApp::log("\n\n");   
  ofApp::log("***********************************");
  ofApp::log("*             Open File           *");
  ofApp::log("***********************************");
  std::ifstream file(path);
  while (std::getline(file, str)) {
   entered=1;
   open_file=0;
   last_frame_time=0;
   std::vector<std::string> el;
   boost::split(el, str, boost::is_any_of("="));
   if(el[0] == "DRAW") {
    draw_type=el[1];
   }
   if(el[0] == "TEXT")
    text_to_write=el[1];
   if(el[0] == "PATTERN_NAME")
    p_name=el[1];
   if(el[0] == "MOVIE_NAME")
    m_name=el[1];
   if(el[0] == "IMAGE") {
    img_file=el[1]; 
   }
   if(el[0] == "ROTATE")
    img_rotate=boost::lexical_cast<int>(el[1]);
   if(el[0] == "DIM") {
    boost::split(dimensions, el[1], boost::is_any_of(","));
    dim1=boost::lexical_cast<int>(dimensions[0]);
    dim2=boost::lexical_cast<int>(dimensions[1]);
   }
   if(el[0] == "RESOLUTION")
    resolution=boost::lexical_cast<int>(el[1]);
   if(el[0] == "RGB") {
    boost::split(rgb, el[1], boost::is_any_of(","));
    red=boost::lexical_cast<int>(rgb[0]);
    green=boost::lexical_cast<int>(rgb[1]);
    blue=boost::lexical_cast<int>(rgb[2]);
   }
   /* Start Patch RPI P4 */
   if(el[0] == "BITS") {
    bits=boost::lexical_cast<int>(el[1]);
    ofxRPI4Window::bit_depth = bits;
    ofxRPI4Window::avi_info.max_bpc = bits;
 //   ofxRPI4Window::colorspace_on=1;
   }
   /* End Patch RPI P4 */
   if(el[0] == "POSITION") {
    boost::split(positions, el[1], boost::is_any_of(","));
    position_x=boost::lexical_cast<int>(positions[0]);
    position_y=boost::lexical_cast<int>(positions[1]);
   }
   if(el[0] == "BG") {
    boost::split(rgbb, el[1], boost::is_any_of(","));
    redb=boost::lexical_cast<int>(rgbb[0]);
    greenb=boost::lexical_cast<int>(rgbb[1]);
    blueb=boost::lexical_cast<int>(rgbb[2]);
   }
   if(el[0] == "FRAME_NAME") {
    name=el[1];
    arr_name[frame]=name;
   }
   if(el[0] == "FRAME") {
    arr_frame_time[frame]=boost::lexical_cast<int>(el[1])*1000;
    frame++;
    n_draw[frame]=0;
   }
   if(el[0] == "FRAME_DURATION")
    arr_frame_duration[frame]=boost::lexical_cast<int>(el[1])*1000;
   if(el[0] == "END") {
    ofApp::set_values();
    n_draw[frame]++;
    dim1=dim2=0;
   }
  }

 }
  /* Start Patch RPI P4 */
  if (draw_type == "IMAGE") {
   ofxRPI4Window::colorspace_on = 0;
  }else {
   ofxRPI4Window::colorspace_on = 1;
   loop_count=0; //reset counter
   previous_image = ""; 
  }
#if 1 
  if (ofxRPI4Window::shader_init && ofxRPI4Window::avi_info.output_format != 0) {
 //  ofxRPI4Window::rgb2ycbcr_shader();
   ofxRPI4Window::shader_init=0;
  }
  if (ofxRPI4Window::shader_init && ofxRPI4Window::is_std_DoVi) {

//  if (ofxRPI4Window::colorspace_on) ofxRPI4Window::dovi_pattern_shader();
 // else							     ofxRPI4Window::dovi_image_shader();
   ofApp::fbo_allocate(); //allocate framebuffer for DoVi background and patch
   ofApp::dovi_metadata_create(); // create dovi metadata fbo 
   ofxRPI4Window::shader_init=0; 
  }
#endif  
  previous_draw_type = draw_type;
  /* End Patch RPI P4 */
 image_save=tmp_dir+ofToString("running/")+ofToString(p_name)+".save";
 const char * save = image_save.c_str();
 ifstream s(save);
 if (s.good()) {
  save_images=1;
  s.close();
 }
}

/*
 ##########################################################
 #                           Draw                         #
 ##########################################################
*/
void ofApp::draw(){
 if(entered == 0)
  return;
 for(to_draw=0;to_draw<n_draw[i];to_draw++) {
  string return_file=tmp_dir+ofToString("/running/return");
  const char * return_file_char = return_file.c_str();
  ifstream r(return_file_char);
  if (r.good()) {
   r.close();
   i=0;
   open_file=1;
   save_images=0;
   unlink(return_file_char);
   return;
  }
  char buffer[255];
  sprintf(buffer,"Doing the frame %d and the Draw %d",i,to_draw);
  ofApp::log(buffer);
  sprintf(buffer,"RGB: %d %d %d",arr_red[i][to_draw],arr_green[i][to_draw],arr_blue[i][to_draw]);
  ofApp::log(buffer);
  sprintf(buffer,"Background: %d %d %d",arr_redbg[i][to_draw],arr_greenbg[i][to_draw],arr_bluebg[i][to_draw]);
  ofApp::log(buffer);
  sprintf(buffer,"DrawType: %d",arr_draw[i][to_draw]);
  ofApp::log(buffer);
  if(arr_draw[i][to_draw] == 4) {
   sprintf(buffer,"DrawImage: %s",arr_text[i][to_draw].c_str());
   ofApp::log(buffer);
  }
  if(arr_draw[i][to_draw] == 5) {
   sprintf(buffer,"DrawImage: %s",arr_image[i][to_draw].c_str());
   ofApp::log(buffer);
  }
  sprintf(buffer,"Dim: %d %d",arr_dim1[i][to_draw],arr_dim2[i][to_draw]);
  ofApp::log(buffer);
  sprintf(buffer,"Resolution: %d",arr_resolution[i][to_draw]);
  ofApp::log(buffer);
  sprintf(buffer,"Position: %d %d",arr_posx[i][to_draw],arr_posy[i][to_draw]);
  ofApp::log(buffer);

  sprintf(buffer,"Bits: %d",arr_bits[i][to_draw]);
  ofApp::log(buffer);

  if(arr_draw[i][to_draw] == 0) 
   ::exit(0);
 /* Start Patch RPI P4 */
 //  ofApp::fbo_allocate(); //allocate framebuffer for DoVi background and patch


  
  ofApp::setBackground(arr_redbg[i][to_draw], arr_greenbg[i][to_draw], arr_bluebg[i][to_draw]);

  ofApp::setColor(arr_red[i][to_draw],arr_green[i][to_draw],arr_blue[i][to_draw]); 

  if(arr_draw[i][to_draw] !=  5) ofApp::shader_begin(0); //set for draw = 0
 /* End Patch RPI P4 */
  if(arr_draw[i][to_draw] ==  1)
   ofApp::rectangle();
  if(arr_draw[i][to_draw] ==  2)
   ofApp::circle();
  if(arr_draw[i][to_draw] ==  3)
   ofApp::triangle();
  if(arr_draw[i][to_draw] ==  4)
   ofApp::text();
  /* Start Patch RPI P4 */
  if(arr_draw[i][to_draw] != 5) ofApp::shader_end(0); //set for draw = 0
   if (arr_draw[i][to_draw] !=  5 && ofxRPI4Window::is_std_DoVi && !ofxRPI4Window::shader_init) ofApp::dovi_metadata_mux(); //draw dovi metadata muxed patch only if shader already initialized
  /* End Patch RPI P4 */
  if(arr_draw[i][to_draw] ==  5)
   ofApp::image();
  /* Start Patch RPI P4 */
  if (arr_draw[i][to_draw] ==  5 && ofxRPI4Window::is_std_DoVi && !ofxRPI4Window::shader_init) ofApp::dovi_metadata_mux(); //draw dovi metadata muxed with patch only if shader already initialized
   /* End Patch RPI P4 */
  if(last_frame_time == 0)
   last_frame_time=ofGetSystemTimeMicros();
 }
 if(save_images && i!=0 && !first_done)
  save_images=0;
 if (save_images) {
  first_done=1;
  //int n_frame=ofGetFrameNum();
  n_frame++;
  if(n_frame != 0 && n_frame > 3) {
   string movie_time=ofToString(arr_frame_time[i]);
   if(arr_frame_duration[i])
    movie_time=ofToString(arr_frame_duration[i]);
   movie_name=p_name;
   if(!m_name.empty())
    movie_name=m_name;
   //string image_name=tmp_dir+ofToString("/frames/Img_")+ofToString(movie_name)+",,,,"+ofToString(i)+"-"+arr_name[i]+",,,,"+movie_time+".png";
   string image_name_tmp=tmp_dir+ofToString("/tmp/")+ofToString(i+1)+"-"+arr_name[i]+",,,,"+movie_time+".png";
   string image_name=tmp_dir+ofToString("/frames/")+ofToString(i+1)+"-"+arr_name[i]+",,,,"+movie_time+".png";
   const char * c = image_name.c_str();
   ifstream p(c);
   if(!p.good()) {
    img.grabScreen(0,0,ofGetWindowWidth(),ofGetWindowHeight());
	ofApp::YCbCr2RGB();
//	dovi_rpu_inject();
//ofApp::dovi_dump();
//	ofApp::dovi_metadata_inject(ofxRPI4Window::bit_depth);
	if( img.isAllocated() ){
 
	  img.draw(arr_posx[i][to_draw],arr_posy[i][to_draw],arr_dim1[i][to_draw],arr_dim2[i][to_draw]);
	}
	img.save(image_name_tmp);
    rename(image_name_tmp.c_str(),image_name.c_str());
   } else
    p.close();
  }
 }
 if(arr_frame_time[i] != 0) {
  unsigned long long diff=ofGetSystemTimeMicros()-last_frame_time;
  if(diff > arr_frame_time[i]) {
   i++;
   last_frame_time=0;
   n_frame=0;
  }
 }


 if(i< frame)
  ofApp::log("\n");
 if(i == frame) {
  i=0;
  open_file=1;
  save_images=0;
  if(first_done) {
   unlink(image_save.c_str());
   //string image_done=tmp_dir+ofToString("/frames/Img_")+ofToString(movie_name)+",,,,.done";
   string image_done=tmp_dir+ofToString("/frames/done");
   const char * save_done = image_done.c_str();
   std::ofstream outfile (save_done);
   outfile << movie_name << std::endl;
   outfile.close();
   first_done=0;
  }
 }

}


/*
 ##########################################################
 #                        Set Values                      #
 ##########################################################
*/
void ofApp::set_values () {
 int draw_num=0;
 if(draw_type == "RECTANGLE") draw_num=1;
 if(draw_type == "CIRCLE")    draw_num=2;
 if(draw_type == "TRIANGLE")  draw_num=3;
 if(draw_type == "TEXT")      draw_num=4;
 if(draw_type == "IMAGE")     draw_num=5;
 arr_text[frame][n_draw[frame]]=text_to_write;
 arr_red[frame][n_draw[frame]]=red;
 arr_green[frame][n_draw[frame]]=green;
 arr_blue[frame][n_draw[frame]]=blue;
 arr_redbg[frame][n_draw[frame]]=redb;
 arr_greenbg[frame][n_draw[frame]]=greenb;
 arr_bluebg[frame][n_draw[frame]]=blueb;
 arr_draw[frame][n_draw[frame]]=draw_num;
 arr_dim1[frame][n_draw[frame]]=dim1;
 arr_dim2[frame][n_draw[frame]]=dim2;
 arr_posx[frame][n_draw[frame]]=position_x;
 arr_posy[frame][n_draw[frame]]=position_y;
 arr_resolution[frame][n_draw[frame]]=resolution;
 arr_image[frame][n_draw[frame]]=img_file;
 arr_rotate[frame][n_draw[frame]]=img_rotate;
 /* Start Patch RPI P4 */
 arr_bits[frame][n_draw[frame]]=bits;
 ofxRPI4Window::bit_depth=bits;
 ofxRPI4Window::avi_info.max_bpc = bits;
 /* End Patch RPI P4 */
}

/*
 ##########################################################
 #                       Rectangle                        #
 ##########################################################
*/
void ofApp::rectangle () {
 if(arr_posx[i][to_draw] == -1) {
  arr_posx[i][to_draw]=(ofGetWindowWidth()-arr_dim1[i][to_draw])/2;
  arr_posy[i][to_draw]=(ofGetWindowHeight()-arr_dim2[i][to_draw])/2;
 }
 ofDrawRectangle(arr_posx[i][to_draw],arr_posy[i][to_draw],arr_dim1[i][to_draw],arr_dim2[i][to_draw]);
}
 
/*
 ##########################################################
 #                       Circle                           #
 ##########################################################
*/
void ofApp::circle() {
 ofSetCircleResolution(arr_resolution[i][to_draw]);
 if(arr_posx[i][to_draw] == -1) {
  arr_posx[i][to_draw]=ofGetWindowWidth()/2;
  arr_posy[i][to_draw]=ofGetWindowHeight()/2;
 }
 ofDrawCircle(arr_posx[i][to_draw],arr_posy[i][to_draw],arr_dim1[i][to_draw]);
}

/*
 ##########################################################
 #                       Triangle                         #
 ##########################################################
*/
void ofApp::triangle() {
 if(arr_posx[i][to_draw] == -1) {
  arr_posx[i][to_draw]=ofGetWindowWidth()/2;
  arr_posy[i][to_draw]=ofGetWindowHeight()/2;
 }
 ofDrawTriangle(arr_posx[i][to_draw],arr_posy[i][to_draw]-arr_dim1[i][to_draw],arr_posx[i][to_draw]-arr_dim1[i][to_draw],arr_posy[i][to_draw]+arr_dim1[i][to_draw],arr_posx[i][to_draw]+arr_dim1[i][to_draw],arr_posy[i][to_draw]+arr_dim1[i][to_draw]);
}

/*
 ##########################################################
 #                         Text                           #
 ##########################################################
*/
void ofApp::text() {
 myfont.load(text_font,arr_dim1[i][to_draw]);
 int width=myfont.stringWidth(arr_text[i][to_draw]);
 //int height=myfont.stringHeight(arr_text[i][to_draw]);
 if(arr_posx[i][to_draw] == -1) {
  arr_posx[i][to_draw]=(ofGetWindowWidth()-width)/2;
  arr_posy[i][to_draw]=ofGetWindowHeight()/2;
 }
 myfont.drawString(arr_text[i][to_draw],arr_posx[i][to_draw],arr_posy[i][to_draw]);
}

/*
 ##########################################################
 #                         Image                          #
 ##########################################################
*/
void ofApp::image() {
 if(arr_posx[i][to_draw] == -1) {
  arr_posx[i][to_draw]=(ofGetWindowWidth()-arr_dim1[i][to_draw])/2;
  arr_posy[i][to_draw]=(ofGetWindowHeight()-arr_dim2[i][to_draw])/2;
 }
 /* Start Patch RPI P4 */
 if (ofxRPI4Window::avi_info.max_bpc == 10 && ofxRPI4Window::isHDR) {
  if (previous_image != arr_image[i][to_draw] || loop_count < 2) { //needs to load each new image twice to allow time to load shader
  float_img.clear();
  float_img.load(arr_image[i][to_draw]);
  float_img.rotate90(arr_rotate[i][to_draw]);

  float_img.getTexture().setTextureMinMagFilter(GL_NEAREST, GL_NEAREST); //set pixel precision
  loop_count++;
  }
  ofSet10bitColor(1023,1023,1023,1023);
//  float_img.update();  //update here no necessary,  occurs in both load and rotate90 routines 
  ofApp::shader_begin(1); //set for image = 1
  float_img.draw(arr_posx[i][to_draw],arr_posy[i][to_draw],arr_dim1[i][to_draw],arr_dim2[i][to_draw]);
  ofApp::shader_end(1); //set for image = 1
 /* End Patch RPI P4 */
 } else {
  if (previous_image != arr_image[i][to_draw] || loop_count < 2) { //needs to load each new image twice to allow time to load shader
    img.clear();
    img.load(arr_image[i][to_draw]);
    img.rotate90(arr_rotate[i][to_draw]);
  //img.update(); //update here no necessary,  occurs in both load and rotate90 routines 
    img.getTexture().setTextureMinMagFilter(GL_NEAREST, GL_NEAREST); //set pixel precision
	loop_count++;
  }
  ofSetColor(255,255,255,255);
  /* Start Patch RPI P4 */
  ofApp::shader_begin(1); //set for image = 1
  /* End Patch RPI P4 */
  img.draw(arr_posx[i][to_draw],arr_posy[i][to_draw],arr_dim1[i][to_draw],arr_dim2[i][to_draw]); 
  /* Start Patch RPI P4 */
  ofApp::shader_end(1); //set for image = 1
  /* End Patch RPI P4 */
 
 }
 previous_image = arr_image[i][to_draw]; 
}

/*
 ##########################################################
 #                          Log                           #
 ##########################################################
*/
void ofApp::log(std::string str) {
  return;
  ifstream f(DOLOG);
  if (f.good()) {
   f.close();
  } else {
   f.close();
   return;
  }   
  std::cout << "[" << boost::posix_time::microsec_clock::local_time().time_of_day().total_milliseconds() << "]: " << str << std::endl;
}

/*
 ##########################################################
 #                   Set Background                       #
 ##########################################################
*/
void ofApp::setBackground(int redbg, int greenbg, int bluebg) {
 if (ofxRPI4Window::isHDR && !ofxRPI4Window::isDoVi && !ofxRPI4Window::is_std_DoVi) { 
  if (ofxRPI4Window::bit_depth == 10) {  
   if(arr_redbg[i][to_draw] != -1) {
    if (ofxRPI4Window::avi_info.output_format != 0) {
     RGB data = RGB(redbg,greenbg,bluebg);
     YCbCr bg = RGB2YCbCr(data,10, ofxRPI4Window::avi_info.colorimetry, ofxRPI4Window::avi_info.rgb_quant_range);
     if (ofxRPI4Window::avi_info.output_format == 1) of10bitBackground(bg.Cb,bg.Cr,bg.Y);  //in YCbCr444, luminance is last channel
     if (ofxRPI4Window::avi_info.output_format == 2) of10bitBackground(bg.Y,bg.Cb,bg.Cr);  //in YCbCr422
    } else                                           of10bitBackground(redbg,greenbg,bluebg);
   }
  } else {
   if(arr_redbg[i][to_draw] != -1) {
    if (ofxRPI4Window::avi_info.output_format != 0) {
     RGB data = RGB(redbg,greenbg,bluebg);
     YCbCr bg = RGB2YCbCr(data,8,ofxRPI4Window::avi_info.colorimetry, ofxRPI4Window::avi_info.rgb_quant_range);
     if (ofxRPI4Window::avi_info.output_format == 1) ofBackground(bg.Cb,bg.Cr,bg.Y);  //in YCbCr444, luminance is last channel
     if (ofxRPI4Window::avi_info.output_format == 2) ofBackground(bg.Y,bg.Cb,bg.Cr);  //in YCbCr422
    } else                                           ofBackground(redbg,greenbg,bluebg);
   }
  }
 } else {
  if (ofxRPI4Window::bit_depth == 10) {  
   if(arr_redbg[i][to_draw] != -1) {
    if (ofxRPI4Window::avi_info.output_format != 0 || ofxRPI4Window::is_std_DoVi) {
     RGB data = RGB(redbg,greenbg,bluebg);
     YCbCr bg = RGB2YCbCr(data,10, ofxRPI4Window::avi_info.colorimetry, ofxRPI4Window::avi_info.rgb_quant_range);
     if (ofxRPI4Window::avi_info.output_format == 1) 					of10bitBackground(bg.Cb,bg.Cr,bg.Y);  //in YCbCr444, luminance is last channel
     if (ofxRPI4Window::avi_info.output_format == 2) 					of10bitBackground(bg.Y,bg.Cb,bg.Cr);  //in YCbCr422
	 if (ofxRPI4Window::is_std_DoVi && ofxRPI4Window::colorspace_on)	ofApp::setDoViBackground(redbg,greenbg,bluebg); //set dovi background only if standard dovi mode and drawing patterns
    } else                                           					of10bitBackground(redbg,greenbg,bluebg);
   }
  } else {
   if(arr_redbg[i][to_draw] != -1) {
    if (ofxRPI4Window::avi_info.output_format != 0 || ofxRPI4Window::is_std_DoVi) {
     RGB data = RGB(redbg,greenbg,bluebg);
     YCbCr bg = RGB2YCbCr(data,8,ofxRPI4Window::avi_info.colorimetry, ofxRPI4Window::avi_info.rgb_quant_range);
     if (ofxRPI4Window::avi_info.output_format == 1)					ofBackground(bg.Cb,bg.Cr,bg.Y);  //in YCbCr444, luminance is last channel
     if (ofxRPI4Window::avi_info.output_format == 2) 					ofBackground(bg.Y,bg.Cb,bg.Cr);  //in YCbCr422
	 if (ofxRPI4Window::is_std_DoVi && ofxRPI4Window::colorspace_on) 	ofApp::setDoViBackground(redbg,greenbg,bluebg);  //set dovi background only if standard dovi mode and drawing patterns
    } else                                          					ofBackground(redbg,greenbg,bluebg);
   }
  }
 }
}

/*
 ##########################################################
 #                     Set Color                          #
 ##########################################################
*/
void ofApp::setColor(int red, int green, int blue) {
 if (ofxRPI4Window::isHDR && !ofxRPI4Window::isDoVi && !ofxRPI4Window::is_std_DoVi) { 
  if (ofxRPI4Window::bit_depth == 10) ofSet10bitColor(red,green,blue);
  else                                ofSetColor(red,green,blue);
 } else {
  if (ofxRPI4Window::bit_depth == 10) ofSet10bitColor(red,green,blue);
  else                                ofSetColor(red,green,blue);
 }
}
#if 0
/*
 ##########################################################
 #                       Shader Begin                     #
 ##########################################################
*/
void ofApp::shader_begin(int is_image) {
 if ((!ofxRPI4Window::shader_init && ofxRPI4Window::avi_info.output_format != 0) || (!ofxRPI4Window::shader_init && ofxRPI4Window::is_std_DoVi)) {
  if (is_image) { 
	if (ofxRPI4Window::avi_info.max_bpc == 10 && ofxRPI4Window::isHDR) float_img.getTexture().bind();
	else 															         img.getTexture().bind();
  }
  if (ofxRPI4Window::is_std_DoVi && ofxRPI4Window::bit_depth == 10) fbo10.begin();
  if (ofxRPI4Window::is_std_DoVi && ofxRPI4Window::bit_depth == 8) fbo8.begin();  
  ofxRPI4Window::shader.begin();
  if (ofxRPI4Window::is_std_DoVi) {
	ofxRPI4Window::shader.setUniform2f("resolution", ofGetWindowWidth(), ofGetWindowHeight());
	if (ofxRPI4Window::dv_profile == 1) {
      ofxRPI4Window::shader.setUniform3f("coeffs_num",0.2627, 0.6780, 0.0593); //BT2020
	  ofxRPI4Window::shader.setUniform3f("coeffs_div",1.8556, 1.5748, 0.5); //BT2020
	}
	if (ofxRPI4Window::dv_profile == 2) {
	  ofxRPI4Window::shader.setUniform3f("coeffs_num",0.2126, 0.7152, 0.0722); //BT709
	  ofxRPI4Window::shader.setUniform3f("coeffs_div", 1.8814, 1.4746, 0.5); //BT709
	}
  }	else {
    ofxRPI4Window::shader.setUniform1i("bits", ofxRPI4Window::bit_depth);
    ofxRPI4Window::shader.setUniform1i("colorimetry", ofxRPI4Window::avi_info.colorimetry);
    ofxRPI4Window::shader.setUniform1i("color_format", ofxRPI4Window::avi_info.output_format);
    ofxRPI4Window::shader.setUniform1i("rgb_quant_range", ofxRPI4Window::avi_info.rgb_quant_range);  
    ofxRPI4Window::shader.setUniform1i("is_image", is_image);

  }
 }
} 
#endif
#if 1
/*
 ##########################################################
 #                       Shader Begin                     #
 ##########################################################
*/
void ofApp::shader_begin(int is_image) {
 if ((!ofxRPI4Window::shader_init && ofxRPI4Window::avi_info.output_format != 0) || (!ofxRPI4Window::shader_init && ofxRPI4Window::is_std_DoVi)) {
  if (is_image) { 
	if (ofxRPI4Window::avi_info.max_bpc == 10 && ofxRPI4Window::isHDR) float_img.getTexture().bind();
	else 															         img.getTexture().bind();
  }
  if (ofxRPI4Window::is_std_DoVi && ofxRPI4Window::bit_depth == 10) fbo10.begin();
  if (ofxRPI4Window::is_std_DoVi && ofxRPI4Window::bit_depth == 8) fbo8.begin();  
  ofxRPI4Window::shader.begin();
  if (ofxRPI4Window::is_std_DoVi) {
	ofxRPI4Window::shader.setUniform2f("resolution", ofGetWindowWidth(), ofGetWindowHeight());
	if (ofxRPI4Window::dv_profile == 2) {
	  ofxRPI4Window::shader.setUniform3f("coeffs_num",0.2126, 0.7152, 0.0722); //BT709
	  ofxRPI4Window::shader.setUniform3f("coeffs_div",1.8556, 1.5748, 0.5); //BT709
	}
	if (ofxRPI4Window::dv_profile == 1) {
      ofxRPI4Window::shader.setUniform3f("coeffs_num",0.2627, 0.6780, 0.0593); //BT2020
	  ofxRPI4Window::shader.setUniform3f("coeffs_div", 1.8814, 1.4746, 0.5); //BT2020
	}

  }	else {
	int scalar1;
	int scalar2;

	if (ofxRPI4Window::avi_info.colorimetry == 2) {
	  ofxRPI4Window::shader.setUniform3f("coeffs_num",0.2126, 0.7152, 0.0722); //BT709
	  ofxRPI4Window::shader.setUniform3f("coeffs_div",1.8556, 1.5748, 0.5); //BT709
	}	
	if (ofxRPI4Window::avi_info.colorimetry == 9) {
      ofxRPI4Window::shader.setUniform3f("coeffs_num",0.2627, 0.6780, 0.0593); //BT2020
	  ofxRPI4Window::shader.setUniform3f("coeffs_div", 1.8814, 1.4746, 0.5); //BT2020
	}
	int shift = ofxRPI4Window::bit_depth - 8;
	if (ofxRPI4Window::avi_info.rgb_quant_range == 1) {
		scalar1 = 224 << shift;		
		scalar2 = 219 << shift;
	}
	if (ofxRPI4Window::avi_info.rgb_quant_range == 2) {
		scalar1 = 256 << shift;
		scalar2 = 255 << shift;
	}
	int offset = 128 << shift;
	int normalizer = (256 << shift) - 1;
	int scale = (256 << (ofxRPI4Window::bit_depth == 10 ? 8 : 0)) - 1;
	
	ofxRPI4Window::shader.setUniform1i("scalar1", scalar1);
    ofxRPI4Window::shader.setUniform1i("scalar2", scalar2);
    ofxRPI4Window::shader.setUniform1i("offset", offset);
    ofxRPI4Window::shader.setUniform1i("scale", scale);
    ofxRPI4Window::shader.setUniform1i("normalizer", normalizer);
    ofxRPI4Window::shader.setUniform1i("color_format", ofxRPI4Window::avi_info.output_format);
    ofxRPI4Window::shader.setUniform1i("is_image", is_image);

  }
 }
} 
#endif
/*
 ##########################################################
 #                        Shader End                      #
 ##########################################################
*/
void ofApp::shader_end(int is_image) {
 if ((!ofxRPI4Window::shader_init && ofxRPI4Window::avi_info.output_format != 0) || (!ofxRPI4Window::shader_init && ofxRPI4Window::is_std_DoVi)) {
  ofxRPI4Window::shader.end();

  if (is_image) { 
	if (ofxRPI4Window::avi_info.max_bpc == 10 && ofxRPI4Window::isHDR) float_img.getTexture().unbind();
    else 															         img.getTexture().unbind();
  }
  if (ofxRPI4Window::is_std_DoVi && ofxRPI4Window::bit_depth == 10) fbo10.end();
  if (ofxRPI4Window::is_std_DoVi && ofxRPI4Window::bit_depth == 8) fbo8.end();
 }		
}

 
void ofApp::YCbCr2RGB(){
	if (ofxRPI4Window::avi_info.output_format != 0) {
		int Y, Cb, Cr;
		//Getting pointer to pixel array of image
		unsigned char *pixels = img.getPixels().getData();
		//Calculate number of pixel components
		int width = img.getPixels().getWidth();
		int height = img.getPixels().getHeight();
		int channels = img.getPixels().getNumChannels();
		//Modify pixel array
		for (int y=0; y<height; y++) {
			for (int x=0; x<width; x++) {
        
				//Read pixel (x,y) color components
				int index = channels * (x + width * y);

				if ( ofxRPI4Window::avi_info.output_format == 1) { //YCbCr444
					Cb = pixels[ index ];
					Cr = pixels[ index + 1 ];
					Y = pixels[ index + 2 ];
				}	
				if ( ofxRPI4Window::avi_info.output_format == 2) { 	//YCbCr422		
					Y = pixels[ index ];
					Cb = pixels[ index + 1 ];
					Cr = pixels[ index + 2 ];
				}

				YCbCr data = YCbCr(Y,Cb,Cr);
				RGB rgb = YCbCrToRGB(data,bits,ofxRPI4Window::avi_info.colorimetry, ofxRPI4Window::avi_info.rgb_quant_range);
				//Set red 
				pixels[ index ] = rgb.R;
				//Set green 
				pixels[ index + 1 ] = rgb.G;
				//Set blue 
				pixels[ index + 2 ] = rgb.B;
			}
		}
		//Calling img.update() to apply changes
		img.update();
	}
}


int ofApp::dv_map_mode=2;
int ofApp::dv_minpq=62;
int ofApp::dv_maxpq=3696;
int ofApp::dv_diagonal=42;
int ofApp::dv_color_space=1;

/*
 ##########################################################
 #                   Update DoVi Metadata                 #
 ##########################################################
*/
//struct ofApp::dv_metadata ofApp::dovi_metadata_update() {
void ofApp::dovi_metadata_update() {

	int crc;
	
	if (dv_map_mode != dv_metadata.dv_map_mode || 
	    dv_minpq != dv_metadata.dv_minpq || 
		dv_maxpq != dv_metadata.dv_maxpq ||
		dv_diagonal != dv_metadata.dv_diagonal ||
		dv_color_space != dv_metadata.dv_color_space) dv_meta_update = 1; 
		
	/* DV Profile 8.1 */	
	if (ofxRPI4Window::dv_profile == 1) {

		if (dv_meta_update) {	
			/* Source signal color space, 0=YCbCr, 1=RGB, 2=IPT, 3=Reserved */
			dv_metadata.dv_meta8_1[66] = dv_color_space & 0xff;
			/* Source display minPQ, maxPQ(in 12-bit PQ encoding) and diagonal */
			/* The value shall be in the range of 0 to 4095, inclusive. If source_min_PQ is not present, it shall be inferred to be 62 */
			dv_metadata.dv_meta8_1[69] = (dv_minpq  >> 8) & 0xff;
			dv_metadata.dv_meta8_1[70] = dv_minpq & 0xff;
			/* The value shall be in the range of 0 to 4095, inclusive. If source_max_PQ is not present, it shall be inferred to be 3696 */			
			dv_metadata.dv_meta8_1[71] = (dv_maxpq >> 8) & 0xff;
			dv_metadata.dv_meta8_1[72] = dv_maxpq & 0xff;	
			/* source_diagonal indicates the diagonal size of source display in inch. The value shall be in the range of 0 to 1023, inclusive. If source_diagonal is not present, it shall be inferred to be 42 */
			dv_metadata.dv_meta8_1[73] = (dv_diagonal >> 8) & 0xff;
			dv_metadata.dv_meta8_1[74]	= dv_diagonal & 0xff;
			
			/* DV Mapping mode (Perceptual = 0,Absolute(Verify) = 1, Relative(Calibrate) = 2, Unknown=3, None = 256, // 0x00000100) */
			dv_metadata.dv_meta8_1[92] = dv_map_mode & 0xff;
			
			/* Level 1 ext metadata block -- Current Scene minPQ, maxPQ, avgPQ(in 12-bit PQ encoding) */
			/* The value shall be in the range of 0 to 4095, inclusive. If min_PQ is not present, it shall be inferred to be equal to the value of source_min_PQ */
			dv_metadata.dv_meta8_1[81] = (dv_minpq  >> 8) & 0xff;
			dv_metadata.dv_meta8_1[82] = dv_minpq & 0xff;
			/* The value shall be in the range of 0 to 4095, inclusive. If max_PQ is not present, it shall be inferred to be equal to the value of source_max_PQ */
			dv_metadata.dv_meta8_1[83] = (dv_maxpq >> 8) & 0xff;
			dv_metadata.dv_meta8_1[84] = dv_maxpq & 0xff;
			/* The value shall be in the range of 0 to 4095, inclusive. If avg_PQ is not present, it shall be inferred to be equal to the value of (source_min_PQ + source_max_PQ)/2 */
			dv_metadata.dv_meta8_1[85] = (((dv_minpq + dv_maxpq)/2) >> 8) & 0xff;
			dv_metadata.dv_meta8_1[86] = ((dv_minpq + dv_maxpq)/2) & 0xff;
	
			crc = ofApp::crc32mpeg(dv_metadata.dv_meta8_1,124);
 
			dv_metadata.dv_meta8_1[124] = crc>>24;
			dv_metadata.dv_meta8_1[125] = (crc>>16)&0xff;
			dv_metadata.dv_meta8_1[126] = (crc>>8)&0xff;
			dv_metadata.dv_meta8_1[127] =crc&0xff;
			dv_meta_update = 0;
		}	
	}
	/* DV Profile 8.2 */
	if (ofxRPI4Window::dv_profile == 2) { 

		if (dv_meta_update) {
			/* Source signal color space, 0=YCbCr, 1=RGB, 2=IPT, 3=Reserved */
			dv_metadata.dv_meta8_2[66] = dv_color_space & 0xff;
			/* Source display minPQ, maxPQ(in 12-bit PQ encoding) and diagonal */
			/* The value shall be in the range of 0 to 4095, inclusive. If source_min_PQ is not present, it shall be inferred to be 62 */
			dv_metadata.dv_meta8_2[69] = (dv_minpq  >> 8) & 0xff;
			dv_metadata.dv_meta8_2[70] = dv_minpq & 0xff;
			/* The value shall be in the range of 0 to 4095, inclusive. If source_max_PQ is not present, it shall be inferred to be 3696 */			
			dv_metadata.dv_meta8_2[71] = (dv_maxpq >> 8) & 0xff;
			dv_metadata.dv_meta8_2[72] = dv_maxpq & 0xff;
			/* source_diagonal indicates the diagonal size of source display in inch. The value shall be in the range of 0 to 1023, inclusive. If source_diagonal is not present, it shall be inferred to be 42 */			
			dv_metadata.dv_meta8_2[73] = (dv_diagonal >> 8) & 0xff;
			dv_metadata.dv_meta8_2[74]	= dv_diagonal & 0xff;	

			/* DV Mapping mode (Perceptual = 0,Absolute(Verify) = 1, Relative(Calibrate) = 2, Unknown=3, None = 256, // 0x00000100) */
			dv_metadata.dv_meta8_2[92] = dv_map_mode & 0xff;
			
			/* Level 1 ext metadata block -- Current Scene minPQ, maxPQ, avgPQ(in 12-bit PQ encoding) */
			/* The value shall be in the range of 0 to 4095, inclusive. If min_PQ is not present, it shall be inferred to be equal to the value of source_min_PQ */
			dv_metadata.dv_meta8_2[81] = (dv_minpq  >> 8) & 0xff;
			dv_metadata.dv_meta8_2[82] = dv_minpq & 0xff;
			/* The value shall be in the range of 0 to 4095, inclusive. If max_PQ is not present, it shall be inferred to be equal to the value of source_max_PQ */
			dv_metadata.dv_meta8_2[83] = (dv_maxpq >> 8) & 0xff;
			dv_metadata.dv_meta8_2[84] = dv_maxpq & 0xff;
			/* The value shall be in the range of 0 to 4095, inclusive. If avg_PQ is not present, it shall be inferred to be equal to the value of (source_min_PQ + source_max_PQ)/2 */
			dv_metadata.dv_meta8_2[85] = (((dv_minpq + dv_maxpq)/2) >> 8) & 0xff;
			dv_metadata.dv_meta8_2[86] = ((dv_minpq + dv_maxpq)/2) & 0xff;
	
			crc = ofApp::crc32mpeg(dv_metadata.dv_meta8_2,124);
 
			dv_metadata.dv_meta8_2[124] = crc>>24;
			dv_metadata.dv_meta8_2[125] = (crc>>16)&0xff;
			dv_metadata.dv_meta8_2[126] = (crc>>8)&0xff;
			dv_metadata.dv_meta8_2[127] =crc&0xff;
			dv_meta_update = 0;
		}	
	}								 
	dv_metadata.dv_map_mode = dv_map_mode;
	dv_metadata.dv_minpq = dv_minpq;
	dv_metadata.dv_maxpq = dv_maxpq;
	dv_metadata.dv_diagonal = dv_diagonal;
	dv_metadata.dv_color_space = dv_color_space;

}

/*
 ##########################################################
 #                   Create DoVi Metadata                 #
 ##########################################################
*/
void ofApp::dovi_metadata_create() {
	int Y=0, Cb=0, Cr=0;
	int num_bits=0;
	ofShortPixels short_pix;
	ofPixels pix;
	ofShortImage short_img;
	ofImage img;


	if (ofxRPI4Window::bit_depth == 10) {
		short_pix.allocate(ofGetWindowWidth(), 2, OF_IMAGE_COLOR_ALPHA);
		short_pix.setColor(1023);
	} else {
		pix.allocate(ofGetWindowWidth(), 2, OF_IMAGE_COLOR_ALPHA);
		pix.setColor(255);
	}


	ofApp::dovi_metadata_update();
	unsigned char mask = 1; // Bit mask
	unsigned char bits[8];
	unsigned char total_bits[1024] = {0};
	int i, j = CHAR_BIT-1;

	int n = sizeof(dv_metadata_active)/sizeof(dv_metadata_active[0]);

	if (ofxRPI4Window::dv_profile == 1) memcpy(dv_metadata_active, dv_metadata.dv_meta8_1, sizeof(dv_metadata)); //DoVi Profile 8.1
	if (ofxRPI4Window::dv_profile == 2) memcpy(dv_metadata_active, dv_metadata.dv_meta8_2, sizeof(dv_metadata)); //DoVi Profile 8.2


	// Extract the bits
	for (int k=0; k < n; k++) {
//		printf("byte 0x%02x : ",dv_metadata[k]);
		for ( i = 0; i < 8; i++,j--,mask = 1) {
			// Mask each bit in the byte and store it
			bits[i] =(dv_metadata_active[k] & (mask<<=j))  !=0;

//			printf("%d", bits[i]);
			total_bits[num_bits] = bits[i];
			num_bits++;
		}

		//		puts("");
		j = CHAR_BIT-1;

	}
	//    printf("Total number of Cal bits %d\n",num_bits);

	/* Create DoVi RPU Display Management Data */
	int x=0;
	int cycles=0;

	for(auto line: pix.getLines(0,2)) {

		for(auto pixel: line.getPixels()) {
			if (cycles < 3) {
				if (x == 1024) {
					x = 0;
					cycles++;
				}				
		//		printf("posx=%d posy=%d z=%d Before: Y %d ,Cb %d , Cr %d ",x, y, z, Y, Cb, Cr);
				if (ofxRPI4Window::bit_depth == 10){
					Cr = 1016;
					Cb = 0xff80; 
				} else {
					Y = 128;// << shift;
					Cb = 16;// << shift;
				}
				if (total_bits[x] == 0) {
					if (ofxRPI4Window::bit_depth == 10) {
						Y = 0x1000;
//				Cb= 0;
					} else {
						Cr = 0;
					}
//				printf(".");
				}
				if (total_bits[x] == 1) {
					if (ofxRPI4Window::bit_depth == 10) {
						Y = 0x1010;
//				Cb = 1016;
					} else {
						Cr = 16;// << shift;
					}
//				printf("^");								
				}

				pixel[0] = Y;
				pixel[1] = Cb;
				pixel[2] = Cr;
	//			printf("==> After: Y %d ,Cb %d , Cr %d \n",Y, Cb, Cr);
			 	x++;	
			}
 			if (cycles == 3) break;
		}
	}

	if (ofxRPI4Window::bit_depth == 10) {

		short_img.setFromPixels(short_pix);
		ofSet10bitColor(1023,1023,1023,1023); 
		fbo_dovi.begin();
		short_img.getTexture().setTextureMinMagFilter(GL_NEAREST, GL_NEAREST);
		short_img.drawSubsection(0,0,ofGetWindowWidth(),1,0,0,ofGetWindowWidth(),1);
		short_img.drawSubsection(0,1,1153,1,0,1);
		fbo_dovi.end();
	} else {
		img.setFromPixels(pix);
		ofSetColor(255,255,255,255); 
		fbo_dovi.begin();
		img.getTexture().setTextureMinMagFilter(GL_NEAREST, GL_NEAREST);
		img.drawSubsection(0,0,ofGetWindowWidth(),1,0,0,ofGetWindowWidth(),1);
		img.drawSubsection(0,1,1153,1,0,1);
		fbo_dovi.end();	
	}	
}	
	
/*
 ##########################################################
 #                   Draw DoVi Pattern/Image              #
 ##########################################################
*/
void ofApp::dovi_metadata_mux() {


	if (ofxRPI4Window::bit_depth == 10) {
		ofSetColor(1023,1023,1023,1023); 
		fbo10.draw(0,0,ofGetWindowWidth(),ofGetWindowHeight());
		fbo_dovi.draw(0,0,ofGetWindowWidth(),2);		
	} else {
		ofSetColor(255,255,255,255); 
		fbo8.draw(0,0,ofGetWindowWidth(),ofGetWindowHeight());		
		fbo_dovi.draw(0,0,ofGetWindowWidth(),2);
		}
}



/*
 ##########################################################
 #                   Set DoVi Background                  #
 ##########################################################
*/
void ofApp::setDoViBackground(int redbg, int greenbg, int bluebg) {
	int bits = ofxRPI4Window::bit_depth;
	redbg   *= ((pow(2,(8+(bits-8))) - 1) / (pow(2,8) - 1));
	greenbg *= ((pow(2,(8+(bits-8))) - 1) / (pow(2,8) - 1));
	bluebg  *= ((pow(2,(8+(bits-8))) - 1) / (pow(2,8) - 1));
	ofApp::setColor(redbg,greenbg,bluebg);
	ofApp::shader_begin(0);

	ofDrawRectangle(0,0,ofGetWindowWidth(),ofGetWindowHeight());

	ofApp::shader_end(0);
}

/*
 ##########################################################
 #                        FBO Allocate                    #
 ##########################################################
*/
void ofApp::fbo_allocate() {
	if (ofxRPI4Window::is_std_DoVi) {
		ofFboSettings settings;
        settings.width                      = ofGetWidth();
        settings.height                     = 2;
        settings.internalformat             = GL_RGBA;
		//set pixel precision
        settings.minFilter                  = GL_NEAREST;
        settings.maxFilter                  = GL_NEAREST;

		//allocate dovi metadata fbo, uses 8bit texture
//		fbo_dovi.allocate(ofGetWindowWidth(),2, GL_RGBA);
		fbo_dovi.allocate(settings);
		fbo_dovi.begin();
		ofClear(0,0,0,0);
		fbo_dovi.end();

		if (ofxRPI4Window::bit_depth == 10) {
			//allocate 10bit fbo
			settings.height 					= ofGetWindowHeight();
			settings.internalformat             = GL_RGB10_A2;
			//fbo10.allocate(ofGetWindowWidth(),ofGetWindowHeight(), GL_RGB10_A2);
			fbo10.allocate(settings);
			fbo10.begin();
			ofClear10bit(0,0,0,0);
			fbo10.end();
		} else {
			//allocate 8bit fbo
			settings.height = ofGetWindowHeight();
			fbo8.allocate(settings);
	//		fbo8.allocate(ofGetWindowWidth(),ofGetWindowHeight(), GL_RGBA);
			fbo8.begin();
			ofClear(0,0,0,0);
			fbo8.end();
		}
	}
}

/*
 ##########################################################
 #                       DoVi CRC32                       #
 ##########################################################
*/
unsigned int ofApp::crc32mpeg(unsigned char *message, size_t l)
{
   size_t i, j;
   unsigned int crc, msb;

   crc = 0xFFFFFFFF;
   for(i = 0; i < l; i++) {
      // xor next byte to upper bits of crc
      crc ^= (((unsigned int)message[i])<<24);
      for (j = 0; j < 8; j++) {    // Do eight times.
            msb = crc>>31;
            crc <<= 1;
            crc ^= (0 - msb) & 0x04C11DB7;
      }

   }
#if 0   
   printf("crc %x ", crc>>24);
   printf("crc %x ", (crc>>16)&0xff);
   printf("crc %x ", (crc>>8)&0xff);
   printf("crc %x\n", crc&0xff);
#endif 

  return crc;         // don't complement crc on output
}


/*
 ##########################################################
 #                        Old Routines                    #
 ##########################################################
*/



#if 0
/*
 ##########################################################
 #                   Inject DoVi Metadata                 #
 ##########################################################
*/
void ofApp::dovi_metadata_inject(int bit_depth) {
	int Y=0, Cb=0, Cr=0;
	int width=0, height=0, channels=0;
	int num_bits=0;
	unsigned short *short_pixels;
	unsigned char *pixels;
	//	ofFbo fbo_dovi;
	ofShortPixels short_pix;
	ofPixels pix;
	ofShortImage short_img;
	ofImage img;

	if (bit_depth == 10) {
		short_pix.allocate(ofGetWindowWidth(), 2, OF_IMAGE_COLOR_ALPHA);
		short_pix.setColor(1023);
	} else {

		pix.allocate(ofGetWindowWidth(), 2, OF_IMAGE_COLOR_ALPHA);
		pix.setColor(255);
	}


	ofApp::dovi_metadata_update();
	unsigned char mask = 1; // Bit mask
	unsigned char bits[8];
	unsigned char total_bits[1024] = {0};
	int i, j = CHAR_BIT-1;


		
	int n = sizeof(dv_metadata_active)/sizeof(dv_metadata_active[0]);

	if (ofxRPI4Window::dv_profile == 1) memcpy(dv_metadata_active, dv_metadata.dv_meta8_1, sizeof(dv_metadata));
	if (ofxRPI4Window::dv_profile == 2) memcpy(dv_metadata_active, dv_metadata.dv_meta8_2, sizeof(dv_metadata));

	// Extract the bits
	for (int k=0; k < n; k++) {
//		printf("byte 0x%02x : ",dv_metadata[k]);
		for ( i = 0; i < 8; i++,j--,mask = 1) {
		// Mask each bit in the byte and store it
			bits[i] =(dv_metadata_active[k] & (mask<<=j))  !=0;
//			printf("%d", bits[i]);
			total_bits[num_bits] = bits[i];
			num_bits++;
		}

	//		puts("");
		j = CHAR_BIT-1;

	}
	//    printf("Total number of Cal bits %d\n",num_bits);

	/* Create DoVi RPU Display Management Data */
	int x=0;
	int cycles=0;
	int shift = bit_depth - 8;
	int index;

	for(auto line: pix.getLines(0,2)){

		for(auto pixel: line.getPixels()){
			if (cycles < 3) {
				if (x == 1024) {
					x = 0;
					cycles++;
				}				
		//		printf("posx=%d posy=%d z=%d Before: Y %d ,Cb %d , Cr %d ",x, y, z, Y, Cb, Cr);
				if (bit_depth == 10){
					Cr = 1016;
					Cb = 0xff80; 
				} else {
					Y = 128;// << shift;
					Cb = 16;// << shift;
				}
				if (total_bits[x] == 0) {
					if (bit_depth == 10) {
						Y = 0x1000;
//				Cb= 0;
					} else {
						Cr = 0;
					}
//				printf(".");
				}
				if (total_bits[x] == 1) {
					if (bit_depth == 10) {
						Y = 0x1010;
//				Cb = 1016;
					} else {
						Cr = 16;// << shift;
					}
//				printf("^");								
				}

				pixel[0] = Y;
				pixel[1] = Cb;
				pixel[2] = Cr;
	//			printf("==> After: Y %d ,Cb %d , Cr %d \n",Y, Cb, Cr);
			 	x++;	
			 }
 			if (cycles == 3) break;
			}
	}

	if (bit_depth == 10) {
		ofSet10bitColor(1023,1023,1023,1023); 
		short_img.setFromPixels(short_pix);
		fbo_dovi.begin();
		short_img.getTexture().setTextureMinMagFilter(GL_NEAREST, GL_NEAREST);
		short_img.drawSubsection(0,0,ofGetWindowWidth(),1,0,0,ofGetWindowWidth(),1);
		short_img.drawSubsection(0,1,1153,1,0,1);
		fbo_dovi.end();
		fbo10.draw(0,0,ofGetWindowWidth(),ofGetWindowHeight());
		fbo_dovi.draw(0,0,ofGetWindowWidth(),2);		
	} else {
			
		ofSetColor(255,255,255,255); 
		img.setFromPixels(pix);
		fbo_dovi.begin();
		img.getTexture().setTextureMinMagFilter(GL_NEAREST, GL_NEAREST);
		img.drawSubsection(0,0,ofGetWindowWidth(),1,0,0,ofGetWindowWidth(),1);
		img.drawSubsection(0,1,1153,1,0,1);
		fbo_dovi.end();
		fbo8.draw(0,0,ofGetWindowWidth(),ofGetWindowHeight());
		fbo_dovi.draw(0,0,ofGetWindowWidth(),2);
	}
}
#endif 
#if 0
void ofApp::dovi_dump() {
		int Y=0, Cb=0, Cr=0;
		//Getting pointer to pixel array of image
		unsigned char *pixels = img.getPixels().getData();
		//Calculate number of pixel components
		int width = img.getPixels().getWidth();
		int height = img.getPixels().getHeight();
		int channels = img.getPixels().getNumChannels();
		int num_bits=0;
		int hex_num=0;

		unsigned char mask = 1; // Bit mask
		unsigned char bits[8];
		unsigned char total_y0_bits[1920] = {0};
		unsigned char total_y1_bits[1920] = {0};
//		int i, j = CHAR_BIT-1;
//		int n = sizeof(byte)/sizeof(byte[0]);

		for (int y=0; y<height; y++) {
			num_bits=0;
			for (int x=0; x<width; x++) {
        
				//Read pixel (x,y) color components
				int index = channels * (x + width * y);
					num_bits++;
					Y = pixels[ index ];
					Cb = pixels[ index + 1 ];
					Cr = pixels[ index + 2 ];
					if (y==0) { 
						printf("posx=%d posy=%d  Before: Y %d ,Cb %d , Cr %d \n",x, y, Y, Cb, Cr);
						
						if (Cr == 16) {
						  total_y0_bits[x] = 1;
						} 
						if (Cr == 0) {
						  total_y0_bits[x] = 0;
						}

					}
					if (y==1) { 
						printf("posx=%d posy=%d  Before: Y %d ,Cb %d , Cr %d \n",x, y, Y, Cb, Cr);
						
						if (Cr == 16) {
						  total_y1_bits[x] = 1;
						} 
						if (Cr == 0) {
						  total_y1_bits[x] = 0;
						}

					}
					

			}	
		}
		printf("Y0 ");
		for ( int x=0; x < num_bits;x+=8) {
			for (int i=0; i < 8; i++) {
			   
				hex_num = (hex_num<<1)|total_y0_bits[i+x];
			   

			}
			printf("0x%02x, ", hex_num);
			hex_num=0;

		}
		puts("");
		printf("Y1 ");
		for ( int x=0; x < num_bits;x+=8) {
			for (int i=0;i < 8; i++) {
				hex_num = (hex_num<<1)|total_y1_bits[i+x];

			}
			printf("0x%02x, ", hex_num);
			hex_num=0;


		}
		puts("");

}
#endif 
#if 0
void ofApp::dovi_rpu_inject() {
	if (ofxRPI4Window::avi_info.rgb_quant_range == 1 && ofxRPI4Window::avi_info.output_format == 2) {
		int Y=0, Cb=0, Cr=0;
		//Getting pointer to pixel array of image
		unsigned char *pixels = img.getPixels().getData();
		//Calculate number of pixel components
		int width = img.getPixels().getWidth();
		int height = img.getPixels().getHeight();
		int channels = img.getPixels().getNumChannels();
		int num_bits=0;
		unsigned char byte[] = {0x00,0x00,0x00,0x01,0x19,0x08,0x09,0x00,0x40,0x61,0xb6,0x50,0x6f,0x00,0x3f,0xf8,0x01,0xff,
								0xc0,0x0f,0xff,0xd0,0x00,0x00,0x10,0x00,0x00,0x1b,0x00,0x00,0x03,0x02,0x00,0x00,0x03,0x03,
								0x60,0x00,0x00,0x40,0x00,0x00,0x68,0x80,0x00,0x0c,0x7c,0x1a,0x44,0x80,0x03,0xf1,0x6c,0x11,
								0x0c,0x80,0x00,0x04,0x2f,0xa9,0x5c,0x00,0x00,0x03,0x00,0x00,0x20,0x00,0x00,0x03,0x00,0x20,
								0x00,0x00,0x03,0x01,0x0a,0xe7,0xfa,0x8f,0xfa,0x8f,0xfa,0x8d,0x0a,0xe7,0xfa,0x8f,0xfa,0x8f,
								0xfa,0x8d,0x0a,0xe7,0xff,0xfc,0x00,0x00,0x03,0x00,0x00,0x03,0x00,0x00,0x03,0x00,0x01,0x90,
								0x81,0xf7,0x38,0x05,0x45,0x30,0x08,0x01,0x3c,0x80,0x8c,0x00,0xc0,0x28,0x21,0x22,0x98,0x00,
								0x80,0x08,0x00,0x80,0x01,0x00,0x02,0x02,0x00,0x00,0x03,0x00,0x09,0x06,0x0f,0xa0,0x00,0x32,
								0x00,0x00,0x03,0x00,0x00,0x46,0xf1,0x99,0x5c,0x80 };

		unsigned char mask = 1; // Bit mask
		unsigned char bits[8];
		unsigned char total_bits[1500] = {0};
		int i, j = CHAR_BIT-1;
		int n = sizeof(byte)/sizeof(byte[0]);

		// Extract the bits
		for (int k=0; k < n; k++) {
			printf("byte 0x%02x : ",byte[k]);
			for ( i = 0; i < 8; i++,j--,mask = 1) {
			// Mask each bit in the byte and store it
				bits[i] =( byte[k] & (mask<<=j))  !=0;

				printf("%d", bits[i]);
				total_bits[num_bits] = bits[i];
				num_bits++;
			}

			puts("");
			j = CHAR_BIT-1;

		}
		printf("Total number of bits %d\n",num_bits);
		int z=0;
		for (int y=0; y<height; y++) {
			for (int x=0; x<width; x++) {
        
				//Read pixel (x,y) color components
				int index = channels * (x + width * y);
				
					Y = pixels[ index ];
					Cb = pixels[ index + 1 ];
					Cr = pixels[ index + 2 ];

					if (index == 0) { //set metadata identifier to 0b00, single packet contains all DM metadata
					//	printf("z=%d Before: Y %d ,Cb %d , Cr %d ",z, Y, Cb, Cr);

						Cb &= 0x3fe;
						Cr &= 0x3fe;
						printf("..");
					}
					if ((z <= num_bits) && (index >= 0)) {
					//	printf("z=%d Before: Y %d ,Cb %d , Cr %d ",z, Y, Cb, Cr);

						if (z % 2 == 0) {
							//printf(" even ");
							if (total_bits[z] == 0) {
								Cb &= 0x3fe;
							//	Cb = 
								printf(".");
							} else {
								Cb |= 1;
								printf("^");
							}
						}else{
							//printf(" odd ");
							if (total_bits[z] == 0) {
								Cr &= 0x3fe;
								printf(".");
							} else {
								Cr |= 1;
								printf("^");
							}
						}
		//		printf("==> After: Y %d ,Cb %d , Cr %d \n",Y, Cb, Cr);
						z++;
						
					pixels[ index + 1 ] = Cb;
					pixels[ index + 2 ] = Cr;
					}

			}
		}
puts("");
	}

	//Calling img.update() to apply changes
	img.update();

}


#endif
