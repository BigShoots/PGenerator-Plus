#!/usr/bin/perl
use strict;
use warnings;

use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Spec;

# This is intentionally a source slicer, not a line-numbered copy script.
# Every boundary below is discovered from the HTML tag structure in the
# heredoc. If the source layout changes, the assertions fail instead of
# silently producing a subtly different page.

my $repo = dirname(dirname(abs_path(__FILE__)));
my $shared = File::Spec->catdir($repo, "usr", "share", "PGenerator");
my $webui_path = File::Spec->catfile($shared, "webui.pm");
my $lg_path = File::Spec->catfile($shared, "lg.pm");
my $webui_only = @ARGV == 1 && $ARGV[0] eq "--webui-only";
die "usage: $0 [--webui-only]\n" if @ARGV && !$webui_only;

sub read_raw {
    my ($path) = @_;
    open my $fh, "<:raw", $path or die "cannot read $path: $!\n";
    local $/;
    my $content = <$fh> // "";
    close $fh or die "cannot close $path: $!\n";
    return $content;
}

sub write_raw {
    my ($path, $content) = @_;
    die "refusing to write empty fragment $path\n" if $content eq "";
    open my $fh, ">:raw", $path or die "cannot write $path: $!\n";
    print {$fh} $content or die "cannot write $path: $!\n";
    close $fh or die "cannot close $path: $!\n";
}

sub split_lines {
    my ($content) = @_;
    my @lines = split /(?<=\n)/, $content, -1;
    pop @lines if @lines && $lines[-1] eq "";
    die "source contains a non-LF line ending\n" if grep { /\r/ } @lines;
    return @lines;
}

sub only_one {
    my ($label, @values) = @_;
    die "$label: expected exactly one match, found " . scalar(@values) . "\n"
        unless @values == 1;
    return $values[0];
}

sub find_line {
    my ($lines, $regex, $label, $from) = @_;
    $from //= 0;
    my @matches = grep { $_ >= $from && $lines->[$_] =~ $regex } 0 .. $#$lines;
    return only_one($label, @matches);
}

sub find_next_line {
    my ($lines, $regex, $label, $from) = @_;
    for my $index (($from + 1) .. $#$lines) {
        return $index if $lines->[$index] =~ $regex;
    }
    die "$label: no match after line index $from\n";
}

sub slice_lines {
    my ($lines, $first, $last) = @_;
    die "invalid slice $first..$last\n"
        if $first < 0 || $last < $first || $last >= @$lines;
    return join "", @{$lines}[$first .. $last];
}

my @webui = split_lines(read_raw($webui_path));
my @html_sub = grep {
    $webui[$_] =~ /^\s*sub\s+webui_html\s*\(\@\)\s*\{\n\z/
} 0 .. $#webui;
my $sub_line = only_one("webui_html declaration", @html_sub);
die "webui_html is not a single-quoted WEBUI_HTML heredoc\n"
    unless $webui[$sub_line + 1] =~ /^\s*my\s+\$html=<<'WEBUI_HTML';\n\z/;
my $html_first = $sub_line + 2;
my $html_terminator = find_line(\@webui, qr/^WEBUI_HTML\n\z/, "WEBUI_HTML terminator", $html_first);
my $html_last = $html_terminator - 1;
my @html = @webui[$html_first .. $html_last];
my $html_original = join "", @html;

my @style_open = grep { $html[$_] =~ /^<style>\n\z/ } 0 .. $#html;
die "expected two top-level style blocks\n" unless @style_open == 2;
my @styles;
for my $open (@style_open) {
    my $close = find_next_line(\@html, qr/^<\/style>\n\z/, "style terminator", $open);
    push @styles, { open => $open, close => $close };
}

my @inline_open = grep { $html[$_] =~ /^<script>\n\z/ } 0 .. $#html;
die "expected bootstrap plus two application inline scripts\n" unless @inline_open == 3;
my @inline_scripts;
for my $open (@inline_open) {
    my $close = find_next_line(\@html, qr/^<\/script>\n\z/, "inline script terminator", $open);
    push @inline_scripts, { open => $open, close => $close };
}

my $hcfr_external = find_line(\@html, qr{^<script src="/assets/hcfr_chc\.js"></script>\n\z}, "HCFR script tag");
my $icc_external = find_line(\@html, qr{^<script src="/assets/icc_profile\.js"></script>\n\z}, "ICC script tag");
die "external script tags are out of order\n" if $hcfr_external > $icc_external;
die "application scripts do not follow their external tags\n"
    unless $inline_scripts[1]{open} > $hcfr_external
        && $inline_scripts[2]{open} > $icc_external;

my $body_first = $styles[1]{close} + 1;
my $body_last = $hcfr_external - 1;
die "unexpected body boundaries\n"
    unless $html[$body_first] eq "</head>\n" && $body_last >= $body_first;
my @body = @html[$body_first .. $body_last];
my @logo_lines = grep {
    $body[$_] =~ /data:image\/png;base64,/ && $body[$_] =~ /alt="PGenerator\+ logo"/
} 0 .. $#body;
my $logo_index = only_one("embedded dark logo line", @logo_lines);
my $logo_line = $body[$logo_index];
$body[$logo_index] = "__PG_LOGO_DARK__\n";

my @skeleton;
push @skeleton, @html[0 .. $styles[0]{open}];
push @skeleton, "__PG_CSS_THEME__\n";
push @skeleton, @html[$styles[0]{close} .. $styles[1]{open}];
push @skeleton, "__PG_CSS_LAYOUT__\n";
push @skeleton, $html[$styles[1]{close}];
push @skeleton, "__PG_BODY__\n";
push @skeleton, @html[$hcfr_external .. $inline_scripts[1]{open}];
push @skeleton, "__PG_JS_APP__\n";
push @skeleton, @html[$inline_scripts[1]{close} .. $inline_scripts[2]{open}];
push @skeleton, "__PG_JS_WORKSPACE__\n";
push @skeleton, @html[$inline_scripts[2]{close} .. $#html];

my $webui_html = join "", @skeleton;
my %webui_fragments = (
    "webui.html"           => $webui_html,
    "webui-theme.css"      => slice_lines(\@html, $styles[0]{open} + 1, $styles[0]{close} - 1),
    "webui-layout.css"     => slice_lines(\@html, $styles[1]{open} + 1, $styles[1]{close} - 1),
    "webui-body.html"      => join("", @body),
    "webui-logo-dark.html" => $logo_line,
    "webui-app.js"         => slice_lines(\@html, $inline_scripts[1]{open} + 1, $inline_scripts[1]{close} - 1),
    "webui-workspace.js"   => slice_lines(\@html, $inline_scripts[2]{open} + 1, $inline_scripts[2]{close} - 1),
);

my $roundtrip = join "", @skeleton;
for my $replacement (
    ["__PG_CSS_THEME__", "webui-theme.css"],
    ["__PG_CSS_LAYOUT__", "webui-layout.css"],
    ["__PG_BODY__", "webui-body.html"],
    ["__PG_LOGO_DARK__", "webui-logo-dark.html"],
    ["__PG_JS_APP__", "webui-app.js"],
    ["__PG_JS_WORKSPACE__", "webui-workspace.js"],
) {
    my ($marker, $name) = @$replacement;
    my $count = ($roundtrip =~ s/^\Q$marker\E\n/$webui_fragments{$name}/me);
    die "round-trip marker $marker: expected one replacement, found " . ($count || 0) . "\n"
        unless $count == 1;
}
die "extracted webui fragments do not reconstruct the original heredoc\n"
    unless $roundtrip eq $html_original;

for my $name (keys %webui_fragments) {
    write_raw(File::Spec->catfile($shared, $name), $webui_fragments{$name});
}

if (!$webui_only) {
    my @lg = split_lines(read_raw($lg_path));
    my $card_sub = find_line(\@lg, qr/^sub\s+webui_lg_card_html\s*\(\@\)\s*\{\n\z/, "LG card declaration");
    die "LG card is not the expected heredoc\n" unless $lg[$card_sub + 1] eq " return <<'LG_CARD';\n";
    my $card_end = find_next_line(\@lg, qr/^LG_CARD\n\z/, "LG_CARD terminator", $card_sub + 1);
    my $js_sub = find_line(\@lg, qr/^sub\s+webui_lg_js\s*\(\@\)\s*\{\n\z/, "LG JavaScript declaration");
    die "LG JavaScript declaration precedes the card heredoc\n" if $js_sub <= $card_end;
    die "LG JavaScript is not the expected heredoc\n" unless $lg[$js_sub + 1] eq " return <<'LG_JS';\n";
    my $js_end = find_next_line(\@lg, qr/^LG_JS\n\z/, "LG_JS terminator", $js_sub + 1);
    my $card_fragment = slice_lines(\@lg, $card_sub + 2, $card_end - 1);
    my $js_fragment = slice_lines(\@lg, $js_sub + 2, $js_end - 1);
    write_raw(File::Spec->catfile($shared, "webui-lg-card.html"), $card_fragment);
    write_raw(File::Spec->catfile($shared, "webui-lg.js"), $js_fragment);
}

print $webui_only
    ? "sliced webui HTML/JS/CSS from tag-derived boundaries\n"
    : "sliced webui HTML/JS/CSS and LG fragments from tag-derived boundaries\n";
