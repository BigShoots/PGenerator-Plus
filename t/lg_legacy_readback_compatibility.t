use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

# This test exercises pure classification and readback helpers. Keep it
# loadable on the minimal CI Perl image without the production TLS dependency.
BEGIN {
 package IO::Socket::SSL;
 sub import { }
 $INC{'IO/Socket/SSL.pm'}=__FILE__;
}

my $helper="$Bin/../usr/sbin/pgenerator-lg";
do $helper;
die $@ if($@);
die "Failed to load $helper" if(!defined(&lg_generation_info));

my @legacy_models=(
 ['OLED65C8PLA',2018],
 ['OLED65C9PLA',2019],
 ['OLED65CXPUA',2020],
 ['OLED65C1AUA',2021],
);

foreach my $case (@legacy_models) {
 my ($model,$year)=@{$case};
 my $generation=lg_generation_info({modelName=>$model},{},{ });
 my $profile=lg_generation_profile($generation);
 ok(!$profile->{readback_supported},"$model does not require LUT readback");
 ok(lg_readback_leniency_ok($generation),"$model accepts an acknowledged write when LUT GET is unavailable");
}

my $unknown=lg_generation_info({},{},{ });
ok($unknown->{ddc_only_white_balance},'an unclassified older TV uses the conservative DDC-only profile');
ok(lg_readback_leniency_ok($unknown),'an unclassified DDC-only TV does not require LUT GET support');

my $modern=lg_generation_info({modelName=>'OLED65G5PUA'},{},{ });
ok(!lg_readback_leniency_ok($modern),'a modern readback-capable TV keeps strict LUT verification');

my $empty_response={type=>'response',payload=>{returnValue=>1,data=>''}};
my $empty_1d={response=>$empty_response,readback_empty=>1};
my $expected_1d=[(0) x 3072];
my $expected_3d=[(0) x (33*33*33*3)];
my $c1=lg_generation_info({modelName=>'OLED65C1AUA'},{},{ });

ok(lg_1d_write_accepted_readback_unavailable_ok($c1,$empty_1d,$expected_1d),
 'C1 accepts an acknowledged 1D write when the TV returns no LUT samples');
ok(lg_3d_write_accepted_readback_unavailable_ok($c1,0,undef,$empty_response,$expected_3d),
 'C1 accepts an acknowledged 3D write when the TV returns no LUT samples');
ok(!lg_1d_write_accepted_readback_unavailable_ok($modern,$empty_1d,$expected_1d),
 'modern 1D upload still requires supported readback');
ok(!lg_3d_write_accepted_readback_unavailable_ok($modern,0,undef,$empty_response,$expected_3d),
 'modern 3D upload still requires supported readback');

my ($missing_failed)=response_is_app_failure_or_missing(undef);
ok($missing_failed,'a missing destructive-write reply is never treated as accepted');
my ($weak_failed)=response_is_app_failure_or_missing({type=>'response',payload=>{}});
ok(!$weak_failed,'a real legacy response envelope may omit returnValue on non-session data steps');

ok(!lg_calibration_start_confirmed(undef),'missing CAL_START remains unconfirmed');
ok(!lg_calibration_end_confirmed(undef,0,0),'missing CAL_END remains unconfirmed');

done_testing();
