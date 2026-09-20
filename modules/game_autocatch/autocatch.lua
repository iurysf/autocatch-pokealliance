-- Auto Catch por ID de corpo para o cliente PokeAlliance (OTClientV8).
--
-- Modulo sandboxed: toda funcao declarada sem "local" vira campo de
-- modules.game_autocatch. A API publica esta listada no fim do arquivo.

local CatchInterval = dofile('/modules/game_autocatch/catch_interval.lua')
local CorpseClaim = dofile('/modules/game_autocatch/corpse_claim.lua')
local CorpseSelection = dofile('/modules/game_autocatch/corpse_selection.lua')
local CatchDispatch = dofile('/modules/game_autocatch/catch_dispatch.lua')
local CorpseTarget = dofile('/modules/game_autocatch/corpse_target.lua')
local CatchStats = dofile('/modules/game_autocatch/catch_stats.lua')
local StaffGuard = dofile('/modules/game_autocatch/staff_guard.lua')
local AutoItem = dofile('/modules/game_autocatch/auto_item.lua')

-- ---------------------------------------------------------------------------
-- Log
-- ---------------------------------------------------------------------------

local debugEnabled = false

local function logInfo(msg)
  pcall(function() print('[AutoCatch] ' .. tostring(msg)) end)
end

local function logWarn(msg)
  pcall(function()
    if g_logger and g_logger.warning then
      g_logger.warning('[AutoCatch] ' .. tostring(msg))
    else
      print('[AutoCatch] AVISO: ' .. tostring(msg))
    end
  end)
end

local function debugLog(msg)
  if not debugEnabled then return end
  pcall(function() print('[AutoCatch][debug] ' .. tostring(msg)) end)
end

-- ---------------------------------------------------------------------------
-- Constantes
-- ---------------------------------------------------------------------------

local CFG = {
  CORPSE_RETRY_DELAY = 100,  -- ms entre buscas do corpo apos a morte
  CORPSE_RETRY_LIMIT = 50,  -- buscas quando a morte foi confirmada (HP 0)
  UNCONFIRMED_RETRY_LIMIT = 3,  -- buscas quando o monstro so sumiu da tela
  MAX_CATCH_DISTANCE = 10,  -- SQM maximo para lancar a Ball
  TRACK_DISTANCE = 12,  -- MAX_CATCH_DISTANCE + 2
  VISIBLE_SCAN_RADIUS_X = 10,
  VISIBLE_SCAN_RADIUS_Y = 5,
  FLOOR_SCAN_INTERVAL = 120,
  CORPSE_CLAIM_TTL = 60000,  -- seguranca: claim some mesmo sem confirmar remocao
  BLOCKED_CORPSE_TTL = 90000,  -- corpo esgotado fica fora da varredura por este tempo
  CATCH_DISPATCH_RETRY_WINDOW = 5000,
  CATCH_RESULT_CHECK_DELAY = 1800,
  MAX_CATCH_SEND_ATTEMPTS = 2,
  RETRY_INTERVAL = 150,  -- ms entre tentativas de um job adiado
  LOW_BALL_WARNING = 10,
  STAFF_CHECK_CACHE_MS = 500,
  OBSERVED_TARGET_TTL = 60000,
  CORPSE_SEEN_TTL = 60000,
  SHINY_DEATH_TTL = 5000,  -- janela para associar um corpo a uma morte de shiny
  REARM_DELAY_MS = 4000,
  AUTO_ITEM_RETRY_MS = 15000,
  AUTO_ITEM_MISSING_BACKOFF_MS = 60000,
  AUTO_ITEM_MAX_LEARNING_ATTEMPTS = 3,
}

local SETTINGS = {
  CORPSE_ENTRIES = 'autoCatchCorpseEntries',
  SHINY_BALL_ID = 'autoCatchShinyBallId',
  RESERVE_BALL_ID = 'autoCatchReserveBallId',
  STAFF_GUARD = 'autoCatchStaffGuard',
  AUTO_REARM = 'autoCatchAutoRearm',
  WAS_ENABLED = 'autoCatchWasEnabled',
  DEBUG = 'autoCatchDebug',
  CATCH_INTERVAL_MIN = 'autoCatchQueueIntervalMin',
  CATCH_INTERVAL_MAX = 'autoCatchQueueIntervalMax',
  AUTO_ITEMS = 'autoCatchAutoItems',
  AUTO_ITEM_NEXT_ID = 'autoCatchAutoItemNextId',
  -- chaves antigas, lidas somente para migrar
  BALL1_ID = 'autoCatchBall1Id',
  BALL2_ID = 'autoCatchBall2Id',
  BALL_ID_LEGACY = 'autoCatchBallId',
  CORPSE1_ID = 'autoCatchCorpse1Id',
  CORPSE2_ID = 'autoCatchCorpse2Id',
  CORPSE_ID_LEGACY = 'autoCatchCorpseId',
  SHINY_BALL_CHOICE = 'autoCatchShinyBallChoice',
  CATCH_ALL_SHINY = 'autoCatchAllShiny',
  AUTO_ACTION_SLOT = 'autoCatchActionSlot',
  AUTO_ITEM_ID = 'autoCatchAutoItemId',
  AUTO_ITEM_ENABLED = 'autoCatchAutoItemEnabled'
}

-- ---------------------------------------------------------------------------
-- Estado
-- ---------------------------------------------------------------------------

local ui = {
  window = nil,
  panel = nil,
  button = nil,
  statusIndicator = nil,
  statusTitle = nil,
  statusLabel = nil,
  statsLine = nil,
  enabledCheckBox = nil,
  navTabCatch = nil,
  navTabSafety = nil,
  navTabUtils = nil,
  tabCatchContent = nil,
  tabSafetyContent = nil,
  tabUtilsContent = nil,
  presetSafeBtn = nil,
  presetNormalBtn = nil,
  presetTurboBtn = nil,
  addPokemonBtn = nil,
  entriesList = nil,
  entriesEmpty = nil,
  entriesCountHint = nil,
  shinyBallSlot = nil,
  shinyBallInfo = nil,
  selectShinyBallBtn = nil,
  clearShinyBallBtn = nil,
  reserveBallSlot = nil,
  reserveBallInfo = nil,
  selectReserveBallBtn = nil,
  clearReserveBallBtn = nil,
  staffGuardCheckBox = nil,
  autoRearmCheckBox = nil,
  autoItemsList = nil,
  autoItemsEmpty = nil,
  autoItemsCountHint = nil,
  addAutoItemBtn = nil,
  catchIntervalMinEdit = nil,
  catchIntervalMaxEdit = nil
}

local corpseEntries = {}
local nextCorpseEntryId = 0
local corpseBallIndex = {}
local corpseEntryIndex = {}
local entryRows = {}
local shinyBallId = 0
local reserveBallId = 0
local staffGuardEnabled = true
local autoRearmEnabled = false
local enabled = false
local updatingInterface = false
local catchIntervalMinimum = CatchInterval.DEFAULT_MINIMUM
local catchIntervalMaximum = CatchInterval.DEFAULT_MAXIMUM

local stats = CatchStats.new()
local pacer = CatchInterval.newPacer()
local corpseClaims = CorpseClaim.new(CFG.CORPSE_CLAIM_TTL, function() return g_clock.millis() end)

local observedTargets = {}      -- token -> monstro vivo rastreado (dentro do alcance)
local dyingTargets = {}         -- token -> monstro morto (ou sumido) aguardando corpo
local retryEvents = {}          -- token -> evento agendado de busca do corpo
local catchVerificationEvents = {}
local catchQueue = {}
local catchQueueEvent = nil
local queuedKeys = {}           -- chave posicao:itemId -> true enquanto na fila
local activeCatchJob = nil
local nextCatchJobId = 0
local corpseFirstSeen = {}      -- chave -> { at = ms, seenAt = ms }
local floorScanEvent = nil
local floorScanHasPendingCorpses = false
local floorScanHasResult = false
local ballRefreshEvent = nil
local lastThrowTime = 0
local nextThrowAllowedAt = 0
local recentBurstThrows = 0
local lowBallWarned = {}
local staffCache = { at = 0, name = nil }
local staffHoldName = nil
local pauseReason = nil
local rearmEvent = nil
local shinyDeaths = {}          -- mortes recentes de shiny { position, at }

local corpseSelectGrabber = nil
local inventorySelectGrabber = nil
local selectingCorpseEntryId = nil

local autoItems = {}
local nextAutoItemCardId = 0
local autoItemTimerEvent = nil
local autoItemLearningCardId = nil
local autoItemBuffSnapshot = nil
local updatingAutoItemInterface = false

-- declaracoes antecipadas (funcoes definidas mais abaixo)
local setStatus, updateStatsLine, refreshCorpseEntries, updateCorpseEntryRows
local refreshSpecialBalls, refreshAutoItemEntries, refreshAutoItemRows
local startBallSelection, startInventorySelection
local getInventoryItemCount, scheduleFloorScan, scanFloorForCorpses
local processCatchQueue, scheduleCatchQueue, cancelRetries
local setAutoItemEnabled, deleteAutoItem, updateAutoItemLoop
local applyCatchIntervalInputs, updatePresetButtons, bindPanelWidgets

-- ---------------------------------------------------------------------------
-- Utilidades
-- ---------------------------------------------------------------------------

local function now()
  return g_clock.millis()
end

local function trim(value)
  return (value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function copyPosition(position)
  if not position then return nil end
  return { x = position.x, y = position.y, z = position.z }
end

local function safeItemId(item)
  if not item then return nil end
  local ok, itemId = pcall(function() return item:getId() end)
  return ok and tonumber(itemId) or nil
end

local function safeItemText(item, methodName)
  local method = item and item[methodName]
  if not method then return '' end
  local ok, value = pcall(function() return method(item) end)
  if not ok or not value then return '' end
  return tostring(value)
end

local function isItemThing(value)
  if not value then return false end
  local ok, result = pcall(function() return value:isItem() end)
  return ok and result == true
end

local function topUseThing(tile)
  if not tile or type(tile.getTopUseThing) ~= 'function' then return nil end
  local ok, item = pcall(function() return tile:getTopUseThing() end)
  return ok and item or nil
end

local function tileItems(tile)
  if not tile then return nil end
  local ok, items = pcall(function() return tile:getItems() end)
  return ok and items or nil
end

local function tileContainsItem(tile, expectedItem)
  local items = tileItems(tile)
  if not items or not expectedItem then return false end
  for _, item in ipairs(items) do
    if item == expectedItem then return true end
  end
  return false
end

-- Quantos itens com o ID existem no tile (nil quando o tile e desconhecido).
local function countMatchingItemsAt(position, itemId)
  local tile = g_map.getTile(position)
  if not tile then return nil end
  local items = tileItems(tile)
  if not items then return 0 end
  local total = 0
  for _, item in ipairs(items) do
    if safeItemId(item) == itemId then total = total + 1 end
  end
  return total
end

local function catchDistance(position)
  local player = g_game.getLocalPlayer()
  local playerPosition = player and player:getPosition() or nil
  return CorpseSelection.distance(playerPosition, position)
end

local function isWithinCatchRange(position)
  local distance = catchDistance(position)
  return distance ~= nil and distance <= CFG.MAX_CATCH_DISTANCE, distance
end

local function playerPosition()
  local player = g_game.getLocalPlayer()
  return player and player:getPosition() or nil
end

getInventoryItemCount = function(itemId)
  itemId = tonumber(itemId) or 0
  if itemId <= 0 then return 0 end
  if not g_game or not g_game.isOnline or not g_game.isOnline() then return 0 end
  local player = g_game.getLocalPlayer and g_game.getLocalPlayer()
  if not player then return 0 end
  local ok, count = pcall(function() return player:getItemCount(itemId) end)
  if ok and type(count) == 'number' then return count end
  return 0
end

local function ballAvailable(ballId)
  ballId = tonumber(ballId) or 0
  return ballId > 0 and getInventoryItemCount(ballId) > 0
end

-- ---------------------------------------------------------------------------
-- Configuracao
-- ---------------------------------------------------------------------------

local function rebuildCorpseIndexes()
  corpseBallIndex = CorpseTarget.buildBallIndex(corpseEntries)
  corpseEntryIndex = CorpseTarget.buildEntryIndex(corpseEntries)
end

local function resolveCorpseTarget(itemId)
  return CorpseTarget.resolveIndexed(itemId, corpseBallIndex)
end

local function hasConfiguredCorpseTarget()
  return next(corpseBallIndex) ~= nil
end

local function normalizeCorpseEntry(rawEntry, index)
  if type(rawEntry) ~= 'table' then return nil end
  local entryId = tonumber(rawEntry.id) or index
  if entryId <= 0 then entryId = index end
  nextCorpseEntryId = math.max(nextCorpseEntryId, entryId)
  return {
    id = entryId,
    name = string.format('Pokemon %d', index),
    ballId = math.max(0, tonumber(rawEntry.ballId) or 0),
    corpseId = math.max(0, tonumber(rawEntry.corpseId) or 0),
    enabled = rawEntry.enabled ~= false
  }
end

local function loadCorpseEntries()
  corpseEntries = {}
  nextCorpseEntryId = 0

  local raw = g_settings.getString(SETTINGS.CORPSE_ENTRIES, '')
  if raw ~= '' then
    local ok, decoded = pcall(function() return json.decode(raw) end)
    if ok and type(decoded) == 'table' then
      for index, rawEntry in ipairs(decoded) do
        local entry = normalizeCorpseEntry(rawEntry, index)
        if entry then table.insert(corpseEntries, entry) end
      end
    end
  end

  -- Migra os dois pares antigos (Ball 1/Corpo 1, Ball 2/Corpo 2) uma unica vez.
  if #corpseEntries == 0 then
    local legacy = {
      { ballId = g_settings.getNumber(SETTINGS.BALL1_ID, 0), corpseId = g_settings.getNumber(SETTINGS.CORPSE1_ID, 0) },
      { ballId = g_settings.getNumber(SETTINGS.BALL2_ID, 0), corpseId = g_settings.getNumber(SETTINGS.CORPSE2_ID, 0) }
    }
    if legacy[1].ballId <= 0 then legacy[1].ballId = g_settings.getNumber(SETTINGS.BALL_ID_LEGACY, 0) end
    if legacy[1].corpseId <= 0 then legacy[1].corpseId = g_settings.getNumber(SETTINGS.CORPSE_ID_LEGACY, 0) end
    for index, rawEntry in ipairs(legacy) do
      if rawEntry.ballId > 0 or rawEntry.corpseId > 0 then
        nextCorpseEntryId = nextCorpseEntryId + 1
        table.insert(corpseEntries, {
          id = nextCorpseEntryId,
          name = string.format('Pokemon %d', index),
          ballId = math.max(0, rawEntry.ballId),
          corpseId = math.max(0, rawEntry.corpseId),
          enabled = true
        })
      end
    end
  end

  rebuildCorpseIndexes()
end

local function loadSpecialBalls()
  shinyBallId = math.max(0, g_settings.getNumber(SETTINGS.SHINY_BALL_ID, 0))
  reserveBallId = math.max(0, g_settings.getNumber(SETTINGS.RESERVE_BALL_ID, 0))

  -- Migra a escolha antiga "Shiny usa a Ball do card 1/2" quando ela estava ativa.
  if shinyBallId <= 0 and g_settings.getBoolean(SETTINGS.CATCH_ALL_SHINY, false) then
    local choice = g_settings.getNumber(SETTINGS.SHINY_BALL_CHOICE, 1)
    local entry = corpseEntries[choice] or corpseEntries[1]
    if entry and (tonumber(entry.ballId) or 0) > 0 then
      shinyBallId = tonumber(entry.ballId)
      g_settings.set(SETTINGS.SHINY_BALL_ID, shinyBallId)
    end
  end
end

local function saveSettings()
  g_settings.set(SETTINGS.CORPSE_ENTRIES, json.encode(corpseEntries))
  g_settings.set(SETTINGS.SHINY_BALL_ID, shinyBallId)
  g_settings.set(SETTINGS.RESERVE_BALL_ID, reserveBallId)
  g_settings.set(SETTINGS.STAFF_GUARD, staffGuardEnabled)
  g_settings.set(SETTINGS.AUTO_REARM, autoRearmEnabled)
  g_settings.set(SETTINGS.CATCH_INTERVAL_MIN, catchIntervalMinimum)
  g_settings.set(SETTINGS.CATCH_INTERVAL_MAX, catchIntervalMaximum)

  local persistedAutoItems = {}
  for _, card in ipairs(autoItems) do
    table.insert(persistedAutoItems, {
      cardId = tonumber(card.cardId) or 0,
      itemId = tonumber(card.itemId) or 0,
      buffNames = card.buffNames or {},
      enabled = card.enabled == true,
      state = card.state or (#(card.buffNames or {}) > 0 and 'active' or 'learning')
    })
  end
  g_settings.set(SETTINGS.AUTO_ITEMS, json.encode(persistedAutoItems))
  g_settings.set(SETTINGS.AUTO_ITEM_NEXT_ID, nextAutoItemCardId)

  -- Espelho das chaves antigas (outros modulos podem le-las).
  local first = corpseEntries[1] or {}
  local second = corpseEntries[2] or {}
  g_settings.set(SETTINGS.BALL1_ID, tonumber(first.ballId) or 0)
  g_settings.set(SETTINGS.BALL2_ID, tonumber(second.ballId) or 0)
  g_settings.set(SETTINGS.CORPSE1_ID, tonumber(first.corpseId) or 0)
  g_settings.set(SETTINGS.CORPSE2_ID, tonumber(second.corpseId) or 0)
  g_settings.set(SETTINGS.BALL_ID_LEGACY, tonumber(first.ballId) or 0)
  g_settings.set(SETTINGS.CORPSE_ID_LEGACY, tonumber(first.corpseId) or 0)
  local firstAutoItem = autoItems[1] or {}
  g_settings.set(SETTINGS.AUTO_ITEM_ID, tonumber(firstAutoItem.itemId) or 0)
  g_settings.set(SETTINGS.AUTO_ITEM_ENABLED, firstAutoItem.enabled == true)
  g_settings.save()
end

-- ---------------------------------------------------------------------------
-- Status
-- ---------------------------------------------------------------------------

setStatus = function(text, color)
  if not ui.statusLabel then return end
  ui.statusLabel:setText(text)
  ui.statusLabel:setColor(color or '#b8b8b8')
end

updateStatsLine = function()
  if not ui.statsLine then return end
  local text = stats:summary()
  if staffHoldName then
    text = text .. ' | EM ESPERA: staff na tela'
  elseif pauseReason then
    text = text .. ' | PAUSADO: ' .. tostring(pauseReason)
  end
  ui.statsLine:setText(text)
end

local function configuredEntriesSummary()
  local configured, active = 0, 0
  for _, entry in ipairs(corpseEntries) do
    if (tonumber(entry.ballId) or 0) > 0 and (tonumber(entry.corpseId) or 0) > 0 then
      configured = configured + 1
      if entry.enabled ~= false then active = active + 1 end
    end
  end
  if active ~= configured then
    return string.format('%d/%d cards configurados (%d ativos)', configured, #corpseEntries, active)
  end
  return string.format('%d/%d cards configurados', configured, #corpseEntries)
end

-- ---------------------------------------------------------------------------
-- Cards de Pokemon (Ball + corpo)
-- ---------------------------------------------------------------------------

local function entryById(entryId)
  entryId = tonumber(entryId) or 0
  for _, entry in ipairs(corpseEntries) do
    if tonumber(entry.id) == entryId then return entry end
  end
  return nil
end

local function entryIndex(entry)
  for index, current in ipairs(corpseEntries) do
    if current == entry then return index end
  end
  return 0
end

local function renumberCorpseEntries()
  for index, entry in ipairs(corpseEntries) do
    entry.name = string.format('Pokemon %d', index)
  end
end

local function entryChanged(reasonWhenEnabled)
  rebuildCorpseIndexes()
  saveSettings()
  refreshCorpseEntries()
  if enabled and reasonWhenEnabled then setEnabled(false, reasonWhenEnabled) end
end

local function setEntryBall(entry, item)
  if not entry or not isItemThing(item) then
    setStatus('A Ball selecionada nao e um item valido.', '#ff7777')
    return false
  end
  local id = safeItemId(item) or 0
  if id <= 0 then
    setStatus('A Ball selecionada nao possui um ID valido.', '#ff7777')
    return false
  end
  entry.ballId = id
  entryChanged('Ball alterada; ative novamente para confirmar.')
  setStatus(string.format('%s configurado com a Ball ID %d.', entry.name, id), '#62d985')
  return true
end

local function setEntryCorpse(entry, item)
  if not entry or not isItemThing(item) then return false end
  local id = safeItemId(item) or 0
  if id <= 0 then return false end
  for _, other in ipairs(corpseEntries) do
    if other ~= entry and tonumber(other.corpseId) == id then
      setStatus(string.format('O corpo ID %d ja esta no %s.', id, other.name), '#ffcc66')
      return false
    end
  end
  entry.corpseId = id
  entryChanged('Corpo alterado; ative novamente para confirmar.')
  setStatus(string.format('Corpo do %s configurado: ID %d.', entry.name, id), '#62d985')
  return true
end

local function setEntryEnabled(entry, value)
  if not entry then return end
  entry.enabled = value == true
  rebuildCorpseIndexes()
  saveSettings()
  updateCorpseEntryRows()
  if enabled and not hasConfiguredCorpseTarget() then
    setEnabled(false, 'Nenhum card ativo; Auto Catch desativado.')
  else
    setStatus(string.format('%s %s.', entry.name, entry.enabled and 'ativado' or 'desativado'), entry.enabled and '#62d985' or '#b8b8b8')
  end
end

local function deleteEntry(entry)
  local index = entryIndex(entry)
  if index <= 0 then return false end
  local entryName = entry.name
  if enabled then setEnabled(false, 'Um card foi excluido; Auto Catch desativado.') end
  table.remove(corpseEntries, index)
  renumberCorpseEntries()
  entryChanged(nil)
  setStatus(string.format('%s excluido.', entryName), '#b8b8b8')
  return true
end

function addNewPokemon()
  nextCorpseEntryId = nextCorpseEntryId + 1
  local entry = {
    id = nextCorpseEntryId,
    name = string.format('Pokemon %d', #corpseEntries + 1),
    ballId = 0,
    corpseId = 0,
    enabled = true
  }
  table.insert(corpseEntries, entry)
  entryChanged(nil)
  setStatus(string.format('%s adicionado. Selecione a Ball e o corpo.', entry.name), '#62d985')
  return entry
end

local function setSlotItem(slot, itemId)
  if not slot then return end
  slot:setItem(nil)
  slot:setItemId(0)
  if itemId and itemId > 0 then
    local visual = Item.create(itemId, 1)
    if visual then slot:setItem(visual) else slot:setItemId(itemId) end
  end
  slot:setItemVisible(true)
  slot:setShowCount(false)
end

local function ballCountText(ballId)
  ballId = tonumber(ballId) or 0
  if ballId <= 0 then return '', '#9aaab5' end
  if not g_game.isOnline() then return '', '#dce9f2' end
  local count = getInventoryItemCount(ballId)
  if count <= 0 then return '  Qtd: 0 (SEM BALL)', '#ff7676' end
  if count <= CFG.LOW_BALL_WARNING then return string.format('  Qtd: %d (acabando)', count), '#ffcc66' end
  return string.format('  Qtd: %d', count), '#dce9f2'
end

local function wireButton(widget, onClickFunc)
  if not widget then return end
  widget.onClick = function()
    local ok, err = pcall(onClickFunc)
    if not ok then logWarn('erro em botao: ' .. tostring(err)) end
  end
  widget.onMouseRelease = function(self, mousePos, mouseButton)
    if mouseButton == MouseLeftButton then
      local ok, err = pcall(onClickFunc)
      if not ok then logWarn('erro em botao: ' .. tostring(err)) end
      return true
    end
  end
end

local function draggedItem(draggedWidget)
  if not draggedWidget then return nil end
  local item = draggedWidget.currentDragThing
  if not item and draggedWidget.getItem then
    local ok, value = pcall(function() return draggedWidget:getItem() end)
    if ok then item = value end
  end
  return isItemThing(item) and item or nil
end

-- Atualiza somente textos e contagens (sem recriar widgets).
local function updateCorpseEntryRow(row, entry, index)
  if not row or not entry then return end
  local nameLabel = row:recursiveGetChildById('pokemonLabel')
  local entryIndexLabel = row:recursiveGetChildById('entryIndex')
  local ballSlot = row:recursiveGetChildById('ballSlot')
  local ballInfo = row:recursiveGetChildById('ballInfo')
  local corpseInfo = row:recursiveGetChildById('corpseInfo')
  local enabledBox = row:recursiveGetChildById('entryEnabled')

  if nameLabel then nameLabel:setText(entry.name) end
  if entryIndexLabel then entryIndexLabel:setText(string.format('#%d', index)) end

  local ballId = tonumber(entry.ballId) or 0
  local corpseId = tonumber(entry.corpseId) or 0
  if ballSlot and row.shownBallId ~= ballId then
    setSlotItem(ballSlot, ballId)
    row.shownBallId = ballId
  end
  if ballInfo then
    local countText, countColor = ballCountText(ballId)
    ballInfo:setText(ballId > 0 and string.format('Ball ID: %d%s', ballId, countText) or 'Ball nao selecionada')
    ballInfo:setColor(ballId > 0 and countColor or '#9aaab5')
  end
  if corpseInfo then
    corpseInfo:setText(corpseId > 0 and string.format('Corpo ID: %d', corpseId) or 'Corpo nao selecionado')
    corpseInfo:setColor(corpseId > 0 and '#62d985' or '#9aaab5')
  end
  if enabledBox then
    updatingInterface = true
    enabledBox:setChecked(entry.enabled ~= false)
    updatingInterface = false
  end
end

local function wireCorpseEntryRow(row, entry)
  wireButton(row:recursiveGetChildById('selectBall'), function() startBallSelection(entry.id) end)
  wireButton(row:recursiveGetChildById('selectCorpse'), function() startCorpseSelection(entry.id) end)
  wireButton(row:recursiveGetChildById('deleteEntry'), function() deleteEntry(entry) end)

  local enabledBox = row:recursiveGetChildById('entryEnabled')
  if enabledBox then
    enabledBox.onCheckChange = function(_, checked)
      if not updatingInterface then setEntryEnabled(entry, checked) end
    end
  end

  local ballSlot = row:recursiveGetChildById('ballSlot')
  if ballSlot then
    ballSlot.onDrop = function(_, draggedWidget)
      local item = draggedItem(draggedWidget)
      local accepted = item ~= nil and setEntryBall(entry, item)
      if draggedWidget then draggedWidget.currentDragThing = nil end
      return accepted
    end
  end
end

refreshCorpseEntries = function()
  local root = ui.panel or ui.window
  if root and not ui.entriesList then ui.entriesList = root:recursiveGetChildById('entriesList') end
  if not ui.entriesList then return end

  ui.entriesList:destroyChildren()
  entryRows = {}
  for index, entry in ipairs(corpseEntries) do
    local row = g_ui.createWidget('AutoCatchEntryRow', ui.entriesList)
    entryRows[entry.id] = row
    wireCorpseEntryRow(row, entry)
    updateCorpseEntryRow(row, entry, index)
  end

  if ui.entriesEmpty then ui.entriesEmpty:setVisible(#corpseEntries == 0) end
  if ui.entriesCountHint then
    ui.entriesCountHint:setText(string.format('%s. A captura usa somente o ID do corpo.', configuredEntriesSummary()))
  end
  refreshSpecialBalls()
end

updateCorpseEntryRows = function()
  if not ui.entriesList then return end
  for index, entry in ipairs(corpseEntries) do
    local row = entryRows[entry.id]
    if row then updateCorpseEntryRow(row, entry, index) end
  end
  if ui.entriesCountHint then
    ui.entriesCountHint:setText(string.format('%s. A captura usa somente o ID do corpo.', configuredEntriesSummary()))
  end
  refreshSpecialBalls()
end

-- ---------------------------------------------------------------------------
-- Ball para Shiny e Ball reserva
-- ---------------------------------------------------------------------------

refreshSpecialBalls = function()
  if ui.shinyBallSlot and ui.shownShinyBallId ~= shinyBallId then
    setSlotItem(ui.shinyBallSlot, shinyBallId)
    ui.shownShinyBallId = shinyBallId
  end
  if ui.shinyBallInfo then
    local countText, countColor = ballCountText(shinyBallId)
    ui.shinyBallInfo:setText(shinyBallId > 0 and string.format('ID %d%s', shinyBallId, countText) or 'Nao configurada (usa a Ball do card)')
    ui.shinyBallInfo:setColor(shinyBallId > 0 and countColor or '#9aaab5')
  end
  if ui.reserveBallSlot and ui.shownReserveBallId ~= reserveBallId then
    setSlotItem(ui.reserveBallSlot, reserveBallId)
    ui.shownReserveBallId = reserveBallId
  end
  if ui.reserveBallInfo then
    local countText, countColor = ballCountText(reserveBallId)
    ui.reserveBallInfo:setText(reserveBallId > 0 and string.format('ID %d%s', reserveBallId, countText) or 'Nao configurada (corpo e ignorado sem Ball)')
    ui.reserveBallInfo:setColor(reserveBallId > 0 and countColor or '#9aaab5')
  end
end

local function setShinyBall(item)
  local id = safeItemId(item) or 0
  if id <= 0 then
    setStatus('A Ball selecionada nao e um item valido.', '#ff7777')
    return false
  end
  shinyBallId = id
  saveSettings()
  refreshSpecialBalls()
  setStatus(string.format('Shinys passam a usar a Ball ID %d.', id), '#62d985')
  return true
end

local function clearShinyBall()
  shinyBallId = 0
  saveSettings()
  refreshSpecialBalls()
  setStatus('Ball para Shiny removida; shinys usam a Ball do card.', '#b8b8b8')
end

local function setReserveBall(item)
  local id = safeItemId(item) or 0
  if id <= 0 then
    setStatus('A Ball selecionada nao e um item valido.', '#ff7777')
    return false
  end
  reserveBallId = id
  saveSettings()
  refreshSpecialBalls()
  setStatus(string.format('Ball reserva configurada: ID %d (usada quando a Ball do card acabar).', id), '#62d985')
  return true
end

local function clearReserveBall()
  reserveBallId = 0
  saveSettings()
  refreshSpecialBalls()
  setStatus('Ball reserva removida.', '#b8b8b8')
end

-- ---------------------------------------------------------------------------
-- Selecao com o mouse (corpo no mapa / item na mochila)
-- ---------------------------------------------------------------------------

local function restoreWindowAfterSelection()
  if ui.window then
    ui.window:show()
    ui.window:raise()
    ui.window:focus()
  end
end

local function finishGrabber(grabber)
  if not grabber then return end
  g_mouse.popCursor('target')
  grabber:ungrabMouse()
  if grabber == corpseSelectGrabber then corpseSelectGrabber = nil end
  if grabber == inventorySelectGrabber then inventorySelectGrabber = nil end
  grabber:destroy()
end

local function cancelSelections()
  if corpseSelectGrabber then finishGrabber(corpseSelectGrabber) end
  if inventorySelectGrabber then finishGrabber(inventorySelectGrabber) end
  selectingCorpseEntryId = nil
end

local function onSelectCorpseRelease(grabber, mousePosition, mouseButton)
  local selectedItem = nil
  if mouseButton == MouseLeftButton or mouseButton == MouseRightButton then
    local rootPanel = modules.game_interface.getRootPanel()
    local clickedWidget = rootPanel and rootPanel:recursiveGetChildByPos(mousePosition, false) or nil
    if clickedWidget and clickedWidget:getClassName() == 'UIGameMap' then
      local tile = clickedWidget:getTile(mousePosition)
      local thing = tile and tile:getTopUseThing() or nil
      if thing and thing:isItem() and not thing:isGround() then selectedItem = thing end
    end
  end

  local entry = entryById(selectingCorpseEntryId)
  finishGrabber(grabber)
  restoreWindowAfterSelection()
  if selectedItem and entry then
    setEntryCorpse(entry, selectedItem)
  else
    setStatus('Nenhum corpo valido selecionado. Clique diretamente no corpo no mapa.', '#ffcc66')
  end
  selectingCorpseEntryId = nil
  return true
end

function startCorpseSelection(entryId)
  if g_ui.isMouseGrabbed() then
    setStatus('Finalize a acao atual do mouse antes de selecionar o corpo.', '#ffcc66')
    return
  end
  if not entryById(entryId) then return end
  selectingCorpseEntryId = entryId
  if enabled then setEnabled(false, 'Auto Catch pausado para selecionar o corpo.') end
  if ui.window then ui.window:hide() end

  corpseSelectGrabber = g_ui.createWidget('UIWidget')
  corpseSelectGrabber:setVisible(false)
  corpseSelectGrabber:setFocusable(false)
  corpseSelectGrabber.onMouseRelease = onSelectCorpseRelease
  corpseSelectGrabber:grabMouse()
  g_mouse.pushCursor('target')
end

local function itemFromInventoryClick(mousePosition)
  local rootPanel = modules.game_interface.getRootPanel()
  local clickedWidget = rootPanel and rootPanel:recursiveGetChildByPos(mousePosition, false) or nil
  local current = clickedWidget
  while current do
    local className = current:getClassName()
    if className == 'UIGameMap' then
      local tile = current:getTile(mousePosition)
      local thing = tile and tile:getTopMoveThing() or nil
      return isItemThing(thing) and thing or nil
    elseif className == 'UIItem' and not current:isVirtual() then
      local item = current:getItem()
      return isItemThing(item) and item or nil
    end
    current = current:getParent()
  end
  return nil
end

-- onSelected(item) recebe o item clicado; onEmpty() e chamado sem item.
startInventorySelection = function(onSelected, onEmpty, pauseMessage)
  if g_ui.isMouseGrabbed() then
    setStatus('Finalize a acao atual do mouse antes de selecionar o item.', '#ffcc66')
    return false
  end
  if enabled and pauseMessage then setEnabled(false, pauseMessage) end
  if ui.window then ui.window:hide() end

  inventorySelectGrabber = g_ui.createWidget('UIWidget')
  inventorySelectGrabber:setVisible(false)
  inventorySelectGrabber:setFocusable(false)
  inventorySelectGrabber.onMouseRelease = function(grabber, mousePosition, mouseButton)
    local selectedItem = mouseButton == MouseLeftButton and itemFromInventoryClick(mousePosition) or nil
    finishGrabber(grabber)
    restoreWindowAfterSelection()
    if selectedItem then
      onSelected(selectedItem)
    elseif onEmpty then
      onEmpty()
    end
    return true
  end
  inventorySelectGrabber:grabMouse()
  g_mouse.pushCursor('target')
  return true
end

startBallSelection = function(entryId)
  local entry = entryById(entryId)
  if not entry then return end
  startInventorySelection(function(item)
    setEntryBall(entry, item)
  end, function()
    setStatus('Nenhuma Ball valida selecionada. Clique em um item da mochila.', '#ffcc66')
  end, 'Auto Catch pausado para selecionar a Ball.')
end

local function startShinyBallSelection()
  startInventorySelection(setShinyBall, function()
    setStatus('Nenhuma Ball valida selecionada. Clique em um item da mochila.', '#ffcc66')
  end, 'Auto Catch pausado para selecionar a Ball de Shiny.')
end

local function startReserveBallSelection()
  startInventorySelection(setReserveBall, function()
    setStatus('Nenhuma Ball valida selecionada. Clique em um item da mochila.', '#ffcc66')
  end, 'Auto Catch pausado para selecionar a Ball reserva.')
end

-- ---------------------------------------------------------------------------
-- Auto Item (renova itens de buff quando o buff termina)
-- ---------------------------------------------------------------------------

local loadAutoItems, stopAutoItemTimer, hasEnabledAutoItems, startAutoItemTimer, onAutoItemBuffsReceived, resetAutoItemRuntimeState

do

local function getLegacyActionBarItemId(slotIndex)
  if not slotIndex or slotIndex <= 0 then return nil end
  if modules.game_playeractionbar and modules.game_playeractionbar.getSlotInfo then
    local info = modules.game_playeractionbar.getSlotInfo(slotIndex)
    if info and info.itemId then return AutoItem.normalizeId(info.itemId) end
  end
  local rootPanel = modules.game_interface and modules.game_interface.getRootPanel()
  local slot = rootPanel and rootPanel:recursiveGetChildById('ACTION_BAR_' .. slotIndex)
  if slot and slot.item and slot.item.getItemId then
    return AutoItem.normalizeId(slot.item:getItemId())
  end
  return 0
end

local function autoItemByCardId(cardId)
  cardId = tonumber(cardId) or 0
  for _, card in ipairs(autoItems) do
    if tonumber(card.cardId) == cardId then return card end
  end
  return nil
end

local function normalizeAutoItemBuffNames(rawNames)
  local names, seen = {}, {}
  if type(rawNames) ~= 'table' then return names end
  for key, value in pairs(rawNames) do
    local name = nil
    if type(value) == 'string' then name = value
    elseif value == true and type(key) == 'string' then name = key end
    if name and name ~= '' and not seen[name] then
      seen[name] = true
      table.insert(names, name)
    end
  end
  table.sort(names)
  return names
end

local function resetAutoItemRuntime(card)
  card.pending = false
  card.retryAt = 0
  card.learningBefore = nil
  card.learningBeforeItemCount = nil
  card.learningStartedAt = 0
  card.learningAttempts = 0
end

local function normalizeAutoItemEntry(rawEntry, fallbackCardId)
  if type(rawEntry) ~= 'table' then return nil end
  local cardId = tonumber(rawEntry.cardId) or tonumber(fallbackCardId) or 0
  if cardId <= 0 then return nil end
  local buffNames = normalizeAutoItemBuffNames(rawEntry.buffNames or rawEntry.buffs)
  if #buffNames == 0 and type(rawEntry.buffName) == 'string' and rawEntry.buffName ~= '' then
    buffNames = { rawEntry.buffName }
  end
  local card = {
    cardId = cardId,
    itemId = AutoItem.normalizeId(rawEntry.itemId),
    buffNames = buffNames,
    enabled = rawEntry.enabled == true,
    state = #buffNames > 0 and 'active' or 'learning'
  }
  resetAutoItemRuntime(card)
  return card
end

loadAutoItems = function()
  autoItems = {}
  nextAutoItemCardId = g_settings.getNumber(SETTINGS.AUTO_ITEM_NEXT_ID, 0)
  local migrated = false

  local raw = g_settings.getString(SETTINGS.AUTO_ITEMS, '')
  if raw ~= '' then
    local ok, decoded = pcall(function() return json.decode(raw) end)
    if ok and type(decoded) == 'table' then
      for index, rawEntry in ipairs(decoded) do
        local card = normalizeAutoItemEntry(rawEntry, index)
        if card then
          table.insert(autoItems, card)
          nextAutoItemCardId = math.max(nextAutoItemCardId, card.cardId)
        end
      end
    end
  end

  if #autoItems == 0 then
    local legacyItemId = AutoItem.normalizeId(g_settings.getNumber(SETTINGS.AUTO_ITEM_ID, 0))
    if legacyItemId <= 0 then
      local legacySlot = g_settings.getNumber(SETTINGS.AUTO_ACTION_SLOT, 0)
      legacyItemId = AutoItem.normalizeId(getLegacyActionBarItemId(legacySlot))
    end
    if legacyItemId > 0 then
      nextAutoItemCardId = math.max(nextAutoItemCardId, 1)
      local card = {
        cardId = 1,
        itemId = legacyItemId,
        buffNames = {},
        enabled = g_settings.getBoolean(SETTINGS.AUTO_ITEM_ENABLED, false),
        state = 'learning'
      }
      resetAutoItemRuntime(card)
      table.insert(autoItems, card)
      migrated = true
    end
  end

  if migrated then saveSettings() end
end

local function getCurrentAutoItemBuffSnapshot()
  if modules.game_buffs and type(modules.game_buffs.getBuffSnapshot) == 'function' then
    local ok, snapshot = pcall(modules.game_buffs.getBuffSnapshot)
    if ok and snapshot ~= nil then return snapshot, true end
  end
  return autoItemBuffSnapshot, autoItemBuffSnapshot ~= nil
end

local function getAutoItemBuffRemainingMs(buffName)
  local snapshot, ready = getCurrentAutoItemBuffSnapshot()
  if not ready then return nil, false end
  if modules.game_buffs and type(modules.game_buffs.getBuffRemainingMs) == 'function' then
    local ok, remaining = pcall(modules.game_buffs.getBuffRemainingMs, buffName)
    if ok and type(remaining) == 'number' then return math.max(0, remaining), true end
  end
  return AutoItem.snapshotRemainingMs(snapshot[buffName], now()), true
end

local function getAutoItemCardRemainingMs(card)
  local maximum = 0
  for _, buffName in ipairs(card.buffNames or {}) do
    local remaining, ready = getAutoItemBuffRemainingMs(buffName)
    if not ready then return nil, false end
    maximum = math.max(maximum, remaining or 0)
  end
  return maximum, true
end

local function formatAutoItemBuffNames(card)
  if not card.buffNames or #card.buffNames == 0 then return 'Buff: descobrindo...' end
  return 'Buff: ' .. table.concat(card.buffNames, ', ')
end

local function autoItemStatusText(card)
  if card.itemId <= 0 then return 'Item nao selecionado' end
  if card.state == 'failed' then return 'Buff nao identificado; card pausado' end
  if #card.buffNames == 0 then
    if card.pending then return 'Usando item e aguardando o icone...' end
    return string.format('Buff ainda nao identificado (%d/%d usos)', card.learningAttempts or 0, CFG.AUTO_ITEM_MAX_LEARNING_ATTEMPTS)
  end
  local remaining, ready = getAutoItemCardRemainingMs(card)
  if not ready then return 'Aguardando estado de buffs do servidor...' end
  if remaining > 0 then return 'Restante: ' .. timeFormat(remaining / 1000) end
  if card.pending then return 'Aguardando renovacao...' end
  if (card.retryAt or 0) > now() then return 'Item ausente; nova tentativa em breve' end
  return 'Buff encerrado; renovando...'
end

local function updateAutoItemRowVisual(row, card, index)
  if not row or not card then return end
  local itemLabel = row:recursiveGetChildById('autoItemLabel')
  local itemIndex = row:recursiveGetChildById('autoItemIndex')
  local itemSlot = row:recursiveGetChildById('itemSlot')
  local itemInfo = row:recursiveGetChildById('itemInfo')
  local buffInfo = row:recursiveGetChildById('buffInfo')
  local timerInfo = row:recursiveGetChildById('timerInfo')
  local enabledBox = row:recursiveGetChildById('itemEnabled')

  if itemLabel then itemLabel:setText(string.format('Item %d', card.cardId)) end
  if itemIndex then itemIndex:setText(string.format('#%d', index)) end
  if itemSlot and row.shownItemId ~= card.itemId then
    setSlotItem(itemSlot, card.itemId)
    row.shownItemId = card.itemId
  end
  if itemInfo then
    itemInfo:setText(card.itemId > 0 and string.format('Item ID %d', card.itemId) or 'Item nao selecionado')
    itemInfo:setColor(card.itemId > 0 and '#fde68a' or '#a39882')
  end
  if buffInfo then
    buffInfo:setText(formatAutoItemBuffNames(card))
    buffInfo:setColor(#card.buffNames > 0 and '#b8d8eb' or '#a39882')
  end
  if timerInfo then
    timerInfo:setText(card.enabled and autoItemStatusText(card) or 'Desativado')
    timerInfo:setColor(card.enabled and (card.state == 'failed' and '#ff7676' or '#38bdf8') or '#778899')
  end
  if enabledBox then
    updatingAutoItemInterface = true
    enabledBox:setChecked(card.enabled == true)
    updatingAutoItemInterface = false
  end
end

stopAutoItemTimer = function()
  if autoItemTimerEvent then
    removeEvent(autoItemTimerEvent)
    autoItemTimerEvent = nil
  end
end

hasEnabledAutoItems = function()
  for _, card in ipairs(autoItems) do
    if card.enabled and card.itemId > 0 then return true end
  end
  return false
end

startAutoItemTimer = function()
  stopAutoItemTimer()
  if updateAutoItemLoop and hasEnabledAutoItems() then
    autoItemTimerEvent = cycleEvent(updateAutoItemLoop, 1000)
  end
end

local function scheduleAutoItemRetry(card, message, delay)
  card.pending = false
  card.retryAt = now() + (delay or CFG.AUTO_ITEM_RETRY_MS)
  card.learningBefore = nil
  card.learningBeforeItemCount = nil
  card.learningStartedAt = 0
  card.state = #card.buffNames > 0 and 'waiting' or 'learning'
  if message then
    logInfo(message)
    setStatus(message, '#ffcc66')
  end
end

local function failAutoItemLearning(card)
  card.enabled = false
  card.state = 'failed'
  card.pending = false
  card.retryAt = 0
  if autoItemLearningCardId == card.cardId then autoItemLearningCardId = nil end
  saveSettings()
  refreshAutoItemEntries()
  if not hasEnabledAutoItems() then stopAutoItemTimer() end
  local message = string.format('[Auto Item] Item ID %d foi usado %d vezes sem nenhum buff novo aparecer; card desativado para nao gastar o item.',
    card.itemId, CFG.AUTO_ITEM_MAX_LEARNING_ATTEMPTS)
  logWarn(message)
  setStatus(message, '#ff7676')
end

local function dispatchAutoItem(card)
  if getInventoryItemCount(card.itemId) <= 0 then
    scheduleAutoItemRetry(card, string.format('[Auto Item] Item ID %d nao encontrado na mochila. Nova tentativa em %ds.',
      card.itemId, math.floor(CFG.AUTO_ITEM_MISSING_BACKOFF_MS / 1000)), CFG.AUTO_ITEM_MISSING_BACKOFF_MS)
    return false
  end

  local currentTime = now()
  if #card.buffNames == 0 then
    if (card.learningAttempts or 0) >= CFG.AUTO_ITEM_MAX_LEARNING_ATTEMPTS then
      failAutoItemLearning(card)
      return false
    end
    local before, ready = getCurrentAutoItemBuffSnapshot()
    if not ready then
      card.retryAt = currentTime + 1000
      card.state = 'waiting-buffs'
      return false
    end
    autoItemLearningCardId = card.cardId
    card.learningBefore = before
    card.learningBeforeItemCount = getInventoryItemCount(card.itemId)
    card.learningStartedAt = currentTime
    card.learningAttempts = (card.learningAttempts or 0) + 1
  end

  local okExec, errorMessage = AutoItem.dispatch(card.itemId, g_game)
  if not okExec then
    if autoItemLearningCardId == card.cardId then autoItemLearningCardId = nil end
    scheduleAutoItemRetry(card, string.format('[Auto Item] Falha ao usar item ID %d (%s). Tentando em 15s.',
      card.itemId, tostring(errorMessage or 'erro desconhecido')))
    return false
  end

  card.pending = true
  card.retryAt = currentTime + CFG.AUTO_ITEM_RETRY_MS
  card.state = #card.buffNames > 0 and 'waiting' or 'learning'
  local message = #card.buffNames > 0 and
    string.format('[Auto Item] Card %d (item ID %d) enviado; aguardando o buff terminar/atualizar.', card.cardId, card.itemId) or
    string.format('[Auto Item] Card %d (item ID %d) usado; aprendendo o buff correspondente (%d/%d).',
      card.cardId, card.itemId, card.learningAttempts or 0, CFG.AUTO_ITEM_MAX_LEARNING_ATTEMPTS)
  logInfo(message)
  setStatus(message, '#62d985')
  return true
end

local function assignAutoItem(card, itemOrId)
  local itemId = AutoItem.normalizeId(itemOrId)
  if not card or itemId <= 0 then
    setStatus('Item invalido. Arraste um item real da mochila.', '#ff7777')
    return false
  end
  if autoItemLearningCardId == card.cardId then autoItemLearningCardId = nil end
  card.itemId = itemId
  card.buffNames = {}
  card.state = 'learning'
  resetAutoItemRuntime(card)
  saveSettings()
  refreshAutoItemEntries()
  setStatus(string.format('Item %d configurado para o item ID %d. O buff sera aprendido ao ativar.', card.cardId, itemId), '#62d985')
  if card.enabled then startAutoItemTimer() end
  return true
end

local function onDropAutoItem(card, draggedWidget)
  if not draggedWidget or not draggedWidget.getClassName or draggedWidget:getClassName() ~= 'UIItem' then
    setStatus('Arraste um item diretamente da mochila.', '#ffcc66')
    return false
  end
  if draggedWidget.isVirtual and draggedWidget:isVirtual() then
    setStatus('O item precisa vir de uma mochila aberta.', '#ffcc66')
    return false
  end
  local selectedItem = draggedItem(draggedWidget)
  if not selectedItem then
    setStatus('Nenhum item valido foi arrastado da mochila.', '#ffcc66')
    return false
  end
  local accepted = assignAutoItem(card, selectedItem)
  draggedWidget.currentDragThing = nil
  return accepted
end

local function wireAutoItemRow(row, card)
  wireButton(row:recursiveGetChildById('selectItem'), function() startAutoItemSelection(card.cardId) end)
  wireButton(row:recursiveGetChildById('deleteItem'), function() deleteAutoItem(card) end)
  local enabledBox = row:recursiveGetChildById('itemEnabled')
  if enabledBox then
    enabledBox.onCheckChange = function(_, checked)
      if not updatingAutoItemInterface then setAutoItemEnabled(card, checked) end
    end
  end
  local itemSlot = row:recursiveGetChildById('itemSlot')
  if itemSlot then
    itemSlot.onDrop = function(_, draggedWidget) return onDropAutoItem(card, draggedWidget) end
  end
end

refreshAutoItemEntries = function()
  local root = ui.panel or ui.window
  if root and not ui.autoItemsList then ui.autoItemsList = root:recursiveGetChildById('autoItemsList') end
  if not ui.autoItemsList then return end

  ui.autoItemsList:destroyChildren()
  for index, card in ipairs(autoItems) do
    local row = g_ui.createWidget('AutoCatchAutoItemRow', ui.autoItemsList)
    wireAutoItemRow(row, card)
    updateAutoItemRowVisual(row, card, index)
  end
  if ui.autoItemsEmpty then ui.autoItemsEmpty:setVisible(#autoItems == 0) end
  if ui.autoItemsCountHint then
    ui.autoItemsCountHint:setText(string.format('%d item(ns). Cada card renova pelo tempo real do buff.', #autoItems))
  end
end

refreshAutoItemRows = function()
  if not ui.autoItemsList then return end
  local children = ui.autoItemsList:getChildren()
  for index, row in ipairs(children) do
    updateAutoItemRowVisual(row, autoItems[index], index)
  end
end

function startAutoItemSelection(cardId)
  local card = autoItemByCardId(cardId) or autoItems[1]
  if not card then
    setStatus('Adicione um card de item antes de selecionar.', '#ffcc66')
    return
  end
  startInventorySelection(function(item)
    assignAutoItem(card, item)
  end, function()
    setStatus('Nenhum item valido selecionado. Clique em um item da mochila.', '#ffcc66')
  end, nil)
end

deleteAutoItem = function(card)
  if not card then return false end
  for index, current in ipairs(autoItems) do
    if current == card then
      if autoItemLearningCardId == card.cardId then autoItemLearningCardId = nil end
      table.remove(autoItems, index)
      saveSettings()
      refreshAutoItemEntries()
      if not hasEnabledAutoItems() then stopAutoItemTimer() else startAutoItemTimer() end
      setStatus(string.format('Item %d excluido.', card.cardId), '#b8b8b8')
      return true
    end
  end
  return false
end

function clearAutoItem(cardId)
  local card = autoItemByCardId(cardId) or autoItems[1]
  if not card then return false end
  card.itemId = 0
  card.buffNames = {}
  card.enabled = false
  card.state = 'learning'
  resetAutoItemRuntime(card)
  if autoItemLearningCardId == card.cardId then autoItemLearningCardId = nil end
  saveSettings()
  refreshAutoItemEntries()
  if not hasEnabledAutoItems() then stopAutoItemTimer() end
  setStatus(string.format('Item %d desconfigurado.', card.cardId), '#b8b8b8')
  return true
end

setAutoItemEnabled = function(card, value)
  value = value == true
  if not card then return end
  if value and card.itemId <= 0 then
    card.enabled = false
    setStatus('Configure um item da mochila antes de ativar o card.', '#ffcc66')
    refreshAutoItemEntries()
    return
  end
  if value and not g_game.isOnline() then
    card.enabled = false
    setStatus('Entre no jogo antes de ativar o Auto Item.', '#ffcc66')
    refreshAutoItemEntries()
    return
  end

  card.enabled = value
  resetAutoItemRuntime(card)
  if not value and autoItemLearningCardId == card.cardId then autoItemLearningCardId = nil end
  card.state = #card.buffNames > 0 and 'active' or 'learning'
  saveSettings()
  refreshAutoItemEntries()
  if value then
    startAutoItemTimer()
    setStatus(string.format('Item %d ativado; renovara somente quando o buff terminar.', card.cardId), '#62d985')
  else
    if not hasEnabledAutoItems() then stopAutoItemTimer() end
    setStatus(string.format('Item %d desativado.', card.cardId), '#b8b8b8')
  end
end

function addNewAutoItem()
  nextAutoItemCardId = nextAutoItemCardId + 1
  local card = {
    cardId = nextAutoItemCardId,
    itemId = 0,
    buffNames = {},
    enabled = false,
    state = 'learning'
  }
  resetAutoItemRuntime(card)
  table.insert(autoItems, card)
  saveSettings()
  refreshAutoItemEntries()
  setStatus(string.format('Item %d adicionado. Selecione o item da mochila.', nextAutoItemCardId), '#62d985')
end

onAutoItemBuffsReceived = function(buffs)
  autoItemBuffSnapshot = AutoItem.makeBuffSnapshot(buffs, now())

  local learningCard = autoItemByCardId(autoItemLearningCardId)
  if learningCard and learningCard.pending and learningCard.learningBefore then
    local changed = AutoItem.changedBuffNames(learningCard.learningBefore, autoItemBuffSnapshot, now())
    local currentItemCount = getInventoryItemCount(learningCard.itemId)
    local consumed = AutoItem.wasItemConsumed(learningCard.learningBeforeItemCount, currentItemCount)
    if #changed > 0 and consumed then
      learningCard.buffNames = changed
      learningCard.state = 'active'
      resetAutoItemRuntime(learningCard)
      autoItemLearningCardId = nil
      saveSettings()
      local linkedMessage = string.format('Item %d vinculado ao buff: %s.', learningCard.cardId, table.concat(changed, ', '))
      logInfo('[Auto Item] ' .. linkedMessage)
      setStatus(linkedMessage, '#62d985')
    elseif #changed > 0 then
      logInfo(string.format('[Auto Item] Mudanca de buff ignorada para o card %d: o item ID %d nao foi consumido neste envio.',
        learningCard.cardId, learningCard.itemId))
    end
  end
  refreshAutoItemRows()
end

resetAutoItemRuntimeState = function()
  autoItemBuffSnapshot = nil
  autoItemLearningCardId = nil
  for _, card in ipairs(autoItems) do resetAutoItemRuntime(card) end
end

updateAutoItemLoop = function()
  if not g_game.isOnline() then
    refreshAutoItemRows()
    return
  end

  local currentTime = now()
  for _, card in ipairs(autoItems) do
    if card.enabled and card.itemId > 0 and card.state ~= 'failed' then
      local remaining, ready = getAutoItemCardRemainingMs(card)
      if not ready then
        -- O servidor ainda nao enviou a lista inicial de buffs deste login.
      elseif card.pending then
        if #card.buffNames > 0 and remaining > 0 then
          card.pending = false
          card.retryAt = 0
          card.state = 'active'
        elseif currentTime >= (card.retryAt or 0) then
          card.pending = false
          if autoItemLearningCardId == card.cardId then autoItemLearningCardId = nil end
          if not autoItemLearningCardId then dispatchAutoItem(card) end
        end
      elseif autoItemLearningCardId and autoItemLearningCardId ~= card.cardId then
        -- O aprendizado e serializado para nao atribuir o buff de outro item.
      elseif #card.buffNames == 0 then
        if currentTime >= (card.retryAt or 0) then dispatchAutoItem(card) end
      elseif remaining <= 0 and currentTime >= (card.retryAt or 0) then
        dispatchAutoItem(card)
      else
        card.state = 'active'
      end
    end
  end
  refreshAutoItemRows()
end

end -- Auto Item

-- ---------------------------------------------------------------------------
-- Staff na tela / pausa
-- ---------------------------------------------------------------------------

-- Nome do staff visivel (ou nil). Consulta o estado do CaveBot quando ele
-- existe e, sempre, as criaturas ao redor do personagem. Cache de 500 ms.
function findVisibleStaff()
  local currentTime = now()
  if currentTime - staffCache.at < CFG.STAFF_CHECK_CACHE_MS then return staffCache.name end
  staffCache.at = currentTime
  staffCache.name = nil

  local cavebot = modules.game_cavebot_pka
  if cavebot and type(cavebot.getBotState) == 'function' then
    local ok, state = pcall(cavebot.getBotState)
    if ok and (state == 'PAUSED_STAFF' or state == 'PAUSED_PLAYER') then
      staffCache.name = 'CaveBot em pausa por staff/jogador'
      return staffCache.name
    end
  end

  local position = playerPosition()
  if not position or not g_map or type(g_map.getSpectators) ~= 'function' then return nil end
  local ok, spectators = pcall(function() return g_map.getSpectators(position, false) end)
  if ok and type(spectators) == 'table' then
    staffCache.name = StaffGuard.findStaff(spectators)
  end
  return staffCache.name
end

local function isHeld()
  return pauseReason ~= nil or staffHoldName ~= nil
end

local function releaseQueuedJobs()
  for _, job in ipairs(catchQueue) do
    corpseClaims:release(job.position, job.itemId)
  end
  catchQueue = {}
  queuedKeys = {}
  activeCatchJob = nil
  if catchQueueEvent then
    catchQueueEvent:cancel()
    catchQueueEvent = nil
  end
end

local function holdForStaff(name)
  if staffHoldName then return end
  staffHoldName = name
  releaseQueuedJobs()
  logWarn(string.format('Staff detectado (%s); Auto Catch em espera.', tostring(name)))
  setStatus(string.format('Staff na tela (%s). Lancamentos em espera.', tostring(name)), '#ff7676')
  updateStatsLine()
end

local function releaseStaffHold()
  if not staffHoldName then return end
  logInfo('Staff saiu da tela; Auto Catch retomado.')
  staffHoldName = nil
  setStatus('Staff saiu da tela; captura retomada.', '#62d985')
  updateStatsLine()
end

-- Verifica staff e atualiza o estado de espera. Devolve true quando pode lancar.
local function updateStaffHold()
  if not staffGuardEnabled then
    if staffHoldName then releaseStaffHold() end
    return true
  end
  local name = findVisibleStaff()
  if name then
    holdForStaff(name)
    return false
  end
  if staffHoldName then releaseStaffHold() end
  return true
end

function pause(reason)
  pauseReason = tostring(reason or 'pausado externamente')
  releaseQueuedJobs()
  setStatus('Auto Catch pausado: ' .. pauseReason, '#ffcc66')
  updateStatsLine()
end

function resume()
  if not pauseReason then return end
  pauseReason = nil
  setStatus('Auto Catch retomado.', '#62d985')
  updateStatsLine()
end

function isPaused()
  return pauseReason ~= nil
end

-- ---------------------------------------------------------------------------
-- Claims (corpos ja tratados)
-- ---------------------------------------------------------------------------

local function cleanupClaimedCorpses()
  corpseClaims:cleanup(countMatchingItemsAt)
end

local function corpseKey(position, itemId)
  return CorpseClaim.key(position, itemId)
end

-- ---------------------------------------------------------------------------
-- Rastreio de monstros vivos
-- ---------------------------------------------------------------------------

local enqueueCatch
local isCreatureShiny, isWildMonster, creatureToken, rememberTarget, pruneObservedTargets, scheduleCorpseSearch
local noteShinyDeath, wasShinyDeathNear

do

local shinyOutfitCache = { at = 0, set = {} }

local function knownShinyLookTypes()
  local currentTime = now()
  if currentTime - shinyOutfitCache.at < 5000 then return shinyOutfitCache.set end
  shinyOutfitCache.at = currentTime
  local set = {}
  local cavebot = modules.game_cavebot_pka
  if cavebot and type(cavebot.listShinyOutfits) == 'function' then
    local ok, list = pcall(cavebot.listShinyOutfits)
    if ok and type(list) == 'table' then
      for lookType, _ in pairs(list) do
        local id = tonumber(lookType)
        if id and id > 0 then set[id] = true end
      end
    end
  end
  shinyOutfitCache.set = set
  return set
end

isCreatureShiny = function(creature)
  if not creature then return false end
  local okName, name = pcall(function() return creature:getName() end)
  if okName and type(name) == 'string' and trim(name):lower():match('^shiny%s+') then return true end
  local okShiny, isSh = pcall(function() return creature.isShiny and creature:isShiny() end)
  if okShiny and isSh == true then return true end
  local okIcon, icon = pcall(function() return creature.getShinyIcon and creature:getShinyIcon() end)
  if okIcon and (icon == 1 or icon == true) then return true end
  local okOutfit, outfit = pcall(function() return creature:getOutfit() end)
  if okOutfit and type(outfit) == 'table' then
    local lookType = tonumber(outfit.type or outfit.lookType) or 0
    if lookType > 0 and knownShinyLookTypes()[lookType] then return true end
  end
  return false
end

isWildMonster = function(creature)
  if not creature then return false end
  local okType, cType = pcall(function() return creature:getType() end)
  if okType and cType then
    if cType == 3 or cType == 4 or cType == (CreatureTypeSummonOwn or 3) or cType == (CreatureTypeSummonOther or 4) then
      return false
    end
    if cType == 0 or cType == (CreatureTypePlayer or 0) or cType == 2 or cType == (CreatureTypeNpc or 2) then
      return false
    end
  end
  local okPlayer, isPlay = pcall(function() return creature:isPlayer() end)
  if okPlayer and isPlay then return false end
  local okNpc, isNpc = pcall(function() return creature:isNpc() end)
  if okNpc and isNpc then return false end
  local okMonster, isMon = pcall(function() return creature:isMonster() end)
  return okMonster and isMon == true
end

creatureToken = function(creature)
  local okId, cid = pcall(function() return creature:getId() end)
  if not okId or not cid then return nil, nil end
  return tostring(cid), cid
end

-- Mantem posicao/nome/shiny dos monstros dentro do alcance. Sem snapshots de
-- itens do tile: a selecao do corpo usa ID + claims por posicao.
rememberTarget = function(creature, position)
  if not enabled or not creature or not hasConfiguredCorpseTarget() then return nil end
  local token, cid = creatureToken(creature)
  if not token then return nil end

  local remembered = observedTargets[token]
  if not remembered and not isWildMonster(creature) then return nil end

  if not position then
    local okPos, cPos = pcall(function() return creature:getPosition() end)
    if okPos and cPos then position = cPos end
  end
  if not position then return remembered end

  local distance = catchDistance(position)
  if not distance or distance > CFG.TRACK_DISTANCE then
    observedTargets[token] = nil
    return nil
  end

  if not remembered then
    local okName, name = pcall(function() return creature:getName() end)
    remembered = {
      creatureId = cid,
      name = okName and name or '',
      isShiny = isCreatureShiny(creature),
      position = copyPosition(position),
      lastSeen = now()
    }
    observedTargets[token] = remembered
  else
    remembered.position.x, remembered.position.y, remembered.position.z = position.x, position.y, position.z
    remembered.lastSeen = now()
  end
  return remembered
end

pruneObservedTargets = function()
  local cutoff = now() - CFG.OBSERVED_TARGET_TTL
  for token, data in pairs(observedTargets) do
    if (data.lastSeen or 0) < cutoff then observedTargets[token] = nil end
  end
end

-- A varredura pode enfileirar o corpo antes do evento de morte; guardamos as
-- mortes de shiny por alguns segundos para a Ball de shiny ser usada mesmo assim.
noteShinyDeath = function(position)
  if not position then return end
  local currentTime = now()
  local kept = {}
  for _, death in ipairs(shinyDeaths) do
    if currentTime - death.at <= CFG.SHINY_DEATH_TTL then table.insert(kept, death) end
  end
  table.insert(kept, { position = copyPosition(position), at = currentTime })
  shinyDeaths = kept
end

wasShinyDeathNear = function(position)
  if #shinyDeaths == 0 then return false end
  local currentTime = now()
  for _, death in ipairs(shinyDeaths) do
    local distance = CorpseSelection.distance(death.position, position)
    if distance and distance <= 2 and currentTime - death.at <= CFG.SHINY_DEATH_TTL then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Busca do corpo depois da morte
-- ---------------------------------------------------------------------------

local SEARCH_OFFSETS = {
  { dx = 0, dy = 0 },
  { dx = 1, dy = 0 }, { dx = -1, dy = 0 }, { dx = 0, dy = 1 }, { dx = 0, dy = -1 },
  { dx = 1, dy = 1 }, { dx = -1, dy = 1 }, { dx = 1, dy = -1 }, { dx = -1, dy = -1 },
  { dx = 2, dy = 0 }, { dx = -2, dy = 0 }, { dx = 0, dy = 2 }, { dx = 0, dy = -2 }
}

local function findCorpseOnTile(pos)
  local tile = g_map.getTile(pos)
  if not tile then return nil end
  local items = tileItems(tile)
  if not items or #items == 0 then return nil end
  local top = topUseThing(tile)
  local topId = safeItemId(top)
  -- so o item utilizavel do topo pode receber a Ball
  if not top or not topId then return nil end
  local matched, matchedName, matchedBall = resolveCorpseTarget(topId)
  if not matched or not matchedBall or matchedBall <= 0 then return nil end
  if corpseClaims:isClaimed(pos, topId) then return nil end
  return top, topId, matchedBall
end

local function findCorpse(target)
  if not target or not target.position then return nil end
  for i = 1, #SEARCH_OFFSETS do
    local offset = SEARCH_OFFSETS[i]
    local pos = { x = target.position.x + offset.dx, y = target.position.y + offset.dy, z = target.position.z }
    local corpse, itemId, ballId = findCorpseOnTile(pos)
    if corpse then
      return corpse, itemId, ballId, pos, i == 1 and 'morte' or 'morte (vizinho)'
    end
  end
  return nil
end

local function describeTile(position)
  local tile = g_map.getTile(position)
  local items = tileItems(tile)
  if not items then return 'tile sem itens' end
  local descriptions = {}
  for index, item in ipairs(items) do
    local id = safeItemId(item)
    table.insert(descriptions, string.format('#%d id=%s nome="%s" claimed=%s',
      index, tostring(id or '?'), safeItemText(item, 'getName'), tostring(corpseClaims:isClaimed(position, id))))
  end
  return table.concat(descriptions, ' | ')
end

local function finishAttempt(token)
  local event = retryEvents[token]
  if event then event:cancel() end
  retryEvents[token] = nil
  dyingTargets[token] = nil
  observedTargets[token] = nil
end

local function attemptCatch(token, attempt)
  retryEvents[token] = nil
  local target = dyingTargets[token]
  if not target or not enabled or not g_game.isOnline() then
    finishAttempt(token)
    return
  end

  local corpse, itemId, ballId, pos, mode = findCorpse(target)
  if corpse then
    local withinRange, distance = isWithinCatchRange(pos)
    if not withinRange then
      -- A varredura enfileira o corpo assim que o personagem entrar no alcance.
      debugLog(string.format('corpo de %s fora do alcance (distancia=%s).', tostring(target.name), tostring(distance)))
      finishAttempt(token)
      return
    end
    enqueueCatch({
      key = corpseKey(pos, itemId),
      position = copyPosition(pos),
      itemId = itemId,
      ballId = ballId,
      corpse = corpse,
      name = target.name,
      isShiny = target.isShiny == true,
      detectionMode = mode,
      firstSeenAt = now()
    })
    finishAttempt(token)
    return
  end

  local limit = target.unconfirmed and CFG.UNCONFIRMED_RETRY_LIMIT or CFG.CORPSE_RETRY_LIMIT
  if attempt >= limit then
    if not target.unconfirmed then
      logInfo(string.format('Corpo de %s nao identificado em %d,%d,%d: %s',
        tostring(target.name), target.position.x, target.position.y, target.position.z, describeTile(target.position)))
      setStatus(string.format('%s morreu, mas nenhum corpo configurado apareceu no tile.', tostring(target.name)), '#ffcc66')
    end
    finishAttempt(token)
    return
  end

  retryEvents[token] = scheduleEvent(function() attemptCatch(token, attempt + 1) end, CFG.CORPSE_RETRY_DELAY)
end

scheduleCorpseSearch = function(token)
  if retryEvents[token] then return end
  retryEvents[token] = scheduleEvent(function() attemptCatch(token, 1) end, CFG.CORPSE_RETRY_DELAY)
end

end -- rastreio e busca do corpo

-- ---------------------------------------------------------------------------
-- Fila de lancamentos
-- ---------------------------------------------------------------------------

local function throwDelayRemaining()
  return math.max(1, nextThrowAllowedAt - now())
end

local function currentPing()
  local ok, value = pcall(function() return g_game.getPing() end)
  return ok and math.max(0, tonumber(value) or 0) or 0
end

scheduleCatchQueue = function(delay)
  if catchQueueEvent or #catchQueue == 0 then return end
  catchQueueEvent = scheduleEvent(function()
    catchQueueEvent = nil
    processCatchQueue()
  end, math.max(1, delay or 1))
end

local function scheduleBallRefresh()
  if ballRefreshEvent then
    ballRefreshEvent:cancel()
    ballRefreshEvent = nil
  end
  ballRefreshEvent = scheduleEvent(function()
    ballRefreshEvent = nil
    updateCorpseEntryRows()
  end, 750)
end

local function cancelBallRefresh()
  if ballRefreshEvent then
    ballRefreshEvent:cancel()
    ballRefreshEvent = nil
  end
end

local function releaseJob(job)
  queuedKeys[job.key] = nil
  corpseClaims:release(job.position, job.itemId)
end

-- Corpo esgotado: sai da varredura por CFG.BLOCKED_CORPSE_TTL (ou ate sumir).
local function discardCatchJob(job, reason, quiet)
  queuedKeys[job.key] = nil
  corpseClaims:block(job.position, job.itemId, {
    count = countMatchingItemsAt(job.position, job.itemId),
    ttl = CFG.BLOCKED_CORPSE_TTL
  })
  stats:recordDiscard()
  updateStatsLine()
  logInfo(string.format('Corpo descartado nome=%s pos=%d,%d,%d motivo=%s tentativas=%d.',
    tostring(job.name), job.position.x, job.position.y, job.position.z, tostring(reason), job.sendAttempts or 0))
  if not quiet then
    setStatus(string.format('%s descartado: %s.', tostring(job.name), tostring(reason)), '#ffcc66')
  end
  return 'drop'
end

local function deferCatchJob(job, reason)
  local currentTime = now()
  local decision = CatchDispatch.decide(currentTime, job.retryDeadline, false, nil)
  if decision == 'drop' then
    return discardCatchJob(job, reason, true)
  end
  job.nextAttemptDelay = CatchDispatch.retryDelay(currentTime, job.retryDeadline, CFG.RETRY_INTERVAL)
  table.insert(catchQueue, 1, job)
  debugLog(string.format('lancamento adiado nome=%s pos=%d,%d,%d motivo=%s.',
    tostring(job.name), job.position.x, job.position.y, job.position.z, tostring(reason)))
  return 'retry'
end

-- Escolhe a Ball: shiny -> Ball de shiny; card; reserva. nil quando nao ha Ball.
local function chooseBall(job)
  if job.isShiny and shinyBallId > 0 and ballAvailable(shinyBallId) then
    return shinyBallId, 'shiny'
  end
  if ballAvailable(job.ballId) then return job.ballId, 'card' end
  if reserveBallId > 0 and ballAvailable(reserveBallId) then return reserveBallId, 'reserva' end
  return nil
end

local function anyBallAvailable()
  for _, ballId in pairs(corpseBallIndex) do
    if ballAvailable(ballId) then return true end
  end
  return reserveBallId > 0 and ballAvailable(reserveBallId)
end

local function warnLowBall(ballId)
  local count = getInventoryItemCount(ballId)
  if count <= CFG.LOW_BALL_WARNING and not lowBallWarned[ballId] then
    lowBallWarned[ballId] = true
    logWarn(string.format('Ball ID %d esta acabando: %d restante(s).', ballId, count))
    setStatus(string.format('Atencao: Ball ID %d esta acabando (%d restantes).', ballId, count), '#ffcc66')
  elseif count > CFG.LOW_BALL_WARNING then
    lowBallWarned[ballId] = nil
  end
end

local function recordCatchCommand(job, useBallId, source)
  local currentTime = now()
  stats:recordSent(useBallId)
  if (currentTime - (lastThrowTime or 0)) > 3000 then recentBurstThrows = 0 end
  recentBurstThrows = (recentBurstThrows or 0) + 1
  lastThrowTime = currentTime
  local delay, paused = pacer:nextDelay(currentPing(), catchIntervalMinimum, catchIntervalMaximum)
  nextThrowAllowedAt = currentTime + delay
  logInfo(string.format('Ball %d (%s) enviada para %s pos=%d,%d,%d fila=%d sessao=%d proximo=%dms%s.',
    useBallId, source, tostring(job.name), job.position.x, job.position.y, job.position.z,
    #catchQueue, stats.sent, delay, paused and ' (pausa curta)' or ''))
end

local function scheduleCatchVerification(job)
  local previous = catchVerificationEvents[job.id]
  if previous and previous.event then previous.event:cancel() end

  local verification = {}
  catchVerificationEvents[job.id] = verification
  verification.event = scheduleEvent(function()
    if catchVerificationEvents[job.id] ~= verification then return end
    catchVerificationEvents[job.id] = nil

    if not enabled or not g_game.isOnline() then
      releaseJob(job)
      return
    end

    local tile = g_map.getTile(job.position)
    local stillPresent = tile and tileContainsItem(tile, job.corpse)
    if not stillPresent then
      releaseJob(job)
      debugLog(string.format('corpo removido apos a Ball para %s.', tostring(job.name)))
      return
    end

    if (job.sendAttempts or 0) >= CFG.MAX_CATCH_SEND_ATTEMPTS then
      discardCatchJob(job, 'corpo permaneceu apos as tentativas de Ball')
      return
    end

    queuedKeys[job.key] = true
    table.insert(catchQueue, 1, job)
    logInfo(string.format('Corpo ainda presente; nova tentativa para %s (tentativa %d).',
      tostring(job.name), (job.sendAttempts or 0) + 1))
    scheduleCatchQueue(throwDelayRemaining())
  end, CFG.CATCH_RESULT_CHECK_DELAY)
end

local function executeCatchJob(job)
  local tile = g_map.getTile(job.position)
  if not tile then
    releaseJob(job)
    return false
  end

  -- Reobtem o item vivo do tile: o userdata guardado pode ter ficado obsoleto.
  local top = topUseThing(tile)
  local topId = safeItemId(top)
  if not top or topId ~= job.itemId then
    if job.corpse and tileContainsItem(tile, job.corpse) then
      return deferCatchJob(job, 'corpo nao esta no topo utilizavel')
    end
    releaseJob(job)
    return false
  end
  job.corpse = top

  local withinRange, distance = isWithinCatchRange(job.position)
  if not withinRange then
    return deferCatchJob(job, string.format('fora do alcance distancia=%s', tostring(distance)))
  end

  local useBallId, source = chooseBall(job)
  if not useBallId then
    local result = discardCatchJob(job, string.format('sem Ball ID %d na mochila', job.ballId or 0))
    if not anyBallAvailable() then
      logWarn('Todas as Balls configuradas acabaram; Auto Catch desativado.')
      setEnabled(false, 'Todas as Balls configuradas acabaram; Auto Catch desativado.')
    end
    return result
  end

  job.sendAttempts = (job.sendAttempts or 0) + 1
  local ok, result = pcall(function()
    return g_game.useInventoryItemWith(useBallId, job.corpse)
  end)

  -- A API e fire-and-forget: nil ja significa enviado; false/erro entra no retry.
  local decision = CatchDispatch.decide(now(), job.retryDeadline, ok, result)
  if decision == 'sent' then
    queuedKeys[job.key] = nil
    recordCatchCommand(job, useBallId, source)
    scheduleCatchVerification(job)
    scheduleBallRefresh()
    warnLowBall(useBallId)
    updateStatsLine()
    if not lowBallWarned[useBallId] then
      setStatus(string.format('Ball %d enviada para %s. Fila: %d.', useBallId, tostring(job.name), #catchQueue), '#62d985')
    end
    return true
  end

  local reason = ok and 'cliente recusou o comando' or tostring(result)
  return deferCatchJob(job, reason)
end

processCatchQueue = function()
  if not enabled or not g_game.isOnline() then
    releaseQueuedJobs()
    corpseClaims:clear()
    return
  end
  if isHeld() then
    -- staff/pausa: nada e lancado; a varredura reconstroi a fila depois.
    releaseQueuedJobs()
    return
  end
  if not updateStaffHold() then return end

  local remaining = nextThrowAllowedAt - now()
  if remaining > 0 then
    scheduleCatchQueue(remaining)
    return
  end

  cleanupClaimedCorpses()
  local job = table.remove(catchQueue, 1)
  if not job then
    activeCatchJob = nil
    return
  end

  activeCatchJob = job
  local result = executeCatchJob(job)
  activeCatchJob = nil

  if #catchQueue > 0 then
    local delay = (result == 'retry' and catchQueue[1].nextAttemptDelay) or throwDelayRemaining()
    scheduleCatchQueue(delay)
  end
end

-- candidate: { key, position, itemId, ballId, corpse, name, isShiny, detectionMode, firstSeenAt }
enqueueCatch = function(candidate)
  if not candidate or not candidate.key then return false end
  if queuedKeys[candidate.key] then
    if candidate.isShiny then
      for _, job in ipairs(catchQueue) do
        if job.key == candidate.key then job.isShiny = true end
      end
    end
    return false
  end
  if corpseClaims:isClaimed(candidate.position, candidate.itemId) then return false end

  local ballId = candidate.ballId
  if not ballId or ballId <= 0 then
    local matched, _, matchedBall = resolveCorpseTarget(candidate.itemId)
    ballId = matched and matchedBall or 0
  end
  if ballId <= 0 then return false end

  if not corpseClaims:claim(candidate.position, candidate.itemId, {
    count = countMatchingItemsAt(candidate.position, candidate.itemId),
    ttl = CFG.CORPSE_CLAIM_TTL
  }) then
    return false
  end

  nextCatchJobId = nextCatchJobId + 1
  queuedKeys[candidate.key] = true
  local entry = corpseEntryIndex[candidate.itemId]
  table.insert(catchQueue, {
    id = nextCatchJobId,
    key = candidate.key,
    position = copyPosition(candidate.position),
    itemId = candidate.itemId,
    ballId = ballId,
    corpse = candidate.corpse,
    name = (entry and entry.name) or candidate.name or string.format('Corpo ID %d', candidate.itemId),
    isShiny = candidate.isShiny == true,
    detectionMode = candidate.detectionMode,
    firstSeenAt = candidate.firstSeenAt or now(),
    sendAttempts = 0,
    retryDeadline = now() + CFG.CATCH_DISPATCH_RETRY_WINDOW
  })
  debugLog(string.format('corpo enfileirado job=%d nome=%s ballId=%d corpoId=%d pos=%d,%d,%d modo=%s shiny=%s fila=%d.',
    nextCatchJobId, tostring(candidate.name), ballId, candidate.itemId,
    candidate.position.x, candidate.position.y, candidate.position.z,
    tostring(candidate.detectionMode), tostring(candidate.isShiny == true), #catchQueue))
  scheduleCatchQueue(throwDelayRemaining())
  return true
end

-- ---------------------------------------------------------------------------
-- Varredura do chao (corpos ja no mapa, ordenados por distancia e idade)
-- ---------------------------------------------------------------------------

local function cancelFloorScan()
  if floorScanEvent then
    floorScanEvent:cancel()
    floorScanEvent = nil
  end
end

local function pruneCorpseSeen(currentTime)
  for key, data in pairs(corpseFirstSeen) do
    if currentTime - (data.seenAt or 0) > CFG.CORPSE_SEEN_TTL then corpseFirstSeen[key] = nil end
  end
end

scanFloorForCorpses = function()
  if not enabled or not g_game.isOnline() then
    floorScanHasPendingCorpses = false
    floorScanHasResult = true
    return
  end
  local center = playerPosition()
  if not center then
    floorScanHasPendingCorpses = false
    floorScanHasResult = true
    return
  end

  cleanupClaimedCorpses()
  local currentTime = now()
  local candidates = {}

  for dx = -CFG.VISIBLE_SCAN_RADIUS_X, CFG.VISIBLE_SCAN_RADIUS_X do
    for dy = -CFG.VISIBLE_SCAN_RADIUS_Y, CFG.VISIBLE_SCAN_RADIUS_Y do
      local pos = { x = center.x + dx, y = center.y + dy, z = center.z }
      local tile = g_map.getTile(pos)
      if tile and not corpseClaims:isPositionClaimed(pos) then
        local item = topUseThing(tile)
        local itemId = safeItemId(item)
        if item and itemId then
          local matched, matchedName, matchedBall = resolveCorpseTarget(itemId)
          if matched and matchedBall and matchedBall > 0 then
            local key = corpseKey(pos, itemId)
            if key and not queuedKeys[key] then
              local seen = corpseFirstSeen[key]
              if not seen then
                seen = { at = currentTime }
                corpseFirstSeen[key] = seen
              end
              seen.seenAt = currentTime
              table.insert(candidates, {
                key = key,
                position = pos,
                itemId = itemId,
                ballId = matchedBall,
                corpse = item,
                name = matchedName,
                isShiny = wasShinyDeathNear(pos),
                detectionMode = 'varredura',
                firstSeenAt = seen.at
              })
            end
          end
        end
      end
    end
  end

  pruneCorpseSeen(currentTime)
  pruneObservedTargets()
  updateStaffHold()

  if #candidates > 0 then
    if isHeld() then
      floorScanHasPendingCorpses = true
      floorScanHasResult = true
      return
    end
    CorpseSelection.sortCandidates(candidates, center)
    for _, candidate in ipairs(candidates) do enqueueCatch(candidate) end
  end

  floorScanHasPendingCorpses = #candidates > 0 or #catchQueue > 0
  floorScanHasResult = true
end

scheduleFloorScan = function()
  cancelFloorScan()
  if not enabled then return end
  floorScanEvent = scheduleEvent(function()
    floorScanEvent = nil
    scanFloorForCorpses()
    scheduleFloorScan()
  end, CFG.FLOOR_SCAN_INTERVAL)
end

-- ---------------------------------------------------------------------------
-- Liga/desliga
-- ---------------------------------------------------------------------------

local function cancelCatchVerifications()
  for jobId, verification in pairs(catchVerificationEvents) do
    if verification and verification.event then verification.event:cancel() end
    catchVerificationEvents[jobId] = nil
  end
end

cancelRetries = function()
  for token, event in pairs(retryEvents) do
    if event then event:cancel() end
    retryEvents[token] = nil
  end
  releaseQueuedJobs()
  cancelFloorScan()
  cancelCatchVerifications()
  dyingTargets = {}
  observedTargets = {}
  corpseClaims:clear()
  corpseFirstSeen = {}
  shinyDeaths = {}
  floorScanHasPendingCorpses = false
  floorScanHasResult = false
  staffHoldName = nil
  pacer:reset()
end

function setEnabled(value, reason)
  value = value == true
  if value then
    if not hasConfiguredCorpseTarget() then
      value = false
      reason = 'Configure uma Ball e selecione o corpo correspondente antes de ativar.'
    elseif not g_game.isOnline() then
      value = false
      reason = 'Entre no jogo antes de ativar.'
    end
  end

  enabled = value
  if g_game.isOnline() then g_settings.set(SETTINGS.WAS_ENABLED, enabled) end
  updatingInterface = true
  if ui.enabledCheckBox then ui.enabledCheckBox:setChecked(enabled) end
  if ui.statusIndicator then ui.statusIndicator:setImageColor(enabled and '#42d392' or '#a85863') end
  if ui.statusTitle then
    ui.statusTitle:setText(enabled and 'AUTO CATCH ATIVADO' or 'AUTO CATCH DESATIVADO')
    ui.statusTitle:setColor(enabled and '#62d985' or '#dbe5ec')
  end
  updatingInterface = false

  if not enabled then
    cancelRetries()
    setStatus(reason or 'Auto Catch desativado.', '#b8b8b8')
  else
    floorScanHasPendingCorpses = true
    floorScanHasResult = false
    lowBallWarned = {}
    setStatus(string.format('Ativo por corpos: %s, alcance %d SQM.', configuredEntriesSummary(), CFG.MAX_CATCH_DISTANCE), '#62d985')
    scheduleFloorScan()
  end
  updateStatsLine()
end

local function hasPendingCorpsesInternal()
  if not enabled or not g_game.isOnline() or isHeld() then return false end
  if not floorScanHasResult then return true end
  return floorScanHasPendingCorpses
end

function hasPendingCorpses()
  return hasPendingCorpsesInternal()
end

-- Usado pelo CaveBot para esperar as capturas antes de andar.
function isBusy()
  if not enabled or isHeld() then return false end
  local currentTime = now()
  if activeCatchJob ~= nil or #catchQueue > 0 then return true end
  for _, target in pairs(dyingTargets) do
    if not target.unconfirmed then return true end
  end
  local gracePeriod = ((recentBurstThrows or 0) >= 5) and 1500 or 800
  if (currentTime - lastThrowTime) < gracePeriod then return true end
  if hasPendingCorpsesInternal() then return true end
  return false
end

function isEnabled()
  return enabled
end

function getStats()
  return stats
end

-- ---------------------------------------------------------------------------
-- Eventos de criaturas
-- ---------------------------------------------------------------------------

local function onCreatureHealthPercentChange(creature, healthPercent)
  if not enabled or not creature then return end
  if (tonumber(healthPercent) or 100) > 0 then
    rememberTarget(creature)
    return
  end

  local token, cid = creatureToken(creature)
  if not token then return end
  local observed = observedTargets[token]
  if not observed and not isWildMonster(creature) then return end

  local position = nil
  local okPos, cPos = pcall(function() return creature:getPosition() end)
  if okPos and cPos then position = cPos else position = observed and observed.position end
  if not position then return end
  local distance = catchDistance(position)
  if not distance or distance > CFG.TRACK_DISTANCE then return end

  local okName, name = pcall(function() return creature:getName() end)
  local isShiny = (observed and observed.isShiny) or isCreatureShiny(creature)
  if isShiny then noteShinyDeath(position) end
  dyingTargets[token] = {
    creatureId = cid,
    name = (observed and observed.name ~= '' and observed.name) or (okName and name) or 'Pokemon',
    isShiny = isShiny,
    position = copyPosition(position),
    unconfirmed = false
  }
end

local function onCreatureAppear(creature)
  if not enabled then return end
  rememberTarget(creature)
end

local function onCreaturePositionChange(creature, newPosition)
  if not enabled then return end
  rememberTarget(creature, newPosition)
end

local function onCreatureDisappear(creature)
  if not enabled or not creature then return end
  local token = creatureToken(creature)
  if not token then return end

  local target = dyingTargets[token]
  if not target then
    -- Sem HP 0 antes: o monstro provavelmente so saiu da tela. Faz poucas
    -- buscas, sem status e sem segurar o CaveBot.
    local observed = observedTargets[token]
    observedTargets[token] = nil
    if not observed then return end
    target = {
      creatureId = observed.creatureId,
      name = observed.name,
      isShiny = observed.isShiny,
      position = copyPosition(observed.position),
      unconfirmed = true
    }
    if observed.isShiny then noteShinyDeath(observed.position) end
    dyingTargets[token] = target
  end

  scheduleCorpseSearch(token)
end

-- ---------------------------------------------------------------------------
-- Confirmacao de captura vinda do servidor
-- ---------------------------------------------------------------------------

local function onCatchWindow(pokemonName, experience, lookType, shiny)
  if not enabled then return end
  local isShiny = shiny == 1 or shiny == true or tostring(pokemonName or ''):lower():find('shiny', 1, true) ~= nil
  if stats:recordConfirmed(pokemonName, isShiny, now()) then
    updateStatsLine()
    setStatus(string.format('Captura confirmada: %s%s.', tostring(pokemonName), isShiny and ' (SHINY)' or ''), '#62d985')
  end
end

local function onTextMessage(mode, text)
  if not enabled or type(text) ~= 'string' then return end
  local function processLine(line)
    local caught = CatchStats.parseCatchMessage(line)
    if caught and stats:recordConfirmed(caught, caught:lower():find('shiny', 1, true) ~= nil, now()) then
      updateStatsLine()
      setStatus(string.format('Captura confirmada: %s.', caught), '#62d985')
    end
    local spent = CatchStats.parseBallsSpent(line)
    if spent then
      stats:recordBallsSpent(spent)
      updateStatsLine()
    end
  end
  if text:find('\n', 1, true) then
    for line in text:gmatch('[^\r\n]+') do processLine(line) end
  else
    processLine(text)
  end
end

-- ---------------------------------------------------------------------------
-- Entrar / sair do jogo
-- ---------------------------------------------------------------------------

local function cancelRearm()
  if rearmEvent then
    rearmEvent:cancel()
    rearmEvent = nil
  end
end

local function onGameEnd()
  cancelRearm()
  g_settings.set(SETTINGS.WAS_ENABLED, enabled)
  cancelSelections()
  stopAutoItemTimer()
  resetAutoItemRuntimeState()
  setEnabled(false, 'Auto Catch desativado ao sair do jogo.')
  hide()
end

local function onGameStart()
  updateCorpseEntryRows()
  scheduleBallRefresh()
  resetAutoItemRuntimeState()
  refreshAutoItemEntries()
  if hasEnabledAutoItems() then startAutoItemTimer() end
  stats:reset()
  updateStatsLine()

  cancelRearm()
  if autoRearmEnabled and g_settings.getBoolean(SETTINGS.WAS_ENABLED, false) then
    rearmEvent = scheduleEvent(function()
      rearmEvent = nil
      if not g_game.isOnline() or enabled then return end
      setEnabled(true)
      if enabled then
        logInfo('Reativado automaticamente ao entrar no jogo.')
        setStatus('Auto Catch reativado automaticamente ao entrar no jogo.', '#62d985')
      end
    end, CFG.REARM_DELAY_MS)
  end
end

-- ---------------------------------------------------------------------------
-- Interface
-- ---------------------------------------------------------------------------

function selectSubTab(tabName)
  local root = ui.panel or ui.window
  if root then
    if not ui.tabCatchContent then ui.tabCatchContent = root:recursiveGetChildById('tabCatchContent') end
    if not ui.tabSafetyContent then ui.tabSafetyContent = root:recursiveGetChildById('tabSafetyContent') end
    if not ui.tabUtilsContent then ui.tabUtilsContent = root:recursiveGetChildById('tabUtilsContent') end
    if not ui.navTabCatch then ui.navTabCatch = root:recursiveGetChildById('navTabCatch') end
    if not ui.navTabSafety then ui.navTabSafety = root:recursiveGetChildById('navTabSafety') end
    if not ui.navTabUtils then ui.navTabUtils = root:recursiveGetChildById('navTabUtils') end
  end

  local isCatch = tabName == 'catch'
  local isSafety = tabName == 'safety'
  local isUtils = tabName == 'utils'
  if ui.tabCatchContent then ui.tabCatchContent:setVisible(isCatch) end
  if ui.tabSafetyContent then ui.tabSafetyContent:setVisible(isSafety) end
  if ui.tabUtilsContent then ui.tabUtilsContent:setVisible(isUtils) end
  if ui.navTabCatch then ui.navTabCatch:setOn(isCatch) end
  if ui.navTabSafety then ui.navTabSafety:setOn(isSafety) end
  if ui.navTabUtils then ui.navTabUtils:setOn(isUtils) end
end

local function updateCatchIntervalInputColors(valid)
  local color = valid and '#dbe5ec' or '#ff7676'
  if ui.catchIntervalMinEdit then ui.catchIntervalMinEdit:setColor(color) end
  if ui.catchIntervalMaxEdit then ui.catchIntervalMaxEdit:setColor(color) end
end

updatePresetButtons = function(minimum, maximum)
  local isSafe = tonumber(minimum) == 350 and tonumber(maximum) == 700
  local isNormal = tonumber(minimum) == 200 and tonumber(maximum) == 400
  local isTurbo = tonumber(minimum) == 80 and tonumber(maximum) == 180
  if ui.presetSafeBtn then ui.presetSafeBtn:setOn(isSafe) end
  if ui.presetNormalBtn then ui.presetNormalBtn:setOn(isNormal) end
  if ui.presetTurboBtn then ui.presetTurboBtn:setOn(isTurbo) end
end

-- Enquanto digita: so valida e colore. Salva ao confirmar (Enter/foco).
local function validateCatchIntervalInputs()
  if not ui.catchIntervalMinEdit or not ui.catchIntervalMaxEdit then return false end
  local minimum = CatchInterval.validate(ui.catchIntervalMinEdit:getText(), ui.catchIntervalMaxEdit:getText())
  updateCatchIntervalInputColors(minimum ~= nil)
  return minimum ~= nil
end

applyCatchIntervalInputs = function()
  if not ui.catchIntervalMinEdit or not ui.catchIntervalMaxEdit then return false end
  local minimum, reason = CatchInterval.validate(ui.catchIntervalMinEdit:getText(), ui.catchIntervalMaxEdit:getText())
  if not minimum then
    updateCatchIntervalInputColors(false)
    local messageText = reason == 'minimum-greater-than-maximum' and
      'Intervalo invalido: minimo nao pode ser maior que o maximo.' or
      'Intervalo invalido: use numeros inteiros entre 50 e 2000 ms.'
    setStatus(messageText, '#ff7676')
    return false
  end
  local maximum = tonumber(ui.catchIntervalMaxEdit:getText())
  if minimum == catchIntervalMinimum and maximum == catchIntervalMaximum then
    updateCatchIntervalInputColors(true)
    updatePresetButtons(minimum, maximum)
    return true
  end
  catchIntervalMinimum, catchIntervalMaximum = minimum, maximum
  updateCatchIntervalInputColors(true)
  updatePresetButtons(minimum, maximum)
  pacer:reset()
  saveSettings()
  setStatus(string.format('Intervalo das Balls: %d-%d ms (sorteado, nunca abaixo do ping).', minimum, maximum), '#62d985')
  return true
end

function applyPreset(minMs, maxMs)
  local root = ui.panel or ui.window
  if not ui.catchIntervalMinEdit and root then ui.catchIntervalMinEdit = root:recursiveGetChildById('catchIntervalMinEdit') end
  if not ui.catchIntervalMaxEdit and root then ui.catchIntervalMaxEdit = root:recursiveGetChildById('catchIntervalMaxEdit') end
  if ui.catchIntervalMinEdit and ui.catchIntervalMaxEdit then
    ui.catchIntervalMinEdit:setText(tostring(minMs))
    ui.catchIntervalMaxEdit:setText(tostring(maxMs))
    applyCatchIntervalInputs()
  else
    catchIntervalMinimum, catchIntervalMaximum = minMs, maxMs
    pacer:reset()
    saveSettings()
  end
  updatePresetButtons(minMs, maxMs)
end

local function isEnterKey(keyCode)
  return keyCode == KeyEnter or (KeyNumpadEnter ~= nil and keyCode == KeyNumpadEnter)
end

local function wireIntervalEdit(edit)
  if not edit then return end
  edit.onTextChange = function() validateCatchIntervalInputs() end
  edit.onFocusChange = function(_, focused)
    if not focused then applyCatchIntervalInputs() end
  end
  edit.onKeyPress = function(_, keyCode)
    if isEnterKey(keyCode) then
      applyCatchIntervalInputs()
      return true
    end
    return false
  end
end

local lastAddTargetTime = 0
function onAddTargetClick()
  local currentTime = now()
  if (currentTime - lastAddTargetTime) < 200 then return end
  lastAddTargetTime = currentTime
  addNewPokemon()
  return true
end

local lastAddAutoItemTime = 0
function onAddAutoItemClick()
  local currentTime = now()
  if (currentTime - lastAddAutoItemTime) < 200 then return end
  lastAddAutoItemTime = currentTime
  addNewAutoItem()
  return true
end

bindPanelWidgets = function(rootWidget)
  if not rootWidget then return end
  ui.panel = rootWidget:recursiveGetChildById('autoCatchPanel') or rootWidget

  ui.entriesList = rootWidget:recursiveGetChildById('entriesList')
  ui.entriesEmpty = rootWidget:recursiveGetChildById('entriesEmpty')
  ui.entriesCountHint = rootWidget:recursiveGetChildById('entriesCountHint')
  ui.addPokemonBtn = rootWidget:recursiveGetChildById('addPokemon')

  ui.enabledCheckBox = rootWidget:recursiveGetChildById('enabled')
  ui.statusLabel = rootWidget:recursiveGetChildById('status')
  ui.statsLine = rootWidget:recursiveGetChildById('statsLine')
  ui.statusIndicator = rootWidget:recursiveGetChildById('statusIndicator')
  ui.statusTitle = rootWidget:recursiveGetChildById('statusTitle')

  ui.navTabCatch = rootWidget:recursiveGetChildById('navTabCatch')
  ui.navTabSafety = rootWidget:recursiveGetChildById('navTabSafety')
  ui.navTabUtils = rootWidget:recursiveGetChildById('navTabUtils')
  ui.tabCatchContent = rootWidget:recursiveGetChildById('tabCatchContent')
  ui.tabSafetyContent = rootWidget:recursiveGetChildById('tabSafetyContent')
  ui.tabUtilsContent = rootWidget:recursiveGetChildById('tabUtilsContent')

  ui.presetSafeBtn = rootWidget:recursiveGetChildById('presetSafe')
  ui.presetNormalBtn = rootWidget:recursiveGetChildById('presetNormal')
  ui.presetTurboBtn = rootWidget:recursiveGetChildById('presetTurbo')

  ui.shinyBallSlot = rootWidget:recursiveGetChildById('shinyBallSlot')
  ui.shinyBallInfo = rootWidget:recursiveGetChildById('shinyBallInfo')
  ui.selectShinyBallBtn = rootWidget:recursiveGetChildById('selectShinyBall')
  ui.clearShinyBallBtn = rootWidget:recursiveGetChildById('clearShinyBall')
  ui.reserveBallSlot = rootWidget:recursiveGetChildById('reserveBallSlot')
  ui.reserveBallInfo = rootWidget:recursiveGetChildById('reserveBallInfo')
  ui.selectReserveBallBtn = rootWidget:recursiveGetChildById('selectReserveBall')
  ui.clearReserveBallBtn = rootWidget:recursiveGetChildById('clearReserveBall')
  ui.shownShinyBallId = nil
  ui.shownReserveBallId = nil

  ui.staffGuardCheckBox = rootWidget:recursiveGetChildById('staffGuard')
  ui.autoRearmCheckBox = rootWidget:recursiveGetChildById('autoRearm')

  ui.autoItemsList = rootWidget:recursiveGetChildById('autoItemsList')
  ui.autoItemsEmpty = rootWidget:recursiveGetChildById('autoItemsEmpty')
  ui.autoItemsCountHint = rootWidget:recursiveGetChildById('autoItemsCountHint')
  ui.addAutoItemBtn = rootWidget:recursiveGetChildById('addAutoItem')
  ui.catchIntervalMinEdit = rootWidget:recursiveGetChildById('catchIntervalMinEdit')
  ui.catchIntervalMaxEdit = rootWidget:recursiveGetChildById('catchIntervalMaxEdit')

  wireButton(ui.navTabCatch, function() selectSubTab('catch') end)
  wireButton(ui.navTabSafety, function() selectSubTab('safety') end)
  wireButton(ui.navTabUtils, function() selectSubTab('utils') end)
  wireButton(ui.presetSafeBtn, function() applyPreset(350, 700) end)
  wireButton(ui.presetNormalBtn, function() applyPreset(200, 400) end)
  wireButton(ui.presetTurboBtn, function() applyPreset(80, 180) end)
  wireButton(ui.addPokemonBtn, onAddTargetClick)
  wireButton(ui.addAutoItemBtn, onAddAutoItemClick)
  wireButton(ui.selectShinyBallBtn, startShinyBallSelection)
  wireButton(ui.clearShinyBallBtn, clearShinyBall)
  wireButton(ui.selectReserveBallBtn, startReserveBallSelection)
  wireButton(ui.clearReserveBallBtn, clearReserveBall)

  if ui.shinyBallSlot then
    ui.shinyBallSlot.onDrop = function(_, draggedWidget)
      local item = draggedItem(draggedWidget)
      local accepted = item ~= nil and setShinyBall(item)
      if draggedWidget then draggedWidget.currentDragThing = nil end
      return accepted
    end
  end
  if ui.reserveBallSlot then
    ui.reserveBallSlot.onDrop = function(_, draggedWidget)
      local item = draggedItem(draggedWidget)
      local accepted = item ~= nil and setReserveBall(item)
      if draggedWidget then draggedWidget.currentDragThing = nil end
      return accepted
    end
  end

  if ui.statusIndicator then ui.statusIndicator:setImageColor(enabled and '#42d392' or '#a85863') end
  if ui.statusTitle then
    ui.statusTitle:setText(enabled and 'AUTO CATCH ATIVADO' or 'AUTO CATCH DESATIVADO')
    ui.statusTitle:setColor(enabled and '#62d985' or '#dbe5ec')
  end

  if ui.catchIntervalMinEdit and ui.catchIntervalMaxEdit then
    ui.catchIntervalMinEdit:setText(tostring(catchIntervalMinimum))
    ui.catchIntervalMaxEdit:setText(tostring(catchIntervalMaximum))
    wireIntervalEdit(ui.catchIntervalMinEdit)
    wireIntervalEdit(ui.catchIntervalMaxEdit)
    updateCatchIntervalInputColors(true)
  end
  updatePresetButtons(catchIntervalMinimum, catchIntervalMaximum)

  updatingInterface = true
  if ui.enabledCheckBox then ui.enabledCheckBox:setChecked(enabled) end
  if ui.staffGuardCheckBox then ui.staffGuardCheckBox:setChecked(staffGuardEnabled) end
  if ui.autoRearmCheckBox then ui.autoRearmCheckBox:setChecked(autoRearmEnabled) end
  updatingInterface = false

  if ui.enabledCheckBox then
    ui.enabledCheckBox.onCheckChange = function(_, checked)
      if updatingInterface then return end
      setEnabled(checked)
    end
  end
  if ui.staffGuardCheckBox then
    ui.staffGuardCheckBox.onCheckChange = function(_, checked)
      if updatingInterface then return end
      staffGuardEnabled = checked == true
      saveSettings()
      if not staffGuardEnabled and staffHoldName then releaseStaffHold() end
      setStatus(staffGuardEnabled and 'Lancamentos ficam em espera enquanto houver staff na tela.' or
        'Atencao: o Auto Catch nao vai parar quando houver staff na tela.', staffGuardEnabled and '#62d985' or '#ffcc66')
    end
  end
  if ui.autoRearmCheckBox then
    ui.autoRearmCheckBox.onCheckChange = function(_, checked)
      if updatingInterface then return end
      autoRearmEnabled = checked == true
      saveSettings()
      setStatus(autoRearmEnabled and 'O Auto Catch sera reativado ao entrar no jogo se estava ligado ao sair.' or
        'O Auto Catch inicia desligado a cada login.', '#b8b8b8')
    end
  end

  selectSubTab('catch')
  refreshCorpseEntries()
  refreshAutoItemEntries()
  updateStatsLine()
end

function createEmbeddedPanel(parent)
  if not parent then return nil end
  if ui.panel then
    ui.panel:destroy()
    ui.panel = nil
  end
  ui.panel = g_ui.createWidget('AutoCatchPanel', parent)
  bindPanelWidgets(ui.panel)
  return ui.panel
end

function getPanel()
  return ui.panel
end

function onMasterTabSelected()
  updateCorpseEntryRows()
  refreshAutoItemEntries()
  updateStatsLine()
end

function show()
  if modules.game_cavebot_pka and modules.game_cavebot_pka.openTab then
    modules.game_cavebot_pka.openTab('autocatch')
    if ui.button then ui.button:setOn(true) end
    return
  end
  if not ui.window then
    local root = modules.game_interface and modules.game_interface.getRootPanel()
    local okCreate, win = pcall(function() return g_ui.createWidget('AutoCatchWindow', root) end)
    if not okCreate or not win then
      logWarn('falha ao criar AutoCatchWindow: ' .. tostring(win))
      return
    end
    ui.window = win
    local okBind, errBind = pcall(bindPanelWidgets, ui.window)
    if not okBind then
      logWarn('erro em bindPanelWidgets: ' .. tostring(errBind))
      ui.window:destroy()
      ui.window = nil
      ui.panel = nil
      if ui.button then ui.button:setOn(false) end
      return
    end
    ui.window.onVisibilityChange = function(_, visible)
      if ui.button then ui.button:setOn(visible) end
    end
    ui.window.onEscape = hide
  end
  ui.window:show()
  ui.window:raise()
  ui.window:focus()
  updateCorpseEntryRows()
  scheduleBallRefresh()
  if ui.button then ui.button:setOn(true) end
end

function hide()
  if modules.game_cavebot_pka and modules.game_cavebot_pka.hide then
    modules.game_cavebot_pka.hide()
    if ui.button then ui.button:setOn(false) end
    return
  end
  if not ui.window then return end
  ui.window:hide()
  if ui.button then ui.button:setOn(false) end
end

function toggle()
  local cavebot = modules.game_cavebot_pka
  if cavebot and cavebot.toggleTab then
    cavebot.toggleTab('autocatch')
    if ui.button and cavebot.isOpen then ui.button:setOn(cavebot.isOpen()) end
    return
  elseif cavebot and cavebot.toggle then
    cavebot.toggle()
    if ui.button and cavebot.isOpen then ui.button:setOn(cavebot.isOpen()) end
    return
  end
  if not ui.window then
    show()
    return
  end
  if ui.window:isVisible() then hide() else show() end
end

function setDebugEnabled(value)
  debugEnabled = value == true
  g_settings.set(SETTINGS.DEBUG, debugEnabled)
  logInfo('debug ' .. (debugEnabled and 'ligado' or 'desligado'))
end

function isDebugEnabled()
  return debugEnabled
end

-- ---------------------------------------------------------------------------
-- Ciclo de vida do modulo
-- ---------------------------------------------------------------------------

function init()
  g_ui.importStyle('autocatch.otui')

  debugEnabled = g_settings.getBoolean(SETTINGS.DEBUG, false)
  staffGuardEnabled = g_settings.getBoolean(SETTINGS.STAFF_GUARD, true)
  autoRearmEnabled = g_settings.getBoolean(SETTINGS.AUTO_REARM, false)

  local configuredMinimum = g_settings.getNumber(SETTINGS.CATCH_INTERVAL_MIN, CatchInterval.DEFAULT_MINIMUM)
  local configuredMaximum = g_settings.getNumber(SETTINGS.CATCH_INTERVAL_MAX, CatchInterval.DEFAULT_MAXIMUM)
  local validMinimum, validMaximum = CatchInterval.validate(configuredMinimum, configuredMaximum)
  if validMinimum then
    catchIntervalMinimum, catchIntervalMaximum = validMinimum, validMaximum
  else
    catchIntervalMinimum, catchIntervalMaximum = CatchInterval.DEFAULT_MINIMUM, CatchInterval.DEFAULT_MAXIMUM
  end

  loadCorpseEntries()
  loadSpecialBalls()
  loadAutoItems()

  if modules.game_cavebot_pka and modules.game_cavebot_pka.getAutoCatchContainer then
    local container = modules.game_cavebot_pka.getAutoCatchContainer()
    if container then createEmbeddedPanel(container) end
  end

  if modules.client_topmenu and not ui.button then
    ui.button = modules.client_topmenu.addMiddleGameToggleButton(
      'autoCatchButton', tr('Auto Catch'), '/modules/game_autocatch/images/icon', toggle, false, 17)
    if ui.button then ui.button:setOn(false) end
  end

  connect(Creature, {
    onAppear = onCreatureAppear,
    onHealthPercentChange = onCreatureHealthPercentChange,
    onPositionChange = onCreaturePositionChange,
    onDisappear = onCreatureDisappear
  })
  connect(g_game, {
    onGameStart = onGameStart,
    onGameEnd = onGameEnd,
    onPlayerBuffsReceived = onAutoItemBuffsReceived,
    onCatchWindow = onCatchWindow,
    onTextMessage = onTextMessage
  })

  updateCorpseEntryRows()
  scheduleBallRefresh()
  refreshAutoItemEntries()
  if hasEnabledAutoItems() then startAutoItemTimer() end
  setEnabled(false, 'Adicione cards com Ball e corpo; o recurso inicia desativado.')
  logInfo(string.format('Cards carregados: %s, AutoItems=%d (enabled=%s), Balls=%d-%dms, shinyBall=%d, reserva=%d, staffGuard=%s.',
    configuredEntriesSummary(), #autoItems, tostring(hasEnabledAutoItems()),
    catchIntervalMinimum, catchIntervalMaximum, shinyBallId, reserveBallId, tostring(staffGuardEnabled)))

  if g_game.isOnline() then onGameStart() end
end

function terminate()
  disconnect(Creature, {
    onAppear = onCreatureAppear,
    onHealthPercentChange = onCreatureHealthPercentChange,
    onPositionChange = onCreaturePositionChange,
    onDisappear = onCreatureDisappear
  })
  disconnect(g_game, {
    onGameStart = onGameStart,
    onGameEnd = onGameEnd,
    onPlayerBuffsReceived = onAutoItemBuffsReceived,
    onCatchWindow = onCatchWindow,
    onTextMessage = onTextMessage
  })
  cancelRearm()
  cancelBallRefresh()
  cancelSelections()
  stopAutoItemTimer()
  resetAutoItemRuntimeState()
  cancelRetries()

  if ui.window then
    ui.window:destroy()
    ui.window = nil
    ui.panel = nil
  elseif ui.panel then
    ui.panel:destroy()
    ui.panel = nil
  end
  if ui.button then
    ui.button:destroy()
    ui.button = nil
  end
  entryRows = {}
end

-- ---------------------------------------------------------------------------
-- API publica (modules.game_autocatch.*)
-- As funcoes declaradas sem "local" acima ja sao campos do modulo:
--   init, terminate, show, hide, toggle, createEmbeddedPanel, getPanel,
--   isEnabled, isBusy, hasPendingCorpses, onMasterTabSelected, selectSubTab,
--   applyPreset, addNewPokemon, addNewAutoItem, clearAutoItem,
--   onAddTargetClick, onAddAutoItemClick, pause, resume, isPaused,
--   setEnabled, startCorpseSelection, startAutoItemSelection,
--   findVisibleStaff, getStats, setDebugEnabled, isDebugEnabled
-- ---------------------------------------------------------------------------

