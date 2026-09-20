-- Kronax Autoexec
-- Start : reclic toutes les 6 s tant que le bouton est visible; arret des
-- que le donjon a commence.
-- Retry : reclic toutes les 3 s tant que le bouton est visible; ne s'arrete
-- pas tant qu'on n'a pas retry.
-- Le farm n'est lance qu'apres Start (ou si un vrai combat est deja actif),
-- Apres son clic, le prochain Autoexec (nouvelle instance) reprend tout.
-- Le farm est telecharge automatiquement depuis GitHub s'il n'est pas deja
-- present en local.

if typeof(_G.StopKronaxAutoexec) == "function" then
    pcall(_G.StopKronaxAutoexec, "autoexec remplace")
    task.wait(0.1)
end

-- Une limite au chargement evite qu'une copie d'Autoexec demeure
-- suspendue pour toujours dans un DataModel.
if not game:IsLoaded() then
    local loadDeadline = os.clock() + 120
    repeat task.wait(0.25) until game:IsLoaded() or os.clock() >= loadDeadline
    if not game:IsLoaded() then
        warn("[Kronax Autoexec] chargement incomplet apres 120 s -> arret")
        return
    end
end

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")

local player = Players.LocalPlayer
local FARM_FILE = "library/farms/kronax_minigun.lua"
local FARM_URL = "https://raw.githubusercontent.com/rayzox-akpl/teste3/main/kronax_minigun.lua"
local INITIAL_SCAN_INTERVAL = 1.0       -- tick de la boucle tant que Start/Skip pas finis
local RETRY_SCAN_INTERVAL = 3.0         -- Retry reclique toutes les 3 s
local START_SEARCH_WINDOW = 200.0
local SKIP_SEARCH_WINDOW = 90.0
local START_CLICK_INTERVAL = 6.0        -- Start reclique toutes les 6 s
local SKIP_MAX_ATTEMPTS = 1

local running = true
local connections = {}
local loadedAt = os.clock()
local startFinished = false
local startClickedAt = nil
local skipFinished = false
local startAttempts = 0
local skipAttempts = 0
local retryPrepared = false
local nextRetryScan = loadedAt
local farmState = "idle"

local function connect(signal, callback)
    local connection = signal:Connect(callback)
    connections[#connections + 1] = connection
    return connection
end

local function guiVisible(object)
    if not object or not object:IsA("GuiObject") then return false end
    if object.AbsoluteSize.X <= 1 or object.AbsoluteSize.Y <= 1 then return false end
    local current = object
    while current do
        if current:IsA("GuiObject") and not current.Visible then return false end
        if current:IsA("LayerCollector") and not current.Enabled then return false end
        current = current.Parent
    end
    return true
end

local function normalizedText(object)
    if not object then return "" end
    local text = ""
    if object:IsA("TextButton") or object:IsA("TextLabel") then
        text = tostring(object.Text or "")
    end
    text = string.lower(text)
    text = string.gsub(text, "<.->", " ")
    text = string.gsub(text, "%s+", " ")
    return string.match(text, "^%s*(.-)%s*$") or ""
end

local function buttonText(button)
    local parts = {normalizedText(button)}
    for _, descendant in ipairs(button:GetDescendants()) do
        local text = normalizedText(descendant)
        if text ~= "" then parts[#parts + 1] = text end
    end
    return table.concat(parts, " ")
end

local function visibleButtonNamed(name)
    local playerGui = player:FindFirstChild("PlayerGui")
    if not playerGui then return nil end
    -- DungeonComplete peut contenir deux RetryBtn, dont un clone cache. On
    -- parcourt les correspondances au lieu d'abandonner sur le premier cache.
    for _, object in ipairs(playerGui:GetDescendants()) do
        if object.Name == name and object:IsA("GuiButton")
            and guiVisible(object) then
            return object
        end
    end
    return nil
end

local function visibleButtonAtPath(root, path)
    local current = root
    for _, name in ipairs(path) do
        current = current and current:FindFirstChild(name)
        if not current then return nil end
    end
    if current:IsA("GuiButton") and guiVisible(current) then return current end
    return nil
end

local function visibleObjectAtPath(root, path)
    local current = root
    for _, name in ipairs(path) do
        current = current and current:FindFirstChild(name)
        if not current then return nil end
    end
    if current:IsA("GuiObject") and guiVisible(current) then return current end
    return nil
end

local function startButton()
    local playerGui = player:FindFirstChild("PlayerGui")
    local main = playerGui and playerGui:FindFirstChild("Main")
    local button = main and main:FindFirstChild("StartBtn")
    if button and button:IsA("GuiButton") and guiVisible(button) then
        return button
    end
    return nil
end

local function retryButton()
    local playerGui = player:FindFirstChild("PlayerGui")
    if not playerGui then return nil end

    -- Les deux emplacements observes sont testes sans parcourir toute l'UI.
    local button = visibleButtonAtPath(playerGui, {
        "DungeonComplete", "Main", "EndGameButtons", "RetryBtn",
    }) or visibleButtonAtPath(playerGui, {
        "DungeonComplete", "Main", "Frame", "RetryBtn",
    })
    if button then return button end

    -- Secours pour une variante d'interface. Ce scan ne peut arriver que
    -- toutes les 3 secondes.
    return visibleButtonNamed("RetryBtn")
end

local function skipButton()
    local playerGui = player:FindFirstChild("PlayerGui")
    if not playerGui then return nil end

    -- Chemin et nom exacts observes sur les cycles Kronax. Le texte du bouton
    -- peut arriver plus tard, donc il ne doit servir que de repli.
    local direct = playerGui:FindFirstChild("SkipCutscene", true)
    if direct and direct:IsA("GuiButton") and guiVisible(direct) then
        return direct
    end

    local skipNames = {
        SkipCutscene = true, SkipBtn = true, SkipButton = true, Skip = true,
    }
    local buttons = {}
    for _, object in ipairs(playerGui:GetDescendants()) do
        if object:IsA("GuiButton") and guiVisible(object) then
            if skipNames[object.Name] then return object end
            buttons[#buttons + 1] = object
        end
    end
    for _, button in ipairs(buttons) do
        local text = buttonText(button)
        if string.find(text, "skip", 1, true)
            or string.find(text, "passer la cinematique", 1, true)
            or text == "passer" then
            return button
        end
    end
    return nil
end

local function activeDungeonVisible()
    local playerGui = player:FindFirstChild("PlayerGui")
    return playerGui ~= nil and visibleObjectAtPath(playerGui, {
        "Main", "BossHealthBars", "DungeonTimer",
    }) ~= nil
end

local function activeKronaxBoss()
    local mobs = workspace:FindFirstChild("Mobs")
    if not mobs then return nil end
    for _, model in ipairs(mobs:GetDescendants()) do
        if model:IsA("Model")
            and string.find(string.lower(model.Name), "kronax", 1, true) then
            local humanoid = model:FindFirstChildOfClass("Humanoid")
            local dungeon = string.lower(tostring(model:GetAttribute("Dungeon") or ""))
            if humanoid and humanoid.Health > 0
                and (model:GetAttribute("Boss") == true
                    or model:GetAttribute("Base") == "TimeBoss"
                    or string.find(dungeon, "timeraid", 1, true)) then
                return model
            end
        end
    end
    return nil
end

local function clickButton(button, label)
    if not guiVisible(button) then return false end
    local position, size = button.AbsolutePosition, button.AbsoluteSize
    local inset = GuiService:GetGuiInset()
    local x = position.X + size.X / 2
    local y = position.Y + size.Y / 2 + inset.Y
    local ok = pcall(function()
        VirtualInputManager:SendMouseMoveEvent(x, y, game)
        task.wait(0.02)
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 0)
        task.wait(0.03)
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 0)
    end)
    if ok then
        print(("[Kronax Autoexec] clic %s envoye : %s")
            :format(label, button:GetFullName()))
    else
        warn("[Kronax Autoexec] impossible d'envoyer le clic " .. label)
    end
    return ok
end

local function stopFarm(reason)
    if typeof(_G.StopCurrentFarm) == "function" then
        pcall(_G.StopCurrentFarm, reason or "autoexec")
    end
end

-- Charge le farm : essaie d'abord le fichier local, sinon telecharge depuis
-- GitHub et l'ecrit sur le disque pour les prochaines executions.
local function fetchFarmSource()
    if typeof(readfile) == "function" and typeof(isfile) == "function"
        and isfile(FARM_FILE) then
        local source
        local readOk, readError = pcall(function()
            source = readfile(FARM_FILE)
        end)
        if readOk and type(source) == "string" and #source > 0 then
            return source, "local"
        end
        warn("[Kronax Autoexec] lecture locale echouee : " .. tostring(readError))
    end

    print("[Kronax Autoexec] telechargement du farm depuis GitHub...")
    local downloaded
    local httpOk, httpError = pcall(function()
        downloaded = game:HttpGet(FARM_URL)
    end)
    if not httpOk or type(downloaded) ~= "string" or #downloaded == 0 then
        warn("[Kronax Autoexec] telechargement impossible : " .. tostring(httpError))
        return nil
    end

    -- Installation locale pour les prochaines executions.
    if typeof(makefolder) == "function" then
        pcall(makefolder, "library")
        pcall(makefolder, "library/farms")
    end
    if typeof(writefile) == "function" then
        local writeOk, writeError = pcall(writefile, FARM_FILE, downloaded)
        if writeOk then
            print("[Kronax Autoexec] farm installe dans " .. FARM_FILE)
        else
            warn("[Kronax Autoexec] ecriture locale echouee : " .. tostring(writeError))
        end
    end
    return downloaded, "github"
end

local function launchFarm(reason)
    if not running then return false end
    if typeof(loadstring) ~= "function" then
        warn("[Kronax Autoexec] loadstring indisponible")
        return false
    end

    local source, origin = fetchFarmSource()
    if not source then return false end

    local chunk, compileError = loadstring(source, "@" .. FARM_FILE)
    if not chunk then
        warn("[Kronax Autoexec] compilation impossible : " .. tostring(compileError))
        return false
    end

    local runOk, runError = pcall(chunk)
    if not runOk then
        warn("[Kronax Autoexec] lancement impossible : " .. tostring(runError))
        return false
    end
    if not running then
        stopFarm("autoexec deja arrete pendant le lancement")
        return false
    end
    print(("[Kronax Autoexec] farm lance (%s) : %s"):format(origin, tostring(reason)))
    return true
end

local function ensureFarm(reason)
    if not running or farmState ~= "idle" then return end
    farmState = "launching"
    task.spawn(function()
        local launched = launchFarm(reason)
        farmState = launched and "running" or "failed"
    end)
end

local function stop(reason)
    if not running then return end
    running = false
    stopFarm(reason or "arret autoexec")
    for _, connection in ipairs(connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(connections)
    if _G.StopKronaxAutoexec == stop then _G.StopKronaxAutoexec = nil end
    _G.KronaxAutoexecRunning = nil
    print("[Kronax Autoexec] arrete : " .. tostring(reason))
end

_G.StopKronaxAutoexec = stop
_G.KronaxAutoexecRunning = true

connect(UserInputService.InputBegan, function(input, processed)
    if not processed and input.KeyCode == Enum.KeyCode.B then
        stop("touche B")
    end
end)

pcall(function()
    connect(player.OnTeleport, function(state)
        if state == Enum.TeleportState.Started
            or state == Enum.TeleportState.InProgress then
            stop("teleport; le prochain Autoexec reprendra")
        end
    end)
end)

task.spawn(function()
    while running do
        local now = os.clock()

        -- Start : reclic toutes les 6 s tant que le bouton reste visible.
        -- Des qu'il disparait apres au moins un clic, la phase se termine.
        if not startFinished then
            local start = startButton()
            if start then
                if startAttempts == 0
                    or now - startClickedAt >= START_CLICK_INTERVAL then
                    if clickButton(start, "Start #" .. (startAttempts + 1)) then
                        startAttempts += 1
                        startClickedAt = now
                        -- Le gros farm est charge dans une autre coroutine :
                        -- meme s'il met 30-60 s a s'initialiser, Skip/Retry
                        -- continuent. On ne le lance qu'au premier clic.
                        if startAttempts == 1 then
                            ensureFarm("Start envoye")
                        end
                    else
                        -- Bouton disparu entre la detection et le clic : le
                        -- tick suivant reessaye sans decaler l'intervalle.
                        warn("[Kronax Autoexec] clic Start manque;"
                            .. " nouvelle tentative au prochain scan")
                    end
                end
            elseif startAttempts > 0 then
                -- Bouton parti : le clic a pris. On arrete de chercher Start.
                startFinished = true
                print(("[Kronax Autoexec] Start confirme apres %d tentative(s)")
                    :format(startAttempts))
            elseif activeKronaxBoss() or activeDungeonVisible() then
                startFinished = true
                skipFinished = true
                ensureFarm("combat Kronax deja actif")
                print("[Kronax Autoexec] combat deja actif; Start inutile")
            elseif now - loadedAt >= START_SEARCH_WINDOW then
                startFinished = true
                skipFinished = true
                print("[Kronax Autoexec] aucun Start initial; mode Retry uniquement")
            end
        -- Skip : une tentative maximum, la seconde si le bouton est encore
        -- visible au scan suivant (la premiere entree a ete ignoree).
        elseif not skipFinished then
            local skip = skipButton()
            if skip then
                if skipAttempts < SKIP_MAX_ATTEMPTS then
                    skipAttempts += 1
                    clickButton(skip, "Skip cinematique #" .. skipAttempts)
                else
                    skipFinished = true
                    warn("[Kronax Autoexec] Skip toujours visible apres 2 tentatives")
                end
            elseif skipAttempts > 0 then
                skipFinished = true
                print(("[Kronax Autoexec] Skip confirme apres %d tentative(s)")
                    :format(skipAttempts))
            elseif now - startClickedAt >= SKIP_SEARCH_WINDOW then
                skipFinished = true
                print("[Kronax Autoexec] fenetre Skip terminee")
            end
        end

        -- Retry : reste le seul controle permanent, scanne toutes les 3 s.
        -- Reclique tant que le bouton est visible; ne s'arrete que sur
        -- teleport ou reapparition d'un nouveau Start.
        if now >= nextRetryScan then
            nextRetryScan = now + RETRY_SCAN_INTERVAL
            local retry = retryButton()
            if retry then
                startFinished = true
                skipFinished = true
                if not retryPrepared then
                    retryPrepared = true
                    stopFarm("retry detecte")
                end
                clickButton(retry, "Retry")
            elseif retryPrepared and (startButton() or activeDungeonVisible()) then
                retryPrepared=false; farmState="idle"
                loadedAt=now; startFinished=false; skipFinished=false
                startAttempts=0; skipAttempts=0; startClickedAt=nil
                print("[Kronax Autoexec] nouvelle execution locale apres Retry")
            end
        end

        if startFinished and skipFinished then
            task.wait(RETRY_SCAN_INTERVAL)
        else
            task.wait(INITIAL_SCAN_INTERVAL)
        end
    end
end)

if running then
    print(("[Kronax Autoexec] actif : Start toutes les %.0f s,"
            .. " Retry toutes les %.0f s, arret B")
        :format(START_CLICK_INTERVAL, RETRY_SCAN_INTERVAL))
end
