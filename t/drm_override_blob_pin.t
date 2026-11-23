#!/usr/bin/perl
# Pins the shipped LD_PRELOAD shim blob: the .so in the repo must be an ARM
# hard-float shared object with an era-safe GLIBC ceiling, and it must carry
# the same literal surface as drm_override.c. This catches the stale-blob
# class where drm_override.c changes and the prebuilt .so silently ships the
# old shim (the pre-unity blob rewrote the renderer's wire 3 back to 1).
# Behavioral proof of the ==3 passthrough is on-device (bench acceptance);
# here we pin structure so a stale blob cannot ship unnoticed.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use Config;

my $so = "$Bin/../usr/lib/drm_override.so";
my $c  = "$Bin/../usr/lib/drm_override.c";
plan skip_all => "missing usr/lib/drm_override.*" unless -f $so && -f $c;

sub slurp_raw { my ($p)=@_; open my $fh,'<:raw',$p or die "$p: $!"; local $/; <$fh> }

my $b = slurp_raw($so);
ok(length($b) > 4096, 'blob is non-trivial ('.length($b).' bytes)');

# ELF32 little-endian ARM shared object (Pi runtime ABI).
is(substr($b,0,4), "\x7fELF", 'ELF magic');
my ($ei_class,$ei_data) = (ord substr($b,4,1), ord substr($b,5,1));
is($ei_class, 1, 'ELFCLASS32');
is($ei_data,  1, 'little-endian');
my ($e_type,$e_machine) = (unpack('v',substr($b,16,2)), unpack('v',substr($b,18,2)));
is($e_type, 3, 'ET_DYN (shared object)');
is($e_machine, 40, 'EM_ARM');
my $flags = unpack('V',substr($b,36,4));
ok(($flags & 0x400) && ($flags & 0x600) == 0x400, 'EABI5 + hard-float ABI (EF_ARM_EABI_VER5|EF_ARM_ABI_FLOAT_HARD)');

# Era ceiling: the Pi's glibc is 2.21 — nothing newer than GLIBC_2.4 may be required.
SKIP: {
    my $readelf = `command -v readelf 2>/dev/null`;
    chomp $readelf;
    skip 'readelf not available', 1 unless $readelf;
    my $ver = `$readelf -V '$so' 2>/dev/null`;
    my @need = $ver =~ /Name:\s+(GLIBC_[\d.]+)/g;
    my @bad = grep { my @v = split /\./, (split /_/)[1]; ($v[0] > 2 || ($v[0] == 2 && $v[1] > 4)) } @need;
    is_deeply(\@bad, [], 'no GLIBC symbol newer than 2.4 (required: '.(@need ? join(',', @need) : 'none').')');
}

# Literal-surface parity: every log-literal the shim writes must also exist in
# the blob it was compiled from. Source-side additions that skip the blob
# rebuild trip this immediately. C escapes are resolved for the comparison.
my $c_src = slurp_raw($c);
my @lits = do { my @m = ($c_src =~ /"(DRM_OVERRIDE:[^"]*)"/g); my %u; grep { !$u{$_}++ }
    map { my $s = $_; $s =~ s/\\n/\n/g; $s =~ s/\\t/\t/g; $s =~ s/\\\\/\\/g; $s } @m };
ok(@lits >= 5, 'extracted '.scalar(@lits).' shim literals from source');
my @missing = grep { index($b, $_) < 0 } @lits;
is_deeply(\@missing, [], 'every shim source literal present in blob (stale-blob check)');

# The unity gate's decision literal is a comment, not a string, so pin it in
# the source: value 3 (Reserved = Limited passthrough) must satisfy Limited (1).
like($c_src, qr/if\s*\(\s*\*value\s*==\s*3\s*&&\s*rgb_qr_override\s*==\s*1\s*\)\s*\n?\s*return/s,
    'override_rgb_qr passes wire 3 through under Limited conf');

# Self-heal guard: if a cross toolchain is present here, the blob must be
# recompilable from this source (syntax gate against source/blob divergence).
my $xcc = `command -v arm-linux-gnueabihf-gcc 2>/dev/null`;
chomp $xcc;
SKIP: {
    skip 'arm-linux-gnueabihf-gcc not installed', 1 unless $xcc;
    my $out = "$so.crosscheck.$Config{pid}.tmp";
    my $rc = system("$xcc -shared -fPIC -O2 -o '$out' '$c' 2>/dev/null");
    my $okc = ($rc == 0 && -s $out);
    unlink $out;
    ok($okc, 'blob source recompiles with the cross toolchain');
}

done_testing();
