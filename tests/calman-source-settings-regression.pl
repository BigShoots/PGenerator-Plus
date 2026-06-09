#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

my $daemon_path='usr/share/PGenerator/daemon.pm';
my $vars_path='usr/share/PGenerator/variables.pm';

do "./$daemon_path" or die "Failed to load $daemon_path: $@ $!";

sub parsed {
 my %result=&calman_parse_source_format_payload(@_);
 return \%result;
}

is_deeply(
 parsed('RGB 8-bit'),
 { color_format=>'0', max_bpc=>'8', range=>'' },
 'RGB 8-bit parses to RGB output and 8bpc'
);

is_deeply(
 parsed('RGB 10-bit'),
 { color_format=>'0', max_bpc=>'10', range=>'' },
 'RGB 10-bit parses to RGB output and 10bpc'
);

is_deeply(
 parsed('YCbCr 4:4:4 10-bit'),
 { color_format=>'1', max_bpc=>'10', range=>'' },
 'YCbCr 4:4:4 10-bit parses to 444 output and 10bpc'
);

is_deeply(
 parsed('YCC444_10'),
 { color_format=>'1', max_bpc=>'10', range=>'' },
 'YCC444_10 parses to 444 output and 10bpc'
);

is_deeply(
 parsed('Resolution=1920x1080,Refresh=24,1_FORMAT=RGB 8-bit,Range=Limited,Bits=8,Dolby=Off'),
 { color_format=>'0', max_bpc=>'8', range=>'1' },
 'combined CONF_FORMAT source payload parses format, range, and bit depth'
);

is_deeply(
 parsed('Resolution=1920x1080,Refresh=24,1_FORMAT=YCbCr 4:4:4 10-bit,Range=Limited,Bits=10,Dolby=Off'),
 { color_format=>'1', max_bpc=>'10', range=>'1' },
 'combined CONF_FORMAT source payload parses colon-delimited YCbCr 4:4:4'
);

is_deeply(
 parsed('RGB',1),
 { color_format=>'0', max_bpc=>'8', range=>'' },
 'CONF_LEVEL bare Format RGB preserves the historical 8bpc default'
);

my ($split_type,$split_payload)=&calman_split_command('CONF_FORMAT:Resolution=1920x1080,Refresh=24,1_FORMAT=YCbCr 4:4:4 10-bit,Range=Limited,Bits=10,Dolby=Off');
is($split_type,'CONF_FORMAT','CalMAN command split keeps the type before the first colon');
is($split_payload,'Resolution=1920x1080,Refresh=24,1_FORMAT=YCbCr 4:4:4 10-bit,Range=Limited,Bits=10,Dolby=Off','CalMAN command split preserves colon-delimited payload values');

my $daemon=do {
 open(my $fh,'<',$daemon_path) or die "Failed to read $daemon_path: $!";
 local $/;
 <$fh>;
};
my $vars=do {
 open(my $fh,'<',$vars_path) or die "Failed to read $vars_path: $!";
 local $/;
 <$fh>;
};

like($vars, qr/\$calman_explicit_max_bpc=0;/, 'CalMAN explicit bit-depth session state exists');
like($daemon, qr/\$calman_explicit_max_bpc=0;\s*\n\s*\$calman_rgb_quant_range=/, 'CalMAN reset clears explicit bit depth');
like($daemon, qr/if\(\$type eq "BITD"\).*?\$calman_note_explicit_bpc->\(\$pattern_cmd\).*?\$calman_apply->\(\);/s, 'BITD records explicit bpc and applies immediately');
like($daemon, qr/\$calman_apply_source_payload->\(\$fmt,0\);.*?\$calman_apply->\(0\);.*?calman_replay_last_pattern\("CONF_FORMAT"\)/s, 'CONF_FORMAT parses source settings and reapplies before replay');
like($daemon, qr/\$calman_apply_source_payload->\(\$1,1\);.*?\$calman_apply->\(\);/s, 'CONF_LEVEL Format uses the shared parser and applies immediately');
unlike($daemon, qr/my \$calman_set_non_dv_mode = sub \{.*?\$calman_save_setting->\("color_format","0"\)/s, 'HDR/SDR metadata changes preserve CalMAN-selected color format');
like($daemon, qr/my \$calman_handle_rpc_source_alias = sub \{.*?\$alias eq "BITDEPTH".*?\$calman_save_setting->\("max_bpc","\$bpc"\).*?\$alias eq "COLORSPACE".*?\$calman_apply_source_payload->\(\$rpc_payload,0\)/s, 'RPC source aliases use the shared source setting apply path');
like($daemon, qr/SET_PGENERATOR_CONF_MAX_BPC:\(8\|10\|12\).*?\$calman_note_explicit_bpc->\(\$1\).*?\$calman_apply->\(\);/s, 'RPC CMD max_bpc source setting applies immediately');
like($daemon, qr/SET_PGENERATOR_CONF_COLOR_FORMAT:\(\[0-3\]\).*?\$calman_save_setting->\("color_format","\$1"\).*?\$calman_apply->\(\);/s, 'RPC CMD color format source setting applies immediately');
like($daemon, qr/\$calman_save_setting->\("max_bpc",\$calman_preferred_bpc->\(\$eotf_val >= 2 \? "10" : "8"\)\);/, 'CONF_HDR preserves an explicit CalMAN bit depth');
like($daemon, qr/\$calman_save_setting->\("max_bpc",\$calman_preferred_bpc->\(&pg_dv_transport_max_bpc\(\$dv_transport\)\)\);/, 'DV setup preserves an explicit CalMAN bit depth');

done_testing();
