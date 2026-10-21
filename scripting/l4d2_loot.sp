#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <skilltree>

#define SND_DROP        "ui/gift_drop.wav"
#define SND_PICKUP      "ui/gift_pickup.wav"
#define SND_LEGENDARY   "ui/pickup_secret01.wav"

enum
{
    RARITY_NONE,
    RARITY_COMMON,
    RARITY_RARE,
    RARITY_EPIC,
    RARITY_LEGENDARY,
    RARITY_COUNT
}

char g_sRarityName[RARITY_COUNT][] = { "", "COMÚN", "RARA", "ÉPICA", "LEGENDARIA" };
char g_sRarityDesc[RARITY_COUNT][] =
{
    "",
    "+10% de daño",
    "+25% de daño",
    "+40% de daño y balas incendiarias",
    "+60% de daño, roba vida y munición infinita"
};
float g_fRarityDamage[RARITY_COUNT] = { 1.0, 1.10, 1.25, 1.40, 1.60 };
int g_iRarityWeight[RARITY_COUNT] = { 0, 55, 30, 12, 3 };
int g_iRarityColor[RARITY_COUNT][3] =
{
    { 0, 0, 0 }, { 220, 220, 220 }, { 40, 120, 255 }, { 170, 60, 255 }, { 255, 180, 0 }
};

char g_sLootWeapons[][] =
{
    "smg", "smg_silenced", "pumpshotgun", "shotgun_chrome", "autoshotgun", "shotgun_spas",
    "rifle", "rifle_desert", "rifle_ak47", "hunting_rifle", "sniper_military"
};

StringMap g_hWeaponNames;
GlobalForward g_fwdPickup;

int g_iRarity[2049];
int g_iRarityRef[2049];

// Para reactivar la rareza al aparecer en el siguiente capítulo
char g_sOwnedLoot[MAXPLAYERS + 1][40];
int g_iOwnedRarity[MAXPLAYERS + 1];

bool g_bEliteHandled[MAXPLAYERS + 1];
int g_iHandledWitchRef = INVALID_ENT_REFERENCE;

ConVar g_cvSpecialChance;
ConVar g_cvWitchChance;

public Plugin myinfo =
{
    name = "L4D2 Loot",
    author = "Carlos",
    description = "Armas con rareza que sueltan los infectados especiales",
    version = "0.1.0",
    url = ""
};

public void OnPluginStart()
{
    g_cvSpecialChance = CreateConVar("l4d2_loot_special_chance", "0.12", "Probabilidad de botín de un especial normal", _, true, 0.0, true, 1.0);
    g_cvWitchChance = CreateConVar("l4d2_loot_witch_chance", "0.40", "Probabilidad de botín de una Witch", _, true, 0.0, true, 1.0);

    g_fwdPickup = new GlobalForward("Loot_OnPickup", ET_Ignore, Param_Cell, Param_Cell, Param_Cell);

    g_hWeaponNames = new StringMap();
    g_hWeaponNames.SetString("weapon_smg", "Uzi");
    g_hWeaponNames.SetString("weapon_smg_silenced", "Uzi silenciada");
    g_hWeaponNames.SetString("weapon_pumpshotgun", "Escopeta de bombeo");
    g_hWeaponNames.SetString("weapon_shotgun_chrome", "Escopeta cromada");
    g_hWeaponNames.SetString("weapon_autoshotgun", "Escopeta automática");
    g_hWeaponNames.SetString("weapon_shotgun_spas", "SPAS-12");
    g_hWeaponNames.SetString("weapon_rifle", "M16");
    g_hWeaponNames.SetString("weapon_rifle_desert", "Desert Rifle");
    g_hWeaponNames.SetString("weapon_rifle_ak47", "AK-47");
    g_hWeaponNames.SetString("weapon_hunting_rifle", "Rifle de caza");
    g_hWeaponNames.SetString("weapon_sniper_military", "Rifle militar");
    g_hWeaponNames.SetString("weapon_rifle_m60", "M60");

    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("witch_killed", Event_WitchKilled);
    HookEvent("player_spawn", Event_PlayerSpawn);

    RegAdminCmd("sm_spawnloot", Cmd_SpawnLoot, ADMFLAG_CHEATS, "sm_spawnloot [1-4] - Suelta un arma con rareza donde apuntas (1 Común ... 4 Legendaria)");

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            OnClientPutInServer(i);
        }
    }
    HookExisting("infected");
    HookExisting("witch");
}

public void OnMapStart()
{
    PrecacheSound(SND_DROP, true);
    PrecacheSound(SND_PICKUP, true);
    PrecacheSound(SND_LEGENDARY, true);
    for (int i = 0; i < sizeof(g_iRarityRef); i++)
    {
        g_iRarityRef[i] = INVALID_ENT_REFERENCE;
    }
}

public void OnClientConnected(int client)
{
    g_sOwnedLoot[client][0] = '\0';
    g_iOwnedRarity[client] = RARITY_NONE;
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
    SDKHook(client, SDKHook_WeaponEquipPost, OnWeaponEquip);
    SDKHook(client, SDKHook_WeaponDropPost, OnWeaponDrop);
}

public void OnEntityCreated(int entity, const char[] classname)
{
    if (StrEqual(classname, "infected") || StrEqual(classname, "witch"))
    {
        SDKHook(entity, SDKHook_OnTakeDamage, OnTakeDamage);
    }
}

void HookExisting(const char[] classname)
{
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, classname)) != -1)
    {
        SDKHook(entity, SDKHook_OnTakeDamage, OnTakeDamage);
    }
}

int GetRarity(int weapon)
{
    if (weapon <= MaxClients || weapon >= sizeof(g_iRarity) || g_iRarityRef[weapon] != EntIndexToEntRef(weapon))
    {
        return RARITY_NONE;
    }
    return g_iRarity[weapon];
}

void SetRarity(int weapon, int rarity)
{
    g_iRarity[weapon] = rarity;
    g_iRarityRef[weapon] = EntIndexToEntRef(weapon);
}

void GetWeaponName(int weapon, char[] name, int maxlen)
{
    char classname[40];
    GetEntityClassname(weapon, classname, sizeof(classname));
    if (!g_hWeaponNames.GetString(classname, name, maxlen))
    {
        strcopy(name, maxlen, classname);
    }
}

// ---------------------------------------------------------------------------
// Drops
// ---------------------------------------------------------------------------

int RollRarity(int minRarity)
{
    int total = 0;
    for (int r = minRarity; r < RARITY_COUNT; r++)
    {
        total += g_iRarityWeight[r];
    }
    int roll = GetRandomInt(1, total);
    for (int r = minRarity; r < RARITY_COUNT; r++)
    {
        roll -= g_iRarityWeight[r];
        if (roll <= 0)
        {
            return r;
        }
    }
    return minRarity;
}

void SpawnLoot(const float origin[3], int rarity)
{
    char classname[40];
    if (rarity == RARITY_LEGENDARY && GetRandomInt(1, 4) == 1)
    {
        strcopy(classname, sizeof(classname), "weapon_rifle_m60");
    }
    else
    {
        Format(classname, sizeof(classname), "weapon_%s", g_sLootWeapons[GetRandomInt(0, sizeof(g_sLootWeapons) - 1)]);
    }

    int weapon = CreateEntityByName(classname);
    if (weapon == -1)
    {
        return;
    }
    DispatchSpawn(weapon);
    float pos[3];
    pos = origin;
    pos[2] += 20.0;
    TeleportEntity(weapon, pos, NULL_VECTOR, NULL_VECTOR);
    if (HasEntProp(weapon, Prop_Send, "m_iExtraPrimaryAmmo"))
    {
        SetEntProp(weapon, Prop_Send, "m_iExtraPrimaryAmmo", 250);
    }

    SetRarity(weapon, rarity);
    ST_SetGlow(weapon, 3, 2000, g_iRarityColor[rarity][0], g_iRarityColor[rarity][1], g_iRarityColor[rarity][2]);

    ST_SoundToHumans(SND_DROP);
    if (rarity >= RARITY_EPIC)
    {
        char name[32];
        GetWeaponName(weapon, name, sizeof(name));
        ST_PrintToHumans("\x04[Botín]\x01 Cayó \x05%s %s\x01: %s.", name, g_sRarityName[rarity], g_sRarityDesc[rarity]);
    }
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (!ST_IsInfected(victim) || !ST_IsSurvivor(GetClientOfUserId(event.GetInt("attacker"))))
    {
        return;
    }
    // Se decide en el siguiente frame: si era élite o jefe, l4d2_elites ya avisó y ese botín es mejor
    DataPack pack = new DataPack();
    float pos[3];
    GetClientAbsOrigin(victim, pos);
    pack.WriteCell(victim);
    pack.WriteCell(ST_GetZombieClass(victim));
    pack.WriteFloatArray(pos, 3);
    RequestFrame(Frame_SpecialDrop, pack);
}

public void Frame_SpecialDrop(DataPack pack)
{
    pack.Reset();
    int victim = pack.ReadCell();
    int zclass = pack.ReadCell();
    float pos[3];
    pack.ReadFloatArray(pos, 3);
    delete pack;

    if (g_bEliteHandled[victim])
    {
        g_bEliteHandled[victim] = false;
        return;
    }
    if (zclass == ST_ZC_TANK)
    {
        SpawnLoot(pos, RollRarity(RARITY_EPIC));
    }
    else if (GetRandomFloat() < g_cvSpecialChance.FloatValue)
    {
        SpawnLoot(pos, RollRarity(RARITY_COMMON));
    }
}

public void Event_WitchKilled(Event event, const char[] name, bool dontBroadcast)
{
    int witch = event.GetInt("witchid");
    if (witch <= MaxClients || !IsValidEntity(witch))
    {
        return;
    }
    DataPack pack = new DataPack();
    float pos[3];
    GetEntPropVector(witch, Prop_Send, "m_vecOrigin", pos);
    pack.WriteCell(EntIndexToEntRef(witch));
    pack.WriteFloatArray(pos, 3);
    RequestFrame(Frame_WitchDrop, pack);
}

public void Frame_WitchDrop(DataPack pack)
{
    pack.Reset();
    int ref = pack.ReadCell();
    float pos[3];
    pack.ReadFloatArray(pos, 3);
    delete pack;

    if (ref != g_iHandledWitchRef && GetRandomFloat() < g_cvWitchChance.FloatValue)
    {
        SpawnLoot(pos, RollRarity(RARITY_RARE));
    }
}

public void Elites_OnEliteKilled(int victim, int attacker, int affix)
{
    g_bEliteHandled[victim] = true;
    if (GetRandomFloat() < 0.5)
    {
        float pos[3];
        GetClientAbsOrigin(victim, pos);
        SpawnLoot(pos, RollRarity(RARITY_RARE));
    }
}

public void Elites_OnBossKilled(int victim, int attacker, int bossType)
{
    float pos[3];
    if (victim <= MaxClients)
    {
        g_bEliteHandled[victim] = true;
        GetClientAbsOrigin(victim, pos);
    }
    else
    {
        g_iHandledWitchRef = EntIndexToEntRef(victim);
        GetEntPropVector(victim, Prop_Send, "m_vecOrigin", pos);
    }
    SpawnLoot(pos, GetRandomFloat() < 0.4 ? RARITY_LEGENDARY : RARITY_EPIC);
}

// ---------------------------------------------------------------------------
// Recoger, soltar y efectos
// ---------------------------------------------------------------------------

public void OnWeaponEquip(int client, int weapon)
{
    int rarity = GetRarity(weapon);
    if (rarity == RARITY_NONE || !ST_IsSurvivor(client))
    {
        return;
    }
    ST_SetGlow(weapon, 0, 0, 0, 0, 0);

    char classname[40];
    GetEntityClassname(weapon, classname, sizeof(classname));
    strcopy(g_sOwnedLoot[client], sizeof(g_sOwnedLoot[]), classname);
    g_iOwnedRarity[client] = rarity;
    ApplyPickupEffects(client, weapon, rarity);

    if (!IsFakeClient(client))
    {
        char name[32];
        GetWeaponName(weapon, name, sizeof(name));
        PrintHintText(client, "%s %s\n%s", name, g_sRarityName[rarity], g_sRarityDesc[rarity]);
        EmitSoundToClient(client, rarity == RARITY_LEGENDARY ? SND_LEGENDARY : SND_PICKUP);
    }

    Call_StartForward(g_fwdPickup);
    Call_PushCell(client);
    Call_PushCell(weapon);
    Call_PushCell(rarity);
    Call_Finish();
}

void ApplyPickupEffects(int client, int weapon, int rarity)
{
    if (rarity == RARITY_EPIC)
    {
        // El jugador tiene que tener el arma activa para recibir la mejora
        RequestFrame(Frame_Incendiary, GetClientUserId(client));
    }
    else if (rarity == RARITY_LEGENDARY)
    {
        Skilltree_MakeInfinite(weapon);
    }
}

public void Frame_Incendiary(int userid)
{
    int client = GetClientOfUserId(userid);
    if (client != 0 && ST_IsAliveStanding(client))
    {
        ST_CheatCommand(client, "upgrade_add", "INCENDIARY_AMMO");
    }
}

public void OnWeaponDrop(int client, int weapon)
{
    int rarity = GetRarity(weapon);
    if (rarity != RARITY_NONE)
    {
        ST_SetGlow(weapon, 3, 2000, g_iRarityColor[rarity][0], g_iRarityColor[rarity][1], g_iRarityColor[rarity][2]);
        if (client >= 1 && client <= MaxClients)
        {
            g_sOwnedLoot[client][0] = '\0';
            g_iOwnedRarity[client] = RARITY_NONE;
        }
    }
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    if (ST_IsSurvivor(client) && g_iOwnedRarity[client] != RARITY_NONE)
    {
        CreateTimer(0.6, Timer_RestoreLoot, userid, TIMER_FLAG_NO_MAPCHANGE);
    }
}

// El juego recrea las armas al cambiar de capítulo: devolverle la rareza si sigue teniendo esa arma
public Action Timer_RestoreLoot(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0)
    {
        return Plugin_Stop;
    }
    int weapon = GetPlayerWeaponSlot(client, 0);
    if (weapon == -1 || GetRarity(weapon) != RARITY_NONE)
    {
        return Plugin_Stop;
    }
    char classname[40];
    GetEntityClassname(weapon, classname, sizeof(classname));
    if (StrEqual(classname, g_sOwnedLoot[client]))
    {
        SetRarity(weapon, g_iOwnedRarity[client]);
        ApplyPickupEffects(client, weapon, g_iOwnedRarity[client]);
    }
    return Plugin_Stop;
}

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    if (!ST_IsSurvivor(attacker) || (victim <= MaxClients && GetClientTeam(victim) != ST_TEAM_INFECTED))
    {
        return Plugin_Continue;
    }
    int weapon = GetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon");
    int rarity = GetRarity(weapon);
    if (rarity == RARITY_NONE)
    {
        return Plugin_Continue;
    }

    damage *= g_fRarityDamage[rarity];
    if (rarity == RARITY_LEGENDARY)
    {
        ST_AddTempHealth(attacker, damage * 0.03);
    }
    return Plugin_Changed;
}

public Action Cmd_SpawnLoot(int client, int args)
{
    if (client == 0)
    {
        return Plugin_Handled;
    }
    int rarity = args >= 1 ? GetCmdArgInt(1) : RollRarity(RARITY_COMMON);
    if (rarity < RARITY_COMMON || rarity >= RARITY_COUNT)
    {
        ReplyToCommand(client, "Uso: sm_spawnloot [1-4]");
        return Plugin_Handled;
    }

    float eyePos[3], eyeAng[3], pos[3];
    GetClientEyePosition(client, eyePos);
    GetClientEyeAngles(client, eyeAng);
    Handle trace = TR_TraceRayFilterEx(eyePos, eyeAng, MASK_SOLID, RayType_Infinite, TraceFilter_Self, client);
    TR_GetEndPosition(pos, trace);
    delete trace;
    SpawnLoot(pos, rarity);
    return Plugin_Handled;
}

public bool TraceFilter_Self(int entity, int mask, int self)
{
    return entity != self;
}
