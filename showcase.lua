-- Services
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PlayerDataStore = DataStoreService:GetDataStore("PlayerData_v3")

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
-- Balancing Settings
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

local AUTOSAVE_INTERVAL = 120
local CLICK_COOLDOWN = 0.05
local MAX_CLICK_BURST = 25

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

-- Remotes
local ClickRemote = Remotes:WaitForChild("ProcessClick")
local UpgradeRemote = Remotes:WaitForChild("PurchaseUpgrade")
local RebirthRemote = Remotes:WaitForChild("PerformRebirth")
local DataSyncRemote = Remotes:WaitForChild("DataSync")
local SettingsRemote = Remotes:WaitForChild("UpdateSetting")

local SessionData = {}
local ClickTimestamps = {}

-- Copy data table
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
-- In case new data is added
local function ReconcileData(saved, template)
	for key, default in template do
		if saved[key] == nil then
			saved[key] = DeepCopy(default)
		elseif type(default) == "table" and type(saved[key]) == "table" then
			ReconcileData(saved[key], default)
		end
	end
end
-- Load Data
local function LoadPlayerData(player: Player)
	local userId = player.UserId
	local data = nil
	local success, err = nil, nil

	for attempt = 1, 3 do
		success, err = pcall(function()
			data = PlayerDataStore:GetAsync("Player_" .. userId)
		end)

		if success then
			break
		end

		task.wait(attempt * 2)
	end

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
-- Save Data
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
-- Top Right Leaderstats
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
-- Update client with server authenticated information
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
-- Calculate scaling
local function GetUpgradeCost(upgradeType: string, currentLevel: number): number
	local config = UPGRADE_CONFIG[upgradeType]
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

local function CalculateClickValue(data): number
	local base = data.Upgrades.ClickPower
	local multiplier = data.Upgrades.Multiplier
	local rebirthBonus = 1 + (data.Rebirths * 0.1)

	return math.floor(base * multiplier * rebirthBonus)
end

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
-- Process actions
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

	local clicksPerTick = math.floor(autoLevel * 0.5 * (1 + data.Rebirths * 0.1))
	if clicksPerTick < 1 then
		clicksPerTick = 1
	end

	data.Clicks += clicksPerTick
	data.TotalClicks += clicksPerTick
end
-- Join / Leave Handling
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

	if SessionData[userId] then
		SavePlayerData(player)
		SessionData[userId] = nil
	end

	ClickTimestamps[userId] = nil
end
-- Actions connection
ClickRemote.OnServerEvent:Connect(ProcessClick)

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

	if type(value) ~= type(data.Settings[settingName]) then
		return false
	end

	data.Settings[settingName] = value
	return true
end

Players.PlayerAdded:Connect(OnPlayerAdded)
Players.PlayerRemoving:Connect(OnPlayerRemoving)

for _, player in Players:GetPlayers() do
	task.spawn(OnPlayerAdded, player)
end
-- Data Saving on interval and server reset.
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

game:BindToClose(function()
	for userId, data in SessionData do
		local player = Players:GetPlayerByUserId(userId)
		if player then
			SavePlayerData(player)
		end
	end
end)
