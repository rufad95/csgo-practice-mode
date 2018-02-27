#define REPLAY_NAME_LENGTH 128
#define REPLAY_ROLE_DESCRIPTION_LENGTH 256
#define REPLAY_ID_LENGTH 16
#define MAX_REPLAY_CLIENTS 5
#define DEFAULT_REPLAY_NAME "unnamed - use .namereplay on me!"

// Ideas:
// 1. ADD A WARNING WHEN YOU NADE TOO EARLY IN THE REPLAY!
// 2. Does practicemode-saved nade data respect cancellation?

// If any data has been changed since load, this should be set.
// All Set* data methods should set this to true.
bool g_UpdatedReplayKv = false;

bool g_RecordingFullReplay = false;
// TODO: find when to reset g_RecordingFullReplayClient
int g_RecordingFullReplayClient = -1;

bool g_StopBotSignal[MAXPLAYERS + 1];

float g_CurrentRecordingStartTime[MAXPLAYERS + 1];

// TODO: collapse these into 1 variable
int g_CurrentRecordingRole[MAXPLAYERS + 1];  // Only set if the client is actively recording.
int g_CurrentEditingRole[MAXPLAYERS +
                         1];  // Only set if the client is actively editing (OR recording).

// TODO: make g_ReplayId per-client
char g_ReplayId[MAXPLAYERS + 1][REPLAY_ID_LENGTH];
int g_ReplayBotClients[MAX_REPLAY_CLIENTS];

int g_CurrentReplayNadeIndex[MAXPLAYERS + 1];
ArrayList g_NadeReplayData[MAXPLAYERS + 1];

// TODO: cvar/setting?
bool g_BotReplayChickenMode = false;

public void BotReplay_MapStart() {
  g_BotInit = false;
  delete g_ReplaysKv;
  g_ReplaysKv = new KeyValues("Replays");

  char map[PLATFORM_MAX_PATH];
  GetCleanMapName(map, sizeof(map));

  char replayFile[PLATFORM_MAX_PATH + 1];
  BuildPath(Path_SM, replayFile, sizeof(replayFile), "data/practicemode/replays/%s.cfg", map);
  g_ReplaysKv.ImportFromFile(replayFile);

  for (int i = 0; i <= MaxClients; i++) {
    delete g_NadeReplayData[i];
    g_NadeReplayData[i] = new ArrayList(14);
  }
}

public void BotReplay_MapEnd() {
  MaybeWriteNewReplayData();
  GarbageCollectReplays();
}

public void Replays_OnThrowGrenade(int entity, int client, GrenadeType grenadeType, const float origin[3],
                            const float velocity[3]) {
  if (g_CurrentRecordingRole[client] >= 0) {
    float delay = GetGameTime() - g_CurrentRecordingStartTime[client];
    float personOrigin[3];
    float personAngles[3];
    GetClientAbsOrigin(client, personOrigin);
    GetClientEyeAngles(client, personAngles);
    AddReplayNade(client, grenadeType, delay, personOrigin, personAngles, origin, velocity);
  }

  if (BotMimic_IsPlayerMimicing(client)) {
    int index = g_CurrentReplayNadeIndex[client];
    int length = g_NadeReplayData[client].Length;
    if (index < length) {
      float delay = 0.0;
      GrenadeType type;
      float personOrigin[3];
      float personAngles[3];
      float nadeOrigin[3];
      float nadeVelocity[3];
      GetReplayNade(client, index, type, delay, personOrigin, personAngles, nadeOrigin,
                    nadeVelocity);
      TeleportEntity(entity, nadeOrigin, NULL_VECTOR, nadeVelocity);
      g_CurrentReplayNadeIndex[client]++;
    }
  }
}

public Action Timer_GetBots(Handle timer) {
  g_BotInit = true;

  for (int i = 0; i < MAX_REPLAY_CLIENTS; i++) {
    char name[MAX_NAME_LENGTH];
    Format(name, sizeof(name), "Replay Bot %d", i + 1);
    if (!IsReplayBot(g_ReplayBotClients[i])) {
      g_ReplayBotClients[i] = GetLiveBot(name);
    }
  }

  return Plugin_Handled;
}

void InitReplayFunctions() {
  ResetData();
  for (int i = 0; i < MAX_REPLAY_CLIENTS; i++) {
    g_ReplayBotClients[i] = -1;
  }

  GetReplayBots();

  g_BotInit = true;
  g_InBotReplayMode = true;
  g_RecordingFullReplay = false;

  // Settings we need to have the mode work
  DisableSettingById("respawning");
  ServerCommand("mp_death_drop_gun 1");
}

public void GetReplayBots() {
  ServerCommand("bot_quota_mode normal");
  for (int i = 0; i < MAX_REPLAY_CLIENTS; i++) {
    if (!IsReplayBot(i)) {
      ServerCommand("bot_add");
    }
  }

  CreateTimer(0.1, Timer_GetBots);
}

public Action Command_Replay(int client, int args) {
  if (!g_InPracticeMode) {
    return Plugin_Handled;
  }

  if (!g_BotMimicLoaded) {
    PM_Message(client, "You need the botmimic plugin loaded to use replay functions.");
    return Plugin_Handled;
  }

  if (!g_CSUtilsLoaded) {
    PM_Message(client, "You need the csutils plugin loaded to use replay functions.");
    return Plugin_Handled;
  }

  if (!g_BotInit) {
    InitReplayFunctions();
  }

  // TODO: if given an arg, set the client's active replay to that id.
  if (HasActiveReplay(client)) {
    if (g_CurrentEditingRole[client] >= 0) {
      // Replay-role specific menu.
      GiveReplayRoleMenu(client, g_CurrentEditingRole[client]);
    } else {
      // Replay-specific menu.
      GiveReplayEditorMenu(client);
    }
  } else {
    // All replays menu.
    GiveMainReplaysMenu(client);
  }

  return Plugin_Handled;
}

public Action Command_Replays(int client, int args) {
  if (!g_InPracticeMode) {
    return Plugin_Handled;
  }

  if (!g_BotMimicLoaded) {
    PM_Message(client, "You need the botmimic plugin loaded to use replay functions.");
    return Plugin_Handled;
  }

  if (!g_CSUtilsLoaded) {
    PM_Message(client, "You need the csutils plugin loaded to use replay functions.");
    return Plugin_Handled;
  }

  if (!g_BotInit) {
    InitReplayFunctions();
  }

  GiveMainReplaysMenu(client);
  return Plugin_Handled;
}

public Action Command_NameReplay(int client, int args) {
  if (!g_InPracticeMode) {
    return Plugin_Handled;
  }

  if (!HasActiveReplay(client)) {
    return Plugin_Handled;
  }

  char buffer[REPLAY_NAME_LENGTH];
  GetCmdArgString(buffer, sizeof(buffer));
  if (StrEqual(buffer, "")) {
    PM_Message(client, "You didn't give a name! Use: .namereplay <name>.");
  } else {
    PM_Message(client, "Saved replay name.");
    SetReplayName(g_ReplayId[client], buffer);
  }
  return Plugin_Handled;
}

public Action Command_NameRole(int client, int args) {
  if (!g_InPracticeMode) {
    return Plugin_Handled;
  }

  if (!HasActiveReplay(client)) {
    return Plugin_Handled;
  }

  if (g_CurrentEditingRole[client] < 0) {
    return Plugin_Handled;
  }

  char buffer[REPLAY_NAME_LENGTH];
  GetCmdArgString(buffer, sizeof(buffer));
  if (StrEqual(buffer, "")) {
    PM_Message(client, "You didn't give a name! Use: .namerole <name>.");
  } else {
    PM_Message(client, "Saved role %d name.", g_CurrentEditingRole[client]);
    SetRoleName(g_ReplayId[client], g_CurrentEditingRole[client], buffer);
  }
  return Plugin_Handled;
}

public void ResetData() {
  for (int i = 0; i < MAX_REPLAY_CLIENTS; i++) {
    g_StopBotSignal[i] = false;
  }
  for (int i = 0; i <= MaxClients; i++) {
    g_CurrentRecordingRole[i] = -1;
    g_CurrentEditingRole[i] = -1;
    g_ReplayId[i] = "";
  }
}

public void BotMimic_OnPlayerMimicLoops(int client) {
  if (!g_InPracticeMode) {
    return;
  }

  if (g_StopBotSignal[client]) {
    BotMimic_ResetPlayback(client);
    BotMimic_StopPlayerMimic(client);
    RequestFrame(Timer_DelayKillBot, GetClientSerial(client));
  } else {
    g_StopBotSignal[client] = true;
  }
}
