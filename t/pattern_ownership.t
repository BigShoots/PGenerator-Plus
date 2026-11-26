use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
require "$Bin/../usr/share/PGenerator/webui.pm";
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
local $main::_meter_read_file=PGAutomation::base_dir().'/read.json';
my ($execution,$grey,$lut,$dv,$series,$session);
local *main::webui_automation_read_execution=sub {$execution};
local *main::webui_meter_lg_autocal_running=sub {$grey};
local *main::webui_meter_lg_3d_autocal_running=sub {$lut};
local *main::webui_meter_lg_dv_profile_running=sub {$dv};
local *main::webui_meter_series_alive=sub {$series};
local *main::webui_meter_session_alive=sub {$session};
local *main::log=sub {};
for my $owner (qw(batch grey lut dv series read)) {
 ($execution,$grey,$lut,$dv,$series,$session)=(undef,0,0,0,0,0);
 $execution={status=>'running',run_id=>'test'} if $owner eq 'batch';
 $grey=1 if $owner eq 'grey'; $lut=1 if $owner eq 'lut';
 $dv=1 if $owner eq 'dv'; $series=1 if $owner eq 'series';
 if($owner eq 'read') {
  $session=1;
  PGAutomation::write_json_atomic($main::_meter_read_file,{status=>'measuring'});
 }
 for my $name (qw(stop patch stabilization)) {
  my $body=PGAutomation::encode_json({name=>$name});
  my $blocked=PGAutomation::decode_json(main::webui_pattern_request_guard($body,'192.0.2.5'));
  is($blocked->{error_code},'pattern-owned',"$owner protects output from external $name");
  is(main::webui_pattern_request_guard($body,'127.0.0.1'),'',"$owner permits local worker $name");
 }
 like(main::webui_pattern_request_guard('{"name":"stop","only_if_unowned":true}','127.0.0.1'),qr/pattern-owned/,"$owner also rejects automatic completion from a local browser");
}
($execution,$grey,$lut,$dv,$series,$session)=(undef,0,0,0,0,0);
is(main::webui_pattern_request_guard('{"name":"stop"}','192.0.2.5'),'','idle Stop can clear the last patch');
is(main::webui_pattern_request_guard('{"name":"patch"}','192.0.2.5'),'','idle manual patch selection still works');
# Continuous reads follow the operator's patch selection.
($execution,$grey,$lut,$dv,$series,$session)=(undef,0,0,0,0,1);
PGAutomation::write_json_atomic($main::_meter_read_file,{status=>'measuring'});
{
 local $main::_meter_continuous_read=1;
 for my $name (qw(patch stop stabilization)) {
  my $body=PGAutomation::encode_json({name=>$name});
  is(main::webui_pattern_request_guard($body,'192.0.2.5'),'',"continuous read lets the operator select $name");
 }
 like(main::webui_pattern_request_guard('{"name":"stop","only_if_unowned":true}','127.0.0.1'),qr/pattern-owned/,'continuous read still rejects automatic completion');
 like(main::webui_pattern_request_guard('{"name":"screensaver","only_if_unowned":true}','127.0.0.1'),qr/pattern-owned/,'continuous read still holds off the idle card');
 is(main::webui_display_owner(),'meter reading','continuous read still owns the display');
 $series=1;
 like(main::webui_pattern_request_guard('{"name":"patch"}','192.0.2.5'),qr/pattern-owned/,'a series is protected even after a continuous read');
 $series=0;
}
{
 local $main::_meter_continuous_read=0;
 like(main::webui_pattern_request_guard('{"name":"patch"}','192.0.2.5'),qr/pattern-owned/,'a single read keeps its patch');
}
done_testing();
