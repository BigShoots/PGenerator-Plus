/* Stub libbcm_host.so for Pi 4/400 KMS (vc4-kms-v3d)
 *
 * On full KMS, the firmware-side dispmanx service is not available.
 * PGeneratord calls bcm_host_init() which tries to register VCHIQ
 * services and fails with "failed to add service - already in use?".
 *
 * This stub makes bcm_host_init() a no-op and returns failure from
 * all vc_dispmanx_* functions, forcing PGeneratord to use its
 * DRM/GBM/EGL code path instead.
 *
 * Usage: LD_PRELOAD=/usr/lib/libbcm_host_stub.so PGeneratord ...
 * Also set LD_LIBRARY_PATH=/usr/lib to prefer Mesa EGL over /opt/vc/lib.
 *
 * Cross-compile:
 *   arm-linux-gnueabihf-gcc -shared -fPIC -o libbcm_host_stub.so bcm_stub.c
 */

#include <stdint.h>
#include <string.h>

typedef uint32_t DISPMANX_DISPLAY_HANDLE_T;
typedef uint32_t DISPMANX_UPDATE_HANDLE_T;
typedef uint32_t DISPMANX_ELEMENT_HANDLE_T;
typedef uint32_t DISPMANX_RESOURCE_HANDLE_T;

/* Core init/deinit - no-ops */
void bcm_host_init(void) { }
void bcm_host_deinit(void) { }

/* Display functions - return failure so oF falls through to DRM */
DISPMANX_DISPLAY_HANDLE_T vc_dispmanx_display_open(uint32_t device) {
 return 0;
}

int vc_dispmanx_display_close(DISPMANX_DISPLAY_HANDLE_T display) {
 return 0;
}

int vc_dispmanx_display_get_info(DISPMANX_DISPLAY_HANDLE_T display,
 void *pinfo) {
 return -1;
}

/* Update functions */
DISPMANX_UPDATE_HANDLE_T vc_dispmanx_update_start(int32_t priority) {
 return 0;
}

int vc_dispmanx_update_submit_sync(DISPMANX_UPDATE_HANDLE_T update) {
 return -1;
}

int vc_dispmanx_update_submit(DISPMANX_UPDATE_HANDLE_T update,
 void *cb_func, void *cb_arg) {
 return -1;
}

/* Element functions */
DISPMANX_ELEMENT_HANDLE_T vc_dispmanx_element_add(
 DISPMANX_UPDATE_HANDLE_T update, DISPMANX_DISPLAY_HANDLE_T display,
 int32_t layer, const void *dest_rect, DISPMANX_RESOURCE_HANDLE_T src,
 const void *src_rect, uint32_t protection, void *alpha,
 void *clamp, uint32_t transform) {
 return 0;
}

int vc_dispmanx_element_remove(DISPMANX_UPDATE_HANDLE_T update,
 DISPMANX_ELEMENT_HANDLE_T element) {
 return -1;
}

int vc_dispmanx_element_change_attributes(DISPMANX_UPDATE_HANDLE_T update,
 DISPMANX_ELEMENT_HANDLE_T element, uint32_t change_flags,
 int32_t layer, uint8_t opacity, const void *dest_rect,
 const void *src_rect, DISPMANX_RESOURCE_HANDLE_T mask,
 uint32_t transform) {
 return -1;
}

/* Resource functions */
DISPMANX_RESOURCE_HANDLE_T vc_dispmanx_resource_create(uint32_t type,
 uint32_t width, uint32_t height, uint32_t *native_image_handle) {
 if (native_image_handle) *native_image_handle = 0;
 return 0;
}

int vc_dispmanx_resource_delete(DISPMANX_RESOURCE_HANDLE_T res) {
 return -1;
}

int vc_dispmanx_resource_write_data(DISPMANX_RESOURCE_HANDLE_T res,
 uint32_t src_type, int src_pitch, void *src_address,
 const void *rect) {
 return -1;
}

/* Display size query - return failure so oF uses DRM for mode info */
int32_t graphics_get_display_size(uint16_t display_number,
 uint32_t *width, uint32_t *height) {
 if (width) *width = 0;
 if (height) *height = 0;
 return -1;
}

/* VCOS stubs that might be needed */
int vcos_init(void) { return 0; }
