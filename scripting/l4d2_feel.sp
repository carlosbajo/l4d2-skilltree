#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <skilltree>

#define SND_HEADSHOT    "ui/alert_clink.wav"
#define SND_KILL        "buttons/blip1.wav"

#define DODGE_WINDOW    0.25    // segundos entre los dos toques
#define DODGE_COOLDOWN  2.5
#define DODGE_SPEED     520.0
#define DODGE_LIFT      180.0

#define SLOWMO_SCALE    0.35
#define SLOWMO_TIME     0.30    // en tiempo de juego (≈0.85 s reales a 0.35)

public Plugin myinfo =
{
    name = "L4D2 Feel",
    author = "Carlos",
    description = "Hitsounds, cámara lenta, esquivar y selector de campaña",
    version = "0.1.0",
    url = ""
};

ConVar g_cvSlowmo;
ConVar g_cvTimescale;
ConVar g_cvCheats;
bool g_bSlowmoActive;

float g_fLastHitsound[MAXPLAYERS + 1];
float g_fLastTap[MAXPLAYERS + 1][3];
float g_fNextDodge[MAXPLAYERS + 1];
int g_iLastButtons[MAXPLAYERS + 1];

// Campañas oficiales: nombre y mapas en orden
char g_sCampaignName[][] =
{
    "Dead Center", "Dark Carnival", "Swamp Fever", "Hard Rain", "The Parish", "The Passing", "The Sacrifice",
    "No Mercy", "Crash Course", "Death Toll", "Dead Air", "Blood Harvest", "Cold Stream", "The Last Stand"
};
char g_sCampaignMaps[][] =
{
    "c1m1_hotel c1m2_streets c1m3_mall c1m4_atrium",
    "c2m1_highway c2m2_fairgrounds c2m3_coaster c2m4_barns c2m5_concert",
    "c3m1_plankcountry c3m2_swamp c3m3_shantytown c3m4_plantation",
    "c4m1_milltown_a c4m2_sugarmill_a c4m3_sugarmill_b c4m4_milltown_b c4m5_milltown_escape",
    "c5m1_waterfront c5m2_park c5m3_cemetery c5m4_quarter c5m5_bridge",
    "c6m1_riverbank c6m2_bedlam c6m3_port",
    "c7m1_docks c7m2_barge c7m3_port",
    "c8m1_apartment c8m2_subway c8m3_sewers c8m4_interior c8m5_rooftop",
    "c9m1_alleys c9m2_lots",
    "c10m1_caves c10m2_drainage c10m3_ranchhouse c10m4_mainstreet c10m5_houseboat",
    "c11m1_greenhouse c11m2_offices c11m3_garage c11m4_terminal c11m5_runway",
    "c12m1_hilltop c12m2_traintunnel c12m3_bridge c12m4_barn c12m5_cornfield",
    "c13m1_alpinecreek c13m2_southpinestream c13m3_memorialbridge c13m4_cutthroatcreek",
    "c14m1_junkyard c14m2_lighthouse"
};
char g_sDifficulty[][] = { "Easy", "Normal", "Hard", "Impossible" };
char g_sDifficultyName[][] = { "Fácil", "Normal", "Avanzado", "Experto" };

public void OnPluginStart()
{
    g_cvSlowmo = CreateConVar("l4d2_feel_slowmo", "1", "Cámara lenta al matar un Tank o hacer crown (activa sv_cheats un instante)");
    g_cvTimescale = FindConVar("host_timescale");
    g_cvCheats = FindConVar("sv_cheats");

    HookEvent("infected_death", Event_InfectedDeath);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("witch_killed", Event_WitchKilled);

    RegConsoleCmd("sm_campana", Cmd_Campaign, "Selector de campaña y dificultad");
    RegConsoleCmd("sm_campaña", Cmd_Campaign, "Selector de campaña y dificultad");
    RegConsoleCmd("sm_mapa", Cmd_Campaign, "Selector de campaña y dificultad");
}

public void OnPluginEnd()
{
    if (g_bSlowmoActive)
    {
        EndSlowmo();
    }
}

public void OnMapStart()
{
    PrecacheSound(SND_HEADSHOT, true);
    PrecacheSound(SND_KILL, true);
    g_bSlowmoActive = false;
}

public void OnClientConnected(int client)
{
    g_fLastHitsound[client] = 0.0;
    g_fNextDodge[client] = 0.0;
    g_iLastButtons[client] = 0;
    for (int i = 0; i < 3; i++)
    {
        g_fLastTap[client][i] = 0.0;
    }
}

// ---------------------------------------------------------------------------
// Hitsounds
// ---------------------------------------------------------------------------

public void Event_InfectedDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("attacker"));
    if (ST_IsHumanSurvivor(client) && event.GetBool("headshot"))
    {
        PlayHeadshot(client);
    }
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    int client = GetClientOfUserId(event.GetInt("attacker"));
    if (!ST_IsInfected(victim) || !ST_IsHumanSurvivor(client))
    {
        return;
    }

    if (event.GetBool("headshot"))
    {
        PlayHeadshot(client);
    }
    EmitSoundToClient(client, SND_KILL);

    if (ST_GetZombieClass(victim) == ST_ZC_TANK)
    {
        StartSlowmo();
    }
}

public void Event_WitchKilled(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (ST_IsHumanSurvivor(client) && event.GetBool("oneshot"))
    {
        PlayHeadshot(client);
        StartSlowmo();
    }
}

void PlayHeadshot(int client)
{
    // Con escopetas o hordas llegan varias muertes en el mismo instante
    float now = GetEngineTime();
    if (now - g_fLastHitsound[client] < 0.06)
    {
        return;
    }
    g_fLastHitsound[client] = now;
    EmitSoundToClient(client, SND_HEADSHOT, _, _, _, _, 0.7);
}

// ---------------------------------------------------------------------------
// Cámara lenta (host_timescale solo tiene efecto con sv_cheats activo)
// ---------------------------------------------------------------------------

void StartSlowmo()
{
    if (!g_cvSlowmo.BoolValue || g_bSlowmoActive || g_cvTimescale == null || g_cvCheats == null)
    {
        return;
    }
    g_bSlowmoActive = true;
    SetCheatsQuiet(true);
    g_cvTimescale.FloatValue = SLOWMO_SCALE;
    CreateTimer(SLOWMO_TIME, Timer_EndSlowmo, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_EndSlowmo(Handle timer)
{
    EndSlowmo();
    return Plugin_Stop;
}

void EndSlowmo()
{
    g_cvTimescale.FloatValue = 1.0;
    SetCheatsQuiet(false);
    g_bSlowmoActive = false;
}

// Cambia sv_cheats sin el aviso "Server cvar changed" en el chat
void SetCheatsQuiet(bool enabled)
{
    int flags = g_cvCheats.Flags;
    g_cvCheats.Flags = flags & ~FCVAR_NOTIFY;
    g_cvCheats.BoolValue = enabled;
    g_cvCheats.Flags = flags;
}

// ---------------------------------------------------------------------------
// Esquivar: doble toque izquierda / derecha / atrás
// ---------------------------------------------------------------------------

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
    if (IsFakeClient(client))
    {
        return Plugin_Continue;
    }

    int pressed = buttons & ~g_iLastButtons[client];
    g_iLastButtons[client] = buttons;
    if (pressed == 0 || !ST_IsAliveStanding(client))
    {
        return Plugin_Continue;
    }

    int dir = -1;
    if (pressed & IN_MOVELEFT)
    {
        dir = 0;
    }
    else if (pressed & IN_MOVERIGHT)
    {
        dir = 1;
    }
    else if (pressed & IN_BACK)
    {
        dir = 2;
    }
    if (dir == -1)
    {
        return Plugin_Continue;
    }

    float now = GetEngineTime();
    bool doubleTap = now - g_fLastTap[client][dir] <= DODGE_WINDOW;
    g_fLastTap[client][dir] = now;

    if (doubleTap && now >= g_fNextDodge[client] && (GetEntityFlags(client) & FL_ONGROUND) && !ST_IsPinned(client))
    {
        g_fNextDodge[client] = now + DODGE_COOLDOWN;
        g_fLastTap[client][dir] = 0.0;
        Dodge(client, angles, dir);
    }
    return Plugin_Continue;
}

void Dodge(int client, const float angles[3], int dir)
{
    float yaw[3], fwd[3], right[3], push[3];
    yaw[1] = angles[1];
    GetAngleVectors(yaw, fwd, right, NULL_VECTOR);

    if (dir == 0)
    {
        NegateVector(right);
        push = right;
    }
    else if (dir == 1)
    {
        push = right;
    }
    else
    {
        NegateVector(fwd);
        push = fwd;
    }

    ScaleVector(push, DODGE_SPEED);
    push[2] = DODGE_LIFT;
    TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, push);
}

// ---------------------------------------------------------------------------
// Selector de campaña y dificultad
// ---------------------------------------------------------------------------

public Action Cmd_Campaign(int client, int args)
{
    if (client != 0)
    {
        ShowCampaignMenu(client);
    }
    return Plugin_Handled;
}

void ShowCampaignMenu(int client)
{
    char difficulty[16], name[16];
    FindConVar("z_difficulty").GetString(difficulty, sizeof(difficulty));
    DifficultyName(difficulty, name, sizeof(name));

    Menu menu = new Menu(MenuHandler_Campaign);
    menu.SetTitle("CAMPAÑAS\nDificultad: %s\n ", name);
    menu.AddItem("difficulty", "Cambiar dificultad");

    char info[8];
    for (int c = 0; c < sizeof(g_sCampaignName); c++)
    {
        IntToString(c, info, sizeof(info));
        menu.AddItem(info, g_sCampaignName[c]);
    }
    menu.Display(client, MENU_TIME_FOREVER);
}

void DifficultyName(const char[] value, char[] name, int maxlen)
{
    strcopy(name, maxlen, value);
    for (int i = 0; i < sizeof(g_sDifficulty); i++)
    {
        if (StrEqual(value, g_sDifficulty[i], false))
        {
            strcopy(name, maxlen, g_sDifficultyName[i]);
        }
    }
}

public int MenuHandler_Campaign(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_Select)
    {
        char info[16];
        menu.GetItem(item, info, sizeof(info));
        if (StrEqual(info, "difficulty"))
        {
            ShowDifficultyMenu(client);
        }
        else
        {
            ShowChapterMenu(client, StringToInt(info));
        }
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}

void ShowChapterMenu(int client, int campaign)
{
    char maps[8][32];
    int count = ExplodeString(g_sCampaignMaps[campaign], " ", maps, sizeof(maps), sizeof(maps[]));

    Menu menu = new Menu(MenuHandler_Chapter);
    menu.SetTitle("%s\nElige capítulo\n ", g_sCampaignName[campaign]);
    char display[48];
    for (int i = 0; i < count; i++)
    {
        Format(display, sizeof(display), "Capítulo %d  (%s)", i + 1, maps[i]);
        menu.AddItem(maps[i], display, IsMapValid(maps[i]) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
    }
    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Chapter(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_Select)
    {
        char map[32];
        menu.GetItem(item, map, sizeof(map));
        PrintToChatAll("\x04[Mapa]\x01 Cambiando a \x05%s\x01...", map);
        ServerCommand("changelevel %s", map);
    }
    else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
    {
        ShowCampaignMenu(client);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}

void ShowDifficultyMenu(int client)
{
    Menu menu = new Menu(MenuHandler_Difficulty);
    menu.SetTitle("Dificultad\n ");
    for (int i = 0; i < sizeof(g_sDifficulty); i++)
    {
        menu.AddItem(g_sDifficulty[i], g_sDifficultyName[i]);
    }
    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Difficulty(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_Select)
    {
        char value[16], name[16];
        menu.GetItem(item, value, sizeof(value));
        FindConVar("z_difficulty").SetString(value);
        DifficultyName(value, name, sizeof(name));
        PrintToChatAll("\x04[Mapa]\x01 Dificultad: \x05%s", name);
        ShowCampaignMenu(client);
    }
    else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
    {
        ShowCampaignMenu(client);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}
