use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

BEGIN {
 package IO::Socket::SSL;
 sub import { }
 $INC{'IO/Socket/SSL.pm'}=__FILE__;
}

my $helper="$Bin/../usr/sbin/pgenerator-lg";
{
 no warnings 'once';
 do $helper;
}
die $@ if($@);
die "Failed to load $helper" if(!defined(&lg_current_input_info));
$SIG{INT}="DEFAULT";
$SIG{TERM}="DEFAULT";

my @requests;
my @responses;
{
 no warnings qw(redefine once);
 *main::lg_request=sub (@) {
  my ($session,$id,$uri,$payload,$timeout)=@_;
  push(@requests,{ id=>$id, uri=>$uri, payload=>$payload, timeout=>$timeout });
  return shift(@responses);
 };
}

@requests=();
@responses=(
 { type=>'response', payload=>{ appId=>'com.webos.app.hdmi2' } },
 { type=>'response', payload=>{ devices=>[
  { id=>'HDMI_1', appId=>'com.webos.app.hdmi1', label=>'Blu-ray' },
  { id=>'HDMI_2', appId=>'com.webos.app.hdmi2', label=>'PGenerator+' },
 ] } },
);
my $info=lg_current_input_info({},5);
ok($info->{current_input_checked},'the foreground source was checked');
ok($info->{current_input_available},'an HDMI source is available');
is($info->{current_input},'hdmi2','the canonical input key is returned');
is($info->{current_input_id},'HDMI_2','the WebOS input ID is returned');
is($info->{current_input_label},'PGenerator+','the TV-assigned input label is returned');
is($info->{current_input_display},'HDMI 2 - PGenerator+','the UI label combines port and TV label');
is_deeply([map { $_->{uri} } @requests],[
 'com.webos.applicationManager/getForegroundAppInfo',
 'tv/getExternalInputList',
],'the helper reads the foreground app then resolves the HDMI label');

@requests=();
@responses=({ type=>'response', payload=>{ appId=>'netflix', title=>'Netflix' } });
$info=lg_current_input_info({},5);
ok($info->{current_input_available},'a foreground app is still a reportable source');
is($info->{current_input},'','an app is not misreported as an HDMI port');
is($info->{current_input_display},'App - Netflix','a non-HDMI foreground source is explicit');
is(scalar(@requests),1,'external inputs are not queried for a native app');

@requests=();
@responses=({ type=>'response', payload=>{} });
$info=lg_current_input_info({},5);
ok($info->{current_input_checked},'an empty foreground response is still a completed check');
ok(!$info->{current_input_available},'an empty response is not presented as an input');
is($info->{current_input_display},'','the UI receives no invented source');

@requests=();
@responses=({ type=>'error', error=>'not permitted' });
$info=lg_current_input_info({},5);
ok($info->{current_input_checked},'a refused foreground request is recorded');
ok(!$info->{current_input_available},'a refused request is unavailable');
like($info->{current_input_message},qr/not permitted/i,'the refusal remains diagnosable');

my $lg_module="$Bin/../usr/share/PGenerator/lg.pm";
open(my $fh,'<',$lg_module) or die "Unable to read $lg_module: $!";
local $/;
my $source=<$fh>;
close($fh);
$source.=do {
 open(my $card,'<:raw',"$Bin/../usr/share/PGenerator/webui-lg-card.html") or die "Unable to read LG card fragment: $!";
 local $/;
 my $content=<$card>;
 close($card);
 $content;
};
$source.=do {
 open(my $js,'<:raw',"$Bin/../usr/share/PGenerator/webui-lg.js") or die "Unable to read LG JavaScript fragment: $!";
 local $/;
 my $content=<$js>;
 close($js);
 $content;
};
like($source,qr/id="lgCurrentInput"/,'the LG card includes the current-input status');
like($source,qr/include_current_input:true/,'the live picture-mode refresh requests current input');
like($source,qr/include_current_input\s*=>\s*\$payload->\{"include_current_input"\}/,'the WebUI forwards the opt-in to the helper');

done_testing();
