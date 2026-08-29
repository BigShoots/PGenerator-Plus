#!/usr/bin/perl

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $helper="$Bin/../usr/sbin/pgenerator-lg";
{
 no warnings 'once';
 do $helper;
}
die $@ if($@);
die "Failed to load $helper" if(!defined(&lg_message_register));

my $c2_message=lg_message_register("","PIN",1,{ deviceOSReleaseVersion => "10.3.1" });
my $c2_manifest=$c2_message->{payload}{manifest};
my %c2_signed=map { $_ => 1 } @{$c2_manifest->{signed}{permissions}||[]};

is($c2_message->{payload}{pairingType},"PIN","PIN pairing type is preserved");
ok($c2_message->{payload}{forcePairing},"forced pairing is preserved");
is($c2_manifest->{signed}{appId},"com.lge.test","pre-webOS 26 TV uses the calibration-capable identity");
ok(ref($c2_manifest->{signatures}) eq "ARRAY","pre-webOS 26 TV receives the legacy certificate");
ok($c2_signed{TEST_SECURE} && $c2_signed{WRITE_SETTINGS},"legacy identity requests calibration permissions");

my $webos26_message=lg_message_register("","PIN",1,{ deviceOSReleaseVersion => "11.0.0" });
my $webos26_manifest=$webos26_message->{payload}{manifest};
my %webos26_outer=map { $_ => 1 } @{$webos26_manifest->{permissions}||[]};

is($webos26_manifest->{signed}{appId},"com.pgenerator.remote","webOS 26 uses the generic PGenerator identity");
is($webos26_manifest->{signed}{localizedAppNames}{""},"PGenerator","generic identity has a display name");
ok(!exists($webos26_manifest->{signatures}),"webOS 26 is not sent the rejected legacy certificate");
ok($webos26_outer{WRITE_SETTINGS},"webOS 26 requests picture-settings permission outside signed metadata");
ok($webos26_outer{WRITE_NOTIFICATION_ALERT},"webOS 26 requests notification bridge permission outside signed metadata");
ok($webos26_outer{TEST_OPEN} && $webos26_outer{TEST_PROTECTED},"generic manifest keeps pairing permissions");

done_testing();
