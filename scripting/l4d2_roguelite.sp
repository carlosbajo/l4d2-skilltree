#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <skilltree>

#define SND_CARD            "ui/menu_enter05.wav"
#define VAMPIRE_MAX_HEALTH  70
#define VAMPIRE_HEAL        2
#define GIANT_TANK_XP       100
#define EXPLOSIVE_CHANCE    0.30
#define EXPLOSIVE_RADIUS    160.0
#define EXPLOSIVE_DAMAGE    60.0

enum
{
    CARD_FURY,
    CARD_GOLD,
    CARD_DOUBLE,
    CARD_GIANTS,
    CARD_FRAGILE,
    CARD_COLDBLOOD,
    CARD_VAMPIRE,
    CARD_ARSENAL,
    CARD_EXPLOSIVE,
    CARD_COUNT
}

char g_sCardName[CARD_COUNT][] =
{
    "FURIA", "FIEBRE DEL ORO", "DOBLE O NADA", "CAZAGIGANTES", "FRÁGILES",
    "SANGRE FRÍA", "VAMPIRO", "ARSENAL", "EXPLOSIVO"
};
char g_sCardBuff[CARD_COUNT][] =
{
    "+50% de daño",
    "Créditos x2",
    "XP x2",
    "Los Tanks dan +100 XP",
    "Los comunes mueren de un empujón",
    "Headshots x2 de daño",
    "+2 de vida por kill",
    "Arma T2 con munición infinita cada capítulo",
    "Los comunes pueden explotar al morir"
};
char g_sCardCurse[CARD_COUNT][] =
{
    "No hay botiquines",
    "Hordas 50% más grandes",
    "Recibes +50% de daño",
    "Tanks con +50% de vida",
    "Los comunes corren 30% más rápido",
    "Disparos al cuerpo -30%",
    "Tu vida máxima es 70",
    "Especiales el doble de seguido",
    "Boomers dobles"
};

char g_sArsenalWeapons[][] =
{
    "autoshotgun", "shotgun_spas", "rifle", "rifle_desert", "rifle_ak47", "sniper_military"
};

bool g_bActive[CARD_COUNT];
int g_iActiveCount;

bool g_bPending;
int g_iOffer[3];
int g_iOfferCount;
char g_sOfferMap[64];

StringMap g_hSavedCvars;

public Plugin myinfo =
{
    name = "L4D2 Roguelite",
    author = "Carlos",
    description = "Cartas con ventaja y maldición en cada capítulo",
    version = "0.1.0",
    url = ""
};

public void OnPluginStart()
{
    g_hSavedCvars = new StringMap();

    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("player_left_start_area", Event_LeftStartArea, EventHookMode_PostNoCopy);
    HookEvent("infected_death", Event_InfectedDeath);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("tank_spawn", Event_TankSpawn);
    HookEvent("entity_shoved", Event_EntityShoved);
    HookEvent("player_spawn", Event_PlayerSpawn);

    RegConsoleCmd("sm_cartas", Cmd_Cards, "Elige carta o muestra las activas");
    RegAdminCmd("sm_cartas_reset", Cmd_ResetCards, ADMFLAG_CHEATS, "Quita todas las cartas");

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

public void OnPluginEnd()
{
    ResetCards();
}

public void OnMapStart()
{
    PrecacheSound(SND_CARD, true);
    PrecacheModel("models/props_junk/gascan001a.mdl", true);

    char map[64];
    GetCurrentMap(map, sizeof(map));
    if (StrEqual(map, g_sOfferMap))
    {
        return;  // reinicio del mismo capítulo: se conserva la elección
    }

    // Primer capítulo de una campaña oficial (c#m1_...): empieza una partida nueva
    if (StrContains(map, "m1_") != -1)
    {
        ResetCards();
    }
    strcopy(g_sOfferMap, sizeof(g_sOfferMap), map);
    RollOffer();
}

// ---------------------------------------------------------------------------
// Cartas
// ---------------------------------------------------------------------------

void RollOffer()
{
    int pool[CARD_COUNT];
    int poolSize = 0;
    for (int c = 0; c < CARD_COUNT; c++)
    {
        if (!g_bActive[c])
        {
            pool[poolSize++] = c;
        }
    }

    g_iOfferCount = 0;
    while (g_iOfferCount < 3 && poolSize > 0)
    {
        int pick = GetRandomInt(0, poolSize - 1);
        g_iOffer[g_iOfferCount++] = pool[pick];
        pool[pick] = pool[--poolSize];
    }
    g_bPending = g_iOfferCount > 0;
}

void ChooseCard(int card)
{
    if (!g_bPending)
    {
        return;
    }
    g_bPending = false;
    g_bActive[card] = true;
    g_iActiveCount++;
    ApplyCards();
    OnCardRoundEffects();

    ST_SoundToHumans(SND_CARD);
    ST_PrintToHumans("\x04[Cartas]\x01 Carta \x05%s\x01: %s, pero %s.", g_sCardName[card], g_sCardBuff[card], g_sCardCurse[card]);
}

void ResetCards()
{
    for (int c = 0; c < CARD_COUNT; c++)
    {
        g_bActive[c] = false;
    }
    g_iActiveCount = 0;
    ApplyCards();
}

void ApplyCards()
{
    Skilltree_SetMultipliers(g_bActive[CARD_DOUBLE] ? 2.0 : 1.0, g_bActive[CARD_GOLD] ? 2.0 : 1.0);

    RestoreCvars();
    if (g_bActive[CARD_GOLD])
    {
        ScaleCvar("z_common_limit", 1.5);
        ScaleCvar("z_mob_spawn_min_size", 1.5);
        ScaleCvar("z_mob_spawn_max_size", 1.5);
    }
    if (g_bActive[CARD_FRAGILE])
    {
        ScaleCvar("z_speed", 1.3);
    }
    if (g_bActive[CARD_ARSENAL])
    {
        ScaleCvar("director_special_respawn_interval", 0.5);
    }
    if (g_bActive[CARD_EXPLOSIVE])
    {
        ScaleCvar("z_boomer_limit", 2.0);
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        ApplyMaxHealth(i);
    }
}

// Efectos que se reaplican cada vez que empieza la ronda (o al elegir la carta)
void OnCardRoundEffects()
{
    if (g_bActive[CARD_FURY])
    {
        RemoveUnheldKits("weapon_first_aid_kit_spawn");
        RemoveUnheldKits("weapon_first_aid_kit");
    }
    if (g_bActive[CARD_ARSENAL])
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            GiveArsenalWeapon(i);
        }
    }
}

// ---------------------------------------------------------------------------
// Cvars (se guardan los valores originales para poder restaurarlos)
// ---------------------------------------------------------------------------

void ScaleCvar(const char[] name, float factor)
{
    ConVar cvar = FindConVar(name);
    if (cvar == null)
    {
        return;
    }

    char original[32];
    if (!g_hSavedCvars.GetString(name, original, sizeof(original)))
    {
        cvar.GetString(original, sizeof(original));
        g_hSavedCvars.SetString(name, original);
    }

    float value = StringToFloat(original) * factor;
    if (StrContains(original, ".") == -1)
    {
        cvar.IntValue = RoundToNearest(value);
    }
    else
    {
        cvar.FloatValue = value;
    }
}

void RestoreCvars()
{
    StringMapSnapshot snapshot = g_hSavedCvars.Snapshot();
    char name[64], original[32];
    for (int i = 0; i < snapshot.Length; i++)
    {
        snapshot.GetKey(i, name, sizeof(name));
        g_hSavedCvars.GetString(name, original, sizeof(original));
        ConVar cvar = FindConVar(name);
        if (cvar != null)
        {
            cvar.SetString(original);
        }
    }
    delete snapshot;
    g_hSavedCvars.Clear();
}

// ---------------------------------------------------------------------------
// Efectos
// ---------------------------------------------------------------------------

void ApplyMaxHealth(int client)
{
    if (!ST_IsHumanSurvivor(client) || !IsPlayerAlive(client))
    {
        return;
    }
    int max = g_bActive[CARD_VAMPIRE] ? VAMPIRE_MAX_HEALTH : 100;
    SetEntProp(client, Prop_Data, "m_iMaxHealth", max);
    if (GetClientHealth(client) > max)
    {
        SetEntityHealth(client, max);
    }
}

void RemoveUnheldKits(const char[] classname)
{
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, classname)) != -1)
    {
        if (!HasEntProp(entity, Prop_Send, "m_hOwnerEntity") || GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity") == -1)
        {
            RemoveEntity(entity);
        }
    }
}

void GiveArsenalWeapon(int client)
{
    if (!ST_IsHumanSurvivor(client) || !ST_IsAliveStanding(client))
    {
        return;
    }
    int current = GetPlayerWeaponSlot(client, 0);
    if (current != -1 && Skilltree_IsInfinite(current))
    {
        return;
    }

    ST_CheatCommand(client, "give", g_sArsenalWeapons[GetRandomInt(0, sizeof(g_sArsenalWeapons) - 1)]);
    int weapon = GetPlayerWeaponSlot(client, 0);
    if (weapon != -1)
    {
        Skilltree_MakeInfinite(weapon);
        PrintHintText(client, "ARSENAL: arma con munición infinita");
    }
}

void HealReal(int client, int amount)
{
    int max = GetEntProp(client, Prop_Data, "m_iMaxHealth");
    int health = GetClientHealth(client) + amount;
    SetEntityHealth(client, health > max ? max : health);
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
    SDKHook(client, SDKHook_TraceAttack, OnTraceAttack);
}

public void OnEntityCreated(int entity, const char[] classname)
{
    if (StrEqual(classname, "infected") || StrEqual(classname, "witch"))
    {
        SDKHook(entity, SDKHook_OnTakeDamage, OnTakeDamage);
        SDKHook(entity, SDKHook_TraceAttack, OnTraceAttack);
    }
}

void HookExisting(const char[] classname)
{
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, classname)) != -1)
    {
        OnEntityCreated(entity, classname);
    }
}

bool IsInfectedVictim(int victim)
{
    return victim > MaxClients || GetClientTeam(victim) == ST_TEAM_INFECTED;
}

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    float mult = 1.0;
    if (g_bActive[CARD_DOUBLE] && victim <= MaxClients && ST_IsHumanSurvivor(victim))
    {
        mult *= 1.5;
    }
    if (g_bActive[CARD_FURY] && ST_IsHumanSurvivor(attacker) && IsInfectedVictim(victim))
    {
        mult *= 1.5;
    }
    if (mult == 1.0)
    {
        return Plugin_Continue;
    }
    damage *= mult;
    return Plugin_Changed;
}

public Action OnTraceAttack(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &ammotype, int hitbox, int hitgroup)
{
    if (!g_bActive[CARD_COLDBLOOD] || !ST_IsHumanSurvivor(attacker) || !IsInfectedVictim(victim))
    {
        return Plugin_Continue;
    }
    damage *= hitgroup == 1 ? 2.0 : 0.7;
    return Plugin_Changed;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    CreateTimer(1.0, Timer_RoundEffects, _, TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(3.0, Timer_ShowOffer, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_RoundEffects(Handle timer)
{
    OnCardRoundEffects();
    return Plugin_Stop;
}

public Action Timer_ShowOffer(Handle timer)
{
    if (!g_bPending)
    {
        return Plugin_Stop;
    }
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            ShowOfferMenu(i);
            PrintHintText(i, "Elige una carta para este capítulo (!cartas)");
        }
    }
    return Plugin_Stop;
}

public void Event_LeftStartArea(Event event, const char[] name, bool dontBroadcast)
{
    if (g_bPending)
    {
        ST_PrintToHumans("\x04[Cartas]\x01 Saliste sin elegir: se toma la primera carta.");
        ChooseCard(g_iOffer[0]);
    }
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (ST_IsHumanSurvivor(client))
    {
        ApplyMaxHealth(client);
    }
}

public void Event_InfectedDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("attacker"));
    if (!ST_IsHumanSurvivor(client))
    {
        return;
    }
    if (g_bActive[CARD_VAMPIRE] && ST_IsAliveStanding(client))
    {
        HealReal(client, VAMPIRE_HEAL);
    }

    int infected = event.GetInt("infected_id");
    if (g_bActive[CARD_EXPLOSIVE] && infected > MaxClients && IsValidEntity(infected) && GetRandomFloat() < EXPLOSIVE_CHANCE)
    {
        // Diferido: la explosión puede matar a otros y disparar este mismo evento
        DataPack pack = new DataPack();
        float pos[3];
        GetEntPropVector(infected, Prop_Send, "m_vecOrigin", pos);
        pack.WriteCell(GetClientUserId(client));
        pack.WriteFloatArray(pos, 3);
        RequestFrame(Frame_Explode, pack);
    }
}

public void Frame_Explode(DataPack pack)
{
    pack.Reset();
    int client = GetClientOfUserId(pack.ReadCell());
    float pos[3];
    pack.ReadFloatArray(pos, 3);
    delete pack;

    if (client == 0)
    {
        return;
    }
    ST_SpawnExplosionFX(pos);

    float other[3];
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "infected")) != -1)
    {
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", other);
        if (GetVectorDistance(pos, other) <= EXPLOSIVE_RADIUS)
        {
            SDKHooks_TakeDamage(entity, client, client, EXPLOSIVE_DAMAGE, DMG_BLAST);
        }
    }
    for (int i = 1; i <= MaxClients; i++)
    {
        if (ST_IsInfected(i) && IsPlayerAlive(i))
        {
            GetClientAbsOrigin(i, other);
            if (GetVectorDistance(pos, other) <= EXPLOSIVE_RADIUS)
            {
                SDKHooks_TakeDamage(i, client, client, EXPLOSIVE_DAMAGE, DMG_BLAST);
            }
        }
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
    if (g_bActive[CARD_VAMPIRE] && ST_IsAliveStanding(client))
    {
        HealReal(client, VAMPIRE_HEAL);
    }
    if (g_bActive[CARD_GIANTS] && ST_GetZombieClass(victim) == ST_ZC_TANK)
    {
        Skilltree_AddXP(client, GIANT_TANK_XP);
        PrintCenterText(client, "CAZAGIGANTES  +%d XP", GIANT_TANK_XP);
    }
}

public void Event_TankSpawn(Event event, const char[] name, bool dontBroadcast)
{
    if (g_bActive[CARD_GIANTS])
    {
        CreateTimer(0.2, Timer_BuffTank, event.GetInt("userid"), TIMER_FLAG_NO_MAPCHANGE);
    }
}

public Action Timer_BuffTank(Handle timer, int userid)
{
    int tank = GetClientOfUserId(userid);
    if (tank != 0 && IsPlayerAlive(tank))
    {
        int health = RoundToNearest(GetClientHealth(tank) * 1.5);
        SetEntProp(tank, Prop_Data, "m_iMaxHealth", health);
        SetEntityHealth(tank, health);
    }
    return Plugin_Stop;
}

public void Event_EntityShoved(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bActive[CARD_FRAGILE])
    {
        return;
    }
    int client = GetClientOfUserId(event.GetInt("attacker"));
    int entity = event.GetInt("entityid");
    if (!ST_IsHumanSurvivor(client) || entity <= MaxClients || !IsValidEntity(entity))
    {
        return;
    }

    char classname[16];
    GetEntityClassname(entity, classname, sizeof(classname));
    if (StrEqual(classname, "infected"))
    {
        SDKHooks_TakeDamage(entity, client, client, 10000.0, DMG_CLUB);
    }
}

// ---------------------------------------------------------------------------
// Menús
// ---------------------------------------------------------------------------

public Action Cmd_Cards(int client, int args)
{
    if (client == 0)
    {
        return Plugin_Handled;
    }
    if (g_bPending)
    {
        ShowOfferMenu(client);
    }
    else
    {
        ShowActiveMenu(client);
    }
    return Plugin_Handled;
}

public Action Cmd_ResetCards(int client, int args)
{
    ResetCards();
    ReplyToCommand(client, "[Cartas] Todas las cartas quitadas.");
    return Plugin_Handled;
}

void ShowOfferMenu(int client)
{
    Menu menu = new Menu(MenuHandler_Offer);
    menu.SetTitle("ELIGE UNA CARTA\nCartas activas: %d\n ", g_iActiveCount);

    char info[8], display[128];
    for (int i = 0; i < g_iOfferCount; i++)
    {
        int card = g_iOffer[i];
        IntToString(card, info, sizeof(info));
        Format(display, sizeof(display), "%s\n   + %s\n   - %s", g_sCardName[card], g_sCardBuff[card], g_sCardCurse[card]);
        menu.AddItem(info, display);
    }
    menu.ExitButton = false;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Offer(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_Select)
    {
        char info[8];
        menu.GetItem(item, info, sizeof(info));
        ChooseCard(StringToInt(info));
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}

void ShowActiveMenu(int client)
{
    Menu menu = new Menu(MenuHandler_Active);
    menu.SetTitle("CARTAS ACTIVAS (%d)\nSe reinician al empezar otra campaña\n ", g_iActiveCount);

    char display[128];
    for (int c = 0; c < CARD_COUNT; c++)
    {
        if (g_bActive[c])
        {
            Format(display, sizeof(display), "%s: + %s / - %s", g_sCardName[c], g_sCardBuff[c], g_sCardCurse[c]);
            menu.AddItem("", display, ITEMDRAW_DISABLED);
        }
    }
    if (g_iActiveCount == 0)
    {
        menu.AddItem("", "Ninguna todavía", ITEMDRAW_DISABLED);
    }
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Active(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}
