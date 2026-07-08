--[[ MINE A MOUNTAIN BOT v11 - Cleaned + Fixed ]]

local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local Workspace          = game:GetService("Workspace")
local StarterGui         = game:GetService("StarterGui")
local UserInputService   = game:GetService("UserInputService")
local CoreGui            = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer

local function Notify(title, text, dur)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = title, Text = text, Duration = dur or 4,
        })
    end)
end

print("=== MINE A MOUNTAIN BOT v11 LOADED ===")
Notify("Mine A Mountain v11", "Loaded successfully", 5)

----------------------------------------------------------------------
-- CONFIG / STATE
----------------------------------------------------------------------
local Config = {
    AutoMine       = false,
    AutoCollect    = true,
    AutoSell       = true,
    FastMine       = true,
    MineSpeedFast  = 50,   -- activations per tick when FastMine is on
    MineSpeedSlow  = 8,    -- activations per tick when FastMine is off
    MineMaxTime    = 6,    -- max seconds to stay on one rock before giving up
    ESP            = true,
    ShowValueOnESP = true,
    AntiFreeze     = true,
    GodMode        = false,
    AutoUpgrade    = false,
}

local State = {
    ESPObjects        = {},
    minimized         = false,
    dragging          = false,
    dragStart         = nil,
    dragPos           = nil,
    upgradeSpamRunning = false,
    guiVisible        = true,
    connections       = {},
    godConnection     = nil,
}

local function TrackConn(conn)
    table.insert(State.connections, conn)
    return conn
end

----------------------------------------------------------------------
-- REMOTE SCANNER
----------------------------------------------------------------------
local Remotes = {}

local function ScanRemotes()
    Remotes = {}
    for _, v in ipairs(ReplicatedStorage:GetDescendants()) do
        if v:IsA("RemoteEvent") or v:IsA("RemoteFunction") then
            Remotes[v.Name:lower()] = v
        end
    end
end
ScanRemotes()

-- rescan when new remotes are added
TrackConn(ReplicatedStorage.DescendantAdded:Connect(function(v)
    if v:IsA("RemoteEvent") or v:IsA("RemoteFunction") then
        Remotes[v.Name:lower()] = v
    end
end))

local function Fire(name, ...)
    name = name:lower()
    for k, remote in pairs(Remotes) do
        if k:find(name, 1, true) then
            local args = { ... }
            pcall(function()
                if remote:IsA("RemoteEvent") then
                    remote:FireServer(table.unpack(args))
                else
                    remote:InvokeServer(table.unpack(args))
                end
            end)
            return true
        end
    end
    return false
end

----------------------------------------------------------------------
-- UTILITY
----------------------------------------------------------------------
local function GetHRP()
    local c = LocalPlayer.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function SetVelocity(part, vel)
    if not part then return end
    pcall(function() part.AssemblyLinearVelocity = vel end)
end

local function TeleportToRock(ore)
    local hrp = GetHRP()
    if hrp and ore and ore.Parent then
        hrp.CFrame = ore.CFrame * CFrame.new(0, 4.8, 0)
        SetVelocity(hrp, Vector3.zero)
    end
end

local ORE_KEYWORDS = { "ore", "crystal", "rock", "gem" }

local function IsOreName(name)
    name = name:lower()
    for _, kw in ipairs(ORE_KEYWORDS) do
        if name:find(kw, 1, true) then return true end
    end
    return false
end

local function GetMineableOres()
    local ores = {}
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if (obj:IsA("BasePart") or obj:IsA("MeshPart"))
            and obj.Transparency < 1
            and IsOreName(obj.Name) then
            table.insert(ores, obj)
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

local function GetNearestOre(ores)
    local hrp = GetHRP()
    if not hrp then return nil end
    local best, bestDist
    for _, ore in ipairs(ores) do
        local d = (ore.Position - hrp.Position).Magnitude
        if not bestDist or d < bestDist then
            best, bestDist = ore, d
        end
    end
    return best
end

----------------------------------------------------------------------
-- MINING + GRAB
----------------------------------------------------------------------
local function CurrentMineSpeed()
    return Config.FastMine and Config.MineSpeedFast or Config.MineSpeedSlow
end

-- Detect when a rock/crystal has been grabbed & mined. Games handle this
-- differently, so we check the common signals: destroyed, un-parented,
-- made invisible, or made non-collidable.
local function IsOreGone(ore)
    if not ore then return true end
    if not ore.Parent then return true end
    if not ore:IsDescendantOf(Workspace) then return true end
    if ore.Transparency >= 1 then return true end
    if ore:IsA("BasePart") and ore.CanCollide == false and ore.Transparency > 0.9 then
        return true
    end
    return false
end

local function TryGrab(ore)
    if not ore or not ore.Parent then return end
    pcall(function()
        local hrp = GetHRP()
        if hrp and typeof(firetouchinterest) == "function" then
            firetouchinterest(hrp, ore, 0)
            task.wait(0.02)
            firetouchinterest(hrp, ore, 1)
        end
    end)
    Fire("pickup", ore); Fire("collect", ore); Fire("grab", ore)
end

-- TP to the rock, then mine + grab it repeatedly until it's collected (gone)
-- or until MineMaxTime seconds pass, so we never get stuck on one rock.
local function MineAndGrab(ore)
    if not ore or not ore.Parent then return false end

    TeleportToRock(ore)
    task.wait(0.05)

    local speed   = CurrentMineSpeed()
    local start   = os.clock()
    local char    = LocalPlayer.Character
    local tool    = char and char:FindFirstChildOfClass("Tool")

    while ore.Parent and (os.clock() - start) < Config.MineMaxTime do
        -- keep locked onto the rock so the touch/grab registers
        TeleportToRock(ore)

        -- GRAB FIRST: in this game grabbing the rock is what mines it,
        -- and it then goes straight into the backpack.
        TryGrab(ore)

        -- back it up with tool activation + mine remotes in case the
        -- game also needs a hit to release the rock
        if tool then
            for _ = 1, speed do pcall(function() tool:Activate() end) end
        end
        for _ = 1, speed do
            Fire("mine", ore); Fire("dig", ore); Fire("hit", ore)
            Fire("break", ore); Fire("harvest", ore)
        end

        task.wait(0.08)
    end

    -- returns true if the rock was fully mined/collected
    return ore.Parent == nil
end

----------------------------------------------------------------------
-- ANTI FREEZE
----------------------------------------------------------------------
local function AntiFreeze()
    if not Config.AntiFreeze then return end
    pcall(function()
        local char = LocalPlayer.Character
        if not char then return end
        for _, v in ipairs(char:GetDescendants()) do
            local n = v.Name:lower()
            if (v:IsA("NumberValue") or v:IsA("IntValue"))
                and (n:find("cold") or n:find("freeze") or n:find("temp") or n:find("warm")) then
                v.Value = 100
            elseif v:IsA("BoolValue") and n:find("frozen") then
                v.Value = false
            end
        end
    end)
end

----------------------------------------------------------------------
-- GOD MODE (event-driven, no math.huge spam)
----------------------------------------------------------------------
local function EnableGodMode()
    if State.godConnection then return end
    local function hook(char)
        local hum = char:WaitForChild("Humanoid", 5)
        if not hum then return end
        if State.godConnection then State.godConnection:Disconnect() end
        State.godConnection = hum.HealthChanged:Connect(function()
            if Config.GodMode then
                hum.Health = hum.MaxHealth
            end
        end)
    end
    if LocalPlayer.Character then hook(LocalPlayer.Character) end
    TrackConn(LocalPlayer.CharacterAdded:Connect(function(char)
        if Config.GodMode then hook(char) end
    end))
end

local function DisableGodMode()
    if State.godConnection then
        State.godConnection:Disconnect()
        State.godConnection = nil
    end
end

----------------------------------------------------------------------
-- UPGRADES
----------------------------------------------------------------------
local function AutoUpgrade()
    if not Config.AutoUpgrade then return end
    Fire("upgradewarmth"); Fire("upgradebackpack"); Fire("upgradepickaxe")
    Fire("buyupgrade", "Warmth"); Fire("buyupgrade", "Backpack"); Fire("buyupgrade", "Pickaxe")
end

local function SpamUpgrades()
    if State.upgradeSpamRunning then return end
    State.upgradeSpamRunning = true
    task.spawn(function()
        for _ = 1, 25 do
            Fire("upgradewarmth"); Fire("upgradebackpack"); Fire("upgradepickaxe")
            task.wait(0.08)
        end
        State.upgradeSpamRunning = false
        Notify("Spam Upgrades", "Done! 25x upgrades fired", 3)
    end)
end

----------------------------------------------------------------------
-- TP TO BEST ORE
----------------------------------------------------------------------
local function TPToBestOre()
    local ores = GetMineableOres()
    if #ores == 0 then
        Notify("TP Best Ore", "No ores found nearby", 2)
        return
    end
    table.sort(ores, function(a, b) return GetValue(a) > GetValue(b) end)
    TeleportToRock(ores[1])
    Notify("TP Best Ore", "Teleported to highest value ore", 2)
end

----------------------------------------------------------------------
-- VALUE ESP
----------------------------------------------------------------------
local function CreateValueESP(obj)
    if State.ESPObjects[obj] then return end
    local value  = GetValue(obj)
    local rarity = GetRarity(obj)

    local hl = Instance.new("Highlight")
    hl.FillColor    = Color3.fromRGB(0, 255, 100)
    hl.OutlineColor = Color3.fromRGB(255, 215, 0)
    hl.FillTransparency = 0.6
    hl.Parent = obj

    local bb = Instance.new("BillboardGui")
    bb.Size        = UDim2.new(0, 220, 0, 55)
    bb.StudsOffset = Vector3.new(0, 5.5, 0)
    bb.AlwaysOnTop = true
    bb.Parent = obj

    local txt = Instance.new("TextLabel")
    txt.Size                   = UDim2.new(1, 0, 1, 0)
    txt.BackgroundTransparency = 1
    txt.Text = Config.ShowValueOnESP
        and string.format("$%d | %s", value, rarity)
        or rarity
    txt.TextColor3           = Color3.fromRGB(255, 255, 100)
    txt.TextStrokeTransparency = 0
    txt.TextScaled           = true
    txt.Font                 = Enum.Font.GothamBold
    txt.Parent = bb

    State.ESPObjects[obj] = { Highlight = hl, Billboard = bb }
end

local function ClearAllESP()
    for obj, data in pairs(State.ESPObjects) do
        if data.Highlight then data.Highlight:Destroy() end
        if data.Billboard then data.Billboard:Destroy() end
        State.ESPObjects[obj] = nil
    end
end

local function RefreshESP()
    for obj, data in pairs(State.ESPObjects) do
        if not obj.Parent then
            if data.Highlight then data.Highlight:Destroy() end
            if data.Billboard then data.Billboard:Destroy() end
            State.ESPObjects[obj] = nil
        end
    end
    if not Config.ESP then
        ClearAllESP()
        return
    end
    for _, ore in ipairs(GetMineableOres()) do
        if not State.ESPObjects[ore] then CreateValueESP(ore) end
    end
end

----------------------------------------------------------------------
-- MAIN LOOP
----------------------------------------------------------------------
task.spawn(function()
    while true do
        task.wait(0.16)

        local ok = pcall(function()
            if Config.AutoMine then
                local ores = GetMineableOres()
                if #ores > 0 then
                    table.sort(ores, function(a, b) return GetValue(a) > GetValue(b) end)
                    MineAndGrab(ores[1])
                end
            end

            if Config.AutoSell and math.random(1, 5) == 1 then
                Fire("sell"); Fire("sellall")
            end

            if Config.AutoUpgrade then AutoUpgrade() end
            if Config.AntiFreeze then AntiFreeze() end

            RefreshESP()
        end)
        -- swallow errors so the loop never dies
        if not ok then task.wait(0.25) end
    end
end)

----------------------------------------------------------------------
-- GUI
----------------------------------------------------------------------
local SG = Instance.new("ScreenGui")
SG.Name          = "MAIM_Bot_v11"
SG.ResetOnSpawn  = false
SG.IgnoreGuiInset = true
SG.Parent        = CoreGui

local Main = Instance.new("Frame")
Main.Size             = UDim2.new(0, 370, 0, 560)
Main.Position         = UDim2.new(0.5, -185, 0.04, 0)
Main.BackgroundColor3 = Color3.fromRGB(18, 18, 26)
Main.BorderSizePixel  = 0
Main.Active           = true
Main.Parent           = SG
Instance.new("UICorner", Main).CornerRadius = UDim.new(0, 16)

-- Title Bar
local TitleBar = Instance.new("Frame")
TitleBar.Size             = UDim2.new(1, 0, 0, 54)
TitleBar.BackgroundColor3 = Color3.fromRGB(0, 150, 80)
TitleBar.BorderSizePixel  = 0
TitleBar.Parent           = Main
Instance.new("UICorner", TitleBar).CornerRadius = UDim.new(0, 16)

local Title = Instance.new("TextLabel")
Title.Size                   = UDim2.new(1, -120, 1, 0)
Title.Position               = UDim2.new(0, 12, 0, 0)
Title.BackgroundTransparency = 1
Title.TextXAlignment         = Enum.TextXAlignment.Left
Title.Text                   = "Mine A Mountain v11"
Title.TextColor3             = Color3.new(1, 1, 1)
Title.TextSize               = 18
Title.Font                   = Enum.Font.GothamBold
Title.Parent                 = TitleBar

local MinBtn = Instance.new("TextButton")
MinBtn.Size             = UDim2.new(0, 50, 0, 38)
MinBtn.Position         = UDim2.new(1, -65, 0, 8)
MinBtn.BackgroundColor3 = Color3.fromRGB(255, 170, 0)
MinBtn.Text             = "-"
MinBtn.TextColor3       = Color3.new(0, 0, 0)
MinBtn.TextSize         = 26
MinBtn.Font             = Enum.Font.GothamBold
MinBtn.Parent           = TitleBar
Instance.new("UICorner", MinBtn).CornerRadius = UDim.new(0, 10)

MinBtn.MouseButton1Click:Connect(function()
    State.minimized = not State.minimized
    Main.Size = State.minimized
        and UDim2.new(0, 370, 0, 54)
        or  UDim2.new(0, 370, 0, 560)
end)

-- Drag only from TitleBar
TitleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        State.dragging  = true
        State.dragStart = input.Position
        State.dragPos   = Main.Position
    end
end)

TrackConn(UserInputService.InputChanged:Connect(function(input)
    if State.dragging
        and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - State.dragStart
        Main.Position = UDim2.new(
            State.dragPos.X.Scale, State.dragPos.X.Offset + delta.X,
            State.dragPos.Y.Scale, State.dragPos.Y.Offset + delta.Y
        )
    end
end))

TrackConn(UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        State.dragging = false
    end
end))

-- Toggle GUI with RightShift
TrackConn(UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.RightShift then
        State.guiVisible = not State.guiVisible
        Main.Visible = State.guiVisible
    end
end))

-- Scrolling settings area
local Scroll = Instance.new("ScrollingFrame")
Scroll.Size                 = UDim2.new(1, -20, 1, -70)
Scroll.Position             = UDim2.new(0, 10, 0, 62)
Scroll.BackgroundTransparency = 1
Scroll.BorderSizePixel      = 0
Scroll.ScrollBarThickness   = 8
Scroll.ScrollBarImageColor3 = Color3.fromRGB(0, 200, 100)
Scroll.CanvasSize           = UDim2.new(0, 0, 0, 0)
Scroll.AutomaticCanvasSize  = Enum.AutomaticSize.Y
Scroll.Parent               = Main

local Layout = Instance.new("UIListLayout")
Layout.SortOrder = Enum.SortOrder.LayoutOrder
Layout.Padding   = UDim.new(0, 8)
Layout.Parent    = Scroll

local function AddToggle(text, default, cb)
    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(1, 0, 0, 58)
    btn.AutoButtonColor  = true
    btn.BackgroundColor3 = default and Color3.fromRGB(0, 180, 90) or Color3.fromRGB(45, 45, 55)
    btn.Text             = text .. (default and "   [ON]" or "   [OFF]")
    btn.TextColor3       = Color3.new(1, 1, 1)
    btn.TextSize         = 17
    btn.Font             = Enum.Font.GothamSemibold
    btn.Parent           = Scroll
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 10)

    btn.MouseButton1Click:Connect(function()
        default = not default
        btn.BackgroundColor3 = default and Color3.fromRGB(0, 180, 90) or Color3.fromRGB(45, 45, 55)
        btn.Text = text .. (default and "   [ON]" or "   [OFF]")
        if cb then cb(default) end
    end)
end

local function AddButton(text, color, cb)
    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(1, 0, 0, 52)
    btn.AutoButtonColor  = true
    btn.BackgroundColor3 = color
    btn.Text             = text
    btn.TextColor3       = Color3.new(1, 1, 1)
    btn.TextSize         = 17
    btn.Font             = Enum.Font.GothamBold
    btn.Parent           = Scroll
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 10)

    btn.MouseButton1Click:Connect(function()
        if cb then cb() end
    end)
end

-- Toggles
AddToggle("Auto Mine + Smart Target", Config.AutoMine,    function(v) Config.AutoMine = v end)
AddToggle("Auto Pickup (Grab)",       Config.AutoCollect, function(v) Config.AutoCollect = v end)
AddToggle("Auto Sell",                Config.AutoSell,    function(v) Config.AutoSell = v end)
AddToggle("Super Fast Mining",        Config.FastMine,    function(v) Config.FastMine = v end)
AddToggle("Value ESP ($ Price)",      Config.ESP,         function(v)
    Config.ESP = v
    if not v then ClearAllESP() end
end)
AddToggle("Anti Freeze",              Config.AntiFreeze,  function(v) Config.AntiFreeze = v end)
AddToggle("God Mode",                 Config.GodMode,     function(v)
    Config.GodMode = v
    if v then EnableGodMode() else DisableGodMode() end
end)
AddToggle("Auto Upgrade",             Config.AutoUpgrade, function(v) Config.AutoUpgrade = v end)

-- Action buttons
AddButton("TP TO BEST ORE",   Color3.fromRGB(70, 130, 255), TPToBestOre)
AddButton("SPAM UPGRADES x25", Color3.fromRGB(180, 80, 220), SpamUpgrades)

if Config.GodMode then EnableGodMode() end

print("v11 ready! Press RightShift to hide/show the GUI.")
Notify("Mine A Mountain v11", "Ready! RightShift = hide/show", 5)
