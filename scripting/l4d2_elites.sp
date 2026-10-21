#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <skilltree>

#define SND_ELITE       "ui/beep07.wav"
#define SND_BOSS        "ui/critical_event_1.wav"
#define MODEL_GASCAN    "models/props_junk/gascan001a.mdl"

#define ELITE_XP        20
#define BOSS_XP         150
#define TOXIC_RADIUS    250.0
#define TOXIC_DAMAGE    3.0
#define TOXIC_TICKS     6
#define SPLIT_MINIS     2
#define QUEEN_MINIONS   2

enum
{
    AFFIX_NONE,
    AFFIX_FIRE,
    AFFIX_ARMOR,
    AFFIX_VAMPIRE,
    AFFIX_TOXIC,
    AFFIX_SWIFT,
    AFFIX_GIANT,
    AFFIX_COUNT
}

char g_sAffixName[AFFIX_COUNT][] = { "", "Ígneo", "Blindado", "Vampiro", "Tóxico", "Veloz", "Gigante" };
char g_sAffixDesc[AFFIX_COUNT][] =
{
    "",
    "inmune al fuego, te quema y deja fuego al morir",
    "-65% de daño salvo por la espalda",
    "se cura con el daño que hace",
    "deja una nube tóxica al morir",
    "40% más rápido",
    "más grande y con mucha más vida"
};
int g_iAffixColor[AFFIX_COUNT][3] =
{
    { 0, 0, 0 }, { 255, 110, 0 }, { 120, 160, 255 }, { 200, 0, 30 }, { 40, 255, 40 }, { 255, 255, 0 }, { 180, 0, 255 }
};

enum
{
    BOSS_NONE,
    BOSS_FIRE_TANK,
    BOSS_SPLIT_TANK,
    BOSS_SUMMON_TANK,
    BOSS_WITCH_QUEEN,
    BOSS_COUNT
}

char g_sBossName[BOSS_COUNT][] = { "", "Tank de Fuego", "Tank Divisor", "Tank Invocador", "Witch Reina" };
char g_sBossDesc[BOSS_COUNT][] =
{
    "",
    "inmune al fuego, sus golpes queman",
    "al morir se divide en dos",
    "invoca hordas sin parar",
    "trae a sus damas de compañía"
};
int g_iBossColor[BOSS_COUNT][3] = { { 0, 0, 0 }, { 255, 40, 0 }, { 0, 220, 255 }, { 170, 0, 255 }, { 255, 0, 200 } };

char g_sClassName[][] = { "", "Smoker", "Boomer", "Hunter", "Spitter", "Jockey", "Charger", "", "Tank" };

ConVar g_cvEliteChance;
ConVar g_cvBossChance;
ConVar g_cvQueenChance;

GlobalForward g_fwdEliteKilled;
GlobalForward g_fwdBossKilled;

int g_iAffix[MAXPLAYERS + 1];
int g_iBoss[MAXPLAYERS + 1];
char g_sOriginalName[MAXPLAYERS + 1][MAX_NAME_LENGTH];

int g_iForceAffix;     // pruebas: el siguiente especial sale con este afijo
int g_iForceBoss;      // pruebas: el siguiente Tank/Witch sale como este jefe
int g_iPendingMinis;
float g_fSplitPos[3];
int g_iQueenRef = INVALID_ENT_REFERENCE;
int g_iPendingMinions;
float g_fQueenPos[3];

public Plugin myinfo =
{
    name = "L4D2 Elites",
    author = "Carlos",
    description = "Especiales élite con afijos, Tanks jefe y Witch Reina",
    version = "0.1.0",
    url = ""
};

public void OnPluginStart()
{
    g_cvEliteChance = CreateConVar("l4d2_elite_chance", "0.20", "Probabilidad de que un especial sea élite", _, true, 0.0, true, 1.0);
    g_cvBossChance = CreateConVar("l4d2_elite_tank_chance", "0.40", "Probabilidad de que un Tank sea jefe", _, true, 0.0, true, 1.0);
    g_cvQueenChance = CreateConVar("l4d2_elite_queen_chance", "0.20", "Probabilidad de que una Witch sea Reina", _, true, 0.0, true, 1.0);

    g_fwdEliteKilled = new GlobalForward("Elites_OnEliteKilled", ET_Ignore, Param_Cell, Param_Cell, Param_Cell);
    g_fwdBossKilled = new GlobalForward("Elites_OnBossKilled", ET_Ignore, Param_Cell, Param_Cell, Param_Cell);

    HookEvent("player_spawn", Event_PlayerSpawn);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("tank_spawn", Event_TankSpawn);
    HookEvent("witch_spawn", Event_WitchSpawn);
    HookEvent("witch_killed", Event_WitchKilled);
    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

    RegAdminCmd("sm_spawnelite", Cmd_SpawnElite, ADMFLAG_CHEATS, "sm_spawnelite [1-6] - Aparece un especial élite (1 Ígneo, 2 Blindado, 3 Vampiro, 4 Tóxico, 5 Veloz, 6 Gigante)");
    RegAdminCmd("sm_spawnboss", Cmd_SpawnBoss, ADMFLAG_CHEATS, "sm_spawnboss [1-4] - Aparece un jefe (1 Tank de Fuego, 2 Divisor, 3 Invocador, 4 Witch Reina)");

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            OnClientPutInServer(i);
        }
    }
}

public void OnMapStart()
{
    PrecacheSound(SND_ELITE, true);
    PrecacheSound(SND_BOSS, true);
    PrecacheModel(MODEL_GASCAN, true);
    g_iPendingMinis = 0;
    g_iPendingMinions = 0;
    g_iQueenRef = INVALID_ENT_REFERENCE;
}

public void OnClientPutInServer(int client)
{
    g_iAffix[client] = AFFIX_NONE;
    g_iBoss[client] = BOSS_NONE;
    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    g_iPendingMinis = 0;
    g_iPendingMinions = 0;
    g_iQueenRef = INVALID_ENT_REFERENCE;
}

// ---------------------------------------------------------------------------
// Especiales élite
// ---------------------------------------------------------------------------

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    if (!ST_IsInfected(client))
    {
        return;
    }
    ClearSpecial(client);
    CreateTimer(0.2, Timer_SetupSpecial, userid, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_SetupSpecial(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0 || !IsPlayerAlive(client) || g_iBoss[client] != BOSS_NONE)
    {
        return Plugin_Stop;
    }
    int zclass = ST_GetZombieClass(client);
    if (zclass < 1 || zclass > 6)
    {
        return Plugin_Stop;
    }
    if (g_iForceAffix != AFFIX_NONE)
    {
        MakeElite(client, g_iForceAffix);
        g_iForceAffix = AFFIX_NONE;
    }
    else if (GetRandomFloat() < g_cvEliteChance.FloatValue)
    {
        MakeElite(client, GetRandomInt(AFFIX_FIRE, AFFIX_COUNT - 1));
    }
    return Plugin_Stop;
}

void MakeElite(int client, int affix)
{
    g_iAffix[client] = affix;
    int zclass = ST_GetZombieClass(client);

    ApplyLook(client, g_iAffixColor[affix]);
    ScaleHealth(client, affix == AFFIX_GIANT ? 2.5 : 1.5);
    if (affix == AFFIX_SWIFT)
    {
        SetEntPropFloat(client, Prop_Send, "m_flLaggedMovementValue", 1.4);
    }
    if (affix == AFFIX_GIANT && HasEntProp(client, Prop_Send, "m_flModelScale"))
    {
        SetEntPropFloat(client, Prop_Send, "m_flModelScale", 1.3);
    }

    char newName[MAX_NAME_LENGTH];
    Format(newName, sizeof(newName), "%s %s", g_sClassName[zclass], g_sAffixName[affix]);
    Rename(client, newName);

    ST_SoundToHumans(SND_ELITE);
    ST_PrintToHumans("\x04[Élite]\x01 \x05%s %s\x01: %s.", g_sClassName[zclass], g_sAffixName[affix], g_sAffixDesc[affix]);
}

void ApplyLook(int client, const int color[3])
{
    ST_SetGlow(client, 3, 1500, color[0], color[1], color[2]);
    SetEntityRenderMode(client, RENDER_TRANSCOLOR);
    SetEntityRenderColor(client, color[0], color[1], color[2], 255);
}

void ScaleHealth(int client, float factor)
{
    int health = RoundToNearest(GetClientHealth(client) * factor);
    SetEntProp(client, Prop_Data, "m_iMaxHealth", health);
    SetEntityHealth(client, health);
}

void Rename(int client, const char[] newName)
{
    if (g_sOriginalName[client][0] == '\0')
    {
        GetClientName(client, g_sOriginalName[client], sizeof(g_sOriginalName[]));
    }
    SetClientName(client, newName);
}

void ClearSpecial(int client)
{
    g_iAffix[client] = AFFIX_NONE;
    g_iBoss[client] = BOSS_NONE;
    if (g_sOriginalName[client][0] != '\0' && IsClientInGame(client))
    {
        SetClientName(client, g_sOriginalName[client]);
    }
    g_sOriginalName[client][0] = '\0';
    if (IsClientInGame(client))
    {
        ST_SetGlow(client, 0, 0, 0, 0, 0);
        SetEntityRenderColor(client, 255, 255, 255, 255);
        if (HasEntProp(client, Prop_Send, "m_flModelScale"))
        {
            SetEntPropFloat(client, Prop_Send, "m_flModelScale", 1.0);
        }
    }
}

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    // Daño recibido por un élite o jefe
    if (ST_IsInfected(victim))
    {
        bool fireImmune = g_iAffix[victim] == AFFIX_FIRE || g_iBoss[victim] == BOSS_FIRE_TANK;
        if (fireImmune && (damagetype & DMG_BURN))
        {
            return Plugin_Handled;
        }
        if (g_iAffix[victim] == AFFIX_ARMOR && ST_IsSurvivor(attacker) && !IsBehind(attacker, victim))
        {
            damage *= 0.35;
            return Plugin_Changed;
        }
        return Plugin_Continue;
    }

    // Daño que hace un élite o jefe a un superviviente
    if (ST_IsSurvivor(victim) && ST_IsInfected(attacker))
    {
        if (g_iAffix[attacker] == AFFIX_VAMPIRE && IsPlayerAlive(attacker))
        {
            int max = GetEntProp(attacker, Prop_Data, "m_iMaxHealth");
            int health = GetClientHealth(attacker) + RoundToNearest(damage * 3.0);
            SetEntityHealth(attacker, health > max ? max : health);
        }
        if (g_iAffix[attacker] == AFFIX_FIRE || g_iBoss[attacker] == BOSS_FIRE_TANK)
        {
            IgniteEntity(victim, 2.0);
        }
    }
    return Plugin_Continue;
}

// ¿El atacante está a la espalda de la víctima?
bool IsBehind(int attacker, int victim)
{
    float angles[3], facing[3], victimPos[3], attackerPos[3], toAttacker[3];
    GetClientEyeAngles(victim, angles);
    angles[0] = 0.0;
    GetAngleVectors(angles, facing, NULL_VECTOR, NULL_VECTOR);
    GetClientAbsOrigin(victim, victimPos);
    GetClientAbsOrigin(attacker, attackerPos);
    MakeVectorFromPoints(victimPos, attackerPos, toAttacker);
    toAttacker[2] = 0.0;
    NormalizeVector(toAttacker, toAttacker);
    return GetVectorDotProduct(facing, toAttacker) < -0.3;
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (!ST_IsInfected(victim))
    {
        return;
    }
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int affix = g_iAffix[victim];
    int boss = g_iBoss[victim];
    if (affix == AFFIX_NONE && boss == BOSS_NONE)
    {
        return;
    }

    float pos[3];
    GetClientAbsOrigin(victim, pos);

    if (affix == AFFIX_FIRE)
    {
        pos[2] += 10.0;
        ST_SpawnFire(pos);
    }
    else if (affix == AFFIX_TOXIC)
    {
        StartToxicCloud(pos);
    }
    if (boss == BOSS_SPLIT_TANK)
    {
        SpawnMinis(pos);
    }

    if (ST_IsHumanSurvivor(attacker))
    {
        int xp = boss != BOSS_NONE ? BOSS_XP : ELITE_XP;
        Skilltree_AddXP(attacker, xp);
        PrintCenterText(attacker, "%s ABATIDO  +%d XP", boss != BOSS_NONE ? "JEFE" : "ÉLITE", xp);
    }

    if (boss != BOSS_NONE)
    {
        Call_StartForward(g_fwdBossKilled);
        Call_PushCell(victim);
        Call_PushCell(attacker);
        Call_PushCell(boss);
        Call_Finish();
    }
    else
    {
        Call_StartForward(g_fwdEliteKilled);
        Call_PushCell(victim);
        Call_PushCell(attacker);
        Call_PushCell(affix);
        Call_Finish();
    }
    ClearSpecial(victim);
}

void StartToxicCloud(const float pos[3])
{
    DataPack pack;
    CreateDataTimer(1.0, Timer_ToxicCloud, pack, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    pack.WriteFloatArray(pos, 3);
    pack.WriteCell(TOXIC_TICKS);

    float other[3];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (ST_IsHumanSurvivor(i))
        {
            GetClientAbsOrigin(i, other);
            if (GetVectorDistance(pos, other) <= TOXIC_RADIUS * 2.0)
            {
                PrintHintText(i, "¡Nube tóxica! Aléjate");
            }
        }
    }
}

public Action Timer_ToxicCloud(Handle timer, DataPack pack)
{
    pack.Reset();
    float pos[3];
    pack.ReadFloatArray(pos, 3);
    DataPackPos ticksPos = pack.Position;
    int ticks = pack.ReadCell();

    float other[3];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (ST_IsAliveStanding(i))
        {
            GetClientAbsOrigin(i, other);
            if (GetVectorDistance(pos, other) <= TOXIC_RADIUS)
            {
                SDKHooks_TakeDamage(i, 0, 0, TOXIC_DAMAGE, DMG_POISON);
            }
        }
    }

    if (--ticks <= 0)
    {
        return Plugin_Stop;
    }
    pack.Position = ticksPos;
    pack.WriteCell(ticks);
    return Plugin_Continue;
}

// ---------------------------------------------------------------------------
// Tanks jefe
// ---------------------------------------------------------------------------

public void Event_TankSpawn(Event event, const char[] name, bool dontBroadcast)
{
    CreateTimer(0.3, Timer_SetupTank, event.GetInt("userid"), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_SetupTank(Handle timer, int userid)
{
    int tank = GetClientOfUserId(userid);
    if (tank == 0 || !IsPlayerAlive(tank))
    {
        return Plugin_Stop;
    }

    // Mini Tanks que salen del Tank Divisor
    if (g_iPendingMinis > 0)
    {
        g_iPendingMinis--;
        float pos[3];
        pos = g_fSplitPos;
        pos[0] += GetRandomFloat(-80.0, 80.0);
        pos[1] += GetRandomFloat(-80.0, 80.0);
        pos[2] += 20.0;
        TeleportEntity(tank, pos, NULL_VECTOR, NULL_VECTOR);
        ScaleHealth(tank, 0.3);
        if (HasEntProp(tank, Prop_Send, "m_flModelScale"))
        {
            SetEntPropFloat(tank, Prop_Send, "m_flModelScale", 0.75);
        }
        Rename(tank, "Mini Tank");
        return Plugin_Stop;
    }

    if (g_iForceBoss >= BOSS_FIRE_TANK && g_iForceBoss <= BOSS_SUMMON_TANK)
    {
        MakeBossTank(tank, g_iForceBoss);
        g_iForceBoss = BOSS_NONE;
    }
    else if (GetRandomFloat() < g_cvBossChance.FloatValue)
    {
        MakeBossTank(tank, GetRandomInt(BOSS_FIRE_TANK, BOSS_SUMMON_TANK));
    }
    return Plugin_Stop;
}

void MakeBossTank(int tank, int boss)
{
    g_iBoss[tank] = boss;
    ApplyLook(tank, g_iBossColor[boss]);
    ScaleHealth(tank, 1.5);
    Rename(tank, g_sBossName[boss]);
    AnnounceBoss(boss);

    if (boss == BOSS_FIRE_TANK)
    {
        CreateTimer(10.0, Timer_FireTrail, GetClientUserId(tank), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }
    else if (boss == BOSS_SUMMON_TANK)
    {
        CreateTimer(15.0, Timer_Summon, GetClientUserId(tank), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }
}

void AnnounceBoss(int boss)
{
    ST_SoundToHumans(SND_BOSS);
    ST_HintToHumans("¡%s! %s", g_sBossName[boss], g_sBossDesc[boss]);
    ST_PrintToHumans("\x04[Jefe]\x01 Apareció \x05%s\x01: %s.", g_sBossName[boss], g_sBossDesc[boss]);
}

bool IsBossAlive(int userid, int boss)
{
    int tank = GetClientOfUserId(userid);
    return tank != 0 && IsPlayerAlive(tank) && g_iBoss[tank] == boss;
}

public Action Timer_FireTrail(Handle timer, int userid)
{
    if (!IsBossAlive(userid, BOSS_FIRE_TANK))
    {
        return Plugin_Stop;
    }
    float pos[3];
    GetClientAbsOrigin(GetClientOfUserId(userid), pos);
    pos[2] += 10.0;
    ST_SpawnFire(pos);
    return Plugin_Continue;
}

public Action Timer_Summon(Handle timer, int userid)
{
    if (!IsBossAlive(userid, BOSS_SUMMON_TANK))
    {
        return Plugin_Stop;
    }
    int human = ST_FindAnyHuman();
    if (human != 0)
    {
        ST_CheatCommand(human, "z_spawn_old", "mob auto");
        ST_PrintToHumans("\x04[Jefe]\x01 ¡El Tank Invocador llama a la horda!");
    }
    return Plugin_Continue;
}

void SpawnMinis(const float pos[3])
{
    int human = ST_FindAnyHuman();
    if (human == 0)
    {
        return;
    }
    g_fSplitPos = pos;
    g_iPendingMinis = SPLIT_MINIS;
    for (int i = 0; i < SPLIT_MINIS; i++)
    {
        ST_CheatCommand(human, "z_spawn_old", "tank auto");
    }
    ST_HintToHumans("¡El Tank Divisor se partió en dos!");
    // Si el juego no logra crear alguno, no dejar el contador colgado
    CreateTimer(5.0, Timer_ClearPendingMinis, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_ClearPendingMinis(Handle timer)
{
    g_iPendingMinis = 0;
    return Plugin_Stop;
}

// ---------------------------------------------------------------------------
// Witch Reina
// ---------------------------------------------------------------------------

public void Event_WitchSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int witch = event.GetInt("witchid");
    if (witch <= MaxClients || !IsValidEntity(witch))
    {
        return;
    }

    if (g_iPendingMinions > 0)
    {
        g_iPendingMinions--;
        float pos[3];
        pos = g_fQueenPos;
        pos[0] += GetRandomFloat(-120.0, 120.0);
        pos[1] += GetRandomFloat(-120.0, 120.0);
        TeleportEntity(witch, pos, NULL_VECTOR, NULL_VECTOR);
        return;
    }

    bool forced = g_iForceBoss == BOSS_WITCH_QUEEN;
    if (EntRefToEntIndex(g_iQueenRef) == INVALID_ENT_REFERENCE && (forced || GetRandomFloat() < g_cvQueenChance.FloatValue))
    {
        g_iForceBoss = BOSS_NONE;
        RequestFrame(Frame_MakeQueen, EntIndexToEntRef(witch));
    }
}

public void Frame_MakeQueen(int ref)
{
    int witch = EntRefToEntIndex(ref);
    if (witch == INVALID_ENT_REFERENCE)
    {
        return;
    }

    g_iQueenRef = ref;
    int color[3];
    color = g_iBossColor[BOSS_WITCH_QUEEN];
    ST_SetGlow(witch, 3, 1500, color[0], color[1], color[2]);
    SetEntityRenderMode(witch, RENDER_TRANSCOLOR);
    SetEntityRenderColor(witch, color[0], color[1], color[2], 255);
    SetEntProp(witch, Prop_Data, "m_iHealth", GetEntProp(witch, Prop_Data, "m_iHealth") * 3);
    if (HasEntProp(witch, Prop_Send, "m_flModelScale"))
    {
        SetEntPropFloat(witch, Prop_Send, "m_flModelScale", 1.25);
    }
    AnnounceBoss(BOSS_WITCH_QUEEN);

    int human = ST_FindAnyHuman();
    if (human != 0)
    {
        GetEntPropVector(witch, Prop_Send, "m_vecOrigin", g_fQueenPos);
        g_iPendingMinions = QUEEN_MINIONS;
        for (int i = 0; i < QUEEN_MINIONS; i++)
        {
            ST_CheatCommand(human, "z_spawn_old", "witch auto");
        }
        CreateTimer(5.0, Timer_ClearPendingMinions, _, TIMER_FLAG_NO_MAPCHANGE);
    }
}

public Action Timer_ClearPendingMinions(Handle timer)
{
    g_iPendingMinions = 0;
    return Plugin_Stop;
}

public void Event_WitchKilled(Event event, const char[] name, bool dontBroadcast)
{
    int witch = event.GetInt("witchid");
    if (witch <= MaxClients || EntIndexToEntRef(witch) != g_iQueenRef)
    {
        return;
    }
    g_iQueenRef = INVALID_ENT_REFERENCE;

    int attacker = GetClientOfUserId(event.GetInt("userid"));
    if (ST_IsHumanSurvivor(attacker))
    {
        Skilltree_AddXP(attacker, BOSS_XP);
        PrintCenterText(attacker, "WITCH REINA ABATIDA  +%d XP", BOSS_XP);
    }

    Call_StartForward(g_fwdBossKilled);
    Call_PushCell(witch);
    Call_PushCell(attacker);
    Call_PushCell(BOSS_WITCH_QUEEN);
    Call_Finish();
}

// ---------------------------------------------------------------------------
// Comandos de prueba
// ---------------------------------------------------------------------------

public Action Cmd_SpawnElite(int client, int args)
{
    if (client == 0)
    {
        return Plugin_Handled;
    }
    int affix = args >= 1 ? GetCmdArgInt(1) : GetRandomInt(AFFIX_FIRE, AFFIX_COUNT - 1);
    if (affix < AFFIX_FIRE || affix >= AFFIX_COUNT)
    {
        ReplyToCommand(client, "Uso: sm_spawnelite [1-6]");
        return Plugin_Handled;
    }
    char classes[][] = { "smoker", "boomer", "hunter", "spitter", "jockey", "charger" };
    g_iForceAffix = affix;
    char args2[32];
    Format(args2, sizeof(args2), "%s auto", classes[GetRandomInt(0, sizeof(classes) - 1)]);
    ST_CheatCommand(client, "z_spawn_old", args2);
    return Plugin_Handled;
}

public Action Cmd_SpawnBoss(int client, int args)
{
    if (client == 0)
    {
        return Plugin_Handled;
    }
    int boss = args >= 1 ? GetCmdArgInt(1) : GetRandomInt(BOSS_FIRE_TANK, BOSS_WITCH_QUEEN);
    if (boss < BOSS_FIRE_TANK || boss >= BOSS_COUNT)
    {
        ReplyToCommand(client, "Uso: sm_spawnboss [1-4]");
        return Plugin_Handled;
    }
    g_iForceBoss = boss;
    ST_CheatCommand(client, "z_spawn_old", boss == BOSS_WITCH_QUEEN ? "witch auto" : "tank auto");
    return Plugin_Handled;
}
