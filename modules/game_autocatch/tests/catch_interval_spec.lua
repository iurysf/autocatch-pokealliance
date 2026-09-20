local source = debug.getinfo(1, "S").source
local testDirectory = source:sub(1, 1) == "@" and source:sub(2):match("^(.*)[/\\]") or "."
local base = (testDirectory or ".") .. "/../"
local Interval = dofile(base .. "catch_interval.lua")
local CorpseClaim = dofile(base .. "corpse_claim.lua")
local CorpseSelection = dofile(base .. "corpse_selection.lua")
local CatchDispatch = dofile(base .. "catch_dispatch.lua")
local CorpseTarget = dofile(base .. "corpse_target.lua")
local CatchStats = dofile(base .. "catch_stats.lua")
local StaffGuard = dofile(base .. "staff_guard.lua")
local AutoItem = dofile(base .. "auto_item.lua")

local passed, failed = 0, 0

local function check(name, fn)
  local ok, message = pcall(fn)
  if ok then
    passed = passed + 1
    print("PASS " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name .. ": " .. tostring(message))
  end
end

local function equal(actual, expected)
  if actual ~= expected then error("expected " .. tostring(expected) .. ", got " .. tostring(actual), 2) end
end

local function readFile(relative)
  local file = assert(io.open(base .. relative, "r"))
  local content = file:read("*a")
  file:close()
  return content
end

-- ---------------------------------------------------------------------------
-- CatchInterval
-- ---------------------------------------------------------------------------

check("preserves current default limits", function()
  local minimum, maximum = Interval.validate(220, 260)
  equal(minimum, 220)
  equal(maximum, 260)
end)

check("accepts only integer limits from 50 through 2000", function()
  equal(Interval.validate(50, 2000), 50)
  equal(Interval.validate(49, 2000), nil)
  equal(Interval.validate(50, 2001), nil)
  equal(Interval.validate(100.5, 200), nil)
end)

check("rejects minimum greater than maximum", function()
  local minimum, reason = Interval.validate(300, 200)
  equal(minimum, nil)
  equal(reason, "minimum-greater-than-maximum")
end)

check("floor never goes below ping plus buffer nor above maximum", function()
  equal(Interval.floor(20, 100, 400), 100)
  equal(Interval.floor(200, 100, 400), 230)
  equal(Interval.floor(500, 100, 400), 400)
end)

check("interval is drawn between the floor and the maximum", function()
  local calls = {}
  local rng = function(lower, upper)
    table.insert(calls, { lower, upper })
    return upper
  end
  equal(Interval.calculate(20, 350, 700, rng), 700)
  equal(calls[1][1], 350)
  equal(calls[1][2], 700)
  equal(Interval.calculate(20, 350, 700, function(lower) return lower end), 350)
  equal(Interval.calculate(500, 100, 400, rng), 400)
  equal(#calls, 1) -- piso igual ao maximo: nao sorteia
end)

check("random interval stays inside the configured range", function()
  for _ = 1, 200 do
    local value = Interval.calculate(40, 350, 700)
    if value < 350 or value > 700 then error("out of range: " .. value) end
  end
end)

check("pacer adds a short pause after a burst of throws", function()
  local pacer = Interval.newPacer({
    random = function(lower, upper)
      if lower == 6 then return 3 end        -- pausa a cada 3 lancamentos
      if lower == 400 then return 500 end    -- pausa de 500 ms
      return lower                           -- intervalo = piso
    end
  })
  local d1 = pacer:nextDelay(20, 200, 400)
  local d2 = pacer:nextDelay(20, 200, 400)
  local d3, paused = pacer:nextDelay(20, 200, 400)
  equal(d1, 200)
  equal(d2, 200)
  equal(d3, 700)
  equal(paused, true)
  local d4, pausedAgain = pacer:nextDelay(20, 200, 400)
  equal(d4, 200)
  equal(pausedAgain, false)
end)

-- ---------------------------------------------------------------------------
-- CorpseClaim (chave = posicao + ID, independente do userdata)
-- ---------------------------------------------------------------------------

check("claims are keyed by position and item id, not by object identity", function()
  local claims = CorpseClaim.new(6000, function() return 1000 end)
  local pos = { x = 10, y = 20, z = 6 }
  equal(claims:claim(pos, 24349), true)
  equal(claims:isClaimed({ x = 10, y = 20, z = 6 }, 24349), true)
  equal(claims:isPositionClaimed({ x = 10, y = 20, z = 6 }), true)
  equal(claims:isClaimed(pos, 99999), false)
  equal(claims:claim(pos, 24349), false)
end)

check("claim is released when the matching item count drops", function()
  local claims = CorpseClaim.new(60000, function() return 1000 end)
  local pos = { x = 10, y = 20, z = 6 }
  equal(claims:claim(pos, 24349, { count = 2 }), true)
  claims:cleanup(function() return 2 end)
  equal(claims:isClaimed(pos, 24349), true)
  claims:cleanup(function() return 1 end)
  equal(claims:isClaimed(pos, 24349), false)
end)

check("claim survives an unknown tile and a temporary extra corpse", function()
  local claims = CorpseClaim.new(60000, function() return 1000 end)
  local pos = { x = 10, y = 20, z = 6 }
  claims:claim(pos, 24349, { count = 1 })
  claims:cleanup(function() return nil end)
  equal(claims:isClaimed(pos, 24349), true)
  claims:cleanup(function() return 2 end)
  equal(claims:isClaimed(pos, 24349), true)
  claims:cleanup(function() return 1 end)
  equal(claims:isClaimed(pos, 24349), false)
end)

check("claims expire by ttl unless persistent", function()
  local now = 1000
  local claims = CorpseClaim.new(6000, function() return now end)
  local pos = { x = 1, y = 2, z = 7 }
  claims:claim(pos, 100)
  claims:claim({ x = 3, y = 4, z = 7 }, 100, { persistent = true })
  now = 7001
  claims:cleanup()
  equal(claims:isClaimed(pos, 100), false)
  equal(claims:isClaimed({ x = 3, y = 4, z = 7 }, 100), true)
end)

check("blocked corpse keeps the scan away until it leaves or the block expires", function()
  local now = 1000
  local claims = CorpseClaim.new(6000, function() return now end)
  local pos = { x = 5, y = 5, z = 7 }
  claims:claim(pos, 100)
  equal(claims:block(pos, 100, { count = 1, ttl = 45000 }), true)
  equal(claims:isBlocked(pos, 100), true)
  equal(claims:isPositionClaimed(pos), true)
  now = 20000
  claims:cleanup(function() return 1 end)
  equal(claims:isBlocked(pos, 100), true)
  claims:cleanup(function() return 0 end)
  equal(claims:isBlocked(pos, 100), false)
  claims:block(pos, 100, { count = 1, ttl = 45000 })
  now = 70000
  claims:cleanup(function() return 1 end)
  equal(claims:isClaimed(pos, 100), false)
end)

check("release and clear remove claims", function()
  local claims = CorpseClaim.new(6000, function() return 1 end)
  claims:claim({ x = 1, y = 1, z = 1 }, 5)
  claims:claim({ x = 2, y = 2, z = 1 }, 5)
  equal(claims:size(), 2)
  claims:release({ x = 1, y = 1, z = 1 }, 5)
  equal(claims:size(), 1)
  claims:clear()
  equal(claims:size(), 0)
end)

-- ---------------------------------------------------------------------------
-- CorpseSelection
-- ---------------------------------------------------------------------------

check("picks the top-most matching corpse that is not claimed", function()
  local bottom = { id = 24349 }
  local top = { id = 24349 }
  local other = { id = 1 }
  local selected, index = CorpseSelection.pick({ bottom, top, other }, { expectedId = 24349 })
  equal(selected, top)
  equal(index, 2)
  local skipped = CorpseSelection.pick({ bottom, top }, {
    expectedId = 24349,
    isClaimed = function(item) return item == top end
  })
  equal(skipped, bottom)
  local none, _, hasMatch = CorpseSelection.pick({ other }, { expectedId = 24349 })
  equal(none, nil)
  equal(hasMatch, false)
end)

check("sorts candidates by distance and then by age", function()
  local player = { x = 100, y = 100, z = 7 }
  local list = {
    { key = "c", position = { x = 105, y = 100, z = 7 }, firstSeenAt = 10 },
    { key = "b", position = { x = 101, y = 100, z = 7 }, firstSeenAt = 50 },
    { key = "a", position = { x = 101, y = 101, z = 7 }, firstSeenAt = 20 },
    { key = "d", position = { x = 101, y = 100, z = 8 }, firstSeenAt = 1 }
  }
  CorpseSelection.sortCandidates(list, player)
  equal(list[1].key, "a")
  equal(list[2].key, "b")
  equal(list[3].key, "c")
  equal(list[4].key, "d")
end)

-- ---------------------------------------------------------------------------
-- CatchDispatch
-- ---------------------------------------------------------------------------

check("retries a rejected dispatch before the deadline", function()
  equal(CatchDispatch.decide(1200, 6000, true, false), "retry")
  equal(CatchDispatch.retryDelay(1200, 6000, 400), 400)
end)

check("drops a rejected dispatch at the deadline", function()
  equal(CatchDispatch.decide(6000, 6000, true, false), "drop")
end)

check("accepts fire-and-forget dispatch without boolean result", function()
  equal(CatchDispatch.decide(1200, 6000, true, nil), "sent")
  equal(CatchDispatch.decide(1200, 6000, true, true), "sent")
  equal(CatchDispatch.decide(1200, 6000, true, false), "retry")
end)

-- ---------------------------------------------------------------------------
-- CorpseTarget
-- ---------------------------------------------------------------------------

check("matches only the configured corpse IDs", function()
  equal(CorpseTarget.hasConfigured(3552, 6076, 0, 0), true)
  local matched, label, ball = CorpseTarget.resolve(6076, 3552, 6076, 0, 0)
  equal(matched, true)
  equal(label, "Corpo 1 (ID 6076)")
  equal(ball, 3552)
  equal(CorpseTarget.resolve(12345, 3552, 6076, 0, 0), false)
end)

check("resolves any number of body cards without using Pokemon names", function()
  local entries = {
    { id = 1, name = "Pokemon 1", ballId = 3552, corpseId = 6076 },
    { id = 2, name = "Pokemon 2", ballId = 2392, corpseId = 12345 },
    { id = 3, name = "Pokemon 3", ballId = 0, corpseId = 99999 }
  }
  equal(CorpseTarget.hasConfigured(entries), true)
  local matched, name, ball = CorpseTarget.resolve(12345, entries)
  equal(matched, true)
  equal(name, "Pokemon 2")
  equal(ball, 2392)
  equal(CorpseTarget.resolve(99999, entries), false)
end)

check("disabled cards do not take part in the capture", function()
  local entries = {
    { id = 1, name = "Pokemon 1", ballId = 3552, corpseId = 6076, enabled = false },
    { id = 2, name = "Pokemon 2", ballId = 2392, corpseId = 12345 }
  }
  local index = CorpseTarget.buildBallIndex(entries)
  equal(index[6076], nil)
  equal(index[12345], 2392)
  equal(CorpseTarget.resolveIndexed(6076, index), false)
  equal(CorpseTarget.resolve(6076, entries), false)
  local entryIndex = CorpseTarget.buildEntryIndex(entries)
  equal(entryIndex[12345].name, "Pokemon 2")
  equal(entryIndex[6076], nil)
  entries[1].enabled = true
  equal(CorpseTarget.buildBallIndex(entries)[6076], 3552)
  equal(CorpseTarget.hasConfigured({ { ballId = 1, corpseId = 2, enabled = false } }), false)
end)

-- ---------------------------------------------------------------------------
-- CatchStats
-- ---------------------------------------------------------------------------

check("counts sent, confirmed, discarded and balls spent", function()
  local stats = CatchStats.new()
  stats:recordSent(3552)
  stats:recordSent(3552)
  equal(stats:recordConfirmed("Bellsprout", false, 1000), true)
  equal(stats:recordConfirmed("Bellsprout", false, 2000), false)
  equal(stats:recordConfirmed("bellsprout", false, 5000), true)
  equal(stats:recordConfirmed("Shiny Pidgey", true, 6000), true)
  stats:recordDiscard()
  stats:recordBallsSpent(4)
  equal(stats.sent, 2)
  equal(stats.byBall[3552], 2)
  equal(stats.confirmed, 3)
  equal(stats.shinyConfirmed, 1)
  equal(stats.bySpecies["Bellsprout"], 1)
  equal(stats.bySpecies["bellsprout"], 1)
  equal(stats.discarded, 1)
  equal(stats.ballsSpent, 4)
  equal(stats:summary(), "Lancadas 2 | Capturas 3 (1 shiny) | Descartes 1 | Balls gastas 4")
  stats:reset()
  equal(stats.sent, 0)
end)

check("parses the server capture messages", function()
  equal(CatchStats.parseCatchMessage("Voce capturou um Pokemon! (Bellsprout)"), "Bellsprout")
  equal(CatchStats.parseCatchMessage("Voce capturou um Bellsprout!"), "Bellsprout")
  equal(CatchStats.parseCatchMessage("You caught a Shiny Pidgey!"), "Shiny Pidgey")
  equal(CatchStats.parseCatchMessage("O jogador Fulano capturou um Pokemon! (Snorlax)"), nil)
  equal(CatchStats.parseCatchMessage("Voce nao capturou nada"), nil)
  equal(CatchStats.parseBallsSpent("Voce gastou: 3 Ultra Balls, 1 Great Ball."), 4)
  equal(CatchStats.parseBallsSpent("You spent: 2 Poke Balls"), 2)
  equal(CatchStats.parseBallsSpent("Voce gastou: 5 pokebolas"), 5)
  equal(CatchStats.parseBallsSpent("sem nada"), nil)
end)

-- ---------------------------------------------------------------------------
-- StaffGuard
-- ---------------------------------------------------------------------------

check("recognizes staff names by tag or prefix", function()
  equal(StaffGuard.isStaffName("[GM] Alice"), true)
  equal(StaffGuard.isStaffName("GM Bob"), true)
  equal(StaffGuard.isStaffName("Tutor Carla"), true)
  equal(StaffGuard.isStaffName("[Staff] Dan"), true)
  equal(StaffGuard.isStaffName("Gmail Fan"), false)
  equal(StaffGuard.isStaffName("Pidgey"), false)
  equal(StaffGuard.isStaffName(""), false)
end)

check("finds a staff member among creatures by name, known list or flag", function()
  local creatures = {
    { getName = function() return "Pidgey" end },
    { getName = function() return "CM Zed" end }
  }
  equal(StaffGuard.findStaff(creatures), "CM Zed")
  equal(StaffGuard.findStaff({ { getName = function() return "Pidgey" end } }), nil)
  equal(StaffGuard.findStaff({ { getName = function() return "Someone" end } }, { someone = true }), "Someone")
  equal(StaffGuard.findStaff({ { getName = function() return "X" end, isStaff = function() return true end } }), "X")
  equal(StaffGuard.findStaff({ { name = "GOD Root" } }), "GOD Root")
end)

-- ---------------------------------------------------------------------------
-- AutoItem
-- ---------------------------------------------------------------------------

check("normalizes the selected inventory item ID", function()
  local item = { getId = function() return 1234 end }
  equal(AutoItem.normalizeId(item), 1234)
  equal(AutoItem.normalizeId("5678"), 5678)
  equal(AutoItem.normalizeId(0), 0)
end)

check("uses the selected item through the confirmed right-click path", function()
  local selectedItem = { getId = function() return 4321 end }
  local usedItem, confirmed = nil, nil
  local fakeGame = {
    findPlayerItem = function(itemId, subType)
      equal(itemId, 4321)
      equal(subType, -1)
      return selectedItem
    end,
    use = function(item, isConfirmed)
      usedItem = item
      confirmed = isConfirmed
    end
  }
  equal(AutoItem.dispatch(4321, fakeGame), true)
  equal(usedItem, selectedItem)
  equal(confirmed, true)
end)

check("rejects direct use without an item or inventory API", function()
  local ok, reason = AutoItem.dispatch(0, {})
  equal(ok, false)
  equal(reason, "invalid-item-id")
  local unavailable, unavailableReason = AutoItem.dispatch(4321, {})
  equal(unavailable, false)
  equal(unavailableReason, "find-player-item-unavailable")
  local missing, missingReason = AutoItem.dispatch(4321, {
    findPlayerItem = function() return nil end,
    use = function() end
  })
  equal(missing, false)
  equal(missingReason, "item-not-in-inventory")
end)

check("creates a buff snapshot and discovers new or extended buffs", function()
  local before = AutoItem.makeBuffSnapshot({
    { name = "loot", endTime = 10000, value = 10 },
    { name = "experience", endTime = 7000, value = 5 }
  }, 1000)
  local after = AutoItem.makeBuffSnapshot({
    { name = "loot", endTime = 12000, value = 10 },
    { name = "experience", endTime = 5000, value = 5 },
    { name = "SweetAroma", endTime = 18000, value = 0 }
  }, 2000)
  local changed = AutoItem.changedBuffNames(before, after, 2000)
  equal(#changed, 2)
  equal(changed[1], "SweetAroma")
  equal(changed[2], "loot")
end)

check("subtracts elapsed time from a buff snapshot", function()
  equal(AutoItem.snapshotRemainingMs({ remainingMs = 5000, receivedAtMs = 1000 }, 2500), 3500)
  equal(AutoItem.snapshotRemainingMs({ remainingMs = 5000, receivedAtMs = 7000 }, 2500), 5000)
  equal(AutoItem.snapshotRemainingMs({ remainingMs = 5000, receivedAtMs = 1000 }, 7000), 0)
end)

check("correlates a buff change only with the consumed learning item", function()
  equal(AutoItem.wasItemConsumed(3, 2), true)
  equal(AutoItem.wasItemConsumed(3, 3), false)
  equal(AutoItem.wasItemConsumed(3, 4), false)
end)

-- ---------------------------------------------------------------------------
-- Contratos do modulo principal e da interface (verificados por texto)
-- ---------------------------------------------------------------------------

check("module is sandboxed and no longer writes generic globals", function()
  local otmod = readFile("autocatch.otmod")
  equal(otmod:find("sandboxed: true", 1, true) ~= nil, true)
  local lua = readFile("autocatch.lua")
  equal(lua:find("_G.autoCatch", 1, true), nil)
  equal(lua:find("io.open(", 1, true), nil)
  equal(lua:find("corpse_registry", 1, true), nil)
end)

check("auto item drop handler is defined before it is wired", function()
  local lua = readFile("autocatch.lua")
  local definition = assert(lua:find("local function onDropAutoItem(", 1, true))
  local usage = assert(lua:find("return onDropAutoItem(card, draggedWidget)", 1, true))
  if definition >= usage then error("onDropAutoItem must be defined before wireAutoItemRow uses it") end
end)

check("throws are guarded by ball availability, staff and confirmed deaths", function()
  local lua = readFile("autocatch.lua")
  equal(lua:find("local useBallId, source = chooseBall(job)", 1, true) ~= nil, true)
  equal(lua:find("corpseClaims:block(job.position, job.itemId", 1, true) ~= nil, true)
  equal(lua:find("Todas as Balls configuradas acabaram", 1, true) ~= nil, true)
  equal(lua:find("unconfirmed = true", 1, true) ~= nil, true)
  equal(lua:find("CFG.UNCONFIRMED_RETRY_LIMIT or CFG.CORPSE_RETRY_LIMIT", 1, true) ~= nil, true)
  equal(lua:find("if not target.unconfirmed then return true end", 1, true) ~= nil, true)
  equal(lua:find("g_map.getSpectators(position, false)", 1, true) ~= nil, true)
  equal(lua:find("onCatchWindow = onCatchWindow", 1, true) ~= nil, true)
  equal(lua:find("onTextMessage = onTextMessage", 1, true) ~= nil, true)
  equal(lua:find("pacer:nextDelay(currentPing(), catchIntervalMinimum, catchIntervalMaximum)", 1, true) ~= nil, true)
  equal(lua:find("AUTO_ITEM_MAX_LEARNING_ATTEMPTS = 3", 1, true) ~= nil, true)
  equal(lua:find("AUTO_ITEM_RETRY_MS = 15000", 1, true) ~= nil, true)
  equal(lua:find("local okExec, errorMessage = AutoItem.dispatch(card.itemId, g_game)", 1, true) ~= nil, true)
  equal(lua:find("onPlayerBuffsReceived = onAutoItemBuffsReceived", 1, true) ~= nil, true)
  equal(lua:find("nao encontrado na mochila", 1, true) ~= nil, true)
  equal(lua:find("Configure um item da mochila antes de ativar o card.", 1, true) ~= nil, true)
  equal(lua:find("snapshotTileItems", 1, true), nil)
end)

check("interface exposes the new controls and drops the enter shortcut", function()
  local otui = readFile("autocatch.otui")
  for _, id in ipairs({ "statsLine", "shinyBallSlot", "selectShinyBall", "clearShinyBall", "reserveBallSlot",
    "selectReserveBall", "clearReserveBall", "entryEnabled", "staffGuard", "autoRearm", "itemEnabled", "deleteItem" }) do
    equal(otui:find("id: " .. id, 1, true) ~= nil, true)
  end
  equal(otui:find("@onEnter", 1, true), nil)
  equal(otui:find("anchors.top: specialRulesCard.bottom", 1, true) ~= nil, true)
  equal(otui:find("tooltip: Arraste um item real da mochila para este card", 1, true) ~= nil, true)
  local rowPosition = assert(otui:find("AutoCatchEntryRow < AutoCatchCard", 1, true))
  local utilsPosition = assert(otui:find("id: tabUtilsContent", 1, true))
  if rowPosition <= utilsPosition then error("AutoCatchEntryRow must be declared after the AutoCatchPanel contents") end
end)

check("exports the server buff timer API", function()
  local lua = readFile("../game_buffs/playerbuffs.lua")
  equal(lua:find("modules.game_buffs.getBuffRemainingMs", 1, true) ~= nil, true)
  equal(lua:find("modules.game_buffs.getBuffSnapshot", 1, true) ~= nil, true)
  equal(lua:find("receivedAtMs", 1, true) ~= nil, true)
end)

check("does not use the Action Bar API for Auto Item", function()
  local lua = readFile("auto_item.lua")
  equal(lua:find("useInventoryItem", 1, true), nil)
  equal(lua:find("gameApi.use(item, true)", 1, true) ~= nil, true)
end)

print(string.format("RESULT %d passed, %d failed", passed, failed))
if failed > 0 then error("Auto Catch tests failed") end
