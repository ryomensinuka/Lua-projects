--======== KEYBINDS (DEFAULTS) ========
local DEFAULT_AIM_KEY = Enum.KeyCode.X
local DEFAULT_ESP_KEY = Enum.KeyCode.Z
local DEFAULT_MENU_KEY = Enum.KeyCode.F1
local DEFAULT_PANIC_KEY = Enum.KeyCode.P

local AimKey = DEFAULT_AIM_KEY
local EspKey = DEFAULT_ESP_KEY
local MenuKey = DEFAULT_MENU_KEY
local PanicKey = DEFAULT_PANIC_KEY

--======== SERVICES ========
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

--======== STATE ========
local Aiming = false
local ESPEnabled = true
local MenuOpen = false
local currentTarget = nil
local cachedTarget = nil
local currentTab = "combat"
local PanicMode = false

local PanicStored = {
    Aiming = false,
    ESPEnabled = true,
    PerfEnabled = false,
    MenuOpen = false,
}

-- configs
local MAX_DISTANCE = 600
local FOV_RADIUS = 90
local SMOOTH_AMOUNT = 0.25

-- PERFORMANCE CONFIG
local PERFORMANCE = {
    enabled = false,
    espUpdateSlow = 0.25,
    espUpdateNormal = 0.10,
}

-- palette
local COLORS = {
    navy = Color3.fromRGB(10, 18, 32),
    deepNavy = Color3.fromRGB(14, 24, 40),
    gold = Color3.fromRGB(212, 175, 55),
    cream = Color3.fromRGB(240, 236, 228),
    slate = Color3.fromRGB(120, 130, 150),
    accent = Color3.fromRGB(139, 166, 199),
    danger = Color3.fromRGB(220, 80, 80),
    success = Color3.fromRGB(46, 204, 113),
}

local ESP_OPTIONS = {
    highlight = true,
    info = true,
    healthbar = true,
    tracers = false,
}

local function KeyCodeToString(code)
    if not code then
        return "None"
    end
    return tostring(code):gsub("Enum%.KeyCode%.", "")
end

local function Notify(text, dur)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Maia Z",
            Text = text,
            Duration = dur or 2
        })
    end)
end

--======== FOV (DRAWING) ========
local fovCircle = Drawing.new("Circle")
fovCircle.Visible = true
fovCircle.Radius = FOV_RADIUS
fovCircle.Color = COLORS.gold
fovCircle.Thickness = 2
fovCircle.Transparency = 0.7
fovCircle.Filled = false
fovCircle.NumSides = 64

local fovCircleInner = Drawing.new("Circle")
fovCircleInner.Visible = false
fovCircleInner.Radius = FOV_RADIUS - 10
fovCircleInner.Color = COLORS.gold
fovCircleInner.Thickness = 1
fovCircleInner.Transparency = 0.5
fovCircleInner.Filled = false
fovCircleInner.NumSides = 64

local function GetMouseScreenPos()
    local loc = UserInputService:GetMouseLocation()
    return Vector2.new(loc.X, loc.Y)
end

local function UpdateFOV()
    if PanicMode then
        fovCircle.Visible = false
        fovCircleInner.Visible = false
        return
    end

    fovCircle.Visible = true

    local mousePos = GetMouseScreenPos()
    fovCircle.Position = mousePos
    fovCircle.Radius = FOV_RADIUS

    fovCircleInner.Position = mousePos

    if cachedTarget then
        fovCircle.Color = COLORS.gold
        fovCircleInner.Visible = true
    else
        fovCircle.Color = COLORS.accent
        fovCircleInner.Visible = false
    end

    if Aiming and currentTarget then
        local pulse = math.abs(math.sin(tick() * 3)) * 8
        fovCircleInner.Radius = FOV_RADIUS - 10 + pulse
    else
        fovCircleInner.Radius = FOV_RADIUS - 10
    end
end

--======== TARGET PART (HEAD/UPPERTORSO/HRP) ========
local function GetAimPart(character)
    if not character then
        return nil
    end

    local head = character:FindFirstChild("Head")
    if head and head:IsA("BasePart") then
        return head
    end

    local upper = character:FindFirstChild("UpperTorso")
    if upper and upper:IsA("BasePart") then
        return upper
    end

    local hrp = character:FindFirstChild("HumanoidRootPart")
    if hrp and hrp:IsA("BasePart") then
        return hrp
    end

    return nil
end

--======== AIM / ESP CORE ========
local function IsTeammate(plr)
    if LocalPlayer.Team and plr.Team then
        return LocalPlayer.Team == plr.Team
    end
    return false
end

local function IsValidTarget(plr)
    if not plr or plr == LocalPlayer then
        return false
    end

    local char = plr.Character
    if not char then
        return false
    end

    local hum = char:FindFirstChildOfClass("Humanoid")
    local part = GetAimPart(char)
    if not hum or not part then
        return false
    end

    if hum.Health <= 0 then
        return false
    end

    if hum.Health == math.huge or hum.MaxHealth == math.huge or hum.Health > 1e6 or hum.MaxHealth > 1e6 then
        return false
    end

    if char:FindFirstChildOfClass("ForceField") then
        return false
    end

    return true
end

local function WorldToViewport(pos)
    local v3, onScreen = Camera:WorldToViewportPoint(pos)
    return Vector2.new(v3.X, v3.Y), onScreen
end

local function GetTargetFromFOV()
    if PanicMode then
        return nil
    end

    local closest
    local closestScreenDist = math.huge
    local mousePos = GetMouseScreenPos()
    local camPos = Camera.CFrame.Position

    for _, plr in ipairs(Players:GetPlayers()) do
        if IsValidTarget(plr) and not IsTeammate(plr) then
            local char = plr.Character
            local part = GetAimPart(char)
            if part then
                local dist3D = (part.Position - camPos).Magnitude
                if dist3D <= MAX_DISTANCE then
                    local screenPos, onScreen = WorldToViewport(part.Position)
                    if onScreen then
                        local screenDist = (screenPos - mousePos).Magnitude
                        if screenDist <= FOV_RADIUS and screenDist < closestScreenDist then
                            closestScreenDist = screenDist
                            closest = plr
                        end
                    end
                end
            end
        end
    end

    return closest
end

local function AimLock()
    if PanicMode or not Aiming then
        return
    end

    if currentTarget and IsValidTarget(currentTarget) then
        local char = currentTarget.Character
        local part = GetAimPart(char)
        if not part then
            currentTarget = nil
            return
        end

        local targetPos = part.Position
        local targetCFrame = CFrame.new(Camera.CFrame.Position, targetPos)
        Camera.CFrame = Camera.CFrame:Lerp(targetCFrame, SMOOTH_AMOUNT)
        return
    end

    currentTarget = GetTargetFromFOV()
end

local function GetOrCreateHighlight(char)
    local hl = char:FindFirstChild("maiaz_ESP")
    if not hl then
        hl = Instance.new("Highlight")
        hl.Name = "maiaz_ESP"
        hl.FillTransparency = 0.7
        hl.OutlineTransparency = 0
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Parent = char
    end
    return hl
end

local tracers = {}
local function GetOrCreateTracer(plr)
    if tracers[plr] and tracers[plr].__OBJECT then
        return tracers[plr].__OBJECT
    end

    local line = Drawing.new("Line")
    line.Visible = false
    line.Thickness = 1.5
    line.Transparency = 0.8

    tracers[plr] = {
        __OBJECT = line
    }

    return line
end

local function DestroyTracer(plr)
    local t = tracers[plr]
    if t and t.__OBJECT then
        pcall(function()
            t.__OBJECT:Remove()
        end)
    end
    tracers[plr] = nil
end

local function ClearAllESP()
    for _, plr in ipairs(Players:GetPlayers()) do
        local char = plr.Character
        if char then
            local hl = char:FindFirstChild("maiaz_ESP")
            if hl then
                hl:Destroy()
            end

            for _, v in ipairs(char:GetChildren()) do
                if v:IsA("BillboardGui") and v.Name == "maiaz_Info" then
                    v:Destroy()
                end
            end
        end
        DestroyTracer(plr)
    end
end

local function UpdateESPForPlayer(plr)
    if PanicMode then
        DestroyTracer(plr)
        return
    end

    local char = plr.Character
    if not char then
        DestroyTracer(plr)
        return
    end

    local hl = char:FindFirstChild("maiaz_ESP")
    local head = GetAimPart(char)
    local billboard = nil
    if head then
        billboard = head:FindFirstChild("maiaz_Info")
    end

    if not ESPEnabled or not IsValidTarget(plr) or IsTeammate(plr) then
        if hl then
            hl:Destroy()
        end
        if billboard then
            billboard:Destroy()
        end
        DestroyTracer(plr)
        return
    end

    -- highlight
    if ESP_OPTIONS.highlight then
        hl = GetOrCreateHighlight(char)
        if plr == currentTarget then
            hl.FillColor = COLORS.gold
            hl.OutlineColor = COLORS.gold
        else
            hl.FillColor = COLORS.accent
            hl.OutlineColor = COLORS.accent
        end
        hl.Enabled = true
    else
        if hl then
            hl:Destroy()
        end
    end

    -- infos
    if head and ESP_OPTIONS.info then
        billboard = head:FindFirstChild("maiaz_Info")
        if not billboard then
            billboard = Instance.new("BillboardGui")
            billboard.Name = "maiaz_Info"
            billboard.Size = UDim2.new(0, 110, 0, 40)
            billboard.StudsOffset = Vector3.new(0, 2, 0)
            billboard.AlwaysOnTop = true
            billboard.Parent = head

            local text = Instance.new("TextLabel")
            text.Name = "Label"
            text.Size = UDim2.new(1, 0, 0.5, 0)
            text.BackgroundTransparency = 1
            text.Font = Enum.Font.GothamMedium
            text.TextSize = 13
            text.TextStrokeTransparency = 0.5
            text.TextColor3 = COLORS.cream
            text.TextXAlignment = Enum.TextXAlignment.Center
            text.Parent = billboard

            local barBg = Instance.new("Frame")
            barBg.Name = "HPBG"
            barBg.Size = UDim2.new(1, -14, 0, 6)
            barBg.Position = UDim2.new(0, 7, 1, -8)
            barBg.BackgroundColor3 = COLORS.deepNavy
            barBg.BorderSizePixel = 0
            barBg.Parent = billboard

            local barBgCorner = Instance.new("UICorner")
            barBgCorner.CornerRadius = UDim.new(0, 3)
            barBgCorner.Parent = barBg

            local bar = Instance.new("Frame")
            bar.Name = "HP"
            bar.Size = UDim2.new(1, 0, 1, 0)
            bar.BackgroundColor3 = COLORS.gold
            bar.BorderSizePixel = 0
            bar.Parent = barBg

            local barCorner = Instance.new("UICorner")
            barCorner.CornerRadius = UDim.new(0, 3)
            barCorner.Parent = bar
        end

        local hum = char:FindFirstChildOfClass("Humanoid")
        local hp = hum and hum.Health or 0
        local maxHp = hum and hum.MaxHealth or 100
        local dist = math.floor((head.Position - Camera.CFrame.Position).Magnitude)

        local label = billboard:FindFirstChild("Label")
        local hpBg = billboard:FindFirstChild("HPBG")
        local hpBar = hpBg and hpBg:FindFirstChild("HP")

        if label then
            label.Text = string.format("%s\n%dm | %dHP", plr.Name, dist, math.floor(hp))
            label.TextColor3 = plr == currentTarget and COLORS.gold or COLORS.cream
        end

        if ESP_OPTIONS.healthbar and hpBg and hpBar and maxHp > 0 then
            local ratio = math.clamp(hp / maxHp, 0, 1)
            hpBar.Size = UDim2.new(ratio, 0, 1, 0)
            if ratio > 0.6 then
                hpBar.BackgroundColor3 = COLORS.success
            elseif ratio > 0.3 then
                hpBar.BackgroundColor3 = Color3.fromRGB(241, 196, 15)
            else
                hpBar.BackgroundColor3 = Color3.fromRGB(231, 76, 60)
            end
        end
    else
        if billboard then
            billboard:Destroy()
        end
    end

    -- tracers
    local tracerObj = tracers[plr] and tracers[plr].__OBJECT or nil
    if ESP_OPTIONS.tracers and head then
        local line = tracerObj or GetOrCreateTracer(plr)
        local screenHead, onScreen = WorldToViewport(head.Position)
        if onScreen then
            local viewportSize = Camera.ViewportSize
            local from = Vector2.new(viewportSize.X / 2, viewportSize.Y)
            line.From = from
            line.To = screenHead
            line.Color = plr == currentTarget and COLORS.gold or COLORS.accent
            line.Visible = true
        else
            line.Visible = false
        end
    else
        if tracerObj then
            tracerObj.Visible = false
        end
    end
end

local function UpdateAllESP()
    if PanicMode then
        ClearAllESP()
        return
    end

    local processed = 0
    local maxPlayersPerTick = PERFORMANCE.enabled and 12 or math.huge

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then
            UpdateESPForPlayer(plr)
            processed += 1
            if processed >= maxPlayersPerTick then
                break
            end
        end
    end
end

local function ForceRefreshESP()
    if not ESPEnabled or PanicMode then
        return
    end
    ClearAllESP()
    UpdateAllESP()
end

Players.PlayerAdded:Connect(function(plr)
    plr.CharacterAdded:Connect(function()
        task.wait(0.5)
        if ESPEnabled and not PanicMode then
            UpdateESPForPlayer(plr)
        end
    end)
end)

Players.PlayerRemoving:Connect(function(plr)
    if plr == currentTarget then
        currentTarget = nil
        Aiming = false
    end
    DestroyTracer(plr)
end)

--======== PERFORMANCE MODE ========
local function ApplyPerformanceMode(on)
    PERFORMANCE.enabled = on

    for _, obj in ipairs(Lighting:GetChildren()) do
        if obj:IsA("BloomEffect") or obj:IsA("DepthOfFieldEffect") or obj:IsA("ColorCorrectionEffect") then
            obj.Enabled = not on
        end
    end

    for _, inst in ipairs(Workspace:GetDescendants()) do
        if inst:IsA("ParticleEmitter") or inst:IsA("Trail") then
            inst.Enabled = not on
        end
    end

    if not PanicMode then
        Notify(on and "Modo 0 LAG ativado" or "Modo 0 LAG desativado", 2)
    end
end

--======== PANIC BUTTON ========
local HelpGui

local function TogglePanic()
    PanicMode = not PanicMode

    if PanicMode then
        PanicStored.Aiming = Aiming
        PanicStored.ESPEnabled = ESPEnabled
        PanicStored.PerfEnabled = PERFORMANCE.enabled
        PanicStored.MenuOpen = MenuOpen

        Aiming = false
        ESPEnabled = false
        MenuOpen = false

        if PERFORMANCE.enabled then
            ApplyPerformanceMode(false)
        end

        ClearAllESP()
        fovCircle.Visible = false
        fovCircleInner.Visible = false

        if HelpGui then
            HelpGui.Enabled = false
        end

        Notify("Botão do Pânico - Maia Z OFF temporário", 2)
    else
        Aiming = false
        ESPEnabled = PanicStored.ESPEnabled

        if PanicStored.PerfEnabled then
            ApplyPerformanceMode(true)
        end

        MenuOpen = PanicStored.MenuOpen

        fovCircle.Visible = true
        fovCircleInner.Visible = false

        if HelpGui then
            HelpGui.Enabled = MenuOpen
        end

        ForceRefreshESP()
        Notify("Botão do Pânico - Maia Z restaurado", 2)
    end
end

--======== UI HELPERS / MENU ========
local MainFrame
local ContentFrame
local TabButtons = {}
local startTime = tick()

local Rebinding = {
    active = false,
    target = nil,
    label = nil,
}

local function BeginRebind(target, labelObj)
    if Rebinding.active then
        return
    end

    Rebinding.active = true
    Rebinding.target = target
    Rebinding.label = labelObj

    if labelObj then
        labelObj.Text = "Pressione uma tecla..."
    end

    Notify("Pressione a nova tecla para " .. target .. " (Maia Z)", 3)
end

local function FinishRebind(keyCode)
    if not Rebinding.active or not keyCode then
        Rebinding.active = false
        Rebinding.target = nil
        Rebinding.label = nil
        return
    end

    if not tostring(keyCode):find("Enum.KeyCode.") then
        return
    end

    if Rebinding.target == "aim" then
        AimKey = keyCode
    elseif Rebinding.target == "esp" then
        EspKey = keyCode
    elseif Rebinding.target == "menu" then
        MenuKey = keyCode
    elseif Rebinding.target == "panic" then
        PanicKey = keyCode
    end

    if Rebinding.label then
        Rebinding.label.Text = "Tecla: " .. KeyCodeToString(keyCode)
    end

    Notify("Tecla atualizada para " .. Rebinding.target .. ": " .. KeyCodeToString(keyCode), 2)

    Rebinding.active = false
    Rebinding.target = nil
    Rebinding.label = nil
end

local function CreateSlider(parent, name, desc, yPos, min, max, default, callback)
    local container = Instance.new("Frame")
    container.Size = UDim2.new(1, -40, 0, 70)
    container.Position = UDim2.new(0, 20, 0, yPos)
    container.BackgroundTransparency = 1
    container.Parent = parent

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(0.6, 0, 0, 20)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamBold
    label.TextSize = 15
    label.TextColor3 = COLORS.cream
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = name
    label.Parent = container

    local valueLabel = Instance.new("TextLabel")
    valueLabel.Size = UDim2.new(0.4, 0, 0, 20)
    valueLabel.Position = UDim2.new(0.6, 0, 0, 0)
    valueLabel.BackgroundTransparency = 1
    valueLabel.Font = Enum.Font.Gotham
    valueLabel.TextSize = 13
    valueLabel.TextColor3 = COLORS.gold
    valueLabel.TextXAlignment = Enum.TextXAlignment.Right
    valueLabel.Text = tostring(default)
    valueLabel.Parent = container

    local descLabel = Instance.new("TextLabel")
    descLabel.Size = UDim2.new(1, 0, 0, 24)
    descLabel.Position = UDim2.new(0, 0, 0, 22)
    descLabel.BackgroundTransparency = 1
    descLabel.Font = Enum.Font.Gotham
    descLabel.TextSize = 12
    descLabel.TextColor3 = COLORS.slate
    descLabel.TextXAlignment = Enum.TextXAlignment.Left
    descLabel.TextWrapped = true
    descLabel.TextTruncate = Enum.TextTruncate.None
    descLabel.Text = desc
    descLabel.Parent = container

    local sliderBg = Instance.new("Frame")
    sliderBg.Size = UDim2.new(1, 0, 0, 4)
    sliderBg.Position = UDim2.new(0, 0, 0, 52)
    sliderBg.BackgroundColor3 = COLORS.deepNavy
    sliderBg.BackgroundTransparency = 0.15
    sliderBg.BorderSizePixel = 0
    sliderBg.Parent = container

    local sliderBgCorner = Instance.new("UICorner")
    sliderBgCorner.CornerRadius = UDim.new(0, 2)
    sliderBgCorner.Parent = sliderBg

    local sliderFill = Instance.new("Frame")
    sliderFill.Size = UDim2.new((default - min) / (max - min), 0, 1, 0)
    sliderFill.BackgroundColor3 = COLORS.gold
    sliderFill.BorderSizePixel = 0
    sliderFill.Parent = sliderBg

    local sliderFillCorner = Instance.new("UICorner")
    sliderFillCorner.CornerRadius = UDim.new(0, 2)
    sliderFillCorner.Parent = sliderFill

    local dragging = false

    local function updateSlider(input)
        local pos = math.clamp((input.Position.X - sliderBg.AbsolutePosition.X) / sliderBg.AbsoluteSize.X, 0, 1)
        local value = math.floor(min + (max - min) * pos)
        sliderFill.Size = UDim2.new(pos, 0, 1, 0)
        valueLabel.Text = tostring(value)
        callback(value)
    end

    sliderBg.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            updateSlider(input)
        end
    end)

    sliderBg.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = false
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            updateSlider(input)
        end
    end)
end

local function CreateToggle(parent, yPos, labelText, key)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, -40, 0, 38)
    btn.Position = UDim2.new(0, 20, 0, yPos)
    btn.BackgroundColor3 = COLORS.deepNavy
    btn.BackgroundTransparency = 0.15
    btn.BorderSizePixel = 0
    btn.AutoButtonColor = false
    btn.Font = Enum.Font.Gotham
    btn.TextSize = 14
    btn.TextXAlignment = Enum.TextXAlignment.Left
    btn.TextColor3 = COLORS.cream
    btn.Text = "  " .. labelText
    btn.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = btn

    local icon = Instance.new("Frame")
    icon.Size = UDim2.new(0, 18, 0, 18)
    icon.Position = UDim2.new(0, 10, 0.5, -9)
    icon.BackgroundColor3 = Color3.fromRGB(5, 10, 20)
    icon.BorderSizePixel = 0
    icon.Parent = btn

    local iconCorner = Instance.new("UICorner")
    iconCorner.CornerRadius = UDim.new(0, 5)
    iconCorner.Parent = icon

    local indicator = Instance.new("Frame")
    indicator.Size = UDim2.new(0, 11, 0, 11)
    indicator.Position = UDim2.new(0.5, -5, 0.5, -5)
    indicator.BackgroundColor3 = ESP_OPTIONS[key] and COLORS.gold or COLORS.slate
    indicator.BorderSizePixel = 0
    indicator.Parent = icon

    local indCorner = Instance.new("UICorner")
    indCorner.CornerRadius = UDim.new(1, 0)
    indCorner.Parent = indicator

    btn.MouseButton1Click:Connect(function()
        ESP_OPTIONS[key] = not ESP_OPTIONS[key]
        indicator.BackgroundColor3 = ESP_OPTIONS[key] and COLORS.gold or COLORS.slate
        UpdateAllESP()
    end)
end

local function FormatTime(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    return string.format("%02d:%02d:%02d", h, m, s)
end

local function SwitchTab(tabName)
    currentTab = tabName

    for name, btn in pairs(TabButtons) do
        if name == tabName then
            btn.TextColor3 = COLORS.gold
            btn.BackgroundTransparency = 0.1
        else
            btn.TextColor3 = COLORS.slate
            btn.BackgroundTransparency = 1
        end
    end

    for _, child in pairs(ContentFrame:GetChildren()) do
        child:Destroy()
    end

    if tabName == "combat" then
        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -40, 0, 24)
        title.Position = UDim2.new(0, 20, 0, 10)
        title.BackgroundTransparency = 1
        title.Font = Enum.Font.GothamBold
        title.TextSize = 18
        title.TextColor3 = COLORS.cream
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.Text = "Combat Control"
        title.Parent = ContentFrame

        CreateSlider(ContentFrame, "FOV", "Área de detecção na tela", 50, 50, 220, FOV_RADIUS, function(v)
            FOV_RADIUS = v
        end)

        CreateSlider(ContentFrame, "Smooth", "Velocidade da mira (maior = mais seco)", 130, 5, 60, SMOOTH_AMOUNT * 100, function(v)
            SMOOTH_AMOUNT = v / 100
        end)

        CreateSlider(ContentFrame, "Distância", "Alcance máximo em studs", 210, 150, 1200, MAX_DISTANCE, function(v)
            MAX_DISTANCE = v
        end)

        local status = Instance.new("TextLabel")
        status.Name = "StatusLabel"
        status.Size = UDim2.new(1, -40, 0, 40)
        status.Position = UDim2.new(0, 20, 0, 290)
        status.BackgroundColor3 = COLORS.deepNavy
        status.BackgroundTransparency = 0.25
        status.BorderSizePixel = 0
        status.Font = Enum.Font.Gotham
        status.TextSize = 13
        status.TextColor3 = COLORS.accent
        status.TextXAlignment = Enum.TextXAlignment.Center
        status.TextYAlignment = Enum.TextYAlignment.Center
        status.Text = "Idle - Nenhum alvo"
        status.Parent = ContentFrame

        local statusCorner = Instance.new("UICorner")
        statusCorner.CornerRadius = UDim.new(0, 6)
        statusCorner.Parent = status

    elseif tabName == "visual" then
        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -40, 0, 24)
        title.Position = UDim2.new(0, 20, 0, 10)
        title.BackgroundTransparency = 1
        title.Font = Enum.Font.GothamBold
        title.TextSize = 18
        title.TextColor3 = COLORS.cream
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.Text = "Visual Layer"
        title.Parent = ContentFrame

        CreateToggle(ContentFrame, 50, "Highlight (contorno)", "highlight")
        CreateToggle(ContentFrame, 92, "Infos (nome / distância / HP)", "info")
        CreateToggle(ContentFrame, 134, "Healthbar (barra de vida)", "healthbar")
        CreateToggle(ContentFrame, 176, "Tracers (linhas)", "tracers")

        local espBtn = Instance.new("TextButton")
        espBtn.Name = "ESPButton"
        espBtn.Size = UDim2.new(1, -40, 0, 40)
        espBtn.Position = UDim2.new(0, 20, 0, 246)
        espBtn.BackgroundColor3 = ESPEnabled and COLORS.gold or COLORS.slate
        espBtn.BackgroundTransparency = 0
        espBtn.BorderSizePixel = 0
        espBtn.Font = Enum.Font.GothamBold
        espBtn.TextSize = 14
        espBtn.TextColor3 = ESPEnabled and COLORS.navy or COLORS.cream
        espBtn.Text = ESPEnabled and "ESP ATIVO" or "ESP DESATIVADO"
        espBtn.Parent = ContentFrame

        local espCorner = Instance.new("UICorner")
        espCorner.CornerRadius = UDim.new(0, 8)
        espCorner.Parent = espBtn

        espBtn.MouseButton1Click:Connect(function()
            if PanicMode then
                return
            end
            ESPEnabled = not ESPEnabled
            espBtn.BackgroundColor3 = ESPEnabled and COLORS.gold or COLORS.slate
            espBtn.TextColor3 = ESPEnabled and COLORS.navy or COLORS.cream
            espBtn.Text = ESPEnabled and "ESP ATIVO" or "ESP DESATIVADO"
            Notify(ESPEnabled and "ESP ativado" or "ESP desativado", 2)
            ForceRefreshESP()
        end)

    elseif tabName == "performance" then
        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -40, 0, 24)
        title.Position = UDim2.new(0, 20, 0, 10)
        title.BackgroundTransparency = 1
        title.Font = Enum.Font.GothamBold
        title.TextSize = 18
        title.TextColor3 = COLORS.cream
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.Text = "Performance"
        title.Parent = ContentFrame

        local desc = Instance.new("TextLabel")
        desc.Size = UDim2.new(1, -40, 0, 36)
        desc.Position = UDim2.new(0, 20, 0, 40)
        desc.BackgroundTransparency = 1
        desc.Font = Enum.Font.Gotham
        desc.TextSize = 13
        desc.TextColor3 = COLORS.slate
        desc.TextXAlignment = Enum.TextXAlignment.Left
        desc.TextYAlignment = Enum.TextYAlignment.Top
        desc.TextWrapped = true
        desc.Text = "Modo 0 LAG (EM TESTE, EVITE USAR)"
        desc.Parent = ContentFrame

        local perfBtn = Instance.new("TextButton")
        perfBtn.Name = "PerfButton"
        perfBtn.Size = UDim2.new(1, -40, 0, 44)
        perfBtn.Position = UDim2.new(0, 20, 0, 90)
        perfBtn.BackgroundColor3 = PERFORMANCE.enabled and COLORS.success or COLORS.danger
        perfBtn.BackgroundTransparency = 0
        perfBtn.BorderSizePixel = 0
        perfBtn.Font = Enum.Font.GothamBold
        perfBtn.TextSize = 14
        perfBtn.TextColor3 = COLORS.cream
        perfBtn.Text = PERFORMANCE.enabled and "MODO 0 LAG: ATIVO" or "MODO 0 LAG: DESATIVADO"
        perfBtn.Parent = ContentFrame

        local perfCorner = Instance.new("UICorner")
        perfCorner.CornerRadius = UDim.new(0, 8)
        perfCorner.Parent = perfBtn

        perfBtn.MouseButton1Click:Connect(function()
            if PanicMode then
                return
            end
            ApplyPerformanceMode(not PERFORMANCE.enabled)
            perfBtn.BackgroundColor3 = PERFORMANCE.enabled and COLORS.success or COLORS.danger
            perfBtn.Text = PERFORMANCE.enabled and "MODO 0 LAG: ATIVO" or "MODO 0 LAG: DESATIVADO"
        end)

    elseif tabName == "config" then
        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -40, 0, 24)
        title.Position = UDim2.new(0, 20, 0, 10)
        title.BackgroundTransparency = 1
        title.Font = Enum.Font.GothamBold
        title.TextSize = 18
        title.TextColor3 = COLORS.cream
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.Text = "Keybinds & Panic"
        title.Parent = ContentFrame

        local function CreateKeybindRow(y, labelText, getKey, setTarget)
            local row = Instance.new("Frame")
            row.Size = UDim2.new(1, -40, 0, 30)
            row.Position = UDim2.new(0, 20, 0, y)
            row.BackgroundTransparency = 1
            row.Parent = ContentFrame

            local lbl = Instance.new("TextLabel")
            lbl.Size = UDim2.new(0.6, 0, 1, 0)
            lbl.Position = UDim2.new(0, 0, 0, 0)
            lbl.BackgroundTransparency = 1
            lbl.Font = Enum.Font.Gotham
            lbl.TextSize = 14
            lbl.TextColor3 = COLORS.cream
            lbl.TextXAlignment = Enum.TextXAlignment.Left
            lbl.Text = labelText
            lbl.Parent = row

            local btn = Instance.new("TextButton")
            btn.Size = UDim2.new(0.4, -10, 1, 0)
            btn.Position = UDim2.new(0.6, 10, 0, 0)
            btn.BackgroundColor3 = COLORS.deepNavy
            btn.BackgroundTransparency = 0.15
            btn.BorderSizePixel = 0
            btn.Font = Enum.Font.Gotham
            btn.TextSize = 13
            btn.TextColor3 = COLORS.gold
            btn.TextXAlignment = Enum.TextXAlignment.Center
            btn.Text = "Tecla: " .. KeyCodeToString(getKey())
            btn.Parent = row

            local corner = Instance.new("UICorner")
            corner.CornerRadius = UDim.new(0, 6)
            corner.Parent = btn

            btn.MouseButton1Click:Connect(function()
                if PanicMode then
                    return
                end
                BeginRebind(setTarget, btn)
            end)
        end

        CreateKeybindRow(50, "Aimlock", function() return AimKey end, "aim")
        CreateKeybindRow(90, "ESP", function() return EspKey end, "esp")
        CreateKeybindRow(130, "Menu", function() return MenuKey end, "menu")
        CreateKeybindRow(170, "Botão do Pânico", function() return PanicKey end, "panic")

        local info = Instance.new("TextLabel")
        info.Size = UDim2.new(1, -40, 0, 60)
        info.Position = UDim2.new(0, 20, 0, 210)
        info.BackgroundTransparency = 1
        info.Font = Enum.Font.Gotham
        info.TextSize = 12
        info.TextColor3 = COLORS.slate
        info.TextXAlignment = Enum.TextXAlignment.Left
        info.TextYAlignment = Enum.TextYAlignment.Top
        info.TextWrapped = true
        info.Text = "Botão do Pânico: desliga Maia Z temporariamente (Aim, ESP, Performance, menu). Pressione novamente para restaurar."
        info.Parent = ContentFrame

        local panicBtn = Instance.new("TextButton")
        panicBtn.Size = UDim2.new(1, -40, 0, 40)
        panicBtn.Position = UDim2.new(0, 20, 0, 280)
        panicBtn.BackgroundColor3 = PanicMode and COLORS.danger or COLORS.deepNavy
        panicBtn.BackgroundTransparency = 0
        panicBtn.BorderSizePixel = 0
        panicBtn.Font = Enum.Font.GothamBold
        panicBtn.TextSize = 14
        panicBtn.TextColor3 = COLORS.cream
        panicBtn.Text = PanicMode and "PANIC ATIVO" or "ATIVAR BOTÃO DO PÂNICO"
        panicBtn.Parent = ContentFrame

        local panicCorner = Instance.new("UICorner")
        panicCorner.CornerRadius = UDim.new(0, 8)
        panicCorner.Parent = panicBtn

        panicBtn.MouseButton1Click:Connect(function()
            TogglePanic()
            panicBtn.BackgroundColor3 = PanicMode and COLORS.danger or COLORS.deepNavy
            panicBtn.Text = PanicMode and "PANIC ATIVO" or "ATIVAR BOTÃO DO PÂNICO"
        end)

    elseif tabName == "info" then
        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -40, 0, 24)
        title.Position = UDim2.new(0, 20, 0, 10)
        title.BackgroundTransparency = 1
        title.Font = Enum.Font.GothamBold
        title.TextSize = 18
        title.TextColor3 = COLORS.cream
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.Text = "Session"
        title.Parent = ContentFrame

        local info = Instance.new("TextLabel")
        info.Name = "ServerInfo"
        info.Size = UDim2.new(1, -40, 0, 80)
        info.Position = UDim2.new(0, 20, 0, 50)
        info.BackgroundColor3 = COLORS.deepNavy
        info.BackgroundTransparency = 0.2
        info.BorderSizePixel = 0
        info.Font = Enum.Font.Gotham
        info.TextSize = 13
        info.TextColor3 = COLORS.accent
        info.TextXAlignment = Enum.TextXAlignment.Left
        info.TextYAlignment = Enum.TextYAlignment.Top
        info.Text = "Carregando..."
        info.Parent = ContentFrame

        local infoCorner = Instance.new("UICorner")
        infoCorner.CornerRadius = UDim.new(0, 8)
        infoCorner.Parent = info
    end
end

local function CreateMenu()
    HelpGui = Instance.new("ScreenGui")
    HelpGui.Name = "MaiaZ_UI"
    HelpGui.ResetOnSpawn = false
    HelpGui.Enabled = false
    HelpGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

    MainFrame = Instance.new("Frame")
    MainFrame.Name = "MainFrame"
    MainFrame.Size = UDim2.new(0, 520, 0, 360)
    MainFrame.Position = UDim2.new(0.5, -260, 0.5, -180)
    MainFrame.BackgroundColor3 = COLORS.navy
    MainFrame.BackgroundTransparency = 0.1
    MainFrame.BorderSizePixel = 0
    MainFrame.Parent = HelpGui

    local mainCorner = Instance.new("UICorner")
    mainCorner.CornerRadius = UDim.new(0, 6)
    mainCorner.Parent = MainFrame

    local mainStroke = Instance.new("UIStroke")
    mainStroke.Thickness = 1
    mainStroke.Color = COLORS.gold
    mainStroke.Transparency = 0.5
    mainStroke.Parent = MainFrame

    local header = Instance.new("Frame")
    header.Name = "Header"
    header.Size = UDim2.new(1, 0, 0, 46)
    header.BackgroundColor3 = COLORS.deepNavy
    header.BackgroundTransparency = 0
    header.BorderSizePixel = 0
    header.Parent = MainFrame

    local headerLine = Instance.new("Frame")
    headerLine.Size = UDim2.new(1, 0, 0, 1)
    headerLine.Position = UDim2.new(0, 0, 1, -1)
    headerLine.BackgroundColor3 = COLORS.gold
    headerLine.BorderSizePixel = 0
    headerLine.Parent = header

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(0, 200, 1, 0)
    title.Position = UDim2.new(0, 18, 0, 0)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 18
    title.TextColor3 = COLORS.cream
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "Maia Z"
    title.Parent = header

    local subtitle = Instance.new("TextLabel")
    subtitle.Size = UDim2.new(0, 220, 1, -20)
    subtitle.Position = UDim2.new(0, 18, 0, 20)
    subtitle.BackgroundTransparency = 1
    subtitle.Font = Enum.Font.Gotham
    subtitle.TextSize = 12
    subtitle.TextColor3 = COLORS.slate
    subtitle.TextXAlignment = Enum.TextXAlignment.Left
    subtitle.Text = "Modulo de combate Executivo"
    subtitle.Parent = header

    local badge = Instance.new("TextLabel")
    badge.Size = UDim2.new(0, 110, 0, 20)
    badge.Position = UDim2.new(1, -120, 0.5, -10)
    badge.BackgroundColor3 = COLORS.gold
    badge.BorderSizePixel = 0
    badge.Font = Enum.Font.GothamBold
    badge.TextSize = 11
    badge.TextColor3 = COLORS.navy
    badge.TextXAlignment = Enum.TextXAlignment.Center
    badge.Text = "PRIVATE BUILD"
    badge.Parent = header

    local badgeCorner = Instance.new("UICorner")
    badgeCorner.CornerRadius = UDim.new(0, 10)
    badgeCorner.Parent = badge

    do
        local dragging = false
        local dragStart
        local startPos

        header.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging = true
                dragStart = UserInputService:GetMouseLocation()
                startPos = MainFrame.Position
            end
        end)

        header.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging = false
            end
        end)

        UserInputService.InputChanged:Connect(function(input)
            if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
                local mousePos = UserInputService:GetMouseLocation()
                local delta = mousePos - dragStart
                MainFrame.Position = UDim2.new(
                    startPos.X.Scale,
                    startPos.X.Offset + delta.X,
                    startPos.Y.Scale,
                    startPos.Y.Offset + delta.Y
                )
            end
        end)
    end

    local sidebar = Instance.new("Frame")
    sidebar.Size = UDim2.new(0, 130, 1, -46)
    sidebar.Position = UDim2.new(0, 0, 0, 46)
    sidebar.BackgroundColor3 = COLORS.navy
    sidebar.BackgroundTransparency = 0.1
    sidebar.BorderSizePixel = 0
    sidebar.Parent = MainFrame

    local tabList = Instance.new("UIListLayout")
    tabList.FillDirection = Enum.FillDirection.Vertical
    tabList.HorizontalAlignment = Enum.HorizontalAlignment.Left
    tabList.VerticalAlignment = Enum.VerticalAlignment.Top
    tabList.Padding = UDim.new(0, 4)
    tabList.Parent = sidebar

    local function CreateTab(name, labelText, short)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, 0, 0, 32)
        btn.BackgroundTransparency = 1
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Font = Enum.Font.Gotham
        btn.TextSize = 13
        btn.TextColor3 = COLORS.slate
        btn.TextXAlignment = Enum.TextXAlignment.Left
        btn.Text = "  " .. labelText
        btn.Parent = sidebar

        local icon = Instance.new("TextLabel")
        icon.Size = UDim2.new(0, 18, 0, 18)
        icon.Position = UDim2.new(0, 10, 0.5, -9)
        icon.BackgroundColor3 = COLORS.deepNavy
        icon.BorderSizePixel = 0
        icon.Font = Enum.Font.GothamBold
        icon.TextSize = 11
        icon.TextColor3 = COLORS.slate
        icon.Text = short
        icon.Parent = btn

        local iconCorner = Instance.new("UICorner")
        iconCorner.CornerRadius = UDim.new(0, 4)
        iconCorner.Parent = icon

        TabButtons[name] = btn

        btn.MouseButton1Click:Connect(function()
            if PanicMode and name ~= "config" then
                return
            end
            SwitchTab(name)
        end)
    end

    CreateTab("combat", "Combat", "C")
    CreateTab("visual", "Visual", "V")
    CreateTab("performance", "Perf", "P")
    CreateTab("config", "Config", "K")
    CreateTab("info", "Session", "S")

    ContentFrame = Instance.new("Frame")
    ContentFrame.Name = "Content"
    ContentFrame.Size = UDim2.new(1, -130, 1, -46)
    ContentFrame.Position = UDim2.new(0, 130, 0, 46)
    ContentFrame.BackgroundColor3 = COLORS.deepNavy
    ContentFrame.BackgroundTransparency = 0.15
    ContentFrame.BorderSizePixel = 0
    ContentFrame.Parent = MainFrame

    local contentCorner = Instance.new("UICorner")
    contentCorner.CornerRadius = UDim.new(0, 6)
    contentCorner.Parent = ContentFrame

    SwitchTab("combat")
end

CreateMenu()

local function ToggleMenu()
    if not HelpGui or PanicMode then
        return
    end
    MenuOpen = not MenuOpen
    HelpGui.Enabled = MenuOpen
end

local lastTargetCheck = 0
local lastESPUpdate = 0

RunService.Heartbeat:Connect(function()
    if PanicMode then
        return
    end

    if MenuOpen and currentTab == "combat" then
        local statusLabel = ContentFrame:FindFirstChild("StatusLabel", true)
        if statusLabel then
            local targetText = currentTarget and currentTarget.Name or "Nenhum alvo"
            local aimStatus = Aiming and "Active" or "Idle"
            statusLabel.Text = string.format("%s • %s", aimStatus, targetText)
            statusLabel.TextColor3 = Aiming and COLORS.gold or COLORS.accent
        end
    end

    if MenuOpen and currentTab == "info" then
        local serverInfo = ContentFrame:FindFirstChild("ServerInfo", true)
        if serverInfo then
            local playerCount = #Players:GetPlayers()
            local uptime = FormatTime(tick() - startTime)
            serverInfo.Text = string.format("Jogadores: %d\nTempo ativo: %s", playerCount, uptime)
        end
    end
end)

UserInputService.InputBegan:Connect(function(input, gp)
    if gp then
        return
    end

    if Rebinding.active and input.UserInputType == Enum.UserInputType.Keyboard then
        FinishRebind(input.KeyCode)
        return
    end

    if input.KeyCode == PanicKey then
        TogglePanic()
        return
    end

    if PanicMode then
        return
    end

    if input.KeyCode == AimKey then
        Aiming = not Aiming
        if Aiming then
            currentTarget = GetTargetFromFOV()
            if currentTarget then
                Notify("Travado em " .. currentTarget.Name, 2)
            else
                Notify("Nenhum alvo detectado", 2)
                Aiming = false
            end
        else
            Notify("Aimlock desativado", 2)
            currentTarget = nil
        end
        ForceRefreshESP()
    end

    if input.KeyCode == EspKey then
        ESPEnabled = not ESPEnabled
        Notify(ESPEnabled and "ESP ativado" or "ESP desativado", 2)
        ForceRefreshESP()
    end

    if input.KeyCode == MenuKey then
        ToggleMenu()
    end
end)

RunService.RenderStepped:Connect(function()
    UpdateFOV()

    if PanicMode then
        return
    end

    if Aiming then
        AimLock()
        if currentTarget and not IsValidTarget(currentTarget) then
            currentTarget = nil
        end
    end

    if tick() - lastTargetCheck > 0.05 then
        cachedTarget = GetTargetFromFOV()
        lastTargetCheck = tick()
    end

    local interval = PERFORMANCE.enabled and PERFORMANCE.espUpdateSlow or PERFORMANCE.espUpdateNormal
    if tick() - lastESPUpdate > interval then
        if ESPEnabled then
            UpdateAllESP()
        end
        lastESPUpdate = tick()
    end
end)

Notify("Maia Z carregado - abra o menu e configure seus binds", 3)
