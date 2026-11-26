use strict;
use warnings;
use FindBin qw($Bin);
use Digest::SHA qw(sha256_hex);
use Test::More;

# The Pi 4 renderer ships as a committed binary (usr/sbin/PGeneratord and
# its .dv twin). Releases 2.13.0-2.14.3 advertised renderer fixes (10-bit
# precision, flicker, the #52 log overflow) that never reached a device
# because the binary was not rebuilt from the tree that carried them.
# usr/sbin/PGeneratord.provenance records the binary hash and the source
# hashes it was built from; this test fails as soon as either drifts.

my $root="$Bin/..";
my $manifest="$root/usr/sbin/PGeneratord.provenance";
open(my $fh,'<',$manifest) or BAIL_OUT("cannot open $manifest: $!");
my (%field,@sources);
while(my $line=<$fh>) {
 $line=~s/\r?\n\z//;
 next if $line=~/^\s*(?:#|$)/;
 if($line=~/^source=([0-9a-f]{64}) (\S+)$/) { push @sources,[$1,$2]; next; }
 $field{$1}=$2 if($line=~/^([a-z0-9_]+)=(.*)$/);
}
close($fh);

sub slurp_raw { my $p=shift; open(my $f,'<:raw',$p) or return undef; local $/; my $c=<$f>; close($f); return $c; }

like($field{binary_sha256}||'',qr/^[0-9a-f]{64}$/,'manifest records the binary hash');
ok(@sources>=6,'manifest lists the renderer sources');
for my $name (qw(PGeneratord PGeneratord.dv)) {
 my $bin=slurp_raw("$root/usr/sbin/$name");
 ok(defined($bin),"usr/sbin/$name is present") or next;
 is(sha256_hex($bin),$field{binary_sha256},"usr/sbin/$name is the binary the manifest describes");
}

# Sources are hashed with CR bytes removed so a CRLF checkout agrees with CI.
my @stale;
for my $entry (@sources) {
 my ($want,$path)=@$entry;
 my $src=slurp_raw("$root/$path");
 if(!defined($src)) { push @stale,"$path (missing)"; next; }
 $src=~s/\r//g;
 push @stale,$path if(sha256_hex($src) ne $want);
}
is_deeply(\@stale,[],'renderer sources match the committed binary')
 or diag("Renderer source changed without a rebuild: rebuild usr/sbin/PGeneratord(.dv) "
        ."on the Pi 4 and update usr/sbin/PGeneratord.provenance");

# Every renderer source file is covered, so a new file cannot slip past.
my %listed=map { $_->[1] => 1 } @sources;
my @unlisted;
for my $dir ('src/pattern_generator/src','src/ofxRPI4Window/src') {
 opendir(my $dh,"$root/$dir") or next;
 push @unlisted,map { "$dir/$_" } grep { /\.(?:cpp|h|c)$/ && !$listed{"$dir/$_"} } readdir($dh);
 closedir($dh);
}
is_deeply([sort @unlisted],[],'no renderer source is missing from the manifest');

# BiasiLinux ships the old libstdc++ ABI and GLIBCXX up to 3.4.22; a binary
# built against a newer toolchain links but fails to start on the device.
my $bin=slurp_raw("$root/usr/sbin/PGeneratord")||'';
unlike($bin,qr/St7__cxx11/,'binary uses the pre-C++11 libstdc++ ABI the image provides');
my ($minor)=sort { $b <=> $a } (0,$bin=~/GLIBCXX_3\.4\.(\d+)/g);
cmp_ok($minor,'<=',22,"binary needs at most GLIBCXX_3.4.22 (found 3.4.$minor)");

done_testing();
