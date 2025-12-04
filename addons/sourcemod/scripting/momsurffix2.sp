#include "sourcemod"
#include "sdktools"
#include "sdkhooks"
#include "dhooks"

#define SNAME "[momsurffix2] "
#define GAME_DATA_FILE "momsurffix2.games"
// #define DEBUG_MEMTEST

/*
	this fork creates an inter-plugin API
	for third party plugins to take advantage
	of the deep engine hooks and precise movement
	data that this plugin provides.

	untested on public servers. 
	performance might be an issue. 
	mainly intended for LAN use right now.
*/

public Plugin myinfo = {
    name = "Momentum surf fix \'2 (API)",
    author = "GAMMA CASE, jtooler",
    description = "Ported surf fix from momentum mod with a public API.",
    version = "3",
	url = "https://github.com/followingthefasciaplane/MomSurfFix-API/" // url = "http://steamcommunity.com/id/_GAMMACASE_/"
};


#define FLT_EPSILON 1.192092896e-07
#define MAX_CLIP_PLANES 5

enum OSType
{
	OSUnknown = -1,
	OSWindows = 1,
	OSLinux = 2
};

OSType gOSType;
EngineVersion gEngineVersion;

#define XYZ(%0) %0[0], %0[1], %0[2]

#define ASSERTUTILS_FAILSTATE_FUNC SetFailStateCustom
#define MEMUTILS_PLUGINENDCALL
#include "glib/memutils"
#undef MEMUTILS_PLUGINENDCALL

ConVar gRampBumpCount,
	gBounce,
	gRampInitialRetraceLength,
	gNoclipWorkAround;

Handle gFwd_OnClipVelocity;
Handle gFwd_OnPlayerStuckOnRamp;
Handle gFwd_OnTryPlayerMovePost;

MomSurfFixContext g_MoveContext[MAXPLAYERS + 1];
Address g_PlayerAddresses[MAXPLAYERS + 1];
int g_CurrentMoveClient;
bool g_ExpectStepMoveUp[MAXPLAYERS + 1];
int g_ExpectStepMoveTick[MAXPLAYERS + 1];

float vec3_origin[3] = {0.0, 0.0, 0.0};
bool gBasePlayerLoadedTooEarly;

#include "momsurffix/utils.sp"
#include "momsurffix/baseplayer.sp"
#include "momsurffix/gametrace.sp"
#include "momsurffix/gamemovement.sp"

#define MOMSURFFIX2_CORE
#include <momsurffix2>

enum struct MomSurfFixContext
{
	int tickCount;
	int callSerial;
	MomSurfFixStepPhase stepMovePhase;
}

void ResetMoveContext(int client)
{
	if(client < 1 || client > MaxClients)
		return;
	
	g_MoveContext[client].tickCount = 0;
	g_MoveContext[client].callSerial = 0;
	g_MoveContext[client].stepMovePhase = MomSurfFixStep_Normal;
	g_ExpectStepMoveUp[client] = false;
	g_ExpectStepMoveTick[client] = 0;
}

public void OnPluginStart()
{
#if defined DEBUG_MEMTEST
	RegAdminCmd("sm_mom_dumpmempool", SM_Dumpmempool, ADMFLAG_ROOT, "Dumps active momory pool. Mainly for debugging.");
#endif
	gFwd_OnClipVelocity = CreateGlobalForward("MomSurfFix_OnClipVelocity", ET_Ignore,
		Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Array, Param_Array, Param_Array, Param_Float);
	gFwd_OnPlayerStuckOnRamp = CreateGlobalForward("MomSurfFix_OnPlayerStuckOnRamp", ET_Ignore,
		Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Array, Param_Array, Param_Cell, Param_Array);
	gFwd_OnTryPlayerMovePost = CreateGlobalForward("MomSurfFix_OnTryPlayerMovePost", ET_Ignore,
		Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Array, Param_Array, Param_Cell, Param_Cell, Param_Array, Param_Float);
	
	gRampBumpCount = CreateConVar("momsurffix_ramp_bumpcount", "8", "Helps with fixing surf/ramp bugs", .hasMin = true, .min = 4.0, .hasMax = true, .max = 16.0);
	gRampInitialRetraceLength = CreateConVar("momsurffix_ramp_initial_retrace_length", "0.2", "Amount of units used in offset for retraces", .hasMin = true, .min = 0.2, .hasMax = true, .max = 5.0);
	gNoclipWorkAround = CreateConVar("momsurffix_enable_noclip_workaround", "1", "Enables workaround to prevent issue #1, can actually help if momsuffix_enable_asm_optimizations is 0", .hasMin = true, .min = 0.0, .hasMax = true, .max = 1.0);
	gBounce = FindConVar("sv_bounce");
	ASSERT_MSG(gBounce, "\"sv_bounce\" convar wasn't found!");
	
	AutoExecConfig();
	
	GameData gd = new GameData(GAME_DATA_FILE);
	ASSERT_FINAL(gd);
	
	ValidateGameAndOS(gd);
	
	InitUtils(gd);
	InitGameTrace(gd);
	gBasePlayerLoadedTooEarly = InitBasePlayer(gd);
	InitGameMovement(gd);
	
	SetupDhooks(gd);
	
	delete gd;
	
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i))
			g_PlayerAddresses[i] = GetEntityAddress(i);
		else
			g_PlayerAddresses[i] = Address_Null;
		
		ResetMoveContext(i);
	}
}

public void OnMapStart()
{
	if(gBasePlayerLoadedTooEarly)
	{
		GameData gd = new GameData(GAME_DATA_FILE);
		LateInitBasePlayer(gd);
		gBasePlayerLoadedTooEarly = false;
		delete gd;
	}
}

public void OnClientPutInServer(int client)
{
	g_PlayerAddresses[client] = GetEntityAddress(client);
	ResetMoveContext(client);
}

public void OnClientDisconnect(int client)
{
	g_PlayerAddresses[client] = Address_Null;
	ResetMoveContext(client);
}

public void OnPluginEnd()
{
	CleanUpUtils();
	
	delete gFwd_OnClipVelocity;
	delete gFwd_OnPlayerStuckOnRamp;
	delete gFwd_OnTryPlayerMovePost;
}

#if defined DEBUG_MEMTEST
public Action SM_Dumpmempool(int client, int args)
{
	DumpMemoryUsage();
	
	return Plugin_Handled;
}
#endif

void ValidateGameAndOS(GameData gd)
{
	gOSType = view_as<OSType>(gd.GetOffset("OSType"));
	ASSERT_FINAL_MSG(gOSType != OSUnknown, "Failed to get OS type or you are trying to load it on unsupported OS!");
	
	gEngineVersion = GetEngineVersion();
	ASSERT_FINAL_MSG(gEngineVersion == Engine_CSS || gEngineVersion == Engine_CSGO, "Only CSGO and CSS are supported by this plugin!");
}

void SetupDhooks(GameData gd)
{
	Handle dhook = DHookCreateDetour(Address_Null, CallConv_THISCALL, ReturnType_Int, ThisPointer_Address);
	
	DHookSetFromConf(dhook, gd, SDKConf_Signature, "CGameMovement::TryPlayerMove");
	DHookAddParam(dhook, HookParamType_Int);
	DHookAddParam(dhook, HookParamType_Int);
	
	if(gEngineVersion == Engine_CSS)
		DHookAddParam(dhook, HookParamType_Float);
	
	ASSERT(DHookEnableDetour(dhook, false, TryPlayerMove_Dhook));
}

public MRESReturn TryPlayerMove_Dhook(Address pThis, Handle hReturn, Handle hParams)
{
	Address pFirstDest = DHookGetParam(hParams, 1);
	Address pFirstTrace = DHookGetParam(hParams, 2);
	
	DHookSetReturn(hReturn, TryPlayerMove(view_as<CGameMovement>(pThis), view_as<Vector>(pFirstDest), view_as<CGameTrace>(pFirstTrace)));
	
	return MRES_Supercede;
}

int TryPlayerMove(CGameMovement pThis, Vector pFirstDest, CGameTrace pFirstTrace)
{
	float original_velocity[3], primal_velocity[3], fixed_origin[3], valid_plane[3], new_velocity[3], end[3], dir[3];
	float allFraction = 0.0, d, time_left = GetGameFrameTime(), planes[MAX_CLIP_PLANES][3];
	int bumpcount, blocked, numplanes, numbumps = gRampBumpCount.IntValue, i, j, h, lastIteration = -1;
	bool stuck_on_ramp, has_valid_plane;
	CGameTrace pm = CGameTrace();
	int client = GetGameMovementClient(pThis);
	int tickCount = GetGameTickCount();
	
	g_CurrentMoveClient = client;
	
	Vector vecVelocity = pThis.mv.m_vecVelocity;
	vecVelocity.ToArray(original_velocity);
	vecVelocity.ToArray(primal_velocity);
	Vector vecAbsOrigin = pThis.mv.m_vecAbsOrigin;
	vecAbsOrigin.ToArray(fixed_origin);
	
	if(client > 0)
	{
		if(g_MoveContext[client].tickCount != tickCount)
		{
			g_MoveContext[client].callSerial = 0;
			g_ExpectStepMoveUp[client] = false;
			g_ExpectStepMoveTick[client] = 0;
		}
		else
		{
			g_MoveContext[client].callSerial++;
		}
		
		int callSerial = g_MoveContext[client].callSerial;
		
		MomSurfFixStepPhase phase = MomSurfFixStep_Normal;
		bool onGround = (pThis.player.m_hGroundEntity != view_as<Address>(-1));
		if(onGround && (pFirstDest.Address != Address_Null || pFirstTrace.Address != Address_Null))
		{
			phase = MomSurfFixStep_StepMoveDown;
			g_ExpectStepMoveUp[client] = true;
			g_ExpectStepMoveTick[client] = tickCount;
		}
		else if(onGround && g_ExpectStepMoveUp[client] && g_ExpectStepMoveTick[client] == tickCount)
		{
			phase = MomSurfFixStep_StepMoveUp;
			g_ExpectStepMoveUp[client] = false;
		}
		else if(!onGround)
		{
			g_ExpectStepMoveUp[client] = false;
			g_ExpectStepMoveTick[client] = 0;
		}
		
		g_MoveContext[client].tickCount = tickCount;
		g_MoveContext[client].callSerial = callSerial;
		g_MoveContext[client].stepMovePhase = phase;
	}
	
	Vector plane_normal;
	static Vector alloced_vector, alloced_vector2;
	
	if(alloced_vector.Address == Address_Null)
		alloced_vector = Vector();
	
	if(alloced_vector2.Address == Address_Null)
		alloced_vector2 = Vector();
	
	for(bumpcount = 0; bumpcount < numbumps; bumpcount++)
	{
		lastIteration = bumpcount;
		
		if(vecVelocity.LengthSqr() == 0.0)
			break;
		
		if(stuck_on_ramp)
		{
			if(!has_valid_plane)
			{
				plane_normal = pm.plane.normal;
				if(!CloseEnough(VectorToArray(plane_normal), view_as<float>({0.0, 0.0, 0.0})) &&
					!IsEqual(valid_plane, VectorToArray(plane_normal)))
				{
					plane_normal.ToArray(valid_plane);
					has_valid_plane = true;
				}
				else
				{
					for(i = numplanes; i-- > 0;)
					{
						if(!CloseEnough(planes[i], view_as<float>({0.0, 0.0, 0.0})) &&
							FloatAbs(planes[i][0]) <= 1.0 && FloatAbs(planes[i][1]) <= 1.0 && FloatAbs(planes[i][2]) <= 1.0 &&
							!IsEqual(valid_plane, planes[i]))
						{
							VectorCopy(planes[i], valid_plane);
							has_valid_plane = true;
							break;
						}
					}
				}
			}
			
			if(has_valid_plane)
			{
				alloced_vector.FromArray(valid_plane);
				if(valid_plane[2] >= 0.7 && valid_plane[2] <= 1.0)
				{
					ClipVelocity(pThis, vecVelocity, alloced_vector, vecVelocity, 1.0);
					vecVelocity.ToArray(original_velocity);
				}
				else
				{
					ClipVelocity(pThis, vecVelocity, alloced_vector, vecVelocity, 1.0 + gBounce.FloatValue * (1.0 - pThis.player.m_surfaceFriction));
					vecVelocity.ToArray(original_velocity);
				}
				alloced_vector.ToArray(valid_plane);
			}
			//TODO: should be replaced with normal solution!! Currently hack to fix issue #1.
			else if(!gNoclipWorkAround.BoolValue || (vecVelocity.z < -6.25 || vecVelocity.z > 0.0))
			{
				//Quite heavy part of the code, should not be triggered much or else it'll impact performance by a lot!!!
				float offsets[3];
				offsets[0] = (float(bumpcount) * 2.0) * -gRampInitialRetraceLength.FloatValue;
				offsets[2] = (float(bumpcount) * 2.0) * gRampInitialRetraceLength.FloatValue;
				int valid_planes = 0;
				
				VectorCopy(view_as<float>({0.0, 0.0, 0.0}), valid_plane);
				
				float offset[3], offset_mins[3], offset_maxs[3], buff[3];
				static Ray_t ray;
				
				// Keep this variable allocated only once
				// since ray.Init should take care of removing any left garbage values
				if(ray.Address == Address_Null)
					ray = Ray_t();
				
				for(i = 0; i < 3; i++)
				{
					for(j = 0; j < 3; j++)
					{
						for(h = 0; h < 3; h++)
						{
							offset[0] = offsets[i];
							offset[1] = offsets[j];
							offset[2] = offsets[h];
							
							VectorCopy(offset, offset_mins);
							ScaleVector(offset_mins, 0.5);
							VectorCopy(offset, offset_maxs);
							ScaleVector(offset_maxs, 0.5);
							
							if(offset[0] > 0.0)
								offset_mins[0] /= 2.0;
							if(offset[1] > 0.0)
								offset_mins[1] /= 2.0;
							if(offset[2] > 0.0)
								offset_mins[2] /= 2.0;
							
							if(offset[0] < 0.0)
								offset_maxs[0] /= 2.0;
							if(offset[1] < 0.0)
								offset_maxs[1] /= 2.0;
							if(offset[2] < 0.0)
								offset_maxs[2] /= 2.0;

							AddVectors(fixed_origin, offset, buff);
							SubtractVectors(end, offset, offset);
							if(gEngineVersion == Engine_CSGO)
							{
								SubtractVectors(VectorToArray(GetPlayerMins(pThis)), offset_mins, offset_mins); 
								AddVectors(VectorToArray(GetPlayerMaxs(pThis)), offset_maxs, offset_maxs);
							}
							else
							{
								SubtractVectors(VectorToArray(GetPlayerMinsCSS(pThis, alloced_vector)), offset_mins, offset_mins); 
								AddVectors(VectorToArray(GetPlayerMaxsCSS(pThis, alloced_vector2)), offset_maxs, offset_maxs);
							}

							ray.Init(buff, offset, offset_mins, offset_maxs);

							UTIL_TraceRay(ray, MASK_PLAYERSOLID, pThis, COLLISION_GROUP_PLAYER_MOVEMENT, pm);

							plane_normal = pm.plane.normal;
							
							if(FloatAbs(plane_normal.x) <= 1.0 && FloatAbs(plane_normal.y) <= 1.0 &&
								FloatAbs(plane_normal.z) <= 1.0 && pm.fraction > 0.0 && pm.fraction < 1.0 && !pm.startsolid)
							{
								valid_planes++;
								AddVectors(valid_plane, VectorToArray(plane_normal), valid_plane);
							}
						}
					}
				}
				
				if(valid_planes != 0 && !CloseEnough(valid_plane, view_as<float>({0.0, 0.0, 0.0})))
				{
					has_valid_plane = true;
					NormalizeVector(valid_plane, valid_plane);
					continue;
				}
			}
			
			if(has_valid_plane)
			{
				VectorMA(fixed_origin, gRampInitialRetraceLength.FloatValue, valid_plane, fixed_origin);
			}
			else
			{
				stuck_on_ramp = false;
				continue;
			}
		}
		
		VectorMA(fixed_origin, time_left, VectorToArray(vecVelocity), end);
		
		if(pFirstDest.Address != Address_Null && IsEqual(end, VectorToArray(pFirstDest)))
		{
			pm.Free();
			pm = pFirstTrace;
		}
		else
		{
			alloced_vector2.FromArray(end);
			
			if(stuck_on_ramp && has_valid_plane)
			{
				alloced_vector.FromArray(fixed_origin);
				TracePlayerBBox(pThis, alloced_vector, alloced_vector2, MASK_PLAYERSOLID, COLLISION_GROUP_PLAYER_MOVEMENT, pm);
				pm.plane.normal.FromArray(valid_plane);
			}
			else
			{
				TracePlayerBBox(pThis, vecAbsOrigin, alloced_vector2, MASK_PLAYERSOLID, COLLISION_GROUP_PLAYER_MOVEMENT, pm);
			}
		}
		
		if(bumpcount > 0 && pThis.player.m_hGroundEntity == view_as<Address>(-1) && !IsValidMovementTrace(pThis, pm))
		{
			bool prevPlane = has_valid_plane;
			has_valid_plane = false;
			stuck_on_ramp = true;
			
			if(client > 0 && gFwd_OnPlayerStuckOnRamp != null && GetForwardFunctionCount(gFwd_OnPlayerStuckOnRamp) > 0)
			{
				FireStuckForward(client, bumpcount, MomSurfFixStuck_InvalidTrace, vecVelocity, fixed_origin, prevPlane, valid_plane);
			}
			continue;
		}
		
		if(pm.fraction > 0.0)
		{
			if((bumpcount == 0 || pThis.player.m_hGroundEntity != view_as<Address>(-1)) && numbumps > 0 && pm.fraction == 1.0)
			{
				CGameTrace stuck = CGameTrace();
				TracePlayerBBox(pThis, pm.endpos, pm.endpos, MASK_PLAYERSOLID, COLLISION_GROUP_PLAYER_MOVEMENT, stuck);
				
				if((stuck.startsolid || stuck.fraction != 1.0) && bumpcount == 0)
				{
					bool prevPlane = has_valid_plane;
					has_valid_plane = false;
					stuck_on_ramp = true;
					
					if(client > 0 && gFwd_OnPlayerStuckOnRamp != null && GetForwardFunctionCount(gFwd_OnPlayerStuckOnRamp) > 0)
					{
						FireStuckForward(client, bumpcount, MomSurfFixStuck_TraceStartSolid, vecVelocity, fixed_origin, prevPlane, valid_plane);
					}
					
					stuck.Free();
					continue;
				}
				else if(stuck.startsolid || stuck.fraction != 1.0)
				{
					vecVelocity.FromArray(vec3_origin);
					
					stuck.Free();
					break;
				}
				
				stuck.Free();
			}
			
			has_valid_plane = false;
			stuck_on_ramp = false;
			
			vecVelocity.ToArray(original_velocity);
			vecAbsOrigin.FromArray(VectorToArray(pm.endpos));
			vecAbsOrigin.ToArray(fixed_origin);
			allFraction += pm.fraction;
			numplanes = 0;
		}
		
		if(CloseEnoughFloat(pm.fraction, 1.0))
			break;
		
		MoveHelper().AddToTouched(pm, vecVelocity);
		
		if(pm.plane.normal.z >= 0.7)
			blocked |= 1;
		
		if(CloseEnoughFloat(pm.plane.normal.z, 0.0))
			blocked |= 2;
		
		time_left -= time_left * pm.fraction;
		
		if(numplanes >= MAX_CLIP_PLANES)
		{
			vecVelocity.FromArray(vec3_origin);
			break;
		}
		
		pm.plane.normal.ToArray(planes[numplanes]);
		numplanes++;
		
		if(numplanes == 1 && pThis.player.m_MoveType == MOVETYPE_WALK && pThis.player.m_hGroundEntity != view_as<Address>(-1))
		{
			Vector vec1 = Vector();
			if(planes[0][2] >= 0.7)
			{
				vec1.FromArray(original_velocity);
				alloced_vector2.FromArray(planes[0]);
				alloced_vector.FromArray(new_velocity);
				ClipVelocity(pThis, vec1, alloced_vector2, alloced_vector, 1.0);
				alloced_vector.ToArray(original_velocity);
				alloced_vector.ToArray(new_velocity);
			}
			else
			{
				vec1.FromArray(original_velocity);
				alloced_vector2.FromArray(planes[0]);
				alloced_vector.FromArray(new_velocity);
				ClipVelocity(pThis, vec1, alloced_vector2, alloced_vector, 1.0 + gBounce.FloatValue * (1.0 - pThis.player.m_surfaceFriction));
				alloced_vector.ToArray(new_velocity);
			}
			
			vecVelocity.FromArray(new_velocity);
			VectorCopy(new_velocity, original_velocity);
			
			vec1.Free();
		}
		else
		{
			for(i = 0; i < numplanes; i++)
			{
				alloced_vector2.FromArray(original_velocity);
				alloced_vector.FromArray(planes[i]);
				ClipVelocity(pThis, alloced_vector2, alloced_vector, vecVelocity, 1.0);
				alloced_vector.ToArray(planes[i]);
				
				for(j = 0; j < numplanes; j++)
					if(j != i)
						if(vecVelocity.Dot(planes[j]) < 0.0)
							break;
				
				if(j == numplanes)
					break;
			}
			
			if(i != numplanes)
			{
				
			}
			else
			{
				if(numplanes != 2)
				{
					vecVelocity.FromArray(vec3_origin);
					break;
				}
				
				if(CloseEnough(planes[0], planes[1]))
				{
					VectorMA(original_velocity, 20.0, planes[0], new_velocity);
					vecVelocity.x = new_velocity[0];
					vecVelocity.y = new_velocity[1];
					
					break;
				}
				
				GetVectorCrossProduct(planes[0], planes[1], dir);
				NormalizeVector(dir, dir);
				
				d = vecVelocity.Dot(dir);
				
				ScaleVector(dir, d);
				vecVelocity.FromArray(dir);
			}
			
			d = vecVelocity.Dot(primal_velocity);
			if(d <= 0.0)
			{
				vecVelocity.FromArray(vec3_origin);
				break;
			}
		}
	}
	
	if(CloseEnoughFloat(allFraction, 0.0))
		vecVelocity.FromArray(vec3_origin);
	
	pm.Free();
	
	if(client > 0)
	{
		float finalVelocity[3], finalOrigin[3], finalPlane[3];
		vecVelocity.ToArray(finalVelocity);
		vecAbsOrigin.ToArray(finalOrigin);
		VectorCopy(valid_plane, finalPlane);
		FireTryPlayerMovePostForward(client, blocked, lastIteration, numbumps, finalVelocity, finalOrigin, stuck_on_ramp, has_valid_plane, finalPlane, allFraction);
	}
	
	g_CurrentMoveClient = 0;
	return blocked;
}

int GetGameMovementClient(CGameMovement gm)
{
	if(MaxClients <= 0)
		return 0;
	
	Address playerAddr = gm.player.Address;
	if(playerAddr == Address_Null)
		return 0;
	
	for(int i = 1; i <= MaxClients; i++)
	{
		if(g_PlayerAddresses[i] == playerAddr)
			return i;
	}
	
	for(int i = 1; i <= MaxClients; i++)
	{
		if(!IsClientInGame(i))
			continue;
		
		Address addr = GetEntityAddress(i);
		g_PlayerAddresses[i] = addr;
		
		if(addr == playerAddr)
			return i;
	}
	
	return 0;
}

void FireStuckForward(int client, int bump, MomSurfFixStuckReason reason, Vector velocity, const float origin[3], bool hadPlane, const float plane[3])
{
	if(client <= 0 || !gFwd_OnPlayerStuckOnRamp)
		return;
	
	int tickCount = g_MoveContext[client].tickCount;
	int callSerial = g_MoveContext[client].callSerial;
	MomSurfFixStepPhase stepPhase = g_MoveContext[client].stepMovePhase;
	float velocityBuff[3];
	velocity.ToArray(velocityBuff);
	
	Call_StartForward(gFwd_OnPlayerStuckOnRamp);
	Call_PushCell(client);
	Call_PushCell(tickCount);
	Call_PushCell(callSerial);
	Call_PushCell(stepPhase);
	Call_PushCell(bump);
	Call_PushCell(reason);
	Call_PushArray(velocityBuff, 3);
	Call_PushArray(origin, 3);
	Call_PushCell(hadPlane);
	Call_PushArray(plane, 3);
	Call_Finish();
}

void FireTryPlayerMovePostForward(int client, int blocked, int lastBump, int maxBumps, float velocity[3], float origin[3], bool stuck, bool hasPlane, float plane[3], float allFraction)
{
	if(client <= 0 || !gFwd_OnTryPlayerMovePost)
		return;
	
	if(GetForwardFunctionCount(gFwd_OnTryPlayerMovePost) == 0)
		return;
	
	int tickCount = g_MoveContext[client].tickCount;
	int callSerial = g_MoveContext[client].callSerial;
	MomSurfFixStepPhase stepMovePhase = g_MoveContext[client].stepMovePhase;
	
	Call_StartForward(gFwd_OnTryPlayerMovePost);
	Call_PushCell(client);
	Call_PushCell(tickCount);
	Call_PushCell(callSerial);
	Call_PushCell(stepMovePhase);
	Call_PushCell(blocked);
	Call_PushCell(lastBump);
	Call_PushCell(maxBumps);
	Call_PushArray(velocity, 3);
	Call_PushArray(origin, 3);
	Call_PushCell(stuck);
	Call_PushCell(hasPlane);
	Call_PushArray(plane, 3);
	Call_PushFloat(allFraction);
	Call_Finish();
}

void FireClipVelocityForward(int client, float inVec[3], float normal[3], float outVec[3], float overbounce)
{
	if(client <= 0 || !gFwd_OnClipVelocity)
		return;
	
	if(GetForwardFunctionCount(gFwd_OnClipVelocity) == 0)
		return;
	
	int tickCount = g_MoveContext[client].tickCount;
	int callSerial = g_MoveContext[client].callSerial;
	MomSurfFixStepPhase stepMovePhase = g_MoveContext[client].stepMovePhase;
	
	Call_StartForward(gFwd_OnClipVelocity);
	Call_PushCell(client);
	Call_PushCell(tickCount);
	Call_PushCell(callSerial);
	Call_PushCell(stepMovePhase);
	Call_PushArray(inVec, 3);
	Call_PushArray(normal, 3);
	Call_PushArray(outVec, 3);
	Call_PushFloat(overbounce);
	Call_Finish();
}

stock void VectorMA(float start[3], float scale, float dir[3], float dest[3])
{
	dest[0] = start[0] + dir[0] * scale;
	dest[1] = start[1] + dir[1] * scale;
	dest[2] = start[2] + dir[2] * scale;
}

stock void VectorCopy(float from[3], float to[3])
{
	to[0] = from[0];
	to[1] = from[1];
	to[2] = from[2];
}

stock float[] VectorToArray(Vector vec)
{
	float ret[3];
	vec.ToArray(ret);
	return ret;
}

stock bool IsEqual(float a[3], float b[3])
{
	return a[0] == b[0] && a[1] == b[1] && a[2] == b[2];
}

stock bool CloseEnough(float a[3], float b[3], float eps = FLT_EPSILON)
{
	return FloatAbs(a[0] - b[0]) <= eps &&
		FloatAbs(a[1] - b[1]) <= eps &&
		FloatAbs(a[2] - b[2]) <= eps;
}

stock bool CloseEnoughFloat(float a, float b, float eps = FLT_EPSILON)
{
	return FloatAbs(a - b) <= eps;
}

public void SetFailStateCustom(const char[] fmt, any ...)
{
	char buff[512];
	VFormat(buff, sizeof(buff), fmt, 2);
	
	CleanUpUtils();
	
	char ostype[32];
	switch(gOSType)
	{
		case OSLinux:	ostype = "LIN";
		case OSWindows:	ostype = "WIN";
		default:		ostype = "UNK";
	}
	
	SetFailState("[%s | %i] %s", ostype, gEngineVersion, buff);
}

stock bool IsValidMovementTrace(CGameMovement pThis, CGameTrace tr)
{
	if(tr.allsolid || tr.startsolid)
		return false;
	
	if(CloseEnoughFloat(tr.fraction, 0.0))
		return false;
	
	Vector plane_normal = tr.plane.normal;
	if(FloatAbs(plane_normal.x) > 1.0 || FloatAbs(plane_normal.y) > 1.0 || FloatAbs(plane_normal.z) > 1.0)
		return false;
	
	CGameTrace stuck = CGameTrace();
	
	TracePlayerBBox(pThis, tr.endpos, tr.endpos, MASK_PLAYERSOLID, COLLISION_GROUP_PLAYER_MOVEMENT, stuck);
	if(stuck.startsolid || !CloseEnoughFloat(stuck.fraction, 1.0))
	{
		stuck.Free();
		return false;
	}
	
	stuck.Free();
	return true;
}

stock void UTIL_TraceRay(Ray_t ray, int mask, CGameMovement gm, int collisionGroup, CGameTrace trace)
{
	if(gEngineVersion == Engine_CSGO)
	{
		CTraceFilterSimple filter = LockTraceFilter(gm, collisionGroup);
		
		gm.m_nTraceCount++;
		ITraceListData tracelist = gm.m_pTraceListData;
		
		if(tracelist.Address != Address_Null && tracelist.CanTraceRay(ray))
			TraceRayAgainstLeafAndEntityList(ray, tracelist, mask, filter, trace);
		else
			TraceRay(ray, mask, filter, trace);
		
		UnlockTraceFilter(gm, filter);
	}
	else if(gEngineVersion == Engine_CSS)
	{
		CTraceFilterSimple filter = CTraceFilterSimple();
		filter.Init(LookupEntity(gm.mv.m_nPlayerHandle), collisionGroup);
		
		TraceRay(ray, mask, filter, trace);
		
		filter.Free();
	}
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	RegPluginLibrary("momsurffix2");
	
	return APLRes_Success;
}