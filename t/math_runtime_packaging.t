use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);

my $root=File::Spec->rel2abs("$Bin/..");
my $image="$root/tools/build_pgenerator_plus_image.sh";
my $ota="$root/tools/build_pgenerator_plus_ota.sh";

sub bash_status {
 my ($body,%environment)=@_;
 local %ENV=(%ENV,%environment);
 system("bash","-c",$body);
 return $?;
}

is(bash_status('bash -n "$PGEN_IMAGE" "$PGEN_OTA"',
 PGEN_IMAGE=>$image,PGEN_OTA=>$ota),0,
 "release builders pass shell syntax validation");

my $pi4_check=q{
 source <(sed -e "\$d" "$PGEN_SCRIPT")
 trap - EXIT
 TARGET=pi4-biasi
 STAGING_DIR="$PGEN_ROOT"
 ROOT_MOUNT="$PGEN_ROOT"
 validate_colour_math_runtime
};
is(bash_status($pi4_check,PGEN_SCRIPT=>$ota,PGEN_ROOT=>$root),0,
 "Pi 4 OTA validates the complete numerical runtime");
is(bash_status($pi4_check,PGEN_SCRIPT=>$image,PGEN_ROOT=>$root),0,
 "Pi 4 image validates the complete numerical runtime");

my $stage=tempdir("pgen-math-package-XXXXXX",TMPDIR=>1,CLEANUP=>1);
make_path("$stage/usr/bin","$stage/usr/share/PGenerator",
 "$stage/usr/lib/python3/dist-packages");
copy("$root/usr/bin/pgen_colour_math.py","$stage/usr/bin/pgen_colour_math.py")
 or die "Unable to stage Python maths module: $!";
copy("$root/usr/share/PGenerator/PGMath.pm","$stage/usr/share/PGenerator/PGMath.pm")
 or die "Unable to stage Perl maths module: $!";
copy("$root/usr/bin/pgen_lut_solve","$stage/usr/bin/pgen_lut_solve")
 or die "Unable to stage native LUT helper: $!";
chmod(0755,"$stage/usr/bin/pgen_lut_solve");

my $pi5_check=q{
 source <(sed -e "\$d" "$PGEN_SCRIPT")
 trap - EXIT
 TARGET=pi5-bookworm-armhf
 STAGING_DIR="$PGEN_STAGE"
 ROOT_MOUNT="$PGEN_STAGE"
 validate_colour_math_runtime
};
is(bash_status($pi5_check,PGEN_SCRIPT=>$ota,PGEN_STAGE=>$stage),0,
 "Pi 5 OTA accepts shared maths without the Pi 4 ABI runtime");
is(bash_status($pi5_check,PGEN_SCRIPT=>$image,PGEN_STAGE=>$stage),0,
 "Pi 5 image accepts shared maths without the Pi 4 ABI runtime");

make_path("$stage/usr/lib/python3/dist-packages/numpy-1.18.5.dist-info");
isnt(bash_status("exec >/dev/null 2>&1\n".$pi5_check,
 PGEN_SCRIPT=>$ota,PGEN_STAGE=>$stage),0,
 "Pi 5 OTA rejects the incompatible Pi 4 NumPy runtime");
isnt(bash_status("exec >/dev/null 2>&1\n".$pi5_check,
 PGEN_SCRIPT=>$image,PGEN_STAGE=>$stage),0,
 "Pi 5 image rejects the incompatible Pi 4 NumPy runtime");

my $missing_pi4=q{
 source <(sed -e "\$d" "$PGEN_OTA")
 trap - EXIT
 PI4_NUMPY_RUNTIME_PATHS+=("usr/lib/definitely-missing-math-runtime")
 TARGET=pi4-biasi
 STAGING_DIR="$PGEN_ROOT"
 validate_colour_math_runtime
};
isnt(bash_status("exec >/dev/null 2>&1\n".$missing_pi4,
 PGEN_OTA=>$ota,PGEN_ROOT=>$root),0,
 "Pi 4 OTA rejects an incomplete numerical runtime");

done_testing();
