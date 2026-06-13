#!/usr/bin/perl
# Quick 1D DPG test harness for the Pi4 (192.168.1.179).
# Usage:
#   1d-dpg-harness.pl capture            # save current 1D DPG to /tmp/dpg-baseline.bin
#   1d-dpg-harness.pl restore             # upload /tmp/dpg-baseline.bin to the panel
#   1d-dpg-harness.pl upload <file.bin>   # upload arbitrary 3072-uint16 LE file
#   1d-dpg-harness.pl read [out.bin]      # dump current panel 1D DPG (default: /tmp/dpg-current.bin)
#   1d-dpg-harness.pl diff <a.bin> <b.bin> # print per-channel max/avg delta and per-index diffs at sample indexes
#   1d-dpg-harness.pl transform <in.bin> <out.bin> <perl-expr>  # apply perl expression to each value
#                                            e.g. '1d-dpg-harness.pl transform baseline.bin scaled.bin
#                                                  '$v * 32767 / 32767'   (no-op sanity)
#                                                  '$v * 0.5'            (halve all values)
#                                                  '$v > 30000 ? 32767 : $v'  (clip upper)
#
# Each round-trip is ~20s. There is no need to run a full autocal between tests;
# the upload wraps its own CAL_START/CAL_END.

use strict;
use warnings;
use MIME::Base64;
use JSON::PP;

my $pi = "192.168.1.179";
my $base = "http://$pi";
my $baseline_path = "/tmp/dpg-baseline.bin";

sub call_api {
    my ($method, $path, $body) = @_;
    my $payload = $body ? "-d " . &shell_quote($body) : "";
    my $cmd = "curl -s -X $method -H 'Content-Type: application/json' $payload '$base$path'";
    my $json = `$cmd`;
    return decode_json($json) if $json && $json =~ /^\s*[\{\[]/;
    return { error => "non-json response", raw => substr($json // "", 0, 500) };
}

sub shell_quote {
    my $s = shift;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

sub pack_lut { pack("v*", @_) }
sub unpack_lut { unpack("v*", shift) }

sub read_panel {
    my $r = call_api("POST", "/api/lg/1d-dpg/read", qq({"picture_mode":"hdrFilmMaker"}));
    if (($r->{status} // "") ne "ok") {
        print "read failed: ", ($r->{message} // "?"), "\n";
        return undef;
    }
    my $b64 = $r->{read_response}{payload}{data};
    my $raw = decode_base64($b64);
    return [ unpack_lut(substr($raw, 0, 6144)) ];
}

sub upload_panel {
    my ($lut) = @_;
    my $b64 = encode_base64(pack_lut(@$lut), "");
    chomp $b64;
    my $body = '{"picture_mode":"hdrFilmMaker","dpg_data":[' . join(",", map { int($_) + 0 } @$lut) . ']}';
    my $r = call_api("POST", "/api/lg/1d-dpg/upload", $body);
    return $r;
}

sub perl_array_to_json {
    my $arr = shift;
    return "[" . join(",", map { int($_) + 0 } @$arr) . "]";
}

sub save_lut {
    my ($path, $lut) = @_;
    open(my $fh, ">", $path) or die "open $path: $!";
    binmode $fh;
    print $fh pack_lut(@$lut);
    close $fh;
    print "wrote ", scalar(@$lut), " values to $path (", -s $path, " bytes)\n";
}

sub load_lut {
    my ($path) = @_;
    open(my $fh, "<", $path) or die "open $path: $!";
    binmode $fh;
    local $/;
    my $raw = <$fh>;
    close $fh;
    my @v = unpack_lut($raw);
    return \@v;
}

sub show_samples {
    my ($label, $lut) = @_;
    my @idx = (0, 14, 19, 28, 42, 51, 70, 103, 154, 206, 257, 308, 411, 514, 612, 715, 920, 1023);
    print "$label  min=", (sort { $a <=> $b } @$lut)[0],
          "  max=", (sort { $b <=> $a } @$lut)[0], "\n";
    printf "  %-6s %6s %6s %6s\n", "idx", "R", "G", "B";
    for my $i (@idx) {
        printf "  %-6d %6d %6d %6d\n",
            $i, $lut->[$i], $lut->[1024 + $i], $lut->[2048 + $i];
    }
}

sub diff_luts {
    my ($a, $b) = @_;
    my $max_diff = 0; my $sum_diff = 0; my $n = @$a;
    for my $i (0..$n-1) {
        my $d = abs($a->[$i] - $b->[$i]);
        $sum_diff += $d;
        $max_diff = $d if $d > $max_diff;
    }
    my @idx = (0, 14, 51, 257, 514, 715, 1023);
    print "diff: max=$max_diff avg=", sprintf("%.2f", $sum_diff / $n), "\n";
    for my $i (@idx) {
        printf "  idx=%-4d  R:%5d->%5d (%+d)  G:%5d->%5d (%+d)  B:%5d->%5d (%+d)\n",
            $i,
            $a->[$i], $b->[$i], $b->[$i] - $a->[$i],
            $a->[1024 + $i], $b->[1024 + $i], $b->[1024 + $i] - $a->[1024 + $i],
            $a->[2048 + $i], $b->[2048 + $i], $b->[2048 + $i] - $a->[2048 + $i];
    }
}

sub apply_transform {
    my ($in, $out, $expr) = @_;
    my @new;
    for my $v (@$in) {
        my $nv = eval $expr;
        die "eval failed: $@" if $@;
        $nv = 0 if $nv < 0;
        $nv = 65535 if $nv > 65535;
        $nv = int($nv + 0.5);
        push @new, $nv;
    }
    save_lut($out, \@new);
}

my $cmd = shift @ARGV;
if (!$cmd || $cmd eq "help") {
    print <<"USAGE";
Usage: 1d-dpg-harness.pl <command> [args...]

  capture                            Save panel 1D DPG to /tmp/dpg-baseline.bin
  read [file]                        Dump panel 1D DPG (default /tmp/dpg-current.bin)
  upload <file>                      Upload a 3072-uint16 LE binary to the panel
  restore                            Upload the saved baseline
  diff <file_a> <file_b>             Compare two LUTs at sample indexes
  transform <in> <out> <perl-expr>   Apply a perl expression to each value

Each call is ~20s. No need to re-run the autocal between tests.
USAGE
    exit 0;
}

if ($cmd eq "capture") {
    my $lut = read_panel();
    die "capture failed" unless $lut;
    save_lut($baseline_path, $lut);
    show_samples("baseline:", $lut);
}
elsif ($cmd eq "read") {
    my $path = shift @ARGV // "/tmp/dpg-current.bin";
    my $lut = read_panel();
    die "read failed" unless $lut;
    save_lut($path, $lut);
    show_samples("current:", $lut);
}
elsif ($cmd eq "upload") {
    my $path = shift @ARGV or die "upload: need a file";
    my $lut = load_lut($path);
    my $r = upload_panel($lut);
    print "upload: status=", ($r->{status} // "?"),
          "  message=", ($r->{message} // "?"), "\n";
}
elsif ($cmd eq "restore") {
    my $lut = load_lut($baseline_path);
    my $r = upload_panel($lut);
    print "restore: status=", ($r->{status} // "?"),
          "  message=", ($r->{message} // "?"), "\n";
}
elsif ($cmd eq "diff") {
    my ($a, $b) = @ARGV;
    diff_luts(load_lut($a), load_lut($b));
}
elsif ($cmd eq "transform") {
    my ($in, $out, $expr) = @ARGV;
    apply_transform(load_lut($in), $out, $expr);
}
else {
    die "unknown command: $cmd\n";
}
