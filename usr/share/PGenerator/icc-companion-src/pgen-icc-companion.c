/* PGenerator ICC Companion
 *
 * Displays measurement patches through the target computer's native output
 * pipeline. SDL3 supplies scRGB on Windows and extended-linear HDR surfaces
 * through supported Vulkan/Wayland compositors.
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
#include <dxgi1_6.h>
#include <icm.h>
#define close_socket closesocket
typedef SOCKET socket_handle_t;
#define INVALID_SOCKET_HANDLE INVALID_SOCKET
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
#endif

#define APP_VERSION "1.3.1"
#define RESPONSE_CAPACITY 32768
#define PGEN_UNUSED __attribute__((unused))

typedef struct {
    char server[256];
    char host[192];
    char token[96];
    char client[96];
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
    char status[256];
} AppState;

static AppState app;

static bool render_alignment(void);
static double pq_to_nits(double value);

#ifdef _WIN32
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
    dialog.pszWindowTitle = L"PGenerator+ ICC Companion";
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

static bool windows_active_profile(SDL_Window *window, char *output, size_t output_size,
                                   wchar_t *profile_path, size_t profile_path_count)
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
        WCS_PROFILE_MANAGEMENT_SCOPE scope = WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER;
        HRESULT hr;
        if (!(paths[index].flags & DISPLAYCONFIG_PATH_ACTIVE)) continue;
        ZeroMemory(&source, sizeof(source));
        source.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
        source.header.size = sizeof(source);
        source.header.adapterId = paths[index].sourceInfo.adapterId;
        source.header.id = paths[index].sourceInfo.id;
        if (DisplayConfigGetDeviceInfo(&source.header) != ERROR_SUCCESS ||
            _wcsicmp(source.viewGdiDeviceName, monitor_info.szDevice) != 0) continue;
        if (get_scope && FAILED(get_scope(paths[index].sourceInfo.adapterId,
                                          paths[index].sourceInfo.id, &scope)))
            scope = WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER;
        hr = get_default(scope, paths[index].sourceInfo.adapterId,
                         paths[index].sourceInfo.id, CPT_ICC, CPST_NONE, &profile);
        if (FAILED(hr) && scope != WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER) {
            scope = WCS_PROFILE_MANAGEMENT_SCOPE_CURRENT_USER;
            hr = get_default(scope, paths[index].sourceInfo.adapterId,
                             paths[index].sourceInfo.id, CPT_ICC, CPST_NONE, &profile);
        }
        if (SUCCEEDED(hr) && profile) {
            const wchar_t *name = windows_profile_basename(profile);
            int converted = WideCharToMultiByte(CP_UTF8, 0, name, -1, output,
                                                (int)output_size, NULL, NULL);
            if (converted > 1) {
                if (wcschr(profile, L'\\') || wcschr(profile, L'/')) {
                    wcsncpy(profile_path, profile, profile_path_count - 1);
                    profile_path[profile_path_count - 1] = L'\0';
                } else {
                    DWORD color_dir_size = (DWORD)profile_path_count;
                    if (GetColorDirectoryW(NULL, profile_path, &color_dir_size) &&
                        wcslen(profile_path) + 1 + wcslen(profile) + 1 <= profile_path_count) {
                        wcscat(profile_path, L"\\");
                        wcscat(profile_path, profile);
                    } else {
                        profile_path[0] = L'\0';
                    }
                }
                found = profile_path[0] != L'\0' && GetFileAttributesW(profile_path) != INVALID_FILE_ATTRIBUTES;
            }
        }
    }
done:
    if (profile) LocalFree(profile);
    if (mscms) FreeLibrary(mscms);
    SDL_free(paths); SDL_free(modes);
    if (!found) { output[0] = '\0'; profile_path[0] = L'\0'; }
    return found;
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
        SDL_free(displays);
        return true;
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
#ifdef _WIN32
display_selected:
#endif
    if (selected < 1 || selected > count) selected = 1;
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

static void companion_source_xyz(const double rgb[3], const char *signal_mode, double white_nits, double xyz[3])
{
    static const double d65_d50[3][3]={{1.0479298,0.0229468,-0.0501922},{0.0296278,0.9904345,-0.0170738},{-0.0092430,0.0150552,0.7518743}};
    static const double srgb_xyz[3][3]={{0.4123908,0.3575843,0.1804808},{0.2126390,0.7151687,0.0721923},{0.0193308,0.1191948,0.9505322}};
    static const double bt2020_xyz[3][3]={{0.6369580,0.1446169,0.1688810},{0.2627002,0.6779981,0.0593017},{0.0,0.0280727,1.0609851}};
    double linear[3], intermediate[3];
    for (int channel=0; channel<3; channel++) {
        if (!strcmp(signal_mode,"hdr10")) linear[channel]=fmin(1.0,pq_to_nits(rgb[channel])/fmax(white_nits,1e-6));
        else linear[channel]=rgb[channel]<=0.04045?rgb[channel]/12.92:pow((rgb[channel]+0.055)/1.055,2.4);
    }
    const double (*source)[3]=!strcmp(signal_mode,"hdr10")?bt2020_xyz:srgb_xyz;
    for(int row=0;row<3;row++) intermediate[row]=source[row][0]*linear[0]+source[row][1]*linear[1]+source[row][2]*linear[2];
    for(int row=0;row<3;row++) xyz[row]=d65_d50[row][0]*intermediate[0]+d65_d50[row][1]*intermediate[1]+d65_d50[row][2]*intermediate[2];
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
#endif

static bool load_correction_lut(uint64_t revision)
{
#ifdef _WIN32
    FILE *file;
    long length;
#endif
    if (!strcmp(app.correction_mode, "system")) {
        SDL_free(app.correction_lut);
        app.correction_lut = NULL;
        app.correction_lut_grid = 0;
        app.correction_lut_revision = revision;
        app.correction_error[0] = '\0';
#ifdef _WIN32
        SDL_free(app.correction_profile_data); app.correction_profile_data=NULL; app.correction_profile_size=0;
#endif
        return true;
    }
    /* Never retain a transform from a previously selected profile if the new
     * LUT cannot be downloaded or decoded. A stale correction would produce a
     * valid patch acknowledgement while applying the wrong profile. */
    SDL_free(app.correction_lut);
    app.correction_lut = NULL;
    app.correction_lut_grid = 0;
    if (!app.correction_profile[0]) {
        SDL_strlcpy(app.correction_error, "The operating system did not report an active ICC profile for the selected display", sizeof(app.correction_error));
        return false;
    }
#ifdef _WIN32
    file=_wfopen(app.correction_profile_path,L"rb");
    if(!file||fseek(file,0,SEEK_END)!=0||(length=ftell(file))<132||length>16*1024*1024||fseek(file,0,SEEK_SET)!=0){if(file)fclose(file);SDL_strlcpy(app.correction_error,"Could not open the active Windows display profile",sizeof(app.correction_error));return false;}
    SDL_free(app.correction_profile_data); app.correction_profile_data=SDL_malloc((size_t)length); app.correction_profile_size=0;
    if(!app.correction_profile_data||fread(app.correction_profile_data,1,(size_t)length,file)!=(size_t)length){fclose(file);SDL_free(app.correction_profile_data);app.correction_profile_data=NULL;SDL_strlcpy(app.correction_error,"Could not read the active Windows display profile",sizeof(app.correction_error));return false;}
    fclose(file); app.correction_profile_size=(size_t)length;
    if(memcmp(app.correction_profile_data+12,"mntr",4)||memcmp(app.correction_profile_data+16,"RGB ",4)||memcmp(app.correction_profile_data+20,"XYZ ",4)){SDL_free(app.correction_profile_data);app.correction_profile_data=NULL;app.correction_profile_size=0;SDL_strlcpy(app.correction_error,"The active Windows profile is not a supported RGB display profile",sizeof(app.correction_error));return false;}
#else
    SDL_strlcpy(app.correction_error,"Active-profile cLUT and matrix enforcement currently require Windows",sizeof(app.correction_error));
    return false;
#endif
    app.correction_lut_revision = revision;
    app.correction_error[0] = '\0';
    return true;
}

static bool apply_correction_lut(double *red, double *green, double *blue)
{
#ifdef _WIN32
    double rgb[3]={*red,*green,*blue},xyz[3],output[3],white_nits=1.0;
#endif
    if (!strcmp(app.correction_mode, "system")) return true;
#ifdef _WIN32
    if(!app.correction_profile_data)return false;
    if(!strcmp(app.correction_signal_mode,"hdr10")){IccTag lumi=icc_tag(app.correction_profile_data,app.correction_profile_size,"lumi");if(!lumi.data||lumi.size<20||memcmp(lumi.data,"XYZ ",4)||(white_nits=read_s15(lumi.data+12))<=0.0)return false;}
    companion_source_xyz(rgb,app.correction_signal_mode,white_nits,xyz);
    if(!strcmp(app.correction_mode,"clut")){if(!apply_local_clut(xyz,output))return false;}
    else if(!apply_local_matrix(xyz,output))return false;
    *red = output[0]; *green = output[1]; *blue = output[2];
    return true;
#else
    (void)red; (void)green; (void)blue;
    return false;
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
static bool windows_window_hdr_enabled(SDL_Window *window)
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

    if (!window) return false;
    window_props = SDL_GetWindowProperties(window);
    hwnd = (HWND)SDL_GetPointerProperty(window_props, SDL_PROP_WINDOW_WIN32_HWND_POINTER, NULL);
    if (!hwnd) return false;
    monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    if (!monitor || FAILED(CreateDXGIFactory1(&pgen_iid_idxgi_factory1, (void **)&factory))) return false;
    for (UINT adapter_index = 0; !enabled; adapter_index++) {
        IDXGIAdapter1 *adapter = NULL;
        HRESULT adapter_result = IDXGIFactory1_EnumAdapters1(factory, adapter_index, &adapter);
        if (adapter_result == DXGI_ERROR_NOT_FOUND) break;
        if (FAILED(adapter_result) || !adapter) continue;
        for (UINT output_index = 0; !enabled; output_index++) {
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
                enabled = output_desc1.ColorSpace == DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020;
            }
            if (output6) IDXGIOutput6_Release(output6);
            IDXGIOutput_Release(output);
        }
        IDXGIAdapter1_Release(adapter);
    }
    IDXGIFactory1_Release(factory);
    return enabled;
}
#endif

static double pq_to_nits(double value)
{
    const double m1 = 2610.0 / 16384.0;
    const double m2 = 2523.0 / 32.0;
    const double c1 = 3424.0 / 4096.0;
    const double c2 = 2413.0 / 128.0;
    const double c3 = 2392.0 / 128.0;
    double p = pow(fmax(0.0, fmin(1.0, value)), 1.0 / m2);
    return 10000.0 * pow(fmax(p - c1, 0.0) / fmax(c2 - c3 * p, 1e-12), 1.0 / m1);
}

static void patch_to_linear(const char *mode, double r, double g, double b, float output[4])
{
    if (!strcmp(mode, "hdr10")) {
        double lr = pq_to_nits(r), lg = pq_to_nits(g), lb = pq_to_nits(b);
        /* Linear BT.2020 to linear BT.709/scRGB, then scRGB 1.0 = 80 nits. */
        output[0] = (float)((1.660491 * lr - 0.587641 * lg - 0.072850 * lb) / 80.0);
        output[1] = (float)((-0.124550 * lr + 1.132900 * lg - 0.008349 * lb) / 80.0);
        output[2] = (float)((-0.018151 * lr - 0.100579 * lg + 1.118730 * lb) / 80.0);
    } else {
        output[0] = srgb_to_linear((float)r);
        output[1] = srgb_to_linear((float)g);
        output[2] = srgb_to_linear((float)b);
    }
    output[3] = 1.0f;
}

static bool update_renderer_hdr_state(void)
{
    SDL_PropertiesID renderer_props;
    float sdr_white_scale = 1.0f;

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

    /* SDL scales linear HDR rendering by the operating system's SDR white
     * level. Our scRGB values are already absolute, with 1.0 equal to 80
     * cd/m2, so cancel that relative-content scale before presentation. */
    return SDL_SetRenderColorScale(app.renderer, app.hdr ? (1.0f / sdr_white_scale) : 1.0f);
}

static void destroy_renderer(void)
{
    if (app.texture) { SDL_DestroyTexture(app.texture); app.texture = NULL; }
    if (app.background_texture) { SDL_DestroyTexture(app.background_texture); app.background_texture = NULL; }
    if (app.renderer) { SDL_DestroyRenderer(app.renderer); app.renderer = NULL; }
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
    app.texture = SDL_CreateTexture(app.renderer, SDL_PIXELFORMAT_RGBA128_FLOAT, SDL_TEXTUREACCESS_STREAMING, 1, 1);
    if (!app.texture) {
        destroy_renderer();
        return false;
    }
    app.background_texture = SDL_CreateTexture(app.renderer, SDL_PIXELFORMAT_RGBA128_FLOAT, SDL_TEXTUREACCESS_STREAMING, 1, 1);
    if (!app.background_texture) {
        destroy_renderer();
        return false;
    }
    SDL_SetTextureScaleMode(app.texture, SDL_SCALEMODE_NEAREST);
    SDL_SetTextureScaleMode(app.background_texture, SDL_SCALEMODE_NEAREST);
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
    return true;
}

static bool create_renderer(bool hdr)
{
#ifdef _WIN32
    /* D3D11 has the broadest reliable scRGB support on Windows. A renderer
     * being constructible does not mean it activated HDR, so validate each
     * complete candidate before moving on to the next backend. */
    const char *hdr_drivers[] = { "direct3d11", "direct3d12", "gpu", "vulkan", NULL };
#else
    const char *hdr_drivers[] = { "vulkan", "gpu", NULL };
#endif
    size_t index;
    char last_error[256] = "No HDR renderer was available";

    if (!hdr) return try_create_renderer(false, NULL);
    for (index = 0; index < SDL_arraysize(hdr_drivers); index++) {
        if (try_create_renderer(true, hdr_drivers[index])) return true;
        if (SDL_GetError() && SDL_GetError()[0]) {
            SDL_strlcpy(last_error, SDL_GetError(), sizeof(last_error));
        }
    }

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
    SDL_FRect destination;
    int width, height, patch_size, window_percent;
    double background_signal = 0.0;
    bool hdr = !strcmp(mode, "hdr10");
    if (!app.renderer || hdr != app.hdr) {
        if (!create_renderer(hdr)) return false;
    }
    patch_to_linear(mode, r, g, b, pixel);
    patch_size = app.displayed_size > 0 ? app.displayed_size : 100;
    window_percent = patch_size;
    if (patch_size > 100 && patch_size < 199) {
        double foreground_luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        double target_apl = (patch_size - 100) / 100.0;
        window_percent = 10;
        background_signal = (target_apl - foreground_luma * 0.10) / 0.90;
        background_signal = fmax(0.0, fmin(1.0, background_signal));
    }
    patch_to_linear(mode, background_signal, background_signal, background_signal, background);
    if (!SDL_UpdateTexture(app.texture, NULL, pixel, (int)sizeof(pixel))) return false;
    if (!SDL_UpdateTexture(app.background_texture, NULL, background, (int)sizeof(background))) return false;
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

static bool apply_display_settings(bool fullscreen, int patch_size)
{
    SDL_WindowFlags flags;
    if (patch_size < 1 || patch_size > 198) patch_size = 100;
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
    app.displayed_size = patch_size;
    return render_current_frame();
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
    char path[1200], response[RESPONSE_CAPACITY], mode[32] = "sdr";
    char window_mode[32] = "window";
    char correction_mode[16] = "system", active_profile[192] = "", profile_hex[385] = "", correction_signal_mode[16] = "sdr";
    char reported_renderer[64] = "starting";
    double sequence_value, r, g, b, input_max, code_min, code_max, poll_ms;
    double settings_revision_value, display_size_value, patch_size_value;
    uint64_t sequence;
    bool is_alignment, reported_hdr_active = false;
    int status;
#ifdef _WIN32
    wchar_t active_profile_path[32768] = L"";
#endif
    SDL_LockMutex(app.network_mutex);
    if (app.ack_renderer[0]) SDL_strlcpy(reported_renderer, app.ack_renderer, sizeof(reported_renderer));
    reported_hdr_active = app.ack_hdr_active;
    SDL_UnlockMutex(app.network_mutex);
#ifdef _WIN32
    windows_active_profile(app.window, active_profile, sizeof(active_profile),
                           active_profile_path, SDL_arraysize(active_profile_path));
#endif
    profile_name_hex(active_profile, profile_hex, sizeof(profile_hex));
    SDL_snprintf(path, sizeof(path),
                 "/api/icc/companion/poll?token=%s&client=%s&version=%s&renderer=%s&hdr=%d&profile_hex=%s",
                 app.config.token, app.config.client, APP_VERSION,
                 reported_renderer, reported_hdr_active ? 1 : 0, profile_hex);
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
            SDL_snprintf(title, sizeof(title), "PGenerator+ ICC Companion | Active profile cLUT: %s%s",
                         app.correction_profile[0] ? app.correction_profile : "not detected",
                         app.correction_error[0] ? " (not ready)" : "");
        else if (!strcmp(app.correction_mode, "matrix"))
            SDL_snprintf(title, sizeof(title), "PGenerator+ ICC Companion | Active profile matrix/TRC: %s%s",
                         app.correction_profile[0] ? app.correction_profile : "not detected",
                         app.correction_error[0] ? " (not ready)" : "");
        else
            SDL_snprintf(title, sizeof(title), "PGenerator+ ICC Companion | No application profile correction");
        queue_status(title);
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
    if (input_max <= 0 || code_max <= code_min) {
        acknowledge(sequence, false, "Invalid patch range", "network", false);
        app.next_poll_ms = SDL_GetTicks() + 250;
        return;
    }
    r = fmax(0.0, fmin(1.0, (r - code_min) / (code_max - code_min)));
    g = fmax(0.0, fmin(1.0, (g - code_min) / (code_max - code_min)));
    b = fmax(0.0, fmin(1.0, (b - code_min) / (code_max - code_min)));
    if (strcmp(app.correction_mode, "system") && strcmp(mode, app.correction_signal_mode)) {
        acknowledge(sequence, false, "The selected ICC correction does not match the patch signal mode", "profile", false);
        app.next_poll_ms = SDL_GetTicks() + 250;
        return;
    }
    if (!apply_correction_lut(&r, &g, &b)) {
        acknowledge(sequence, false, app.correction_error[0] ? app.correction_error : "The selected ICC correction is not ready", "profile", false);
        app.next_poll_ms = SDL_GetTicks() + 250;
        return;
    }
    SDL_LockMutex(app.network_mutex);
    app.command_sequence = sequence;
    app.command_alignment = false;
    app.command_r = r;
    app.command_g = g;
    app.command_b = b;
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
        if (!alignment) app.displayed_size = command_size;
        ok = alignment ? render_alignment() : render_patch(mode, r, g, b);
        const char *message = ok ? "" : (alignment ? "The renderer could not display the alignment target" :
                              (!strcmp(mode, "hdr10") ? "HDR output is not active or supported on this display" : "The renderer could not display the patch"));
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
    SDL_strlcpy(app.correction_mode, "system", sizeof(app.correction_mode));
    SDL_strlcpy(app.correction_signal_mode, "sdr", sizeof(app.correction_signal_mode));
#ifdef _WIN32
    {
        WSADATA data;
        if (WSAStartup(MAKEWORD(2, 2), &data) != 0) return SDL_APP_FAILURE;
    }
#endif
    if (!load_config(&app.config)) {
        SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "PGenerator ICC Companion",
                                 "PGenICCCompanion.conf is missing or invalid. Download the companion again from your PGenerator.", NULL);
        return SDL_APP_FAILURE;
    }
    if (!SDL_Init(SDL_INIT_VIDEO)) return SDL_APP_FAILURE;
    app.network_mutex = SDL_CreateMutex();
    if (!app.network_mutex) return SDL_APP_FAILURE;
    app.window = SDL_CreateWindow("PGenerator+ ICC Companion", 1280, 720,
                                  SDL_WINDOW_HIGH_PIXEL_DENSITY | SDL_WINDOW_RESIZABLE);
    if (!app.window) return SDL_APP_FAILURE;
#ifdef _WIN32
    set_windows_window_icon();
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
    if (event->type == SDL_EVENT_WINDOW_HDR_STATE_CHANGED && state->renderer) {
        update_renderer_hdr_state();
        SDL_LockMutex(state->network_mutex);
        state->ack_hdr_active = state->hdr_active;
        SDL_UnlockMutex(state->network_mutex);
        render_current_frame();
    }
    if (event->type == SDL_EVENT_WINDOW_ENTER_FULLSCREEN) {
        state->fullscreen = true;
        render_current_frame();
    }
    if (event->type == SDL_EVENT_WINDOW_LEAVE_FULLSCREEN) {
        state->fullscreen = false;
        render_current_frame();
    }
    if (event->type == SDL_EVENT_KEY_DOWN) {
        if (event->key.key == SDLK_ESCAPE) return SDL_APP_SUCCESS;
        if (event->key.key == SDLK_F11) {
            SDL_WindowFlags flags = SDL_GetWindowFlags(state->window);
            bool fullscreen = (flags & SDL_WINDOW_FULLSCREEN) == 0;
            apply_display_settings(fullscreen, state->displayed_size);
        }
    }
    if (event->type == SDL_EVENT_WINDOW_EXPOSED ||
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
