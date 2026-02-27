#
# Copyright (c) 2017-2018 Biasiotto Riccardo
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# See the File README and COPYING for more detail about License
#

###############################################
#                Variables                    #
###############################################
$pwd = getcwd;
$program_name="/usr/sbin/PGeneratord.pl";
$pid_file="/var/run/PGenerator/PGeneratord.pl.pid";

$debug="file";
$log_file="/tmp/pgenerator_debug.log";

$none="None";

@list_info_cmd=("GET_DMESG","GET_EDID_INFO","GET_PGENERATOR_CONF_ALL","GET_MODES_AVAILABLE","GET_MODE","GET_DISCOVERABLE","GET_DEVICE_MODEL","GET_CPU_INFO","GET_CPU_HARDWARE","GET_CPU_REVISION","GET_CPU_SERIAL","GET_STATS","GET_PGENERATOR_IS_EXECUTED","GET_CORE_VOLTAGE","GET_SCALING_GOVERNOR_CUR_FREQ","GET_SCALING_GOVERNOR","GET_SCALING_GOVERNOR_AVAILABLE","GET_PGENERATOR_VERSION","GET_ALL_IPMAC","GET_HDMI_INFO","GET_REFRESH","GET_OUTPUT_RANGE","GET_RESOLUTION","GET_GPU_MEMORY","GET_FREE_DISK","GET_TEMPERATURE","GET_CPU","GET_HOSTNAME","GET_WIFI_NET","GET_WIFI_NET_CONFIGURED","GET_UP_FROM","GET_LA","GET_FREE_MEM","GET_IP_MAC_ALL","GET_WIFI_STATUS","GET_CEA_DMT_AVAILABLE","GET_CEA_DMT","GET_DTOVERLAY","GET_BOOT_CONFIG");

$scaling_file="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor";
$scaling_available_file="/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors";
$scaling_freq_file="/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq";
$temperature_file="/sys/class/thermal/thermal_zone0/temp";
$mem_info_file="/proc/meminfo";
$arp_file="/proc/net/arp";
$rcPGenerator_default_file="/etc/default/rcPGenerator";
$cpu_file="/proc/cpuinfo";
$proc_device_model="/proc/device-tree/model";
$wifi_conf="/etc/wpa_supplicant/wpa_supplicant.conf";
$hostapd_conf="/etc/hostapd/hostapd.conf";
$hostapd_init="/etc/init.d/hostapd";
$uptime_file="/proc/uptime";
$load_avg_file="/proc/loadavg ";
$dir_wpa="/var/run/wpa_supplicant";
$hostname_file="/etc/hostname";


$not_connected="Disconnected";
$no_info_available="No info available";

$wpa_cli="/usr/bin/wpa_cli";
$wpa_passphrase="/usr/bin/wpa_passphrase";
$ip="/sbin/ip";
$hcitool="/usr/bin/hcitool";
$vcgencmd="/opt/vc/bin/vcgencmd";
$tar="/bin/tar";
$file_command="/usr/bin/file";
$setsid="/usr/bin/setsid";
$unzip="/usr/bin/unzip";
$tvservice="/opt/vc/bin/tvservice";
$modetest="/usr/bin/modetest -M vc4";
$edidparser="/usr/bin/edid-decode";
$init_hdmi_command="$tvservice -e";
$df="/bin/df";
$convert="/usr/bin/convert";
$sync="/bin/sync";
$reboot="/sbin/reboot";
$halt="/sbin/halt";
$timeout="/bin/timeout";
$iptables="/sbin/iptables";
$pkg="/usr/bin/pkg";
$passwd="/usr/bin/passwd";
$perl="/usr/bin/perl";
$dmesg="/bin/dmesg";
$identify="identify -ping -format '%w %h'";

$boot_loader_bin="/usr/bin/bootloader";
$bootloader_config_file="config.txt";
$bootloader_file="/boot/loader/boot_dir/$bootloader_config_file";

$pg_cmd_env="PG_CMD";

$sleep_info=5;

$distro_programs_info="/var/lib/BiasiLinux";

$socat_program="/usr/bin/socat";
$socat_device_options="b921600,icrnl=0,icanon=0,echo=0";

$serial_program_name="/usr/bin/PGenerator_serial.pl";

$serial_name="ttyAMA";

$sudo_cmd="sudo -E /usr/bin/PGenerator_cmd.pl";

$ENV{LD_LIBRARY_PATH}="/usr/lib:/opt/vc/lib" if(-e "/dev/dri/card0");

$eth_interface="eth0";
$bt_interface="bnep";
$hci_interface="hci0";
$wlan_interface="wlan0";

$img_width=128;
$img_height=72;

$status="Alive";

$port_server_calman=2100;

$w_s=1920;
$h_s=1080;

# START PI4 VARIABLES
$hdmi_1="HDMI-A-1";
$hdmi_2="HDMI-A-2";
$edid_prefix="/sys/devices/platform/gpu/drm";
# END PI4 VARIABLES

$var_dir="/var/lib/PGenerator/";
$pattern_templates="$var_dir/tmp";
$pattern_video="$var_dir/video";
$pattern_images="$var_dir/images";
$pattern_frames="$var_dir/frames";
$video_dir="$var_dir/video";

$pattern_dynamic="PatternDynamic";
$pattern_profile="MeterProfile";
$pattern_position="MeterPosition";
$pattern_screensaver="ScreenSaver";
$pattern_start="PatternStart";
$pattern_calman1="CalmanCustomPattern1";
$pattern_calman2="CalmanCustomPattern2";
$pattern_calman3="CalmanCustomPattern3";
$pattern_calman4="CalmanCustomPattern4";

$upload_tmp_dir="/tmp";

$close_command="QUIT";
$rgb_triplet_command="RGB";
$functions_command="FUNCTIONS";
$video_command="VIDEO";
$save_images_command="SAVEIMAGES";
$get_patternimages_list_command="GETPATTERNIMAGESLIST";
$get_pattern_image_command="GETPATTERNIMAGE";
$get_file_list_command="GETFILELIST";
$upload_file_command="UPLOAD_FILE";
$delete_file_command="DELETE";
$test_template_command="TESTTEMPLATE";
$test_template_ramdisk_command="TESTTEMPLATERAMDISK";
$test_pattern_command="TESTPATTERN";
$pgenerator_executed_command="PGENERATORISEXECUTED";
$restart_pgenerator_command="RESTARTPGENERATOR";
$cmd_pgenerator_command="CMD";
$status_command="GETSTATUS";

$split_images_string=",,,,";

$bg_default="0,0,0";
$res_default="100";
$bits_default=8;
$draw_default="RECTANGLE";
$rgb_default="16,16,16";
$dim_default="640,360";
$position_default="-1,-1";
$text_default="No Text";
$frame_default="1";

$max_x=1920;
$max_y=1080;

$separator=";";


$timeout_client=5;

$osname=$Config{osname};
$archname=$Config{archname};

$is_alive_command="IS_ALIVE";

$get_conf_command="GETCONF";
$set_conf_command="SETCONF";

$banner="**** Device Pattern [$version] ****";

$pattern_generator="/usr/sbin/PGeneratord";

$ok_response="OK";
$error_response="ERR";
$alive_response="ALIVE";
$end_cmd_string="\cB\r";
$end_cmd_string_calman="\x03";
$start_cmd_string_calman="\x02";
$ack_cmd_string="\x06";

$calman_special_pattern{$start_cmd_string_calman."RGB_B:0020,0020,0020,0000"}=$pattern_calman1;
$calman_special_pattern{$start_cmd_string_calman."RGB_B:1000,1000,1000,1020"}=$pattern_calman2;
$calman_special_pattern{$start_cmd_string_calman."RGB_S:0940,0940,0940,018"}=$pattern_calman3;
$calman_special_pattern{$start_cmd_string_calman."RGB_S:0064,0064,0064,018"}=$pattern_calman4;

$calman_bg="0,0,0";
$calman_settings_dirty=0;
$calman_win_size=10;
$calibration_client_ip="";
$calibration_client_software="";

$pattern_plugins="$var_dir/plugins";
$plugin_archive_file="PGenerator-plugin-.*.tar.gz";
$plugin_conf_file="plugin.conf";
$plugin_dir="$upload_tmp_dir/PGenerator-plugin";
$plugin_permitted{"c93dca84b1678a06664954a9ab8c2596"}=1;

$command_file="$var_dir/running/operations.txt";

$info_dir="$var_dir/running/info";

$pattern_stop_command="EXIT";

$sendkey_program="extra_software/WinSendKeys/WinSendKeys.exe";

$client_dir="ClientFunctions";

$pattern_conf_dir="/etc/PGenerator";
$pattern_conf="/etc/PGenerator/PGenerator.conf";

$lut_file="/etc/PGenerator/lut.txt";

$pand_default_file="/etc/default/pand";
$rcPGenerator_dhcpd_default_file="/etc/dhcp/dhcpd.conf.rcPGenerator";
$dhcpd_file="/etc/dhcp/dhcpd.conf";

$discoverable_disabled_file="$pattern_conf_dir/DISCOVERABLE.disabled";
$port_discovery_devicecontrol=1977;
$port_discovery_lightspace=20123;
$reply_discovery_devicecontrol="I am a PGenerator";
$message_discovery_devicecontrol="Who is a PGenerator";

$requested_by_default="EVAL_pattern";

$distro_name="BiasiLinux";
$distro_conf="/etc/$distro_name/packages.conf";

$bash_program_name="/usr/bin/PGenerator_bash.pl";
$bash_action{1}="bash_subscribe";
$bash_action{2}="bash_update";
$bash_action{3}="bash_change_password";
$bash_action{4}="bash_reboot";
$bash_action{5}="bash_shutdown";
$bash_action{6}="exit";

share(%info);

share($w_s);
share($h_s);

share($hdmi_info);
share($preferred_mode);
share(%pgenerator_conf);

share($program_video_to_kill);

share($last_pattern_requested_by);

share($doing_wifi_scan);

share($calman_settings_dirty);
share($calman_win_size);
share($calibration_client_ip);
share($calibration_client_software);

return 1;
