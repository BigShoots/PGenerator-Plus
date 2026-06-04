#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use JSON::PP;

my $pgenerator_lg = "$FindBin::Bin/../usr/sbin/pgenerator-lg";
open(my $fh, '<', $pgenerator_lg) or die "open $pgenerator_lg: $!\n";
local $/;
my $source = <$fh>;
close($fh);

our (
 $LG_DDC_1D_MIN_STEP_UNITS,
 $LG_DDC_1D_STEP_RATIO,
 $LG_DDC_1D_BLACK_SAMPLE,
 $LG_DDC_SDR26_LEGAL_100_SAMPLE,
 $LG_DDC_SDR26_TOP_CONTINUITY_MAX_LEGAL_100_DELTA,
 @LG_DDC_1D_LABELS,
 @LG_DDC_1D_LABELS_SDR,
 @LG_DDC_1D_LABELS_HDR20,
 @LG_DDC_1D_INDEXES,
 @LG_DDC_1D_INDEXES_SDR,
 @LG_DDC_1D_INDEXES_HDR20,
 @LG_DDC_1D_PATCH_CODES_8BIT,
 @LG_DDC_1D_PATCH_INDEXES_8BIT,
 @LG_DDC_1D_PATCH_INDEXES_8BIT_SDR,
 @LG_DDC_1D_PATCH_INDEXES_8BIT_HDR20
);

sub extract_assignment {
 my ($sigil, $name) = @_;
 my $pattern = qr/(\Q$sigil\E\Q$name\E\s*=[^;]+;)/s;
 die "could not extract $sigil$name\n" if $source !~ $pattern;
 return $1;
}

sub extract_sub {
 my ($name) = @_;
 my $start = index($source, "sub $name");
 die "could not find sub $name\n" if $start < 0;
 my $brace = index($source, '{', $start);
 die "could not find body for sub $name\n" if $brace < 0;

 my $depth = 0;
 for(my $pos = $brace; $pos < length($source); $pos++) {
  my $char = substr($source, $pos, 1);
  $depth++ if $char eq '{';
  if($char eq '}') {
   $depth--;
   return substr($source, $start, $pos - $start + 1) if $depth == 0;
   die "unbalanced body for sub $name\n" if $depth < 0;
  }
 }
 die "unterminated body for sub $name\n";
}

my @pieces = (
 (map { extract_assignment('$', $_) } qw(
  LG_DDC_1D_MIN_STEP_UNITS
  LG_DDC_1D_STEP_RATIO
  LG_DDC_1D_BLACK_SAMPLE
  LG_DDC_SDR26_LEGAL_100_SAMPLE
  LG_DDC_SDR26_TOP_CONTINUITY_MAX_LEGAL_100_DELTA
 )),
 (map { extract_assignment('@', $_) } qw(
  LG_DDC_1D_LABELS
  LG_DDC_1D_LABELS_SDR
  LG_DDC_1D_LABELS_HDR20
  LG_DDC_1D_INDEXES
  LG_DDC_1D_INDEXES_SDR
  LG_DDC_1D_INDEXES_HDR20
  LG_DDC_1D_PATCH_CODES_8BIT
  LG_DDC_1D_PATCH_INDEXES_8BIT
  LG_DDC_1D_PATCH_INDEXES_8BIT_SDR
  LG_DDC_1D_PATCH_INDEXES_8BIT_HDR20
 )),
 (map { extract_sub($_) } qw(
  json_true
  json_false
  lg_unity_1d_lut
  lg_ddc_normalize_rgb_array
  lg_ddc_1d_index_for_ire
  lg_ddc_step_units_for_point
  lg_ddc_1d_sorted_slots
  lg_ddc_offset_units_for_slot
  lg_ddc_interpolated_offset_at_index
  lg_ddc_sdr26_top_continuity_guard_settings
  lg_ddc_build_1d_lut
  lg_ddc_lut_top_sample_snapshot
 ))
);

eval join("\n", @pieces, "1;") or die "eval pgenerator-lg LUT pieces: $@\n";

my $failures = 0;

sub ok {
 my ($condition, $message) = @_;
 if($condition) {
  print "ok  $message\n";
  return;
 }
 $failures++;
 print "not ok  $message\n";
}

sub sample_by_code {
 my ($samples, $code) = @_;
 foreach my $item (@{$samples || []}) {
  return $item if(($item->{"sample"}||-1) == $code);
 }
 return undef;
}

sub delta_gap {
 my ($samples, $left_code, $right_code, $channel) = @_;
 my $left = sample_by_code($samples, $left_code);
 my $right = sample_by_code($samples, $right_code);
 die "missing samples for gap\n" if(ref($left) ne "HASH" || ref($right) ne "HASH");
 return abs(($right->{$channel."_delta"}||0) - ($left->{$channel."_delta"}||0));
}

my $baseline = lg_unity_1d_lut();
my $slot99 = lg_ddc_1d_index_for_ire(99);
my $slot105 = lg_ddc_1d_index_for_ire(105);
my @zeros = map { 0 } @LG_DDC_1D_INDEXES;
my %red_settings = (
 ddc_layout => 'sdr26',
 whiteBalanceMethod => '22',
 whiteBalanceIre => 99,
 whiteBalanceRed => [@zeros],
 whiteBalanceGreen => [@zeros],
 whiteBalanceBlue => [@zeros],
 adjustingLuminance => [@zeros],
);

$red_settings{whiteBalanceRed}->[$slot99] = 5;
$red_settings{whiteBalanceRed}->[$slot105] = -30;

my $raw_lut = lg_ddc_build_1d_lut($baseline, \%red_settings);
my $raw_samples = lg_ddc_lut_top_sample_snapshot($raw_lut, $baseline);
my ($guarded_settings, $guard) = lg_ddc_sdr26_top_continuity_guard_settings($baseline, \%red_settings);
my $guarded_lut = lg_ddc_build_1d_lut($baseline, $guarded_settings);
my $guarded_samples = lg_ddc_lut_top_sample_snapshot($guarded_lut, $baseline);

ok($guard->{"applied"}, 'SDR26 guard should apply to extreme 99/105 opposing slopes');
ok(ref($guard->{"changes"}) eq "ARRAY" && @{$guard->{"changes"}} >= 1, 'guard diagnostics should expose changed top channels');

my %seen_samples = map { ($_->{sample} => 1) } @{$guarded_samples};
ok($seen_samples{926} && $seen_samples{940} && $seen_samples{981} && $seen_samples{1023}, 'generated top LUT samples should expose 926/940/981/1023');

foreach my $change (@{$guard->{"changes"}}) {
 my $limit = abs($change->{"legal_100_delta_unit_limit"} || 0);
 my $after = abs($change->{"legal_100_delta_units_after"} || 0);
 ok($after <= $limit + 3.0, "$change->{setting} legal 100 delta should stay inside the continuity guard");
}

ok(
 delta_gap($guarded_samples, 926, 940, 'red') < delta_gap($raw_samples, 926, 940, 'red'),
 'guarded linear build should pull generated red sample 940 closer to sample 926 than the raw pathological slope'
);

my %luma_settings = (
 ddc_layout => 'sdr26',
 whiteBalanceMethod => '22',
 whiteBalanceIre => 99,
 whiteBalanceRed => [@zeros],
 whiteBalanceGreen => [@zeros],
 whiteBalanceBlue => [@zeros],
 adjustingLuminance => [@zeros],
);
$luma_settings{adjustingLuminance}->[$slot99] = 5;
$luma_settings{adjustingLuminance}->[$slot105] = -18;
my $raw_luma_lut = lg_ddc_build_1d_lut($baseline, \%luma_settings);
my $raw_luma_samples = lg_ddc_lut_top_sample_snapshot($raw_luma_lut, $baseline);
my ($guarded_luma_settings, $luma_guard) = lg_ddc_sdr26_top_continuity_guard_settings($baseline, \%luma_settings);
my $guarded_luma_lut = lg_ddc_build_1d_lut($baseline, $guarded_luma_settings);
my $guarded_luma_samples = lg_ddc_lut_top_sample_snapshot($guarded_luma_lut, $baseline);
ok($luma_guard->{"applied"}, 'SDR26 guard should apply to extreme 99/105 luminance slopes');
ok(
 delta_gap($guarded_luma_samples, 926, 940, 'green') < delta_gap($raw_luma_samples, 926, 940, 'green'),
 'guarded linear build should pull generated green sample 940 closer to sample 926 through luminance continuity'
);

{
 local @LG_DDC_1D_LABELS = @LG_DDC_1D_LABELS_HDR20;
 local @LG_DDC_1D_INDEXES = @LG_DDC_1D_INDEXES_HDR20;
 local @LG_DDC_1D_PATCH_INDEXES_8BIT = @LG_DDC_1D_PATCH_INDEXES_8BIT_HDR20;
 my @hdr_zeros = map { 0 } @LG_DDC_1D_INDEXES;
 my %hdr_settings = (
  ddc_layout => 'hdr20',
  whiteBalanceMethod => '22',
  whiteBalanceIre => 100,
  whiteBalanceRed => [@hdr_zeros],
  whiteBalanceGreen => [@hdr_zeros],
  whiteBalanceBlue => [@hdr_zeros],
  adjustingLuminance => [@hdr_zeros],
 );
 my ($hdr_guarded, $hdr_guard) = lg_ddc_sdr26_top_continuity_guard_settings($baseline, \%hdr_settings);
 ok(!$hdr_guard->{"applied"} && $hdr_guarded == \%hdr_settings, 'HDR20 helper path should not receive the SDR26 top-continuity guard');
}

exit($failures ? 1 : 0);
