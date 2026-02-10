--[[
    MAIA Z - PRIVATE BUILD
    Sistema de Combate Executivo
    
    Melhorias aplicadas:
    - UI alinhada e consistente (sliders, toggles, labels)
    - Proteção contra remoção (watchdog)
    - Mira humanizada (variação suave)
    - Nomes neutralizados (anti-detecção leve)
    - Código estruturado e otimizado
]]

--======== CONFIGURAÇÃO DE TECLAS PADRÃO ========
local DEFAULT_AIM_KEY   = Enum.KeyCode.X
local DEFAULT_ESP_KEY   = Enum.KeyCode.Z
local DEFAULT_MENU_KEY  = Enum.KeyCode.F1
local DEFAULT_PANIC_KEY = Enum.KeyCode.P

local AimKey   = DEFAULT_AIM_KEY
local EspKey   = DEFAULT_ESP_KEY
local MenuKey  = DEFAULT_MENU_KEY
local PanicKey = DEFAULT_PANIC_KEY

--======== SERVIÇOS ========
local Players          = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService       = game:GetService("RunService")
local StarterGui       = game:GetService("StarterGui")
local Lighting         = game:GetService("Lighting")
local Workspace        = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local Camera      = Workspace.CurrentCamera

--======== ESTADO GLOBAL ========
local Controller = {
    active         = false,  -- Aimlock ativo
    visualsOn      = true,   -- ESP ativo
    uiVisible      = false,  -- Menu aberto
    safeMode       = false,  -- Panic mode
    currentFocus   = nil,    -- Alvo atual
    cachedFocus    = nil,    -- Alvo em cache (FOV)
    activeTab      = "combat"
}

local SafeModeBackup = {
    active    = false,
    visualsOn = true,
    perfOn    = false,
    uiVisible = false,
}

-- Configurações ajustáveis
local Config = {
    maxRange      = 600,
    detectionSize = 90,
    trackSmooth   = 0.25,
    -- humanização
    smoothJitter  = 0.02,  -- variação na suavidade
    aimOffset     = 0.5,   -- offset aleatório (studs)
}

-- Performance
local PerfMode = {
    enabled       = false,
    updateSlow    = 0.25,
    updateNormal  = 0.10,
}

-- Paleta visual
local Theme = {
    navy      = Color3.fromRGB(10, 18, 32),
    deepNavy  = Color3.fromRGB(14, 24, 40),
    gold      = Color3.fromRGB(212, 175, 55),
    cream     = Color3.fromRGB(240, 236, 228),
    slate     = Color3.fromRGB(120, 130, 150),
    accent    = Color3.fromRGB(139, 166, 199),
    danger    = Color3.fromRGB(220, 80, 80),
    success   = Color3.fromRGB(46, 204, 113),
}

local VisualOpts = {
    outline   = true,
    dataLayer = true,
    healthVis = true,
    pathLines = false,
}

--======== UTILITÁRIOS ========
local function KeyCodeToString(code)
    if not code then return "None" end
    return tostring(code):gsub("Enum%.KeyCode%.", "")
end

local function Notify(text, dur)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title    = "Maia Z",
            Text     = text,
            Duration = dur or 2
        })
    end)
end

--======== CÍRCULO DE DETECÇÃO (FOV) ========
local detectionCircle = Drawing.new("Circle")
detectionCircle.Visible    = true
detectionCircle.Radius     = Config.detectionSize
detectionCircle.Color      = Theme.gold
detectionCircle.Thickness  = 2
detectionCircle.Transparency = 0.7
detectionCircle.Filled     = false
detectionCircle.NumSides   = 64

local innerCircle = Drawing.new("Circle")
innerCircle.Visible     = false
innerCircle.Radius      = Config.detectionSize - 10
innerCircle.Color       = Theme.gold
innerCircle.Thickness   = 1
innerCircle.Transparency= 0.5
innerCircle.Filled      = false
innerCircle.NumSides    = 64

-- PROTEÇÃO: recria círculos se forem removidos
local function EnsureCircles()
    if not detectionCircle or not detectionCircle.Visible then
        detectionCircle = Drawing.new("Circle")
        detectionCircle.Visible    = true
        detectionCircle.Radius     = Config.detectionSize
        detectionCircle.Color      = Theme.gold
        detectionCircle.Thickness  = 2
        detectionCircle.Transparency = 0.7
        detectionCircle.Filled     = false
        detectionCircle.NumSides   = 64
    end
    
    if not innerCircle or not innerCircle.Visible then
        innerCircle = Drawing.new("Circle")
        innerCircle.Visible     = false
        innerCircle.Radius      = Config.detectionSize - 10
        innerCircle.Color       = Theme.gold
        innerCircle.Thickness   = 1
        innerCircle.Transparency= 0.5
        innerCircle.Filled      = false
        innerCircle.NumSides    = 64
    end
end

local function GetCursorPos()
    local loc = UserInputService:GetMouseLocation()
    return Vector2.new(loc.X, loc.Y)
end

local function UpdateDetectionVisual()
    if Controller.safeMode then
        detectionCircle.Visible = false
        innerCircle.Visible = false
        return
    end

    EnsureCircles()

    local cursorPos = GetCursorPos()
    detectionCircle.Visible  = true
    detectionCircle.Position = cursorPos
    detectionCircle.Radius   = Config.detectionSize
    innerCircle.Position     = cursorPos

    if Controller.cachedFocus then
        detectionCircle.Color = Theme.gold
        innerCircle.Visible   = true
    else
        detectionCircle.Color = Theme.accent
        innerCircle.Visible   = false
    end

    if Controller.active and Controller.currentFocus then
        local pulse = math.abs(math.sin(tick() * 3)) * 8
        innerCircle.Radius = Config.detectionSize - 10 + pulse
    else
        innerCircle.Radius = Config.detectionSize - 10
    end
end

--======== SISTEMA DE MIRA ========
local function GetTargetPart(character)
    if not character then return nil end

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

local function IsFriendly(player)
    if LocalPlayer.Team and player.Team then
        return LocalPlayer.Team == player.Team
    end
    return false
end

local function IsValidFocus(player)
    if not player or player == LocalPlayer then return false end

    local char = player.Character
    if not char then return false end

    local hum  = char:FindFirstChildOfClass("Humanoid")
    local part = GetTargetPart(char)

    if not hum or not part then return false end
    if hum.Health <= 0 then return false end

    if hum.Health == math.huge or hum.MaxHealth == math.huge
        or hum.Health > 1e6 or hum.MaxHealth > 1e6 then
        return false
    end

    if char:FindFirstChildOfClass("ForceField") then
        return false
    end

    local _, visible = Camera:WorldToViewportPoint(part.Position)
    if not visible then
        return false
    end

    return true
end

local function WorldToScreen(pos)
    local v3, onScreen = Camera:WorldToViewportPoint(pos)
    return Vector2.new(v3.X, v3.Y), onScreen
end

local function ScanForFocus()
    if Controller.safeMode then return nil end

    local nearest = nil
    local nearestDist = math.huge

    local cursorPos = GetCursorPos()
    local camPos    = Camera.CFrame.Position

    for _, player in ipairs(Players:GetPlayers()) do
        if not IsFriendly(player) and IsValidFocus(player) then
            local char = player.Character
            local part = GetTargetPart(char)
            if part then
                local distance3D = (part.Position - camPos).Magnitude
                if distance3D <= Config.maxRange then
                    local screenPos, visible = WorldToScreen(part.Position)
                    if visible then
                        local screenDist = (screenPos - cursorPos).Magnitude
                        if screenDist <= Config.detectionSize and screenDist < nearestDist then
                            nearestDist = screenDist
                            nearest     = player
                        end
                    end
                end
            end
        end
    end

    return nearest
end

-- HUMANIZAÇÃO: adiciona variação suave e offset aleatório
local function TrackFocus()
    if Controller.safeMode or not Controller.active then
        return
    end

    if Controller.currentFocus and IsValidFocus(Controller.currentFocus) then
        local char = Controller.currentFocus.Character
        local part = GetTargetPart(char)
        if not part then
            Controller.currentFocus = nil
            return
        end

        -- Offset aleatório para parecer humano
        local randomOffset = Vector3.new(
            (math.random() - 0.5) * Config.aimOffset,
            (math.random() - 0.5) * Config.aimOffset,
            (math.random() - 0.5) * Config.aimOffset
        )
        
        local targetPos = part.Position + randomOffset
        local targetCFrame = CFrame.new(Camera.CFrame.Position, targetPos)

        -- Variação na suavidade
        local smoothVariation = Config.trackSmooth + (math.random() - 0.5) * Config.smoothJitter
        smoothVariation = math.clamp(smoothVariation, 0.05, 0.5)

        Camera.CFrame = Camera.CFrame:Lerp(targetCFrame, smoothVariation)
        return
    end

    Controller.currentFocus = ScanForFocus()
end

--======== SISTEMA VISUAL (ESP) ========
local function GetOrCreateOutline(char)
    local outline = char:FindFirstChild("mz_outline")
    if not outline then
        outline = Instance.new("Highlight")
        outline.Name = "mz_outline"
        outline.FillTransparency = 0.7
        outline.OutlineTransparency = 0
        outline.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        outline.Parent = char
    end
    return outline
end

local pathLines = {}

local function GetOrCreatePathLine(player)
    if pathLines[player] and pathLines[player].__OBJ then
        return pathLines[player].__OBJ
    end

    local line = Drawing.new("Line")
    line.Visible = false
    line.Thickness = 1.5
    line.Transparency = 0.8

    pathLines[player] = {__OBJ = line}
    return line
end

local function RemovePathLine(player)
    local data = pathLines[player]
    if data and data.__OBJ then
        pcall(function()
            data.__OBJ:Remove()
        end)
    end
    pathLines[player] = nil
end

local function ClearAllVisuals()
    for _, player in ipairs(Players:GetPlayers()) do
        local char = player.Character
        if char then
            local outline = char:FindFirstChild("mz_outline")
            if outline then outline:Destroy() end

            for _, obj in ipairs(char:GetDescendants()) do
                if obj:IsA("BillboardGui") and obj.Name == "mz_data" then
                    obj:Destroy()
                end
            end
        end
        RemovePathLine(player)
    end
end

local function UpdatePlayerVisuals(player)
    if not Controller.visualsOn or Controller.safeMode then
        RemovePathLine(player)
        local char = player.Character
        if char then
            local outline = char:FindFirstChild("mz_outline")
            if outline then outline.Enabled = false end

            local part = GetTargetPart(char)
            if part then
                local billboard = part:FindFirstChild("mz_data")
                if billboard then billboard.Enabled = false end
            end
        end
        return
    end

    local char = player.Character
    if not char then
        RemovePathLine(player)
        return
    end

    local part = GetTargetPart(char)
    local outline = char:FindFirstChild("mz_outline")
    local billboard

    if part then
        billboard = part:FindFirstChild("mz_data")
    end

    if not IsValidFocus(player) or IsFriendly(player) then
        if outline then outline.Enabled = false end
        if billboard then billboard.Enabled = false end
        RemovePathLine(player)
        return
    end

    -- Outline
    if VisualOpts.outline then
        outline = GetOrCreateOutline(char)
        if player == Controller.currentFocus then
            outline.FillColor    = Theme.gold
            outline.OutlineColor = Theme.gold
        else
            outline.FillColor    = Theme.accent
            outline.OutlineColor = Theme.accent
        end
        outline.Enabled = true
    elseif outline then
        outline.Enabled = false
    end

    -- Billboard de informações
    if part and VisualOpts.dataLayer then
        if not billboard then
            billboard = Instance.new("BillboardGui")
            billboard.Name = "mz_data"
            billboard.Size = UDim2.new(0, 110, 0, 40)
            billboard.StudsOffset = Vector3.new(0, 2, 0)
            billboard.AlwaysOnTop = true
            billboard.Parent = part

            local label = Instance.new("TextLabel")
            label.Name = "InfoText"
            label.Size = UDim2.new(1, 0, 0.5, 0)
            label.BackgroundTransparency = 1
            label.Font = Enum.Font.GothamMedium
            label.TextSize = 13
            label.TextStrokeTransparency = 0.5
            label.TextColor3 = Theme.cream
            label.TextXAlignment = Enum.TextXAlignment.Center
            label.Parent = billboard

            local hpBg = Instance.new("Frame")
            hpBg.Name = "HealthBG"
            hpBg.Size = UDim2.new(1, -14, 0, 6)
            hpBg.Position = UDim2.new(0, 7, 1, -8)
            hpBg.BackgroundColor3 = Theme.deepNavy
            hpBg.BorderSizePixel = 0
            hpBg.Parent = billboard

            local hpBgCorner = Instance.new("UICorner")
            hpBgCorner.CornerRadius = UDim.new(0, 3)
            hpBgCorner.Parent = hpBg

            local hpBar = Instance.new("Frame")
            hpBar.Name = "HealthBar"
            hpBar.Size = UDim2.new(1, 0, 1, 0)
            hpBar.BackgroundColor3 = Theme.gold
            hpBar.BorderSizePixel = 0
            hpBar.Parent = hpBg

            local hpBarCorner = Instance.new("UICorner")
            hpBarCorner.CornerRadius = UDim.new(0, 3)
            hpBarCorner.Parent = hpBar
        end

        billboard.Enabled = true

        local hum = char:FindFirstChildOfClass("Humanoid")
        local hp = hum and hum.Health or 0
        local maxHp = hum and hum.MaxHealth or 100
        local distance = math.floor((part.Position - Camera.CFrame.Position).Magnitude)

        local infoLabel = billboard:FindFirstChild("InfoText")
        local healthBG = billboard:FindFirstChild("HealthBG")
        local healthBar = healthBG and healthBG:FindFirstChild("HealthBar")

        if infoLabel then
            infoLabel.Text = string.format("%s\n%dm | %dHP", player.Name, distance, math.floor(hp))
            infoLabel.TextColor3 = player == Controller.currentFocus and Theme.gold or Theme.cream
        end

        if VisualOpts.healthVis and healthBG and healthBar and maxHp > 0 then
            local ratio = math.clamp(hp / maxHp, 0, 1)
            healthBar.Size = UDim2.new(ratio, 0, 1, 0)

            if ratio > 0.6 then
                healthBar.BackgroundColor3 = Theme.success
            elseif ratio > 0.3 then
                healthBar.BackgroundColor3 = Color3.fromRGB(241, 196, 15)
            else
                healthBar.BackgroundColor3 = Color3.fromRGB(231, 76, 60)
            end
        end
    elseif billboard then
        billboard.Enabled = false
    end

    -- Path lines (tracers)
    local lineObj = pathLines[player] and pathLines[player].__OBJ or nil
    if VisualOpts.pathLines and part then
        local line = lineObj or GetOrCreatePathLine(player)
        local screenPos, visible = WorldToScreen(part.Position)
        if visible then
            local viewportSize = Camera.ViewportSize
            local origin = Vector2.new(viewportSize.X / 2, viewportSize.Y)
            line.From = origin
            line.To = screenPos
            line.Color = player == Controller.currentFocus and Theme.gold or Theme.accent
            line.Visible = true
        else
            line.Visible = false
        end
    elseif lineObj then
        lineObj.Visible = false
    end
end

local function RefreshAllVisuals()
    if Controller.safeMode then return end
    ClearAllVisuals()
    if Controller.visualsOn then
        local maxPerCycle = PerfMode.enabled and 12 or math.huge
        local count = 0
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer then
                UpdatePlayerVisuals(player)
                count = count + 1
                if count >= maxPerCycle then break end
            end
        end
    end
end

local function ForceVisualRefresh()
    if Controller.safeMode then return end
    ClearAllVisuals()
    if Controller.visualsOn then
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer then
                UpdatePlayerVisuals(player)
            end
        end
    end
end

Players.PlayerAdded:Connect(function(player)
    player.CharacterAdded:Connect(function()
        task.wait(0.5)
        if Controller.visualsOn and not Controller.safeMode then
            UpdatePlayerVisuals(player)
        end
    end)
end)

Players.PlayerRemoving:Connect(function(player)
    if player == Controller.currentFocus then
        Controller.currentFocus = nil
        Controller.active = false
    end
    RemovePathLine(player)
end)

--======== MODO PERFORMANCE ========
local function TogglePerformanceMode(enable)
    PerfMode.enabled = enable

    for _, obj in ipairs(Lighting:GetChildren()) do
        if obj:IsA("BloomEffect")
        or obj:IsA("DepthOfFieldEffect")
        or obj:IsA("ColorCorrectionEffect") then
            obj.Enabled = not enable
        end
    end

    for _, inst in ipairs(Workspace:GetDescendants()) do
        if inst:IsA("ParticleEmitter") or inst:IsA("Trail") then
            inst.Enabled = not enable
        end
    end

    if not Controller.safeMode then
        Notify(enable and "Modo 0 LAG ativado" or "Modo 0 LAG desativado", 2)
    end
end

--======== BOTÃO DO PÂNICO ========
local UIRoot

local function ActivateSafeMode()
    Controller.safeMode = not Controller.safeMode

    if Controller.safeMode then
        SafeModeBackup.active    = Controller.active
        SafeModeBackup.visualsOn = Controller.visualsOn
        SafeModeBackup.perfOn    = PerfMode.enabled
        SafeModeBackup.uiVisible = Controller.uiVisible

        Controller.active    = false
        Controller.visualsOn = false
        Controller.uiVisible = false

        if PerfMode.enabled then
            TogglePerformanceMode(false)
        end

        ClearAllVisuals()
        detectionCircle.Visible = false
        innerCircle.Visible = false

        if UIRoot then
            UIRoot.Enabled = false
        end

        Notify("Modo Seguro ATIVO", 2)
    else
        Controller.active    = false
        Controller.visualsOn = SafeModeBackup.visualsOn

        if SafeModeBackup.perfOn then
            TogglePerformanceMode(true)
        end

        Controller.uiVisible = SafeModeBackup.uiVisible

        detectionCircle.Visible = true
        innerCircle.Visible = false

        if UIRoot then
            UIRoot.Enabled = Controller.uiVisible
        end

        ForceVisualRefresh()
        Notify("Modo Seguro DESATIVADO", 2)
    end
end

--======== INTERFACE (UI) ========
local MainContainer
local TabContent
local TabRegistry = {}
local sessionStart = tick()

local KeybindCapture = {
    active = false,
    target = nil,
    label  = nil,
}

local function StartKeyCapture(targetName, labelRef)
    if KeybindCapture.active then return end

    KeybindCapture.active = true
    KeybindCapture.target = targetName
    KeybindCapture.label  = labelRef

    if labelRef then
        labelRef.Text = "Aguardando tecla..."
    end

    Notify("Pressione nova tecla para " .. targetName, 3)
end

local function FinishKeyCapture(keyCode)
    if not KeybindCapture.active or not keyCode then
        KeybindCapture.active = false
        KeybindCapture.target = nil
        KeybindCapture.label  = nil
        return
    end

    if not tostring(keyCode):find("Enum.KeyCode.") then
        return
    end

    if KeybindCapture.target == "aim" then
        AimKey = keyCode
    elseif KeybindCapture.target == "esp" then
        EspKey = keyCode
    elseif KeybindCapture.target == "menu" then
        MenuKey = keyCode
    elseif KeybindCapture.target == "panic" then
        PanicKey = keyCode
    end

    if KeybindCapture.label then
        KeybindCapture.label.Text = "Tecla: " .. KeyCodeToString(keyCode)
    end

    Notify("Tecla atualizada: " .. KeyCodeToString(keyCode), 2)

    KeybindCapture.active = false
    KeybindCapture.target = nil
    KeybindCapture.label  = nil
end

local function CreateConfigSlider(parent, title, desc, yOffset, minVal, maxVal, defaultVal, onchange)
    local container = Instance.new("Frame")
    container.Size = UDim2.new(1, -40, 0, 70)
    container.Position = UDim2.new(0, 20, 0, yOffset)
    container.BackgroundTransparency = 1
    container.Parent = parent

    local titleLabel = Instance.new("TextLabel")
    titleLabel.Size = UDim2.new(0.6, 0, 0, 20)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Font = Enum.Font.GothamBold
    titleLabel.TextSize = 15
    titleLabel.TextColor3 = Theme.cream
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    titleLabel.Text = title
    titleLabel.Parent = container

    local valueLabel = Instance.new("TextLabel")
    valueLabel.Size = UDim2.new(0.4, 0, 0, 20)
    valueLabel.Position = UDim2.new(0.6, 0, 0, 0)
    valueLabel.BackgroundTransparency = 1
    valueLabel.Font = Enum.Font.Gotham
    valueLabel.TextSize = 13
    valueLabel.TextColor3 = Theme.gold
    valueLabel.TextXAlignment = Enum.TextXAlignment.Right
    valueLabel.Text = tostring(defaultVal)
    valueLabel.Parent = container

    local descLabel = Instance.new("TextLabel")
    descLabel.Size = UDim2.new(1, 0, 0, 24)
    descLabel.Position = UDim2.new(0, 0, 0, 22)
    descLabel.BackgroundTransparency = 1
    descLabel.Font = Enum.Font.Gotham
    descLabel.TextSize = 12
    descLabel.TextColor3 = Theme.slate
    descLabel.TextXAlignment = Enum.TextXAlignment.Left
    descLabel.TextWrapped = true
    descLabel.Text = desc
    descLabel.Parent = container

    local trackBg = Instance.new("Frame")
    trackBg.Size = UDim2.new(1, 0, 0, 4)
    trackBg.Position = UDim2.new(0, 0, 0, 52)
    trackBg.BackgroundColor3 = Theme.deepNavy
    trackBg.BackgroundTransparency = 0.15
    trackBg.BorderSizePixel = 0
    trackBg.Parent = container

    local trackCorner = Instance.new("UICorner")
    trackCorner.CornerRadius = UDim.new(0, 2)
    trackCorner.Parent = trackBg

    local trackFill = Instance.new("Frame")
    trackFill.Size = UDim2.new((defaultVal - minVal) / (maxVal - minVal), 0, 1, 0)
    trackFill.BackgroundColor3 = Theme.gold
    trackFill.BorderSizePixel = 0
    trackFill.Parent = trackBg

    local fillCorner = Instance.new("UICorner")
    fillCorner.CornerRadius = UDim.new(0, 2)
    fillCorner.Parent = trackFill

    local dragging = false

    local function updateValue(input)
        local ratio = math.clamp((input.Position.X - trackBg.AbsolutePosition.X) / trackBg.AbsoluteSize.X, 0, 1)
        local value = math.floor(minVal + (maxVal - minVal) * ratio)
        trackFill.Size = UDim2.new(ratio, 0, 1, 0)
        valueLabel.Text = tostring(value)
        onchange(value)
    end

    trackBg.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            updateValue(input)
        end
    end)

    trackBg.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = false
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            updateValue(input)
        end
    end)
end

local function CreateVisualToggle(parent, yOffset, labelText, optionKey)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, -40, 0, 38)
    btn.Position = UDim2.new(0, 20, 0, yOffset)
    btn.BackgroundColor3 = Theme.deepNavy
    btn.BackgroundTransparency = 0.15
    btn.BorderSizePixel = 0
    btn.AutoButtonColor = false
    btn.Font = Enum.Font.Gotham
    btn.TextSize = 14
    btn.TextXAlignment = Enum.TextXAlignment.Left
    btn.TextColor3 = Theme.cream
    btn.Text = "  " .. labelText
    btn.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = btn

    local iconBox = Instance.new("Frame")
    iconBox.Size = UDim2.new(0, 18, 0, 18)
    iconBox.Position = UDim2.new(0, 10, 0.5, -9)
    iconBox.BackgroundColor3 = Color3.fromRGB(5, 10, 20)
    iconBox.BorderSizePixel = 0
    iconBox.Parent = btn

    local iconCorner = Instance.new("UICorner")
    iconCorner.CornerRadius = UDim.new(0, 5)
    iconCorner.Parent = iconBox

    local indicator = Instance.new("Frame")
    indicator.Size = UDim2.new(0, 11, 0, 11)
    indicator.Position = UDim2.new(0.5, -5, 0.5, -5)
    indicator.BackgroundColor3 = VisualOpts[optionKey] and Theme.gold or Theme.slate
    indicator.BorderSizePixel = 0
    indicator.Parent = iconBox

    local indCorner = Instance.new("UICorner")
    indCorner.CornerRadius = UDim.new(1, 0)
    indCorner.Parent = indicator

    btn.MouseButton1Click:Connect(function()
        if Controller.safeMode then return end
        VisualOpts[optionKey] = not VisualOpts[optionKey]
        indicator.BackgroundColor3 = VisualOpts[optionKey] and Theme.gold or Theme.slate
        ForceVisualRefresh()
    end)
end

local function FormatUptime(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    return string.format("%02d:%02d:%02d", h, m, s)
end

local function SwitchToTab(tabName)
    Controller.activeTab = tabName

    for name, btn in pairs(TabRegistry) do
        if name == tabName then
            btn.TextColor3 = Theme.gold
            btn.BackgroundTransparency = 0.1
        else
            btn.TextColor3 = Theme.slate
            btn.BackgroundTransparency = 1
        end
    end

    for _, child in pairs(TabContent:GetChildren()) do
        child:Destroy()
    end

    if tabName == "combat" then
        local header = Instance.new("TextLabel")
        header.Size = UDim2.new(1, -40, 0, 24)
        header.Position = UDim2.new(0, 20, 0, 10)
        header.BackgroundTransparency = 1
        header.Font = Enum.Font.GothamBold
        header.TextSize = 18
        header.TextColor3 = Theme.cream
        header.TextXAlignment = Enum.TextXAlignment.Left
        header.Text = "Combat Control"
        header.Parent = TabContent

        CreateConfigSlider(TabContent, "FOV", "Área de detecção", 50, 50, 220, Config.detectionSize, function(v)
            Config.detectionSize = v
        end)

        CreateConfigSlider(TabContent, "Smooth", "Suavidade (maior = mais rápido)", 130, 5, 60, Config.trackSmooth * 100, function(v)
            Config.trackSmooth = v / 100
        end)

        CreateConfigSlider(TabContent, "Distância", "Alcance máximo", 210, 150, 1200, Config.maxRange, function(v)
            Config.maxRange = v
        end)

        local statusBox = Instance.new("TextLabel")
        statusBox.Name = "StatusDisplay"
        statusBox.Size = UDim2.new(1, -40, 0, 40)
        statusBox.Position = UDim2.new(0, 20, 0, 290)
        statusBox.BackgroundColor3 = Theme.deepNavy
        statusBox.BackgroundTransparency = 0.25
        statusBox.BorderSizePixel = 0
        statusBox.Font = Enum.Font.Gotham
        statusBox.TextSize = 13
        statusBox.TextColor3 = Theme.accent
        statusBox.TextXAlignment = Enum.TextXAlignment.Center
        statusBox.Text = "Idle - Sem alvo"
        statusBox.Parent = TabContent

        local statusCorner = Instance.new("UICorner")
        statusCorner.CornerRadius = UDim.new(0, 6)
        statusCorner.Parent = statusBox

    elseif tabName == "visual" then
        local header = Instance.new("TextLabel")
        header.Size = UDim2.new(1, -40, 0, 24)
        header.Position = UDim2.new(0, 20, 0, 10)
        header.BackgroundTransparency = 1
        header.Font = Enum.Font.GothamBold
        header.TextSize = 18
        header.TextColor3 = Theme.cream
        header.TextXAlignment = Enum.TextXAlignment.Left
        header.Text = "Visual Layer"
        header.Parent = TabContent

        CreateVisualToggle(TabContent, 50, "Outline (contorno)", "outline")
        CreateVisualToggle(TabContent, 92, "Dados (nome/HP/dist)", "dataLayer")
        CreateVisualToggle(TabContent, 134, "Healthbar", "healthVis")
        CreateVisualToggle(TabContent, 176, "Path Lines", "pathLines")

        local espMainBtn = Instance.new("TextButton")
        espMainBtn.Name = "ESPMaster"
        espMainBtn.Size = UDim2.new(1, -40, 0, 40)
        espMainBtn.Position = UDim2.new(0, 20, 0, 246)
        espMainBtn.BackgroundColor3 = Controller.visualsOn and Theme.gold or Theme.slate
        espMainBtn.BorderSizePixel = 0
        espMainBtn.Font = Enum.Font.GothamBold
        espMainBtn.TextSize = 14
        espMainBtn.TextColor3 = Controller.visualsOn and Theme.navy or Theme.cream
        espMainBtn.Text = Controller.visualsOn and "ESP ATIVO" or "ESP DESATIVADO"
        espMainBtn.Parent = TabContent

        local espCorner = Instance.new("UICorner")
        espCorner.CornerRadius = UDim.new(0, 8)
        espCorner.Parent = espMainBtn

        espMainBtn.MouseButton1Click:Connect(function()
            if Controller.safeMode then return end
            Controller.visualsOn = not Controller.visualsOn
            espMainBtn.BackgroundColor3 = Controller.visualsOn and Theme.gold or Theme.slate
            espMainBtn.TextColor3 = Controller.visualsOn and Theme.navy or Theme.cream
            espMainBtn.Text = Controller.visualsOn and "ESP ATIVO" or "ESP DESATIVADO"
            Notify(Controller.visualsOn and "ESP ativado" or "ESP desativado", 2)
            ForceVisualRefresh()
        end)

    elseif tabName == "performance" then
        local header = Instance.new("TextLabel")
        header.Size = UDim2.new(1, -40, 0, 24)
        header.Position = UDim2.new(0, 20, 0, 10)
        header.BackgroundTransparency = 1
        header.Font = Enum.Font.GothamBold
        header.TextSize = 18
        header.TextColor3 = Theme.cream
        header.TextXAlignment = Enum.TextXAlignment.Left
        header.Text = "Performance"
        header.Parent = TabContent

        local warning = Instance.new("TextLabel")
        warning.Size = UDim2.new(1, -40, 0, 36)
        warning.Position = UDim2.new(0, 20, 0, 40)
        warning.BackgroundTransparency = 1
        warning.Font = Enum.Font.Gotham
        warning.TextSize = 13
        warning.TextColor3 = Theme.slate
        warning.TextXAlignment = Enum.TextXAlignment.Left
        warning.TextYAlignment = Enum.TextYAlignment.Top
        warning.TextWrapped = true
        warning.Text = "Modo 0 LAG - Experimental"
        warning.Parent = TabContent

        local perfBtn = Instance.new("TextButton")
        perfBtn.Name = "PerfToggle"
        perfBtn.Size = UDim2.new(1, -40, 0, 44)
        perfBtn.Position = UDim2.new(0, 20, 0, 90)
        perfBtn.BackgroundColor3 = PerfMode.enabled and Theme.success or Theme.danger
        perfBtn.BorderSizePixel = 0
        perfBtn.Font = Enum.Font.GothamBold
        perfBtn.TextSize = 14
        perfBtn.TextColor3 = Theme.cream
        perfBtn.Text = PerfMode.enabled and "0 LAG: ATIVO" or "0 LAG: DESATIVADO"
        perfBtn.Parent = TabContent

        local perfCorner = Instance.new("UICorner")
        perfCorner.CornerRadius = UDim.new(0, 8)
        perfCorner.Parent = perfBtn

        perfBtn.MouseButton1Click:Connect(function()
            if Controller.safeMode then return end
            TogglePerformanceMode(not PerfMode.enabled)
            perfBtn.BackgroundColor3 = PerfMode.enabled and Theme.success or Theme.danger
            perfBtn.Text = PerfMode.enabled and "0 LAG: ATIVO" or "0 LAG: DESATIVADO"
        end)

    elseif tabName == "config" then
        local header = Instance.new("TextLabel")
        header.Size = UDim2.new(1, -40, 0, 24)
        header.Position = UDim2.new(0, 20, 0, 10)
        header.BackgroundTransparency = 1
        header.Font = Enum.Font.GothamBold
        header.TextSize = 18
        header.TextColor3 = Theme.cream
        header.TextXAlignment = Enum.TextXAlignment.Left
        header.Text = "Keybinds & Panic"
        header.Parent = TabContent

        local function CreateKeybindEntry(yPos, labelText, getKeyFunc, targetName)
            local row = Instance.new("Frame")
            row.Size = UDim2.new(1, -40, 0, 30)
            row.Position = UDim2.new(0, 20, 0, yPos)
            row.BackgroundTransparency = 1
            row.Parent = TabContent

            local label = Instance.new("TextLabel")
            label.Size = UDim2.new(0.6, 0, 1, 0)
            label.BackgroundTransparency = 1
            label.Font = Enum.Font.Gotham
            label.TextSize = 14
            label.TextColor3 = Theme.cream
            label.TextXAlignment = Enum.TextXAlignment.Left
            label.Text = labelText
            label.Parent = row

            local keyBtn = Instance.new("TextButton")
            keyBtn.Size = UDim2.new(0.4, -10, 1, 0)
            keyBtn.Position = UDim2.new(0.6, 10, 0, 0)
            keyBtn.BackgroundColor3 = Theme.deepNavy
            keyBtn.BackgroundTransparency = 0.15
            keyBtn.BorderSizePixel = 0
            keyBtn.Font = Enum.Font.Gotham
            keyBtn.TextSize = 13
            keyBtn.TextColor3 = Theme.gold
            keyBtn.Text = "Tecla: " .. KeyCodeToString(getKeyFunc())
            keyBtn.Parent = row

            local keyCorner = Instance.new("UICorner")
            keyCorner.CornerRadius = UDim.new(0, 6)
            keyCorner.Parent = keyBtn

            keyBtn.MouseButton1Click:Connect(function()
                if Controller.safeMode then return end
                StartKeyCapture(targetName, keyBtn)
            end)
        end

        CreateKeybindEntry(50, "Aimlock", function() return AimKey end, "aim")
        CreateKeybindEntry(90, "ESP", function() return EspKey end, "esp")
        CreateKeybindEntry(130, "Menu", function() return MenuKey end, "menu")
        CreateKeybindEntry(170, "Panic", function() return PanicKey end, "panic")

        local info = Instance.new("TextLabel")
        info.Size = UDim2.new(1, -40, 0, 60)
        info.Position = UDim2.new(0, 20, 0, 210)
        info.BackgroundTransparency = 1
        info.Font = Enum.Font.Gotham
        info.TextSize = 12
        info.TextColor3 = Theme.slate
        info.TextXAlignment = Enum.TextXAlignment.Left
        info.TextYAlignment = Enum.TextYAlignment.Top
        info.TextWrapped = true
        info.Text = "Panic: desativa tudo temporariamente. Pressione novamente para restaurar."
        info.Parent = TabContent

        local panicBtn = Instance.new("TextButton")
        panicBtn.Size = UDim2.new(1, -40, 0, 40)
        panicBtn.Position = UDim2.new(0, 20, 0, 280)
        panicBtn.BackgroundColor3 = Controller.safeMode and Theme.danger or Theme.deepNavy
        panicBtn.BorderSizePixel = 0
        panicBtn.Font = Enum.Font.GothamBold
        panicBtn.TextSize = 14
        panicBtn.TextColor3 = Theme.cream
        panicBtn.Text = Controller.safeMode and "PANIC ATIVO" or "ATIVAR PANIC"
        panicBtn.Parent = TabContent

        local panicCorner = Instance.new("UICorner")
        panicCorner.CornerRadius = UDim.new(0, 8)
        panicCorner.Parent = panicBtn

        panicBtn.MouseButton1Click:Connect(function()
            ActivateSafeMode()
            panicBtn.BackgroundColor3 = Controller.safeMode and Theme.danger or Theme.deepNavy
            panicBtn.Text = Controller.safeMode and "PANIC ATIVO" or "ATIVAR PANIC"
        end)

    elseif tabName == "info" then
        local header = Instance.new("TextLabel")
        header.Size = UDim2.new(1, -40, 0, 24)
        header.Position = UDim2.new(0, 20, 0, 10)
        header.BackgroundTransparency = 1
        header.Font = Enum.Font.GothamBold
        header.TextSize = 18
        header.TextColor3 = Theme.cream
        header.TextXAlignment = Enum.TextXAlignment.Left
        header.Text = "Session Info"
        header.Parent = TabContent

        local sessionBox = Instance.new("TextLabel")
        sessionBox.Name = "SessionData"
        sessionBox.Size = UDim2.new(1, -40, 0, 80)
        sessionBox.Position = UDim2.new(0, 20, 0, 50)
        sessionBox.BackgroundColor3 = Theme.deepNavy
        sessionBox.BackgroundTransparency = 0.2
        sessionBox.BorderSizePixel = 0
        sessionBox.Font = Enum.Font.Gotham
        sessionBox.TextSize = 13
        sessionBox.TextColor3 = Theme.accent
        sessionBox.TextXAlignment = Enum.TextXAlignment.Left
        sessionBox.TextYAlignment = Enum.TextYAlignment.Top
        sessionBox.Text = "Carregando..."
        sessionBox.Parent = TabContent

        local infoCorner = Instance.new("UICorner")
        infoCorner.CornerRadius = UDim.new(0, 8)
        infoCorner.Parent = sessionBox
    end
end

local function BuildInterface()
    UIRoot = Instance.new("ScreenGui")
    UIRoot.Name = "MaiaZ_Interface"
    UIRoot.ResetOnSpawn = false
    UIRoot.Enabled = false
    UIRoot.Parent = LocalPlayer:WaitForChild("PlayerGui")

    MainContainer = Instance.new("Frame")
    MainContainer.Name = "Container"
    MainContainer.Size = UDim2.new(0, 520, 0, 360)
    MainContainer.Position = UDim2.new(0.5, -260, 0.5, -180)
    MainContainer.BackgroundColor3 = Theme.navy
    MainContainer.BackgroundTransparency = 0.1
    MainContainer.BorderSizePixel = 0
    MainContainer.Parent = UIRoot

    local mainCorner = Instance.new("UICorner")
    mainCorner.CornerRadius = UDim.new(0, 6)
    mainCorner.Parent = MainContainer

    local mainStroke = Instance.new("UIStroke")
    mainStroke.Thickness = 1
    mainStroke.Color = Theme.gold
    mainStroke.Transparency = 0.5
    mainStroke.Parent = MainContainer

    local topBar = Instance.new("Frame")
    topBar.Name = "TopBar"
    topBar.Size = UDim2.new(1, 0, 0, 46)
    topBar.BackgroundColor3 = Theme.deepNavy
    topBar.BorderSizePixel = 0
    topBar.Parent = MainContainer

    local topLine = Instance.new("Frame")
    topLine.Size = UDim2.new(1, 0, 0, 1)
    topLine.Position = UDim2.new(0, 0, 1, -1)
    topLine.BackgroundColor3 = Theme.gold
    topLine.BorderSizePixel = 0
    topLine.Parent = topBar

    local appTitle = Instance.new("TextLabel")
    appTitle.Size = UDim2.new(0, 200, 1, 0)
    appTitle.Position = UDim2.new(0, 18, 0, 0)
    appTitle.BackgroundTransparency = 1
    appTitle.Font = Enum.Font.GothamBold
    appTitle.TextSize = 18
    appTitle.TextColor3 = Theme.cream
    appTitle.TextXAlignment = Enum.TextXAlignment.Left
    appTitle.Text = "Maia Z"
    appTitle.Parent = topBar

    local appSubtitle = Instance.new("TextLabel")
    appSubtitle.Size = UDim2.new(0, 220, 1, -20)
    appSubtitle.Position = UDim2.new(0, 18, 0, 20)
    appSubtitle.BackgroundTransparency = 1
    appSubtitle.Font = Enum.Font.Gotham
    appSubtitle.TextSize = 12
    appSubtitle.TextColor3 = Theme.slate
    appSubtitle.TextXAlignment = Enum.TextXAlignment.Left
    appSubtitle.Text = "Sistema Executivo"
    appSubtitle.Parent = topBar

    local badge = Instance.new("TextLabel")
    badge.Size = UDim2.new(0, 110, 0, 20)
    badge.Position = UDim2.new(1, -120, 0.5, -10)
    badge.BackgroundColor3 = Theme.gold
    badge.BorderSizePixel = 0
    badge.Font = Enum.Font.GothamBold
    badge.TextSize = 11
    badge.TextColor3 = Theme.navy
    badge.Text = "PRIVATE BUILD"
    badge.Parent = topBar

    local badgeCorner = Instance.new("UICorner")
    badgeCorner.CornerRadius = UDim.new(0, 10)
    badgeCorner.Parent = badge

    -- Drag funcional CORRIGIDO
    do
        local dragging = false
        local dragStart
        local startPos

        topBar.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging = true
                dragStart = UserInputService:GetMouseLocation()
                startPos = MainContainer.Position
            end
        end)

        topBar.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging = false
            end
        end)

        UserInputService.InputChanged:Connect(function(input)
            if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
                local currentPos = UserInputService:GetMouseLocation()
                local delta = currentPos - dragStart
                MainContainer.Position = UDim2.new(
                    startPos.X.Scale,
                    startPos.X.Offset + delta.X,
                    startPos.Y.Scale,
                    startPos.Y.Offset + delta.Y
                )
            end
        end)
    end

    local navBar = Instance.new("Frame")
    navBar.Size = UDim2.new(0, 130, 1, -46)
    navBar.Position = UDim2.new(0, 0, 0, 46)
    navBar.BackgroundColor3 = Theme.navy
    navBar.BackgroundTransparency = 0.1
    navBar.BorderSizePixel = 0
    navBar.Parent = MainContainer

    local navLayout = Instance.new("UIListLayout")
    navLayout.FillDirection = Enum.FillDirection.Vertical
    navLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    navLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    navLayout.Padding = UDim.new(0, 4)
    navLayout.Parent = navBar

    local function CreateNavButton(tabID, displayName, iconText)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, 0, 0, 32)
        btn.BackgroundTransparency = 1
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Font = Enum.Font.Gotham
        btn.TextSize = 13
        btn.TextColor3 = Theme.slate
        btn.TextXAlignment = Enum.TextXAlignment.Left
        btn.Text = "  " .. displayName
        btn.Parent = navBar

        local icon = Instance.new("TextLabel")
        icon.Size = UDim2.new(0, 18, 0, 18)
        icon.Position = UDim2.new(0, 10, 0.5, -9)
        icon.BackgroundColor3 = Theme.deepNavy
        icon.BorderSizePixel = 0
        icon.Font = Enum.Font.GothamBold
        icon.TextSize = 11
        icon.TextColor3 = Theme.slate
        icon.Text = iconText
        icon.Parent = btn

        local iconCorner = Instance.new("UICorner")
        iconCorner.CornerRadius = UDim.new(0, 4)
        iconCorner.Parent = icon

        TabRegistry[tabID] = btn

        btn.MouseButton1Click:Connect(function()
            if Controller.safeMode and tabID ~= "config" then return end
            SwitchToTab(tabID)
        end)
    end

    CreateNavButton("combat", "Combat", "C")
    CreateNavButton("visual", "Visual", "V")
    CreateNavButton("performance", "Perf", "P")
    CreateNavButton("config", "Config", "K")
    CreateNavButton("info", "Session", "S")

    TabContent = Instance.new("Frame")
    TabContent.Name = "TabContent"
    TabContent.Size = UDim2.new(1, -130, 1, -46)
    TabContent.Position = UDim2.new(0, 130, 0, 46)
    TabContent.BackgroundColor3 = Theme.deepNavy
    TabContent.BackgroundTransparency = 0.15
    TabContent.BorderSizePixel = 0
    TabContent.Parent = MainContainer

    local contentCorner = Instance.new("UICorner")
    contentCorner.CornerRadius = UDim.new(0, 6)
    contentCorner.Parent = TabContent

    SwitchToTab("combat")
end

BuildInterface()

-- WATCHDOG: recria UI se for destruída
local function WatchdogCheck()
    if not UIRoot or not UIRoot.Parent then
        BuildInterface()
        UIRoot.Enabled = Controller.uiVisible and not Controller.safeMode
    end
end

local function ToggleInterface()
    if Controller.safeMode then return end
    Controller.uiVisible = not Controller.uiVisible
    if UIRoot then
        UIRoot.Enabled = Controller.uiVisible
    end
end

--======== LOOPS PRINCIPAIS ========
local lastFocusCheck = 0
local lastVisualUpdate = 0
local lastWatchdog = 0

RunService.Heartbeat:Connect(function()
    -- Watchdog leve (verifica a cada 2s)
    if tick() - lastWatchdog > 2 then
        WatchdogCheck()
        lastWatchdog = tick()
    end

    if Controller.safeMode then return end

    -- Atualiza status no combat tab
    if Controller.uiVisible and Controller.activeTab == "combat" then
        local statusDisplay = TabContent:FindFirstChild("StatusDisplay", true)
        if statusDisplay then
            local targetName = Controller.currentFocus and Controller.currentFocus.Name or "Sem alvo"
            local statusText = Controller.active and "Active" or "Idle"
            statusDisplay.Text = string.format("%s • %s", statusText, targetName)
            statusDisplay.TextColor3 = Controller.active and Theme.gold or Theme.accent
        end
    end

    -- Atualiza info na session tab
    if Controller.uiVisible and Controller.activeTab == "info" then
        local sessionData = TabContent:FindFirstChild("SessionData", true)
        if sessionData then
            local playerCount = #Players:GetPlayers()
            local uptime = FormatUptime(tick() - sessionStart)
            sessionData.Text = string.format("Jogadores: %d\nTempo ativo: %s", playerCount, uptime)
        end
    end
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end

    if KeybindCapture.active and input.UserInputType == Enum.UserInputType.Keyboard then
        FinishKeyCapture(input.KeyCode)
        return
    end

    if input.KeyCode == PanicKey then
        ActivateSafeMode()
        return
    end

    if Controller.safeMode then return end

    if input.KeyCode == AimKey then
        Controller.active = not Controller.active

        if Controller.active then
            Controller.currentFocus = ScanForFocus()
            if Controller.currentFocus then
                Notify("Travado: " .. Controller.currentFocus.Name, 2)
            else
                Notify("Nenhum alvo", 2)
                Controller.active = false
            end
        else
            Notify("Aimlock OFF", 2)
            Controller.currentFocus = nil
        end
    end

    if input.KeyCode == EspKey then
        Controller.visualsOn = not Controller.visualsOn
        Notify(Controller.visualsOn and "ESP ON" or "ESP OFF", 2)
        ForceVisualRefresh()
    end

    if input.KeyCode == MenuKey then
        ToggleInterface()
    end
end)

RunService.RenderStepped:Connect(function()
    UpdateDetectionVisual()

    if Controller.safeMode then return end

    if Controller.active then
        TrackFocus()
        if Controller.currentFocus and not IsValidFocus(Controller.currentFocus) then
            Controller.currentFocus = nil
        end
    end

    if tick() - lastFocusCheck > 0.05 then
        Controller.cachedFocus = Controller.visualsOn and ScanForFocus() or nil
        lastFocusCheck = tick()
    end

    local updateInterval = PerfMode.enabled and PerfMode.updateSlow or PerfMode.updateNormal
    if tick() - lastVisualUpdate > updateInterval then
        RefreshAllVisuals()
        lastVisualUpdate = tick()
    end
end)

Notify("Maia Z iniciado - Pressione " .. KeyCodeToString(MenuKey), 3)
