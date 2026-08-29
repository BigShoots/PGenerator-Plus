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

my $message=lg_message_register("","PIN",1);
my $manifest=$message->{payload}{manifest};
my $signed=$manifest->{signed};
my %outer=map { $_ => 1 } @{$manifest->{permissions}||[]};

is($message->{payload}{pairingType},"PIN","PIN pairing type is preserved");
ok($message->{payload}{forcePairing},"forced pairing is preserved");
is($signed->{appId},"com.pgenerator.remote","generic PGenerator identity is used");
is($signed->{localizedAppNames}{""},"PGenerator","pairing identity has a display name");
ok(!exists($manifest->{signatures}),"blacklisted legacy certificate is not sent");
ok($outer{WRITE_SETTINGS},"picture-settings permission is requested outside signed metadata");
ok($outer{WRITE_NOTIFICATION_ALERT},"notification bridge permission is requested outside signed metadata");
ok($outer{TEST_OPEN} && $outer{TEST_PROTECTED},"legacy pairing permissions remain available");

done_testing();
