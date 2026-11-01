#
# PGSelfTestCheck.pm - expected infoframe fields and codes for the signal
# self-test (usr/bin/pgen_selftest.pl). Pure functions: no I/O, so t/ can
# judge real captures with them.
#
# Sources:
#  - AVI InfoFrame layout: CTA-861-G 6.4 (Tables 8-14), as the kernel log
#    prints it (82 02 0d PB0 PB1 ...).
#  - AVI colorimetry: the renderer's AviColorimetryForFormat() and its HDR
#    and Dolby Vision branches (ofxRPI4Window.cpp), then linux 5.10.89
#    drm_hdmi_avi_infoframe_colorspace() / hdmi_colorimetry_val[] (the Pi's
#    kernel): property values past BT2020_YCC (10) go out as No Data.
#  - VIC: linux 5.10.89 drm_match_cea_mode() over edid_cea_modes_1/_193, as
#    the renderer carries it in src/ofxRPI4Window/src/cea_vic.h
#    (t/selftest_check.t keeps both tables equal). drm_mode_cea_vic() sends
#    VIC 0 for the HDMI 1.4b 4K modes (their VIC goes in the HDMI VSIF) and
#    for VICs above 64 to a sink that is not HDMI 2.0.
#  - Dynamic Range and Mastering InfoFrame: CTA-861-G 6.9 (Tables 42-45),
#    primaries in 0.00002, max luminance in 1 cd/m2, min in 0.0001 cd/m2;
#    filled as the renderer's updateHDR_Infoframe() does (HLG: EOTF 3,
#    metadata not provided, all zero).
#  - Y'CbCr codes: ITU-R BT.601-7 / BT.709-6 / BT.2020-2 / BT.2100-2 (Table 9),
#    round half away from zero.
#
package PGSelfTestCheck;
use strict;
use warnings;

# CTA-861 VIC timings: vic, clock (kHz), h display/sync start/sync end/total,
# v display/sync start/sync end/total, DRM_MODE_FLAG_* bits.
our @CEA_VICS=(
 [1,25175,640,656,752,800,480,490,492,525,0xa],[2,27000,720,736,798,858,480,489,495,525,0xa],
 [3,27000,720,736,798,858,480,489,495,525,0xa],[4,74250,1280,1390,1430,1650,720,725,730,750,0x5],
 [5,74250,1920,2008,2052,2200,1080,1084,1094,1125,0x15],
 [6,13500,720,739,801,858,480,488,494,525,0x101a],[7,13500,720,739,801,858,480,488,494,525,0x101a],
 [8,13500,720,739,801,858,240,244,247,262,0x100a],[9,13500,720,739,801,858,240,244,247,262,0x100a],
 [10,54000,2880,2956,3204,3432,480,488,494,525,0x1a],
 [11,54000,2880,2956,3204,3432,480,488,494,525,0x1a],
 [12,54000,2880,2956,3204,3432,240,244,247,262,0xa],
 [13,54000,2880,2956,3204,3432,240,244,247,262,0xa],
 [14,54000,1440,1472,1596,1716,480,489,495,525,0xa],
 [15,54000,1440,1472,1596,1716,480,489,495,525,0xa],
 [16,148500,1920,2008,2052,2200,1080,1084,1089,1125,0x5],
 [17,27000,720,732,796,864,576,581,586,625,0xa],[18,27000,720,732,796,864,576,581,586,625,0xa],
 [19,74250,1280,1720,1760,1980,720,725,730,750,0x5],
 [20,74250,1920,2448,2492,2640,1080,1084,1094,1125,0x15],
 [21,13500,720,732,795,864,576,580,586,625,0x101a],
 [22,13500,720,732,795,864,576,580,586,625,0x101a],
 [23,13500,720,732,795,864,288,290,293,312,0x100a],
 [24,13500,720,732,795,864,288,290,293,312,0x100a],
 [25,54000,2880,2928,3180,3456,576,580,586,625,0x1a],
 [26,54000,2880,2928,3180,3456,576,580,586,625,0x1a],
 [27,54000,2880,2928,3180,3456,288,290,293,312,0xa],
 [28,54000,2880,2928,3180,3456,288,290,293,312,0xa],
 [29,54000,1440,1464,1592,1728,576,581,586,625,0xa],
 [30,54000,1440,1464,1592,1728,576,581,586,625,0xa],
 [31,148500,1920,2448,2492,2640,1080,1084,1089,1125,0x5],
 [32,74250,1920,2558,2602,2750,1080,1084,1089,1125,0x5],
 [33,74250,1920,2448,2492,2640,1080,1084,1089,1125,0x5],
 [34,74250,1920,2008,2052,2200,1080,1084,1089,1125,0x5],
 [35,108000,2880,2944,3192,3432,480,489,495,525,0xa],
 [36,108000,2880,2944,3192,3432,480,489,495,525,0xa],
 [37,108000,2880,2928,3184,3456,576,581,586,625,0xa],
 [38,108000,2880,2928,3184,3456,576,581,586,625,0xa],
 [39,72000,1920,1952,2120,2304,1080,1126,1136,1250,0x19],
 [40,148500,1920,2448,2492,2640,1080,1084,1094,1125,0x15],
 [41,148500,1280,1720,1760,1980,720,725,730,750,0x5],[42,54000,720,732,796,864,576,581,586,625,0xa],
 [43,54000,720,732,796,864,576,581,586,625,0xa],[44,27000,720,732,795,864,576,580,586,625,0x101a],
 [45,27000,720,732,795,864,576,580,586,625,0x101a],
 [46,148500,1920,2008,2052,2200,1080,1084,1094,1125,0x15],
 [47,148500,1280,1390,1430,1650,720,725,730,750,0x5],[48,54000,720,736,798,858,480,489,495,525,0xa],
 [49,54000,720,736,798,858,480,489,495,525,0xa],[50,27000,720,739,801,858,480,488,494,525,0x101a],
 [51,27000,720,739,801,858,480,488,494,525,0x101a],[52,108000,720,732,796,864,576,581,586,625,0xa],
 [53,108000,720,732,796,864,576,581,586,625,0xa],[54,54000,720,732,795,864,576,580,586,625,0x101a],
 [55,54000,720,732,795,864,576,580,586,625,0x101a],[56,108000,720,736,798,858,480,489,495,525,0xa],
 [57,108000,720,736,798,858,480,489,495,525,0xa],[58,54000,720,739,801,858,480,488,494,525,0x101a],
 [59,54000,720,739,801,858,480,488,494,525,0x101a],
 [60,59400,1280,3040,3080,3300,720,725,730,750,0x5],
 [61,74250,1280,3700,3740,3960,720,725,730,750,0x5],
 [62,74250,1280,3040,3080,3300,720,725,730,750,0x5],
 [63,297000,1920,2008,2052,2200,1080,1084,1089,1125,0x5],
 [64,297000,1920,2448,2492,2640,1080,1084,1089,1125,0x5],
 [65,59400,1280,3040,3080,3300,720,725,730,750,0x5],
 [66,74250,1280,3700,3740,3960,720,725,730,750,0x5],
 [67,74250,1280,3040,3080,3300,720,725,730,750,0x5],
 [68,74250,1280,1720,1760,1980,720,725,730,750,0x5],
 [69,74250,1280,1390,1430,1650,720,725,730,750,0x5],
 [70,148500,1280,1720,1760,1980,720,725,730,750,0x5],
 [71,148500,1280,1390,1430,1650,720,725,730,750,0x5],
 [72,74250,1920,2558,2602,2750,1080,1084,1089,1125,0x5],
 [73,74250,1920,2448,2492,2640,1080,1084,1089,1125,0x5],
 [74,74250,1920,2008,2052,2200,1080,1084,1089,1125,0x5],
 [75,148500,1920,2448,2492,2640,1080,1084,1089,1125,0x5],
 [76,148500,1920,2008,2052,2200,1080,1084,1089,1125,0x5],
 [77,297000,1920,2448,2492,2640,1080,1084,1089,1125,0x5],
 [78,297000,1920,2008,2052,2200,1080,1084,1089,1125,0x5],
 [79,59400,1680,3040,3080,3300,720,725,730,750,0x5],
 [80,59400,1680,2908,2948,3168,720,725,730,750,0x5],
 [81,59400,1680,2380,2420,2640,720,725,730,750,0x5],
 [82,82500,1680,1940,1980,2200,720,725,730,750,0x5],
 [83,99000,1680,1940,1980,2200,720,725,730,750,0x5],
 [84,165000,1680,1740,1780,2000,720,725,730,825,0x5],
 [85,198000,1680,1740,1780,2000,720,725,730,825,0x5],
 [86,99000,2560,3558,3602,3750,1080,1084,1089,1100,0x5],
 [87,90000,2560,3008,3052,3200,1080,1084,1089,1125,0x5],
 [88,118800,2560,3328,3372,3520,1080,1084,1089,1125,0x5],
 [89,185625,2560,3108,3152,3300,1080,1084,1089,1125,0x5],
 [90,198000,2560,2808,2852,3000,1080,1084,1089,1100,0x5],
 [91,371250,2560,2778,2822,2970,1080,1084,1089,1250,0x5],
 [92,495000,2560,3108,3152,3300,1080,1084,1089,1250,0x5],
 [93,297000,3840,5116,5204,5500,2160,2168,2178,2250,0x5],
 [94,297000,3840,4896,4984,5280,2160,2168,2178,2250,0x5],
 [95,297000,3840,4016,4104,4400,2160,2168,2178,2250,0x5],
 [96,594000,3840,4896,4984,5280,2160,2168,2178,2250,0x5],
 [97,594000,3840,4016,4104,4400,2160,2168,2178,2250,0x5],
 [98,297000,4096,5116,5204,5500,2160,2168,2178,2250,0x5],
 [99,297000,4096,5064,5152,5280,2160,2168,2178,2250,0x5],
 [100,297000,4096,4184,4272,4400,2160,2168,2178,2250,0x5],
 [101,594000,4096,5064,5152,5280,2160,2168,2178,2250,0x5],
 [102,594000,4096,4184,4272,4400,2160,2168,2178,2250,0x5],
 [103,297000,3840,5116,5204,5500,2160,2168,2178,2250,0x5],
 [104,297000,3840,4896,4984,5280,2160,2168,2178,2250,0x5],
 [105,297000,3840,4016,4104,4400,2160,2168,2178,2250,0x5],
 [106,594000,3840,4896,4984,5280,2160,2168,2178,2250,0x5],
 [107,594000,3840,4016,4104,4400,2160,2168,2178,2250,0x5],
 [108,90000,1280,2240,2280,2500,720,725,730,750,0x5],
 [109,90000,1280,2240,2280,2500,720,725,730,750,0x5],
 [110,99000,1680,2490,2530,2750,720,725,730,750,0x5],
 [111,148500,1920,2558,2602,2750,1080,1084,1089,1125,0x5],
 [112,148500,1920,2558,2602,2750,1080,1084,1089,1125,0x5],
 [113,198000,2560,3558,3602,3750,1080,1084,1089,1100,0x5],
 [114,594000,3840,5116,5204,5500,2160,2168,2178,2250,0x5],
 [115,594000,4096,5116,5204,5500,2160,2168,2178,2250,0x5],
 [116,594000,3840,5116,5204,5500,2160,2168,2178,2250,0x5],
 [117,1188000,3840,4896,4984,5280,2160,2168,2178,2250,0x5],
 [118,1188000,3840,4016,4104,4400,2160,2168,2178,2250,0x5],
 [119,1188000,3840,4896,4984,5280,2160,2168,2178,2250,0x5],
 [120,1188000,3840,4016,4104,4400,2160,2168,2178,2250,0x5],
 [121,396000,5120,7116,7204,7500,2160,2168,2178,2200,0x5],
 [122,396000,5120,6816,6904,7200,2160,2168,2178,2200,0x5],
 [123,396000,5120,5784,5872,6000,2160,2168,2178,2200,0x5],
 [124,742500,5120,5866,5954,6250,2160,2168,2178,2475,0x5],
 [125,742500,5120,6216,6304,6600,2160,2168,2178,2250,0x5],
 [126,742500,5120,5284,5372,5500,2160,2168,2178,2250,0x5],
 [127,1485000,5120,6216,6304,6600,2160,2168,2178,2250,0x5],
 [193,1485000,5120,5284,5372,5500,2160,2168,2178,2250,0x5],
 [194,1188000,7680,10232,10408,11000,4320,4336,4356,4500,0x5],
 [195,1188000,7680,10032,10208,10800,4320,4336,4356,4400,0x5],
 [196,1188000,7680,8232,8408,9000,4320,4336,4356,4400,0x5],
 [197,2376000,7680,10232,10408,11000,4320,4336,4356,4500,0x5],
 [198,2376000,7680,10032,10208,10800,4320,4336,4356,4400,0x5],
 [199,2376000,7680,8232,8408,9000,4320,4336,4356,4400,0x5],
 [200,4752000,7680,9792,9968,10560,4320,4336,4356,4500,0x5],
 [201,4752000,7680,8032,8208,8800,4320,4336,4356,4500,0x5],
 [202,1188000,7680,10232,10408,11000,4320,4336,4356,4500,0x5],
 [203,1188000,7680,10032,10208,10800,4320,4336,4356,4400,0x5],
 [204,1188000,7680,8232,8408,9000,4320,4336,4356,4400,0x5],
 [205,2376000,7680,10232,10408,11000,4320,4336,4356,4500,0x5],
 [206,2376000,7680,10032,10208,10800,4320,4336,4356,4400,0x5],
 [207,2376000,7680,8232,8408,9000,4320,4336,4356,4400,0x5],
 [208,4752000,7680,9792,9968,10560,4320,4336,4356,4500,0x5],
 [209,4752000,7680,8032,8208,8800,4320,4336,4356,4500,0x5],
 [210,1485000,10240,11732,11908,12500,4320,4336,4356,4950,0x5],
 [211,1485000,10240,12732,12908,13500,4320,4336,4356,4400,0x5],
 [212,1485000,10240,10528,10704,11000,4320,4336,4356,4500,0x5],
 [213,2970000,10240,11732,11908,12500,4320,4336,4356,4950,0x5],
 [214,2970000,10240,12732,12908,13500,4320,4336,4356,4400,0x5],
 [215,2970000,10240,10528,10704,11000,4320,4336,4356,4500,0x5],
 [216,5940000,10240,12432,12608,13200,4320,4336,4356,4500,0x5],
 [217,5940000,10240,10528,10704,11000,4320,4336,4356,4500,0x5],
 [218,1188000,4096,4896,4984,5280,2160,2168,2178,2250,0x5],
 [219,1188000,4096,4184,4272,4400,2160,2168,2178,2250,0x5],
);

# DRM_MODE_FLAG_INTERLACE, _DBLSCAN; 3D and picture aspect bits are not
# compared (cea_vic_for_mode() in cea_vic.h).
my $FLAG_INTERLACE=0x10;
my $FLAG_DBLSCAN=0x20;
my $FLAG_IGNORE=(0x1f << 14) | (0xf << 19);

sub _vrefresh {
 my ($clock,$htotal,$vtotal,$flags)=@_;
 return 0 if(!$htotal || !$vtotal);
 my ($num,$den)=($clock,$htotal*$vtotal);
 $num*=2 if($flags & $FLAG_INTERLACE);
 $den*=2 if($flags & $FLAG_DBLSCAN);
 return int(($num*1000+int($den/2))/$den);
}

sub _alternate_clock {
 my ($t)=@_;
 my ($clock,$vdisplay,$htotal,$vtotal,$flags)=($t->[1],$t->[6],$t->[5],$t->[9],$t->[10]);
 return $clock if(_vrefresh($clock,$htotal,$vtotal,$flags) % 6 != 0);
 return int(($clock*1001+500)/1000) if($vdisplay == 480 || $vdisplay == 240);
 return int(($clock*1000+500)/1001);
}

# The scanned-out mode from /sys/kernel/debug/dri/N/state: the CRTC that
# drives an HDMI connector. DRM_MODE_FMT: "name": vrefresh clock hdisplay
# hsync_start hsync_end htotal vdisplay vsync_start vsync_end vtotal type
# flags. Returns a hash or undef.
sub crtc_mode_from_state {
 my ($text)=@_;
 return undef if(!defined($text));
 my $crtc;
 while($text=~/^connector\[\d+\]: (HDMI-A-\d+)\n((?:\t.*\n?)*)/mg) {
  my ($name,$body)=($1,$2);
  if($body=~/^\tcrtc=(crtc-\d+)/m) { $crtc=$1; last; }
 }
 return undef if(!defined($crtc));
 return undef if($text!~/^crtc\[\d+\]: \Q$crtc\E\n((?:\t.*\n?)*)/m);
 my $body=$1;
 return undef if($body!~/^\tmode: "([^"]*)": (\d+) (\d+) (\d+) (\d+) (\d+) (\d+) (\d+) (\d+) (\d+) (\d+) 0x([0-9a-f]+) 0x([0-9a-f]+)/m);
 return { name=>$1, vrefresh=>$2, clock=>$3, h=>[$4,$5,$6,$7], v=>[$8,$9,$10,$11], flags=>hex($13), crtc=>$crtc };
}

# VIC of a mode as linux 5.10 drm_match_cea_mode() finds it, 0 for none.
sub cea_vic_for_mode {
 my ($m)=@_;
 return 0 if(!$m || !$m->{clock});
 my $picos=int(1000000000/$m->{clock});
 foreach my $row (@CEA_VICS) {
  my @t=@$row;
  my $clock2=_alternate_clock(\@t);
  next if($picos != int(1000000000/$t[1]) && $picos != int(1000000000/$clock2));
  for(;;) {
   return $t[0] if($m->{h}[0] == $t[2] && $m->{h}[1] == $t[3] && $m->{h}[2] == $t[4] && $m->{h}[3] == $t[5] &&
                   $m->{v}[0] == $t[6] && $m->{v}[1] == $t[7] && $m->{v}[2] == $t[8] && $m->{v}[3] == $t[9] &&
                   (($m->{flags} & ~$FLAG_IGNORE) == ($t[10] & ~$FLAG_IGNORE)));
   # cea_mode_alternate_timings(): 240p/288p with one or two more lines.
   last if(!((($t[0] == 8 || $t[0] == 9 || $t[0] == 12 || $t[0] == 13) && $t[9] < 263) ||
             (($t[0] == 23 || $t[0] == 24 || $t[0] == 27 || $t[0] == 28) && $t[9] < 314)));
   $t[7]++; $t[8]++; $t[9]++;
  }
 }
 return 0;
}

# The AVI VIC against the mode: (ok, info, expect text). VIC 0 instead of
# the CTA VIC is right when the kernel had to leave it out (HDMI 1.4b 4K
# VIC in the HDMI VSIF, VIC > 64 to an HDMI 1.4 sink); whether that applies
# depends on the EDID, so it is reported, not judged.
sub vic_verdict {
 my ($avi_vic,$mode_vic)=@_;
 return (1,0,"VIC $mode_vic") if($avi_vic == $mode_vic);
 if($avi_vic == 0 && ($mode_vic == 93 || $mode_vic == 94 || $mode_vic == 95 || $mode_vic == 98)) {
  return (1,1,"VIC $mode_vic, or 0 with the VIC in the HDMI VSIF");
 }
 return (1,1,"VIC $mode_vic, or 0 for an HDMI 1.4 sink") if($avi_vic == 0 && $mode_vic > 64);
 return (0,0,"VIC $mode_vic");
}

# AVI InfoFrame as the kernel log prints it: 82 02 0d PB0 PB1 .. PB13.
sub avi_fields {
 my ($b)=@_;
 return undef if(ref($b) ne "ARRAY" || @$b < 9 || $b->[0] != 0x82);
 my $len=$b->[2];
 return undef if($len < 5 || @$b < 4+$len);
 my $sum=0;
 $sum+=$b->[$_] for(0..3+$len);
 my @pb=@$b[3..$#$b];
 return { checksum_ok=>(($sum & 0xff) == 0 ? 1 : 0), Y=>($pb[1] >> 5) & 7, C=>($pb[2] >> 6) & 3,
          EC=>($pb[3] >> 4) & 7, Q=>($pb[3] >> 2) & 3, VIC=>$pb[4] & 0x7f, YQ=>($pb[5] >> 6) & 3 };
}

# hdmi_colorimetry_val[] of linux 5.10: Colorspace property -> [C, EC].
my @KERNEL_COLORIMETRY=([0,0],[1,0],[2,0],[3,0],[3,1],[3,2],[3,3],[3,4],[3,5],[3,6],[3,6]);
my %C_NAME=(0=>"No Data",1=>"BT.601",2=>"BT.709");
my %EC_NAME=(0=>"xvYCC601",1=>"xvYCC709",2=>"sYCC601",3=>"opYCC601",4=>"opRGB",5=>"BT.2020 YcCbcCrc",6=>"BT.2020",7=>"DCI-P3");

sub colorimetry_name {
 my ($c,$ec)=@_;
 return "C=$c (".($C_NAME{$c} || "?").")" if($c != 3);
 return "C=3 EC=$ec (".($EC_NAME{$ec} || "?").")";
}

# Expected AVI [C, EC] for a signal mode, link format ("RGB",
# "YCbCr 4:4:4", "YCbCr 4:2:2") and the conf colorimetry (Colorspace
# property value). HDR10, HLG and both Dolby Vision transports are
# BT.2020 (the renderer sets BT2020_RGB/_YCC; standard DV keeps the conf
# value, which the daemon pins to 9 in DV).
sub avi_colorimetry_expect {
 my ($signal_mode,$format,$colorimetry)=@_;
 my $prop;
 if(($signal_mode || "sdr") ne "sdr") {
  $prop=9;
 } else {
  $prop=(defined($colorimetry) && "$colorimetry"=~/^\d+$/) ? int($colorimetry) : 0;
  # AviColorimetryForFormat(): RGB keeps the RGB values, the BT.2020 YCC
  # ones become BT2020_RGB, the rest Default.
  if($format eq "RGB") {
   $prop=($prop == 8 || $prop == 10) ? 9 : ($prop == 0 || $prop == 7 || $prop == 9 || $prop == 11 || $prop == 12) ? $prop : 0;
  }
 }
 return [0,0] if($prop < 0 || $prop > $#KERNEL_COLORIMETRY);
 return [@{$KERNEL_COLORIMETRY[$prop]}];
}

# The matrix a sink decodes Y'CbCr with, from the AVI colorimetry: BT.2020
# for C=3 EC=6, BT.709 for C=2 and xvYCC709, BT.601 for C=1 and the other
# xvYCC/sYCC/opYCC 601 forms (EC=5, BT.2020 constant luminance, is no 3x3
# matrix the renderer could encode: none named); C=0 (No Data) is the default of CTA-861-F
# 5.1: BT.601 below 720 active lines, BT.709 from 720 (vactive unknown:
# none we can name). opRGB and DCI-P3 name no Y'CbCr matrix.
sub ycc_matrix_for {
 my ($c,$ec,$vactive)=@_;
 return "2020" if($c == 3 && $ec == 6);
 return "709" if($c == 2 || ($c == 3 && $ec == 1));
 return "601" if($c == 1 || ($c == 3 && ($ec == 0 || $ec == 2 || $ec == 3)));
 return (($vactive || 0) <= 0) ? "" : ($vactive < 720) ? "601" : "709" if($c == 0);
 return "";
}

my %K=("601"=>[0.299,0.114],"709"=>[0.2126,0.0722],"2020"=>[0.2627,0.0593]);

# Limited-range R'G'B' codes (in_bits) -> limited-range Y'CbCr codes
# (out_bits): [[Y,Cb,Cr], tie]. tie is set when a value sits on .5 before
# rounding, where an exact renderer may legitimately round the other way.
sub ycc_codes {
 my ($rgb,$in_bits,$out_bits,$matrix)=@_;
 my ($kr,$kb)=@{$K{$matrix}};
 my $kg=1-$kr-$kb;
 my $s_in=2**($in_bits-8);
 my @e=map { ($_/$s_in-16)/219 } @$rgb;
 my $ey=$kr*$e[0]+$kg*$e[1]+$kb*$e[2];
 my $ecb=($e[2]-$ey)/(2*(1-$kb));
 my $ecr=($e[0]-$ey)/(2*(1-$kr));
 my $s=2**($out_bits-8);
 my @raw=((219*$ey+16)*$s,(224*$ecb+128)*$s,(224*$ecr+128)*$s);
 my $tie=0;
 foreach my $v (@raw) { $tie=1 if(abs(($v-int($v))-0.5) < 1e-9); }
 return [[map { int($_+0.5) } @raw],$tie];
}

# A 12-bit source code (SOURCE_MAX=4095) as the 10-bit code it is sent
# with: studio range keeps its place, D10 = Round(D12 / 4); full range
# D10 = Round(1023 x D12 / 4095) (BT.2100 Table 9).
sub code12_to_10 {
 my ($code,$full)=@_;
 return $full ? int(($code*1023)/4095+0.5) : int($code/4+0.5);
}

# CIE xy of the conf's primaries choice (index into the renderer's
# DisplayChromacityList): [Rx,Ry,Gx,Gy,Bx,By,Wx,Wy]. 0-4 are standard
# gamuts (BT.709, BT.2020, P3-D65, P3-DCI, P3-D60); 5 has none.
my @PRIMARIES=(
 [0.640,0.330,0.300,0.600,0.150,0.060,0.3127,0.3290],
 [0.708,0.292,0.170,0.797,0.131,0.046,0.3127,0.3290],
 [0.680,0.320,0.265,0.690,0.150,0.060,0.3127,0.3290],
 [0.680,0.320,0.265,0.690,0.150,0.060,0.314,0.351],
 [0.680,0.320,0.265,0.690,0.150,0.060,0.32168,0.33767],
);
our @PRIMARIES_NAME=("BT.709","BT.2020","P3-D65","P3-DCI","P3-D60");

sub _u16 { my $v=shift; $v=0 if($v < 0); $v=65535 if($v > 65535); return ($v & 0xff,($v >> 8) & 0xff); }

# Expected DRM InfoFrame payload PB1..PB26 for EOTF 2 (HDR10, values from
# the conf) or 3 (HLG). undef when the conf names no standard gamut.
sub drm_expect {
 my ($eotf,$conf)=@_;
 return [3,(0) x 25] if($eotf == 3);
 my $idx=$conf->{primaries};
 return undef if(!defined($idx) || "$idx"!~/^\d+$/ || !$PRIMARIES[$idx]);
 my @p=@{$PRIMARIES[$idx]};
 my $num=sub { my ($v,$d)=@_; return (defined($v) && "$v"=~/^\d+(?:\.\d+)?$/) ? $v : $d; };
 my $min=$num->($conf->{min_luma},0.005);
 $min=6.5535 if($min > 6.5535);
 # Display primaries in the order green, blue, red, then white point.
 my @xy=map { int($_*50000+0.5) } @p[2,3,4,5,0,1,6,7];
 return [$eotf,0,(map { _u16($_) } @xy),_u16(int($num->($conf->{max_luma},1000))),_u16(int($min/0.0001+0.5)),
         _u16(int($num->($conf->{max_cll},1000))),_u16(int($num->($conf->{max_fall},400)))];
}

# Packet RAM line of pgen_hdmi_packet: "slot=7 enabled=1 type=87 version=01
# length=1a bytes=PB0:PB1:..". Returns {enabled, type, version, length,
# pb=>[PB1..], checksum_ok} or undef. A slot that is off (its bit in
# HDMI_RAM_PACKET_CONFIG clear) holds whatever is in the RAM, after boot
# random bytes with any length: then {enabled=>0, ...} without pb and
# checksum_ok when the bytes do not make a packet.
sub packet_fields {
 my ($line,$slot)=@_;
 return undef if(!defined($line) || $line!~/^slot=\Q$slot\E enabled=(\d) type=([0-9a-f]{2}) version=([0-9a-f]{2}) length=([0-9a-f]{2}) bytes=([0-9a-f:]*)/m);
 my ($on,$type,$ver,$len,@b)=($1,hex($2),hex($3),hex($4),map { hex($_) } split(/:/,$5));
 if(@b < $len+1) {
  return undef if($on ne "0");
  return { enabled=>$on, type=>$type, version=>$ver, length=>$len, pb=>undef, checksum_ok=>undef };
 }
 my $sum=$type+$ver+$len;
 $sum+=$b[$_] for(0..$len);
 return { enabled=>$on, type=>$type, version=>$ver, length=>$len, pb=>[@b[1..$len]], checksum_ok=>(($sum & 0xff) == 0 ? 1 : 0) };
}

# Field-by-field differences between the DRM payload sent and expected:
# a list of "name sent X, expected Y", empty when they agree.
sub drm_differences {
 my ($pb,$want)=@_;
 my @names=("EOTF","metadata ID");
 my @who=("green x","green y","blue x","blue y","red x","red y","white x","white y","max mastering luminance","min mastering luminance","MaxCLL","MaxFALL");
 my @diff;
 for my $i (0..1) {
  push(@diff,"$names[$i] $pb->[$i], expected $want->[$i]") if(!defined($pb->[$i]) || $pb->[$i] != $want->[$i]);
 }
 for my $k (0..$#who) {
  my $i=2+2*$k;
  my $got=(defined($pb->[$i]) && defined($pb->[$i+1])) ? $pb->[$i]+($pb->[$i+1] << 8) : -1;
  my $exp=$want->[$i]+($want->[$i+1] << 8);
  push(@diff,"$who[$k] $got, expected $exp") if($got != $exp);
 }
 return @diff;
}

1;
