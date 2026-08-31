package PGMeterReading;

use strict;
use warnings;
use Exporter qw(import);
# Resolve sibling modules relative to this file so the module compiles from
# any checkout (perl -c, deploy tooling), not only when /usr/share/PGenerator
# is already on @INC.
use File::Basename ();
use lib File::Basename::dirname(__FILE__);
use PGCalibrationMath qw(bounded_number);

our @EXPORT_OK = qw(reading_xyz);

# A deliberately generous ceiling that rejects overflow and hostile meter
# records without constraining any plausible tristimulus or luminance reading.
my $METER_COMPONENT_LIMIT=10_000_000;

sub _meter_component {
 return bounded_number($_[0],-$METER_COMPONENT_LIMIT,$METER_COMPONENT_LIMIT);
}

sub reading_xyz {
 my ($reading)=@_;
 return undef if(ref($reading) ne "HASH");

 # Select one representation first. A complete direct record wins, and fields
 # from the unused xyY representation are intentionally not evaluated.
 if(defined($reading->{"X"}) && defined($reading->{"Y"})
   && defined($reading->{"Z"})) {
  my @xyz=map { _meter_component($reading->{$_}) } qw(X Y Z);
  return undef if(grep { !defined($_) } @xyz);
  return \@xyz;
 }

 my $luminance=defined($reading->{"luminance"})
  ? bounded_number($reading->{"luminance"},0,$METER_COMPONENT_LIMIT)
  : bounded_number($reading->{"Y"},0,$METER_COMPONENT_LIMIT);
 my $x=bounded_number($reading->{"x"},0,1);
 my $y=bounded_number($reading->{"y"},0,1);
 return undef if(!defined($luminance) || !defined($x) || !defined($y) || $y <= 0);

 my @xyz=(($x/$y)*$luminance,$luminance,
          ((1-$x-$y)/$y)*$luminance);
 return undef if(grep { !defined(_meter_component($_)) } @xyz);
 return \@xyz;
}

1;
