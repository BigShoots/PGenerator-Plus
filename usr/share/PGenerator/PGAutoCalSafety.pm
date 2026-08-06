package PGAutoCalSafety;

use strict;
use warnings;
use Exporter qw(import);
use Scalar::Util qw(looks_like_number);

our @EXPORT_OK = qw(
 profile_reading_plausibility_error
 profile_primary_monotonicity_error
 critical_shadow_needs_revisit
 autocal_solver_target_delta_e
 autocal_white_residual_stop_allowed
 autocal_restored_acceptance_needs_retry
);

sub _reading_xyz {
 my ($reading)=@_;
 return undef if(ref($reading) ne "HASH");
 return undef if(!defined($reading->{X}) || !defined($reading->{Y}) || !defined($reading->{Z}));
 return undef if(!looks_like_number($reading->{X}) || !looks_like_number($reading->{Y}) || !looks_like_number($reading->{Z}));
 return [ $reading->{X}+0, $reading->{Y}+0, $reading->{Z}+0 ];
}

sub _step_is_nonblack {
 my ($step)=@_;
 return 0 if(ref($step) ne "HASH");
 return 0 if(lc($step->{kind}||"") eq "black");
 foreach my $key (qw(signal_r_pct signal_g_pct signal_b_pct)) {
  return 1 if(defined($step->{$key}) && looks_like_number($step->{$key}) && ($step->{$key}+0) > 0);
 }
 return 1 if(defined($step->{level}) && looks_like_number($step->{level}) && ($step->{level}+0) > 0);
 return 1 if(defined($step->{ire}) && looks_like_number($step->{ire}) && ($step->{ire}+0) > 0);
 return 0;
}

# Reject readings which cannot physically describe the requested patch.  The
# threshold is deliberately far below even a 5% blue OLED patch, but above an
# exact/stale black result.  A black patch may legitimately be XYZ 0/0/0.
sub profile_reading_plausibility_error {
 my ($step,$reading,$minimum_y)=@_;
 my $xyz=_reading_xyz($reading);
 return "returned no numeric XYZ" if(!$xyz);
 foreach my $value (@{$xyz}) {
  return "returned negative XYZ" if($value < -0.001);
 }
 return undef if(!_step_is_nonblack($step));
 $minimum_y=0.001 if(!defined($minimum_y) || !looks_like_number($minimum_y) || $minimum_y < 0);
 my $sum=$xyz->[0]+$xyz->[1]+$xyz->[2];
 return sprintf("non-black patch returned black XYZ (%.6f/%.6f/%.6f)",@{$xyz})
  if($xyz->[1] <= $minimum_y && $sum <= ($minimum_y*3));
 return undef;
}

sub _pure_primary_axis {
 my ($step)=@_;
 return if(ref($step) ne "HASH");
 my @pct=map {
  (defined($step->{$_}) && looks_like_number($step->{$_})) ? ($step->{$_}+0) : 0
 } qw(signal_r_pct signal_g_pct signal_b_pct);
 my @active=grep { $pct[$_] > 0 } (0..2);
 return if(@active != 1);
 my $axis=$active[0];
 return ($axis,$pct[$axis]);
}

# A higher point on the same pure-primary ramp must not collapse below the
# preceding point.  A generous 65% floor tolerates panel drift and noise while
# catching endpoint failures such as 90% blue -> valid, 100% blue -> black.
sub profile_primary_monotonicity_error {
 my ($step,$reading,$previous_entries,$minimum_ratio)=@_;
 return undef if(ref($previous_entries) ne "ARRAY");
 my ($axis,$level)=_pure_primary_axis($step);
 return undef if(!defined($axis) || $level < 10);
 my ($previous,$previous_level);
 foreach my $entry (@{$previous_entries}) {
  next if(ref($entry) ne "HASH");
  my ($prior_axis,$prior_level)=_pure_primary_axis($entry->{step});
  next if(!defined($prior_axis) || $prior_axis != $axis || $prior_level >= $level);
  next if(defined($previous_level) && $prior_level <= $previous_level);
  my $xyz=_reading_xyz($entry->{reading});
  next if(!$xyz);
  $previous=$xyz;
  $previous_level=$prior_level;
 }
 return undef if(!$previous);
 my $current=_reading_xyz($reading);
 return "returned no numeric XYZ" if(!$current);
 $minimum_ratio=0.65 if(!defined($minimum_ratio) || !looks_like_number($minimum_ratio) || $minimum_ratio <= 0 || $minimum_ratio >= 1);
 my @axis_names=qw(red green blue);
 my $dominant=$axis==0 ? 0 : ($axis==1 ? 1 : 2);
 return sprintf(
  "%s ramp collapsed at %.3g%% (dominant %.6f after %.3g%% %.6f)",
  $axis_names[$axis],$level,$current->[$dominant],$previous_level,$previous->[$dominant]
 ) if($previous->[$dominant] > 0 && $current->[$dominant] < ($previous->[$dominant]*$minimum_ratio));
 return sprintf(
  "%s luminance ramp collapsed at %.3g%% (Y %.6f after %.3g%% %.6f)",
  $axis_names[$axis],$level,$current->[1],$previous_level,$previous->[1]
 ) if($previous->[1] > 0 && $current->[1] < ($previous->[1]*$minimum_ratio));
 return undef;
}

sub critical_shadow_needs_revisit {
 my ($step,$converged)=@_;
 return 0 if($converged || ref($step) ne "HASH");
 my $ire=defined($step->{ire}) && looks_like_number($step->{ire})
  ? ($step->{ire}+0)
  : (defined($step->{stimulus}) && looks_like_number($step->{stimulus}) ? ($step->{stimulus}+0) : undef);
 return 0 if(!defined($ire));
 return abs($ire-2.3) < 0.001 ? 1 : 0;
}

# Resolve the dE target used by a specialised solver.  The worker-specific key
# remains available as an intentional expert override, but normal AutoCal runs
# must inherit the operator's target_delta_e rather than silently reverting to
# a solver-local default.
sub autocal_solver_target_delta_e {
 my ($config,$override_key,$fallback)=@_;
 $fallback=0.5 if(!defined($fallback) || !looks_like_number($fallback) || $fallback <= 0);
 my $target=$fallback+0;
 if(ref($config) eq "HASH") {
  if(defined($override_key) && $override_key ne ""
   && defined($config->{$override_key}) && looks_like_number($config->{$override_key})
   && ($config->{$override_key}+0) > 0) {
   $target=$config->{$override_key}+0;
  } elsif(defined($config->{target_delta_e}) && looks_like_number($config->{target_delta_e})
   && ($config->{target_delta_e}+0) > 0) {
   $target=$config->{target_delta_e}+0;
  }
 }
 $target=0.05 if($target < 0.05);
 $target=10.0 if($target > 10.0);
 return $target+0;
}

# A small white-channel residual is not, by itself, permission to abandon an
# above-target solve.  Allow the noise/physical-limit shortcut only after the
# worker has made several real attempts, or after repeated reverts demonstrate
# that those attempts are no longer improving the result.
sub autocal_white_residual_stop_allowed {
 my ($iter,$reverts,$residual,$de,$target)=@_;
 return 0 if(!defined($residual) || !looks_like_number($residual));
 return 0 if(!defined($de) || !looks_like_number($de));
 return 0 if(!defined($target) || !looks_like_number($target) || $target <= 0);
 return 0 if(($de+0) <= ($target+0));
 return 0 if(($residual+0) > 0.004);
 $iter=0 if(!defined($iter) || !looks_like_number($iter));
 $reverts=0 if(!defined($reverts) || !looks_like_number($reverts));
 return (($iter+0) >= 4 || ($reverts+0) >= 2) ? 1 : 0;
}

# A historically sub-target sample is not enough to finish an anchor when the
# coefficients that produced it are restored and their verification read has
# drifted back above target.  Continue solving from that verified panel state;
# a failed verification read cannot safely drive another move and is handled by
# the caller's existing read-failure/best-known fallback.
sub autocal_restored_acceptance_needs_retry {
 my ($restored_ok,$restored_de,$target)=@_;
 return 0 if(!$restored_ok);
 return 0 if(!defined($restored_de) || !looks_like_number($restored_de));
 return 0 if(!defined($target) || !looks_like_number($target) || ($target+0) <= 0);
 return (($restored_de+0) >= ($target+0)) ? 1 : 0;
}

1;
