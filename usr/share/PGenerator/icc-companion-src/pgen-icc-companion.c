/* PGenerator+ Patch Companion
 *
 * Displays measurement patches through the target computer's native output
 * pipeline. Windows uses a native DXGI HDR10 swapchain so PQ/BT.2020 patch
 * codes reach the operating-system HDR pipeline without scRGB remapping.
 */

#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
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
#include <unistd.h>
#define close_socket close
typedef int socket_handle_t;
#define INVALID_SOCKET_HANDLE (-1)
/* Windows takes its icon from the resource script. Everywhere else the same
 * artwork is compiled in, because the Companion ships as a small zip that must
 * not gain a runtime file dependency. */
#include "pgen-icc-companion-icon.h"
#endif

#define APP_VERSION "1.3.39"
/* Width in source code units over which the grey-axis calibration blends into
 * the cLUT result. */
#define PGEN_NEUTRAL_BLEND 0.06
#define RESPONSE_CAPACITY 32768
#define PGEN_UNUSED __attribute__((unused))

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
    SDL_Mutex *network_mutex;
    SDL_AtomicInt quit_requested;
    bool command_pending;
    uint64_t command_sequence;
    bool command_alignment;
    double command_r, command_g, command_b;
    double command_max_luma, command_min_luma;
    double command_max_cll, command_max_fall;
    int command_size;
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
#ifdef _WIN32
    unsigned char *correction_profile_data;
    size_t correction_profile_size;
#endif
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
                                   bool hdr_mode)
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
        SDL_free(displays);
        return true;
    }
    if (app.config.display[0]) {
        for (int index = 0; index < count; index++) {
            const char *name = SDL_GetDisplayName(displays[index]);
            if (name && (SDL_strcasecmp(name, app.config.display) == 0 ||
                         SDL_strcasestr(name, app.config.display))) {
                selected = index + 1;
                goto display_selected;
            }
        }
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
        if (index == 0) buttons[index].flags = SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT;
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
        const char *name = SDL_GetDisplayName(displays[selected - 1]);
        SDL_strlcpy(app.selected_display, name ? name : "Unnamed display",
                    sizeof(app.selected_display));
    }
    if (!SDL_GetDisplayUsableBounds(displays[selected - 1], &bounds)) {
        ok = false;
        goto done;
    }
    {
        int width = 1280, height = 720;
        int x, y;
        SDL_GetWindowSize(app.window, &width, &height);
        x = bounds.x + (bounds.w - width) / 2;
        y = bounds.y + (bounds.h - height) / 2;
        if (!SDL_SetWindowPosition(app.window, x, y)) {
            ok = false;
            goto done;
        }
        SDL_SyncWindow(app.window);
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

static bool load_config(CompanionConfig *config)
{
    char path[1024];
    const char *base = SDL_GetBasePath();
    FILE *file;
    char line[512];
    memset(config, 0, sizeof(*config));
    config->port = 80;
    SDL_snprintf(path, sizeof(path), "%sPGenICCCompanion.conf", base ? base : "");
    file = fopen(path, "rb");
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
        if (!strcmp(line, "SERVER")) SDL_strlcpy(config->server, equals, sizeof(config->server));
        else if (!strcmp(line, "TOKEN")) SDL_strlcpy(config->token, equals, sizeof(config->token));
        else if (!strcmp(line, "DISPLAY")) SDL_strlcpy(config->display, equals, sizeof(config->display));
    }
    fclose(file);
    if (!config->server[0] || !config->token[0]) return false;

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
#else
    if (gethostname(config->client, sizeof(config->client) - 1) != 0) SDL_strlcpy(config->client, "Linux-PC", sizeof(config->client));
#endif
    for (char *p = config->client; *p; p++) if (!isalnum((unsigned char)*p) && *p != '-' && *p != '_') *p = '_';
    return config->host[0] && config->port > 0 && config->port < 65536;
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

/* Which build this is; only these two are packaged. Reported so the server can
 * describe what is genuinely unavailable instead of showing an empty value as a
 * failure: reading the display's active ICC profile, and the active-profile
 * transforms that depend on it, are Windows-only. */
static const char *companion_platform(void)
{
#ifdef _WIN32
    return "windows";
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

#ifdef _WIN32
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
    double determinant = m[0][0]*(m[1][1]*m[2][2]-m[1][2]*m[2][1])-
                         m[0][1]*(m[1][0]*m[2][2]-m[1][2]*m[2][0])+
                         m[0][2]*(m[1][0]*m[2][1]-m[1][1]*m[2][0]);
    if (fabs(determinant) < 1e-12) return false;
    out[0][0]=(m[1][1]*m[2][2]-m[1][2]*m[2][1])/determinant;
    out[0][1]=(m[0][2]*m[2][1]-m[0][1]*m[2][2])/determinant;
    out[0][2]=(m[0][1]*m[1][2]-m[0][2]*m[1][1])/determinant;
    out[1][0]=(m[1][2]*m[2][0]-m[1][0]*m[2][2])/determinant;
    out[1][1]=(m[0][0]*m[2][2]-m[0][2]*m[2][0])/determinant;
    out[1][2]=(m[0][2]*m[1][0]-m[0][0]*m[1][2])/determinant;
    out[2][0]=(m[1][0]*m[2][1]-m[1][1]*m[2][0])/determinant;
    out[2][1]=(m[0][1]*m[2][0]-m[0][0]*m[2][1])/determinant;
    out[2][2]=(m[0][0]*m[1][1]-m[0][1]*m[1][0])/determinant;
    return true;
}

/* Bradford adaptation from the profile's media white onto the D50 PCS white.
 * ArgyllCMS adapts display profiles with this transform and bakes it into the
 * cLUT, leaving wtpt holding the unadapted native white and no chad tag to
 * read back. Scaling XYZ channel-wise from wtpt to the PCS white -- the old
 * shortcut -- lands neutral away from where the profile expects it and biases
 * the corrected white point. */
static bool companion_adaptation(const double media_white[3], double out[3][3])
{
    static const double bradford[3][3]={{0.8951,0.2664,-0.1614},{-0.7502,1.7135,0.0367},{0.0389,-0.0685,1.0296}};
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
        if (!strcmp(signal_mode,"hdr10")) linear[channel]=fmin(1.0,pq_to_nits(rgb[channel])/fmax(white_nits,1e-6));
        else linear[channel]=rgb[channel]<=0.04045?rgb[channel]/12.92:pow((rgb[channel]+0.055)/1.055,2.4);
    }
    const double (*source)[3]=!strcmp(signal_mode,"hdr10")?bt2020_xyz:srgb_xyz;
    for(int row=0;row<3;row++) intermediate[row]=source[row][0]*linear[0]+source[row][1]*linear[1]+source[row][2]*linear[2];
    for(int row=0;row<3;row++)
        xyz[row]=adaptation[row][0]*intermediate[0]+adaptation[row][1]*intermediate[1]+adaptation[row][2]*intermediate[2];
}

/* Absolute luminance of the profile's PCS white. The measurement set is
 * normalised so PCS Y=1.0 is the profiling white, and ArgyllCMS embeds that
 * value as LUMINANCE_XYZ_CDM2 in the retained characterization tags. The lumi
 * tag is not interchangeable: for Windows HDR profiles the builder writes the
 * MHC2-calibrated peak there, which is lower by the white-balance headroom the
 * matrix takes, so normalising PQ by it over-drives every level. */
static bool companion_characterization_white(double *white_nits)
{
    static const char *names[3]={"targ","CIED","DevD"};
    for(int index=0;index<3;index++) {
        IccTag tag=icc_tag(app.correction_profile_data,app.correction_profile_size,names[index]);
        if(!tag.data||tag.size<16||memcmp(tag.data,"text",4)) continue;
        for(size_t offset=8;offset+18<tag.size;offset++) {
            if(memcmp(tag.data+offset,"LUMINANCE_XYZ_CDM2",18)) continue;
            const char *cursor=(const char *)tag.data+offset+18;
            const char *limit=(const char *)tag.data+tag.size;
            char buffer[128];
            size_t length=0;
            while(cursor<limit&&*cursor!='"') cursor++;
            if(cursor>=limit) break;
            cursor++;
            while(cursor<limit&&*cursor!='"'&&length<sizeof(buffer)-1) buffer[length++]=*cursor++;
            buffer[length]='\0';
            char *end=NULL;
            double x=strtod(buffer,&end);
            if(end==buffer) break;
            double y=strtod(end,&end);
            (void)x;
            if(isfinite(y)&&y>0.0) { *white_nits=y; return true; }
            break;
        }
    }
    return false;
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
    double clut_result[3]={0,0,0};
    for(int corner=0;corner<8;corner++) {
        double weight=1.0; int coordinate[3];
        for(int axis=0;axis<3;axis++){bool upper=(corner&(1<<axis))!=0;coordinate[axis]=base[axis]+(upper?1:0);weight*=upper?fraction[axis]:1.0-fraction[axis];}
        size_t offset=clut_offset+(size_t)(((coordinate[0]*grid+coordinate[1])*grid+coordinate[2])*3)*2;
        for(int channel=0;channel<3;channel++) clut_result[channel]+=weight*read_be16(tag.data+offset+channel*2)/65535.0;
    }
    for(int channel=0;channel<3;channel++) output[channel]=icc_table_sample(tag.data+output_offset+(size_t)channel*out_count*2,out_count,clut_result[channel]);
    return true;
}

static double linear_to_pq(double value)
{
    const double m1=2610.0/16384.0,m2=2523.0/32.0;
    const double c1=3424.0/4096.0,c2=2413.0/128.0,c3=2392.0/128.0;
    double power=pow(fmax(0.0,value),m1);
    return pow((c1+c2*power)/(1.0+c3*power),m2);
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
/* Undo the MHC2 stage Windows applies to windowed output.
 *
 * In windowed mode Windows applies the active profile's MHC2 calibration to
 * the Companion's surface. When the Companion is also applying that profile's
 * cLUT, the display is corrected twice and the shadows overshoot -- which is
 * what lifted blacks in a windowed post-calibration read. Fullscreen does not
 * have the problem because Windows bypasses MHC2 for a borderless
 * monitor-covering swapchain, which is why the two modes disagreed.
 *
 * Pre-compensating with the inverse cancels the OS stage, so windowed and
 * fullscreen land on the same corrected output.
 */
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

/* Sample one vcgt channel curve. */
static bool vcgt_table(const unsigned char **table,uint32_t *entries)
{
    IccTag tag=icc_tag(app.correction_profile_data,app.correction_profile_size,"vcgt");
    if(!tag.data||tag.size<18||memcmp(tag.data,"vcgt",4))return false;
    if(read_be32(tag.data+8)!=0)return false;
    uint32_t channels=read_be16(tag.data+12),count=read_be16(tag.data+14),size=read_be16(tag.data+16);
    if(channels!=3||count<2||size!=2)return false;
    if(tag.size<18u+(size_t)channels*count*2u)return false;
    *table=tag.data+18;*entries=count;
    return true;
}

static double vcgt_sample(const unsigned char *table,uint32_t entries,int channel,double value)
{
    if(!(value>0.0))value=0.0;
    if(value>1.0)value=1.0;
    double position=value*(double)(entries-1);
    uint32_t low=(uint32_t)position;
    if(low>entries-2)low=entries-2;
    double fraction=position-(double)low;
    const unsigned char *base=table+(size_t)channel*entries*2u;
    double first=read_be16(base+(size_t)low*2)/65535.0;
    double second=read_be16(base+((size_t)low+1)*2)/65535.0;
    return first*(1.0-fraction)+second*fraction;
}

/* Apply vcgt to the SOURCE code rather than to the cLUT's output.
 *
 * vcgt is normally a post-transform stage, but that is precisely why it could
 * not fix the grey axis: the cLUT converts absolute PCS XYZ into a code, and
 * its shadow grid cannot resolve that conversion, so the error is already
 * baked in before vcgt ever sees the value. Measured on one panel, 5% stimulus
 * still landed 6.7x short of target with vcgt applied downstream.
 *
 * The calibration is parameterised on absolute PQ, so for a neutral patch the
 * correct device value is simply curve(code) -- no cLUT involved. That is the
 * same position MHC2 occupies, and the reason MHC2 tracks the grey axis while
 * a downstream vcgt cannot. Chromatic patches still need the cLUT, so the two
 * are blended by how neutral the request is rather than switched at a
 * threshold, which would put a seam one code off neutral.
 */
static bool apply_vcgt_direct(const double rgb[3],double output[3])
{
    const unsigned char *table;uint32_t entries;
    if(!vcgt_table(&table,&entries))return false;
    for(int channel=0;channel<3;channel++)output[channel]=vcgt_sample(table,entries,channel,rgb[channel]);
    return true;
}

static bool apply_local_mhc2(const double input[3], double output[3])
{
    static const double wire[3][3]={{0.6369580,0.1446169,0.1688810},{0.2627002,0.6779981,0.0593017},{0.0,0.0280727,1.0609851}};
    IccTag tag=icc_tag(app.correction_profile_data,app.correction_profile_size,"MHC2");
    double inverse_wire[3][3],linear[3],xyz[3],adjusted[3],target[3];
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
    for(int channel=0;channel<3;channel++)linear[channel]=pq_to_nits(input[channel])/10000.0;
    for(int row=0;row<3;row++)xyz[row]=wire[row][0]*linear[0]+wire[row][1]*linear[1]+wire[row][2]*linear[2];
    for(int row=0;row<3;row++)adjusted[row]=matrix[row][0]*xyz[0]+matrix[row][1]*xyz[1]+matrix[row][2]*xyz[2];
    for(int row=0;row<3;row++)target[row]=inverse_wire[row][0]*adjusted[0]+inverse_wire[row][1]*adjusted[1]+inverse_wire[row][2]*adjusted[2];
    for(int channel=0;channel<3;channel++){
        double encoded=linear_to_pq(target[channel]);
        output[channel]=count?mhc2_curve_sample(tag.data+curve_offsets[channel],count,encoded):encoded;
    }
    return true;
}

#endif

static bool load_correction_lut(uint64_t revision)
{
#ifdef _WIN32
    FILE *file;
    long length;
#endif
    /* "none" is a true passthrough: no profile is required and nothing is
     * applied. "system" still needs the profile for the fullscreen MHC2
     * stand-in below, so the two are only equivalent for readiness. */
    bool system_mode=!strcmp(app.correction_mode,"system")||!strcmp(app.correction_mode,"none");
    /* Never retain a transform from a previously selected profile if the new
     * LUT cannot be downloaded or decoded. A stale correction would produce a
     * valid patch acknowledgement while applying the wrong profile. */
    SDL_free(app.correction_lut);
    app.correction_lut = NULL;
    app.correction_lut_grid = 0;
    app.correction_ready = system_mode;
#ifndef _WIN32
    /* Report the real reason first. Reading the display's active profile and
     * applying it are both Windows-only here, so the generic "the operating
     * system did not report an active ICC profile" message below would blame a
     * missing profile for something this build cannot do at all. */
    if (!system_mode) {
        app.correction_ready = false;
        SDL_strlcpy(app.correction_error,
                    "Active-profile correction needs the Windows Companion",
                    sizeof(app.correction_error));
        return false;
    }
    app.correction_lut_revision = revision;
    app.correction_error[0] = '\0';
    return true;
#endif
    if (!app.correction_profile[0]) {
        if(system_mode){app.correction_lut_revision=revision;app.correction_error[0]='\0';return true;}
        app.correction_ready = false;
        SDL_strlcpy(app.correction_error, "The operating system did not report an active ICC profile for the selected display", sizeof(app.correction_error));
        return false;
    }
#ifdef _WIN32
    file=_wfopen(app.correction_profile_path,L"rb");
    if(!file||fseek(file,0,SEEK_END)!=0||(length=ftell(file))<132||length>16*1024*1024||fseek(file,0,SEEK_SET)!=0){if(file)fclose(file);if(system_mode){app.correction_lut_revision=revision;app.correction_error[0]='\0';return true;}SDL_strlcpy(app.correction_error,"Could not open the active Windows display profile",sizeof(app.correction_error));return false;}
    SDL_free(app.correction_profile_data); app.correction_profile_data=SDL_malloc((size_t)length); app.correction_profile_size=0;
    if(!app.correction_profile_data||fread(app.correction_profile_data,1,(size_t)length,file)!=(size_t)length){fclose(file);SDL_free(app.correction_profile_data);app.correction_profile_data=NULL;SDL_strlcpy(app.correction_error,"Could not read the active Windows display profile",sizeof(app.correction_error));return false;}
    fclose(file); app.correction_profile_size=(size_t)length;
    if(memcmp(app.correction_profile_data+12,"mntr",4)||memcmp(app.correction_profile_data+16,"RGB ",4)||memcmp(app.correction_profile_data+20,"XYZ ",4)){SDL_free(app.correction_profile_data);app.correction_profile_data=NULL;app.correction_profile_size=0;SDL_strlcpy(app.correction_error,"The active Windows profile is not a supported RGB display profile",sizeof(app.correction_error));return false;}
#endif
    app.correction_lut_revision = revision;
    app.correction_error[0] = '\0';
    app.correction_ready = true;
    return true;
}

static bool apply_correction_lut(double *red, double *green, double *blue)
{
#ifdef _WIN32
    double rgb[3]={*red,*green,*blue},xyz[3],output[3],white_nits=1.0;
    double media_white[3],adaptation[3][3];
#endif
#ifdef _WIN32
    /* Pure passthrough. Profiling selects this so the characterization
     * measures the panel itself: "system" is NOT a no-correction mode,
     * because the branch below deliberately applies MHC2 on fullscreen HDR
     * where Windows would skip it. */
    if(!strcmp(app.correction_mode,"none")) return true;
    if(!strcmp(app.correction_mode,"system")){
        /* Windows can bypass an HDR profile's MHC2 transform for a
         * borderless monitor-covering swapchain even when DWM reports the
         * presentation as composed. Apply that native HDR calibration stage
         * ourselves for fullscreen Companion output. Windowed output remains
         * OS-managed so Windows cannot apply the same MHC2 transform twice. */
        if((app.fullscreen||app.settings_fullscreen)&&app.correction_profile_data&&
           !strcmp(app.correction_signal_mode,"hdr10")&&apply_local_mhc2(rgb,output)){
            *red=output[0];*green=output[1];*blue=output[2];
        }
        return true;
    }
    if(!app.correction_profile_data)return false;
    /* Neutral HDR patches used to be diverted to MHC2 here, because a
     * relative-colorimetric BToA maps PCS white onto the uncalibrated media
     * white and so returned neutrals at the panel's native white. That is a
     * property of how the PCS target was built, not of the table: adapting the
     * requested XYZ with the profile's own Bradford transform now lands
     * neutral on the requested white through the cLUT itself.
     *
     * Keeping the diversion actively hurt. It corrected the grey axis with a
     * different engine than everything around it, so an exactly neutral patch
     * and a patch one code off neutral took different paths and disagreed at
     * the boundary, and the grey axis inherited the MHC2 curves' behaviour of
     * freezing once the measured channel response saturates. In these modes
     * the Companion is the only correction stage, so one transform handles the
     * whole space. MHC2 still runs for correction_mode "system", where it
     * stands in for the calibration stage Windows skips on fullscreen output. */
    {IccTag wtpt=icc_tag(app.correction_profile_data,app.correction_profile_size,"wtpt");if(!wtpt.data||wtpt.size<20||memcmp(wtpt.data,"XYZ ",4))return false;for(int channel=0;channel<3;channel++){media_white[channel]=read_s15(wtpt.data+8+channel*4);if(media_white[channel]<=0.0)return false;}}
    if(!companion_adaptation(media_white,adaptation))return false;
    if(!strcmp(app.correction_signal_mode,"hdr10")&&!companion_characterization_white(&white_nits)){
        IccTag lumi=icc_tag(app.correction_profile_data,app.correction_profile_size,"lumi");
        if(!lumi.data||lumi.size<20||memcmp(lumi.data,"XYZ ",4)||(white_nits=read_s15(lumi.data+12))<=0.0)return false;
    }
    companion_source_xyz(rgb,app.correction_signal_mode,white_nits,adaptation,xyz);
    if(!strcmp(app.correction_mode,"clut")){if(!apply_local_clut(xyz,output))return false;}
    else if(!apply_local_matrix(xyz,output))return false;
    /* No vcgt after the cLUT. The cLUT is fitted to raw measurements, so it is
     * already a complete PCS->device transform and composing a calibration on
     * top would correct twice. The 1D stage runs on the SOURCE code below,
     * where it bypasses the cLUT's shadow grid. */
    {
        /* On the grey axis take the calibration straight from the source code
         * instead, bypassing the cLUT whose shadow grid cannot resolve the PQ
         * conversion. Blend by how neutral the request is so there is no seam
         * one code off neutral.
         *
         * MHC2 is preferred over vcgt here: both carry the same measured 1D
         * response, but MHC2 also carries the 3x3, so it corrects chromaticity
         * as well as tone. vcgt is per-channel only and can do no more than
         * scale each channel, which measured a worse white point. vcgt remains
         * the fallback for profiles built without an MHC2 tag. */
        double direct[3];
        double high=rgb[0]>rgb[1]?(rgb[0]>rgb[2]?rgb[0]:rgb[2]):(rgb[1]>rgb[2]?rgb[1]:rgb[2]);
        double low=rgb[0]<rgb[1]?(rgb[0]<rgb[2]?rgb[0]:rgb[2]):(rgb[1]<rgb[2]?rgb[1]:rgb[2]);
        double spread=high-low;
        double weight=1.0-spread/PGEN_NEUTRAL_BLEND;
        if(weight>0.0&&(apply_local_mhc2(rgb,direct)||apply_vcgt_direct(rgb,direct))){
            if(weight>1.0)weight=1.0;
            for(int channel=0;channel<3;channel++)
                output[channel]=weight*direct[channel]+(1.0-weight)*output[channel];
        }
    }
    if(!app.fullscreen&&!app.settings_fullscreen){
        /* Windowed output still passes through the OS MHC2 stage, so cancel it
         * here or the display is corrected twice. */
        apply_mhc2_inverse(output);
    }
    *red = output[0]; *green = output[1]; *blue = output[2];
    return true;
#else
    (void)red; (void)green; (void)blue;
    /* "none" and "system" are the same true passthrough here: there is no
     * OS-managed display transform to apply, and none to cancel either, so the
     * requested code reaches the panel unchanged. Returning false for them
     * rejected every patch this Companion was ever sent. The active-profile
     * modes really cannot run, and say so. */
    return !strcmp(app.correction_mode, "none") ||
           !strcmp(app.correction_mode, "system");
#endif
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
    windows_nvapi_hdr_source_begin(app.window);
    app.hdr = true;
    app.hdr_active = windows_window_hdr_enabled(app.window);
    if (pgen_nvapi_source_active)
        SDL_strlcpy(app.renderer_name, "direct3d11-hdr10-nvapi-rec2100",
                    sizeof(app.renderer_name));
    else
        SDL_snprintf(app.renderer_name, sizeof(app.renderer_name),
                     "direct3d11-hdr10-nvapi-error-%d",
                     pgen_nvapi_last_status);
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
    const double m1 = 2610.0 / 16384.0;
    const double m2 = 2523.0 / 32.0;
    const double c1 = 3424.0 / 4096.0;
    const double c2 = 2413.0 / 128.0;
    const double c3 = 2392.0 / 128.0;
    double p = pow(fmax(0.0, fmin(1.0, value)), 1.0 / m2);
    return 10000.0 * pow(fmax(p - c1, 0.0) / fmax(c2 - c3 * p, 1e-12), 1.0 / m1);
}

static void patch_to_sdr_linear(double r, double g, double b, float output[4])
{
    output[0] = srgb_to_linear((float)r);
    output[1] = srgb_to_linear((float)g);
    output[2] = srgb_to_linear((float)b);
    output[3] = 1.0f;
}

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

static bool update_renderer_hdr_state(void)
{
    SDL_PropertiesID renderer_props;
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
    app.hdr_active = SDL_GetBooleanProperty(renderer_props, SDL_PROP_RENDERER_HDR_ENABLED_BOOLEAN, false);
#ifdef _WIN32
    /* SDL derives this flag from its dynamic HDR-headroom property. Some
     * Windows drivers leave that property at 1.0 even while DWM is actively
     * presenting the selected monitor in the HDR10 output colorspace. DXGI's
     * output description reflects the actual monitor pipeline in that case. */
    if (app.hdr && !app.hdr_active && windows_window_hdr_enabled(app.window))
        app.hdr_active = true;
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
    if (app.renderer) { SDL_DestroyRenderer(app.renderer); app.renderer = NULL; }
}

static SDL_Texture *create_patch_texture(bool hdr)
{
    SDL_PropertiesID props = SDL_CreateProperties();
    SDL_Texture *texture;
    if (!props) return NULL;
    SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_FORMAT_NUMBER,
                          hdr ? SDL_PIXELFORMAT_ABGR2101010 : SDL_PIXELFORMAT_RGBA128_FLOAT);
    SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_ACCESS_NUMBER, SDL_TEXTUREACCESS_STREAMING);
    SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_WIDTH_NUMBER, 1);
    SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_HEIGHT_NUMBER, 1);
    if (hdr) {
        SDL_PropertiesID renderer_props = SDL_GetRendererProperties(app.renderer);
        float output_headroom = SDL_GetFloatProperty(
            renderer_props, SDL_PROP_RENDERER_HDR_HEADROOM_FLOAT, 1.0f);
        if (!isfinite(output_headroom) || output_headroom <= 0.0f) output_headroom = 1.0f;
        SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_COLORSPACE_NUMBER, SDL_COLORSPACE_HDR10);
        /* Match the source metadata to the active output headroom. This keeps
         * SDL's required HDR10-to-scRGB transport conversion but disables its
         * optional source-to-display tone-mapping pass. */
        SDL_SetFloatProperty(props, SDL_PROP_TEXTURE_CREATE_HDR_HEADROOM_FLOAT, output_headroom);
    } else {
        SDL_SetNumberProperty(props, SDL_PROP_TEXTURE_CREATE_COLORSPACE_NUMBER, SDL_COLORSPACE_SRGB_LINEAR);
    }
    texture = SDL_CreateTextureWithProperties(app.renderer, props);
    SDL_DestroyProperties(props);
    return texture;
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
    SDL_SetNumberProperty(props, SDL_PROP_RENDERER_CREATE_OUTPUT_COLORSPACE_NUMBER,
                          hdr ? SDL_COLORSPACE_SRGB_LINEAR : SDL_COLORSPACE_SRGB);
    if (driver) SDL_SetStringProperty(props, SDL_PROP_RENDERER_CREATE_NAME_STRING, driver);
    app.renderer = SDL_CreateRendererWithProperties(props);
    SDL_DestroyProperties(props);
    if (!app.renderer) return false;
    app.hdr = hdr;
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
         * Give DWM and the renderer time to publish the dynamic state. */
        hdr_deadline = SDL_GetTicks() + 1000;
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
            SDL_SetError("The scRGB renderer did not enter HDR after its first presented frame");
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

static bool create_renderer(bool hdr)
{
#ifndef _WIN32
    const char *hdr_drivers[] = { "vulkan", "gpu", NULL };
    size_t index;
#endif
    char last_error[256] = "No HDR renderer was available";

    if (!hdr) return try_create_renderer(false, NULL);
#ifdef _WIN32
    destroy_renderer();
    if (windows_create_hdr_output()) return true;
    SDL_strlcpy(last_error, SDL_GetError(), sizeof(last_error));
#else
    for (index = 0; index < SDL_arraysize(hdr_drivers); index++) {
        if (try_create_renderer(true, hdr_drivers[index])) return true;
        if (SDL_GetError() && SDL_GetError()[0]) {
            SDL_strlcpy(last_error, SDL_GetError(), sizeof(last_error));
        }
    }
#endif

    /* Keep the alignment target usable after an HDR failure, while preserving
     * the failure result so the server does not measure an SDR fallback. */
    try_create_renderer(false, NULL);
    if (app.renderer) render_alignment();
    SDL_SetError("HDR renderer unavailable: %s", last_error);
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
    uint32_t hdr_pixel, hdr_background;
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
        /* PGenerator+ sends normalized HDR10 code values. Preserve them as
         * native 10-bit PQ/BT.2020 pixels without local PQ or roll-off math. */
        hdr_pixel = patch_to_hdr10(r, g, b);
        hdr_background = patch_to_hdr10(background_signal, background_signal, background_signal);
        if (!SDL_UpdateTexture(app.texture, NULL, &hdr_pixel, (int)sizeof(hdr_pixel))) return false;
        if (!SDL_UpdateTexture(app.background_texture, NULL, &hdr_background, (int)sizeof(hdr_background))) return false;
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
        /* Exact monitor coverage intentionally exercises Windows' fullscreen
         * presentation promotion path. */
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

static void companion_run_build(const char *poll_response)
{
    char ti3_path[1200], icc_path[1200], base_path[1200], tool[1024];
    char command[8192], flags[2048], directory[1024];
    unsigned char *ti3 = NULL;
    size_t ti3_length = 0;
    FILE *handle;
    int status;
    bool built = false;

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

    {   /* Fetch the characterization: too large for the poll response buffer. */
        char path[512];
        SDL_snprintf(path, sizeof(path), "/api/icc/companion/build-ti3?token=%s", app.config.token);
        status = http_binary(&app.config, "GET", path, "text/plain", NULL, 0, &ti3, &ti3_length);
        if (status != 200 || !ti3 || ti3_length < 32) {
            if (ti3) SDL_free(ti3);
            companion_report_build_error("could not fetch the characterization");
            return;
        }
    }
    handle = fopen(ti3_path, "wb");
    if (!handle || fwrite(ti3, 1, ti3_length, handle) != ti3_length) {
        if (handle) fclose(handle);
        SDL_free(ti3);
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
            companion_report_build_error("the fit arguments could not be read");
            return;
        }
        cleaned[out] = '\0';
#ifdef _WIN32
        SDL_snprintf(command, sizeof(command), "\"\"%s\" %s -O \"%s\" \"%s\"\"",
                     tool, cleaned, icc_path, base_path);
#else
        SDL_snprintf(command, sizeof(command), "\"%s\" %s -O \"%s\" \"%s\"",
                     tool, cleaned, icc_path, base_path);
#endif
    }
    queue_status("PGenerator+ Patch Companion | Building ICC profile...");
    status = system(command);
    (void)status;

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
                                icc, (size_t)size, &reply, &reply_length) == 200)
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
                           reported_hdr_active);
#else
    /* There is no DXGI swapchain and no OS presentation-mode query here, and no
     * portable way to read the display's active ICC profile either. Report what
     * this build genuinely knows - the colorspace the renderer presents in and
     * the video backend carrying it - instead of a placeholder that reads as a
     * failure. active_profile stays empty because none was read, not because
     * none is installed. */
    {
        SDL_PropertiesID renderer_props =
            app.renderer ? SDL_GetRendererProperties(app.renderer) : 0;
        SDL_Colorspace colorspace = renderer_props
            ? (SDL_Colorspace)SDL_GetNumberProperty(renderer_props,
                                                    SDL_PROP_RENDERER_OUTPUT_COLORSPACE_NUMBER,
                                                    SDL_COLORSPACE_UNKNOWN)
            : SDL_COLORSPACE_UNKNOWN;
        const char *driver = SDL_GetCurrentVideoDriver();
        if (colorspace == SDL_COLORSPACE_SRGB_LINEAR)
            SDL_strlcpy(swapchain_color_space, "scrgb-linear", sizeof(swapchain_color_space));
        else if (colorspace == SDL_COLORSPACE_SRGB)
            SDL_strlcpy(swapchain_color_space, "srgb", sizeof(swapchain_color_space));
        if (driver && driver[0])
            SDL_strlcpy(presentation_mode, driver, sizeof(presentation_mode));
    }
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
                 "/api/icc/companion/poll?token=%s&client=%s&version=%s&platform=%s&renderer=%s&hdr=%d&profile_hex=%s&display_hex=%s&swapchain_cs=%s&presentation=%s&output_max=%.3f&output_full=%.3f&output_bits=%u&transform=%s&transform_ready=%d&transform_note_hex=%s&source_r=%.6f&source_g=%.6f&source_b=%.6f&submitted_r=%.6f&submitted_g=%.6f&submitted_b=%.6f&build_argyll=%s",
                 app.config.token, app.config.client, APP_VERSION,
                 companion_platform(),
                 reported_renderer, reported_hdr_active ? 1 : 0, profile_hex,
                 display_hex,
                 swapchain_color_space, presentation_mode,
                 output_maximum_luminance, output_full_frame_luminance,
                 output_bits_per_color, app.correction_mode,
                 app.correction_ready ? 1 : 0, transform_note_hex,
                 app.source_r, app.source_g, app.source_b,
                 app.submitted_r, app.submitted_g, app.submitted_b,
                 companion_argyll_version());
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
        if (settings_revision != app.correction_lut_revision ||
            strcmp(active_profile, app.correction_profile)) {
            SDL_strlcpy(app.correction_mode, correction_mode, sizeof(app.correction_mode));
            SDL_strlcpy(app.correction_profile, active_profile, sizeof(app.correction_profile));
            SDL_strlcpy(app.correction_signal_mode, correction_signal_mode, sizeof(app.correction_signal_mode));
#ifdef _WIN32
            wcsncpy(app.correction_profile_path,active_profile_path,SDL_arraysize(app.correction_profile_path)-1);
            app.correction_profile_path[SDL_arraysize(app.correction_profile_path)-1]=L'\0';
#endif
            load_correction_lut(settings_revision);
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
        if (!strcmp(app.correction_mode, "clut"))
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
        SDL_strlcpy(mode, app.command_mode, sizeof(mode));
        app.command_pending = false;
    }
    SDL_UnlockMutex(app.network_mutex);
    if (status_dirty) SDL_SetWindowTitle(app.window, title);
    if (have_settings) {
        if (apply_display_settings(settings_fullscreen, settings_size)) {
            SDL_LockMutex(app.network_mutex);
            app.applied_settings_revision = settings_revision;
            SDL_UnlockMutex(app.network_mutex);
        }
    }
    if (have_command) {
        bool ok;
#ifdef _WIN32
        bool refresh_fullscreen_hdr =
            app.fullscreen && !alignment && !strcmp(mode, "hdr10") &&
            command_size >= 100 &&
            app.hdr_swapchain &&
            (strcmp(app.displayed_mode, mode) || app.displayed_r != r ||
             app.displayed_g != g || app.displayed_b != b ||
             app.displayed_size != command_size ||
             app.displayed_max_luma != max_luma ||
             app.displayed_min_luma != min_luma ||
             app.displayed_max_cll != max_cll ||
             app.displayed_max_fall != max_fall);
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
         * cannot sample this reset frame. */
        if (refresh_fullscreen_hdr &&
            (!try_create_renderer(false, NULL) ||
             (SDL_Delay(50), !create_renderer(true)))) ok = false;
        else ok = alignment ? render_alignment() : render_patch(mode, r, g, b);
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
        if (ok) app.sequence = sequence;
        app.ack_sequence = sequence;
        app.ack_ok = ok;
        SDL_strlcpy(app.ack_message, message, sizeof(app.ack_message));
        SDL_strlcpy(app.ack_renderer, app.renderer_name, sizeof(app.ack_renderer));
        app.ack_hdr_active = app.hdr_active;
        app.ack_pending = true;
        SDL_UnlockMutex(app.network_mutex);
    }
}

SDL_AppResult SDL_AppInit(void **appstate, int argc, char *argv[])
{
    (void)argc; (void)argv;
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
    if (!load_config(&app.config)) {
        SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "PGenerator+ Patch Companion",
                                 "PGenICCCompanion.conf is missing or invalid. Download the companion again from your PGenerator.", NULL);
        return SDL_APP_FAILURE;
    }
    if (!SDL_Init(SDL_INIT_VIDEO)) return SDL_APP_FAILURE;
    app.network_mutex = SDL_CreateMutex();
    if (!app.network_mutex) return SDL_APP_FAILURE;
    app.window = SDL_CreateWindow("PGenerator+ Patch Companion", 1280, 720,
                                  SDL_WINDOW_HIGH_PIXEL_DENSITY | SDL_WINDOW_RESIZABLE);
    if (!app.window) return SDL_APP_FAILURE;
#ifdef _WIN32
    set_windows_window_icon();
#else
    set_embedded_window_icon();
#endif
    if (!select_target_display()) return SDL_APP_FAILURE;
    app.fullscreen = false;
    app.displayed_size = 100;
    if (!create_renderer(false)) return SDL_APP_FAILURE;
    if (!render_alignment()) return SDL_APP_FAILURE;
    SDL_strlcpy(app.ack_renderer, app.renderer_name, sizeof(app.ack_renderer));
    app.ack_hdr_active = app.hdr_active;
    SDL_SetAtomicInt(&app.quit_requested, 0);
    app.network_thread = SDL_CreateThread(network_thread_main, "PGen ICC network", NULL);
    if (!app.network_thread) return SDL_APP_FAILURE;
    *appstate = &app;
    return SDL_APP_CONTINUE;
}

SDL_AppResult SDL_AppEvent(void *appstate, SDL_Event *event)
{
    AppState *state = (AppState *)appstate;
    if (event->type == SDL_EVENT_QUIT) return SDL_APP_SUCCESS;
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
#endif
    SDL_Delay(5);
    return state->quit ? SDL_APP_SUCCESS : SDL_APP_CONTINUE;
}

void SDL_AppQuit(void *appstate, SDL_AppResult result)
{
    AppState *state = (AppState *)appstate;
    (void)result;
    if (state) {
        SDL_SetAtomicInt(&state->quit_requested, 1);
        if (state->network_thread) SDL_WaitThread(state->network_thread, NULL);
        if (state->texture) SDL_DestroyTexture(state->texture);
        if (state->background_texture) SDL_DestroyTexture(state->background_texture);
        if (state->renderer) SDL_DestroyRenderer(state->renderer);
#ifdef _WIN32
        windows_destroy_hdr_output();
#endif
        SDL_free(state->correction_lut);
#ifdef _WIN32
        SDL_free(state->correction_profile_data);
#endif
        if (state->window) SDL_DestroyWindow(state->window);
        if (state->network_mutex) SDL_DestroyMutex(state->network_mutex);
    }
    SDL_Quit();
#ifdef _WIN32
    WSACleanup();
#endif
}
