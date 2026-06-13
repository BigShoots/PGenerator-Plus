#!/usr/bin/perl
use strict;
use warnings;
use MIME::Base64;
use JSON::PP;
use Time::HiRes qw(stat);

my $file = $ARGV[0] // "/tmp/calman-relay-captures/local-tls-20260613-172208.jsonl";
my $pos = $file && -e $file ? (stat($file))[7] : 0;
local $| = 1;
print "=== watching $file (starting at offset $pos) ===\n";
while (1) {
    open my $fh, "<", $file or next;
    seek $fh, $pos, 0;
    my $buf = do { local $/; <$fh> };
    close $fh;
    $pos += length($buf);
    for my $line (split /\n/, $buf) {
        next unless $line;
        my $d = eval { decode_json($line) };
        next unless $d;
        my $dir = $d->{direction} or next;
        my $js = $d->{json} or next;
        my $type = $js->{type} // "";
        my $pl  = $js->{payload} // {};
        my $cmd = ref $pl eq 'HASH' ? ($pl->{command} // $pl->{type} // "") : "";
        my $name = $type eq 'request' ? ($cmd || $type) : $type;
        # highlight calibration commands
        if ($name =~ /1D_DPG_DATA|1D_TONEMAP|BT2020_3BY3|3D_LUT_DATA|CAL_START|CAL_END/) {
            my $extra = "";
            if ($name eq '1D_DPG_DATA' && $pl->{data}) {
                my $raw = decode_base64($pl->{data});
                my $n = length($raw) / 2;
                my @v = unpack "v*", $raw;
                my @hdr20_idx = (0, 14, 51, 257, 514, 715, 1023);
                $extra .= "\n    data_count=$pl->{dataCount}  data_type=$pl->{dataType}  data_opt=$pl->{dataOpt}";
                $extra .= "\n    samples (R,G,B per channel, 1024 spaced):";
                for my $i (@hdr20_idx) {
                    my $r = $v[$i];
                    my $g = $v[1024+$i];
                    my $b = $v[2048+$i] if $n > 2048+$i;
                    $extra .= sprintf "\n      idx=%-4d  R=%5d  G=%5d  B=%5d", $i, $r, $g, ($b // 0);
                }
            }
            printf "[%s] %s  id=%s%s\n", $dir, $name, ($js->{id}//""), $extra;
        } elsif ($type eq 'request') {
            printf "[%s] %s  id=%s  command=%s\n", $dir, $type, ($js->{id}//""), ($cmd || "?");
        } elsif ($type eq 'response' || $type eq 'registered') {
            printf "[%s] %s  id=%s\n", $dir, $type, ($js->{id}//"");
        }
    }
    sleep 0.3;
}
