# L4D2 Skill Tree

Plugins de SourceMod para renovar Left 4 Dead 2 jugando solo: XP, árbol de habilidades, tienda, cartas roguelite,
especiales élite, jefes, bots con clases, botín con rareza y logros.

| Plugin | Qué hace |
|---|---|
| `l4d2_skilltree` | Core: XP, niveles, habilidades, créditos, tienda, HUD y la API (`scripting/include/skilltree.inc`) |
| `l4d2_roguelite` | Una carta por capítulo (ventaja + maldición) que se acumula durante la campaña |
| `l4d2_elites` | Especiales élite con afijos, Tanks jefe y Witch Reina |
| `l4d2_squad` | Bots con clase que escala con tu nivel, órdenes e IA mejorada |
| `l4d2_loot` | Armas con rareza que sueltan los especiales |
| `l4d2_achievements` | Logros propios con recompensa |
| `l4d2_feel` | Hitsounds, cámara lenta, esquivar y selector de campaña |

Los módulos dependen del core; cada uno se puede quitar moviendo su `.smx` a `plugins/disabled/`.

## Compilar

```bash
./build.sh   # compila scripting/*.sp a plugins/*.smx
```

La primera vez descarga SourceMod (`SM_TAG`, por defecto 1.12 estable) desde GitHub Releases en `.sourcemod/`
para usar `spcomp`. El servidor debe correr la misma versión de SourceMod (o una más nueva).

## Servidor local

Servidor dedicado en `~/l4d2server`, descargado con SteamCMD (`~/steamcmd`). En Linux, la plataforma
tiene que forzarse *antes* del login (con anonymous falla si se pone después):

```bash
~/steamcmd/steamcmd.sh +force_install_dir ~/l4d2server +@sSteamCmdForcePlatformType windows \
    +login anonymous +app_update 222860 +quit
~/steamcmd/steamcmd.sh +force_install_dir ~/l4d2server +@sSteamCmdForcePlatformType linux \
    +login anonymous +app_update 222860 validate +quit
mkdir -p ~/.steam/sdk32 && ln -sf ~/steamcmd/linux32/steamclient.so ~/.steam/sdk32/steamclient.so
```

```bash
./build.sh && ./server/install.sh   # Metamod 1.12 + SourceMod 1.12 estables (1ª vez), admin, server.cfg y plugin
./server/ctl.sh install-service     # servicio systemd de usuario (1ª vez)
ln -sf "$PWD/server/ctl.sh" ~/.local/bin/l4d2
```

Día a día:

```bash
l4d2 start | stop | restart | status
l4d2 logs                        # consola en vivo (Ctrl+C sale, el servidor sigue)
l4d2 cmd changelevel c2m1_highway
l4d2 deploy                      # compila + instala + recarga todos los plugins, sin reiniciar
```

En el juego: `connect 127.0.0.1:27016` (puerto 27016 porque el cliente de L4D2 ocupa el 27015).
`./server/start.sh` sigue sirviendo para correrlo a mano en primer plano.

El progreso se guarda en SQLite (`storage-local`, configurado por defecto en `databases.cfg`).

## Comandos

| Comando | Descripción |
|---|---|
| `!skills` | Abre el árbol de habilidades |
| `!shop` / `!tienda` | Abre la tienda de armas |
| `!xp` | Muestra nivel, XP, puntos y créditos |
| `!cartas` | Elegir carta del capítulo o ver las activas |
| `!escuadron` | Clases de tus bots |
| `!ordenes` | Órdenes a los bots (conviene `bind <tecla> sm_ordenes`) |
| `!logros` | Logros y progreso |
| `!campaña` / `!mapa` | Cambiar de campaña, capítulo o dificultad |
| `sm_givexp <n>` | (admin) darte XP para probar (también da créditos) |
| `sm_givemoney <n>` | (admin) darte solo créditos |
| `sm_spawnelite [1-6]` | (admin) especial élite: 1 Ígneo, 2 Blindado, 3 Vampiro, 4 Tóxico, 5 Veloz, 6 Gigante |
| `sm_spawnboss [1-4]` | (admin) jefe: 1 Tank de Fuego, 2 Divisor, 3 Invocador, 4 Witch Reina |
| `sm_spawnloot [1-4]` | (admin) arma con rareza donde apuntas: 1 Común … 4 Legendaria |
| `sm_cartas_reset` | (admin) quita todas las cartas |

En la tienda, "Comprando para" cambia quién recibe el arma: tú o uno de tus bots.

## XP

| Acción | XP |
|---|---|
| Común | 1 (+2 headshot) |
| Especial | 8–12, Tank 50 (+5 headshot) |
| Witch | 30 (+20 crown) |
| Combo | +1 por cada 5 kills seguidas (ventana de 2 s) |

Nivel N → N+1 cuesta `100 + 50·(N-1)` XP. 1 punto por nivel, nivel máximo 50.

## Habilidades

Cada rama tiene 2 tiers; el tier 2 se desbloquea con 3 puntos invertidos en la rama.

| Rama | T1 | T2 |
|---|---|---|
| Tirador | Ojo de halcón: +15% daño headshot/rango | Racha letal: +0.5% daño por kill de combo/rango |
| Demoledor | Munición especial: incendiarias cada 60/45/30 kills | Granadero: pipe bomb cada 80/60/40 kills |
| Soporte | Vampirismo: +0.5 vida temporal por kill/rango | Aura curativa: +1 vida temporal/2 s a aliados en 400u/rango |
| Superviviente | Piernas ligeras: +6% velocidad/rango | Piel dura: -10% daño de comunes/rango |

## Tienda de armas

Cada punto de XP ganado también da 1 crédito (`$`), incluso en nivel máximo. Las armas compradas tienen
munición infinita sin recargar: el cargador se mantiene lleno en cada disparo. Va ligada al arma: si se suelta,
quien la recoja también la tiene. Al pasar de capítulo se reactiva si el comprador sigue llevando ese tipo de arma.

| Categoría | Armas |
|---|---|
| Subfusiles | Uzi, Uzi silenciada — $300 |
| Escopetas | Bombeo, Cromada — $300 · Automática, SPAS-12 — $700 |
| Rifles | M16 — $700 · Desert Rifle — $750 · AK-47 — $800 |
| Francotiradores | Rifle de caza — $600 · Rifle militar — $800 |
| Pesadas | Lanzagranadas — $1500 · M60 — $2000 |

Las armas de CS (MP5, SG552, Scout, AWP) quedan fuera: si el mapa no las tiene precargadas pueden tirar el servidor.

## HUD

Usa el HUD scripted de L4D2 escribiendo directo los netprops de `terror_gamerules` (`m_szScriptedHUDStringSet`,
`m_iScriptedHUDFlags`, …). El cliente solo lo dibuja con `m_bChallengeModeActive` activo y con `HUD_FLAG_TEXT`
en cada slot. Una línea por superviviente humano (máx. 4) arriba a la izquierda:

```
Carlos  Nv 7  [======---------]  140/400  $1234  (+1 pts)  x12
```

## Cartas (roguelite)

Al empezar cada capítulo se ofrecen 3 cartas; si sales del saferoom sin elegir se toma la primera. Se acumulan
y se reinician al empezar otra campaña (mapa `c#m1_…`).

| Carta | Ventaja | Maldición |
|---|---|---|
| Furia | +50% de daño | No hay botiquines |
| Fiebre del oro | Créditos x2 | Hordas 50% más grandes |
| Doble o nada | XP x2 | Recibes +50% de daño |
| Cazagigantes | Tanks dan +100 XP | Tanks con +50% de vida |
| Frágiles | Comunes mueren de un empujón | Comunes 30% más rápidos |
| Sangre fría | Headshots x2 | Cuerpo -30% |
| Vampiro | +2 de vida por kill | Vida máxima 70 |
| Arsenal | Arma T2 con munición infinita cada capítulo | Especiales el doble de seguido |
| Explosivo | Comunes pueden explotar al morir | Boomers dobles |

## Élites y jefes

20% de los especiales salen élite (`l4d2_elite_chance`), con brillo de color y nombre propio. +20 XP.

| Afijo | Efecto |
|---|---|
| Ígneo | Inmune al fuego, sus golpes queman, deja fuego al morir |
| Blindado | -65% de daño salvo por la espalda |
| Vampiro | Se cura con el daño que hace |
| Tóxico | Deja una nube tóxica al morir |
| Veloz | 40% más rápido |
| Gigante | Más grande, x2.5 de vida |

40% de los Tanks salen jefe (`l4d2_elite_tank_chance`) y 20% de las Witches Reina (`l4d2_elite_queen_chance`).
+150 XP y botín épico o legendario.

| Jefe | Efecto |
|---|---|
| Tank de Fuego | Inmune al fuego, sus golpes queman, deja fuego cada 10 s |
| Tank Divisor | Al morir se parte en dos Mini Tanks |
| Tank Invocador | Llama una horda cada 15 s |
| Witch Reina | x3 de vida, aparece con dos Witches más |

## Escuadrón

Cada bot tiene una clase según su personaje; el rango sube cada 10 niveles del jugador (máx. 5).

| Clase | Efecto (rango 0 → 5) |
|---|---|
| Médico | +1…+6 vida temporal cada 3 s a quien esté a 450u |
| Tirador | +20…+70% de daño |
| Demoledor | Munición incendiaria cada 90…40 s (explosiva desde rango 3) |
| Guardián | -20…-70% de daño recibido |

Órdenes vía `CommandABot`: síganme, vengan aquí, vayan a donde apunto, atacar especial, retirada.
Además ajusta la IA (`sb_*`): reacción más rápida, menos tiempo cegados por vómito, disparan entre compañeros.

## Botín

Los especiales sueltan armas (12%, élites 50%, Tanks siempre, Witch 40%) con brillo según la rareza.

| Rareza | Efecto |
|---|---|
| Común | +10% de daño |
| Rara | +25% de daño |
| Épica | +40% de daño y balas incendiarias |
| Legendaria | +60% de daño, roba vida y munición infinita |

## Logros

`!logros`: Coronador, Cazatanques, Ojo de águila, Carnicero, Imparable, A mano limpia, Intocable,
Exterminador élite, Matajefes, Superviviente, Veterano y Leyenda. Dan entre 300 y 2000 XP (y los mismos créditos).

## Feel

- Hitsound al hacer headshot y sonido al matar un especial.
- Cámara lenta al matar un Tank o hacer crown (`l4d2_feel_slowmo`). `host_timescale` solo funciona con
  `sv_cheats`, así que lo activa durante menos de un segundo.
- Esquivar: doble toque izquierda / derecha / atrás (cooldown 2.5 s).
