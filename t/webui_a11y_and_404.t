#!/usr/bin/perl
# Exploratory QA (dogfood pass, Sep 2026) found the Web UI's visible field
# captions were plain sibling text: no <label for=...> and no aria-label, so
# screen readers announced ~80 controls as unlabeled combos, unknown page routes
# answered with a bare "404 Not Found" body, and out-of-range HDR metadata
# numbers only surfaced through the native validationMessage. These assertions
# pin the fixes in the shipped fragments: every visible input/select in the
# page fragments must have a programmatic label, apPass must stay a visible
# autofill-free text field (see the AP section for why), the
# page 404 must be an HTML page with a link home, and the calibration chip must
# read unambiguously. A companion sweep covers controls the JS files render at
# runtime (innerHTML string-built tags), where the static fragment scan cannot
# see them. Model: t/dv_transport_lldv_retired.t (static fragments).
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $dir = "$Bin/../usr/share/PGenerator";

sub slurp {
 my ($name)=@_;
 open(my $fh, '<:raw', "$dir/$name") or die "open $name: $!";
 local $/; my $c=<$fh>; close($fh);
 return $c;
}

my %frag = map { $_ => slurp($_) }
 qw(webui.html webui-body.html webui-automation.html webui-lg-card.html icc_profile.html);
my $all = join("\n", values %frag);

# --- label associations -------------------------------------------------
# A control counts as labeled when any of: aria-label on the tag,
# aria-labelledby (a caption element the app re-labels at runtime, e.g. the
# panel-light row), a <label for="id"> anywhere in the assembled page, or it
# is wrapped by an open <label> whose close tag comes after the control.
my @unlabeled;
for my $file (sort keys %frag) {
 my $c = $frag{$file};
 while ($c =~ /(<(?:select|input)\b[^>]*\bid="([^"]+)"[^>]*>)/g) {
  my ($tagfull, $id) = ($1, $2);
  my $start = $-[0]; # capture before further matches clobber @-
  my ($tag) = $tagfull =~ /^(<[^\s>]+)/;
  my $hidden = $tagfull =~ /type="hidden"/;
  next if $hidden;
  next if $tagfull =~ /aria-label/;
  # aria-hidden management selects (automation panel policy) are intentionally
  # invisible to AT and excluded from the tab order.
  next if $tagfull =~ /aria-hidden="true"/ && $tagfull =~ /tabindex="-1"/;
  next if $all =~ /<label[^>]*\bfor="\Q$id\E"/;
  # wrapped label: last <label before the control with no </label> between
  my $pre = substr($c, 0, $start);
  my $li = rindex($pre, '<label');
  next if $li >= 0 && index(substr($pre, $li), '</label>') < 0;
  push @unlabeled, "$file: $tag#$id";
 }
}
is_deeply(\@unlabeled, [], 'every visible input/select has a programmatic label')
 or diag explain \@unlabeled;

# Every label 'for' must resolve to an id that exists in the assembled page.
my @dangling;
for my $file (sort keys %frag) {
 while ($frag{$file} =~ /<label[^>]*\bfor="([^"]+)"/g) {
  push @dangling, "$file: for=\"$1\"" unless $all =~ /\bid="\Q$1\E"/;
 }
 # aria-labelledby names a caption element; a missing target means the
 # control silently loses its accessible name (the panel-light caption span
 # is renamed at runtime, so the id is the contract, not the text).
 while ($frag{$file} =~ /\baria-labelledby="([^"]+)"/g) {
  push @dangling, "$file: aria-labelledby=\"$1\"" unless $all =~ /\bid="\Q$1\E"/;
 }
}
is_deeply(\@dangling, [], 'no label targets a missing id');

# A help-tip span inside a control's <label> contributes its own aria-label
# ("… help") to the control's accessible name — "Target Colorspace Target
# colorspace help". aria-hidden keeps the tip readable as a hover target
# while the control name stays exactly the visible caption.
my @tip_pollution;
for my $file (sort keys %frag) {
 while ($frag{$file} =~ /<label\b[^>]*\bfor="[^"]*"[^>]*>((?:(?!<\/label>)[\s\S])*?)<\/label>/g) {
  my $inner = $1;
  while ($inner =~ /<span class="meter-help-tip"([^>]*)>/g) {
   push @tip_pollution, "$file: $1" if $1 !~ /aria-hidden="true"/;
  }
 }
}
is_deeply(\@tip_pollution, [], 'help spans inside control labels stay out of the accessible name')
 or diag explain \@tip_pollution;

# Same guarantee for controls the app JS renders at runtime via innerHTML
# string-built tags: the static fragment scan above cannot see those lines.
# Physical lines starting with '+' are joined into one logical line (these
# builders concatenate tags across lines), the scan counts an interpolated
# aria-label="'+...+'" as labeled, and it exempts controls wrapped inside a
# <label> still open before them. Comment lines are skipped.
my @dyn_unlabeled;
sub scan_logical {
 my ($js, $logical)=@_;
 return if $logical =~ /^\s*(?:\/\/|\*)/;
 return if $logical =~ /a\s+<(?:input|select)>/; # prose, not markup
 while ($logical =~ /(<(?:input|select)\b[^>]*?)(?:>|\z)/g) {
  my $tag = $1;
  my $start = $-[0]; # capture before further matches clobber @-
  next if $tag =~ /type="hidden"/;
  next if $tag =~ /aria-label/;
  if ($tag =~ /\bid="([^"]+)"/) {
   my $id = $1;
   next if $logical =~ /<label[^>]*\bfor="\Q$id\E"/;
  }
  my $pre = substr($logical, 0, $start);
  my $li = rindex($pre, '<label');
  next if $li >= 0 && index(substr($pre, $li), '</label>') < 0;
  push @dyn_unlabeled, "$js: $tag";
 }
}
opendir(my $dh, $dir) or die "opendir: $!";
for my $js (sort grep { /\.js$/ } readdir($dh)) {
 my $logical = '';
 for my $line (split /\n/, slurp($js)) {
  next if $line =~ /^\s*(?:\/\/|\*)/;
  if ($logical ne '' && $line =~ /^\s*\+/) { $logical .= $line; next; }
  scan_logical($js, $logical) if $logical ne '';
  $logical = $line;
 }
 scan_logical($js, $logical) if $logical ne '';
}
is_deeply(\@dyn_unlabeled, [], 'runtime-rendered controls carry labels too')
 or diag explain \@dyn_unlabeled;

# --- AP passphrase field ------------------------------------------------
# The AP passphrase is shown, not masked: it is the appliance's own hotspot
# key (the owner has to read it to join, and the default is not printed
# anywhere else), and loadAP() pre-fills it. A pre-filled type="password"
# under the SSID text field reads as a login form, so browsers offered to
# save a username and password on every visit. Keep it a plain text field
# with autocomplete off and password-manager ignore hints.
unlike($frag{'webui-body.html'}, qr/<input[^>]*\btype="password"[^>]*\bid="apPass"/,
 'the AP passphrase is a visible text field, not a password field');
like($frag{'webui-body.html'}, qr/\bid="apPass"[^>]*autocomplete="off"/,
 'apPass opts out of autofill');
like($frag{'webui-body.html'}, qr/\bid="apSsid"[^>]*autocomplete="off"/,
 'apSsid is not offered as a saved username');

# --- CCMX matrix cell direction -----------------------------------------
# ArgyllCMS applies out = M x in (see pgen-icc-companion.c: out[row] =
# sum(M[row][c] * in[c])), so cell (r,c) carries measured component c into
# corrected component r: M12 is Y->X, not X->Y. The aria-labels carry the
# semantic hint (the grid has no visible axis labels), so a transposed label
# files values into the wrong cells for screen-reader users.
like($frag{'webui-body.html'}, qr/id="meterCcmxM12"[^>]*aria-label="Matrix row 1 column 2 \(Y to X\)"/,
 'CCMX cell M12 is labelled by its actual direction (Y to X)');
like($frag{'webui-body.html'}, qr/id="meterCcmxM21"[^>]*aria-label="Matrix row 2 column 1 \(X to Y\)"/,
 'CCMX cell M21 is labelled by its actual direction (X to Y)');

# --- styled page 404 ------------------------------------------------------
my $pm;
{
 open(my $fh, '<:raw', "$dir/webui.pm") or die "open webui.pm: $!";
 local $/; $pm = <$fh>; close($fh);
}
like($pm, qr/sub webui_not_found_html/, 'webui.pm builds a styled 404 page');
like($pm, qr/webui_not_found_html\(\$path\)/, 'the page 404 catch-all serves the styled page');
like($pm, qr/PG_404_PAGE/, 'the 404 page carries its marker');

# Call the real function rather than grepping its source: a branch swap or a
# copy of the template without the escaper still passes a source-text pin.
# webui.pm is loadable standalone (subdefinitions only; the daemon entry
# point guards on !caller()).
require "$dir/webui.pm";
my $page = main::webui_not_found_html('/no/such/page?x=1"onload=alert(1)>');
like($page, qr/PG_404_PAGE/, 'the served 404 carries the page marker');
like($page, qr/<a class="button" href="\/">/, 'the 404 links back to the Web UI');
like($page, qr{<code>/no/such/page\?x=1&quot;onload=alert\(1\)&gt;</code>},
 'the requested path is echoed escaped, so it stays inert text');
unlike($page, qr/x=1"[^&]/, 'the echoed path carries no raw quote that could break out of the element');
my $utf = main::webui_not_found_html('/tëst<em>');
like($utf, qr/tëst&lt;em&gt;/, 'non-ASCII paths survive and markup is escaped');
is(main::webui_not_found_html(undef) =~ /<code>([^<]*)</ ? $1 : 'X', '',
 'an undefined path renders an empty code element without dying');

# Unknown API routes must keep the compact body clients parse. The pin reads
# the catch-all 404 block itself — comment line through the styled print —
# so it cannot be satisfied by the unrelated /api/ route matchers elsewhere
# in webui.pm that a whole-file regex would match.
my ($block404) = $pm =~ /(# Unknown page routes[\s\S]*?charset=utf-8[^\n]*)/;
ok($block404, 'the catch-all page-404 block is present');
ok(defined($block404) && index($block404, '$path=~/^\\/api\\//') >= 0
 && index($block404, '$path=~/^\\/api\\//') < index($block404, '&webui_not_found_html($path)')
 && index($block404, '$msg="404 Not Found"') >= 0
 && index($block404, '$msg="404 Not Found"') < index($block404, '&webui_not_found_html($path)'),
 'the page 404 branch keeps /api/* on the compact response');
ok(defined($block404) && index($block404, '&webui_not_found_html($path)') >= 0,
 'the page 404 branch serves the styled page');

# --- calibration chip wording --------------------------------------------
unlike($frag{'webui-body.html'}, qr/>No SW</, 'the header chip no longer reads cryptic "No SW"');
my $appjs = slurp('webui-app.js');
like($appjs, qr/Cal: none/, 'the disconnected calibration chip reads "Cal: none"');
like($appjs, qr/title='Calibration software: not connected\./,
 'the chip tooltip explains what the indicator means');

# --- out-of-range metadata feedback --------------------------------------
like(slurp('webui-theme.css'), qr/input\[type=number\]:out-of-range/,
 'out-of-range number fields get a visible border');
like(slurp('webui-app.js'), qr/aria-invalid/,
 'validity is mirrored onto aria-invalid for assistive tech');
# Programmatic .value writes fire no input/change event: the shared refresher
# must exist AND be called from every direct-write site (config seed,
# resetDefaults, the DV field copy) or aria-invalid goes stale there.
{
 my $js = slurp('webui-app.js');
 my $calls = () = $js =~ /if\(typeof pgRefreshHdrMetadataValidity==='function'\) pgRefreshHdrMetadataValidity\(\);/g;
 cmp_ok($calls, '>=', 3, 'every programmatic write of the HDR metadata fields refreshes aria-invalid');
 my ($reset) = $js =~ /(function resetDefaults\(\)\{[\s\S]*?\n\})/;
 ok(defined($reset) && index($reset, 'pgRefreshHdrMetadataValidity();') >= 0,
  'resetDefaults refreshes aria-invalid after loading defaults');
 my ($copy) = $js =~ /(function meterCopyHdrMetadataFields\(fromMode,toMode\)\{[\s\S]*?\n\})/;
 ok(defined($copy) && index($copy, 'pgRefreshHdrMetadataValidity();') >= 0,
  'the DV-mode field copy refreshes aria-invalid');
}

done_testing();
