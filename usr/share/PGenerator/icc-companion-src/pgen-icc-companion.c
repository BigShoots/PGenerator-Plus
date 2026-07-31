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

#define APP_VERSION "1.0.0"
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
    CompanionConfig config;
    uint64_t sequence;
    bool hdr;
    bool hdr_active;
    bool fullscreen;
    bool quit;
    uint64_t next_poll_ms;
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

static bool create_renderer(bool hdr)
{
    const char *drivers[] = { "gpu", "direct3d12", "direct3d11", "vulkan", NULL };
    SDL_PropertiesID props;
    int index;
    if (app.texture) { SDL_DestroyTexture(app.texture); app.texture = NULL; }
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
    {
        SDL_PropertiesID renderer_props = SDL_GetRendererProperties(app.renderer);
        const char *name = SDL_GetStringProperty(renderer_props, SDL_PROP_RENDERER_NAME_STRING, "unknown");
        app.hdr_active = SDL_GetBooleanProperty(renderer_props, SDL_PROP_RENDERER_HDR_ENABLED_BOOLEAN, false);
        SDL_strlcpy(app.renderer_name, name, sizeof(app.renderer_name));
    }
    app.texture = SDL_CreateTexture(app.renderer, SDL_PIXELFORMAT_RGBA128_FLOAT, SDL_TEXTUREACCESS_STREAMING, 1, 1);
    if (!app.texture) return false;
    SDL_SetTextureScaleMode(app.texture, SDL_SCALEMODE_NEAREST);
    if (hdr) {
        SDL_PropertiesID texture_props = SDL_GetTextureProperties(app.texture);
        SDL_SetFloatProperty(texture_props, SDL_PROP_TEXTURE_SDR_WHITE_POINT_FLOAT, 1.0f);
        SDL_SetFloatProperty(texture_props, SDL_PROP_TEXTURE_HDR_HEADROOM_FLOAT, 125.0f);
    }
    app.hdr = hdr;
    SDL_SetRenderDrawColorFloat(app.renderer, 0, 0, 0, 1);
    SDL_RenderClear(app.renderer);
    SDL_RenderPresent(app.renderer);
    return !hdr || app.hdr_active;
}

static bool render_patch(const char *mode, double r, double g, double b)
{
    float pixel[4];
    bool hdr = !strcmp(mode, "hdr10");
    if (!app.renderer || hdr != app.hdr) {
        if (!create_renderer(hdr)) return false;
    }
    patch_to_linear(mode, r, g, b, pixel);
    if (!SDL_UpdateTexture(app.texture, NULL, pixel, (int)sizeof(pixel))) return false;
    for (int frame = 0; frame < 3; frame++) {
        SDL_SetRenderDrawColorFloat(app.renderer, 0, 0, 0, 1);
        SDL_RenderClear(app.renderer);
        SDL_RenderTexture(app.renderer, app.texture, NULL, NULL);
        SDL_RenderPresent(app.renderer);
    }
    return true;
}

static void acknowledge(uint64_t sequence, bool ok, const char *message)
{
    char path[256], body[1024], response[2048];
    SDL_snprintf(path, sizeof(path), "/api/icc/companion/ack");
    SDL_snprintf(body, sizeof(body),
                 "{\"token\":\"%s\",\"client\":\"%s\",\"sequence\":%llu,\"status\":\"%s\",\"renderer\":\"%s\",\"hdr_active\":%s,\"version\":\"%s\",\"message\":\"%s\"}",
                 app.config.token, app.config.client, (unsigned long long)sequence,
                 ok ? "ok" : "error", app.renderer_name, app.hdr_active ? "true" : "false", APP_VERSION, message ? message : "");
    http_request(&app.config, "POST", path, body, response, sizeof(response));
}

static void poll_server(void)
{
    char path[768], response[RESPONSE_CAPACITY], mode[32] = "sdr";
    double sequence_value, r, g, b, input_max, code_min, code_max;
    uint64_t sequence;
    int status;
    SDL_snprintf(path, sizeof(path),
                 "/api/icc/companion/poll?token=%s&client=%s&version=%s&renderer=%s&hdr=%d",
                 app.config.token, app.config.client, APP_VERSION,
                 app.renderer_name[0] ? app.renderer_name : "starting", app.hdr_active ? 1 : 0);
    status = http_request(&app.config, "GET", path, NULL, response, sizeof(response));
    if (status != 200) {
        SDL_snprintf(app.status, sizeof(app.status), "Waiting for %s", app.config.server);
        SDL_SetWindowTitle(app.window, app.status);
        app.next_poll_ms = SDL_GetTicks() + 1000;
        return;
    }
    SDL_snprintf(app.status, sizeof(app.status), "Connected to %s", app.config.server);
    SDL_SetWindowTitle(app.window, app.status);
    if (!strstr(response, "\"status\":\"patch\"")) {
        app.next_poll_ms = SDL_GetTicks() + 250;
        return;
    }
    if (!json_number(response, "sequence", &sequence_value) ||
        !json_number(response, "r", &r) || !json_number(response, "g", &g) ||
        !json_number(response, "b", &b) ||
        !json_number(response, "input_max", &input_max) ||
        !json_number(response, "code_min", &code_min) || !json_number(response, "code_max", &code_max)) {
        app.next_poll_ms = SDL_GetTicks() + 500;
        return;
    }
    json_string(response, "signal_mode", mode, sizeof(mode));
    sequence = (uint64_t)sequence_value;
    if (sequence == app.sequence) { app.next_poll_ms = SDL_GetTicks() + 250; return; }
    if (input_max <= 0 || code_max <= code_min) {
        acknowledge(sequence, false, "Invalid patch range");
        app.next_poll_ms = SDL_GetTicks() + 250;
        return;
    }
    r = fmax(0.0, fmin(1.0, (r - code_min) / (code_max - code_min)));
    g = fmax(0.0, fmin(1.0, (g - code_min) / (code_max - code_min)));
    b = fmax(0.0, fmin(1.0, (b - code_min) / (code_max - code_min)));
    if (!render_patch(mode, r, g, b)) {
        acknowledge(sequence, false, !strcmp(mode, "hdr10") ? "HDR output is not active or supported on this display" : "The renderer could not display the patch");
    } else {
        app.sequence = sequence;
        acknowledge(sequence, true, "");
    }
    app.next_poll_ms = SDL_GetTicks() + 50;
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
    app.window = SDL_CreateWindow("PGenerator ICC Companion", 1280, 720,
                                  SDL_WINDOW_HIGH_PIXEL_DENSITY | SDL_WINDOW_RESIZABLE);
    if (!app.window) return SDL_APP_FAILURE;
    app.fullscreen = false;
    if (!create_renderer(false)) return SDL_APP_FAILURE;
    *appstate = &app;
    return SDL_APP_CONTINUE;
}

SDL_AppResult SDL_AppEvent(void *appstate, SDL_Event *event)
{
    AppState *state = (AppState *)appstate;
    if (event->type == SDL_EVENT_QUIT) return SDL_APP_SUCCESS;
    if (event->type == SDL_EVENT_KEY_DOWN) {
        if (event->key.key == SDLK_ESCAPE) return SDL_APP_SUCCESS;
        if (event->key.key == SDLK_F11) {
            state->fullscreen = !state->fullscreen;
            SDL_SetWindowFullscreen(state->window, state->fullscreen);
        }
    }
    return SDL_APP_CONTINUE;
}

SDL_AppResult SDL_AppIterate(void *appstate)
{
    AppState *state = (AppState *)appstate;
    if (SDL_GetTicks() >= state->next_poll_ms) poll_server();
    SDL_Delay(5);
    return state->quit ? SDL_APP_SUCCESS : SDL_APP_CONTINUE;
}

void SDL_AppQuit(void *appstate, SDL_AppResult result)
{
    AppState *state = (AppState *)appstate;
    (void)result;
    if (state) {
        if (state->texture) SDL_DestroyTexture(state->texture);
        if (state->renderer) SDL_DestroyRenderer(state->renderer);
        if (state->window) SDL_DestroyWindow(state->window);
    }
    SDL_Quit();
#ifdef _WIN32
    WSACleanup();
#endif
}
