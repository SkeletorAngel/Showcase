local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerDataStore = DataStoreService:GetDataStore("PlayerData_v3")

-- ClickPower starts at 1 so new players still earn something per click
-- AutoClickSpeed at 0 means no passive income until they buy it
local DATA_TEMPLATE = {
	Clicks = 0,
	TotalClicks = 0,
	Gems = 0,
	Rebirths = 0,
	Upgrades = {
		ClickPower = 1,
		AutoClickSpeed = 0,
		Multiplier = 1,
	},
	Settings = {
		SFXEnabled = true,
		VFXEnabled = true,
	},
}

local UPGRADE_CONFIG = {
	ClickPower = {
		BaseCost = 50,
		CostScaling = 1.35,
		MaxLevel = 500,
	},
	AutoClickSpeed = {
		BaseCost = 200,
		CostScaling = 1.5,
		MaxLevel = 100,
	},
	Multiplier = {
		BaseCost = 1000,
		CostScaling = 1.75,
		MaxLevel = 50,
	},
}

local REBIRTH_CONFIG = {
	BaseRequirement = 100000,
	RequirementScaling = 2.5,
	GemReward = 10,
	GemScaling = 1.2,
}

-- 120s is a safe middle ground, fast enough to not lose much on a crash but slow enough to not throttle the datastore
local AUTOSAVE_INTERVAL = 120
local CLICK_COOLDOWN = 0.05
-- anything past 25 clicks in a 1 second window is almost certainly an autoclicker
local MAX_CLICK_BURST = 25

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local ClickRemote = Remotes:WaitForChild("ProcessClick")
local UpgradeRemote = Remotes:WaitForChild("PurchaseUpgrade")
local RebirthRemote = Remotes:WaitForChild("PerformRebirth")
local DataSyncRemote = Remotes:WaitForChild("DataSync")
local SettingsRemote = Remotes:WaitForChild("UpdateSetting")

-- all player data lives here during the session, only touches the datastore on save/load
local SessionData = {}
-- tracks timestamps per player so we can detect click spam
local ClickTimestamps = {}

local function DeepCopy(original)
	if type(original) ~= "table" then
		return original
	end

	local copy = {}
	for key, value in original do
		copy[key] = DeepCopy(value)
	end
	return copy
end

-- fills in any missing keys so old saves don't break when we add new fields to the template
local function ReconcileData(saved, template)
	for key, default in template do
		if saved[key] == nil then
			saved[key] = DeepCopy(default)
		elseif type(default) == "table" and type(saved[key]) == "table" then
			ReconcileData(saved[key], default)
		end
	end
end

local function LoadPlayerData(player: Player)
	local userId = player.UserId
	local data = nil
	local success, err = nil, nil

	-- retry up to 3 times with increasing wait (2s, 4s, 6s) in case of datastore hiccups
	for attempt = 1, 3 do
		success, err = pcall(function()
			data = PlayerDataStore:GetAsync("Player_" .. userId)
		end)

		if success then
			break
		end

		task.wait(attempt * 2)
	end

	-- better to kick than let them play with no saving
	if not success then
		warn(`Failed to load data for {player.Name}: {err}`)
		player:Kick("Unable to load your data. Please rejoin.")
		return nil
	end

	if data then
		ReconcileData(data, DATA_TEMPLATE)
	else
		data = DeepCopy(DATA_TEMPLATE)
	end

	return data
end

local function SavePlayerData(player: Player)
	local userId = player.UserId
	local data = SessionData[userId]
	if not data then
		return false
	end

	local success, err = pcall(function()
		PlayerDataStore:SetAsync("Player_" .. userId, data)
	end)

	if not success then
		warn(`Failed to save data for {player.Name}: {err}`)
	end

	return success
end

-- top right leaderstats
local function SetupLeaderstats(player: Player, data)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"

	local clicksStat = Instance.new("NumberValue")
	clicksStat.Name = "Clicks"
	clicksStat.Value = data.Clicks
	clicksStat.Parent = leaderstats

	local gemsStat = Instance.new("NumberValue")
	gemsStat.Name = "Gems"
	gemsStat.Value = data.Gems
	gemsStat.Parent = leaderstats

	local rebirthStat = Instance.new("IntValue")
	rebirthStat.Name = "Rebirths"
	rebirthStat.Value = data.Rebirths
	rebirthStat.Parent = leaderstats

	leaderstats.Parent = player
end

local function UpdateLeaderstats(player: Player, data)
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then
		return
	end

	leaderstats.Clicks.Value = data.Clicks
	leaderstats.Gems.Value = data.Gems
	leaderstats.Rebirths.Value = data.Rebirths
end

-- sends everything the client UI needs to stay up to date
local function SyncToClient(player: Player, data)
	DataSyncRemote:FireClient(player, {
		Clicks = data.Clicks,
		TotalClicks = data.TotalClicks,
		Gems = data.Gems,
		Rebirths = data.Rebirths,
		Upgrades = data.Upgrades,
		Settings = data.Settings,
	})
end

local function GetUpgradeCost(upgradeType: string, currentLevel: number): number
	local config = UPGRADE_CONFIG[upgradeType]
	-- anti-exploit
	if not config then
		return math.huge
	end

	return math.floor(config.BaseCost * config.CostScaling ^ (currentLevel - 1))
end

local function GetRebirthRequirement(rebirthCount: number): number
	return math.floor(
		REBIRTH_CONFIG.BaseRequirement * REBIRTH_CONFIG.RequirementScaling ^ rebirthCount
	)
end

local function GetRebirthGemReward(rebirthCount: number): number
	return math.floor(
		REBIRTH_CONFIG.GemReward * REBIRTH_CONFIG.GemScaling ^ rebirthCount
	)
end

-- 10% per rebirth
local function CalculateClickValue(data): number
	local base = data.Upgrades.ClickPower
	local multiplier = data.Upgrades.Multiplier
	local rebirthBonus = 1 + (data.Rebirths * 0.1)

	return math.floor(base * multiplier * rebirthBonus)
end

-- sliding window rate limiter, drops timestamps older than 1 second then checks if they've hit the cap
local function IsClickRateLimited(player: Player): boolean
	local userId = player.UserId
	local now = os.clock()

	if not ClickTimestamps[userId] then
		ClickTimestamps[userId] = {}
	end

	local timestamps = ClickTimestamps[userId]

	while #timestamps > 0 and (now - timestamps[1]) > 1 do
		table.remove(timestamps, 1)
	end

	if #timestamps >= MAX_CLICK_BURST then
		return true
	end

	table.insert(timestamps, now)
	return false
end

local function ProcessClick(player: Player)
	local data = SessionData[player.UserId]
	if not data then
		return
	end

	if IsClickRateLimited(player) then
		return
	end

	local clickValue = CalculateClickValue(data)
	data.Clicks += clickValue
	data.TotalClicks += clickValue

	UpdateLeaderstats(player, data)
	SyncToClient(player, data)
end

local function ProcessUpgrade(player: Player, upgradeType: string): (boolean, string?)
	local data = SessionData[player.UserId]
	if not data then
		return false, "NoData"
	end

	local config = UPGRADE_CONFIG[upgradeType]
	if not config then
		return false, "InvalidUpgrade"
	end

	local currentLevel = data.Upgrades[upgradeType]
	if currentLevel >= config.MaxLevel then
		return false, "MaxLevel"
	end

	local cost = GetUpgradeCost(upgradeType, currentLevel)
	if data.Clicks < cost then
		return false, "NotEnoughClicks"
	end

	data.Clicks -= cost
	data.Upgrades[upgradeType] += 1

	UpdateLeaderstats(player, data)
	SyncToClient(player, data)

	return true, nil
end

local function ProcessRebirth(player: Player): (boolean, string?)
	local data = SessionData[player.UserId]
	if not data then
		return false, "NoData"
	end

	local requirement = GetRebirthRequirement(data.Rebirths)
	if data.Clicks < requirement then
		return false, "NotEnoughClicks"
	end

	local gemReward = GetRebirthGemReward(data.Rebirths)

	-- wipe clicks and upgrades back to defaults
	data.Clicks = 0
	data.TotalClicks = 0
	data.Rebirths += 1
	data.Gems += gemReward

	data.Upgrades.ClickPower = 1
	data.Upgrades.AutoClickSpeed = 0
	data.Upgrades.Multiplier = 1

	UpdateLeaderstats(player, data)
	SyncToClient(player, data)

	return true, nil
end

local function ProcessAutoClicks(player: Player, data)
	local autoLevel = data.Upgrades.AutoClickSpeed
	if autoLevel <= 0 then
		return
	end

	-- 0.5 per level keeps it from outpacing manual clicks too early, rebirth bonus still applies here
	local clicksPerTick = math.floor(autoLevel * 0.5 * (1 + data.Rebirths * 0.1))
	if clicksPerTick < 1 then
		clicksPerTick = 1
	end

	data.Clicks += clicksPerTick
	data.TotalClicks += clicksPerTick
end

local function OnPlayerAdded(player: Player)
	local data = LoadPlayerData(player)
	if not data then
		return
	end

	SessionData[player.UserId] = data
	SetupLeaderstats(player, data)
	SyncToClient(player, data)
end

local function OnPlayerRemoving(player: Player)
	local userId = player.UserId

	-- nil out their session so it doesn't sit in memory after they leave
	if SessionData[userId] then
		SavePlayerData(player)
		SessionData[userId] = nil
	end

	ClickTimestamps[userId] = nil
end

ClickRemote.OnServerEvent:Connect(ProcessClick)

-- don't trust what the client sends, exploiters can pass whatever they want through remotes
UpgradeRemote.OnServerInvoke = function(player: Player, upgradeType: string)
	if type(upgradeType) ~= "string" then
		return false, "InvalidInput"
	end

	return ProcessUpgrade(player, upgradeType)
end

RebirthRemote.OnServerInvoke = function(player: Player)
	return ProcessRebirth(player)
end

SettingsRemote.OnServerInvoke = function(player: Player, settingName: string, value: any)
	if type(settingName) ~= "string" then
		return false
	end

	local data = SessionData[player.UserId]
	if not data then
		return false
	end

	if data.Settings[settingName] == nil then
		return false
	end

	-- type check the value against what's already stored
	if type(value) ~= type(data.Settings[settingName]) then
		return false
	end

	data.Settings[settingName] = value
	return true
end

Players.PlayerAdded:Connect(OnPlayerAdded)
Players.PlayerRemoving:Connect(OnPlayerRemoving)

-- catches anyone who joined before this script connected
for _, player in Players:GetPlayers() do
	task.spawn(OnPlayerAdded, player)
end

-- runs every second, ticking once per second keeps the numbers predictable for balancing
task.spawn(function()
	while true do
		task.wait(1)
		for userId, data in SessionData do
			local player = Players:GetPlayerByUserId(userId)
			if player then
				ProcessAutoClicks(player, data)
				UpdateLeaderstats(player, data)
			end
		end
	end
end)

-- each save is spawned separately so one player's datastore timeout doesn't hold up the rest
task.spawn(function()
	while true do
		task.wait(AUTOSAVE_INTERVAL)
		for userId, data in SessionData do
			local player = Players:GetPlayerByUserId(userId)
			if player then
				task.spawn(SavePlayerData, player)
			end
		end
	end
end)

-- prevents data loss on shutdowns
game:BindToClose(function()
	for userId, data in SessionData do
		local player = Players:GetPlayerByUserId(userId)
		if player then
			SavePlayerData(player)
		end
	end
end)
