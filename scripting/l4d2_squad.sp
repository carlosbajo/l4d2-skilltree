#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <skilltree>

#define MEDIC_RADIUS    450.0

// Comandos de CommandABot (VScript)
#define BOT_CMD_ATTACK  0
#define BOT_CMD_MOVE    1
#define BOT_CMD_RETREAT 2
#define BOT_CMD_RESET   3

enum
{
    CLASS_MEDIC,
    CLASS_MARKSMAN,
    CLASS_DEMO,
    CLASS_GUARD,
    CLASS_COUNT
}

char g_sClassName[CLASS_COUNT][] = { "Médico", "Tirador", "Demoledor", "Guardián" };

// Ajustes de IA de los bots: se aplican solo si el cvar existe y se restauran al descargar
char g_sBotCvars[][][] =
{
    { "sb_allow_shoot_through_survivors", "1" },
    { "sb_vomit_blind_time", "2" },
    { "sb_combat_saccade_speed", "2500" },
    { "sb_normal_saccade_speed", "1500" },
    { "sb_max_team_melee_weapons", "2" },
    { "sb_temp_health_consider_factor", "0.5" },
    { "sb_sidestep_for_horde", "1" }
};

StringMap g_hSavedCvars;
int g_iClass[MAXPLAYERS + 1] = { -1, ... };
char g_sBaseName[MAXPLAYERS + 1][MAX_NAME_LENGTH];
int g_iDemoTimer[MAXPLAYERS + 1];
int g_iScriptEnt = INVALID_ENT_REFERENCE;
bool g_bMapRunning;

public Plugin myinfo =
{
    name = "L4D2 Squad",
    author = "Carlos",
    description = "Bots con clases que escalan con tu nivel, órdenes e IA mejorada",
    version = "0.1.0",
    url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    g_bMapRunning = late;
    return APLRes_Success;
}

public void OnPluginStart()
{
    g_hSavedCvars = new StringMap();

    HookEvent("player_spawn", Event_PlayerSpawn);
    HookEvent("bot_player_replace", Event_BotReplace);

    RegConsoleCmd("sm_escuadron", Cmd_Squad, "Muestra las clases de tus bots");
    RegConsoleCmd("sm_ordenes", Cmd_Orders, "Da órdenes a los bots");

    CreateTimer(3.0, Timer_Medic, _, TIMER_REPEAT);
    CreateTimer(10.0, Timer_Demo, _, TIMER_REPEAT);

    ApplyBotCvars();

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            OnClientPutInServer(i);
            if (IsFakeClient(i) && GetClientTeam(i) == ST_TEAM_SURVIVOR)
            {
                AssignClass(i);
            }
        }
    }
    HookExisting("infected");
    HookExisting("witch");
}

public void OnPluginEnd()
{
    StringMapSnapshot snapshot = g_hSavedCvars.Snapshot();
    char name[64], original[32];
    for (int i = 0; i < snapshot.Length; i++)
    {
        snapshot.GetKey(i, name, sizeof(name));
        g_hSavedCvars.GetString(name, original, sizeof(original));
        FindConVar(name).SetString(original);
    }
    delete snapshot;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && g_sBaseName[i][0] != '\0')
        {
            SetClientName(i, g_sBaseName[i]);
        }
    }
}

public void OnMapStart()
{
    g_bMapRunning = true;
    g_iScriptEnt = INVALID_ENT_REFERENCE;
}

public void OnMapEnd()
{
    g_bMapRunning = false;
}

public void OnConfigsExecuted()
{
    ApplyBotCvars();
}

void ApplyBotCvars()
{
    for (int i = 0; i < sizeof(g_sBotCvars); i++)
    {
        ConVar cvar = FindConVar(g_sBotCvars[i][0]);
        if (cvar == null)
        {
            continue;
        }
        char original[32];
        if (!g_hSavedCvars.GetString(g_sBotCvars[i][0], original, sizeof(original)))
        {
            cvar.GetString(original, sizeof(original));
            g_hSavedCvars.SetString(g_sBotCvars[i][0], original);
        }
        cvar.SetString(g_sBotCvars[i][1]);
    }
}

public void OnClientPutInServer(int client)
{
    g_iClass[client] = -1;
    g_sBaseName[client][0] = '\0';
    g_iDemoTimer[client] = 0;
    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

// ---------------------------------------------------------------------------
// Clases
// ---------------------------------------------------------------------------

int GetSquadTier()
{
    int best = 1;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (ST_IsHumanSurvivor(i))
        {
            int level = Skilltree_GetLevel(i);
            if (level > best)
            {
                best = level;
            }
        }
    }
    int tier = best / 10;
    return tier > 5 ? 5 : tier;
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client != 0 && IsFakeClient(client) && GetClientTeam(client) == ST_TEAM_SURVIVOR)
    {
        AssignClass(client);
    }
}

// Un humano tomó el control de un bot o lo devolvió: el bot recupera su clase
public void Event_BotReplace(Event event, const char[] name, bool dontBroadcast)
{
    int bot = GetClientOfUserId(event.GetInt("bot"));
    if (bot != 0)
    {
        AssignClass(bot);
    }
}

void AssignClass(int bot)
{
    // La clase depende del personaje, así cada uno conserva la suya entre capítulos
    int character = GetEntProp(bot, Prop_Send, "m_survivorCharacter");
    g_iClass[bot] = character % CLASS_COUNT;

    if (g_sBaseName[bot][0] == '\0')
    {
        GetClientName(bot, g_sBaseName[bot], sizeof(g_sBaseName[]));
    }
    char newName[MAX_NAME_LENGTH];
    Format(newName, sizeof(newName), "%s (%s)", g_sBaseName[bot], g_sClassName[g_iClass[bot]]);
    SetClientName(bot, newName);
}

bool IsSquadBot(int client, int squadClass)
{
    return client >= 1 && client <= MaxClients && IsClientInGame(client) && IsFakeClient(client)
        && GetClientTeam(client) == ST_TEAM_SURVIVOR && g_iClass[client] == squadClass;
}

public Action Timer_Medic(Handle timer)
{
    int tier = GetSquadTier();
    for (int medic = 1; medic <= MaxClients; medic++)
    {
        if (!IsSquadBot(medic, CLASS_MEDIC) || !ST_IsAliveStanding(medic))
        {
            continue;
        }
        float origin[3], pos[3];
        GetClientAbsOrigin(medic, origin);
        for (int target = 1; target <= MaxClients; target++)
        {
            if (ST_IsAliveStanding(target))
            {
                GetClientAbsOrigin(target, pos);
                if (GetVectorDistance(origin, pos) <= MEDIC_RADIUS)
                {
                    ST_AddTempHealth(target, float(1 + tier));
                }
            }
        }
    }
    return Plugin_Continue;
}

public Action Timer_Demo(Handle timer)
{
    int interval = 90 - 10 * GetSquadTier();
    for (int bot = 1; bot <= MaxClients; bot++)
    {
        if (!IsSquadBot(bot, CLASS_DEMO) || !ST_IsAliveStanding(bot))
        {
            continue;
        }
        g_iDemoTimer[bot] += 10;
        if (g_iDemoTimer[bot] >= interval && GetPlayerWeaponSlot(bot, 0) != -1)
        {
            g_iDemoTimer[bot] = 0;
            ST_CheatCommand(bot, "upgrade_add", GetSquadTier() >= 3 ? "EXPLOSIVE_AMMO" : "INCENDIARY_AMMO");
        }
    }
    return Plugin_Continue;
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

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    // Tirador: más daño a infectados
    if (IsSquadBot(attacker, CLASS_MARKSMAN) && (victim > MaxClients || GetClientTeam(victim) == ST_TEAM_INFECTED))
    {
        damage *= 1.2 + 0.1 * GetSquadTier();
        return Plugin_Changed;
    }
    // Guardián: recibe menos daño
    if (IsSquadBot(victim, CLASS_GUARD))
    {
        float mult = 0.8 - 0.1 * GetSquadTier();
        damage *= mult < 0.3 ? 0.3 : mult;
        return Plugin_Changed;
    }
    return Plugin_Continue;
}

public Action Cmd_Squad(int client, int args)
{
    if (client == 0)
    {
        return Plugin_Handled;
    }
    int tier = GetSquadTier();
    Menu menu = new Menu(MenuHandler_Squad);
    menu.SetTitle("ESCUADRÓN  (rango %d/5, sube cada 10 niveles)\n ", tier);

    char display[128];
    for (int bot = 1; bot <= MaxClients; bot++)
    {
        if (!IsClientInGame(bot) || !IsFakeClient(bot) || GetClientTeam(bot) != ST_TEAM_SURVIVOR || g_iClass[bot] == -1)
        {
            continue;
        }
        switch (g_iClass[bot])
        {
            case CLASS_MEDIC:    Format(display, sizeof(display), "%s: cura +%d vida temporal cada 3s a quien esté cerca", g_sBaseName[bot], 1 + tier);
            case CLASS_MARKSMAN: Format(display, sizeof(display), "%s: +%d%% de daño", g_sBaseName[bot], 20 + 10 * tier);
            case CLASS_DEMO:     Format(display, sizeof(display), "%s: munición %s cada %ds", g_sBaseName[bot], tier >= 3 ? "explosiva" : "incendiaria", 90 - 10 * tier);
            case CLASS_GUARD:    Format(display, sizeof(display), "%s: -%d%% de daño recibido", g_sBaseName[bot], 20 + 10 * tier);
        }
        Format(display, sizeof(display), "[%s] %s", g_sClassName[g_iClass[bot]], display);
        menu.AddItem("", display, ITEMDRAW_DISABLED);
    }
    menu.AddItem("orders", "Dar órdenes");
    menu.Display(client, MENU_TIME_FOREVER);
    return Plugin_Handled;
}

public int MenuHandler_Squad(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_Select)
    {
        ShowOrdersMenu(client);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Órdenes (CommandABot de VScript)
// ---------------------------------------------------------------------------

public Action Cmd_Orders(int client, int args)
{
    if (client != 0)
    {
        ShowOrdersMenu(client);
    }
    return Plugin_Handled;
}

void ShowOrdersMenu(int client)
{
    Menu menu = new Menu(MenuHandler_Orders);
    menu.SetTitle("ÓRDENES AL ESCUADRÓN\n ");
    menu.AddItem("follow", "Síganme (comportamiento normal)");
    menu.AddItem("hold", "Vengan aquí");
    menu.AddItem("goto", "Vayan a donde apunto");
    menu.AddItem("attack", "Ataquen al especial (apuntado o el más cercano)");
    menu.AddItem("retreat", "Retirada del especial más cercano");
    menu.Display(client, 20);
}

public int MenuHandler_Orders(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_Select)
    {
        char info[16];
        menu.GetItem(item, info, sizeof(info));
        GiveOrder(client, info);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}

void GiveOrder(int client, const char[] order)
{
    if (!ST_IsSurvivor(client) || !IsPlayerAlive(client))
    {
        return;
    }

    float pos[3];
    int target = 0;
    int cmd;
    if (StrEqual(order, "follow"))
    {
        cmd = BOT_CMD_RESET;
    }
    else if (StrEqual(order, "hold"))
    {
        cmd = BOT_CMD_MOVE;
        GetClientAbsOrigin(client, pos);
    }
    else if (StrEqual(order, "goto"))
    {
        cmd = BOT_CMD_MOVE;
        GetAimPoint(client, pos, target);
    }
    else
    {
        cmd = StrEqual(order, "attack") ? BOT_CMD_ATTACK : BOT_CMD_RETREAT;
        GetAimPoint(client, pos, target);
        if (!ST_IsInfected(target) || !IsPlayerAlive(target) || cmd == BOT_CMD_RETREAT)
        {
            target = FindNearestSpecial(client);
        }
        if (target == 0)
        {
            PrintToChat(client, "\x04[Escuadrón]\x01 No hay especiales a la vista.");
            return;
        }
    }

    char code[256];
    int count = 0;
    for (int bot = 1; bot <= MaxClients; bot++)
    {
        if (!IsClientInGame(bot) || !IsFakeClient(bot) || !ST_IsAliveStanding(bot))
        {
            continue;
        }
        if (cmd == BOT_CMD_MOVE)
        {
            Format(code, sizeof(code), "CommandABot({cmd = %d, bot = GetPlayerFromUserID(%d), pos = Vector(%.1f, %.1f, %.1f)})",
                cmd, GetClientUserId(bot), pos[0], pos[1], pos[2]);
        }
        else if (cmd == BOT_CMD_RESET)
        {
            Format(code, sizeof(code), "CommandABot({cmd = %d, bot = GetPlayerFromUserID(%d)})", cmd, GetClientUserId(bot));
        }
        else
        {
            Format(code, sizeof(code), "CommandABot({cmd = %d, bot = GetPlayerFromUserID(%d), target = GetPlayerFromUserID(%d)})",
                cmd, GetClientUserId(bot), GetClientUserId(target));
        }
        RunVScript(code);
        count++;
    }
    PrintToChat(client, "\x04[Escuadrón]\x01 Orden enviada a %d bot(s).", count);
}

void GetAimPoint(int client, float pos[3], int &hit)
{
    float eyePos[3], eyeAng[3];
    GetClientEyePosition(client, eyePos);
    GetClientEyeAngles(client, eyeAng);
    Handle trace = TR_TraceRayFilterEx(eyePos, eyeAng, MASK_SHOT, RayType_Infinite, TraceFilter_Self, client);
    TR_GetEndPosition(pos, trace);
    hit = TR_GetEntityIndex(trace);
    delete trace;
}

public bool TraceFilter_Self(int entity, int mask, int self)
{
    return entity != self;
}

int FindNearestSpecial(int client)
{
    float origin[3], pos[3];
    GetClientAbsOrigin(client, origin);
    int best = 0;
    float bestDist = 2000.0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (ST_IsInfected(i) && IsPlayerAlive(i) && !GetEntProp(i, Prop_Send, "m_isGhost"))
        {
            GetClientAbsOrigin(i, pos);
            float dist = GetVectorDistance(origin, pos);
            if (dist < bestDist)
            {
                bestDist = dist;
                best = i;
            }
        }
    }
    return best;
}

void RunVScript(const char[] code)
{
    if (!g_bMapRunning)
    {
        return;
    }
    int entity = EntRefToEntIndex(g_iScriptEnt);
    if (entity == INVALID_ENT_REFERENCE)
    {
        entity = CreateEntityByName("logic_script");
        if (entity == -1)
        {
            return;
        }
        DispatchSpawn(entity);
        g_iScriptEnt = EntIndexToEntRef(entity);
    }
    SetVariantString(code);
    AcceptEntityInput(entity, "RunScriptCode");
}
