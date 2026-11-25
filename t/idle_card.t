#!/usr/bin/perl
# Idle information card: the requested/sent comparison is only as good as the
# readback parsers, so they are exercised on the connector listing and debugfs
# text the Pi 4 actually prints, plus the level, hop and argument rules.
use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGIdleCard qw(
 parse_modetest_connectors parse_debugfs_active_mode parse_hdmi_packet_config
 decode_hdr_output_metadata requested_signal sent_signal card_model model_signature
 text_levels hop_positions convert_arguments sequence_pattern picture_mode_label
);

# HDR10 metadata as the renderer sets it: PQ, P3-D65, 1000/0.005 nits, 1000/400.
my $blob=unpack("H*",pack("V C C v12",0,2,0,34000,16000,13250,34500,7500,3000,15635,16450,1000,50,1000,400));
my $hdr_lines=join("",map { "\t\t\t$_\n" } ($blob=~/(.{1,32})/g));
my $listing=<<"LIST";
trying to open device 'vc4'...done
Connectors:
id\tencoder\tstatus\t\tname\t\tsize (mm)\tmodes\tencoders
33\t32\tconnected\tHDMI-A-1       \t1600x900\t\t45\t32
  modes:
  #0 1920x1080 24.00 1920 2558 2602 2750 1080 1084 1089 1125 74250 flags: phsync, pvsync; type: driver
  props:
\t38 Colorimetry:
\t\tflags: enum
\t\tenums: Default=0 SMPTE_170M_YCC=1 BT709_YCC=2 BT2020_RGB=9 BT2020_YCC=10
\t\tvalue: 10
\t41 max bpc:
\t\tflags: range
\t\tvalues: 8 12
\t\tvalue: 10
\t42 active pixel rate:
\t\tflags: range
\t\tvalues: 0 4294967295
\t\tvalue: 185625000
\t43 active color format:
\t\tflags: enum
\t\tenums: RGB444=0 YCbCr444=1 YCbCr422=2 YCbCr420=3
\t\tvalue: 1
\t44 rgb quant range:
\t\tflags: enum
\t\tenums: Default=0 Limited [16-235]=1 Full [0-255]=2 Reserved=3
\t\tvalue: 1
\t7 HDR_OUTPUT_METADATA:
\t\tflags: blob
\t\tblobs:

\t\tvalue:
$hdr_lines\t8 DOVI_OUTPUT_METADATA:
\t\tflags: blob
\t\tblobs:

\t\tvalue:
46\t0\tdisconnected\tHDMI-A-2       \t0x0\t\t0\t45
  props:
LIST
my $state=<<'STATE';
crtc[80]: crtc-2
	enable=0
	mode: "": 0 0 0 0 0 0 0 0 0 0 0x0 0x0
crtc[87]: crtc-3
	enable=1
	active=1
	mode: "1920x1080": 24 74250 1920 2558 2602 2750 1080 1084 1089 1125 0x40 0x5
STATE

my $connectors=parse_modetest_connectors($listing);
is($connectors->{"HDMI-A-1"}{status},"connected","connected HDMI port found");
is($connectors->{"HDMI-A-1"}{props}{"max bpc"}{value},"10","range property value read");
is($connectors->{"HDMI-A-1"}{props}{Colorimetry}{enums}{10},"BT2020_YCC","enum names kept");
is($connectors->{"HDMI-A-2"}{status},"disconnected","second port kept separately");
my $meta=decode_hdr_output_metadata($connectors->{"HDMI-A-1"}{props}{HDR_OUTPUT_METADATA}{blob});
is($meta->{eotf},2,"blob EOTF is PQ");
is_deeply([@{$meta}{qw(max_luminance max_cll max_fall)}],[1000,1000,400],"light levels decoded");
ok(abs($meta->{min_luminance}-0.005) < 1e-9,"minimum luminance in 0.0001-nit units");

my $mode=parse_debugfs_active_mode($state);
is_deeply([@{$mode}{qw(w h interlaced)}],[1920,1080,0],"enabled CRTC mode read, disabled CRTC skipped");
ok(abs($mode->{refresh}-24) < 1e-6,"refresh from pixel clock and totals");
my $packets=parse_hdmi_packet_config("  HDMI_RAM_PACKET_CONFIG = 0x0001008c\n");
is_deeply([@{$packets}{qw(avi hdr vendor)}],[1,1,0],"AVI and HDR packet slots decoded");

my $sent=sent_signal(mode=>$mode,connector=>$connectors->{"HDMI-A-1"},packets=>$packets);
is($sent->{mode_label},"HDR10","HDR packet plus PQ blob reads as HDR10");
is($sent->{bits},"10-bit","doubled pixel rate folds back to 10-bit deep colour");
is($sent->{primaries},"DCI-P3 D65","primaries matched as a set");
is($sent->{mastering},"1000 / 0.005 nits","mastering text");
my $stale=sent_signal(mode=>$mode,connector=>$connectors->{"HDMI-A-1"},packets=>parse_hdmi_packet_config("HDMI_RAM_PACKET_CONFIG = 0x0001000c"));
is($stale->{mode_label},"SDR","a blob left on the connector without the HDR packet is not HDR");

my %conf=(signal_mode=>"hdr10",color_format=>1,max_bpc=>10,rgb_quant_range=>1,colorimetry=>9,
 primaries=>2,max_luma=>1000,min_luma=>0.005,max_cll=>1000,max_fall=>400);
my $requested=requested_signal(\%conf,"MODETEST (30) YCbCr444 limited 16:9, 1920x1080 @ 24.00HzHz");
my $model=card_model($requested,$sent,{generator=>"PGenerator+ 2.12.2 at 192.0.2.10"});
is($model->{mismatches},0,"matching request and readback report no difference");
is($model->{headline},"HDR10","headline is the sent mode");
my %rows=map { $_->{label} => $_ } @{$model->{rows}};
is($rows{Resolution}{sent},"1920 \x{00D7} 1080 at 24 Hz","resolution text");

$conf{max_bpc}=12;
my $differs=card_model(requested_signal(\%conf,"1920x1080 @ 24.00Hz"),$sent,{});
is($differs->{mismatches},1,"a changed request is counted");
like($differs->{footer},qr/differs from the settings in 1 field\./,"footer names the count");
ok((grep { $_->{label} eq "Bit depth" && $_->{differs} } @{$differs->{rows}}),"bit depth row carries the marker");
isnt(model_signature($model),model_signature($differs),"signature follows the content");

my $container=card_model(requested_signal({%conf,color_format=>2,max_bpc=>10},"1920x1080 @ 24.00Hz"),
 {%$sent,format=>"YCbCr 4:2:2",bits=>"12-bit container"},{});
ok(!(grep { $_->{label} eq "Bit depth" && $_->{differs} } @{$container->{rows}}),"4:2:2 container depth is not a mismatch");
my $hlg=card_model(requested_signal({%conf,signal_mode=>"hlg",max_bpc=>10},"1920x1080 @ 24.00Hz"),
 {%$sent,mode_label=>"HLG",transfer=>"HLG",primaries=>"None"},{});
is($hlg->{mismatches},0,"HLG without primaries is not a mismatch");
my $dv=card_model(requested_signal({signal_mode=>"dv",dv_transport=>"lldv"},"1920x1080 @ 24.00Hz"),
 {readable=>1,mode_label=>"Dolby Vision",transfer=>"Dolby Vision",dv_metadata=>"Attached",w=>1920,h=>1080,refresh=>24},{});
ok(!(grep { $_->{label} eq "Signal" && $_->{differs} } @{$dv->{rows}}),"sent Dolby Vision satisfies a low-latency request");
my $unread=card_model($requested,{readable=>0},{});
like($unread->{footer},qr/could not be read/,"unreadable driver is said, not guessed");
is($unread->{mismatches},0,"unknown values are never mismatches");

my $missing=sent_signal(connector=>{props=>{}});
my $partial=card_model($requested,$missing,{});
is($partial->{mismatches},0,"missing metadata properties do not invent SDR mismatches");
ok(!defined($missing->{mode_label}) && !defined($missing->{dv_metadata}),"missing signal and DV metadata stay unknown");
my $truncated=sent_signal(connector=>{props=>{
 HDR_OUTPUT_METADATA=>{blob=>'',value=>undef},DOVI_OUTPUT_METADATA=>{blob=>'',value=>undef},
}});
ok(!defined($truncated->{mode_label}),"properties cut off before their values stay unknown");
my $empty_listing=$listing;
$empty_listing=~s/\Q$hdr_lines\E//;
my $sdr=sent_signal(connector=>parse_modetest_connectors($empty_listing)->{'HDMI-A-1'});
is($sdr->{mode_label},'SDR',"successfully read empty metadata still identifies SDR");
my $dv_connector={props=>{DOVI_OUTPUT_METADATA=>{blob=>'01000000'}}};
is(sent_signal(connector=>$dv_connector,packets=>{vendor=>1,hdr=>0})->{mode_label},'Dolby Vision',"enabled vendor packet carries the attached DV metadata");
my $disabled_dv=sent_signal(connector=>$dv_connector,packets=>{vendor=>0,hdr=>0});
is($disabled_dv->{mode_label},'SDR',"stale DV metadata with a disabled packet is not a Dolby Vision signal");
is($disabled_dv->{dv_metadata},'Attached',"attached metadata remains distinct from transmitted signal");
my $unread_hdr=sent_signal(connector=>{props=>{}},packets=>{vendor=>0,hdr=>1});
ok(!defined($unread_hdr->{mode_label}),"an active HDR packet with unreadable EOTF does not become SDR");
my $default_range=sent_signal(connector=>{props=>{'active color format'=>{value=>0},'rgb quant range'=>{value=>0}}});
ok(!defined($default_range->{range}),"driver-default RGB range is not guessed as limited");
# Issue 74: on the RQ3V1 unity-CSC kernel the renderer drives wire value 3
# (RESERVED = Limited signalling, CSC disabled). It must label Limited like
# value 1, or the idle card's measured range goes blank under a live renderer.
my $unity_range=sent_signal(connector=>{props=>{'active color format'=>{value=>0},'rgb quant range'=>{value=>3}}});
is($unity_range->{range},'Limited',"unity wire value 3 reads as Limited on the idle card");
my $unity_ycbcr=sent_signal(connector=>{props=>{'active color format'=>{value=>1},'rgb quant range'=>{value=>3}}});
is($unity_ycbcr->{range},'Limited',"YCbCr with wire 3 stays Limited whatever the RGB property says");
my $full_range=sent_signal(connector=>{props=>{'active color format'=>{value=>0},'rgb quant range'=>{value=>2}}});
is($full_range->{range},'Full',"full range still reads Full next to the unity branch");
my $pi5_listing=$listing;
$pi5_listing=~s/Colorimetry:/Colorspace:/;
$pi5_listing=~s/active color format:/output format:/;
my $pi5=sent_signal(mode=>$mode,connector=>parse_modetest_connectors($pi5_listing)->{'HDMI-A-1'},packets=>$packets);
is($pi5->{colorimetry},'BT.2020','Pi 5 Colorspace property supplies colourimetry');
is($pi5->{format},'YCbCr 4:4:4','Pi 5 output format fallback remains supported');
my $interlaced=card_model($requested,{%$sent,interlaced=>1},{});
ok((grep { $_->{label} eq 'Resolution' && $_->{differs} } @{$interlaced->{rows}}),"progressive and interlaced timings disagree even with equal dimensions and refresh");

is_deeply(text_levels("sdr"),{value=>143,label=>105,black=>0},"SDR codes against a 100-nit white");
is(text_levels("hdr10")->{value},96,"HDR10 value code is PQ 25 nits");
is(text_levels("hlg")->{value},95,"HLG value code on a 1000-nit display");
is_deeply(text_levels("dv","standard"),{value=>52,label=>42,black=>16},"measured Dolby Vision tunnel codes");

my @draws=(0.1,0.1,0.9,0.9,0.12,0.1,0.1,0.8,0.8,0.1);
my $positions=hop_positions(1920,1080,800,560,5,sub { @draws ? shift(@draws) : 0.5 });
is(scalar(@$positions),5,"one position per hop");
my ($free_w,$free_h)=(1920-2*57-800,1080-2*32-560);
for my $i (1..$#$positions) {
 my ($a,$b)=@{$positions}[$i-1,$i];
 my $distance=sqrt((($a->[0]-$b->[0])/$free_w)**2+(($a->[1]-$b->[1])/$free_h)**2);
 ok($distance >= 1/3,"hop $i lands at least a third of the free travel away");
}
ok(!(grep { $_->[0] < 0 || $_->[1] < 0 || $_->[0]+800 > 1920 || $_->[1]+560 > 1080 } @$positions),"every hop stays on screen");

my @args=convert_arguments({headline=>"\@/etc/passwd",rows=>[{label=>"TV",requested=>"50%",sent=>"a\\b",differs=>1}],kit=>[]},
 fonts=>{regular=>"r.ttf",bold=>"b.ttf"},levels=>{value=>143,label=>105,black=>0});
ok((grep { $_ eq "label:\\\@/etc/passwd" } @args),"a leading @ cannot make ImageMagick read a file");
ok((grep { /^label:.*50%%/s } @args),"percent escapes are neutralised");
ok((grep { /\x{2260}/ } @args),"a differing row draws the not-equal marker");
ok((grep { /^label:\x{200b}\nTV$/ } @args),'blank header remains anchored above the row labels');
my @matching_args=convert_arguments($model,fonts=>{regular=>"r.ttf",bold=>"b.ttf"});
ok(!(grep { /^label:\s*$/ } @matching_args),'matching signals do not render an unsupported whitespace-only marker label');
my $pattern=sequence_pattern(w=>800,h=>560,bg=>"0,0,0",image=>"/tmp/card.png",positions=>[[10,20],[30,40]]);
is(scalar(() = $pattern=~/^FRAME=20000$/mg),2,"twenty seconds per hop");
like($pattern,qr/POSITION=30,40\nIMAGE=\/tmp\/card\.png\nSOURCE_RANGE=FULL\nEND=1/,"frames reuse one image at a new position");
is(picture_mode_label("filmMaker"),"Filmmaker","known LG mode names are readable");
is(picture_mode_label("someNewMode"),"Some new mode","unknown modes are split into words");
done_testing();
