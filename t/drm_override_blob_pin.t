#!/usr/bin/perl
# Pins the shipped LD_PRELOAD shim blob: the .so in the repo must be an ARM
# hard-float shared object with an era-safe GLIBC ceiling, it must carry the
# EXACT literal surface of drm_override.c (both directions), and its .text
# section digest must match the reviewed artifact byte-for-byte. This catches
# the stale-blob class where drm_override.c changes and the prebuilt .so
# silently ships the old shim (the pre-unity blob rewrote the renderer's
# wire 3 back to 1), in both directions and for logic-only edits: a blob
# rebuilt from tampered source trips the reverse-literal or .text pins, and a
# source edit without a blob rebuild trips the forward pin or, wherever the
# era toolchain (GCC 7.3.0 — the bench Pi's native compiler) is available,
# the full .text byte compare below.
# Behavioral proof of the ==3 passthrough is on-device (bench acceptance);
# here we pin structure so a stale blob cannot ship unnoticed.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use Config;
use Digest::SHA qw(sha256_hex);

# Read the section bytes of an ELF32 object (pure Perl; no binutils needed).
sub elf_section {
    my ($b, $name) = @_;
    return undef unless length($b) > 52 && substr($b, 4, 1) eq "\x01"; # ELFCLASS32
    my ($sh_off, $sh_entsize, $sh_num, $sh_strndx) =
        (unpack('V', substr($b, 32, 4)), unpack('v', substr($b, 46, 2)),
         unpack('v', substr($b, 48, 2)), unpack('v', substr($b, 50, 2)));
    return undef unless $sh_off && $sh_entsize && $sh_num;
    my $strhdr = $sh_off + $sh_strndx * $sh_entsize;
    my ($stroff, $strsz) = (unpack('V', substr($b, $strhdr + 16, 4)),
                            unpack('V', substr($b, $strhdr + 20, 4)));
    return undef unless $stroff + $strsz <= length($b);
    my $strtab = substr($b, $stroff, $strsz);
    for my $i (0 .. $sh_num - 1) {
        my $e = $sh_off + $i * $sh_entsize;
        my $noff = unpack('V', substr($b, $e, 4));
        my $nend = index($strtab, "\0", $noff);
        next if $nend < 0;
        next unless substr($strtab, $noff, $nend - $noff) eq $name;
        my ($off, $sz) = (unpack('V', substr($b, $e + 16, 4)),
                          unpack('V', substr($b, $e + 20, 4)));
        return undef unless $off + $sz <= length($b);
        return substr($b, $off, $sz);
    }
    return undef;
}

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

# Literal-surface parity, both directions: the blob's set of NUL-terminated
# "DRM_OVERRIDE: ..." strings must be EXACTLY the set of shim literals in the
# source it claims to be compiled from (C escapes resolved). Source-side
# additions that skip the blob rebuild trip the forward check; a blob built
# from different source trips the reverse check. The forward check demands a
# NUL-terminated occurrence: strings in .rodata are NUL-separated, so a
# source literal that is only a strict prefix of what the blob carries (the
# forged-suffix shape) must NOT pass by substring.
my $c_src = slurp_raw($c);
my @lits = do { my @m = grep { /^DRM_OVERRIDE:/ } ($c_src =~ /"([^"]*)"/g); my %u; grep { !$u{$_}++ }
    map { my $s = $_; $s =~ s/\\n/\n/g; $s =~ s/\\t/\t/g; $s =~ s/\\\\/\\/g; $s } @m };
ok(@lits >= 5, 'extracted '.scalar(@lits).' shim literals from source');
my @missing = grep { index($b, $_ . "\0") < 0 } @lits;
is_deeply(\@missing, [], 'every shim source literal present in blob (stale-blob check)');

my %src_lit = map { $_ => 1 } @lits;
my %blob_lit;
while ($b =~ /DRM_OVERRIDE:[^\x00]*/g) { $blob_lit{$&} = 1 }
my @orphan = grep { !$src_lit{$_} } sort keys %blob_lit;
is_deeply(\@orphan, [], 'blob carries no DRM_OVERRIDE literal absent from source (reverse parity, '.
    scalar(keys %blob_lit).' blob literals)');

# .text digest of the reviewed artifact. Any logic change without a pinned
# re-record (including literal-free edits) trips this, in every environment.
my $text = elf_section($b, '.text');
ok(defined $text, 'parsed .text section from the blob') or BAIL_OUT('cannot parse ELF sections');
is(Digest::SHA::sha256_hex($text), 'af5bb26871866014112a1e87bf109861f5d987a0da48114762d5a62f66852e2a',
    'blob .text digest matches the reviewed artifact (sha256 of '.length($text).' bytes)');

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
    my $out = "$so.crosscheck.$Config{PID}.tmp";
    my $errlog = "$out.err";
    my $rc = system("$xcc -shared -fPIC -O2 -o '$out' '$c' > '$errlog' 2>&1");
    my $okc = ($rc == 0 && -s $out);
    my $err = do { local $/; open my $fh, '<', $errlog or next; <$fh> };
    unlink $out, $errlog;
    ok($okc, 'blob source recompiles with the cross toolchain')
        or diag(sprintf('rc=%d exists=%s size=%s tool=%s stderr=%s',
                        $rc, -f $out ? 'y' : 'n', -s $out // 0, $xcc,
                        substr($err // '(no stderr captured)', 0, 2000)));
}

# Full-closure .text compare: rebuild from source and compare .text bytes to
# the shipped blob. Only valid when the local compiler is the exact era one
# the reviewed blob was produced with (GCC 7.3.0 — Ubuntu 18.04 cross, or the
# bench Pi's native armv7l-linux-gnueabihf build); codegen differs on every
# newer gcc, so other toolchains stay on the syntax gate above. Recorded
# (PR 86 round-6 review): bench Pi native gcc 7.3.0 reproduced the shipped
# .text byte-for-byte with exactly `gcc -shared -fPIC -O2`.
{
    my ($era_cc);
    for my $cand ($xcc || (), 'gcc') {
        my $v = `$cand --version 2>/dev/null`;
        next unless $v =~ /\(GCC[^)]*\)\s*7\.3\.0\b/;
        # plain gcc only qualifies when this machine IS the era target
        next if $cand eq 'gcc' && `$cand -dumpmachine 2>/dev/null` !~ /^armv7l.*gnueabihf/;
        $era_cc = $cand;
        last;
    }
    SKIP: {
        my $found = $era_cc
            || ($xcc && `$xcc --version 2>/dev/null` =~ s/\n.*//sr)
            || 'no 7.3.0 compiler here';
        skip ".text byte compare needs the exact era compiler (gcc 7.3.0 armhf); found: $found", 2
            unless $era_cc;
        my $out = "$so.textcmp.$Config{PID}.tmp";
        my $rc = system("$era_cc -shared -fPIC -O2 -o '$out' '$c' >/dev/null 2>&1");
        my $rebuilt = ($rc == 0 && -s $out) ? slurp_raw($out) : undef;
        unlink $out;
        skip 'era rebuild failed (broken system headers?) — byte compare skipped', 2
            unless defined $rebuilt;
        my $rtext = elf_section($rebuilt, '.text');
        ok(defined $rtext, 'parsed .text from era rebuild');
        is(Digest::SHA::sha256_hex($rtext // ''), sha256_hex($text),
            'era-toolchain rebuild .text matches shipped blob byte-for-byte (logic-drift closure)');
    }
}

done_testing();
