use strict;
use warnings;
use File::Temp qw(tempdir);
use MIME::Base64 qw(encode_base64);

my $path = 'usr/share/PGenerator/webui.pm';
open(my $fh, '<', $path) or die "Failed to open $path: $!\n";
local $/;
my $source = <$fh>;
close($fh);

sub extract_between {
 my ($start, $end) = @_;
 my $start_idx = index($source, $start);
 die "Missing block start: $start\n" if $start_idx < 0;
 my $end_idx = index($source, $end, $start_idx);
 die "Missing block end: $end\n" if $end_idx < 0;
 return substr($source, $start_idx, $end_idx - $start_idx);
}

sub perl_sq {
 my ($text) = @_;
 $text =~ s/\\/\\\\/g;
 $text =~ s/'/\\'/g;
 return "'$text'";
}

my $json_escape = extract_between('sub _webui_json_escape (@) {', "\nmy \$_diag_video_sequence_root=");
my $normalize_repair = extract_between('sub _webui_ccss_normalize_keywords (@) {', "\nsub resolve_display_type (@)");
my $storage_helpers = extract_between('sub _webui_ensure_custom_storage_dir (@) {', "\nsub webui_ccss_upload (@)");
my $upload = extract_between('sub webui_ccss_upload (@) {', "\nsub _webui_ccss_create_write_state (@)");
my $safe_filename = extract_between('sub _webui_ccss_safe_filename (@) {', "\nsub _webui_ccss_guess_meta (@)");

sub build_upload_runner {
 my ($pkg, $primary, $legacy) = @_;
 my $code =
  "package $pkg;\n".
  "no strict;\nno warnings;\n".
  "use MIME::Base64 qw(decode_base64);\n".
  "my \$_custom_ccss_dir=".perl_sq($primary).";\n".
  "my \$_custom_ccss_legacy_dir=".perl_sq($legacy).";\n".
  q{
sub log {}
sub read_from_file {
 my ($path)=@_;
 return "" if(!open(my $fh,"<:raw",$path));
 local $/;
 my $raw=<$fh>;
 close($fh);
 return $raw;
}
sub _webui_ccss_from_ti3 { return (0,"TI3 path not used",""); }
sub csv_to_ccss { return undef; }
}.
  $json_escape.
  $normalize_repair.
  $storage_helpers.
  $upload.
  $safe_filename.
  "\n1;";
 my $loaded = eval $code;
 die "Failed to load CCSS upload helpers: $@\n" if !$loaded;
 no strict 'refs';
 return \&{"${pkg}::webui_ccss_upload"};
}

sub assert_contains {
 my ($text, $needle, $message) = @_;
 die "$message\nMissing: $needle\nPayload: $text\n" if index($text, $needle) < 0;
}

my $raw_ccss = <<'CCSS_DATA';
CCSS
ORIGINATOR "PGenerator regression"
DESCRIPTOR "Storage probe"
KEYWORD "DISPLAY"
DISPLAY "Storage probe"
NUMBER_OF_FIELDS 4
BEGIN_DATA_FORMAT
SAMPLE_ID SPEC_380 SPEC_390 SPEC_400
END_DATA_FORMAT
NUMBER_OF_SETS 1
BEGIN_DATA
white 1.0 1.0 1.0
END_DATA
CCSS_DATA

my $body = '{"name":"Storage Probe","filename":"probe.ccss","content":"'.encode_base64($raw_ccss, '').'"}';

my $tmpdir = tempdir(CLEANUP => 1);

my $primary = "$tmpdir/primary/ccss/custom";
my $legacy = "$tmpdir/legacy/custom";
my $primary_runner = build_upload_runner('CCSSPrimaryStorage', $primary, $legacy);
my $primary_result = $primary_runner->($body);
assert_contains($primary_result, '"status":"ok"', 'Upload should create and use primary custom storage');
die "Expected upload in primary storage\n" if !-f "$primary/Storage_Probe.ccss";
die "Upload should not fall back when primary is writable\n" if -f "$legacy/Storage_Probe.ccss";

my $not_a_dir = "$tmpdir/not-a-dir";
open(my $block_fh, '>', $not_a_dir) or die "Failed to create blocking file: $!\n";
print $block_fh "not a directory\n";
close($block_fh);

my $blocked_primary = "$not_a_dir/ccss/custom";
my $fallback_legacy = "$tmpdir/fallback/custom";
my $fallback_runner = build_upload_runner('CCSSFallbackStorage', $blocked_primary, $fallback_legacy);
my $fallback_result = $fallback_runner->($body);
assert_contains($fallback_result, '"status":"ok"', 'Upload should use legacy custom storage when primary cannot be created');
die "Expected upload in fallback custom storage\n" if !-f "$fallback_legacy/Storage_Probe.ccss";

print "CCSS custom storage regression checks passed.\n";
