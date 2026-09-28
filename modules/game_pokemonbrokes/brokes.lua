local brokesWindow = nil
local pokemonsPerPage = 25
local currentPage = 1
local pokemons = {}
local lastKnownBrokes = {}
local sortedPokemons = {}
local totalPages = 1
local searchEvent = nil
local favorites = {}
local sortColumn = "pokemon"
local sortAscending = true
local refreshBrokesList

local pokeballs = {
"pokeball",
"greatball",
"superball",
"ultraball",
"safariball",
"moonball",
"tinkerball",
"yumeball",
"duskball",
"heavyball",
"janguruball",
"maguball",
"netball",
"soraball",
"taleball",
"fastball",
"premierball",
"allianceball"
}

local pokeballWidgetMap = {
    { widgetId = "pokeballCount",    brokeKey = "poke",     label = "Poké Ball" },
    { widgetId = "greatballCount",   brokeKey = "great",    label = "Great Ball" },
    { widgetId = "superballCount",   brokeKey = "super",    label = "Super Ball" },
    { widgetId = "ultraballCount",   brokeKey = "ultra",    label = "Ultra Ball" },
    { widgetId = "safariballCount",  brokeKey = "safari",   label = "Safari Ball" },
    { widgetId = "moonballCount",    brokeKey = "moon",     label = "Moon Ball" },
    { widgetId = "tinkerballCount",  brokeKey = "tinker",   label = "Tinker Ball" },
    { widgetId = "yumeballCount",    brokeKey = "yume",     label = "Yume Ball" },
    { widgetId = "duskballCount",    brokeKey = "dusk",     label = "Dusk Ball" },
    { widgetId = "heavyballCount",   brokeKey = "heavy",    label = "Heavy Ball" },
    { widgetId = "janguruballCount", brokeKey = "janguru",  label = "Janguru Ball" },
    { widgetId = "maguballCount",    brokeKey = "magu",     label = "Magu Ball" },
    { widgetId = "netballCount",     brokeKey = "net",      label = "Net Ball" },
    { widgetId = "soraballCount",    brokeKey = "sora",     label = "Sora Ball" },
    { widgetId = "taleballCount",    brokeKey = "tale",     label = "Tale Ball" },
    { widgetId = "fastballCount",    brokeKey = "fast",     label = "Fast Ball" },
    { widgetId = "premierballCount", brokeKey = "premier",  label = "Premier Ball" },
    { widgetId = "allianceballCount",brokeKey = "alliance", label = "Alliance Ball" },
}

local function populatePokeballCounts(widget, brokes)
    local showAll = brokesWindow and brokesWindow.showAllPokeballs and brokesWindow.showAllPokeballs:isChecked()
    for _, entry in ipairs(pokeballWidgetMap) do
        local count = brokes[entry.brokeKey] or 0
        local pokeWidget = widget.pokeballPanel[entry.widgetId]
        if pokeWidget then
            pokeWidget.count:setText(comma_value2(count))
            if showAll then
                pokeWidget:setVisible(true)
            else
                pokeWidget:setVisible(count > 0)
            end
        end
    end
end

modules.client_hotkeys.registerHotkeyCallback("BROKES",
  function(actionName, action, keyInfo, chatState, keyType)
    local callback = function()
      local chatModeEnabled = not modules.game_chat.consoleToggleChat
      local wantChat = (chatState == "chatEnabled")
      if (wantChat and chatModeEnabled) or (not wantChat and not chatModeEnabled) then
        toggle()
      end
    end
    return { callback = callback, widget = modules.game_interface.getRootPanel() }
  end)

function init()
    connect(g_game, {
        onGameEnd = onGameEnd,
        onPokeballBrokesReceived = onReceiveBrokes,
    })
    connect(g_client, {
        onTrainerClose = hideBrokesWindow
    })
    brokesWindow = g_ui.loadUI('brokes', modules.game_interface.getRootPanel())
    brokesWindow:hide()

    brokesTrackerInit()

    local header = brokesWindow.header.topPokemonInfo
    header.pokemonId.onClick = function()
        if sortColumn == "pokemon" then
            sortAscending = not sortAscending
        else
            sortColumn = "pokemon"
            sortAscending = true
        end
        currentPage = 1
        refreshBrokesList()
    end
    header.pokemonName.onClick = function()
        if sortColumn == "pokeballs" then
            sortAscending = not sortAscending
        else
            sortColumn = "pokeballs"
            sortAscending = false
        end
        currentPage = 1
        refreshBrokesList()
    end
    header.total.onClick = function()
        if sortColumn == "total" then
            sortAscending = not sortAscending
        else
            sortColumn = "total"
            sortAscending = false
        end
        currentPage = 1
        refreshBrokesList()
    end

    brokesWindow.searchPokemon.onTextChange = function()
        if searchEvent then
            removeEvent(searchEvent)
            searchEvent = nil
        end
        searchEvent = scheduleEvent(function()
            searchEvent = nil
            local text = brokesWindow.searchPokemon:getText()
            if text:len() == 0 then
                openBrokesWindow(true)
            else
                createPokemonInfo(text, 1)
            end
        end, 300)
    end

    brokesWindow.showAllPokeballs.onCheckChange = function(self, checked)
        local margin = checked and 20 or 2
        local imageSource = checked and "/images/general_ui/icons/base_slider_selected" or "/images/general_ui/icons/base_slider"
        local sliderButton = self.sliderButton
        if sliderButton then
            sliderButton:setMarginLeft(margin)
        end
        self:setImageSource(imageSource)

        if brokesWindow:isVisible() then
            local text = brokesWindow.searchPokemon:getText()
            if text:len() == 0 then
                openBrokesWindow(true)
            else
                createPokemonInfo(text, currentPage)
            end
        end
    end
end

function terminate()
    disconnect(g_game, {
        onGameEnd = onGameEnd,
        onPokeballBrokesReceived = onReceiveBrokes,
    })

    disconnect(g_client, {
        onTrainerClose = hideBrokesWindow,
    })

    if searchEvent then
        removeEvent(searchEvent)
        searchEvent = nil
    end

    if brokesWindow then
        brokesWindow:destroy()
    end

    brokesTrackerTerminate()
end

function onGameEnd()
    sortedPokemons = {}
    pokemons = {}
    favorites = {}
    sortColumn = "pokemon"
    sortAscending = true
    hideBrokesWindow()
    onBrokesTrackerGameEnd()
end

local function loadFavorites()
    local saved = CharacterConfig.get("brokesFavorites")
    if saved and type(saved) == "table" then
        favorites = saved
    else
        favorites = {}
    end
end

local function saveFavorites()
    CharacterConfig.set("brokesFavorites", favorites)
    CharacterConfig.save()
end

local function isFavorite(pokemonName)
    return favorites[pokemonName] == true
end

local function isPinned(pokemonName)
    return favorites[pokemonName] == true or isBrokeTracked(pokemonName)
end

local function getSortPriority(name)
    local fav = isFavorite(name)
    local trk = isBrokeTracked(name)
    if fav and trk then return 0 end
    if fav then return 1 end
    if trk then return 2 end
    return 3
end

local function getTotalBrokes(brokes)
    local total = 0
    for _, count in pairs(brokes) do
        total = total + count
    end
    return total
end

local function getDistinctBallTypes(brokes)
    local count = 0
    for _, v in pairs(brokes) do
        if v > 0 then
            count = count + 1
        end
    end
    return count
end

local function sortPokemons()
    sortedPokemons = {}
    for name, data in pairs(pokemons) do
        table.insert(sortedPokemons, {name = name, id = data.id, shinyId = data.shinyId, brokes = data.brokes})
    end
    table.sort(sortedPokemons, function(a, b)
        local aPri = getSortPriority(a.name)
        local bPri = getSortPriority(b.name)
        if aPri ~= bPri then
            return aPri < bPri
        end

        if sortColumn == "total" then
            local aTotal = getTotalBrokes(a.brokes)
            local bTotal = getTotalBrokes(b.brokes)
            if aTotal ~= bTotal then
                if sortAscending then
                    return aTotal < bTotal
                else
                    return aTotal > bTotal
                end
            end
        elseif sortColumn == "pokeballs" then
            local aTypes = getDistinctBallTypes(a.brokes)
            local bTypes = getDistinctBallTypes(b.brokes)
            if aTypes ~= bTypes then
                if sortAscending then
                    return aTypes < bTypes
                else
                    return aTypes > bTypes
                end
            end
        elseif sortColumn == "pokemon" then
            if a.id ~= b.id then
                if sortAscending then
                    return a.id < b.id
                else
                    return a.id > b.id
                end
            end
            if a.shinyId ~= b.shinyId then
                if sortAscending then
                    return a.shinyId < b.shinyId
                else
                    return a.shinyId > b.shinyId
                end
            end
            return false
        end

        if a.id ~= b.id then
            return a.id < b.id
        end
        if a.shinyId ~= b.shinyId then
            return a.shinyId < b.shinyId
        end
        return false
    end)
end

refreshBrokesList = function()
    sortPokemons()

    local scrollBar = brokesWindow:getChildById("brokesPanelScrollBar")
    local scrollValue = scrollBar and scrollBar:getValue() or 0

    local text = brokesWindow.searchPokemon:getText()
    if text:len() == 0 then
        openBrokesWindow(true)
    else
        createPokemonInfo(text, currentPage)
    end

    if scrollBar then
        scrollBar:setValue(scrollValue)
    end
end

local function setupFavoriteButton(widget, pokemonName)
    local favBtn = widget.pokemonsInfo.favoriteButton
    if not favBtn then return end
    if isFavorite(pokemonName) then
        favBtn:setImageSource("/images/modules/selected_star")
        favBtn:setTooltip(tr('Remove from favorites'))
    else
        favBtn:setImageSource("/images/modules/empty_star")
        favBtn:setTooltip(tr('Add to favorites'))
    end
    favBtn.onClick = function()
        if isFavorite(pokemonName) then
            favorites[pokemonName] = nil
        else
            favorites[pokemonName] = true
        end
        saveFavorites()
        refreshBrokesList()
    end
end

local function setupTrackerButton(widget, pokemonName)
    local trkBtn = widget.pokemonsInfo.trackerButton
    if not trkBtn then return end
    if isBrokeTracked(pokemonName) then
        trkBtn:setIconColor("#55bbff")
        trkBtn:setTooltip(tr('Stop tracking brokes'))
    else
        trkBtn:setIconColor("#666666")
        trkBtn:setTooltip(tr('Track brokes'))
    end
    trkBtn.onClick = function()
        toggleBrokeTracker(pokemonName)
        refreshBrokesList()
    end
end

function formatPokemonBrokesText(pokemonName)
    local data = pokemons[pokemonName]
    if not data then
        return pokemonName
    end
    local lines = { pokemonName .. " #" .. string.format('%03d', data.id) }
    local total = 0
    for _, entry in ipairs(pokeballWidgetMap) do
        local count = data.brokes[entry.brokeKey] or 0
        if count > 0 then
            table.insert(lines, entry.label .. ": " .. comma_value2(count))
            total = total + count
        end
    end
    table.insert(lines, tr("Total") .. ": " .. comma_value2(total))
    return table.concat(lines, "\n")
end

local function setupCopyButton(widget, pokemonName)
    local copyBtn = widget.pokemonsInfo.copyButton
    if not copyBtn then return end
    copyBtn.onClick = function()
        g_window.setClipboardText(formatPokemonBrokesText(pokemonName))
        modules.game_textmessage.displayStatusMessage(tr("%s brokes copied to clipboard", pokemonName))
    end
end

local function setupDexButton(widget, pokemonId)
    local dexBtn = widget.pokemonsInfo.dexButton
    if not dexBtn then return end
    dexBtn.onClick = function()
        modules.game_pokedex.openFor(pokemonId)
    end
end

function onReceiveBrokes(data)
    local msgType = data.type
    local entries = data.entries

    for _, entry in ipairs(entries) do
        local total = getTotalBrokes(entry.brokes)
        if total > 0 then
            lastKnownBrokes[entry.name] = {
                id = entry.id,
                shinyId = entry.shinyId,
                total = total,
                brokes = entry.brokes
            }
        end
        pokemons[entry.name] = {
            id = entry.id,
            shinyId = entry.shinyId,
            brokes = entry.brokes
        }
    end

    loadFavorites()

    if msgType == 0 then
        rebuildTracker()
    else
        refreshTrackerCounts()
    end

    sortPokemons()
end

function hideBrokesWindow()
    if searchEvent then
        removeEvent(searchEvent)
        searchEvent = nil
    end

    if brokesWindow then
        local searchWidget = brokesWindow.searchPokemon
        if searchWidget then
            local oldOnTextChange = searchWidget.onTextChange
            searchWidget.onTextChange = nil
            searchWidget:setText("")
            searchWidget.onTextChange = oldOnTextChange
        end

        g_effects.fadeOut(brokesWindow)
        scheduleEvent(function()
            if brokesWindow then
                brokesWindow:hide()
                g_uistates.remove(brokesWindow)
            end
        end, 500)
    end
end

function toggle()
    if brokesWindow and brokesWindow:isVisible() then
        hideBrokesWindow()
    else
        local text = brokesWindow.searchPokemon:getText()
        if text:len() == 0 then
            openBrokesWindow()
        else
            createPokemonInfo(text, currentPage)
        end
        g_uistates.push(brokesWindow)
    end
end

function getBrokesWindow()
    return brokesWindow
end

function getPokemons()
    return pokemons
end

function getPokemonBrokesSummary(pokemonName)
    if not pokemonName or type(pokemonName) ~= "string" then
        return { total = 0, brokes = {}, breakdown = {} }
    end
    local query = pokemonName:gsub("^%s+", ""):gsub("%s+$", "")
    local data = pokemons[query] or lastKnownBrokes[query]

    if not data then
        local clean = query:gsub("^[Ss]hiny%s+", "")
        data = pokemons[clean] or lastKnownBrokes[clean] or pokemons["Shiny " .. clean] or lastKnownBrokes["Shiny " .. clean]
    end

    if not data then
        local lowerQuery = query:lower()
        for name, entry in pairs(pokemons) do
            if name:lower() == lowerQuery then
                data = entry
                break
            end
        end
        if not data then
            for name, entry in pairs(lastKnownBrokes) do
                if name:lower() == lowerQuery then
                    data = entry
                    break
                end
            end
        end
    end

    if not data or not data.brokes then
        return {
            total = 0,
            brokes = {},
            breakdown = {}
        }
    end

    local total = 0
    local breakdown = {}
    for brokeKey, count in pairs(data.brokes) do
        local num = tonumber(count)
        if num and num > 0 then
            total = total + num
            breakdown[brokeKey] = num
        end
    end

    return {
        total = total,
        brokes = data.brokes,
        breakdown = breakdown,
        id = data.id,
        shinyId = data.shinyId
    }
end

function openBrokesWindow(ignoreFadeIn)
    if not brokesWindow then
        return
    end
    local brokesPanel = brokesWindow:getChildById("pokemonBrokesPanel")
    if not brokesPanel then
        return
    end
    local layout = brokesPanel:getLayout()
    if layout then layout:disableUpdates() end
    brokesPanel:destroyChildren()
    local totalCount = 0
    for _ in pairs(pokemons) do
        totalCount = totalCount + 1
    end

    local startIndex = (currentPage - 1) * pokemonsPerPage + 1
    local endIndex = math.min(startIndex + pokemonsPerPage - 1, totalCount)
    for i = startIndex, endIndex do
        local pokemonInfo = sortedPokemons[i]
        if pokemonInfo then
            local widget = g_ui.createWidget("PokemonBrokeWidget", brokesPanel)
            widget:setId(i)
            widget.pokemonsInfo.pokemonName:setText(pokemonInfo.name)
            local widgetId = string.format('%03d', pokemonInfo.id)
            widget.pokemonsInfo.pokemonId:setText("#"..widgetId)
            widget.pokemonsInfo.pokemon:setImageSource(pokemonPortraitSource(pokemonInfo.name, pokemonInfo.id, pokemonInfo.shinyId))
            populatePokeballCounts(widget, pokemonInfo.brokes)
            setupFavoriteButton(widget, pokemonInfo.name)
            setupTrackerButton(widget, pokemonInfo.name)
            setupCopyButton(widget, pokemonInfo.name)
            setupDexButton(widget, pokemonInfo.id)
            local totalBrokes = 0
            for _, count in pairs(pokemonInfo.brokes) do
                totalBrokes = totalBrokes + count
            end
            widget.totalPokeballs:setText(comma_value2(totalBrokes))
        end
    end

    totalPages = math.max(math.ceil(totalCount / pokemonsPerPage), 1)
    brokesWindow.pageIndex:setText(tr("Page: %d/%d", currentPage, totalPages))
    brokesWindow:show()
    brokesWindow:focus()
    if not ignoreFadeIn then
        g_effects.fadeIn(brokesWindow)
    end
    if layout then
        layout:enableUpdates()
        layout:update()
    end
end

function nextPage()
    local oldCurrentPage = currentPage
    currentPage = math.min(currentPage + 1, totalPages)
    if oldCurrentPage == currentPage then
        return
    end
    local brokesPanel = brokesWindow:getChildById("pokemonBrokesPanel")
    if brokesPanel then
        brokesPanel:destroyChildren()
    end
    local text = brokesWindow.searchPokemon:getText()
    if text:len() == 0 then
        openBrokesWindow(true)
    else
        createPokemonInfo(text, currentPage)
    end
end

function prevPage()
    local oldCurrentPage = currentPage
    currentPage = math.max(currentPage - 1, 1)
    if oldCurrentPage == currentPage then
        return
    end
    local text = brokesWindow.searchPokemon:getText()
    if text:len() == 0 then
        openBrokesWindow(true)
    else
        createPokemonInfo(text, currentPage)
    end
end

function createPokemonInfo(text, page)
    local brokesPanel = brokesWindow:getChildById("pokemonBrokesPanel")
    if not brokesPanel then return end
    local layout = brokesPanel:getLayout()
    if layout then layout:disableUpdates() end
    brokesPanel:destroyChildren()
    currentPage = page
    local textPokemons = {}
    local lowerText = text:lower()

    for _, config in pairs(sortedPokemons) do
        local lowerName = config.name:lower()
        if string.find(lowerName, lowerText, 1, true) then
            table.insert(textPokemons, config)
        end
    end

    local pokeCount = 0
    local startIndex = (currentPage - 1) * pokemonsPerPage + 1
    local endIndex = math.min(startIndex + pokemonsPerPage - 1, #textPokemons)

    for i = startIndex, endIndex do
        local pokemonInfo = textPokemons[i]
        if pokemonInfo then
            local widget = g_ui.createWidget("PokemonBrokeWidget", brokesPanel)
            widget:setId(i)
            widget.pokemonsInfo.pokemonName:setText(pokemonInfo.name)
            local widgetId = string.format('%03d', pokemonInfo.id)
            widget.pokemonsInfo.pokemonId:setText("#"..widgetId)
            widget.pokemonsInfo.pokemon:setImageSource(pokemonPortraitSource(pokemonInfo.name, pokemonInfo.id, pokemonInfo.shinyId))
            populatePokeballCounts(widget, pokemonInfo.brokes)
            setupFavoriteButton(widget, pokemonInfo.name)
            setupTrackerButton(widget, pokemonInfo.name)
            setupCopyButton(widget, pokemonInfo.name)
            setupDexButton(widget, pokemonInfo.id)
            local totalBrokes = 0
            for _, count in pairs(pokemonInfo.brokes) do
                totalBrokes = totalBrokes + count
            end
            widget.totalPokeballs:setText(comma_value2(totalBrokes))
            pokeCount = pokeCount + 1
        end
    end
    totalPages = math.max(math.ceil(#textPokemons / pokemonsPerPage), 1)
    brokesWindow.pageIndex:setText(tr("Page: %d/%d", currentPage, totalPages))
    brokesWindow:show()
    brokesWindow:focus()
    if layout then
        layout:enableUpdates()
        layout:update()
    end
end