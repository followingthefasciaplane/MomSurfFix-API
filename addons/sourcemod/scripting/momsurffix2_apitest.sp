#include <sourcemod>
#include <sdktools>
#undef REQUIRE_PLUGIN
#include <momsurffix2>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
	name = "MomSurfFix2 API Test Suite",
	author = "jtooler",
	description = "comprehensive logging and testing for MomSurfFix2 API",
	version = "3",
	url = "https://github.com/followingthefasciaplane/MomSurfFix-API"
};

// =========================================================================
// start: /sm_momsurf_test @me 1
// stop: /sm_momsurf_test @me 0
// path: addons/sourcemod/logs/momsurffix2-api/PlayerName_SteamID.log
// =========================================================================

bool g_bLibraryReady;
bool g_bClientLogging[MAXPLAYERS + 1];
char g_sClientLogPath[MAXPLAYERS + 1][PLATFORM_MAX_PATH];
char g_sLogDir[PLATFORM_MAX_PATH];

static char g_sStepNames[][] = { "Normal", "StepDown", "StepUp" }; // TryPlayerMove phases
static char g_sStuckReasons[][] = { "InvalidTrace", "TraceStartSolid" }; // StuckOnRamp reasons

public void OnPluginStart()
{
	RegAdminCmd("sm_momsurf_test", Command_ToggleClientTest, ADMFLAG_GENERIC, "enable MomSurfFix2 API logging. usage: sm_momsurf_test <target> [0/1]");

	BuildPath(Path_SM, g_sLogDir, sizeof(g_sLogDir), "logs/momsurffix2-api");
	if(!DirExists(g_sLogDir))
	{
		CreateDirectory(g_sLogDir, 511);
	}
	
	g_bLibraryReady = LibraryExists("momsurffix2");
}

public void OnLibraryAdded(const char[] name)
{
	if(StrEqual(name, "momsurffix2"))
	{
		g_bLibraryReady = true;
		LogMessage("[MomSurfFix2 Test] library detected.");
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if(StrEqual(name, "momsurffix2"))
	{
		g_bLibraryReady = false;
		LogMessage("[MomSurfFix2 Test] library removed.");
	}
}

public void OnClientDisconnect(int client)
{
	StopClientTest(client, false);
}


public Action Command_ToggleClientTest(int client, int args)
{
	if(!g_bLibraryReady)
	{
		ReplyToCommand(client, "[MomSurfFix2 Test] library not loaded.");
		return Plugin_Handled;
	}

	if(args < 1)
	{
		ReplyToCommand(client, "usage: sm_momsurf_test <target> [0/1]");
		return Plugin_Handled;
	}

	char targetArg[64];
	GetCmdArg(1, targetArg, sizeof(targetArg));

	bool enable = true;
	if(args >= 2)
	{
		char toggleArg[8];
		GetCmdArg(2, toggleArg, sizeof(toggleArg));
		enable = StringToInt(toggleArg) != 0;
	}

	int targets[MAXPLAYERS];
	char targetName[MAX_TARGET_LENGTH];
	bool tn_is_ml;
	int found = ProcessTargetString(targetArg, client, targets, sizeof(targets), COMMAND_FILTER_CONNECTED, targetName, sizeof(targetName), tn_is_ml);

	if(found <= 0)
	{
		ReplyToTargetError(client, found);
		return Plugin_Handled;
	}

	for(int i = 0; i < found; i++)
	{
		int target = targets[i];
		if(enable)
		{
			if(StartClientTest(target))
				ReplyToCommand(client, "[MomSurfFix2 Test] logging ENABLED for %N -> %s", target, g_sClientLogPath[target]);
			else
				ReplyToCommand(client, "[MomSurfFix2 Test] failed to enable for %N.", target);
		}
		else
		{
			StopClientTest(target, true);
			ReplyToCommand(client, "[MomSurfFix2 Test] logging DISABLED for %N.", target);
		}
	}

	return Plugin_Handled;
}

public void MomSurfFix_OnClipVelocity(int client, int tickCount, int callSerial, MomSurfFixStepPhase stepPhase, const float inVel[3], const float planeNormal[3], const float outVel[3], float overbounce)
{
	if(!ShouldLog(client)) return;

	char sIn[64], sPlane[64], sOut[64];
	FormatVector(inVel, sIn, sizeof(sIn));
	FormatVector(planeNormal, sPlane, sizeof(sPlane));
	FormatVector(outVel, sOut, sizeof(sOut));

	LogToFileEx(g_sClientLogPath[client], 
		"[ClipVelocity] T:%d | S:%d | Phase: %-8s\n    In:    %s\n    Plane: %s (OB: %.2f)\n    Out:   %s",
		tickCount, callSerial, g_sStepNames[stepPhase], sIn, sPlane, overbounce, sOut);
}

public void MomSurfFix_OnPlayerStuckOnRamp(int client, int tickCount, int callSerial, MomSurfFixStepPhase stepPhase, int iteration, MomSurfFixStuckReason reason, const float velocity[3], const float origin[3], bool hadValidPlane, const float candidatePlane[3])
{
	if(!ShouldLog(client)) return;
	
	char sVel[64], sOrg[64], sPlane[64];
	FormatVector(velocity, sVel, sizeof(sVel));
	FormatVector(origin, sOrg, sizeof(sOrg));
	FormatVector(candidatePlane, sPlane, sizeof(sPlane));

	LogToFileEx(g_sClientLogPath[client], 
		"!!! [RAMP STUCK] T:%d | S:%d | Phase: %-8s | Iter: %d\n    Reason: %s\n    Vel:    %s\n    Pos:    %s\n    Plane:  %s (HadValid: %d)",
		tickCount, callSerial, g_sStepNames[stepPhase], iteration, g_sStuckReasons[reason], sVel, sOrg, sPlane, hadValidPlane);
}

public void MomSurfFix_OnTryPlayerMovePost(int client, int tickCount, int callSerial, MomSurfFixStepPhase stepPhase, int blockedMask, int lastIteration, int maxIterations, const float finalVelocity[3], const float finalOrigin[3], bool stuckOnRamp, bool hasValidPlane, const float finalPlane[3], float totalFraction)
{
	if(!ShouldLog(client)) return;

	char sVel[64], sOrg[64], sPlane[64], sBlocked[32];
	FormatVector(finalVelocity, sVel, sizeof(sVel));
	FormatVector(finalOrigin, sOrg, sizeof(sOrg));
	FormatVector(finalPlane, sPlane, sizeof(sPlane));

	// decode blocked mask (Standard Source Movement flags: 1=Floor, 2=Step/Wall)
	if(blockedMask == 0) Format(sBlocked, sizeof(sBlocked), "None");
	else Format(sBlocked, sizeof(sBlocked), "0x%X (Floor:%d Wall:%d)", blockedMask, (blockedMask & 1), (blockedMask & 2) >> 1);

	LogToFileEx(g_sClientLogPath[client], 
		"[MoveComplete] T:%d | S:%d | Phase: %-8s\n    Result: Vel %s\n            Pos %s\n    Plane:  %s (Valid: %d)\n    Bumps:  %d/%d | Blocked: %s | Stuck: %d\n    TotalFrac: %.4f",
		tickCount, callSerial, g_sStepNames[stepPhase], sVel, sOrg, sPlane, hasValidPlane, lastIteration + 1, maxIterations, sBlocked, stuckOnRamp, totalFraction);
}

bool ShouldLog(int client)
{
	return (g_bLibraryReady && IsValidClient(client) && g_bClientLogging[client] && g_sClientLogPath[client][0] != '\0');
}

bool IsValidClient(int client)
{
	return (1 <= client <= MaxClients && IsClientInGame(client));
}

bool StartClientTest(int client)
{
	if(!IsValidClient(client)) return false;

	// path: addons/sourcemod/logs/momsurffix2-api/PlayerName_SteamID.log
	char name[MAX_NAME_LENGTH];
	GetClientName(client, name, sizeof(name));
	SanitizeFilename(name);
	
	char auth[64];
	if(!GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth), true))
		strcopy(auth, sizeof(auth), "unknown_auth");
	SanitizeFilename(auth);

	Format(g_sClientLogPath[client], PLATFORM_MAX_PATH, "%s/%s_%s.log", g_sLogDir, name, auth);

	g_bClientLogging[client] = true;

	LogToFileEx(g_sClientLogPath[client], "==================================================================");
	LogToFileEx(g_sClientLogPath[client], " LOG STARTED: %N (Tickrate: %.0f)", client, 1.0 / GetTickInterval());
	LogToFileEx(g_sClientLogPath[client], " Plugin API (compile): %d", MOMSURFFIX2_API_VERSION);
	LogToFileEx(g_sClientLogPath[client], "==================================================================");
	return true;
}

void StopClientTest(int client, bool writeFooter)
{
	if(!IsValidClient(client)) return;
	
	if(g_bClientLogging[client] && writeFooter)
	{
		LogToFileEx(g_sClientLogPath[client], "==================================================================");
		LogToFileEx(g_sClientLogPath[client], " LOG STOPPED");
		LogToFileEx(g_sClientLogPath[client], "==================================================================");
	}
	
	g_bClientLogging[client] = false;
	g_sClientLogPath[client][0] = '\0';
}

void SanitizeFilename(char[] buffer)
{
	int len = strlen(buffer);
	for(int i = 0; i < len; i++)
	{
		char c = buffer[i];
		if(c == '/' || c == '\\' || c == ':' || c == '*' || c == '?' || c == '"' || c == '<' || c == '>' || c == '|' || c <= 32)
		{
			buffer[i] = '_';
		}
	}
}

// formats with fixed alignment
void FormatVector(const float vec[3], char[] buffer, int maxlen)
{
	Format(buffer, maxlen, "[%9.2f %9.2f %9.2f]", vec[0], vec[1], vec[2]);
}
