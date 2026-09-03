/* PGenerator+ Patch Companion
 *
 * Displays measurement patches through the target computer's native output
 * pipeline. Windows uses a native DXGI HDR10 swapchain so PQ/BT.2020 patch
 * codes reach the operating-system HDR pipeline without scRGB remapping.
 * Linux drives a Wayland PQ/BT.2020 surface for the same reason. macOS has no
 * PQ surface to offer, so it presents through SDL's Metal EDR path with the
 * PQ decode done locally - a stable code-to-light mapping rather than an
 * absolute one.
 */

#ifndef _WIN32
#ifndef __APPLE__
/* Darwin headers expose everything by default and hide extensions this file
 * relies on when a strict POSIX level is requested, so only Linux asks. */
#define _POSIX_C_SOURCE 200809L
#endif
#endif
#define SDL_MAIN_USE_CALLBACKS 1
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>

#include <ctype.h>
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../../../src/common/pgen_colour_math.h"

/* Use the same embedded proportional UI faces as the Linux Profile Loader.
 * This keeps the pairing screen self-contained while giving both tools the
 * same application typography instead of SDL's terminal-style debug font. */
#include "pgen-ui-font.h"

#ifdef _WIN32
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0600
#endif
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <commctrl.h>
#include <d3d11_1.h>
#include <dxgi1_6.h>
#include <icm.h>
#define close_socket closesocket
typedef SOCKET socket_handle_t;
#define INVALID_SOCKET_HANDLE INVALID_SOCKET

typedef int (__cdecl *PgenNvInitialize)(void);
typedef int (__cdecl *PgenNvUnload)(void);
typedef int (__cdecl *PgenNvGetDisplayId)(const char *, unsigned long *);
typedef int (__cdecl *PgenNvSetSourceColorSpace)(unsigned long, int);
typedef int (__cdecl *PgenNvSetSourceHdrMetadata)(unsigned long, const void *);
typedef int (__cdecl *PgenNvGetHdrToneMapping)(unsigned long, int *);
typedef int (__cdecl *PgenNvSetHdrToneMapping)(unsigned long, int);
typedef void *(__cdecl *PgenNvQueryInterface)(unsigned int);

typedef struct {
    unsigned long version;
    unsigned short display_primary_x0, display_primary_y0;
    unsigned short display_primary_x1, display_primary_y1;
    unsigned short display_primary_x2, display_primary_y2;
    unsigned short display_white_point_x, display_white_point_y;
    unsigned short max_display_mastering_luminance;
    unsigned short min_display_mastering_luminance;
    unsigned short max_content_light_level;
    unsigned short max_frame_average_light_level;
} PgenNvHdrMetadata;
#else
#include <arpa/inet.h>
#include <netdb.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __APPLE__
/* macOS presents HDR through SDL's Metal EDR surface and reads the display's
 * assigned profile from ColorSync, so neither Wayland nor the generated
 * color-management protocol glue exists in this build. */
#include <CoreGraphics/CoreGraphics.h>
#include <ColorSync/ColorSync.h>
#else
#include <wayland-client.h>
#include "pgen-color-management-v1-client-protocol.h"
#endif
#define close_socket close
typedef int socket_handle_t;
#define INVALID_SOCKET_HANDLE (-1)
/* Windows takes its icon from the resource script. Everywhere else the same
 * artwork is compiled in, because the Companion ships as a small zip that must
 * not gain a runtime file dependency. */
#include "pgen-icc-companion-icon.h"
#endif

#ifndef _WIN32
static int reap_profile_loader(void *opaque)
{
    pid_t child = (pid_t)(intptr_t)opaque;
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
    return 0;
}
#endif

#define APP_VERSION "1.4.28"
#define APP_BUILD "1"
#define APP_TITLE "PGenerator+ Patch Companion " APP_VERSION " (build " APP_BUILD ")"
#define RESPONSE_CAPACITY 32768
#define PGEN_UNUSED __attribute__((unused))

#if !defined(_WIN32) && !defined(__APPLE__)
typedef struct {
    struct wl_display *display;
    struct wp_color_manager_v1 *manager;
    struct wp_color_management_surface_v1 *surface;
    /* The wl_surface the color surface above was created for. SDL recreates
     * the window surface on renderer fallback, and a request on a color
     * surface whose wl_surface is gone is a protocol error that fatally
     * closes the display connection. */
    struct wl_surface *bound_surface;
    bool parametric;
    bool set_primaries;
    bool luminances;
    bool mastering_metadata;
    bool pq;
    bool bt2020;
    bool absolute_intent;
    bool absolute_no_adaptation_intent;
    bool description_ready;
    bool description_failed;
    bool information_done;
    bool native_primaries_ready;
    int32_t native_primaries[8];
    bool target_primaries_ready;
    int32_t target_primaries[8];
} PgenWaylandColor;

static PgenWaylandColor wayland_color;

static void pgen_cm_intent(void *data, struct wp_color_manager_v1 *manager,
                           uint32_t intent)
{
    PgenWaylandColor *state = data;
    (void)manager;
    if (intent == WP_COLOR_MANAGER_V1_RENDER_INTENT_ABSOLUTE)
        state->absolute_intent = true;
    else if (intent == WP_COLOR_MANAGER_V1_RENDER_INTENT_ABSOLUTE_NO_ADAPTATION)
        state->absolute_no_adaptation_intent = true;
}

static void pgen_cm_feature(void *data, struct wp_color_manager_v1 *manager,
                            uint32_t feature)
{
    PgenWaylandColor *state = data;
    (void)manager;
    if (feature == WP_COLOR_MANAGER_V1_FEATURE_PARAMETRIC)
        state->parametric = true;
    else if (feature == WP_COLOR_MANAGER_V1_FEATURE_SET_PRIMARIES)
        state->set_primaries = true;
    else if (feature == WP_COLOR_MANAGER_V1_FEATURE_SET_LUMINANCES)
        state->luminances = true;
    else if (feature == WP_COLOR_MANAGER_V1_FEATURE_SET_MASTERING_DISPLAY_PRIMARIES)
        state->mastering_metadata = true;
}

static void pgen_cm_tf(void *data, struct wp_color_manager_v1 *manager,
                       uint32_t transfer)
{
    PgenWaylandColor *state = data;
    (void)manager;
    if (transfer == WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_ST2084_PQ)
        state->pq = true;
}

static void pgen_cm_primaries(void *data, struct wp_color_manager_v1 *manager,
                              uint32_t primaries)
{
    PgenWaylandColor *state = data;
    (void)manager;
    if (primaries == WP_COLOR_MANAGER_V1_PRIMARIES_BT2020)
        state->bt2020 = true;
}

static void pgen_cm_done(void *data, struct wp_color_manager_v1 *manager)
{
    (void)data;
    (void)manager;
}

static const struct wp_color_manager_v1_listener pgen_cm_listener = {
    pgen_cm_intent, pgen_cm_feature, pgen_cm_tf, pgen_cm_primaries, pgen_cm_done
};

static void pgen_registry_global(void *data, struct wl_registry *registry,
                                 uint32_t name, const char *interface,
                                 uint32_t version)
{
    PgenWaylandColor *state = data;
    if (!strcmp(interface, wp_color_manager_v1_interface.name)) {
        uint32_t bind_version = version < 2 ? version : 2;
        state->manager = wl_registry_bind(registry, name,
                                          &wp_color_manager_v1_interface,
                                          bind_version);
        wp_color_manager_v1_add_listener(state->manager, &pgen_cm_listener,
                                         state);
    }
}

static void pgen_registry_remove(void *data, struct wl_registry *registry,
                                 uint32_t name)
{
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener pgen_registry_listener = {
    pgen_registry_global, pgen_registry_remove
};

static void pgen_description_failed(void *data,
                                    struct wp_image_description_v1 *description,
                                    uint32_t cause, const char *message)
{
    PgenWaylandColor *state = data;
    (void)description;
    (void)cause;
    state->description_failed = true;
    SDL_Log("KWin rejected the HDR surface description: %s",
            message && message[0] ? message : "unknown reason");
}

static void pgen_description_ready(void *data,
                                   struct wp_image_description_v1 *description,
                                   uint32_t identity)
{
    PgenWaylandColor *state = data;
    (void)description;
    (void)identity;
    state->description_ready = true;
}

static void pgen_description_ready2(void *data,
                                    struct wp_image_description_v1 *description,
                                    uint32_t identity_hi, uint32_t identity_lo)
{
    PgenWaylandColor *state = data;
    (void)description;
    (void)identity_hi;
    (void)identity_lo;
    state->description_ready = true;
}

static const struct wp_image_description_v1_listener pgen_description_listener = {
    pgen_description_failed, pgen_description_ready, pgen_description_ready2
};

static void pgen_preferred_changed(void *data,
                                   struct wp_color_management_surface_feedback_v1 *feedback,
                                   uint32_t identity)
{ (void)data; (void)feedback; (void)identity; }
static void pgen_preferred_changed2(void *data,
                                    struct wp_color_management_surface_feedback_v1 *feedback,
                                    uint32_t identity_hi, uint32_t identity_lo)
{ (void)data; (void)feedback; (void)identity_hi; (void)identity_lo; }
static const struct wp_color_management_surface_feedback_v1_listener pgen_feedback_listener={
    pgen_preferred_changed, pgen_preferred_changed2
};
static void pgen_info_done(void *data, struct wp_image_description_info_v1 *info)
{ ((PgenWaylandColor *)data)->information_done=true; (void)info; }
static void pgen_info_icc(void *data, struct wp_image_description_info_v1 *info, int32_t fd, uint32_t size)
{ (void)data; (void)info; (void)size; close(fd); }
static void pgen_info_primaries(void *data, struct wp_image_description_info_v1 *info,
                                int32_t rx, int32_t ry, int32_t gx, int32_t gy,
                                int32_t bx, int32_t by, int32_t wx, int32_t wy)
{
    PgenWaylandColor *state=data;
    int32_t values[8]={rx,ry,gx,gy,bx,by,wx,wy};
    memcpy(state->native_primaries,values,sizeof(values));
    state->native_primaries_ready=true; (void)info;
}
static void pgen_info_named_primaries(void *d, struct wp_image_description_info_v1 *i, uint32_t v)
{ (void)d; (void)i; (void)v; }
static void pgen_info_tf_power(void *d, struct wp_image_description_info_v1 *i, uint32_t v)
{ (void)d; (void)i; (void)v; }
static void pgen_info_tf_named(void *d, struct wp_image_description_info_v1 *i, uint32_t v)
{ (void)d; (void)i; (void)v; }
static void pgen_info_luminances(void *d, struct wp_image_description_info_v1 *i, uint32_t a, uint32_t b, uint32_t c)
{ (void)d; (void)i; (void)a; (void)b; (void)c; }
static void pgen_info_target_primaries(void *data, struct wp_image_description_info_v1 *info,
                                       int32_t rx, int32_t ry, int32_t gx, int32_t gy,
                                       int32_t bx, int32_t by, int32_t wx, int32_t wy)
{
    PgenWaylandColor *state=data;
    int32_t values[8]={rx,ry,gx,gy,bx,by,wx,wy};
    memcpy(state->target_primaries,values,sizeof(values));
    state->target_primaries_ready=true; (void)info;
}
static void pgen_info_target_luminance(void *d, struct wp_image_description_info_v1 *i, uint32_t a, uint32_t b)
{ (void)d; (void)i; (void)a; (void)b; }
static void pgen_info_max_cll(void *d, struct wp_image_description_info_v1 *i, uint32_t v)
{ (void)d; (void)i; (void)v; }
static void pgen_info_max_fall(void *d, struct wp_image_description_info_v1 *i, uint32_t v)
{ (void)d; (void)i; (void)v; }
static const struct wp_image_description_info_v1_listener pgen_info_listener={
    pgen_info_done,pgen_info_icc,pgen_info_primaries,pgen_info_named_primaries,
    pgen_info_tf_power,pgen_info_tf_named,pgen_info_luminances,
    pgen_info_target_primaries,pgen_info_target_luminance,pgen_info_max_cll,
    pgen_info_max_fall
};

static bool pgen_wayland_set_hdr_surface(SDL_Window *window, bool hdr,
                                         bool device_encoded,
                                         uint32_t reference_luminance,
                                         double mastering_min_luminance,
                                         double mastering_max_luminance,
                                         double max_cll, double max_fall)
{
    SDL_PropertiesID properties;
    struct wl_surface *wl_surface;

    if (strcmp(SDL_GetCurrentVideoDriver(), "wayland")) return true;
    if (!hdr && !wayland_color.surface) return true;
    properties = SDL_GetWindowProperties(window);
    wayland_color.display = SDL_GetPointerProperty(
        properties, SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, NULL);
    wl_surface = SDL_GetPointerProperty(
        properties, SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, NULL);
    if (!wayland_color.display || !wl_surface) {
        return SDL_SetError("Wayland did not expose the window surface");
    }

    if (!wayland_color.manager) {
        struct wl_registry *registry = wl_display_get_registry(wayland_color.display);
        if (!registry) return SDL_SetError("Could not read Wayland globals");
        wl_registry_add_listener(registry, &pgen_registry_listener,
                                 &wayland_color);
        if (wl_display_roundtrip(wayland_color.display) < 0 ||
            wl_display_roundtrip(wayland_color.display) < 0) {
            wl_registry_destroy(registry);
            return SDL_SetError("Could not query Wayland color management");
        }
        wl_registry_destroy(registry);
        if (!wayland_color.manager)
            return SDL_SetError("KWin does not expose color-management-v1");
    }
    if (wayland_color.surface && wayland_color.bound_surface != wl_surface) {
        /* SDL recreated the window surface (renderer fallback, display
         * move). The color surface still references the destroyed
         * wl_surface, and any request on it makes KWin close the whole
         * display connection. Drop it and bind the current surface. */
        wp_color_management_surface_v1_destroy(wayland_color.surface);
        wayland_color.surface = NULL;
        wayland_color.bound_surface = NULL;
    }
    if (!wayland_color.surface) {
        if (!hdr) return true;
        SDL_Log("Creating Wayland color-management surface (hdr=%d)", hdr ? 1 : 0);
        wayland_color.surface = wp_color_manager_v1_get_surface(
            wayland_color.manager, wl_surface);
        wayland_color.bound_surface = wl_surface;
    }

    SDL_Log("Setting Wayland surface color state hdr=%d manager=%p surface=%p",
            hdr ? 1 : 0, (void *)wayland_color.manager,
            (void *)wayland_color.surface);

    if (!hdr) {
        if (wayland_color.surface)
            wp_color_management_surface_v1_unset_image_description(
                wayland_color.surface);
        wl_display_flush(wayland_color.display);
        return true;
    }

    if (!wayland_color.parametric || !wayland_color.luminances ||
        !wayland_color.pq || !wayland_color.bt2020 ||
        (!wayland_color.absolute_intent &&
         !wayland_color.absolute_no_adaptation_intent)) {
        return SDL_SetError("KWin lacks native BT.2020/PQ surface support");
    }

    /* Locally evaluated B2A values are encoded in the display's device gamut,
     * not BT.2020. Reuse KWin's reported target primaries with PQ transfer so
     * the compositor does not interpret them as BT.2020 a second time. */
    if (device_encoded) {
        struct wp_color_management_surface_feedback_v1 *feedback=
            wp_color_manager_v1_get_surface_feedback(wayland_color.manager,wl_surface);
        struct wp_image_description_v1 *preferred,*description;
        struct wp_image_description_info_v1 *information;
        struct wp_image_description_creator_params_v1 *creator;
        if(!feedback)return SDL_SetError("Could not query the output color description");
        wp_color_management_surface_feedback_v1_add_listener(feedback,&pgen_feedback_listener,&wayland_color);
        preferred=wp_color_management_surface_feedback_v1_get_preferred(feedback);
        if(!preferred){wp_color_management_surface_feedback_v1_destroy(feedback);return SDL_SetError("Could not create the output color description");}
        wayland_color.description_ready=false;
        wayland_color.description_failed=false;
        wp_image_description_v1_add_listener(preferred,&pgen_description_listener,&wayland_color);
        if(wl_display_roundtrip(wayland_color.display)<0||wayland_color.description_failed||!wayland_color.description_ready){
            wp_image_description_v1_destroy(preferred);wp_color_management_surface_feedback_v1_destroy(feedback);return SDL_SetError("KWin rejected the output color description");
        }
        wayland_color.information_done=false;wayland_color.native_primaries_ready=false;wayland_color.target_primaries_ready=false;
        information=wp_image_description_v1_get_information(preferred);
        wp_image_description_info_v1_add_listener(information,&pgen_info_listener,&wayland_color);
        if(wl_display_roundtrip(wayland_color.display)<0||!wayland_color.information_done||!wayland_color.native_primaries_ready||!wayland_color.set_primaries){
            wp_image_description_v1_destroy(preferred);wp_color_management_surface_feedback_v1_destroy(feedback);return SDL_SetError("KWin did not provide native output primaries");
        }
        creator=wp_color_manager_v1_create_parametric_creator(wayland_color.manager);
        wp_image_description_creator_params_v1_set_tf_named(creator,WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_ST2084_PQ);
        {
            const int32_t *p=wayland_color.target_primaries_ready?wayland_color.target_primaries:wayland_color.native_primaries;
            wp_image_description_creator_params_v1_set_primaries(creator,p[0],p[1],p[2],p[3],p[4],p[5],p[6],p[7]);
        }
        wp_image_description_creator_params_v1_set_luminances(creator,0,10000,reference_luminance?reference_luminance:203);
        description=wp_image_description_creator_params_v1_create(creator);
        wayland_color.description_ready=false;wayland_color.description_failed=false;
        wp_image_description_v1_add_listener(description,&pgen_description_listener,&wayland_color);
        if(wl_display_roundtrip(wayland_color.display)<0||wayland_color.description_failed||!wayland_color.description_ready){
            wp_image_description_v1_destroy(description);wp_image_description_v1_destroy(preferred);wp_color_management_surface_feedback_v1_destroy(feedback);return SDL_SetError("KWin rejected native-primary PQ output");
        }
        wp_color_management_surface_v1_set_image_description(wayland_color.surface,description,
            wayland_color.absolute_no_adaptation_intent
                ? WP_COLOR_MANAGER_V1_RENDER_INTENT_ABSOLUTE_NO_ADAPTATION
                : WP_COLOR_MANAGER_V1_RENDER_INTENT_ABSOLUTE);
        wp_image_description_v1_destroy(description);
        wp_image_description_v1_destroy(preferred);
        wp_color_management_surface_feedback_v1_destroy(feedback);
        wl_display_flush(wayland_color.display);
        return true;
    }

    {
        struct wp_image_description_creator_params_v1 *creator =
            wp_color_manager_v1_create_parametric_creator(
                wayland_color.manager);
        struct wp_image_description_v1 *description;
        if (!creator) return SDL_SetError("Could not create HDR parameters");
        wp_image_description_creator_params_v1_set_tf_named(
            creator, WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_ST2084_PQ);
        wp_image_description_creator_params_v1_set_primaries_named(
            creator, WP_COLOR_MANAGER_V1_PRIMARIES_BT2020);
        wp_image_description_creator_params_v1_set_luminances(
            creator, 0, 10000,
            reference_luminance ? reference_luminance : 203);
        /* PQ always has a 10,000-nit primary color volume, but that is not the
         * same thing as the content's mastering volume. Without this metadata
         * KWin assumes every calibration patch may contain 10,000-nit content
         * and tone-maps the whole signal before the output ICC transform. */
        if (wayland_color.mastering_metadata) {
            uint32_t mastering_min = (uint32_t)lround(
                fmax(0.0, fmin(429496.0, mastering_min_luminance)) * 10000.0);
            uint32_t mastering_max = (uint32_t)lround(
                fmax(mastering_min_luminance + 0.0001,
                     fmin(10000.0, mastering_max_luminance)));
            uint32_t content_max = (uint32_t)lround(
                fmax(1.0, fmin(10000.0, max_cll)));
            uint32_t frame_average_max = (uint32_t)lround(
                fmax(1.0, fmin((double)content_max, max_fall)));
            wp_image_description_creator_params_v1_set_mastering_luminance(
                creator, mastering_min, mastering_max);
            wp_image_description_creator_params_v1_set_max_cll(
                creator, content_max);
            wp_image_description_creator_params_v1_set_max_fall(
                creator, frame_average_max);
        }
        description = wp_image_description_creator_params_v1_create(creator);
        if (!description) return SDL_SetError("Could not create HDR description");
        wayland_color.description_ready = false;
        wayland_color.description_failed = false;
        wp_image_description_v1_add_listener(description,
                                             &pgen_description_listener,
                                             &wayland_color);
        if (wl_display_roundtrip(wayland_color.display) < 0 ||
            wayland_color.description_failed ||
            !wayland_color.description_ready) {
            wp_image_description_v1_destroy(description);
            return SDL_SetError("KWin rejected the BT.2020/PQ description");
        }
        wp_color_management_surface_v1_set_image_description(
            wayland_color.surface, description,
            wayland_color.absolute_no_adaptation_intent
                ? WP_COLOR_MANAGER_V1_RENDER_INTENT_ABSOLUTE_NO_ADAPTATION
                : WP_COLOR_MANAGER_V1_RENDER_INTENT_ABSOLUTE);
        wp_image_description_v1_destroy(description);
        wl_display_flush(wayland_color.display);
    }
    return true;
}
#endif
/* PGenerator+ runs its own mDNS responder under this name, independent of
 * whatever mDNS stack the host OS may or may not have configured, so a plain
 * getaddrinfo() for it resolves on both Windows 10+ and Linux with
 * nss-mdns/avahi installed. */
#define PGEN_DISCOVERY_HOST "pgenerator.local"
/* PGenPatchCompanion.template.conf ships inside the installer with these
 * literal slot markers in place of a real SERVER/TOKEN; PGenerator+
 * overwrites the fixed-width slots only when a unit downloads its own
 * personalised copy. A static installer taken straight from a GitHub release
 * still carries the markers, so their presence means the value was never
 * personalised and must be treated the same as the field being absent. */
#define PGEN_SERVER_SLOT_MARKER "__PGEN_SERVER_SLOT__"
#define PGEN_TOKEN_SLOT_MARKER "__PGEN_TOKEN_SLOT__"
/* The conf holds the pairing token, and it was named for the Companion when
 * the Companion was still called the ICC Companion. Both names are read so an
 * install predating the rename keeps its pairing; only the current name is
 * ever written, so the retired file stops mattering after the next save. */
#define PGEN_CONF_NAME "PGenPatchCompanion.conf"
#define PGEN_CONF_RETIRED_NAME "PGenICCCompanion.conf"

typedef struct {
    char server[256];
    char host[192];
    char token[96];
    char client[96];
    char display[192];
    int port;
    struct sockaddr_storage resolved_address;
    int resolved_address_length;
    int resolved_family;
    int resolved_socktype;
    int resolved_protocol;
    bool address_resolved;
} CompanionConfig;

typedef struct {
    SDL_Window *window;
    SDL_Renderer *renderer;
    SDL_Texture *texture;
    SDL_Texture *background_texture;
    SDL_Texture *font_texture[PGEN_FACE_COUNT];
    CompanionConfig config;
    uint64_t sequence;
    bool hdr;
    bool hdr_active;
    float hdr_sdr_white_scale;
    bool fullscreen;
    bool alignment;
    double displayed_r, displayed_g, displayed_b;
    double displayed_max_luma, displayed_min_luma;
    double displayed_max_cll, displayed_max_fall;
    int displayed_size;
    char displayed_mode[32];
    bool quit;
    uint64_t next_poll_ms;
    SDL_Thread *network_thread;
    SDL_Thread *install_thread;
    SDL_Mutex *network_mutex;
    SDL_AtomicInt quit_requested;
    SDL_AtomicInt install_in_progress;
    /* Set by the install worker when the Profile Loader finished applying a
     * profile: the loader cycles Advanced Color underneath this process, and
     * a swapchain created before that cycle can survive demoted to composed
     * presentation, where Windows tone-maps output to the profile-reported
     * peak. Consumed on the main thread by recreating the renderer before
     * the next fullscreen HDR patch is displayed. */
    SDL_AtomicInt presentation_recovery_pending;
    SDL_AtomicInt correction_recovery_pending;
    bool command_pending;
    uint64_t refresh_until_ms;
    uint64_t command_sequence;
    bool command_alignment;
    double command_r, command_g, command_b;
    double command_max_luma, command_min_luma;
    double command_max_cll, command_max_fall;
    int command_size;
    bool command_preserve_hdr_calibration;
    char command_mode[32];
    bool settings_pending;
    bool settings_fullscreen;
    int settings_size;
    uint64_t settings_revision;
    uint64_t applied_settings_revision;
    char correction_mode[16];
    char correction_profile[192];
#ifdef _WIN32
    wchar_t correction_profile_path[32768];
    bool windows_correction_isolated;
    bool windows_startup_restore_complete;
    bool windows_restore_attempted;
    int windowed_x;
    int windowed_y;
    int windowed_width;
    int windowed_height;
    bool windowed_geometry_valid;
    ID3D11Device *hdr_device;
    ID3D11DeviceContext *hdr_context;
    ID3D11DeviceContext1 *hdr_context1;
    IDXGISwapChain *hdr_swapchain;
    ID3D11RenderTargetView *hdr_render_target;
    int hdr_width;
    int hdr_height;
#endif
    char correction_signal_mode[16];
    float *correction_lut;
    int correction_lut_grid;
    /* The profile bytes the transform runs on. Both platforms need these now:
     * only the way the file is located differs, not what is done with it. */
    unsigned char *correction_profile_data;
    size_t correction_profile_size;
    uint64_t correction_lut_revision;
    char correction_error[256];
    bool ack_pending;
    uint64_t ack_sequence;
    bool ack_ok;
    char ack_message[256];
    char ack_renderer[64];
    bool ack_hdr_active;
    bool status_dirty;
    char renderer_name[64];
    char selected_display[192];
    SDL_DisplayID selected_display_id;
#ifdef _WIN32
    wchar_t windows_monitor_path[256];
#endif
#if !defined(_WIN32) && !defined(__APPLE__)
    /* Full path of the profile KWin has assigned to the selected output, as of
     * the last poll. The correction stages read the file from here, the way the
     * Windows build reads the path DXGI hands it. */
    char linux_profile_path[1024];
    char linux_profile_connector[64];
    bool linux_profile_hdr;
    bool linux_forced_profile_passthrough;
#endif
#ifdef __APPLE__
    /* Full path of the profile ColorSync reports for the selected display, as
     * of the last poll. The correction stages read the file from here, the way
     * the Linux build reads the KWin assignment. */
    char macos_profile_path[1024];
#endif
    double source_r, source_g, source_b;
    double submitted_r, submitted_g, submitted_b;
    bool correction_ready;
    char status[256];
} AppState;

static AppState app;

#ifdef _WIN32
static HMODULE pgen_nvapi_module;
static PgenNvUnload pgen_nvapi_unload;
static PgenNvSetSourceColorSpace pgen_nvapi_set_source_color_space;
static PgenNvSetSourceHdrMetadata pgen_nvapi_set_source_hdr_metadata;
static PgenNvSetHdrToneMapping pgen_nvapi_set_hdr_tone_mapping;
static unsigned long pgen_nvapi_display_id;
static int pgen_nvapi_original_tone_mapping;
static int pgen_nvapi_last_status;
static bool pgen_nvapi_source_active;
static UINT pgen_adapter_vendor_id;
static bool pgen_nvapi_tone_mapping_saved;
static bool pgen_nvapi_metadata_valid;
static PgenNvHdrMetadata pgen_nvapi_metadata;

static void *pgen_nvapi_function(PgenNvQueryInterface query, unsigned int id)
{
    return query ? query(id) : NULL;
}

static void windows_nvapi_hdr_source_end(void)
{
    if (pgen_nvapi_source_active && pgen_nvapi_set_source_color_space)
        pgen_nvapi_set_source_color_space(pgen_nvapi_display_id, 0);
    if (pgen_nvapi_tone_mapping_saved && pgen_nvapi_set_hdr_tone_mapping)
        pgen_nvapi_set_hdr_tone_mapping(pgen_nvapi_display_id,
                                        pgen_nvapi_original_tone_mapping);
    if (pgen_nvapi_unload) pgen_nvapi_unload();
    if (pgen_nvapi_module) FreeLibrary(pgen_nvapi_module);
    pgen_nvapi_module = NULL;
    pgen_nvapi_unload = NULL;
    pgen_nvapi_set_source_color_space = NULL;
    pgen_nvapi_set_source_hdr_metadata = NULL;
    pgen_nvapi_set_hdr_tone_mapping = NULL;
    pgen_nvapi_source_active = false;
    pgen_nvapi_tone_mapping_saved = false;
    pgen_nvapi_metadata_valid = false;
}

static bool windows_nvapi_hdr_source_begin(SDL_Window *window)
{
    PgenNvQueryInterface query;
    PgenNvInitialize initialize;
    PgenNvGetDisplayId get_display_id;
    PgenNvGetHdrToneMapping get_tone_mapping;
    MONITORINFOEXA monitor_info;
    HWND hwnd;
    HMONITOR monitor;
    FARPROC query_function;
    void *function;
    int status;

    windows_nvapi_hdr_source_end();
    pgen_nvapi_last_status = -2;
    pgen_nvapi_module = LoadLibraryA("nvapi64.dll");
    if (!pgen_nvapi_module) return false;
    query_function = GetProcAddress(pgen_nvapi_module, "nvapi_QueryInterface");
    memcpy(&query, &query_function, sizeof(query));
    if (!query) goto failed;
#define PGEN_NVAPI_LOAD(target, type, id) \
    do { function = pgen_nvapi_function(query, id); memcpy(&(target), &function, sizeof(type)); } while (0)
    PGEN_NVAPI_LOAD(initialize, PgenNvInitialize, 0x0150e828);
    PGEN_NVAPI_LOAD(pgen_nvapi_unload, PgenNvUnload, 0xd22bdd7e);
    PGEN_NVAPI_LOAD(get_display_id, PgenNvGetDisplayId, 0xae457190);
    PGEN_NVAPI_LOAD(pgen_nvapi_set_source_color_space,
                    PgenNvSetSourceColorSpace, 0x473b6caf);
    PGEN_NVAPI_LOAD(pgen_nvapi_set_source_hdr_metadata,
                    PgenNvSetSourceHdrMetadata, 0x905eb63b);
    PGEN_NVAPI_LOAD(get_tone_mapping, PgenNvGetHdrToneMapping, 0xfbd36e71);
    PGEN_NVAPI_LOAD(pgen_nvapi_set_hdr_tone_mapping,
                    PgenNvSetHdrToneMapping, 0xdd6da362);
#undef PGEN_NVAPI_LOAD
    if (!initialize || !pgen_nvapi_unload || !get_display_id ||
        !pgen_nvapi_set_source_color_space || !pgen_nvapi_set_source_hdr_metadata)
        goto failed;
    status = initialize();
    if (status != 0) { pgen_nvapi_last_status = status; goto failed; }
    hwnd = (HWND)SDL_GetPointerProperty(SDL_GetWindowProperties(window),
                                        SDL_PROP_WINDOW_WIN32_HWND_POINTER, NULL);
    monitor = hwnd ? MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST) : NULL;
    ZeroMemory(&monitor_info, sizeof(monitor_info));
    monitor_info.cbSize = sizeof(monitor_info);
    if (!monitor || !GetMonitorInfoA(monitor, (MONITORINFO *)&monitor_info)) goto failed;
    status = get_display_id(monitor_info.szDevice, &pgen_nvapi_display_id);
    if (status != 0) { pgen_nvapi_last_status = status; goto failed; }
    status = pgen_nvapi_set_source_color_space(pgen_nvapi_display_id, 12);
    if (status != 0) { pgen_nvapi_last_status = status; goto failed; }
    pgen_nvapi_source_active = true;
    if (get_tone_mapping && pgen_nvapi_set_hdr_tone_mapping &&
        get_tone_mapping(pgen_nvapi_display_id,
                         &pgen_nvapi_original_tone_mapping) == 0) {
        pgen_nvapi_tone_mapping_saved = true;
        status = pgen_nvapi_set_hdr_tone_mapping(pgen_nvapi_display_id, 0);
        if (status != 0) { pgen_nvapi_last_status = status; goto failed; }
    }
    pgen_nvapi_last_status = 0;
    return true;
failed:
    windows_nvapi_hdr_source_end();
    return false;
}

static bool windows_nvapi_hdr_metadata(const DXGI_HDR_METADATA_HDR10 *metadata)
{
    PgenNvHdrMetadata converted;
    int status;
    if (!pgen_nvapi_source_active || !pgen_nvapi_set_source_hdr_metadata)
        return false;
    ZeroMemory(&converted, sizeof(converted));
    converted.version = (unsigned long)(sizeof(converted) | (1U << 16));
    converted.display_primary_x0 = metadata->RedPrimary[0];
    converted.display_primary_y0 = metadata->RedPrimary[1];
    converted.display_primary_x1 = metadata->GreenPrimary[0];
    converted.display_primary_y1 = metadata->GreenPrimary[1];
    converted.display_primary_x2 = metadata->BluePrimary[0];
    converted.display_primary_y2 = metadata->BluePrimary[1];
    converted.display_white_point_x = metadata->WhitePoint[0];
    converted.display_white_point_y = metadata->WhitePoint[1];
    converted.max_display_mastering_luminance =
        (unsigned short)metadata->MaxMasteringLuminance;
    converted.min_display_mastering_luminance =
        (unsigned short)metadata->MinMasteringLuminance;
    converted.max_content_light_level = metadata->MaxContentLightLevel;
    converted.max_frame_average_light_level = metadata->MaxFrameAverageLightLevel;
    if (pgen_nvapi_metadata_valid &&
        !memcmp(&converted, &pgen_nvapi_metadata, sizeof(converted))) return true;
    status = pgen_nvapi_set_source_hdr_metadata(pgen_nvapi_display_id, &converted);
    pgen_nvapi_last_status = status;
    if (status != 0) return false;
    pgen_nvapi_metadata = converted;
    pgen_nvapi_metadata_valid = true;
    return true;
}
#endif

static bool render_alignment(void);
static PGEN_UNUSED double pq_to_nits(double value);

#ifdef _WIN32
#define PGEN_CPST_STANDARD_DISPLAY_COLOR_MODE ((COLORPROFILESUBTYPE)7)
#define PGEN_CPST_EXTENDED_DISPLAY_COLOR_MODE ((COLORPROFILESUBTYPE)8)
typedef HRESULT (WINAPI *PFN_ColorProfileGetDisplayDefault)(
    WCS_PROFILE_MANAGEMENT_SCOPE, LUID, UINT32, COLORPROFILETYPE,
    COLORPROFILESUBTYPE, LPWSTR *);
typedef HRESULT (WINAPI *PFN_ColorProfileGetDisplayUserScope)(
    LUID, UINT32, WCS_PROFILE_MANAGEMENT_SCOPE *);

static void set_windows_window_icon(void)
{
    HWND window = (HWND)SDL_GetPointerProperty(SDL_GetWindowProperties(app.window),
                                                SDL_PROP_WINDOW_WIN32_HWND_POINTER, NULL);
    HINSTANCE instance = GetModuleHandleW(NULL);
    HICON large, small;
    if (!window || !instance) return;
    large = (HICON)LoadImageW(instance, MAKEINTRESOURCEW(1), IMAGE_ICON,
                              GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), LR_SHARED);
    small = (HICON)LoadImageW(instance, MAKEINTRESOURCEW(1), IMAGE_ICON,
                              GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_SHARED);
    if (large) SendMessageW(window, WM_SETICON, ICON_BIG, (LPARAM)large);
    if (small) SendMessageW(window, WM_SETICON, ICON_SMALL, (LPARAM)small);
}

static bool windows_window_hdr_enabled(SDL_Window *window);

/* 1 means selected, 0 means cancelled, and -1 requests the SDL fallback. */
static int select_windows_target_display(SDL_DisplayID *displays, int count, int *selected)
{
    TASKDIALOGCONFIG dialog;
    TASKDIALOG_BUTTON *buttons = SDL_calloc((size_t)count, sizeof(*buttons));
    wchar_t (*labels)[256] = SDL_calloc((size_t)count, sizeof(*labels));
    int chosen = 0;
    HRESULT result;
    if (!buttons || !labels) {
        SDL_free(labels);
        SDL_free(buttons);
        return -1;
    }
    for (int index = 0; index < count; index++) {
        const char *name = SDL_GetDisplayName(displays[index]);
        wchar_t display_name[192] = L"Unnamed display";
        if (name && name[0]) {
            int converted = MultiByteToWideChar(CP_UTF8, 0, name, -1, display_name, (int)SDL_arraysize(display_name));
            if (converted <= 0) lstrcpyW(display_name, L"Unnamed display");
        }
        _snwprintf(labels[index], SDL_arraysize(labels[index]) - 1,
                   L"Display %d\n%s", index + 1, display_name);
        labels[index][SDL_arraysize(labels[index]) - 1] = L'\0';
        buttons[index].nButtonID = index + 1;
        buttons[index].pszButtonText = labels[index];
    }
    ZeroMemory(&dialog, sizeof(dialog));
    dialog.cbSize = sizeof(dialog);
    dialog.hwndParent = (HWND)SDL_GetPointerProperty(SDL_GetWindowProperties(app.window),
                                                     SDL_PROP_WINDOW_WIN32_HWND_POINTER, NULL);
    dialog.hInstance = GetModuleHandleW(NULL);
    dialog.dwFlags = TDF_USE_COMMAND_LINKS | TDF_ALLOW_DIALOG_CANCELLATION |
                     TDF_POSITION_RELATIVE_TO_WINDOW | TDF_SIZE_TO_CONTENT;
    dialog.pszWindowTitle = L"PGenerator+ Patch Companion";
    dialog.pszMainInstruction = L"Select the profiling display";
    dialog.pszContent = L"Choose the monitor that will show measurement patches. You can move and resize the Companion window afterward.";
    dialog.pszMainIcon = MAKEINTRESOURCEW(1);
    dialog.cButtons = (UINT)count;
    dialog.pButtons = buttons;
    dialog.nDefaultButton = 1;
    result = TaskDialogIndirect(&dialog, &chosen, NULL, NULL);
    SDL_free(labels);
    SDL_free(buttons);
    if (FAILED(result)) return -1;
    if (chosen < 1 || chosen > count) return 0;
    *selected = chosen;
    return 1;
}

static const wchar_t *windows_profile_basename(const wchar_t *path)
{
    const wchar_t *slash = wcsrchr(path, L'\\');
    const wchar_t *forward = wcsrchr(path, L'/');
    if (forward && (!slash || forward > slash)) slash = forward;
    return slash ? slash + 1 : path;
}

static bool windows_installed_profile_path(const wchar_t *name, wchar_t *path,
                                           size_t path_count)
{
    DWORD color_dir_size;
    if (!name || !name[0] || !path || path_count < 2) return false;
    path[0] = L'\0';
    if (wcschr(name, L'\\') || wcschr(name, L'/')) {
        wcsncpy(path, name, path_count - 1);
        path[path_count - 1] = L'\0';
    } else {
        color_dir_size = (DWORD)path_count;
        if (!GetColorDirectoryW(NULL, path, &color_dir_size) ||
            wcslen(path) + 1 + wcslen(name) + 1 > path_count) {
            path[0] = L'\0';
            return false;
        }
        wcscat(path, L"\\");
        wcscat(path, name);
    }
    return GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES;
}

static bool windows_profile_loader_fallback(const wchar_t *monitor_path,
                                            bool hdr_mode,
                                            char *output, size_t output_size,
                                            wchar_t *profile_path,
                                            size_t profile_path_count)
{
    wchar_t local_app_data[MAX_PATH] = L"";
    wchar_t ini_path[MAX_PATH] = L"";
    wchar_t saved_monitor[256] = L"";
    wchar_t profile_name[MAX_PATH] = L"";
    BOOL saved_advanced;
    DWORD length;
    int converted;
    if (!monitor_path || !monitor_path[0]) return false;
    length = GetEnvironmentVariableW(L"LOCALAPPDATA", local_app_data, MAX_PATH);
    if (!length || length >= MAX_PATH) return false;
    if (swprintf(ini_path, MAX_PATH, L"%ls\\PGenerator+\\ProfileLoader.ini",
                 local_app_data) < 0) return false;
    GetPrivateProfileStringW(L"ProfileLoader", L"MonitorPath", L"", saved_monitor,
                             (DWORD)(sizeof(saved_monitor) / sizeof(saved_monitor[0])), ini_path);
    GetPrivateProfileStringW(L"ProfileLoader", L"ProfileName", L"", profile_name,
                             MAX_PATH, ini_path);
    saved_advanced = GetPrivateProfileIntW(L"ProfileLoader", L"AdvancedAssociation",
                                           0, ini_path) != 0;
    if (!saved_monitor[0] || !profile_name[0] ||
        saved_advanced != (hdr_mode ? TRUE : FALSE) ||
        _wcsicmp(saved_monitor, monitor_path) != 0 ||
        !windows_installed_profile_path(profile_name, profile_path, profile_path_count))
        return false;
    converted = WideCharToMultiByte(CP_UTF8, 0, profile_name, -1, output,
                                    (int)output_size, NULL, NULL);
    return converted > 1;
}

static bool windows_active_profile(SDL_Window *window, char *output, size_t output_size,
                                   wchar_t *profile_path, size_t profile_path_count,
                                   bool hdr_mode, wchar_t *monitor_path,
                                   size_t monitor_path_count)
{
    HWND hwnd;
    HMONITOR monitor;
    MONITORINFOEXW monitor_info;
    UINT32 path_count = 0, mode_count = 0;
    DISPLAYCONFIG_PATH_INFO *paths = NULL;
    DISPLAYCONFIG_MODE_INFO *modes = NULL;
    HMODULE mscms = NULL;
    PFN_ColorProfileGetDisplayDefault get_default = NULL;
    PFN_ColorProfileGetDisplayUserScope get_scope = NULL;
    LPWSTR profile = NULL;
    bool found = false;
    LONG result;

    if (!output || output_size < 2 || !profile_path || profile_path_count < 2) return false;
    output[0] = '\0';
    profile_path[0] = L'\0';
    if (monitor_path && monitor_path_count) monitor_path[0] = L'\0';
    hwnd = (HWND)SDL_GetPointerProperty(SDL_GetWindowProperties(window),
                                        SDL_PROP_WINDOW_WIN32_HWND_POINTER, NULL);
    monitor = hwnd ? MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST) : NULL;
    ZeroMemory(&monitor_info, sizeof(monitor_info));
    monitor_info.cbSize = sizeof(monitor_info);
    if (!monitor || !GetMonitorInfoW(monitor, (MONITORINFO *)&monitor_info)) return false;
    do {
        SDL_free(paths); SDL_free(modes); paths = NULL; modes = NULL;
        if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &path_count, &mode_count) != ERROR_SUCCESS) goto done;
        paths = SDL_calloc(path_count, sizeof(*paths));
        modes = SDL_calloc(mode_count, sizeof(*modes));
        if (!paths || !modes) goto done;
        result = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &path_count, paths,
                                    &mode_count, modes, NULL);
    } while (result == ERROR_INSUFFICIENT_BUFFER);
    if (result != ERROR_SUCCESS) goto done;
    mscms = LoadLibraryW(L"mscms.dll");
    if (!mscms) goto done;
    {
        FARPROC proc = GetProcAddress(mscms, "ColorProfileGetDisplayDefault");
        memcpy(&get_default, &proc, sizeof(get_default));
        proc = GetProcAddress(mscms, "ColorProfileGetDisplayUserScope");
        memcpy(&get_scope, &proc, sizeof(get_scope));
    }
    if (!get_default) goto done;
    for (UINT32 index = 0; index < path_count && !found; index++) {
        DISPLAYCONFIG_SOURCE_DEVICE_NAME source;
        DISPLAYCONFIG_TARGET_DEVICE_NAME target;
        WCS_PROFILE_MANAGEMENT_SCOPE scope = WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER;
        WCS_PROFILE_MANAGEMENT_SCOPE alternate;
        COLORPROFILESUBTYPE subtype = hdr_mode
                                    ? PGEN_CPST_EXTENDED_DISPLAY_COLOR_MODE
                                    : PGEN_CPST_STANDARD_DISPLAY_COLOR_MODE;
        HRESULT hr;
        if (!(paths[index].flags & DISPLAYCONFIG_PATH_ACTIVE)) continue;
        ZeroMemory(&source, sizeof(source));
        source.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
        source.header.size = sizeof(source);
        source.header.adapterId = paths[index].sourceInfo.adapterId;
        source.header.id = paths[index].sourceInfo.id;
        if (DisplayConfigGetDeviceInfo(&source.header) != ERROR_SUCCESS ||
            _wcsicmp(source.viewGdiDeviceName, monitor_info.szDevice) != 0) continue;
        ZeroMemory(&target, sizeof(target));
        target.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
        target.header.size = sizeof(target);
        target.header.adapterId = paths[index].targetInfo.adapterId;
        target.header.id = paths[index].targetInfo.id;
        DisplayConfigGetDeviceInfo(&target.header);
        if (monitor_path && monitor_path_count && target.monitorDevicePath[0]) {
            wcsncpy(monitor_path, target.monitorDevicePath, monitor_path_count - 1);
            monitor_path[monitor_path_count - 1] = L'\0';
        }
        if (get_scope && FAILED(get_scope(paths[index].sourceInfo.adapterId,
                                          paths[index].sourceInfo.id, &scope)))
            scope = WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER;
        hr = get_default(scope, paths[index].sourceInfo.adapterId,
                         paths[index].sourceInfo.id, CPT_ICC, subtype, &profile);
        if (FAILED(hr)) {
            alternate = scope == WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER
                      ? WCS_PROFILE_MANAGEMENT_SCOPE_SYSTEM_WIDE
                      : WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER;
            hr = get_default(alternate, paths[index].sourceInfo.adapterId,
                             paths[index].sourceInfo.id, CPT_ICC, subtype, &profile);
        }
        if (SUCCEEDED(hr) && profile) {
            const wchar_t *name = windows_profile_basename(profile);
            int converted = WideCharToMultiByte(CP_UTF8, 0, name, -1, output,
                                                (int)output_size, NULL, NULL);
            if (converted > 1) {
                found = windows_installed_profile_path(profile, profile_path,
                                                       profile_path_count);
            }
        }
        if (!found && !hdr_mode) {
            HDC dc = CreateDCW(L"DISPLAY", source.viewGdiDeviceName, NULL, NULL);
            wchar_t dc_profile[MAX_PATH] = L"";
            DWORD dc_profile_count = MAX_PATH;
            if (dc && GetICMProfileW(dc, &dc_profile_count, dc_profile) && dc_profile[0] &&
                windows_installed_profile_path(dc_profile, profile_path, profile_path_count)) {
                const wchar_t *name = windows_profile_basename(dc_profile);
                found = WideCharToMultiByte(CP_UTF8, 0, name, -1, output,
                                            (int)output_size, NULL, NULL) > 1;
            }
            if (dc) DeleteDC(dc);
        }
        if (!found && target.monitorDevicePath[0])
            found = windows_profile_loader_fallback(target.monitorDevicePath, hdr_mode,
                                                    output, output_size,
                                                    profile_path, profile_path_count);
    }
done:
    if (profile) LocalFree(profile);
    if (mscms) FreeLibrary(mscms);
    SDL_free(paths); SDL_free(modes);
    if (!found) { output[0] = '\0'; profile_path[0] = L'\0'; }
    return found;
}
#endif

#ifndef _WIN32
/* The non-Windows counterpart to set_windows_window_icon(). Both use the same
 * favicon: Windows loads it as icon resource 1 out of the executable's resource
 * section, and pgen-icc-companion-icon.h carries the largest frame of that same
 * file as raw RGBA so no icon has to be shipped or found at runtime. */
static void set_embedded_window_icon(void)
{
    SDL_Surface *icon = SDL_CreateSurfaceFrom(PGEN_COMPANION_ICON_WIDTH,
                                              PGEN_COMPANION_ICON_HEIGHT,
                                              SDL_PIXELFORMAT_RGBA32,
                                              (void *)pgen_companion_icon_rgba,
                                              PGEN_COMPANION_ICON_WIDTH * 4);
    if (!icon) return;
    /* SDL copies the pixels it needs before this returns. */
    SDL_SetWindowIcon(app.window, icon);
    SDL_DestroySurface(icon);
}
#endif

static void profile_name_hex(const char *profile, char *hex, size_t hex_size)
{
    static const char digits[] = "0123456789abcdef";
    size_t used = 0;
    if (!hex || hex_size < 1) return;
    if (!profile) profile = "";
    while (*profile && used + 2 < hex_size) {
        unsigned char value = (unsigned char)*profile++;
        hex[used++] = digits[value >> 4];
        hex[used++] = digits[value & 15];
    }
    hex[used] = '\0';
}

static bool select_target_display(void)
{
    SDL_DisplayID *displays;
    SDL_MessageBoxButtonData *buttons = NULL;
    char (*labels)[192] = NULL;
    SDL_MessageBoxData dialog;
    SDL_Rect bounds;
    int count = 0, selected = 1;
    bool ok = true;

    displays = SDL_GetDisplays(&count);
    if (!displays || count < 1) return false;
    if (count == 1) {
        const char *name = SDL_GetDisplayName(displays[0]);
        SDL_strlcpy(app.selected_display, name ? name : "Unnamed display",
                    sizeof(app.selected_display));
        app.selected_display_id = displays[0];
        SDL_free(displays);
        return true;
    }
    /* A saved DISPLAY= value skips the picker only when it is UNAMBIGUOUS.
     *
     * Matching the first substring hit used to pick the wrong panel and left
     * the other monitor unreachable without hand-editing the conf, so the
     * picker became mandatory - but that stopped the Companion ever starting
     * unattended, which is how it is normally driven. Counting the matches
     * gets both: one match is a decision the user already made, more than one
     * is genuinely ambiguous and still worth asking about. An exact,
     * case-insensitive name always wins over a substring. */
    if (app.config.display[0]) {
        int matches = 0, exact = 0, first_match = 0, first_exact = 0;
        for (int index = 0; index < count; index++) {
            const char *name = SDL_GetDisplayName(displays[index]);
            if (!name) continue;
            if (SDL_strcasecmp(name, app.config.display) == 0) {
                if (!exact++) first_exact = index + 1;
            } else if (SDL_strcasestr(name, app.config.display)) {
                if (!matches++) first_match = index + 1;
            }
        }
        if (exact == 1) { selected = first_exact; goto display_selected; }
        if (!exact && matches == 1) { selected = first_match; goto display_selected; }
        /* Ambiguous or unmatched: fall through to the picker, pre-selecting a
         * candidate if there was one so the default button is the likely one. */
        if (exact) selected = first_exact;
        else if (matches) selected = first_match;
    }
#ifdef _WIN32
    {
     int modern_result = select_windows_target_display(displays, count, &selected);
     if (modern_result == 0) {
        ok = false;
        goto done;
     }
     if (modern_result > 0) goto display_selected;
    }
#endif
    buttons = SDL_calloc((size_t)count, sizeof(*buttons));
    labels = SDL_calloc((size_t)count, sizeof(*labels));
    if (!buttons || !labels) {
        ok = false;
        goto done;
    }
    for (int index = 0; index < count; index++) {
        const char *name = SDL_GetDisplayName(displays[index]);
        SDL_snprintf(labels[index], sizeof(labels[index]), "Display %d: %s",
                     index + 1, (name && name[0]) ? name : "Unnamed display");
        buttons[index].buttonID = index + 1;
        buttons[index].text = labels[index];
        if (index + 1 == selected) buttons[index].flags = SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT;
    }
    SDL_zero(dialog);
    dialog.flags = SDL_MESSAGEBOX_INFORMATION;
    dialog.window = app.window;
    dialog.title = "Select profiling display";
    dialog.message = "Choose the display that will show measurement patches. You can move and resize the companion window after selecting it.";
    dialog.numbuttons = count;
    dialog.buttons = buttons;
    if (!SDL_ShowMessageBox(&dialog, &selected)) {
        ok = false;
        goto done;
    }
display_selected:
    if (selected < 1 || selected > count) selected = 1;
    {
        SDL_DisplayID target = displays[selected - 1];
        const char *name = SDL_GetDisplayName(target);
        int width = 1280, height = 720;
        SDL_strlcpy(app.selected_display, name ? name : "Unnamed display",
                    sizeof(app.selected_display));
        app.selected_display_id = target;
        SDL_GetWindowSize(app.window, &width, &height);
#if !defined(_WIN32) && !defined(__APPLE__)
        /* Wayland ignores most SetWindowPosition calls. The reliable way to
         * land on a chosen output is to recreate the window with
         * SDL_WINDOWPOS_CENTERED_DISPLAY and then enter borderless fullscreen
         * for that display. Otherwise the picker can say "Innoview" while the
         * surface stays on the MSI primary and HDR/series fail. */
        {
            SDL_PropertiesID props = SDL_CreateProperties();
            SDL_Window *moved = NULL;
            if (props) {
                SDL_SetStringProperty(props, SDL_PROP_WINDOW_CREATE_TITLE_STRING,
                                      APP_TITLE);
                SDL_SetNumberProperty(props, SDL_PROP_WINDOW_CREATE_X_NUMBER,
                                      SDL_WINDOWPOS_CENTERED_DISPLAY(target));
                SDL_SetNumberProperty(props, SDL_PROP_WINDOW_CREATE_Y_NUMBER,
                                      SDL_WINDOWPOS_CENTERED_DISPLAY(target));
                SDL_SetNumberProperty(props, SDL_PROP_WINDOW_CREATE_WIDTH_NUMBER, width);
                SDL_SetNumberProperty(props, SDL_PROP_WINDOW_CREATE_HEIGHT_NUMBER, height);
                SDL_SetNumberProperty(props, SDL_PROP_WINDOW_CREATE_FLAGS_NUMBER,
                                      SDL_WINDOW_HIGH_PIXEL_DENSITY | SDL_WINDOW_RESIZABLE);
                moved = SDL_CreateWindowWithProperties(props);
                SDL_DestroyProperties(props);
            }
            if (moved) {
                SDL_DestroyWindow(app.window);
                app.window = moved;
                set_embedded_window_icon();
            } else if (SDL_GetDisplayUsableBounds(target, &bounds)) {
                int x = bounds.x + (bounds.w - width) / 2;
                int y = bounds.y + (bounds.h - height) / 2;
                (void)SDL_SetWindowPosition(app.window, x, y);
            }
            /* Borderless desktop fullscreen on the target output is the most
             * reliable Wayland multi-monitor placement + HDR enable path. */
            (void)SDL_SetWindowFullscreenMode(app.window, NULL);
            if (SDL_SetWindowFullscreen(app.window, true)) {
                app.fullscreen = true;
                SDL_SyncWindow(app.window);
                SDL_PumpEvents();
            }
        }
#else
        if (SDL_GetDisplayUsableBounds(target, &bounds)) {
            int x = bounds.x + (bounds.w - width) / 2;
            int y = bounds.y + (bounds.h - height) / 2;
            if (SDL_SetWindowPosition(app.window, x, y)) SDL_SyncWindow(app.window);
        }
#endif
        SDL_ShowWindow(app.window);
        SDL_RaiseWindow(app.window);
    }
done:
    SDL_free(labels);
    SDL_free(buttons);
    SDL_free(displays);
    return ok;
}

static void trim(char *text)
{
    char *start = text;
    char *end;
    while (*start && isspace((unsigned char)*start)) start++;
    if (start != text) memmove(text, start, strlen(start) + 1);
    end = text + strlen(text);
    while (end > text && isspace((unsigned char)end[-1])) end--;
    *end = '\0';
}

/* Exactly 64 lowercase hex characters, matching the token PGenerator+ mints.
 * A conf value carrying the un-personalised template text, or a --token
 * typo, fails this and is treated the same as no token at all. */
static bool token_is_valid(const char *token)
{
    size_t length = strlen(token);
    if (length != 64) return false;
    for (size_t index = 0; index < length; index++) {
        char c = token[index];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
    }
    return true;
}

/* Reads one conf file and fills in whichever of SERVER/TOKEN/DISPLAY it
 * defines. Fields the file does not mention are left untouched, so a caller
 * can read the beside-the-binary copy and the pref-path copy into separate
 * buffers and merge them itself. Returns false only when the file could not be
 * opened. */
static bool load_conf_fields(const char *path, char *server, size_t server_size,
                             char *token, size_t token_size,
                             char *display, size_t display_size)
{
    FILE *file = fopen(path, "rb");
    char line[512];
    if (!file) return false;
    while (fgets(line, sizeof(line), file)) {
        char *equals;
        trim(line);
        if (!line[0] || line[0] == '#') continue;
        equals = strchr(line, '=');
        if (!equals) continue;
        *equals++ = '\0';
        trim(line);
        trim(equals);
        if (!strcmp(line, "SERVER")) SDL_strlcpy(server, equals, server_size);
        else if (!strcmp(line, "TOKEN")) SDL_strlcpy(token, equals, token_size);
        else if (!strcmp(line, "DISPLAY")) SDL_strlcpy(display, equals, display_size);
    }
    fclose(file);
    return true;
}

/* Reads both conf names out of one directory, retired name first and current
 * name over the top, so a field the current file actually defines wins while
 * anything it leaves out still comes through from before the rename. Each
 * file's slot markers are cleared before it is overlaid: an installer drops an
 * unpersonalised template under the current name, and stripping only after the
 * merge would let that empty template blank a real token underneath it. */
static void load_conf_dir(const char *dir, char *server, size_t server_size,
                          char *token, size_t token_size,
                          char *display, size_t display_size)
{
    static const char *const names[] = { PGEN_CONF_RETIRED_NAME, PGEN_CONF_NAME };
    for (size_t index = 0; index < SDL_arraysize(names); index++) {
        char path[1024];
        char file_server[256] = "", file_token[96] = "", file_display[192] = "";
        SDL_snprintf(path, sizeof(path), "%s%s", dir, names[index]);
        if (!load_conf_fields(path, file_server, sizeof(file_server),
                              file_token, sizeof(file_token),
                              file_display, sizeof(file_display))) continue;
        if (strstr(file_server, PGEN_SERVER_SLOT_MARKER)) file_server[0] = '\0';
        if (strstr(file_token, PGEN_TOKEN_SLOT_MARKER)) file_token[0] = '\0';
        if (file_server[0]) SDL_strlcpy(server, file_server, server_size);
        if (file_token[0]) SDL_strlcpy(token, file_token, token_size);
        if (file_display[0]) SDL_strlcpy(display, file_display, display_size);
    }
}

static bool load_config(CompanionConfig *config, int argc, char *argv[])
{
    char conf_server[256] = "", conf_token[96] = "", conf_display[192] = "";
    char pref_server[256] = "", pref_token[96] = "", pref_display[192] = "";
    const char *arg_server = NULL, *arg_token = NULL, *arg_display = NULL;
    const char *server_value, *token_value, *display_value;
    const char *base, *pref;

    memset(config, 0, sizeof(*config));
    config->port = 80;

    for (int index = 1; index < argc; index++) {
        if (!strncmp(argv[index], "--server=", 9)) arg_server = argv[index] + 9;
        else if (!strncmp(argv[index], "--token=", 8)) arg_token = argv[index] + 8;
        else if (!strncmp(argv[index], "--display=", 10)) arg_display = argv[index] + 10;
    }

    base = SDL_GetBasePath();
    load_conf_dir(base ? base : "", conf_server, sizeof(conf_server),
                  conf_token, sizeof(conf_token), conf_display, sizeof(conf_display));
    /* Learned at run time via companion_pair() and save_config() when the
     * beside-the-binary location is not writable, e.g. under Program Files. */
    pref = SDL_GetPrefPath("PGeneratorPlus", "PatchCompanion");
    if (pref) {
        load_conf_dir(pref, pref_server, sizeof(pref_server),
                      pref_token, sizeof(pref_token), pref_display, sizeof(pref_display));
    }

    server_value = conf_server[0] ? conf_server : (pref_server[0] ? pref_server : NULL);
    token_value = conf_token[0] ? conf_token : (pref_token[0] ? pref_token : NULL);
    display_value = conf_display[0] ? conf_display : pref_display;

    if (arg_display && arg_display[0]) SDL_strlcpy(config->display, arg_display, sizeof(config->display));
    else SDL_strlcpy(config->display, display_value, sizeof(config->display));

    if (arg_token && token_is_valid(arg_token)) SDL_strlcpy(config->token, arg_token, sizeof(config->token));
    else if (token_value && token_is_valid(token_value)) SDL_strlcpy(config->token, token_value, sizeof(config->token));
    /* A missing or invalid token is not fatal here: SDL_AppInit sends this
     * Companion through companion_pair() to obtain one when it is empty. */

    if (arg_server && arg_server[0]) {
        SDL_strlcpy(config->server, arg_server, sizeof(config->server));
    } else if (server_value) {
        SDL_strlcpy(config->server, server_value, sizeof(config->server));
    } else {
        /* Nothing on the command line or in either conf file: see whether
         * PGenerator+'s own mDNS responder answers for its fixed name before
         * giving up entirely. */
        struct addrinfo hints, *addresses = NULL;
        memset(&hints, 0, sizeof(hints));
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;
        if (getaddrinfo(PGEN_DISCOVERY_HOST, "80", &hints, &addresses) == 0) {
            freeaddrinfo(addresses);
            /* Keep the name, not the address it resolved to today, so a
             * PGenerator+ that later gets a new DHCP lease still resolves. */
            SDL_strlcpy(config->server, "http://" PGEN_DISCOVERY_HOST, sizeof(config->server));
        }
    }
    if (!config->server[0]) return false;

    {
        const char *source = config->server;
        const char *slash;
        char authority[256];
        char *colon;
        if (!strncmp(source, "http://", 7)) source += 7;
        else return false;
        slash = strchr(source, '/');
        size_t authority_length = slash ? (size_t)(slash - source) : strlen(source);
        SDL_snprintf(authority, sizeof(authority), "%.*s", (int)authority_length, source);
        colon = strrchr(authority, ':');
        if (colon && strchr(authority, ':') == colon) {
            *colon++ = '\0';
            config->port = atoi(colon);
        }
        SDL_strlcpy(config->host, authority, sizeof(config->host));
    }
#ifdef _WIN32
    {
        DWORD size = (DWORD)sizeof(config->client);
        if (!GetComputerNameA(config->client, &size)) SDL_strlcpy(config->client, "Windows-PC", sizeof(config->client));
    }
#elif defined(__APPLE__)
    if (gethostname(config->client, sizeof(config->client) - 1) != 0) SDL_strlcpy(config->client, "Mac", sizeof(config->client));
#else
    if (gethostname(config->client, sizeof(config->client) - 1) != 0) SDL_strlcpy(config->client, "Linux-PC", sizeof(config->client));
#endif
    for (char *p = config->client; *p; p++) if (!isalnum((unsigned char)*p) && *p != '-' && *p != '_') *p = '_';
    return config->host[0] && config->port > 0 && config->port < 65536;
}

/* Remembers a pairing this Companion just obtained so the next launch does
 * not have to repeat it. Tried beside the executable first, matching where
 * PGenerator+ places a personalised download; falls back to the pref path
 * when that location cannot be written, which is the common case once a
 * Windows installer has placed the program under Program Files. Not being
 * able to write anywhere is not fatal: the caller keeps the token in memory
 * either way, so this session still works, and only the next launch is
 * affected. */
static bool save_config(const CompanionConfig *config)
{
    char path[1024];
    const char *base = SDL_GetBasePath();
    const char *pref;
    FILE *file = NULL;

    if (base) {
        SDL_snprintf(path, sizeof(path), "%s" PGEN_CONF_NAME, base);
        file = fopen(path, "wb");
    }
    if (!file) {
        pref = SDL_GetPrefPath("PGeneratorPlus", "PatchCompanion");
        if (pref) {
            SDL_snprintf(path, sizeof(path), "%s" PGEN_CONF_NAME, pref);
            file = fopen(path, "wb");
        }
    }
    if (!file) return false;
    fprintf(file, "# Paired with PGenerator+\n");
    fprintf(file, "SERVER=%s\n", config->server);
    fprintf(file, "TOKEN=%s\n", config->token);
    if (config->display[0]) fprintf(file, "DISPLAY=%s\n", config->display);
    fclose(file);
    return true;
}

static bool connect_with_timeout(socket_handle_t sock, const struct sockaddr *address,
                                 int address_length, int timeout_ms)
{
    int result, socket_error = 0;
#ifdef _WIN32
    u_long nonblocking = 1;
    int error_length = (int)sizeof(socket_error);
    if (ioctlsocket(sock, FIONBIO, &nonblocking) != 0) return false;
    result = connect(sock, address, address_length);
    if (result != 0) {
        int error = WSAGetLastError();
        if (error != WSAEWOULDBLOCK && error != WSAEINPROGRESS) return false;
    }
#else
    int flags = fcntl(sock, F_GETFL, 0);
    socklen_t error_length = (socklen_t)sizeof(socket_error);
    if (flags < 0 || fcntl(sock, F_SETFL, flags | O_NONBLOCK) != 0) return false;
    result = connect(sock, address, (socklen_t)address_length);
    if (result != 0 && errno != EINPROGRESS) return false;
#endif
    if (result != 0) {
        fd_set write_set;
        struct timeval timeout;
        FD_ZERO(&write_set);
        FD_SET(sock, &write_set);
        timeout.tv_sec = timeout_ms / 1000;
        timeout.tv_usec = (timeout_ms % 1000) * 1000;
#ifdef _WIN32
        result = select(0, NULL, &write_set, NULL, &timeout);
#else
        result = select(sock + 1, NULL, &write_set, NULL, &timeout);
#endif
        if (result <= 0 || !FD_ISSET(sock, &write_set) ||
            getsockopt(sock, SOL_SOCKET, SO_ERROR, (char *)&socket_error, &error_length) != 0 ||
            socket_error != 0) return false;
    }
#ifdef _WIN32
    nonblocking = 0;
    if (ioctlsocket(sock, FIONBIO, &nonblocking) != 0) return false;
#else
    if (fcntl(sock, F_SETFL, flags) != 0) return false;
#endif
    return true;
}

static socket_handle_t open_server_socket(CompanionConfig *config)
{
    struct addrinfo hints, *addresses = NULL, *address;
    socket_handle_t sock = INVALID_SOCKET_HANDLE;
    char port[16];

    if (config->address_resolved) {
        sock = socket(config->resolved_family, config->resolved_socktype, config->resolved_protocol);
        if (sock == INVALID_SOCKET_HANDLE) return INVALID_SOCKET_HANDLE;
        if (connect_with_timeout(sock, (const struct sockaddr *)&config->resolved_address,
                                 config->resolved_address_length, 2500)) return sock;
        close_socket(sock);
        return INVALID_SOCKET_HANDLE;
    }

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    SDL_snprintf(port, sizeof(port), "%d", config->port);
    if (getaddrinfo(config->host, port, &hints, &addresses) != 0) return INVALID_SOCKET_HANDLE;
    for (address = addresses; address; address = address->ai_next) {
        if ((size_t)address->ai_addrlen > sizeof(config->resolved_address)) continue;
        sock = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (sock == INVALID_SOCKET_HANDLE) continue;
        if (connect_with_timeout(sock, address->ai_addr, (int)address->ai_addrlen, 2500)) {
            memcpy(&config->resolved_address, address->ai_addr, (size_t)address->ai_addrlen);
            config->resolved_address_length = (int)address->ai_addrlen;
            config->resolved_family = address->ai_family;
            config->resolved_socktype = address->ai_socktype;
            config->resolved_protocol = address->ai_protocol;
            config->address_resolved = true;
            break;
        }
        close_socket(sock);
        sock = INVALID_SOCKET_HANDLE;
    }
    freeaddrinfo(addresses);
    return sock;
}

static int http_request(CompanionConfig *config, const char *method, const char *path,
                        const char *body, char *response, size_t response_size)
{
    char request[4096];
    char raw[RESPONSE_CAPACITY];
    size_t used = 0;
    socket_handle_t sock = INVALID_SOCKET_HANDLE;
    int status = 0;
    sock = open_server_socket(config);
    if (sock == INVALID_SOCKET_HANDLE) return 0;
#ifdef _WIN32
    {
        DWORD timeout = 2500;
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, (const char *)&timeout, sizeof(timeout));
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, (const char *)&timeout, sizeof(timeout));
    }
#else
    {
        struct timeval timeout = {2, 500000};
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    }
#endif
    if (!body) body = "";
    SDL_snprintf(request, sizeof(request),
                 "%s %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: %u\r\n\r\n%s",
                 method, path, config->host, (unsigned)strlen(body), body);
    {
        size_t sent = 0, length = strlen(request);
        while (sent < length) {
            int count = (int)send(sock, request + sent, (int)(length - sent), 0);
            if (count <= 0) { close_socket(sock); return 0; }
            sent += (size_t)count;
        }
    }
    while (used + 1 < sizeof(raw)) {
        int count = (int)recv(sock, raw + used, (int)(sizeof(raw) - used - 1), 0);
        if (count <= 0) break;
        used += (size_t)count;
    }
    close_socket(sock);
    raw[used] = '\0';
    if (sscanf(raw, "HTTP/%*s %d", &status) != 1) return 0;
    {
        char *payload = strstr(raw, "\r\n\r\n");
        if (!payload) payload = strstr(raw, "\n\n");
        payload = payload ? payload + (payload[0] == '\r' ? 4 : 2) : raw;
        SDL_strlcpy(response, payload, response_size);
    }
    return status;
}

/* Binary-safe request/response. http_request above is built for JSON: it
 * measures the body with strlen and copies the reply with strlcpy, and an ICC
 * profile is full of NUL bytes at both ends of that exchange. */
static int http_binary(CompanionConfig *config, const char *method, const char *path,
                       const char *content_type, const unsigned char *body, size_t body_length,
                       unsigned char **reply, size_t *reply_length)
{
    char header[2048];
    socket_handle_t sock;
    int status = 0;
    size_t capacity = 1 << 20, used = 0;
    unsigned char *raw = NULL;
    if (reply) *reply = NULL;
    if (reply_length) *reply_length = 0;
    sock = open_server_socket(config);
    if (sock == INVALID_SOCKET_HANDLE) return 0;
#ifdef _WIN32
    { DWORD t = 120000; setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, (const char *)&t, sizeof(t));
                        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, (const char *)&t, sizeof(t)); }
#else
    { struct timeval t = {120, 0}; setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &t, sizeof(t));
                                   setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &t, sizeof(t)); }
#endif
    SDL_snprintf(header, sizeof(header),
                 "%s %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\nContent-Type: %s\r\nContent-Length: %u\r\n\r\n",
                 method, path, config->host, content_type, (unsigned)body_length);
    {
        size_t sent = 0, length = strlen(header);
        while (sent < length) {
            int count = (int)send(sock, header + sent, (int)(length - sent), 0);
            if (count <= 0) { close_socket(sock); return 0; }
            sent += (size_t)count;
        }
    }
    while (body_length > 0) {
        int count = (int)send(sock, (const char *)body, (int)(body_length > 32768 ? 32768 : body_length), 0);
        if (count <= 0) { close_socket(sock); return 0; }
        body += count; body_length -= (size_t)count;
    }
    raw = (unsigned char *)SDL_malloc(capacity);
    if (!raw) { close_socket(sock); return 0; }
    for (;;) {
        int count;
        if (used + 16384 > capacity) {
            unsigned char *grown;
            if (capacity >= (size_t)96 * 1024 * 1024) break;
            capacity *= 2;
            grown = (unsigned char *)SDL_realloc(raw, capacity);
            if (!grown) break;
            raw = grown;
        }
        count = (int)recv(sock, (char *)raw + used, 16384, 0);
        if (count <= 0) break;
        used += (size_t)count;
    }
    close_socket(sock);
    if (used < 12 || sscanf((const char *)raw, "HTTP/%*s %d", &status) != 1) { SDL_free(raw); return 0; }
    {
        size_t index;
        size_t start = used;
        for (index = 0; index + 3 < used; index++) {
            if (raw[index] == '\r' && raw[index + 1] == '\n' && raw[index + 2] == '\r' && raw[index + 3] == '\n') {
                start = index + 4; break;
            }
        }
        if (start >= used) { SDL_free(raw); return status; }
        if (reply && reply_length) {
            size_t length = used - start;
            unsigned char *payload = (unsigned char *)SDL_malloc(length + 1);
            if (payload) {
                memcpy(payload, raw + start, length);
                payload[length] = 0;
                *reply = payload;
                *reply_length = length;
            }
        }
    }
    SDL_free(raw);
    return status;
}

/* Absolute path to a tool shipped beside this executable. */
static bool companion_tool_path(const char *name, char *out, size_t out_size)
{
    const char *base = SDL_GetBasePath();
    if (!base || !name) return false;
#ifdef _WIN32
    SDL_snprintf(out, out_size, "%s%s.exe", base, name);
#else
    SDL_snprintf(out, out_size, "%s%s", base, name);
#endif
    return true;
}

#ifdef _WIN32
/* Explicit none/cLUT/matrix output must not run underneath Windows' per-user
 * MHC2 calibration. The Profile Loader switches only the selected monitor's
 * WCS scope and preserves every saved association. B2A0 remains loaded from
 * the cached selected profile for cLUT/matrix evaluation; none submits the
 * source directly to the same isolated output. */
static bool windows_set_correction_isolation_internal(bool isolate, bool force)
{
    char loader[1200], command[5000], monitor_utf8[1024] = "";
    char profile_utf8[32768] = "", result_path[1500];
    STARTUPINFOA startup;
    PROCESS_INFORMATION process;
    FILE *result;
    bool accepted = false;
    const char *directory;
    if (!force && app.windows_correction_isolated == isolate) return true;
    if (!app.windows_monitor_path[0] ||
        (isolate && !app.correction_profile_path[0]) ||
        !companion_tool_path("PGenProfileLoader", loader, sizeof(loader)))
        return false;
    if (!WideCharToMultiByte(CP_UTF8, 0, app.windows_monitor_path, -1,
                             monitor_utf8, sizeof(monitor_utf8), NULL, NULL) ||
        !WideCharToMultiByte(CP_UTF8, 0, app.correction_profile_path, -1,
                             profile_utf8, sizeof(profile_utf8), NULL, NULL))
        return false;
    directory = SDL_GetPrefPath("PGeneratorPlus", "profiles");
    if (!directory) return false;
    SDL_snprintf(result_path, sizeof(result_path), "%scorrection-stage.result",
                 directory);
    remove(result_path);
    SDL_snprintf(command, sizeof(command),
                 "\"%s\" %s --profile \"%s\" --monitor \"%s\" --owner-pid %lu --result \"%s\"",
                 loader,
                 isolate ? "--isolate-for-correction"
                         : "--restore-after-correction",
                 profile_utf8, monitor_utf8,
                 (unsigned long)GetCurrentProcessId(), result_path);
    ZeroMemory(&startup, sizeof(startup));
    startup.cb = sizeof(startup);
    ZeroMemory(&process, sizeof(process));
    if (!CreateProcessA(NULL, command, NULL, NULL, FALSE, 0, NULL, NULL,
                        &startup, &process))
        return false;
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    for (int attempt = 0; attempt < 480; attempt++) {
        result = fopen(result_path, "rb");
        if (result) {
            char text[16] = "";
            fread(text, 1, sizeof(text) - 1, result);
            fclose(result);
            accepted = !strncmp(text, "ok", 2);
            break;
        }
        SDL_Delay(250);
    }
    remove(result_path);
    if (!accepted) return false;
    app.windows_correction_isolated = isolate;
    SDL_SetAtomicInt(&app.presentation_recovery_pending, 1);
    return true;
}

static bool windows_set_correction_isolation(bool isolate)
{
    return windows_set_correction_isolation_internal(isolate, false);
}

static bool windows_restore_correction_state(void)
{
    return windows_set_correction_isolation_internal(false, true);
}
#endif

/* Which build this is; only these three are packaged. Reported so the server
 * can describe what is genuinely unavailable instead of showing an empty value
 * as a failure - installing a finished profile through the Profile Loader, for
 * example, exists on Windows and Linux but not on macOS. */
static const char *companion_platform(void)
{
#ifdef _WIN32
    return "windows";
#elif defined(__APPLE__)
    return "macos";
#else
    return "linux";
#endif
}

/* ArgyllCMS version of the bundled colprof, empty when it is absent or will
 * not run. Reported to the server so the builder can refuse to offload to a
 * version other than its own. */
static const char *companion_argyll_version(void)
{
    static char cached[32];
    static bool probed = false;
    char path[1024];
    char command[1200];
    FILE *pipe;
    if (probed) return cached;
    probed = true;
    cached[0] = '\0';
    if (!companion_tool_path("colprof", path, sizeof(path))) return cached;
    {   /* Presence check without platform access(): the tool either opens or it does not. */
        FILE *probe = fopen(path, "rb");
        if (!probe) return cached;
        fclose(probe);
    }
#ifdef _WIN32
    SDL_snprintf(command, sizeof(command), "\"\"%s\"\" 2>&1", path);
    pipe = _popen(command, "r");
#else
    SDL_snprintf(command, sizeof(command), "\"%s\" 2>&1", path);
    pipe = popen(command, "r");
#endif
    if (!pipe) return cached;
    {
        char line[512];
        while (fgets(line, sizeof(line), pipe)) {
            const char *found = strstr(line, "Version ");
            if (found) {
                unsigned index = 0;
                found += 8;
                while (index + 1 < sizeof(cached) && ((*found >= '0' && *found <= '9') || *found == '.'))
                    cached[index++] = *found++;
                cached[index] = '\0';
                break;
            }
        }
    }
#ifdef _WIN32
    _pclose(pipe);
#else
    pclose(pipe);
#endif
    return cached;
}

/* targen jobs are advertised separately from colprof so a new generator never
 * sends chart work to an older Companion that only understands profile fits.
 * Require the same Argyll version from both bundled commands. */
static bool companion_targen_available(void)
{
    static int cached = -1;
    char path[1024], command[1200], version[32] = "";
    FILE *pipe;
    if (cached >= 0) return cached != 0;
    cached = 0;
    if (!companion_tool_path("targen", path, sizeof(path))) return false;
    {
        FILE *probe = fopen(path, "rb");
        if (!probe) return false;
        fclose(probe);
    }
#ifdef _WIN32
    SDL_snprintf(command, sizeof(command), "\"\"%s\"\" 2>&1", path);
    pipe = _popen(command, "r");
#else
    SDL_snprintf(command, sizeof(command), "\"%s\" 2>&1", path);
    pipe = popen(command, "r");
#endif
    if (!pipe) return false;
    {
        char line[512];
        while (fgets(line, sizeof(line), pipe)) {
            const char *found = strstr(line, "Version ");
            if (found) {
                unsigned index = 0;
                found += 8;
                while (index + 1 < sizeof(version) &&
                       ((*found >= '0' && *found <= '9') || *found == '.'))
                    version[index++] = *found++;
                version[index] = '\0';
                break;
            }
        }
    }
#ifdef _WIN32
    _pclose(pipe);
#else
    pclose(pipe);
#endif
    cached = version[0] && !strcmp(version, companion_argyll_version());
    return cached != 0;
}

static PGEN_UNUSED uint16_t read_be16(const unsigned char *value)
{
    return (uint16_t)(((uint16_t)value[0] << 8) | value[1]);
}

static uint32_t read_be32(const unsigned char *value)
{
    return ((uint32_t)value[0] << 24) | ((uint32_t)value[1] << 16) |
           ((uint32_t)value[2] << 8) | value[3];
}

static PGEN_UNUSED double read_s15(const unsigned char *value)
{
    int32_t raw = (int32_t)read_be32(value);
    return raw / 65536.0;
}

/* ICC parsing and the PCS->device transform. Platform-neutral maths on the
 * profile bytes: only LOCATING the profile differs between Windows and
 * KWin, so this stays one implementation rather than being duplicated. */
typedef struct { const unsigned char *data; size_t size; } IccTag;

static IccTag icc_tag(const unsigned char *profile, size_t size, const char signature[4])
{
    IccTag empty = {NULL, 0};
    if (!profile || size < 132) return empty;
    uint32_t count = read_be32(profile + 128);
    if (count > 256 || 132u + (size_t)count * 12u > size) return empty;
    for (uint32_t index = 0; index < count; index++) {
        const unsigned char *entry = profile + 132 + (size_t)index * 12;
        uint32_t offset = read_be32(entry + 4), length = read_be32(entry + 8);
        if (!memcmp(entry, signature, 4) && offset >= 128 && length >= 4 && (size_t)offset + length <= size) {
            IccTag tag = {profile + offset, length};
            return tag;
        }
    }
    return empty;
}

static double icc_table_sample(const unsigned char *table, uint32_t count, double value)
{
    double position = fmax(0.0, fmin(1.0, value)) * (count - 1);
    uint32_t lower = (uint32_t)position;
    if (lower >= count - 1) lower = count - 2;
    double fraction = position - lower;
    return (read_be16(table + lower * 2) * (1.0 - fraction) +
            read_be16(table + (lower + 1) * 2) * fraction) / 65535.0;
}

static bool icc_inverse_curve(IccTag tag, double value, double *result)
{
    if (!tag.data || tag.size < 12 || memcmp(tag.data, "curv", 4)) return false;
    uint32_t count = read_be32(tag.data + 8);
    value = fmax(0.0, fmin(1.0, value));
    if (count == 0) { *result = value; return true; }
    if (count == 1) {
        if (tag.size < 14) return false;
        double gamma = read_be16(tag.data + 12) / 256.0;
        *result = gamma > 0.0 ? pow(value, 1.0 / gamma) : value;
        return true;
    }
    if (count < 2 || 12u + (size_t)count * 2u > tag.size) return false;
    uint32_t low = 0, high = count - 1;
    while (high - low > 1) {
        uint32_t middle = (low + high) / 2;
        if (read_be16(tag.data + 12 + middle * 2) / 65535.0 < value) low = middle;
        else high = middle;
    }
    double y0 = read_be16(tag.data + 12 + low * 2) / 65535.0;
    double y1 = read_be16(tag.data + 12 + high * 2) / 65535.0;
    double fraction = y1 <= y0 ? 0.0 : (value - y0) / (y1 - y0);
    *result = (low + fmax(0.0, fmin(1.0, fraction))) / (count - 1);
    return true;
}

static bool inverse_matrix3(const double m[3][3], double out[3][3])
{
    return pgen_matrix3_inverse_divide(m,out,1e-12)!=0;
}

/* Construct a Bradford adaptation from a source-space white onto D50 PCS.
 * This is used by the calibrated profile paths below. Ordinary uncalibrated
 * Argyll display profiles instead use their saved chad matrix for the
 * absolute-colorimetric conversion. */
static bool companion_adaptation(const double media_white[3], double out[3][3])
{
    static const double bradford[3][3]=PGEN_BRADFORD_MATRIX_INITIALIZER;
    static const double pcs_white[3]={0.9642,1.0,0.8249};
    double inverse[3][3], source[3], destination[3], scaled[3][3];
    if(!inverse_matrix3(bradford,inverse)) return false;
    for(int row=0;row<3;row++) {
        source[row]=bradford[row][0]*media_white[0]+bradford[row][1]*media_white[1]+bradford[row][2]*media_white[2];
        destination[row]=bradford[row][0]*pcs_white[0]+bradford[row][1]*pcs_white[1]+bradford[row][2]*pcs_white[2];
        if(fabs(source[row])<1e-9) return false;
    }
    for(int row=0;row<3;row++)
        for(int column=0;column<3;column++)
            scaled[row][column]=(destination[row]/source[row])*bradford[row][column];
    for(int row=0;row<3;row++)
        for(int column=0;column<3;column++)
            out[row][column]=inverse[row][0]*scaled[0][column]+inverse[row][1]*scaled[1][column]+inverse[row][2]*scaled[2][column];
    return true;
}

static void companion_source_xyz(const double rgb[3], const char *signal_mode,
                                 double white_nits, const double adaptation[3][3],
                                 double xyz[3])
{
    static const double srgb_xyz[3][3]={{0.4123908,0.3575843,0.1804808},{0.2126390,0.7151687,0.0721923},{0.0193308,0.1191948,0.9505322}};
    static const double bt2020_xyz[3][3]={{0.6369580,0.1446169,0.1688810},{0.2627002,0.6779981,0.0593017},{0.0,0.0280727,1.0609851}};
    double linear[3], intermediate[3];
    for (int channel=0; channel<3; channel++) {
        /* Relative PCS deliberately exceeds 1.0 above the profile's measured
         * white: the lut16 XYZ number encoding reserves headroom to 2.0 and
         * HDR BToA input shapers use it to resolve highlights through the
         * display rolloff. icc_table_sample clamps at the encoding limit, so
         * clamping here at 1.0 would pin every brighter request to the
         * measured-white code and diverge from a compositor's evaluation. */
        if (!strcmp(signal_mode,"hdr10")) linear[channel]=pq_to_nits(rgb[channel])/fmax(white_nits,1e-6);
        else linear[channel]=rgb[channel]<=0.04045?rgb[channel]/12.92:pow((rgb[channel]+0.055)/1.055,2.4);
    }
    const double (*source)[3]=!strcmp(signal_mode,"hdr10")?bt2020_xyz:srgb_xyz;
    for(int row=0;row<3;row++) intermediate[row]=source[row][0]*linear[0]+source[row][1]*linear[1]+source[row][2]*linear[2];
    for(int row=0;row<3;row++)
        xyz[row]=adaptation[row][0]*intermediate[0]+adaptation[row][1]*intermediate[1]+adaptation[row][2]*intermediate[2];
}

static bool apply_local_matrix(const double xyz[3], double output[3])
{
    static const char *xyz_names[3]={"rXYZ","gXYZ","bXYZ"};
    static const char *trc_names[3]={"rTRC","gTRC","bTRC"};
    double matrix[3][3], inverse[3][3], linear[3];
    for(int column=0;column<3;column++) {
        IccTag tag=icc_tag(app.correction_profile_data,app.correction_profile_size,xyz_names[column]);
        if(!tag.data||tag.size<20||memcmp(tag.data,"XYZ ",4)) return false;
        for(int row=0;row<3;row++) matrix[row][column]=read_s15(tag.data+8+row*4);
    }
    if(!inverse_matrix3(matrix,inverse)) return false;
    for(int row=0;row<3;row++) linear[row]=inverse[row][0]*xyz[0]+inverse[row][1]*xyz[1]+inverse[row][2]*xyz[2];
    for(int channel=0;channel<3;channel++) if(!icc_inverse_curve(icc_tag(app.correction_profile_data,app.correction_profile_size,trc_names[channel]),linear[channel],&output[channel])) return false;
    return true;
}

static bool apply_local_clut(const double xyz[3], double output[3])
{
    IccTag tag=icc_tag(app.correction_profile_data,app.correction_profile_size,"B2A0");
    if(!tag.data||tag.size<52||memcmp(tag.data,"mft2",4)||tag.data[8]!=3||tag.data[9]!=3||tag.data[10]<2) return false;
    int grid=tag.data[10]; uint32_t in_count=read_be16(tag.data+48),out_count=read_be16(tag.data+50);
    if(in_count<2||out_count<2) return false;
    size_t input_offset=52,clut_offset=input_offset+(size_t)3*in_count*2;
    size_t clut_size=(size_t)grid*grid*grid*3*2,output_offset=clut_offset+clut_size;
    if(output_offset+(size_t)3*out_count*2>tag.size) return false;
    double values[3],fraction[3]; int base[3];
    for(int row=0;row<3;row++) {
        double mapped=0.0; for(int column=0;column<3;column++) mapped+=read_s15(tag.data+12+(row*3+column)*4)*xyz[column];
        values[row]=icc_table_sample(tag.data+input_offset+(size_t)row*in_count*2,in_count,mapped/(65535.0/32768.0));
        double position=fmax(0.0,fmin(1.0,values[row]))*(grid-1); base[row]=(int)position; if(base[row]>=grid-1)base[row]=grid-2; fraction[row]=position-base[row];
    }
    double clut_result[3]={0.0,0.0,0.0};
    for(int channel=0;channel<3;channel++) {
#define CLUT_VALUE(dx,dy,dz) (read_be16(tag.data+clut_offset+(size_t)((((base[0]+(dx))*grid+(base[1]+(dy)))*grid+(base[2]+(dz)))*3+channel)*2)/65535.0)
        for(int red=0;red<2;red++)
            for(int green=0;green<2;green++)
                for(int blue=0;blue<2;blue++){
                    double weight=(red?fraction[0]:1.0-fraction[0])
                                 *(green?fraction[1]:1.0-fraction[1])
                                 *(blue?fraction[2]:1.0-fraction[2]);
                    clut_result[channel]+=CLUT_VALUE(red,green,blue)*weight;
                }
#undef CLUT_VALUE
    }
    for(int channel=0;channel<3;channel++) output[channel]=icc_table_sample(tag.data+output_offset+(size_t)channel*out_count*2,out_count,clut_result[channel]);
    return true;
}

static double linear_to_pq(double value)
{
    return pgen_pq_encode_linear(value);
}

static double mhc2_curve_sample(const unsigned char *curve, uint32_t count,
                                double value)
{
    double position=fmax(0.0,fmin(1.0,value))*(count-1);
    uint32_t lower=(uint32_t)position;
    double fraction;
    if(lower>=count-1)lower=count-2;
    fraction=position-lower;
    return read_s15(curve+8+lower*4)*(1.0-fraction)+
           read_s15(curve+8+(lower+1)*4)*fraction;
}

/* Apply the profile's vcgt calibration to a device triple.
 *
 * vcgt is the 1D per-channel calibration stage. When the profile carries one,
 * its cLUT was fitted in the calibrated domain, so this must run between the
 * profile transform and the panel or the shadows come out under-driven. On
 * Windows an OS profile loader would normally do this, but the GPU LUT is
 * bypassed once Advanced Color is on, so for HDR the Companion is the only
 * thing that can. A profile without the tag is left untouched.
 */
/* Undo MHC2 only for the diagnostic no-correction mode. Explicit cLUT and
 * matrix modes suspend Windows' per-user profile stage instead, because a
 * clipped MHC2 curve is not invertible and those modes must evaluate their
 * selected transform without borrowing data from MHC2. */
static bool apply_mhc2_inverse(double rgb[3])
{
    static const double wire[3][3]={{0.6369580,0.1446169,0.1688810},{0.2627002,0.6779981,0.0593017},{0.0,0.0280727,1.0609851}};
    IccTag tag=icc_tag(app.correction_profile_data,app.correction_profile_size,"MHC2");
    double inverse_wire[3][3],inverse_matrix[3][3],linear[3],xyz[3],undone[3],target[3];
    double matrix[3][3]={{1,0,0},{0,1,0},{0,0,1}};
    uint32_t count,matrix_offset,curve_offsets[3];
    if(!tag.data||tag.size<36||memcmp(tag.data,"MHC2",4))return false;
    count=read_be32(tag.data+8);matrix_offset=read_be32(tag.data+20);
    for(int channel=0;channel<3;channel++)curve_offsets[channel]=read_be32(tag.data+24+channel*4);
    if(matrix_offset){
        if(matrix_offset+48>tag.size)return false;
        for(int row=0;row<3;row++)for(int column=0;column<3;column++)
            matrix[row][column]=read_s15(tag.data+matrix_offset+(row*4+column)*4);
    }
    if(count>4096||(count>0&&count<2))return false;
    if(count)for(int channel=0;channel<3;channel++)
        if(curve_offsets[channel]<36||curve_offsets[channel]+8+(size_t)count*4>tag.size||
           memcmp(tag.data+curve_offsets[channel],"sf32",4))return false;
    if(!inverse_matrix3(wire,inverse_wire))return false;
    if(!inverse_matrix3(matrix,inverse_matrix))return false;
    /* Invert the per-channel curve first, then the matrix: the reverse of the
     * order Windows applies them. */
    for(int channel=0;channel<3;channel++){
        double encoded=rgb[channel];
        if(count){
            /* The curves are monotonic, so a bisection recovers the input. */
            double low=0.0,high=1.0;
            for(int step=0;step<24;step++){
                double middle=0.5*(low+high);
                if(mhc2_curve_sample(tag.data+curve_offsets[channel],count,middle)<encoded)low=middle;
                else high=middle;
            }
            encoded=0.5*(low+high);
        }
        target[channel]=pq_to_nits(encoded)/10000.0;
    }
    for(int row=0;row<3;row++)xyz[row]=wire[row][0]*target[0]+wire[row][1]*target[1]+wire[row][2]*target[2];
    for(int row=0;row<3;row++)undone[row]=inverse_matrix[row][0]*xyz[0]+inverse_matrix[row][1]*xyz[1]+inverse_matrix[row][2]*xyz[2];
    for(int row=0;row<3;row++)linear[row]=inverse_wire[row][0]*undone[0]+inverse_wire[row][1]*undone[1]+inverse_wire[row][2]*undone[2];
    for(int channel=0;channel<3;channel++)rgb[channel]=linear_to_pq(linear[channel]<0.0?0.0:linear[channel]);
    return true;
}

/* Apply the profile's vcgt calibration to a device triple.
 *
 * vcgt is the standard post-transform stage: BToA emits device codes for the
 * calibrated display and the video-card gamma table runs after it. In
 * application-side correction modes nothing else loads that table, so the
 * Companion applies it to the transform output here. HDR profiles that need
 * grey-axis tracking beyond what a downstream 1D stage can express must
 * incorporate the calibration into BToA instead of shipping a vcgt tag.
 * macOS is the exception and compiles this out: ColorSync loads the active
 * profile's vcgt into the display pipe itself. */
#ifndef __APPLE__
static bool apply_vcgt(double rgb[3])
{
    IccTag tag=icc_tag(app.correction_profile_data,app.correction_profile_size,"vcgt");
    if(!tag.data||tag.size<18||memcmp(tag.data,"vcgt",4)) return false;
    if(read_be32(tag.data+8)!=0) return false;           /* 0 = table, 1 = formula */
    uint32_t channels=read_be16(tag.data+12);
    uint32_t entries=read_be16(tag.data+14);
    uint32_t entry_size=read_be16(tag.data+16);
    if(channels!=3||entries<2||entry_size!=2) return false;
    if(tag.size < 18u + (size_t)channels*entries*2u) return false;
    const unsigned char *table=tag.data+18;
    for(int channel=0;channel<3;channel++){
        double value=rgb[channel];
        if(!(value>0.0)) value=0.0;
        if(value>1.0) value=1.0;
        double position=value*(double)(entries-1);
        uint32_t low=(uint32_t)position;
        if(low>entries-2) low=entries-2;
        double fraction=position-(double)low;
        const unsigned char *base=table+(size_t)channel*entries*2u;
        double first=read_be16(base+(size_t)low*2)/65535.0;
        double second=read_be16(base+((size_t)low+1)*2)/65535.0;
        rgb[channel]=first*(1.0-fraction)+second*fraction;
    }
    return true;
}
#endif

static bool load_correction_lut(uint64_t revision)
{
    FILE *file;
    long length;
    /* System and none remain usable without a readable profile. Without one,
     * system is ordinary OS handling and none can only fall back to submitting
     * the source unchanged because there is no MHC2 stage to invert. */
    bool system_mode=!strcmp(app.correction_mode,"system")||!strcmp(app.correction_mode,"none");
    /* Never retain a transform from a previously selected profile if the new
     * LUT cannot be downloaded or decoded. A stale correction would produce a
     * valid patch acknowledgement while applying the wrong profile. */
    SDL_free(app.correction_lut);
    app.correction_lut = NULL;
    app.correction_lut_grid = 0;
    app.correction_ready = system_mode;
    if (!app.correction_profile[0]) {
        if(system_mode){app.correction_lut_revision=revision;app.correction_error[0]='\0';return true;}
        app.correction_ready = false;
#ifdef _WIN32
        SDL_strlcpy(app.correction_error, "The operating system did not report an active ICC profile for the selected display", sizeof(app.correction_error));
#elif defined(__APPLE__)
        SDL_strlcpy(app.correction_error,
                    "ColorSync did not report a profile for the selected display",
                    sizeof(app.correction_error));
#else
        /* Name the compositor and the slot: on Plasma 6.7 an HDR display has a
         * separate "HDR ICC profile" assignment, and a display with only the
         * SDR one set looks identical to one with nothing set. */
        SDL_strlcpy(app.correction_error,
                    "No ICC profile is assigned to this display in KWin",
                    sizeof(app.correction_error));
#endif
        return false;
    }
#ifdef _WIN32
    file=_wfopen(app.correction_profile_path,L"rb");
#elif defined(__APPLE__)
    /* Same file, a third way of finding it: ColorSync names it here. A factory
     * profile generated in memory has no file behind it, which leaves the path
     * empty and the explicit correction modes unavailable. */
    if (!app.macos_profile_path[0]) {
        if(system_mode){app.correction_lut_revision=revision;app.correction_error[0]='\0';return true;}
        app.correction_ready = false;
        SDL_strlcpy(app.correction_error,
                    "The display's ColorSync profile has no readable file",
                    sizeof(app.correction_error));
        return false;
    }
    file=fopen(app.macos_profile_path,"rb");
#else
    /* Same file, different way of finding it: DXGI names it on Windows, KWin
     * names it here. Everything after the open is identical, so the profile
     * parsing and the whole transform stay a single implementation. */
    if (!app.linux_profile_path[0]) {
        if(system_mode){app.correction_lut_revision=revision;app.correction_error[0]='\0';return true;}
        app.correction_ready = false;
        SDL_strlcpy(app.correction_error,
                    "No ICC profile is assigned to this display in KWin",
                    sizeof(app.correction_error));
        return false;
    }
    file=fopen(app.linux_profile_path,"rb");
#endif
    if(!file||fseek(file,0,SEEK_END)!=0||(length=ftell(file))<132||length>16*1024*1024||fseek(file,0,SEEK_SET)!=0){if(file)fclose(file);if(system_mode){app.correction_lut_revision=revision;app.correction_error[0]='\0';return true;}SDL_strlcpy(app.correction_error,"Could not open the display's active ICC profile",sizeof(app.correction_error));return false;}
    SDL_free(app.correction_profile_data); app.correction_profile_data=SDL_malloc((size_t)length); app.correction_profile_size=0;
    if(!app.correction_profile_data||fread(app.correction_profile_data,1,(size_t)length,file)!=(size_t)length){fclose(file);SDL_free(app.correction_profile_data);app.correction_profile_data=NULL;SDL_strlcpy(app.correction_error,"Could not read the display's active ICC profile",sizeof(app.correction_error));return false;}
    fclose(file); app.correction_profile_size=(size_t)length;
    if(memcmp(app.correction_profile_data+12,"mntr",4)||memcmp(app.correction_profile_data+16,"RGB ",4)||memcmp(app.correction_profile_data+20,"XYZ ",4)){SDL_free(app.correction_profile_data);app.correction_profile_data=NULL;app.correction_profile_size=0;SDL_strlcpy(app.correction_error,"The active profile is not a supported RGB display profile",sizeof(app.correction_error));return false;}
    app.correction_lut_revision = revision;
    app.correction_error[0] = '\0';
    app.correction_ready = true;
    return true;
}

static bool apply_correction_lut(double *red, double *green, double *blue)
{
    double rgb[3]={*red,*green,*blue},xyz[3],output[3],white_nits=1.0;
    static const double d65_white[3]={0.9504559,1.0,1.0890578};
    double adaptation[3][3];

    /* On Windows the selected monitor's per-user profile stage is suspended
     * before none/cLUT/matrix HDR handling reaches this function. None is the
     * profiling path, so it must be literal source passthrough. Pre-inverting
     * MHC2 here made raw characterizations depend on whether Windows happened
     * to attach that stage to the HDR swapchain. */
    if(!strcmp(app.correction_mode,"none")) {
#ifdef _WIN32
        *red=rgb[0];*green=rgb[1];*blue=rgb[2];
#endif
        return true;
    }
    if(!strcmp(app.correction_mode,"system")){
#ifdef _WIN32
        /* The swapchain is borderless and composed, not exclusive fullscreen.
         * DWM applies the active profile's MHC2 stage in both window modes, so
         * system handling must submit the source unchanged. Applying MHC2
         * locally here corrects fullscreen patches twice. */
#elif defined(__APPLE__)
        /* macOS composites every window through the display's assigned
         * ColorSync profile on its own, and this build never toggles that OS
         * state. "system" means exactly that native handling, so the patch
         * passes through unchanged for the meter to measure it. */
#else
        /* KWin composites the assigned profile itself, including in HDR from
         * Plasma 6.7 on, so there is nothing here to stand in for - applying
         * it again would correct the patch twice. "system" means the
         * compositor's correction, and letting the patch through unchanged is
         * exactly how the meter gets to measure it. */
#endif
        return true;
    }
    if(!app.correction_profile_data)return false;
    /* Both sRGB and BT.2020 use D65.  ICC PCS is D50, so source colours must
     * always be adapted from D65 to D50 before entering BToA.  The profile's
     * wtpt is the measured display white and is characterization data, not the
     * source white for this conversion.  Using it here moved even requested
     * D65 white away from PCS white and produced a severe red/yellow cast. */
    if(!companion_adaptation(d65_white,adaptation))return false;
    if(!strcmp(app.correction_signal_mode,"hdr10")){
        IccTag lumi=icc_tag(app.correction_profile_data,app.correction_profile_size,"lumi");
        if(!lumi.data||lumi.size<20||memcmp(lumi.data,"XYZ ",4)||(white_nits=read_s15(lumi.data+12))<=0.0)return false;
    }
    companion_source_xyz(rgb,app.correction_signal_mode,white_nits,adaptation,xyz);
    if(!strcmp(app.correction_mode,"clut")){if(!apply_local_clut(xyz,output))return false;}
    else if(!apply_local_matrix(xyz,output))return false;
#ifndef __APPLE__
    /* Standard ICC order: vcgt runs on the transform's device output, exactly
     * where a video-card gamma table would. */
    apply_vcgt(output);
#else
    /* macOS loads the active profile's vcgt into the video-card gamma table
     * itself, and this build leaves that OS state alone, so the calibration
     * already runs after this transform - applying the tag here as well would
     * run it twice. */
#endif
    /* Windows explicit modes suspend the selected monitor's per-user profile
     * stage before reaching this function. Do not sample MHC2 locally and do
     * not pre-invert it: B2A0 (plus a real vcgt when present) is the complete
     * correction path the operator selected. */
    *red = output[0]; *green = output[1]; *blue = output[2];
    return true;
}

static bool json_number(const char *json, const char *key, double *value)
{
    char needle[96];
    const char *found;
    char *end;
    SDL_snprintf(needle, sizeof(needle), "\"%s\"", key);
    found = strstr(json, needle);
    if (!found || !(found = strchr(found + strlen(needle), ':'))) return false;
    *value = strtod(found + 1, &end);
    return end != found + 1 && isfinite(*value);
}

static bool json_string(const char *json, const char *key, char *value, size_t size)
{
    char needle[96];
    const char *found, *start, *end;
    SDL_snprintf(needle, sizeof(needle), "\"%s\"", key);
    found = strstr(json, needle);
    if (!found || !(found = strchr(found + strlen(needle), ':'))) return false;
    start = strchr(found, '"');
    if (!start) return false;
    end = strchr(++start, '"');
    if (!end) return false;
    SDL_snprintf(value, size, "%.*s", (int)(end - start), start);
    return true;
}

static float srgb_to_linear(float value)
{
    if (value <= 0.04045f) return value / 12.92f;
    return powf((value + 0.055f) / 1.055f, 2.4f);
}

#ifdef _WIN32
static bool windows_window_hdr_info(SDL_Window *window, double *minimum_luminance,
                                    double *maximum_luminance,
                                    double *maximum_full_frame_luminance,
                                    UINT *bits_per_color)
{
    static const GUID pgen_iid_idxgi_output6 =
        { 0x068346e8, 0xaaec, 0x4b84, { 0xad, 0xd7, 0x13, 0x7f, 0x51, 0x3f, 0x77, 0xa1 } };
    static const GUID pgen_iid_idxgi_factory1 =
        { 0x770aae78, 0xf26f, 0x4dba, { 0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87 } };
    SDL_PropertiesID window_props;
    HWND hwnd;
    HMONITOR monitor;
    IDXGIFactory1 *factory = NULL;
    bool enabled = false;
    bool found = false;

    if (minimum_luminance) *minimum_luminance = 0.0;
    if (maximum_luminance) *maximum_luminance = 0.0;
    if (maximum_full_frame_luminance) *maximum_full_frame_luminance = 0.0;
    if (bits_per_color) *bits_per_color = 0;

    if (!window) return false;
    window_props = SDL_GetWindowProperties(window);
    hwnd = (HWND)SDL_GetPointerProperty(window_props, SDL_PROP_WINDOW_WIN32_HWND_POINTER, NULL);
    if (!hwnd) return false;
    monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    if (!monitor || FAILED(CreateDXGIFactory1(&pgen_iid_idxgi_factory1, (void **)&factory))) return false;
    for (UINT adapter_index = 0; !found; adapter_index++) {
        IDXGIAdapter1 *adapter = NULL;
        HRESULT adapter_result = IDXGIFactory1_EnumAdapters1(factory, adapter_index, &adapter);
        if (adapter_result == DXGI_ERROR_NOT_FOUND) break;
        if (FAILED(adapter_result) || !adapter) continue;
        for (UINT output_index = 0; !found; output_index++) {
            IDXGIOutput *output = NULL;
            IDXGIOutput6 *output6 = NULL;
            DXGI_OUTPUT_DESC output_desc;
            DXGI_OUTPUT_DESC1 output_desc1;
            HRESULT output_result = IDXGIAdapter1_EnumOutputs(adapter, output_index, &output);
            if (output_result == DXGI_ERROR_NOT_FOUND) break;
            if (FAILED(output_result) || !output) continue;
            if (SUCCEEDED(IDXGIOutput_GetDesc(output, &output_desc)) && output_desc.Monitor == monitor &&
                SUCCEEDED(IDXGIOutput_QueryInterface(output, &pgen_iid_idxgi_output6, (void **)&output6)) && output6 &&
                SUCCEEDED(IDXGIOutput6_GetDesc1(output6, &output_desc1))) {
                found = true;
                enabled = output_desc1.ColorSpace == DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020;
                if (minimum_luminance) *minimum_luminance = output_desc1.MinLuminance;
                if (maximum_luminance) *maximum_luminance = output_desc1.MaxLuminance;
                if (maximum_full_frame_luminance)
                    *maximum_full_frame_luminance = output_desc1.MaxFullFrameLuminance;
                if (bits_per_color) *bits_per_color = output_desc1.BitsPerColor;
            }
            if (output6) IDXGIOutput6_Release(output6);
            IDXGIOutput_Release(output);
        }
        IDXGIAdapter1_Release(adapter);
    }
    IDXGIFactory1_Release(factory);
    return enabled;
}

static bool windows_window_hdr_enabled(SDL_Window *window)
{
    return windows_window_hdr_info(window, NULL, NULL, NULL, NULL);
}

static void windows_hdr_diagnostics(char *swapchain_color_space,
                                    size_t swapchain_color_space_size,
                                    char *presentation_mode,
                                    size_t presentation_mode_size,
                                    double *output_maximum_luminance,
                                    double *output_full_frame_luminance,
                                    UINT *output_bits_per_color)
{
    static const GUID pgen_iid_idxgi_swapchain_media =
        { 0xdd95b90b, 0xf05f, 0x4f6a, { 0xbd, 0x65, 0x25, 0xbf, 0xb2, 0x64, 0xbd, 0x84 } };
    IDXGISwapChainMedia *swapchain_media = NULL;
    DXGI_FRAME_STATISTICS_MEDIA statistics;

    SDL_strlcpy(swapchain_color_space, "none", swapchain_color_space_size);
    SDL_strlcpy(presentation_mode, "unknown", presentation_mode_size);
    *output_maximum_luminance = 0.0;
    *output_full_frame_luminance = 0.0;
    *output_bits_per_color = 0;
    windows_window_hdr_info(app.window, NULL, output_maximum_luminance,
                            output_full_frame_luminance, output_bits_per_color);
    if (!app.hdr_swapchain) return;
    /* The swapchain is retained only after CheckColorSpaceSupport and
     * SetColorSpace1 both accept the HDR10/PQ colorspace. */
    if (app.hdr)
        SDL_strlcpy(swapchain_color_space, "hdr10-pq", swapchain_color_space_size);
    if (SUCCEEDED(IDXGISwapChain_QueryInterface(app.hdr_swapchain,
                                                &pgen_iid_idxgi_swapchain_media,
                                                (void **)&swapchain_media)) &&
        swapchain_media) {
        SDL_zero(statistics);
        if (SUCCEEDED(IDXGISwapChainMedia_GetFrameStatisticsMedia(swapchain_media,
                                                                  &statistics))) {
            const char *mode = "unknown";
            if (statistics.CompositionMode == DXGI_FRAME_PRESENTATION_MODE_COMPOSED)
                mode = "composed";
            else if (statistics.CompositionMode == DXGI_FRAME_PRESENTATION_MODE_OVERLAY)
                mode = "hardware-overlay";
            else if (statistics.CompositionMode == DXGI_FRAME_PRESENTATION_MODE_NONE)
                mode = "direct";
            else if (statistics.CompositionMode == DXGI_FRAME_PRESENTATION_MODE_COMPOSITION_FAILURE)
                mode = "composition-failure";
            SDL_strlcpy(presentation_mode, mode, presentation_mode_size);
        }
        IDXGISwapChainMedia_Release(swapchain_media);
    }
}

static void windows_destroy_hdr_output(void)
{
    windows_nvapi_hdr_source_end();
    if (app.hdr_context) ID3D11DeviceContext_OMSetRenderTargets(app.hdr_context, 0, NULL, NULL);
    if (app.hdr_render_target) { ID3D11RenderTargetView_Release(app.hdr_render_target); app.hdr_render_target = NULL; }
    if (app.hdr_swapchain) {
        IDXGISwapChain_Release(app.hdr_swapchain);
        app.hdr_swapchain = NULL;
    }
    if (app.hdr_context1) { ID3D11DeviceContext1_Release(app.hdr_context1); app.hdr_context1 = NULL; }
    if (app.hdr_context) { ID3D11DeviceContext_Release(app.hdr_context); app.hdr_context = NULL; }
    if (app.hdr_device) { ID3D11Device_Release(app.hdr_device); app.hdr_device = NULL; }
    app.hdr_width = 0;
    app.hdr_height = 0;
}

static bool windows_hdr_render_target(int width, int height)
{
    ID3D11Texture2D *back_buffer = NULL;
    IDXGISwapChain3 *swapchain3 = NULL;
    HRESULT result;
    if (!app.hdr_swapchain || !app.hdr_device || width < 1 || height < 1) return false;
    if (app.hdr_render_target && width == app.hdr_width && height == app.hdr_height) return true;
    if (app.hdr_context) ID3D11DeviceContext_OMSetRenderTargets(app.hdr_context, 0, NULL, NULL);
    if (app.hdr_render_target) { ID3D11RenderTargetView_Release(app.hdr_render_target); app.hdr_render_target = NULL; }
    result = IDXGISwapChain_ResizeBuffers(app.hdr_swapchain, 0, (UINT)width, (UINT)height,
                                         DXGI_FORMAT_R10G10B10A2_UNORM, 0);
    if (FAILED(result)) {
        SDL_SetError("Could not resize the native HDR10 swapchain (0x%08lx)", (unsigned long)result);
        return false;
    }
    result = IDXGISwapChain_GetBuffer(app.hdr_swapchain, 0, &IID_ID3D11Texture2D,
                                      (void **)&back_buffer);
    if (SUCCEEDED(result))
        result = ID3D11Device_CreateRenderTargetView(app.hdr_device,
                                                     (ID3D11Resource *)back_buffer,
                                                     NULL, &app.hdr_render_target);
    if (back_buffer) ID3D11Texture2D_Release(back_buffer);
    if (FAILED(result) || !app.hdr_render_target) {
        SDL_SetError("Could not create the native HDR10 render target (0x%08lx)", (unsigned long)result);
        return false;
    }
    result = IDXGISwapChain_QueryInterface(app.hdr_swapchain, &IID_IDXGISwapChain3,
                                           (void **)&swapchain3);
    if (SUCCEEDED(result))
        result = IDXGISwapChain3_SetColorSpace1(
            swapchain3, DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020);
    if (swapchain3) IDXGISwapChain3_Release(swapchain3);
    if (FAILED(result)) {
        SDL_SetError("Could not restore the HDR10 swapchain color space (0x%08lx)", (unsigned long)result);
        ID3D11RenderTargetView_Release(app.hdr_render_target);
        app.hdr_render_target = NULL;
        return false;
    }
    app.hdr_width = width;
    app.hdr_height = height;
    return true;
}

static bool windows_set_hdr_metadata(void)
{
    IDXGISwapChain4 *swapchain4 = NULL;
    DXGI_HDR_METADATA_HDR10 metadata;
    double min_luma_wire;
    HRESULT result;
    if (!app.hdr_swapchain) return false;
    memset(&metadata, 0, sizeof(metadata));
    /* BT.2020 mastering primaries and D65, in 0.00002 chromaticity units. */
    metadata.RedPrimary[0] = 35400; metadata.RedPrimary[1] = 14600;
    metadata.GreenPrimary[0] = 8500; metadata.GreenPrimary[1] = 39850;
    metadata.BluePrimary[0] = 6550; metadata.BluePrimary[1] = 2300;
    metadata.WhitePoint[0] = 15635; metadata.WhitePoint[1] = 16450;
    metadata.MaxMasteringLuminance = (UINT)lround(fmax(0.0, fmin(10000.0, app.displayed_max_luma)));
    /* Current UI values are nits. Accept the legacy/conf wire-unit form too. */
    min_luma_wire = app.displayed_min_luma >= 1.0
        ? app.displayed_min_luma : app.displayed_min_luma * 10000.0;
    metadata.MinMasteringLuminance = (UINT)lround(fmax(0.0, fmin(65535.0, min_luma_wire)));
    metadata.MaxContentLightLevel = (USHORT)lround(fmax(0.0, fmin(10000.0, app.displayed_max_cll)));
    metadata.MaxFrameAverageLightLevel = (USHORT)lround(fmax(0.0, fmin(10000.0, app.displayed_max_fall)));
    result = IDXGISwapChain_QueryInterface(app.hdr_swapchain, &IID_IDXGISwapChain4,
                                           (void **)&swapchain4);
    if (SUCCEEDED(result))
        result = IDXGISwapChain4_SetHDRMetaData(swapchain4, DXGI_HDR_METADATA_TYPE_HDR10,
                                                sizeof(metadata), &metadata);
    if (swapchain4) IDXGISwapChain4_Release(swapchain4);
    if (FAILED(result)) {
        SDL_SetError("Could not apply HDR10 mastering metadata (0x%08lx)", (unsigned long)result);
        return false;
    }
    if (pgen_nvapi_source_active) {
        if (windows_nvapi_hdr_metadata(&metadata))
            SDL_strlcpy(app.renderer_name, "direct3d11-hdr10-composed-nvapi",
                        sizeof(app.renderer_name));
        else
            SDL_snprintf(app.renderer_name, sizeof(app.renderer_name),
                         "direct3d11-hdr10-nvapi-error-%d",
                         pgen_nvapi_last_status);
    }
    return true;
}

static bool windows_create_hdr_output(void)
{
    HWND hwnd = (HWND)SDL_GetPointerProperty(SDL_GetWindowProperties(app.window),
                                              SDL_PROP_WINDOW_WIN32_HWND_POINTER, NULL);
    static const GUID pgen_iid_idxgi_device =
        { 0x54ec77fa, 0x1377, 0x44e6, { 0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c } };
    static const GUID pgen_iid_idxgi_factory2 =
        { 0x50c83a1c, 0xe072, 0x4c48, { 0x87, 0xb0, 0x36, 0x30, 0xfa, 0x36, 0xa6, 0xd0 } };
    D3D_FEATURE_LEVEL requested_feature_levels[] = { D3D_FEATURE_LEVEL_11_0 };
    DXGI_SWAP_CHAIN_DESC1 desc;
    D3D_FEATURE_LEVEL feature_level;
    IDXGIDevice *dxgi_device = NULL;
    IDXGIAdapter *adapter = NULL;
    IDXGIFactory2 *factory = NULL;
    IDXGISwapChain1 *swapchain1 = NULL;
    IDXGISwapChain3 *swapchain3 = NULL;
    UINT color_support = 0;
    RECT client;
    HRESULT result;
    if (!hwnd || !GetClientRect(hwnd, &client)) {
        SDL_SetError("Could not get the Windows patch-window handle");
        return false;
    }
    SDL_zero(desc);
    desc.Width = 0;
    desc.Height = 0;
    desc.Format = DXGI_FORMAT_R10G10B10A2_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    desc.Scaling = DXGI_SCALING_STRETCH;
    desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;

    /* Create the device separately, then obtain its current DXGI factory and
     * use the modern HWND flip-model path. This is the same native HDR10
     * presentation path used by dogegen. The legacy combined creation API is
     * not updated for current swap-chain features and can leave a window in
     * the desktop SDR composition policy on some Windows/driver stacks. */
    result = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL,
                               D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                               requested_feature_levels,
                               (UINT)SDL_arraysize(requested_feature_levels),
                               D3D11_SDK_VERSION, &app.hdr_device,
                               &feature_level, &app.hdr_context);
    if (SUCCEEDED(result))
        result = ID3D11Device_QueryInterface(app.hdr_device, &pgen_iid_idxgi_device,
                                             (void **)&dxgi_device);
    if (SUCCEEDED(result)) result = IDXGIDevice_GetAdapter(dxgi_device, &adapter);
    if (SUCCEEDED(result)) {
        DXGI_ADAPTER_DESC adapter_desc;
        if (SUCCEEDED(IDXGIAdapter_GetDesc(adapter, &adapter_desc)))
            pgen_adapter_vendor_id = adapter_desc.VendorId;
    }
    if (SUCCEEDED(result))
        result = IDXGIAdapter_GetParent(adapter, &pgen_iid_idxgi_factory2,
                                        (void **)&factory);
    if (SUCCEEDED(result))
        result = IDXGIFactory2_CreateSwapChainForHwnd(factory,
                                                       (IUnknown *)app.hdr_device,
                                                       hwnd, &desc, NULL, NULL,
                                                       &swapchain1);
    if (SUCCEEDED(result))
        result = IDXGIFactory2_MakeWindowAssociation(factory, hwnd,
                                                      DXGI_MWA_NO_WINDOW_CHANGES);
    if (SUCCEEDED(result)) {
        app.hdr_swapchain = (IDXGISwapChain *)swapchain1;
        swapchain1 = NULL;
    }
    if (swapchain1) IDXGISwapChain1_Release(swapchain1);
    if (factory) IDXGIFactory2_Release(factory);
    if (adapter) IDXGIAdapter_Release(adapter);
    if (dxgi_device) IDXGIDevice_Release(dxgi_device);
    if (FAILED(result)) {
        SDL_SetError("Could not create the native Windows HDR10 renderer (0x%08lx)", (unsigned long)result);
        windows_destroy_hdr_output();
        return false;
    }
    result = ID3D11DeviceContext_QueryInterface(app.hdr_context,
                                                &IID_ID3D11DeviceContext1,
                                                (void **)&app.hdr_context1);
    if (FAILED(result) || !app.hdr_context1) {
        SDL_SetError("Windows HDR10 rectangle rendering is unavailable (0x%08lx)", (unsigned long)result);
        windows_destroy_hdr_output();
        return false;
    }
    result = IDXGISwapChain_QueryInterface(app.hdr_swapchain, &IID_IDXGISwapChain3,
                                           (void **)&swapchain3);
    if (SUCCEEDED(result))
        result = IDXGISwapChain3_CheckColorSpaceSupport(
            swapchain3, DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020, &color_support);
    if (SUCCEEDED(result) && (color_support & DXGI_SWAP_CHAIN_COLOR_SPACE_SUPPORT_FLAG_PRESENT))
        result = IDXGISwapChain3_SetColorSpace1(
            swapchain3, DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020);
    else if (SUCCEEDED(result))
        result = E_NOTIMPL;
    if (swapchain3) IDXGISwapChain3_Release(swapchain3);
    if (FAILED(result)) {
        SDL_SetError("The selected display cannot present a native HDR10 swapchain (0x%08lx)", (unsigned long)result);
        windows_destroy_hdr_output();
        return false;
    }
    if (!windows_hdr_render_target((int)(client.right - client.left),
                                   (int)(client.bottom - client.top))) {
        windows_destroy_hdr_output();
        return false;
    }
    /* NVAPI only exists on NVIDIA: probing it on other vendors reported a
     * loader sentinel (-2) as a driver error on every AMD and Intel machine.
     * Name the actual path instead; the NVAPI error format is reserved for
     * NVIDIA adapters where the status is a genuine NvAPI_Status. */
    if (pgen_adapter_vendor_id == 0x10DE)
        windows_nvapi_hdr_source_begin(app.window);
    app.hdr = true;
    app.hdr_active = windows_window_hdr_enabled(app.window);
    if (pgen_nvapi_source_active)
        SDL_strlcpy(app.renderer_name, "direct3d11-hdr10-nvapi-rec2100",
                    sizeof(app.renderer_name));
    else if (pgen_adapter_vendor_id == 0x10DE)
        SDL_snprintf(app.renderer_name, sizeof(app.renderer_name),
                     "direct3d11-hdr10-nvapi-error-%d",
                     pgen_nvapi_last_status);
    else if (pgen_adapter_vendor_id == 0x1002 || pgen_adapter_vendor_id == 0x1022)
        SDL_strlcpy(app.renderer_name, "direct3d11-hdr10-amd",
                    sizeof(app.renderer_name));
    else if (pgen_adapter_vendor_id == 0x8086)
        SDL_strlcpy(app.renderer_name, "direct3d11-hdr10-intel",
                    sizeof(app.renderer_name));
    else
        SDL_strlcpy(app.renderer_name, "direct3d11-hdr10",
                    sizeof(app.renderer_name));
    if (!app.hdr_active) {
        SDL_SetError("Windows HDR is not active on the selected display");
        windows_destroy_hdr_output();
        return false;
    }
    return true;
}

static bool windows_render_hdr(double r, double g, double b, double background,
                               const SDL_FRect *destination)
{
    int width, height;
    float background_color[4] = {(float)background, (float)background, (float)background, 1.0f};
    float patch_color[4] = {(float)r, (float)g, (float)b, 1.0f};
    D3D11_RECT rect;
    if (!SDL_GetWindowSizeInPixels(app.window, &width, &height) ||
        !windows_hdr_render_target(width, height)) return false;
    if (!windows_set_hdr_metadata()) return false;
    rect.left = (LONG)fmaxf(0.0f, destination->x);
    rect.top = (LONG)fmaxf(0.0f, destination->y);
    rect.right = (LONG)fminf((float)width, destination->x + destination->w);
    rect.bottom = (LONG)fminf((float)height, destination->y + destination->h);
    ID3D11DeviceContext_ClearRenderTargetView(app.hdr_context, app.hdr_render_target,
                                              background_color);
    ID3D11DeviceContext1_ClearView(app.hdr_context1,
                                  (ID3D11View *)app.hdr_render_target,
                                  patch_color, &rect, 1);
    if (FAILED(IDXGISwapChain_Present(app.hdr_swapchain, 1, 0))) {
        SDL_SetError("The native HDR10 frame could not be presented");
        return false;
    }
    return true;
}
#endif

static PGEN_UNUSED double pq_to_nits(double value)
{
    return pgen_pq_decode_nits(value);
}

static void patch_to_sdr_linear(double r, double g, double b, float output[4])
{
    output[0] = srgb_to_linear((float)r);
    output[1] = srgb_to_linear((float)g);
    output[2] = srgb_to_linear((float)b);
    output[3] = 1.0f;
}

#ifdef __APPLE__
/* Convert HDR10 patch codes to the linear values SDL's Metal EDR surface
 * expects, where 1.0 is the display's current SDR white.
 *
 * macOS never exposes the physical luminance of SDR white -
 * SDL_PROP_WINDOW_SDR_WHITE_LEVEL_FLOAT is the SDR white VALUE in the linear
 * colorspace, defined as 1.0 on Apple EDR surfaces - so absolute PQ placement
 * is not achievable here and the mapping assumes the common 100 cd/m2
 * reference for SDR white. That is sufficient for characterization: the meter
 * reads the absolute light, and what matters is that the code-to-light
 * mapping is deterministic and repeatable at a fixed brightness setting.
 * Channel values are handed over per channel, so the surface's extended-sRGB
 * primaries stand in for BT.2020 - stable, but a BT.2020 saturation target
 * lands at the sRGB chromaticity.
 *
 * Values beyond the display's EDR headroom would otherwise be clipped per
 * channel by the OS; when the largest channel exceeds it, all three are
 * scaled by one common factor so the channel ratios survive. */
#define PGEN_MACOS_ASSUMED_SDR_WHITE_NITS 100.0
static void patch_to_edr_linear(double r, double g, double b, float output[4])
{
    SDL_PropertiesID window_props = SDL_GetWindowProperties(app.window);
    float sdr_white = SDL_GetFloatProperty(
        window_props, SDL_PROP_WINDOW_SDR_WHITE_LEVEL_FLOAT, 1.0f);
    float headroom = SDL_GetFloatProperty(
        window_props, SDL_PROP_WINDOW_HDR_HEADROOM_FLOAT, 0.0f);
    double linear[3], peak;
    if (!isfinite((double)sdr_white) || sdr_white <= 0.0f) sdr_white = 1.0f;
    linear[0] = pq_to_nits(r) / PGEN_MACOS_ASSUMED_SDR_WHITE_NITS * (double)sdr_white;
    linear[1] = pq_to_nits(g) / PGEN_MACOS_ASSUMED_SDR_WHITE_NITS * (double)sdr_white;
    linear[2] = pq_to_nits(b) / PGEN_MACOS_ASSUMED_SDR_WHITE_NITS * (double)sdr_white;
    peak = fmax(linear[0], fmax(linear[1], linear[2]));
    if (isfinite((double)headroom) && headroom > 1.0f &&
        peak > (double)headroom * (double)sdr_white) {
        double scale = (double)headroom * (double)sdr_white / peak;
        linear[0] *= scale;
        linear[1] *= scale;
        linear[2] *= scale;
    }
    output[0] = (float)linear[0];
    output[1] = (float)linear[1];
    output[2] = (float)linear[2];
    output[3] = 1.0f;
}
#else
static uint32_t patch_to_hdr10(double r, double g, double b)
{
    uint32_t red = (uint32_t)lround(fmax(0.0, fmin(1.0, r)) * 1023.0);
    uint32_t green = (uint32_t)lround(fmax(0.0, fmin(1.0, g)) * 1023.0);
    uint32_t blue = (uint32_t)lround(fmax(0.0, fmin(1.0, b)) * 1023.0);
    /* SDL's D3D11 backend exposes DXGI_FORMAT_R10G10B10A2_UNORM as
     * ABGR2101010. Use that native layout so SDL does not silently create an
     * 8-bit conversion texture for the unsupported ARGB2101010 format. */
    return 0xc0000000u | (blue << 20) | (green << 10) | red;
}
#endif

#if !defined(_WIN32) && !defined(__APPLE__)
/* What KWin says about the output the patches land on.
 *
 * Two things are only knowable from the compositor. SDL reports HDR through
 * the Wayland colour-management protocol, which KWin does not always answer
 * for a client even while it is driving the panel in HDR - the same gap the
 * Windows path works around with DXGI's output description. And the ICC
 * profile assigned to a display is the compositor's business entirely.
 *
 * Plasma 6.7 keeps SDR and HDR assignments in SEPARATE slots: "ICC profile"
 * and "HDR ICC profile". The HDR one is absent from `kscreen-doctor -j`
 * (which carries only iccProfilePath), so the human-readable `-o` form is the
 * only source for it. An HDR display commonly has an HDR profile and an EMPTY
 * SDR one, which is why reading iccProfilePath alone reports "no profile".
 */
typedef struct {
    bool found;
    bool enabled;
    bool hdr;
    int sdr_brightness;
    char connector[64];
    long score;               /* Distance from the SDL rectangle */
    char icc_path[1024];      /* SDR slot */
    char hdr_icc_path[1024];  /* HDR slot, Plasma 6.7+ */
} KWinOutputState;

/* kscreen-doctor colours its output; the escapes sit inside the values. */
static void kwin_strip_ansi(char *text)
{
    char *read = text, *write = text;
    while (*read) {
        if (*read == 0x1b) {
            while (*read && *read != 'm') read++;
            if (*read) read++;
            continue;
        }
        *write++ = *read++;
    }
    *write = '\0';
}

static void kwin_trim(char *value)
{
    char *end;
    while (*value == ' ' || *value == '\t') memmove(value, value + 1, strlen(value));
    end = value + strlen(value);
    while (end > value && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\r' || end[-1] == '\n'))
        *--end = '\0';
}

/* Matched by LOGICAL GEOMETRY, not by name: SDL names a display by its make
 * and model ("YCT Innoview") while kscreen-doctor names it by connector
 * ("HDMI-A-1"), and neither can be derived from the other.
 *
 * The two do NOT agree exactly. On a fractionally scaled output they round the
 * logical size differently - a real example being SDL 2133x1333 against
 * kscreen 2134x1334 for the same panel, with identical positions. So this
 * scores every output by how far it sits from the SDL rectangle and takes the
 * nearest, rather than demanding equality and matching nothing. Position
 * dominates the score because two monitors can share a size but never an
 * origin. */
static bool kwin_output_state(SDL_DisplayID display, KWinOutputState *state)
{
    FILE *pipe;
    char line[1400];
    SDL_Rect bounds;
    bool current = false;
    int enabled_count = 0;
    long best_score = -1;
    KWinOutputState pending, best, sole_enabled;

    SDL_zerop(state);
    if (!display || !SDL_GetDisplayBounds(display, &bounds)) return false;
    pipe = popen("kscreen-doctor -o 2>/dev/null", "r");
    if (!pipe) return false;
    SDL_zero(pending);
    SDL_zero(best);
    SDL_zero(sole_enabled);
    while (fgets(line, sizeof(line), pipe)) {
        char *cursor = line;
        kwin_strip_ansi(line);
        while (*cursor == ' ' || *cursor == '\t') cursor++;
        if (!strncmp(cursor, "Output:", 7)) {
            if (current && pending.enabled) {
                enabled_count++;
                sole_enabled = pending;
            }
            if (current && pending.found &&
                (best_score < 0 || pending.score < best_score)) {
                best = pending;
                best_score = pending.score;
            }
            SDL_zero(pending);
            {   /* "Output: 2 HDMI-A-1 <uuid>" */
                char identifier[32], name[64];
                if (sscanf(cursor + 7, "%31s %63s", identifier, name) == 2)
                    SDL_strlcpy(pending.connector, name, sizeof(pending.connector));
            }
            current = true;
        } else if (current && !strncmp(cursor, "enabled", 7)) {
            pending.enabled = true;
        } else if (current && !strncmp(cursor, "Geometry:", 9)) {
            int x = 0, y = 0, w = 0, h = 0;
            if (sscanf(cursor + 9, " %d,%d %dx%d", &x, &y, &w, &h) == 4) {
                long dx = labs((long)x - bounds.x), dy = labs((long)y - bounds.y);
                long dw = labs((long)w - bounds.w), dh = labs((long)h - bounds.h);
                pending.score = (dx + dy) * 8 + dw + dh;
                /* Generous enough for rounding, tight enough that a genuinely
                 * different monitor never wins. */
                pending.found = (dx <= 4 && dy <= 4 && dw <= 8 && dh <= 8);
            }
        } else if (current && !strncmp(cursor, "HDR ICC profile:", 16)) {
            SDL_strlcpy(pending.hdr_icc_path, cursor + 16, sizeof(pending.hdr_icc_path));
            kwin_trim(pending.hdr_icc_path);
            if (!strcmp(pending.hdr_icc_path, "none")) pending.hdr_icc_path[0] = '\0';
        } else if (current && !strncmp(cursor, "ICC profile:", 12)) {
            SDL_strlcpy(pending.icc_path, cursor + 12, sizeof(pending.icc_path));
            kwin_trim(pending.icc_path);
            if (!strcmp(pending.icc_path, "none")) pending.icc_path[0] = '\0';
        } else if (current && !strncmp(cursor, "HDR:", 4)) {
            pending.hdr = strstr(cursor, "enabled") != NULL;
        } else if (current && !strncmp(cursor, "SDR brightness:", 15)) {
            (void)sscanf(cursor + 15, " %d", &pending.sdr_brightness);
        }
    }
    if (current && pending.enabled) {
        enabled_count++;
        sole_enabled = pending;
    }
    if (current && pending.found && (best_score < 0 || pending.score < best_score))
        best = pending;
    pclose(pipe);
    /* Wayland normalizes an application's coordinates to the sole active
     * output, while kscreen-doctor can retain that output's old multi-monitor
     * origin. Geometry cannot match in that valid configuration. A sole
     * enabled output is unambiguous, so use it directly. */
    if (best_score < 0 && enabled_count == 1) {
        best = sole_enabled;
        best.found = true;
    }
    *state = best;
    return state->found;
}

static bool kwin_safe_connector(const char *connector)
{
    const unsigned char *cursor = (const unsigned char *)connector;
    if (!cursor || !*cursor) return false;
    for (; *cursor; cursor++)
        if (!isalnum(*cursor) && *cursor != '-' && *cursor != '_' && *cursor != '.')
            return false;
    return true;
}

static bool linux_profile_name_is_hdr(const char *path)
{
    char upper[1024];
    size_t index;
    const char *name = strrchr(path, '/');
    name = name ? name + 1 : path;
    for (index = 0; index + 1 < sizeof(upper) && name[index]; index++)
        upper[index] = (char)toupper((unsigned char)name[index]);
    upper[index] = '\0';
    return strstr(upper, "HDR-MHC2") != NULL || strstr(upper, "-HDR-") != NULL;
}

static bool profile_has_hdr_cicp(const unsigned char *profile, size_t profile_length)
{
    IccTag tag = icc_tag(profile, profile_length, "cicp");
    return tag.data && tag.size >= 12 && !memcmp(tag.data, "cicp", 4) &&
           tag.data[8] == 9 && tag.data[9] == 16 &&
           tag.data[10] == 0 && tag.data[11] == 1;
}

/* Keep compositor-managed and application-managed correction mutually
 * exclusive. KWin uses the MHC2 curves as the output calibration when that
 * tag exists, and otherwise uses vcgt. Leaving KWin's ICC path active while
 * the Companion also evaluates MHC2 or BToA therefore corrects greyscale
 * twice and crushes the first PQ steps.
 *
 * The assigned profile path is retained. Only its active source changes, so
 * the Companion can still read the selected profile while presenting through
 * EDID, and system mode can restore KWin handling without another file pick.
 */
static bool kwin_set_profile_source(const KWinOutputState *output, bool system_mode)
{
    char argument[256];
    const char *source;
    pid_t child;
    int status = 0;
    if (!output || !kwin_safe_connector(output->connector)) return false;
    if (output->hdr) {
        if (!output->hdr_icc_path[0]) return system_mode;
        source = system_mode ? "ICC" : "EDID";
        SDL_snprintf(argument, sizeof(argument),
                     "output.%s.hdrColorProfileSource.%s",
                     output->connector, source);
    } else {
        if (!output->icc_path[0]) return system_mode;
        source = system_mode ? "ICC" : "sRGB";
        SDL_snprintf(argument, sizeof(argument),
                     "output.%s.colorProfileSource.%s",
                     output->connector, source);
    }
    child = fork();
    if (child < 0) return false;
    if (child == 0) {
        int null_fd = open("/dev/null", O_WRONLY);
        if (null_fd >= 0) {
            dup2(null_fd, STDOUT_FILENO);
            dup2(null_fd, STDERR_FILENO);
            close(null_fd);
        }
        execlp("kscreen-doctor", "kscreen-doctor", argument, (char *)NULL);
        _exit(127);
    }
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) return false;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) return false;
    SDL_strlcpy(app.linux_profile_connector, output->connector,
                sizeof(app.linux_profile_connector));
    app.linux_profile_hdr = output->hdr;
    app.linux_forced_profile_passthrough = !system_mode;
    return true;
}

static void kwin_restore_profile_source(void)
{
    KWinOutputState output;
    if (!app.linux_forced_profile_passthrough) return;
    if (!kwin_output_state(app.selected_display_id, &output)) {
        SDL_zero(output);
        SDL_strlcpy(output.connector, app.linux_profile_connector,
                    sizeof(output.connector));
        output.hdr = app.linux_profile_hdr;
        if (output.hdr)
            SDL_strlcpy(output.hdr_icc_path, "assigned",
                        sizeof(output.hdr_icc_path));
        else
            SDL_strlcpy(output.icc_path, "assigned", sizeof(output.icc_path));
    }
    (void)kwin_set_profile_source(&output, true);
}

static uint32_t kwin_hdr_surface_reference(SDL_DisplayID display)
{
    KWinOutputState output;
    double reference;
    if (!kwin_output_state(display, &output) || output.sdr_brightness <= 0)
        return 203;
    /* The Wayland image description specifies reference luminance in cd/m2.
     * Desktop scale changes logical geometry only and must never alter the
     * absolute luminance represented by a PQ surface. */
    reference = output.sdr_brightness;
    if (reference < 1.0) reference = 1.0;
    if (reference > 10000.0) reference = 10000.0;
    SDL_Log("KWin HDR reference: SDR white %d, surface reference %.0f",
            output.sdr_brightness, reference);
    return (uint32_t)lround(reference);
}
#endif

#ifdef __APPLE__
/* What ColorSync says about the display the patches land on.
 *
 * SDL does not expose the CGDirectDisplayID behind one of its displays, so the
 * SDL bounds rectangle is matched against CoreGraphics' global display bounds;
 * both are top-left-origin desktop coordinates. macOS keeps one profile
 * assignment per display - there is no separate SDR/HDR slot to choose
 * between the way Plasma 6.7 has. */
static CGDirectDisplayID macos_direct_display_id(SDL_DisplayID display)
{
    SDL_Rect bounds;
    CGDirectDisplayID matched[16];
    uint32_t count = 0;
    if (!display || !SDL_GetDisplayBounds(display, &bounds)) return 0;
    if (CGGetDisplaysWithRect(CGRectMake(bounds.x, bounds.y, bounds.w, bounds.h),
                              (uint32_t)SDL_arraysize(matched), matched,
                              &count) != kCGErrorSuccess || count < 1) return 0;
    return matched[0];
}

static bool macos_active_profile(SDL_DisplayID display, char *output,
                                 size_t output_size, char *profile_path,
                                 size_t profile_path_size)
{
    CGDirectDisplayID display_id = macos_direct_display_id(display);
    ColorSyncProfileRef profile;
    CFURLRef url;
    output[0] = '\0';
    profile_path[0] = '\0';
    if (!display_id) return false;
    profile = ColorSyncProfileCreateWithDisplayID(display_id);
    if (!profile) return false;
    url = ColorSyncProfileGetURL(profile, NULL);
    if (url && CFURLGetFileSystemRepresentation(url, true, (UInt8 *)profile_path,
                                                (CFIndex)profile_path_size)) {
        const char *base = strrchr(profile_path, '/');
        SDL_strlcpy(output, base ? base + 1 : profile_path, output_size);
    } else {
        /* A factory profile can be generated in memory with no file behind
         * it. Report its description so the status stays meaningful; the
         * empty path makes the explicit correction modes report not-ready
         * instead of evaluating the wrong file. */
        CFStringRef description = ColorSyncProfileCopyDescriptionString(profile);
        profile_path[0] = '\0';
        if (description) {
            if (!CFStringGetCString(description, output, (CFIndex)output_size,
                                    kCFStringEncodingUTF8)) output[0] = '\0';
            CFRelease(description);
        }
    }
    CFRelease(profile);
    return output[0] != '\0';
}
#endif

static bool update_renderer_hdr_state(void)
{
    SDL_PropertiesID renderer_props;
    SDL_Colorspace output_colorspace;
    float sdr_white_scale = 1.0f;

#ifdef _WIN32
    if (app.hdr_swapchain) {
        app.hdr_active = windows_window_hdr_enabled(app.window);
        app.hdr_sdr_white_scale = 1.0f;
        return true;
    }
#endif
    if (!app.renderer) return false;
    renderer_props = SDL_GetRendererProperties(app.renderer);
    if (!renderer_props) return false;
    output_colorspace = (SDL_Colorspace)SDL_GetNumberProperty(
        renderer_props, SDL_PROP_RENDERER_OUTPUT_COLORSPACE_NUMBER,
        SDL_COLORSPACE_SRGB);
    app.hdr_active = SDL_GetBooleanProperty(renderer_props, SDL_PROP_RENDERER_HDR_ENABLED_BOOLEAN, false);
#ifdef _WIN32
    /* SDL derives this flag from its dynamic HDR-headroom property. Some
     * Windows drivers leave that property at 1.0 even while DWM is actively
     * presenting the selected monitor in the HDR10 output colorspace. DXGI's
     * output description reflects the actual monitor pipeline in that case. */
    if (app.hdr && !app.hdr_active && windows_window_hdr_enabled(app.window))
        app.hdr_active = true;
#elif defined(__APPLE__)
    /* Metal EDR keeps presenting through the same linear surface in both
     * modes, so unlike the other platforms there is no PQ output colorspace
     * to double-check - only that the linear surface was actually granted. */
    if (app.hdr && output_colorspace != SDL_COLORSPACE_SRGB_LINEAR) {
        SDL_SetError("Renderer %s returned colorspace 0x%08x instead of linear EDR",
                     app.renderer_name[0] ? app.renderer_name : "unknown",
                     (unsigned int)output_colorspace);
        app.hdr_active = false;
        return false;
    }
    if (app.hdr && !app.hdr_active) {
        /* Same gap as the other platforms: SDL derives its flag from the
         * display's EDR headroom and can lag a brightness or reference-mode
         * change, so the window's current headroom settles it. */
        float headroom = SDL_GetFloatProperty(
            SDL_GetWindowProperties(app.window),
            SDL_PROP_WINDOW_HDR_HEADROOM_FLOAT, 0.0f);
        if (isfinite((double)headroom) && headroom > 1.0f) app.hdr_active = true;
    }
#else
    /* Same gap, other compositor. KWin does not always report HDR back to a
     * client through the colour-management protocol, so SDL's flag can stay
     * false while the panel is genuinely being driven in HDR - the Companion
     * then reported "HDR inactive" for a display KWin lists as HDR: enabled.
     * The compositor's own view of the output settles it. */
    if (app.hdr && output_colorspace != SDL_COLORSPACE_HDR10) {
        SDL_SetError("Renderer %s returned colorspace 0x%08x instead of HDR10 PQ",
                     app.renderer_name[0] ? app.renderer_name : "unknown",
                     (unsigned int)output_colorspace);
        app.hdr_active = false;
        return false;
    }
    if (app.hdr && !app.hdr_active) {
        KWinOutputState output;
        if (kwin_output_state(app.selected_display_id, &output) && output.hdr)
            app.hdr_active = true;
    }
#endif
    if (app.hdr) {
        sdr_white_scale = SDL_GetFloatProperty(renderer_props, SDL_PROP_RENDERER_SDR_WHITE_POINT_FLOAT, 1.0f);
        if (!isfinite(sdr_white_scale) || sdr_white_scale <= 0.0f) sdr_white_scale = 1.0f;
    }
    app.hdr_sdr_white_scale = sdr_white_scale;

    /* Native HDR10 pixels are already PQ/BT.2020. Do not apply scRGB white
     * scaling or any other local transfer-function adjustment. */
    return SDL_SetRenderColorScale(app.renderer, 1.0f);
}

static void destroy_renderer(void)
{
#ifdef _WIN32
    windows_destroy_hdr_output();
#endif
    if (app.texture) { SDL_DestroyTexture(app.texture); app.texture = NULL; }
    if (app.background_texture) { SDL_DestroyTexture(app.background_texture); app.background_texture = NULL; }
    for (int face = 0; face < PGEN_FACE_COUNT; face++) app.font_texture[face] = NULL;
    if (app.renderer) { SDL_DestroyRenderer(app.renderer); app.renderer = NULL; }
}

static SDL_Texture *create_patch_texture(bool hdr)
{
    SDL_PropertiesID props = SDL_CreateProperties();
    SDL_Texture *texture;
    if (!props) return NULL;
#ifdef __APPLE__
    /* Both modes stream float pixels here: HDR patches arrive at the texture
     * already decoded to linear EDR values, so the packed HDR10 layout is
     * never used and the linear values pass to the linear surface untouched.
     * The texture headroom is left undeclared so SDL never adds its optional
     * tone-mapping pass on top. */
    SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_FORMAT_NUMBER,
                          SDL_PIXELFORMAT_RGBA128_FLOAT);
#else
    SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_FORMAT_NUMBER,
                          hdr ? SDL_PIXELFORMAT_ABGR2101010 : SDL_PIXELFORMAT_RGBA128_FLOAT);
#endif
    SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_ACCESS_NUMBER, SDL_TEXTUREACCESS_STREAMING);
    SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_WIDTH_NUMBER, 1);
    SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_HEIGHT_NUMBER, 1);
    if (hdr) {
#ifdef __APPLE__
        SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_COLORSPACE_NUMBER, SDL_COLORSPACE_SRGB_LINEAR);
#else
        SDL_PropertiesID renderer_props = SDL_GetRendererProperties(app.renderer);
        float output_headroom = SDL_GetFloatProperty(
            renderer_props, SDL_PROP_RENDERER_HDR_HEADROOM_FLOAT, 1.0f);
        if (!isfinite(output_headroom) || output_headroom <= 0.0f) output_headroom = 1.0f;
        SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_COLORSPACE_NUMBER, SDL_COLORSPACE_HDR10);
        /* Match the source metadata to the active output headroom. This keeps
         * SDL's required HDR10-to-scRGB transport conversion but disables its
         * optional source-to-display tone-mapping pass. */
        SDL_SetFloatProperty(props, SDL_PROP_TEXTURE_CREATE_HDR_HEADROOM_FLOAT, output_headroom);
#endif
    } else {
        SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_COLORSPACE_NUMBER, SDL_COLORSPACE_SRGB_LINEAR);
    }
    texture = SDL_CreateTextureWithProperties(app.renderer, props);
    SDL_DestroyProperties(props);
    return texture;
}

/* Windows presents HDR through its own swapchain, so the SDL renderer there
 * keeps the scRGB-linear surface it has always used and the D3D path is
 * untouched. Everywhere else the SDL renderer IS the HDR output, and it has to
 * carry PQ because that is what the patch values are. */
static SDL_Colorspace colorspace_for_hdr(void)
{
#ifdef _WIN32
    return SDL_COLORSPACE_SRGB_LINEAR;
#elif defined(__APPLE__)
    /* Metal's EDR path is a linear extended-range surface; the PQ decode to
     * linear light happens in patch_to_edr_linear before upload. */
    return SDL_COLORSPACE_SRGB_LINEAR;
#else
    return SDL_COLORSPACE_HDR10;
#endif
}

static bool try_create_renderer(bool hdr, const char *driver)
{
    SDL_PropertiesID props;
    uint64_t hdr_deadline;
    destroy_renderer();
    props = SDL_CreateProperties();
    if (!props) return false;
    SDL_SetPointerProperty(props, SDL_PROP_RENDERER_CREATE_WINDOW_POINTER, app.window);
    SDL_SetNumberProperty(props, SDL_PROP_RENDERER_CREATE_PRESENT_VSYNC_NUMBER, 1);
    /* Ask for a real PQ surface, not a linear one.
     *
     * Patch values are already PQ/BT.2020 - the Windows path presents them
     * through an HDR10 swapchain and hands them over untouched. Requesting
     * SDL_COLORSPACE_SRGB_LINEAR here instead meant PQ codes were written into
     * a LINEAR surface, so the ladder came out roughly twenty times too bright
     * and clipped at the panel's peak from about 38% stimulus upward - two
     * thirds of a greyscale measuring the same luminance.
     *
     * SDL_COLORSPACE_HDR10 is the same colorspace the Windows swapchain uses
     * (DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020), and SDL tags the Wayland
     * surface with it through the colour-management protocol, so KWin knows
     * the content is PQ and passes it through rather than reinterpreting it.
     * Not every backend offers it - SDL's "gpu" renderer refuses it outright -
     * so the caller's driver preference decides, and create_renderer falls
     * back to linear only if nothing can present PQ. */
    SDL_SetNumberProperty(props, SDL_PROP_RENDERER_CREATE_OUTPUT_COLORSPACE_NUMBER,
                          hdr ? colorspace_for_hdr() : SDL_COLORSPACE_SRGB);
    if (driver) SDL_SetStringProperty(props, SDL_PROP_RENDERER_CREATE_NAME_STRING, driver);
    app.renderer = SDL_CreateRendererWithProperties(props);
    SDL_DestroyProperties(props);
    if (!app.renderer) return false;
    app.hdr = hdr;
#if !defined(_WIN32) && !defined(__APPLE__)
    /* The Vulkan swapchain uses VK_COLOR_SPACE_PASS_THROUGH_EXT on Wayland,
     * leaving this application as the sole owner of the surface description.
     * Attach BT.2020/PQ before the first frame reaches KWin. */
    if (!pgen_wayland_set_hdr_surface(
            app.window, hdr,
            hdr && (!strcmp(app.correction_mode, "clut") ||
                    !strcmp(app.correction_mode, "matrix")),
            hdr ? kwin_hdr_surface_reference(app.selected_display_id) : 0,
            app.command_min_luma, app.command_max_luma,
            app.command_max_cll, app.command_max_fall)) {
        destroy_renderer();
        return false;
    }
#endif
    {
        SDL_PropertiesID renderer_props = SDL_GetRendererProperties(app.renderer);
        const char *name = SDL_GetStringProperty(renderer_props, SDL_PROP_RENDERER_NAME_STRING, "unknown");
        SDL_strlcpy(app.renderer_name, name, sizeof(app.renderer_name));
    }
    if (!update_renderer_hdr_state()) {
        destroy_renderer();
        return false;
    }
    SDL_SetRenderDrawColorFloat(app.renderer, 0, 0, 0, 1);
    if (!SDL_RenderClear(app.renderer) || !SDL_RenderPresent(app.renderer)) {
        destroy_renderer();
        return false;
    }
    if (hdr) {
        /* On Windows the swapchain's Advanced Color state may not be exposed
         * until its first scRGB frame has been presented. Checking the HDR
         * property before that frame falsely rejects an HDR-enabled desktop.
         * Wayland/KWin can also lag a bit after fullscreen + first present.
         * Give the compositor time to publish the dynamic HDR state. */
        hdr_deadline = SDL_GetTicks() + 2500;
        do {
            SDL_PumpEvents();
            if (!update_renderer_hdr_state()) {
                destroy_renderer();
                return false;
            }
            if (app.hdr_active) break;
            SDL_Delay(20);
        } while (SDL_GetTicks() < hdr_deadline);
        if (!app.hdr_active) {
#ifdef __APPLE__
            /* On Apple displays the EDR headroom shrinks as the SDR
             * brightness rises; at full brightness there is none left. */
            SDL_SetError(
                "The renderer did not enter HDR after its first presented frame "
                "(driver=%s). macOS reports no EDR headroom for this display: "
                "lower the display brightness or select a High Dynamic Range "
                "preset in System Settings > Displays, then try again.",
                app.renderer_name[0] ? app.renderer_name : (driver ? driver : "default"));
#else
            SDL_SetError(
                "The scRGB renderer did not enter HDR after its first presented frame "
                "(driver=%s). On Linux install a working Vulkan stack "
                "(vulkan-loader + mesa-vulkan-drivers or the vendor Vulkan package) "
                "and enable HDR for this display in Plasma.",
                app.renderer_name[0] ? app.renderer_name : (driver ? driver : "default"));
#endif
            destroy_renderer();
            return false;
        }
    }
    app.texture = create_patch_texture(hdr);
    if (!app.texture) {
        destroy_renderer();
        return false;
    }
    app.background_texture = create_patch_texture(hdr);
    if (!app.background_texture) {
        destroy_renderer();
        return false;
    }
    SDL_SetTextureScaleMode(app.texture, SDL_SCALEMODE_NEAREST);
    SDL_SetTextureScaleMode(app.background_texture, SDL_SCALEMODE_NEAREST);
    return true;
}

/* A failed HDR attempt is expensive: forced fullscreen, per-driver probes
 * with multi-second waits, swapchain creation and teardown. The server keeps
 * requesting patches while the condition persists (HDR disabled in the
 * desktop, dead GPU stack), and retrying the whole gauntlet for every
 * request pegs a core and can leak per attempt. Fail fast from the cached
 * error during a cooldown; an HDR state change event clears it so enabling
 * HDR in the desktop settings retries immediately. */
static Uint64 hdr_attempt_cooldown_until;
static char hdr_attempt_cached_error[512];

static bool create_renderer(bool hdr)
{
#ifndef _WIN32
#ifdef __APPLE__
    /* Metal is the only SDL backend that presents EDR on macOS. NULL stays
     * last so a stack without it still gets SDL's default attempt. */
    const char *hdr_drivers[] = { "metal", NULL };
#else
    /* Prefer Vulkan (the path proven on Kubuntu/KDE Wayland). Then SDL's GPU
     * backend, then the platform default. NULL must stay last. */
    const char *hdr_drivers[] = { "vulkan", "gpu", NULL };
#endif
    size_t index;
    char attempt_error[256];
#endif
    char last_error[512] = "";

    if (!hdr) return try_create_renderer(false, NULL);
    if (hdr_attempt_cooldown_until &&
        SDL_GetTicks() < hdr_attempt_cooldown_until) {
        return SDL_SetError("%s", hdr_attempt_cached_error[0]
                            ? hdr_attempt_cached_error
                            : "HDR renderer unavailable");
    }
#ifdef _WIN32
    destroy_renderer();
    if (windows_create_hdr_output()) {
        hdr_attempt_cooldown_until = 0;
        return true;
    }
    SDL_strlcpy(last_error, SDL_GetError(), sizeof(last_error));
#else
#ifndef __APPLE__
    /* KWin only exposes an HDR-capable surface for some clients after the
     * window is fullscreen on an HDR output. Attempt that before creating the
     * scRGB renderer so SDL_PROP_RENDERER_HDR_ENABLED_BOOLEAN can become true.
     * Metal EDR has no such precondition, so macOS skips the forced
     * fullscreen and leaves window mode to the WebUI setting. */
    {
        SDL_WindowFlags flags = SDL_GetWindowFlags(app.window);
        if ((flags & SDL_WINDOW_FULLSCREEN) == 0) {
            (void)SDL_SetWindowFullscreenMode(app.window, NULL);
            if (SDL_SetWindowFullscreen(app.window, true)) {
                app.fullscreen = true;
                SDL_SyncWindow(app.window);
                SDL_PumpEvents();
                SDL_Delay(50);
            }
        }
        SDL_ShowWindow(app.window);
        SDL_RaiseWindow(app.window);
    }
#endif
    for (index = 0; index < SDL_arraysize(hdr_drivers); index++) {
        const char *driver = hdr_drivers[index];
        char attempt_summary[320];
        if (try_create_renderer(true, driver)) {
            hdr_attempt_cooldown_until = 0;
            return true;
        }
        attempt_error[0] = '\0';
        if (SDL_GetError() && SDL_GetError()[0])
            SDL_strlcpy(attempt_error, SDL_GetError(), sizeof(attempt_error));
        else
            SDL_strlcpy(attempt_error, "create failed", sizeof(attempt_error));
        SDL_snprintf(attempt_summary, sizeof(attempt_summary), "%s: %s",
                     driver && driver[0] ? driver : "default", attempt_error);
        SDL_Log("Native HDR renderer attempt failed: %s", attempt_summary);
        if (last_error[0]) SDL_strlcat(last_error, "; ", sizeof(last_error));
        SDL_strlcat(last_error, attempt_summary, sizeof(last_error));
    }
#endif

    /* Keep the alignment target usable after an HDR failure, while preserving
     * the failure result so the server does not measure an SDR fallback. */
    try_create_renderer(false, NULL);
    if (app.renderer) render_alignment();
    SDL_SetError("HDR renderer unavailable: %s",
                 last_error[0] ? last_error : "No HDR renderer was available");
    SDL_strlcpy(hdr_attempt_cached_error, SDL_GetError(),
                sizeof(hdr_attempt_cached_error));
    hdr_attempt_cooldown_until = SDL_GetTicks() + 5000;
    return false;
}

static bool render_alignment(void)
{
    int width, height;
    float center_x, center_y, extent, arm;
#ifdef _WIN32
    if (app.hdr_swapchain) {
        SDL_FRect horizontal, vertical;
        const double alignment_white_pq = 0.5080784215; /* 100 cd/m2 */
        float black[4] = {0.0f, 0.0f, 0.0f, 1.0f};
        float white[4] = {(float)alignment_white_pq, (float)alignment_white_pq,
                          (float)alignment_white_pq, 1.0f};
        D3D11_RECT rects[2];
        if (!SDL_GetWindowSizeInPixels(app.window, &width, &height)) return false;
        center_x = (float)width * 0.5f;
        center_y = (float)height * 0.5f;
        extent = (float)(width < height ? width : height);
        arm = fmaxf(48.0f, extent * 0.12f);
        horizontal.x = center_x - arm; horizontal.y = center_y - 1.0f;
        horizontal.w = arm * 2.0f; horizontal.h = 3.0f;
        vertical.x = center_x - 1.0f; vertical.y = center_y - arm;
        vertical.w = 3.0f; vertical.h = arm * 2.0f;
        rects[0].left = (LONG)horizontal.x; rects[0].top = (LONG)horizontal.y;
        rects[0].right = (LONG)(horizontal.x + horizontal.w);
        rects[0].bottom = (LONG)(horizontal.y + horizontal.h);
        rects[1].left = (LONG)vertical.x; rects[1].top = (LONG)vertical.y;
        rects[1].right = (LONG)(vertical.x + vertical.w);
        rects[1].bottom = (LONG)(vertical.y + vertical.h);
        if (!windows_hdr_render_target(width, height)) return false;
        ID3D11DeviceContext_ClearRenderTargetView(app.hdr_context,
                                                  app.hdr_render_target, black);
        ID3D11DeviceContext1_ClearView(app.hdr_context1,
                                      (ID3D11View *)app.hdr_render_target,
                                      white, rects, 2);
        if (FAILED(IDXGISwapChain_Present(app.hdr_swapchain, 1, 0))) return false;
        app.alignment = true;
        return true;
    }
#endif
    if (!app.renderer || !SDL_GetCurrentRenderOutputSize(app.renderer, &width, &height)) return false;
    center_x = (float)width * 0.5f;
    center_y = (float)height * 0.5f;
    extent = (float)(width < height ? width : height);
    arm = fmaxf(48.0f, extent * 0.12f);

    for (int frame = 0; frame < 3; frame++) {
        SDL_SetRenderDrawColorFloat(app.renderer, 0.0f, 0.0f, 0.0f, 1.0f);
        if (!SDL_RenderClear(app.renderer)) return false;
        SDL_SetRenderDrawColorFloat(app.renderer, 1.0f, 1.0f, 1.0f, 1.0f);
        for (int offset = -1; offset <= 1; offset++) {
            if (!SDL_RenderLine(app.renderer, center_x - arm, center_y + (float)offset,
                               center_x + arm, center_y + (float)offset) ||
                !SDL_RenderLine(app.renderer, center_x + (float)offset, center_y - arm,
                               center_x + (float)offset, center_y + arm)) return false;
        }
        SDL_RenderPresent(app.renderer);
    }
    app.alignment = true;
    return true;
}

static bool render_patch(const char *mode, double r, double g, double b)
{
    float pixel[4], background[4];
#ifndef __APPLE__
    uint32_t hdr_pixel, hdr_background;
#endif
    SDL_FRect destination;
    int width, height, patch_size, window_percent;
    double background_signal = 0.0;
    bool hdr = !strcmp(mode, "hdr10");
    bool renderer_ready = app.renderer != NULL;
#ifdef _WIN32
    renderer_ready = renderer_ready || app.hdr_swapchain != NULL;
#endif
    if (!renderer_ready || hdr != app.hdr) {
        if (!create_renderer(hdr)) return false;
    }
    patch_size = app.displayed_size > 0 ? app.displayed_size : 100;
    window_percent = patch_size;
    if (patch_size > 100 && patch_size < 199) {
        double foreground_luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        double target_apl = (patch_size - 100) / 100.0;
        window_percent = 10;
        background_signal = (target_apl - foreground_luma * 0.10) / 0.90;
        background_signal = fmax(0.0, fmin(1.0, background_signal));
    }
    if (hdr) {
#ifdef _WIN32
        if (app.hdr_swapchain) {
            if (!SDL_GetWindowSizeInPixels(app.window, &width, &height)) return false;
            destination.x = 0.0f;
            destination.y = 0.0f;
            destination.w = (float)width;
            destination.h = (float)height;
            if (app.fullscreen && window_percent < 100) {
                float scale = sqrtf(fmaxf(0.0f, (float)window_percent / 100.0f));
                destination.w = width * scale;
                destination.h = height * scale;
                destination.x = (width - destination.w) * 0.5f;
                destination.y = (height - destination.h) * 0.5f;
            }
            if (!windows_render_hdr(r, g, b, background_signal, &destination)) return false;
            app.alignment = false;
            app.displayed_r = r;
            app.displayed_g = g;
            app.displayed_b = b;
            SDL_strlcpy(app.displayed_mode, mode, sizeof(app.displayed_mode));
            return true;
        }
#endif
#ifdef __APPLE__
        /* The Metal EDR surface is linear, not PQ, so the PQ codes are decoded
         * to light here rather than preserved; see patch_to_edr_linear for the
         * mapping and its assumptions. */
        patch_to_edr_linear(r, g, b, pixel);
        patch_to_edr_linear(background_signal, background_signal, background_signal, background);
        if (!SDL_UpdateTexture(app.texture, NULL, pixel, (int)sizeof(pixel))) return false;
        if (!SDL_UpdateTexture(app.background_texture, NULL, background, (int)sizeof(background))) return false;
#else
        /* PGenerator+ sends normalized HDR10 code values. Preserve them as
         * native 10-bit PQ/BT.2020 pixels without local PQ or roll-off math. */
        hdr_pixel = patch_to_hdr10(r, g, b);
        hdr_background = patch_to_hdr10(background_signal, background_signal, background_signal);
        if (!SDL_UpdateTexture(app.texture, NULL, &hdr_pixel, (int)sizeof(hdr_pixel))) return false;
        if (!SDL_UpdateTexture(app.background_texture, NULL, &hdr_background, (int)sizeof(hdr_background))) return false;
#endif
    } else {
        patch_to_sdr_linear(r, g, b, pixel);
        patch_to_sdr_linear(background_signal, background_signal, background_signal, background);
        if (!SDL_UpdateTexture(app.texture, NULL, pixel, (int)sizeof(pixel))) return false;
        if (!SDL_UpdateTexture(app.background_texture, NULL, background, (int)sizeof(background))) return false;
    }
    if (!SDL_GetCurrentRenderOutputSize(app.renderer, &width, &height)) return false;
    destination.x = 0.0f;
    destination.y = 0.0f;
    destination.w = (float)width;
    destination.h = (float)height;
    if (app.fullscreen && window_percent < 100) {
        float scale = sqrtf(fmaxf(0.0f, (float)window_percent / 100.0f));
        destination.w = width * scale;
        destination.h = height * scale;
        destination.x = (width - destination.w) * 0.5f;
        destination.y = (height - destination.h) * 0.5f;
    }
    for (int frame = 0; frame < 3; frame++) {
        if (!SDL_RenderTexture(app.renderer, app.background_texture, NULL, NULL)) return false;
        if (!SDL_RenderTexture(app.renderer, app.texture, NULL, &destination)) return false;
        SDL_RenderPresent(app.renderer);
    }
    app.alignment = false;
    app.displayed_r = r;
    app.displayed_g = g;
    app.displayed_b = b;
    SDL_strlcpy(app.displayed_mode, mode, sizeof(app.displayed_mode));
    return true;
}

static bool render_current_frame(void)
{
    if (app.alignment) return render_alignment();
    return render_patch(app.displayed_mode[0] ? app.displayed_mode : "sdr",
                        app.displayed_r, app.displayed_g, app.displayed_b);
}

#ifdef _WIN32
static bool windows_activate_pattern_window(HWND window);

static LRESULT CALLBACK windows_handoff_window_proc(HWND window, UINT message,
                                                     WPARAM wparam, LPARAM lparam)
{
    return DefWindowProcW(window, message, wparam, lparam);
}

static bool windows_presentation_handoff(HWND target)
{
    static const wchar_t class_name[] = L"PGeneratorPresentationHandoff";
    static ATOM window_class;
    HINSTANCE instance = GetModuleHandleW(NULL);
    MONITORINFO monitor_info;
    HMONITOR monitor;
    HWND cover;
    if (!target || !instance) return false;
    monitor = MonitorFromWindow(target, MONITOR_DEFAULTTONEAREST);
    ZeroMemory(&monitor_info, sizeof(monitor_info));
    monitor_info.cbSize = sizeof(monitor_info);
    if (!monitor || !GetMonitorInfoW(monitor, &monitor_info)) return false;
    if (!window_class) {
        WNDCLASSEXW window_class_info;
        ZeroMemory(&window_class_info, sizeof(window_class_info));
        window_class_info.cbSize = sizeof(window_class_info);
        window_class_info.lpfnWndProc = windows_handoff_window_proc;
        window_class_info.hInstance = instance;
        window_class_info.hCursor = LoadCursorW(NULL, IDC_ARROW);
        window_class_info.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
        window_class_info.lpszClassName = class_name;
        window_class = RegisterClassExW(&window_class_info);
        if (!window_class && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
            return false;
    }
    cover = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
                            class_name, L"", WS_POPUP,
                            monitor_info.rcMonitor.left,
                            monitor_info.rcMonitor.top,
                            monitor_info.rcMonitor.right - monitor_info.rcMonitor.left,
                            monitor_info.rcMonitor.bottom - monitor_info.rcMonitor.top,
                            NULL, NULL, instance, NULL);
    if (!cover) return false;
    ShowWindow(cover, SW_SHOW);
    UpdateWindow(cover);
    SetWindowPos(cover, HWND_TOPMOST, monitor_info.rcMonitor.left,
                 monitor_info.rcMonitor.top,
                 monitor_info.rcMonitor.right - monitor_info.rcMonitor.left,
                 monitor_info.rcMonitor.bottom - monitor_info.rcMonitor.top,
                 SWP_SHOWWINDOW);
    SetForegroundWindow(cover);
    SetActiveWindow(cover);
    SetFocus(cover);
    SDL_Delay(500);
    DestroyWindow(cover);
    windows_activate_pattern_window(target);
    SDL_Delay(500);
    return true;
}

static bool windows_activate_pattern_window(HWND window)
{
    HWND foreground;
    DWORD current_thread, foreground_thread = 0;
    bool attached = false;
    BOOL foreground_result;
    if (!window) return false;

    /* A topmost window is not necessarily the foreground/active window.
     * Windows and the NVIDIA driver can keep an exact-monitor HDR swapchain
     * in the dim desktop-composition policy until it receives a genuine
     * foreground activation. SetForegroundWindow alone is routinely denied
     * for remotely driven patches because the Companion did not receive the
     * most recent user input. Temporarily join the foreground input queue so
     * the activation is honored, matching the state produced by Alt-Tabbing
     * back to the Companion. */
    foreground = GetForegroundWindow();
    current_thread = GetCurrentThreadId();
    if (foreground && foreground != window) {
        foreground_thread = GetWindowThreadProcessId(foreground, NULL);
        if (foreground_thread && foreground_thread != current_thread)
            attached = AttachThreadInput(current_thread, foreground_thread, TRUE) != FALSE;
    }
    ShowWindow(window, SW_RESTORE);
    SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
    BringWindowToTop(window);
    foreground_result = SetForegroundWindow(window);
    SetActiveWindow(window);
    SetFocus(window);
    if (attached)
        AttachThreadInput(current_thread, foreground_thread, FALSE);
    return foreground_result != FALSE || GetForegroundWindow() == window;
}

static bool windows_set_borderless_windowed(bool fullscreen)
{
    if (fullscreen) {
        SDL_Rect bounds;
        SDL_DisplayID display = SDL_GetDisplayForWindow(app.window);
        if (!display || !SDL_GetDisplayBounds(display, &bounds)) return false;
        if (!app.windowed_geometry_valid) {
            if (!SDL_GetWindowPosition(app.window, &app.windowed_x, &app.windowed_y) ||
                !SDL_GetWindowSize(app.window, &app.windowed_width,
                                   &app.windowed_height)) return false;
            app.windowed_geometry_valid = true;
        }
        /* Cover every physical pixel. Leaving even one desktop pixel visible
         * creates a lit perimeter on this HDR desktop and can change an OLED's
         * ABL response during full-field measurements. Presentation recovery
         * is handled by the explicit foreground handoff, not by shrinking the
         * measurement surface. */
        if (!SDL_SetWindowBordered(app.window, false) ||
            !SDL_SetWindowResizable(app.window, false) ||
            !SDL_SetWindowPosition(app.window, bounds.x, bounds.y) ||
            !SDL_SetWindowSize(app.window, bounds.w, bounds.h) ||
            !SDL_SyncWindow(app.window)) return false;
    } else if (app.windowed_geometry_valid) {
        if (!SDL_SetWindowBordered(app.window, true) ||
            !SDL_SetWindowResizable(app.window, true) ||
            !SDL_SetWindowPosition(app.window, app.windowed_x, app.windowed_y) ||
            !SDL_SetWindowSize(app.window, app.windowed_width,
                               app.windowed_height) ||
            !SDL_SyncWindow(app.window)) return false;
        app.windowed_geometry_valid = false;
    }
    app.fullscreen = fullscreen;
    return true;
}
#endif

static void raise_pattern_window(void)
{
    SDL_SetWindowAlwaysOnTop(app.window, app.fullscreen);
    SDL_ShowWindow(app.window);
    SDL_RaiseWindow(app.window);
#ifdef _WIN32
    if (app.fullscreen) {
        HWND window = (HWND)SDL_GetPointerProperty(
            SDL_GetWindowProperties(app.window),
            SDL_PROP_WINDOW_WIN32_HWND_POINTER, NULL);
        if (window) {
            windows_activate_pattern_window(window);
        }
    }
#endif
}

#ifdef _WIN32
static bool windows_verified_foreground(bool force_cycle)
{
    /* SetForegroundWindow is denied to background processes and the failure
     * is silent: after the Profile Loader runs, the fullscreen HDR window can
     * stay under the desktop's dim composed policy and every mid-band read
     * sags 12-17%. A window restored from minimize is granted genuine
     * foreground, mirroring the manual minimize/restore that recovers the
     * bench. Verify with GetForegroundWindow and retry a bounded number of
     * times rather than trusting the activation call. */
    HWND window;
    if (!app.fullscreen || !app.window) return false;
    window = (HWND)SDL_GetPointerProperty(SDL_GetWindowProperties(app.window),
                                          SDL_PROP_WINDOW_WIN32_HWND_POINTER, NULL);
    if (!window) return false;
    for (int attempt = 0;
         attempt < 3 && (force_cycle || GetForegroundWindow() != window);
         attempt++) {
        ShowWindow(window, SW_MINIMIZE);
        SDL_Delay(250);
        ShowWindow(window, SW_RESTORE);
        SDL_Delay(250);
        windows_activate_pattern_window(window);
        SDL_Delay(250);
        force_cycle = false;
    }
    return GetForegroundWindow() == window;
}
#endif

static bool apply_display_settings(bool fullscreen, int patch_size)
{
#ifndef _WIN32
    SDL_WindowFlags flags;
#endif
    if (patch_size < 1 || patch_size > 198) patch_size = 100;
#ifdef _WIN32
    if (app.fullscreen != fullscreen &&
        !windows_set_borderless_windowed(fullscreen)) return false;
#else
    flags = SDL_GetWindowFlags(app.window);
    app.fullscreen = (flags & SDL_WINDOW_FULLSCREEN) != 0;
    if (app.fullscreen != fullscreen) {
        /* Fullscreen changes are asynchronous on Windows. Accept a successful
         * request here and let the enter/leave event confirm the final state. */
        if (fullscreen) {
            if (!SDL_SetWindowFullscreenMode(app.window, NULL)) return false;
        }
        if (!SDL_SetWindowFullscreen(app.window, fullscreen)) return false;
        app.fullscreen = fullscreen;
    }
#endif
    app.displayed_size = patch_size;
    raise_pattern_window();
    return render_current_frame();
}

static void queue_status(const char *text);

#ifdef _WIN32
typedef struct {
    HANDLE previous_output;
    HANDLE previous_error;
    bool allocated;
    bool active;
} CompanionBuildConsole;

static bool companion_build_console_open(CompanionBuildConsole *console)
{
    static const char message[] =
        "\r\nPGenerator+ is building your ICC profile.\r\n"
        "This calculation was offloaded from PGenerator+.\r\n"
        "Please do not close this window. It will close automatically when the build finishes.\r\n\r\n";
    HANDLE output;
    DWORD written = 0;

    memset(console, 0, sizeof(*console));
    console->previous_output = GetStdHandle(STD_OUTPUT_HANDLE);
    console->previous_error = GetStdHandle(STD_ERROR_HANDLE);
    if (GetConsoleWindow() == NULL) {
        if (!AllocConsole()) return false;
        console->allocated = true;
    }
    console->active = true;
    SetConsoleTitleA("PGenerator+ ICC Profile Build");
    output = GetStdHandle(STD_OUTPUT_HANDLE);
    if (output != NULL && output != INVALID_HANDLE_VALUE)
        WriteFile(output, message, (DWORD)(sizeof(message) - 1), &written, NULL);
    return true;
}

static void companion_build_console_close(CompanionBuildConsole *console)
{
    if (!console->active) return;
    if (console->allocated) {
        FreeConsole();
        SetStdHandle(STD_OUTPUT_HANDLE, console->previous_output);
        SetStdHandle(STD_ERROR_HANDLE, console->previous_error);
    }
    console->active = false;
}
#endif

/* Tell the generator the fit failed so it falls back to its own colprof
 * instead of waiting out the build timeout. */
static void companion_report_build_error(const char *reason)
{
    char path[768];
    char escaped[240];
    size_t out = 0, index;
    for (index = 0; reason[index] && out + 4 < sizeof(escaped); index++) {
        char c = reason[index];
        if (c == ' ') { escaped[out++] = '+'; continue; }
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
            c == '.' || c == '_' || c == '-') { escaped[out++] = c; continue; }
    }
    escaped[out] = '\0';
    SDL_snprintf(path, sizeof(path), "/api/icc/companion/build-result?token=%s&error=%s",
                 app.config.token, escaped);
    http_binary(&app.config, "POST", path, "text/plain", (const unsigned char *)"x", 1, NULL, NULL);
}

/* Run the profile fit the generator handed over.
 *
 * colprof is single-threaded and a high-quality cLUT fit is roughly ten
 * minutes on the generator against under a minute here, so the generator
 * offloads the fit when this Companion reports a matching ArgyllCMS. Only the
 * fit moves: the characterization, the MHC2/vcgt derivation and the ICC
 * rebuild all stay there. Any failure is reported so the generator falls back
 * to its own colprof rather than waiting out the timeout.
 */
/* Append one shell-quoted argument, separated by a space. Returns false when
   the destination is too small, so the caller can refuse the job rather than
   run colprof with a silently truncated argument list. */
static bool companion_quote_append(char *destination, size_t capacity, size_t *used, const char *argument)
{
    size_t out = *used;
    const char *cursor;

    if (out && out + 1 < capacity) destination[out++] = ' ';
#ifdef _WIN32
    /* cmd.exe: double quotes, and a literal quote cannot survive inside them. */
    if (out + 1 >= capacity) return false;
    destination[out++] = '"';
    for (cursor = argument; *cursor; cursor++) {
        char c = (*cursor == '"') ? '\'' : *cursor;
        if (out + 2 >= capacity) return false;
        destination[out++] = c;
    }
    if (out + 1 >= capacity) return false;
    destination[out++] = '"';
#else
    /* POSIX: single quotes take everything literally; close, escape, reopen. */
    if (out + 1 >= capacity) return false;
    destination[out++] = '\'';
    for (cursor = argument; *cursor; cursor++) {
        if (*cursor == '\'') {
            if (out + 5 >= capacity) return false;
            destination[out++] = '\'';
            destination[out++] = '\\';
            destination[out++] = '\'';
            destination[out++] = '\'';
            continue;
        }
        if (out + 2 >= capacity) return false;
        destination[out++] = *cursor;
    }
    if (out + 1 >= capacity) return false;
    destination[out++] = '\'';
#endif
    if (out >= capacity) return false;
    destination[out] = '\0';
    *used = out;
    return true;
}

static void companion_run_targen(const char *poll_response)
{
    char ti1_path[1200], base_path[1200], input_path[1200], tool[1024];
    char command[8192], flags[2048], directory[1024];
    unsigned char *input = NULL;
    size_t input_length = 0;
    FILE *handle;
    int status, attempt;
    bool built = false;
    bool precondition = strstr(poll_response, "\"precondition\":true") != NULL;

    if (!companion_targen_available() ||
        !companion_tool_path("targen", tool, sizeof(tool))) {
        companion_report_build_error("targen is not available in this Companion package");
        return;
    }
    flags[0] = '\0';
    {
        const char *start = strstr(poll_response, "\"flags\":[");
        if (start) {
            const char *end = strchr(start, ']');
            size_t length = end ? (size_t)(end - start - 9) : 0;
            if (length && length < sizeof(flags)) {
                memcpy(flags, start + 9, length);
                flags[length] = '\0';
            }
        }
    }
    {
        const char *base = SDL_GetPrefPath("PGeneratorPlus", "build");
        if (!base) {
            companion_report_build_error("could not create the chart work directory");
            return;
        }
        SDL_strlcpy(directory, base, sizeof(directory));
        SDL_snprintf(base_path, sizeof(base_path), "%schart", directory);
        SDL_snprintf(ti1_path, sizeof(ti1_path), "%schart.ti1", directory);
        SDL_snprintf(input_path, sizeof(input_path), "%sprecondition.icc", directory);
    }
    remove(ti1_path);
    remove(input_path);

    {   /* Fetching even an empty input claims the synchronous chart job. */
        char path[512];
        SDL_snprintf(path, sizeof(path),
                     "/api/icc/companion/build-input?token=%s", app.config.token);
        status = http_binary(&app.config, "GET", path, "application/octet-stream",
                             NULL, 0, &input, &input_length);
        if (status != 200) {
            if (input) SDL_free(input);
            companion_report_build_error("could not claim the chart generation job");
            return;
        }
    }
    if (precondition) {
        if (!input || input_length <= 128 || input_length > 64u * 1024u * 1024u ||
            memcmp(input + 36, "acsp", 4)) {
            if (input) SDL_free(input);
            companion_report_build_error("the preconditioning profile is invalid");
            return;
        }
        handle = fopen(input_path, "wb");
        if (!handle || fwrite(input, 1, input_length, handle) != input_length) {
            if (handle) fclose(handle);
            SDL_free(input);
            companion_report_build_error("could not stage the preconditioning profile");
            return;
        }
        fclose(handle);
    }
    if (input) SDL_free(input);

    {
        char cleaned[3072];
        size_t out = 0, index = 0;
        while (flags[index]) {
            char argument[1024];
            size_t length = 0;
            bool truncated = false;
            while (flags[index] == ' ' || flags[index] == ',') index++;
            if (flags[index] != '"') break;
            index++;
            while (flags[index] && flags[index] != '"') {
                char c = flags[index++];
                if (c == '\\' && flags[index]) c = flags[index++];
                if (length + 1 >= sizeof(argument)) { truncated = true; break; }
                argument[length++] = c;
            }
            if (truncated || flags[index] != '"') { out = 0; break; }
            index++;
            argument[length] = '\0';
            if (!companion_quote_append(cleaned, sizeof(cleaned), &out, argument)) {
                out = 0;
                break;
            }
        }
        if (!out) {
            companion_report_build_error("the chart arguments could not be read");
            remove(input_path);
            return;
        }
        cleaned[out] = '\0';
#ifdef _WIN32
        SDL_snprintf(command, sizeof(command),
                     "title PGenerator+ ICC Chart Generation & "
                     "echo. & echo PGenerator+ is optimizing the measurement chart. & "
                     "echo This calculation was offloaded from PGenerator+. & "
                     "echo Please do not close this window. It will close automatically when generation finishes. & "
                     "echo. & \"%s\" %s%s%s%s \"%s\"",
                     tool, cleaned,
                     precondition ? " -c \"" : "",
                     precondition ? input_path : "",
                     precondition ? "\"" : "", base_path);
#else
        SDL_snprintf(command, sizeof(command), "\"%s\" %s%s%s%s \"%s\"",
                     tool, cleaned,
                     precondition ? " -c \"" : "",
                     precondition ? input_path : "",
                     precondition ? "\"" : "", base_path);
#endif
    }
    queue_status("PGenerator+ Patch Companion | Optimizing ICC measurement chart...");
    /* OFPS occasionally exhausts one randomized layout while re-seeding.
     * A second invocation starts from a new layout and normally succeeds.
     * Retry here where the CPU work lives instead of falling back to the Pi
     * and presenting the last harmless "Re-seeding" progress line as the
     * cause of the failure. */
    for (attempt = 1; attempt <= 3 && !built; attempt++) {
        remove(ti1_path);
        if (attempt > 1)
            queue_status("PGenerator+ Patch Companion | Retrying ICC chart optimization...");
        status = system(command);
        (void)status;

        handle = fopen(ti1_path, "rb");
        if (handle) {
            long size;
            fseek(handle, 0, SEEK_END);
            size = ftell(handle);
            fseek(handle, 0, SEEK_SET);
            if (size > 32 && size < 64 * 1024 * 1024) {
                unsigned char *ti1 = (unsigned char *)SDL_malloc((size_t)size);
                if (ti1 && fread(ti1, 1, (size_t)size, handle) == (size_t)size) {
                    char path[512];
                    unsigned char *reply = NULL;
                    size_t reply_length = 0;
                    SDL_snprintf(path, sizeof(path),
                                 "/api/icc/companion/build-result?token=%s",
                                 app.config.token);
                    if (http_binary(&app.config, "POST", path,
                                    "application/octet-stream", ti1, (size_t)size,
                                    &reply, &reply_length) == 200 && reply &&
                        strstr((const char *)reply, "\"status\":\"ok\""))
                        built = true;
                    if (reply) SDL_free(reply);
                }
                if (ti1) SDL_free(ti1);
            }
            fclose(handle);
        }
    }
    remove(ti1_path);
    remove(input_path);
    if (!built) companion_report_build_error("targen failed after three chart optimization attempts");
}

static void companion_run_build(const char *poll_response)
{
    char ti3_path[1200], icc_path[1200], base_path[1200], tool[1024];
    char command[8192], flags[2048], directory[1024];
    unsigned char *ti3 = NULL;
    size_t ti3_length = 0;
    FILE *handle;
    int status;
    bool built = false;
#ifdef _WIN32
    CompanionBuildConsole build_console;
#endif

    if (strstr(poll_response, "\"operation\":\"targen\"")) {
        companion_run_targen(poll_response);
        return;
    }

    if (!companion_tool_path("colprof", tool, sizeof(tool))) return;
    /* Flags are produced by the generator's builder from its argument list. */
    flags[0] = '\0';
    {
        const char *start = strstr(poll_response, "\"flags\":[");
        if (start) {
            const char *end = strchr(start, ']');
            size_t length = end ? (size_t)(end - start - 9) : 0;
            if (length && length < sizeof(flags)) {
                memcpy(flags, start + 9, length);
                flags[length] = '\0';
            }
        }
    }

    {   /* Work in the OS temp directory; the generator keeps the authoritative copies. */
        const char *base = SDL_GetPrefPath("PGeneratorPlus", "build");
        if (!base) return;
        SDL_strlcpy(directory, base, sizeof(directory));
        SDL_snprintf(base_path, sizeof(base_path), "%sfit", directory);
        SDL_snprintf(ti3_path, sizeof(ti3_path), "%sfit.ti3", directory);
        SDL_snprintf(icc_path, sizeof(icc_path), "%sfit.icc", directory);
    }
    remove(icc_path);
#ifdef _WIN32
    companion_build_console_open(&build_console);
#endif

    {   /* Fetch the characterization: too large for the poll response buffer. */
        char path[512];
        SDL_snprintf(path, sizeof(path), "/api/icc/companion/build-ti3?token=%s", app.config.token);
        status = http_binary(&app.config, "GET", path, "text/plain", NULL, 0, &ti3, &ti3_length);
        if (status != 200 || !ti3 || ti3_length < 32) {
            if (ti3) SDL_free(ti3);
#ifdef _WIN32
            companion_build_console_close(&build_console);
#endif
            companion_report_build_error("could not fetch the characterization");
            return;
        }
    }
    handle = fopen(ti3_path, "wb");
    if (!handle || fwrite(ti3, 1, ti3_length, handle) != ti3_length) {
        if (handle) fclose(handle);
        SDL_free(ti3);
#ifdef _WIN32
        companion_build_console_close(&build_console);
#endif
        companion_report_build_error("could not stage the characterization");
        return;
    }
    fclose(handle);
    SDL_free(ti3);

    {   /* The flags arrive as a JSON array. Rebuild them as shell arguments,
           quoting each element on its own: values routinely contain spaces
           (-D "Living room OLED", -C "Created from user measurements by
           PGenerator+"), and flattening the buffer would hand colprof those
           words as stray positional arguments. */
        char cleaned[3072];
        size_t out = 0, index = 0;

        while (flags[index]) {
            char argument[1024];
            size_t length = 0;
            bool truncated = false;

            while (flags[index] == ' ' || flags[index] == ',') index++;
            if (flags[index] != '"') break;
            index++;
            while (flags[index] && flags[index] != '"') {
                char c = flags[index++];
                if (c == '\\' && flags[index]) c = flags[index++];
                if (length + 1 >= sizeof(argument)) { truncated = true; break; }
                argument[length++] = c;
            }
            if (truncated || flags[index] != '"') { out = 0; break; }
            index++;
            argument[length] = '\0';
            if (!companion_quote_append(cleaned, sizeof(cleaned), &out, argument)) { out = 0; break; }
        }
        if (!out) {
#ifdef _WIN32
            companion_build_console_close(&build_console);
#endif
            companion_report_build_error("the fit arguments could not be read");
            return;
        }
        cleaned[out] = '\0';
#ifdef _WIN32
        if (build_console.active) {
            /* system() routes the command through cmd.exe. A command whose
             * first character is a quote loses that quote in cmd's special
             * executable-path parsing when the tool lives below a directory
             * containing spaces. Keep a harmless command in front so the
             * quoted colprof path is parsed as an ordinary command segment. */
            SDL_snprintf(command, sizeof(command), "title PGenerator+ ICC Profile Build & \"%s\" %s -O \"%s\" \"%s\"",
                         tool, cleaned, icc_path, base_path);
        } else {
            SDL_snprintf(command, sizeof(command),
                         "title PGenerator+ ICC Profile Build & "
                         "echo. & echo PGenerator+ is building your ICC profile. & "
                         "echo This calculation was offloaded from PGenerator+. & "
                         "echo Please do not close this window. It will close automatically when the build finishes. & "
                         "echo. & \"%s\" %s -O \"%s\" \"%s\"",
                         tool, cleaned, icc_path, base_path);
        }
#else
        SDL_snprintf(command, sizeof(command), "\"%s\" %s -O \"%s\" \"%s\"",
                     tool, cleaned, icc_path, base_path);
#endif
    }
    queue_status("PGenerator+ Patch Companion | Building ICC profile...");
    status = system(command);
    (void)status;
#ifdef _WIN32
    companion_build_console_close(&build_console);
#endif

    handle = fopen(icc_path, "rb");
    if (handle) {
        long size;
        fseek(handle, 0, SEEK_END);
        size = ftell(handle);
        fseek(handle, 0, SEEK_SET);
        if (size > 128 && size < 96 * 1024 * 1024) {
            unsigned char *icc = (unsigned char *)SDL_malloc((size_t)size);
            if (icc && fread(icc, 1, (size_t)size, handle) == (size_t)size) {
                char path[512];
                unsigned char *reply = NULL;
                size_t reply_length = 0;
                SDL_snprintf(path, sizeof(path), "/api/icc/companion/build-result?token=%s", app.config.token);
                if (http_binary(&app.config, "POST", path, "application/octet-stream",
                                icc, (size_t)size, &reply, &reply_length) == 200 &&
                    reply && strstr((const char *)reply, "\"status\":\"ok\""))
                    built = true;
                if (reply) SDL_free(reply);
            }
            if (icc) SDL_free(icc);
        }
        fclose(handle);
    }
    remove(ti3_path);
    remove(icc_path);
    if (!built) companion_report_build_error("colprof did not produce a profile");
}

static void companion_report_install(const char *job, bool ok, const char *message)
{
    char message_hex[481], path[1200];
    profile_name_hex(message ? message : "", message_hex, sizeof(message_hex));
    SDL_snprintf(path, sizeof(path),
                 "/api/icc/companion/profile-install-result?token=%s&job=%s&ok=%d&message_hex=%s",
                 app.config.token, job, ok ? 1 : 0, message_hex);
    http_binary(&app.config, "POST", path, "text/plain",
                (const unsigned char *)"x", 1, NULL, NULL);
}

static void companion_run_install(const char *poll_response)
{
    char job[96] = "", file[256] = "", request[768], directory[1200], profile_path[1500];
    unsigned char *profile = NULL;
    size_t profile_length = 0;
    FILE *handle;
    bool accepted = false;
#ifndef _WIN32
    bool profile_is_hdr = false;
#endif
    if (!json_string(poll_response, "install_job", job, sizeof(job)) ||
        !json_string(poll_response, "file", file, sizeof(file)) ||
        !job[0] || !file[0] || strstr(file, "..") || strchr(file, '/') || strchr(file, '\\')) {
        return;
    }
#ifdef _WIN32
    /* Profile installation changes the Windows default itself. Restore the
     * normal profile scope before handing that job to the loader; the next
     * settings poll will cache the newly installed B2A0 and isolate it again
     * if explicit handling is still selected. */
    if (app.windows_correction_isolated &&
        !windows_set_correction_isolation(false)) {
        companion_report_install(job, false,
            "Patch Companion could not restore Windows profile handling before installation");
        return;
    }
#endif
    SDL_snprintf(request, sizeof(request),
                 "/api/icc/companion/profile-install-data?token=%s&job=%s",
                 app.config.token, job);
    if (http_binary(&app.config, "GET", request, "text/plain", NULL, 0,
                    &profile, &profile_length) != 200 || !profile ||
        profile_length <= 128 || profile_length > 64u * 1024u * 1024u ||
        memcmp(profile + 36, "acsp", 4)) {
        if (profile) SDL_free(profile);
        companion_report_install(job, false, "Patch Companion could not download a valid ICC profile");
        return;
    }
#if !defined(_WIN32) && !defined(__APPLE__)
    profile_is_hdr = linux_profile_name_is_hdr(file) ||
                     profile_has_hdr_cicp(profile, profile_length);
#endif
    {
        const char *base = SDL_GetPrefPath("PGeneratorPlus", "profiles");
        if (!base) {
            SDL_free(profile);
            companion_report_install(job, false, "Patch Companion could not create its profile directory");
            return;
        }
        SDL_strlcpy(directory, base, sizeof(directory));
    }
    SDL_snprintf(profile_path, sizeof(profile_path), "%s%s", directory, file);
    handle = fopen(profile_path, "wb");
    if (!handle || fwrite(profile, 1, profile_length, handle) != profile_length) {
        if (handle) fclose(handle);
        SDL_free(profile);
        companion_report_install(job, false, "Patch Companion could not stage the ICC profile locally");
        return;
    }
    if (fclose(handle) != 0) {
        SDL_free(profile);
        companion_report_install(job, false, "Patch Companion could not finish staging the ICC profile locally");
        return;
    }
    SDL_free(profile);
    queue_status("PGenerator+ Patch Companion | Installing and applying ICC profile...");
#ifdef _WIN32
    {
        char loader[1200], command[5000], monitor_utf8[1024] = "", result_path[1500];
        STARTUPINFOA startup;
        PROCESS_INFORMATION process;
        if (!companion_tool_path("PGenProfileLoader", loader, sizeof(loader))) {
            companion_report_install(job, false, "PGenerator+ Profile Loader is not installed beside Patch Companion");
            return;
        }
        WideCharToMultiByte(CP_UTF8, 0, app.windows_monitor_path, -1,
                            monitor_utf8, sizeof(monitor_utf8), NULL, NULL);
        SDL_snprintf(result_path, sizeof(result_path), "%sinstall-%s.result", directory, job);
        remove(result_path);
        SDL_snprintf(command, sizeof(command),
                     "\"%s\" --apply-from-companion --profile \"%s\" --monitor \"%s\" --result \"%s\"",
                     loader, profile_path, monitor_utf8, result_path);
        ZeroMemory(&startup, sizeof(startup)); startup.cb = sizeof(startup);
        ZeroMemory(&process, sizeof(process));
        if (CreateProcessA(NULL, command, NULL, NULL, FALSE, 0, NULL, NULL,
                           &startup, &process)) {
            CloseHandle(process.hThread);
            CloseHandle(process.hProcess);
            for (int attempt = 0; attempt < 480; attempt++) {
                FILE *result = fopen(result_path, "rb");
                if (result) {
                    char text[16] = "";
                    fread(text, 1, sizeof(text) - 1, result);
                    fclose(result);
                    accepted = !strncmp(text, "ok", 2);
                    break;
                }
                SDL_Delay(250);
            }
            remove(result_path);
            /* The loader has just cycled Advanced Color under our swapchain.
             * Recover foreground before the next HDR patch, but keep this
             * renderer alive: destroying the new HDR path here detaches the
             * MHC2 stage Windows just loaded until another foreground handoff. */
            if (accepted)
                SDL_SetAtomicInt(&app.presentation_recovery_pending, 1);
        }
    }
#elif defined(__APPLE__)
    {
        char loader[1200], display_argument[320], uuid_argument[128];
        char result_argument[1600], result_path[1500];
        char uuid_text[64] = "";
        pid_t child;
        (void)profile_is_hdr;   /* macOS keeps one profile slot per display */
        if (!companion_tool_path("PGenProfileLoader", loader, sizeof(loader))) {
            companion_report_install(job, false, "PGenerator+ Profile Loader is not installed beside Patch Companion");
            return;
        }
        /* The display's CGDisplay UUID is the macOS analogue of the Windows
         * monitor device path: stable across reboots and unambiguous when two
         * identical panels are attached, which a display name is not. */
        {
            CGDirectDisplayID display_id = macos_direct_display_id(app.selected_display_id);
            CFUUIDRef uuid = display_id ? CGDisplayCreateUUIDFromDisplayID(display_id) : NULL;
            if (uuid) {
                CFStringRef text = CFUUIDCreateString(NULL, uuid);
                if (text) {
                    CFStringGetCString(text, uuid_text, sizeof(uuid_text),
                                       kCFStringEncodingUTF8);
                    CFRelease(text);
                }
                CFRelease(uuid);
            }
        }
        SDL_snprintf(result_path, sizeof(result_path), "%sinstall-%s.result", directory, job);
        remove(result_path);
        SDL_snprintf(display_argument, sizeof(display_argument), "--display=%s", app.selected_display);
        SDL_snprintf(uuid_argument, sizeof(uuid_argument), "--display-uuid=%s", uuid_text);
        SDL_snprintf(result_argument, sizeof(result_argument), "--result=%s", result_path);
        child = fork();
        if (child == 0) {
            execl(loader, loader, "--apply-from-companion", uuid_argument,
                  display_argument, result_argument, profile_path, (char *)NULL);
            _exit(127);
        }
        if (child > 0) {
            bool child_exited = false;
            int child_status = 0;
            /* The loader writes "ok" or "error: <reason>" once ColorSync has
             * genuinely adopted (or refused) the profile - the same contract
             * the Windows loader uses, and the reason macOS does not need the
             * compositor-polling loop Linux falls back on below.
             *
             * Watch the child as well as the file. A loader that dies without
             * writing - a dyld failure, a crash, bad arguments - would
             * otherwise turn an instantly diagnosable error into two minutes
             * of silence while this loop waits out its full timeout. */
            for (int attempt = 0; attempt < 480; attempt++) {
                FILE *result = fopen(result_path, "rb");
                if (result) {
                    char text[16] = "";
                    fread(text, 1, sizeof(text) - 1, result);
                    fclose(result);
                    accepted = !strncmp(text, "ok", 2);
                    break;
                }
                if (waitpid(child, &child_status, WNOHANG) == child) {
                    /* One last look: it may have written the file in its final
                     * moments, after this iteration's check. */
                    result = fopen(result_path, "rb");
                    if (result) {
                        char text[16] = "";
                        fread(text, 1, sizeof(text) - 1, result);
                        fclose(result);
                        accepted = !strncmp(text, "ok", 2);
                    }
                    child_exited = true;
                    break;
                }
                SDL_Delay(250);
            }
            remove(result_path);
            if (child_exited && !accepted) {
                if (WIFSIGNALED(child_status))
                    SDL_Log("Profile Loader died on signal %d without reporting "
                            "a result", WTERMSIG(child_status));
                else
                    SDL_Log("Profile Loader exited with status %d without "
                            "reporting a result",
                            WIFEXITED(child_status) ? WEXITSTATUS(child_status) : -1);
                SDL_free(profile);
                companion_report_install(job, false,
                    "Profile Loader exited without reporting a result - it may "
                    "be missing a library or incompatible with this system");
                return;
            }
            if (!child_exited) {
                /* Still running after a result or the timeout: reap it in the
                 * background rather than leaving a zombie. */
                SDL_Thread *reaper = SDL_CreateThread(reap_profile_loader,
                                                      "profile-loader-reaper",
                                                      (void *)(intptr_t)child);
                if (reaper) SDL_DetachThread(reaper);
                else waitpid(child, NULL, WNOHANG);
            }
        }
    }
#else
    {
        char loader[1200], display_argument[256];
        pid_t child;
        if (!companion_tool_path("PGenProfileLoader", loader, sizeof(loader))) {
            companion_report_install(job, false, "PGenerator+ Profile Loader is not installed beside Patch Companion");
            return;
        }
        SDL_snprintf(display_argument, sizeof(display_argument), "--display=%s", app.selected_display);
        child = fork();
        if (child == 0) {
            execl(loader, loader, "--apply-silent", display_argument, profile_path, (char *)NULL);
            _exit(127);
        }
        if (child > 0) {
            SDL_Thread *reaper = SDL_CreateThread(reap_profile_loader,
                                                  "profile-loader-reaper",
                                                  (void *)(intptr_t)child);
            if (reaper) SDL_DetachThread(reaper);
            const char *wanted = strrchr(profile_path, '/');
            wanted = wanted ? wanted + 1 : profile_path;
            for (int attempt = 0; attempt < 120; attempt++) {
                KWinOutputState output;
                const char *active;
                SDL_Delay(250);
                if (!kwin_output_state(app.selected_display_id, &output)) continue;
                active = profile_is_hdr
                       ? output.hdr_icc_path : output.icc_path;
                if (active && active[0]) {
                    const char *name = strrchr(active, '/');
                    name = name ? name + 1 : active;
                    if (!strcmp(name, wanted)) { accepted = true; break; }
                }
            }
            if (!reaper) waitpid(child, NULL, WNOHANG);
        }
    }
#endif
    companion_report_install(job, accepted,
                             accepted ? "Profile Loader installed and applied the profile to the selected display"
                                      : "Profile Loader could not verify the profile on the selected display");
}

static int SDLCALL companion_install_thread_main(void *data)
{
    char *response = (char *)data;
    companion_run_install(response);
    SDL_free(response);
    SDL_SetAtomicInt(&app.install_in_progress, 0);
    return 0;
}

static void companion_start_install(const char *poll_response)
{
    char *response;
    if (SDL_GetAtomicInt(&app.install_in_progress)) return;
    if (app.install_thread) {
        SDL_WaitThread(app.install_thread, NULL);
        app.install_thread = NULL;
    }
    response = SDL_strdup(poll_response);
    if (!response) return;
    SDL_SetAtomicInt(&app.install_in_progress, 1);
    app.install_thread = SDL_CreateThread(companion_install_thread_main,
                                          "PGen profile install", response);
    if (!app.install_thread) {
        SDL_SetAtomicInt(&app.install_in_progress, 0);
        SDL_free(response);
    }
}

static void acknowledge(uint64_t sequence, bool ok, const char *message,
                        const char *renderer, bool hdr_active)
{
    char path[256], body[1024], response[2048];
    SDL_snprintf(path, sizeof(path), "/api/icc/companion/ack");
    SDL_snprintf(body, sizeof(body),
                 "{\"token\":\"%s\",\"client\":\"%s\",\"sequence\":%llu,\"status\":\"%s\",\"renderer\":\"%s\",\"hdr_active\":%s,\"version\":\"%s\",\"message\":\"%s\"}",
                 app.config.token, app.config.client, (unsigned long long)sequence,
                 ok ? "ok" : "error", renderer, hdr_active ? "true" : "false", APP_VERSION, message ? message : "");
    http_request(&app.config, "POST", path, body, response, sizeof(response));
}

static void queue_status(const char *text)
{
    SDL_LockMutex(app.network_mutex);
    SDL_strlcpy(app.status, text, sizeof(app.status));
    app.status_dirty = true;
    SDL_UnlockMutex(app.network_mutex);
}

static void send_pending_ack(void)
{
    uint64_t sequence = 0;
    bool ok = false, hdr_active = false;
    char message[256] = "", renderer[64] = "unknown";
    SDL_LockMutex(app.network_mutex);
    if (app.ack_pending) {
        sequence = app.ack_sequence;
        ok = app.ack_ok;
        hdr_active = app.ack_hdr_active;
        SDL_strlcpy(message, app.ack_message, sizeof(message));
        SDL_strlcpy(renderer, app.ack_renderer, sizeof(renderer));
        app.ack_pending = false;
    }
    SDL_UnlockMutex(app.network_mutex);
    if (sequence) acknowledge(sequence, ok, message, renderer, hdr_active);
}

static void poll_server(void)
{
    char path[3072], response[RESPONSE_CAPACITY], mode[32] = "sdr";
    char window_mode[32] = "window";
    char correction_mode[16] = "system", active_profile[192] = "", profile_hex[385] = "", correction_signal_mode[16] = "sdr";
    char display_hex[385] = "";
    char reported_renderer[64] = "starting";
    /* "unknown" is the value the server treats as "nothing to report", so a
     * platform that has no such concept must leave these alone rather than
     * inventing a placeholder the operator then has to interpret. */
    char swapchain_color_space[32] = "unknown", presentation_mode[32] = "unknown";
    char transform_note[128] = "", transform_note_hex[257] = "";
    double sequence_value, r, g, b, input_max, code_min, code_max, poll_ms;
    double max_luma = 1000.0, min_luma = 0.005, max_cll = 1000.0, max_fall = 400.0;
    double settings_revision_value, display_size_value, patch_size_value;
    double preserve_hdr_calibration_value = 0.0;
    uint64_t sequence;
    bool is_alignment, reported_hdr_active = false;
    double output_maximum_luminance = 0.0, output_full_frame_luminance = 0.0;
    unsigned int output_bits_per_color = 0;
    int status;
#ifdef _WIN32
    wchar_t active_profile_path[32768] = L"";
#endif
    SDL_LockMutex(app.network_mutex);
    if (app.ack_renderer[0]) SDL_strlcpy(reported_renderer, app.ack_renderer, sizeof(reported_renderer));
    reported_hdr_active = app.ack_hdr_active;
    SDL_UnlockMutex(app.network_mutex);
#ifdef _WIN32
    reported_hdr_active = windows_window_hdr_enabled(app.window);
    windows_hdr_diagnostics(swapchain_color_space, sizeof(swapchain_color_space),
                            presentation_mode, sizeof(presentation_mode),
                            &output_maximum_luminance,
                            &output_full_frame_luminance,
                            &output_bits_per_color);
    windows_active_profile(app.window, active_profile, sizeof(active_profile),
                           active_profile_path, SDL_arraysize(active_profile_path),
                           reported_hdr_active, app.windows_monitor_path,
                           SDL_arraysize(app.windows_monitor_path));
    /* WCS now reports the system-scope fallback while explicit correction is
     * isolated. Keep reporting and evaluating the profile whose B2A0 bytes we
     * cached before the switch; the fallback is deliberately not the selected
     * transform. */
    if (app.windows_correction_isolated && app.correction_profile[0]) {
        SDL_strlcpy(active_profile, app.correction_profile,
                    sizeof(active_profile));
        wcsncpy(active_profile_path, app.correction_profile_path,
                SDL_arraysize(active_profile_path) - 1);
        active_profile_path[SDL_arraysize(active_profile_path) - 1] = L'\0';
    }
#else
    /* There is no DXGI swapchain and no OS presentation-mode query here.
     * Report what this build genuinely knows - the colorspace the renderer
     * presents in and the video backend carrying it - instead of a
     * placeholder that reads as a failure. The active profile is filled in
     * below by whichever platform owns the assignment, KWin or ColorSync;
     * when neither reports one, active_profile stays empty because none was
     * read, not because none is installed. */
    {
        SDL_PropertiesID renderer_props =
            app.renderer ? SDL_GetRendererProperties(app.renderer) : 0;
        SDL_Colorspace colorspace = renderer_props
            ? (SDL_Colorspace)SDL_GetNumberProperty(renderer_props,
                                                    SDL_PROP_RENDERER_OUTPUT_COLORSPACE_NUMBER,
                                                    SDL_COLORSPACE_UNKNOWN)
            : SDL_COLORSPACE_UNKNOWN;
        const char *driver = SDL_GetCurrentVideoDriver();
        if (colorspace == SDL_COLORSPACE_HDR10)
            SDL_strlcpy(swapchain_color_space, "hdr10-pq", sizeof(swapchain_color_space));
        else if (colorspace == SDL_COLORSPACE_SRGB_LINEAR)
            SDL_strlcpy(swapchain_color_space, "scrgb-linear", sizeof(swapchain_color_space));
        else if (colorspace == SDL_COLORSPACE_SRGB)
            SDL_strlcpy(swapchain_color_space, "srgb", sizeof(swapchain_color_space));
        if (driver && driver[0])
            SDL_strlcpy(presentation_mode, driver, sizeof(presentation_mode));
    }
#ifdef __APPLE__
    /* Ask ColorSync which profile macOS has assigned to this display. The
     * name goes into the status JSON exactly where the Linux build reports
     * the KWin assignment, and the path is what the explicit correction
     * modes read. */
    macos_active_profile(app.selected_display_id, active_profile,
                         sizeof(active_profile), app.macos_profile_path,
                         sizeof(app.macos_profile_path));
#else
    /* Ask KWin what it has assigned to this output, and which of its two slots
     * applies. Plasma 6.7 keeps SDR and HDR assignments apart, and an HDR
     * display routinely carries an HDR profile with an EMPTY SDR one - reading
     * only iccProfilePath is what made a configured display report "no profile
     * loaded". Also settles HDR when the colour-management protocol did not. */
    {
        KWinOutputState output;
        if (kwin_output_state(app.selected_display_id, &output)) {
            const char *path_in_use = output.hdr && output.hdr_icc_path[0]
                ? output.hdr_icc_path : output.icc_path;
            if (output.hdr) reported_hdr_active = true;
            if (path_in_use && path_in_use[0]) {
                const char *base = strrchr(path_in_use, '/');
                SDL_strlcpy(active_profile, base ? base + 1 : path_in_use,
                            sizeof(active_profile));
                SDL_strlcpy(app.linux_profile_path, path_in_use,
                            sizeof(app.linux_profile_path));
            } else {
                app.linux_profile_path[0] = '\0';
            }
        }
    }
#endif
#endif
    /* Carry the reason a requested transform is not running, so the server does
     * not have to guess whether a profile is missing or the whole feature is.
     * Both fields belong to this thread: load_correction_lut runs from here. */
    if (!app.correction_ready && app.correction_error[0])
        SDL_strlcpy(transform_note, app.correction_error, sizeof(transform_note));
    profile_name_hex(transform_note, transform_note_hex, sizeof(transform_note_hex));
    profile_name_hex(active_profile, profile_hex, sizeof(profile_hex));
    profile_name_hex(app.selected_display, display_hex, sizeof(display_hex));
    SDL_snprintf(path, sizeof(path),
                 "/api/icc/companion/poll?token=%s&client=%s&version=%s&build=%s&platform=%s&renderer=%s&hdr=%d&profile_hex=%s&display_hex=%s&swapchain_cs=%s&presentation=%s&output_max=%.3f&output_full=%.3f&output_bits=%u&transform=%s&transform_ready=%d&transform_note_hex=%s&source_r=%.6f&source_g=%.6f&source_b=%.6f&submitted_r=%.6f&submitted_g=%.6f&submitted_b=%.6f&build_argyll=%s&build_targen=%d",
                 app.config.token, app.config.client, APP_VERSION, APP_BUILD,
                 companion_platform(),
                 reported_renderer, reported_hdr_active ? 1 : 0, profile_hex,
                 display_hex,
                 swapchain_color_space, presentation_mode,
                 output_maximum_luminance, output_full_frame_luminance,
                 output_bits_per_color, app.correction_mode,
                 app.correction_ready ? 1 : 0, transform_note_hex,
                 app.source_r, app.source_g, app.source_b,
                 app.submitted_r, app.submitted_g, app.submitted_b,
                 companion_argyll_version(), companion_targen_available() ? 1 : 0);
    status = http_request(&app.config, "GET", path, NULL, response, sizeof(response));
    if (status != 200) {
        char title[256];
        SDL_snprintf(title, sizeof(title), "Waiting for %s", app.config.server);
        queue_status(title);
        app.next_poll_ms = SDL_GetTicks() + 1000;
        return;
    }
    if (json_number(response, "settings_revision", &settings_revision_value) &&
        json_number(response, "display_size", &display_size_value) &&
        json_string(response, "window_mode", window_mode, sizeof(window_mode))) {
        uint64_t settings_revision = (uint64_t)settings_revision_value;
        json_string(response, "correction_mode", correction_mode, sizeof(correction_mode));
        json_string(response, "correction_signal_mode", correction_signal_mode, sizeof(correction_signal_mode));
#ifdef _WIN32
        /* A previous Companion can exit while explicit cLUT handling has the
         * loader's persisted per-display isolation enabled. The new process
         * cannot infer that state from its zeroed in-memory flag, and system
         * mode would otherwise report the selected profile while Windows is
         * still serving the system fallback. Make the loader restore its
         * persisted state once before accepting any correction mode. Restore
         * does not require a profile argument; the loader owns the exact
         * profile and monitor state that must be recovered. */
        if (!app.windows_startup_restore_complete) {
            if (!windows_restore_correction_state()) {
                app.correction_ready = false;
                SDL_strlcpy(app.correction_error,
                            "Could not recover Windows profile handling left by a previous session",
                            sizeof(app.correction_error));
                app.next_poll_ms = SDL_GetTicks() + 1000;
                return;
            }
            app.windows_startup_restore_complete = true;
            active_profile[0] = '\0';
            active_profile_path[0] = L'\0';
            windows_active_profile(app.window, active_profile,
                                   sizeof(active_profile), active_profile_path,
                                   SDL_arraysize(active_profile_path),
                                   reported_hdr_active,
                                   app.windows_monitor_path,
                                   SDL_arraysize(app.windows_monitor_path));
        }
        bool explicit_hdr_requested =
            (!strcmp(correction_mode, "none") ||
             !strcmp(correction_mode, "clut") ||
             !strcmp(correction_mode, "matrix")) &&
            !strcmp(correction_signal_mode, "hdr10");
        bool wants_isolation = reported_hdr_active && explicit_hdr_requested;
        if (!explicit_hdr_requested)
            app.windows_restore_attempted = false;
        else if (reported_hdr_active)
            app.windows_restore_attempted = false;
        else if (!app.windows_restore_attempted) {
            /* An upgrade can terminate the previous processes between the
             * disable and re-enable halves of an Advanced Color reload. Ask
             * the loader to recover its persisted isolation state even though
             * DXGI currently reports HDR off, then query the selected profile
             * again before caching any explicit transform. */
            app.windows_restore_attempted = true;
            if (!app.correction_profile_path[0] && active_profile_path[0]) {
                wcsncpy(app.correction_profile_path, active_profile_path,
                        SDL_arraysize(app.correction_profile_path) - 1);
                app.correction_profile_path[
                    SDL_arraysize(app.correction_profile_path) - 1] = L'\0';
            }
            if (!windows_restore_correction_state()) {
                app.correction_ready = false;
                SDL_strlcpy(app.correction_error,
                            "Could not recover Windows HDR profile handling after startup",
                            sizeof(app.correction_error));
            }
            app.next_poll_ms = SDL_GetTicks() + 250;
            return;
        }
        {
            if (app.windows_correction_isolated && !wants_isolation) {
                if (!windows_set_correction_isolation(false)) {
                    app.correction_ready = false;
                    SDL_strlcpy(app.correction_error,
                                "Could not restore Windows profile handling on the selected display",
                                sizeof(app.correction_error));
                    app.next_poll_ms = SDL_GetTicks() + 500;
                    return;
                }
                active_profile[0] = '\0';
                active_profile_path[0] = L'\0';
                windows_active_profile(app.window, active_profile,
                                       sizeof(active_profile), active_profile_path,
                                       SDL_arraysize(active_profile_path),
                                       reported_hdr_active,
                                       app.windows_monitor_path,
                                       SDL_arraysize(app.windows_monitor_path));
            }
        }
#endif
        if (settings_revision != app.correction_lut_revision ||
            strcmp(active_profile, app.correction_profile)
#ifdef _WIN32
            || (wants_isolation && !app.windows_correction_isolated &&
                !app.correction_ready)
#endif
            ) {
#ifdef _WIN32
            bool correction_path_changed = strcmp(app.correction_mode,
                                                   correction_mode) != 0;
#endif
            SDL_strlcpy(app.correction_mode, correction_mode, sizeof(app.correction_mode));
            SDL_strlcpy(app.correction_profile, active_profile, sizeof(app.correction_profile));
            SDL_strlcpy(app.correction_signal_mode, correction_signal_mode, sizeof(app.correction_signal_mode));
#ifdef _WIN32
            wcsncpy(app.correction_profile_path,active_profile_path,SDL_arraysize(app.correction_profile_path)-1);
            app.correction_profile_path[SDL_arraysize(app.correction_profile_path)-1]=L'\0';
#elif defined(__APPLE__)
            /* The path to read was captured from ColorSync above, and macOS
             * keeps compositing through the assigned profile in every mode -
             * there is no compositor source to toggle the way KWin has. */
#else
            {
                KWinOutputState output;
                bool system_mode = !strcmp(app.correction_mode, "system");
                if (kwin_output_state(app.selected_display_id, &output) &&
                    (output.hdr_icc_path[0] || output.icc_path[0]) &&
                    !kwin_set_profile_source(&output, system_mode)) {
                    app.correction_ready = false;
                    SDL_strlcpy(app.correction_error,
                                "Could not switch KWin to the selected profile correction path",
                                sizeof(app.correction_error));
                    app.correction_lut_revision = settings_revision;
                    app.next_poll_ms = SDL_GetTicks() + 500;
                    return;
                }
            }
#endif
            load_correction_lut(settings_revision);
#ifdef _WIN32
            if (app.correction_ready && wants_isolation &&
                !app.windows_correction_isolated &&
                !windows_set_correction_isolation(true)) {
                app.correction_ready = false;
                SDL_strlcpy(app.correction_error,
                                "Could not suspend Windows MHC2 for the selected explicit correction path",
                            sizeof(app.correction_error));
            }
            /* The loader cycles Advanced Color when either isolating explicit
             * B2A0 handling or restoring Windows system handling. Complete the
             * foreground handoff before the next HDR patch is acknowledged. */
            if (correction_path_changed || wants_isolation)
                SDL_SetAtomicInt(&app.correction_recovery_pending, 1);
#endif
        }
        SDL_LockMutex(app.network_mutex);
        if (settings_revision != app.applied_settings_revision &&
            (!app.settings_pending || settings_revision != app.settings_revision)) {
            app.settings_revision = settings_revision;
            app.settings_fullscreen = !strcmp(window_mode, "fullscreen");
            app.settings_size = (int)display_size_value;
            app.settings_pending = true;
        }
        SDL_UnlockMutex(app.network_mutex);
    }
    {
        char title[512];
        if (SDL_GetAtomicInt(&app.install_in_progress))
            SDL_strlcpy(title,
                        "PGenerator+ Patch Companion | Installing and applying ICC profile...",
                        sizeof(title));
        else if (!strcmp(app.correction_mode, "clut"))
            SDL_snprintf(title, sizeof(title), "PGenerator+ Patch Companion | Active profile cLUT: %s%s",
                         app.correction_profile[0] ? app.correction_profile : "not detected",
                         app.correction_error[0] ? " (not ready)" : "");
        else if (!strcmp(app.correction_mode, "matrix"))
            SDL_snprintf(title, sizeof(title), "PGenerator+ Patch Companion | Active profile matrix/TRC: %s%s",
                         app.correction_profile[0] ? app.correction_profile : "not detected",
                         app.correction_error[0] ? " (not ready)" : "");
        else
            SDL_snprintf(title, sizeof(title), "PGenerator+ Patch Companion | No application profile correction");
        queue_status(title);
    }
    /* A build job pre-empts the patch path: the generator's builder is blocked
     * and no patch is pending while a fit runs. */
    if (strstr(response, "\"status\":\"build\"")) {
        companion_run_build(response);
        app.next_poll_ms = SDL_GetTicks() + 250;
        return;
    }
    if (strstr(response, "\"status\":\"install\"")) {
        companion_start_install(response);
        app.next_poll_ms = SDL_GetTicks() + 250;
        return;
    }
    is_alignment = strstr(response, "\"status\":\"align\"") != NULL;
    if (!is_alignment && !strstr(response, "\"status\":\"patch\"")) {
        poll_ms = 500;
        json_number(response, "poll_ms", &poll_ms);
        poll_ms = fmax(25.0, fmin(1000.0, poll_ms));
        app.next_poll_ms = SDL_GetTicks() + (uint64_t)poll_ms;
        return;
    }
    if (!json_number(response, "sequence", &sequence_value)) {
        app.next_poll_ms = SDL_GetTicks() + 500;
        return;
    }
    sequence = (uint64_t)sequence_value;
    SDL_LockMutex(app.network_mutex);
    if (sequence == app.sequence || (app.command_pending && sequence == app.command_sequence)) {
        SDL_UnlockMutex(app.network_mutex);
        app.next_poll_ms = SDL_GetTicks() + 250;
        return;
    }
    SDL_UnlockMutex(app.network_mutex);
    if (is_alignment) {
        SDL_LockMutex(app.network_mutex);
        app.command_sequence = sequence;
        app.command_alignment = true;
        app.command_preserve_hdr_calibration = false;
        app.command_pending = true;
        SDL_UnlockMutex(app.network_mutex);
        app.next_poll_ms = SDL_GetTicks() + 50;
        return;
    }
    if (!json_number(response, "r", &r) || !json_number(response, "g", &g) ||
        !json_number(response, "b", &b) ||
        !json_number(response, "input_max", &input_max) ||
        !json_number(response, "code_min", &code_min) || !json_number(response, "code_max", &code_max)) {
        app.next_poll_ms = SDL_GetTicks() + 500;
        return;
    }
    json_string(response, "signal_mode", mode, sizeof(mode));
    json_number(response, "max_luma", &max_luma);
    json_number(response, "min_luma", &min_luma);
    json_number(response, "max_cll", &max_cll);
    json_number(response, "max_fall", &max_fall);
    if (input_max <= 0 || code_max <= code_min) {
        acknowledge(sequence, false, "Invalid patch range", "network", false);
        app.next_poll_ms = SDL_GetTicks() + 250;
        return;
    }
    /* The server has already produced the final video code values. Preserve
     * them exactly, including legal-range codes, by normalizing only against
     * their declared bit depth. code_min/code_max describe the authored
     * range; they must not be expanded into a second full-range signal here. */
    r = fmax(0.0, fmin(1.0, r / input_max));
    g = fmax(0.0, fmin(1.0, g / input_max));
    b = fmax(0.0, fmin(1.0, b / input_max));
    app.source_r = r;
    app.source_g = g;
    app.source_b = b;
    if (strcmp(app.correction_mode, "system") && strcmp(app.correction_mode, "none") && strcmp(mode, app.correction_signal_mode)) {
        acknowledge(sequence, false, "The selected ICC correction does not match the patch signal mode", "profile", false);
        app.next_poll_ms = SDL_GetTicks() + 250;
        return;
    }
    if (!apply_correction_lut(&r, &g, &b)) {
        acknowledge(sequence, false, app.correction_error[0] ? app.correction_error : "The selected ICC correction is not ready", "profile", false);
        app.next_poll_ms = SDL_GetTicks() + 250;
        return;
    }
    app.submitted_r = r;
    app.submitted_g = g;
    app.submitted_b = b;
    SDL_LockMutex(app.network_mutex);
    app.command_sequence = sequence;
    app.command_alignment = false;
    app.command_r = r;
    app.command_g = g;
    app.command_b = b;
    app.command_max_luma = max_luma;
    app.command_min_luma = min_luma;
    app.command_max_cll = max_cll;
    app.command_max_fall = max_fall;
    app.command_size = 100;
    if (json_number(response, "size", &patch_size_value)) app.command_size = (int)patch_size_value;
    json_number(response, "preserve_hdr_calibration", &preserve_hdr_calibration_value);
    app.command_preserve_hdr_calibration = preserve_hdr_calibration_value != 0.0;
    SDL_strlcpy(app.command_mode, mode, sizeof(app.command_mode));
    app.command_pending = true;
    SDL_UnlockMutex(app.network_mutex);
    app.next_poll_ms = SDL_GetTicks() + 50;
}

static int SDLCALL network_thread_main(void *unused)
{
    (void)unused;
    while (!SDL_GetAtomicInt(&app.quit_requested)) {
        send_pending_ack();
        if (SDL_GetTicks() >= app.next_poll_ms) poll_server();
        SDL_Delay(10);
    }
    send_pending_ack();
    return 0;
}

static void process_network_updates(void)
{
    bool have_command = false, alignment = false, status_dirty = false;
    bool preserve_hdr_calibration = false;
    bool have_settings = false, settings_fullscreen = false;
    int command_size = 100, settings_size = 100;
    uint64_t settings_revision = 0;
    uint64_t sequence = 0;
    double r = 0.0, g = 0.0, b = 0.0;
    double max_luma = 1000.0, min_luma = 0.005, max_cll = 1000.0, max_fall = 400.0;
    char mode[32] = "sdr", title[256] = "";
    SDL_LockMutex(app.network_mutex);
    if (app.status_dirty) {
        status_dirty = true;
        SDL_strlcpy(title, app.status, sizeof(title));
        app.status_dirty = false;
    }
    if (app.settings_pending) {
        have_settings = true;
        settings_fullscreen = app.settings_fullscreen;
        settings_size = app.settings_size;
        settings_revision = app.settings_revision;
        app.settings_pending = false;
    }
    if (app.command_pending) {
        have_command = true;
        sequence = app.command_sequence;
        alignment = app.command_alignment;
        r = app.command_r; g = app.command_g; b = app.command_b;
        max_luma = app.command_max_luma; min_luma = app.command_min_luma;
        max_cll = app.command_max_cll; max_fall = app.command_max_fall;
        command_size = app.command_size;
        preserve_hdr_calibration = app.command_preserve_hdr_calibration;
        SDL_strlcpy(mode, app.command_mode, sizeof(mode));
        app.command_pending = false;
    }
    SDL_UnlockMutex(app.network_mutex);
    if (status_dirty) SDL_SetWindowTitle(app.window, title);
    if (have_settings) {
        /* Always consume the revision. On Wayland, fullscreen/position changes
         * can fail or be asynchronous; retrying every poll (50-500 ms) made the
         * window thrash in and out of the taskbar. One attempt per revision is
         * enough: the operator can toggle the setting again if needed. */
        (void)apply_display_settings(settings_fullscreen, settings_size);
        SDL_LockMutex(app.network_mutex);
        app.applied_settings_revision = settings_revision;
        SDL_UnlockMutex(app.network_mutex);
    }
    if (have_command) {
        bool ok;
#ifdef _WIN32
        bool had_hdr_swapchain = app.hdr_swapchain != NULL;
        /* A completed profile install needs foreground recovery after the
         * loader's Advanced Color cycle. Do not include it in the renderer
         * refresh below: recreating the HDR swapchain after a successful
         * install detaches Windows' newly loaded MHC2 stage. */
        bool install_recovery =
            SDL_GetAtomicInt(&app.presentation_recovery_pending) != 0 &&
            app.fullscreen && !alignment && !strcmp(mode, "hdr10") &&
            !preserve_hdr_calibration && app.hdr_swapchain;
        /* Changing between Windows-system MHC2 and an explicit transform is
         * different from a profile install, but both must preserve the live
         * swapchain: recreating it detaches the downstream MHC2 stage that an
         * explicit transform has already pre-cancelled. Track mode changes
         * separately so the same-monitor presentation handoff runs even when
         * the next request repeats the currently displayed patch. */
        bool correction_recovery =
            SDL_GetAtomicInt(&app.correction_recovery_pending) != 0 &&
            app.fullscreen && !alignment && !strcmp(mode, "hdr10") &&
            !preserve_hdr_calibration && app.hdr_swapchain;
        bool refresh_fullscreen_hdr =
            app.fullscreen && !alignment && !strcmp(mode, "hdr10") &&
            !preserve_hdr_calibration &&
            command_size >= 100 &&
            app.hdr_swapchain &&
            (strcmp(app.displayed_mode, mode) || app.displayed_r != r ||
             app.displayed_g != g || app.displayed_b != b ||
             app.displayed_size != command_size ||
             app.displayed_max_luma != max_luma ||
             app.displayed_min_luma != min_luma ||
             app.displayed_max_cll != max_cll ||
             app.displayed_max_fall != max_fall);
        bool recover_mhc2_after_render =
            app.fullscreen && !alignment && !strcmp(mode, "hdr10") &&
            (install_recovery || correction_recovery ||
             refresh_fullscreen_hdr || !had_hdr_swapchain);
#endif
        char message[256] = "";
        raise_pattern_window();
        if (!alignment) {
            app.displayed_size = command_size;
            app.displayed_max_luma = max_luma;
            app.displayed_min_luma = min_luma;
            app.displayed_max_cll = max_cll;
            app.displayed_max_fall = max_fall;
        }
#ifdef _WIN32
        /* On this Windows/NVIDIA path, an exact-fullscreen HDR swapchain can
         * remain tagged with the dim desktop composition policy after a dark
         * patch. Alt-Tab or an SDR-to-HDR transition immediately restores the
         * correct PQ output. Perform a short real SDR presentation reset only
         * when a new fullscreen HDR patch is selected, not for the per-refresh
         * redraw loop or repeated reads of the same patch. The normal meter
         * settle delay starts after the new HDR patch is acknowledged, so it
         * cannot sample this reset frame. Full-field OLED conditioning
         * commands opt out because recreating the HDR path can silently drop
         * the active Windows MHC2 calibration for every following patch. */
        if (install_recovery)
            SDL_SetAtomicInt(&app.presentation_recovery_pending, 0);
        if (correction_recovery)
            SDL_SetAtomicInt(&app.correction_recovery_pending, 0);
        if (refresh_fullscreen_hdr &&
            (!try_create_renderer(false, NULL) ||
             (SDL_Delay(50), !create_renderer(true)))) ok = false;
        else {
            ok = alignment ? render_alignment() : render_patch(mode, r, g, b);
            /* Windows attaches an active MHC2 stage only after the new HDR
             * path has presented and then completed a real foreground handoff.
             * Do the handoff before acknowledging the patch, then present it
             * again so the meter never sees the uncalibrated first frame. */
            if (ok && recover_mhc2_after_render) {
                bool needs_handoff = install_recovery || correction_recovery ||
                                     !had_hdr_swapchain;
                if ((needs_handoff && !windows_presentation_handoff(
                        (HWND)SDL_GetPointerProperty(
                            SDL_GetWindowProperties(app.window),
                            SDL_PROP_WINDOW_WIN32_HWND_POINTER, NULL))) ||
                    !windows_verified_foreground(true))
                    ok = SDL_SetError("The HDR patch window could not regain foreground after MHC2 recovery");
                else
                    ok = render_patch(mode, r, g, b);
            }
        }
#else
        ok = alignment ? render_alignment() : render_patch(mode, r, g, b);
#endif
        if (!ok) {
            const char *detail = SDL_GetError();
            if (detail && detail[0]) SDL_strlcpy(message, detail, sizeof(message));
            else SDL_strlcpy(message,
                alignment ? "The renderer could not display the alignment target" :
                (!strcmp(mode, "hdr10") ? "HDR output is not active or supported on this display" :
                                          "The renderer could not display the patch"),
                sizeof(message));
        }
        SDL_LockMutex(app.network_mutex);
        if (ok) {
            app.sequence = sequence;
#ifndef _WIN32
            /* Keep presenting throughout a meter integration. A few frames
             * only fill the swapchain; stopping there can leave a stale image
             * visible during long, low-light reads. Use elapsed time rather
             * than a frame count so high-refresh displays get the same 15
             * second interval. Each new patch resets it. */
            app.refresh_until_ms = SDL_GetTicks() + 15000;
#endif
        }
        app.ack_sequence = sequence;
        app.ack_ok = ok;
        SDL_strlcpy(app.ack_message, message, sizeof(app.ack_message));
        SDL_strlcpy(app.ack_renderer, app.renderer_name, sizeof(app.ack_renderer));
        app.ack_hdr_active = app.hdr_active;
        app.ack_pending = true;
        SDL_UnlockMutex(app.network_mutex);
    }
}

static bool pairing_build_font_textures(void)
{
    if (app.font_texture[0]) return true;
    for (int face = 0; face < PGEN_FACE_COUNT; face++) {
        const PgenFace *info = &pgen_font_faces[face];
        size_t count = (size_t)info->atlas_width * (size_t)info->atlas_height;
        SDL_Surface *surface = SDL_CreateSurface(info->atlas_width, info->atlas_height,
                                                 SDL_PIXELFORMAT_RGBA32);
        uint32_t *pixels;
        if (!surface) return false;
        pixels = (uint32_t *)surface->pixels;
        for (size_t index = 0; index < count; index++) {
            unsigned value = 0;
            const char *hex = info->alpha_hex + index * 2;
            for (int digit = 0; digit < 2; digit++) {
                char c = hex[digit];
                value = (value << 4) |
                        (unsigned)(c >= 'a' ? c - 'a' + 10 :
                                   (c >= 'A' ? c - 'A' + 10 : c - '0'));
            }
            pixels[(index / (size_t)info->atlas_width) * (size_t)(surface->pitch / 4) +
                   (index % (size_t)info->atlas_width)] =
                0x00ffffffu | ((uint32_t)value << 24);
        }
        app.font_texture[face] = SDL_CreateTextureFromSurface(app.renderer, surface);
        SDL_DestroySurface(surface);
        if (!app.font_texture[face]) return false;
        SDL_SetTextureScaleMode(app.font_texture[face], SDL_SCALEMODE_LINEAR);
        SDL_SetTextureBlendMode(app.font_texture[face], SDL_BLENDMODE_BLEND);
    }
    return true;
}

static float pairing_text_width(PgenFaceId face, float points, const char *text)
{
    const PgenFace *info = &pgen_font_faces[face];
    float scale = points / info->design_size;
    float width = 0.0f;
    for (const unsigned char *cursor = (const unsigned char *)text; *cursor; cursor++) {
        int code = *cursor;
        if (code < PGEN_FONT_FIRST_CHAR || code > PGEN_FONT_LAST_CHAR) code = '?';
        width += info->glyphs[code - PGEN_FONT_FIRST_CHAR].advance;
    }
    return width * scale;
}

static void pairing_draw_text(float x, float y, PgenFaceId face, float points,
                              SDL_Color color, const char *text)
{
    const PgenFace *info = &pgen_font_faces[face];
    float scale = points / info->design_size;
    float baseline = y + info->ascent * scale;
    float pen = x;
    SDL_SetTextureColorMod(app.font_texture[face], color.r, color.g, color.b);
    SDL_SetTextureAlphaMod(app.font_texture[face], color.a);
    for (const unsigned char *cursor = (const unsigned char *)text; *cursor; cursor++) {
        int code = *cursor;
        const PgenGlyph *glyph;
        if (code < PGEN_FONT_FIRST_CHAR || code > PGEN_FONT_LAST_CHAR) code = '?';
        glyph = &info->glyphs[code - PGEN_FONT_FIRST_CHAR];
        if (glyph->width > 0 && glyph->height > 0) {
            SDL_FRect source = {(float)glyph->x, 0.0f,
                                (float)glyph->width, (float)glyph->height};
            SDL_FRect target = {pen + (float)glyph->bearing_x * scale,
                                baseline - (float)glyph->bearing_y * scale,
                                (float)glyph->width * scale,
                                (float)glyph->height * scale};
            SDL_RenderTexture(app.renderer, app.font_texture[face], &source, &target);
        }
        pen += glyph->advance * scale;
    }
}

static void pairing_fill_rect(float x, float y, float w, float h, SDL_Color color)
{
    SDL_FRect rect = {x, y, w, h};
    SDL_SetRenderDrawColor(app.renderer, color.r, color.g, color.b, color.a);
    SDL_RenderFillRect(app.renderer, &rect);
}

static void pairing_frame_rect(float x, float y, float w, float h, SDL_Color color)
{
    SDL_FRect rect = {x, y, w, h};
    SDL_SetRenderDrawColor(app.renderer, color.r, color.g, color.b, color.a);
    SDL_RenderRect(app.renderer, &rect);
}

/* Drawn before any patch has ever been shown, on the plain SDL renderer
 * create_renderer(false) made at startup, never the Windows HDR swapchain. */
static bool render_pairing(const char *code, const char *server, int seconds_left, const char *note)
{
    int width, height;
    float density, margin, card_x, card_y, card_w, card_h, y;
    char line[256];
    const SDL_Color background = {32, 32, 32, 255};
    const SDL_Color card = {43, 43, 43, 255};
    const SDL_Color inset = {24, 24, 24, 255};
    const SDL_Color border = {64, 64, 64, 255};
    const SDL_Color text = {244, 244, 244, 255};
    const SDL_Color muted = {168, 172, 180, 255};
    const SDL_Color accent = {76, 148, 255, 255};

    if (!app.renderer) return false;
    if (!SDL_GetCurrentRenderOutputSize(app.renderer, &width, &height)) return false;
    if (!pairing_build_font_textures()) return false;

    density = fmaxf(1.0f, fminf((float)width / 900.0f, (float)height / 560.0f));
    margin = 32.0f * density;
    card_x = margin;
    card_y = margin;
    card_w = (float)width - margin * 2.0f;
    card_h = fminf((float)height - margin * 2.0f, 465.0f * density);

    SDL_SetRenderScale(app.renderer, 1.0f, 1.0f);
    SDL_SetRenderDrawColor(app.renderer, background.r, background.g, background.b, 255);
    if (!SDL_RenderClear(app.renderer)) return false;
    pairing_fill_rect(card_x, card_y, card_w, card_h, card);
    pairing_frame_rect(card_x, card_y, card_w, card_h, border);

    y = card_y + 28.0f * density;
    pairing_draw_text(card_x + 28.0f * density, y, PGEN_FACE_TITLE,
                      22.0f * density, text, "PGenerator+ Patch Companion");
    y += 38.0f * density;
    SDL_snprintf(line, sizeof(line), "Server: %s", server ? server : "");
    pairing_draw_text(card_x + 28.0f * density, y, PGEN_FACE_REGULAR,
                      11.0f * density, muted, line);
    y += 34.0f * density;
    pairing_draw_text(card_x + 28.0f * density, y, PGEN_FACE_REGULAR,
                      13.0f * density, text,
                      "Approve this computer in the PGenerator+ WebUI to finish pairing.");
    y += 24.0f * density;
    pairing_draw_text(card_x + 28.0f * density, y, PGEN_FACE_REGULAR,
                      13.0f * density, text, "Check the code shown there matches:");
    y += 31.0f * density;
    {
        const char *shown_code = code && code[0] ? code : "------";
        float code_h = 92.0f * density;
        pairing_fill_rect(card_x + 28.0f * density, y,
                          card_w - 56.0f * density, code_h, inset);
        pairing_frame_rect(card_x + 28.0f * density, y,
                           card_w - 56.0f * density, code_h, border);
        pairing_draw_text(card_x + (card_w - pairing_text_width(PGEN_FACE_MONO,
                          46.0f * density, shown_code)) * 0.5f,
                          y + 17.0f * density, PGEN_FACE_MONO,
                          46.0f * density, accent, shown_code);
        y += code_h + 27.0f * density;
    }
    SDL_snprintf(line, sizeof(line), "Time remaining: %d seconds", seconds_left > 0 ? seconds_left : 0);
    pairing_draw_text(card_x + 28.0f * density, y, PGEN_FACE_BOLD,
                      12.0f * density, text, line);
    y += 24.0f * density;
    pairing_draw_text(card_x + 28.0f * density, y, PGEN_FACE_REGULAR,
                      11.0f * density, muted, "Press Escape to cancel.");
    if (note && note[0]) {
        y += 24.0f * density;
        pairing_draw_text(card_x + 28.0f * density, y, PGEN_FACE_REGULAR,
                          11.0f * density, accent, note);
    }

    return SDL_RenderPresent(app.renderer);
}

/* Set by companion_pair() on any false return, so SDL_AppInit can show the
 * specific reason without threading a buffer through a signature the caller
 * only ever needs to check as a bool. */
static char companion_pair_error[256];

/* Runs the unattended pairing handshake against the PGenerator+ this
 * Companion has already found an address for but has no token for yet. The
 * server side mints a six-digit code and a one-shot request id; this pumps
 * SDL's event queue and redraws the pairing screen itself for up to
 * expires_in seconds, since SDL_AppIterate's own loop has not started yet at
 * this point in SDL_AppInit, while polling for the operator's decision no
 * more often than every 1500 ms. */
static bool companion_pair(void)
{
    char body[256], response[2048];
    char request_id[40] = "", code[16] = "", message[256] = "";
    double expires_in = 180.0, parsed;
    int status;
    uint64_t deadline, next_poll;

    companion_pair_error[0] = '\0';
    SDL_snprintf(body, sizeof(body), "{\"client\":\"%s\",\"platform\":\"%s\",\"version\":\"%s\"}",
                 app.config.client, companion_platform(), APP_VERSION);
    status = http_request(&app.config, "POST", "/api/icc/companion/pair-request", body,
                          response, sizeof(response));
    if (status != 200 || !json_string(response, "request", request_id, sizeof(request_id)) ||
        !json_string(response, "code", code, sizeof(code))) {
        if (!json_string(response, "message", message, sizeof(message)) || !message[0])
            SDL_strlcpy(message, "PGenerator+ did not accept the pairing request.", sizeof(message));
        SDL_strlcpy(companion_pair_error, message, sizeof(companion_pair_error));
        return false;
    }
    if (json_number(response, "expires_in", &parsed) && parsed > 0.0) expires_in = parsed;

    deadline = SDL_GetTicks() + (uint64_t)(expires_in * 1000.0);
    next_poll = SDL_GetTicks();
    for (;;) {
        SDL_Event event;
        uint64_t now = SDL_GetTicks();
        int seconds_left = (int)((deadline > now ? deadline - now : 0) / 1000);

        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_EVENT_QUIT ||
                (event.type == SDL_EVENT_KEY_DOWN && event.key.key == SDLK_ESCAPE)) {
                SDL_strlcpy(companion_pair_error, "Pairing cancelled.", sizeof(companion_pair_error));
                return false;
            }
        }
        if (!render_pairing(code, app.config.server, seconds_left, NULL)) {
            SDL_strlcpy(companion_pair_error, "Could not draw the pairing screen.",
                       sizeof(companion_pair_error));
            return false;
        }
        if (now >= deadline) {
            SDL_strlcpy(companion_pair_error,
                       "Pairing timed out. Try again from the PGenerator+ WebUI.",
                       sizeof(companion_pair_error));
            return false;
        }
        if (now >= next_poll) {
            char path[96], poll_response[512], poll_status[24] = "";
            SDL_snprintf(path, sizeof(path), "/api/icc/companion/pair-status?request=%s", request_id);
            status = http_request(&app.config, "GET", path, NULL, poll_response, sizeof(poll_response));
            next_poll = now + 1500;
            if (status == 200 && json_string(poll_response, "status", poll_status, sizeof(poll_status))) {
                /* "approved" and "denied" are one-shot: the server deletes the
                 * request as soon as this read happens, so the token below
                 * must be kept now - a second poll only ever sees "expired". */
                if (!strcmp(poll_status, "approved")) {
                    char token[96] = "";
                    if (!json_string(poll_response, "token", token, sizeof(token)) ||
                        !token_is_valid(token)) {
                        SDL_strlcpy(companion_pair_error,
                                   "PGenerator+ approved pairing but did not send a usable token.",
                                   sizeof(companion_pair_error));
                        return false;
                    }
                    SDL_strlcpy(app.config.token, token, sizeof(app.config.token));
                    if (!save_config(&app.config)) {
                        render_pairing(code, app.config.server, seconds_left,
                                      "Paired, but could not save the token for next launch.");
                        SDL_Delay(2000);
                    }
                    return true;
                }
                if (!strcmp(poll_status, "denied")) {
                    SDL_strlcpy(companion_pair_error,
                               "Pairing was denied in the PGenerator+ WebUI.",
                               sizeof(companion_pair_error));
                    return false;
                }
                if (!strcmp(poll_status, "expired")) {
                    SDL_strlcpy(companion_pair_error,
                               "Pairing request expired. Try again from the PGenerator+ WebUI.",
                               sizeof(companion_pair_error));
                    return false;
                }
                /* "pending": keep waiting. */
            }
        }
        SDL_Delay(16);
    }
}

SDL_AppResult SDL_AppInit(void **appstate, int argc, char *argv[])
{
    memset(&app, 0, sizeof(app));
    app.displayed_max_luma = app.command_max_luma = 1000.0;
    app.displayed_min_luma = app.command_min_luma = 0.005;
    app.displayed_max_cll = app.command_max_cll = 1000.0;
    app.displayed_max_fall = app.command_max_fall = 400.0;
    SDL_strlcpy(app.correction_mode, "system", sizeof(app.correction_mode));
    app.correction_ready = true;
    SDL_strlcpy(app.correction_signal_mode, "sdr", sizeof(app.correction_signal_mode));
#ifdef _WIN32
    {
        WSADATA data;
        if (WSAStartup(MAKEWORD(2, 2), &data) != 0) return SDL_APP_FAILURE;
    }
#endif
    if (!load_config(&app.config, argc, argv)) {
        SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "PGenerator+ Patch Companion",
                                 "Could not find a PGenerator+ on this network. PGenerator+ answers to "
                                 "the name " PGEN_DISCOVERY_HOST ". If this computer cannot resolve that "
                                 "name, put a line reading SERVER=http://<address of your PGenerator+> "
                                 "in " PGEN_CONF_NAME " beside this program, or start it with "
                                 "--server=http://<address>.", NULL);
        return SDL_APP_FAILURE;
    }
    if (!SDL_Init(SDL_INIT_VIDEO)) {
        SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "PGenerator+ Patch Companion",
                                 SDL_GetError()[0] ? SDL_GetError()
                                                   : "Could not initialize video.",
                                 NULL);
        return SDL_APP_FAILURE;
    }
    app.network_mutex = SDL_CreateMutex();
    if (!app.network_mutex) return SDL_APP_FAILURE;
    app.window = SDL_CreateWindow(APP_TITLE, 1280, 720,
                                  SDL_WINDOW_HIGH_PIXEL_DENSITY | SDL_WINDOW_RESIZABLE);
    if (!app.window) {
        SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "PGenerator+ Patch Companion",
                                 SDL_GetError()[0] ? SDL_GetError()
                                                   : "Could not create the Patch Companion window.",
                                 NULL);
        return SDL_APP_FAILURE;
    }
    /* Calibration patches must not be altered by the desktop's idle dimming
     * policy during a long series. On Wayland SDL implements this with the
     * compositor idle-inhibit protocol for the lifetime of this window. */
    SDL_DisableScreenSaver();
#ifdef _WIN32
    /* Idle transitions degrade the HDR pipeline mid-session even with the
     * screensaver off: unattended meter runs measured a tone-mapped panel
     * until the session was interacted with. Assert a display requirement
     * for the process lifetime; cleared in SDL_AppQuit. */
    SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED);
#endif
#ifdef _WIN32
    set_windows_window_icon();
#else
    set_embedded_window_icon();
#endif
    if (!select_target_display()) {
        char detail[320];
        const char *error = SDL_GetError();
        if (error && error[0])
            SDL_snprintf(detail, sizeof(detail),
                         "Could not select the profiling display.\n\n%s", error);
        else
            SDL_strlcpy(detail, "Could not select the profiling display.", sizeof(detail));
        SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "PGenerator+ Patch Companion",
                                 detail, app.window);
        return SDL_APP_FAILURE;
    }
    app.fullscreen = false;
    app.displayed_size = 100;
    if (!create_renderer(false)) {
        char detail[320];
        const char *error = SDL_GetError();
        if (error && error[0])
            SDL_snprintf(detail, sizeof(detail),
                         "Could not create the Patch Companion renderer.\n\n%s", error);
        else
            SDL_strlcpy(detail, "Could not create the Patch Companion renderer.", sizeof(detail));
        SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "PGenerator+ Patch Companion",
                                 detail, app.window);
        return SDL_APP_FAILURE;
    }
    if (!render_alignment()) {
        SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "PGenerator+ Patch Companion",
                                 "Could not draw the alignment target.", app.window);
        return SDL_APP_FAILURE;
    }
    if (!app.config.token[0]) {
        /* A static, unpaired download has an address but no token yet: ask
         * the operator to approve this computer in the WebUI before falling
         * through to the normal alignment target and network thread below. */
        if (!companion_pair()) {
            SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "PGenerator+ Patch Companion",
                                     companion_pair_error[0] ? companion_pair_error
                                                              : "Pairing with PGenerator+ failed.",
                                     app.window);
            return SDL_APP_FAILURE;
        }
        if (!render_alignment()) {
            SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "PGenerator+ Patch Companion",
                                     "Could not draw the alignment target after pairing.",
                                     app.window);
            return SDL_APP_FAILURE;
        }
    }
    SDL_strlcpy(app.ack_renderer, app.renderer_name, sizeof(app.ack_renderer));
    app.ack_hdr_active = app.hdr_active;
    SDL_SetAtomicInt(&app.quit_requested, 0);
    SDL_SetAtomicInt(&app.install_in_progress, 0);
    app.network_thread = SDL_CreateThread(network_thread_main, "PGen ICC network", NULL);
    if (!app.network_thread) {
        SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "PGenerator+ Patch Companion",
                                 "Could not start the network thread.", app.window);
        return SDL_APP_FAILURE;
    }
    *appstate = &app;
    return SDL_APP_CONTINUE;
}

SDL_AppResult SDL_AppEvent(void *appstate, SDL_Event *event)
{
    AppState *state = (AppState *)appstate;
    if (event->type == SDL_EVENT_QUIT) return SDL_APP_SUCCESS;
    if (event->type == SDL_EVENT_WINDOW_HDR_STATE_CHANGED) {
        /* The desktop's HDR state changed (for example the user just enabled
         * HDR for the display), so a cooled-down HDR failure is stale. */
        hdr_attempt_cooldown_until = 0;
    }
    if (event->type == SDL_EVENT_WINDOW_HDR_STATE_CHANGED &&
        (state->renderer
#ifdef _WIN32
         || state->hdr_swapchain
#endif
        )) {
        update_renderer_hdr_state();
        SDL_LockMutex(state->network_mutex);
        state->ack_hdr_active = state->hdr_active;
        SDL_UnlockMutex(state->network_mutex);
        render_current_frame();
    }
    if (event->type == SDL_EVENT_WINDOW_ENTER_FULLSCREEN) {
        state->fullscreen = true;
        raise_pattern_window();
        render_current_frame();
    }
    if (event->type == SDL_EVENT_WINDOW_LEAVE_FULLSCREEN) {
        state->fullscreen = false;
        SDL_SetWindowAlwaysOnTop(state->window, false);
        render_current_frame();
    }
    if (event->type == SDL_EVENT_KEY_DOWN) {
        if (event->key.key == SDLK_ESCAPE) return SDL_APP_SUCCESS;
        if (event->key.key == SDLK_F11) {
#ifdef _WIN32
            bool fullscreen = !state->fullscreen;
#else
            SDL_WindowFlags flags = SDL_GetWindowFlags(state->window);
            bool fullscreen = (flags & SDL_WINDOW_FULLSCREEN) == 0;
#endif
            apply_display_settings(fullscreen, state->displayed_size);
        }
    }
    if (event->type == SDL_EVENT_WINDOW_EXPOSED ||
        event->type == SDL_EVENT_WINDOW_FOCUS_GAINED ||
        event->type == SDL_EVENT_WINDOW_RESTORED ||
        event->type == SDL_EVENT_WINDOW_SHOWN ||
        event->type == SDL_EVENT_WINDOW_RESIZED ||
        event->type == SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED) {
        render_current_frame();
    }
    return SDL_APP_CONTINUE;
}

SDL_AppResult SDL_AppIterate(void *appstate)
{
    AppState *state = (AppState *)appstate;
    process_network_updates();
#ifdef _WIN32
    /* A flip-model swapchain owns multiple buffers. Keep drawing the active
     * HDR patch every refresh, as dogegen does, so the desktop compositor can
     * never surface an untouched or stale buffer after a Present rotation. */
    if (state->hdr_swapchain && !render_current_frame()) return SDL_APP_FAILURE;
#else
    /* Vulkan swapchains rotate multiple images too. Keep every image filled
     * with the active patch so KWin cannot present an older frame after a
     * series advances. Focus and expose events used to hide this by causing an
     * extra redraw, which is why Alt-Tab appeared to repair the patch. */
    if (state->hdr && state->renderer && SDL_GetTicks() < state->refresh_until_ms) {
        if (!render_current_frame()) return SDL_APP_FAILURE;
    }
#endif
    SDL_Delay(10);
    return state->quit ? SDL_APP_SUCCESS : SDL_APP_CONTINUE;
}

void SDL_AppQuit(void *appstate, SDL_AppResult result)
{
#ifdef _WIN32
    SetThreadExecutionState(ES_CONTINUOUS);
#endif
    AppState *state = (AppState *)appstate;
    (void)result;
    if (state) {
        SDL_SetAtomicInt(&state->quit_requested, 1);
        if (state->network_thread) SDL_WaitThread(state->network_thread, NULL);
        if (state->install_thread) SDL_WaitThread(state->install_thread, NULL);
#ifdef _WIN32
        if (state->windows_correction_isolated &&
            !windows_set_correction_isolation(false))
            SDL_Log("Could not restore Windows profile handling while exiting");
#endif
#if !defined(_WIN32) && !defined(__APPLE__)
        kwin_restore_profile_source();
#endif
        if (state->texture) SDL_DestroyTexture(state->texture);
        if (state->background_texture) SDL_DestroyTexture(state->background_texture);
        if (state->renderer) SDL_DestroyRenderer(state->renderer);
#ifdef _WIN32
        windows_destroy_hdr_output();
#endif
        SDL_free(state->correction_lut);
        SDL_free(state->correction_profile_data);
        if (state->window) SDL_DestroyWindow(state->window);
        if (state->network_mutex) SDL_DestroyMutex(state->network_mutex);
    }
    SDL_Quit();
#ifdef _WIN32
    WSACleanup();
#endif
}
