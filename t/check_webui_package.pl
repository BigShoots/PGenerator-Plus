#!/usr/bin/perl
use strict;
use warnings;

use File::Temp qw(tempdir);

die "usage: $0 <release.tar.gz>\n" unless @ARGV == 1;
my ($archive) = @ARGV;
die "archive does not exist: $archive\n" unless -f $archive;

my @fragments = qw(
    usr/share/PGenerator/webui.html
    usr/share/PGenerator/webui-theme.css
    usr/share/PGenerator/webui-layout.css
    usr/share/PGenerator/webui-body.html
    usr/share/PGenerator/webui-logo-dark.html
    usr/share/PGenerator/webui-app.js
    usr/share/PGenerator/webui-workspace.js
    usr/share/PGenerator/webui-lg-card.html
    usr/share/PGenerator/webui-lg.js
);

# The served page also reads these from disk (server-side splice and
# <script src> routes); a release without them ships a broken UI too.
my @page_assets = qw(
    usr/share/PGenerator/icc_profile.html
    usr/share/PGenerator/icc_profile.css
    usr/share/PGenerator/icc_profile.js
    usr/share/PGenerator/hcfr_chc.js
);

open my $tar_fh, "-|", "tar", "-tzf", $archive
    or die "cannot list $archive with tar: $!\n";
my %entries;
while (my $entry = <$tar_fh>) {
    chomp $entry;
    $entry =~ s{^\./}{};
    $entries{$entry}++;
}
close $tar_fh or die "tar could not read $archive\n";

# macOS bsdtar can embed AppleDouble metadata companions; a device would
# extract them as junk files and the name checks below would not see them.
my @apple_double = sort grep { m{(?:\A|/)\._} } keys %entries;
if (@apple_double) {
    die "AppleDouble metadata entries in $archive (set COPYFILE_DISABLE=1):\n  "
        . join("\n  ", @apple_double[0 .. (@apple_double > 5 ? 4 : $#apple_double)]) . "\n";
}

my @missing = grep { !$entries{$_} } @fragments, @page_assets;
if (@missing) {
    die "missing Web UI files from $archive:\n  " . join("\n  ", @missing) . "\n";
}

# A cumulative archive must contain the nine current fragment names, not a
# mixture of the new split and stale/renamed webui-* files.  Paths without a
# hyphen or .html suffix after "webui", such as webui.pm, stay out of this
# check by construction.
my %expected = map { $_ => 1 } @fragments;
my @fragment_entries = grep {
    m{\Ausr/share/PGenerator/webui(?:\.html|-.*)\z}
} keys %entries;
my @unexpected = sort grep { !$expected{$_} } @fragment_entries;
if (@unexpected) {
    die "unexpected Web UI fragments from $archive:\n  "
        . join("\n  ", @unexpected) . "\n";
}
my @duplicates = sort grep { $entries{$_} > 1 } @fragments;
if (@duplicates) {
    die "duplicate Web UI fragments from $archive:\n  "
        . join("\n  ", @duplicates) . "\n";
}
die "expected exactly " . scalar(@fragments)
    . " Web UI fragment paths, found " . scalar(@fragment_entries) . "\n"
    unless @fragment_entries == @fragments;

# Names are not enough: a truncated fragment would pass every check above and
# boot every updated device onto the recovery page.  One extraction pass
# verifies each file actually carries content.
my $extract_dir = tempdir("pgenerator-webui-check-XXXXXX", TMPDIR => 1, CLEANUP => 1);
system("tar", "-xzf", $archive, "-C", $extract_dir, @fragments, @page_assets) == 0
    or die "cannot extract Web UI files from $archive for content verification\n";
my @empty = grep { !-s "$extract_dir/$_" } @fragments, @page_assets;
if (@empty) {
    die "empty Web UI files in $archive:\n  " . join("\n  ", @empty) . "\n";
}

print "verified ", scalar(@fragments), " Web UI fragments and ",
    scalar(@page_assets), " page assets in $archive\n";
exit 0;
