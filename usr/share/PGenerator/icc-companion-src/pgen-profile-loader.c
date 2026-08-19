#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <commdlg.h>
#include <shellapi.h>
#include <icm.h>
#include <uxtheme.h>
#include <dwmapi.h>
#include <setupapi.h>
#include <devguid.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <wctype.h>

#define APP_NAME L"PGenerator+ Profile Loader"
#define APP_VERSION L"1.3.7"
#define WM_TRAYICON (WM_APP + 1)
#define WM_APPLY_DONE (WM_APP + 2)
#define WM_BROWSE_DONE (WM_APP + 3)
#define TIMER_VERIFY 1
#define MAX_DISPLAYS 24
#define MAX_DISPLAY_PROFILES 256
#define ID_DISPLAY 101
#define ID_PROFILE 102
#define ID_BROWSE 103
#define ID_APPLY 104
#define ID_STATUS 105
#define ID_AUTOREAPPLY 106
#define ID_STARTUP 107
#define ID_SETTINGS 108
#define ID_HIDE 109
#define ID_CLEAR_DEFAULT 110
#define ID_DISPLAY_PROFILES 111
#define ID_SET_DEFAULT 112
#define ID_TRAY_SHOW 201
#define ID_TRAY_APPLY 202
#define ID_TRAY_AUTOREAPPLY 203
#define ID_TRAY_SETTINGS 204
#define ID_TRAY_EXIT 205
#define ID_TRAY_CLEAR_DEFAULT 206
#define IDI_PGEN_APP 101
#define PGEN_CPST_STANDARD_DISPLAY_COLOR_MODE ((COLORPROFILESUBTYPE)7)
#define PGEN_CPST_EXTENDED_DISPLAY_COLOR_MODE ((COLORPROFILESUBTYPE)8)

typedef HRESULT (WINAPI *PFN_ColorProfileAddDisplayAssociation)(
    WCS_PROFILE_MANAGEMENT_SCOPE, PCWSTR, LUID, UINT32, BOOL, BOOL);
typedef HRESULT (WINAPI *PFN_ColorProfileGetDisplayDefault)(
    WCS_PROFILE_MANAGEMENT_SCOPE, LUID, UINT32, COLORPROFILETYPE,
    COLORPROFILESUBTYPE, LPWSTR *);
typedef HRESULT (WINAPI *PFN_ColorProfileGetDisplayUserScope)(
    LUID, UINT32, WCS_PROFILE_MANAGEMENT_SCOPE *);
typedef HRESULT (WINAPI *PFN_ColorProfileGetDisplayList)(
    WCS_PROFILE_MANAGEMENT_SCOPE, LUID, UINT32, LPWSTR **, PDWORD);
typedef HRESULT (WINAPI *PFN_ColorProfileSetDisplayDefaultAssociation)(
    WCS_PROFILE_MANAGEMENT_SCOPE, PCWSTR, COLORPROFILETYPE,
    COLORPROFILESUBTYPE, LUID, UINT32);
typedef HRESULT (WINAPI *PFN_ColorProfileRemoveDisplayAssociation)(
    WCS_PROFILE_MANAGEMENT_SCOPE, PCWSTR, LUID, UINT32, BOOL);

typedef struct {
    LUID adapter;
    UINT32 source_id;
    LUID target_adapter;
    UINT32 target_id;
    WCHAR source_name[CCHDEVICENAME];
    WCHAR friendly[128];
    WCHAR monitor_path[256];
    WCHAR driver_key[128];
} DISPLAY_ENTRY;

typedef struct {
    WCHAR name[MAX_PATH];
    BOOL advanced;
    BOOL current_standard;
    BOOL current_advanced;
} PROFILE_ENTRY;

static HINSTANCE g_instance;
static HWND g_window, g_display, g_profile, g_display_profiles, g_set_default;
static HWND g_status, g_status_heading, g_apply, g_browse, g_clear_default;
static NOTIFYICONDATAW g_tray;
static HICON g_icon_ok, g_icon_bad;
static HFONT g_font_normal, g_font_label, g_font_title, g_font_subtitle, g_font_button;
static HBRUSH g_brush_background, g_brush_card;
static UINT g_dpi = 96;
static BOOL g_status_ok;
static BOOL g_status_pending;
static DISPLAY_ENTRY g_displays[MAX_DISPLAYS];
static UINT g_display_count;
static PROFILE_ENTRY g_profiles[MAX_DISPLAY_PROFILES];
static UINT g_profile_count;
static WCHAR g_ini[MAX_PATH];
static WCHAR g_profile_path[MAX_PATH];
static WCHAR g_profile_name[MAX_PATH];
static WCHAR g_saved_monitor_path[256];
static BOOL g_profile_has_mhc2;
static BOOL g_associate_advanced;
static BOOL g_auto_reapply = TRUE;
/* Owner-drawn checkboxes do not maintain check state themselves, so the
 * two toggles are tracked here and drawn from these. */
static BOOL g_startup_enabled;
static WCHAR g_companion_result[MAX_PATH];
static WCHAR g_pending_companion[2048];
static BOOL g_correction_isolated;
static BOOL g_isolation_was_per_user = TRUE;
static HANDLE g_isolation_owner;
static BOOL g_reject_next_isolate_for_stale_restore;
static int g_profile_operation;
#define PROFILE_OPERATION_APPLY 0
#define PROFILE_OPERATION_ISOLATE 1
#define PROFILE_OPERATION_RESTORE 2
static void accept_profile_path(const WCHAR *path);
static void start_apply_profile(void);
static void start_profile_operation(int operation);
static BOOL associate_profile(DISPLAY_ENTRY *display, BOOL interactive);
static void write_companion_result(BOOL ok);
static HBRUSH g_brush_input;
static BOOL g_exiting;
static DWORD g_last_reapply_tick;
static UINT g_mismatch_count;
static BOOL g_reapply_attempted_for_mismatch;
static volatile LONG g_apply_in_progress;
static volatile LONG g_browse_in_progress;
static volatile LONG g_advanced_color_refresh_in_progress;
static BOOL g_profile_pending_selection;
static WCHAR g_browse_path[MAX_PATH];
static BOOL g_browse_has_mhc2;
static BOOL g_browse_advanced;
static HMODULE g_mscms;
static PFN_ColorProfileAddDisplayAssociation p_add_association;
static PFN_ColorProfileGetDisplayDefault p_get_default;
static PFN_ColorProfileGetDisplayUserScope p_get_scope;
static PFN_ColorProfileGetDisplayList p_get_list;
static PFN_ColorProfileSetDisplayDefaultAssociation p_set_default;
static PFN_ColorProfileRemoveDisplayAssociation p_remove_association;

/* SYSTEM THEME
 *
 * The palette is read from the OS at startup rather than hardcoded, so a
 * dark-themed desktop does not get a glaring light window. Sources:
 *   HKCU\...\Themes\Personalize  AppsUseLightTheme  (0 = dark, 1 = light)
 *   HKCU\Software\Microsoft\Windows\DWM  AccentColor  (ABGR)
 * Both are plain registry reads, so no dependency is added. The title bar is
 * switched with DWMWA_USE_IMMERSIVE_DARK_MODE, because a dark window under a
 * light title bar looks broken.
 *
 * Read once at startup and refreshed on WM_SETTINGCHANGE. */
typedef struct {
    COLORREF background, card, border, text, muted, accent, accent_pressed;
    COLORREF ok, bad, pending, disabled, on_accent;
    /* Win32 common controls keep their own light theme regardless of the
     * window's, so the control surfaces are part of the palette too. */
    COLORREF input, control, control_hot, selection, selection_text;
    BOOL dark;
} PGEN_PALETTE;

static PGEN_PALETTE g_palette;

static DWORD read_dword_value(HKEY root, const WCHAR *path, const WCHAR *name, DWORD fallback) {
    HKEY key;
    DWORD value = fallback, size = sizeof(value), type = 0;
    if (RegOpenKeyExW(root, path, 0, KEY_QUERY_VALUE, &key) != ERROR_SUCCESS) return fallback;
    if (RegQueryValueExW(key, name, NULL, &type, (LPBYTE)&value, &size) != ERROR_SUCCESS ||
        type != REG_DWORD) value = fallback;
    RegCloseKey(key);
    return value;
}

static COLORREF blend_color(COLORREF a, COLORREF b, double t) {
    return RGB((int)(GetRValue(a) + (GetRValue(b) - GetRValue(a)) * t),
               (int)(GetGValue(a) + (GetGValue(b) - GetGValue(a)) * t),
               (int)(GetBValue(a) + (GetBValue(b) - GetBValue(a)) * t));
}

static void load_system_palette(void) {
    DWORD light = read_dword_value(HKEY_CURRENT_USER,
        L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        L"AppsUseLightTheme", 1);
    DWORD accent = read_dword_value(HKEY_CURRENT_USER,
        L"Software\\Microsoft\\Windows\\DWM", L"AccentColor", 0);
    g_palette.dark = light == 0;
    /* DWM stores the accent as ABGR, not ARGB. */
    g_palette.accent = accent ? RGB(accent & 0xFF, (accent >> 8) & 0xFF, (accent >> 16) & 0xFF)
                              : (g_palette.dark ? RGB(76, 148, 255) : RGB(55, 96, 220));
    if (g_palette.dark) {
        g_palette.background = RGB(32, 32, 32);
        g_palette.card = RGB(43, 43, 43);
        g_palette.border = RGB(64, 64, 64);
        g_palette.text = RGB(244, 244, 244);
        g_palette.muted = RGB(168, 172, 180);
        g_palette.ok = RGB(94, 208, 143);
        g_palette.bad = RGB(255, 130, 120);
        /* A disabled grey picked for a light background disappears on dark. */
        g_palette.disabled = RGB(132, 136, 144);
        g_palette.accent_pressed = blend_color(g_palette.accent, RGB(255, 255, 255), 0.18);
        g_palette.input = RGB(24, 24, 24);
        g_palette.control = RGB(53, 53, 53);
        g_palette.control_hot = RGB(66, 66, 66);
    } else {
        g_palette.background = RGB(246, 248, 252);
        g_palette.card = RGB(255, 255, 255);
        g_palette.border = RGB(221, 226, 235);
        g_palette.text = RGB(48, 56, 72);
        g_palette.muted = RGB(110, 120, 138);
        g_palette.ok = RGB(24, 132, 70);
        g_palette.bad = RGB(190, 55, 48);
        g_palette.disabled = RGB(166, 174, 190);
        g_palette.accent_pressed = blend_color(g_palette.accent, RGB(0, 0, 0), 0.22);
        g_palette.input = RGB(255, 255, 255);
        g_palette.control = RGB(255, 255, 255);
        g_palette.control_hot = RGB(240, 244, 251);
    }
    g_palette.selection = blend_color(g_palette.input, g_palette.accent,
                                      g_palette.dark ? 0.42 : 0.22);
    g_palette.selection_text = g_palette.text;
    g_palette.pending = g_palette.accent;
    /* Keep the label on the primary button legible whatever the accent is. */
    g_palette.on_accent = (GetRValue(g_palette.accent) * 299 + GetGValue(g_palette.accent) * 587 +
                           GetBValue(g_palette.accent) * 114) / 1000 > 150
                          ? RGB(16, 18, 22) : RGB(255, 255, 255);
}

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

static void apply_titlebar_theme(HWND window) {
    BOOL dark = g_palette.dark;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof(dark));
}

static int px(int value) {
    return MulDiv(value, (int)g_dpi, 96);
}

static HFONT make_ui_font(int points, int weight) {
    return CreateFontW(-MulDiv(points, (int)g_dpi, 72), 0, 0, 0, weight,
                       FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                       CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                       DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
}

static void apply_font(HWND control, HFONT font) {
    SendMessageW(control, WM_SETFONT, (WPARAM)font, TRUE);
}

/* Every surface in this window is drawn from the palette, but the scrollbars
 * inside the list and the combo drop-down belong to the control and cannot be
 * owner-drawn. DarkMode_Explorer is the theme class that renders those dark.
 * SetWindowTheme is documented and simply leaves the control on its default
 * theme when the class name is not recognised, so an older or newer Windows
 * loses the dark scrollbar and nothing else. */
static void apply_control_theme(HWND control) {
    SetWindowTheme(control, g_palette.dark ? L"DarkMode_Explorer" : L"Explorer", NULL);
}

static void message_error(HWND owner, const WCHAR *action, DWORD code) {
    WCHAR system[512] = L"";
    WCHAR text[768];
    FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                   NULL, code, 0, system, 511, NULL);
    swprintf(text, 768, L"%ls failed.\n\n%ls\nError 0x%08lX", action,
             system[0] ? system : L"Windows did not provide additional details.", code);
    MessageBoxW(owner, text, APP_NAME, MB_OK | MB_ICONERROR);
}

static uint32_t read_be32(const BYTE *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static BOOL profile_contains_mhc2(const WCHAR *path) {
    HANDLE file;
    BYTE header[132];
    DWORD got = 0, count, i;
    LARGE_INTEGER size;
    file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                       FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return FALSE;
    if (!GetFileSizeEx(file, &size) || size.QuadPart < 132 ||
        !ReadFile(file, header, sizeof(header), &got, NULL) || got != sizeof(header)) {
        CloseHandle(file);
        return FALSE;
    }
    count = read_be32(header + 128);
    if (count > 4096 || 132ULL + (uint64_t)count * 12ULL > (uint64_t)size.QuadPart) {
        CloseHandle(file);
        return FALSE;
    }
    for (i = 0; i < count; i++) {
        BYTE tag[12];
        if (!ReadFile(file, tag, sizeof(tag), &got, NULL) || got != sizeof(tag)) break;
        if (memcmp(tag, "MHC2", 4) == 0) {
            CloseHandle(file);
            return TRUE;
        }
    }
    CloseHandle(file);
    return FALSE;
}

static BOOL profile_contains_hdr_cicp(const WCHAR *path) {
    HANDLE file;
    BYTE header[132];
    DWORD got = 0, count, i;
    LARGE_INTEGER size;
    file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                       FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return FALSE;
    if (!GetFileSizeEx(file, &size) || size.QuadPart < 132 ||
        !ReadFile(file, header, sizeof(header), &got, NULL) || got != sizeof(header)) {
        CloseHandle(file);
        return FALSE;
    }
    count = read_be32(header + 128);
    for (i = 0; i < count && i < 4096; i++) {
        BYTE tag[12], payload[12];
        LARGE_INTEGER position;
        uint32_t offset, tag_size;
        position.QuadPart = 132ULL + (uint64_t)i * 12ULL;
        if (!SetFilePointerEx(file, position, NULL, FILE_BEGIN) ||
            !ReadFile(file, tag, sizeof(tag), &got, NULL) || got != sizeof(tag)) break;
        if (memcmp(tag, "cicp", 4) != 0) continue;
        offset = read_be32(tag + 4);
        tag_size = read_be32(tag + 8);
        position.QuadPart = offset;
        if (tag_size < sizeof(payload) || offset + sizeof(payload) > (uint64_t)size.QuadPart ||
            !SetFilePointerEx(file, position, NULL, FILE_BEGIN) ||
            !ReadFile(file, payload, sizeof(payload), &got, NULL) || got != sizeof(payload)) break;
        CloseHandle(file);
        return memcmp(payload, "cicp", 4) == 0 && payload[8] == 9 &&
               payload[9] == 16 && payload[10] == 0 && payload[11] == 1;
    }
    CloseHandle(file);
    return FALSE;
}

/* The MHC2 tag stores its calibrated peak as s15Fixed16 cd/m2 at offset 16,
   after the signature, four reserved bytes, the entry count and the minimum
   luminance. */
static double profile_mhc2_peak_luminance(const WCHAR *path) {
    HANDLE file;
    BYTE header[132];
    DWORD got = 0, count, i;
    LARGE_INTEGER size;
    file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                       FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return 0.0;
    if (!GetFileSizeEx(file, &size) || size.QuadPart < 132 ||
        !ReadFile(file, header, sizeof(header), &got, NULL) || got != sizeof(header)) {
        CloseHandle(file);
        return 0.0;
    }
    count = read_be32(header + 128);
    for (i = 0; i < count && i < 4096; i++) {
        BYTE tag[12], payload[20];
        LARGE_INTEGER position;
        uint32_t offset, tag_size, raw;
        position.QuadPart = 132ULL + (uint64_t)i * 12ULL;
        if (!SetFilePointerEx(file, position, NULL, FILE_BEGIN) ||
            !ReadFile(file, tag, sizeof(tag), &got, NULL) || got != sizeof(tag)) break;
        if (memcmp(tag, "MHC2", 4) != 0) continue;
        offset = read_be32(tag + 4);
        tag_size = read_be32(tag + 8);
        position.QuadPart = offset;
        if (tag_size < sizeof(payload) || offset + sizeof(payload) > (uint64_t)size.QuadPart ||
            !SetFilePointerEx(file, position, NULL, FILE_BEGIN) ||
            !ReadFile(file, payload, sizeof(payload), &got, NULL) || got != sizeof(payload)) break;
        CloseHandle(file);
        if (memcmp(payload, "MHC2", 4) != 0) return 0.0;
        raw = read_be32(payload + 16);
        return (raw >= 0x80000000u ? (double)raw - 4294967296.0 : (double)raw) / 65536.0;
    }
    CloseHandle(file);
    return 0.0;
}

#define PGEN_ASSOCIATION_UNKNOWN 0
#define PGEN_ASSOCIATION_SDR 1
#define PGEN_ASSOCIATION_HDR 2

/* PGenerator+ Windows profiles carry a private text tag naming the per-user
   display association they were built for. Unknown ICC tags are ignored by
   colour engines, while this positive marker avoids guessing from MHC2 peak
   luminance. A bright SDR display can legitimately exceed a dim HDR display. */
static int profile_association_marker(const WCHAR *path) {
    HANDLE file;
    BYTE header[132];
    DWORD got = 0, count, i;
    LARGE_INTEGER size;
    file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                       FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return PGEN_ASSOCIATION_UNKNOWN;
    if (!GetFileSizeEx(file, &size) || size.QuadPart < 132 ||
        !ReadFile(file, header, sizeof(header), &got, NULL) || got != sizeof(header)) {
        CloseHandle(file);
        return PGEN_ASSOCIATION_UNKNOWN;
    }
    count = read_be32(header + 128);
    if (count > 4096 || 132ULL + (uint64_t)count * 12ULL > (uint64_t)size.QuadPart) {
        CloseHandle(file);
        return PGEN_ASSOCIATION_UNKNOWN;
    }
    for (i = 0; i < count; i++) {
        BYTE tag[12], payload[20];
        LARGE_INTEGER position;
        uint32_t offset, tag_size;
        position.QuadPart = 132ULL + (uint64_t)i * 12ULL;
        if (!SetFilePointerEx(file, position, NULL, FILE_BEGIN) ||
            !ReadFile(file, tag, sizeof(tag), &got, NULL) || got != sizeof(tag)) break;
        if (memcmp(tag, "pGAs", 4) != 0) continue;
        offset = read_be32(tag + 4);
        tag_size = read_be32(tag + 8);
        position.QuadPart = offset;
        if (tag_size < sizeof(payload) ||
            (uint64_t)offset + sizeof(payload) > (uint64_t)size.QuadPart ||
            !SetFilePointerEx(file, position, NULL, FILE_BEGIN) ||
            !ReadFile(file, payload, sizeof(payload), &got, NULL) || got != sizeof(payload)) break;
        CloseHandle(file);
        if (memcmp(payload, "text\0\0\0\0", 8) != 0 || payload[19] != 0)
            return PGEN_ASSOCIATION_UNKNOWN;
        if (memcmp(payload + 8, "windows-sdr", 11) == 0) return PGEN_ASSOCIATION_SDR;
        if (memcmp(payload + 8, "windows-hdr", 11) == 0) return PGEN_ASSOCIATION_HDR;
        return PGEN_ASSOCIATION_UNKNOWN;
    }
    CloseHandle(file);
    return PGEN_ASSOCIATION_UNKNOWN;
}

static BOOL profile_name_is_hdr(const WCHAR *path) {
    WCHAR upper[MAX_PATH];
    size_t i;
    wcsncpy_s(upper, MAX_PATH, path, _TRUNCATE);
    for (i = 0; upper[i]; i++) upper[i] = towupper(upper[i]);
    return wcsstr(upper, L"HDR-MHC2") != NULL || wcsstr(upper, L"-HDR-") != NULL;
}

/* STANDARD versus EXTENDED is a property of the display association, not of
   the ICC payload. A non-MHC2 HDR profile still belongs in Windows' EXTENDED
   (HDR) association list; requiring MHC2 here made Windows show every HDR
   cLUT-only profile as an SDR profile. Classify from the content, because a
   renamed profile still has to reach the right list. New PGenerator+
   profiles carry an authoritative private association marker. For older
   profiles, cicp marks HDR authoritatively, and an MHC2 profile without cicp
   is treated as HDR when its calibrated peak clears the usual SDR range. The
   file name remains the last resort for profiles carrying none of them. */
static BOOL profile_is_hdr_association(const WCHAR *path) {
    int association = profile_association_marker(path);
    if (association != PGEN_ASSOCIATION_UNKNOWN)
        return association == PGEN_ASSOCIATION_HDR;
    return profile_contains_hdr_cicp(path) ||
           profile_mhc2_peak_luminance(path) >= 250.0 ||
           profile_name_is_hdr(path);
}

static void make_ini_path(void) {
    WCHAR dir[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", dir, MAX_PATH);
    if (!n || n >= MAX_PATH) GetTempPathW(MAX_PATH, dir);
    swprintf(g_ini, MAX_PATH, L"%ls\\PGenerator+", dir);
    CreateDirectoryW(g_ini, NULL);
    wcscat_s(g_ini, MAX_PATH, L"\\ProfileLoader.ini");
}

static void save_settings(void) {
    WritePrivateProfileStringW(L"ProfileLoader", L"ProfilePath", g_profile_path, g_ini);
    WritePrivateProfileStringW(L"ProfileLoader", L"ProfileName", g_profile_name, g_ini);
    WritePrivateProfileStringW(L"ProfileLoader", L"MonitorPath", g_saved_monitor_path, g_ini);
    WritePrivateProfileStringW(L"ProfileLoader", L"AutoReapply", g_auto_reapply ? L"1" : L"0", g_ini);
    WritePrivateProfileStringW(L"ProfileLoader", L"HasMHC2", g_profile_has_mhc2 ? L"1" : L"0", g_ini);
    WritePrivateProfileStringW(L"ProfileLoader", L"AdvancedAssociation", g_associate_advanced ? L"1" : L"0", g_ini);
    WritePrivateProfileStringW(L"ProfileLoader", L"CorrectionIsolationActive",
                               g_correction_isolated ? L"1" : L"0", g_ini);
    WritePrivateProfileStringW(L"ProfileLoader", L"IsolationWasPerUser",
                               g_isolation_was_per_user ? L"1" : L"0", g_ini);
}

static void load_settings(void) {
    int association;
    GetPrivateProfileStringW(L"ProfileLoader", L"ProfilePath", L"", g_profile_path,
                             MAX_PATH, g_ini);
    GetPrivateProfileStringW(L"ProfileLoader", L"ProfileName", L"", g_profile_name,
                             MAX_PATH, g_ini);
    GetPrivateProfileStringW(L"ProfileLoader", L"MonitorPath", L"", g_saved_monitor_path,
                             256, g_ini);
    g_auto_reapply = GetPrivateProfileIntW(L"ProfileLoader", L"AutoReapply", 1, g_ini) != 0;
    g_profile_has_mhc2 = GetPrivateProfileIntW(L"ProfileLoader", L"HasMHC2", 0, g_ini) != 0;
    g_associate_advanced = GetPrivateProfileIntW(L"ProfileLoader", L"AdvancedAssociation", 0, g_ini) != 0;
    g_correction_isolated = GetPrivateProfileIntW(L"ProfileLoader",
                                                   L"CorrectionIsolationActive", 0,
                                                   g_ini) != 0;
    g_isolation_was_per_user = GetPrivateProfileIntW(L"ProfileLoader",
                                                      L"IsolationWasPerUser", 1,
                                                      g_ini) != 0;
    if (GetFileAttributesW(g_profile_path) != INVALID_FILE_ATTRIBUTES) {
        g_profile_has_mhc2 = profile_contains_mhc2(g_profile_path);
        /* Explicit builder markers remain authoritative. Otherwise upgrade a
           saved STANDARD selection when the profile content or name proves it
           is HDR, but preserve an existing Advanced Color selection for an
           ambiguous vendor profile. Such profiles can carry no MHC2, cicp or
           HDR token even though Windows already associated them with the HDR
           display mode. Downgrading the saved bit makes auto-reapply move the
           vendor profile into the SDR list after every loader restart. */
        association = profile_association_marker(g_profile_path);
        if (association != PGEN_ASSOCIATION_UNKNOWN)
            g_associate_advanced = association == PGEN_ASSOCIATION_HDR;
        else if (profile_is_hdr_association(g_profile_path))
            g_associate_advanced = TRUE;
    }
}

static BOOL startup_enabled(void) {
    HKEY key;
    WCHAR value[MAX_PATH * 2];
    DWORD type = 0, bytes = sizeof(value);
    BOOL enabled = FALSE;
    if (RegOpenKeyExW(HKEY_CURRENT_USER,
                      L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", 0,
                      KEY_QUERY_VALUE, &key) == ERROR_SUCCESS) {
        enabled = RegQueryValueExW(key, L"PGenerator+ Profile Loader", NULL, &type,
                                   (BYTE *)value, &bytes) == ERROR_SUCCESS;
        RegCloseKey(key);
    }
    return enabled;
}

static BOOL set_startup(BOOL enabled) {
    HKEY key;
    LONG rc = RegCreateKeyExW(HKEY_CURRENT_USER,
                              L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", 0,
                              NULL, 0, KEY_SET_VALUE, NULL, &key, NULL);
    if (rc != ERROR_SUCCESS) return FALSE;
    if (enabled) {
        WCHAR exe[MAX_PATH], command[MAX_PATH + 16];
        GetModuleFileNameW(NULL, exe, MAX_PATH);
        swprintf(command, MAX_PATH + 16, L"\"%ls\" --tray", exe);
        rc = RegSetValueExW(key, L"PGenerator+ Profile Loader", 0, REG_SZ,
                            (BYTE *)command, (DWORD)((wcslen(command) + 1) * sizeof(WCHAR)));
    } else {
        rc = RegDeleteValueW(key, L"PGenerator+ Profile Loader");
        if (rc == ERROR_FILE_NOT_FOUND) rc = ERROR_SUCCESS;
    }
    RegCloseKey(key);
    return rc == ERROR_SUCCESS;
}

static BOOL same_luid(LUID a, LUID b) {
    return a.HighPart == b.HighPart && a.LowPart == b.LowPart;
}

static BOOL monitor_instance_id(const WCHAR *path, WCHAR *instance, size_t count) {
    const WCHAR *source;
    size_t used = 0;
    int separators = 0;
    if (!path || !instance || count < 2) return FALSE;
    source = !wcsncmp(path, L"\\\\?\\", 4) ? path + 4 : path;
    while (*source && used + 1 < count) {
        if (source[0] == L'#' && source[1] == L'{') break;
        if (*source == L'#' && separators < 2) {
            instance[used++] = L'\\';
            separators++;
        } else {
            instance[used++] = *source;
        }
        source++;
    }
    instance[used] = L'\0';
    return separators == 2 && used > 0;
}

static BOOL monitor_driver_key(const WCHAR *monitor_path, WCHAR *driver, size_t count) {
    HDEVINFO devices;
    SP_DEVINFO_DATA info;
    WCHAR wanted[256], instance[256];
    DWORD index;
    BOOL found = FALSE;
    if (!monitor_instance_id(monitor_path, wanted, 256)) return FALSE;
    devices = SetupDiGetClassDevsW(&GUID_DEVCLASS_MONITOR, NULL, NULL, DIGCF_PRESENT);
    if (devices == INVALID_HANDLE_VALUE) return FALSE;
    ZeroMemory(&info, sizeof(info));
    info.cbSize = sizeof(info);
    for (index = 0; SetupDiEnumDeviceInfo(devices, index, &info); index++) {
        DWORD type = 0, bytes = 0;
        if (!SetupDiGetDeviceInstanceIdW(devices, &info, instance, 256, NULL) ||
            _wcsicmp(instance, wanted) != 0) continue;
        if (SetupDiGetDeviceRegistryPropertyW(devices, &info, SPDRP_DRIVER,
                                              &type, (BYTE *)driver,
                                              (DWORD)(count * sizeof(WCHAR)), &bytes) &&
            type == REG_SZ && driver[0]) found = TRUE;
        break;
    }
    SetupDiDestroyDeviceInfoList(devices);
    return found;
}

static void enumerate_displays(void) {
    UINT32 path_count = 0, mode_count = 0, i;
    DISPLAYCONFIG_PATH_INFO *paths = NULL;
    DISPLAYCONFIG_MODE_INFO *modes = NULL;
    LONG rc;
    int selected = -1;

    g_display_count = 0;
    SendMessageW(g_display, CB_RESETCONTENT, 0, 0);
    do {
        free(paths); free(modes); paths = NULL; modes = NULL;
        if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &path_count, &mode_count) != ERROR_SUCCESS)
            break;
        paths = (DISPLAYCONFIG_PATH_INFO *)calloc(path_count, sizeof(*paths));
        modes = (DISPLAYCONFIG_MODE_INFO *)calloc(mode_count, sizeof(*modes));
        if (!paths || !modes) break;
        rc = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &path_count, paths, &mode_count,
                                modes, NULL);
    } while (rc == ERROR_INSUFFICIENT_BUFFER);
    if (!paths || !modes || rc != ERROR_SUCCESS) goto done;

    for (i = 0; i < path_count && g_display_count < MAX_DISPLAYS; i++) {
        DISPLAYCONFIG_TARGET_DEVICE_NAME target;
        DISPLAYCONFIG_SOURCE_DEVICE_NAME source;
        DISPLAY_ENTRY *entry;
        UINT j;
        if (!(paths[i].flags & DISPLAYCONFIG_PATH_ACTIVE)) continue;
        for (j = 0; j < g_display_count; j++) {
            if (same_luid(g_displays[j].adapter, paths[i].sourceInfo.adapterId) &&
                g_displays[j].source_id == paths[i].sourceInfo.id) break;
        }
        if (j < g_display_count) continue;
        ZeroMemory(&target, sizeof(target));
        target.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
        target.header.size = sizeof(target);
        target.header.adapterId = paths[i].targetInfo.adapterId;
        target.header.id = paths[i].targetInfo.id;
        ZeroMemory(&source, sizeof(source));
        source.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
        source.header.size = sizeof(source);
        source.header.adapterId = paths[i].sourceInfo.adapterId;
        source.header.id = paths[i].sourceInfo.id;
        if (DisplayConfigGetDeviceInfo(&source.header) != ERROR_SUCCESS) continue;
        DisplayConfigGetDeviceInfo(&target.header);
        entry = &g_displays[g_display_count];
        ZeroMemory(entry, sizeof(*entry));
        entry->adapter = paths[i].sourceInfo.adapterId;
        entry->source_id = paths[i].sourceInfo.id;
        entry->target_adapter = paths[i].targetInfo.adapterId;
        entry->target_id = paths[i].targetInfo.id;
        wcsncpy_s(entry->source_name, CCHDEVICENAME, source.viewGdiDeviceName, _TRUNCATE);
        wcsncpy_s(entry->friendly, 128,
                  target.monitorFriendlyDeviceName[0] ? target.monitorFriendlyDeviceName : source.viewGdiDeviceName,
                  _TRUNCATE);
        wcsncpy_s(entry->monitor_path, 256, target.monitorDevicePath, _TRUNCATE);
        monitor_driver_key(entry->monitor_path, entry->driver_key, 128);
        {
            WCHAR label[320];
            UINT duplicate_number = 1;
            for (j = 0; j < g_display_count; j++) {
                if (_wcsicmp(g_displays[j].friendly, entry->friendly) == 0)
                    duplicate_number++;
            }
            if (duplicate_number > 1)
                swprintf(label, 320, L"%ls %u", entry->friendly, duplicate_number);
            else
                wcsncpy_s(label, 320, entry->friendly, _TRUNCATE);
            SendMessageW(g_display, CB_ADDSTRING, 0, (LPARAM)label);
        }
        if (g_saved_monitor_path[0] && _wcsicmp(g_saved_monitor_path, entry->monitor_path) == 0)
            selected = (int)g_display_count;
        g_display_count++;
    }
done:
    free(paths); free(modes);
    if (g_display_count) {
        if (selected < 0) selected = 0;
        SendMessageW(g_display, CB_SETCURSEL, selected, 0);
    }
}

static DISPLAY_ENTRY *selected_display(void) {
    LRESULT index = SendMessageW(g_display, CB_GETCURSEL, 0, 0);
    if (index < 0 || (UINT)index >= g_display_count) return NULL;
    return &g_displays[index];
}

static HICON make_status_icon(COLORREF color) {
    const int w = 16, h = 16;
    BYTE xor_bits[w * h * 4];
    BYTE and_bits[w * h / 8];
    ICONINFO ii;
    int x, y;
    ZeroMemory(xor_bits, sizeof(xor_bits));
    memset(and_bits, 0xFF, sizeof(and_bits));
    for (y = 2; y < 14; y++) for (x = 2; x < 14; x++) {
        int dx = x - 8, dy = y - 8;
        if (dx * dx + dy * dy <= 32) {
            BYTE *p = xor_bits + ((h - 1 - y) * w + x) * 4;
            p[0] = GetBValue(color); p[1] = GetGValue(color); p[2] = GetRValue(color); p[3] = 0;
            and_bits[y * 2 + x / 8] &= (BYTE)~(0x80 >> (x & 7));
        }
    }
    ZeroMemory(&ii, sizeof(ii));
    ii.fIcon = TRUE;
    ii.hbmColor = CreateBitmap(w, h, 1, 32, xor_bits);
    ii.hbmMask = CreateBitmap(w, h, 1, 1, and_bits);
    {
        HICON icon = CreateIconIndirect(&ii);
        DeleteObject(ii.hbmColor); DeleteObject(ii.hbmMask);
        return icon;
    }
}

static void update_tray(BOOL ok, const WCHAR *detail) {
    g_tray.hIcon = ok ? g_icon_ok : g_icon_bad;
    wcsncpy_s(g_tray.szTip, 128, detail, _TRUNCATE);
    Shell_NotifyIconW(NIM_MODIFY, &g_tray);
}

static BOOL read_profile_list(HKEY key, const WCHAR *value, WCHAR *buffer,
                              DWORD buffer_count) {
    DWORD type = 0, bytes = buffer_count * sizeof(WCHAR);
    LONG rc;
    if (!key || !buffer || buffer_count < 2) return FALSE;
    ZeroMemory(buffer, bytes);
    rc = RegQueryValueExW(key, value, NULL, &type, (BYTE *)buffer, &bytes);
    if (rc != ERROR_SUCCESS || (type != REG_MULTI_SZ && type != REG_SZ)) return FALSE;
    buffer[buffer_count - 1] = L'\0';
    buffer[buffer_count - 2] = L'\0';
    return buffer[0] != L'\0';
}

static HKEY open_display_profile_registry(DISPLAY_ENTRY *display) {
    static const WCHAR *user_base =
        L"Software\\Microsoft\\Windows NT\\CurrentVersion\\ICM\\ProfileAssociations\\Display\\";
    static const WCHAR *system_base =
        L"SYSTEM\\CurrentControlSet\\Control\\Class\\";
    WCHAR path[512];
    HKEY key = NULL;
    DWORD use_user = 0, type = 0, bytes = sizeof(use_user);
    if (!display || !display->driver_key[0]) return NULL;
    swprintf(path, 512, L"%ls%ls", user_base, display->driver_key);
    if (RegOpenKeyExW(HKEY_CURRENT_USER, path, 0, KEY_READ, &key) == ERROR_SUCCESS) {
        if (RegQueryValueExW(key, L"UsePerUserProfiles", NULL, &type,
                            (BYTE *)&use_user, &bytes) == ERROR_SUCCESS &&
            type == REG_DWORD && use_user) return key;
        RegCloseKey(key);
        key = NULL;
    }
    swprintf(path, 512, L"%ls%ls", system_base, display->driver_key);
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, path, 0, KEY_READ, &key) != ERROR_SUCCESS)
        return NULL;
    return key;
}

static BOOL last_profile_name(const WCHAR *profiles, WCHAR *name, size_t count) {
    const WCHAR *item;
    BOOL found = FALSE;
    if (!profiles || !name || !count) return FALSE;
    for (item = profiles; *item; item += wcslen(item) + 1) {
        wcsncpy_s(name, count, item, _TRUNCATE);
        found = TRUE;
    }
    return found;
}

static BOOL registry_profile_defaults(DISPLAY_ENTRY *display,
                                      WCHAR *standard, size_t standard_count,
                                      WCHAR *advanced, size_t advanced_count) {
    HKEY key = open_display_profile_registry(display);
    WCHAR profiles[8192];
    BOOL found = FALSE;
    if (standard && standard_count) standard[0] = L'\0';
    if (advanced && advanced_count) advanced[0] = L'\0';
    if (!key) return FALSE;
    if (standard && read_profile_list(key, L"ICMProfile", profiles, 8192))
        found |= last_profile_name(profiles, standard, standard_count);
    if (advanced && read_profile_list(key, L"ICMProfileAC", profiles, 8192))
        found |= last_profile_name(profiles, advanced, advanced_count);
    RegCloseKey(key);
    return found;
}

static HRESULT get_active_default(DISPLAY_ENTRY *display, LPWSTR *name,
                                  WCS_PROFILE_MANAGEMENT_SCOPE *scope) {
    HRESULT hr;
    WCS_PROFILE_MANAGEMENT_SCOPE alternate;
    COLORPROFILESUBTYPE subtype = g_associate_advanced
                                ? PGEN_CPST_EXTENDED_DISPLAY_COLOR_MODE
                                : PGEN_CPST_STANDARD_DISPLAY_COLOR_MODE;
    *name = NULL;
    *scope = WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER;
    {
        WCHAR standard[MAX_PATH] = L"", advanced[MAX_PATH] = L"";
        const WCHAR *selected;
        if (registry_profile_defaults(display, standard, MAX_PATH,
                                      advanced, MAX_PATH)) {
            selected = g_associate_advanced ? advanced : standard;
            if (selected[0]) {
                size_t bytes = (wcslen(selected) + 1) * sizeof(WCHAR);
                *name = (LPWSTR)LocalAlloc(LMEM_FIXED, bytes);
                if (!*name) return E_OUTOFMEMORY;
                memcpy(*name, selected, bytes);
                return S_OK;
            }
        }
    }
    if (!p_get_default) return E_NOTIMPL;
    if (p_get_scope) {
        hr = p_get_scope(display->adapter, display->source_id, scope);
        if (FAILED(hr)) *scope = WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER;
    }
    hr = p_get_default(*scope, display->adapter, display->source_id,
                       CPT_ICC, subtype, name);
    if (FAILED(hr)) {
        alternate = *scope == WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER
                  ? WCS_PROFILE_MANAGEMENT_SCOPE_SYSTEM_WIDE
                  : WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER;
        *scope = alternate;
        hr = p_get_default(alternate, display->adapter, display->source_id,
                           CPT_ICC, subtype, name);
    }
    return hr;
}

static const WCHAR *profile_basename(const WCHAR *path) {
    const WCHAR *slash = wcsrchr(path, L'\\');
    const WCHAR *forward = wcsrchr(path, L'/');
    if (forward && (!slash || forward > slash)) slash = forward;
    return slash ? slash + 1 : path;
}

static BOOL profile_is_active(DISPLAY_ENTRY *display, WCHAR *actual, size_t actual_count) {
    LPWSTR current = NULL;
    WCS_PROFILE_MANAGEMENT_SCOPE scope;
    HRESULT hr;
    if (!display || !g_profile_name[0]) return FALSE;
    hr = get_active_default(display, &current, &scope);
    if (FAILED(hr) || !current) {
        HDC dc = g_associate_advanced ? NULL
                                      : CreateDCW(L"DISPLAY", display->source_name, NULL, NULL);
        WCHAR path[MAX_PATH] = L"";
        DWORD path_count = MAX_PATH;
        if (dc && GetICMProfileW(dc, &path_count, path) && path[0]) {
            BOOL match = _wcsicmp(profile_basename(path), g_profile_name) == 0;
            wcsncpy_s(actual, actual_count, profile_basename(path), _TRUNCATE);
            DeleteDC(dc);
            if (current) LocalFree(current);
            return match;
        }
        if (dc) DeleteDC(dc);
        swprintf(actual, actual_count,
                 L"Default profile could not be queried through either Windows display-profile API (0x%08lX).",
                 (DWORD)hr);
        if (current) LocalFree(current);
        return FALSE;
    }
    wcsncpy_s(actual, actual_count, current, _TRUNCATE);
    {
        BOOL match = _wcsicmp(profile_basename(current), g_profile_name) == 0;
        LocalFree(current);
        return match;
    }
}

static void set_status(BOOL ok, const WCHAR *text) {
    g_status_ok = ok;
    g_status_pending = FALSE;
    SetWindowTextW(g_status, text);
    SetWindowTextW(g_status_heading, ok ? L"PROFILE ACTIVE" : L"ATTENTION REQUIRED");
    InvalidateRect(g_window, NULL, FALSE);
    InvalidateRect(g_status, NULL, TRUE);
    InvalidateRect(g_status_heading, NULL, TRUE);
    update_tray(ok, ok ? L"PGenerator+ Profile Loader: profile active"
                       : L"PGenerator+ Profile Loader: attention required");
}

static void set_pending_status(const WCHAR *heading, const WCHAR *text) {
    g_status_ok = FALSE;
    g_status_pending = TRUE;
    SetWindowTextW(g_status, text);
    SetWindowTextW(g_status_heading, heading);
    InvalidateRect(g_window, NULL, FALSE);
    InvalidateRect(g_status, NULL, TRUE);
    InvalidateRect(g_status_heading, NULL, TRUE);
}

static void show_ready_status(void) {
    WCHAR text[MAX_PATH + 96];
    swprintf(text, MAX_PATH + 96, L"Ready to install and apply: %ls", g_profile_name);
    set_pending_status(L"READY TO APPLY", text);
}

static void verify_profile(BOOL allow_reapply);

static BOOL install_elevated(const WCHAR *path) {
    WCHAR exe[MAX_PATH], params[MAX_PATH + 64];
    SHELLEXECUTEINFOW sei;
    GetModuleFileNameW(NULL, exe, MAX_PATH);
    swprintf(params, MAX_PATH + 64, L"--install-only \"%ls\"", path);
    ZeroMemory(&sei, sizeof(sei));
    sei.cbSize = sizeof(sei);
    sei.fMask = SEE_MASK_NOCLOSEPROCESS;
    sei.lpVerb = L"runas";
    sei.lpFile = exe;
    sei.lpParameters = params;
    sei.nShow = SW_HIDE;
    if (!ShellExecuteExW(&sei)) return FALSE;
    WaitForSingleObject(sei.hProcess, INFINITE);
    {
        DWORD exit_code = 1;
        GetExitCodeProcess(sei.hProcess, &exit_code);
        CloseHandle(sei.hProcess);
        return exit_code == 0;
    }
}

static BOOL display_profile_is_associated(DISPLAY_ENTRY *display, const WCHAR *name) {
    LPWSTR *profiles = NULL;
    DWORD count = 0, i;
    HRESULT hr;
    BOOL found = FALSE;
    HKEY key;
    WCHAR stored[8192];
    const WCHAR *item;
    if (!display || !name) return FALSE;
    key = open_display_profile_registry(display);
    if (key) {
        const WCHAR *values[2] = {L"ICMProfile", L"ICMProfileAC"};
        int value_index;
        for (value_index = 0; value_index < 2 && !found; value_index++) {
            if (!read_profile_list(key, values[value_index], stored, 8192)) continue;
            for (item = stored; *item; item += wcslen(item) + 1) {
                if (_wcsicmp(profile_basename(item), name) == 0) {
                    found = TRUE;
                    break;
                }
            }
        }
        RegCloseKey(key);
        if (found) return TRUE;
    }
    if (!p_get_list) return FALSE;
    hr = p_get_list(WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER,
                    display->adapter, display->source_id, &profiles, &count);
    if (FAILED(hr) || !profiles) return FALSE;
    for (i = 0; i < count; i++) {
        if (profiles[i] && _wcsicmp(profile_basename(profiles[i]), name) == 0) {
            found = TRUE;
            break;
        }
    }
    LocalFree(profiles);
    return found;
}

static BOOL installed_profile_path(const WCHAR *name, WCHAR *path, size_t path_count) {
    WCHAR directory[MAX_PATH];
    DWORD count = MAX_PATH;
    if (!name || !name[0] || !path || path_count == 0 ||
        !GetColorDirectoryW(NULL, directory, &count)) return FALSE;
    if (swprintf(path, path_count, L"%ls\\%ls", directory,
                 profile_basename(name)) < 0) return FALSE;
    return GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES;
}

/* An installed profile of the same name is not necessarily the same profile.
   A rebuilt or fine-tuned profile keeps its generated name, so treating the
   name as proof of installation leaves Windows serving the previous version's
   bytes under it and the new calibration never reaches the display. */
static BOOL installed_profile_matches(const WCHAR *name, const WCHAR *source_path) {
    WCHAR path[MAX_PATH];
    HANDLE installed, source;
    LARGE_INTEGER installed_size, source_size;
    BOOL same;
    if (!source_path || !source_path[0] ||
        !installed_profile_path(name, path, MAX_PATH)) return FALSE;
    installed = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                            FILE_ATTRIBUTE_NORMAL, NULL);
    if (installed == INVALID_HANDLE_VALUE) return FALSE;
    source = CreateFileW(source_path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                         FILE_ATTRIBUTE_NORMAL, NULL);
    if (source == INVALID_HANDLE_VALUE) {
        CloseHandle(installed);
        return FALSE;
    }
    same = GetFileSizeEx(installed, &installed_size) &&
           GetFileSizeEx(source, &source_size) &&
           installed_size.QuadPart == source_size.QuadPart;
    while (same) {
        BYTE left[8192], right[8192];
        DWORD got_left = 0, got_right = 0;
        if (!ReadFile(installed, left, sizeof(left), &got_left, NULL) ||
            !ReadFile(source, right, sizeof(right), &got_right, NULL) ||
            got_left != got_right) same = FALSE;
        else if (!got_left) break;
        else if (memcmp(left, right, got_left) != 0) same = FALSE;
    }
    CloseHandle(source);
    CloseHandle(installed);
    return same;
}

/* InstallColorProfileW is not a replacement operation. On current Windows 11
   it can even return success when a profile of the same name is already
   installed while leaving that file's old bytes untouched. Compare first and
   proactively uninstall a differing copy, then verify the installed bytes
   after every install. A caller that cannot replace the file must not go on to
   associate a name whose content is stale. */
static BOOL install_profile_file(const WCHAR *path) {
    WCHAR installed[MAX_PATH];
    const WCHAR *name = profile_basename(path);
    if (installed_profile_path(name, installed, MAX_PATH)) {
        if (installed_profile_matches(name, path)) return TRUE;
        if (!UninstallColorProfileW(NULL, installed, TRUE)) return FALSE;
    }
    if (!InstallColorProfileW(NULL, path)) return FALSE;
    if (!installed_profile_matches(name, path)) {
        SetLastError(ERROR_WRITE_FAULT);
        return FALSE;
    }
    return TRUE;
}

static BOOL get_default_name(DISPLAY_ENTRY *display, COLORPROFILESUBTYPE subtype,
                             WCHAR *name, size_t name_count) {
    WCS_PROFILE_MANAGEMENT_SCOPE scope = WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER;
    WCS_PROFILE_MANAGEMENT_SCOPE alternate;
    LPWSTR current = NULL;
    HRESULT hr;
    if (!display || !p_get_default || !name || name_count == 0) return FALSE;
    name[0] = L'\0';
    if (p_get_scope && FAILED(p_get_scope(display->adapter, display->source_id, &scope)))
        scope = WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER;
    hr = p_get_default(scope, display->adapter, display->source_id,
                       CPT_ICC, subtype, &current);
    if (FAILED(hr) || !current || !current[0]) {
        if (current) LocalFree(current);
        current = NULL;
        alternate = scope == WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER
                  ? WCS_PROFILE_MANAGEMENT_SCOPE_SYSTEM_WIDE
                  : WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER;
        hr = p_get_default(alternate, display->adapter, display->source_id,
                           CPT_ICC, subtype, &current);
    }
    if (FAILED(hr) || !current || !current[0]) {
        if (current) LocalFree(current);
        return FALSE;
    }
    wcsncpy_s(name, name_count, profile_basename(current), _TRUNCATE);
    LocalFree(current);
    return TRUE;
}

static void append_display_profile_name(const WCHAR *name, BOOL advanced) {
    UINT i;
    PROFILE_ENTRY *entry;
    WCHAR path[MAX_PATH];
    if (!name || !name[0]) return;
    for (i = 0; i < g_profile_count; i++) {
        if (_wcsicmp(g_profiles[i].name, profile_basename(name)) == 0) {
            if (advanced) g_profiles[i].advanced = TRUE;
            return;
        }
    }
    if (g_profile_count >= MAX_DISPLAY_PROFILES) return;
    entry = &g_profiles[g_profile_count++];
    ZeroMemory(entry, sizeof(*entry));
    wcsncpy_s(entry->name, MAX_PATH, profile_basename(name), _TRUNCATE);
    entry->advanced = advanced ||
                      (installed_profile_path(entry->name, path, MAX_PATH) &&
                       profile_is_hdr_association(path));
}

static void append_display_profile_registry(DISPLAY_ENTRY *display) {
    HKEY key = open_display_profile_registry(display);
    WCHAR profiles[8192];
    const WCHAR *item;
    if (!key) return;
    if (read_profile_list(key, L"ICMProfile", profiles, 8192))
        for (item = profiles; *item; item += wcslen(item) + 1)
            append_display_profile_name(item, FALSE);
    if (read_profile_list(key, L"ICMProfileAC", profiles, 8192))
        for (item = profiles; *item; item += wcslen(item) + 1)
            append_display_profile_name(item, TRUE);
    RegCloseKey(key);
}

static void append_display_profile_scope(DISPLAY_ENTRY *display,
                                         WCS_PROFILE_MANAGEMENT_SCOPE scope) {
    LPWSTR *profiles = NULL;
    DWORD count = 0, i;
    HRESULT hr;
    if (!display || !p_get_list || g_profile_count >= MAX_DISPLAY_PROFILES) return;
    hr = p_get_list(scope, display->adapter, display->source_id, &profiles, &count);
    if (FAILED(hr) || !profiles) return;
    for (i = 0; i < count && g_profile_count < MAX_DISPLAY_PROFILES; i++) {
        const WCHAR *name;
        if (!profiles[i] || !profiles[i][0]) continue;
        name = profile_basename(profiles[i]);
        append_display_profile_name(name, FALSE);
    }
    LocalFree(profiles);
}

static void refresh_display_profiles(void) {
    DISPLAY_ENTRY *display = selected_display();
    WCHAR standard_default[MAX_PATH] = L"";
    WCHAR advanced_default[MAX_PATH] = L"";
    WCHAR selected_name[MAX_PATH] = L"";
    int preferred = -1, current = -1;
    UINT i;
    if (!g_display_profiles) return;
    {
        LRESULT selection = SendMessageW(g_display_profiles, LB_GETCURSEL, 0, 0);
        if (selection != LB_ERR) {
            LRESULT entry_index = SendMessageW(g_display_profiles, LB_GETITEMDATA,
                                                (WPARAM)selection, 0);
            if (entry_index >= 0 && (UINT)entry_index < g_profile_count)
                wcsncpy_s(selected_name, MAX_PATH,
                          g_profiles[entry_index].name, _TRUNCATE);
        }
    }
    SendMessageW(g_display_profiles, LB_RESETCONTENT, 0, 0);
    g_profile_count = 0;
    if (!display) {
        EnableWindow(g_set_default, FALSE);
        return;
    }
    registry_profile_defaults(display, standard_default, MAX_PATH,
                              advanced_default, MAX_PATH);
    if (!standard_default[0])
        get_default_name(display, PGEN_CPST_STANDARD_DISPLAY_COLOR_MODE,
                         standard_default, MAX_PATH);
    if (!advanced_default[0])
        get_default_name(display, PGEN_CPST_EXTENDED_DISPLAY_COLOR_MODE,
                         advanced_default, MAX_PATH);
    append_display_profile_registry(display);
    append_display_profile_scope(display, WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER);
    append_display_profile_scope(display, WCS_PROFILE_MANAGEMENT_SCOPE_SYSTEM_WIDE);
    for (i = 0; i < g_profile_count; i++) {
        PROFILE_ENTRY *entry = &g_profiles[i];
        WCHAR label[MAX_PATH + 64];
        LRESULT row;
        entry->current_standard = standard_default[0] &&
                                  _wcsicmp(entry->name, standard_default) == 0;
        entry->current_advanced = advanced_default[0] &&
                                  _wcsicmp(entry->name, advanced_default) == 0;
        if (entry->current_standard && entry->current_advanced)
            swprintf(label, MAX_PATH + 64, L"%ls  (Current SDR and HDR profile)", entry->name);
        else if (entry->current_advanced)
            swprintf(label, MAX_PATH + 64, L"%ls  (Current HDR profile)", entry->name);
        else if (entry->current_standard)
            swprintf(label, MAX_PATH + 64, L"%ls  (Current SDR profile)", entry->name);
        else
            swprintf(label, MAX_PATH + 64, L"%ls  (%ls profile)", entry->name,
                     entry->advanced ? L"HDR" : L"SDR");
        row = SendMessageW(g_display_profiles, LB_ADDSTRING, 0, (LPARAM)label);
        if (row == LB_ERR || row == LB_ERRSPACE) continue;
        SendMessageW(g_display_profiles, LB_SETITEMDATA, (WPARAM)row, (LPARAM)i);
        if ((selected_name[0] && _wcsicmp(entry->name, selected_name) == 0) ||
            (!selected_name[0] && g_profile_name[0] &&
             _wcsicmp(entry->name, g_profile_name) == 0)) preferred = (int)row;
        if (current < 0 && (entry->current_advanced || entry->current_standard))
            current = (int)row;
    }
    if (preferred < 0) preferred = current;
    if (preferred < 0 && g_profile_count) preferred = 0;
    if (preferred >= 0) SendMessageW(g_display_profiles, LB_SETCURSEL, preferred, 0);
    EnableWindow(g_set_default, preferred >= 0);
}

static BOOL enable_per_user_profiles(DISPLAY_ENTRY *display, BOOL interactive) {
    BOOL enabled = FALSE;
    /* The modern association APIs do not enable the legacy per-user profile
       list shown as "Use my settings for this device" in Color Management.
       Without this, Windows can report our WCS default while the classic UI
       and older color-managed applications continue using the system list. */
    if (display && display->driver_key[0] &&
        WcsGetUsePerUserProfiles(display->driver_key, CLASS_MONITOR, &enabled) && enabled)
        return TRUE;
    if (display && display->driver_key[0] &&
        WcsSetUsePerUserProfiles(display->driver_key, CLASS_MONITOR, TRUE)) return TRUE;
    if (interactive)
        message_error(g_window, L"Enabling per-user display profiles", GetLastError());
    return FALSE;
}

/* Windows keeps the Advanced Color association name when a fine-tune pass
   replaces that profile's bytes, but DWM can continue using the transform it
   built from the previous file. Re-enter HDR on the selected target before
   reporting the Companion install complete so the next meter pass sees the
   newly installed MHC2 curves. This is the per-display equivalent of the
   Win+Alt+B recovery that operators otherwise have to perform by hand. */
static BOOL refresh_advanced_color_profile(DISPLAY_ENTRY *display) {
    DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO info;
    DISPLAYCONFIG_SET_ADVANCED_COLOR_STATE state;
    LONG result;
    int attempt;
    if (!display) return FALSE;
    ZeroMemory(&info, sizeof(info));
    info.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO;
    info.header.size = sizeof(info);
    info.header.adapterId = display->target_adapter;
    info.header.id = display->target_id;
    result = DisplayConfigGetDeviceInfo(&info.header);
    if (result != ERROR_SUCCESS) {
        SetLastError((DWORD)result);
        return FALSE;
    }
    if (!info.advancedColorEnabled) return TRUE;

    InterlockedExchange(&g_advanced_color_refresh_in_progress, 1);
    ZeroMemory(&state, sizeof(state));
    state.header.type = DISPLAYCONFIG_DEVICE_INFO_SET_ADVANCED_COLOR_STATE;
    state.header.size = sizeof(state);
    state.header.adapterId = display->target_adapter;
    state.header.id = display->target_id;
    state.enableAdvancedColor = 0;
    result = DisplayConfigSetDeviceInfo(&state.header);
    if (result != ERROR_SUCCESS) {
        InterlockedExchange(&g_advanced_color_refresh_in_progress, 0);
        SetLastError((DWORD)result);
        return FALSE;
    }
    Sleep(3000);
    state.enableAdvancedColor = 1;
    for (attempt = 0; attempt < 6; attempt++) {
        result = DisplayConfigSetDeviceInfo(&state.header);
        if (result == ERROR_SUCCESS) break;
        Sleep(500);
    }
    if (result != ERROR_SUCCESS) {
        InterlockedExchange(&g_advanced_color_refresh_in_progress, 0);
        SetLastError((DWORD)result);
        return FALSE;
    }
    Sleep(4000);
    InterlockedExchange(&g_advanced_color_refresh_in_progress, 0);
    return TRUE;
}

/* Explicit Companion cLUT/matrix handling already contains the profile's
   calibration in B2A0 (or the matrix/TRC path). Windows must therefore stop
   applying the per-user Advanced Color calibration underneath that test.
   Toggling the per-user scope leaves every association and its ordering
   intact, unlike removing the current default, which would promote an older
   HDR profile from the same display's list. */
static BOOL set_explicit_correction_isolation(BOOL isolate) {
    DISPLAY_ENTRY *display = selected_display();
    BOOL enabled = FALSE;
    if (!display || !display->driver_key[0]) {
        SetLastError(ERROR_NOT_FOUND);
        return FALSE;
    }
    if (!WcsGetUsePerUserProfiles(display->driver_key, CLASS_MONITOR, &enabled))
        return FALSE;
    if (isolate) {
        if (!g_correction_isolated) {
            g_isolation_was_per_user = enabled;
            g_correction_isolated = TRUE;
            save_settings();
        }
        if (enabled && !WcsSetUsePerUserProfiles(display->driver_key,
                                                 CLASS_MONITOR, FALSE))
            return FALSE;
    } else {
        if (enabled != g_isolation_was_per_user &&
            !WcsSetUsePerUserProfiles(display->driver_key, CLASS_MONITOR,
                                      g_isolation_was_per_user))
            return FALSE;
        /* Re-enabling the per-user scope does not reliably reselect the
           previous Advanced Color default. Reassert the exact cached profile
           before the reload so system handling cannot fall back to the vendor
           profile or another older association. */
        if (g_isolation_was_per_user && !associate_profile(display, FALSE))
            return FALSE;
    }
    /* Make DWM rebuild the Advanced Color path now. Without this, Windows can
       retain the transform from the previous scope until an unrelated window
       activation happens to rebuild it. */
    if (!refresh_advanced_color_profile(display)) return FALSE;
    if (!WcsGetUsePerUserProfiles(display->driver_key, CLASS_MONITOR, &enabled) ||
        enabled != (isolate ? FALSE : g_isolation_was_per_user)) {
        SetLastError(ERROR_INVALID_STATE);
        return FALSE;
    }
    if (!isolate) {
        g_correction_isolated = FALSE;
        if (g_isolation_owner) {
            CloseHandle(g_isolation_owner);
            g_isolation_owner = NULL;
        }
    }
    save_settings();
    return TRUE;
}

static BOOL associate_profile(DISPLAY_ENTRY *display, BOOL interactive) {
    HRESULT hr;
    BOOL associated;
    if (!display || !g_profile_name[0] || !p_add_association || !p_set_default ||
        !enable_per_user_profiles(display, interactive)) return FALSE;
    associated = display_profile_is_associated(display, g_profile_name);
    if (!associated || g_associate_advanced) {
        /* For a normal profile, add it without changing the active transform;
           the explicit default setter below performs the only pipeline switch. */
        hr = p_add_association(WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER,
                               g_profile_name, display->adapter, display->source_id,
                               g_associate_advanced, g_associate_advanced);
        if (FAILED(hr)) {
            if (interactive)
                message_error(g_window, L"Associating the profile with the display", (DWORD)hr);
            return FALSE;
        }
    }
    /* Adding a profile that is already associated can return success without
       promoting it over the previous default. Explicitly select it for both
       the standard and Advanced Color association lists. */
    hr = p_set_default(WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER,
                       g_profile_name, CPT_ICC,
                       g_associate_advanced ? PGEN_CPST_EXTENDED_DISPLAY_COLOR_MODE
                                            : PGEN_CPST_STANDARD_DISPLAY_COLOR_MODE,
                       display->adapter, display->source_id);
    if (FAILED(hr)) {
        if (interactive)
            message_error(g_window, L"Setting the profile as the display default", (DWORD)hr);
        return FALSE;
    }
    /* ColorProfileSetDisplayDefaultAssociation normally updates the legacy
       per-user list as well. Calling WcsSetDefaultColorProfile again can block
       for more than a minute while Windows refreshes the same association.
       Keep it only as a fallback for systems where the modern API did not
       synchronize the standard profile list. */
    if (!g_associate_advanced) {
        WCHAR standard[MAX_PATH] = L"", advanced[MAX_PATH] = L"";
        BOOL synchronized = registry_profile_defaults(display, standard, MAX_PATH,
                                                       advanced, MAX_PATH) &&
                            _wcsicmp(profile_basename(standard), g_profile_name) == 0;
        if (!synchronized &&
            !WcsSetDefaultColorProfile(WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER,
                                       display->source_name, CPT_ICC, CPST_NONE, 0,
                                       g_profile_name)) {
            if (interactive)
                message_error(g_window, L"Updating the legacy display profile default", GetLastError());
            return FALSE;
        }
    }
    g_last_reapply_tick = GetTickCount();
    g_mismatch_count = 0;
    return TRUE;
}

static void set_selected_profile_default(void) {
    DISPLAY_ENTRY *display = selected_display();
    LRESULT row, entry_index;
    PROFILE_ENTRY *entry;
    WCHAR path[MAX_PATH];
    if (!display) {
        MessageBoxW(g_window, L"Select an active display first.", APP_NAME,
                    MB_OK | MB_ICONWARNING);
        return;
    }
    row = SendMessageW(g_display_profiles, LB_GETCURSEL, 0, 0);
    if (row == LB_ERR) return;
    entry_index = SendMessageW(g_display_profiles, LB_GETITEMDATA, (WPARAM)row, 0);
    if (entry_index < 0 || (UINT)entry_index >= g_profile_count) return;
    entry = &g_profiles[entry_index];
    if (!installed_profile_path(entry->name, path, MAX_PATH)) {
        MessageBoxW(g_window,
                    L"Windows reports this display association, but the installed profile file could not be found.",
                    APP_NAME, MB_OK | MB_ICONERROR);
        return;
    }
    wcsncpy_s(g_profile_path, MAX_PATH, path, _TRUNCATE);
    wcsncpy_s(g_profile_name, MAX_PATH, entry->name, _TRUNCATE);
    g_profile_has_mhc2 = profile_contains_mhc2(path);
    g_associate_advanced = entry->current_advanced ||
                           (!entry->current_standard && entry->advanced);
    g_profile_pending_selection = FALSE;
    SetWindowTextW(g_profile, g_profile_path);
    if (!associate_profile(display, TRUE)) return;
    wcsncpy_s(g_saved_monitor_path, 256, display->monitor_path, _TRUNCATE);
    save_settings();
    refresh_display_profiles();
    verify_profile(FALSE);
}

static BOOL apply_profile(BOOL interactive) {
    DISPLAY_ENTRY *display = selected_display();
    DWORD error;
    BOOL reinstalled = FALSE;
    if (!display) {
        if (interactive) MessageBoxW(g_window, L"Select an active display first.", APP_NAME,
                                     MB_OK | MB_ICONWARNING);
        return FALSE;
    }
    if (!g_profile_path[0] || GetFileAttributesW(g_profile_path) == INVALID_FILE_ATTRIBUTES) {
        if (interactive) MessageBoxW(g_window, L"Choose an ICC or ICM profile first.", APP_NAME,
                                     MB_OK | MB_ICONWARNING);
        return FALSE;
    }
    if (!p_add_association) {
        if (interactive) MessageBoxW(g_window,
            L"This version of Windows does not provide the per-display profile association API. Windows 10 build 20348 or newer is required.",
            APP_NAME, MB_OK | MB_ICONERROR);
        return FALSE;
    }
    wcsncpy_s(g_profile_name, MAX_PATH, profile_basename(g_profile_path), _TRUNCATE);
    if (!installed_profile_matches(g_profile_name, g_profile_path)) {
        reinstalled = TRUE;
        if (!install_profile_file(g_profile_path)) {
            error = GetLastError();
            if (interactive && (error == ERROR_ACCESS_DENIED || error == ERROR_PRIVILEGE_NOT_HELD) &&
                install_elevated(g_profile_path)) {
                error = ERROR_SUCCESS;
            } else if (!installed_profile_matches(g_profile_name, g_profile_path)) {
                if (interactive) message_error(g_window, L"Installing the color profile", error);
                return FALSE;
            }
        }
    }
    g_profile_has_mhc2 = profile_contains_mhc2(g_profile_path);
    g_associate_advanced = profile_is_hdr_association(g_profile_path);
    /* Do this before the already-active shortcut. A profile may be present in
       the per-user WCS association list even though Color Management is still
       configured to ignore that list. */
    if (!enable_per_user_profiles(display, interactive)) return FALSE;
    /* Replacing the file leaves the association name unchanged, so the
       shortcut below would report success while Windows still holds the
       transform it built from the previous bytes. Set the association again
       instead. */
    if (!reinstalled) {
        WCHAR actual[MAX_PATH + 128] = L"";
        if (profile_is_active(display, actual, sizeof(actual) / sizeof(actual[0]))) {
            /* Any Advanced Color association change needs the reload cycle,
             * not only MHC2 profiles: a cLUT-only HDR profile still changes
             * the peak the pipeline reports, and an un-reloaded association
             * was measured serving the previous transform mid-session. */
            if (g_associate_advanced &&
                !refresh_advanced_color_profile(display)) {
                if (interactive)
                    message_error(g_window, L"Reloading the Advanced Color profile", GetLastError());
                return FALSE;
            }
            wcsncpy_s(g_saved_monitor_path, 256, display->monitor_path, _TRUNCATE);
            save_settings();
            return TRUE;
        }
    }
    if (!associate_profile(display, interactive)) return FALSE;
    if (g_associate_advanced &&
        !refresh_advanced_color_profile(display)) {
        if (interactive)
            message_error(g_window, L"Reloading the Advanced Color profile", GetLastError());
        return FALSE;
    }
    wcsncpy_s(g_saved_monitor_path, 256, display->monitor_path, _TRUNCATE);
    save_settings();
    return TRUE;
}

static void clear_display_default(void) {
    DISPLAY_ENTRY *display = selected_display();
    LPWSTR current = NULL;
    COLORPROFILESUBTYPE subtype = g_associate_advanced
                                ? PGEN_CPST_EXTENDED_DISPLAY_COLOR_MODE
                                : PGEN_CPST_STANDARD_DISPLAY_COLOR_MODE;
    HRESULT hr;
    WCHAR question[512];
    WCHAR result[512];
    if (!display) {
        MessageBoxW(g_window, L"Select an active display first.", APP_NAME,
                    MB_OK | MB_ICONWARNING);
        return;
    }
    if (!p_get_default || !p_remove_association) {
        MessageBoxW(g_window,
                    L"This version of Windows does not provide the per-display profile removal API.",
                    APP_NAME, MB_OK | MB_ICONERROR);
        return;
    }
    hr = p_get_default(WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER,
                       display->adapter, display->source_id, CPT_ICC,
                       subtype, &current);
    if (FAILED(hr) || !current || !current[0]) {
        if (current) LocalFree(current);
        set_status(FALSE, g_associate_advanced
                   ? L"No per-user HDR display profile is currently set as the default."
                   : L"No per-user SDR display profile is currently set as the default.");
        return;
    }
    swprintf(question, 512,
             L"Remove %ls as the current %ls display default?\n\nThe profile will remain installed and can be applied again later.",
             profile_basename(current), g_associate_advanced ? L"HDR" : L"SDR");
    if (MessageBoxW(g_window, question, APP_NAME,
                    MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2) != IDYES) {
        LocalFree(current);
        return;
    }
    hr = p_remove_association(WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER,
                              current, display->adapter, display->source_id,
                              g_associate_advanced);
    if (FAILED(hr)) {
        message_error(g_window, L"Removing the display profile association", (DWORD)hr);
        LocalFree(current);
        return;
    }
    if (!g_associate_advanced) {
        /* A NULL current-user default restores the system-wide fallback. */
        WcsSetDefaultColorProfile(WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER,
                                  display->source_name, CPT_ICC, CPST_NONE, 0, NULL);
    }
    g_auto_reapply = FALSE;
    InvalidateRect(GetDlgItem(g_window, ID_AUTOREAPPLY), NULL, TRUE);
    save_settings();
    swprintf(result, 512,
             L"Removed %ls as the per-user %ls display default. Windows will use the next available system or display profile.",
             profile_basename(current), g_associate_advanced ? L"HDR" : L"SDR");
    LocalFree(current);
    set_pending_status(L"DEFAULT PROFILE CLEARED", result);
    refresh_display_profiles();
}

static DWORD WINAPI apply_profile_thread(LPVOID unused) {
    BOOL ok;
    (void)unused;
    if (g_profile_operation == PROFILE_OPERATION_ISOLATE)
        ok = set_explicit_correction_isolation(TRUE);
    else if (g_profile_operation == PROFILE_OPERATION_RESTORE)
        ok = set_explicit_correction_isolation(FALSE);
    else
        ok = apply_profile(TRUE);
    write_companion_result(ok);
    PostMessageW(g_window, WM_APPLY_DONE, ok ? 1 : 0, 0);
    return 0;
}

static void write_companion_result(BOOL ok) {
    /* The apply stole foreground from the Companion's fullscreen HDR
     * window; without this grant Windows denies its reactivation and the
     * desktop's dim composed policy corrupts every following read. */
    AllowSetForegroundWindow(ASFW_ANY);
    HANDLE result;
    DWORD written = 0;
    const char *text = ok ? "ok" : "error";
    if (!g_companion_result[0]) return;
    result = CreateFileW(g_companion_result, GENERIC_WRITE, FILE_SHARE_READ,
                         NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (result != INVALID_HANDLE_VALUE) {
        WriteFile(result, text, (DWORD)strlen(text), &written, NULL);
        CloseHandle(result);
    }
    g_companion_result[0] = L'\0';
}

static BOOL finish_companion_apply_if_active(void) {
    DISPLAY_ENTRY *display;
    WCHAR standard[MAX_PATH] = L"", advanced[MAX_PATH] = L"";
    const WCHAR *current;
    if (g_profile_operation != PROFILE_OPERATION_APPLY ||
        !g_companion_result[0] || !g_profile_name[0] ||
        InterlockedCompareExchange(&g_advanced_color_refresh_in_progress, 0, 0) != 0)
        return FALSE;
    display = selected_display();
    if (!display || !registry_profile_defaults(display, standard, MAX_PATH,
                                                advanced, MAX_PATH)) return FALSE;
    current = g_associate_advanced ? advanced : standard;
    if (!current[0] || _wcsicmp(profile_basename(current), g_profile_name) != 0)
        return FALSE;
    wcsncpy_s(g_saved_monitor_path, 256, display->monitor_path, _TRUNCATE);
    g_profile_pending_selection = FALSE;
    save_settings();
    write_companion_result(TRUE);
    SetWindowTextW(g_apply, L"Finalizing...");
    verify_profile(FALSE);
    return TRUE;
}

static BOOL command_value(const WCHAR *command, const WCHAR *name,
                          WCHAR *value, size_t count) {
    const WCHAR *start;
    size_t used = 0;
    if (!command || !name || !value || count < 2) return FALSE;
    start = wcsstr(command, name);
    if (!start) return FALSE;
    start += wcslen(name);
    while (*start == L' ') start++;
    if (*start == L'"') {
        start++;
        while (*start && *start != L'"' && used + 1 < count) value[used++] = *start++;
    } else {
        while (*start && *start != L' ' && used + 1 < count) value[used++] = *start++;
    }
    value[used] = L'\0';
    return used > 0;
}

static void apply_companion_command(const WCHAR *command) {
    WCHAR profile[MAX_PATH] = L"";
    WCHAR monitor[256] = L"";
    WCHAR result[MAX_PATH] = L"";
    WCHAR owner_text[32] = L"";
    BOOL isolate, restore;
    DWORD owner_pid = 0;
    if (!command) return;
    isolate = wcsstr(command, L"--isolate-for-correction") != NULL;
    restore = wcsstr(command, L"--restore-after-correction") != NULL;
    if ((!wcsstr(command, L"--apply-from-companion") && !isolate && !restore) ||
        !command_value(command, L"--profile", profile, MAX_PATH)) return;
    command_value(command, L"--monitor", monitor, 256);
    command_value(command, L"--result", result, MAX_PATH);
    if (command_value(command, L"--owner-pid", owner_text, 32))
        owner_pid = wcstoul(owner_text, NULL, 10);
    if (monitor[0]) {
        wcsncpy_s(g_saved_monitor_path, 256, monitor, _TRUNCATE);
        enumerate_displays();
        refresh_display_profiles();
    }
    if (result[0]) {
        DeleteFileW(result);
        wcsncpy_s(g_companion_result, MAX_PATH, result, _TRUNCATE);
    }
    /* A previous Companion can be terminated while explicit correction has
       the per-user profile scope suspended. Loader startup restores the saved
       scope synchronously, but the new Companion may already have queried the
       temporary system fallback and sent it back in its first isolate request.
       Reject that one stale request. The Companion will query the restored
       profile and retry instead of caching or associating the fallback. */
    if (isolate && g_reject_next_isolate_for_stale_restore) {
        g_reject_next_isolate_for_stale_restore = FALSE;
        write_companion_result(FALSE);
        return;
    }
    g_browse_has_mhc2 = profile_contains_mhc2(profile);
    g_browse_advanced = profile_is_hdr_association(profile);
    /* Adopt the requested profile as the loader's selection IMMEDIATELY,
       before any queueing: if the verify timer auto-reapplies while this
       command waits out a prior apply's Advanced Color cycle, it must
       reapply the profile the WebUI just asked for, never the stale saved
       one. Rejecting a busy command used to leave the old selection saved
       and the timer then set the old profile as default mid-session. */
    accept_profile_path(profile);
    save_settings();
    g_profile_operation = isolate ? PROFILE_OPERATION_ISOLATE
                                  : (restore ? PROFILE_OPERATION_RESTORE
                                             : PROFILE_OPERATION_APPLY);
    if (isolate && owner_pid) {
        HANDLE owner = OpenProcess(SYNCHRONIZE, FALSE, owner_pid);
        if (owner) {
            if (g_isolation_owner) CloseHandle(g_isolation_owner);
            g_isolation_owner = owner;
        }
    }
    if (InterlockedCompareExchange(&g_apply_in_progress, 0, 0) != 0) {
        wcsncpy_s(g_pending_companion, 2048, command, _TRUNCATE);
        return;
    }
    start_profile_operation(g_profile_operation);
}

static void start_profile_operation(int operation) {
    HANDLE thread;
    if (InterlockedCompareExchange(&g_apply_in_progress, 1, 0) != 0) return;
    g_profile_operation = operation;
    EnableWindow(g_apply, FALSE);
    SetWindowTextW(g_apply, L"Applying...");
    set_pending_status(L"APPLYING PROFILE",
                       L"Windows is installing and activating the selected profile. You can continue using this window while it finishes.");
    InvalidateRect(g_apply, NULL, TRUE);
    thread = CreateThread(NULL, 0, apply_profile_thread, NULL, 0, NULL);
    if (!thread) {
        InterlockedExchange(&g_apply_in_progress, 0);
        EnableWindow(g_apply, TRUE);
        SetWindowTextW(g_apply, L"Install and apply");
        message_error(g_window, L"Starting profile application", GetLastError());
        show_ready_status();
        return;
    }
    CloseHandle(thread);
}

static void start_apply_profile(void) {
    start_profile_operation(PROFILE_OPERATION_APPLY);
}

static void verify_profile(BOOL allow_reapply) {
    DISPLAY_ENTRY *display = selected_display();
    WCHAR actual[MAX_PATH + 128] = L"";
    WCHAR text[768];
    BOOL active;
    if (g_correction_isolated) {
        set_status(TRUE,
                   L"Explicit cLUT/matrix correction is active. The selected display's per-user profile stage is temporarily suspended; all saved profile associations are unchanged.");
        return;
    }
    if (!display) {
        set_status(FALSE, L"No active display is available.");
        return;
    }
    if (g_profile_pending_selection && g_profile_name[0]) {
        show_ready_status();
        return;
    }
    if (!g_profile_name[0]) {
        set_status(FALSE, L"No profile has been selected. Choose a profile, then install and apply it.");
        return;
    }
    active = profile_is_active(display, actual, sizeof(actual) / sizeof(actual[0]));
    if (!active) {
        DWORD now = GetTickCount();
        g_mismatch_count++;
        /* Wait for two failed checks and permit at most one automatic
           association attempt per minute. Never reinstall from the timer. */
        if (allow_reapply && g_auto_reapply && g_profile_name[0] &&
            g_mismatch_count >= 2 && !g_reapply_attempted_for_mismatch &&
            (g_last_reapply_tick == 0 || now - g_last_reapply_tick >= 60000)) {
            g_reapply_attempted_for_mismatch = TRUE;
            if (associate_profile(display, FALSE)) {
                active = profile_is_active(display, actual, sizeof(actual) / sizeof(actual[0]));
                if (active) {
                    verify_profile(FALSE);
                    return;
                }
            }
        }
    } else {
        g_mismatch_count = 0;
        g_reapply_attempted_for_mismatch = FALSE;
    }
    if (active) {
        if (g_profile_has_mhc2)
            swprintf(text, 768,
                     L"Active and verified: %ls\r\nWindows reports this MHC2 profile as the display default. Its system-wide correction is loaded by the Windows Advanced Color pipeline.",
                     g_profile_name);
        else
            swprintf(text, 768,
                     L"Active and verified: %ls\r\nWindows reports this as the display default. Applications that use Windows color management can use this profile; it does not contain an MHC2 system correction.",
                     g_profile_name);
        set_status(TRUE, text);
    } else {
        swprintf(text, 768, L"Not active. Selected: %ls\r\nWindows default: %ls",
                 g_profile_name, actual[0] ? actual : L"not reported");
        set_status(FALSE, text);
    }
}

static void accept_profile_path(const WCHAR *path) {
    wcsncpy_s(g_profile_path, MAX_PATH, path, _TRUNCATE);
    SetWindowTextW(g_profile, g_profile_path);
    g_profile_has_mhc2 = g_browse_has_mhc2;
    g_associate_advanced = g_browse_advanced;
    wcsncpy_s(g_profile_name, MAX_PATH, profile_basename(g_profile_path), _TRUNCATE);
    g_profile_pending_selection = TRUE;
    show_ready_status();
}

static DWORD WINAPI choose_profile_thread(LPVOID unused) {
    OPENFILENAMEW ofn;
    (void)unused;
    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    ZeroMemory(&ofn, sizeof(ofn));
    ofn.lStructSize = sizeof(ofn);
    /* Do not make a window from another thread the modal owner. That can
       deadlock the Explorer dialog while it re-enables the owner on Open. */
    ofn.hwndOwner = NULL;
    ofn.lpstrFilter = L"Color profiles (*.icc;*.icm)\0*.icc;*.icm\0All files (*.*)\0*.*\0";
    ofn.lpstrFile = g_browse_path;
    ofn.nMaxFile = MAX_PATH;
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_EXPLORER | OFN_NOCHANGEDIR;
    if (GetOpenFileNameW(&ofn)) {
        g_browse_has_mhc2 = profile_contains_mhc2(g_browse_path);
        g_browse_advanced = profile_is_hdr_association(g_browse_path);
        PostMessageW(g_window, WM_BROWSE_DONE, 1, 0);
    } else {
        PostMessageW(g_window, WM_BROWSE_DONE, 0, 0);
    }
    CoUninitialize();
    return 0;
}

static void choose_profile(void) {
    HANDLE thread;
    if (InterlockedCompareExchange(&g_browse_in_progress, 1, 0) != 0) return;
    wcsncpy_s(g_browse_path, MAX_PATH, g_profile_path, _TRUNCATE);
    EnableWindow(g_browse, FALSE);
    EnableWindow(g_apply, FALSE);
    SetWindowTextW(g_browse, L"Opening...");
    thread = CreateThread(NULL, 0, choose_profile_thread, NULL, 0, NULL);
    if (!thread) {
        InterlockedExchange(&g_browse_in_progress, 0);
        EnableWindow(g_browse, TRUE);
        EnableWindow(g_apply, TRUE);
        SetWindowTextW(g_browse, L"Browse");
        message_error(g_window, L"Opening the profile picker", GetLastError());
        return;
    }
    CloseHandle(thread);
}

static void layout_controls(HWND hwnd) {
    RECT rc;
    int w, content_w;
    GetClientRect(hwnd, &rc);
    w = rc.right - rc.left;
    content_w = w - px(56);
    MoveWindow(g_display, px(28), px(140), content_w, px(280), TRUE);
    MoveWindow(g_profile, px(28), px(220), content_w - px(124), px(34), TRUE);
    MoveWindow(GetDlgItem(hwnd, ID_BROWSE), w - px(140), px(218), px(112), px(38), TRUE);
    MoveWindow(GetDlgItem(hwnd, ID_AUTOREAPPLY), px(28), px(276), px(390), px(24), TRUE);
    MoveWindow(GetDlgItem(hwnd, ID_STARTUP), w - px(190), px(276), px(162), px(24), TRUE);
    MoveWindow(g_display_profiles, px(28), px(342), content_w - px(170), px(112), TRUE);
    MoveWindow(g_set_default, w - px(188), px(342), px(160), px(40), TRUE);
    MoveWindow(g_status_heading, px(58), px(497), content_w - px(56), px(20), TRUE);
    MoveWindow(g_status, px(58), px(524), content_w - px(60), px(62), TRUE);
    MoveWindow(GetDlgItem(hwnd, ID_SETTINGS), px(28), px(614), px(190), px(40), TRUE);
    MoveWindow(g_clear_default, px(228), px(614), px(168), px(40), TRUE);
    MoveWindow(GetDlgItem(hwnd, ID_HIDE), w - px(292), px(614), px(126), px(40), TRUE);
    MoveWindow(g_apply, w - px(156), px(614), px(128), px(40), TRUE);
}

static void show_window(void) {
    ShowWindow(g_window, SW_SHOW);
    SetForegroundWindow(g_window);
    verify_profile(FALSE);
}

static void show_tray_menu(void) {
    POINT pt;
    HMENU menu = CreatePopupMenu();
    AppendMenuW(menu, MF_STRING, ID_TRAY_SHOW, L"Open Profile Loader");
    AppendMenuW(menu, MF_STRING, ID_TRAY_APPLY, L"Reapply selected profile");
    AppendMenuW(menu, MF_STRING, ID_TRAY_CLEAR_DEFAULT, L"Clear display default");
    AppendMenuW(menu, MF_STRING | (g_auto_reapply ? MF_CHECKED : 0),
                ID_TRAY_AUTOREAPPLY, L"Automatically reapply");
    AppendMenuW(menu, MF_STRING, ID_TRAY_SETTINGS, L"Windows Color Profile settings");
    AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
    AppendMenuW(menu, MF_STRING, ID_TRAY_EXIT, L"Exit");
    GetCursorPos(&pt);
    SetForegroundWindow(g_window);
    TrackPopupMenu(menu, TPM_RIGHTBUTTON, pt.x, pt.y, 0, g_window, NULL);
    DestroyMenu(menu);
}

static void open_color_settings(void) {
    HINSTANCE result = ShellExecuteW(g_window, L"open",
                                     L"ms-settings:display?settingId=SystemSettings_Display_ColorProfileSetting",
                                     NULL, NULL, SW_SHOWNORMAL);
    if ((INT_PTR)result <= 32)
        result = ShellExecuteW(g_window, L"open", L"ms-settings:display",
                               NULL, NULL, SW_SHOWNORMAL);
    if ((INT_PTR)result <= 32)
        ShellExecuteW(g_window, L"open", L"colorcpl.exe", NULL, NULL, SW_SHOWNORMAL);
}

static LRESULT CALLBACK window_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE: {
        HWND ctl;
        g_dpi = GetDpiForWindow(hwnd);
        if (!g_dpi) g_dpi = 96;
        /* Segoe UI is 9pt in native Windows dialogs. px() and make_ui_font()
         * already convert 96-dpi design units once each under the PerMonitorV2
         * manifest, so there is no scale multiplier to remove here - the title
         * was simply authored far larger than any native dialog heading. */
        g_font_normal = make_ui_font(9, FW_NORMAL);
        g_font_label = make_ui_font(8, FW_SEMIBOLD);
        g_font_title = make_ui_font(13, FW_SEMIBOLD);
        g_font_subtitle = make_ui_font(9, FW_NORMAL);
        g_font_button = make_ui_font(9, FW_SEMIBOLD);
        apply_titlebar_theme(hwnd);
        g_brush_background = CreateSolidBrush(g_palette.background);
        g_brush_card = CreateSolidBrush(g_palette.card);

        ctl = CreateWindowW(L"STATIC", L"PGenerator+ Profile Loader",
                            WS_CHILD | WS_VISIBLE, px(28), px(22), px(520), px(38),
                            hwnd, NULL, g_instance, NULL);
        apply_font(ctl, g_font_title);
        ctl = CreateWindowW(L"STATIC",
                            L"Keep the correct display profile active across Windows and HDR mode changes.",
                            WS_CHILD | WS_VISIBLE, px(30), px(66), px(620), px(24),
                            hwnd, NULL, g_instance, NULL);
        apply_font(ctl, g_font_subtitle);
        ctl = CreateWindowW(L"STATIC", L"DISPLAY", WS_CHILD | WS_VISIBLE,
                            px(28), px(112), px(120), px(20), hwnd, NULL, g_instance, NULL);
        apply_font(ctl, g_font_label);
        g_display = CreateWindowW(WC_COMBOBOXW, L"", WS_CHILD | WS_VISIBLE |
                                  CBS_DROPDOWNLIST | WS_VSCROLL |
                                  CBS_OWNERDRAWFIXED | CBS_HASSTRINGS,
                                  px(28), px(140), px(644), px(280),
                                  hwnd, (HMENU)ID_DISPLAY, g_instance, NULL);
        apply_font(g_display, g_font_normal);
        apply_control_theme(g_display);
        ctl = CreateWindowW(L"STATIC", L"ICC PROFILE", WS_CHILD | WS_VISIBLE,
                            px(28), px(192), px(140), px(20), hwnd, NULL, g_instance, NULL);
        apply_font(ctl, g_font_label);
        g_profile = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
                                    WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL | ES_READONLY,
                                    px(28), px(220), px(520), px(34), hwnd,
                                    (HMENU)ID_PROFILE, g_instance, NULL);
        apply_font(g_profile, g_font_normal);
        apply_control_theme(g_profile);
        g_browse = CreateWindowW(L"BUTTON", L"Browse", WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
                                 px(560), px(218), px(112), px(38), hwnd,
                                 (HMENU)ID_BROWSE, g_instance, NULL);
        apply_font(g_browse, g_font_button);
        apply_control_theme(g_browse);
        ctl = CreateWindowW(L"BUTTON", L"Automatically restore the selected profile",
                            WS_CHILD | WS_VISIBLE | BS_OWNERDRAW, px(28), px(276), px(390), px(24),
                            hwnd, (HMENU)ID_AUTOREAPPLY, g_instance, NULL);
        apply_font(ctl, g_font_normal);
        ctl = CreateWindowW(L"BUTTON", L"Start with Windows", WS_CHILD | WS_VISIBLE |
                            BS_OWNERDRAW, px(510), px(276), px(162), px(24), hwnd,
                            (HMENU)ID_STARTUP, g_instance, NULL);
        apply_font(ctl, g_font_normal);
        g_startup_enabled = startup_enabled();
        ctl = CreateWindowW(L"STATIC", L"PROFILES FOR SELECTED DISPLAY",
                            WS_CHILD | WS_VISIBLE, px(28), px(316), px(260), px(20),
                            hwnd, NULL, g_instance, NULL);
        apply_font(ctl, g_font_label);
        g_display_profiles = CreateWindowExW(WS_EX_CLIENTEDGE, L"LISTBOX", L"",
                                              WS_CHILD | WS_VISIBLE | WS_VSCROLL |
                                              LBS_NOTIFY | LBS_NOINTEGRALHEIGHT |
                                              LBS_OWNERDRAWFIXED | LBS_HASSTRINGS,
                                              px(28), px(342), px(474), px(112), hwnd,
                                              (HMENU)ID_DISPLAY_PROFILES, g_instance, NULL);
        apply_font(g_display_profiles, g_font_normal);
        apply_control_theme(g_display_profiles);
        g_set_default = CreateWindowW(L"BUTTON", L"Set as default",
                                      WS_CHILD | WS_VISIBLE | WS_DISABLED | BS_OWNERDRAW,
                                      px(512), px(342), px(160), px(40), hwnd,
                                      (HMENU)ID_SET_DEFAULT, g_instance, NULL);
        apply_font(g_set_default, g_font_button);
        apply_control_theme(g_set_default);
        g_status_heading = CreateWindowW(L"STATIC", L"ATTENTION REQUIRED",
                                         WS_CHILD | WS_VISIBLE, px(58), px(497), px(520), px(20),
                                         hwnd, NULL, g_instance, NULL);
        apply_font(g_status_heading, g_font_label);
        g_status = CreateWindowW(L"STATIC", L"",
                                   WS_CHILD | WS_VISIBLE | SS_LEFT, px(58), px(524), px(570), px(62),
                                   hwnd, (HMENU)ID_STATUS, g_instance, NULL);
        apply_font(g_status, g_font_normal);
        ctl = CreateWindowW(L"BUTTON", L"Windows color settings",
                            WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
                            px(28), px(614), px(190), px(40), hwnd,
                            (HMENU)ID_SETTINGS, g_instance, NULL);
        apply_font(ctl, g_font_button);
        apply_control_theme(ctl);
        g_clear_default = CreateWindowW(L"BUTTON", L"Clear display default",
                                        WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
                                        px(228), px(614), px(168), px(40), hwnd,
                                        (HMENU)ID_CLEAR_DEFAULT, g_instance, NULL);
        apply_font(g_clear_default, g_font_button);
        SetWindowTheme(g_clear_default, L"Explorer", NULL);
        ctl = CreateWindowW(L"BUTTON", L"Hide to tray", WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
                            px(408), px(614), px(126), px(40), hwnd,
                            (HMENU)ID_HIDE, g_instance, NULL);
        apply_font(ctl, g_font_button);
        apply_control_theme(ctl);
        g_apply = CreateWindowW(L"BUTTON", L"Install and apply", WS_CHILD | WS_VISIBLE |
                                BS_OWNERDRAW, px(544), px(614), px(128), px(40), hwnd,
                                (HMENU)ID_APPLY, g_instance, NULL);
        apply_font(g_apply, g_font_button);
        SetWindowTextW(g_profile, g_profile_path);
        enumerate_displays();
        refresh_display_profiles();
        SetTimer(hwnd, TIMER_VERIFY, 5000, NULL);
        verify_profile(FALSE);
        break;
    }
    case WM_ERASEBKGND: {
        RECT rc;
        GetClientRect(hwnd, &rc);
        FillRect((HDC)wp, &rc, g_brush_background ? g_brush_background : (HBRUSH)(COLOR_WINDOW + 1));
        return 1;
    }
    case WM_PAINT: {
        PAINTSTRUCT ps;
        RECT rc, card;
        HDC dc = BeginPaint(hwnd, &ps);
        HBRUSH accent = CreateSolidBrush(g_palette.accent);
        HBRUSH dot = CreateSolidBrush(g_status_ok ? g_palette.ok :
                                     (g_status_pending ? g_palette.pending : g_palette.bad));
        HPEN border_pen = CreatePen(PS_SOLID, 1, g_palette.border);
        HGDIOBJ old_pen, old_brush;
        GetClientRect(hwnd, &rc);
        FillRect(dc, &rc, g_brush_background);
        rc.bottom = px(5);
        FillRect(dc, &rc, accent);
        card.left = px(28); card.top = px(480);
        card.right = rc.right - px(28);
        card.bottom = px(594);
        old_pen = SelectObject(dc, border_pen);
        old_brush = SelectObject(dc, g_brush_card);
        RoundRect(dc, card.left, card.top, card.right, card.bottom, px(14), px(14));
        SelectObject(dc, old_brush);
        SelectObject(dc, old_pen);
        old_pen = SelectObject(dc, GetStockObject(NULL_PEN));
        old_brush = SelectObject(dc, dot);
        Ellipse(dc, px(42), px(499), px(52), px(509));
        SelectObject(dc, old_brush);
        SelectObject(dc, old_pen);
        DeleteObject(accent);
        DeleteObject(dot);
        DeleteObject(border_pen);
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_CTLCOLORSTATIC: {
        HDC dc = (HDC)wp;
        HWND control = (HWND)lp;
        SetBkMode(dc, TRANSPARENT);
        if (control == g_status || control == g_status_heading) {
            SetTextColor(dc, control == g_status_heading
                             ? (g_status_ok ? g_palette.ok :
                                (g_status_pending ? g_palette.pending : g_palette.bad))
                             : g_palette.text);
            SetBkColor(dc, g_palette.card);
            return (LRESULT)g_brush_card;
        }
        SetTextColor(dc, g_palette.text);
        return (LRESULT)g_brush_background;
    }
    case WM_CTLCOLORBTN:
        SetBkMode((HDC)wp, TRANSPARENT);
        SetTextColor((HDC)wp, g_palette.text);
        return (LRESULT)g_brush_background;
    case WM_CTLCOLOREDIT:
    case WM_CTLCOLORLISTBOX: {
        /* Cached brush: creating one per message would leak a GDI object on
         * every repaint. It is rebuilt on a theme change and freed on destroy. */
        HDC dc = (HDC)wp;
        SetTextColor(dc, g_palette.text);
        SetBkColor(dc, g_palette.input);
        if (!g_brush_input) g_brush_input = CreateSolidBrush(g_palette.input);
        return (LRESULT)g_brush_input;
    }
    case WM_MEASUREITEM: {
        MEASUREITEMSTRUCT *measure = (MEASUREITEMSTRUCT *)lp;
        if (measure && (measure->CtlID == ID_DISPLAY_PROFILES || measure->CtlID == ID_DISPLAY)) {
            measure->itemHeight = (UINT)px(22);
            return TRUE;
        }
        break;
    }
    case WM_DRAWITEM: {
        DRAWITEMSTRUCT *item = (DRAWITEMSTRUCT *)lp;
        /* The list and the combo are owner-drawn because their selection bar is
         * otherwise system blue on system white, which is unreadable inside a
         * dark panel. */
        if (item && (item->CtlID == ID_DISPLAY_PROFILES || item->CtlID == ID_DISPLAY) &&
            item->CtlType != ODT_BUTTON) {
            WCHAR text[MAX_PATH + 96];
            BOOL selected = (item->itemState & ODS_SELECTED) != 0;
            HBRUSH back = CreateSolidBrush(selected ? g_palette.selection : g_palette.input);
            RECT text_rect = item->rcItem;
            if ((int)item->itemID < 0) {
                DeleteObject(back);
                break;
            }
            FillRect(item->hDC, &item->rcItem, back);
            DeleteObject(back);
            text[0] = L'\0';
            if (item->CtlType == ODT_COMBOBOX)
                SendMessageW(item->hwndItem, CB_GETLBTEXT, item->itemID, (LPARAM)text);
            else
                SendMessageW(item->hwndItem, LB_GETTEXT, item->itemID, (LPARAM)text);
            SetBkMode(item->hDC, TRANSPARENT);
            SetTextColor(item->hDC, (item->itemState & ODS_DISABLED) ? g_palette.disabled
                                    : (selected ? g_palette.selection_text : g_palette.text));
            SelectObject(item->hDC, g_font_normal);
            text_rect.left += px(6);
            text_rect.right -= px(6);
            DrawTextW(item->hDC, text, -1, &text_rect,
                      DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
            if (item->itemState & ODS_FOCUS) DrawFocusRect(item->hDC, &item->rcItem);
            return TRUE;
        }
        /* Checkboxes are BUTTON-class windows, so WM_CTLCOLORSTATIC never
         * reaches their label and a dark brush cannot fix the text colour.
         * They are drawn here from the palette instead of opting the process
         * into dark mode through the undocumented uxtheme ordinals, which vary
         * by Windows build and cannot be tested here. Owner-drawing means this
         * control no longer keeps its own check state, so the two toggles are
         * tracked in g_auto_reapply and g_startup_enabled. */
        if (item && item->CtlType == ODT_BUTTON &&
            (item->CtlID == ID_AUTOREAPPLY || item->CtlID == ID_STARTUP)) {
            BOOL checked = item->CtlID == ID_AUTOREAPPLY ? g_auto_reapply : g_startup_enabled;
            BOOL disabled = (item->itemState & ODS_DISABLED) != 0;
            int side = px(15);
            RECT box = item->rcItem;
            RECT label = item->rcItem;
            WCHAR text[128];
            HBRUSH face = CreateSolidBrush(checked && !disabled ? g_palette.accent
                                                                : g_palette.input);
            HPEN pen = CreatePen(PS_SOLID, 1, disabled ? g_palette.disabled :
                                 (checked ? g_palette.accent : g_palette.border));
            HGDIOBJ old_brush, old_pen;
            box.top += (box.bottom - box.top - side) / 2;
            box.bottom = box.top + side;
            box.right = box.left + side;
            FillRect(item->hDC, &item->rcItem, g_brush_background);
            old_brush = SelectObject(item->hDC, face);
            old_pen = SelectObject(item->hDC, pen);
            Rectangle(item->hDC, box.left, box.top, box.right, box.bottom);
            SelectObject(item->hDC, old_brush);
            SelectObject(item->hDC, old_pen);
            DeleteObject(face);
            DeleteObject(pen);
            if (checked) {
                /* A tick drawn as two strokes, so no font or glyph is needed. */
                HPEN tick = CreatePen(PS_SOLID, px(2),
                                      disabled ? g_palette.disabled : g_palette.on_accent);
                HGDIOBJ old_tick = SelectObject(item->hDC, tick);
                MoveToEx(item->hDC, box.left + px(3), box.top + px(7), NULL);
                LineTo(item->hDC, box.left + px(6), box.bottom - px(4));
                LineTo(item->hDC, box.right - px(3), box.top + px(4));
                SelectObject(item->hDC, old_tick);
                DeleteObject(tick);
            }
            GetWindowTextW(item->hwndItem, text, 128);
            label.left = box.right + px(8);
            SetBkMode(item->hDC, TRANSPARENT);
            SetTextColor(item->hDC, disabled ? g_palette.disabled : g_palette.text);
            SelectObject(item->hDC, g_font_normal);
            DrawTextW(item->hDC, text, -1, &label,
                      DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
            if (item->itemState & ODS_FOCUS) DrawFocusRect(item->hDC, &item->rcItem);
            return TRUE;
        }
        /* Secondary push buttons. Win32 leaves these light in a dark window
         * even with a dark theme class applied, so they are drawn to match the
         * primary action instead of being left as white rectangles. */
        if (item && item->CtlType == ODT_BUTTON && item->CtlID != ID_APPLY) {
            BOOL disabled = (item->itemState & ODS_DISABLED) != 0;
            BOOL pressed = (item->itemState & ODS_SELECTED) != 0;
            COLORREF fill = disabled ? blend_color(g_palette.control, g_palette.background, 0.55)
                                     : (pressed ? g_palette.control_hot : g_palette.control);
            HBRUSH brush = CreateSolidBrush(fill);
            HPEN pen = CreatePen(PS_SOLID, 1, g_palette.border);
            HGDIOBJ old_brush = SelectObject(item->hDC, brush);
            HGDIOBJ old_pen = SelectObject(item->hDC, pen);
            WCHAR text[64];
            FillRect(item->hDC, &item->rcItem, g_brush_background);
            RoundRect(item->hDC, item->rcItem.left, item->rcItem.top,
                      item->rcItem.right, item->rcItem.bottom, px(10), px(10));
            SelectObject(item->hDC, old_brush);
            SelectObject(item->hDC, old_pen);
            DeleteObject(brush);
            DeleteObject(pen);
            GetWindowTextW(item->hwndItem, text, 64);
            SetBkMode(item->hDC, TRANSPARENT);
            SetTextColor(item->hDC, disabled ? g_palette.disabled : g_palette.text);
            SelectObject(item->hDC, g_font_button);
            DrawTextW(item->hDC, text, -1, &item->rcItem,
                      DT_CENTER | DT_VCENTER | DT_SINGLELINE);
            if (item->itemState & ODS_FOCUS) {
                RECT focus = item->rcItem;
                InflateRect(&focus, -px(4), -px(4));
                DrawFocusRect(item->hDC, &focus);
            }
            return TRUE;
        }
        if (item && item->CtlID == ID_APPLY) {
            COLORREF color = (item->itemState & ODS_DISABLED) ? g_palette.disabled :
                             ((item->itemState & ODS_SELECTED) ? g_palette.accent_pressed
                                                               : g_palette.accent);
            HBRUSH brush = CreateSolidBrush(color);
            HGDIOBJ old_brush = SelectObject(item->hDC, brush);
            HGDIOBJ old_pen = SelectObject(item->hDC, GetStockObject(NULL_PEN));
            WCHAR text[64];
            RoundRect(item->hDC, item->rcItem.left, item->rcItem.top,
                      item->rcItem.right, item->rcItem.bottom, px(10), px(10));
            SelectObject(item->hDC, old_brush);
            SelectObject(item->hDC, old_pen);
            DeleteObject(brush);
            GetWindowTextW(item->hwndItem, text, 64);
            SetBkMode(item->hDC, TRANSPARENT);
            SetTextColor(item->hDC, g_palette.on_accent);
            SelectObject(item->hDC, g_font_button);
            DrawTextW(item->hDC, text, -1, &item->rcItem,
                      DT_CENTER | DT_VCENTER | DT_SINGLELINE);
            if (item->itemState & ODS_FOCUS) {
                RECT focus = item->rcItem;
                InflateRect(&focus, -px(4), -px(4));
                DrawFocusRect(item->hDC, &focus);
            }
            return TRUE;
        }
        break;
    }
    case WM_SIZE:
        if (wp != SIZE_MINIMIZED) layout_controls(hwnd);
        else ShowWindow(hwnd, SW_HIDE);
        return 0;
    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case ID_BROWSE: choose_profile(); break;
        case ID_APPLY: start_apply_profile(); break;
        case ID_SET_DEFAULT: set_selected_profile_default(); break;
        case ID_DISPLAY_PROFILES:
            if (HIWORD(wp) == LBN_SELCHANGE)
                EnableWindow(g_set_default,
                             SendMessageW(g_display_profiles, LB_GETCURSEL, 0, 0) != LB_ERR);
            else if (HIWORD(wp) == LBN_DBLCLK)
                set_selected_profile_default();
            break;
        case ID_CLEAR_DEFAULT: case ID_TRAY_CLEAR_DEFAULT: clear_display_default(); break;
        case ID_SETTINGS: case ID_TRAY_SETTINGS: open_color_settings(); break;
        case ID_HIDE: ShowWindow(hwnd, SW_HIDE); break;
        case ID_DISPLAY:
            if (HIWORD(wp) == CBN_SELCHANGE) {
                DISPLAY_ENTRY *d = selected_display();
                if (d) wcsncpy_s(g_saved_monitor_path, 256, d->monitor_path, _TRUNCATE);
                save_settings(); refresh_display_profiles(); verify_profile(FALSE);
            }
            break;
        case ID_AUTOREAPPLY:
            g_auto_reapply = !g_auto_reapply;
            InvalidateRect(GetDlgItem(hwnd, ID_AUTOREAPPLY), NULL, TRUE);
            save_settings(); break;
        case ID_STARTUP:
            g_startup_enabled = !g_startup_enabled;
            InvalidateRect(GetDlgItem(hwnd, ID_STARTUP), NULL, TRUE);
            if (!set_startup(g_startup_enabled))
                message_error(hwnd, L"Updating Windows startup", GetLastError());
            break;
        case ID_TRAY_SHOW: show_window(); break;
        case ID_TRAY_APPLY: start_apply_profile(); break;
        case ID_TRAY_AUTOREAPPLY:
            g_auto_reapply = !g_auto_reapply;
            InvalidateRect(GetDlgItem(hwnd, ID_AUTOREAPPLY), NULL, TRUE);
            save_settings(); break;
        case ID_TRAY_EXIT: g_exiting = TRUE; DestroyWindow(hwnd); break;
        }
        return 0;
    case WM_COPYDATA: {
        const COPYDATASTRUCT *copy = (const COPYDATASTRUCT *)lp;
        if (copy && copy->lpData && copy->cbData >= sizeof(WCHAR))
            apply_companion_command((const WCHAR *)copy->lpData);
        return TRUE;
    }
    case WM_TIMER:
        if (wp == TIMER_VERIFY) {
            if (g_correction_isolated && g_isolation_owner &&
                WaitForSingleObject(g_isolation_owner, 0) == WAIT_OBJECT_0 &&
                InterlockedCompareExchange(&g_apply_in_progress, 0, 0) == 0) {
                g_companion_result[0] = L'\0';
                start_profile_operation(PROFILE_OPERATION_RESTORE);
            } else if (InterlockedCompareExchange(&g_apply_in_progress, 0, 0) != 0)
                finish_companion_apply_if_active();
            else if (InterlockedCompareExchange(&g_browse_in_progress, 0, 0) == 0
                     && !g_pending_companion[0])
                verify_profile(TRUE);
        }
        return 0;
    case WM_APPLY_DONE:
        InterlockedExchange(&g_apply_in_progress, 0);
        EnableWindow(g_apply, TRUE);
        SetWindowTextW(g_apply, L"Install and apply");
        InvalidateRect(g_apply, NULL, TRUE);
        if (wp) g_profile_pending_selection = FALSE;
        refresh_display_profiles();
        if (g_pending_companion[0]) {
            WCHAR queued[2048];
            wcsncpy_s(queued, 2048, g_pending_companion, _TRUNCATE);
            g_pending_companion[0] = L'\0';
            apply_companion_command(queued);
            return 0;
        }
        verify_profile(FALSE);
        return 0;
    case WM_BROWSE_DONE:
        InterlockedExchange(&g_browse_in_progress, 0);
        EnableWindow(g_browse, TRUE);
        if (InterlockedCompareExchange(&g_apply_in_progress, 0, 0) == 0)
            EnableWindow(g_apply, TRUE);
        SetWindowTextW(g_browse, L"Browse");
        if (wp) accept_profile_path(g_browse_path);
        return 0;
    case WM_DISPLAYCHANGE: case WM_DEVICECHANGE:
        if (InterlockedCompareExchange(&g_apply_in_progress, 0, 0) != 0) {
            finish_companion_apply_if_active();
        } else if (
            InterlockedCompareExchange(&g_browse_in_progress, 0, 0) == 0) {
            g_reapply_attempted_for_mismatch = FALSE;
            enumerate_displays();
            refresh_display_profiles();
            verify_profile(TRUE);
        }
        return 0;
    case WM_SETTINGCHANGE:
        /* Windows broadcasts ImmersiveColorSet when the light/dark preference
         * or the accent changes; rebuild the palette-derived GDI objects so the
         * window follows the system theme while running. */
        if (lp && !lstrcmpiW((const WCHAR *)lp, L"ImmersiveColorSet")) {
            load_system_palette();
            apply_titlebar_theme(hwnd);
            if (g_brush_background) DeleteObject(g_brush_background);
            if (g_brush_card) DeleteObject(g_brush_card);
            g_brush_background = CreateSolidBrush(g_palette.background);
            g_brush_card = CreateSolidBrush(g_palette.card);
            if (g_icon_ok) DestroyIcon(g_icon_ok);
            if (g_icon_bad) DestroyIcon(g_icon_bad);
            if (g_brush_input) { DeleteObject(g_brush_input); g_brush_input = NULL; }
            g_icon_ok = make_status_icon(g_palette.ok);
            g_icon_bad = make_status_icon(g_palette.bad);
            g_tray.hIcon = g_status_ok ? g_icon_ok : g_icon_bad;
            Shell_NotifyIconW(NIM_MODIFY, &g_tray);
            /* The scrollbar theme class differs between light and dark. */
            apply_control_theme(g_display);
            apply_control_theme(g_profile);
            apply_control_theme(g_display_profiles);
            InvalidateRect(hwnd, NULL, TRUE);
        }
        if (InterlockedCompareExchange(&g_apply_in_progress, 0, 0) != 0) {
            finish_companion_apply_if_active();
        } else if (
            InterlockedCompareExchange(&g_browse_in_progress, 0, 0) == 0) {
            refresh_display_profiles();
            verify_profile(TRUE);
        }
        return 0;
    case WM_TRAYICON:
        if (LOWORD(lp) == WM_LBUTTONDBLCLK) show_window();
        else if (LOWORD(lp) == WM_RBUTTONUP || LOWORD(lp) == WM_CONTEXTMENU) show_tray_menu();
        return 0;
    case WM_CLOSE:
        if (!g_exiting) { ShowWindow(hwnd, SW_HIDE); return 0; }
        break;
    case WM_DESTROY:
        KillTimer(hwnd, TIMER_VERIFY);
        Shell_NotifyIconW(NIM_DELETE, &g_tray);
        DeleteObject(g_font_normal);
        DeleteObject(g_font_label);
        DeleteObject(g_font_title);
        DeleteObject(g_font_subtitle);
        DeleteObject(g_font_button);
        DeleteObject(g_brush_background);
        DeleteObject(g_brush_card);
        if (g_brush_input) DeleteObject(g_brush_input);
        if (g_isolation_owner) {
            CloseHandle(g_isolation_owner);
            g_isolation_owner = NULL;
        }
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static BOOL already_running(const WCHAR *command_line) {
    HANDLE mutex = CreateMutexW(NULL, FALSE, L"Local\\PGeneratorPlusProfileLoader");
    if (!mutex || GetLastError() != ERROR_ALREADY_EXISTS) return FALSE;
    {
        HWND other = FindWindowW(L"PGeneratorPlusProfileLoaderWindow", NULL);
        if (other) {
            if (command_line &&
                (wcsstr(command_line, L"--apply-from-companion") ||
                 wcsstr(command_line, L"--isolate-for-correction") ||
                 wcsstr(command_line, L"--restore-after-correction"))) {
                COPYDATASTRUCT copy;
                copy.dwData = 1;
                copy.cbData = (DWORD)((wcslen(command_line) + 1) * sizeof(WCHAR));
                copy.lpData = (PVOID)command_line;
                SendMessageW(other, WM_COPYDATA, 0, (LPARAM)&copy);
            } else {
                ShowWindow(other, SW_SHOW);
                SetForegroundWindow(other);
            }
        }
    }
    CloseHandle(mutex);
    return TRUE;
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR command_line, int show) {
    WNDCLASSEXW wc;
    MSG msg;
    INITCOMMONCONTROLSEX controls;
    BOOL tray_only = wcsstr(command_line, L"--tray") != NULL;
    BOOL companion_apply = wcsstr(command_line, L"--apply-from-companion") != NULL ||
                           wcsstr(command_line, L"--isolate-for-correction") != NULL ||
                           wcsstr(command_line, L"--restore-after-correction") != NULL;
    WCHAR *install_arg = wcsstr(command_line, L"--install-only ");
    (void)previous;
    if (install_arg) {
        WCHAR *path = install_arg + 15;
        size_t n = wcslen(path);
        while (*path == L' ' || *path == L'\"') path++;
        n = wcslen(path);
        if (n && path[n - 1] == L'\"') path[n - 1] = L'\0';
        return install_profile_file(path) ? 0 : (int)GetLastError();
    }
    if (already_running(command_line)) return 0;
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    g_dpi = GetDpiForSystem();
    if (!g_dpi) g_dpi = 96;
    ZeroMemory(&controls, sizeof(controls));
    controls.dwSize = sizeof(controls);
    controls.dwICC = ICC_STANDARD_CLASSES;
    InitCommonControlsEx(&controls);
    g_instance = instance;
    make_ini_path();
    load_settings();
    g_mscms = LoadLibraryW(L"Mscms.dll");
    if (g_mscms) {
        FARPROC proc = GetProcAddress(g_mscms, "ColorProfileAddDisplayAssociation");
        memcpy(&p_add_association, &proc, sizeof(p_add_association));
        proc = GetProcAddress(g_mscms, "ColorProfileGetDisplayDefault");
        memcpy(&p_get_default, &proc, sizeof(p_get_default));
        proc = GetProcAddress(g_mscms, "ColorProfileGetDisplayUserScope");
        memcpy(&p_get_scope, &proc, sizeof(p_get_scope));
        proc = GetProcAddress(g_mscms, "ColorProfileGetDisplayList");
        memcpy(&p_get_list, &proc, sizeof(p_get_list));
        proc = GetProcAddress(g_mscms, "ColorProfileSetDisplayDefaultAssociation");
        memcpy(&p_set_default, &proc, sizeof(p_set_default));
        proc = GetProcAddress(g_mscms, "ColorProfileRemoveDisplayAssociation");
        memcpy(&p_remove_association, &proc, sizeof(p_remove_association));
    }
    load_system_palette();
    g_icon_ok = make_status_icon(g_palette.ok);
    g_icon_bad = make_status_icon(g_palette.bad);
    ZeroMemory(&wc, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = window_proc;
    wc.hInstance = instance;
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hIcon = (HICON)LoadImageW(instance, MAKEINTRESOURCEW(IDI_PGEN_APP), IMAGE_ICON,
                                0, 0, LR_DEFAULTSIZE | LR_SHARED);
    wc.hIconSm = (HICON)LoadImageW(instance, MAKEINTRESOURCEW(IDI_PGEN_APP), IMAGE_ICON,
                                  16, 16, LR_SHARED);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszClassName = L"PGeneratorPlusProfileLoaderWindow";
    if (!RegisterClassExW(&wc)) return 1;
    g_window = CreateWindowExW(0, wc.lpszClassName, APP_NAME L" " APP_VERSION,
                                WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
                                CW_USEDEFAULT, CW_USEDEFAULT, px(728), px(714),
                                NULL, NULL, instance, NULL);
    if (!g_window) return 1;
    if (g_correction_isolated) {
        /* Complete stale-isolation recovery before accepting commands from a
           newly launched Companion. Running this synchronously closes the
           installer/startup race where the Companion could cache Windows'
           temporary system-scope fallback during the four-second Advanced
           Color reload. The first isolate command is rejected below so the
           Companion re-queries the restored per-user profile. */
        BOOL restored;
        g_profile_operation = PROFILE_OPERATION_RESTORE;
        g_reject_next_isolate_for_stale_restore = TRUE;
        set_pending_status(L"RESTORING PROFILE",
                           L"Restoring the selected display profile after an interrupted explicit correction session.");
        restored = set_explicit_correction_isolation(FALSE);
        if (restored) {
            refresh_display_profiles();
            verify_profile(FALSE);
        } else if (InterlockedCompareExchange(&g_apply_in_progress, 0, 0) == 0) {
            g_companion_result[0] = L'\0';
            start_profile_operation(PROFILE_OPERATION_RESTORE);
        }
    }
    if (companion_apply)
        apply_companion_command(command_line);
    {
        DWORD corner = 2; /* DWMWCP_ROUND on Windows 11. */
        DwmSetWindowAttribute(g_window, 33, &corner, sizeof(corner));
    }
    ZeroMemory(&g_tray, sizeof(g_tray));
    g_tray.cbSize = sizeof(g_tray);
    g_tray.hWnd = g_window;
    g_tray.uID = 1;
    g_tray.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    g_tray.uCallbackMessage = WM_TRAYICON;
    g_tray.hIcon = g_icon_bad;
    wcscpy_s(g_tray.szTip, 128, L"PGenerator+ Profile Loader");
    Shell_NotifyIconW(NIM_ADD, &g_tray);
    g_tray.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &g_tray);
    if (InterlockedCompareExchange(&g_apply_in_progress, 0, 0) == 0)
        verify_profile(FALSE);
    if ((!tray_only && !companion_apply) || (!g_profile_name[0] && !companion_apply))
        ShowWindow(g_window, show);
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    if (g_icon_ok) DestroyIcon(g_icon_ok);
    if (g_icon_bad) DestroyIcon(g_icon_bad);
    if (g_mscms) FreeLibrary(g_mscms);
    return (int)msg.wParam;
}
