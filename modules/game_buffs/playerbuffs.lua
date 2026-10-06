local playerBuffsWindow = nil
local playerBuffs = {}
local confirmationWindow = nil
local buffStateReceived = false

local function nowMillis()
    if g_clock and type(g_clock.millis) == 'function' then
        return g_clock.millis()
    end
    return os.time() * 1000
end

local function getBuffRemainingMs(buffName)
    if type(buffName) ~= 'string' or buffName == '' then
        return 0
    end

    local buffConfig = playerBuffs[buffName]
    if not buffConfig then
        return 0
    end

    local elapsed = math.max(0, nowMillis() - (buffConfig.receivedAtMs or nowMillis()))
    return math.max(0, (tonumber(buffConfig.endTime) or 0) - elapsed)
end

local function getBuffSnapshot()
    if not buffStateReceived then
        return nil
    end

    local snapshot = {}
    local now = nowMillis()
    for name, buffConfig in pairs(playerBuffs) do
        local remainingMs = getBuffRemainingMs(name)
        if remainingMs > 0 then
            snapshot[name] = {
                remainingMs = remainingMs,
                value = buffConfig.value,
                receivedAtMs = now
            }
        end
    end
    return snapshot
end

local function publishApi()
    if not modules.game_buffs then modules.game_buffs = {} end
    modules.game_buffs.getBuffRemainingMs = getBuffRemainingMs
    modules.game_buffs.getBuffSnapshot = getBuffSnapshot
end

function onGameStart()
    g_ui.loadUI('playerbuffs')
    playerBuffsWindow = g_ui.createWidget('PlayerBuffsWindow')
    playerBuffsWindow:setParent(modules.game_interface.getRootPanel())
    loadPosition()
    playerBuffsWindow:hide()
    playerBuffsWindow.onDragLeave = function(widget)
        setBuffsPosition({
            x = playerBuffsWindow:getX(),
            y = playerBuffsWindow:getY()
        })
        return true
    end
    -- O pacote de buffs nao pode ser pedido de novo: se ele chegou antes desta janela existir, o
    -- conteudo ja esta em playerBuffs e so falta desenhar.
    createBuffWidget()
end

function onGameEnd()
    playerBuffs = {}
    buffStateReceived = false
    -- Destruir a janela derruba os widgets de buff, e cada um leva junto o proprio cycleEvent
    -- (ver startCooldown). Nao ha lista de eventos para varrer aqui.
    if playerBuffsWindow then
        playerBuffsWindow:destroy()
        playerBuffsWindow = nil
    end

    if confirmationWindow then
        confirmationWindow:destroy()
        confirmationWindow = nil
    end
end

function init()
    publishApi()
    connect(g_game, {
        onGameStart = onGameStart,
        onGameEnd = onGameEnd,
        onPlayerBuffsReceived = onPlayerBuffsReceived
    })
end

function terminate()
    disconnect(g_game, {
        onGameStart = onGameStart,
        onGameEnd = onGameEnd,
        onPlayerBuffsReceived = onPlayerBuffsReceived
    })
    if modules.game_buffs then
        modules.game_buffs.getBuffRemainingMs = nil
        modules.game_buffs.getBuffSnapshot = nil
    end
end

function onPlayerBuffsReceived(buffs)
    playerBuffs = {}
    local receivedAtMs = nowMillis()
    for _, buff in ipairs(buffs) do
        playerBuffs[buff.name] = {
            endTime = buff.endTime,
            value = buff.value,
            receivedAtMs = receivedAtMs
        }
    end
    buffStateReceived = true

    -- Sem a janela o estado fica guardado, nao descartado: o onGameStart desenha.
    if playerBuffsWindow then
        createBuffWidget()
    end
end

local configTable = {
    ["catch"] = {description = "Increases the chance of catching Pokémon by %d%%", name = "Catch"},
    ["experience"] = {description = "Increases the EXP earned by %d%%", name = "Experience"},
    ["loot"] = {description = "Increases the drop chance of all Pokémon by %d%%", name = "Loot"},
    ["shiny_appear"] = {description = "Increases the appearance of shiny Pokémon by %d%%", name = "Shiny Charm"},
    ["shiny_catch"] = {description = "Increases the chance of catching Pokémon Shiny by %d%%", name = "Shiny Catch"},
    ["SweetAroma"] = {description = "Passive Pokémon will become aggressive.", name = "Sweet Aroma"},
    ["pokelog_boost"] = {description = "Doubles your Pokélog. Each defeated creature counts twice.", name = "Pokelog Boost"}
}

function getTooltipDesc(name, config)
    local tableConfig = configTable[name]
    if not tableConfig then
        return ""
    end

    local text = string.format(tableConfig.description, config.value)
    return text
end

function confirmationWindowCleanup()
    if confirmationWindow then
        confirmationWindow:destroy()
        confirmationWindow = nil
    end
end

function confirmRemoveBonus()
    if not confirmationWindow then
        return
    end

    local buffName = confirmationWindow.buffName
    confirmationWindowCleanup()
    if not buffName or buffName:len() <= 0 then
        return
    end

    g_game.sendRemoveBonus(buffName)
end

function createMenu(widget)
    if not widget then
        return
    end

    local name = widget.name or ""
    local config = configTable[name]
    if not config or not config.name then
        return
    end

    -- O UIPopupMenu se destroi sozinho (opcao escolhida, clique fora, Escape) e o display() ja mata
    -- o menu anterior; guardar a referencia aqui so deixava um ponteiro pendurado para redestruir no
    -- onGameEnd. setGameMenu(true) entrega o fechamento no logout ao corelib.
    local menu = g_ui.createWidget('PopupMenu')
    menu:setGameMenu(true)
    menu:addOption(string.format("Delete %s Bonus", config.name), function()
        confirmationWindowCleanup()

        confirmationWindow = displayGeneralBox(tr('Confirm Remove'), tr('Are you sure you want to remove %s bonus?', config.name), {
            {
                text = tr('Yes'),
                callback = confirmRemoveBonus
            },
            {
                text = tr('No'),
                callback = confirmationWindowCleanup
            },
            anchor = AnchorHorizontalCenter
        }, confirmRemoveBonus, confirmationWindowCleanup)
        confirmationWindow.buffName = name
    end)
    menu:display()
end

function createBuffWidget()
    local totalCount = 0
    playerBuffsWindow:destroyChildren()
    local hide = true
    for name, config in pairs(playerBuffs) do
        local leftTimeMs = getBuffRemainingMs(name)
        local leftTime = leftTimeMs / 1000
        -- Buff vencido nao vira widget. Antes ele virava, e o updateCooldown de abertura derrubava
        -- tudo por dentro do startCooldown -- que voltava e prendia um cycleEvent no widget recem
        -- destruido. O evento orfao sobrevivia ao logout batendo em campos ja liberados
        -- (buffWidget.name == nil -> "table index is nil" no playerBuffs[nil]).
        if leftTime <= 0 then
            playerBuffs[name] = nil
        else
            hide = false
            local buffWidget = g_ui.createWidget("PlayerBuff", playerBuffsWindow)
            buffWidget.name = name
            buffWidget.icon:setImageSource("/images/playerBuffs/"..name)
            buffWidget.leftTimeMs = nowMillis() + leftTimeMs
            buffWidget.duration:setText(timeFormat(leftTime))
            buffWidget.icon:setTooltip(getTooltipDesc(name, config))
            startCooldown(buffWidget)
            totalCount = totalCount + 1
            g_mouse.bindPress(buffWidget, function()
                createMenu(buffWidget)
            end, MouseRightButton)
        end
    end

    local totalHeight = (36 * totalCount) + (10 * math.max(0, (totalCount - 1))) + 12
    playerBuffsWindow:setHeight(totalHeight)
    if not hide then
        playerBuffsWindow:show()
        return
    end

    playerBuffsWindow:hide()
end

function startCooldown(buffWidget)
    buffWidget.updateEvent = cycleEvent(function()
        updateCooldown(buffWidget)
    end, 1000)
    -- O ciclo pertence ao widget e morre com ele. Sem este dono unico, toda destruicao que nao
    -- passasse por um laco manual (destroyChildren, o pai indo embora) deixava o evento vivo.
    buffWidget.onDestroy = function(widget)
        removeEvent(widget.updateEvent)
    end
end

function updateCooldown(buffWidget)
    local leftTime = (buffWidget.leftTimeMs - nowMillis()) / 1000
    if leftTime <= 0 then
        playerBuffs[buffWidget.name] = nil
        createBuffWidget()
        return
    end

    buffWidget.duration:setText(timeFormat(leftTime))
end

publishApi()

function setBuffsPosition(pos)
    g_settings.set('playerBuffs_x', pos.x)
    g_settings.set('playerBuffs_y', pos.y)
    g_settings.save()
end

function loadPosition()
    if not playerBuffsWindow then
        return
    end
    playerBuffsWindow:move(getBuffsPositionX(), getBuffsPositionY())
    -- A posicao salva pode vir de uma tela maior que a atual; restaurada como esta, a janela
    -- fica fora do alcance do jogador.
    playerBuffsWindow:bindRectToParent()
end

function getBuffsPositionX()
    return g_settings.getNumber('playerBuffs_x', 250)
end

function getBuffsPositionY()
    return g_settings.getNumber('playerBuffs_y', 50)
end
