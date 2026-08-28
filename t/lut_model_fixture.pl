# Shared synthetic display model for the native-helper tests.
#
# t/lg_3d_lut_native_parity.t proves the native solver is byte-identical to
# the Perl path; t/lg_3d_lut_native_fallback.t proves the Perl path still
# produces a complete, correct cube when the helper is unusable. Both need the
# same measured forward model, and they have to be the SAME model: a fallback
# test against a different display would not exercise the cube the parity gate
# blesses. Loaded with "do" after the worker, so it lands in main alongside
# skeleton_levels(), model_from_readings() and build_measured_forward_model().

# A synthetic WOLED whose per-channel response is deliberately not a clean
# power and whose white subpixel adds a saturation-dependent gain, so the
# measured forward model carries real ramps and real non-additivity rather
# than something fm_invert can hit on the first step.
sub build_model {
 my ($gamma,$gamut,$mode,$volume_n,$greys,$solve_only)=@_;
 my @black=(0.021,0.020,0.023);
 my %prim=(
  red   => { x=>0.680, y=>0.320, peak=>21.5, g=>2.31 },
  green => { x=>0.268, y=>0.690, peak=>70.5, g=>2.28 },
  blue  => { x=>0.145, y=>0.052, peak=>8.0,  g=>2.40 },
 );
 my $ch=sub {
  my ($k,$f)=@_;
  my $p=$prim{$k};
  my $y=($f <= 0) ? 0 : ($f ** $p->{g});
  $y=$p->{peak}*$y*(1+0.035*sin(3.14159265358979*$f));
  return [ ($p->{x}/$p->{y})*$y, $y, ((1-$p->{x}-$p->{y})/$p->{y})*$y ];
 };
 my $panel=sub {
  my ($fr,$fg,$fb)=@_;
  my $r=$ch->("red",$fr); my $g=$ch->("green",$fg); my $b=$ch->("blue",$fb);
  my @v=map { $black[$_]+$r->[$_]+$g->[$_]+$b->[$_] } (0..2);
  my $mx=$fr; $mx=$fg if($fg > $mx); $mx=$fb if($fb > $mx);
  my $mn=$fr; $mn=$fg if($fg < $mn); $mn=$fb if($fb < $mn);
  if($mx > 1e-9) {
   my $sat=($mx-$mn)/$mx;
   my $wg=1+0.31*(1-$sat)*(1-$sat)*$mx;
   my $na=1-0.05*$sat*$sat*(1-$sat)*6.75*$mx;
   @v=map { $_*$wg*$na } @v;
   my $x=1+0.02*($fr-$fb)*$sat;
   $v[0]*=$x; $v[2]/=$x;
  }
  return [@v];
 };
 my @patches=([0,0,0]);
 foreach my $l (skeleton_levels()) {
  next if($l <= 0);
  push @patches,[$l,$l,$l],[$l,0,0],[0,$l,0],[0,0,$l];
 }
 for(my $i=0;$i<$volume_n;$i++) { for(my $j=0;$j<$volume_n;$j++) { for(my $k=0;$k<$volume_n;$k++) {
  push @patches,[100*$i/($volume_n-1),100*$j/($volume_n-1),100*$k/($volume_n-1)];
 }}}
 my (%seen,@nodes);
 foreach my $p (@patches) {
  my $key=sprintf("%.3f/%.3f/%.3f",@{$p});
  next if($seen{$key}++);
  my ($fr,$fg,$fb)=map { $_/100 } @{$p};
  push @nodes,{ fr=>$fr, fg=>$fg, fb=>$fb, xyz=>$panel->($fr,$fg,$fb) };
 }
 my $config={ method=>"hybrid", signal_mode=>$mode, target_gamma=>$gamma,
  target_gamut=>$gamut, display_type=>"oled_generic", include_greyscale=>($greys?1:0) };
 # solve_only keeps the requested gamma and gamut on the model; the live LG
 # path rewrites both (HDR forces bt2020 and a DPG calibration gamma).
 $config->{"solve_only"}=1 if($solve_only);
 my @profile;
 foreach my $kind (qw(white red green blue)) {
  my $xyz=($kind eq "white") ? $panel->(1,1,1)
   : ($kind eq "red") ? $panel->(1,0,0) : ($kind eq "green") ? $panel->(0,1,0) : $panel->(0,0,1);
  push @profile,{ step=>{kind=>$kind,level=>100,phase=>"profile"},
   reading=>{X=>$xyz->[0],Y=>$xyz->[1],Z=>$xyz->[2]}, read_time=>0 };
 }
 my $k=$panel->(0,0,0);
 push @profile,{ step=>{kind=>"black",level=>0,phase=>"profile"},
  reading=>{X=>$k->[0],Y=>$k->[1],Z=>$k->[2]}, read_time=>0 };
 my $model=model_from_readings("matrix",\@profile,$config);
 my $fm=build_measured_forward_model($model,\@nodes,$config);
 return undef if(ref($fm) ne "HASH");
 $model->{"forward_model"}=$fm;
 return $model;
}

1;
