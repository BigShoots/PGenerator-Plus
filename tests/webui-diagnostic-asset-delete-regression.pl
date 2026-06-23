#!/usr/bin/env perl
# Test that the WebUI has a delete affordance for custom diagnostic
# videos/images: server-side handler, HTTP route, markup, CSS, and
# client-side JS.
#
# Background: prior to this change, users could upload custom diagnostic
# videos and images via the WebUI's "Upload video..." / "Upload image..."
# sentinels in the Diagnostic Patterns card, but there was no way to remove
# them from the WebUI. The only path was SSH + manual rm. The new
# affordance adds a third icon button (trash can) next to the existing
# play and stop buttons in each diag-custom-picker; clicking it deletes
# the selected file via POST /api/diagnostic/delete.
#
# This is a source-only test, no live renderer required.
use strict;
use warnings;
use Test::More;

my $src_path = 'usr/share/PGenerator/webui.pm';
open(my $fh, '<', $src_path) or BAIL_OUT("can't read $src_path: $!");
local $/; my $src = <$fh>; close $fh;

# ---------------------------------------------------------------------------
# 1. Server: the webui_diag_asset_delete sub must exist with the right
#    shape -- it has to funnel the filename through the same
#    _webui_diag_asset_safe_filename sanitizer the upload path uses
#    (path-traversal protection), refuse invalid kinds/filenames, and
#    unlink the file.
# ---------------------------------------------------------------------------
like($src, qr/sub webui_diag_asset_delete\b/,
     'webui.pm defines webui_diag_asset_delete sub');

my $delete_sub_re = qr/sub webui_diag_asset_delete[^{]*\{([\s\S]*?)\n\}/;
my ($delete_body) = $src =~ /$delete_sub_re/;
ok(defined($delete_body), 'extracted webui_diag_asset_delete body')
  or BAIL_OUT("webui_diag_asset_delete body not found -- sub was refactored, update test");

# Must reject missing kind, missing filename, and unknown kind.
like($delete_body, qr/Invalid asset type/,
     'delete sub rejects unknown kind');
like($delete_body, qr/Invalid filename/,
     'delete sub rejects empty/unsafe filename');
like($delete_body, qr/File not found/,
     'delete sub rejects missing file');

# Must funnel the filename through the safe-filename sanitizer (same path
# as the upload handler), and unlink the file.
like($delete_body, qr/_webui_diag_asset_safe_filename/,
     'delete sub sanitises filename via _webui_diag_asset_safe_filename');
like($delete_body, qr/unlink\(\$path\)/,
     'delete sub unlinks the file');
like($delete_body, qr/Delete failed/,
     'delete sub surfaces a Delete failed error when unlink returns false');

# Must wipe the .diagseq/<key>/ renderer-frame cache for videos so a
# re-upload of the same name does not pick up stale frames.
like($delete_body, qr/_webui_diag_asset_video_sequence_dir/,
     'delete sub looks up the video sequence dir');
like($delete_body, qr/_webui_diag_asset_reset_dir/,
     'delete sub wipes the video sequence dir');
# ... and only for videos, not images.
like($delete_body, qr/\$resolved_kind eq "video"[\s\S]{0,200}?_webui_diag_asset_video_sequence_dir/,
     'delete sub only touches the sequence dir for videos');

# Must log on success.
like($delete_body, qr/&log\("WebUI: custom diagnostic \$resolved_kind deleted/,
     'delete sub logs the deletion');

# Must return status:ok with the deleted filename on success.
like($delete_body, qr/\{"status":"ok","filename":/,
     'delete sub returns status:ok with deleted filename');

# ---------------------------------------------------------------------------
# 2. HTTP route: POST /api/diagnostic/delete must dispatch to the new sub.
# ---------------------------------------------------------------------------
like($src, qr|\$path eq "/api/diagnostic/delete" && \$method eq "POST"|,
     'POST /api/diagnostic/delete route is wired');
like($src, qr|/api/diagnostic/delete" && \$method eq "POST"[\s\S]{0,200}?webui_diag_asset_delete|,
     'route dispatches to webui_diag_asset_delete');

# The new route must sit alongside the other diagnostic routes, not
# inside the CCSS dispatcher block.
like($src, qr{/api/diagnostic/upload[\s\S]{0,1500}?/api/diagnostic/video-sequence[\s\S]{0,800}?/api/diagnostic/delete}s,
     'diagnostic route block ordering (upload -> video-sequence -> delete) is intact');

# ---------------------------------------------------------------------------
# 3. Markup: the diagnostic-picker must now have THREE icon buttons
#    (play, stop, delete) and the delete button must be disabled by
#    default until a custom entry is picked.
# ---------------------------------------------------------------------------
# Video picker.
like($src, qr/id="diagCustomVideoDelete"[\s\S]{0,400}?onclick="diagDeleteSelectedAsset\('video'\)"[\s\S]{0,400}?disabled/,
     'video picker has #diagCustomVideoDelete calling diagDeleteSelectedAsset and is initially disabled');
# Image picker.
like($src, qr/id="diagCustomImageDelete"[\s\S]{0,400}?onclick="diagDeleteSelectedAsset\('image'\)"[\s\S]{0,400}?disabled/,
     'image picker has #diagCustomImageDelete calling diagDeleteSelectedAsset and is initially disabled');

# Both buttons use the .diag-asset-icon-btn-delete modifier so the
# disabled state and red-hover styling reach them.
like($src, qr/diag-asset-icon-btn-delete/,
     'delete buttons carry the .diag-asset-icon-btn-delete class');

# Sanity: still has play and stop buttons on both pickers (regression
# guard so the new button doesn't accidentally replace one of them).
like($src, qr/diagPlaySelectedAsset\('video'\)/,
     'video picker still has play button');
like($src, qr/onclick="stopPattern\(\)" title="Stop custom diagnostic video"/,
     'video picker still has stop button');
like($src, qr/diagPlaySelectedAsset\('image'\)/,
     'image picker still has play button');
like($src, qr/onclick="stopPattern\(\)" title="Stop custom diagnostic image"/,
     'image picker still has stop button');

# ---------------------------------------------------------------------------
# 4. CSS: the picker grid must grow a 4th column and the delete button
#    needs disabled + hover-red styling.
# ---------------------------------------------------------------------------
# Grid was 3-col "minmax(0,1fr) 32px 32px", now 4-col "... 32px 32px 32px".
like($src, qr/diag-custom-picker\{display:grid;grid-template-columns:minmax\(0,1fr\) 32px 32px 32px/,
     'diag-custom-picker is now a 4-column grid (select + play + stop + delete)');

# Disabled state on the delete button.
like($src, qr/diag-asset-icon-btn-delete:disabled\{opacity:\.35;cursor:not-allowed/,
     'delete button has a disabled visual state (opacity + cursor)');
# Hover-red so the destructive intent is telegraphed.
like($src, qr/diag-asset-icon-btn-delete:not\(:disabled\):hover\{color:var\(--red\);border-color:var\(--red\)/,
     'delete button hovers red when enabled');

# ---------------------------------------------------------------------------
# 5. Client JS: the new diagDeleteSelectedAsset and diagUpdateDeleteButtonState
#    functions must exist, and the button-state updater must be called
#    everywhere the picker state can change.
# ---------------------------------------------------------------------------
like($src, qr/function diagUpdateDeleteButtonState\b/,
     'JS defines diagUpdateDeleteButtonState');
like($src, qr/async function diagDeleteSelectedAsset\b/,
     'JS defines async diagDeleteSelectedAsset');

# Must ask the user to confirm before firing the request.
like($src, qr/async function diagDeleteSelectedAsset\([^{]*\{[\s\S]{0,600}?confirm\('Delete custom diagnostic /,
     'diagDeleteSelectedAsset prompts the user with confirm()');

# Must stop the renderer first if the deleted file is currently playing.
like($src, qr/async function diagDeleteSelectedAsset\([^{]*\{[\s\S]{0,800}?diagAssetPatternToken\([\s\S]{0,200}?await stopPattern/,
     'diagDeleteSelectedAsset stops the renderer first when the deleted file is the active pattern');

# Must POST to the new endpoint with kind+filename and a timeout.
like($src, qr/async function diagDeleteSelectedAsset\([^{]*\{[\s\S]{0,1500}?fetchJSON\('\/api\/diagnostic\/delete'[\s\S]{0,400}?_timeoutMs:8000/,
     'diagDeleteSelectedAsset POSTs to /api/diagnostic/delete with 8s timeout');

# diagUpdateDeleteButtonState must be invoked from diagRenderAssetSelect
# and diagHandleAssetSelect so the button enables/disables with the
# <select>.
my ($render_body) = $src =~ /function diagRenderAssetSelect\([^{]*\{([\s\S]*?)\n\}/;
ok(defined($render_body), 'extracted diagRenderAssetSelect body')
  or BAIL_OUT("diagRenderAssetSelect body not found -- function was refactored, update test");
like($render_body, qr/diagUpdateDeleteButtonState\(kind\)/,
     'diagRenderAssetSelect calls diagUpdateDeleteButtonState');

# diagHandleAssetSelect must also update the button state.
like($src, qr/diagSetInfoHtml\(diagAssetInfoHtml\(kind,value\)\);\s*diagUpdateDeleteButtonState\(kind\)/s,
     'diagHandleAssetSelect calls diagUpdateDeleteButtonState after a selection');

# ---------------------------------------------------------------------------
# 6. Negative path: the JS handler must refuse to fire when the select is
#    empty or pointing at the upload sentinel.
# ---------------------------------------------------------------------------
my ($delete_js) = $src =~ /async function diagDeleteSelectedAsset\([^{]*\{([\s\S]*?)\n\}/;
ok(defined($delete_js), 'extracted diagDeleteSelectedAsset body')
  or BAIL_OUT("diagDeleteSelectedAsset body not found -- function was refactored, update test");
like($delete_js, qr/filename===DIAG_UPLOAD_SENTINEL\)\s*return/,
     'diagDeleteSelectedAsset no-ops on the upload sentinel');
like($delete_js, qr/!filename \|\| filename===DIAG_UPLOAD_SENTINEL\)\s*return/,
     'diagDeleteSelectedAsset no-ops on an empty selection');
like($delete_js, qr/!files\.includes\(filename\)\)\s*return/,
     'diagDeleteSelectedAsset no-ops on a filename not in the current catalog');

# ---------------------------------------------------------------------------
# 7. The pre-fix code (no delete affordance) must not be there. We
#    verify by checking that the old 3-column grid template no longer
#    appears, AND that the two pickers no longer have only two icon
#    buttons each.
# ---------------------------------------------------------------------------
unlike($src, qr/diag-custom-picker\{display:grid;grid-template-columns:minmax\(0,1fr\) 32px 32px(?! 32px)/,
     'old 3-column diag-custom-picker grid is gone');

done_testing();
