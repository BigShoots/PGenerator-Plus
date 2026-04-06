#pragma once

#include "ofConstants.h"
#include "ofAppBaseWindow.h"
#include "ofRectangle.h"
#include "ofGLProgrammableRenderer.h"

#include <stdio.h> // sprintf
#include <stdlib.h>  // malloc
#include <fcntl.h>  // open fcntl
#include <unistd.h> // read close
#include <string.h> // strlen
#include <sys/time.h>

#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>
#include <gbm.h>

#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>


#ifndef EGL_KHR_platform_gbm
#define EGL_KHR_platform_gbm 1
#define EGL_PLATFORM_GBM_KHR              0x31D7
#endif /* EGL_KHR_platform_gbm */
#ifndef EGL_EXT_gl_colorspace_bt2020_pq
#define EGL_EXT_gl_colorspace_bt2020_pq 1
#define EGL_GL_COLORSPACE_BT2020_PQ_EXT   0x3340
#endif /* EGL_EXT_gl_colorspace_bt2020_pq */

#ifndef DRM_FORMAT_NV15 
#define DRM_FORMAT_NV15 fourcc_code('N', 'V', '1', '5')
#endif

#ifndef DRM_FORMAT_NV20
#define DRM_FORMAT_NV20 fourcc_code('N', 'V', '2', '0')
#endif

// P030 should be defined in drm_fourcc.h and hopefully will be sometime
// in the future but until then...
#ifndef DRM_FORMAT_P030
#define DRM_FORMAT_P030 fourcc_code('P', '0', '3', '0')
#endif

#ifndef DRM_FORMAT_NV15
#define DRM_FORMAT_NV15 fourcc_code('N', 'V', '1', '5')
#endif

#ifndef DRM_FORMAT_NV20
#define DRM_FORMAT_NV20 fourcc_code('N', 'V', '2', '0') 
#endif

// V4L2_PIX_FMT_NV12_10_COL128 and V4L2_PIX_FMT_NV12_COL128 should be defined
// in drm_fourcc.h hopefully will be sometime in the future but until then...
#ifndef V4L2_PIX_FMT_NV12_10_COL128
#define V4L2_PIX_FMT_NV12_10_COL128 v4l2_fourcc('N', 'C', '3', '0')
#endif

#ifndef V4L2_PIX_FMT_NV12_COL128
#define V4L2_PIX_FMT_NV12_COL128 v4l2_fourcc('N', 'C', '1', '2') /* 12  Y/CbCr 4:2:0 128 pixel wide column */
#endif

#ifndef HAS_GBM_MODIFIERS
#define HAS_GBM_MODIFIERS
#endif

#define EGL_SMPTE2086_DISPLAY_PRIMARY_RX_EXT 0x3341
#define EGL_SMPTE2086_DISPLAY_PRIMARY_RY_EXT 0x3342
#define EGL_SMPTE2086_DISPLAY_PRIMARY_GX_EXT 0x3343
#define EGL_SMPTE2086_DISPLAY_PRIMARY_GY_EXT 0x3344
#define EGL_SMPTE2086_DISPLAY_PRIMARY_BX_EXT 0x3345
#define EGL_SMPTE2086_DISPLAY_PRIMARY_BY_EXT 0x3346
#define EGL_SMPTE2086_WHITE_POINT_X_EXT   0x3347
#define EGL_SMPTE2086_WHITE_POINT_Y_EXT   0x3348
#define EGL_SMPTE2086_MAX_LUMINANCE_EXT   0x3349
#define EGL_SMPTE2086_MIN_LUMINANCE_EXT   0x334A 
#define	EGL_CTA861_3_MAX_CONTENT_LIGHT_LEVEL_EXT   0x3360
#define	EGL_CTA861_3_MAX_FRAME_AVERAGE_LEVEL_EXT   0x3361
#define METADATA_SCALE(x) (static_cast<EGLint>(x * EGL_METADATA_SCALING_EXT))

typedef EGLDisplay (EGLAPIENTRYP PFNEGLGETPLATFORMDISPLAYEXTPROC) (EGLenum platform, void *native_display, const EGLint *attrib_list);
//EGLAPI EGLDisplay EGLAPIENTRY eglGetPlatformDisplayEXT (EGLenum platform, void *native_display, const EGLint *attrib_list);

using namespace std;

/* HDR EDID parsing. */
#define HDMI_IEEE_OUI 0x000c03
#define HDMI_FORUM_IEEE_OUI 0xc45dd8
#define HDMI_DOVI_OUI 0x00d046
#define HDMI_HDR10_PLUS_OUI 0x90848b
#define CTA_EXTENSION_VERSION		0x03
#define DOVI_VIDEO_DATA_BLOCK 0x1
#define HDR10_PLUS_DATA_BLOCK 0x1 
#define HDR_DYNAMIC_METADATA_BLOCK 0x7
#define HDR_STATIC_METADATA_BLOCK       0x06
#define USE_EXTENDED_TAG		0x07


#define HDR_TYPE_HDR10 1
#define HDR_TYPE_DOVI 2
#define HDR_TYPE_HDR10_PLUS 3
#define HDR_TYPE_HLG 4

// HDR definitions copied from linux/include/uapi/drm/drm_mode.h

#ifndef HAVE_DRM_HDR_OUTPUT_METADATA

struct drm_hdr_metadata_infoframe {
  uint8_t eotf;
  uint8_t metadata_type;
  struct {
    uint16_t x, y;
  } display_primaries[3];
  struct {
    uint16_t x, y;
  } white_point;
  uint16_t max_display_mastering_luminance;
  uint16_t min_display_mastering_luminance;
  uint16_t max_cll;
  uint16_t max_fall;
};

struct drm_hdr_output_metadata {
  uint32_t metadata_type;
  union {
    struct drm_hdr_metadata_infoframe hdmi_metadata_type1;
  };
};
#endif  // HAVE_DRM_HDR_OUTPUT_METADATA

/**
 * struct dovi_output_metadata - DoViSource Metadata
 *
 * DoVi source metadata to be passed from userspace
 */
struct dovi_output_metadata {
	/**
	 * @dv_status: DoVi status, active/not active
	 */
	uint32_t oui = 0;
	uint8_t dv_status = 0;
	uint8_t dv_interface = 0; 
	uint8_t backlight_metadata = 0;
	uint8_t backlight_max_luminance = 0;
	uint8_t aux_runmode = 0;
	uint8_t aux_version = 0;
	uint8_t aux_debug = 0;

};

/* DRM HDR definitions. Not in the UAPI header, unfortunately. */
enum hdmi_metadata_type {
	HDMI_STATIC_METADATA_TYPE1 = 0,
};

enum hdmi_eotf {
	HDMI_EOTF_TRADITIONAL_GAMMA_SDR = 0,
	HDMI_EOTF_TRADITIONAL_GAMMA_HDR = 1,
	HDMI_EOTF_SMPTE_ST2084 = 2,
    HDMI_EOTF_BT_2100_HLG = 3,
	RESERVED_FOR_FUTURE_USE1 = 4,
	RESERVED_FOR_FUTURE_USE2 = 5,	
};

struct drm_fb {
	struct gbm_bo *bo = nullptr;
	uint32_t fb_id = 0;
    uint32_t format = 0;
};

struct avi_infoframe {
	int colorimetry = 0;
	int rgb_quant_range = 0;
    int max_bpc = 0; 
	int output_format = 0;
	int c_enc = 0; 
	int c_range = 0;
};

struct DisplayChromacities
{
	double RedX;
	double RedY;
	double GreenX;
	double GreenY;
	double BlueX;
	double BlueY;
	double WhiteX;
	double WhiteY;
};

static const DisplayChromacities DisplayChromacityList[] =
{
	{ 0.64000, 0.33000, 0.30000, 0.60000, 0.15000, 0.06000, 0.31270, 0.32900 }, // Display Gamut Rec709
	{ 0.70800, 0.29200, 0.17000, 0.79700, 0.13100, 0.04600, 0.31270, 0.32900 }, // Display Gamut Rec2020
	{ 0.68000, 0.32000, 0.26500, 0.69000, 0.15000, 0.06000, 0.31270, 0.32900 }, // Display Gamut P3D65
	{ 0.68000, 0.32000, 0.26500, 0.69000, 0.15000, 0.06000, 0.31400, 0.35100 }, // Display Gamut P3DCI(Theater)
	{ 0.68000, 0.32000, 0.26500, 0.69000, 0.15000, 0.06000, 0.32168, 0.33767 }, // Display Gamut P3D60(ACES Cinema)
	{ 0.67030, 0.32970, 0.26060, 0.67320, 0.14420, 0.05120, 0.31270, 0.32900 }, //videoforge dovi ??
};

static const drmModeModeInfo mode_3840x2160_30 = {
	297000,
	3840, 4016, 4104, 4400, 0,
	2160, 2168, 2178, 2250, 0,
	30,
	DRM_MODE_FLAG_PHSYNC | DRM_MODE_FLAG_PVSYNC,
	DRM_MODE_TYPE_DRIVER,
	"3840x2160"
};


static const drmModeModeInfo mode_4096x2160_30 = {
	297000,
	4096, 4184, 4272, 4400, 0,
	2160, 2168, 2178, 2250, 0,
	30,
	DRM_MODE_FLAG_PHSYNC | DRM_MODE_FLAG_PVSYNC,
	DRM_MODE_TYPE_DRIVER,
	"4096x2160"
};

#ifndef MODE_4K_10bit
#define MODE_4K_10bit mode_3840x2160_30
#endif

class ofxRPI4Window : public ofAppBaseGLESWindow
{
public:
    

    EGLDisplay display = NULL;
	EGLImageKHR image = NULL;
    EGLContext context = NULL;
    EGLSurface surface = NULL;
	
	EGLint SurfaceAttribs [12] = {
		EGL_SMPTE2086_DISPLAY_PRIMARY_RX_EXT,       
		EGL_SMPTE2086_DISPLAY_PRIMARY_RY_EXT,
		EGL_SMPTE2086_DISPLAY_PRIMARY_GX_EXT,
		EGL_SMPTE2086_DISPLAY_PRIMARY_GY_EXT,
		EGL_SMPTE2086_DISPLAY_PRIMARY_BX_EXT,
		EGL_SMPTE2086_DISPLAY_PRIMARY_BY_EXT,
		EGL_SMPTE2086_WHITE_POINT_X_EXT,
		EGL_SMPTE2086_WHITE_POINT_Y_EXT,
		EGL_SMPTE2086_MAX_LUMINANCE_EXT,
		EGL_SMPTE2086_MIN_LUMINANCE_EXT,
		EGL_CTA861_3_MAX_CONTENT_LIGHT_LEVEL_EXT,
		EGL_CTA861_3_MAX_FRAME_AVERAGE_LEVEL_EXT
	};   
    int device;
 
    drmModeModeInfo mode;
    struct gbm_device* gbmDevice = nullptr;
    struct gbm_surface* gbmSurface = nullptr;
	
    drmModeCrtc *crtc = nullptr;
	int crtc_index = 0;
    uint32_t crtcId = 0, connectorId = 0, HDRplaneId = 0, SDRplaneId = 0;

	uint64_t colorimetry = 0, rgb_quant_range = 0, max_bpc = 0, output_format = 0, c_enc = 0, c_range = 0;
	uint32_t prop_id = 0;

	drmModePropertyPtr prop = nullptr;
	drmModeAtomicReq *req = nullptr;
	drmModePlaneRes *res = nullptr;
	drmModePlane *plane = nullptr;
	unsigned int num_modifiers = 0;
	uint64_t *modifiers = nullptr;
	avi_infoframe property_id;
	static struct drm_hdr_output_metadata hdr_metadata;
	static avi_infoframe avi_info;
//	uint32_t flags = DRM_MODE_ATOMIC_ALLOW_MODESET;
	
    gbm_bo *previousBo = nullptr;
    uint32_t previousFb = 0;
	uint32_t buffer_width = 0, buffer_height = 0;
    static ofShader shader;  
 //   static ofShader dovi_shader; 	
    ofRectangle currentWindowRect;
    ofOrientation orientation;
    bool bEnableSetupScreen;
    int glesVersion = 0;
    ofWindowMode windowMode;


    static bool allowsMultiWindow(){ return false; }
    static bool doesLoop(){ return false; }
    static void loop(){};
    static bool needsPolling(){ return true; }
    static void pollEvents();
    

    ofxRPI4Window();
    ofxRPI4Window(const ofGLESWindowSettings & settings);

   
    int getWidth() override;
    int getHeight() override;
    glm::vec2 getWindowSize() override;
    glm::vec2 getWindowPosition() override;
    glm::vec2 getScreenSize()  override;
    ofOrientation getOrientation() { return orientation; }
    void enableSetupScreen() override;
    void disableSetupScreen() override;
    void setWindowShape(int w, int h) override;
    void setVerticalSync(bool enabled) override;
     
    void update() override;
    void draw() override;
	void EGL_info();
	/* DRM utilities, get/set properties, atomic set */
	bool drm_mode_get_property(int drm_fd, uint32_t object_id, uint32_t object_type,
							   const char *name, uint32_t *prop_id /* out */,
							   uint64_t *value /* out */, drmModePropertyPtr *prop /* out */);
							   
	void drm_mode_atomic_set_property(int drm_fd, drmModeAtomicReq *freq, const char *name /* in */, uint32_t object_id /* in */,
									  uint32_t prop_id /* in */, uint64_t value /* in */, drmModePropertyPtr prop /* in */, uint32_t flags);
	int last_req = 0;
	int first_req = 0;
	bool flip = true;

	void get_format_modifiers(int fd, uint32_t blob_id, int format_index);
	void FindModifiers(uint32_t format, uint32_t plane_id);
	int find_device();
	bool InitDRM(); 
	/* Static variables set from command line */
	static int isHDR;
	static int isDoVi;
	static int is_std_DoVi;
	static hdmi_eotf eotf;
	static int hdr_primaries; 
	static int bit_depth;
	static int mode_idx;
	static int dv_profile;	
	static int dv_status;
	static int dv_interface; 
//	static int dv_minpq; 
//	static int dv_maxpq; 
//	static int dv_diagonal; 
	int current_bit_depth = 0;
	int initial_bit_depth = 0;
	int starting_bpc = 0;
	static int colorspace_on;
	int colorspace_status = 0;
	static int shader_init;

	void EGL_create_surface(EGLint attribs[], EGLConfig config);
	
	/* shaders */
	static void rgb2ycbcr_shader();
	static void dovi_pattern_shader();
	static void dovi_image_shader();
	
	int CreateFB_ID();
	/* Parse EDID for HDR and DoVi support report if display supports */
	int is_panel_hdr_dovi(int fd, int connector_id);
	void in_formats_info(int fd, uint32_t blob_id);
	bool cta_is_hdr_static_metadata_block(const char *edid_ext);
	bool cta_is_dovi_video_block(const char *edid_ext);

	/* Set DRM Plane swap between HDR and SDR planes */
	void FlipPage(bool flip, uint32_t fb_id);
	void SetActivePlane(uint32_t plane_id, ofRectangle currentWindowRect, int fb_id);
	void DisablePlane(uint32_t plane_id, const char* plane); 
	void ResetConnectorProperties();
	int SetPlaneId();

	/* Userspace access to HDR, DoVi , AVI Infoframes */
	void updateHDR_Infoframe(enum hdmi_eotf, int idx);
	void updateAVI_Infoframe(uint32_t plane_id, struct avi_infoframe avi_infoframe);
	void updateDoVi_Infoframe(int enable, int dv_interface);

	drm_fb * drm_fb_get_from_bo(struct gbm_bo *bo);
    void swapBuffers() override;
    
    void makeCurrent() override;
    void startRender() override;
    void finishRender() override;
    
    ofCoreEvents coreEvents;
    ofCoreEvents & events();
    std::shared_ptr<ofBaseRenderer> & renderer();
    std::shared_ptr<ofBaseRenderer> currentRenderer;
	
	/* Setup surfaces */
    void setup(const ofGLESWindowSettings & settings);
	void HDRWindowSetup();
	void UploadImage(GLenum textureTarget);
	void Bit10_16WindowSetup();
    void SDRWindowSetup();   
	


  
    EGLDisplay getEGLDisplay() override;
    EGLContext getEGLContext() override;
    EGLSurface getEGLSurface() override;
    bool DestroyWindow();
	void DestroyContext();
	void DestroySurface();
	void DestroyImage();
    virtual ~ofxRPI4Window();
    bool skipRender=false;
    struct timeval t0;
    struct timeval t1;
    float lastFrameTimeMillis;
    string getInfo();
    void gbmClean();
};
