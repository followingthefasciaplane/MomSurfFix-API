#include <sourcemod>
#include <sdktools>
#include <momsurffix2>

#pragma semicolon 1
#pragma newdecls required

#define MAX_HUD_LINES 512
#define MAX_HUD_SECTIONS 4

ConVar g_cvEnabled;

enum struct HudSection
{
    char name[32];
    float x;
    float y;
    char lines[MAX_HUD_LINES];
    Handle sync;
    bool needsUpdate;
}

HudSection g_HudSections[MAX_HUD_SECTIONS];

public void OnPluginStart()
{
    g_cvEnabled = CreateConVar("sm_momsurffix_hud_enabled", "1", "Enable/disable MomSurfFix HUD display", _, true, 0.0, true, 1.0);
    
    RegConsoleCmd("sm_msf_hud", Command_ToggleHUD, "Toggle MomSurfFix HUD display");

    InitializeHudSections();

    // Hook player_spawn event to display HUD when players spawn
    HookEvent("player_spawn", Event_PlayerSpawn);
}

public void OnPluginEnd()
{
    for (int i = 0; i < MAX_HUD_SECTIONS; i++)
    {
        if (g_HudSections[i].sync != INVALID_HANDLE)
        {
            CloseHandle(g_HudSections[i].sync);
            g_HudSections[i].sync = INVALID_HANDLE;
        }
    }
}

void InitializeHudSections()
{
    SetHudSection(0, "OnBumpIteration", 0.05, 0.05);
    SetHudSection(1, "OnPlayerStuckOnRamp", 0.05, 0.30);
    SetHudSection(2, "OnClipVelocity", 0.55, 0.05);
    SetHudSection(3, "OnTryPlayerMovePost", 0.55, 0.30);
}

void SetHudSection(int index, const char[] name, float x, float y)
{
    if (index < 0 || index >= MAX_HUD_SECTIONS)
    {
        ThrowError("Attempted to set invalid HUD section index: %d", index);
        return;
    }

    strcopy(g_HudSections[index].name, sizeof(HudSection::name), name);
    g_HudSections[index].x = x;
    g_HudSections[index].y = y;
    g_HudSections[index].lines[0] = '\0';
    g_HudSections[index].needsUpdate = true;
    
    if (g_HudSections[index].sync != INVALID_HANDLE)
    {
        CloseHandle(g_HudSections[index].sync);
    }
    g_HudSections[index].sync = CreateHudSynchronizer();
}

public Action Command_ToggleHUD(int client, int args)
{
    if (client == 0)
    {
        ReplyToCommand(client, "[SM] This command can only be used in-game.");
        return Plugin_Handled;
    }
    
    bool enabled = !g_cvEnabled.BoolValue;
    g_cvEnabled.SetBool(enabled);
    
    ReplyToCommand(client, "[SM] MomSurfFix HUD display %s.", enabled ? "enabled" : "disabled");

    if (enabled)
    {
        DisplayAllHudSections(client);
    }
    else
    {
        ClearAllHudSections(client);
    }

    return Plugin_Handled;
}

void UpdateAndDisplayHudSection(int index, const char[][] lines, int lineCount)
{
    if (index < 0 || index >= MAX_HUD_SECTIONS)
    {
        LogError("Attempted to update invalid HUD section index: %d", index);
        return;
    }

    if (!g_cvEnabled.BoolValue)
        return;

    char buffer[MAX_HUD_LINES];
    buffer[0] = '\0';

    for (int i = 0; i < lineCount; i++)
    {
        Format(buffer, sizeof(buffer), "%s%s\n", buffer, lines[i]);
    }

    // Only update if the content has changed
    if (strcmp(g_HudSections[index].lines, buffer) != 0)
    {
        strcopy(g_HudSections[index].lines, sizeof(HudSection::lines), buffer);
        g_HudSections[index].needsUpdate = true;
    }

    if (g_HudSections[index].sync == INVALID_HANDLE)
    {
        LogError("Invalid HUD synchronizer handle for section %d", index);
        return;
    }

    // Only redraw if an update is needed
    if (g_HudSections[index].needsUpdate)
    {
        char displayBuffer[MAX_HUD_LINES];
        Format(displayBuffer, sizeof(displayBuffer), "%s:\n%s", g_HudSections[index].name, g_HudSections[index].lines);

        for (int client = 1; client <= MaxClients; client++)
        {
            if (IsClientInGame(client) && !IsFakeClient(client))
            {
                SetHudTextParams(g_HudSections[index].x, g_HudSections[index].y, 99999.0, 53, 169, 217, 255, 0, 0.0, 0.0, 0.0);
                ShowSyncHudText(client, g_HudSections[index].sync, displayBuffer);
            }
        }
        g_HudSections[index].needsUpdate = false;
    }
}

void DisplayAllHudSections(int client)
{
    if (!g_cvEnabled.BoolValue)
        return;

    for (int i = 0; i < MAX_HUD_SECTIONS; i++)
    {
        if (g_HudSections[i].sync != INVALID_HANDLE)
        {
            char displayBuffer[MAX_HUD_LINES];
            Format(displayBuffer, sizeof(displayBuffer), "%s:\n%s", g_HudSections[i].name, g_HudSections[i].lines);

            SetHudTextParams(g_HudSections[i].x, g_HudSections[i].y, 99999.0, 53, 169, 217, 255, 0, 0.0, 0.0, 0.0);
            ShowSyncHudText(client, g_HudSections[i].sync, displayBuffer);
        }
    }
}

void ClearAllHudSections(int client)
{
    for (int i = 0; i < MAX_HUD_SECTIONS; i++)
    {
        if (g_HudSections[i].sync != INVALID_HANDLE)
        {
            ClearSyncHud(client, g_HudSections[i].sync);
        }
    }
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (IsValidClient(client))
    {
        DisplayAllHudSections(client);
    }
}

bool IsValidClient(int client)
{
    return (client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client));
}

// The following forward functions remain unchanged
public Action MomSurfFix_OnBumpIteration(int client, int bumpcount, float velocity[3], float origin[3])
{
    char lines[5][64];
    Format(lines[0], sizeof(lines[]), "Ticked Time: %.2f", GetTickedTime());
    Format(lines[1], sizeof(lines[]), "Bump Count: %d", bumpcount);
    Format(lines[2], sizeof(lines[]), "Bump Velocity: X(%.2f) Y(%.2f) Z(%.2f)", velocity[0], velocity[1], velocity[2]);
    Format(lines[3], sizeof(lines[]), "Bump Origin: X(%.2f) Y(%.2f) Z(%.2f)", origin[0], origin[1], origin[2]);
    UpdateAndDisplayHudSection(0, lines, 4);
    return Plugin_Continue;
}

public void MomSurfFix_OnPlayerStuckOnRamp(int client, float velocity[3], float origin[3], float validPlane[3])
{
    char lines[5][64];
    Format(lines[0], sizeof(lines[]), "Ticked Time: %.2f", GetTickedTime());
    Format(lines[1], sizeof(lines[]), "Stuck Velocity: X(%.2f) Y(%.2f) Z(%.2f)", velocity[0], velocity[1], velocity[2]);
    Format(lines[2], sizeof(lines[]), "Stuck Origin: X(%.2f) Y(%.2f) Z(%.2f)", origin[0], origin[1], origin[2]);
    Format(lines[3], sizeof(lines[]), "Surface Normal: X(%.2f) Y(%.2f) Z(%.2f)", validPlane[0], validPlane[1], validPlane[2]);
    UpdateAndDisplayHudSection(1, lines, 4);
}

public Action MomSurfFix_OnClipVelocity(int client, float inVelocity[3], float normal[3], float& overbounce)
{
    char lines[5][64];
    Format(lines[0], sizeof(lines[]), "Ticked Time: %.2f", GetTickedTime());
    Format(lines[1], sizeof(lines[]), "In Velocity: X(%.2f) Y(%.2f) Z(%.2f)", inVelocity[0], inVelocity[1], inVelocity[2]);
    Format(lines[2], sizeof(lines[]), "Surface Normal: X(%.2f) Y(%.2f) Z(%.2f)", normal[0], normal[1], normal[2]);
    Format(lines[3], sizeof(lines[]), "Overbounce: %.2f", overbounce);
    UpdateAndDisplayHudSection(2, lines, 4);
    return Plugin_Continue;
}

public void MomSurfFix_OnTryPlayerMovePost(int client, int blocked, float endVelocity[3], float endOrigin[3], float allFraction)
{
    char lines[6][64];
    Format(lines[0], sizeof(lines[]), "Ticked Time: %.2f", GetTickedTime());
    Format(lines[1], sizeof(lines[]), "Blocked: %d", blocked);
    Format(lines[2], sizeof(lines[]), "End Velocity: X(%.2f) Y(%.2f) Z(%.2f)", endVelocity[0], endVelocity[1], endVelocity[2]);
    Format(lines[3], sizeof(lines[]), "End Origin: X(%.2f) Y(%.2f) Z(%.2f)", endOrigin[0], endOrigin[1], endOrigin[2]);
    Format(lines[4], sizeof(lines[]), "Fraction Moved: %.2f", allFraction);
    UpdateAndDisplayHudSection(3, lines, 5);
}

public void MomSurfFix_OnPluginReady()
{
    PrintToServer("[MomSurfFix HUD] MomSurfFix2 plugin is ready!");
    InitializeHudSections(); // Re-initialize HUD sections when MomSurfFix2 is ready
}
