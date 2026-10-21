#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION "0.1.0"

#define TEAM_SURVIVOR   2
#define TEAM_INFECTED   3

#define MAX_LEVEL       50
#define COMBO_WINDOW    2.0     // segundos entre muertes para mantener el combo
#define COMBO_CAP       20
#define POINTS_PER_TIER 3       // puntos invertidos en la rama para desbloquear el siguiente tier
#define AURA_RADIUS     400.0

#define XP_COMMON       1
#define XP_HEADSHOT     2
#define XP_SPECIAL_HS   5
#define XP_WITCH        30
#define XP_WITCH_CROWN  20

#define SND_LEVELUP     "ui/bigreward.wav"

// Slots y flags del HUD scripted de L4D2 (HUD_SCORE_1, HUD_FLAG_*)
#define HUD_SLOT_FIRST  11
#define HUD_MAX_LINES   4
#define HUD_TEXT_LEN    128
#define HUDF_ALIGN_LEFT (1 << 8)
#define HUDF_SURVIVORS  (1 << 10)
#define HUDF_TEXT       (1 << 13)   // sin este flag el cliente no dibuja el texto
#define HUDF_HIDDEN     (1 << 14)
#define HUD_BAR_WIDTH   15

#define SKILL_NAME_LEN  32
#define SKILL_DESC_LEN  64

// El orden define cómo se guardan en la DB: agregar habilidades nuevas solo al final.
enum
{
    SK_HAWKEYE,     // Tirador T1
    SK_STREAK,      // Tirador T2
    SK_INCENDIARY,  // Demoledor T1
    SK_GRENADIER,   // Demoledor T2
    SK_VAMPIRE,     // Soporte T1
    SK_AURA,        // Soporte T2
    SK_SPEED,       // Superviviente T1
    SK_TOUGH,       // Superviviente T2
    SK_COUNT
}

enum struct SkillInfo
{
    char name[SKILL_NAME_LEN];
    char desc[SKILL_DESC_LEN];
    int branch;
    int tier;
    int maxRank;
}

#define BRANCH_COUNT 4
char g_sBranchName[BRANCH_COUNT][] = { "Tirador", "Demoledor", "Soporte", "Superviviente" };

// Indexado por m_zombieClass
char g_sSpecialName[][] = { "", "Smoker", "Boomer", "Hunter", "Spitter", "Jockey", "Charger", "", "Tank" };
int g_iSpecialXP[] = { 0, 10, 8, 10, 10, 10, 12, 0, 50 };

// Muertes necesarias por rango
int g_iIncendiaryKills[] = { 0, 60, 45, 30 };
int g_iGrenadierKills[] = { 0, 80, 60, 40 };

SkillInfo g_Skills[SK_COUNT];
Database g_hDB;
ConVar g_cvPillsDecay;
bool g_bMapRunning;
float g_fXPMult = 1.0;
float g_fCreditMult = 1.0;
bool g_bHudDirty = true;
bool g_bEnabledChallenge;
char g_sHudLine[HUD_MAX_LINES][HUD_TEXT_LEN];

bool g_bLoaded[MAXPLAYERS + 1];
int g_iXP[MAXPLAYERS + 1];
int g_iLevel[MAXPLAYERS + 1];
int g_iPoints[MAXPLAYERS + 1];
int g_iRank[MAXPLAYERS + 1][SK_COUNT];

int g_iCombo[MAXPLAYERS + 1];
float g_fLastKill[MAXPLAYERS + 1];
int g_iIncendiaryCount[MAXPLAYERS + 1];
int g_iGrenadierCount[MAXPLAYERS + 1];

// Tienda: créditos ($) que se ganan 1:1 con la XP
enum struct ShopItem
{
    char name[32];
    char classname[32];   // sin el prefijo "weapon_"
    int price;
    int category;
}

#define SHOP_CATEGORY_COUNT 5
char g_sShopCategory[SHOP_CATEGORY_COUNT][] = { "Subfusiles", "Escopetas", "Rifles", "Francotiradores", "Pesadas" };

ArrayList g_hShopItems;
int g_iCredits[MAXPLAYERS + 1];
int g_iInfiniteRef[2049];   // EntRef de armas compradas (munición infinita), indexado por entidad
int g_iInfiniteClip[2049];  // tamaño de cargador a mantener, indexado por entidad

// Última arma comprada, para reactivarla al aparecer en el siguiente capítulo (el juego recrea las armas)
char g_sOwnedWeapon[MAXPLAYERS + 1][40];
int g_iShopTarget[MAXPLAYERS + 1];  // userid del superviviente que recibe la compra (0 = uno mismo)
int g_iOwnedClip[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name = "L4D2 Skill Tree",
    author = "Carlos",
    description = "XP por muertes/combos/headshots y árbol de habilidades",
    version = PLUGIN_VERSION,
    url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    g_bMapRunning = late;

    CreateNative("Skilltree_GetLevel", Native_GetLevel);
    CreateNative("Skilltree_AddXP", Native_AddXP);
    CreateNative("Skilltree_GetCredits", Native_GetCredits);
    CreateNative("Skilltree_AddCredits", Native_AddCredits);
    CreateNative("Skilltree_SetMultipliers", Native_SetMultipliers);
    CreateNative("Skilltree_MakeInfinite", Native_MakeInfinite);
    CreateNative("Skilltree_IsInfinite", Native_IsInfinite);
    RegPluginLibrary("skilltree");
    return APLRes_Success;
}

// ---------------------------------------------------------------------------
// API para los demás módulos (ver include/skilltree.inc)
// ---------------------------------------------------------------------------

bool IsValidClientArg(int client)
{
    return client >= 1 && client <= MaxClients && IsClientInGame(client);
}

public any Native_GetLevel(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    return IsValidClientArg(client) ? g_iLevel[client] : 1;
}

public any Native_AddXP(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if (IsValidClientArg(client))
    {
        AddXP(client, GetNativeCell(2));
    }
    return 0;
}

public any Native_GetCredits(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    return IsValidClientArg(client) ? g_iCredits[client] : 0;
}

public any Native_AddCredits(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if (IsValidClientArg(client) && g_bLoaded[client])
    {
        g_iCredits[client] += GetNativeCell(2);
        if (g_iCredits[client] < 0)
        {
            g_iCredits[client] = 0;
        }
        SavePlayer(client);
    }
    return 0;
}

public any Native_SetMultipliers(Handle plugin, int numParams)
{
    g_fXPMult = GetNativeCell(1);
    g_fCreditMult = GetNativeCell(2);
    return 0;
}

public any Native_MakeInfinite(Handle plugin, int numParams)
{
    int weapon = GetNativeCell(1);
    if (weapon > MaxClients && weapon < sizeof(g_iInfiniteRef) && IsValidEntity(weapon))
    {
        MakeInfinite(weapon, GetMaxClip(weapon));
    }
    return 0;
}

public any Native_IsInfinite(Handle plugin, int numParams)
{
    return IsInfiniteWeapon(GetNativeCell(1));
}

public void OnPluginStart()
{
    DefineSkills();

    g_cvPillsDecay = FindConVar("pain_pills_decay_rate");

    HookEvent("infected_death", Event_InfectedDeath);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("witch_killed", Event_WitchKilled);
    HookEvent("player_spawn", Event_PlayerSpawn);
    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
    HookEvent("weapon_fire", Event_WeaponFire);

    DefineShopItems();

    RegConsoleCmd("sm_skills", Cmd_Skills, "Abre el árbol de habilidades");
    RegConsoleCmd("sm_shop", Cmd_Shop, "Abre la tienda de armas");
    RegConsoleCmd("sm_tienda", Cmd_Shop, "Abre la tienda de armas");
    RegConsoleCmd("sm_xp", Cmd_XP, "Muestra tu nivel y XP");
    RegAdminCmd("sm_givexp", Cmd_GiveXP, ADMFLAG_CHEATS, "sm_givexp <cantidad> - Darte XP (pruebas)");
    RegAdminCmd("sm_givemoney", Cmd_GiveMoney, ADMFLAG_CHEATS, "sm_givemoney <cantidad> - Darte créditos (pruebas)");

    Database.Connect(OnDBConnect, "storage-local");

    CreateTimer(0.5, Timer_UpdateHud, _, TIMER_REPEAT);
    CreateTimer(2.0, Timer_Aura, _, TIMER_REPEAT);

    // Carga tardía
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            OnClientConnected(i);
            OnClientPutInServer(i);
        }
    }
    HookExistingInfected("infected");
    HookExistingInfected("witch");
}

public void OnPluginEnd()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        SavePlayer(i);
    }
    if (g_bMapRunning)
    {
        for (int i = 0; i < HUD_MAX_LINES; i++)
        {
            HUD_SetSlot(HUD_SLOT_FIRST + i, HUDF_HIDDEN, "");
        }
        if (g_bEnabledChallenge)
        {
            GameRules_SetProp("m_bChallengeModeActive", false, _, _, true);
        }
    }
}

void DefineSkills()
{
    DefineSkill(SK_HAWKEYE,    "Ojo de halcón",     "+15% daño en headshots",            0, 1, 3);
    DefineSkill(SK_STREAK,     "Racha letal",       "+0.5% daño por kill de combo",      0, 2, 3);
    DefineSkill(SK_INCENDIARY, "Munición especial", "Balas incendiarias cada 60/45/30 kills", 1, 1, 3);
    DefineSkill(SK_GRENADIER,  "Granadero",         "Pipe bomb gratis cada 80/60/40 kills",   1, 2, 3);
    DefineSkill(SK_VAMPIRE,    "Vampirismo",        "+0.5 vida temporal por kill",       2, 1, 3);
    DefineSkill(SK_AURA,       "Aura curativa",     "+1 vida temporal/2s a aliados cerca", 2, 2, 3);
    DefineSkill(SK_SPEED,      "Piernas ligeras",   "+6% velocidad",                     3, 1, 3);
    DefineSkill(SK_TOUGH,      "Piel dura",         "-10% daño de infectados comunes",   3, 2, 3);
}

void DefineShopItems()
{
    g_hShopItems = new ArrayList(sizeof(ShopItem));
    DefineShopItem("Uzi",                 "smg",              300, 0);
    DefineShopItem("Uzi silenciada",      "smg_silenced",     300, 0);
    DefineShopItem("Escopeta de bombeo",  "pumpshotgun",      300, 1);
    DefineShopItem("Escopeta cromada",    "shotgun_chrome",   300, 1);
    DefineShopItem("Escopeta automática", "autoshotgun",      700, 1);
    DefineShopItem("SPAS-12",             "shotgun_spas",     700, 1);
    DefineShopItem("M16",                 "rifle",            700, 2);
    DefineShopItem("Desert Rifle",        "rifle_desert",     750, 2);
    DefineShopItem("AK-47",               "rifle_ak47",       800, 2);
    DefineShopItem("Rifle de caza",       "hunting_rifle",    600, 3);
    DefineShopItem("Rifle militar",       "sniper_military",  800, 3);
    DefineShopItem("Lanzagranadas",       "grenade_launcher", 1500, 4);
    DefineShopItem("M60",                 "rifle_m60",        2000, 4);
}

void DefineShopItem(const char[] name, const char[] classname, int price, int category)
{
    ShopItem item;
    strcopy(item.name, sizeof(item.name), name);
    strcopy(item.classname, sizeof(item.classname), classname);
    item.price = price;
    item.category = category;
    g_hShopItems.PushArray(item);
}

void DefineSkill(int id, const char[] name, const char[] desc, int branch, int tier, int maxRank)
{
    strcopy(g_Skills[id].name, SKILL_NAME_LEN, name);
    strcopy(g_Skills[id].desc, SKILL_DESC_LEN, desc);
    g_Skills[id].branch = branch;
    g_Skills[id].tier = tier;
    g_Skills[id].maxRank = maxRank;
}

public void OnMapStart()
{
    PrecacheSound(SND_LEVELUP, true);
    g_bMapRunning = true;
    g_bHudDirty = true;
    g_bEnabledChallenge = false;
    for (int i = 1; i <= MaxClients; i++)
    {
        ResetCombo(i);
    }
    for (int i = 0; i < sizeof(g_iInfiniteRef); i++)
    {
        g_iInfiniteRef[i] = INVALID_ENT_REFERENCE;
    }
}

public void OnMapEnd()
{
    g_bMapRunning = false;
    for (int i = 1; i <= MaxClients; i++)
    {
        SavePlayer(i);
    }
}

// ---------------------------------------------------------------------------
// Clientes
// ---------------------------------------------------------------------------

public void OnClientConnected(int client)
{
    ResetPlayer(client);
    // Fuera de ResetPlayer: la recarga desde la DB en cada cambio de mapa no debe borrarla
    g_sOwnedWeapon[client][0] = '\0';
    g_iShopTarget[client] = 0;
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_TraceAttack, OnTraceAttack);
    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

public void OnClientPostAdminCheck(int client)
{
    LoadPlayer(client);
}

public void OnClientDisconnect(int client)
{
    SavePlayer(client);
    ResetPlayer(client);
}

void ResetPlayer(int client)
{
    g_bLoaded[client] = false;
    g_iXP[client] = 0;
    g_iLevel[client] = 1;
    g_iPoints[client] = 0;
    g_iCredits[client] = 0;
    for (int s = 0; s < SK_COUNT; s++)
    {
        g_iRank[client][s] = 0;
    }
    g_iIncendiaryCount[client] = 0;
    g_iGrenadierCount[client] = 0;
    ResetCombo(client);
}

void ResetCombo(int client)
{
    g_iCombo[client] = 0;
    g_fLastKill[client] = -1000.0;
}

bool IsHumanSurvivor(int client)
{
    return client >= 1 && client <= MaxClients && IsClientInGame(client)
        && !IsFakeClient(client) && GetClientTeam(client) == TEAM_SURVIVOR;
}

bool IsAliveSurvivor(int client)
{
    return IsClientInGame(client) && GetClientTeam(client) == TEAM_SURVIVOR && IsPlayerAlive(client)
        && !GetEntProp(client, Prop_Send, "m_isIncapacitated");
}

// ---------------------------------------------------------------------------
// Base de datos (SQLite local)
// ---------------------------------------------------------------------------

public void OnDBConnect(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("No se pudo conectar a storage-local: %s", error);
        return;
    }

    g_hDB = db;
    g_hDB.Query(OnGenericQuery, "CREATE TABLE IF NOT EXISTS skilltree ("
        ... "steamid TEXT PRIMARY KEY, xp INTEGER NOT NULL, level INTEGER NOT NULL, "
        ... "points INTEGER NOT NULL, skills TEXT NOT NULL, credits INTEGER NOT NULL DEFAULT 0)");
    // Migración de tablas creadas antes de la tienda; falla (y se ignora) si la columna ya existe
    g_hDB.Query(OnIgnoreQuery, "ALTER TABLE skilltree ADD COLUMN credits INTEGER NOT NULL DEFAULT 0");

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

public void OnIgnoreQuery(Database db, DBResultSet results, const char[] error, any data)
{
}

void LoadPlayer(int client)
{
    if (g_hDB == null || IsFakeClient(client))
    {
        return;
    }

    char auth[32];
    if (!GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
    {
        return;
    }

    char query[256];
    g_hDB.Format(query, sizeof(query), "SELECT xp, level, points, skills, credits FROM skilltree WHERE steamid = '%s'", auth);
    g_hDB.Query(OnLoadPlayer, query, GetClientUserId(client));
}

public void OnLoadPlayer(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0)
    {
        return;
    }

    // Si falla la carga no marcamos como cargado, para no sobrescribir su progreso con ceros
    if (results == null)
    {
        LogError("Error cargando a %N: %s", client, error);
        return;
    }

    ResetPlayer(client);
    if (results.FetchRow())
    {
        g_iXP[client] = results.FetchInt(0);
        g_iLevel[client] = results.FetchInt(1);
        g_iPoints[client] = results.FetchInt(2);
        g_iCredits[client] = results.FetchInt(4);

        char skills[128];
        results.FetchString(3, skills, sizeof(skills));
        char parts[SK_COUNT][8];
        int count = ExplodeString(skills, ",", parts, SK_COUNT, sizeof(parts[]));
        for (int s = 0; s < count; s++)
        {
            g_iRank[client][s] = StringToInt(parts[s]);
        }
    }
    g_bLoaded[client] = true;
    ApplySpeed(client);
}

void SavePlayer(int client)
{
    if (g_hDB == null || !g_bLoaded[client] || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    char auth[32];
    if (!GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
    {
        return;
    }

    char skills[128];
    for (int s = 0; s < SK_COUNT; s++)
    {
        Format(skills, sizeof(skills), "%s%s%d", skills, s > 0 ? "," : "", g_iRank[client][s]);
    }

    char query[512];
    g_hDB.Format(query, sizeof(query),
        "INSERT OR REPLACE INTO skilltree (steamid, xp, level, points, skills, credits) VALUES ('%s', %d, %d, %d, '%s', %d)",
        auth, g_iXP[client], g_iLevel[client], g_iPoints[client], skills, g_iCredits[client]);
    g_hDB.Query(OnGenericQuery, query);
}

// ---------------------------------------------------------------------------
// XP, niveles y combos
// ---------------------------------------------------------------------------

int XPToNext(int level)
{
    return 100 + 50 * (level - 1);
}

void AddXP(int client, int amount)
{
    if (!g_bLoaded[client])
    {
        return;
    }

    int credits = RoundToFloor(amount * g_fCreditMult);
    amount = RoundToFloor(amount * g_fXPMult);

    // Los créditos se siguen ganando aunque ya esté en el nivel máximo
    g_iCredits[client] += credits;
    if (g_iLevel[client] >= MAX_LEVEL)
    {
        return;
    }

    g_iXP[client] += amount;
    bool leveled = false;
    while (g_iLevel[client] < MAX_LEVEL && g_iXP[client] >= XPToNext(g_iLevel[client]))
    {
        g_iXP[client] -= XPToNext(g_iLevel[client]);
        g_iLevel[client]++;
        g_iPoints[client]++;
        leveled = true;
    }
    if (g_iLevel[client] >= MAX_LEVEL)
    {
        g_iXP[client] = 0;
    }

    if (leveled)
    {
        LevelUpFX(client);
        SavePlayer(client);
    }
}

int RegisterKill(int client)
{
    float now = GetGameTime();
    if (now - g_fLastKill[client] <= COMBO_WINDOW)
    {
        g_iCombo[client]++;
    }
    else
    {
        g_iCombo[client] = 1;
    }
    g_fLastKill[client] = now;
    return g_iCombo[client];
}

int ActiveCombo(int client)
{
    return GetGameTime() - g_fLastKill[client] <= COMBO_WINDOW ? g_iCombo[client] : 0;
}

void LevelUpFX(int client)
{
    EmitSoundToClient(client, SND_LEVELUP);
    ScreenFade(client, 255, 200, 40, 80);
    PrintHintText(client, "¡NIVEL %d!  +1 punto de habilidad\nEscribe !skills para usarlo", g_iLevel[client]);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == TEAM_SURVIVOR)
        {
            PrintToChat(i, "\x04[Skills]\x01 %N subió a \x05nivel %d", client, g_iLevel[client]);
        }
    }
}

void ScreenFade(int client, int r, int g, int b, int a)
{
    Handle msg = StartMessageOne("Fade", client);
    if (msg == null)
    {
        return;
    }
    BfWrite bf = UserMessageToBfWrite(msg);
    bf.WriteShort(300);             // duración (1/512 s)
    bf.WriteShort(100);             // hold
    bf.WriteShort(0x0001 | 0x0010); // FFADE_IN | FFADE_PURGE
    bf.WriteByte(r);
    bf.WriteByte(g);
    bf.WriteByte(b);
    bf.WriteByte(a);
    EndMessage();
}

// ---------------------------------------------------------------------------
// Eventos de muertes
// ---------------------------------------------------------------------------

public void Event_InfectedDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("attacker"));
    if (!IsHumanSurvivor(client))
    {
        return;
    }

    bool headshot = event.GetBool("headshot");
    int combo = RegisterKill(client);
    int xp = XP_COMMON + (headshot ? XP_HEADSHOT : 0) + combo / 5;
    AddXP(client, xp);
    OnKillPerks(client);

    if (headshot || combo >= 5)
    {
        ShowKillPopup(client, headshot ? "HEADSHOT" : "", xp, combo);
    }
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    int client = GetClientOfUserId(event.GetInt("attacker"));
    if (victim == 0 || GetClientTeam(victim) != TEAM_INFECTED || !IsHumanSurvivor(client))
    {
        return;
    }

    int zclass = GetEntProp(victim, Prop_Send, "m_zombieClass");
    if (zclass < 1 || zclass >= sizeof(g_iSpecialXP) || g_iSpecialXP[zclass] == 0)
    {
        return;
    }

    bool headshot = event.GetBool("headshot");
    int combo = RegisterKill(client);
    int xp = g_iSpecialXP[zclass] + (headshot ? XP_SPECIAL_HS : 0) + combo / 5;
    AddXP(client, xp);
    OnKillPerks(client);

    char label[32];
    Format(label, sizeof(label), "%s%s", g_sSpecialName[zclass], headshot ? " HEADSHOT" : "");
    ShowKillPopup(client, label, xp, combo);
}

public void Event_WitchKilled(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsHumanSurvivor(client))
    {
        return;
    }

    bool crown = event.GetBool("oneshot");
    int xp = XP_WITCH + (crown ? XP_WITCH_CROWN : 0);
    AddXP(client, xp);
    ShowKillPopup(client, crown ? "¡CROWN!" : "Witch", xp, 0);
}

void ShowKillPopup(int client, const char[] label, int xp, int combo)
{
    if (combo >= 2)
    {
        PrintCenterText(client, "%s  +%d XP  |  COMBO x%d", label, xp, combo);
    }
    else
    {
        PrintCenterText(client, "%s  +%d XP", label, xp);
    }
}

void OnKillPerks(int client)
{
    int rank = g_iRank[client][SK_VAMPIRE];
    if (rank > 0)
    {
        AddTempHealth(client, 0.5 * rank);
    }

    rank = g_iRank[client][SK_INCENDIARY];
    if (rank > 0 && ++g_iIncendiaryCount[client] >= g_iIncendiaryKills[rank]
        && GetPlayerWeaponSlot(client, 0) != -1)
    {
        g_iIncendiaryCount[client] = 0;
        CheatCommand(client, "upgrade_add", "INCENDIARY_AMMO");
        PrintHintText(client, "Munición especial: ¡balas incendiarias!");
    }

    // Si ya carga una granada, se queda esperando hasta que tenga el slot libre
    rank = g_iRank[client][SK_GRENADIER];
    if (rank > 0 && ++g_iGrenadierCount[client] >= g_iGrenadierKills[rank]
        && GetPlayerWeaponSlot(client, 2) == -1)
    {
        g_iGrenadierCount[client] = 0;
        CheatCommand(client, "give", "pipe_bomb");
        PrintHintText(client, "Granadero: ¡pipe bomb gratis!");
    }
}

// ---------------------------------------------------------------------------
// Efectos de habilidades
// ---------------------------------------------------------------------------

public void OnEntityCreated(int entity, const char[] classname)
{
    if (StrEqual(classname, "infected") || StrEqual(classname, "witch"))
    {
        SDKHook(entity, SDKHook_TraceAttack, OnTraceAttack);
    }
}

void HookExistingInfected(const char[] classname)
{
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, classname)) != -1)
    {
        SDKHook(entity, SDKHook_TraceAttack, OnTraceAttack);
    }
}

// Daño que hace el jugador: Ojo de halcón y Racha letal
public Action OnTraceAttack(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &ammotype, int hitbox, int hitgroup)
{
    if (!IsHumanSurvivor(attacker))
    {
        return Plugin_Continue;
    }
    if (victim <= MaxClients && GetClientTeam(victim) != TEAM_INFECTED)
    {
        return Plugin_Continue;
    }

    float mult = 1.0;
    if (hitgroup == 1)
    {
        mult += 0.15 * g_iRank[attacker][SK_HAWKEYE];
    }
    int combo = ActiveCombo(attacker);
    if (combo > COMBO_CAP)
    {
        combo = COMBO_CAP;
    }
    mult += 0.005 * combo * g_iRank[attacker][SK_STREAK];

    if (mult == 1.0)
    {
        return Plugin_Continue;
    }
    damage *= mult;
    return Plugin_Changed;
}

// Daño que recibe el jugador: Piel dura
public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    if (!IsHumanSurvivor(victim) || g_iRank[victim][SK_TOUGH] == 0)
    {
        return Plugin_Continue;
    }
    if (attacker <= MaxClients || !IsValidEntity(attacker))
    {
        return Plugin_Continue;
    }

    char classname[16];
    GetEntityClassname(attacker, classname, sizeof(classname));
    if (!StrEqual(classname, "infected"))
    {
        return Plugin_Continue;
    }

    damage *= 1.0 - 0.10 * g_iRank[victim][SK_TOUGH];
    return Plugin_Changed;
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    // También bots: pueden tener armas compradas para ellos
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    if (client != 0 && GetClientTeam(client) == TEAM_SURVIVOR)
    {
        CreateTimer(0.5, Timer_ApplySpawn, userid, TIMER_FLAG_NO_MAPCHANGE);
    }
}

public Action Timer_ApplySpawn(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client != 0)
    {
        ApplySpeed(client);
        RestoreOwnedWeapon(client);
    }
    return Plugin_Stop;
}

void ApplySpeed(int client)
{
    if (!IsHumanSurvivor(client) || !IsPlayerAlive(client))
    {
        return;
    }
    SetEntPropFloat(client, Prop_Send, "m_flLaggedMovementValue", 1.0 + 0.06 * g_iRank[client][SK_SPEED]);
}

public Action Timer_Aura(Handle timer)
{
    for (int healer = 1; healer <= MaxClients; healer++)
    {
        int rank = IsHumanSurvivor(healer) ? g_iRank[healer][SK_AURA] : 0;
        if (rank == 0 || !IsAliveSurvivor(healer))
        {
            continue;
        }

        float origin[3];
        GetClientAbsOrigin(healer, origin);
        for (int target = 1; target <= MaxClients; target++)
        {
            if (target == healer || !IsAliveSurvivor(target))
            {
                continue;
            }
            float pos[3];
            GetClientAbsOrigin(target, pos);
            if (GetVectorDistance(origin, pos) <= AURA_RADIUS)
            {
                AddTempHealth(target, 1.0 * rank);
            }
        }
    }
    return Plugin_Continue;
}

float GetTempHealth(int client)
{
    float buffer = GetEntPropFloat(client, Prop_Send, "m_healthBuffer");
    float elapsed = GetGameTime() - GetEntPropFloat(client, Prop_Send, "m_healthBufferTime");
    float temp = buffer - elapsed * g_cvPillsDecay.FloatValue;
    return temp > 0.0 ? temp : 0.0;
}

void AddTempHealth(int client, float amount)
{
    if (!IsAliveSurvivor(client))
    {
        return;
    }

    float temp = GetTempHealth(client);
    float room = float(GetEntProp(client, Prop_Data, "m_iMaxHealth") - GetClientHealth(client)) - temp;
    if (room <= 0.0)
    {
        return;
    }
    SetEntPropFloat(client, Prop_Send, "m_healthBuffer", temp + (amount < room ? amount : room));
    SetEntPropFloat(client, Prop_Send, "m_healthBufferTime", GetGameTime());
}

void CheatCommand(int client, const char[] command, const char[] args)
{
    int flags = GetCommandFlags(command);
    SetCommandFlags(command, flags & ~FCVAR_CHEAT);
    FakeClientCommand(client, "%s %s", command, args);
    SetCommandFlags(command, flags);
}

// ---------------------------------------------------------------------------
// HUD (HUD scripted de L4D2, escrito directo en los netprops de terror_gamerules)
// ---------------------------------------------------------------------------

void HUD_SetSlot(int slot, int flags, const char[] text)
{
    GameRules_SetProp("m_iScriptedHUDFlags", flags, _, slot, true);
    GameRules_SetPropString("m_szScriptedHUDStringSet", text, true, slot);
}

void HUD_Place(int slot, float x, float y, float width, float height)
{
    GameRules_SetPropFloat("m_fScriptedHUDPosX", x, slot, true);
    GameRules_SetPropFloat("m_fScriptedHUDPosY", y, slot, true);
    GameRules_SetPropFloat("m_fScriptedHUDWidth", width, slot, true);
    GameRules_SetPropFloat("m_fScriptedHUDHeight", height, slot, true);
}

public Action Timer_UpdateHud(Handle timer)
{
    if (!g_bMapRunning)
    {
        return Plugin_Continue;
    }

    // El cliente solo dibuja el HUD scripted con el modo "challenge" (el de las mutaciones) activo
    if (!GameRules_GetProp("m_bChallengeModeActive"))
    {
        GameRules_SetProp("m_bChallengeModeActive", true, _, _, true);
        g_bEnabledChallenge = true;
        g_bHudDirty = true;
    }
    if (g_bHudDirty)
    {
        for (int i = 0; i < HUD_MAX_LINES; i++)
        {
            HUD_Place(HUD_SLOT_FIRST + i, 0.010, 0.030 + 0.040 * i, 0.500, 0.035);
        }
    }

    char text[HUD_TEXT_LEN];
    int line = 0;
    for (int client = 1; client <= MaxClients && line < HUD_MAX_LINES; client++)
    {
        if (!IsHumanSurvivor(client) || !g_bLoaded[client])
        {
            continue;
        }
        FormatHudLine(client, text, sizeof(text));
        if (g_bHudDirty || !StrEqual(text, g_sHudLine[line]))
        {
            HUD_SetSlot(HUD_SLOT_FIRST + line, HUDF_TEXT | HUDF_ALIGN_LEFT | HUDF_SURVIVORS, text);
            strcopy(g_sHudLine[line], HUD_TEXT_LEN, text);
        }
        line++;
    }
    for (; line < HUD_MAX_LINES; line++)
    {
        if (g_bHudDirty || g_sHudLine[line][0] != '\0')
        {
            HUD_SetSlot(HUD_SLOT_FIRST + line, HUDF_HIDDEN, "");
            g_sHudLine[line][0] = '\0';
        }
    }
    g_bHudDirty = false;
    return Plugin_Continue;
}

void FormatHudLine(int client, char[] buffer, int maxlen)
{
    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));
    TruncateUtf8(name, 14);

    if (g_iLevel[client] >= MAX_LEVEL)
    {
        Format(buffer, maxlen, "%s  Nv %d  [MAX]", name, g_iLevel[client]);
    }
    else
    {
        int need = XPToNext(g_iLevel[client]);
        int filled = g_iXP[client] * HUD_BAR_WIDTH / need;
        char bar[HUD_BAR_WIDTH + 1];
        for (int i = 0; i < HUD_BAR_WIDTH; i++)
        {
            bar[i] = i < filled ? '=' : '-';
        }
        bar[HUD_BAR_WIDTH] = '\0';
        Format(buffer, maxlen, "%s  Nv %d  [%s]  %d/%d", name, g_iLevel[client], bar, g_iXP[client], need);
    }

    // De más a menos importante: si el slot se queda corto, se corta el final
    char extra[32];
    Format(extra, sizeof(extra), "  $%d", g_iCredits[client]);
    StrCat(buffer, maxlen, extra);
    if (g_iPoints[client] > 0)
    {
        Format(extra, sizeof(extra), "  (+%d pts)", g_iPoints[client]);
        StrCat(buffer, maxlen, extra);
    }
    int combo = ActiveCombo(client);
    if (combo >= 2)
    {
        Format(extra, sizeof(extra), "  x%d", combo);
        StrCat(buffer, maxlen, extra);
    }
}

// Corta a maxChars caracteres sin romper secuencias UTF-8
void TruncateUtf8(char[] str, int maxChars)
{
    int chars = 0;
    for (int i = 0; str[i] != '\0'; i++)
    {
        if ((str[i] & 0xC0) != 0x80)
        {
            if (chars == maxChars)
            {
                str[i] = '\0';
                return;
            }
            chars++;
        }
    }
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        ResetCombo(i);
    }
    g_bHudDirty = true;
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        SavePlayer(i);
    }
}

// ---------------------------------------------------------------------------
// Comandos y menús
// ---------------------------------------------------------------------------

public Action Cmd_Skills(int client, int args)
{
    if (client == 0)
    {
        return Plugin_Handled;
    }
    if (!g_bLoaded[client])
    {
        ReplyToCommand(client, "[Skills] Tu progreso aún no carga, intenta en unos segundos.");
        return Plugin_Handled;
    }
    ShowMainMenu(client);
    return Plugin_Handled;
}

public Action Cmd_XP(int client, int args)
{
    if (client == 0 || !g_bLoaded[client])
    {
        return Plugin_Handled;
    }
    PrintToChat(client, "\x04[Skills]\x01 Nivel \x05%d\x01 | XP %d/%d | Puntos: \x05%d\x01 | Créditos: \x05$%d",
        g_iLevel[client], g_iXP[client], XPToNext(g_iLevel[client]), g_iPoints[client], g_iCredits[client]);
    return Plugin_Handled;
}

public Action Cmd_GiveXP(int client, int args)
{
    if (client == 0 || args < 1)
    {
        ReplyToCommand(client, "Uso: sm_givexp <cantidad>");
        return Plugin_Handled;
    }
    AddXP(client, GetCmdArgInt(1));
    return Plugin_Handled;
}

public Action Cmd_GiveMoney(int client, int args)
{
    if (client == 0 || args < 1 || !g_bLoaded[client])
    {
        ReplyToCommand(client, "Uso: sm_givemoney <cantidad>");
        return Plugin_Handled;
    }
    g_iCredits[client] += GetCmdArgInt(1);
    SavePlayer(client);
    PrintToChat(client, "\x04[Tienda]\x01 Ahora tienes \x05$%d", g_iCredits[client]);
    return Plugin_Handled;
}

int BranchSpent(int client, int branch)
{
    int total = 0;
    for (int s = 0; s < SK_COUNT; s++)
    {
        if (g_Skills[s].branch == branch)
        {
            total += g_iRank[client][s];
        }
    }
    return total;
}

int TierRequirement(int skill)
{
    return POINTS_PER_TIER * (g_Skills[skill].tier - 1);
}

bool CanBuy(int client, int skill)
{
    return g_bLoaded[client] && g_iPoints[client] > 0
        && g_iRank[client][skill] < g_Skills[skill].maxRank
        && BranchSpent(client, g_Skills[skill].branch) >= TierRequirement(skill);
}

void ShowMainMenu(int client)
{
    Menu menu = new Menu(MenuHandler_Main);
    if (g_iLevel[client] >= MAX_LEVEL)
    {
        menu.SetTitle("ÁRBOL DE HABILIDADES\nNivel %d (MAX)\nPuntos disponibles: %d\n ",
            g_iLevel[client], g_iPoints[client]);
    }
    else
    {
        menu.SetTitle("ÁRBOL DE HABILIDADES\nNivel %d  |  XP %d/%d\nPuntos disponibles: %d\n ",
            g_iLevel[client], g_iXP[client], XPToNext(g_iLevel[client]), g_iPoints[client]);
    }

    char info[8], display[64];
    for (int b = 0; b < BRANCH_COUNT; b++)
    {
        IntToString(b, info, sizeof(info));
        Format(display, sizeof(display), "%s  (%d pts)", g_sBranchName[b], BranchSpent(client, b));
        menu.AddItem(info, display);
    }
    Format(display, sizeof(display), "Tienda de armas  ($%d)", g_iCredits[client]);
    menu.AddItem("shop", display);
    menu.AddItem("reset", "Reiniciar puntos");
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Main(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_Select)
    {
        char info[8];
        menu.GetItem(item, info, sizeof(info));
        if (StrEqual(info, "reset"))
        {
            ResetSkills(client);
            ShowMainMenu(client);
        }
        else if (StrEqual(info, "shop"))
        {
            ShowShopMenu(client);
        }
        else
        {
            ShowBranchMenu(client, StringToInt(info));
        }
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}

void ShowBranchMenu(int client, int branch)
{
    Menu menu = new Menu(MenuHandler_Branch);
    menu.SetTitle("%s  (%d pts invertidos)\nPuntos disponibles: %d\n ",
        g_sBranchName[branch], BranchSpent(client, branch), g_iPoints[client]);

    char info[8], display[128];
    for (int s = 0; s < SK_COUNT; s++)
    {
        if (g_Skills[s].branch != branch)
        {
            continue;
        }
        IntToString(s, info, sizeof(info));
        if (BranchSpent(client, branch) < TierRequirement(s))
        {
            Format(display, sizeof(display), "%s [bloqueado: %d pts en la rama]", g_Skills[s].name, TierRequirement(s));
        }
        else
        {
            Format(display, sizeof(display), "%s [%d/%d] %s",
                g_Skills[s].name, g_iRank[client][s], g_Skills[s].maxRank, g_Skills[s].desc);
        }
        menu.AddItem(info, display, CanBuy(client, s) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
    }
    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Branch(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_Select)
    {
        char info[8];
        menu.GetItem(item, info, sizeof(info));
        int skill = StringToInt(info);
        if (CanBuy(client, skill))
        {
            g_iRank[client][skill]++;
            g_iPoints[client]--;
            ApplySpeed(client);
            SavePlayer(client);
            PrintToChat(client, "\x04[Skills]\x01 %s subió a rango \x05%d", g_Skills[skill].name, g_iRank[client][skill]);
        }
        ShowBranchMenu(client, g_Skills[skill].branch);
    }
    else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
    {
        ShowMainMenu(client);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}

void ResetSkills(int client)
{
    for (int s = 0; s < SK_COUNT; s++)
    {
        g_iPoints[client] += g_iRank[client][s];
        g_iRank[client][s] = 0;
    }
    g_iIncendiaryCount[client] = 0;
    g_iGrenadierCount[client] = 0;
    ApplySpeed(client);
    SavePlayer(client);
    PrintToChat(client, "\x04[Skills]\x01 Puntos reiniciados. Tienes \x05%d\x01 para repartir.", g_iPoints[client]);
}

// ---------------------------------------------------------------------------
// Tienda de armas (munición infinita)
// ---------------------------------------------------------------------------

public Action Cmd_Shop(int client, int args)
{
    if (client == 0)
    {
        return Plugin_Handled;
    }
    if (!g_bLoaded[client])
    {
        ReplyToCommand(client, "[Skills] Tu progreso aún no carga, intenta en unos segundos.");
        return Plugin_Handled;
    }
    ShowShopMenu(client);
    return Plugin_Handled;
}

void ShowShopMenu(int client)
{
    Menu menu = new Menu(MenuHandler_Shop);
    menu.SetTitle("TIENDA DE ARMAS\nMunición infinita\nCréditos: $%d\n ", g_iCredits[client]);

    char info[8], display[64], targetName[MAX_NAME_LENGTH];
    int target = GetShopTarget(client);
    if (target == client)
    {
        strcopy(targetName, sizeof(targetName), "Ti");
    }
    else
    {
        GetClientName(target, targetName, sizeof(targetName));
    }
    Format(display, sizeof(display), "Comprando para: %s", targetName);
    menu.AddItem("target", display);

    for (int c = 0; c < SHOP_CATEGORY_COUNT; c++)
    {
        IntToString(c, info, sizeof(info));
        menu.AddItem(info, g_sShopCategory[c]);
    }
    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Shop(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_Select)
    {
        char info[8];
        menu.GetItem(item, info, sizeof(info));
        if (StrEqual(info, "target"))
        {
            CycleShopTarget(client);
            ShowShopMenu(client);
        }
        else
        {
            ShowShopCategory(client, StringToInt(info));
        }
    }
    else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
    {
        ShowMainMenu(client);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}

void ShowShopCategory(int client, int category)
{
    Menu menu = new Menu(MenuHandler_ShopCategory);
    menu.SetTitle("%s\nCréditos: $%d\n ", g_sShopCategory[category], g_iCredits[client]);

    ShopItem item;
    char info[8], display[64];
    for (int i = 0; i < g_hShopItems.Length; i++)
    {
        g_hShopItems.GetArray(i, item);
        if (item.category != category)
        {
            continue;
        }
        IntToString(i, info, sizeof(info));
        Format(display, sizeof(display), "%s  $%d", item.name, item.price);
        menu.AddItem(info, display, g_iCredits[client] >= item.price ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
    }
    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ShopCategory(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_Select)
    {
        char info[8];
        menu.GetItem(item, info, sizeof(info));
        BuyWeapon(client, StringToInt(info));
    }
    else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
    {
        ShowShopMenu(client);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}

// Quién recibe la compra: uno mismo o un bot superviviente vivo
int GetShopTarget(int client)
{
    int target = GetClientOfUserId(g_iShopTarget[client]);
    if (target == 0 || !IsClientInGame(target) || GetClientTeam(target) != TEAM_SURVIVOR || !IsPlayerAlive(target))
    {
        g_iShopTarget[client] = 0;
        return client;
    }
    return target;
}

void CycleShopTarget(int client)
{
    int current = GetShopTarget(client);
    // Recorre: uno mismo -> bots supervivientes vivos -> uno mismo
    int start = current == client ? 0 : current;
    for (int i = start + 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && IsFakeClient(i) && GetClientTeam(i) == TEAM_SURVIVOR && IsPlayerAlive(i))
        {
            g_iShopTarget[client] = GetClientUserId(i);
            return;
        }
    }
    g_iShopTarget[client] = 0;
}

void BuyWeapon(int client, int index)
{
    ShopItem item;
    g_hShopItems.GetArray(index, item);

    int target = GetShopTarget(client);
    if (!IsHumanSurvivor(client) || !IsAliveSurvivor(target))
    {
        PrintToChat(client, "\x04[Tienda]\x01 El que recibe el arma tiene que estar vivo y de pie.");
        return;
    }
    if (g_iCredits[client] < item.price)
    {
        PrintToChat(client, "\x04[Tienda]\x01 No te alcanza: %s cuesta \x05$%d", item.name, item.price);
        return;
    }

    CheatCommand(target, "give", item.classname);

    char expected[40], classname[40];
    Format(expected, sizeof(expected), "weapon_%s", item.classname);
    int weapon = GetPlayerWeaponSlot(target, 0);
    if (weapon == -1 || !GetEntityClassname(weapon, classname, sizeof(classname)) || !StrEqual(classname, expected))
    {
        PrintToChat(client, "\x04[Tienda]\x01 No se pudo entregar %s, no se cobró nada.", item.name);
        return;
    }

    g_iCredits[client] -= item.price;
    // El arma recién entregada trae el cargador lleno: ese es el tamaño a mantener
    g_iOwnedClip[target] = GetMaxClip(weapon);
    strcopy(g_sOwnedWeapon[target], sizeof(g_sOwnedWeapon[]), expected);
    MakeInfinite(weapon, g_iOwnedClip[target]);
    SavePlayer(client);

    EmitSoundToClient(client, SND_LEVELUP);
    if (target == client)
    {
        PrintHintText(client, "%s con munición infinita", item.name);
        PrintToChat(client, "\x04[Tienda]\x01 Compraste \x05%s\x01 por $%d. Te quedan \x05$%d", item.name, item.price, g_iCredits[client]);
    }
    else
    {
        PrintHintText(client, "%N recibió %s con munición infinita", target, item.name);
        PrintToChat(client, "\x04[Tienda]\x01 Le compraste \x05%s\x01 a %N por $%d. Te quedan \x05$%d", item.name, target, item.price, g_iCredits[client]);
    }
}

bool IsInfiniteWeapon(int weapon)
{
    return weapon > MaxClients && weapon < sizeof(g_iInfiniteRef)
        && g_iInfiniteRef[weapon] == EntIndexToEntRef(weapon);
}

// Tamaño de cargador de cada arma (los valores del juego); si no está en la tabla, usa el cargador actual
int GetMaxClip(int weapon)
{
    static StringMap clips;
    if (clips == null)
    {
        clips = new StringMap();
        clips.SetValue("weapon_smg", 50);
        clips.SetValue("weapon_smg_silenced", 50);
        clips.SetValue("weapon_smg_mp5", 50);
        clips.SetValue("weapon_pumpshotgun", 8);
        clips.SetValue("weapon_shotgun_chrome", 8);
        clips.SetValue("weapon_autoshotgun", 10);
        clips.SetValue("weapon_shotgun_spas", 10);
        clips.SetValue("weapon_rifle", 50);
        clips.SetValue("weapon_rifle_desert", 60);
        clips.SetValue("weapon_rifle_ak47", 40);
        clips.SetValue("weapon_rifle_sg552", 50);
        clips.SetValue("weapon_hunting_rifle", 15);
        clips.SetValue("weapon_sniper_military", 30);
        clips.SetValue("weapon_sniper_scout", 15);
        clips.SetValue("weapon_sniper_awp", 20);
        clips.SetValue("weapon_grenade_launcher", 1);
        clips.SetValue("weapon_rifle_m60", 150);
        clips.SetValue("weapon_pistol", 15);
        clips.SetValue("weapon_pistol_magnum", 8);
    }

    char classname[40];
    GetEntityClassname(weapon, classname, sizeof(classname));
    int clip;
    if (clips.GetValue(classname, clip))
    {
        return clip;
    }
    clip = GetEntProp(weapon, Prop_Send, "m_iClip1");
    return clip > 0 ? clip : 1;
}

void MakeInfinite(int weapon, int clip)
{
    g_iInfiniteRef[weapon] = EntIndexToEntRef(weapon);
    g_iInfiniteClip[weapon] = clip;
    RefillWeapon(weapon);
}

// Al aparecer en un capítulo nuevo, reactivar la munición infinita del arma comprada
void RestoreOwnedWeapon(int client)
{
    if (g_sOwnedWeapon[client][0] == '\0')
    {
        return;
    }

    int weapon = GetPlayerWeaponSlot(client, 0);
    char classname[40];
    if (weapon == -1 || IsInfiniteWeapon(weapon) || !GetEntityClassname(weapon, classname, sizeof(classname)))
    {
        return;
    }
    if (StrEqual(classname, g_sOwnedWeapon[client]))
    {
        MakeInfinite(weapon, g_iOwnedClip[client]);
    }
}

public void Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client == 0 || GetClientTeam(client) != TEAM_SURVIVOR)
    {
        return;
    }

    int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (IsInfiniteWeapon(weapon))
    {
        RefillWeapon(weapon);
        // El juego descuenta la bala después del evento: rellenar también en el siguiente frame
        RequestFrame(Frame_Refill, EntIndexToEntRef(weapon));
    }
}

public void Frame_Refill(int ref)
{
    int weapon = EntRefToEntIndex(ref);
    if (weapon != INVALID_ENT_REFERENCE && IsInfiniteWeapon(weapon))
    {
        RefillWeapon(weapon);
    }
}

void RefillWeapon(int weapon)
{
    SetEntProp(weapon, Prop_Send, "m_iClip1", g_iInfiniteClip[weapon]);
}
