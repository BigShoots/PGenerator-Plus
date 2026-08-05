use strict;
use warnings;
use FindBin qw($Bin);

# Keep the PR's standalone hardware-free regression check in the normal test
# suite as well, so future picture-mode changes cannot silently bypass it.
my $script="$Bin/../tools/check_lg_picture_mode_regression.pl";
my $result=do $script;
die $@ if($@);
die "could not run $script: $!" if(!defined($result));
