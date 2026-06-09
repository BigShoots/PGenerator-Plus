#!/usr/bin/env perl
# GCI control plane must not override PGenerator's WebUI signal-mode
# settings. Only primaries and eotf are Calman-controlled on the GCI
# path; everything else (signal_mode, color_format, max_bpc,
# rgb_quant_range, colorimetry) is left to the WebUI conf. The
# drm_override.so library also suppresses its connector-property
# overrides while GCI is active, so the TV/renderer reports win.
# The Calman RPC plugin never sends INIT:2.0 and is unaffected.
use strict;
use warnings;
use Test::More;

sub read_text {
 my ($path)=@_;
 open(my $fh,'<',$path) or die "Failed to read $path: $!";
 local $/;
 return <$fh>;
}

my $daemon=read_text('usr/share/PGenerator/daemon.pm');
my $override=read_text('usr/lib/drm_override.c');
my $rootfs_command=read_text('tools/image-targets/pi4-biasi/rootfs/usr/share/PGenerator/command.pm');
my $rootfs_override=read_text('tools/image-targets/pi4-biasi/rootfs/usr/lib/drm_override.c');

# 1) Rootfs mirror parity: drm_override.c is mirrored to the Pi4 image
#    rootfs (same convention as pi4-hdr-ycbcr-colorimetry-regression.pl).
#    daemon.pm is not mirrored today (no rootfs daemon.pm exists) so we
#    only require drm_override.c parity.
is($rootfs_override,$override,'Pi4 image rootfs drm_override.c matches shared runtime drm_override.c');

# 2) daemon.pm declares a per-connection GCI flag and a helper that
#    mirrors the global active count into PGenerator.conf.
like($daemon,qr{if\(\$pattern_cmd\s*=~\Q/\s*2\.0\E/},'daemon.pm INIT branch detects UPGCI 2.0 handshake');
like($daemon,qr/\$calman_gci\{\$connection\}=1;[\s\S]{0,200}?&calman_set_gci_active\(1\)/,'daemon.pm INIT:2.0 sets per-connection flag and global active flag');
like($daemon,qr/sub\s+calman_set_gci_active\s*\(@\)/,'daemon.pm declares calman_set_gci_active helper');
like($daemon,qr/sub\s+calman_clear_gci_connection\s*\(@\)/,'daemon.pm declares calman_clear_gci_connection helper');

# 3) $calman_save_setting is gated so that GCI connections only
#    save primaries and eotf. Every other key is suppressed with a
#    log line and the function returns without writing PGenerator.conf.
like($daemon,qr{my\s+\$calman_save_setting\s*=\s*sub\s*\{[\s\S]{0,2000}?if\(\$calman_gci\{\$connection\}\s*&&\s*\$conf_key\s*ne\s*"primaries"\s*&&\s*\$conf_key\s*ne\s*"eotf"\)}s,'daemon.pm calman_save_setting gates non-primaries/non-eotf saves on the GCI flag');

# 4) Runtime range overrides are also gated on the GCI flag at every
#    call site in the colon-dispatch (source settings, QRNG, SetRange,
#    CONF_LEVEL:Range, the combined SPECIALTY+CONF_LEVEL:Range path, the
#    RPC CMD rgb_quant_range path, and the DV RGB transport helpers).
my @gated_range_sites=(
 [qr/if\(\$parsed\{range\}\s*ne\s*""\)\s*\{[\s\S]{0,200}?if\(\$calman_gci\{\$connection\}\)/,'source-format range (CONF_FORMAT / COLF) is gated on GCI'],
 [qr/if\(\$calman_gci\{\$connection\}\)\s*\{[\s\S]{0,80}?QRNG ignored/,'QRNG is gated on GCI'],
 [qr/if\(\$calman_gci\{\$connection\}\)\s*\{[\s\S]{0,80}?SetRange=\$range_val ignored/,'SetRange is gated on GCI'],
 [qr/if\(\$calman_gci\{\$connection\}\)\s*\{[\s\S]{0,80}?CONF_LEVEL:Range ignored/,'CONF_LEVEL:Range is gated on GCI'],
 [qr/if\(\$calman_gci\{\$connection\}\)\s*\{[\s\S]{0,80}?SPECIALTY\+CONF_LEVEL:Range ignored/,'combined SPECIALTY+CONF_LEVEL:Range is gated on GCI'],
 [qr/if\(\$calman_gci\{\$connection\}\)\s*\{[\s\S]{0,80}?RPC CMD rgb_quant_range ignored/,'RPC CMD rgb_quant_range is gated on GCI'],
);
for my $site (@gated_range_sites) {
 like($daemon,$site->[0],$site->[1]);
}

# 5) The DV RGB transport helpers (calman_force_dv_rgb,
#    calman_set_dv_rgb) keep their rgb_quant_range runtime override
#    behind a GCI gate.
like($daemon,qr/my\s+\$calman_force_dv_rgb\s*=\s*sub\s*\{[\s\S]{0,1200}?if\(!\$calman_gci\{\$connection\}\)\s*\{[\s\S]{0,200}?apply_source_rgb_quant_range\("calman",2\)/s,'calman_force_dv_rgb runtime rgb_quant_range override is gated on GCI');
like($daemon,qr/my\s+\$calman_set_dv_rgb\s*=\s*sub\s*\{[\s\S]{0,1200}?if\(!\$calman_gci\{\$connection\}\)\s*\{[\s\S]{0,200}?apply_source_rgb_quant_range\("calman",2\)/s,'calman_set_dv_rgb runtime rgb_quant_range override is gated on GCI');

# 6) Connection teardown paths (TERM, SHUTDOWN, QUIT, generic
#    close_connection) all call calman_clear_gci_connection so the
#    global flag drops when the last GCI client leaves.
like($daemon,qr/if\(\$calman\{\$connection\}\s*&&\s*\$key=~\/TERM\/\)\s*\{[\s\S]{0,400}?&calman_clear_gci_connection\(\$connection\)/,'TERM calls calman_clear_gci_connection');
like($daemon,qr/if\(\$clean_key\s*eq\s*"SHUTDOWN"\s*\|\|\s*\$clean_key\s*eq\s*"QUIT"\)\s*\{[\s\S]{0,400}?&calman_clear_gci_connection\(\$connection\)/,'SHUTDOWN/QUIT call calman_clear_gci_connection');
like($daemon,qr/delete\s+\$rpc_client\{\$connection\};[\s\S]{0,80}?&calman_clear_gci_connection\(\$connection\)/,'close_connection calls calman_clear_gci_connection after the per-connection teardown');

# 7) Pattern commands (RGB_S / RGB_B / RGB_A / CommandRGB) and the
#    Calman control plane handshake (SN, CAP, ENABLE PATTERNS, DISABLE
#    PATTERNS, STATUS, FIRMWARE, GET_SETTINGS, IS_ALIVE, UPDATE) are
#    NOT gated — they must still work on GCI.
like($daemon,qr/if\(\$type\s*=~\/RGB_\/\)\s*\{[\s\S]{0,400}?&calman_render_rgb_pattern/,'RGB_S/B/A pattern dispatch still calls calman_render_rgb_pattern');
like($daemon,qr/if\(\$type\s*eq\s*"CommandRGB"\)\s*\{[\s\S]{0,400}?&calman_render_commandrgb_pattern/,'CommandRGB pattern dispatch still calls calman_render_commandrgb_pattern');
like($daemon,qr/if\(\$clean_key\s*eq\s*"ENABLE PATTERNS"/,'ENABLE PATTERNS handshake is unchanged');
like($daemon,qr/if\(\$clean_key\s*eq\s*"SN"\)/,'SN handshake is unchanged');

# 8) drm_override.c reads the calman_gci=1 conf key.
like($override,qr{calman_gci_active\s*=\s*\(p\[11\]\s*==\s*'1'\)\s*\?\s*1\s*:\s*0}s,'drm_override.c parses calman_gci=1 from PGenerator.conf');
like($override,qr/static\s+int\s+calman_gci_active\s*=\s*0;/,'drm_override.c declares calman_gci_active state');

# 9) Every override_* function short-circuits when calman_gci_active
#    is set, with a one-shot log line for debuggability.
for my $name (qw(max_bpc output_fmt colorimetry rgb_qr)) {
 my $fn="override_${name}";
 like($override,qr/static\s+void\s+${fn}\([^)]+\)\s*\{[\s\S]{0,200}?if\s*\(\s*calman_gci_active\s*\)/,"drm_override.c ${fn} short-circuits when Calman GCI is active");
}
like($override,qr/calman_gci_logged\s*=\s*1/,'drm_override.c logs the GCI short-circuit at most once per process');

# 10) RPC path is unchanged: the RPC source-alias handler still has
#     unconditional saves for the RPC aliases (BITDEPTH / COLORSPACE /
#     RANGE / CMD). GCI is orthogonal to RPC.
like($daemon,qr/return\s+0\s+if\(\!\$rpc_client\{\$connection\}\);[\s\S]{0,800}?BITDEPTH.*?max_bpc.*?COLORSPACE/s,'RPC source alias handler is unchanged');
like($daemon,qr/return\s+0\s+if\(\!\$rpc_client\{\$connection\}\);[\s\S]{0,1500}?RANGE/s,'RPC RANGE alias is still inside the RPC-only branch');

# 11) Existing colorimetry / picture-mode mapping regressions stay green.
#     The shared command.pm and rootfs mirror are unchanged by this fix.
is($rootfs_command,read_text('usr/share/PGenerator/command.pm'),'Pi4 image rootfs command.pm matches shared runtime command.pm (untouched by GCI fix)');

done_testing();
