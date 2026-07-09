--[[ MINE A MOUNTAIN BOT v12 - Movement Exploits ]]

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
    MineMaxTime    = 12,   -- max seconds to stay on one rock before giving up
    MineHighestValue = true, -- true = target highest value, false = nearest
    GrabHoldTime   = 3,    -- seconds to hold the grab/mine prompt
    ESP            = true,
    ShowValueOnESP = true,
    AntiFreeze     = true,
    GodMode        = false,
    AutoUpgrade    = false,

    -- movement / positioning
    StayOnRock     = true,   -- lock in place while mining so you don't slide off
    AntiFall       = true,   -- kill fall damage + stop free-falling down the mountain
    NoClip         = false,  -- walk / fly through the mountain and rocks
    Fly            = false,  -- free fly with WASD + Space/Ctrl
    FlySpeed       = 80,
    InfiniteJump   = false,
    WalkSpeedOn    = false,
    WalkSpeed      = 60,
    JumpPower      = 50,
    AutoSellFull   = true,   -- auto sell when backpack is full
}

local State = {
    ESPObjects        = {},
    minimized         = false,
    dragging          = false,
    dragStart         = nil,
    dragPos           = nil,
    upgradeSpamRunning = false,
    blacklist         = {},
    guiVisible        = true,
    connections       = {},
    godConnection     = nil,
    noclipConnection  = nil,
    flyConnection     = nil,
    flyParts          = {},
    heldKeys          = {},
    lockPos           = nil,   -- CFrame we hold when StayOnRock is active
}

local function TrackConn(conn)
    table.insert(State.connections, conn)
    return conn
end

-- forward declarations (defined later, used by the mining engine)
local IsBackpackFull
local GoSellAndReturn

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

local function GetHumanoid()
    local c = LocalPlayer.Character
    return c and c:FindFirstChildOfClass("Humanoid")
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
        -- remember this spot so StayOnRock can hold us here
        State.lockPos = hrp.CFrame
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

-- Read a rock/crystal's remaining health / durability if the game exposes it,
-- so we can mine "until it's basically dead" and then it drops to the backpack.
local HEALTH_KEYS = { "Health", "HP", "Durability", "Hits", "Amount", "Progress" }
local function GetOreHealth(ore)
    if not ore then return nil end
    local model = ore:FindFirstAncestorOfClass("Model")
    for _, src in ipairs({ ore, model }) do
        if src then
            for _, key in ipairs(HEALTH_KEYS) do
                local a = src:GetAttribute(key)
                if a ~= nil then return tonumber(a) end
                local c = src:FindFirstChild(key)
                if c and (c:IsA("NumberValue") or c:IsA("IntValue")) then return c.Value end
            end
        end
    end
    return nil
end

-- Trigger any ProximityPrompt on the rock. Most "hold to mine / grab" games
-- use these, and this is usually why a plain remote-spam does nothing.
local function FireGrabPrompt(ore)
    if typeof(fireproximityprompt) ~= "function" then return false end
    local fired = false
    for _, root in ipairs({ ore, ore:FindFirstAncestorOfClass("Model") }) do
        if root then
            for _, p in ipairs(root:GetDescendants()) do
                if p:IsA("ProximityPrompt") then
                    pcall(function() fireproximityprompt(p) end)
                    fired = true
                end
            end
        end
    end
    return fired
end

local function TryGrab(ore)
    if not ore or not ore.Parent then return end
    FireGrabPrompt(ore)
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

local function HitOre(ore, tool, speed)
    if tool then
        for _ = 1, speed do pcall(function() tool:Activate() end) end
    end
    for _ = 1, speed do
        Fire("mine", ore); Fire("dig", ore); Fire("hit", ore)
        Fire("break", ore); Fire("harvest", ore); Fire("damage", ore)
    end
    FireGrabPrompt(ore)
end

-- Full cycle for one rock/crystal:
--  1. if backpack full -> go sell, come back
--  2. TP to it and hold the grab prompt (~GrabHoldTime seconds)
--  3. mine until its health is depleted / it's gone / timeout
--  4. final collect sweep so it lands in the backpack
local function MineAndGrab(ore)
    if not ore or not ore.Parent then return false end

    if IsBackpackFull and IsBackpackFull() and GoSellAndReturn then
        GoSellAndReturn(ore)
    end

    TeleportToRock(ore)
    task.wait(0.05)

    local speed = CurrentMineSpeed()
    local start = os.clock()
    local char  = LocalPlayer.Character
    local tool  = char and char:FindFirstChildOfClass("Tool")

    -- 1) GRAB: hold the prompt for a couple seconds like the game requires
    local grabDeadline = os.clock() + Config.GrabHoldTime
    while ore.Parent and not IsOreGone(ore) and os.clock() < grabDeadline do
        TeleportToRock(ore)
        TryGrab(ore)
        if tool then pcall(function() tool:Activate() end) end
        task.wait(0.1)
    end

    -- 2) MINE until health is basically dead, it's gone, or we time out
    while not IsOreGone(ore) and (os.clock() - start) < Config.MineMaxTime do
        TeleportToRock(ore)
        HitOre(ore, tool, speed)
        TryGrab(ore)

        local hp = GetOreHealth(ore)
        if hp ~= nil and hp <= 0 then break end

        -- mid-mining weight check: dump if we filled up
        if IsBackpackFull and IsBackpackFull() and GoSellAndReturn then
            GoSellAndReturn(ore)
        end

        for _ = 1, 4 do
            if IsOreGone(ore) then break end
            task.wait(0.03)
        end
    end

    -- 3) final collect sweep so the mined rock lands in the backpack
    for _ = 1, 8 do
        if IsOreGone(ore) then break end
        TryGrab(ore)
        task.wait(0.06)
    end

    return IsOreGone(ore)
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
-- NOCLIP (walk / fly / teleport through the mountain and rocks)
----------------------------------------------------------------------
local function EnableNoClip()
    if State.noclipConnection then return end
    State.noclipConnection = RunService.Stepped:Connect(function()
        if not Config.NoClip then return end
        local char = LocalPlayer.Character
        if not char then return end
        for _, p in ipairs(char:GetDescendants()) do
            if p:IsA("BasePart") and p.CanCollide then
                p.CanCollide = false
            end
        end
    end)
    TrackConn(State.noclipConnection)
end

local function DisableNoClip()
    if State.noclipConnection then
        State.noclipConnection:Disconnect()
        State.noclipConnection = nil
    end
end

----------------------------------------------------------------------
-- FLY (WASD + Space up / Ctrl down, camera-relative)
----------------------------------------------------------------------
local function DestroyFlyParts()
    for _, obj in ipairs(State.flyParts) do
        pcall(function() obj:Destroy() end)
    end
    State.flyParts = {}
end

local function EnableFly()
    local hrp = GetHRP()
    local hum = GetHumanoid()
    if not hrp or not hum then return end

    DestroyFlyParts()

    local bv = Instance.new("BodyVelocity")
    bv.MaxForce = Vector3.new(1, 1, 1) * math.huge
    bv.Velocity = Vector3.zero
    bv.Parent = hrp

    local bg = Instance.new("BodyGyro")
    bg.MaxForce = Vector3.new(1, 1, 1) * math.huge
    bg.P = 9e4
    bg.CFrame = hrp.CFrame
    bg.Parent = hrp

    State.flyParts = { bv, bg }
    pcall(function() hum.PlatformStand = true end)

    if State.flyConnection then State.flyConnection:Disconnect() end
    State.flyConnection = RunService.RenderStepped:Connect(function()
        if not Config.Fly then return end
        local cam = Workspace.CurrentCamera
        if not cam or not hrp or not hrp.Parent then return end

        local dir = Vector3.zero
        local look = cam.CFrame.LookVector
        local right = cam.CFrame.RightVector
        if State.heldKeys[Enum.KeyCode.W] then dir += look end
        if State.heldKeys[Enum.KeyCode.S] then dir -= look end
        if State.heldKeys[Enum.KeyCode.D] then dir += right end
        if State.heldKeys[Enum.KeyCode.A] then dir -= right end
        if State.heldKeys[Enum.KeyCode.Space] then dir += Vector3.yAxis end
        if State.heldKeys[Enum.KeyCode.LeftControl] then dir -= Vector3.yAxis end

        if dir.Magnitude > 0 then dir = dir.Unit end
        bv.Velocity = dir * Config.FlySpeed
        bg.CFrame = cam.CFrame
    end)
    TrackConn(State.flyConnection)
end

local function DisableFly()
    if State.flyConnection then
        State.flyConnection:Disconnect()
        State.flyConnection = nil
    end
    DestroyFlyParts()
    local hum = GetHumanoid()
    if hum then pcall(function() hum.PlatformStand = false end) end
end

----------------------------------------------------------------------
-- STAY ON ROCK + ANTI-FALL (don't slide down the mountain)
----------------------------------------------------------------------
local function StayOnRockStep()
    if Config.Fly then return end        -- flying overrides positioning
    local hrp = GetHRP()
    if not hrp then return end

    -- Hard lock in place while auto-mining a rock
    if Config.StayOnRock and Config.AutoMine and State.lockPos then
        hrp.CFrame = State.lockPos
        SetVelocity(hrp, Vector3.zero)
        return
    end

    -- Anti-fall: if free-falling fast down the mountain, kill the drop
    if Config.AntiFall then
        local vel = hrp.AssemblyLinearVelocity
        if vel.Y < -55 then
            SetVelocity(hrp, Vector3.new(vel.X, 0, vel.Z))
        end
    end
end

local function EnableAntiFallDamage()
    local hum = GetHumanoid()
    if not hum then return end
    pcall(function()
        hum.StateChanged:Connect(function(_, new)
            if Config.AntiFall and new == Enum.HumanoidStateType.Landed then
                SetVelocity(GetHRP(), Vector3.zero)
            end
        end)
    end)
end

----------------------------------------------------------------------
-- SPEED / JUMP TWEAKS
----------------------------------------------------------------------
local function ApplyCharTweaks()
    local hum = GetHumanoid()
    if not hum then return end
    pcall(function()
        if Config.WalkSpeedOn then
            hum.WalkSpeed = Config.WalkSpeed
        end
        if Config.JumpPower and Config.JumpPower ~= 50 then
            hum.UseJumpPower = true
            hum.JumpPower = Config.JumpPower
        end
    end)
end

----------------------------------------------------------------------
-- INPUT (fly keys + infinite jump) + MOVEMENT LOOP
----------------------------------------------------------------------
TrackConn(UserInputService.InputBegan:Connect(function(input, gpe)
    if input.KeyCode ~= Enum.KeyCode.Unknown then
        State.heldKeys[input.KeyCode] = true
    end
    if gpe then return end
    -- infinite jump
    if input.KeyCode == Enum.KeyCode.Space and Config.InfiniteJump then
        local hum = GetHumanoid()
        if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
    end
end))

TrackConn(UserInputService.InputEnded:Connect(function(input)
    if input.KeyCode ~= Enum.KeyCode.Unknown then
        State.heldKeys[input.KeyCode] = nil
    end
end))

-- re-apply movement features on respawn
TrackConn(LocalPlayer.CharacterAdded:Connect(function()
    task.wait(0.6)
    if Config.NoClip then EnableNoClip() end
    if Config.Fly then EnableFly() end
    EnableAntiFallDamage()
    ApplyCharTweaks()
    State.lockPos = nil
end)
)

task.spawn(function()
    EnableAntiFallDamage()
    while true do
        RunService.RenderStepped:Wait()
        pcall(function()
            StayOnRockStep()
            if Config.WalkSpeedOn or (Config.JumpPower and Config.JumpPower ~= 50) then
                ApplyCharTweaks()
            end
        end)
    end
end)

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
-- AUTO SELL WHEN BACKPACK IS FULL
-- (the wiki notes runs end when carry capacity fills, so dump early)
----------------------------------------------------------------------
local function GetWeightPair(container)
    local cur, max
    for _, v in ipairs(container:GetDescendants()) do
        if v:IsA("NumberValue") or v:IsA("IntValue") then
            local n = v.Name:lower()
            if n:find("weight") or n:find("carry") or n:find("kg") or n:find("capacity") or n:find("load") then
                if n:find("max") or n:find("limit") then
                    max = v.Value
                else
                    cur = v.Value
                end
            end
        end
    end
    return cur, max
end

-- assigns to the forward-declared local so the mining engine can use it
function IsBackpackFull()
    local player = LocalPlayer
    local cur, max = GetWeightPair(player)
    if (not cur or not max) and player.Character then
        local c2, m2 = GetWeightPair(player.Character)
        cur = cur or c2; max = max or m2
    end
    if cur and max and max > 0 then
        return cur >= max * 0.97
    end
    -- also honor a boolean "full" flag if the game exposes one
    for _, v in ipairs(player:GetDescendants()) do
        if v:IsA("BoolValue") and v.Name:lower():find("full") then
            return v.Value == true
        end
    end
    return false
end

-- find the shop / seller so we can teleport to it when full
local SELLER_KEYS = { "sell", "shop", "vendor", "trader", "merchant", "seller" }
local function FindSeller()
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("BasePart") or obj:IsA("MeshPart") then
            local n = obj.Name:lower()
            for _, kw in ipairs(SELLER_KEYS) do
                if n:find(kw, 1, true) then return obj end
            end
        end
    end
    return nil
end

local function FireSell(seller)
    -- try selling the lowest item first, then fall back to sell-all
    Fire("selllowest"); Fire("sellone"); Fire("sellcheapest")
    Fire("sell"); Fire("sellall"); Fire("sellcrystals")
    if seller then FireGrabPrompt(seller) end
end

-- assigns to the forward-declared local. TP to seller, sell to free weight,
-- then TP back to where we were mining and resume.
function GoSellAndReturn(returnOre)
    local hrp = GetHRP()
    if not hrp then return end
    local backCFrame = State.lockPos or hrp.CFrame
    Notify("Backpack Full", "Teleporting to seller...", 2)

    local seller = FindSeller()
    for _ = 1, 22 do
        if seller and seller.Parent then
            hrp.CFrame = seller.CFrame * CFrame.new(0, 4, 5)
            SetVelocity(hrp, Vector3.zero)
        end
        FireSell(seller)
        task.wait(0.15)
        if not IsBackpackFull() then break end
    end

    -- go back to the rock we were working on
    hrp.CFrame = backCFrame
    SetVelocity(hrp, Vector3.zero)
    task.wait(0.1)
    Notify("Sold", "Returned to mining", 2)
end

local function AutoSellIfFull()
    if not Config.AutoSellFull then return end
    if IsBackpackFull() then
        if Config.AutoMine then
            GoSellAndReturn()   -- travel to seller during auto-farm
        else
            FireSell(nil)       -- just fire sell remotes in place
        end
    end
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
                -- skip rocks we just failed to mine (short cooldown) so a
                -- stubborn rock doesn't block the rest
                local now = os.clock()
                local hrp = GetHRP()

                if Config.MineHighestValue then
                    -- highest value first
                    table.sort(ores, function(a, b) return GetValue(a) > GetValue(b) end)
                elseif hrp then
                    -- nearest first
                    table.sort(ores, function(a, b)
                        return (a.Position - hrp.Position).Magnitude
                             < (b.Position - hrp.Position).Magnitude
                    end)
                end

                local target
                for _, ore in ipairs(ores) do
                    local until_ = State.blacklist[ore]
                    if not until_ or now > until_ then
                        target = ore
                        break
                    end
                end
                if target then
                    local grabbed = MineAndGrab(target)
                    if not grabbed then
                        -- timed out on this rock, ignore it for a few seconds
                        State.blacklist[target] = os.clock() + 5
                    end
                end
            end

            if Config.AutoSell and math.random(1, 5) == 1 then
                Fire("sell"); Fire("sellall")
            end

            AutoSellIfFull()

            if Config.AutoUpgrade then AutoUpgrade() end
            if Config.AntiFreeze then AntiFreeze() end

            RefreshESP()
        end)
        -- swallow errors so the loop never dies
        if not ok then task.wait(0.25) end
    end
end)

----------------------------------------------------------------------
-- GUI (compact hub layout)
----------------------------------------------------------------------
local ACCENT = Color3.fromRGB(0, 200, 100)
local BG     = Color3.fromRGB(16, 17, 22)
local PANEL  = Color3.fromRGB(22, 23, 30)
local ROW    = Color3.fromRGB(30, 31, 40)
local ROWOFF = Color3.fromRGB(48, 50, 62)
local TXT    = Color3.fromRGB(235, 235, 240)
local SUB    = Color3.fromRGB(150, 152, 165)

local function corner(inst, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 8)
    c.Parent = inst
    return c
end

local SG = Instance.new("ScreenGui")
SG.Name           = "MAIM_Hub_v12"
SG.ResetOnSpawn   = false
SG.IgnoreGuiInset = true
SG.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function() SG.Parent = (gethui and gethui()) or CoreGui end)
if not SG.Parent then SG.Parent = CoreGui end

-- root window (compact)
local Main = Instance.new("Frame")
Main.Size             = UDim2.new(0, 520, 0, 320)
Main.Position         = UDim2.new(0.5, -260, 0.5, -160)
Main.BackgroundColor3 = BG
Main.BorderSizePixel  = 0
Main.Active           = true
Main.Parent           = SG
corner(Main, 12)

local stroke = Instance.new("UIStroke", Main)
stroke.Color = Color3.fromRGB(0, 90, 55)
stroke.Thickness = 1.4

-- header
local Header = Instance.new("Frame")
Header.Size             = UDim2.new(1, 0, 0, 42)
Header.BackgroundColor3 = PANEL
Header.BorderSizePixel  = 0
Header.Parent           = Main
corner(Header, 12)

local HeaderFix = Instance.new("Frame")  -- square off bottom corners
HeaderFix.Size = UDim2.new(1, 0, 0, 12)
HeaderFix.Position = UDim2.new(0, 0, 1, -12)
HeaderFix.BackgroundColor3 = PANEL
HeaderFix.BorderSizePixel = 0
HeaderFix.Parent = Header

local Title = Instance.new("TextLabel")
Title.Size                   = UDim2.new(1, -60, 0, 22)
Title.Position               = UDim2.new(0, 14, 0, 4)
Title.BackgroundTransparency = 1
Title.TextXAlignment         = Enum.TextXAlignment.Left
Title.Text                   = "Mine A Mountain Hub"
Title.TextColor3             = TXT
Title.TextSize               = 16
Title.Font                   = Enum.Font.GothamBold
Title.Parent                 = Header

local SubTitle = Instance.new("TextLabel")
SubTitle.Size                   = UDim2.new(1, -60, 0, 14)
SubTitle.Position               = UDim2.new(0, 14, 0, 24)
SubTitle.BackgroundTransparency = 1
SubTitle.TextXAlignment         = Enum.TextXAlignment.Left
SubTitle.Text                   = "v12 - RightShift to hide"
SubTitle.TextColor3             = SUB
SubTitle.TextSize               = 11
SubTitle.Font                   = Enum.Font.Gotham
SubTitle.Parent                 = Header

local Close = Instance.new("TextButton")
Close.Size             = UDim2.new(0, 26, 0, 26)
Close.Position         = UDim2.new(1, -34, 0, 8)
Close.BackgroundColor3 = Color3.fromRGB(40, 42, 54)
Close.Text             = "X"
Close.TextColor3       = TXT
Close.TextSize         = 14
Close.Font             = Enum.Font.GothamBold
Close.Parent           = Header
corner(Close, 6)
Close.MouseButton1Click:Connect(function()
    State.guiVisible = false
    Main.Visible = false
end)

-- accent line under header
local Line = Instance.new("Frame")
Line.Size             = UDim2.new(1, 0, 0, 2)
Line.Position         = UDim2.new(0, 0, 0, 42)
Line.BackgroundColor3 = ACCENT
Line.BorderSizePixel  = 0
Line.Parent           = Main

-- sidebar
local Side = Instance.new("Frame")
Side.Size             = UDim2.new(0, 132, 1, -44)
Side.Position         = UDim2.new(0, 0, 0, 44)
Side.BackgroundColor3 = PANEL
Side.BorderSizePixel  = 0
Side.Parent           = Main

local SideList = Instance.new("UIListLayout")
SideList.SortOrder = Enum.SortOrder.LayoutOrder
SideList.Padding   = UDim.new(0, 2)
SideList.Parent    = Side
local SidePad = Instance.new("UIPadding", Side)
SidePad.PaddingTop = UDim.new(0, 8)

-- content area
local Content = Instance.new("Frame")
Content.Size             = UDim2.new(1, -132, 1, -44)
Content.Position         = UDim2.new(0, 132, 0, 44)
Content.BackgroundColor3 = BG
Content.BorderSizePixel  = 0
Content.Parent           = Main

----------------------------------------------------------------------
-- drag (from header) + RightShift toggle
----------------------------------------------------------------------
Header.InputBegan:Connect(function(input)
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

TrackConn(UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.RightShift then
        State.guiVisible = not State.guiVisible
        Main.Visible = State.guiVisible
    end
end))

----------------------------------------------------------------------
-- tab system
----------------------------------------------------------------------
local Tabs = {}
local currentPage

local function SelectTab(name)
    for tabName, t in pairs(Tabs) do
        local on = (tabName == name)
        t.page.Visible = on
        t.indicator.Visible = on
        t.title.TextColor3 = on and TXT or SUB
        t.btn.BackgroundColor3 = on and ROW or PANEL
        if on then currentPage = t.page end
    end
end

local function AddTab(title, subtitle)
    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(1, -8, 0, 42)
    btn.Position         = UDim2.new(0, 4, 0, 0)
    btn.BackgroundColor3 = PANEL
    btn.AutoButtonColor  = false
    btn.Text             = ""
    btn.Parent           = Side
    corner(btn, 8)

    local indicator = Instance.new("Frame")
    indicator.Size             = UDim2.new(0, 3, 0.6, 0)
    indicator.Position         = UDim2.new(0, 0, 0.2, 0)
    indicator.BackgroundColor3 = ACCENT
    indicator.BorderSizePixel  = 0
    indicator.Visible          = false
    indicator.Parent           = btn
    corner(indicator, 2)

    local t = Instance.new("TextLabel")
    t.Size                   = UDim2.new(1, -14, 0, 18)
    t.Position               = UDim2.new(0, 12, 0, 4)
    t.BackgroundTransparency = 1
    t.TextXAlignment         = Enum.TextXAlignment.Left
    t.Text                   = title
    t.TextColor3             = SUB
    t.TextSize               = 14
    t.Font                   = Enum.Font.GothamBold
    t.Parent                 = btn

    local s = Instance.new("TextLabel")
    s.Size                   = UDim2.new(1, -14, 0, 12)
    s.Position               = UDim2.new(0, 12, 0, 22)
    s.BackgroundTransparency = 1
    s.TextXAlignment         = Enum.TextXAlignment.Left
    s.Text                   = subtitle
    s.TextColor3             = SUB
    s.TextSize               = 10
    s.Font                   = Enum.Font.Gotham
    s.Parent                 = btn

    local page = Instance.new("ScrollingFrame")
    page.Size                 = UDim2.new(1, 0, 1, 0)
    page.BackgroundTransparency = 1
    page.BorderSizePixel      = 0
    page.ScrollBarThickness   = 4
    page.ScrollBarImageColor3 = ACCENT
    page.CanvasSize           = UDim2.new(0, 0, 0, 0)
    page.AutomaticCanvasSize  = Enum.AutomaticSize.Y
    page.Visible              = false
    page.Parent               = Content

    local pl = Instance.new("UIListLayout")
    pl.SortOrder = Enum.SortOrder.LayoutOrder
    pl.Padding   = UDim.new(0, 6)
    pl.Parent    = page
    local pp = Instance.new("UIPadding", page)
    pp.PaddingTop = UDim.new(0, 10); pp.PaddingBottom = UDim.new(0, 10)
    pp.PaddingLeft = UDim.new(0, 10); pp.PaddingRight = UDim.new(0, 10)

    Tabs[title] = { btn = btn, page = page, indicator = indicator, title = t }
    btn.MouseButton1Click:Connect(function() SelectTab(title) end)
    return page
end

----------------------------------------------------------------------
-- widgets (parented into a page)
----------------------------------------------------------------------
local function Section(parent, text)
    local h = Instance.new("Frame")
    h.Size = UDim2.new(1, 0, 0, 22)
    h.BackgroundTransparency = 1
    h.Parent = parent

    local dot = Instance.new("Frame")
    dot.Size = UDim2.new(0, 8, 0, 8)
    dot.Position = UDim2.new(0, 2, 0.5, -4)
    dot.BackgroundColor3 = ACCENT
    dot.BorderSizePixel = 0
    dot.Parent = h
    corner(dot, 4)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -18, 1, 0)
    lbl.Position = UDim2.new(0, 18, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Text = text
    lbl.TextColor3 = ACCENT
    lbl.TextSize = 13
    lbl.Font = Enum.Font.GothamBold
    lbl.Parent = h
end

local function AddToggle(parent, text, default, cb)
    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(1, 0, 0, 34)
    btn.BackgroundColor3 = ROW
    btn.AutoButtonColor  = false
    btn.Text             = ""
    btn.Parent           = parent
    corner(btn, 8)

    local lbl = Instance.new("TextLabel")
    lbl.Size                   = UDim2.new(1, -50, 1, 0)
    lbl.Position               = UDim2.new(0, 10, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.TextXAlignment         = Enum.TextXAlignment.Left
    lbl.Text                   = text
    lbl.TextColor3             = TXT
    lbl.TextSize               = 13
    lbl.Font                   = Enum.Font.GothamMedium
    lbl.Parent                 = btn

    local box = Instance.new("Frame")
    box.Size             = UDim2.new(0, 18, 0, 18)
    box.Position         = UDim2.new(1, -28, 0.5, -9)
    box.BackgroundColor3 = default and ACCENT or ROWOFF
    box.BorderSizePixel  = 0
    box.Parent           = btn
    corner(box, 5)

    local check = Instance.new("TextLabel")
    check.Size = UDim2.new(1, 0, 1, 0)
    check.BackgroundTransparency = 1
    check.Text = default and "v" or ""
    check.TextColor3 = Color3.new(0, 0, 0)
    check.TextSize = 12
    check.Font = Enum.Font.GothamBold
    check.Parent = box

    btn.MouseButton1Click:Connect(function()
        default = not default
        box.BackgroundColor3 = default and ACCENT or ROWOFF
        check.Text = default and "v" or ""
        if cb then cb(default) end
    end)
end

local function AddButton(parent, text, color, cb)
    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(1, 0, 0, 32)
    btn.BackgroundColor3 = color
    btn.AutoButtonColor  = true
    btn.Text             = text
    btn.TextColor3       = Color3.new(1, 1, 1)
    btn.TextSize         = 13
    btn.Font             = Enum.Font.GothamBold
    btn.Parent           = parent
    corner(btn, 8)
    btn.MouseButton1Click:Connect(function() if cb then cb() end end)
end

local function AddSlider(parent, text, min, max, default, cb)
    local box = Instance.new("Frame")
    box.Size             = UDim2.new(1, 0, 0, 44)
    box.BackgroundColor3 = ROW
    box.BorderSizePixel  = 0
    box.Parent           = parent
    corner(box, 8)

    local lbl = Instance.new("TextLabel")
    lbl.Size                   = UDim2.new(1, -50, 0, 18)
    lbl.Position               = UDim2.new(0, 10, 0, 4)
    lbl.BackgroundTransparency = 1
    lbl.TextXAlignment         = Enum.TextXAlignment.Left
    lbl.Text                   = text
    lbl.TextColor3             = TXT
    lbl.TextSize               = 13
    lbl.Font                   = Enum.Font.GothamMedium
    lbl.Parent                 = box

    local val = Instance.new("TextLabel")
    val.Size                   = UDim2.new(0, 40, 0, 18)
    val.Position               = UDim2.new(1, -46, 0, 4)
    val.BackgroundTransparency = 1
    val.TextXAlignment         = Enum.TextXAlignment.Right
    val.Text                   = tostring(default)
    val.TextColor3             = ACCENT
    val.TextSize               = 13
    val.Font                   = Enum.Font.GothamBold
    val.Parent                 = box

    local track = Instance.new("Frame")
    track.Size             = UDim2.new(1, -20, 0, 6)
    track.Position         = UDim2.new(0, 10, 0, 30)
    track.BackgroundColor3 = ROWOFF
    track.BorderSizePixel  = 0
    track.Parent           = box
    corner(track, 3)

    local fill = Instance.new("Frame")
    fill.Size             = UDim2.new((default - min) / (max - min), 0, 1, 0)
    fill.BackgroundColor3 = ACCENT
    fill.BorderSizePixel  = 0
    fill.Parent           = track
    corner(fill, 3)

    local dragging = false
    local function set(x)
        local rel = math.clamp((x - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
        local value = math.floor(min + (max - min) * rel + 0.5)
        fill.Size = UDim2.new((value - min) / (max - min), 0, 1, 0)
        val.Text = tostring(value)
        if cb then cb(value) end
    end
    track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true; set(input.Position.X)
        end
    end)
    TrackConn(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            set(input.Position.X)
        end
    end))
    TrackConn(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))
end

----------------------------------------------------------------------
-- pages / content
----------------------------------------------------------------------
local pMine = AddTab("Mining", "Auto mine, sell")
Section(pMine, "Mining")
AddToggle(pMine, "Auto Mine (Smart Target)", Config.AutoMine,    function(v) Config.AutoMine = v end)
AddToggle(pMine, "Mine Highest Value First",  Config.MineHighestValue, function(v) Config.MineHighestValue = v end)
AddToggle(pMine, "Auto Pickup (Grab)",       Config.AutoCollect, function(v) Config.AutoCollect = v end)
AddToggle(pMine, "Super Fast Mining",        Config.FastMine,    function(v) Config.FastMine = v end)
AddSlider(pMine, "Grab Hold (sec)", 1, 6, Config.GrabHoldTime, function(v) Config.GrabHoldTime = v end)
AddSlider(pMine, "Max Time / Rock",  4, 30, Config.MineMaxTime, function(v) Config.MineMaxTime = v end)
Section(pMine, "Selling")
AddToggle(pMine, "Auto Sell",                Config.AutoSell,    function(v) Config.AutoSell = v end)
AddToggle(pMine, "Auto Sell When Full",      Config.AutoSellFull, function(v) Config.AutoSellFull = v end)
AddButton(pMine, "SELL ALL NOW", Color3.fromRGB(230, 120, 40), function()
    Fire("sell"); Fire("sellall"); Fire("sellcrystals")
    Notify("Sell", "Fired sell / sellall", 2)
end)

local pMove = AddTab("Movement", "Fly, noclip")
Section(pMove, "Positioning")
AddToggle(pMove, "Stay On Rock (No Slide)",  Config.StayOnRock,  function(v) Config.StayOnRock = v end)
AddToggle(pMove, "Anti Fall / No Fall Dmg",  Config.AntiFall,    function(v) Config.AntiFall = v end)
Section(pMove, "Exploits")
AddToggle(pMove, "NoClip (Thru Mountain)",   Config.NoClip,      function(v)
    Config.NoClip = v
    if v then EnableNoClip() else DisableNoClip() end
end)
AddToggle(pMove, "Fly (WASD + Space/Ctrl)",  Config.Fly,         function(v)
    Config.Fly = v
    if v then EnableFly() else DisableFly() end
end)
AddToggle(pMove, "Infinite Jump",            Config.InfiniteJump, function(v) Config.InfiniteJump = v end)
AddToggle(pMove, "Walk Speed Boost",         Config.WalkSpeedOn, function(v)
    Config.WalkSpeedOn = v
    if not v then
        local hum = GetHumanoid()
        if hum then pcall(function() hum.WalkSpeed = 16 end) end
    end
end)
Section(pMove, "Speed")
AddSlider(pMove, "Fly Speed",  20, 250, Config.FlySpeed,  function(v) Config.FlySpeed = v end)
AddSlider(pMove, "Walk Speed", 16, 200, Config.WalkSpeed, function(v) Config.WalkSpeed = v end)

local pPlayer = AddTab("Player", "ESP, godmode")
Section(pPlayer, "Visual")
AddToggle(pPlayer, "Value ESP ($ Price)",    Config.ESP,         function(v)
    Config.ESP = v
    if not v then ClearAllESP() end
end)
Section(pPlayer, "Protection")
AddToggle(pPlayer, "Anti Freeze",            Config.AntiFreeze,  function(v) Config.AntiFreeze = v end)
AddToggle(pPlayer, "God Mode",               Config.GodMode,     function(v)
    Config.GodMode = v
    if v then EnableGodMode() else DisableGodMode() end
end)

local pActions = AddTab("Actions", "TP, upgrades")
Section(pActions, "Teleport")
AddButton(pActions, "TP TO BEST ORE", Color3.fromRGB(70, 130, 255), TPToBestOre)
Section(pActions, "Upgrades")
AddToggle(pActions, "Auto Upgrade",          Config.AutoUpgrade, function(v) Config.AutoUpgrade = v end)
AddButton(pActions, "SPAM UPGRADES x25", Color3.fromRGB(180, 80, 220), SpamUpgrades)

SelectTab("Mining")

if Config.GodMode then EnableGodMode() end
if Config.NoClip then EnableNoClip() end
if Config.Fly then EnableFly() end

print("v12 ready! RightShift = hide/show GUI. Fly = WASD + Space/Ctrl.")
Notify("Mine A Mountain v12", "New compact hub UI loaded", 5)
