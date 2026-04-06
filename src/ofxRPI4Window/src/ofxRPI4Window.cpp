#include "ofxRPI4Window.h"
#include "igt_edid.h"

#include <fcntl.h>
// O_CLOEXEC
//#include <asm-generic/fcntl.h>



#include <sys/ioctl.h>
#include <sys/mman.h>
#define __func__ __PRETTY_FUNCTION__

#define CASE_STR(x,y) case x: str = y; break

const char *format_str(uint32_t format)
{
	switch (format) {
	case DRM_FORMAT_INVALID:
		return "INVALID";
	case DRM_FORMAT_C8:
		return "C8";
	case DRM_FORMAT_R8:
		return "R8";
	case DRM_FORMAT_R16:
		return "R16";
	case DRM_FORMAT_RG88:
		return "RG88";
	case DRM_FORMAT_GR88:
		return "GR88";
	case DRM_FORMAT_RG1616:
		return "RG1616";
	case DRM_FORMAT_GR1616:
		return "GR1616";
	case DRM_FORMAT_RGB332:
		return "RGB332";
	case DRM_FORMAT_BGR233:
		return "BGR233";
	case DRM_FORMAT_XRGB4444:
		return "XRGB4444";
	case DRM_FORMAT_XBGR4444:
		return "XBGR4444";
	case DRM_FORMAT_RGBX4444:
		return "RGBX4444";
	case DRM_FORMAT_BGRX4444:
		return "BGRX4444";
	case DRM_FORMAT_ARGB4444:
		return "ARGB4444";
	case DRM_FORMAT_ABGR4444:
		return "ABGR4444";
	case DRM_FORMAT_RGBA4444:
		return "RGBA4444";
	case DRM_FORMAT_BGRA4444:
		return "BGRA4444";
	case DRM_FORMAT_XRGB1555:
		return "XRGB1555";
	case DRM_FORMAT_XBGR1555:
		return "XBGR1555";
	case DRM_FORMAT_RGBX5551:
		return "RGBX5551";
	case DRM_FORMAT_BGRX5551:
		return "BGRX5551";
	case DRM_FORMAT_ARGB1555:
		return "ARGB1555";
	case DRM_FORMAT_ABGR1555:
		return "ABGR1555";
	case DRM_FORMAT_RGBA5551:
		return "RGBA5551";
	case DRM_FORMAT_BGRA5551:
		return "BGRA5551";
	case DRM_FORMAT_RGB565:
		return "RGB565";
	case DRM_FORMAT_BGR565:
		return "BGR565";
	case DRM_FORMAT_RGB888:
		return "RGB888";
	case DRM_FORMAT_BGR888:
		return "BGR888";
	case DRM_FORMAT_XRGB8888:
		return "XRGB8888";
	case DRM_FORMAT_XBGR8888:
		return "XBGR8888";
	case DRM_FORMAT_RGBX8888:
		return "RGBX8888";
	case DRM_FORMAT_BGRX8888:
		return "BGRX8888";
	case DRM_FORMAT_ARGB8888:
		return "ARGB8888";
	case DRM_FORMAT_ABGR8888:
		return "ABGR8888";
	case DRM_FORMAT_RGBA8888:
		return "RGBA8888";
	case DRM_FORMAT_BGRA8888:
		return "BGRA8888";
	case DRM_FORMAT_XRGB2101010:
		return "XRGB2101010";
	case DRM_FORMAT_XBGR2101010:
		return "XBGR2101010";
	case DRM_FORMAT_RGBX1010102:
		return "RGBX1010102";
	case DRM_FORMAT_BGRX1010102:
		return "BGRX1010102";
	case DRM_FORMAT_ARGB2101010:
		return "ARGB2101010";
	case DRM_FORMAT_ABGR2101010:
		return "ABGR2101010";
	case DRM_FORMAT_RGBA1010102:
		return "RGBA1010102";
	case DRM_FORMAT_BGRA1010102:
		return "BGRA1010102";
	case DRM_FORMAT_XRGB16161616F:
		return "XRGB16161616F";
	case DRM_FORMAT_XBGR16161616F:
		return "XBGR16161616F";
	case DRM_FORMAT_ARGB16161616F:
		return "ARGB16161616F";
	case DRM_FORMAT_ABGR16161616F:
		return "ABGR16161616F";
	case DRM_FORMAT_AXBXGXRX106106106106:
		return "AXBXGXRX106106106106";
	case DRM_FORMAT_YUYV:
		return "YUYV";
	case DRM_FORMAT_YVYU:
		return "YVYU";
	case DRM_FORMAT_UYVY:
		return "UYVY";
	case DRM_FORMAT_VYUY:
		return "VYUY";
	case DRM_FORMAT_AYUV:
		return "AYUV";
	case DRM_FORMAT_XYUV8888:
		return "XYUV8888";
	case DRM_FORMAT_VUY888:
		return "VUY888";
	case DRM_FORMAT_VUY101010:
		return "VUY101010";
	case DRM_FORMAT_Y210:
		return "Y210";
	case DRM_FORMAT_Y212:
		return "Y212";
	case DRM_FORMAT_Y216:
		return "Y216";
	case DRM_FORMAT_Y410:
		return "Y410";
	case DRM_FORMAT_Y412:
		return "Y412";
	case DRM_FORMAT_Y416:
		return "Y416";
	case DRM_FORMAT_XVYU2101010:
		return "XVYU2101010";
	case DRM_FORMAT_XVYU12_16161616:
		return "XVYU12_16161616";
	case DRM_FORMAT_XVYU16161616:
		return "XVYU16161616";
	case DRM_FORMAT_Y0L0:
		return "Y0L0";
	case DRM_FORMAT_X0L0:
		return "X0L0";
	case DRM_FORMAT_Y0L2:
		return "Y0L2";
	case DRM_FORMAT_X0L2:
		return "X0L2";
	case DRM_FORMAT_YUV420_8BIT:
		return "YUV420_8BIT";
	case DRM_FORMAT_YUV420_10BIT:
		return "YUV420_10BIT";
	case DRM_FORMAT_XRGB8888_A8:
		return "XRGB8888_A8";
	case DRM_FORMAT_XBGR8888_A8:
		return "XBGR8888_A8";
	case DRM_FORMAT_RGBX8888_A8:
		return "RGBX8888_A8";
	case DRM_FORMAT_BGRX8888_A8:
		return "BGRX8888_A8";
	case DRM_FORMAT_RGB888_A8:
		return "RGB888_A8";
	case DRM_FORMAT_BGR888_A8:
		return "BGR888_A8";
	case DRM_FORMAT_RGB565_A8:
		return "RGB565_A8";
	case DRM_FORMAT_BGR565_A8:
		return "BGR565_A8";
	case DRM_FORMAT_NV12:
		return "NV12";
	case DRM_FORMAT_NV21:
		return "NV21";
	case DRM_FORMAT_NV16:
		return "NV16";
	case DRM_FORMAT_NV61:
		return "NV61";
	case DRM_FORMAT_NV24:
		return "NV24";
	case DRM_FORMAT_NV42:
		return "NV42";
	case DRM_FORMAT_NV15:
		return "NV15";
	case DRM_FORMAT_P210:
		return "P210";
	case DRM_FORMAT_P010:
		return "P010";
	case DRM_FORMAT_P012:
		return "P012";
	case DRM_FORMAT_P016:
		return "P016";
    case DRM_FORMAT_P030:
	    return "P030";
	case DRM_FORMAT_Q410:
		return "Q410";
	case DRM_FORMAT_Q401:
		return "Q401";
	case DRM_FORMAT_YUV410:
		return "YUV410";
	case DRM_FORMAT_YVU410:
		return "YVU410";
	case DRM_FORMAT_YUV411:
		return "YUV411";
	case DRM_FORMAT_YVU411:
		return "YVU411";
	case DRM_FORMAT_YUV420:
		return "YUV420";
	case DRM_FORMAT_YVU420:
		return "YVU420";
	case DRM_FORMAT_YUV422:
		return "YUV422";
	case DRM_FORMAT_YVU422:
		return "YVU422";
	case DRM_FORMAT_YUV444:
		return "YUV444";
	case DRM_FORMAT_YVU444:
		return "YVU444";
	default:
		return "Unknown";
	}
}

#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))

static float mode_vrefresh(drmModeModeInfo *mode)
{
	return  mode->clock * 1000.00
			/ (mode->htotal * mode->vtotal);
}

#define bit_name_fn(res)					\
const char * res##_str(int type) {				\
	unsigned int i;						\
	const char *sep = "";					\
	for (i = 0; i < ARRAY_SIZE(res##_names); i++) {		\
		if (type & (1 << i)) {				\
			printf("%s%s", sep, res##_names[i]);	\
			sep = ", ";				\
		}						\
	}							\
	return NULL;						\
}

static const char *mode_type_names[] = {
	"builtin",
	"clock_c",
	"crtc_c",
	"preferred",
	"default",
	"userdef",
	"driver",
};

static bit_name_fn(mode_type)

static const char *mode_flag_names[] = {
	"phsync",
	"nhsync",
	"pvsync",
	"nvsync",
	"interlace",
	"dblscan",
	"csync",
	"pcsync",
	"ncsync",
	"hskew",
	"bcast",
	"pixmux",
	"dblclk",
	"clkdiv2"
};

static bit_name_fn(mode_flag)

static void dump_mode(drmModeModeInfo *mode, int index)
{
	printf("  #%2i %-10s %6.2f %4d %4d %4d %4d %4d %4d %4d %4d %6d",
	       index,
	       mode->name,
	       mode_vrefresh(mode),
	       mode->hdisplay,
	       mode->hsync_start,
	       mode->hsync_end,
	       mode->htotal,
	       mode->vdisplay,
	       mode->vsync_start,
	       mode->vsync_end,
	       mode->vtotal,
	       mode->clock);

	printf(" flags: ");
	mode_flag_str(mode->flags);
	printf("; type: ");
	mode_type_str(mode->type);
	printf("\n");
}

void mode_id_info(int fd, uint32_t blob_id)
{
	drmModePropertyBlobRes *blob = drmModeGetPropertyBlob(fd, blob_id);
	if (!blob) {
		perror("drmModeGetPropertyBlob");
	}

	drmModeModeInfo *mode = static_cast<drmModeModeInfo*>(blob->data);
	
	ofLog() << "MODE_ID(blob) currently set to:";
	ofLog() << "    clock " << mode->clock;

	ofLog() << "    hdisplay " << mode->hdisplay;
	ofLog() << "    hsync_start " << mode->hsync_start;
	ofLog() << "    hsync_end " << mode->hsync_end;
	ofLog() << "    htotal " << mode->htotal;
	ofLog() << "    hskew " << mode->hskew;

	ofLog() << "    vdisplay " << mode->vdisplay;
	ofLog() << "    vsync_start " << mode->vsync_start;
	ofLog() << "    vsync_end " << mode->vsync_end;
	ofLog() << "    vtotal " << mode->vtotal;
	ofLog() << "    vscan " << mode->vscan;

	ofLog() << "    vrefresh " << mode->vrefresh;

	ofLog() << "    flags " << mode->flags;
	ofLog() << "    type " << mode->type;
	ofLog() << "    name " << mode->name;

	drmModeFreePropertyBlob(blob);

}

void hdr_output_metadata_info(int fd, uint32_t blob_id)
{
	drmModePropertyBlobRes *blob = drmModeGetPropertyBlob(fd, blob_id);
	if (!blob) {
		ofLogError() << "Could not get drmModeGetPropertyBlob";
	}

	struct drm_hdr_output_metadata *meta = static_cast<drm_hdr_output_metadata*>(blob->data);

	if (meta->metadata_type == 0 /*HDMI_STATIC_METADATA_TYPE1*/) {
 

		const struct drm_hdr_metadata_infoframe* info = &meta->hdmi_metadata_type1;
		ofLog() << "HDR_OUTPUT_METADATA(blob) currently set to:";
		ofLog() << "	metadata_type = " << static_cast<int>(info->metadata_type); 
		ofLog() << "	eotf = " << static_cast<int>(info->eotf);
		ofLog() << "	metadata_type = " << static_cast<int>(info->metadata_type);
		ofLog() << "	display_primaries_r_x = " << info->display_primaries[2].x;
		ofLog() << "	display_primaries_r_y = " << info->display_primaries[2].y;
		ofLog() << "	display_primaries_g_x = " << info->display_primaries[0].x;
		ofLog() << "	display_primaries_g_y = " << info->display_primaries[0].y;
		ofLog() << "	display_primaries_b_x = " << info->display_primaries[1].x;
		ofLog() << "	display_primaries_b_y = " << info->display_primaries[1].y;
		ofLog() << "	white_point_x = " << info->white_point.x;
		ofLog() << "	white_point_y = " << info->white_point.y;
		ofLog() << "	max_display_mastering_luminance = " << info->max_display_mastering_luminance;
		ofLog() << "	min_display_mastering_luminance = " << info->min_display_mastering_luminance;
		ofLog() << "	max_cll = " << info->max_cll;
		ofLog() << "	max_fall = " << info->max_fall;
	}

	drmModeFreePropertyBlob(blob);

}

void dovi_output_metadata_info(int fd, uint32_t blob_id)
{
	drmModePropertyBlobRes *blob = drmModeGetPropertyBlob(fd, blob_id);
	if (!blob) {
		ofLogError() << "Could not get drmModeGetPropertyBlob";
	}

	struct dovi_output_metadata *dovi = static_cast<dovi_output_metadata*>(blob->data);

 

		ofLog() << "DOVI_OUTPUT_METADATA(blob) currently set to:";
		ofLog() << "    Vendor OUI = " << std::hex  << setfill('0') << setw(1) << (dovi->oui >> 16)
											 << "-" << setfill('0') << (((dovi->oui >> 8) < 0x10) ? setw(1) : setw(0) ) << (dovi->oui >> 8) 
											 << "-" << setfill('0') << (((dovi->oui & 0xff) < 0x10) ? setw(1) : setw(0)) << (dovi->oui &0xff); 

		ofLog() << "    DV Status = " << (dovi->dv_status ? "active" : "not active"); 
		ofLog() << "    DV Interface = " << (dovi->dv_interface >> 1 ? "LLDV" : "standard"); //fix
		ofLog() << "    Backlight Metadata = " << (dovi->backlight_metadata ? "present" : "not present");
		ofLog() << "    Backlight Max Luminance = " << (dovi->backlight_max_luminance  ? "present" : "not present");
		ofLog() << "    Auxillary runmode = " << (dovi->aux_runmode  ? "present" : "not present");
		ofLog() << "    Auxillary version = " << (dovi->aux_version  ? "present" : "not present");
		ofLog() << "    Auxillary debug = " << (dovi->aux_debug  ? "present" : "not present");



	drmModeFreePropertyBlob(blob);

}

void ofxRPI4Window::in_formats_info(int fd, uint32_t blob_id)
{
	uint32_t fmt = 0;

	drmModePropertyBlobRes *blob = drmModeGetPropertyBlob(fd, blob_id);
	if (!blob) {
		perror("drmModeGetPropertyBlob");

	}

	struct drm_format_modifier_blob *data = static_cast<drm_format_modifier_blob*>(blob->data);
//	uint32_t fmts_arr[data->count_modifiers];
	uint32_t *fmts = (uint32_t *)
		((char *)data + data->formats_offset);

	struct drm_format_modifier *mods = (struct drm_format_modifier *)
		((char *)data + data->modifiers_offset);

	for (uint32_t i = 0; i < data->count_modifiers; ++i) {

		ofLog() << "modifier " << std::hex << mods[i].modifier;


		for (uint64_t j = 0; j < 64; ++j) {
			if (mods[i].formats & (1ull << j)) {
				fmt = fmts[j + mods[i].offset];

				ofLog() << "        " << format_str(fmt) << std::hex << " (0x" << fmt << ")"; 
			}
		}


	}


	drmModeFreePropertyBlob(blob);


}

void ofxRPI4Window::get_format_modifiers(int fd, uint32_t blob_id, int format_index)
{


	drmModePropertyBlobRes *blob = drmModeGetPropertyBlob(fd, blob_id);
	if (!blob) {
		perror("drmModeGetPropertyBlob");

	}

	struct drm_format_modifier_blob *data = static_cast<drm_format_modifier_blob*>(blob->data);

	uint32_t *fmts = (uint32_t *)
		((char *)data + data->formats_offset);

	struct drm_format_modifier *mods = (struct drm_format_modifier *)
		((char *)data + data->modifiers_offset);

	for (uint32_t j = 0; j < data->count_modifiers; j++) {


			if (mods[j].formats & (1ull << format_index)) {


					num_modifiers++;

				

			}
		


	}
	num_modifiers +=1;
	modifiers = (uint64_t *)calloc(data->count_modifiers, sizeof(uint64_t));

	if (!modifiers) {
		ofLogError() << "DRM: -failed to allocate modifiers";
	}

	for (uint32_t j = 0; j < data->count_modifiers; j++) {
		if (mods[j].formats & (1ULL << format_index)) {
			modifiers[j] = mods[j].modifier;
	   /*
		* Some broadcom modifiers have parameters encoded which need to be
		* masked out before comparing with reported modifiers.
		*/
			if ((modifiers[j] >> 56) == DRM_FORMAT_MOD_VENDOR_BROADCOM)
				modifiers[j] = fourcc_mod_broadcom_mod(modifiers[j]);
		}
	}

	drmModeFreePropertyBlob(blob);


}


static string eglErrorString(EGLint err) {
    string str;
    switch (err) {
            CASE_STR(EGL_SUCCESS, "EGL_SUCCESS");
            CASE_STR(EGL_NOT_INITIALIZED, "EGL_NOT_INITIALIZED");
            CASE_STR(EGL_BAD_ACCESS, "EGL_BAD_ACCESS");
            CASE_STR(EGL_BAD_ALLOC, "EGL_BAD_ACCESS");
            CASE_STR(EGL_BAD_ATTRIBUTE, "EGL_BAD_ATTRIBUTE");
            CASE_STR(EGL_BAD_CONTEXT, "EGL_BAD_CONTEXT");
            CASE_STR(EGL_BAD_CONFIG, "EGL_BAD_CONFIG");
            CASE_STR(EGL_BAD_CURRENT_SURFACE, "EGL_BAD_CURRENT_SURFACE");
            CASE_STR(EGL_BAD_DISPLAY, "EGL_BAD_DISPLAY");
            CASE_STR(EGL_BAD_SURFACE, "EGL_BAD_SURFACE");
            CASE_STR(EGL_BAD_MATCH, "EGL_BAD_MATCH");
            CASE_STR(EGL_BAD_PARAMETER, "EGL_BAD_PARAMETER");
            CASE_STR(EGL_BAD_NATIVE_PIXMAP, "EGL_BAD_NATIVE_PIXMAP");
            CASE_STR(EGL_BAD_NATIVE_WINDOW, "EGL_BAD_NATIVE_WINDOW");
            CASE_STR(EGL_CONTEXT_LOST, "EGL_CONTEXT_LOST");
        default: str = "unknown error " + err; break;
    }
    return str;
}


ofxRPI4Window::ofxRPI4Window() {
    orientation = OF_ORIENTATION_DEFAULT;
    skipRender = false;
    previousBo = NULL;
    previousFb = 0;
    lastFrameTimeMillis = 0;
    gbmDevice = NULL;
    gbmSurface = NULL;
}
ofxRPI4Window::ofxRPI4Window(const ofGLESWindowSettings & settings) {
    ofLog() << "CTOR CALLED WITH settings";
    setup(settings);
}

int match_config_to_visual(EGLDisplay egl_display,
                           EGLint visual_id,
                           EGLConfig *configs,
                           int count)
{
    int i;
    
    for (i = 0; i < count; ++i) {
        EGLint id;
        
        if (!eglGetConfigAttrib(egl_display,
                                configs[i], EGL_NATIVE_VISUAL_ID,
                                &id))
            continue;
			
        if (id == visual_id)
            return i;
    }
 
    return -1;
}


/**
 * Print table of all available configurations.
 */
#define MAX_CONFIGS 1000
/* These are X visual types, so if you're running eglinfo under
 * something not X, they probably don't make sense. */
static const char *vnames[] = { "SG", "GS", "SC", "PC", "TC", "DC" };

static void
PrintConfigs(EGLDisplay d)
{
   EGLConfig configs[MAX_CONFIGS];
   EGLint numConfigs, i;

   eglGetConfigs(d, configs, MAX_CONFIGS, &numConfigs);

   printf("Configurations:\n");
   printf("     bf lv colorbuffer dp st  ms     vis                                 cav bi     renderable  supported\n");
   printf("  id sz  l  r  g  b  a th cl ns b     id                                 eat nd gl es es2 es3 vg surfaces \n");
   printf("----------------------------------------------------------------------------------------------------------\n");
   for (i = 0; i < numConfigs; i++) {
      EGLint id, size, level;
      EGLint red, green, blue, alpha;
      EGLint depth, stencil;
      EGLint renderable, surfaces;
      EGLint vid, vtype, caveat, bindRgb, bindRgba;
      EGLint samples, sampleBuffers;
	  EGLint cc_type;//, cc_type_fixed;
      char surfString[100] = "";

      eglGetConfigAttrib(d, configs[i], EGL_CONFIG_ID, &id);
      eglGetConfigAttrib(d, configs[i], EGL_BUFFER_SIZE, &size);
      eglGetConfigAttrib(d, configs[i], EGL_LEVEL, &level);

      eglGetConfigAttrib(d, configs[i], EGL_RED_SIZE, &red);
      eglGetConfigAttrib(d, configs[i], EGL_GREEN_SIZE, &green);
      eglGetConfigAttrib(d, configs[i], EGL_BLUE_SIZE, &blue);
      eglGetConfigAttrib(d, configs[i], EGL_ALPHA_SIZE, &alpha);
      eglGetConfigAttrib(d, configs[i], EGL_DEPTH_SIZE, &depth);
      eglGetConfigAttrib(d, configs[i], EGL_STENCIL_SIZE, &stencil);
      eglGetConfigAttrib(d, configs[i], EGL_NATIVE_VISUAL_ID, &vid);
      eglGetConfigAttrib(d, configs[i], EGL_NATIVE_VISUAL_TYPE, &vtype);

      eglGetConfigAttrib(d, configs[i], EGL_CONFIG_CAVEAT, &caveat);
      eglGetConfigAttrib(d, configs[i], EGL_BIND_TO_TEXTURE_RGB, &bindRgb);
      eglGetConfigAttrib(d, configs[i], EGL_BIND_TO_TEXTURE_RGBA, &bindRgba);
      eglGetConfigAttrib(d, configs[i], EGL_RENDERABLE_TYPE, &renderable);
      eglGetConfigAttrib(d, configs[i], EGL_SURFACE_TYPE, &surfaces);

      eglGetConfigAttrib(d, configs[i], EGL_SAMPLES, &samples);
      eglGetConfigAttrib(d, configs[i], EGL_SAMPLE_BUFFERS, &sampleBuffers);
	   eglGetConfigAttrib(d, configs[i],   EGL_COLOR_COMPONENT_TYPE_EXT,&cc_type);
 //  eglGetConfigAttrib(d, configs[i], EGL_PBUFFER_BIT, &cc_type_fixed);

      if (surfaces & EGL_WINDOW_BIT)
         strcat(surfString, "win,");
      if (surfaces & EGL_PBUFFER_BIT)
         strcat(surfString, "pb,");
      if (surfaces & EGL_PIXMAP_BIT)
         strcat(surfString, "pix,");
      if (surfaces & EGL_STREAM_BIT_KHR)
         strcat(surfString, "str,");
      if (strlen(surfString) > 0)
         surfString[strlen(surfString) - 1] = 0;

      printf("0x%02x %2d %2d %2d %2d %2d %2d %2d %2d %2d%2d %s(0x%02x)%s 0x%02x(%s)",
             id, size, level,
             red, green, blue, alpha,
             depth, stencil,
             samples, sampleBuffers, format_str(vid),vid, vtype < 6 ? vnames[vtype] : "--", cc_type, cc_type == 0x333A ? "Fixed" : "Float");
      printf("  %c  %c  %c  %c  %c   %c  %c %s\n",
             (caveat != EGL_NONE) ? 'y' : ' ',
             (bindRgba) ? 'a' : (bindRgb) ? 'y' : ' ',
             (renderable & EGL_OPENGL_BIT) ? 'y' : ' ',
             (renderable & EGL_OPENGL_ES_BIT) ? 'y' : ' ',
             (renderable & EGL_OPENGL_ES2_BIT) ? 'y' : ' ',
             (renderable & EGL_OPENGL_ES3_BIT) ? 'y' : ' ',
             (renderable & EGL_OPENVG_BIT) ? 'y' : ' ',
             surfString);
   }
}

static void check_extensions(void)
{

        const char *client_extensions = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);

        if (!client_extensions) {
            ofLogError() << "No client extensions string available\n";
            abort();
        }
        if (strstr(client_extensions, "EGL_KHR_platform_gbm")) {
			ofLog() << "EGL_KHR_platform_gbm available\n";
           // abort();
        }
		        if (strstr(client_extensions, "EGL_MESA_platform_gbm")) {
			ofLog() << "EGL_MESA_platform_gbm available\n";
           // abort();
        }
		        if (strstr(client_extensions, "EGL_EXT_platform_base")) {
			ofLog() << "EGL_EXT_platform_base available\n";
           // abort();
        }

}

static EGLDisplay
gbm_get_display (gbm_device* gbmDevice)
{
  EGLDisplay dpy = NULL;
        const char *client_extensions = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);

        if (!client_extensions) {
            ofLogError() << "No client extensions string available\n";
            abort();
        }
        if (!strstr(client_extensions, "EGL_KHR_platform_gbm")) {
			ofLogError() << "No EGL_KHR_platform_gbm available\n";
            abort();
        }
#if 0
  static const int MAX_DEVICES = 32;
  EGLDeviceEXT eglDevs[MAX_DEVICES];
  EGLint numDevices;

  PFNEGLQUERYDEVICESEXTPROC eglQueryDevicesEXT =
    (PFNEGLQUERYDEVICESEXTPROC)
    eglGetProcAddress("eglQueryDevicesEXT");

  eglQueryDevicesEXT(MAX_DEVICES, eglDevs, &numDevices);

  printf("Detected %d devices\n", numDevices);
#endif  
  if (strstr(client_extensions, "EGL_EXT_platform_base"))
    {
		ofLog() << "EGL_EXT_platform_base available\n";
      PFNEGLGETPLATFORMDISPLAYEXTPROC getPlatformDisplayEXT =
        (PFNEGLGETPLATFORMDISPLAYEXTPROC) eglGetProcAddress ("eglGetPlatformDisplayEXT");

      if (getPlatformDisplayEXT)
        dpy = getPlatformDisplayEXT (EGL_PLATFORM_GBM_KHR,
                               gbmDevice,
						      // eglDevs[2],
                                  NULL);
      if (dpy)
        return dpy;
    }

  return 0;//eglGetDisplay ((EGLNativeDisplayType) gbmDevice);
}

void
ofxRPI4Window::drm_mode_atomic_set_property(int drm_fd, drmModeAtomicReq *freq, const char *name /* in */, uint32_t object_id /* in */,
			uint32_t prop_id /* in */, uint64_t value /* in */, drmModePropertyPtr prop /* in */, uint32_t flags)
{
	int success = 0;
    if (first_req) { req = drmModeAtomicAlloc(); first_req = 0;}
//    uint32_t flags = DRM_MODE_ATOMIC_ALLOW_MODESET;	
	uint64_t tmp_value;
	
	success = drmModeAtomicAddProperty(req, object_id, prop_id, value);						

	if (success < 0) {
		ofLogError() << "DRM: Unable to request " << name << " " << strerror(errno);
	} else {
		uint32_t flags = prop->flags;			
		uint32_t type = flags &
		(DRM_MODE_PROP_LEGACY_TYPE | DRM_MODE_PROP_EXTENDED_TYPE);
		

		switch (type) {
		case DRM_MODE_PROP_RANGE:
			// This is a special case, as the SRC_* properties are
			// in 16.16 fixed point
			if (strncmp(prop->name, "SRC_", 4) == 0) {
				tmp_value = value >> 16;
				ofLog() << "DRM: atomic_request " << name << "(range): [" <<  prop->values[0] << ".." << prop->values[1] << "] = " << value << " (" << tmp_value << ")";
			} else {
				ofLog() << "DRM: atomic_request " << name << "(range): [" <<  prop->values[0] << ".." << prop->values[1] << "] = " << value;
			}
			break;
		case DRM_MODE_PROP_ENUM:
			ofLog() << "DRM: atomic_request " << name << "(enum): {" << prop->enums[value].name << "} = " << prop->enums[value].value;
			break;
		case DRM_MODE_PROP_BITMASK:
		    break;
		case DRM_MODE_PROP_OBJECT:
			ofLog() << "DRM: atomic_request " << name << "(object): " << prop->name << " = " << value;
			break;
		case DRM_MODE_PROP_SIGNED_RANGE:
			ofLog() << "DRM: atomic_request " << name << "(signed range): [" <<  static_cast<int32_t>(prop->values[0]) << ".." << static_cast<int32_t>(prop->values[1]) << "] = " << static_cast<int32_t>(value);
			break;

		case DRM_MODE_PROP_BLOB:
			ofLog() << "DRM: atomic_request " << name << "(blob): blob_id = " << value;
			if (!value) {
				break;
			}
			if (strcmp(prop->name, "IN_FORMATS") == 0) {
			    in_formats_info(drm_fd, (uint32_t)value);
			} else if (strcmp(prop->name, "MODE_ID") == 0) {
				mode_id_info(drm_fd, (uint32_t)value);
			} else if (strcmp(prop->name, "HDR_OUTPUT_METADATA") == 0) {
				hdr_output_metadata_info(drm_fd, (uint32_t)value);
			} else if (strcmp(prop->name, "DOVI_OUTPUT_METADATA") == 0) {
				dovi_output_metadata_info(drm_fd, (uint32_t)value);
			} else if (strcmp(prop->name, "WRITEBACK_PIXEL_FORMATS") == 0) {
			//	writeback_pixel_formats_info(drm_fd, value);
			} else if (strcmp(prop->name, "PATH") == 0) {
				//path_info(drm_fd, value);
			}
			break;
		}	

	}
	drmModeFreeProperty(prop);

	if (last_req) {
		success = drmModeAtomicCommit(drm_fd, req, flags, NULL);
		if (success < 0) {
			ofLogError() << "DRM: atomic commit failed " << strerror(errno);
		} else {
			ofLog() << "DRM: atomic commit successful";
		}  

		
		drmModeAtomicFree(req);	
		last_req = 0;
	}
};

bool  
ofxRPI4Window::drm_mode_get_property(int drm_fd, uint32_t object_id, uint32_t object_type,
		     const char *name, uint32_t *prop_id /* out */,
		     uint64_t *value /* out */,
		     drmModePropertyPtr *prop /* out */)
{
	drmModeObjectPropertiesPtr proplist;
	drmModePropertyPtr _prop;
	bool found = false;

	proplist = drmModeObjectGetProperties(drm_fd, object_id, object_type);
	for (uint32_t i = 0; i < proplist->count_props; i++) {
		_prop = drmModeGetProperty(drm_fd, proplist->props[i]);
		if (!_prop)
			continue;

//		bool atomic = flags & DRM_MODE_PROP_ATOMIC;
//		bool immutable = flags & DRM_MODE_PROP_IMMUTABLE;
		uint64_t _value = proplist->prop_values[i];
		uint64_t tmp_value;
		if (strcmp(_prop->name, name) == 0) {
			found = true;
			uint32_t flags = _prop->flags;
			uint32_t type = flags &
			(DRM_MODE_PROP_LEGACY_TYPE | DRM_MODE_PROP_EXTENDED_TYPE);
			

			switch (type) {
			case DRM_MODE_PROP_RANGE:
				// This is a special case, as the SRC_* properties are
				// in 16.16 fixed point
				if (strncmp(_prop->name, "SRC_", 4) == 0) {
					tmp_value = _value >> 16;
				ofLog() << "DRM: " << name << ": range [" <<  _prop->values[0] << ".." << _prop->values[1] << "] currently set to = " << _value << " (" << tmp_value << ")";

				} else {
				ofLog() << "DRM: " << name << ": range [" <<  _prop->values[0] << ".." << _prop->values[1] << "] currently set to = " << _value;
				}
				break;
			case DRM_MODE_PROP_ENUM:
				ofLog() << "DRM: " << name << "(enum) values:";
				for (int j = 0; j < _prop->count_enums; ++j) {;
				ofLog() << "    {" << _prop->enums[j].name << "} = " << _prop->enums[j].value;
				}	
			    ofLog() << "DRM: " << name << "(enum): currently set to {"<< _prop->enums[_value].name << "} = " << _value;			
				break;
			case DRM_MODE_PROP_BITMASK:
				ofLog() << "DRM: " << name << ":";
				for (int j = 0; j < _prop->count_enums; ++j) {;
				ofLog() << "    enum {" << _prop->enums[j].name << "} = " << _prop->enums[j].value;
				}
				ofLog() << "DRM: " << name << "(enum): currently set to " << _value;
				break;
			case DRM_MODE_PROP_OBJECT:
				ofLog() << "DRM: " << name << "(object): currently set to " << _prop->name << " = " << _value;
				if (!_value) {
					break;
				}
				if (strcmp(_prop->name, "FB_ID") == 0) {
				//	fb_info(drm_fd, value);
				}
				break;
			case DRM_MODE_PROP_SIGNED_RANGE:
				ofLog() << "DRM: " << name << "(signed range): [" <<  static_cast<int32_t>(_prop->values[0]) << ".." << static_cast<int32_t>(_prop->values[1]) << "] currently set to = " <<  static_cast<int32_t>(_value);
				break;
			case DRM_MODE_PROP_BLOB:
				// TODO: base64-encode blob contents
				ofLog() << "DRM: " << name << "(blob): currently set to blob_id = " << _value;
				if (!_value) {
					break;
				}
				if (strcmp(_prop->name, "IN_FORMATS") == 0) {
				    in_formats_info(drm_fd, (uint32_t)_value);
				} else if (strcmp(_prop->name, "MODE_ID") == 0) {
					mode_id_info(drm_fd, (uint32_t)_value);
				} else if (strcmp(_prop->name, "HDR_OUTPUT_METADATA") == 0) {
					hdr_output_metadata_info(drm_fd, (uint32_t)_value);
				} else if (strcmp(_prop->name, "DOVI_OUTPUT_METADATA") == 0) {
					dovi_output_metadata_info(drm_fd, (uint32_t)_value);
				} else if (strcmp(_prop->name, "WRITEBACK_PIXEL_FORMATS") == 0) {
				//	writeback_pixel_formats_info(drm_fd, _value);
				} else if (strcmp(_prop->name, "PATH") == 0) {
					//path_info(drm_fd, _value);
				}
				break;
			}		
       		
			if (prop_id)
				*prop_id = proplist->props[i];
			if (value)
				*value = proplist->prop_values[i];
			if (prop)
				*prop = _prop;
		    else
				drmModeFreeProperty(_prop);
			break;
		}
	if (prop) drmModeFreeProperty(_prop);
	}


	drmModeFreeObjectProperties(proplist);
	return found;
}


static void
print_device_info(drmDevicePtr device, int i, bool print_revision)
{
    ofLog() << "device[" << i << "]";
    ofLog() << "+-> available_nodes " << hex << setw(4) <<  device->available_nodes;
    ofLog() << "+-> nodes";
    for (int j = 0; j < DRM_NODE_MAX; j++)
        if (device->available_nodes & 1 << j)
            ofLog() << "|   +-> nodes[" << j << "] " << device->nodes[j];
    ofLog() << "+-> bustype " << hex << setw(4) << device->bustype;
    if (device->bustype == DRM_BUS_PCI) {
        ofLog() << "|   +-> pci";
        ofLog() << "|       +-> domain " << hex << setw(4) << device->businfo.pci->domain;
        ofLog() << "|       +-> bus    " << hex << setw(2) <<  device->businfo.pci->bus;
        ofLog() << "|       +-> dev    " << hex << setw(2) <<  device->businfo.pci->dev;
        ofLog() << "|       +-> func   " << static_cast<unsigned long>(device->businfo.pci->func);
        ofLog() << "+-> deviceinfo";
        ofLog() << "    +-> pci";
        ofLog() << "        +-> vendor_id    " << hex << setw(4) <<  device->deviceinfo.pci->vendor_id;
        ofLog() << "        +-> device_id    " << hex << setw(4) <<  device->deviceinfo.pci->device_id;
        ofLog() << "        +-> subvendor_id  " << hex << setw(4) <<  device->deviceinfo.pci->subvendor_id;
        ofLog() << "        +-> subdevice_id  " << hex << setw(4) <<  device->deviceinfo.pci->subdevice_id;
        if (print_revision)
            ofLog() << "        +-> revision_id   " << hex << setw(2) <<  device->deviceinfo.pci->revision_id;
        else
            ofLog() <<"        +-> revision_id   IGNORED";
    } else if (device->bustype == DRM_BUS_USB) {
        ofLog() << "|   +-> usb";
        ofLog() << "|       +-> bus " << setw(3) << unsigned(device->businfo.usb->bus);
        ofLog() << "|       +-> dev " << setw(3) << unsigned(device->businfo.usb->dev);
        ofLog() << "+-> deviceinfo";
        ofLog() << "    +-> usb";
        ofLog() << "        +-> vendor  " << hex << setw(4) <<  device->deviceinfo.usb->vendor;
        ofLog() << "        +-> product " << hex << setw(4) <<  device->deviceinfo.usb->product;
    } else if (device->bustype == DRM_BUS_PLATFORM) {
        char **compatible = device->deviceinfo.platform->compatible;
        ofLog() << "|   +-> platform";
        ofLog() << "|       +-> fullname     " << device->businfo.platform->fullname;
        ofLog() << "+-> deviceinfo";
        ofLog() << "    +-> platform";
        ofLog() << "        +-> compatible";
        while (*compatible) {
            ofLog() << "                    " << *compatible;
            compatible++;
        }
    } else if (device->bustype == DRM_BUS_HOST1X) {
        char **compatible = device->deviceinfo.host1x->compatible;
        ofLog() << "|   +-> host1x";
        ofLog() << "|       +-> fullname     " << device->businfo.host1x->fullname;
        ofLog() << "+-> deviceinfo";
        ofLog() << "    +-> host1x";
        ofLog() << "        +-> compatible";
        while (*compatible) {
            ofLog() << "                    " << *compatible;
            compatible++;
        }
    } else {
        ofLog() << "Unknown/unhandled bustype";
    }

}

const char* renderDevicePath{nullptr};
int renderDevice;

int
ofxRPI4Window::find_device(void)
{
//    drmDevicePtr *devices;

    drmDevicePtr device;
    int fd = 0, ret = 0, max_devices = 0;
    ofLog() << "--- Checking the number of DRM device available ---";
    max_devices = drmGetDevices2(0, NULL, 0);
    if (max_devices <= 0) {
        ofLogError() << "drmGetDevices2() has not found any devices " << strerror(errno) << " " << -max_devices;
        return 77;
    }
    ofLog() << "--- Devices reported " << max_devices << " ---";

 std::vector<drmDevicePtr> devices(max_devices);

    ofLog() << "--- Retrieving devices information (PCI device revision is ignored) ---";
    ret = drmGetDevices2(0, devices.data(), devices.size());//devices, max_devices);
    if (ret < 0) {
        ofLogError() << "drmGetDevices2() returned an error " << strerror(errno) << " " << ret;

        return -1;
    }

	for (const auto device : devices) {
		if (!(device->available_nodes & 1 << DRM_NODE_PRIMARY))
            continue;
		::close(fd);
		fd = open(device->nodes[DRM_NODE_PRIMARY], O_RDWR | O_CLOEXEC);
		if (fd < 0)
			continue;
		ofLog() << "DRM: opened device: " << device->nodes[DRM_NODE_PRIMARY];	
		print_device_info(devices[0], 0, false);
	
	    const char* renderPath = drmGetRenderDeviceNameFromFd(fd);

		if (!renderPath)
			renderPath = drmGetDeviceNameFromFd2(fd);

		if (!renderPath)
			renderPath = drmGetDeviceNameFromFd(fd);

		if (renderPath)
		{
			renderDevicePath = renderPath;
			renderDevice = open(renderPath, O_RDWR | O_CLOEXEC);
			if (renderDevice != 0)
				ofLog() << "DRM: - opened render node: " << renderPath;
		}
		drmFreeDevices(devices.data(), devices.size());//devices, ret);

		return fd;
	}
	drmFreeDevices(devices.data(), devices.size());//devices, ret);

    return 0;
}

bool ofxRPI4Window::cta_is_hdr_static_metadata_block(const char *edid_ext)
{
	/*
	 * Byte 1: 0x07 indicates Extended Tag
	 * Byte 2: 0x06 indicates HDMI Static Metadata Block
	 * Byte 3: bits 0 to 5 identify EOTF functions supported by sink
	 *	       where ET_0: Traditional Gamma - SDR Luminance Range
	 *	             ET_1: Traditional Gamma - HDR Luminance Range
	 *	             ET_2: SMPTE ST 2084
	 *	             ET_3: Hybrid Log-Gamma (HLG)
	 *	             ET_4 to ET_5: Reserved for future use
	 */

	if ((((edid_ext[0] & 0xe0) >> 5 == USE_EXTENDED_TAG) &&
	      (edid_ext[1] == HDR_STATIC_METADATA_BLOCK)) &&
	     ((edid_ext[2] & HDMI_EOTF_TRADITIONAL_GAMMA_HDR) ||
	      (edid_ext[2] & HDMI_EOTF_SMPTE_ST2084)))
			return true;

	return false;
}

bool ofxRPI4Window::cta_is_dovi_video_block(const char *edid_ext)
{
	unsigned int oui;
	/*
	 * Byte 1: 0x07 indicates Extended Tag
	 * Byte 2: 0x01 indicates HDMI DoVi VSDB
	 * Bytes 3-5: HDMI DoVi Laboratories OUI
	 */
	oui = edid_ext[4] << 16 | edid_ext[3] << 8 | edid_ext[2];
	if ((((edid_ext[0] & 0xe0) >> 5 == USE_EXTENDED_TAG) &&
	      (edid_ext[1] == DOVI_VIDEO_DATA_BLOCK)) &&
	      (oui == HDMI_DOVI_OUI))
			return true;

	return false;
}

/* Returns if panel supports HDR of HDR and DoVi support */
int ofxRPI4Window::is_panel_hdr_dovi(int fd, int connector_id)
{
	bool ok;
	int i, j;
	uint8_t offset;
	uint64_t edid_blob_id;
	drmModePropertyBlobRes *edid_blob;
	const struct edid_ext *edid_ext;
	const struct edid *edid;
	const struct edid_cea *edid_cea;
	const char *cea_data;
	int ret = 0;
	bool supportsHDR = false;
	bool supportsDoVi = false;
	
	ok = drm_mode_get_property(fd, connector_id, DRM_MODE_OBJECT_CONNECTOR, "EDID",	&prop_id, &edid_blob_id, NULL);

	if (!ok || !edid_blob_id)
		return ret;

	edid_blob = drmModeGetPropertyBlob(fd, edid_blob_id);
	assert(edid_blob);

	edid = (const struct edid *) edid_blob->data;
	assert(edid);

	drmModeFreePropertyBlob(edid_blob);

	for (i = 0; i < edid->extensions_len; i++) {
		edid_ext = &edid->extensions[i];
		edid_cea = &edid_ext->data.cea;

		/* HDR not defined in CTA Extension Version < 3. */
		if ((edid_ext->tag != EDID_EXT_CEA) ||
		    (edid_cea->revision != CTA_EXTENSION_VERSION))
				continue;
		else {
			offset = edid_cea->dtd_start;
			cea_data = edid_cea->data;

			for (j = 0; j < offset; j += (cea_data[j] & 0x1f) + 1) {
			//	ret = cta_block(cea_data + j);
				
				if (cta_is_hdr_static_metadata_block(cea_data + j))
					supportsHDR = true;
					
				if (cta_is_dovi_video_block(cea_data + j))
					supportsDoVi = true;

			}
		}
	}
	if (supportsHDR && !supportsDoVi)
		ret = HDR_TYPE_HDR10;
	else if (supportsDoVi && supportsHDR)
		ret = HDR_TYPE_DOVI;
	else 
		ret = 0; 
 
	return ret;
}

bool ofxRPI4Window::InitDRM()
{
	bool ok;
	int ret;
	
	device = find_device();
	/* give up drm master in case we are first */
	ret =		drmDropMaster(device);
	if (ret < 0)
    {
      ofLogError() << "DRM: - failed to drop drm master: " << strerror(errno);
	  exit(1);
      } else {
        ofLog() << "DRM: - successfully dropped drm master";		
	}
    /* Programmer!! Save your sanity!!
     * VERY important or we won't get all the available planes on drmGetPlaneResources()!
     * We also need to enable the ATOMIC cap to see the atomic properties in objects!! */
    ret = drmSetClientCap(device, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
    if (ret)
       ofLogError() << "DRM: can't set UNIVERSAL PLANES cap";
    else
       ofLog() << "DRM: UNIVERSAL PLANES cap set";

    ret = drmSetClientCap(device, DRM_CLIENT_CAP_ATOMIC, 1);
    if (ret)
    {
       /*If this happens, check kernel support and kernel parameters
        * (add i915.nuclear_pageflip=y to the kernel boot line for example) */
       ofLogError() << "DRM: can't set ATOMIC caps: " <<  strerror(errno);
    }
    else
       ofLog() << "DRM: ATOMIC caps set";
	//set to 0 to avoid listing extra modes when display is 3D capable, causes issue with mode index 
    ret = drmSetClientCap(device, DRM_CLIENT_CAP_STEREO_3D, 0);
   if (ret)
   {
     ofLogError() << "DRM: failed to set stereo 3d capability: " << strerror(errno);
   }

#if defined(DRM_CLIENT_CAP_ASPECT_RATIO)
   ret = drmSetClientCap(device, DRM_CLIENT_CAP_ASPECT_RATIO, 0);
   if (ret != 0)
     ofLogError() << "DRM: aspect ratio capability is not supported: " << strerror(errno);
#endif


    drmModeRes* resources = drmModeGetResources(device);
    bool passed = false;
    if (resources == NULL)
    {
        ofLogError() << "DRM: Unable to get DRM resources";
    }
    
    drmModeConnector* connector = NULL;
    
    for (int i = 0; i < resources->count_connectors; i++)
    {
        drmModeConnector* modeConnector = drmModeGetConnector(device, resources->connectors[i]);
        if (modeConnector->connection == DRM_MODE_CONNECTED)
        {
            connector = modeConnector;
			ofLog() << "DRM: Using CONNECTOR_ID: " << connector->connector_id;
            break;
        }
        drmModeFreeConnector(connector);
    }
    
 
    if (connector == NULL)
    {
        ofLogError() << "DRM: Unable to get connector";
        drmModeFreeResources(resources);
    }
    
    connectorId = connector->connector_id;

#if 0
	/* find prefered mode or the highest resolution mode: */
	printf("  Connector Modes:\n");
	printf("index    name      (Hz) hdisp hss  hse htot vdisp "
			       "vss  vse vtot  clock\n");
	for (int i = 0, area = 0; i < connector->count_modes; i++) {
		drmModeModeInfo current_mode = connector->modes[i];

		dump_mode(&connector->modes[i], i);
		if (current_mode.type & DRM_MODE_TYPE_USERDEF) {
			mode = current_mode;
		}

		int current_area = current_mode.hdisplay * current_mode.vdisplay;
		if (current_area > area) {
		//	mode = current_mode;
			area = current_area;
		}
	}

	if (!&mode) {
		ofLog() <<"could not find mode!\n";
		return -1;
	}
#endif	
	// Start BiasiLinux patch for compatibility with old version
	mode = connector->modes[0];
	for (int i=0;i<connector->count_modes;i++) {
		drmModeModeInfo *current_mode = &connector->modes[i];
		if (current_mode->type & DRM_MODE_TYPE_USERDEF) {
			mode = connector->modes[i];
//			ofxRPI4Window::mode_idx = i;	
			break;
		}
	}

	if (connector->encoder_id) {
		drmModeEncoder* encoder_tmp = NULL;
		encoder_tmp = drmModeGetEncoder(device, connector->encoder_id);
		if (encoder_tmp != NULL) {
			crtc = drmModeGetCrtc(device, encoder_tmp->crtc_id);
			mode = crtc->mode;
			drmModeFreeEncoder(encoder_tmp);
		}
	}
	if(ofxRPI4Window::mode_idx!= -1) mode = connector->modes[ofxRPI4Window::mode_idx];

	//End BiasiLinux patch for compatiblity with old version
//    ofLog() << "DRM: Current Mode Index " << ofxRPI4Window::mode_idx;
   
    currentWindowRect = ofRectangle(0, 0, mode.hdisplay, mode.vdisplay);
    ofLog() << "DRM: currentWindowRect: " << currentWindowRect;
    
    drmModeEncoder* encoder = NULL;
    drmModeFreeCrtc(crtc);
    
    if (connector->encoder_id)
    {
        encoder = drmModeGetEncoder(device, connector->encoder_id);
		ofLog() << "DRM: Using ENCODER_ID: " << connector->encoder_id;

    }
    
    
    if (encoder == NULL)
    {
        ofLogError() << "DRM: Unable to get encoder";
        
        drmModeFreeConnector(connector);
        drmModeFreeResources(resources);
    }


		
        crtc = drmModeGetCrtc(device, encoder->crtc_id);
		for (int i = 0; i < resources->count_crtcs; i++) {
			if (resources->crtcs[i] == crtc->crtc_id) {
				crtc_index = i;
				break;
			}
		}
		
	crtcId = crtc->crtc_id;	
		
		
    res	= drmModeGetPlaneResources(device);
	if (!res) {
		ofLogError() << "DRM: Unable to get drmModeGetPlaneResources";

	}
int foundHDR=0;
	for (uint32_t i = 0; i < res->count_planes; i++) {
		plane = drmModeGetPlane(device, res->planes[i]);
		if (!plane) {
			ofLogError() << "DRM: Unable to get drmModeGetPlane";
			continue;
		}

		if (plane->possible_crtcs & (1 << crtc_index) && !foundHDR) {
			HDRplaneId = plane->plane_id;
			foundHDR = 1;

		}	

  
       		if (plane->possible_crtcs & (1 << crtc_index) && plane->plane_id != HDRplaneId && foundHDR) {
			SDRplaneId = plane->plane_id;
			drmModeFreePlane(plane);
			break;

		}	

		drmModeFreePlane(plane);

	
	}
				
			
	ofLog() << "DRM: Using FB_ID: " << crtc->buffer_id;					
	ofLog() << "DRM: Using CRTC_ID: " << crtc->crtc_id;
	ofLog() << "DRM: Using HDR PLANE_ID: " << HDRplaneId;
	ofLog() << "DRM: Using SDR PLANE_ID: " << SDRplaneId;	

    ret = drmSetMaster(device);
    if (ret < 0)
    {
      ofLogError() << "DRM: - failed to set drm master, will try to authorize instead: " << strerror(errno);

      drm_magic_t magic;

      ret = drmGetMagic(device, &magic);
      if (ret < 0)
      {
        ofLogError() << "DRM: - failed to get drm magic: " <<  strerror(errno);
	 //   passed = false; 
      } else {
        ofLog() << "DRM: - successfully got drm magic";		
	 //   passed = true; 
	  }
      ret = drmAuthMagic(device, magic);
      if (ret < 0)
      {
        ofLogError() << "DRM: - failed to authorize drm magic: " << strerror(errno);
	 	passed = false;
		exit(1);
      } else {
	    ofLog() << "DRM: - successfully authorized drm magic";
	    passed = true;
      }
     } else {
	   ofLog() << "DRM: - successfully authorized drm master";
	   passed = true; 
	  
	}


    drmModeFreeCrtc(crtc);
	drmModeFreePlaneResources(res);
    drmModeFreeEncoder(encoder);
    drmModeFreeConnector(connector);
    drmModeFreeResources(resources);
	
	
	if(passed)
    { 
		ofLog() << "DRM: - initialized atomic DRM";
		return true;
	} else {
		return false;
	}
}

void ofxRPI4Window::FindModifiers(uint32_t format, uint32_t plane_id)
{
	bool ok;
	int format_index=0;
	uint64_t in_formats=0;
	plane = drmModeGetPlane(device, plane_id);
	if (!plane) {
		ofLogError() << "DRM: Unable to get drmModeGetPlane";
	}


	
	for (uint32_t i = 0; i < plane->count_formats; i++) {
		uint32_t fmt = plane->formats[i];

		if (fmt == format) {
			format_index = i;
			break;
		} 
	}
	ok = drm_mode_get_property(device, plane_id, DRM_MODE_OBJECT_PLANE, "IN_FORMATS", &prop_id, &in_formats, &prop);

	if (!ok) 
		ofLogError() << "DRM: Unable to find IN_FORMATS";	
	
	get_format_modifiers(device, in_formats, format_index);	
	
//	drmModeFreeProperty(prop);

	drmModeFreePlane(plane);
	
}	

	
void ofxRPI4Window::EGL_info()
{
	#if 1
            
            
            ofLog() << "-----EGL-----";
           // ofLog() << "EGL_VERSION_MAJOR = " << eglVersionMajor;
           // ofLog() << "EGL_VERSION_MINOR = " << eglVersionMinor;
            ofLog() << "EGL_CLIENT_APIS = " << eglQueryString(getEGLDisplay(), EGL_CLIENT_APIS);
            ofLog() << "EGL_VENDOR = "  << eglQueryString(getEGLDisplay(), EGL_VENDOR);
            ofLog() << "EGL_VERSION = " << eglQueryString(getEGLDisplay(), EGL_VERSION);
            ofLog() << "EGL_EXTENSIONS = " << eglQueryString(getEGLDisplay(), EGL_EXTENSIONS);
            ofLog() << "GL_SHADING_LANGUAGE_VERSION   = " << glGetString(GL_SHADING_LANGUAGE_VERSION);
            ofLog() << "GL_RENDERER = " << glGetString(GL_RENDERER);
            ofLog() << "GL_VERSION  = " << glGetString(GL_VERSION);
            ofLog() << "GL_VENDOR   = " << glGetString(GL_VENDOR);
            ofLog() << "-------------";
            
            auto gl_exts = (char *) glGetString(GL_EXTENSIONS);
            ofLog(OF_LOG_VERBOSE, "GL INFO");
            ofLog(OF_LOG_VERBOSE, "  version: \"%s\"", glGetString(GL_VERSION));
            ofLog(OF_LOG_VERBOSE, "  shading language version: \"%s\"", glGetString(GL_SHADING_LANGUAGE_VERSION));
            ofLog(OF_LOG_VERBOSE, "  vendor: \"%s\"", glGetString(GL_VENDOR));
            ofLog(OF_LOG_VERBOSE, "  renderer: \"%s\"", glGetString(GL_RENDERER));
            ofLog(OF_LOG_VERBOSE, "  extensions: \"%s\"", gl_exts);
            ofLog(OF_LOG_VERBOSE, "===================================\n");
            //get_proc_gl(GL_OES_EGL_image, glEGLImageTargetTexture2DOES);
       
#endif   
} 

int ofxRPI4Window::isHDR = 0;
int ofxRPI4Window::isDoVi = 0;
int ofxRPI4Window::is_std_DoVi = 0;
int ofxRPI4Window::bit_depth = 0;
int ofxRPI4Window::mode_idx = 0;
int ofxRPI4Window::dv_profile = 2;
int ofxRPI4Window::dv_status = 0;
int ofxRPI4Window::dv_interface = 0;
//int ofxRPI4Window::dv_minpq = 0;
//int ofxRPI4Window::dv_maxpq = 0;
//int ofxRPI4Window::dv_diagonal = 0;
hdmi_eotf ofxRPI4Window::eotf = static_cast<hdmi_eotf>(2); 
int ofxRPI4Window::hdr_primaries=2;
avi_infoframe ofxRPI4Window::avi_info;
drm_hdr_output_metadata ofxRPI4Window::hdr_metadata;
int ofxRPI4Window::colorspace_on = 0;
int ofxRPI4Window::shader_init = 0;
ofShader ofxRPI4Window::shader;

void ofxRPI4Window::setup(const ofGLESWindowSettings & settings)
{
	

    check_extensions();
    bEnableSetupScreen = true;
//	colorspace_on = true;
    windowMode = OF_WINDOW;
    glesVersion = settings.glesVersion;
    InitDRM(); 
 
	initial_bit_depth = bit_depth;
	switch (bit_depth) {
		case 0:
			bit_depth = 8;
			colorspace_on = 0;
		break;
		case 10:
			if (bit_depth != avi_info.max_bpc) {
				ofLogError() << "DRM: input bit_depth of " << bit_depth << " bits not compatible with output bpc of " << avi_info.max_bpc << " bits, switching output bpc to 10 bits"; 
				avi_info.max_bpc = 10;
			}
		break;
		case 12:
			if (bit_depth != avi_info.max_bpc) {
				ofLogError() << "DRM: input bit_depth of " << bit_depth << " bits not compatible with output bpc of " << avi_info.max_bpc << " bits, switching output bpc to 10 bits"; 
				avi_info.max_bpc = 12;
			}
		break;
	}
	
    if (is_panel_hdr_dovi(device, connectorId) == HDR_TYPE_HDR10) {
		ofLog() << "DRM: panel is HDR capable";
		if (isHDR && !isDoVi && !is_std_DoVi) {
			if ((bit_depth >= 8) && (bit_depth <= 10) && (avi_info.max_bpc == 10)) {
				ofLog() << "DRM: setting up HDR(10 bit) window/surface"; 
				FindModifiers(DRM_FORMAT_ABGR2101010, HDRplaneId);
				HDRWindowSetup();
			} else if ((bit_depth >=8) && (bit_depth <= 12)  && (avi_info.max_bpc == 12)) {
				ofLog() << "DRM: setting up HDR(12 bit) window/surface"; 
				FindModifiers(DRM_FORMAT_ABGR16161616F, HDRplaneId);
				Bit10_16WindowSetup();
			} else {
				ofLog() << "DRM: setting up HDR(8 bit) window/surface";
				FindModifiers(DRM_FORMAT_ARGB8888, SDRplaneId);
				SDRWindowSetup();
			}	
		} else {
			ofLog() << "DRM: setting up SDR(8 bit) window/surface";
			isHDR = 0;
			isDoVi = 0;
			is_std_DoVi = 0;
			FindModifiers(DRM_FORMAT_ARGB8888, SDRplaneId);
			SDRWindowSetup();
		}
	} else if (is_panel_hdr_dovi(device, connectorId) == HDR_TYPE_DOVI) {
		ofLog() << "DRM: panel is HDR and DoVi capable";
		if (isHDR && isDoVi && !is_std_DoVi) {

			if ((bit_depth >= 8) && (bit_depth <= 10) && (avi_info.max_bpc == 10)) {
				ofLog() << "DRM: setting up Low Latency DoVi(10 bit) window/surface"; 

				FindModifiers(DRM_FORMAT_ABGR2101010, HDRplaneId);
				HDRWindowSetup();
			} else if ((bit_depth >=8) && (bit_depth <= 12)  && (avi_info.max_bpc == 12)) {
				ofLog() << "DRM: setting up Low Latency DoVi(12 bit) window/surface"; 

				FindModifiers(DRM_FORMAT_ABGR16161616F, HDRplaneId);
				Bit10_16WindowSetup();
			} else {
				ofLog() << "DRM: setting up Low Latency DoVi(8 bit) window/surface"; 

				FindModifiers(DRM_FORMAT_ARGB8888, SDRplaneId);
				SDRWindowSetup();
			}
		} else if (isHDR && !isDoVi && !is_std_DoVi) {


			if ((bit_depth >= 8) && (bit_depth <= 10) && (avi_info.max_bpc == 10)) {
				ofLog() << "DRM: setting up HDR(10 bit) window/surface"; 
				FindModifiers(DRM_FORMAT_ABGR2101010, HDRplaneId);
				HDRWindowSetup();
			} else if ((bit_depth >=8) && (bit_depth <= 12)  && (avi_info.max_bpc == 12)) {
				ofLog() << "DRM: setting up HDR(12 bit) window/surface"; 
				FindModifiers(DRM_FORMAT_ABGR16161616F, HDRplaneId);
				Bit10_16WindowSetup();
			} else {
				ofLog() << "DRM: setting up HDR(8 bit) window/surface";
				FindModifiers(DRM_FORMAT_ARGB8888, SDRplaneId);
				SDRWindowSetup();
			}
		} else if (isHDR && isDoVi && is_std_DoVi) {
			if (bit_depth == 10 && avi_info.max_bpc == 10) {
				ofLog() << "DRM: setting up Standard DoVi(10 bit) window/surface";
				FindModifiers(DRM_FORMAT_ABGR2101010, HDRplaneId);
				HDRWindowSetup();
			} else {
			    ofLog() << "DRM: setting up Standard DoVi(8 bit) window/surface";
				FindModifiers(DRM_FORMAT_ARGB8888, SDRplaneId);
				SDRWindowSetup();
			}
		} else {
			if (bit_depth == 10 && avi_info.max_bpc == 10) {
				ofLog() << "DRM: setting up SDR(10 bit) window/surface";
				FindModifiers(DRM_FORMAT_ABGR2101010, HDRplaneId);
				HDRWindowSetup();
			} else {
				avi_info.max_bpc = 8;
				ofLog() << "DRM: setting up SDR(8 bit) window/surface";
				FindModifiers(DRM_FORMAT_ARGB8888, SDRplaneId);
				SDRWindowSetup();
			}
		}
			

	} else {
		ofLog() << "DRM: panel is not HDR capable";
		ofLog() << "DRM: setting up SDR window/surface";
		isHDR = 0;
		isDoVi = 0;
		is_std_DoVi = 0;
		FindModifiers(DRM_FORMAT_ARGB8888, SDRplaneId);
		SDRWindowSetup();
	}

 		current_bit_depth = bit_depth;
        starting_bpc = avi_info.max_bpc;
		colorspace_status = colorspace_on;
    
}

void ofxRPI4Window::EGL_create_surface(EGLint attribs[], EGLConfig config)
{
	PFNEGLCREATEPLATFORMWINDOWSURFACEEXTPROC createPlatformWindowSurfaceEXT = nullptr;
	const char *extensions = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);
	if (extensions && (strstr(extensions, "EGL_KHR_platform_gbm") || strstr(extensions, "EGL_MESA_platform_gbm")))
	{
		createPlatformWindowSurfaceEXT = (PFNEGLCREATEPLATFORMWINDOWSURFACEEXTPROC)
		eglGetProcAddress("eglCreatePlatformWindowSurfaceEXT");
	}
	if (createPlatformWindowSurfaceEXT) {
		surface = createPlatformWindowSurfaceEXT(display, config, gbmSurface, attribs);
	} else {
		ofLog() << "No eglCreatePlatformWindowSurface for GBM, falling back to eglCreateWindowSurface\n" ;
		surface = eglCreateWindowSurface(display, config, (EGLNativeWindowType)gbmSurface, NULL);
	}
}
#if 1
void ofxRPI4Window::rgb2ycbcr_shader()	 
{
	ofShaderSettings settings;
	settings.shaderSources[GL_VERTEX_SHADER] = R"(
		#version 310 es
		uniform mat4 modelViewProjectionMatrix;
		in vec4 position;
		in vec2 texcoord;
		out vec2 texCoordVarying;
		void main(){
			texCoordVarying = texcoord;
			gl_Position = modelViewProjectionMatrix * position;
		}

	)"; 
	settings.shaderSources[GL_FRAGMENT_SHADER] = R"(
		#version 310 es
		precision highp float;
		uniform vec4 globalColor;

		uniform int color_format;

		uniform int is_image;
		uniform int scalar1;
		uniform int scalar2;
		uniform int offset;
		uniform int scale;
		uniform int normalizer;
		uniform vec3 coeffs_num;
		uniform vec3 coeffs_div;
		uniform sampler2D tex0;
		uniform vec2 resolution;
		in vec2 texCoordVarying; 
		out vec4 outputColor;
		
		vec4 RGBtoYCbCr(vec4 rgb) 
		{		
			float Y, Cb, Cr, a;
			Y = round(coeffs_num.x * rgb.r*float(scale) + coeffs_num.y* rgb.g*float(scale) + coeffs_num.z * rgb.b*float(scale));
			Cb = round(((-coeffs_num.x/coeffs_div.x) * rgb.r*float(scale) - (coeffs_num.y/coeffs_div.x) * rgb.g*float(scale) + coeffs_div.z * rgb.b*float(scale))*float(scalar1)/float(scalar2) + float(offset)); // Chrominance Blue
			Cr = round((coeffs_div.z * rgb.r*float(scale) - (coeffs_num.y/coeffs_div.y) * rgb.g*float(scale) - (coeffs_num.z/coeffs_div.y) * rgb.b*float(scale))*float(scalar1)/float(scalar2) + float(offset)); // Chrominance Red
			a = 1.0;
 
		
		//	     Y = dot(rgb.rgb, coeffs_num*64.0625);
		//	    Cb = dot(rgb.rgb, vec3(-coeffs_num.x/coeffs_div.x,-coeffs_num.y/coeffs_div.x, coeffs_div.z)) + 0.5;
		//	    Cr = dot(rgb.rgb, vec3(coeffs_div.z, -coeffs_num.y/coeffs_div.y, -coeffs_num.z/coeffs_div.y)) + 0.5;	

			if (color_format == 1) {
				return vec4(Cb/float(normalizer),Cr/float(normalizer),Y/float(normalizer), a);
			}
			if (color_format == 2) {
				return vec4(Y/float(normalizer),Cb/float(normalizer),Cr/float(normalizer), a);
		//	return vec4(Y,Cb,Cr, a); 
			}
		}

		void main() {
			if (is_image == 1) {
				vec4 color = texture(tex0, texCoordVarying);
				outputColor = RGBtoYCbCr(color.rgba);
			} else {
				outputColor = RGBtoYCbCr(globalColor.rgba);
			}
		}
		
	)";
	shader.setup(settings);	
}
#endif
#if 0
void ofxRPI4Window::rgb2ycbcr_shader()
{  //  ofShader shader;    

	ofShaderSettings settings;
	settings.shaderSources[GL_VERTEX_SHADER] = R"(
		#version 310 es
		uniform mat4 modelViewProjectionMatrix;
		in vec4 position;
		in vec2 texcoord;
		out vec2 texCoordVarying;
		void main(){
			texCoordVarying = texcoord;
			gl_Position = modelViewProjectionMatrix * position;
		}

	)";

	settings.shaderSources[GL_FRAGMENT_SHADER] = R"(
		#version 310 es
		precision highp float;
		uniform vec4 globalColor;
		uniform int bits;
		uniform int colorimetry;
		uniform int color_format;
		uniform int rgb_quant_range;
		uniform int is_image;
		uniform sampler2D tex0;
		uniform vec2 resolution;
		in vec2 texCoordVarying; 
		out vec4 outputColor;
		
		vec4 RGBtoYCbCr(vec4 rgb)
		{		
			//vec4 rgb1;
			//vec4 rgb2;
			/*
			if (is_image == 1) {
				rgb1 = rgb;
				vec2 onePixel = vec2(1.0, 0.0) / resolution;
				//vec2 position = ( gl_FragCoord.xy / resolution.xy );
				rgb2 = texture(tex0, texCoordVarying + onePixel) * globalColor;//vec4((gl_FragCoord.x+0.5)/u_resolution.x,gl_FragCoord.y/u_resolution.y,1.0,0.0);//rgb;
				
			} 
			if (is_image == 0) {
				rgb1 = rgb2 = rgb; 
			}
			*/
			float coeffs[5][3];
			coeffs[0] = float[](0.2126, 0.7152, 0.0722); //BT709
			coeffs[1] = float[](0.2627, 0.6780, 0.0593); //BT2020
			float Y, Y1, Y2, Cb, Cr, a;
			int R1, G1, B1, R2, G2, B2;
			float d,e,f1,f2,scale, normalizer;
			int shift = bits - 8;
			float scalar_full1 = float(256 << shift);
			float scalar_full2 = float(255 << shift);
			float scalar_limit1 = float(224 << shift);
			float scalar_limit2 = float(219 << shift);
			float scalar1;
			float scalar2;
			float offset  = float(128 << shift);

			int idx;
			if (rgb_quant_range == 1) {
				scalar1=scalar_limit1;
				scalar2=scalar_limit2;
			}
			if (rgb_quant_range == 2) {
				scalar1=scalar_full1;
				scalar2=scalar_full2;
			}
			if (colorimetry == 2) {

					idx = 0;
					d = 1.8556;
					e = 1.5748;
					f1 = f2 = 0.5;

			}	
			if (colorimetry == 9) {

					idx = 1;
					d = 1.8814;
					e = 1.4746;
					f1 = f2 = 0.5;

			}

			normalizer = float((256 << shift) - 1);
		
			if (bits == 10) {
			   shift = 8; // for 10bit need to use 16bit scalar
			}	
			scale = float((256 << shift) - 1);

	//		if (color_format == 0) {
	//			scale =  float((256 << shift) - 1);
				/* YCrCb422 matrix */
	//			Y1 = round(coeffs[idx][0] * float(int(rgb1.r*scale)<<4) + coeffs[idx][1]* float(int(rgb1.g*scale)<<4) + coeffs[idx][2] * float(int(rgb1.b*scale)<<4) + coeffs[idx+4][0] * float(int(rgb2.r*scale)<<4) + coeffs[idx+4][1]* float(int(rgb2.g*scale)<<4) + coeffs[idx+4][2] * float(int(rgb2.b*scale)<<4));
	//			Cb = round((((-coeffs[idx][0]/d) * float(int(rgb1.r*scale)<<4) - (coeffs[idx][1]/d) * float(int(rgb1.g*scale)<<4) + float(f1) * float(int(rgb1.b*scale)<<4) + (-coeffs[idx][0]/d) * float(int(rgb2.r*scale)<<4) - (coeffs[idx][1]/d) * float(int(rgb2.g*scale)<<4) + float(f1) * float(int(rgb2.b*scale)<<4))*scalar1/scalar2)/float(2.0) + 2048.); // Chrominance Blue
	//			Y2 = round(coeffs[idx+4][0] * float(int(rgb1.r*scale)<<4) + coeffs[idx+4][1]* float(int(rgb1.g*scale)<<4) + coeffs[idx+4][2] * float(int(rgb1.b*scale)<<4) + coeffs[idx][0] * float(int(rgb2.r*scale)<<4) + coeffs[idx][1]* float(int(rgb2.g*scale)<<4) + coeffs[idx][2] * float(int(rgb2.b*scale)<<4));
	//			Cr = round(((float(f2) * float(int(rgb1.r*scale)<<4) - (coeffs[idx][1]/e) * float(int(rgb1.g*scale)<<4) - (coeffs[idx][2]/e) * float(int(rgb1.b*scale)<<4) + float(f2) * float(int(rgb2.r*scale)<<4) - (coeffs[idx][1]/e) * float(int(rgb2.g*scale)<<4) - (coeffs[idx][2]/e) * float(int(rgb2.b*scale)<<4))*scalar1/scalar2)/float(2.0) + 2048.); // Chrominance Red
		//		a = 1.0;
				/* Pack YUV for tunneling -- to do?? */
		//	} else {		
				Y = round(coeffs[idx][0] * rgb.r*scale + coeffs[idx][1]* rgb.g*scale + coeffs[idx][2] * rgb.b*scale);
				Cb = round(((-coeffs[idx][0]/d) * rgb.r*scale - (coeffs[idx][1]/d) * rgb.g*scale + float(f1) * rgb.b*scale)*scalar1/scalar2 + offset); // Chrominance Blue
				Cr = round((float(f2) * rgb.r*scale - (coeffs[idx][1]/e) * rgb.g*scale - (coeffs[idx][2]/e) * rgb.b*scale)*scalar1/scalar2 + offset); // Chrominance Red
				a = 1.0;
		//	}
			
			if (color_format == 1) {
				return vec4(Cb/normalizer,Cr/normalizer,Y/normalizer, a); 
			}
			if (color_format == 2) {
				return vec4(Y/normalizer,Cb/normalizer,Cr/normalizer, a);
			}
			if (color_format == 0) {
				/* Pack Dolby As RGB */
				B1 = int(Cb) >> 4;  
				G1 = int(Y1) >> 4;
				R1 = int(Cr) >>4;//int(Y1) & 15 | ((int(Cb) & 15) << 4);
				R2 = int(Cr) >> 4;  
				G2 = int(Y2) >> 4;
				B2 = int(Cb) >> 4;//int(Y2) & 15 | ((int(Cr) & 15) << 4);				

			//	vec2 txc = gl_FragCoord.xy;
			//	vec2 txc =  vec2(gl_FragCoord.x, u_resolution.y - gl_FragCoord.y) - 0.5;
				// even
			//	if (int(floor(txc.x)) % 2 == 0) {
				if(mod(gl_FragCoord.x,2.0)<1.0) {
				
				//	return vec4(Cb/normalizer,Y/normalizer,Cr/normalizer, a);
					return  vec4(float(G1)/normalizer,float(B1)/normalizer, float(R1)/normalizer,a); 
						//			return  vec4(G1/normalizer,B1/normalizer, R1/normalizer,a); 

				// odd
				} else {
				
			//	return vec4(Y2/normalizer,Cb/normalizer,Cr/normalizer, a);
					return  vec4(float(G2)/normalizer,float(B2)/normalizer, float(R2)/normalizer,a); 
				}
			} 

		}


		void main() {
			if (is_image == 1) {
				vec4 color = texture(tex0, texCoordVarying) * globalColor;
				outputColor = RGBtoYCbCr(color.rgba);
			} else {
				outputColor = RGBtoYCbCr(globalColor.rgba);
			}
		} 
	)";
		
	
	shader.setup(settings);	
//	dovi_shader.setup(settings);
}
#endif

void ofxRPI4Window::dovi_pattern_shader()
{  //  ofShader shader;    

	ofShaderSettings settings;
	settings.shaderSources[GL_VERTEX_SHADER] = R"(
		#version 310 es
		uniform mat4 modelViewProjectionMatrix;
		in vec4 position;
		in vec2 texcoord;
		out vec2 texCoordVarying;
		void main(){
			texCoordVarying = texcoord;
			gl_Position = modelViewProjectionMatrix * position;
		}

	)";

	settings.shaderSources[GL_FRAGMENT_SHADER] = R"(
		#version 310 es
		precision highp float;
		uniform vec4 globalColor;
	//	uniform int bits;
	//	uniform int colorimetry;
	//	uniform int color_format;
	//	uniform int rgb_quant_range;
	//	uniform int is_image;
	//	uniform int is_std_DoVi;
		uniform vec3 coeffs_num;
		uniform vec3 coeffs_div;
		uniform sampler2D tex0;
		uniform vec2 resolution;
		in vec2 texCoordVarying; 
		out vec4 outputColor;

		void main() 
		{		
			vec4 rgb1 = globalColor;
			vec4 rgb2 = globalColor;
		//	float coeffs[5][3];
		//	coeffs[0] = float[](0.2126, 0.7152, 0.0722); //BT709
		//	coeffs[1] = float[](0.2627, 0.6780, 0.0593); //BT2020
		//	coeffs[2] = float[](0.212630069, 0.715188177, 0.072181753);  //dovi BT709
		//	coeffs[3] = float[](0.262710755, 0.6779981,	0.059291146); //dovi BT2020
		//	coeffs[4] = float[](0.0, 0.0, 0.0); //dovi rgb2 coeff
			float Y1, Y2, Cb, Cr, a;
			int R1, G1, B1, R2, G2, B2;
	
				/* YCrCb422 matrix */
				Y1 = round(coeffs_num.x * float(int(rgb1.r*256.0)<<4) + coeffs_num.y* float(int(rgb1.g*256.0)<<4) + coeffs_num.z * float(int(rgb1.b*256.0)<<4) + 0.0 * float(int(rgb2.r*256.0)<<4) + 0.0 * float(int(rgb2.g*256.0)<<4) + 0.0 * float(int(rgb2.b*256.0)<<4));
				Cb = round((((-coeffs_num.x/coeffs_div.x) * float(int(rgb1.r*256.0)<<4) - (coeffs_num.y/coeffs_div.x) * float(int(rgb1.g*256.0)<<4) + coeffs_div.z * float(int(rgb1.b*256.0)<<4) + (-coeffs_num.x/coeffs_div.x) * float(int(rgb2.r*256.0)<<4) - (coeffs_num.y/coeffs_div.x) * float(int(rgb2.g*256.0)<<4) + coeffs_div.z * float(int(rgb2.b*256.0)<<4))*224.0/219.0)/2.0 + 2048.0); // Chrominance Blue
				Y2 = round(0.0 * float(int(rgb1.r*256.0)<<4) + 0.0 * float(int(rgb1.g*256.0)<<4) + 0.0 * float(int(rgb1.b*256.0)<<4) + coeffs_num.x * float(int(rgb2.r*256.0)<<4) + coeffs_num.y * float(int(rgb2.g*256.0)<<4) + coeffs_num.z * float(int(rgb2.b*256.0)<<4));
				Cr = round(((coeffs_div.z * float(int(rgb1.r*256.0)<<4) - (coeffs_num.y/coeffs_div.y) * float(int(rgb1.g*256.0)<<4) - (coeffs_num.z/coeffs_div.y) * float(int(rgb1.b*256.0)<<4) + coeffs_div.z * float(int(rgb2.r*256.0)<<4) - (coeffs_num.y/coeffs_div.y) * float(int(rgb2.g*256.0)<<4) - (coeffs_num.z/coeffs_div.y) * float(int(rgb2.b*256.0)<<4))*224.0/219.0)/2.0 + 2048.0); // Chrominance Red
				a = 1.0;
				/* Pack YUV for tunneling -- to do?? */
			

				/* Pack Dolby As RGB */
				R1 = int(Cb) >> 4;  
				G1 = int(Y1) >> 4;
				B1 = int(Y1) & 15 | ((int(Cb) & 15) << 4);
				R2 = int(Cr) >> 4;  
				G2 = int(Y2) >> 4;
				B2 = int(Y2) & 15 | ((int(Cr) & 15) << 4);	
				
				//even
				if(mod(gl_FragCoord.x,2.0)<1.0) {
	
					outputColor =  vec4(float(R1)/255.0,float(G1)/255.0, float(B1)/255.0,a); 

				// odd
				} else {

					outputColor =  vec4(float(R2)/255.0,float(G2)/255.0, float(B2)/255.0,a); 
				}
		} 
	)";
		
	
	shader.setup(settings);	
//	dovi_shader.setup(settings);
}

void ofxRPI4Window::dovi_image_shader()
{  //  ofShader shader;    

	ofShaderSettings settings;
	settings.shaderSources[GL_VERTEX_SHADER] = R"(
		#version 310 es
		uniform mat4 modelViewProjectionMatrix;
		in vec4 position;
		in vec2 texcoord;
		out vec2 texCoordVarying;
		void main(){
			texCoordVarying = texcoord;
			gl_Position = modelViewProjectionMatrix * position;
		}

	)";

	settings.shaderSources[GL_FRAGMENT_SHADER] = R"(
		#version 310 es
		precision highp float;
		uniform vec4 globalColor;

	//	uniform int is_image;
		uniform sampler2D tex0;
		uniform vec2 resolution;
		uniform vec3 coeffs_num;
		uniform vec3 coeffs_div;
		in vec2 texCoordVarying; 
		out vec4 outputColor;
		

		void main() 
		{		

			vec2 onePixel = vec2(1.0, 0.0) / resolution;
			vec4 rgb1 = texture(tex0, texCoordVarying);

				//vec2 position = ( gl_FragCoord.xy / resolution.xy );
			vec4 rgb2 = texture(tex0, texCoordVarying + onePixel);//vec4((gl_FragCoord.x+0.5)/u_resolution.x,gl_FragCoord.y/u_resolution.y,1.0,0.0);//rgb;
				

		//	float coeffs[5][3];
		//	coeffs[0] = float[](0.2126, 0.7152, 0.0722); //BT709
		//	coeffs[1] = float[](0.2627, 0.6780, 0.0593); //BT2020
		//	coeffs[2] = float[](0.212630069, 0.715188177, 0.072181753);  //dovi BT709
		//	coeffs[3] = float[](0.262710755, 0.6779981,	0.059291146); //dovi BT2020
		//	coeffs[4] = float[](0.0, 0.0, 0.0); //dovi rgb2 coeff
			float Y1, Y2, Cb, Cr, a;
			int R1, G1, B1, R2, G2, B2;
		//	float scale;






			//	scale =  256.0;
				/* YCrCb422 matrix */
				Y1 = round(coeffs_num.x * float(int(rgb1.r*256.0)<<4) + coeffs_num.y* float(int(rgb1.g*256.0)<<4) + coeffs_num.z * float(int(rgb1.b*256.0)<<4) + 0.0 * float(int(rgb2.r*256.0)<<4) + 0.0 * float(int(rgb2.g*256.0)<<4) + 0.0 * float(int(rgb2.b*256.0)<<4));
				Cb = round((((-coeffs_num.x/coeffs_div.x) * float(int(rgb1.r*256.0)<<4) - (coeffs_num.y/coeffs_div.x) * float(int(rgb1.g*256.0)<<4) + coeffs_div.z * float(int(rgb1.b*256.0)<<4) + (-coeffs_num.x/coeffs_div.x) * float(int(rgb2.r*256.0)<<4) - (coeffs_num.y/coeffs_div.x) * float(int(rgb2.g*256.0)<<4) + coeffs_div.z * float(int(rgb2.b*256.0)<<4))*224.0/219.0)/2.0 + 2048.0); // Chrominance Blue
				Y2 = round(0.0 * float(int(rgb1.r*256.0)<<4) + 0.0 * float(int(rgb1.g*256.0)<<4) + 0.0 * float(int(rgb1.b*256.0)<<4) + coeffs_num.x * float(int(rgb2.r*256.0)<<4) + coeffs_num.y * float(int(rgb2.g*256.0)<<4) + coeffs_num.z * float(int(rgb2.b*256.0)<<4));
				Cr = round(((coeffs_div.z * float(int(rgb1.r*256.0)<<4) - (coeffs_num.y/coeffs_div.y) * float(int(rgb1.g*256.0)<<4) - (coeffs_num.z/coeffs_div.y) * float(int(rgb1.b*256.0)<<4) + coeffs_div.z * float(int(rgb2.r*256.0)<<4) - (coeffs_num.y/coeffs_div.y) * float(int(rgb2.g*256.0)<<4) - (coeffs_num.z/coeffs_div.y) * float(int(rgb2.b*256.0)<<4))*224.0/219.0)/2.0 + 2048.0); // Chrominance Red
				a = 1.0;
				/* Pack YUV for tunneling -- to do?? */
			

				/* Pack Dolby As RGB */
				R1 = int(Cb) >> 4;  
				G1 = int(Y1) >> 4;
				B1 = int(Y1) & 15 | ((int(Cb) & 15) << 4);
				R2 = int(Cr) >> 4;  
				G2 = int(Y2) >> 4;
				B2 = int(Y2) & 15 | ((int(Cr) & 15) << 4);				

				// even
				if(mod(gl_FragCoord.x,2.0)<1.0) {
	
					outputColor =  vec4(float(R1)/255.0,float(G1)/255.0, float(B1)/255.0,a); 


				// odd
				} else {

					outputColor =  vec4(float(R2)/255.0,float(G2)/255.0, float(B2)/255.0,a); 
				}

		} 
	)";
		 
	
	shader.setup(settings);	
//	dovi_shader.setup(settings);
}
void ofxRPI4Window::HDRWindowSetup()
{
	if (!DestroyWindow()) 
	{
		ofLogError() << "GBM: Failed to deinitialize GBM";
	}
	
    gbmDevice = gbm_create_device(device);
	  if (!gbmDevice)
	{
		ofLogError() << "GBM: - failed to create device: " << gbmDevice; 

	}
#if 0
	if (ofxRPI4Window::bit_depth == 10) {
		if ((strcmp(mode.name, "4096x2160") == 0 || strcmp(mode.name, "3840x2160") == 0) && mode_vrefresh(&mode) >= 30) { 

			mode = MODE_4K_10bit;// mode_3840x2160_30;
			//mode = mode_4096x2160_30;
			ofLogError() << "DRM: - Detected 4k mode > 30Hz...changed resolution to " << mode.hdisplay << "x" << mode.vdisplay << "@" << mode_vrefresh(&mode) <<"Hz";
		}
		
	}
#endif
#if 1
#if defined(HAS_GBM_MODIFIERS)
	if (num_modifiers > 0)
	{
		gbmSurface = gbm_surface_create_with_modifiers(gbmDevice, (uint32_t)mode.hdisplay, (uint32_t)mode.vdisplay, GBM_FORMAT_ABGR2101010, modifiers,
                                                num_modifiers);
	}
#endif
	if (!gbmSurface)
	{
		gbmSurface = gbm_surface_create(gbmDevice, (uint32_t)mode.hdisplay, (uint32_t)mode.vdisplay,GBM_FORMAT_ABGR2101010,
									GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING);
	}

	if (!gbmSurface)
	{
		ofLogError() << "GBM: - failed to create surface: " << strerror(errno);

	} else {

		ofLog() << "GBM: - created surface with size " << mode.hdisplay << "x" << mode.vdisplay << " and " << ((*modifiers >= 0) ? "modifier " : "no modifier ") << hex << ((*modifiers >= 0) ? *modifiers : 0);
	}
	free(modifiers);
#else
    gbmSurface = gbm_surface_create(gbmDevice, (uint32_t)mode.hdisplay, (uint32_t)mode.vdisplay, GBM_FORMAT_ABGR2101010, GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING);

	if (!gbmSurface)
	{
		ofLogError() << "GBM: - failed to create surface: " << strerror(errno);

	} else {

		ofLog() << "GBM: - created surface with size " << mode.hdisplay << "x" << mode.vdisplay;
	}
#endif		
	display = gbm_get_display(gbmDevice);
    if (!display)
    {
        auto error = eglGetError();
        ofLogError() << "display ERROR: " << eglErrorString(error);
    }
        
    int major, minor;
    //   eglInitialize(display, &major, &minor);
    //eglBindAPI(EGL_OPENGL_API);
    if (!eglInitialize(display, &major, &minor))
    {
        auto error = eglGetError();
        ofLogError() << "initialize ERROR: " << eglErrorString(error);
    }
    eglBindAPI(EGL_OPENGL_ES_API);
        
    EGLint count = 0;
    EGLint matched = 0;
    int config_index = -1;
        
    if (!eglGetConfigs(display, NULL, 0, &count) || count < 1)
    {
        ofLogError() << "No EGL configs to choose from";
    }
    ofLog() <<"EGL has " << count << " configs";


	EGLConfig *configs = (EGLConfig *)malloc(count * sizeof *configs);
  //      EGLConfig configs[count];

	EGLint configAttribs[] = {
		EGL_RED_SIZE,10,
		EGL_GREEN_SIZE,10,
		EGL_BLUE_SIZE,10,
		EGL_ALPHA_SIZE,2,
		EGL_DEPTH_SIZE,24,
		EGL_BUFFER_SIZE,32,
		EGL_STENCIL_SIZE,8,
		EGL_SAMPLES,0,
		EGL_SAMPLE_BUFFERS,0,
//		EGL_BIND_TO_TEXTURE_RGBA,EGL_TRUE,
//		EGL_BIND_TO_TEXTURE_RGB,EGL_FALSE,
//		EGL_CONFIG_CAVEAT,EGL_NON_CONFORMANT_CONFIG,
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR, //| EGL_OPENGL_ES3_BIT,
		EGL_COLOR_COMPONENT_TYPE_EXT, EGL_COLOR_COMPONENT_TYPE_FIXED_EXT, //EGL_COLOR_COMPONENT_TYPE_FLOAT_EXT, 
		EGL_NONE
	};
		//EGLint visualId = GBM_FORMAT_RGBX1010102; //??HDR  
	EGLint visualId = GBM_FORMAT_ABGR2101010;

	if (ofGetLogLevel() == 0) PrintConfigs(display);
	 
    EGLConfig config = NULL;
        
        
        
        
    if (!eglChooseConfig(display, configAttribs, configs, count, &matched) || !matched)
	{
        printf("No EGL configs with appropriate attributes.\n");
    }
       
    if (config_index == -1)
    {
        config_index = match_config_to_visual(display,
                                              visualId,
                                              configs,
                                              matched);
    }
        
    if (config_index != -1)
    {
        config = configs[config_index];
    }
        
    free(configs);        
        
 //       const EGLint contextAttribs[] = {
  //         EGL_CONTEXT_CLIENT_VERSION, 2,
  //          EGL_NONE};
    const EGLint contextAttribs[] = {
        EGL_CONTEXT_MAJOR_VERSION, 3,  //update to version 3.0, previously 2
		EGL_CONTEXT_MINOR_VERSION, 1,
        EGL_NONE
	};
			
    if(config)
    {
        context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttribs);
        if (!context)
        {
            auto error = eglGetError();
            ofLogError() << "context ERROR: " << eglErrorString(error);
        }
	    const char *client_extensions = eglQueryString(display, EGL_EXTENSIONS);
				  
	    if (strstr(client_extensions, "EGL_EXT_gl_colorspace_bt2020_pq"))
		{
			ofLog() << "EGL_GL_COLORSPACE_BT2020_PQ_EXT available\n";
				  
		} else {
			ofLogError() << "EGL_GL_COLORSPACE_BT2020_PQ_EXT not available\n";
		}

		if (strstr(client_extensions, "EGL_KHR_gl_colorspace")) {
			ofLog() << "EGL_GL_COLORSPACE_KHR  available\n";
		} else {
			ofLogError() << "EGL_GL_COLORSPACE_KHR not available\n";
		}		
		 
		if (hdr_primaries == 1) {
			if (static_cast<int>(eotf) == 2) {
				EGLint attribs[] = {EGL_GL_COLORSPACE_KHR,EGL_GL_COLORSPACE_BT2020_PQ_EXT,EGL_NONE };
				EGL_create_surface(attribs, config);				
			} else {
				EGLint attribs[] = {EGL_GL_COLORSPACE_KHR,EGL_GL_COLORSPACE_BT2020_LINEAR_EXT,EGL_NONE }; 	
				EGL_create_surface(attribs, config);
			}
		}

		if (hdr_primaries == 2 || hdr_primaries == 0) {
			EGLint attribs[] = {EGL_GL_COLORSPACE_KHR,EGL_GL_COLORSPACE_DISPLAY_P3_LINEAR_EXT,EGL_NONE };    //linear Display-P3 color space is assumed, with a corresponding GL_FRAMEBUFFER_ATTACHMENT_COLOR_ENCODING value of GL_LINEAR
	//		EGLint attribs[] = {EGL_GL_COLORSPACE_KHR,EGL_GL_COLORSPACE_DISPLAY_P3_EXT,EGL_NONE };   //non-linear, sRGB encoded Display-P3 color space is assumed, with a corresponding GL_FRAME-BUFFER_ATTACHMENT_COLOR_ENCODING value of GL_SRGB.
   			EGL_create_surface(attribs, config);
		}

#if 1
		eglSurfaceAttrib(display, surface, SurfaceAttribs[0],EGLint(DisplayChromacityList[hdr_primaries].RedX * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display, surface, SurfaceAttribs[1],EGLint(DisplayChromacityList[hdr_primaries].RedY * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display, surface, SurfaceAttribs[2],EGLint(DisplayChromacityList[hdr_primaries].GreenX * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display, surface, SurfaceAttribs[3],EGLint(DisplayChromacityList[hdr_primaries].GreenY * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display, surface, SurfaceAttribs[4],EGLint(DisplayChromacityList[hdr_primaries].BlueX * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display, surface, SurfaceAttribs[5],EGLint(DisplayChromacityList[hdr_primaries].BlueY * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display, surface, SurfaceAttribs[6],EGLint(DisplayChromacityList[hdr_primaries].WhiteX * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display, surface, SurfaceAttribs[7],EGLint(DisplayChromacityList[hdr_primaries].WhiteY * EGL_METADATA_SCALING_EXT));
//		eglSurfaceAttrib(display, surface, SurfaceAttribs[8],EGLint(10000.0f * 10000.0f));
//		eglSurfaceAttrib(display ,surface, SurfaceAttribs[9],EGLint(0.001f    * 10000.0f));
#endif
        eglSurfaceAttrib(display, surface, SurfaceAttribs[8], hdr_metadata.hdmi_metadata_type1.max_display_mastering_luminance); //EGL_SMPTE2086_MAX_LUMINANCE_EXT
                         
        eglSurfaceAttrib(display, surface, SurfaceAttribs[9], hdr_metadata.hdmi_metadata_type1.min_display_mastering_luminance);	//EGL_SMPTE2086_MIN_LUMINANCE_EXT
                        
		eglSurfaceAttrib(display, surface, SurfaceAttribs[10], hdr_metadata.hdmi_metadata_type1.max_cll); //EGL_CTA861_3_MAX_CONTENT_LIGHT_LEVEL_EXT            

		eglSurfaceAttrib(display, surface, SurfaceAttribs[11], hdr_metadata.hdmi_metadata_type1.max_fall); //EGL_CTA861_3_MAX_FRAME_AVERAGE_LEVEL_EXT  

	 

        if (!surface)
        {
            auto error = eglGetError();
            ofLogError() << "surface ERROR: " << eglErrorString(error);
        }
         currentRenderer.reset();  
        currentRenderer = make_shared<ofGLProgrammableRenderer>(this);
        makeCurrent();
        static_cast<ofGLProgrammableRenderer*>(currentRenderer.get())->setup(3,1);
		if (avi_info.output_format != 0 && shader_init) { 

			rgb2ycbcr_shader();
		}
		if (is_std_DoVi && shader_init) {
			if (colorspace_on) {
				dovi_pattern_shader();
			} else {
				dovi_image_shader();
			}

		}
		EGL_info();	
		ofLog() << "GBM: - initialized GBM";	
			
	} else {
        ofLogError() << "RIP";
    }
	
	
}

void ofxRPI4Window::UploadImage(GLenum textureTarget)
{
	PFNGLEGLIMAGETARGETTEXTURE2DOESPROC glEGLImageTargetTexture2DOES =
        (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress("glEGLImageTargetTexture2DOES");
    assert(glEGLImageTargetTexture2DOES);
	
	glEGLImageTargetTexture2DOES(textureTarget, image);
}

void ofxRPI4Window::DestroyImage()
{
	PFNEGLDESTROYIMAGEKHRPROC eglDestroyImageKHR =
		(PFNEGLDESTROYIMAGEKHRPROC)eglGetProcAddress("eglDestroyImageKHR");
	assert(eglDestroyImageKHR);
	
	eglDestroyImageKHR(display, image);
}

void ofxRPI4Window::Bit10_16WindowSetup()
{
	if (!DestroyWindow()) 
	{
		ofLogError() << "GBM: Failed to deinitialize GBM";
	}
	
    gbmDevice = gbm_create_device(device);
	  if (!gbmDevice)
	{
		ofLogError() << "GBM: - failed to create device: " << gbmDevice; 
 
	}
#if 1
#if defined(HAS_GBM_MODIFIERS)
	if (num_modifiers > 0)
	{
		gbmSurface = gbm_surface_create_with_modifiers(gbmDevice, (uint32_t)mode.hdisplay, (uint32_t)mode.vdisplay, GBM_FORMAT_ABGR16161616F, modifiers,
                                                num_modifiers);
	}
#endif
	if (!gbmSurface)
	{
		gbmSurface = gbm_surface_create(gbmDevice, (uint32_t)mode.hdisplay, (uint32_t)mode.vdisplay,GBM_FORMAT_ABGR16161616F,
									GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING);
	}

	if (!gbmSurface)
	{
		ofLogError() << "GBM: - failed to create surface: " << strerror(errno);

	} else {

		ofLog() << "GBM: - created surface with size " << mode.hdisplay << "x" << mode.vdisplay << " and " << ((*modifiers >= 0) ? "modifier " : "no modifier ") << hex << ((*modifiers >= 0) ? modifiers[0] : 0);
	}
	free(modifiers);
#else
    gbmSurface = gbm_surface_create(gbmDevice, (uint32_t)mode.hdisplay, (uint32_t)mode.vdisplay, GBM_FORMAT_ABGR16161616F, GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING);

	if (!gbmSurface)
	{
		ofLogError() << "GBM: - failed to create surface: " << strerror(errno);

	} else {

		ofLog() << "GBM: - created surface with size " << mode.hdisplay << "x" << mode.vdisplay;
	}
#endif		
	display = gbm_get_display(gbmDevice);
    if (!display)
    {
        auto error = eglGetError();
        ofLogError() << "display ERROR: " << eglErrorString(error);
    }
        
    int major, minor;
    //   eglInitialize(display, &major, &minor);
    //eglBindAPI(EGL_OPENGL_API);
    if (!eglInitialize(display, &major, &minor))
    {
        auto error = eglGetError();
        ofLogError() << "initialize ERROR: " << eglErrorString(error);
    }
    eglBindAPI(EGL_OPENGL_ES_API);
        
    EGLint count = 0;
    EGLint matched = 0;
    int config_index = -1;
        
    if (!eglGetConfigs(display, NULL, 0, &count) || count < 1)
    {
        ofLogError() << "No EGL configs to choose from";
    }
    ofLog() <<"EGL has " << count << " configs";


	EGLConfig *configs = (EGLConfig *)malloc(count * sizeof *configs);
  //      EGLConfig configs[count];

	EGLint configAttribs[] = {
		EGL_RED_SIZE,16,
		EGL_GREEN_SIZE,16,
		EGL_BLUE_SIZE,16,
		EGL_ALPHA_SIZE,16,
		EGL_DEPTH_SIZE,24,
		EGL_BUFFER_SIZE,64,
		EGL_STENCIL_SIZE,8,
		EGL_SAMPLES,0,
		EGL_SAMPLE_BUFFERS,0,
//		EGL_BIND_TO_TEXTURE_RGBA,EGL_TRUE,
//		EGL_BIND_TO_TEXTURE_RGB,EGL_FALSE,
//		EGL_CONFIG_CAVEAT,EGL_NON_CONFORMANT_CONFIG,
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR, //| EGL_OPENGL_ES3_BIT,
		EGL_COLOR_COMPONENT_TYPE_EXT, EGL_COLOR_COMPONENT_TYPE_FLOAT_EXT, //EGL_COLOR_COMPONENT_TYPE_FIXED_EXT, //EGL_COLOR_COMPONENT_TYPE_FLOAT_EXT, 
		EGL_NONE
	};
		//EGLint visualId = GBM_FORMAT_RGBX1010102; //??HDR  
	EGLint visualId = GBM_FORMAT_ABGR16161616F;


  //  eglGetConfigs(display, configs, count, &count);
    
//    int i;
//    for (i = 0; i < count; i++) {
//	printConfigInfo(i, display, &configs[i]);
 //   }
	if (ofGetLogLevel() == 0) PrintConfigs(display);
	 
    EGLConfig config = NULL;
        
        
        
        
    if (!eglChooseConfig(display, configAttribs, configs, count, &matched) || !matched)
	{
        printf("No EGL configs with appropriate attributes.\n");
    }
       
    if (config_index == -1)
    {
        config_index = match_config_to_visual(display,
                                              visualId,
                                              configs,
                                              matched);
    }
        
    if (config_index != -1)
    {
        config = configs[config_index];
    }
    free(configs);         
        
        
 //       const EGLint contextAttribs[] = {
  //         EGL_CONTEXT_CLIENT_VERSION, 2,
  //          EGL_NONE};
    const EGLint contextAttribs[] = {
        EGL_CONTEXT_MAJOR_VERSION, 3,  //update to version 3.0, previously 2
		EGL_CONTEXT_MINOR_VERSION, 1,
        EGL_NONE
	};
		 	
    if(config)
    {
        context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttribs);
        if (!context)
        {
            auto error = eglGetError();
            ofLogError() << "context ERROR: " << eglErrorString(error);
        }
	    const char *client_extensions = eglQueryString(display, EGL_EXTENSIONS);
				  
	    if (strstr(client_extensions, "EGL_EXT_gl_colorspace_bt2020_pq"))
		{
			ofLog() << "EGL_GL_COLORSPACE_BT2020_PQ_EXT available\n";
				  
		} else {
			ofLogError() << "EGL_GL_COLORSPACE_BT2020_PQ_EXT not available\n";
		}
		if (strstr(client_extensions, "EGL_KHR_gl_colorspace")) {
			ofLog() << "EGL_GL_COLORSPACE_KHR  available\n";
		} else {
			ofLogError() << "EGL_GL_COLORSPACE_KHR not available\n";
		}
		EGLint attribs[] = {EGL_GL_COLORSPACE_KHR,EGL_GL_COLORSPACE_BT2020_PQ_EXT,EGL_NONE };         
		EGL_create_surface(attribs, config);
#if 0
		PFNEGLCREATEPLATFORMWINDOWSURFACEEXTPROC createPlatformWindowSurfaceEXT = nullptr;
		const char *extensions = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);
		if (extensions && (strstr(extensions, "EGL_KHR_platform_gbm") || strstr(extensions, "EGL_MESA_platform_gbm"))) {
			createPlatformWindowSurfaceEXT = (PFNEGLCREATEPLATFORMWINDOWSURFACEEXTPROC)
			eglGetProcAddress("eglCreatePlatformWindowSurfaceEXT");
		}
		if (createPlatformWindowSurfaceEXT) {
			surface = createPlatformWindowSurfaceEXT(display, config, gbmSurface, attribs);
		} else {
			ofLog() << "No eglCreatePlatformWindowSurface for GBM, falling back to eglCreateWindowSurface\n" ;
			surface = eglCreateWindowSurface(display, config, (EGLNativeWindowType)gbmSurface, NULL);
		}
#endif

#if 1
		eglSurfaceAttrib(display,surface, SurfaceAttribs[0],EGLint(DisplayChromacityList[2].RedX * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[1],EGLint(DisplayChromacityList[2].RedY * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[2],EGLint(DisplayChromacityList[2].GreenX * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[3],EGLint(DisplayChromacityList[2].GreenY * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[4],EGLint(DisplayChromacityList[2].BlueX * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[5],EGLint(DisplayChromacityList[2].BlueY * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[6],EGLint(DisplayChromacityList[2].WhiteX * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[7],EGLint(DisplayChromacityList[2].WhiteY * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[8],EGLint(10000.0f * 10000.0f));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[9],EGLint(0.001f    * 10000.0f));
#endif

	

        if (!surface)
        {
            auto error = eglGetError();
            ofLogError() << "surface ERROR: " << eglErrorString(error);
        }
#if 0
	EGLint image_attribs[] = {
		EGL_WIDTH, mode.hdisplay,
		EGL_HEIGHT, mode.vdisplay,
		EGL_LINUX_DRM_FOURCC_EXT, fourcc_code('N', 'V', '1', '2'),
		EGL_DMA_BUF_PLANE0_FD_EXT, device,// descriptor->objects[layer->planes[0].object_index].fd,
		EGL_DMA_BUF_PLANE0_OFFSET_EXT, 0,//layer->planes[0].offset,
		EGL_DMA_BUF_PLANE0_PITCH_EXT, 7680,//layer->planes[0].pitch,
		EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, static_cast<EGLint>(modifiers[1] & 0xFFFFFFFF),
		EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, static_cast<EGLint>(modifiers[1] >> 32),

		EGL_DMA_BUF_PLANE1_FD_EXT, device,//descriptor->objects[layer->planes[1].object_index].fd,
		EGL_DMA_BUF_PLANE1_OFFSET_EXT, 0,//layer->planes[1].offset,
		EGL_DMA_BUF_PLANE1_PITCH_EXT, 7680,//layer->planes[1].pitch,
		EGL_DMA_BUF_PLANE1_MODIFIER_LO_EXT, static_cast<EGLint>(modifiers[1] & 0xFFFFFFFF),
		EGL_DMA_BUF_PLANE1_MODIFIER_HI_EXT, static_cast<EGLint>(modifiers[1] >> 32),
		EGL_YUV_COLOR_SPACE_HINT_EXT, EGL_ITU_REC2020_EXT,
		EGL_SAMPLE_RANGE_HINT_EXT, EGL_YUV_FULL_RANGE_EXT,
		EGL_YUV_CHROMA_VERTICAL_SITING_HINT_EXT, EGL_YUV_CHROMA_SITING_0_EXT,
		EGL_YUV_CHROMA_HORIZONTAL_SITING_HINT_EXT, EGL_YUV_CHROMA_SITING_0_EXT,
		EGL_NONE
	};
	
	PFNEGLCREATEIMAGEKHRPROC eglCreateImageKHR =
		(PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
	assert(eglCreateImageKHR);
	
	image = eglCreateImageKHR(display, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, (EGLClientBuffer)NULL, image_attribs);



	if (!image)
	{
		auto error = eglGetError();
		ofLog(OF_LOG_VERBOSE, "{%s} - failed to import buffer into EGL image: {%s}",
				__FUNCTION__, eglErrorString(error));

	}
PFNEGLQUERYDMABUFFORMATSEXTPROC eglQueryDmaBufFormatsEXT =
      (PFNEGLQUERYDMABUFFORMATSEXTPROC)eglGetProcAddress("eglQueryDmaBufFormatsEXT");
       EGLint num_formats = 0;
	   EGLint formats[50];
        bool ok = eglQueryDmaBufFormatsEXT(display, 0, NULL,
                                           &num_formats);
        if (ok && num_formats) {
//formats = calloc(num_formats, sizeof(EGLint));
            ok = eglQueryDmaBufFormatsEXT(display, num_formats,
                                          formats, &num_formats);
   

            ofLog() << "EGL formats supported:";
            for (int i = 0; i < num_formats; ++i) {
				ofLog() << hex << formats[i];
			}
		}
#endif           
        currentRenderer = make_shared<ofGLProgrammableRenderer>(this);
        makeCurrent();
        static_cast<ofGLProgrammableRenderer*>(currentRenderer.get())->setup(3,1);



EGL_info();	
		ofLog() << "GBM: - initialized GBM";	
			
	} else {
        ofLogError() << "RIP";
    }
	
	
}

void ofxRPI4Window::SDRWindowSetup()
{
	


int ret;

	if (!DestroyWindow()) 
	{
		ofLogError() << "GBM: Failed to deinitialize GBM";
	}
	
    gbmDevice = gbm_create_device(device);
	
	if (!gbmDevice)
	{
		ofLogError() << "GBM: - failed to create device: " << gbmDevice; 

	}
#if 1
#if defined(HAS_GBM_MODIFIERS)
	if (num_modifiers > 0)
	{
		gbmSurface = gbm_surface_create_with_modifiers(gbmDevice, (uint32_t)mode.hdisplay, (uint32_t)mode.vdisplay, GBM_FORMAT_ARGB8888, modifiers,
                                                num_modifiers);
	}
#endif
	if (!gbmSurface)
	{
		gbmSurface = gbm_surface_create(gbmDevice, (uint32_t)mode.hdisplay, (uint32_t)mode.vdisplay, GBM_FORMAT_ARGB8888,
									GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING);
	}

	if (!gbmSurface)
	{
		ofLogError() << "GBM: - failed to create surface: " << strerror(errno);

	} else {

		ofLog() << "GBM: - created surface with size " << mode.hdisplay << "x" << mode.vdisplay << " and " << ((*modifiers >= 0) ? "modifier " : "no modifier ") << hex << ((*modifiers >= 0) ? *modifiers : 0);
	}
	free(modifiers);
#else
    gbmSurface = gbm_surface_create(gbmDevice, (uint32_t)mode.hdisplay, (uint32_t)mode.vdisplay, GBM_FORMAT_ARGB8888 , GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING);

	if (!gbmSurface)
	{
		ofLogError() << "GBM: - failed to create surface: " << strerror(errno);

	} else {

		ofLog() << "GBM: - created surface with size " << mode.hdisplay << "x" << mode.vdisplay;
	}
#endif	

	display = gbm_get_display(gbmDevice);
    if (!display)
    {
       auto error = eglGetError();
       ofLogError() << "display ERROR: " << eglErrorString(error);
    }
        
    int major, minor;
    eglInitialize(display, &major, &minor);
    //eglBindAPI(EGL_OPENGL_API);
    eglBindAPI(EGL_OPENGL_ES_API);
        
    EGLint count = 0;
    EGLint matched = 0;
    int config_index = -1;
        
    if (!eglGetConfigs(display, NULL, 0, &count) || count < 1)
    {
        ofLogError() << "No EGL configs to choose from";
    }
    ofLog() <<"EGL has " << count << " configs";


	EGLConfig *configs = (EGLConfig *)malloc(count * sizeof *configs);
  //      EGLConfig configs[count];

	EGLint configAttribs[] = {
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_DEPTH_SIZE, 16,
		EGL_ALPHA_SIZE, 8,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR,
        EGL_NONE
	};
	EGLint visualId = GBM_FORMAT_ARGB8888;

      

	if (ofGetLogLevel() == 0) PrintConfigs(display);
	
    EGLConfig config = NULL;
        
        
        
        
        
    if (!eglChooseConfig(display, configAttribs, configs,
                             count, &matched) || !matched) {
        printf("No EGL configs with appropriate attributes.\n");
    }
        
    if (config_index == -1)
    {
        config_index = match_config_to_visual(display,
                                              visualId,
                                              configs,
                                              matched); 
	}
        
    if (config_index != -1)
	{
		config = configs[config_index];
    }
        
    free(configs);    
        
 //       const EGLint contextAttribs[] = {
  //         EGL_CONTEXT_CLIENT_VERSION, 2,
  //          EGL_NONE};
    const EGLint contextAttribs[] = {
		EGL_CONTEXT_MAJOR_VERSION, 3,  //update to version 3.0, previously 2
		EGL_CONTEXT_MINOR_VERSION, 1,
		EGL_NONE
	};
			 
    if(config)
    {
        context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttribs);
        if (!context)
        {
            auto error = eglGetError();
            ofLogError() << "context ERROR: " << eglErrorString(error);
        }
#if 1
		const char *client_extensions = eglQueryString(display, EGL_EXTENSIONS);
				  

		if (strstr(client_extensions, "EGL_KHR_gl_colorspace")) {
			ofLog() << "EGL_GL_COLORSPACE_KHR  available\n";
		} else {
			ofLogError() << "EGL_GL_COLORSPACE_KHR not available\n";
		}
#if 0
		if (isHDR && isDoVi && is_std_DoVi) {
			if (colorspace_on) { 
				EGLint attribs[] = {EGL_GL_COLORSPACE_KHR, EGL_GL_COLORSPACE_LINEAR_KHR, EGL_NONE }; 
				EGL_create_surface(attribs, config);				
			} else {
				EGLint attribs[] = {EGL_GL_COLORSPACE_KHR, EGL_GL_COLORSPACE_SRGB_KHR, EGL_NONE };  
				EGL_create_surface(attribs, config);
			}

		} else {
			if (colorspace_on) { 
				EGLint attribs[] = {EGL_GL_COLORSPACE_KHR, EGL_GL_COLORSPACE_LINEAR_KHR, EGL_NONE }; 
				EGL_create_surface(attribs, config);				
			} else {
				EGLint attribs[] = {EGL_GL_COLORSPACE_KHR, EGL_GL_COLORSPACE_SRGB_KHR, EGL_NONE };  
				EGL_create_surface(attribs, config);
			}
			
		}
#endif
		EGLint attribs[] = {EGL_GL_COLORSPACE_KHR, EGL_GL_COLORSPACE_LINEAR_KHR, EGL_NONE }; 
		EGL_create_surface(attribs, config);		
#endif

#if 0
		if (isDoVi || is_std_DoVi) {

		eglSurfaceAttrib(display,surface, SurfaceAttribs[0],EGLint(DisplayChromacityList[2].RedX * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[1],EGLint(DisplayChromacityList[2].RedY * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[2],EGLint(DisplayChromacityList[2].GreenX * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[3],EGLint(DisplayChromacityList[2].GreenY * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[4],EGLint(DisplayChromacityList[2].BlueX * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[5],EGLint(DisplayChromacityList[2].BlueY * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[6],EGLint(DisplayChromacityList[2].WhiteX * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[7],EGLint(DisplayChromacityList[2].WhiteY * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[8],EGLint(10000.0f * 10000.0f));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[9],EGLint(0.001f    * 10000.0f));

		} else {

		eglSurfaceAttrib(display,surface, SurfaceAttribs[0],EGLint(DisplayChromacityList[0].RedX * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[1],EGLint(DisplayChromacityList[0].RedY * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[2],EGLint(DisplayChromacityList[0].GreenX * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[3],EGLint(DisplayChromacityList[0].GreenY * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[4],EGLint(DisplayChromacityList[0].BlueX * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[5],EGLint(DisplayChromacityList[0].BlueY * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[6],EGLint(DisplayChromacityList[0].WhiteX * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[7],EGLint(DisplayChromacityList[0].WhiteY * EGL_METADATA_SCALING_EXT));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[8],EGLint(10000.0f * 10000.0f));
		eglSurfaceAttrib(display,surface, SurfaceAttribs[9],EGLint(0.001f    * 10000.0f));
		
		}
#endif	
        if (!surface)
        {
            auto error = eglGetError();
            ofLogError() << "surface ERROR: " << eglErrorString(error);
        }
#if 0
  PFNEGLQUERYDMABUFFORMATSEXTPROC eglQueryDmaBufFormatsEXT =
      (PFNEGLQUERYDMABUFFORMATSEXTPROC)eglGetProcAddress("eglQueryDmaBufFormatsEXT");
       EGLint num_formats = 0;
	   EGLint formats[50];
        bool ok = eglQueryDmaBufFormatsEXT(display, 0, NULL,
                                           &num_formats);
        if (ok && num_formats) {
//formats = calloc(num_formats, sizeof(EGLint));
            ok = eglQueryDmaBufFormatsEXT(display, num_formats,
                                          formats, &num_formats);
    

            ofLog() << "EGL formats supported:";
            for (int i = 0; i < num_formats; ++i) {
				ofLog() << hex << formats[i];
			}
		} 
#endif		
         currentRenderer.reset();  

        currentRenderer = make_shared<ofGLProgrammableRenderer>(this);
        makeCurrent();
        static_cast<ofGLProgrammableRenderer*>(currentRenderer.get())->setup(3,1);
		if (avi_info.output_format != 0 && shader_init) { 

			rgb2ycbcr_shader();

		}
		if (is_std_DoVi && shader_init) {
			if (colorspace_on) {
				dovi_pattern_shader();
			} else {
				dovi_image_shader();
			} 
		}

   EGL_info();   
		ofLog() << "GBM: - initialized GBM";

        }else
        {
            ofLogError() << "RIP";
        }
        
     
    
}




void ofxRPI4Window::makeCurrent()
{
    eglMakeCurrent(display, surface, surface, context);
}

void ofxRPI4Window::update()
{
   // ofLog() << "update";

   if (current_bit_depth != bit_depth)
		flip = 1;
	if (colorspace_status != colorspace_on) 
		flip = 1;
    coreEvents.notifyUpdate();
	if (flip) {
		if (!colorspace_on && !initial_bit_depth) colorspace_on = 0;
		switch (bit_depth) {
			case 0:
				bit_depth = 8;
				colorspace_on = 0;
			break;
			case 8:
				if (colorspace_on) {
				   ofLog() << "DRM: input bit_depth of " << bit_depth << " bits switching to output bpc of " << bit_depth << " bits"; 
				  //  avi_info.max_bpc = starting_bpc;
				   avi_info.max_bpc = bit_depth;

				}
			break;
			case 10:
				if (bit_depth != avi_info.max_bpc) {
					ofLogError() << "DRM: input bit_depth of " << bit_depth << " bits not compatible with output bpc of " << avi_info.max_bpc << " bits, switching output bpc to 10 bits"; 
					avi_info.max_bpc = 10;
				}
				if (!colorspace_on) bit_depth=8;
			break;
			case 12:
				if (bit_depth != avi_info.max_bpc) {
					ofLogError() << "DRM: input bit_depth of " << bit_depth << " bits not compatible with output bpc of " << avi_info.max_bpc << " bits switching output bpc to 12 bits"; 
					avi_info.max_bpc = 12;
				}
			break;
		}  

		if (isHDR && !isDoVi && !is_std_DoVi) { 
			if ((bit_depth >= 8) && (bit_depth <= 10) && (avi_info.max_bpc == 10)) {
				ofLog() << "DRM: updating HDR(10 bit) window/surface"; 
				FindModifiers(DRM_FORMAT_ABGR2101010, HDRplaneId);
//				if (avi_info.rgb_quant_range == 1)
				if (!ofxRPI4Window::shader_init && ofxRPI4Window::avi_info.output_format != 0)
					shader_init = 1;
				HDRWindowSetup();
			} else if ((bit_depth >=8) && (bit_depth <= 12)  && (avi_info.max_bpc == 12)) {
				ofLog() << "DRM: updating HDR(12 bit) window/surface"; 
				FindModifiers(DRM_FORMAT_ABGR16161616F, HDRplaneId);
				Bit10_16WindowSetup();
			} else {
				ofLog() << "DRM: updating HDR(8 bit) window/surface"; 
				FindModifiers(DRM_FORMAT_ARGB8888, SDRplaneId);
//				if (avi_info.rgb_quant_range == 1)
				if (!ofxRPI4Window::shader_init && ofxRPI4Window::avi_info.output_format != 0)
					shader_init = 1;
				SDRWindowSetup();				
			}	
		}
		else if (isHDR && isDoVi && !is_std_DoVi) {

			if ((bit_depth >= 8) && (bit_depth <= 10) && (avi_info.max_bpc == 10)) {
				ofLog() << "DRM: updating Low Latency DoVi(10 bit) window/surface"; 
				FindModifiers(DRM_FORMAT_ABGR2101010, HDRplaneId);
				HDRWindowSetup();
			} else if ((bit_depth >=8) && (bit_depth <= 12)  && (avi_info.max_bpc == 12)) {
				ofLog() << "DRM: updating Low Latency DoVi(12 bit) window/surface"; 
				FindModifiers(DRM_FORMAT_ABGR16161616F, HDRplaneId);
				Bit10_16WindowSetup();
			} else {
				ofLog() << "DRM: updating Low Latency Dovi(8 bit) window/surface"; 
				FindModifiers(DRM_FORMAT_ARGB8888, SDRplaneId);
				SDRWindowSetup();				
			}	

		} else if (isHDR && isDoVi && is_std_DoVi) {
		 	if (bit_depth == 10) {
				ofLog() << "DRM: updating Standard DoVi(10 bit) window/surface"; 
				FindModifiers(DRM_FORMAT_ABGR2101010, HDRplaneId);
				if (!ofxRPI4Window::shader_init && avi_info.output_format == 0 && avi_info.rgb_quant_range == 2)
					shader_init =1;
				HDRWindowSetup();
			} else {
				ofLog() << "DRM: updating Standard DoVi(8 bit) window/surface"; 
				FindModifiers(DRM_FORMAT_ARGB8888, SDRplaneId);
				if (!ofxRPI4Window::shader_init && avi_info.output_format == 0 && avi_info.rgb_quant_range == 2)
					shader_init = 1;				
				SDRWindowSetup();
			}

		} 
		else {
		 	if (bit_depth == 10) {
				ofLog() << "DRM: updating SDR(10 bit) window/surface"; 
				FindModifiers(DRM_FORMAT_ABGR2101010, HDRplaneId);
//				if (avi_info.rgb_quant_range == 1)
				if (!ofxRPI4Window::shader_init && ofxRPI4Window::avi_info.output_format != 0)
					shader_init = 1;
				HDRWindowSetup();
			} else {
				ofLog() << "DRM: updating SDR(8 bit) window/surface"; 
//				if (avi_info.rgb_quant_range == 1)
				if (!ofxRPI4Window::shader_init && ofxRPI4Window::avi_info.output_format != 0)
					shader_init = 1;
				FindModifiers(DRM_FORMAT_ARGB8888, SDRplaneId);
				SDRWindowSetup();
			}
		}
		//	flip = 0;
		current_bit_depth = bit_depth;
		colorspace_status = colorspace_on;
	} 
}

int ofxRPI4Window::getWidth()
{
    //ofLog() << __func__ << currentWindowRect.width;
    return currentWindowRect.width;
}

int ofxRPI4Window::getHeight()
{
    //ofLog() << __func__ << currentWindowRect.height;
    
    return currentWindowRect.height;
}

glm::vec2 ofxRPI4Window::getScreenSize()
{
    
    //ofLog() << __func__;
    return {currentWindowRect.getWidth(), currentWindowRect.getHeight()};
}

glm::vec2 ofxRPI4Window::getWindowSize()
{
    //ofLog() << __func__;
    return {currentWindowRect.width, currentWindowRect.height};
}

//------------------------------------------------------------
glm::vec2 ofxRPI4Window::getWindowPosition(){
    //ofLog() << __func__;
    return glm::vec2(currentWindowRect.getPosition());
}

static void on_pageflip_event(int fd, unsigned int frame, unsigned int sec,	unsigned int usec, void *userdata) 
{
	ofLog() << "DRM: page flip event ocurred: " << /*%12.6f\n",*/ std::fixed  << std::setprecision(6) << sec + (usec / 1000000.0);
}


static void drm_fb_destroy_callback(struct gbm_bo *bo, void *data)
{
	drm_fb *fb = static_cast<drm_fb*>(data);

	if (fb->fb_id > 0)
	{
	   int drm_fd = gbm_device_get_fd(gbm_bo_get_device(bo));
	   drmModeRmFB(drm_fd, fb->fb_id);
	}
//	delete fb;
	free(fb);
}

drm_fb * ofxRPI4Window::drm_fb_get_from_bo(struct gbm_bo *bo)
{
	int drm_fd = gbm_device_get_fd(gbm_bo_get_device(bo));
#if 0
  {
	struct drm_fb *fb = static_cast<drm_fb*>(gbm_bo_get_user_data(bo));

   if(fb)
    {
   //   if (gbm_bo_get_format(bo) == fb->format)
        return fb;
   //   else
    //    drm_fb_destroy_callback(bo, gbm_bo_get_user_data(bo));
    }
  }
#endif 
  struct drm_fb *fb = static_cast<drm_fb*>(calloc(1, sizeof *fb)); 
 // struct drm_fb *fb = new drm_fb;

  fb->bo = bo;
  fb->format = gbm_bo_get_format(bo);

  uint32_t handles[4] = {0},
           strides[4] = {0},
           offsets[4] = {0};

  uint64_t modifier[4] = {0};
  
   
	buffer_width = gbm_bo_get_width(bo);
	buffer_height = gbm_bo_get_height(bo);

#if defined(HAS_GBM_MODIFIERS)
  for (int i = 0; i < gbm_bo_get_plane_count(bo); i++) 
  {
    handles[i] = gbm_bo_get_handle_for_plane(bo, i).u32;
    strides[i] = gbm_bo_get_stride_for_plane(bo, i);
    offsets[i] = gbm_bo_get_offset(bo, i);
    modifier[i] = gbm_bo_get_modifier(bo);
  }
#else
  handles[0] = gbm_bo_get_handle(bo).u32;
  strides[0] = gbm_bo_get_stride(bo);
  memset(offsets, 0, 16);

#endif

  uint32_t flags = 0;

	  if (modifier[0] && modifier[0] != DRM_FORMAT_MOD_INVALID)
  {
    flags |= DRM_MODE_FB_MODIFIERS;
   printf("%s - using modifier: {:%llx}\n", __func__, modifier[0]);
  }
	
 int ret = drmModeAddFB2WithModifiers(drm_fd,
                                       buffer_width,
                                       buffer_height,
                                       fb->format,
                                       handles,
                                       strides,
                                       offsets,
                                       modifier,
                                       &fb->fb_id,
                                       flags);

  if(ret < 0)
  {
	if (flags)
			ofLogError() << "DRM: Modifiers failed!";
		
    ret = drmModeAddFB2(drm_fd,
                        buffer_width,
                        buffer_height,
                        fb->format,
                        handles,
                        strides,
                        offsets,
                        &fb->fb_id,
                        flags);

 if (ret < 0)
    {
//      delete fb;
	  free(fb);
      ofLogError() << "DRM: - failed to add framebuffer " <<  strerror(errno) << "  " << errno;
      return nullptr;
    }
  }

// gbm_bo_set_user_data(bo, fb, drm_fb_destroy_callback);
  gbm_bo_set_user_data(bo, fb, NULL);

  return fb;
}

void ofxRPI4Window::swapBuffers()
{
 //    ofLog() << __func__;
    drmEventContext evctx   = {0};
    evctx.version           = DRM_EVENT_CONTEXT_VERSION;
    evctx.page_flip_handler = on_pageflip_event;
   
	setVerticalSync(false);
    EGLBoolean success = eglSwapBuffers(display, surface);
    if(!success) {
        GLint error = eglGetError();
        ofLog() << "eglSwapBuffers failed: " << eglErrorString(error);
    }
    struct gbm_bo *bo = gbm_surface_lock_front_buffer(gbmSurface);
	if (!bo) {
			ofLogError() << "GBM: Failed to lock frontbuffer";

	}
	struct drm_fb *fb = drm_fb_get_from_bo(bo);
	if (!fb) {
		ofLogError() << "DRM: Failed to get a new framebuffer BO";
	}


		
 //  drmModeSetCrtc(device, crtc->crtc_id, fb->fb_id, 0, 0, &connectorId, 1, &mode);   
     FlipPage(flip, fb->fb_id);
     flip = false;  //change to flags 
					/* Allow a modeset change for the first commit only. */
		//flags &= ~(DRM_MODE_ATOMIC_ALLOW_MODESET);
#if 0
	int waiting_for_flip = 1;
	drmModeSetCrtc(device, crtcId, fb->fb_id, 0, 0, &connectorId, 1, &mode);   
	int	ret = drmModePageFlip(device, crtcId, fb->fb_id, DRM_MODE_PAGE_FLIP_ASYNC, &waiting_for_flip);
	if (ret) {
		ofLogError() << "DRM: failed to queue page flip: " << strerror(errno);

	}
#endif
	int ret = drmHandleEvent(device, &evctx);
	if (ret) {
		ofLogError() << "DRM: Failed to wait for page flip completion";
		
	}

    if (previousBo)
    {
        drmModeRmFB(device, previousFb);
        gbm_surface_release_buffer(gbmSurface, previousBo);

    }
    previousBo = bo;
    previousFb = fb->fb_id;

//	flip = false;
	//delete fb;
	free(fb);


}


void ofxRPI4Window::startRender()
{
   //ofLog() << __func__;
//    glEnable(GL_DEPTH_TEST);

    renderer()->startRender();
}

void ofxRPI4Window::finishRender()
{
    //ofLog() << __func__;
    renderer()->finishRender();
}


float timedifference_msec(struct timeval t0, struct timeval t1)
{
    return (t1.tv_sec - t0.tv_sec) * 1000.0f + (t1.tv_usec - t0.tv_usec) / 1000.0f;
}

int ofxRPI4Window::CreateFB_ID()
{
int ret;
	/* Request a dumb buffer */
	struct drm_mode_create_dumb create_request = {
		mode.vdisplay, //height
		mode.hdisplay, //width
		16		//bpp
	};
	ret = ioctl(device, DRM_IOCTL_MODE_CREATE_DUMB, &create_request);

	/* Bail out if we could not allocate a dumb buffer */
	if (ret) {
		printf(
			"Dumb Buffer Object Allocation request of %ux%u@%u failed : %s\n",
			create_request.width, create_request.height,
			create_request.bpp,
			strerror(ret)
		);
	//	goto could_not_allocate_buffer;
	}


ret = drmModeRmFB(device, crtc->buffer_id);

  if (ret) {
    printf("drmModeRmFB failed for fb_id %d with error %d\n", crtc->buffer_id, ret);
  }
	/* create framebuffer object for the dumb-buffer */
	uint32_t bo_handles[4] = { create_request.handle, create_request.handle  };
	uint32_t pitches[4] = { create_request.pitch, create_request.pitch };
	uint32_t offsets[4] = { 0, 276480  };
	 uint32_t flags = 0;
uint64_t modifier[4] = { modifiers[1], modifiers[1] };
	uint32_t frame_buffer_id;
	
	if (modifier[0] && modifier[0] != DRM_FORMAT_MOD_INVALID) 
	{
		flags = DRM_MODE_FB_MODIFIERS;
	}

	ret = drmModeAddFB2WithModifiers(
		device,
		mode.hdisplay, mode.vdisplay,
		DRM_FORMAT_P030, bo_handles,
		pitches, offsets, modifier, &frame_buffer_id, flags
	);

	/* Without framebuffer, we won't do anything so bail out ! */
	if (ret) {
		printf(
			"Could not add a framebuffer using drmModeAddFB2 : %s\n",
			strerror(ret)
		);
	//	goto could_not_add_frame_buffer;
	}

	/* We assume that the currently chosen encoder CRTC ID is the current
	 * one.
	 */
	uint32_t current_crtc_id = crtcId;

	if (!current_crtc_id) {
		printf("The retrieved encoder has no CRTC attached... ?\n");
		//goto could_not_retrieve_current_crtc;
	}

	/* Backup the informations of the CRTC to restore when we're done.
	 * The most important piece seems to currently be the buffer ID.
	 */
	drmModeCrtc * __restrict crtc_to_restore =
		drmModeGetCrtc(device, current_crtc_id);

	if (!crtc_to_restore) {
		printf("Could not retrieve the current CRTC with a valid ID !\n");
	//	goto could_not_retrieve_current_crtc;
	}

	/* Set the CRTC so that it uses our new framebuffer */
	ret = drmModeSetCrtc(
		device, current_crtc_id, frame_buffer_id,
		0, 0,
		&connectorId,
		1,
		&mode);

	/* For this test only : Export our dumb buffer using PRIME */
	/* This will provide us a PRIME File Descriptor that we'll use to
	 * map the represented buffer. This could be also be used to reimport
	 * the GEM buffer into another GPU */
	struct drm_prime_handle prime_request = {
		create_request.handle, //handle
		DRM_CLOEXEC | DRM_RDWR, //flags
		-1 //fd
	};

	ret = ioctl(device, DRM_IOCTL_PRIME_HANDLE_TO_FD, &prime_request);
	int const dma_buf_fd = prime_request.fd;

	/* If we could not export the buffer, bail out since that's the
	 * purpose of our test */
	if (ret || dma_buf_fd < 0) {
		printf(
			"Could not export buffer : %s (%d) - FD : %d\n",
			strerror(ret), ret,
			dma_buf_fd
 		);
	//	goto could_not_export_buffer;
	}
 
	/* Map the exported buffer, using the PRIME File descriptor */
	/* That ONLY works if the DRM driver implements gem_prime_mmap.
	 * This function is not implemented in most of the DRM drivers for 
	 * GPU with discrete memory. Meaning that it will surely fail with
	 * Radeon, AMDGPU and Nouveau drivers for desktop cards ! */
	uint8_t * primed_framebuffer = static_cast<uint8_t*>(mmap(
		0, create_request.size,	PROT_READ | PROT_WRITE, MAP_SHARED,
		dma_buf_fd, 0));
	ret = errno;

	/* Bail out if we could not map the framebuffer using this method */
	if (primed_framebuffer == NULL || primed_framebuffer == MAP_FAILED) {
		printf(
			"Could not map buffer exported through PRIME : %s (%d)\n"
			"Buffer : %p\n",
			strerror(ret), ret,
			primed_framebuffer
		);
		//goto could_not_map_buffer;
	}
	

	printf("Buffer mapped !\n");
return frame_buffer_id;
}

void ofxRPI4Window::ResetConnectorProperties()
{
	bool ok;
	uint64_t blob_id = 0;
	
	ofLog() << "DRM: Resetting connector properties";

	first_req = 1;
					
    //set Colorimetry, set to default
	ok = drm_mode_get_property(device, connectorId,	DRM_MODE_OBJECT_CONNECTOR, "Colorimetry", &prop_id, &colorimetry, &prop);

	if (!ok || !(colorimetry >= 0)) {
			ofLogError() << "Unable to find Colorimetry";
	} else {
	    /* set colorimetry to Default = 0 */
		colorimetry = 0; 
		drm_mode_atomic_set_property(device, req, "Colorimetry", connectorId, prop_id, colorimetry, prop, 0);
    }	
	//set rgb_quant_range, set to full as default
	ok = drm_mode_get_property(device, connectorId, DRM_MODE_OBJECT_CONNECTOR, "rgb quant range", &prop_id, &rgb_quant_range, &prop);

	if (!ok || !(rgb_quant_range >=0)) { 
		ofLogError() << "DRM: Unable to find RGB Quant Range";
	} else {
		
		rgb_quant_range = 2; //set to full as default
		drm_mode_atomic_set_property(device, req, "rgb quant range" , connectorId, prop_id, rgb_quant_range, prop, 0);
	}		

    //disable HDR Metadata
	ok = drm_mode_get_property(device, connectorId,	DRM_MODE_OBJECT_CONNECTOR, "HDR_OUTPUT_METADATA", &prop_id, &blob_id, &prop);
	
	if (!ok || !blob_id) {
		ofLogError() << "Unable to find or HDR_OUTPUT_METADATA not set";
		blob_id = 0; //set to 0 to be sure property is disabled
		drm_mode_atomic_set_property(device, req, "HDR_OUTPUT_METADATA", connectorId, prop_id, blob_id, prop, 0);
	} else {

		if (blob_id) {
			drmModeDestroyPropertyBlob(device, blob_id);
			blob_id = 0;
		}
		drm_mode_atomic_set_property(device, req, "HDR_OUTPUT_METADATA", connectorId, prop_id, blob_id, prop, 0);
	}

	last_req = 1; //final atomic request, set to commit all prior requests
	
    //disable DOVI Metadata
	ok = drm_mode_get_property(device, connectorId,	DRM_MODE_OBJECT_CONNECTOR, "DOVI_OUTPUT_METADATA", &prop_id, &blob_id, &prop);

	if (!ok || !blob_id) {
		ofLogError() << "Unable to find or DOVI_OUTPUT_METADATA not set";
		blob_id = 0; //set to 0 to be sure property is disabled
		drm_mode_atomic_set_property(device, req, "DOVI_OUTPUT_METADATA", connectorId, prop_id, blob_id, prop, DRM_MODE_ATOMIC_ALLOW_MODESET);
	} else {				

		if (blob_id) {
			drmModeDestroyPropertyBlob(device, blob_id);
			blob_id = 0;
		}
		drm_mode_atomic_set_property(device, req, "DOVI_OUTPUT_METADATA", connectorId,	prop_id, blob_id, prop, DRM_MODE_ATOMIC_ALLOW_MODESET);
	}

		
}

void ofxRPI4Window::DisablePlane(uint32_t plane_id, const char* plane)
{
	bool ok;
	ofLog() << "DRM: Disabling " << plane << " plane: " << plane_id;
	
	first_req = 1;
	
    //disable CRTC
 	ok = drm_mode_get_property(device, plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_ID", &prop_id, NULL, &prop);
	if (!ok)
		ofLogError() << "DRM: Unable to find CRTC_ID";

 	drm_mode_atomic_set_property(device, req, "CRTC_ID" , plane_id,	prop_id, 0, prop, 0);
	
    //disable FB_ID					
	ok = drm_mode_get_property(device, plane_id, DRM_MODE_OBJECT_PLANE, "FB_ID", &prop_id, NULL, &prop);
	if (!ok)
		ofLogError() << "DRM: Unable to find FB_ID";
	
	last_req = 1; //final atomic request, set to commit all prior requests
	drm_mode_atomic_set_property(device, req, "FB_ID", plane_id, prop_id , 0, prop, 0); 
	
}

int ofxRPI4Window::SetPlaneId()
{
	if (isHDR)
		return HDRplaneId;
	else
		return SDRplaneId; 
}
 
void ofxRPI4Window::FlipPage(bool flip, uint32_t fb_id)
{
	/***************************************************************/
	/* YQ1 YQ0 YCC Quantization Range 							   */
	/*	0   0     Limited Range									   */
	/*	0   1     Full Range        							   */
	/*	1   0 	  Reserved           							   */
	/*	1   1 	  Reserved           							   */
	/* Table 16 AVI Info Frame YCC Quantization Range, Data Byte 5 */
	/***************************************************************/

	if (flip) { 
		// disable plane when working layer no longer is active, do this at window change/flip	
		DisablePlane(SDRplaneId, "SDR");
		DisablePlane(HDRplaneId, "HDR");
		ResetConnectorProperties();
		if (isHDR && !isDoVi && !is_std_DoVi)
		{  

			updateDoVi_Infoframe(dv_status, dv_interface); // Disable DOVI infoframe
 
			updateHDR_Infoframe(ofxRPI4Window::eotf, hdr_primaries);// Display Gamut P3D65
			struct avi_infoframe avi_infoframe;
//			if (hdr_primaries == 1)
				avi_infoframe.colorimetry = 9; //BT2020_RGB
//			if (hdr_primaries == 2)
//				avi_infoframe.colorimetry = 11; //P3-D65	
			avi_infoframe.rgb_quant_range = avi_info.rgb_quant_range; //Full range [0-255]
			avi_infoframe.output_format = avi_info.output_format; //1; //YCrCb444
			avi_infoframe.max_bpc = avi_info.max_bpc; //10 bit
			avi_infoframe.c_enc = avi_info.c_enc; //ITU-R BT.2020 YCbCr set to 2
			avi_infoframe.c_range = 1; //YCbCr Full range 
			updateAVI_Infoframe(HDRplaneId, avi_infoframe);	  

		} else if (isHDR && isDoVi && !is_std_DoVi) {

			updateDoVi_Infoframe(dv_status, dv_interface); // Enable LLDV DOVI infoframe
			struct avi_infoframe avi_infoframe;
			avi_infoframe.colorimetry = 9; //BT2020_YCC or BT2020_RGB??
			avi_infoframe.rgb_quant_range = avi_info.rgb_quant_range; //Full range [0-255]
			avi_infoframe.output_format = avi_info.output_format; //2; //YCrCb422, doesnt work with YCrCb420 or RGB444
			avi_infoframe.max_bpc = avi_info.max_bpc; // 12 bit
			avi_infoframe.c_enc = 2; //ITU-R BT.2020 YCbCr
			avi_infoframe.c_range = 1; //YCbCr full range
			updateAVI_Infoframe(HDRplaneId, avi_infoframe);	

		} else if (isHDR && isDoVi && is_std_DoVi) {

			updateDoVi_Infoframe(dv_status, dv_interface); // Enable Standard DOVI infoframe
			struct avi_infoframe avi_infoframe;
			avi_infoframe.colorimetry = avi_info.colorimetry; //Default
			avi_infoframe.rgb_quant_range = 2; //Full range [0-255]
			avi_infoframe.output_format = avi_info.output_format; //0 RGB444; //YCrCb422, doesnt work with YCrCb420
			avi_infoframe.max_bpc = avi_info.max_bpc; // only works in 8 bit
			avi_infoframe.c_enc = 2; //ITU-R BT.2020 YCbCr 
			avi_infoframe.c_range = 1; //YCbCr Full Range
			updateAVI_Infoframe(HDRplaneId, avi_infoframe);	

		} else {

			updateDoVi_Infoframe(dv_status, dv_interface); // Disable DOVI infoframe if on, for some reason destroying blob doesn't clear the infoframe
//			updateHDR_Infoframe(ofxRPI4Window::eotf, 0); // Display Gamut Rec709
			struct avi_infoframe avi_infoframe;
			avi_infoframe.colorimetry = avi_info.colorimetry; //Default
			avi_infoframe.rgb_quant_range = avi_info.rgb_quant_range;  //Full range [0-255] = 2
			avi_infoframe.output_format = avi_info.output_format; //1; //YCrCb444
			avi_infoframe.max_bpc = avi_info.max_bpc; //8 bit
			avi_infoframe.c_enc = avi_info.c_enc; //ITU-R BT.709 YCbCr  set to 1
			avi_infoframe.c_range = 1; //YCbCr full range
			updateAVI_Infoframe(SDRplaneId, avi_infoframe);	
		}
		

	}
	
	SetActivePlane(SetPlaneId(), currentWindowRect, fb_id); 

/*
	if (drmModeSetPlane(device, SetPlaneId(), crtcId,
		    fb_id, DRM_MODE_PAGE_FLIP_ASYNC |DRM_MODE_ATOMIC_NONBLOCK, crtc->x, crtc->y,
		    crtc->width, crtc->height, 0, 0,
		    ((int)currentWindowRect.width << 16), ((int)currentWindowRect.height << 16)))
	{
		ofLogError() << "DRM: -failed to enable plane " << strerror(errno) << "  " << errno;
	}
*/
}

void ofxRPI4Window::SetActivePlane(uint32_t plane_id, ofRectangle currentWindowRect, int fb_id)
{
	bool ok;
    uint64_t blob_id;
   
	first_req = 1;

	// at window change/update allow modesetting of CRTC to make active 
	if (flip) {
		
		ofLog() << "DRM: Setting Active plane";	
		
		// set connector CRTC_ID
 		ok = drm_mode_get_property(device, connectorId,	DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID", &prop_id, NULL, &prop);

		if (!ok)
			ofLogError() << "DRM: Unable to find CRTC_ID";

		drm_mode_atomic_set_property(device, req, "CRTC_ID" , connectorId,	prop_id, crtcId, prop, 0);
		
		//set CRTC mode 			
		ok = drm_mode_get_property(device, crtcId, DRM_MODE_OBJECT_CRTC, "MODE_ID", &prop_id, &blob_id, &prop);

		if (!ok || !blob_id)
			ofLogError() << "DRM: Unable to find MODE_ID";
		if (blob_id)
			drmModeDestroyPropertyBlob(device, blob_id);
		blob_id = 0;

		drmModeCreatePropertyBlob(device, &mode, sizeof(mode), (uint32_t*)&blob_id);						  
		drm_mode_atomic_set_property(device, req, "MODE_ID", crtcId, prop_id, blob_id, prop, 0);
		
		//set CRTC as Active		
		ok = drm_mode_get_property(device, crtcId, DRM_MODE_OBJECT_CRTC, "ACTIVE", &prop_id, NULL, &prop);

		if (!ok)
			ofLogError() << "DRM: Unable to find ACTIVE";

		drm_mode_atomic_set_property(device, req, "ACTIVE", crtcId,	prop_id, 1, prop, DRM_MODE_ATOMIC_ALLOW_MODESET);
	}
	//set CRTC dimenstions to match mode and plane
	uint32_t x = static_cast<int32_t>(currentWindowRect.x);
	uint32_t y = static_cast<int32_t>(currentWindowRect.y);
	uint32_t width = ((static_cast<uint32_t>(currentWindowRect.width) + 1) & ~1);
	uint32_t height = ((static_cast<uint32_t>(currentWindowRect.height) + 1) & ~1);
			
	//set plane parameters 
//	flags |= DRM_MODE_PAGE_FLIP_EVENT  | DRM_MODE_ATOMIC_NONBLOCK; //set flags to handle atomic page flip event

	ok = drm_mode_get_property(device, plane_id, DRM_MODE_OBJECT_PLANE, "FB_ID", &prop_id, NULL, &prop);
	drm_mode_atomic_set_property(device, req, "FB_ID", plane_id, prop_id, fb_id, prop, 0);  //value can also be crtc->buffer_id ** FB id to connect to			
					
	ok = drm_mode_get_property(device, plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_ID", &prop_id, NULL, &prop);
	drm_mode_atomic_set_property(device, req, "CRTC_ID", plane_id, prop_id, crtcId, prop, 0);
					
	ok = drm_mode_get_property(device, plane_id, DRM_MODE_OBJECT_PLANE, "SRC_X", &prop_id, NULL, &prop);
	drm_mode_atomic_set_property(device, req, "SRC_X", plane_id, prop_id, 0, prop, 0);
 
	ok = drm_mode_get_property(device, plane_id, DRM_MODE_OBJECT_PLANE, "SRC_Y", &prop_id, NULL, &prop);
	drm_mode_atomic_set_property(device, req, "SRC_Y", plane_id, prop_id, 0 , prop, 0);

	ok = drm_mode_get_property(device, plane_id, DRM_MODE_OBJECT_PLANE, "SRC_W", &prop_id, NULL, &prop);
	drm_mode_atomic_set_property(device, req, "SRC_W", plane_id, prop_id, buffer_width << 16, prop, 0);

	ok = drm_mode_get_property(device, plane_id, DRM_MODE_OBJECT_PLANE, "SRC_H", &prop_id, NULL, &prop);
	drm_mode_atomic_set_property(device, req, "SRC_H", plane_id, prop_id, buffer_height << 16, prop, 0);

	ok = drm_mode_get_property(device, plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_X", &prop_id, NULL, &prop);
	drm_mode_atomic_set_property(device, req, "CRTC_X", plane_id, prop_id, x, prop, 0);
	
	ok = drm_mode_get_property(device, plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_Y", &prop_id, NULL, &prop);
	drm_mode_atomic_set_property(device, req, "CRTC_Y", plane_id, prop_id, y, prop, 0);

	ok = drm_mode_get_property(device, plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_W", &prop_id, NULL, &prop);
	drm_mode_atomic_set_property(device, req, "CRTC_W", plane_id, prop_id, width, prop, 0);
	
	ok = drm_mode_get_property(device, plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_H", &prop_id, NULL, &prop);
	
	last_req = 1;
	drm_mode_atomic_set_property(device, req, "CRTC_H", plane_id, prop_id, height, prop, DRM_MODE_ATOMIC_ALLOW_MODESET | DRM_MODE_PAGE_FLIP_EVENT  | DRM_MODE_ATOMIC_NONBLOCK);

}
void ofxRPI4Window::updateHDR_Infoframe(hdmi_eotf eotf, int idx)
{
	bool ok;
	uint64_t blob_id = 0;	
	ofLog() << "DRM: Setting HDR infoframe";	

/*
	ok = drm_mode_get_property(device, connectorId,	DRM_MODE_OBJECT_CONNECTOR, "DOVI_OUTPUT_METADATA", &prop_id, &blob_id, &prop);
	if (!ok) {
		ofLogError() << "Unable to find DOVI_OUTPUT_METADATA";
	} else {
		if (blob_id) {
			drmModeDestroyPropertyBlob(device, blob_id);
			blob_id = 0;
		}
	}
*/
	ok = drm_mode_get_property(device, connectorId,	DRM_MODE_OBJECT_CONNECTOR, "HDR_OUTPUT_METADATA", &prop_id, &blob_id, &prop);
	if (!ok) {
		ofLogError() << "Unable to find HDR_OUTPUT_METADATA";

	} else {
		if (blob_id)
			drmModeDestroyPropertyBlob(device, blob_id);
		blob_id = 0;
	
		struct drm_hdr_output_metadata meta;
		if (static_cast<int>(eotf) == 3) {
			meta.metadata_type = HDMI_STATIC_METADATA_TYPE1;
			meta.hdmi_metadata_type1.eotf = eotf;
			meta.hdmi_metadata_type1.metadata_type = HDMI_STATIC_METADATA_TYPE1;

			meta.hdmi_metadata_type1.display_primaries[0].x = 0;
			meta.hdmi_metadata_type1.display_primaries[0].y = 0;
			meta.hdmi_metadata_type1.display_primaries[1].x = 0;
			meta.hdmi_metadata_type1.display_primaries[1].y = 0;
			meta.hdmi_metadata_type1.display_primaries[2].x = 0;
			meta.hdmi_metadata_type1.display_primaries[2].y = 0;		
			meta.hdmi_metadata_type1.white_point.x = 0;
			meta.hdmi_metadata_type1.white_point.y = 0;

			meta.hdmi_metadata_type1.max_display_mastering_luminance = 0;
			meta.hdmi_metadata_type1.min_display_mastering_luminance = 0;
		
			meta.hdmi_metadata_type1.max_fall = 0; 
			meta.hdmi_metadata_type1.max_cll = 0;
		} else {
			meta.metadata_type = HDMI_STATIC_METADATA_TYPE1;
			meta.hdmi_metadata_type1.eotf = eotf;
			meta.hdmi_metadata_type1.metadata_type = HDMI_STATIC_METADATA_TYPE1;

			meta.hdmi_metadata_type1.display_primaries[0].x = std::round(DisplayChromacityList[idx].GreenX * EGL_METADATA_SCALING_EXT);
			meta.hdmi_metadata_type1.display_primaries[0].y = std::round(DisplayChromacityList[idx].GreenY * EGL_METADATA_SCALING_EXT);
			meta.hdmi_metadata_type1.display_primaries[1].x = std::round(DisplayChromacityList[idx].BlueX * EGL_METADATA_SCALING_EXT);
			meta.hdmi_metadata_type1.display_primaries[1].y = std::round(DisplayChromacityList[idx].BlueY * EGL_METADATA_SCALING_EXT);
			meta.hdmi_metadata_type1.display_primaries[2].x = std::round(DisplayChromacityList[idx].RedX * EGL_METADATA_SCALING_EXT);
			meta.hdmi_metadata_type1.display_primaries[2].y = std::round(DisplayChromacityList[idx].RedY * EGL_METADATA_SCALING_EXT);		
			meta.hdmi_metadata_type1.white_point.x = std::round(DisplayChromacityList[idx].WhiteX * EGL_METADATA_SCALING_EXT);
			meta.hdmi_metadata_type1.white_point.y = std::round(DisplayChromacityList[idx].WhiteY * EGL_METADATA_SCALING_EXT);

			meta.hdmi_metadata_type1.max_display_mastering_luminance = (uint16_t)((float)hdr_metadata.hdmi_metadata_type1.max_display_mastering_luminance);// * 10000.0f);//(uint16_t)(10000.0f * 10000.0f);
			meta.hdmi_metadata_type1.min_display_mastering_luminance = (uint16_t)((float)(hdr_metadata.hdmi_metadata_type1.min_display_mastering_luminance/10000.0f) * 10000.0f);//(uint16_t)(0.001f    * 10000.0f);
		
			meta.hdmi_metadata_type1.max_fall = (float)hdr_metadata.hdmi_metadata_type1.max_fall; 
			meta.hdmi_metadata_type1.max_cll = (float)hdr_metadata.hdmi_metadata_type1.max_cll;
		}
			
		drmModeCreatePropertyBlob(device, &meta, sizeof(meta), (uint32_t*)&blob_id); 
		first_req = 1; // allocate for atomic requests
		last_req = 1; // commit previous atomic requests	
		drm_mode_atomic_set_property(device, req, "HDR_OUTPUT_METADATA", connectorId, prop_id, blob_id, prop, DRM_MODE_ATOMIC_ALLOW_MODESET);
	}

}
 
void ofxRPI4Window::updateDoVi_Infoframe(int enable, int dv_interface) 
{
	bool ok;
	uint64_t blob_id = 0;
	
	ofLog() << "DRM: Setting DoVi infoframe";	
	
	ok = drm_mode_get_property(device, connectorId,	DRM_MODE_OBJECT_CONNECTOR, "DOVI_OUTPUT_METADATA", &prop_id, &blob_id, &prop);
	
	if (!ok) {
		ofLogError() << "Unable to find DOVI_OUTPUT_METADATA";
	} else {
		if (blob_id)
			drmModeDestroyPropertyBlob(device, blob_id);
		blob_id = 0;	
		if (!enable && !dv_interface) {
			first_req = 1; // allocate for atomic requests
			last_req = 1; // commit previous atomic requests	
			drm_mode_atomic_set_property(device, req, "DOVI_OUTPUT_METADATA", connectorId, prop_id, blob_id, prop, DRM_MODE_ATOMIC_ALLOW_MODESET);
			return; 
		}
		struct dovi_output_metadata dovi;
		if (dv_interface == 1) 
			dovi.oui = 0x000C03;
		else if (dv_interface == 2)	
			dovi.oui = 0x00D046;
		dovi.dv_status = enable; //set to 1 to enable dovi infoframe 
		dovi.dv_interface = dv_interface; 
		dovi.backlight_metadata = 0;
		dovi.backlight_max_luminance = 0;
		dovi.aux_runmode = 0;
		dovi.aux_version = 0;
		dovi.aux_debug = 0;
		drmModeCreatePropertyBlob(device, &dovi, sizeof(dovi), (uint32_t*)&blob_id); 
		first_req = 1; // allocate for atomic requests
		last_req = 1; // commit previous atomic requests	
		drm_mode_atomic_set_property(device, req, "DOVI_OUTPUT_METADATA", connectorId, prop_id, blob_id, prop, DRM_MODE_ATOMIC_ALLOW_MODESET);
	} 

}

void ofxRPI4Window::updateAVI_Infoframe(uint32_t plane_id, struct avi_infoframe avi_infoframe)
{
	bool ok;
	
	ofLog() << "DRM: Setting connector properties";
	
	first_req = 1; // allocate for atomic requests
	
	/* set colorimtery */	
	ok = drm_mode_get_property(device, connectorId,	DRM_MODE_OBJECT_CONNECTOR, "Colorimetry", &prop_id, &colorimetry, &prop);
	
	if (!ok || !(colorimetry >= 0)) {
		ofLogError() << "Unable to find Colorspace";
	} else {
		colorimetry = avi_infoframe.colorimetry; 
		drm_mode_atomic_set_property(device, req, "Colorimetry" , connectorId,	prop_id, colorimetry, prop, 0);
    }			
	
	/* set output format */
	ok = drm_mode_get_property(device, connectorId,	DRM_MODE_OBJECT_CONNECTOR, "output format",	&prop_id, &output_format, &prop);

	if (!ok || !(output_format >=0)) {
		ofLogError() << "DRM: Unable to find OUTPUT FORMAT";
	} else {
		output_format = avi_infoframe.output_format;
		drm_mode_atomic_set_property(device, req, "output format" , connectorId, prop_id, output_format, prop, 0);
	}

	/* set max_bpc */	
	ok = drm_mode_get_property(device, connectorId,	DRM_MODE_OBJECT_CONNECTOR, "max bpc", &prop_id, &max_bpc, &prop);

	if (!ok || !max_bpc) {
		ofLogError() << "DRM: Unable to find MAX_BPC";
	} else {
		max_bpc = avi_infoframe.max_bpc;
		drm_mode_atomic_set_property(device, req, "max bpc" , connectorId,	prop_id, max_bpc, prop, 0);
	}
	
	/* set rgb quant range */
	ok = drm_mode_get_property(device, connectorId,	DRM_MODE_OBJECT_CONNECTOR, "rgb quant range", &prop_id, &rgb_quant_range, &prop);

	if (!ok || !(rgb_quant_range >=0)) { 
		ofLogError() << "DRM: Unable to find RGB Quant Range";
	} else {	
		rgb_quant_range = avi_infoframe.rgb_quant_range;
		drm_mode_atomic_set_property(device, req, "rgb quant range", connectorId, prop_id, rgb_quant_range, prop, 0);
	}	

	ofLog() << "DRM: Setting plane properties";
	
    /* set COLOR_ENCODING plane property, for multi-plane formats, does nothing for single plane formats*/
	ok = drm_mode_get_property(device, plane_id, DRM_MODE_OBJECT_PLANE, "COLOR_ENCODING", &prop_id, &c_enc, &prop);

	if (!ok || !(c_enc >= 0)) {
		ofLogError() << "DRM: Unable find COLOR_ENCODING";
	} else {
		c_enc = avi_infoframe.c_enc; //set to ITU-R BT.601 YCbCr or ITU-R BT.709 YCbCr or ITU-R BT.2020 YCbCr
		drm_mode_atomic_set_property(device, req, "COLOR_ENCODING", plane_id, prop_id, c_enc, prop, 0);
	}

	last_req = 1; // commit previous atomic requests	
	
	/* set COLOR_RANGE plane property */
	ok = drm_mode_get_property(device, plane_id, DRM_MODE_OBJECT_PLANE, "COLOR_RANGE", &prop_id, &c_range, &prop);

	if (!ok || !(c_range >= 0)) {
		ofLogError() << "DRM: Unable find COLOR_RANGE";
	} else {
		c_range = avi_infoframe.c_range; //set to YCbCr full range	
		drm_mode_atomic_set_property(device, req, "COLOR_RANGE", plane_id, prop_id, c_range, prop, DRM_MODE_ATOMIC_ALLOW_MODESET);
	}

}

void ofxRPI4Window::draw()
{
    
//ofLog() << getInfo();
    
    int waiting_for_flip = 1;
    auto startFrame = ofGetElapsedTimeMillis();
    gettimeofday(&t0, 0);
	   
    if(skipRender)
    {
        
        coreEvents.notifyDraw();
        
        swapBuffers();
        
    }else
    {
        currentRenderer->startRender();
        if( bEnableSetupScreen )
        {
            currentRenderer->setupScreen();
          //bEnableSetupScreen = false;
        }
        
        
        coreEvents.notifyDraw();
        currentRenderer->finishRender();
        swapBuffers();
    }

 
    gettimeofday(&t1, 0);
    
    lastFrameTimeMillis = timedifference_msec(t0, t1);
    
    //printf("Code executed in %f milliseconds.\n", elapsed);
    
    
    
    
}

void ofxRPI4Window::setWindowShape(int w, int h)
{
    currentWindowRect = ofRectangle(currentWindowRect.x,currentWindowRect.y, w, h);
}

void ofxRPI4Window::pollEvents()
{
    //ofLog() << "pollEvents";
    
}

ofCoreEvents & ofxRPI4Window::events(){
    return coreEvents;
}


void ofxRPI4Window::enableSetupScreen(){
    bEnableSetupScreen = true;
}

//------------------------------------------------------------
void ofxRPI4Window::disableSetupScreen(){
    bEnableSetupScreen = false;
}

void ofxRPI4Window::setVerticalSync(bool enabled)
{
    eglSwapInterval(display, enabled ? 1 : 0);
}

EGLDisplay ofxRPI4Window::getEGLDisplay()
{
    //ofLog() << __func__;
    return display;
}

EGLContext ofxRPI4Window::getEGLContext()
{
    //ofLog() << __func__;
    
    return context;
}

EGLSurface ofxRPI4Window::getEGLSurface()
{
    //ofLog() << __func__;
    
    return surface;
}

shared_ptr<ofBaseRenderer> & ofxRPI4Window::renderer(){
    
    //ofLog() << __func__;
    
    return currentRenderer;
}

string ofxRPI4Window::getInfo()
{
    
    
    stringstream info;
    
    info << "ofGetFrameRate(): " << ofGetFrameRate() << endl;
    info << "ofGetLastFrameTime(): " << ofGetLastFrameTime() << endl;
    info << "lastFrameTimeMillis: " << lastFrameTimeMillis << endl;

    info << "ofGetWidth(): " << ofGetWidth() << endl;
    info << "ofGetHeight(): " << ofGetHeight()<< endl;
    info << "ofGetScreenHeight(): " << ofGetScreenHeight()<< endl;
    info << "ofGetScreenWidth(): " << ofGetScreenWidth()<< endl;
    info << "ofGetWindowWidth(): " << ofGetWindowWidth()<< endl;
    info << "ofGetWindowHeight(): " << ofGetWindowHeight()<< endl;
    info << "ofGetWindowPositionX(): " << ofGetWindowPositionX()<< endl;
    info << "ofGetWindowPositionY(): " << ofGetWindowPositionY()<< endl;
    info << "ofGetWindowRect(): " << ofGetWindowRect()<< endl;
    
    return info.str();
}
 
bool ofxRPI4Window::DestroyWindow()
{
    DestroySurface();
	DestroyContext();
  if (display != EGL_NO_DISPLAY)
  {
   eglTerminate(display);
   display = EGL_NO_DISPLAY; 
  }
  gbmClean();

  ofLog() << "GBM: - deinitialized GBM";
  return true;
}

void ofxRPI4Window::DestroyContext()
{
  if (context != EGL_NO_CONTEXT)
  {
    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(display, context);
    context = EGL_NO_CONTEXT;
  }
}

void ofxRPI4Window::DestroySurface()
{
  if (surface != EGL_NO_SURFACE)
  {
    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroySurface(display, surface);
    surface = EGL_NO_SURFACE;
  }
} 
void ofxRPI4Window::gbmClean()
{
#if 0 
 // set the previous crtc
    drmModeSetCrtc(device, crtcId, crtc->buffer_id, crtc->x, crtc->y, &connectorId, 1, &crtc->mode);
    drmModeFreeCrtc(crtc);

	drm_mode_atomic_set_property(device, req, "max bpc" , connectorId,
			property_id.max_bpc , 8 , prop );    

	drm_mode_atomic_set_property(device, req, "Colorimetry" , connectorId,
			property_id.colorimetry , 0 , prop );

	drm_mode_atomic_set_property(device, req, "output format" , connectorId,
			property_id.output_format , 0 , prop );
			

	drm_mode_atomic_set_property(device, req, "COLOR_ENCODING" , plane->plane_id,
			property_id.c_enc , 0 , prop );

	drm_mode_atomic_set_property(device, req, "COLOR_RANGE" , plane->plane_id,
			property_id.c_range , 0 , prop );
#endif			
    if (previousBo)
    { 
    //    drmModeRmFB(device, previousFb);
       gbm_surface_release_buffer(gbmSurface, previousBo);
    }

  if (gbmSurface != NULL) { 
    gbm_surface_destroy(gbmSurface);
	gbmSurface = NULL;
  }
  if (gbmDevice != NULL) {
  //  gbm_device_destroy(gbmDevice);
	gbmDevice = NULL;
  }
}


ofxRPI4Window::~ofxRPI4Window()
{
    eglDestroyContext(display, context);
    eglDestroySurface(display, surface);
    eglTerminate(display);
    gbmClean();
    if (drmAuthMagic(device, 0) == EINVAL)
    drmDropMaster(device);
    ::close(device); 
}



