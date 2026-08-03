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
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#define close_socket closesocket
typedef SOCKET socket_handle_t;
#define INVALID_SOCKET_HANDLE INVALID_SOCKET
#else
#include <arpa/inet.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#define close_socket close
typedef int socket_handle_t;
#define INVALID_SOCKET_HANDLE (-1)
#endif

#define APP_VERSION "1.1.1"
#define RESPONSE_CAPACITY 32768

typedef struct {
    char server[256];
    char host[192];
    char token[96];
    char client[96];
    int port;
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

static int http_request(const CompanionConfig *config, const char *method, const char *path,
                        const char *body, char *response, size_t response_size)
{
    struct addrinfo hints, *addresses = NULL, *address;
    char port[16];
    char request[4096];
    char raw[RESPONSE_CAPACITY];
    size_t used = 0;
    socket_handle_t sock = INVALID_SOCKET_HANDLE;
    int status = 0;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    SDL_snprintf(port, sizeof(port), "%d", config->port);
    if (getaddrinfo(config->host, port, &hints, &addresses) != 0) return 0;
    for (address = addresses; address; address = address->ai_next) {
        sock = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (sock == INVALID_SOCKET_HANDLE) continue;
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
        if (connect(sock, address->ai_addr, (int)address->ai_addrlen) == 0) break;
        close_socket(sock);
        sock = INVALID_SOCKET_HANDLE;
    }
    freeaddrinfo(addresses);
    if (sock == INVALID_SOCKET_HANDLE) return 0;
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

static bool create_renderer(bool hdr)
{
    const char *drivers[] = { "gpu", "direct3d12", "direct3d11", "vulkan", NULL };
    SDL_PropertiesID props;
    int index;
    if (app.texture) { SDL_DestroyTexture(app.texture); app.texture = NULL; }
    if (app.background_texture) { SDL_DestroyTexture(app.background_texture); app.background_texture = NULL; }
    if (app.renderer) { SDL_DestroyRenderer(app.renderer); app.renderer = NULL; }
    for (index = 0; ; index++) {
        props = SDL_CreateProperties();
        SDL_SetPointerProperty(props, SDL_PROP_RENDERER_CREATE_WINDOW_POINTER, app.window);
        SDL_SetNumberProperty(props, SDL_PROP_RENDERER_CREATE_PRESENT_VSYNC_NUMBER, 1);
        SDL_SetNumberProperty(props, SDL_PROP_RENDERER_CREATE_OUTPUT_COLORSPACE_NUMBER,
                              hdr ? SDL_COLORSPACE_SRGB_LINEAR : SDL_COLORSPACE_SRGB);
        if (hdr && drivers[index]) SDL_SetStringProperty(props, SDL_PROP_RENDERER_CREATE_NAME_STRING, drivers[index]);
        app.renderer = SDL_CreateRendererWithProperties(props);
        SDL_DestroyProperties(props);
        if (app.renderer || !hdr || !drivers[index]) break;
    }
    if (!app.renderer) return false;
    app.hdr = hdr;
    {
        SDL_PropertiesID renderer_props = SDL_GetRendererProperties(app.renderer);
        const char *name = SDL_GetStringProperty(renderer_props, SDL_PROP_RENDERER_NAME_STRING, "unknown");
        SDL_strlcpy(app.renderer_name, name, sizeof(app.renderer_name));
    }
    if (!update_renderer_hdr_state()) return false;
    app.texture = SDL_CreateTexture(app.renderer, SDL_PIXELFORMAT_RGBA128_FLOAT, SDL_TEXTUREACCESS_STREAMING, 1, 1);
    if (!app.texture) return false;
    app.background_texture = SDL_CreateTexture(app.renderer, SDL_PIXELFORMAT_RGBA128_FLOAT, SDL_TEXTUREACCESS_STREAMING, 1, 1);
    if (!app.background_texture) return false;
    SDL_SetTextureScaleMode(app.texture, SDL_SCALEMODE_NEAREST);
    SDL_SetTextureScaleMode(app.background_texture, SDL_SCALEMODE_NEAREST);
    SDL_SetRenderDrawColorFloat(app.renderer, 0, 0, 0, 1);
    SDL_RenderClear(app.renderer);
    SDL_RenderPresent(app.renderer);
    return !hdr || app.hdr_active;
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
        /* Fullscreen changes are asynchronous on Windows. Synchronize before
         * repainting so the renderer uses the new client area, and verify the
         * window manager actually accepted the requested state. */
        if (fullscreen) {
            if (!SDL_RestoreWindow(app.window)) return false;
            if (!SDL_SyncWindow(app.window)) return false;
            if (!SDL_SetWindowFullscreenMode(app.window, NULL)) return false;
        }
        if (!SDL_SetWindowFullscreen(app.window, fullscreen)) return false;
        if (!SDL_SyncWindow(app.window)) return false;
        if (!fullscreen) {
            if (!SDL_RestoreWindow(app.window)) return false;
            if (!SDL_SyncWindow(app.window)) return false;
        }
        flags = SDL_GetWindowFlags(app.window);
        app.fullscreen = (flags & SDL_WINDOW_FULLSCREEN) != 0;
        if (app.fullscreen != fullscreen) {
            SDL_SetError("The window manager did not apply the requested display mode");
            return false;
        }
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
    char path[768], response[RESPONSE_CAPACITY], mode[32] = "sdr";
    char window_mode[32] = "window";
    char reported_renderer[64] = "starting";
    double sequence_value, r, g, b, input_max, code_min, code_max, poll_ms;
    double settings_revision_value, display_size_value, patch_size_value;
    uint64_t sequence;
    bool is_alignment, reported_hdr_active = false;
    int status;
    SDL_LockMutex(app.network_mutex);
    if (app.ack_renderer[0]) SDL_strlcpy(reported_renderer, app.ack_renderer, sizeof(reported_renderer));
    reported_hdr_active = app.ack_hdr_active;
    SDL_UnlockMutex(app.network_mutex);
    SDL_snprintf(path, sizeof(path),
                 "/api/icc/companion/poll?token=%s&client=%s&version=%s&renderer=%s&hdr=%d",
                 app.config.token, app.config.client, APP_VERSION,
                 reported_renderer, reported_hdr_active ? 1 : 0);
    status = http_request(&app.config, "GET", path, NULL, response, sizeof(response));
    if (status != 200) {
        char title[256];
        SDL_snprintf(title, sizeof(title), "Waiting for %s", app.config.server);
        queue_status(title);
        app.next_poll_ms = SDL_GetTicks() + 1000;
        return;
    }
    {
        char title[256];
        SDL_snprintf(title, sizeof(title), "Connected to %s", app.config.server);
        queue_status(title);
    }
    if (json_number(response, "settings_revision", &settings_revision_value) &&
        json_number(response, "display_size", &display_size_value) &&
        json_string(response, "window_mode", window_mode, sizeof(window_mode))) {
        uint64_t settings_revision = (uint64_t)settings_revision_value;
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
    app.window = SDL_CreateWindow("PGenerator ICC Companion", 1280, 720,
                                  SDL_WINDOW_HIGH_PIXEL_DENSITY | SDL_WINDOW_RESIZABLE);
    if (!app.window) return SDL_APP_FAILURE;
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
        if (state->window) SDL_DestroyWindow(state->window);
        if (state->network_mutex) SDL_DestroyMutex(state->network_mutex);
    }
    SDL_Quit();
#ifdef _WIN32
    WSACleanup();
#endif
}
