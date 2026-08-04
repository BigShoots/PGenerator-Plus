#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <commdlg.h>
#include <shellapi.h>
#include <icm.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <wctype.h>

#define APP_NAME L"PGenerator+ Profile Loader"
#define APP_VERSION L"1.0.0"
#define WM_TRAYICON (WM_APP + 1)
#define TIMER_VERIFY 1
#define MAX_DISPLAYS 24
#define ID_DISPLAY 101
#define ID_PROFILE 102
#define ID_BROWSE 103
#define ID_APPLY 104
#define ID_STATUS 105
#define ID_AUTOREAPPLY 106
#define ID_STARTUP 107
#define ID_SETTINGS 108
#define ID_HIDE 109
#define ID_TRAY_SHOW 201
#define ID_TRAY_APPLY 202
#define ID_TRAY_AUTOREAPPLY 203
#define ID_TRAY_SETTINGS 204
#define ID_TRAY_EXIT 205

typedef HRESULT (WINAPI *PFN_ColorProfileAddDisplayAssociation)(
    WCS_PROFILE_MANAGEMENT_SCOPE, PCWSTR, LUID, UINT32, BOOL, BOOL);
typedef HRESULT (WINAPI *PFN_ColorProfileGetDisplayDefault)(
    WCS_PROFILE_MANAGEMENT_SCOPE, LUID, UINT32, COLORPROFILETYPE,
    COLORPROFILESUBTYPE, LPWSTR *);
typedef HRESULT (WINAPI *PFN_ColorProfileGetDisplayUserScope)(
    LUID, UINT32, WCS_PROFILE_MANAGEMENT_SCOPE *);

typedef struct {
    LUID adapter;
    UINT32 source_id;
    WCHAR source_name[CCHDEVICENAME];
    WCHAR friendly[128];
    WCHAR monitor_path[256];
} DISPLAY_ENTRY;

static HINSTANCE g_instance;
static HWND g_window, g_display, g_profile, g_status, g_apply;
static NOTIFYICONDATAW g_tray;
static HICON g_icon_ok, g_icon_bad;
static DISPLAY_ENTRY g_displays[MAX_DISPLAYS];
static UINT g_display_count;
static WCHAR g_ini[MAX_PATH];
static WCHAR g_profile_path[MAX_PATH];
static WCHAR g_profile_name[MAX_PATH];
static WCHAR g_saved_monitor_path[256];
static BOOL g_profile_has_mhc2;
static BOOL g_associate_advanced;
static BOOL g_auto_reapply = TRUE;
static BOOL g_exiting;
static HMODULE g_mscms;
static PFN_ColorProfileAddDisplayAssociation p_add_association;
static PFN_ColorProfileGetDisplayDefault p_get_default;
static PFN_ColorProfileGetDisplayUserScope p_get_scope;

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

static BOOL profile_name_is_hdr(const WCHAR *path) {
    WCHAR upper[MAX_PATH];
    size_t i;
    wcsncpy_s(upper, MAX_PATH, path, _TRUNCATE);
    for (i = 0; upper[i]; i++) upper[i] = towupper(upper[i]);
    return wcsstr(upper, L"HDR-MHC2") != NULL || wcsstr(upper, L"-HDR-") != NULL;
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
}

static void load_settings(void) {
    GetPrivateProfileStringW(L"ProfileLoader", L"ProfilePath", L"", g_profile_path,
                             MAX_PATH, g_ini);
    GetPrivateProfileStringW(L"ProfileLoader", L"ProfileName", L"", g_profile_name,
                             MAX_PATH, g_ini);
    GetPrivateProfileStringW(L"ProfileLoader", L"MonitorPath", L"", g_saved_monitor_path,
                             256, g_ini);
    g_auto_reapply = GetPrivateProfileIntW(L"ProfileLoader", L"AutoReapply", 1, g_ini) != 0;
    g_profile_has_mhc2 = GetPrivateProfileIntW(L"ProfileLoader", L"HasMHC2", 0, g_ini) != 0;
    g_associate_advanced = GetPrivateProfileIntW(L"ProfileLoader", L"AdvancedAssociation", 0, g_ini) != 0;
    if (GetFileAttributesW(g_profile_path) != INVALID_FILE_ATTRIBUTES)
        g_profile_has_mhc2 = profile_contains_mhc2(g_profile_path);
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
        wcsncpy_s(entry->source_name, CCHDEVICENAME, source.viewGdiDeviceName, _TRUNCATE);
        wcsncpy_s(entry->friendly, 128,
                  target.monitorFriendlyDeviceName[0] ? target.monitorFriendlyDeviceName : source.viewGdiDeviceName,
                  _TRUNCATE);
        wcsncpy_s(entry->monitor_path, 256, target.monitorDevicePath, _TRUNCATE);
        {
            WCHAR label[320];
            swprintf(label, 320, L"%ls  (%ls)", entry->friendly, entry->source_name);
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

static HRESULT get_active_default(DISPLAY_ENTRY *display, LPWSTR *name,
                                  WCS_PROFILE_MANAGEMENT_SCOPE *scope) {
    HRESULT hr;
    *name = NULL;
    *scope = WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER;
    if (!p_get_default) return E_NOTIMPL;
    if (p_get_scope) {
        hr = p_get_scope(display->adapter, display->source_id, scope);
        if (FAILED(hr)) *scope = WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER;
    }
    hr = p_get_default(*scope, display->adapter, display->source_id,
                       CPT_ICC, CPST_NONE, name);
    if (FAILED(hr) && *scope != WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER) {
        *scope = WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER;
        hr = p_get_default(*scope, display->adapter, display->source_id,
                           CPT_ICC, CPST_NONE, name);
    }
    return hr;
}

static BOOL profile_is_active(DISPLAY_ENTRY *display, WCHAR *actual, size_t actual_count) {
    LPWSTR current = NULL;
    WCS_PROFILE_MANAGEMENT_SCOPE scope;
    HRESULT hr;
    if (!display || !g_profile_name[0]) return FALSE;
    hr = get_active_default(display, &current, &scope);
    if (FAILED(hr) || !current) {
        swprintf(actual, actual_count, L"Default profile could not be queried (0x%08lX).", (DWORD)hr);
        if (current) LocalFree(current);
        return FALSE;
    }
    wcsncpy_s(actual, actual_count, current, _TRUNCATE);
    {
        BOOL match = _wcsicmp(current, g_profile_name) == 0;
        LocalFree(current);
        return match;
    }
}

static void set_status(BOOL ok, const WCHAR *text) {
    SetWindowTextW(g_status, text);
    update_tray(ok, ok ? L"PGenerator+ Profile Loader: profile active"
                       : L"PGenerator+ Profile Loader: attention required");
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

static BOOL apply_profile(BOOL interactive) {
    DISPLAY_ENTRY *display = selected_display();
    HRESULT hr;
    DWORD error;
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
    if (!InstallColorProfileW(NULL, g_profile_path)) {
        error = GetLastError();
        if (interactive && (error == ERROR_ACCESS_DENIED || error == ERROR_PRIVILEGE_NOT_HELD) &&
            install_elevated(g_profile_path)) {
            error = ERROR_SUCCESS;
        } else if (error != ERROR_FILE_EXISTS && error != ERROR_ALREADY_EXISTS) {
            if (interactive) message_error(g_window, L"Installing the color profile", error);
            return FALSE;
        }
    }
    {
        const WCHAR *base = wcsrchr(g_profile_path, L'\\');
        base = base ? base + 1 : g_profile_path;
        wcsncpy_s(g_profile_name, MAX_PATH, base, _TRUNCATE);
    }
    g_profile_has_mhc2 = profile_contains_mhc2(g_profile_path);
    g_associate_advanced = g_profile_has_mhc2 && profile_name_is_hdr(g_profile_path);
    /* Select the per-user association list, matching "Use my settings for
       this device" in the legacy control panel. This API is available to a
       least-privileged user. */
    WcsSetUsePerUserProfiles(display->source_name, CLASS_MONITOR, TRUE);
    hr = p_add_association(WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER,
                           g_profile_name, display->adapter, display->source_id,
                           TRUE, g_associate_advanced);
    if (FAILED(hr)) {
        if (interactive) message_error(g_window, L"Associating the profile with the display", (DWORD)hr);
        return FALSE;
    }
    wcsncpy_s(g_saved_monitor_path, 256, display->monitor_path, _TRUNCATE);
    save_settings();
    verify_profile(FALSE);
    return TRUE;
}

static void verify_profile(BOOL allow_reapply) {
    DISPLAY_ENTRY *display = selected_display();
    WCHAR actual[MAX_PATH + 128] = L"";
    WCHAR text[768];
    BOOL active;
    if (!display) {
        set_status(FALSE, L"No active display is available.");
        return;
    }
    if (!g_profile_name[0]) {
        set_status(FALSE, L"No profile has been selected. Choose a profile, then install and apply it.");
        return;
    }
    active = profile_is_active(display, actual, sizeof(actual) / sizeof(actual[0]));
    if (!active && allow_reapply && g_auto_reapply && g_profile_path[0]) {
        if (apply_profile(FALSE)) return;
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

static void choose_profile(void) {
    OPENFILENAMEW ofn;
    WCHAR path[MAX_PATH] = L"";
    ZeroMemory(&ofn, sizeof(ofn));
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = g_window;
    ofn.lpstrFilter = L"Color profiles (*.icc;*.icm)\0*.icc;*.icm\0All files (*.*)\0*.*\0";
    ofn.lpstrFile = path;
    ofn.nMaxFile = MAX_PATH;
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST;
    if (GetOpenFileNameW(&ofn)) {
        wcsncpy_s(g_profile_path, MAX_PATH, path, _TRUNCATE);
        SetWindowTextW(g_profile, g_profile_path);
        g_profile_has_mhc2 = profile_contains_mhc2(g_profile_path);
        g_associate_advanced = g_profile_has_mhc2 && profile_name_is_hdr(g_profile_path);
        g_profile_name[0] = L'\0';
        verify_profile(FALSE);
    }
}

static void layout_controls(HWND hwnd) {
    RECT rc;
    int w, field_w;
    GetClientRect(hwnd, &rc);
    w = rc.right - rc.left;
    field_w = w - 40;
    MoveWindow(GetDlgItem(hwnd, ID_DISPLAY), 20, 48, field_w, 300, TRUE);
    MoveWindow(GetDlgItem(hwnd, ID_PROFILE), 20, 113, field_w - 105, 25, TRUE);
    MoveWindow(GetDlgItem(hwnd, ID_BROWSE), field_w - 75, 111, 95, 29, TRUE);
    MoveWindow(g_status, 20, 168, field_w, 92, TRUE);
    MoveWindow(g_apply, w - 170, 278, 150, 32, TRUE);
    MoveWindow(GetDlgItem(hwnd, ID_SETTINGS), 20, 278, 185, 32, TRUE);
    MoveWindow(GetDlgItem(hwnd, ID_HIDE), w - 285, 278, 105, 32, TRUE);
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
    HINSTANCE result = ShellExecuteW(g_window, L"open", L"ms-settings:display-advancedcolor",
                                     NULL, NULL, SW_SHOWNORMAL);
    if ((INT_PTR)result <= 32)
        ShellExecuteW(g_window, L"open", L"colorcpl.exe", NULL, NULL, SW_SHOWNORMAL);
}

static LRESULT CALLBACK window_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE: {
        HFONT font = (HFONT)GetStockObject(DEFAULT_GUI_FONT);
        HWND ctl;
        ctl = CreateWindowW(L"STATIC", L"Display", WS_CHILD | WS_VISIBLE,
                            20, 25, 100, 20, hwnd, NULL, g_instance, NULL);
        SendMessageW(ctl, WM_SETFONT, (WPARAM)font, TRUE);
        g_display = CreateWindowW(WC_COMBOBOXW, L"", WS_CHILD | WS_VISIBLE |
                                  CBS_DROPDOWNLIST | WS_VSCROLL, 20, 48, 520, 300,
                                  hwnd, (HMENU)ID_DISPLAY, g_instance, NULL);
        SendMessageW(g_display, WM_SETFONT, (WPARAM)font, TRUE);
        ctl = CreateWindowW(L"STATIC", L"Profile", WS_CHILD | WS_VISIBLE,
                            20, 90, 100, 20, hwnd, NULL, g_instance, NULL);
        SendMessageW(ctl, WM_SETFONT, (WPARAM)font, TRUE);
        g_profile = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
                                    WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL | ES_READONLY,
                                    20, 113, 415, 25, hwnd, (HMENU)ID_PROFILE, g_instance, NULL);
        SendMessageW(g_profile, WM_SETFONT, (WPARAM)font, TRUE);
        ctl = CreateWindowW(L"BUTTON", L"Browse...", WS_CHILD | WS_VISIBLE,
                            445, 111, 95, 29, hwnd, (HMENU)ID_BROWSE, g_instance, NULL);
        SendMessageW(ctl, WM_SETFONT, (WPARAM)font, TRUE);
        ctl = CreateWindowW(L"BUTTON", L"Automatically reapply if Windows changes the default",
                            WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, 20, 145, 360, 20,
                            hwnd, (HMENU)ID_AUTOREAPPLY, g_instance, NULL);
        SendMessageW(ctl, WM_SETFONT, (WPARAM)font, TRUE);
        SendMessageW(ctl, BM_SETCHECK, g_auto_reapply ? BST_CHECKED : BST_UNCHECKED, 0);
        ctl = CreateWindowW(L"BUTTON", L"Start with Windows", WS_CHILD | WS_VISIBLE |
                            BS_AUTOCHECKBOX, 390, 145, 150, 20, hwnd,
                            (HMENU)ID_STARTUP, g_instance, NULL);
        SendMessageW(ctl, WM_SETFONT, (WPARAM)font, TRUE);
        SendMessageW(ctl, BM_SETCHECK, startup_enabled() ? BST_CHECKED : BST_UNCHECKED, 0);
        g_status = CreateWindowExW(WS_EX_CLIENTEDGE, L"STATIC", L"",
                                   WS_CHILD | WS_VISIBLE | SS_LEFT, 20, 168, 520, 92,
                                   hwnd, (HMENU)ID_STATUS, g_instance, NULL);
        SendMessageW(g_status, WM_SETFONT, (WPARAM)font, TRUE);
        ctl = CreateWindowW(L"BUTTON", L"Color Profile settings", WS_CHILD | WS_VISIBLE,
                            20, 278, 185, 32, hwnd, (HMENU)ID_SETTINGS, g_instance, NULL);
        SendMessageW(ctl, WM_SETFONT, (WPARAM)font, TRUE);
        ctl = CreateWindowW(L"BUTTON", L"Hide to tray", WS_CHILD | WS_VISIBLE,
                            275, 278, 105, 32, hwnd, (HMENU)ID_HIDE, g_instance, NULL);
        SendMessageW(ctl, WM_SETFONT, (WPARAM)font, TRUE);
        g_apply = CreateWindowW(L"BUTTON", L"Install and apply", WS_CHILD | WS_VISIBLE |
                                BS_DEFPUSHBUTTON, 390, 278, 150, 32, hwnd,
                                (HMENU)ID_APPLY, g_instance, NULL);
        SendMessageW(g_apply, WM_SETFONT, (WPARAM)font, TRUE);
        SetWindowTextW(g_profile, g_profile_path);
        enumerate_displays();
        SetTimer(hwnd, TIMER_VERIFY, 5000, NULL);
        verify_profile(FALSE);
        break;
    }
    case WM_SIZE:
        if (wp != SIZE_MINIMIZED) layout_controls(hwnd);
        else ShowWindow(hwnd, SW_HIDE);
        return 0;
    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case ID_BROWSE: choose_profile(); break;
        case ID_APPLY: apply_profile(TRUE); break;
        case ID_SETTINGS: case ID_TRAY_SETTINGS: open_color_settings(); break;
        case ID_HIDE: ShowWindow(hwnd, SW_HIDE); break;
        case ID_DISPLAY:
            if (HIWORD(wp) == CBN_SELCHANGE) {
                DISPLAY_ENTRY *d = selected_display();
                if (d) wcsncpy_s(g_saved_monitor_path, 256, d->monitor_path, _TRUNCATE);
                save_settings(); verify_profile(FALSE);
            }
            break;
        case ID_AUTOREAPPLY:
            g_auto_reapply = SendMessageW(GetDlgItem(hwnd, ID_AUTOREAPPLY), BM_GETCHECK, 0, 0) == BST_CHECKED;
            save_settings(); break;
        case ID_STARTUP:
            if (!set_startup(SendMessageW(GetDlgItem(hwnd, ID_STARTUP), BM_GETCHECK, 0, 0) == BST_CHECKED))
                message_error(hwnd, L"Updating Windows startup", GetLastError());
            break;
        case ID_TRAY_SHOW: show_window(); break;
        case ID_TRAY_APPLY: apply_profile(TRUE); break;
        case ID_TRAY_AUTOREAPPLY:
            g_auto_reapply = !g_auto_reapply;
            SendMessageW(GetDlgItem(hwnd, ID_AUTOREAPPLY), BM_SETCHECK,
                         g_auto_reapply ? BST_CHECKED : BST_UNCHECKED, 0);
            save_settings(); break;
        case ID_TRAY_EXIT: g_exiting = TRUE; DestroyWindow(hwnd); break;
        }
        return 0;
    case WM_TIMER:
        if (wp == TIMER_VERIFY) verify_profile(TRUE);
        return 0;
    case WM_DISPLAYCHANGE: case WM_DEVICECHANGE:
        enumerate_displays(); verify_profile(TRUE); return 0;
    case WM_SETTINGCHANGE:
        verify_profile(TRUE); return 0;
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
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static BOOL already_running(void) {
    HANDLE mutex = CreateMutexW(NULL, FALSE, L"Local\\PGeneratorPlusProfileLoader");
    if (!mutex || GetLastError() != ERROR_ALREADY_EXISTS) return FALSE;
    {
        HWND other = FindWindowW(L"PGeneratorPlusProfileLoaderWindow", NULL);
        if (other) { ShowWindow(other, SW_SHOW); SetForegroundWindow(other); }
    }
    CloseHandle(mutex);
    return TRUE;
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR command_line, int show) {
    WNDCLASSEXW wc;
    MSG msg;
    BOOL tray_only = wcsstr(command_line, L"--tray") != NULL;
    WCHAR *install_arg = wcsstr(command_line, L"--install-only ");
    (void)previous;
    if (install_arg) {
        WCHAR *path = install_arg + 15;
        size_t n = wcslen(path);
        while (*path == L' ' || *path == L'\"') path++;
        n = wcslen(path);
        if (n && path[n - 1] == L'\"') path[n - 1] = L'\0';
        return InstallColorProfileW(NULL, path) ? 0 : (int)GetLastError();
    }
    if (already_running()) return 0;
    g_instance = instance;
    make_ini_path();
    load_settings();
    g_mscms = LoadLibraryW(L"Mscms.dll");
    if (g_mscms) {
        p_add_association = (PFN_ColorProfileAddDisplayAssociation)GetProcAddress(g_mscms, "ColorProfileAddDisplayAssociation");
        p_get_default = (PFN_ColorProfileGetDisplayDefault)GetProcAddress(g_mscms, "ColorProfileGetDisplayDefault");
        p_get_scope = (PFN_ColorProfileGetDisplayUserScope)GetProcAddress(g_mscms, "ColorProfileGetDisplayUserScope");
    }
    g_icon_ok = make_status_icon(RGB(35, 166, 78));
    g_icon_bad = make_status_icon(RGB(210, 48, 48));
    ZeroMemory(&wc, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = window_proc;
    wc.hInstance = instance;
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hIcon = g_icon_ok;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszClassName = L"PGeneratorPlusProfileLoaderWindow";
    if (!RegisterClassExW(&wc)) return 1;
    g_window = CreateWindowExW(0, wc.lpszClassName, APP_NAME L" " APP_VERSION,
                                WS_OVERLAPPEDWINDOW & ~WS_MAXIMIZEBOX,
                                CW_USEDEFAULT, CW_USEDEFAULT, 590, 370,
                                NULL, NULL, instance, NULL);
    if (!g_window) return 1;
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
    verify_profile(FALSE);
    if (!tray_only || !g_profile_name[0]) ShowWindow(g_window, show);
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    if (g_icon_ok) DestroyIcon(g_icon_ok);
    if (g_icon_bad) DestroyIcon(g_icon_bad);
    if (g_mscms) FreeLibrary(g_mscms);
    return (int)msg.wParam;
}
