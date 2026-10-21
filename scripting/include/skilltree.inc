#if defined _skilltree_included
 #endinput
#endif
#define _skilltree_included

#include <sdktools>

#define ST_TEAM_SURVIVOR    2
#define ST_TEAM_INFECTED    3
#define ST_ZC_TANK          8

// ---------------------------------------------------------------------------
// API del plugin principal (l4d2_skilltree)
// ---------------------------------------------------------------------------

/** Nivel del jugador (1 si aún no carga). */
native int Skilltree_GetLevel(int client);

/** Suma XP y créditos (aplica los multiplicadores activos). */
native void Skilltree_AddXP(int client, int amount);

native int Skilltree_GetCredits(int client);

/** Suma (o resta, con negativo) créditos sin tocar la XP. */
native void Skilltree_AddCredits(int client, int amount);

/** Multiplicadores globales de XP y créditos (1.0 = normal). */
native void Skilltree_SetMultipliers(float xp, float credits);

/** Marca un arma con munición infinita sin recargar. */
native void Skilltree_MakeInfinite(int weapon);

native bool Skilltree_IsInfinite(int weapon);

// ---------------------------------------------------------------------------
// Forwards entre módulos
// ---------------------------------------------------------------------------

/** l4d2_elites: murió un especial élite. */
forward void Elites_OnEliteKilled(int victim, int attacker, int affix);

/** l4d2_elites: murió un jefe (Tank especial o Witch Reina). */
forward void Elites_OnBossKilled(int victim, int attacker, int bossType);

/** l4d2_loot: un jugador recogió un arma con rareza. */
forward void Loot_OnPickup(int client, int weapon, int rarity);

public SharedPlugin __pl_skilltree =
{
    name = "skilltree",
    file = "l4d2_skilltree.smx",
    required = 1,
};

// ---------------------------------------------------------------------------
// Helpers comunes
// ---------------------------------------------------------------------------

stock bool ST_IsSurvivor(int client)
{
    return client >= 1 && client <= MaxClients && IsClientInGame(client) && GetClientTeam(client) == ST_TEAM_SURVIVOR;
}

stock bool ST_IsHumanSurvivor(int client)
{
    return ST_IsSurvivor(client) && !IsFakeClient(client);
}

stock bool ST_IsInfected(int client)
{
    return client >= 1 && client <= MaxClients && IsClientInGame(client) && GetClientTeam(client) == ST_TEAM_INFECTED;
}

stock bool ST_IsIncapped(int client)
{
    return GetEntProp(client, Prop_Send, "m_isIncapacitated") != 0;
}

stock bool ST_IsAliveStanding(int client)
{
    return ST_IsSurvivor(client) && IsPlayerAlive(client) && !ST_IsIncapped(client);
}

stock int ST_GetZombieClass(int client)
{
    return GetEntProp(client, Prop_Send, "m_zombieClass");
}

/** Atrapado por un Hunter, Smoker, Jockey o Charger. */
stock bool ST_IsPinned(int client)
{
    return GetEntPropEnt(client, Prop_Send, "m_pounceAttacker") > 0
        || GetEntPropEnt(client, Prop_Send, "m_tongueOwner") > 0
        || GetEntPropEnt(client, Prop_Send, "m_pummelAttacker") > 0
        || GetEntPropEnt(client, Prop_Send, "m_carryAttacker") > 0
        || GetEntPropEnt(client, Prop_Send, "m_jockeyAttacker") > 0;
}

/** Primer humano en el servidor, para ejecutar comandos de cheat (z_spawn_old, give...). */
stock int ST_FindAnyHuman()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            return i;
        }
    }
    return 0;
}

stock void ST_CheatCommand(int client, const char[] command, const char[] args)
{
    int flags = GetCommandFlags(command);
    SetCommandFlags(command, flags & ~FCVAR_CHEAT);
    FakeClientCommand(client, "%s %s", command, args);
    SetCommandFlags(command, flags);
}

/** Brillo a través de paredes (m_iGlowType 3 = constante). type 0 lo quita. */
stock void ST_SetGlow(int entity, int type, int range, int r, int g, int b)
{
    SetEntProp(entity, Prop_Send, "m_iGlowType", type);
    SetEntProp(entity, Prop_Send, "m_nGlowRange", range);
    SetEntProp(entity, Prop_Send, "m_glowColorOverride", r + (g << 8) + (b << 16));
}

stock float ST_GetTempHealth(int client)
{
    static ConVar decay;
    if (decay == null)
    {
        decay = FindConVar("pain_pills_decay_rate");
    }
    float buffer = GetEntPropFloat(client, Prop_Send, "m_healthBuffer");
    float elapsed = GetGameTime() - GetEntPropFloat(client, Prop_Send, "m_healthBufferTime");
    float temp = buffer - elapsed * decay.FloatValue;
    return temp > 0.0 ? temp : 0.0;
}

stock void ST_AddTempHealth(int client, float amount)
{
    if (!ST_IsAliveStanding(client))
    {
        return;
    }
    float temp = ST_GetTempHealth(client);
    float room = float(GetEntProp(client, Prop_Data, "m_iMaxHealth") - GetClientHealth(client)) - temp;
    if (room <= 0.0)
    {
        return;
    }
    SetEntPropFloat(client, Prop_Send, "m_healthBuffer", temp + (amount < room ? amount : room));
    SetEntPropFloat(client, Prop_Send, "m_healthBufferTime", GetGameTime());
}

stock void ST_PrintToHumans(const char[] format, any ...)
{
    char buffer[256];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            SetGlobalTransTarget(i);
            VFormat(buffer, sizeof(buffer), format, 2);
            PrintToChat(i, "%s", buffer);
        }
    }
}

stock void ST_HintToHumans(const char[] format, any ...)
{
    char buffer[256];
    VFormat(buffer, sizeof(buffer), format, 2);
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            PrintHintText(i, "%s", buffer);
        }
    }
}

stock void ST_SoundToHumans(const char[] sample)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            EmitSoundToClient(i, sample);
        }
    }
}

/** Rompe un bidón de gasolina en la posición: deja un charco de fuego. */
stock void ST_SpawnFire(const float pos[3])
{
    int can = CreateEntityByName("prop_physics");
    if (can == -1)
    {
        return;
    }
    DispatchKeyValue(can, "model", "models/props_junk/gascan001a.mdl");
    DispatchSpawn(can);
    TeleportEntity(can, pos, NULL_VECTOR, NULL_VECTOR);
    AcceptEntityInput(can, "Break");
}

/** Explosión solo visual y de sonido (spawnflag 1 = sin daño). */
stock void ST_SpawnExplosionFX(const float pos[3])
{
    int ent = CreateEntityByName("env_explosion");
    if (ent == -1)
    {
        return;
    }
    DispatchKeyValue(ent, "iMagnitude", "0");
    DispatchKeyValue(ent, "spawnflags", "1");
    DispatchSpawn(ent);
    TeleportEntity(ent, pos, NULL_VECTOR, NULL_VECTOR);
    AcceptEntityInput(ent, "Explode");
    AcceptEntityInput(ent, "Kill");
}
