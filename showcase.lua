local SSS = game:GetService('ServerScriptService')
local CurrentGame = SSS:FindFirstChild('CurrentGame')

local RS = game:GetService('ReplicatedStorage')
local OriginalCases = RS:FindFirstChild('Briefcases')

function startGame(Player)
	CurrentGame:FindFirstChild('Cases'):ClearAllChildren()
	CurrentGame:FindFirstChild('PlayerCase'):ClearAllChildren()
	CurrentGame:FindFirstChild('OpenedCases'):ClearAllChildren()
	CurrentGame:FindFirstChild('State').Value = "Creating Cases"
	
	CurrentGame:FindFirstChild('Player').Value = Player
	
	local ClonedCases = OriginalCases:Clone()
	
	for i = 1, 26 do
		local NewCase = Instance.new('NumberValue')
		NewCase.Name = i
		
		local RandomSelected = ClonedCases:GetChildren()[math.random(1,#ClonedCases:GetChildren())]
		NewCase.Value = RandomSelected.Value
		NewCase.Parent = CurrentGame:FindFirstChild('Cases')
		RandomSelected:Destroy()
	end
	
	CurrentGame:FindFirstChild('State').Value = "Player Choose Case"
	RS.Assets.Instructions:FireClient(Player, 'Please choose your case!')
	repeat wait() until CurrentGame:FindFirstChild('State').Value ~= "Player Choose Case"
	local ElimsLeft = 6
	repeat
		CurrentGame:FindFirstChild("State").Value = "Remove Cases"
		CurrentGame:FindFirstChild('ElimsLeft').Value = ElimsLeft
		RS.Assets.Instructions:FireClient(Player, 'Please choose ' .. tostring(ElimsLeft) .. ' cases to remove.')
		ElimsLeft = math.clamp(ElimsLeft-1, 1, 6)

		repeat wait() until CurrentGame:FindFirstChild("ElimsLeft").Value == 0

		local total = 0
		local number = 0

		for _, Case in pairs(CurrentGame:FindFirstChild('Cases'):GetChildren()) do
			total += Case.Value
			number += 1
		end

		CurrentGame:FindFirstChild('DealAmount').Value = math.round(total/number)

		RS.Assets.Instructions:FireClient(Player, "The banker has offered you $" .. tostring(CurrentGame:FindFirstChild('DealAmount').Value) .. ".")

		RS.Assets.DealOrNoDeal:FireClient(Player, 'Start')

		CurrentGame:FindFirstChild('State').Value = "Deal Or No Deal"

		repeat wait() until CurrentGame:FindFirstChild('State').Value ~= "Deal Or No Deal"
	until CurrentGame:FindFirstChild('State').Value == "Game Over"
	
	
	
end

game.Players.PlayerAdded:Connect(function(Player)
	task.wait(10)
	
	startGame(Player)
end)

RS.Assets.Deal.OnServerEvent:Connect(function(Player)
	if CurrentGame:FindFirstChild('State').Value == "Deal Or No Deal" then
		Player.leaderstats.Money.Value += CurrentGame:FindFirstChild('DealAmount').Value
		CurrentGame:FindFirstChild('State').Value = "Game Over"
		RS.Assets.DealOrNoDeal:FireClient(Player, 'End')
	end
end)

RS.Assets.NoDeal.OnServerEvent:Connect(function(Player)
	if CurrentGame:FindFirstChild('State').Value == "Deal Or No Deal" then
		CurrentGame:FindFirstChild('State').Value = "No Deal"
		RS.Assets.DealOrNoDeal:FireClient(Player, 'End')
	end
end)

RS.Assets.ChooseCase.OnServerEvent:Connect(function(Player, Case)
	if CurrentGame:FindFirstChild('State').Value == "Player Choose Case" then
		if #CurrentGame:FindFirstChild('PlayerCase'):GetChildren() > 0 then return end
		if CurrentGame:FindFirstChild('Cases'):FindFirstChild(Case) then
			CurrentGame:FindFirstChild('Cases'):FindFirstChild(Case).Parent = CurrentGame:FindFirstChild('PlayerCase')
			CurrentGame:FindFirstChild("State").Value = "Remove Cases"
			RS.Assets.CaseTaken:FireClient(Player, Case, Color3.new(0,1,0))
		end
	elseif CurrentGame:FindFirstChild('State').Value == "Remove Cases" and CurrentGame:FindFirstChild('ElimsLeft').Value > 0 then
		if CurrentGame:FindFirstChild('Cases'):FindFirstChild(Case) then
			CurrentGame:FindFirstChild('ElimsLeft').Value -= 1
			RS.Assets.Instructions:FireClient(Player, 'Please choose ' .. tostring(CurrentGame:FindFirstChild('ElimsLeft').Value) .. ' cases to remove.')
			CurrentGame:FindFirstChild('Cases'):FindFirstChild(Case).Parent = CurrentGame:FindFirstChild('OpenedCases')
			RS.Assets.CaseTaken:FireClient(Player, Case, Color3.new(1,0,0), CurrentGame:FindFirstChild('OpenedCases'):FindFirstChild(Case).Value)
		end
	end
end)
