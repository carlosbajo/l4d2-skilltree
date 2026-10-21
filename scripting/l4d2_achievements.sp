#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <skilltree>

#define SND_UNLOCK      "ui/survival_medal.wav"
#define COMBO_WINDOW    2.0
#define RARITY_LEGENDARY 4

// El orden define el id en la DB: agregar logros nuevos solo al final
enum
{
    ACH_CROWNS,
    ACH_TANKS,
    ACH_HEADSHOTS,
    ACH_COMMONS,
    ACH_COMBO,
    ACH_MELEE_TANK,
    ACH_UNTOUCHABLE,
    ACH_ELITES,
    ACH_BOSSES,
    ACH_CAMPAIGN,
    ACH_VETERAN,
    ACH_LEGENDARY,
    ACH_COUNT
}

char g_sAchName[ACH_COUNT][] =
{
    "Coronador", "Cazatanques", "Ojo de águila", "Carnicero", "Imparable", "A mano limpia",
    "Intocable", "Exterminador élite", "Matajefes", "Superviviente", "Veterano", "Leyenda"
};
char g_sAchDesc[ACH_COUNT][] =
{
    "Haz crown a 10 Witches",
    "Mata 10 Tanks",
    "Haz 500 headshots",
    "Mata 5000 infectados comunes",
    "Llega a un combo x50",
    "Mata un Tank con un arma cuerpo a cuerpo",
    "Termina un capítulo sin caer",
    "Mata 25 especiales élite",
    "Mata 5 jefes",
    "Termina una campaña",
    "Termina 5 campañas",
    "Consigue un arma legendaria"
};
int g_iAchGoal[ACH_COUNT] = { 10, 10, 500, 5000, 1, 1, 1, 25, 5, 1, 5, 1 };
int g_iAchReward[ACH_COUNT] = { 500, 500, 300, 500, 300, 1000, 300, 500, 800, 1000, 2000, 300 };

Database g_hDB;
bool g_bLoaded[MAXPLAYERS + 1];
int g_iProgress[MAXPLAYERS + 1][ACH_COUNT];
bool g_bDirty[MAXPLAYERS + 1][ACH_COUNT];
bool g_bIncapped[MAXPLAYERS + 1];
int g_iCombo[MAXPLAYERS + 1];
float g_fLastKill[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name = "L4D2 Achievements",
    author = "Carlos",
    description = "Logros propios con recompensa de XP y créditos",
    version = "0.1.0",
    url = ""
};

public void OnPluginStart()
{
    HookEvent("witch_killed", Event_WitchKilled);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("infected_death", Event_InfectedDeath);
    HookEvent("player_incapacitated", Event_Incapacitated);
    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("round_end", Event_SaveAll, EventHookMode_PostNoCopy);
    HookEvent("map_transition", Event_MapTransition, EventHookMode_PostNoCopy);
    HookEvent("finale_win", Event_FinaleWin, EventHookMode_PostNoCopy);

    RegConsoleCmd("sm_logros", Cmd_Achievements, "Muestra tus logros");

    Database.Connect(OnDBConnect, "storage-local");
}

public void OnMapStart()
{
    PrecacheSound(SND_UNLOCK, true);
}

public void OnMapEnd()
{
    SaveAll();
}

public void OnPluginEnd()
{
    SaveAll();
}

// ---------------------------------------------------------------------------
// Base de datos
// ---------------------------------------------------------------------------

public void OnDBConnect(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("No se pudo conectar a storage-local: %s", error);
        return;
    }
    g_hDB = db;
    g_hDB.Query(OnGenericQuery, "CREATE TABLE IF NOT EXISTS skilltree_achievements ("
        ... "steamid TEXT NOT NULL, id INTEGER NOT NULL, progress INTEGER NOT NULL, PRIMARY KEY (steamid, id))");

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && IsClientAuthorized(i))
        {
            LoadPlayer(i);
        }
    }
}

public void OnGenericQuery(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
    {
        LogError("Error SQL: %s", error);
    }
}

public void OnClientConnected(int client)
{
    g_bLoaded[client] = false;
    g_bIncapped[client] = false;
    g_iCombo[client] = 0;
    g_fLastKill[client] = -1000.0;
    for (int a = 0; a < ACH_COUNT; a++)
    {
        g_iProgress[client][a] = 0;
        g_bDirty[client][a] = false;
    }
}

public void OnClientPostAdminCheck(int client)
{
    LoadPlayer(client);
}

public void OnClientDisconnect(int client)
{
    SavePlayer(client);
    g_bLoaded[client] = false;
}

void LoadPlayer(int client)
{
    char auth[32];
    if (g_hDB == null || IsFakeClient(client) || !GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
    {
        return;
    }
    char query[256];
    g_hDB.Format(query, sizeof(query), "SELECT id, progress FROM skilltree_achievements WHERE steamid = '%s'", auth);
    g_hDB.Query(OnLoadPlayer, query, GetClientUserId(client));
}

public void OnLoadPlayer(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0)
    {
        return;
    }
    if (results == null)
    {
        LogError("Error cargando logros de %N: %s", client, error);
        return;
    }
    while (results.FetchRow())
    {
        int id = results.FetchInt(0);
        if (id >= 0 && id < ACH_COUNT)
        {
            g_iProgress[client][id] = results.FetchInt(1);
        }
    }
    g_bLoaded[client] = true;
}

void SavePlayer(int client)
{
    char auth[32];
    if (g_hDB == null || !g_bLoaded[client] || !IsClientInGame(client) || !GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
    {
        return;
    }
    char query[256];
    for (int a = 0; a < ACH_COUNT; a++)
    {
        if (!g_bDirty[client][a])
        {
            continue;
        }
        g_bDirty[client][a] = false;
        g_hDB.Format(query, sizeof(query),
            "INSERT OR REPLACE INTO skilltree_achievements (steamid, id, progress) VALUES ('%s', %d, %d)",
            auth, a, g_iProgress[client][a]);
        g_hDB.Query(OnGenericQuery, query);
    }
}

void SaveAll()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        SavePlayer(i);
    }
}

public void Event_SaveAll(Event event, const char[] name, bool dontBroadcast)
{
    SaveAll();
}

// ---------------------------------------------------------------------------
// Progreso
// ---------------------------------------------------------------------------

void Progress(int client, int ach, int amount = 1)
{
    if (!ST_IsHumanSurvivor(client) || !g_bLoaded[client] || g_iProgress[client][ach] >= g_iAchGoal[ach])
    {
        return;
    }
    g_iProgress[client][ach] += amount;
    g_bDirty[client][ach] = true;
    if (g_iProgress[client][ach] >= g_iAchGoal[ach])
    {
        g_iProgress[client][ach] = g_iAchGoal[ach];
        Unlock(client, ach);
    }
}

void Unlock(int client, int ach)
{
    Skilltree_AddXP(client, g_iAchReward[ach]);
    SavePlayer(client);

    EmitSoundToClient(client, SND_UNLOCK);
    PrintHintText(client, "LOGRO DESBLOQUEADO: %s\n+%d XP y $%d", g_sAchName[ach], g_iAchReward[ach], g_iAchReward[ach]);
    PrintToChatAll("\x04[Logro]\x01 %N desbloqueó \x05%s\x01 (%s).", client, g_sAchName[ach], g_sAchDesc[ach]);
}

void RegisterKill(int client)
{
    float now = GetGameTime();
    g_iCombo[client] = now - g_fLastKill[client] <= COMBO_WINDOW ? g_iCombo[client] + 1 : 1;
    g_fLastKill[client] = now;
    if (g_iCombo[client] >= 50)
    {
        Progress(client, ACH_COMBO);
    }
}

public void Event_InfectedDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("attacker"));
    if (!ST_IsHumanSurvivor(client))
    {
        return;
    }
    Progress(client, ACH_COMMONS);
    if (event.GetBool("headshot"))
    {
        Progress(client, ACH_HEADSHOTS);
    }
    RegisterKill(client);
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
        Progress(client, ACH_HEADSHOTS);
    }
    RegisterKill(client);

    if (ST_GetZombieClass(victim) == ST_ZC_TANK)
    {
        Progress(client, ACH_TANKS);
        char weapon[32];
        event.GetString("weapon", weapon, sizeof(weapon));
        if (StrContains(weapon, "melee") != -1 || StrEqual(weapon, "chainsaw"))
        {
            Progress(client, ACH_MELEE_TANK);
        }
    }
}

public void Event_WitchKilled(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (event.GetBool("oneshot"))
    {
        Progress(client, ACH_CROWNS);
    }
}

public void Event_Incapacitated(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client != 0)
    {
        g_bIncapped[client] = true;
    }
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_bIncapped[i] = false;
    }
}

void CheckUntouchable()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (ST_IsHumanSurvivor(i) && IsPlayerAlive(i) && !g_bIncapped[i])
        {
            Progress(i, ACH_UNTOUCHABLE);
        }
    }
}

public void Event_MapTransition(Event event, const char[] name, bool dontBroadcast)
{
    CheckUntouchable();
    SaveAll();
}

public void Event_FinaleWin(Event event, const char[] name, bool dontBroadcast)
{
    CheckUntouchable();
    for (int i = 1; i <= MaxClients; i++)
    {
        if (ST_IsHumanSurvivor(i))
        {
            Progress(i, ACH_CAMPAIGN);
            Progress(i, ACH_VETERAN);
        }
    }
    SaveAll();
}

public void Elites_OnEliteKilled(int victim, int attacker, int affix)
{
    Progress(attacker, ACH_ELITES);
}

public void Elites_OnBossKilled(int victim, int attacker, int bossType)
{
    Progress(attacker, ACH_BOSSES);
}

public void Loot_OnPickup(int client, int weapon, int rarity)
{
    if (rarity == RARITY_LEGENDARY)
    {
        Progress(client, ACH_LEGENDARY);
    }
}

// ---------------------------------------------------------------------------
// Menú
// ---------------------------------------------------------------------------

public Action Cmd_Achievements(int client, int args)
{
    if (client == 0)
    {
        return Plugin_Handled;
    }
    int unlocked = 0;
    for (int a = 0; a < ACH_COUNT; a++)
    {
        if (g_iProgress[client][a] >= g_iAchGoal[a])
        {
            unlocked++;
        }
    }

    Menu menu = new Menu(MenuHandler_Achievements);
    menu.SetTitle("LOGROS  (%d/%d)\n ", unlocked, ACH_COUNT);
    char display[128];
    for (int a = 0; a < ACH_COUNT; a++)
    {
        bool done = g_iProgress[client][a] >= g_iAchGoal[a];
        Format(display, sizeof(display), "[%s] %s (%d/%d): %s, +%d XP",
            done ? "X" : " ", g_sAchName[a], g_iProgress[client][a], g_iAchGoal[a], g_sAchDesc[a], g_iAchReward[a]);
        menu.AddItem("", display, ITEMDRAW_DISABLED);
    }
    menu.Display(client, MENU_TIME_FOREVER);
    return Plugin_Handled;
}

public int MenuHandler_Achievements(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}
