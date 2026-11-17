use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;

# Execute the real parser/draw methods with an in-memory drawing surface.
# Notifications can then be injected at precise points within a frame.
sub read_file {
    open my $fh, '<', $_[0] or die "$!";
    local $/;
    return <$fh>;
}

my $tmp = tempdir(CLEANUP => 1);
mkdir "$tmp/running" or die "$!";

# CXX may carry arguments ("zig c++"), so split it the way make does.
my @compiler = split(" ", $ENV{CXX} || "");
@compiler = ("c++") if(!@compiler);
my @flags = ('-std=c++11', '-O0');

# Returns ("", output) on success or (reason, output) on failure. Compiler
# chatter is captured so a passing run stays quiet and a failing one reports
# the diagnostics instead of a bare wait status.
sub compile {
    my ($source, $binary) = @_;
    my $log = "$tmp/compile.log";
    my $command = join(" ", map {"'$_'"} (@compiler, @flags, $source, '-o', $binary));
    my $status = system("$command >'$log' 2>&1");
    my $output = -f $log ? read_file($log) : "";
    return ($status == 0 ? "" : "$compiler[0] exited with status $status", $output);
}

# The appliance ships a c++ driver whose assembler is missing, so probe with a
# trivial program rather than testing for the binary. Skipping stops a host
# without a usable toolchain from failing a renderer test it cannot run; the CI
# workflow asserts the compiler so this can never silently vanish there.
open my $probe, '>', "$tmp/probe.cpp" or die "$!";
print {$probe} "int main(){return 0;}\n";
close $probe;
my ($no_compiler) = compile("$tmp/probe.cpp", "$tmp/probe");
plan skip_all => "No working C++ compiler (@compiler): $no_compiler" if($no_compiler);

my $source = read_file("$Bin/../src/pattern_generator/src/ofApp.cpp");
my (@methods, @missing);
for my $name (qw(update draw set_values)) {
    my ($method) = $source =~ /(^void ofApp::\Q$name\E\s*\([^)]*\)\s*\{.*?^\})/ms;
    defined($method) ? push(@methods, $method) : push(@missing, $name);
}
ok(!@missing, 'locate renderer methods in ofApp.cpp') or diag("not extracted: @missing");

SKIP: {
    skip("renderer methods could not be extracted", 2) if(@missing);
    my $harness = read_file("$Bin/fixtures/renderer_pattern_handoff.cpp");
    my $header = read_file("$Bin/../src/ofxRPI4Window/src/ofxRPI4Window.h");
    my ($predicate) = $header =~ /(static bool usesColourShader\(\) \{.*?^    \})/ms;
    die 'Missing shader-selection predicate' unless defined $predicate;
    # Anchor the snapshot on the helper definition itself, not the constant:
    # a constant-anchored lazy match could over-capture any block that later
    # lands between the constant and the helper. Each piece is captured
    # independently, so a missing or renamed piece fails loudly here rather
    # than at compile inside the generated fixture.
    my ($checked_const) = $source =~ /^(static const size_t MAX_PATTERN_FIELD_LEN[^\n]*\n)/m;
    die 'Missing pattern-field length guard' unless defined $checked_const;
    my ($checked_fn) = $source =~ /(^static std::string checked_field\(.*?^\}\n)/ms;
    die 'Missing checked_field() helper definition' unless defined $checked_fn;
    my $checked = $checked_const . "\n" . $checked_fn;
    $harness =~ s{// COLOUR_SHADER_PREDICATE}{$predicate};
    $harness =~ s{// CHECKED_FIELD_HELPER}{$checked};
    $harness =~ s{// REAL_RENDERER_METHODS}{join("\n", @methods)}e;
    open my $cpp, '>', "$tmp/handoff.cpp" or die "$!";
    print {$cpp} $harness;
    close $cpp;

    my ($build_failed, $build_output) = compile("$tmp/handoff.cpp", "$tmp/handoff");
    ok(!$build_failed, 'compile real renderer methods') or diag($build_output);
    skip("renderer harness did not compile", 1) if($build_failed);
    is(system("$tmp/handoff", $tmp), 0,
        'pattern changes preserve complete frames and reload promptly');
}
done_testing();
