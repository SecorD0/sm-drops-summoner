#pragma semicolon 1
#pragma newdecls required
#include <sdktools>
#include <dhooks>
#include <telegram>
#include <ripext>

public Plugin myinfo =
{
	name = "Drops Summoner",
	author = "SecorD",
	version = "1.0.0",
	url = "https://github.com/SecorD0/sm-drops-summoner"
};

bool g_bWindows;
Handle g_hRewardMatchEndDrops = null;
Handle g_hTimerWaitDrops = null;
Address g_pDropForAllPlayersPatch = Address_Null;
char g_szLogFile[256];
ConVar g_hDSWaitTimer = null;
ConVar g_hDSInfo = null;
ConVar g_hDSPlaySound = null;
int m_pPersonaDataPublic = -1;
ConVar g_hDSIgnoreNonPrime = null;

public void OnPluginStart()
{
	GameData hGameData = LoadGameConfigFile("DropsSummoner.games");
	if (!hGameData)
	{
		SetFailState("Failed to load DropsSummoner gamedata.");
		
		return;
	}

	char szBuf[14];
	GetCommandLine(szBuf, sizeof szBuf);
	g_bWindows = strcmp(szBuf, "./srcds_linux") != 0;
	
	StartPrepSDKCall(g_bWindows ? SDKCall_Static : SDKCall_Raw);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "CCSGameRules::RewardMatchEndDrops");
	PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_Plain);
	if (!(g_hRewardMatchEndDrops = EndPrepSDKCall()))
	{
		SetFailState("Failed to create call for CCSGameRules::RewardMatchEndDrops");
		
		return;
	}
	
	DynamicDetour hCCSGameRules_RecordPlayerItemDrop = DynamicDetour.FromConf(hGameData, "CCSGameRules::RecordPlayerItemDrop");
	if (!hCCSGameRules_RecordPlayerItemDrop)
	{
		SetFailState("Failed to setup detour for CCSGameRules::RecordPlayerItemDrop");
		
		return;
	}
	
	if(!hCCSGameRules_RecordPlayerItemDrop.Enable(Hook_Post, Detour_RecordPlayerItemDrop))
	{
		SetFailState("Failed to detour CCSGameRules::RecordPlayerItemDrop.");
		
		return;
	}
	
	g_pDropForAllPlayersPatch = hGameData.GetAddress("DropForAllPlayersPatch");
	if(g_pDropForAllPlayersPatch != Address_Null)
	{
		// ja always false
		// 83 F8 01 ?? [cmp eax, 1]
		if((LoadFromAddress(g_pDropForAllPlayersPatch, NumberType_Int32) & 0xFFFFFF) == 0x1F883)
		{
			// 39 C0 [cmp eax, eax]
			StoreToAddress(g_pDropForAllPlayersPatch, 0xC039, NumberType_Int16);
			// 90 [nop]
			StoreToAddress(g_pDropForAllPlayersPatch + view_as<Address>(2), 0x90, NumberType_Int8);
		}
		else
		{
			g_pDropForAllPlayersPatch = Address_Null;
			
			LogError("At address g_pDropForAllPlayersPatch received not what we expected, drop for all players will be unavailable.");
		}
	}
	else
	{
		LogError("Failed to get address DropForAllPlayersPatch, drop for all players will be unavailable.");
	}
	
	hGameData.Close();
	
	m_pPersonaDataPublic = FindSendPropInfo("CCSPlayer", "m_unMusicID") + 0xA;
	
	BuildPath(Path_SM, g_szLogFile, sizeof g_szLogFile, "logs/DropsSummoner.log");
	
	g_hDSWaitTimer = CreateConVar("sm_drops_summoner_wait_timer", "610", "Delay between attempts to summon a drop in seconds", _, true, 60.0);
	g_hDSInfo = CreateConVar("sm_drops_summoner_info", "0", "Whether to notify in the chat of attempts to summon a drop", _, true, 0.0, true, 1.0);
	g_hDSPlaySound = CreateConVar("sm_drops_summoner_play_sound", "1", "Play a sound when someone get a drop [0 - no | 1 - only to the receiver | 2 - everyone]", _, true, 0.0, true, 2.0);
	g_hDSIgnoreNonPrime = CreateConVar("sm_drops_summoner_ignore_non_prime", "1", "Ignore drop for non-Prime players (doesn't affect logging)", _, true, 0.0, true, 1.0);
	
	AutoExecConfig(true, "DropsSummoner");
}

public void OnPluginEnd()
{
	if(g_pDropForAllPlayersPatch != Address_Null)
	{
		StoreToAddress(g_pDropForAllPlayersPatch, 0xF883, NumberType_Int16);
		StoreToAddress(g_pDropForAllPlayersPatch + view_as<Address>(2), 0x01, NumberType_Int8);
	}
}

public void OnMapStart()
{
	PrecacheSound("ui/panorama/case_awarded_1_uncommon_01.wav");
	
	CreateTimer(g_hDSWaitTimer.FloatValue, Timer_SendRewardMatchEndDrops, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

MRESReturn Detour_RecordPlayerItemDrop(DHookParam hParams)
{
	int iAccountID = hParams.GetObjectVar(1, 16, ObjectValueType_Int);
	int iClient = GetClientFromAccountID(iAccountID);
	
	if(iClient != -1)
	{
		bool bPrime = IsPrimeClient(iClient);
		int iDefIndex = hParams.GetObjectVar(1, 20, ObjectValueType_Int);
		int iPaintIndex = hParams.GetObjectVar(1, 24, ObjectValueType_Int);
		int iRarity = hParams.GetObjectVar(1, 28, ObjectValueType_Int);
		int iQuality = hParams.GetObjectVar(1, 32, ObjectValueType_Int);
		
		static const char szPrime[] = "non-prime";
		LogToFile(g_szLogFile, "Player %L<%s> received [%u-%u-%u-%u]", iClient, szPrime[bPrime ? 4 : 0], iDefIndex, iPaintIndex, iRarity, iQuality);
		
		if(!g_hDSIgnoreNonPrime.BoolValue || bPrime)
		{
			delete g_hTimerWaitDrops;

			char szCaseName[256];
			if(iDefIndex == 4001)
			{
				szCaseName = "CS:GO Weapon Case (2013)";
			}
			else if(iDefIndex == 4003)
			{
				szCaseName = "Operation Bravo Case (2013)";
			}
			else if(iDefIndex == 4004)
			{
				szCaseName = "CS:GO Weapon Case 2 (2013)";
			}
			else if(iDefIndex == 4007)
			{
				szCaseName = "Sticker Capsule (2014)";
			}
			else if(iDefIndex == 4009)
			{
				szCaseName = "Winter Offensive Weapon Case (2013)";
			}
			else if(iDefIndex == 4010)
			{
				szCaseName = "CS:GO Weapon Case 3 (2014)";
			}
			else if(iDefIndex == 4011)
			{
				szCaseName = "Operation Phoenix Weapon Case (2014)";
			}
			else if(iDefIndex == 4012)
			{
				szCaseName = "Sticker Capsule 2 (2014)";
			}
			else if(iDefIndex == 4016)
			{
				szCaseName = "Community Sticker Capsule 1 (2014)";
			}
			else if(iDefIndex == 4017)
			{
				szCaseName = "Huntsman Weapon Case (2014)";
			}
			else if(iDefIndex == 4018)
			{
				szCaseName = "Operation Breakout Weapon Case (2014)";
			}
			else if(iDefIndex == 4029)
			{
				szCaseName = "Operation Vanguard Weapon Case (2014)";
			}
			else if(iDefIndex == 4061)
			{
				szCaseName = "Chroma Case (2015)";
			}
			else if(iDefIndex == 4089)
			{
				szCaseName = "Chroma 2 Case (2015)";
			}
			else if(iDefIndex == 4091)
			{
				szCaseName = "Falchion Case (2015)";
			}
			else if(iDefIndex == 4138)
			{
				szCaseName = "Shadow Case (2015)";
			}
			else if(iDefIndex == 4186)
			{
				szCaseName = "Revolver Case (2015)";
			}
			else if(iDefIndex == 4187)
			{
				szCaseName = "Operation Wildfire Case (2016)";
			}
			else if(iDefIndex == 4233)
			{
				szCaseName = "Chroma 3 Case (2016)";
			}
			else if(iDefIndex == 4236)
			{
				szCaseName = "Gamma Case (2016)";
			}
			else if(iDefIndex == 4281)
			{
				szCaseName = "Gamma 2 Case (2016)";
			}
			else if(iDefIndex == 4288)
			{
				szCaseName = "Glove Case (2016)";
			}
			else if(iDefIndex == 4351)
			{
				szCaseName = "Spectrum Case (2017)";
			}
			else if(iDefIndex == 4352)
			{
				szCaseName = "Operation Hydra Case (2017)";
			}
			else if(iDefIndex == 4403)
			{
				szCaseName = "Spectrum 2 Case (2017)";
			}
			else if(iDefIndex == 4471)
			{
				szCaseName = "Clutch Case (2018)";
			}
			else if(iDefIndex == 4482)
			{
				szCaseName = "Horizon Case (2018)";
			}
			else if(iDefIndex == 4548)
			{
				szCaseName = "Danger Zone Case (2018)";
			}
			else if(iDefIndex == 4598)
			{
				szCaseName = "Prisma Case (2019)";
			}
			else if(iDefIndex == 4669)
			{
				szCaseName = "CS20 Case (2019)";
			}
			else if(iDefIndex == 4695)
			{
				szCaseName = "Prisma 2 Case (2020)";
			}
			else if(iDefIndex == 4698)
			{
				szCaseName = "Fracture Case (2020)";
			}
			else if(iDefIndex == 4747)
			{
				szCaseName = "Snakebite Case (2021)";
			}
			else if(iDefIndex == 4818)
			{
				szCaseName = "Dreams & Nightmares Case (2022)";
			}
			else if(iDefIndex == 4846)
			{
				szCaseName = "Recoil Case (2022)";
			}
			else if(iDefIndex == 4880)
			{
				szCaseName = "Revolution Case (2023)";
			}
			else
			{
				Format(szCaseName, sizeof szCaseName, "unidentified item with the following ID: %u", iDefIndex);
			}

			char szTelegramMessage[256];
			Format(szTelegramMessage, sizeof szTelegramMessage, "*%N* received *%s*", iClient, szCaseName);
			Telegram_SendMessage(szTelegramMessage, "markdown");

			char szSteam2[256];
			GetClientAuthId(iClient, AuthId_Steam2, szSteam2, sizeof(szSteam2));
			ServerCommand("sm_kick #%s you received an item", szSteam2);

			Protobuf hSendPlayerItemFound = view_as<Protobuf>(StartMessageAll("SendPlayerItemFound", USERMSG_RELIABLE));
			hSendPlayerItemFound.SetInt("entindex", iClient);

			Protobuf hIteminfo = hSendPlayerItemFound.ReadMessage("iteminfo");
			hIteminfo.SetInt("defindex", iDefIndex);
			hIteminfo.SetInt("paintindex", iPaintIndex);
			hIteminfo.SetInt("rarity", iRarity);
			hIteminfo.SetInt("quality", iQuality);
			hIteminfo.SetInt("inventory", 6); // UNACK_ITEM_GIFTED

			EndMessage();

			SetHudTextParams(-1.0, 0.4, 3.0, 0, 255, 255, 255);
			ShowHudText(iClient, -1, "You received an item, see your inventory");

			int iPlaySound = g_hDSPlaySound.IntValue;

			if(iPlaySound == 2)
			{
				EmitSoundToAll("ui/panorama/case_awarded_1_uncommon_01.wav", SOUND_FROM_LOCAL_PLAYER, _, SNDLEVEL_NONE);
			}
			else if(iPlaySound == 1)
			{
				EmitSoundToClient(iClient, "ui/panorama/case_awarded_1_uncommon_01.wav", SOUND_FROM_LOCAL_PLAYER, _, SNDLEVEL_NONE);
			}
		}
	}
	
	return MRES_Ignored;
}

int GetClientFromAccountID(int iAccountID)
{
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientConnected(i) && !IsFakeClient(i))
		{
			if(GetSteamAccountID(i, false) == iAccountID)
			{
				return i;
			}
		}
	}
	
	return -1;
}

bool IsPrimeClient(int iClient)
{
	Address pPersonaDataPublic = view_as<Address>(GetEntData(iClient, m_pPersonaDataPublic));
	if(pPersonaDataPublic != Address_Null)
	{
		return view_as<bool>(LoadFromAddress(pPersonaDataPublic + view_as<Address>(20), NumberType_Int8));
	}
	
	return false;
}

Action Timer_SendRewardMatchEndDrops(Handle hTimer)
{
	if(g_hDSInfo.BoolValue)
	{
		g_hTimerWaitDrops = CreateTimer(1.2, Timer_WaitDrops);
		
		PrintToChatAll(" \x07Trying to summon a drop.");
	}
	
	if(g_bWindows)
	{
		SDKCall(g_hRewardMatchEndDrops, false);
	}
	else
	{
		SDKCall(g_hRewardMatchEndDrops, 0xDEADC0DE, false);
	}
	
	return Plugin_Continue;
}

Action Timer_WaitDrops(Handle hTimer)
{
	g_hTimerWaitDrops = null;
	
	PrintToChatAll(" \x07Attempt failed!");
	
	return Plugin_Continue;
}