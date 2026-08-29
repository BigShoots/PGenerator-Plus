use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Digest::SHA qw(sha256_hex);
use Cwd qw(getcwd);

my $root=File::Spec->rel2abs("$Bin/..");
my $image="$root/tools/build_pgenerator_plus_image.sh";
my $ota="$root/tools/build_pgenerator_plus_ota.sh";
my $pi4_runtime="$root/tools/runtime/pi4_numpy_runtime.sh";

sub bash_status {
 my ($body,%environment)=@_;
 local %ENV=(%ENV,%environment);
 system("bash","-c",$body);
 return $?;
}

is(bash_status('bash -n "$PGEN_IMAGE" "$PGEN_OTA" "$PGEN_PI4_RUNTIME"',
 PGEN_IMAGE=>$image,PGEN_OTA=>$ota,PGEN_PI4_RUNTIME=>$pi4_runtime),0,
 "release builders pass shell syntax validation");

# Sourcing a release builder installs its EXIT trap, whose cleanup runs
# "rm -rf $STAGING_DIR" (and umounts $ROOT_MOUNT). Handing those variables the
# developer's checkout would put the whole repository one stray exit away from
# deletion, so nothing here ever names the checkout directly: the validators
# read a throwaway directory whose only entry is a symlink to the repo's usr/
# tree, every snippet clears the trap AND sets the builders' own keep flags,
# and "rm -rf" on the mirror can therefore only unlink the symlink.
my $mirror=tempdir("pgen-math-mirror-XXXXXX",TMPDIR=>1,CLEANUP=>1);
symlink("$root/usr","$mirror/usr")
 or die "Unable to mirror the repository usr/ tree: $!";

my $pi4_check=q{
 source "$PGEN_SCRIPT"
 trap - EXIT
 KEEP_STAGING=1
 KEEP_WORKDIR=1
 TARGET=pi4-biasi
 STAGING_DIR="$PGEN_MIRROR"
 ROOT_MOUNT="$PGEN_MIRROR"
 validate_colour_math_runtime
};
isnt(bash_status("exec >/dev/null 2>&1\n".$pi4_check,
 PGEN_SCRIPT=>$ota,PGEN_MIRROR=>$mirror),0,
 "Pi 4 OTA refuses a repository overlay before the external runtime is hydrated");
isnt(bash_status("exec >/dev/null 2>&1\n".$pi4_check,
 PGEN_SCRIPT=>$image,PGEN_MIRROR=>$mirror),0,
 "Pi 4 image refuses a repository overlay before the external runtime is hydrated");

ok(!-d "$root/usr/lib/python3/dist-packages/numpy",
 "the expanded NumPy package is not stored in Git");
ok(!-e "$root/usr/lib/libatlas.so.3",
 "the expanded Pi 4 numerical libraries are not stored in Git");

# Exercise the shared downloader/stager without a network dependency. The
# fixtures have the upstream wheel and Debian package shapes but tiny
# stand-ins. Their checksums are supplied after sourcing the production
# manifest; builder arguments cannot replace the production checksum pins.
my $fixture=tempdir("pgen-pi4-numpy-fixture-XXXXXX",TMPDIR=>1,CLEANUP=>1);
my $wheel_root="$fixture/wheel";
my $runtime_file_list="$root/tools/runtime/pi4_numpy_runtime_files.txt";
open(my $list_fh,"<",$runtime_file_list)
 or die "Unable to read the NumPy runtime file list: $!";
my @wheel_files;
while(my $rel=<$list_fh>) {
 chomp($rel);
 next if($rel eq "" || $rel =~ /^#/);
 push(@wheel_files,$rel);
 make_path(File::Spec->catdir($wheel_root,File::Spec->splitdir(
  (File::Spec->splitpath($rel))[1])));
 open(my $fh,">","$wheel_root/$rel") or die "Unable to create $rel: $!";
 print {$fh} "fixture:$rel\n";
 close($fh);
}
close($list_fh);
make_path("$wheel_root/not-selected");
open(my $extra_fh,">","$wheel_root/not-selected/unexpected.py")
 or die "Unable to create unselected wheel fixture: $!";
print {$extra_fh} "must not be staged\n";
close($extra_fh);
my $fixture_wheel="$fixture/numpy-fixture.whl";
my $original_dir=getcwd();
chdir($wheel_root) or die "Unable to enter wheel fixture: $!";
my $zip_status=system("zip","-qr",$fixture_wheel,
 "numpy","numpy-1.18.5.dist-info","not-selected");
chdir($original_dir) or die "Unable to restore test directory: $!";
is($zip_status,0,"created the isolated NumPy wheel fixture");

my $deb_data="$fixture/deb-data";
my @atlas_sources=(
 "usr/lib/atlas-base/libatlas.so.3.0",
 "usr/lib/atlas-base/atlas/libblas.so.3.0",
 "usr/lib/atlas-base/libcblas.so.3.0",
 "usr/lib/atlas-base/libf77blas.so.3.0",
 "usr/lib/atlas-base/atlas/liblapack.so.3.0",
);
foreach my $rel (@atlas_sources) {
 my (undef,$directory)=File::Spec->splitpath($rel);
 make_path("$deb_data/$directory");
 open(my $fh,">","$deb_data/$rel") or die "Unable to create $rel: $!";
 print {$fh} "fixture:$rel\n";
 close($fh);
}
my $deb_payload="$fixture/data.tar.xz";
is(system("tar","-cJf",$deb_payload,"-C",$deb_data,"."),0,
 "created the isolated ATLAS package payload");
my $fixture_deb="$fixture/atlas-fixture.deb";
chdir($fixture) or die "Unable to enter Debian-package fixture: $!";
my $ar_status=system("ar","qS",$fixture_deb,"data.tar.xz");
chdir($original_dir) or die "Unable to restore test directory: $!";
is($ar_status,0,
 "created the isolated ATLAS Debian-package fixture");

my $wheel_sha=file_sha256($fixture_wheel);
my $atlas_sha=file_sha256($fixture_deb);
my $hydrated=tempdir("pgen-pi4-numpy-hydrated-XXXXXX",TMPDIR=>1,CLEANUP=>1);
make_path("$hydrated/usr/lib/python3/dist-packages/numpy");
open(my $stale_fh,">","$hydrated/usr/lib/python3/dist-packages/numpy/stale.py")
 or die "Unable to create stale fixture: $!";
close($stale_fh);
my $hydrate=q{
 source "$PGEN_HELPER"
 PI4_NUMPY_WHEEL_SHA256="$PGEN_WHEEL_SHA"
 PI4_ATLAS_DEB_SHA256="$PGEN_ATLAS_SHA"
 PGEN_PI4_NUMPY_WHEEL="$PGEN_WHEEL"
 PGEN_PI4_ATLAS_DEB="$PGEN_ATLAS_DEB"
 hydrate_pi4_numpy_runtime "$PGEN_DESTINATION"
};
is(bash_status($hydrate,PGEN_HELPER=>$pi4_runtime,
 PGEN_WHEEL_SHA=>$wheel_sha,PGEN_ATLAS_SHA=>$atlas_sha,
 PGEN_WHEEL=>$fixture_wheel,PGEN_ATLAS_DEB=>$fixture_deb,
 PGEN_DESTINATION=>$hydrated),0,
 "the shared helper verifies and hydrates a complete pinned runtime");
ok(-f "$hydrated/usr/lib/python3/dist-packages/numpy/__init__.py",
 "the verified runtime is staged into the release root");
ok(!-e "$hydrated/usr/lib/python3/dist-packages/numpy/stale.py",
 "hydration removes stale files from an older NumPy tree");
ok(!-e "$hydrated/usr/lib/python3/dist-packages/not-selected/unexpected.py",
 "hydration stages only the explicit runtime subset from the wheel");
ok(-f "$hydrated/usr/lib/liblapack.so.3",
 "hydration maps the Debian ATLAS package into the legacy runtime paths");
is((stat("$hydrated/usr/lib/python3/dist-packages/numpy/core/_multiarray_umath.cpython-35m-arm-linux-gnueabihf.so"))[2] & 07777,
 0644,"hydration preserves the established non-executable extension mode");

my $tampered="$fixture/numpy-tampered.whl";
copy($fixture_wheel,$tampered) or die "Unable to copy checksum fixture: $!";
open(my $tampered_fh,">>",$tampered) or die "Unable to alter checksum fixture: $!";
print {$tampered_fh} "tampered";
close($tampered_fh);
isnt(bash_status("exec >/dev/null 2>&1\n".$hydrate,
 PGEN_HELPER=>$pi4_runtime,PGEN_WHEEL_SHA=>$wheel_sha,
 PGEN_ATLAS_SHA=>$atlas_sha,PGEN_WHEEL=>$tampered,
 PGEN_ATLAS_DEB=>$fixture_deb,PGEN_DESTINATION=>$hydrated),0,
 "the shared helper rejects a wheel with the wrong SHA-256");

my $stage=tempdir("pgen-math-package-XXXXXX",TMPDIR=>1,CLEANUP=>1);
make_path("$stage/usr/bin","$stage/usr/share/PGenerator",
 "$stage/usr/lib/python3/dist-packages");
copy("$root/usr/bin/pgen_colour_math.py","$stage/usr/bin/pgen_colour_math.py")
 or die "Unable to stage Python maths module: $!";
copy("$root/usr/bin/pgen_meter_average.py","$stage/usr/bin/pgen_meter_average.py")
 or die "Unable to stage meter averaging helper: $!";
copy("$root/usr/share/PGenerator/PGMath.pm","$stage/usr/share/PGenerator/PGMath.pm")
 or die "Unable to stage Perl maths module: $!";
copy("$root/usr/bin/pgen_lut_solve","$stage/usr/bin/pgen_lut_solve")
 or die "Unable to stage native LUT helper: $!";
chmod(0755,"$stage/usr/bin/pgen_lut_solve");

my $pi5_check=q{
 source "$PGEN_SCRIPT"
 trap - EXIT
 KEEP_STAGING=1
 KEEP_WORKDIR=1
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

ok(-d "$root/usr" && -f "$root/usr/bin/pgen_colour_math.py",
 "the repository survives sourcing the release builders' cleanup traps");

# The one runtime dependency the Pi 4 assumes rather than ships. Every other
# numerical library has its architecture checked; libgfortran.so.3 comes from
# the base image, and until now nothing looked for it at all.
my $gfortran_check=q{
 source "$PGEN_IMAGE"
 trap - EXIT
 KEEP_STAGING=1
 KEEP_WORKDIR=1
 TARGET=pi4-biasi
 ROOT_MOUNT="$PGEN_ROOT"
 validate_pi4_base_numerical_runtime
};
my $bare_root=tempdir("pgen-pi4-base-XXXXXX",TMPDIR=>1,CLEANUP=>1);
make_path("$bare_root/usr/lib/arm-linux-gnueabihf","$bare_root/lib");
isnt(bash_status("exec >/dev/null 2>&1\n".$gfortran_check,
 PGEN_IMAGE=>$image,PGEN_ROOT=>$bare_root),0,
 "Pi 4 image rejects a base root without libgfortran.so.3");
open(my $gfortran_fh,">","$bare_root/usr/lib/arm-linux-gnueabihf/libgfortran.so.3")
 or die "Unable to stage a libgfortran stand-in: $!";
close($gfortran_fh);
is(bash_status($gfortran_check,PGEN_IMAGE=>$image,PGEN_ROOT=>$bare_root),0,
 "Pi 4 image accepts a base root that supplies libgfortran.so.3");

# Pi 5 stages python3-numpy with "dpkg-deb -x", so the update-alternatives
# links libblas.so.3 and liblapack.so.3 that NumPy loads through are never
# created. The builder recreates them and then refuses to ship without them.
my $pi5_blas_stage=q{
 source "$PGEN_IMAGE"
 trap - EXIT
 KEEP_STAGING=1
 KEEP_WORKDIR=1
 TARGET=pi5-bookworm-armhf
 ROOT_MOUNT="$PGEN_ROOT"
 stage_pi5_blas_alternatives
 validate_pi5_numerical_runtime
};
my $pi5_root=tempdir("pgen-pi5-blas-XXXXXX",TMPDIR=>1,CLEANUP=>1);
my $pi5_multiarch="$pi5_root/usr/lib/arm-linux-gnueabihf";
make_path($pi5_multiarch);
isnt(bash_status("exec >/dev/null 2>&1\n".$pi5_blas_stage,
 PGEN_IMAGE=>$image,PGEN_ROOT=>$pi5_root),0,
 "Pi 5 image rejects a root with no BLAS implementation at all");
make_path("$pi5_multiarch/blas","$pi5_multiarch/lapack");
foreach my $pair (["blas","libblas.so.3"],["lapack","liblapack.so.3"]) {
 open(my $fh,">","$pi5_multiarch/$pair->[0]/$pair->[1]")
  or die "Unable to stage $pair->[1]: $!";
 close($fh);
}
is(bash_status($pi5_blas_stage,PGEN_IMAGE=>$image,PGEN_ROOT=>$pi5_root),0,
 "Pi 5 image recreates the alternatives links dpkg-deb -x never made");
ok(-l "$pi5_multiarch/libblas.so.3" && -e "$pi5_multiarch/libblas.so.3",
 "the recreated libblas.so.3 link resolves");
ok(-l "$pi5_multiarch/liblapack.so.3" && -e "$pi5_multiarch/liblapack.so.3",
 "the recreated liblapack.so.3 link resolves");
unlink("$pi5_multiarch/blas/libblas.so.3");
isnt(bash_status("exec >/dev/null 2>&1\n".$pi5_blas_stage,
 PGEN_IMAGE=>$image,PGEN_ROOT=>$pi5_root),0,
 "Pi 5 image rejects a dangling alternatives link");

like(source_text("$root/tools/build_pgenerator_plus_image.sh"),
 qr/"usr\/bin\/pgen_lut_solve"/,
 "the image builder gives the native LUT helper mode 0755 on the device");
like(source_text($pi4_runtime),
 qr/PI4_NUMPY_WHEEL_SHA256="[0-9a-f]{64}".*PI4_ATLAS_DEB_SHA256="[0-9a-f]{64}"/s,
 "both upstream Pi 4 numerical packages are pinned by SHA-256");
like(source_text($ota),
 qr/stage_overlay\s+if \[\[ "\$TARGET" == "pi4-biasi" \]\]; then\s+.*?hydrate_pi4_numpy_runtime.*?validate_colour_math_runtime/s,
 "the OTA builder hydrates the upstream packages before validating them");
like(source_text($image),
 qr/overlay_tree\s+if \[\[ "\$TARGET" == "pi4-biasi" \]\]; then\s+.*?hydrate_pi4_numpy_runtime.*?validate_colour_math_runtime/s,
 "the image builder hydrates the upstream packages before validating them");

sub source_text {
 my ($path)=@_;
 open(my $fh,"<",$path) or die "Unable to read $path: $!";
 local $/;
 my $text=<$fh>;
 close($fh);
 return $text;
}

# Nothing else binds the COMMITTED armhf usr/bin/pgen_lut_solve to the C it
# was built from: CI compiles a host build of the source and proves that,
# while the appliance runs this binary. Edit the C, forget src/lut_solver/
# build.sh, and the suite stays green while the device keeps the stale solver.
# build.sh records both hashes; this re-hashes the working tree and fails when
# they drift. The build is reproducible, so the fix is always "run build.sh".
my $manifest_path="$root/src/lut_solver/pgen_lut_solve.manifest";
ok(-f $manifest_path,"the native LUT solver ships a build manifest");
SKIP: {
 skip "no build manifest to check",4 if(!-f $manifest_path);
 open(my $manifest_fh,"<",$manifest_path)
  or die "Unable to read $manifest_path: $!";
 my %recorded;
 while(my $line=<$manifest_fh>) {
  next if($line =~ /\A\s*#/);
  $recorded{$2}=lc($1) if($line =~ /\A([0-9a-fA-F]{64})\s+(\S+)\s*\z/);
 }
 close($manifest_fh);

 sub file_sha256 {
  my ($path)=@_;
  open(my $fh,"<",$path) or return "";
  binmode($fh);
  local $/;
  my $data=<$fh>;
  close($fh);
  return sha256_hex(defined($data) ? $data : "");
 }

 foreach my $rel (qw(src/lut_solver/pgen_lut_solve.c usr/bin/pgen_lut_solve)) {
  ok(defined($recorded{$rel}),"the manifest records $rel");
  is(file_sha256("$root/$rel"),$recorded{$rel} || "",
   "$rel matches the manifest; if not, rerun src/lut_solver/build.sh");
 }
}

done_testing();
