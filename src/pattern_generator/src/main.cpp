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
 
#include "ofMain.h"
#include "ofApp.h"
#define TEST_BUILD
#ifdef TEST_BUILD
 const char * pgenCodeVersion = "V02.00T";
#endif
#ifdef REL_BUILD
 const char * pgenCodeVersion = "V02.00R";
#endif

/* PGenerator Conf Default Variables */
char PGenerator_conf[100]="/etc/PGenerator/PGenerator.conf";
std::string color_format="0";
std::string rgb_quant_range="2";
std::string colorimetry="0";
std::string is_hdr="0";
std::string is_ll_dovi="0";
std::string is_std_dovi="0";
std::string eotf="2";
std::string primaries="2";
std::string max_fall="400";
std::string max_cll="1000";
std::string max_luma="4000";
std::string min_luma="1";
std::string max_bpc="8";
std::string mode_idx="-1";
std::string dv_status="0";
std::string dv_interface="0";
std::string dv_profile="2";
std::string dv_map_mode="2";
std::string dv_minpq="62";
std::string dv_maxpq="3696";
std::string dv_diagonal="42";
std::string dv_color_space="1";
/* Include RPI p4 header file */
#include "ofxRPI4Window.h"
// End Patch RPI p4

int main(int argc, char **argv){
 int w=1920;
 int h=1080;
 int ok=0;
 std::string str;
 /* Check Distro */
 if(boost::filesystem::exists("/etc/BiasiLinux/system_info"))       ok++;
 if(boost::filesystem::exists("/etc/BiasiLinux/packages.conf"))     ok++;
 if(boost::filesystem::exists("/etc/BiasiLinux/boot_device.conf"))  ok++;
 if(boost::filesystem::exists("/var/lib/BiasiLinux/PGenerator"))    ok++;
 if(boost::filesystem::exists("/var/lib/BiasiLinux/linux"))         ok++;
 if(boost::filesystem::exists("/usr/bin/pkg"))                      ok++;
 if(boost::filesystem::exists("/usr/bin/rcset"))                    ok++;
 if(boost::filesystem::exists("/usr/bin/bootloader"))               ok++;
 if(boost::filesystem::exists("/proc/device-tree/model"))           ok++;
 if(ok != 9 ) {
  printf("\nOnly on Distro BiasiLinux with PGenerator installed can be executed this program!\n\n");
  exit(1);
 }
 /* Check Device */
 ok=0;
 std::ifstream file("/proc/device-tree/model");
 std::getline(file, str);
 file.close();
 if (str.find("Raspberry") == string::npos) {
  printf("\nOnly on Raspberry Device can be executed this program!\n\n");
  exit(1);
 } 
 /* Continue */
 ofSetLogLevel(OF_LOG_VERBOSE);
 if(argc == 3) {
  w=atoi(argv[1]);
  h=atoi(argv[2]);
 }
 //ofLog() << "PGenerator version " << pgenCodeVersion;
 if (str.find("Raspberry Pi 4") == string::npos) {
  ofSetupOpenGL(w,h, OF_FULLSCREEN);
  ofRunApp( new ofApp());
 } else {
// Start Patch RPI p4
  /* Get var from PGenerator Conf */
  std::ifstream file(PGenerator_conf);
  while (std::getline(file, str)) {
   std::vector<std::string> el;
   boost::split(el, str, boost::is_any_of("="));
   if(el[0] == "max_cll")         max_cll=el[1];
   if(el[0] == "max_fall")        max_fall=el[1];
   if(el[0] == "max_luma")        max_luma=el[1];
   if(el[0] == "min_luma")        min_luma=el[1];
   if(el[0] == "max_bpc")         max_bpc=el[1];
   if(el[0] == "eotf")            eotf=el[1];
   if(el[0] == "color_format")    color_format=el[1];
   if(el[0] == "rgb_quant_range") rgb_quant_range=el[1];
   if(el[0] == "colorimetry") 	  colorimetry=el[1];
   if(el[0] == "is_hdr")          is_hdr=el[1];
   if(el[0] == "is_ll_dovi")      is_ll_dovi=el[1];
   if(el[0] == "is_std_dovi")     is_std_dovi=el[1];
   if(el[0] == "primaries")       primaries=el[1];
   if(el[0] == "mode_idx")        mode_idx=el[1];
   if(el[0] == "dv_status")       dv_status=el[1];
   if(el[0] == "dv_interface")    dv_interface=el[1];
   if(el[0] == "dv_profile")      dv_profile=el[1];
   if(el[0] == "dv_map_mode")     dv_map_mode=el[1];
   if(el[0] == "dv_minpq")    	  dv_minpq=el[1];
   if(el[0] == "dv_maxpq")        dv_maxpq=el[1];
   if(el[0] == "dv_diagonal")     dv_diagonal=el[1];
   if(el[0] == "dv_color_space")  dv_color_space=el[1];
  }
  file.close();

  /* Set var from PGenerator Conf */
  ofxRPI4Window::avi_info.output_format=atoi(color_format.c_str());
  ofxRPI4Window::avi_info.rgb_quant_range=atoi(rgb_quant_range.c_str());
  ofxRPI4Window::avi_info.colorimetry=atoi(colorimetry.c_str());
  ofxRPI4Window::isHDR=atoi(is_hdr.c_str());
  ofxRPI4Window::isDoVi=atoi(is_ll_dovi.c_str());
  ofxRPI4Window::is_std_DoVi=atoi(is_std_dovi.c_str());
  ofxRPI4Window::eotf=(static_cast<hdmi_eotf>(atoi(eotf.c_str())));
  ofxRPI4Window::hdr_primaries=atoi(primaries.c_str());
  ofxRPI4Window::hdr_metadata.hdmi_metadata_type1.max_fall=atof(max_fall.c_str());
  ofxRPI4Window::hdr_metadata.hdmi_metadata_type1.max_cll=atof(max_cll.c_str());
  ofxRPI4Window::hdr_metadata.hdmi_metadata_type1.max_display_mastering_luminance=atof(max_luma.c_str());
  ofxRPI4Window::hdr_metadata.hdmi_metadata_type1.min_display_mastering_luminance=atof(min_luma.c_str());
  ofxRPI4Window::avi_info.max_bpc=atoi(max_bpc.c_str());
  ofxRPI4Window::mode_idx=atoi(mode_idx.c_str());
  ofxRPI4Window::dv_status=atoi(dv_status.c_str());
  ofxRPI4Window::dv_interface=atoi(dv_interface.c_str());
  ofxRPI4Window::dv_profile=atoi(dv_profile.c_str());
  ofApp::dv_map_mode=atoi(dv_map_mode.c_str());
  ofApp::dv_minpq=atoi(dv_minpq.c_str());
  ofApp::dv_maxpq=atoi(dv_maxpq.c_str());
  ofApp::dv_diagonal=atoi(dv_diagonal.c_str());
  ofApp::dv_color_space=atoi(dv_color_space.c_str());

  /* RPI4 Run App */
  ofGLESWindowSettings settings;
  settings.glesVersion = 3;
  ofApp *cs_data;
  cs_data = new ofApp();
  cs_data->update();
  auto window = std::make_shared<ofxRPI4Window>(settings);
  auto app = std::make_shared<ofApp>();
  delete cs_data;

  ofRunApp(window, app);
  ofRunMainLoop();
// End Patch RPI p4
 }
}
