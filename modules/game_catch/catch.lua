catchWindow = nil
local pendingCatch = nil
local pendingCatchEvent = nil
local lastCatchDispatched = { name = "", time = 0 }

local function parseCatchPokemon(text)
  if not text or type(text) ~= 'string' then return nil end

  -- Exclude broadcasts of other players
  local lower = text:lower()
  if lower:find('jogador', 1, true) or lower:find('treinador', 1, true) or lower:find('player', 1, true) then
    return nil
  end

  local hasCatch = text:find('capturou um', 1, true) or
                   text:find('capturou uma', 1, true) or
                   text:find('caught a', 1, true) or
                   text:find('caught an', 1, true)
  if not hasCatch then return nil end

  -- 1) Extract from parentheses: "(Bellsprout)"
  local inParen = text:match('%((.-)%)')
  if inParen then
    local trimmed = inParen:gsub('^%s+', ''):gsub('%s+$', ''):gsub('%.$', '')
    if #trimmed > 0 and trimmed:lower() ~= 'pokémon' and trimmed:lower() ~= 'pokemon' then
      return trimmed
    end
  end

  -- 2) Fallback without parentheses: "capturou um Bellsprout!"
  local candidate = text:match('[Cc]apturou%s+um[a]?%s+([^!%.]+)') or
                    text:match('[Cc]aught%s+an?%s+([^!%.]+)')
  if candidate then
    local trimmed = candidate:gsub('^%s+', ''):gsub('%s+$', ''):gsub('%.$', '')
    local afterPoke = trimmed:match('^[Pp]ok[ée]mon!*%s*(.*)$')
    if afterPoke and #afterPoke > 0 then
      trimmed = afterPoke:gsub('^%s+', ''):gsub('%s+$', ''):gsub('%.$', '')
    end
    if #trimmed > 0 and trimmed:lower() ~= 'pokémon' and trimmed:lower() ~= 'pokemon' then
      return trimmed
    end
  end

  return nil
end

local function parseBallsSpent(text)
  if not text or type(text) ~= 'string' then return nil end
  if not (text:find('gastou:', 1, true) or text:find('spent:', 1, true)) then
    return nil
  end

  local afterColon = text:match(':[%s]*(.+)')
  if not afterColon then return nil end

  local total = 0
  local breakdown = {}

  for countStr, ballPrefix in afterColon:gmatch('(%d+)%s+([%a%s]-)[Bb]all[s]?') do
    local c = tonumber(countStr)
    if c and c > 0 then
      total = total + c
      local clean = ballPrefix:gsub('^%s+', ''):gsub('%s+$', ''):lower()
      if clean == '' then clean = 'poke' end
      breakdown[clean] = (breakdown[clean] or 0) + c
    end
  end

  if total == 0 then
    local cStr, bName = afterColon:match('(%d+)%s+([^%.,]+)')
    local c = tonumber(cStr)
    if c and c > 0 and bName then
      total = c
      local clean = bName:gsub('^%s+', ''):gsub('%s+$', ''):lower():gsub('%s*[Bb]all[s]?$', '')
      if clean == '' then clean = 'poke' end
      breakdown[clean] = c
    end
  end

  if total > 0 then return total, breakdown end
  return nil
end

local function notifyTelegramCatch(pokemonName, experience, lookType, shiny, totalBalls, breakdown)
  if not pokemonName or type(pokemonName) ~= 'string' or pokemonName == '' then return end

  local telegram = MarketTelegram
  if not telegram or not telegram.notifyCatch then
    if modules and modules.game_market and modules.game_market.MarketTelegram then
      telegram = modules.game_market.MarketTelegram
    end
  end
  if not telegram or not telegram.notifyCatch then return end

  local isShiny = (shiny == 1 or shiny == true) or (tostring(pokemonName):lower():find("shiny", 1, true) ~= nil)
  local charName = g_game.getCharacterName and g_game.getCharacterName() or ""
  local worldName = g_game.getWorldName and g_game.getWorldName() or ""

  local finalTotalBalls = tonumber(totalBalls)
  local finalBreakdown = type(breakdown) == "table" and breakdown or {}

  if not finalTotalBalls or finalTotalBalls <= 0 then
    local brokesSummary = nil
    if modules and modules.game_pokemonbrokes and modules.game_pokemonbrokes.getPokemonBrokesSummary then
      brokesSummary = modules.game_pokemonbrokes.getPokemonBrokesSummary(pokemonName)
    elseif getPokemonBrokesSummary then
      brokesSummary = getPokemonBrokesSummary(pokemonName)
    end

    if brokesSummary and brokesSummary.total and brokesSummary.total > 0 then
      finalTotalBalls = brokesSummary.total + 1
      finalBreakdown = brokesSummary.breakdown or {}
    else
      finalTotalBalls = 1
      finalBreakdown = {}
    end
  end

  local catchData = {
    catchCode = string.format("catch_%d_%s", os.time(), tostring(pokemonName):lower():gsub("%s+", "_")),
    pokemonName = pokemonName,
    isShiny = isShiny,
    lookType = lookType,
    experience = tonumber(experience) or 0,
    characterName = charName,
    worldName = worldName,
    totalBalls = finalTotalBalls,
    ballBreakdown = finalBreakdown,
    timestamp = os.time(),
    localTime = os.date("%d/%m/%Y %H:%M:%S")
  }

  local ok, err = pcall(telegram.notifyCatch, catchData)
  if not ok and g_logger then
    g_logger.error("[Catch Telegram] Erro ao notificar catch de " .. tostring(pokemonName) .. ": " .. tostring(err))
  end
end

local function flushPendingCatch()
  if pendingCatchEvent then
    removeEvent(pendingCatchEvent)
    pendingCatchEvent = nil
  end

  if not pendingCatch then return end
  local catch = pendingCatch
  pendingCatch = nil

  local pName = catch.pokemonName
  if not pName or pName == "" then return end

  -- Deduplicate if exact same pokemon was dispatched in the last 3 seconds
  local now = os.time()
  if lastCatchDispatched.name:lower() == pName:lower() and (now - lastCatchDispatched.time) < 3 then
    return
  end
  lastCatchDispatched.name = pName
  lastCatchDispatched.time = now

  notifyTelegramCatch(
    pName,
    catch.experience,
    catch.lookType,
    catch.shiny,
    catch.totalBalls,
    catch.breakdown
  )
end

local function queueCatchEvent(pName, exp, look, shiny)
  if not pName or pName == "" then return end

  -- If a different pokemon is already pending, flush it first
  if pendingCatch and pendingCatch.pokemonName:lower() ~= pName:lower() then
    flushPendingCatch()
  end

  if not pendingCatch then
    pendingCatch = {
      pokemonName = pName,
      experience = tonumber(exp) or 0,
      lookType = look,
      shiny = (shiny == 1 or shiny == true),
      totalBalls = nil,
      breakdown = {}
    }
  else
    if exp and tonumber(exp) and tonumber(exp) > 0 then
      pendingCatch.experience = tonumber(exp)
    end
    if look then
      pendingCatch.lookType = look
    end
    if shiny == 1 or shiny == true then
      pendingCatch.shiny = true
    end
  end

  if pendingCatchEvent then
    removeEvent(pendingCatchEvent)
    pendingCatchEvent = nil
  end
  pendingCatchEvent = scheduleEvent(flushPendingCatch, 350)
end

function init()
  -- onCatchWindow: protocolo custom 1577 (parseCatchWindow em C++), popup de 1a captura
  -- onTextMessage: mensagens de chat padrão da captura (ex: Você capturou um Pokémon! / Você gastou: X Ball)
  connect(g_game, {
    onGameEnd = onGameEnd,
    onCatchWindow = onCatchWindow,
    onTextMessage = onTextMessage
  })

  catchWindow = g_ui.displayUI('catch')
  catchWindow:hide()
end

function terminate()
  disconnect(g_game, {
    onGameEnd = onGameEnd,
    onCatchWindow = onCatchWindow,
    onTextMessage = onTextMessage
  })

  if pendingCatchEvent then
    removeEvent(pendingCatchEvent)
    pendingCatchEvent = nil
  end
  pendingCatch = nil

  if catchWindow then
    catchWindow:destroy()
    catchWindow = nil
  end
end

function onGameEnd()
  if pendingCatchEvent then
    removeEvent(pendingCatchEvent)
    pendingCatchEvent = nil
  end
  pendingCatch = nil

  if catchWindow and catchWindow:isVisible() then
    catchWindow:hide()
  end
end

function onCatchWindow(pokemonName, experience, lookType, shiny)
  show(pokemonName, experience, lookType, shiny)
  queueCatchEvent(pokemonName, experience, lookType, shiny)
end

function onTextMessage(mode, text)
  if not text or type(text) ~= 'string' then return end

  local function processLine(line)
    local caught = parseCatchPokemon(line)
    if caught then
      queueCatchEvent(caught, 0, nil, false)
    end

    local ballsTotal, ballsBreakdown = parseBallsSpent(line)
    if ballsTotal and ballsTotal > 0 then
      if pendingCatch then
        pendingCatch.totalBalls = (pendingCatch.totalBalls or 0) + ballsTotal
        for k, v in pairs(ballsBreakdown) do
          pendingCatch.breakdown[k] = (pendingCatch.breakdown[k] or 0) + v
        end
      end
    end
  end

  if text:find('\n', 1, true) then
    for line in text:gmatch('[^\r\n]+') do
      processLine(line)
    end
  else
    processLine(text)
  end
end

function show(pokemonName, experience, lookType, isShiny)
  if not catchWindow then return end
  if not catchWindow:isVisible() then
    addEvent(function() if catchWindow then g_effects.fadeIn(catchWindow) end end)
  end
  catchWindow:getChildById('looktype'):setOutfit({type = lookType})
  if experience > 0 then
    catchWindow:getChildById('text'):setText(tr(string.format('Congratulations, you caught a %s!\nXP: %s', pokemonName, experience)))
  else
    catchWindow:getChildById('text'):setText(tr(string.format('Congratulations, you caught a %s!', pokemonName)))
  end
  catchWindow:show()
  catchWindow:setVisible(true)
  g_effects.fadeIn(catchWindow)

  scheduleEvent(function() if catchWindow then g_effects.fadeOut(catchWindow) end end, 3000)
  scheduleEvent(function() if catchWindow then catchWindow:hide() end end, 3500)
end

function hide()
  if not catchWindow then return end
  addEvent(function() if catchWindow then g_effects.fadeOut(catchWindow) end end)
  scheduleEvent(function() if catchWindow then catchWindow:hide() end end, 250)
end

-- Export for automated test runner
if _G and _G.TEST_MODE then
  CatchInternal = {
    parseCatchPokemon = parseCatchPokemon,
    parseBallsSpent = parseBallsSpent,
    queueCatchEvent = queueCatchEvent,
    flushPendingCatch = flushPendingCatch,
    notifyTelegramCatch = notifyTelegramCatch,
    getPendingCatch = function() return pendingCatch end,
    getLastCatchDispatched = function() return lastCatchDispatched end,
    resetState = function()
      if pendingCatchEvent then
        removeEvent(pendingCatchEvent)
        pendingCatchEvent = nil
      end
      pendingCatch = nil
      lastCatchDispatched = { name = "", time = 0 }
    end
  }
end
