use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

# Issue 74: the RQ3V1 kernel add-on (src/ofxRPI4Window/vc4_rgb_limited_unity.patch)
# must apply cleanly to the known post-image of drm_vc4.patch (the base requirement
# in its header) and must produce exactly the intended result.  The PRE fixtures
# below are lifted from the '+' side of drm_vc4.patch; if that patch ever changes
# these regions, this test failing is a prompt to re-audit the add-on, not just to
# refresh the fixtures.

sub read_file {
 open my $fh, '<', $_[0] or die "$!";
 local $/;
 return <$fh>;
}

my $patch="$Bin/../src/ofxRPI4Window/vc4_rgb_limited_unity.patch";
plan skip_all=>'missing '.$patch unless -f $patch;

my $tmp=tempdir(CLEANUP=>1);
mkdir "$tmp/drivers"; mkdir "$tmp/drivers/gpu"; mkdir "$tmp/drivers/gpu/drm"; mkdir "$tmp/drivers/gpu/drm/vc4";
mkdir "$tmp/scripts"; mkdir "$tmp/scripts/mod";

my $pre_hdmi=<<'FIXTURE_END_HDMI';
#define HDMI_14_MAX_TMDS_CLK   (340 * 1000 * 1000)

static bool vc4_hdmi_mode_needs_scrambling(const struct drm_display_mode *mode)
{
	return (mode->clock * 1000) > HDMI_14_MAX_TMDS_CLK;
}

static bool vc4_hdmi_is_full_range_rgb(struct vc4_hdmi *vc4_hdmi,
				       const struct drm_connector_state *conn_state,
				       const struct drm_display_mode *mode)
{
	struct vc4_hdmi_encoder *vc4_encoder = &vc4_hdmi->encoder;
	enum drm_hdmi_broadcast_rgb broadcast_rgb =
		conn_state ? conn_state->broadcast_rgb : DRM_HDMI_BROADCAST_RGB_AUTO;

	if (broadcast_rgb == DRM_HDMI_BROADCAST_RGB_FULL)
		return true;

	if (broadcast_rgb == DRM_HDMI_BROADCAST_RGB_LIMITED)
		return false;

	return !vc4_encoder->hdmi_monitor ||
		drm_default_rgb_quant_range(mode) == HDMI_QUANTIZATION_RANGE_FULL;
}

static int vc4_hdmi_debugfs_regs(struct seq_file *m, void *unused)
{
	return 0;
}

static void vc4_hdmi_csc_setup(struct vc4_hdmi *vc4_hdmi,
			       const struct drm_connector_state *conn_state,
			       const struct drm_display_mode *mode)
{
	u32 if_cfg = 0;
	u32 if_xbar = 0x203010;

	switch (vc4_hdmi->output_format) {
	case DRM_COLOR_FORMAT_YCRCB422:
		break;

	case DRM_COLOR_FORMAT_RGB444:
		if_xbar = 0x354021;

		if (!vc4_hdmi_is_full_range_rgb(vc4_hdmi, conn_state, mode))
			vc5_hdmi_set_csc_coeffs(vc4_hdmi, vc5_hdmi_csc_full_rgb_to_limited_rgb);
		else
			vc5_hdmi_set_csc_coeffs(vc4_hdmi, vc5_hdmi_csc_full_rgb_unity);
		break;

	default:
		break;
	}

	HDMI_WRITE(HDMI_VEC_INTERFACE_CFG, if_cfg);
	HDMI_WRITE(HDMI_VEC_INTERFACE_XBAR, if_xbar);
}
FIXTURE_END_HDMI
my $post_hdmi=<<'FIXTURE_END_HDMI2';
#define HDMI_14_MAX_TMDS_CLK   (340 * 1000 * 1000)

static bool vc4_hdmi_mode_needs_scrambling(const struct drm_display_mode *mode)
{
	return (mode->clock * 1000) > HDMI_14_MAX_TMDS_CLK;
}

/*
 * PGenerator issue 74: extended "rgb quant range" value 3.
 *
 * The renderer needs Limited signalling (AVI infoframe and CEA wire
 * levels) without the 0x1b80/0x0400 compress matrix: squashing 256
 * full-range codes through that fixed-point matrix is lossy, so for
 * its own patterns the generator draws the Limited wire codes itself
 * and asks the CSC to stay at unity.  Value 3 behaves exactly like
 * LIMITED everywhere except the CSC coefficient selection.
 *
 * LIMITED and FULL occupy two of {1,2} in this tree's
 * enum drm_hdmi_broadcast_rgb, so 3 is free; see the commit message
 * for the build-time checks.
 */
#define DRM_HDMI_BROADCAST_RGB_LIMITED_UNITY	3

static bool vc4_hdmi_rgb_limited_unity(const struct drm_connector_state *conn_state)
{
	return conn_state &&
	       conn_state->broadcast_rgb == DRM_HDMI_BROADCAST_RGB_LIMITED_UNITY;
}

static bool vc4_hdmi_is_full_range_rgb(struct vc4_hdmi *vc4_hdmi,
				       const struct drm_connector_state *conn_state,
				       const struct drm_display_mode *mode)
{
	struct vc4_hdmi_encoder *vc4_encoder = &vc4_hdmi->encoder;
	enum drm_hdmi_broadcast_rgb broadcast_rgb =
		conn_state ? conn_state->broadcast_rgb : DRM_HDMI_BROADCAST_RGB_AUTO;

	if (broadcast_rgb == DRM_HDMI_BROADCAST_RGB_FULL)
		return true;

	if (broadcast_rgb == DRM_HDMI_BROADCAST_RGB_LIMITED ||
	    broadcast_rgb == DRM_HDMI_BROADCAST_RGB_LIMITED_UNITY)
		return false;

	return !vc4_encoder->hdmi_monitor ||
		drm_default_rgb_quant_range(mode) == HDMI_QUANTIZATION_RANGE_FULL;
}

static int vc4_hdmi_debugfs_regs(struct seq_file *m, void *unused)
{
	return 0;
}

static void vc4_hdmi_csc_setup(struct vc4_hdmi *vc4_hdmi,
			       const struct drm_connector_state *conn_state,
			       const struct drm_display_mode *mode)
{
	u32 if_cfg = 0;
	u32 if_xbar = 0x203010;

	switch (vc4_hdmi->output_format) {
	case DRM_COLOR_FORMAT_YCRCB422:
		break;

	case DRM_COLOR_FORMAT_RGB444:
		if_xbar = 0x354021;

		if (!vc4_hdmi_is_full_range_rgb(vc4_hdmi, conn_state, mode) &&
		    !vc4_hdmi_rgb_limited_unity(conn_state))
			vc5_hdmi_set_csc_coeffs(vc4_hdmi, vc5_hdmi_csc_full_rgb_to_limited_rgb);
		else
			vc5_hdmi_set_csc_coeffs(vc4_hdmi, vc5_hdmi_csc_full_rgb_unity);
		break;

	default:
		break;
	}

	HDMI_WRITE(HDMI_VEC_INTERFACE_CFG, if_cfg);
	HDMI_WRITE(HDMI_VEC_INTERFACE_XBAR, if_xbar);
}
FIXTURE_END_HDMI2
my $pre_mod=<<'FIXTURE_END_MOD';
static void add_srcversion(struct buffer *b, struct module *mod)
{
	if (mod->srcversion[0]) {
		buf_printf(b, "\n");
		buf_printf(b, "MODULE_INFO(srcversion, \"%s\");\n",
			   mod->srcversion);
	}
}
FIXTURE_END_MOD
my $post_mod=<<'FIXTURE_END_MOD2';
static void add_srcversion(struct buffer *b, struct module *mod)
{
	if (mod->srcversion[0]) {
		/* PGenerator: stamp builds of vc4.ko that carry the RGB
		 * Limited unity-CSC hunk; the renderer greps the module's
		 * srcversion for RQ3V1 before switching to that path.
		 */
		const char *marker = strcmp(mod->name, "vc4") ? "" : "RQ3V1-";

		buf_printf(b, "\n");
		buf_printf(b, "MODULE_INFO(srcversion, \"%s%s\");\n",
			   marker, mod->srcversion);
	}
}
FIXTURE_END_MOD2

open my $fh,'>',"$tmp/drivers/gpu/drm/vc4/vc4_hdmi.c" or die $!; print $fh $pre_hdmi; close $fh;
open $fh,'>',"$tmp/scripts/mod/modpost.c" or die $!; print $fh $pre_mod; close $fh;

my $rc=system("cd $tmp && patch -p1 --forward --fuzz=0 -s < ".$patch." 2>/dev/null");
is($rc,0,'add-on applies to the drm_vc4.patch post-image with zero fuzz');

is(read_file("$tmp/drivers/gpu/drm/vc4/vc4_hdmi.c"),$post_hdmi,'vc4_hdmi.c post-image exact');
is(read_file("$tmp/scripts/mod/modpost.c"),$post_mod,'modpost.c post-image exact');

my $rt=read_file("$Bin/../src/ofxRPI4Window/src/ofxRPI4Window.cpp");
like($rt,qr/RQ3V1/,'renderer greps for the RQ3V1 srcversion marker');
like($rt,qr/wireRgbQuantRange/,'renderer maps conf Limited onto wire value 3 only behind the marker');

my $body=read_file($patch);
my $hunks=()=$body=~/^@@ /mg;
cmp_ok($hunks,'>=',4,'add-on carries all four hunks');
like($body,qr/DRM_HDMI_BROADCAST_RGB_LIMITED_UNITY/,'unity enum extension present');

done_testing();
