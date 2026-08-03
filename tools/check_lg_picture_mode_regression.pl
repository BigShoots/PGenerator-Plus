#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

my $path='usr/sbin/pgenerator-lg';
open(my $fh,'<',$path) or die "open $path: $!";
local $/;
my $source=<$fh>;
close($fh);

my ($payload_sub)=$source=~/(sub lg_picture_mode_ssap_payload \(\@\) \{.*?^\})/ms;
ok($payload_sub,'picture-mode SSAP payload helper is present');
{
 package LGPictureModePayloadTest;
 no strict 'refs';
 eval "$payload_sub\n1;" or die $@;
}

is_deeply(
 LGPictureModePayloadTest::lg_picture_mode_ssap_payload('filmMaker'),
 {
  category => 'picture',
  settings => { pictureMode => 'filmMaker' },
 },
 'picture-mode selection uses the minimal public WebOS settings payload',
);

my @matching_subs;
for my $name (qw(
 map_picture_mode_label_to_ddc_name
 lg_picture_mode_signal_for_canonical_name
 lg_picture_mode_signal_compatible
 lg_picture_mode_readback_matches
)) {
 my ($sub)=$source=~/(sub \Q$name\E \(\@\) \{.*?^\})/ms;
 ok($sub,"$name is present");
 push(@matching_subs,$sub||'');
}
{
 package LGPictureModeReadbackTest;
 no strict 'refs';
 eval join("\n",@matching_subs)."\n1;" or die $@;
}
ok(
 LGPictureModeReadbackTest::lg_picture_mode_readback_matches('filmMaker','filmMaker','sdr'),
 'matching SDR picture-mode readback is accepted',
);
ok(
 LGPictureModeReadbackTest::lg_picture_mode_readback_matches('dolbyHdrCinema','dolbyHdrCinemaDark','dv'),
 'equivalent Dolby Vision write and readback names are accepted',
);
ok(
 !LGPictureModeReadbackTest::lg_picture_mode_readback_matches('filmMaker','cinema','sdr'),
 'stale picture-mode readback is rejected',
);

my ($workflow)=$source=~/(sub lg_picture_set_workflow \(\@\) \{.*?^\})/ms;
ok($workflow,'picture-set workflow is present');
like(
 $workflow,
 qr/"settings\/setSystemSettings",\s*\$set_payload/s,
 'picture-mode write uses public SSAP setSystemSettings',
);
unlike(
 $workflow,
 qr/set_picture_mode_active_app|current_app.*picture_mode_only/s,
 'picture-mode write is not diverted through a scoped Luna alert',
);
like(
 $workflow,
 qr/get_picture_mode_after_.*?settings\/getSystemSettings/s,
 'picture-mode selection performs an independent readback',
);
like(
 $workflow,
 qr/picture-mode-readback-mismatch/,
 'missing or stale picture-mode readback is reported as failure',
);

done_testing();
