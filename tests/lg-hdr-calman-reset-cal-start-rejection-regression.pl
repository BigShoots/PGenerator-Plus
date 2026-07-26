#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

sub slurp {
 my ($path)=@_;
 open(my $fh,'<',$path) or die "Failed to read $path: $!";
 local $/;
 return <$fh>;
}

my $helper=slurp('usr/sbin/pgenerator-lg');

like(
 $helper,
 qr/sub\s+lg_externalpq_error_is_expected_driver_rejection\b[\s\S]{0,1200}?\{"errorCode"\}[\s\S]{0,300}?ne\s+"20"[\s\S]{0,800}?driver error while executing the command/s,
 'expected externalpq rejection is narrowly fingerprinted as errorCode 20 plus the driver-error text',
);

like(
 $helper,
 qr/lg_hdr_calman_reset_workflow[\s\S]{0,1800}?my\s+\$start_tolerated=\$start_failed\s*&&\s*&lg_externalpq_error_is_expected_driver_rejection\(\$start,\$start_message\)/s,
 'HDR reset identifies the expected CAL_START rejection',
);

like(
 $helper,
 qr/lg_hdr_calman_reset_workflow[\s\S]{0,2200}?failed\s*=>\s*&json_bool\(\$start_failed\s*&&\s*!\$start_tolerated\)[\s\S]{0,200}?tolerated\s*=>\s*&json_bool\(\$start_tolerated\)/s,
 'expected CAL_START rejection is recorded as tolerated rather than failed',
);

like(
 $helper,
 qr/lg_hdr_calman_reset_workflow[\s\S]{0,2600}?if\(\(\$start_failed\s*&&\s*!\$start_tolerated\)\s*\|\|\s*ref\(\$start\)\s*ne\s*"HASH"\)/s,
 'HDR reset still hard-stops on unrelated application failures and malformed or dropped responses',
);

like(
 $helper,
 qr/lg_hdr_calman_reset_workflow[\s\S]{0,3600}?foreach\s+my\s+\$item[\s\S]{0,500}?BRIGHTNESS_UI_DATA/s,
 'HDR reset continues into the reset data sequence after the CAL_START gate',
);

done_testing();
