--[[ ?? MINE A MOUNTAIN BOT v10 - MAX EXPLOITS + SHARP GUI ]]
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

print("=== MINE A MOUNTAIN BOT v10 - MAX EXPLOITS LOADED ===")
StarterGui:SetCore("SendNotification",{Title="? v10 MAX",Text="All Exploits + Sharp GUI",Duration=6})

-- CONFIG
local Config = {
    AutoMine = false,
    AutoCollect = true,
    AutoSell = true,
    FastMine = true,
    MineSpeed = 50,
    ESP = true,
    ShowValueOnESP = true,
    AntiFreeze = true,
    GodMode = false,
    AutoUpgrade = false,
}

local State = { 
    ESPObjects = {}, 
    minimized = false, 
    dragging = false, 
    dragStart = nil, 
    dragPos = nil,
    upgradeSpamRunning = false
}

-- REMOTE SCANNER
local function GetRemotes()
    local remotes = {}
    for _,v in ipairs(ReplicatedStorage:GetDescendants()) do
        if v:IsA("RemoteEvent") or v:IsA("RemoteFunction") then
            remotes[v.Name:lower()] = v
        end
    end
    return remotes
end

local Remotes = GetRemotes()

local function Fire(name, ...)
    for k, remote in pairs(Remotes) do
        if k:find(name:lower()) then
            pcall(function()
                if remote:IsA("RemoteEvent") then remote:FireServer(...) else remote:InvokeServer(...) end
            end)
            return true
        end
    end
    return false
end

-- UTILITY
local function GetHRP()
    local c = LocalPlayer.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function TeleportToRock(ore)
    local hrp = GetHRP()
    if hrp and ore then
        hrp.CFrame = ore.CFrame * CFrame.new(0, 4.8, 0)
        hrp.Velocity = Vector3.new(0,0,0)
    end
end

local function GetMineableOres()
    local ores = {}
    for _,obj in ipairs(Workspace:GetDescendants()) do
        if (obj:IsA("BasePart") or obj:IsA("MeshPart")) and obj.Transparency < 1 then
            local n = obj.Name:lower()
            if n:find("ore") or n:find("crystal") or n:find("rock") or n:find("gem") then
                table.insert(ores, obj)
            end
        end
    end
    return ores
end

local function GetValue(obj)
    if not obj then return 0 end
    local v = obj:GetAttribute("Value") or obj:GetAttribute("Price") or obj:GetAttribute("SellPrice")
    if v then return tonumber(v) or 0 end
    local vc = obj:FindFirstChild("Value") or obj:FindFirstChild("Price")
    if vc and (vc:IsA("NumberValue") or vc:IsA("IntValue")) then return vc.Value end
    return 5
end

local function GetRarity(obj)
    if not obj then return "Common" end
    local a = obj:GetAttribute("Rarity")
    if a then return a end
    local rv = obj:FindFirstChild("Rarity")
    if rv and rv:IsA("StringValue") then return rv.Value end
    return "Common"
end

-- MAX MINING + GRAB
local function MineAndGrab(ore)
    if not ore then return end
    TeleportToRock(ore)
    task.wait(0.05)
    
    local tool = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Tool")
    if tool then for i=1,Config.MineSpeed do pcall(function() tool:Activate() end) end end
    
    for i=1,Config.MineSpeed do
        Fire("mine", ore) Fire("dig", ore) Fire("hit", ore) Fire("break", ore) Fire("harvest", ore)
    end
    
    if Config.AutoCollect then
        for i=1,14 do
            pcall(function()
                local hrp = GetHRP()
                if hrp then
                    firetouchinterest(hrp, ore, 0)
                    task.wait(0.025)
                    firetouchinterest(hrp, ore, 1)
                end
            end)
            Fire("pickup", ore) Fire("collect", ore)
            task.wait(0.18)
        end
    end
end

-- ANTI FREEZE
local function AntiFreeze()
    if not Config.AntiFreeze then return end
    pcall(function()
        local char = LocalPlayer.Character
        if not char then return end
        for _,v in ipairs(char:GetDescendants()) do
            if (v:IsA("NumberValue") or v:IsA("IntValue")) and (v.Name:lower():find("cold") or v.Name:lower():find("freeze") or v.Name:lower():find("temp")) then
                v.Value = 100
            end
            if v:IsA("BoolValue") and v.Name:lower():find("frozen") then v.Value = false end
        end
    end)
end

-- GOD MODE + NO FALL DAMAGE
local function GodMode()
    if not Config.GodMode then return end
    pcall(function()
        local char = LocalPlayer.Character
        if not char then return end
        local hum = char:FindFirstChild("Humanoid")
        if hum then
            hum.MaxHealth = math.huge
            hum.Health = math.huge
        end
    end)
end

-- AUTO UPGRADE
local function AutoUpgrade()
    if not Config.AutoUpgrade then return end
    Fire("upgradewarmth")
    Fire("upgradebackpack")
    Fire("upgradepickaxe")
    Fire("buyupgrade", "Warmth")
    Fire("buyupgrade", "Backpack")
    Fire("buyupgrade", "Pickaxe")
end

-- SPAM UPGRADES
local function SpamUpgrades()
    if State.upgradeSpamRunning then return end
    State.upgradeSpamRunning = true
    spawn(function()
        for i = 1, 25 do
            Fire("upgradewarmth")
            Fire("upgradebackpack")
            Fire("upgradepickaxe")
            task.wait(0.08)
        end
        State.upgradeSpamRunning = false
        StarterGui:SetCore("SendNotification",{Title="Spam Upgrades",Text="Done! 25x upgrades fired",Duration=3})
    end)
end

-- TP TO BEST ORE
local function TPToBestOre()
    local ores = GetMineableOres()
    if #ores == 0 then return end
    
    table.sort(ores, function(a,b) return GetValue(a) > GetValue(b) end)
    TeleportToRock(ores[1])
    StarterGui:SetCore("SendNotification",{Title="TP Best Ore",Text="Teleported to highest value ore",Duration=2})
end

-- VALUE ESP
local function CreateValueESP(obj)
    if State.ESPObjects[obj] then return end
    local value = GetValue(obj)
    local rarity = GetRarity(obj)
    
    local hl = Instance.new("Highlight", obj)
    hl.FillColor = Color3.fromRGB(0,255,100)
    hl.OutlineColor = Color3.fromRGB(255,215,0)
    
    local bb = Instance.new("BillboardGui", obj)
    bb.Size = UDim2.new(0,220,0,55)
    bb.StudsOffset = Vector3.new(0,5.5,0)
    bb.AlwaysOnTop = true
    
    local txt = Instance.new("TextLabel", bb)
    txt.Size = UDim2.new(1,0,1,0)
    txt.BackgroundTransparency = 1
    txt.Text = string.format("$%d | %s", value, rarity)
    txt.TextColor3 = Color3.fromRGB(255,255,100)
    txt.TextStrokeTransparency = 0
    txt.TextScaled = true
    txt.Font = Enum.Font.GothamBold
    
    State.ESPObjects[obj] = {Highlight=hl, Billboard=bb}
end

local function RefreshESP()
    for obj,data in pairs(State.ESPObjects) do
        if not obj.Parent then
            if data.Highlight then data.Highlight:Destroy() end
            if data.Billboard then data.Billboard:Destroy() end
            State.ESPObjects[obj] = nil
        end
    end
    if not Config.ESP then return end
    for _,ore in ipairs(GetMineableOres()) do
        if not State.ESPObjects[ore] then CreateValueESP(ore) end
    end
end

-- MAIN LOOP
spawn(function()
    while true do
        task.wait(0.16)
        
        if Config.AutoMine then
            local ores = GetMineableOres()
            if #ores > 0 then
                table.sort(ores, function(a,b) return GetValue(a) > GetValue(b) end)
                MineAndGrab(ores[1])
            end
        end
        
        if Config.AutoSell and math.random(1,5) == 1 then
            Fire("sell") Fire("sellall")
        end
        
        if Config.AutoUpgrade then AutoUpgrade() end
        if Config.AntiFreeze then AntiFreeze() end
        if Config.GodMode then GodMode() end
        
        RefreshESP()
    end
end)

-- === SHARP CRYSTAL CLEAR GUI ===
local SG = Instance.new("ScreenGui")
SG.Name = "MAIM_Bot_v10"
SG.ResetOnSpawn = false
SG.Parent = game:GetService("CoreGui")

local Main = Instance.new("Frame")
Main.Size = UDim2.new(0,370,0,560)
Main.Position = UDim2.new(0.5,-185,0.04,0)
Main.BackgroundColor3 = Color3.fromRGB(18,18,26)
Main.BorderSizePixel = 0
Main.Parent = SG
Instance.new("UICorner", Main).CornerRadius = UDim.new(0,16)

-- Title Bar
local TitleBar = Instance.new("Frame")
TitleBar.Size = UDim2.new(1,0,0,54)
TitleBar.BackgroundColor3 = Color3.fromRGB(0,150,80)
TitleBar.Parent = Main
Instance.new("UICorner", TitleBar).CornerRadius = UDim.new(0,16)

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1,-120,1,0)
Title.BackgroundTransparency = 1
Title.Text = "?? Mine A Mountain v10 MAX"
Title.TextColor3 = Color3.new(1,1,1)
Title.TextSize = 18
Title.Font = Enum.Font.GothamBold
Title.Parent = TitleBar

local MinBtn = Instance.new("TextButton")
MinBtn.Size = UDim2.new(0,50,0,38)
MinBtn.Position = UDim2.new(1,-65,0,8)
MinBtn.BackgroundColor3 = Color3.fromRGB(255,170,0)
MinBtn.Text = "-"
MinBtn.TextColor3 = Color3.new(0,0,0)
MinBtn.TextSize = 26
MinBtn.Font = Enum.Font.GothamBold
MinBtn.Parent = TitleBar
Instance.new("UICorner", MinBtn).CornerRadius = UDim.new(0,10)

MinBtn.MouseButton1Click:Connect(function()
    State.minimized = not State.minimized
    Main.Size = State.minimized and UDim2.new(0,370,0,54) or UDim2.new(0,370,0,560)
end)

-- Drag only from TitleBar
TitleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        State.dragging = true
        State.dragStart = input.Position
        State.dragPos = Main.Position
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if State.dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - State.dragStart
        Main.Position = UDim2.new(State.dragPos.X.Scale, State.dragPos.X.Offset + delta.X, State.dragPos.Y.Scale, State.dragPos.Y.Offset + delta.Y)
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        State.dragging = false
    end
end)

-- SCROLLING SETTINGS AREA
local Scroll = Instance.new("ScrollingFrame")
Scroll.Size = UDim2.new(1,-20,1,-70)
Scroll.Position = UDim2.new(0,10,0,62)
Scroll.BackgroundTransparency = 1
Scroll.ScrollBarThickness = 8
Scroll.ScrollBarImageColor3 = Color3.fromRGB(0,200,100)
Scroll.Parent = Main

local Layout = Instance.new("UIListLayout")
Layout.SortOrder = Enum.SortOrder.LayoutOrder
Layout.Padding = UDim.new(0,8)
Layout.Parent = Scroll

-- Helper function for toggles
local function AddToggle(text, default, cb)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1,0,0,58)
    btn.BackgroundColor3 = default and Color3.fromRGB(0,180,90) or Color3.fromRGB(45,45,55)
    btn.Text = text .. (default and "   ? ON" or "   ? OFF")
    btn.TextColor3 = Color3.new(1,1,1)
    btn.TextSize = 17
    btn.Font = Enum.Font.GothamSemibold
    btn.Parent = Scroll
    
    btn.MouseButton1Click:Connect(function()
        default = not default
        btn.BackgroundColor3 = default and Color3.fromRGB(0,180,90) or Color3.fromRGB(45,45,55)
        btn.Text = text .. (default and "   ? ON" or "   ? OFF")
        if cb then cb(default) end
    end)
end

-- Helper for action buttons
local function AddButton(text, color, cb)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1,0,0,52)
    btn.BackgroundColor3 = color
    btn.Text = text
    btn.TextColor3 = Color3.new(1,1,1)
    btn.TextSize = 17
    btn.Font = Enum.Font.GothamBold
    btn.Parent = Scroll
    
    btn.MouseButton1Click:Connect(function()
        if cb then cb() end
    end)
end

-- === ALL TOGGLES ===
AddToggle("Auto Mine + Smart Target", Config.AutoMine, function(v) Config.AutoMine = v end)
AddToggle("Auto Pickup (Grab)", Config.AutoCollect, function(v) Config.AutoCollect = v end)
AddToggle("Auto Sell", Config.AutoSell, function(v) Config.AutoSell = v end)
AddToggle("Super Fast Mining", Config.FastMine, function(v) Config.FastMine = v end)
AddToggle("Value ESP ($ Price)", Config.ESP, function(v) Config.ESP = v end)
AddToggle("Anti Freeze", Config.AntiFreeze, function(v) Config.AntiFreeze = v end)
AddToggle("God Mode + No Fall", Config.GodMode, function(v) Config.GodMode = v end)
AddToggle("Auto Upgrade", Config.AutoUpgrade, function(v) Config.AutoUpgrade = v end)

-- === ACTION BUTTONS ===
AddButton("?? TP TO BEST ORE", Color3.fromRGB(70,130,255), TPToBestOre)
AddButton("? SPAM UPGRADES x25", Color3.fromRGB(180,80,220), SpamUpgrades)

Scroll.CanvasSize = UDim2.new(0,0,0,#Scroll:GetChildren()*66)

print("? v10 MAX ready! Sharp GUI + Scrollbar + All Exploits added.")
