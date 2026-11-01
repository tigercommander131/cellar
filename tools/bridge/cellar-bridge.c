/* cellar-bridge: asks the Steam client already running in the bottle about friends and their games.
 *
 *   cellar-bridge friends <output.json>             who is on, what they play, how to join them
 *   cellar-bridge invite <steamid> <connect> <output.json>   invite a friend to the game named by the
 *                                                   SteamAppId environment variable
 *
 * Talks to steamclient64.dll (from the Steam folder) through its public interfaces, so nothing from
 * the Steamworks SDK ships with Cellar and Steam doesn't show the helper as a running game.
 * Method numbers are vtable slots from SteamClient021 / SteamFriends017 / SteamUser021.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -o cellar-bridge.exe cellar-bridge.c */
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void *(*CreateInterfaceFn)(const char *name, int *ret);
typedef struct { int user; int callback; uint8_t *param; int size; } CallbackMsg;
typedef int (*BGetCallbackFn)(int pipe, CallbackMsg *msg);
typedef void (*FreeLastCallbackFn)(int pipe);

#pragma pack(push, 8)
typedef struct {
    uint64_t game_id;   /* low 24 bits: app ID */
    uint32_t ip;
    uint16_t game_port;
    uint16_t query_port;
    uint64_t lobby;
} FriendGameInfo;
#pragma pack(pop)

#define SLOT(obj, n) ((*(void ***)(obj))[n])

/* ISteamClient */
typedef int (*CreateSteamPipeFn)(void *self);
typedef int (*ConnectToGlobalUserFn)(void *self, int pipe);
typedef void *(*GetInterfaceFn)(void *self, int user, int pipe, const char *version);
/* ISteamUser. CSteamID comes back through a hidden pointer on this ABI. */
typedef uint64_t *(*GetSteamIDFn)(void *self, uint64_t *ret);
/* ISteamFriends */
typedef int (*GetFriendCountFn)(void *self, int flags);
typedef uint64_t *(*GetFriendByIndexFn)(void *self, uint64_t *ret, int index, int flags);
typedef int (*GetFriendPersonaStateFn)(void *self, uint64_t id);
typedef const char *(*GetFriendPersonaNameFn)(void *self, uint64_t id);
typedef uint8_t (*GetFriendGamePlayedFn)(void *self, uint64_t id, FriendGameInfo *info);
typedef const char *(*GetFriendRichPresenceFn)(void *self, uint64_t id, const char *key);
typedef void (*RequestFriendRichPresenceFn)(void *self, uint64_t id);
typedef uint8_t (*InviteUserToGameFn)(void *self, uint64_t id, const char *connect);

enum { K_FRIEND_FLAG_IMMEDIATE = 0x04, MAX_FRIENDS = 2000 };

static void json_string(FILE *f, const char *s)
{
    fputc('"', f);
    for (; s && *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') fprintf(f, "\\%c", c);
        else if (c < 0x20) fprintf(f, "\\u%04x", c);
        else fputc(c, f);
    }
    fputc('"', f);
}

static int fail(FILE *f, const char *why)
{
    fprintf(f, "{\"ok\":false,\"error\":");
    json_string(f, why);
    fprintf(f, "}\n");
    if (f != stdout) fclose(f);
    return 1;
}

int main(int argc, char **argv)
{
    FILE *out = stdout;
    int inviting = argc == 5 && !strcmp(argv[1], "invite");
    if (!inviting && !(argc >= 2 && !strcmp(argv[1], "friends"))) {
        fprintf(stderr, "usage: cellar-bridge friends [output.json] | invite <steamid> <connect> <output.json>\n");
        return 2;
    }
    const char *out_path = inviting ? argv[4] : (argc > 2 ? argv[2] : NULL);
    if (out_path && !(out = fopen(out_path, "wb"))) return 3;

    char dir[MAX_PATH], dll[MAX_PATH];
    DWORD type, size = sizeof(dir);
    HKEY key;
    if (RegOpenKeyExA(HKEY_CURRENT_USER, "Software\\Valve\\Steam\\ActiveProcess", 0, KEY_READ, &key)) return fail(out, "Steam isn't running");
    size = sizeof(dll);
    if (RegQueryValueExA(key, "SteamClientDll64", NULL, &type, (BYTE *)dll, &size)) { RegCloseKey(key); return fail(out, "Steam isn't running"); }
    RegCloseKey(key);
    strcpy(dir, dll);
    char *slash = strrchr(dir, '\\');
    if (!slash) slash = strrchr(dir, '/');
    if (slash) { *slash = 0; SetDllDirectoryA(dir); }

    HMODULE client_dll = LoadLibraryA(dll);
    if (!client_dll) return fail(out, "Couldn't load steamclient64.dll");
    CreateInterfaceFn create = (CreateInterfaceFn)GetProcAddress(client_dll, "CreateInterface");
    BGetCallbackFn get_callback = (BGetCallbackFn)GetProcAddress(client_dll, "Steam_BGetCallback");
    FreeLastCallbackFn free_callback = (FreeLastCallbackFn)GetProcAddress(client_dll, "Steam_FreeLastCallback");
    if (!create) return fail(out, "steamclient64.dll has no CreateInterface");

    void *client = create("SteamClient021", NULL);
    if (!client) return fail(out, "No SteamClient021 interface");
    int pipe = ((CreateSteamPipeFn)SLOT(client, 0))(client);
    if (!pipe) return fail(out, "Couldn't open a pipe to Steam");
    int user = ((ConnectToGlobalUserFn)SLOT(client, 2))(client, pipe);
    if (!user) return fail(out, "Steam has no signed-in user");
    void *steam_user = ((GetInterfaceFn)SLOT(client, 5))(client, user, pipe, "SteamUser021");
    void *friends = ((GetInterfaceFn)SLOT(client, 8))(client, user, pipe, "SteamFriends017");
    if (!steam_user || !friends) return fail(out, "Steam refused the friends interface");

    uint64_t me = 0;
    ((GetSteamIDFn)SLOT(steam_user, 2))(steam_user, &me);

    GetFriendByIndexFn by_index = (GetFriendByIndexFn)SLOT(friends, 4);
    GetFriendPersonaStateFn state_of = (GetFriendPersonaStateFn)SLOT(friends, 6);
    GetFriendPersonaNameFn name_of = (GetFriendPersonaNameFn)SLOT(friends, 7);
    GetFriendGamePlayedFn game_of = (GetFriendGamePlayedFn)SLOT(friends, 8);
    GetFriendRichPresenceFn presence_of = (GetFriendRichPresenceFn)SLOT(friends, 45);
    RequestFriendRichPresenceFn request_presence = (RequestFriendRichPresenceFn)SLOT(friends, 48);

    if (inviting) {
        uint64_t target = _strtoui64(argv[2], NULL, 10);
        uint8_t sent = ((InviteUserToGameFn)SLOT(friends, 49))(friends, target, argv[3]);
        fprintf(out, "{\"ok\":%s}\n", sent ? "true" : "false");
        if (out != stdout) fclose(out);
        return sent ? 0 : 1;
    }

    int count = ((GetFriendCountFn)SLOT(friends, 3))(friends, K_FRIEND_FLAG_IMMEDIATE);
    if (count > MAX_FRIENDS) count = MAX_FRIENDS;

    /* Friends in a game: ask for their join info, then let Steam deliver it. */
    for (int i = 0; i < count; i++) {
        uint64_t id = 0;
        FriendGameInfo info;
        by_index(friends, &id, i, K_FRIEND_FLAG_IMMEDIATE);
        memset(&info, 0, sizeof(info));
        if (game_of(friends, id, &info)) request_presence(friends, id);
    }
    if (get_callback && free_callback) {
        DWORD end = GetTickCount() + 1500;
        CallbackMsg msg;
        while (GetTickCount() < end) {
            while (get_callback(pipe, &msg)) free_callback(pipe);
            Sleep(50);
        }
    }

    /* The signed-in user: what they're playing and their own lobby, for inviting. */
    FriendGameInfo own;
    memset(&own, 0, sizeof(own));
    int own_playing = game_of(friends, me, &own);
    fprintf(out, "{\"ok\":true,\"me\":\"%llu\",\"app\":%llu,\"lobby\":\"%llu\",\"connect\":", (unsigned long long)me,
            own_playing ? (unsigned long long)(own.game_id & 0xFFFFFF) : 0ULL, own_playing ? (unsigned long long)own.lobby : 0ULL);
    json_string(out, own_playing ? presence_of(friends, me, "connect") : "");
    fprintf(out, ",\"friends\":[");
    for (int i = 0; i < count; i++) {
        uint64_t id = 0;
        FriendGameInfo info;
        by_index(friends, &id, i, K_FRIEND_FLAG_IMMEDIATE);
        memset(&info, 0, sizeof(info));
        int playing = game_of(friends, id, &info);
        fprintf(out, "%s{\"id\":\"%llu\",\"name\":", i ? "," : "", (unsigned long long)id);
        json_string(out, name_of(friends, id));
        fprintf(out, ",\"state\":%d", state_of(friends, id));
        if (playing) {
            fprintf(out, ",\"app\":%llu,\"lobby\":\"%llu\",\"ip\":%u,\"port\":%u,\"connect\":",
                    (unsigned long long)(info.game_id & 0xFFFFFF), (unsigned long long)info.lobby, info.ip, info.game_port);
            json_string(out, presence_of(friends, id, "connect"));
        }
        fputc('}', out);
    }
    fprintf(out, "]}\n");
    if (out != stdout) fclose(out);
    return 0;
}
