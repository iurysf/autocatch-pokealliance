-- Testa autocatch.lua de ponta a ponta em um cliente falso (tests/fake_client.lua).
local source = debug.getinfo(1, "S").source
local testDirectory = source:sub(1, 1) == "@" and source:sub(2):match("^(.*)[/\\]") or "."
local moduleDir = testDirectory .. "/.."
local Fake = dofile(testDirectory .. "/fake_client.lua")

local passed, failed = 0, 0
local function check(name, fn)
  local ok, message = pcall(fn)
  if ok then passed = passed + 1; print("PASS " .. name)
  else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(message)) end
end
local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%sexpected %s, got %s", label and (label .. ": ") or "", tostring(expected), tostring(actual)), 2)
  end
end
local function contains(list, needle)
  for _, line in ipairs(list) do if tostring(line):find(needle, 1, true) then return true end end
  return false
end

-- Card list as saved in g_settings (inside an object: OTML splits a "[...]" value).
local function savedList(fake, key)
  local decoded = fake.env.json.decode(fake.settings[key])
  if type(decoded.list) ~= "table" then error(key .. " was not saved inside an object", 2) end
  return decoded.list
end

local BALL, CORPSE, SHINY_BALL, RESERVE_BALL = 3552, 6076, 4000, 4100

-- Cria o cliente falso com um card configurado e o modulo carregado e ligado.
local function boot(options)
  options = options or {}
  local fake = Fake.new()
  fake.moduleDir = moduleDir
  fake.inventory[BALL] = options.balls or 50
  if options.reserve then fake.inventory[RESERVE_BALL] = options.reserve end
  if options.shinyBalls then fake.inventory[SHINY_BALL] = options.shinyBalls end
  fake.settings.autoCatchCorpseEntries = fake.env.json.encode({ { id = 1, ballId = BALL, corpseId = CORPSE, enabled = true } })
  fake.settings.autoCatchQueueIntervalMin = options.intervalMin or 200
  fake.settings.autoCatchQueueIntervalMax = options.intervalMax or 200
  if options.shinyBall then fake.settings.autoCatchShinyBallId = SHINY_BALL end
  if options.reserve then fake.settings.autoCatchReserveBallId = RESERVE_BALL end
  if options.staffGuard ~= nil then fake.settings.autoCatchStaffGuard = options.staffGuard end
  if options.autoRearm then fake.settings.autoCatchAutoRearm = true end
  if options.wasEnabled then fake.settings.autoCatchWasEnabled = true end
  local api = fake:load(moduleDir .. "/autocatch.lua")
  api.init()
  api.show()
  if options.enable ~= false then api.setEnabled(true) end
  return fake, api
end

-- o servidor consome o corpo quando a Ball chega
local function consumeOnThrow(fake)
  fake.onUse = function(_, thing)
    local pos = thing:getPosition()
    local tile = fake:tile(pos)
    for index = #tile.items, 1, -1 do
      if tile.items[index].id == thing:getId() then table.remove(tile.items, index); return end
    end
  end
end

local function corpseNear(fake, dx, dy)
  local pos = { x = fake.playerPos.x + (dx or 1), y = fake.playerPos.y + (dy or 0), z = fake.playerPos.z }
  return fake:addItem(pos, CORPSE, "corpo"), pos
end

check("module loads sandboxed, opens the window and enables with a configured card", function()
  local fake, api = boot()
  equal(api.isEnabled(), true)
  equal(type(api.isBusy), "function")
  equal(type(api.pause), "function")
  equal(type(api.createEmbeddedPanel), "function")
  equal(fake.env.setEnabled, api.setEnabled)
end)

check("floor scan throws one ball at a visible corpse and releases the claim when it vanishes", function()
  local fake, api = boot()
  local corpse = corpseNear(fake, 1, 0)
  fake:advance(400)
  equal(#fake.uses, 1)
  equal(fake.uses[1].ballId, BALL)
  equal(fake.uses[1].itemId, CORPSE)
  equal(api.getStats().sent, 1)
  fake:removeItem(corpse)
  fake:advance(3000)
  equal(#fake.uses, 1, "no second throw after the corpse left")
  equal(api.isBusy(), false)
end)

check("a corpse that survives gets one retry, then is blocked instead of looping", function()
  local fake, api = boot()
  corpseNear(fake, 1, 0)
  fake:advance(80000)
  equal(#fake.uses, 2, "exactly two throws while the corpse is blocked")
  equal(api.getStats().discarded, 1)
  fake:advance(30000)
  equal(#fake.uses, 4, "block expires and the corpse gets another pair of tries")
end)

check("without balls nothing is sent and the module disables itself", function()
  local fake, api = boot({ balls = 0 })
  corpseNear(fake, 1, 0)
  fake:advance(5000)
  equal(#fake.uses, 0)
  equal(api.isEnabled(), false)
  equal(contains(fake.log, "acabaram"), true)
end)

check("reserve ball is used when the card ball runs out", function()
  local fake, api = boot({ balls = 0, reserve = 5 })
  corpseNear(fake, 1, 0)
  fake:advance(500)
  equal(#fake.uses, 1)
  equal(fake.uses[1].ballId, RESERVE_BALL)
  equal(api.isEnabled(), true)
end)

check("shiny death routes the corpse to the shiny ball even if the scan sees it first", function()
  local fake = boot({ shinyBall = true, shinyBalls = 3 })
  local pos = { x = fake.playerPos.x + 2, y = fake.playerPos.y, z = fake.playerPos.z }
  local shiny = fake:creature({ name = "Shiny Rattata", position = pos, shiny = true })
  fake:appear(shiny)
  fake:health(shiny, 40)
  fake:health(shiny, 0)
  fake:addItem(pos, CORPSE, "corpo")
  fake:disappear(shiny)
  fake:advance(600)
  equal(#fake.uses, 1)
  equal(fake.uses[1].ballId, SHINY_BALL)
end)

check("a shiny whose corpse already got its ball from the floor scan stops holding the cavebot", function()
  -- 24/09 22:54+: the scan threw first, and the death search, blind to a
  -- claimed corpse, held the bot for the rest of its 5 s after every shiny.
  local fake, api = boot({ shinyBall = true, shinyBalls = 3 })
  local pos = { x = fake.playerPos.x + 3, y = fake.playerPos.y, z = fake.playerPos.z }
  local shiny = fake:creature({ name = "Shiny Rattata", position = pos, shiny = true })
  fake:appear(shiny)
  fake:health(shiny, 40)
  fake:addItem(pos, CORPSE, "corpo")
  fake:advance(600)
  equal(#fake.uses, 1, "the floor scan threw at the corpse")
  fake:health(shiny, 0)
  fake:disappear(shiny)
  fake:advance(300)
  equal(#api.getPendingPositions(), 0, "the death finds its corpse already handled")
end)

check("a ball keeps Auto Catch busy until its result is checked, without a position to hold", function()
  -- 25/09 audit (A6): busy ended 800 ms after the ball, the CaveBot dropped its
  -- leash and the retry at 1.8 s went out with the trainer 9-15 squares away.
  local fake, api = boot()
  consumeOnThrow(fake)
  corpseNear(fake, 3, 0)
  local waited = 0
  while #fake.uses == 0 and waited < 2000 do fake:advance(50); waited = waited + 50 end
  equal(#fake.uses, 1)
  fake:advance(1000)
  equal(api.isBusy(), true, "the result comes at 1.8 s: a second ball may still be needed")
  equal(#api.getPendingPositions(), 0, "nothing to stand still for while the ball flies")
  fake:advance(1000)
  equal(api.isBusy(), false, "corpse gone: caught")
end)

check("a shiny caught before its death reached the client stops holding at once", function()
  -- 25/09 audit (B4): the ball goes out before the HP-0 update; the death
  -- then searched an empty tile for 5 s and held the CaveBot (26 s in 65 min).
  local fake, api = boot({ shinyBall = true, shinyBalls = 3 })
  consumeOnThrow(fake)
  local pos = { x = fake.playerPos.x + 3, y = fake.playerPos.y, z = fake.playerPos.z }
  local shiny = fake:creature({ name = "Shiny Rattata", position = pos, shiny = true })
  fake:appear(shiny)
  fake:health(shiny, 40)
  fake:addItem(pos, CORPSE, "corpo")
  fake:advance(600)
  equal(#fake.uses, 1, "the floor scan caught the corpse first")
  fake:health(shiny, 0)
  fake:disappear(shiny)
  fake:advance(300)
  equal(#api.getPendingPositions(), 0, "the death finds its tile already handled")

  -- A shiny recorded one step off the tile that got the ball counts as handled
  -- too; a common death next to it keeps searching its own tile.
  local nextTo = { x = pos.x + 1, y = pos.y, z = pos.z }
  local offset = fake:creature({ name = "Shiny Rattata", position = nextTo, shiny = true })
  fake:appear(offset)
  fake:health(offset, 0)
  fake:disappear(offset)
  fake:advance(300)
  equal(#api.getPendingPositions(), 0, "one step off, still the same ball")
end)

check("a queued corpse left out of reach waits for the trainer to come back", function()
  -- 24/09 20:05 and 21:59: the retry of a shiny ball found the trainer 11
  -- squares away and the corpse was dropped when the 5 s window closed.
  local fake = boot({ shinyBall = true, shinyBalls = 3 })
  local home = { x = fake.playerPos.x, y = fake.playerPos.y, z = fake.playerPos.z }
  local pos = { x = home.x + 3, y = home.y, z = home.z }
  local shiny = fake:creature({ name = "Shiny Rattata", position = pos, shiny = true })
  fake:appear(shiny)
  fake:health(shiny, 0)
  fake:addItem(pos, CORPSE, "corpo")
  fake:disappear(shiny)
  fake:advance(600)
  equal(#fake.uses, 1, "first ball while in reach")
  fake.playerPos = { x = home.x - 9, y = home.y, z = home.z }
  fake:advance(6000)
  equal(#fake.uses, 1, "12 squares away: no ball")
  equal(contains(fake.log, "Corpo descartado"), false, "still waiting past the 5 s window")
  fake.playerPos = home
  fake:advance(600)
  equal(#fake.uses, 2, "back in reach: the retry goes out")
end)

check("normal death keeps the card ball", function()
  local fake = boot({ shinyBall = true, shinyBalls = 3 })
  local pos = { x = fake.playerPos.x + 2, y = fake.playerPos.y, z = fake.playerPos.z }
  local monster = fake:creature({ name = "Rattata", position = pos })
  fake:appear(monster)
  fake:health(monster, 0)
  fake:addItem(pos, CORPSE, "corpo")
  fake:disappear(monster)
  fake:advance(600)
  equal(#fake.uses, 1)
  equal(fake.uses[1].ballId, BALL)
end)

check("monster leaving the screen does not block the cavebot nor spam the status", function()
  local fake, api = boot()
  fake:advance(200)
  local pos = { x = fake.playerPos.x + 3, y = fake.playerPos.y, z = fake.playerPos.z }
  local monster = fake:creature({ name = "Rattata", position = pos })
  fake:appear(monster)
  fake:health(monster, 80)
  fake:disappear(monster)
  fake:advance(50)
  equal(api.isBusy(), false, "unconfirmed disappearance must not hold the cavebot")
  fake:advance(6000)
  equal(contains(fake.log, "nao identificado"), false)
  equal(#fake.uses, 0)
end)

check("confirmed death with no corpse logs the diagnostic once", function()
  local fake, api = boot()
  local pos = { x = fake.playerPos.x + 3, y = fake.playerPos.y, z = fake.playerPos.z }
  local monster = fake:creature({ name = "Rattata", position = pos })
  fake:appear(monster)
  fake:health(monster, 0)
  fake:disappear(monster)
  fake:advance(50)
  equal(api.isBusy(), true, "confirmed death holds the cavebot while searching")
  fake:advance(6000)
  equal(contains(fake.log, "nao identificado"), true)
  equal(api.isBusy(), false)
end)

check("a species that never leaves a configured corpse stops holding the cavebot; shinies and caught species still do", function()
  local fake, api = boot({ shinyBall = true, shinyBalls = 3 })
  local function die(name, withCorpse, shiny)
    local pos = { x = fake.playerPos.x + 3, y = fake.playerPos.y, z = fake.playerPos.z }
    local monster = fake:creature({ name = name, position = pos, shiny = shiny })
    fake:appear(monster)
    fake:health(monster, 0)
    if withCorpse then fake:addItem(pos, CORPSE, "corpo") end
    fake:disappear(monster)
    fake:advance(50)
    local busy = api.isBusy()
    fake:advance(6000)
    return busy
  end
  for index = 1, 3 do equal(die("Magneton"), true, "death " .. index .. " still holds (no evidence yet)") end
  equal(die("Magneton"), false, "24/09: 304 holds for corpses never caught")
  equal(#api.getPendingPositions(), 0)
  equal(die("Shiny Magneton", false, true), true, "a shiny always holds")
  equal(die("Rattata", true), true, "a species with a configured corpse keeps holding")
end)

check("a configured corpse on a neighbour tile or a rare hit does not keep a corpseless species holding", function()
  local fake, api = boot({ shinyBall = true, shinyBalls = 3 })
  local function die(name, corpseOffset)
    local pos = { x = fake.playerPos.x + 3, y = fake.playerPos.y, z = fake.playerPos.z }
    local monster = fake:creature({ name = name, position = pos })
    fake:appear(monster)
    fake:health(monster, 0)
    if corpseOffset then
      fake:addItem({ x = pos.x + corpseOffset, y = pos.y, z = pos.z }, CORPSE, "corpo")
    end
    fake:disappear(monster)
    fake:advance(50)
    local busy = api.isBusy()
    fake:advance(6000)
    return busy
  end
  -- 24/09: a shiny corpse next to a common Magneton in the pack was matched to
  -- it, and that one hit kept all common deaths holding the bot.
  equal(die("Magneton", 1), true, "the neighbour corpse is still caught")
  equal(#fake.uses >= 1, true, "a ball goes to the neighbour corpse")
  for index = 1, 3 do die("Magneton") end
  equal(die("Magneton"), false, "the neighbour corpse was not evidence for Magneton")
end)

check("a species with configured corpses in under 5% of its deaths stops holding", function()
  local fake, api = boot({ shinyBall = true, shinyBalls = 3 })
  local step = 0
  local function die(withCorpse)
    step = step + 1
    -- The death with a corpse stays out of the other deaths' search radius.
    local pos = { x = fake.playerPos.x + 1 + (step % 5), y = fake.playerPos.y + math.floor(step / 5) % 5 - 2,
      z = fake.playerPos.z }
    if withCorpse then pos = { x = fake.playerPos.x - 4, y = fake.playerPos.y, z = fake.playerPos.z } end
    local monster = fake:creature({ name = "Magneton", position = pos })
    fake:appear(monster)
    fake:health(monster, 0)
    if withCorpse then fake:addItem(pos, CORPSE, "corpo") end
    fake:disappear(monster)
    fake:advance(50)
    local busy = api.isBusy()
    fake:advance(6000)
    return busy
  end
  equal(die(true), true)
  for _ = 1, 20 do die(false) end
  equal(die(false), true, "1 hit against 20 misses is not below 5%")
  equal(die(false), false, "1 hit against 21 misses is below 5%")
end)

check("deaths with no configured corpse: one full line, then a summary every 10 minutes, all counted", function()
  local fake, api = boot()
  local function die(dx)
    local pos = { x = fake.playerPos.x + dx, y = fake.playerPos.y, z = fake.playerPos.z }
    local monster = fake:creature({ name = "Magneton", position = pos })
    fake:appear(monster)
    fake:health(monster, 0)
    fake:disappear(monster)
    fake:advance(6000)
  end
  local function lines(text)
    local n = 0
    for _, line in ipairs(fake.log) do if tostring(line):find(text, 1, true) then n = n + 1 end end
    return n
  end
  die(3)
  die(2)
  equal(lines("Corpo de Magneton nao identificado em"), 1, "the first one in full (2,700 an hour on 24/09)")
  equal(lines("nao identificado mais"), 0)
  fake:advance(600000)
  die(3)
  equal(lines("Corpo de Magneton nao identificado mais 2 vez(es)"), 1, "then one summary line")
  equal(api.getStats().deaths, 3, "every death still counted for the CaveBot log")
end)

check("a death that is not shiny holds the cavebot only briefly while the search goes on", function()
  local fake, api = boot()
  local pos = { x = fake.playerPos.x + 3, y = fake.playerPos.y, z = fake.playerPos.z }
  local monster = fake:creature({ name = "Magneton", position = pos })
  fake:appear(monster)
  fake:health(monster, 0)
  fake:disappear(monster)
  fake:advance(50)
  equal(api.isBusy(), true, "right after the death")
  equal(#api.getPendingPositions(), 1)
  fake:advance(1300)
  equal(api.isBusy(), false, "1.2 s later the cavebot may walk on")
  equal(#api.getPendingPositions(), 0)
  fake:advance(5000)
  equal(contains(fake.log, "nao identificado"), true, "the search itself still runs to the end")
end)

check("a shiny death holds the cavebot for the whole corpse search", function()
  local fake, api = boot({ shinyBall = true, shinyBalls = 3 })
  local pos = { x = fake.playerPos.x + 3, y = fake.playerPos.y, z = fake.playerPos.z }
  local shiny = fake:creature({ name = "Shiny Magneton", position = pos, shiny = true })
  fake:appear(shiny)
  fake:health(shiny, 0)
  fake:disappear(shiny)
  fake:advance(2000)
  equal(api.isBusy(), true, "still searching the shiny corpse")
  equal(#api.getPendingPositions(), 1)
end)

check("staff on screen holds every throw and releases when it leaves", function()
  local fake, api = boot()
  consumeOnThrow(fake)
  fake.spectators = { fake:creature({ name = "[GM] Fiscal", monster = false }) }
  corpseNear(fake, 1, 0)
  fake:advance(3000)
  equal(#fake.uses, 0)
  equal(api.isBusy(), false, "held autocatch must not block the cavebot")
  fake.spectators = {}
  fake:advance(3000)
  equal(#fake.uses, 1)
end)

check("staff guard can be turned off", function()
  local fake = boot({ staffGuard = false })
  consumeOnThrow(fake)
  fake.spectators = { fake:creature({ name = "GM Fiscal", monster = false }) }
  corpseNear(fake, 1, 0)
  fake:advance(1000)
  equal(#fake.uses, 1)
end)

check("pause and resume from another module", function()
  local fake, api = boot()
  consumeOnThrow(fake)
  api.pause("teste")
  equal(api.isPaused(), true)
  corpseNear(fake, 1, 0)
  fake:advance(2000)
  equal(#fake.uses, 0)
  api.resume()
  fake:advance(2000)
  equal(#fake.uses, 1)
end)

check("throws respect the configured interval and are sorted by distance", function()
  local fake = boot()
  consumeOnThrow(fake)
  corpseNear(fake, 4, 0)
  corpseNear(fake, 1, 0)
  corpseNear(fake, 2, 1)
  fake:advance(5000)
  equal(#fake.uses, 3)
  equal(fake.uses[1].position.x, fake.playerPos.x + 1)
  equal(fake.uses[2].position.x, fake.playerPos.x + 2)
  equal(fake.uses[3].position.x, fake.playerPos.x + 4)
  if fake.uses[2].at - fake.uses[1].at < 200 then error("second throw came too early") end
  if fake.uses[3].at - fake.uses[2].at < 200 then error("third throw came too early") end
end)

check("a long queue waits the drawn interval between every ball and adds the short pause", function()
  local fake = boot({ intervalMin = 900, intervalMax = 1100 })
  consumeOnThrow(fake)
  local placed = 0
  for dx = -3, 3 do
    for _, dy in ipairs({ -1, 1 }) do
      corpseNear(fake, dx, dy)
      placed = placed + 1
    end
  end
  fake:advance(60000)
  equal(#fake.uses, placed, "every corpse got its ball")
  local pauses = 0
  for index = 2, #fake.uses do
    local gap = fake.uses[index].at - fake.uses[index - 1].at
    if gap < 900 then error(string.format("ball %d came %d ms after the previous one (minimum 900)", index, gap)) end
    if gap > 1100 then
      -- Short pause: the drawn interval plus 400-900 ms.
      if gap < 900 + 400 or gap > 1100 + 900 then
        error(string.format("ball %d waited %d ms, outside interval + short pause", index, gap))
      end
      pauses = pauses + 1
    end
  end
  if pauses < 1 then error("14 balls must include at least one short pause (every 6-12 throws)") end
end)

check("intervals above the old 2000 ms ceiling are kept and respected (5-6 s)", function()
  local fake = boot({ intervalMin = 5000, intervalMax = 6000 })
  consumeOnThrow(fake)
  corpseNear(fake, 1, 0)
  corpseNear(fake, 2, 0)
  corpseNear(fake, 3, 0)
  fake:advance(30000)
  equal(#fake.uses, 3)
  for index = 2, 3 do
    local gap = fake.uses[index].at - fake.uses[index - 1].at
    if gap < 5000 then error(string.format("ball %d came %d ms after the previous one (minimum 5000)", index, gap)) end
  end
  equal(fake.settings.autoCatchQueueIntervalMax, 6000, "the saved interval was not reset to the defaults")
end)

check("a queued corpse that left the screen vertically gets no ball until it is back", function()
  local fake, api = boot()
  consumeOnThrow(fake)
  corpseNear(fake, 1, 0)
  corpseNear(fake, 0, 5)
  fake:advance(150)
  equal(#fake.uses, 1, "the nearest corpse first")
  -- One step north: the second corpse is 6 squares below, off screen.
  fake.playerPos = { x = fake.playerPos.x, y = fake.playerPos.y - 1, z = fake.playerPos.z }
  fake:advance(2000)
  equal(#fake.uses, 1, "no throw at a corpse off screen")
  equal(#api.getPendingPositions() > 0, true, "still pending for the CaveBot")
  fake.playerPos = { x = fake.playerPos.x, y = fake.playerPos.y + 1, z = fake.playerPos.z }
  fake:advance(2000)
  equal(#fake.uses, 2, "back on screen: thrown")
end)

check("server confirmation messages feed the session statistics", function()
  local fake, api = boot()
  fake:gameEvent("onCatchWindow", "Rattata", 100, 5, 0)
  fake:gameEvent("onTextMessage", 1, "Voce gastou: 3 Ultra Balls")
  fake:gameEvent("onTextMessage", 1, "Voce capturou um Pokemon! (Pidgey)")
  local stats = api.getStats()
  equal(stats.confirmed, 2)
  equal(stats.ballsSpent, 3)
  equal(stats.bySpecies["Rattata"], 1)
end)

check("re-arms after login when the option is on and it was enabled before logout", function()
  local fake, api = boot({ autoRearm = true })
  fake.online = false
  fake:gameEvent("onGameEnd")
  equal(api.isEnabled(), false)
  equal(fake.settings.autoCatchWasEnabled, true)
  fake.online = true
  fake:gameEvent("onGameStart")
  fake:advance(5000)
  equal(api.isEnabled(), true)
end)

check("does not re-arm when the option is off", function()
  local fake, api = boot()
  fake.online = false
  fake:gameEvent("onGameEnd")
  fake.online = true
  fake:gameEvent("onGameStart")
  fake:advance(5000)
  equal(api.isEnabled(), false)
end)

check("auto item stops after three uses without a new buff", function()
  local fake, api = boot({ enable = false })
  fake.inventory[777] = 10
  fake.env.modules.game_buffs = { getBuffSnapshot = function() return {} end, getBuffRemainingMs = function() return 0 end }
  fake.settings.autoCatchAutoItems = fake.env.json.encode({ { cardId = 1, itemId = 777, buffNames = {}, enabled = true } })
  fake.settings.autoCatchAutoItemNextId = 1
  -- recarrega o modulo com o card salvo
  api.terminate()
  fake.gameHandlers, fake.creatureHandlers = {}, {}
  api = fake:load(moduleDir .. "/autocatch.lua")
  api.init()
  fake:advance(90000)
  equal(fake.itemUses, 3)
  equal(fake.inventory[777], 7)
  local saved = savedList(fake, "autoCatchAutoItems")
  equal(saved[1].enabled, false)
  equal(contains(fake.log, "card desativado"), true)
end)

-- Servidor de buffs falso: guarda os buffs, responde ao modulo game_buffs e
-- manda a lista inteira (como o pacote real) em send().
local function buffServer(fake)
  local server = { buffs = {} }
  function server:snapshot()
    local snapshot = {}
    for name, buff in pairs(self.buffs) do
      local left = buff.ms - (fake.time - buff.at)
      if left > 0 then snapshot[name] = { remainingMs = left, value = buff.value, receivedAtMs = fake.time } end
    end
    return snapshot
  end
  function server:active(name) return self:snapshot()[name] ~= nil end
  function server:send(name, ms, value)
    self.buffs[name] = { ms = ms, at = fake.time, value = value or 0 }
    local list = {}
    for buffName, entry in pairs(self:snapshot()) do
      list[#list + 1] = { name = buffName, endTime = entry.remainingMs, value = entry.value }
    end
    fake:gameEvent("onPlayerBuffsReceived", list)
  end
  fake.env.modules.game_buffs = {
    getBuffSnapshot = function() return server:snapshot() end,
    getBuffRemainingMs = function(name) local entry = server:snapshot()[name]; return entry and entry.remainingMs or 0 end
  }
  -- a resposta do servidor chega depois do envio, como na rede
  function server:later(ms, fn) fake.env.scheduleEvent(fn, ms) end
  return server
end

-- Liga um card de Auto Item salvo (item 777, buff ainda desconhecido).
local function bootAutoItem(prepare)
  local fake, api = boot({ enable = false })
  fake.inventory[777] = 10
  local server = buffServer(fake)
  if prepare then prepare(fake, server) end
  fake.settings.autoCatchAutoItems = fake.env.json.encode({ { cardId = 1, itemId = 777, buffNames = {}, enabled = true } })
  fake.settings.autoCatchAutoItemNextId = 1
  api.terminate()
  fake.gameHandlers, fake.creatureHandlers = {}, {}
  api = fake:load(moduleDir .. "/autocatch.lua")
  api.init()
  return fake, api, server
end

check("auto item learns the buff the server sends before removing the item", function()
  local fake, api, server = bootAutoItem()
  fake.env.g_game.use = function(item)
    fake.itemUses = (fake.itemUses or 0) + 1
    server:later(50, function() server:send("experience", 3600000, 50) end)
    server:later(100, function() fake.inventory[777] = fake.inventory[777] - 1 end)
  end
  fake:advance(20000)
  equal(fake.itemUses, 1)
  local saved = savedList(fake, "autoCatchAutoItems")
  equal(saved[1].enabled, true)
  equal(saved[1].buffNames[1], "experience", "on 24/09 this change was ignored as 'nao foi consumido'")
  fake:advance(30 * 60000)
  equal(fake.itemUses, 1, "buff still active: no new use")
end)

check("auto item keeps trying while the server refuses the use and learns once it is accepted", function()
  local fake, api, server = bootAutoItem(function(_, server)
    server.buffs.experience = { ms = 180000, at = 1000, value = 50 }
  end)
  fake.env.g_game.use = function()
    fake.itemUses = (fake.itemUses or 0) + 1
    if server:active("experience") then
      server:later(50, function() fake:gameEvent("onTextMessage", 20, "You already have an active experience boost.") end)
      return
    end
    server:later(50, function()
      fake.inventory[777] = fake.inventory[777] - 1
      server:send("experience", 3600000, 50)
    end)
  end
  fake:advance(170000)
  local saved = savedList(fake, "autoCatchAutoItems")
  equal(saved[1].enabled, true, "refused uses do not disable the card (5958 on 24/09)")
  equal(fake.inventory[777], 10, "nothing was spent")
  equal(fake.itemUses, 3, "one try per minute, not 3 in 45 s")
  equal(contains(fake.log, "nao conta como uso gasto"), true)
  equal(contains(fake.log, "already have an active"), true, "the server answer is logged")
  fake:advance(120000)
  saved = savedList(fake, "autoCatchAutoItems")
  equal(saved[1].buffNames[1], "experience")
  equal(fake.inventory[777], 9)
end)

check("auto item links an item that stays in the backpack after the same buff refreshes twice", function()
  local fake, api, server = bootAutoItem()
  fake.env.g_game.use = function()
    fake.itemUses = (fake.itemUses or 0) + 1
    server:later(50, function() server:send("loot", 10000 + fake.time, 20) end)
  end
  fake:advance(50000)
  local saved = savedList(fake, "autoCatchAutoItems")
  equal(saved[1].buffNames[1], "loot")
  equal(saved[1].enabled, true)
  equal(fake.itemUses, 2)
end)

check("auto item eats food on the character, learns its regeneration and eats again when it ends", function()
  local fake, api = bootAutoItem(function(fake) fake.multiUse = { [777] = true } end)
  local targets = {}
  fake.env.g_game.use = function() error("food needs use with") end
  fake.env.g_game.useWith = function(item, thing)
    targets[#targets + 1] = thing:getId()
    fake.env.scheduleEvent(function()
      fake.inventory[777] = fake.inventory[777] - 1
      fake:gameEvent("onConditionIcon", "add", fake.playerId, 8192, 0, 600000)
    end, 50)
  end
  fake:advance(5000)
  equal(#targets, 1)
  equal(targets[1], fake.playerId, "used on the player, not just clicked")
  local saved = savedList(fake, "autoCatchAutoItems")
  equal(saved[1].buffNames[1], "food")
  equal(contains(fake.log, "no personagem"), true)
  fake:advance(5 * 60000)
  equal(#targets, 1, "regenerating: no food wasted")
  fake:gameEvent("onConditionIcon", "remove", fake.playerId, 8192, 0, 0)
  fake:advance(2000)
  equal(#targets, 2, "the regeneration ended: eats again")
  equal(fake.inventory[777], 8)
end)

check("food regeneration from the player stats works when the server sends no condition", function()
  local fake, api = bootAutoItem(function(fake) fake.multiUse = { [777] = true }; fake.regenerationSeconds = 0 end)
  local uses = 0
  fake.env.g_game.useWith = function()
    uses = uses + 1
    fake.env.scheduleEvent(function()
      fake.inventory[777] = fake.inventory[777] - 1
      fake.regenerationSeconds = 300
    end, 50)
  end
  fake:advance(5000)
  local saved = savedList(fake, "autoCatchAutoItems")
  equal(saved[1].buffNames[1], "food")
  fake:advance(290000)
  equal(uses, 1, "300 s of regeneration counted down from the stats")
  fake:advance(15000)
  equal(uses, 2)
end)

-- What OTML keeps of a "[...]" value after a restart: the comma pieces.
local function otmlPieces(text)
  local pieces = {}
  for piece in (text:sub(2, -2) .. ","):gmatch("([^,]*),") do pieces[#pieces + 1] = piece end
  return pieces
end

check("auto item cards and their buffs survive a restart with the list OTML split (24/09)", function()
  local fake, api = boot({ enable = false })
  -- Every start on 24/09 loaded one card from the legacy keys, with no buff.
  fake.settings.autoCatchAutoItems = nil
  fake.settingsLists = { autoCatchAutoItems = otmlPieces(
    '[{"buffNames":["experience","loot","shiny_appear"],"itemId":5958,"state":"active","enabled":true,"cardId":1},' ..
    '{"buffNames":["food"],"itemId":169,"state":"active","enabled":true,"cardId":8}]') }
  fake.settings.autoCatchAutoItemId = 5958
  fake.settings.autoCatchAutoItemEnabled = true
  fake.settings.autoCatchAutoItemNextId = 8
  api.terminate()
  fake.gameHandlers, fake.creatureHandlers = {}, {}
  api = fake:load(moduleDir .. "/autocatch.lua")
  api.init()
  local cards = savedList(fake, "autoCatchAutoItems")
  equal(#cards, 2, "the food card is still there")
  equal(cards[1].buffNames[1], "experience", "the voucher keeps its buffs")
  equal(cards[2].itemId, 169)
  equal(contains(fake.log, "recuperados do formato antigo: 2"), true)
end)

check("auto item logs only the server's first answer to a use, never experience or loot", function()
  local fake = bootAutoItem(function(fake, server)
    fake.env.MessageModes = { Exp = 24, ExpOthers = 27, Loot = 29 }
    server.buffs.experience = { ms = 180000, at = 1000, value = 50 }
  end)
  fake.env.g_game.use = function()
    fake.itemUses = (fake.itemUses or 0) + 1
    fake.env.scheduleEvent(function()
      fake:gameEvent("onTextMessage", 24, "Voce ganhou 2699 pontos de experiencia.")
      fake:gameEvent("onTextMessage", 29, "Loot de Magneton: 6 screws e 6 pieces of steel.")
      fake:gameEvent("onTextMessage", 20, "Voce ja tem um bonus ativo.")
      fake:gameEvent("onTextMessage", 20, "Outra mensagem qualquer.")
    end, 20)
  end
  fake:advance(3000)
  local answers = {}
  for _, line in ipairs(fake.log) do
    if tostring(line):find("Servidor apos usar", 1, true) then answers[#answers + 1] = line end
  end
  equal(#answers, 1)
  equal(tostring(answers[1]):find("bonus ativo", 1, true) ~= nil, true)
end)

check("disabling a card stops its corpse from being caught", function()
  local fake, api = boot()
  fake.settings.autoCatchCorpseEntries = fake.env.json.encode({ { id = 1, ballId = BALL, corpseId = CORPSE, enabled = false } })
  api.terminate()
  fake.gameHandlers, fake.creatureHandlers = {}, {}
  api = fake:load(moduleDir .. "/autocatch.lua")
  api.init()
  api.setEnabled(true)
  equal(api.isEnabled(), false, "no active card means it cannot enable")
end)


-- ---------------------------------------------------------------------------
-- Interface: cards, slots, selecao, intervalo
-- ---------------------------------------------------------------------------

local function panelOf(fake)
  -- a janela standalone e o ultimo widget criado pelo show(); os ids sao resolvidos sob demanda
  return fake.lastWindow
end

check("cards can be added, dropped on, toggled and deleted from the interface", function()
  local fake, api = boot({ enable = false })
  local window = fake.window
  local entriesList = window:recursiveGetChildById('entriesList')
  equal(#entriesList.children, 1)
  api.addNewPokemon()
  equal(#entriesList.children, 2)
  local row = entriesList.children[2]
  local ballSlot = row:recursiveGetChildById('ballSlot')
  local dragged = { currentDragThing = fake:tile(fake.playerPos):getItems()[1] }
  fake:addItem(fake.playerPos, 9999, 'ball')
  dragged.currentDragThing = fake:tile(fake.playerPos):getItems()[1]
  equal(ballSlot.onDrop(ballSlot, dragged), true)
  local saved = savedList(fake, "autoCatchCorpseEntries")
  equal(saved[2].ballId, 9999)
  local enabledBox = row:recursiveGetChildById('entryEnabled')
  enabledBox.onCheckChange(enabledBox, false)
  saved = savedList(fake, "autoCatchCorpseEntries")
  equal(saved[2].enabled, false)
  local deleteButton = row:recursiveGetChildById('deleteEntry')
  deleteButton.onClick(deleteButton)
  saved = savedList(fake, "autoCatchCorpseEntries")
  equal(#saved, 1)
  equal(#entriesList.children, 1)
end)

check("ball and corpse selection through the mouse grabbers", function()
  local fake, api = boot({ enable = false })
  local window = fake.window
  fake:addItem(fake.playerPos, 8888, 'ball')
  local backpackItem = fake:tile(fake.playerPos):getItems()[1]
  local corpsePos = { x = fake.playerPos.x + 1, y = fake.playerPos.y, z = fake.playerPos.z }
  fake:addItem(corpsePos, 7777, 'corpo')
  -- painel raiz falso: um clique cai num UIItem da mochila ou no mapa
  local mapWidget = { getClassName = function() return 'UIGameMap' end, getTile = function() return fake:tile(corpsePos) end, getParent = function() return nil end }
  local itemWidget = { getClassName = function() return 'UIItem' end, isVirtual = function() return false end, getItem = function() return backpackItem end, getParent = function() return nil end }
  local clickTarget = itemWidget
  fake.env.modules.game_interface.getRootPanel = function()
    return { recursiveGetChildByPos = function() return clickTarget end }
  end
  local row = window:recursiveGetChildById('entriesList').children[1]
  local selectBall = row:recursiveGetChildById('selectBall')
  selectBall.onClick(selectBall)
  local grabber = fake.lastGrabber
  equal(grabber ~= nil, true)
  grabber.onMouseRelease(grabber, { x = 1, y = 1 }, 1)
  equal(savedList(fake, "autoCatchCorpseEntries")[1].ballId, 8888)
  clickTarget = mapWidget
  local selectCorpse = row:recursiveGetChildById('selectCorpse')
  selectCorpse.onClick(selectCorpse)
  grabber = fake.lastGrabber
  grabber.onMouseRelease(grabber, { x = 1, y = 1 }, 1)
  equal(savedList(fake, "autoCatchCorpseEntries")[1].corpseId, 7777)
  -- shiny e reserva pelos botoes
  clickTarget = itemWidget
  local selectShiny = window:recursiveGetChildById('selectShinyBall')
  selectShiny.onClick(selectShiny)
  fake.lastGrabber.onMouseRelease(fake.lastGrabber, { x = 1, y = 1 }, 1)
  equal(fake.settings.autoCatchShinyBallId, 8888)
  local selectReserve = window:recursiveGetChildById('selectReserveBall')
  selectReserve.onClick(selectReserve)
  fake.lastGrabber.onMouseRelease(fake.lastGrabber, { x = 1, y = 1 }, 1)
  equal(fake.settings.autoCatchReserveBallId, 8888)
  local clearShiny = window:recursiveGetChildById('clearShinyBall')
  clearShiny.onClick(clearShiny)
  equal(fake.settings.autoCatchShinyBallId, 0)
end)

check("interval edits validate while typing and save on enter or focus loss", function()
  local fake = boot({ enable = false })
  local window = fake.window
  local minEdit = window:recursiveGetChildById('catchIntervalMinEdit')
  local maxEdit = window:recursiveGetChildById('catchIntervalMaxEdit')
  local savesBefore = fake.saves or 0
  equal(minEdit:getText(), '0,2', "the panel shows seconds")
  minEdit:setText('0,01'); minEdit.onTextChange(minEdit)
  equal(minEdit.color, '#ff7676', "below 0,05 s is invalid")
  equal(fake.saves or 0, savesBefore, "typing must not save")
  minEdit:setText('0,35'); minEdit.onTextChange(minEdit)
  maxEdit:setText('0.7'); maxEdit.onTextChange(maxEdit)
  equal(minEdit.color, '#dbe5ec')
  equal(fake.settings.autoCatchQueueIntervalMin, 200, "still not saved before confirming")
  equal(minEdit.onKeyPress(minEdit, 13), true)
  equal(fake.settings.autoCatchQueueIntervalMin, 350)
  equal(fake.settings.autoCatchQueueIntervalMax, 700)
  -- Seconds, with no 2000 ms ceiling: 5 = 5000 ms.
  maxEdit:setText('5'); maxEdit.onTextChange(maxEdit)
  maxEdit.onFocusChange(maxEdit, false)
  equal(fake.settings.autoCatchQueueIntervalMax, 5000)
  local presetTurbo = window:recursiveGetChildById('presetTurbo')
  presetTurbo.onClick(presetTurbo)
  equal(fake.settings.autoCatchQueueIntervalMin, 80)
  equal(fake.settings.autoCatchQueueIntervalMax, 180)
  equal(minEdit:getText(), '0,08')
  equal(maxEdit:getText(), '0,18')
end)

local function speedWidgets(fake)
  local window = fake.window
  return window:recursiveGetChildById('catchIntervalMinEdit'), window:recursiveGetChildById('catchIntervalMaxEdit'),
    function(id) local button = window:recursiveGetChildById(id); button.onClick(button) end, window
end

local function typeInterval(minEdit, maxEdit, minimum, maximum)
  minEdit:setText(minimum); minEdit.onTextChange(minEdit)
  maxEdit:setText(maximum); maxEdit.onTextChange(maxEdit)
end

check("a valid custom interval is saved by itself shortly after typing", function()
  local fake, api = boot({ enable = false })
  local minEdit, maxEdit, _, window = speedWidgets(fake)
  typeInterval(minEdit, maxEdit, '2', '3,5')
  equal(window:recursiveGetChildById('intervalSaveStatus').text:find('Nao salvo', 1, true) ~= nil, true)
  fake:advance(900)
  equal(fake.settings.autoCatchQueueIntervalMin, 2000)
  equal(fake.settings.autoCatchQueueIntervalMax, 3500)
  equal(fake.settings.autoCatchIntervalMode, 'custom')
  equal(fake.settings.autoCatchCustomIntervalMin, 2000)
  equal(window:recursiveGetChildById('intervalSaveStatus').text, 'Salvo.')
  equal(window:recursiveGetChildById('presetCustom').on, true)
  equal(api.getIntervalMode(), 'custom')
end)

check("an invalid interval is never saved, not even later", function()
  local fake = boot({ enable = false })
  local minEdit, maxEdit = speedWidgets(fake)
  typeInterval(minEdit, maxEdit, '5', '2')
  fake:advance(3000)
  maxEdit.onFocusChange(maxEdit, false)
  equal(fake.settings.autoCatchQueueIntervalMin, 200)
  equal(fake.settings.autoCatchQueueIntervalMax, 200)
  equal(minEdit.color, '#ff7676')
end)

check("choosing a mode is not a custom edit and the last custom interval comes back", function()
  local fake, api = boot({ enable = false })
  local minEdit, maxEdit, click, window = speedWidgets(fake)
  typeInterval(minEdit, maxEdit, '5', '8')
  fake:advance(900)
  click('presetTurbo')
  equal(api.getIntervalMode(), 'turbo')
  equal(fake.settings.autoCatchQueueIntervalMin, 80)
  equal(fake.settings.autoCatchIntervalMode, 'turbo')
  equal(minEdit:getText(), '0,08')
  equal(window:recursiveGetChildById('presetTurbo').on, true)
  equal(window:recursiveGetChildById('presetCustom').on, false)
  -- Leaving an untouched field, pressing Enter or Salvar keeps the chosen mode.
  minEdit.onFocusChange(minEdit, false)
  minEdit.onKeyPress(minEdit, 13)
  click('intervalSaveButton')
  fake:advance(3000)
  equal(api.getIntervalMode(), 'turbo')
  click('presetCustom')
  equal(api.getIntervalMode(), 'custom')
  equal(fake.settings.autoCatchQueueIntervalMin, 5000)
  equal(fake.settings.autoCatchQueueIntervalMax, 8000)
  equal(minEdit:getText(), '5')
  equal(maxEdit:getText(), '8')
end)

check("closing the panel keeps an interval that is still being typed", function()
  local fake, api = boot({ enable = false })
  local minEdit, maxEdit = speedWidgets(fake)
  typeInterval(minEdit, maxEdit, '1,5', '2,5')
  api.hide()
  equal(fake.settings.autoCatchQueueIntervalMin, 1500)
  equal(fake.settings.autoCatchQueueIntervalMax, 2500)
end)

check("mode and custom interval survive a restart", function()
  local fake, api = boot({ enable = false })
  local minEdit, maxEdit, click = speedWidgets(fake)
  typeInterval(minEdit, maxEdit, '4', '6')
  fake:advance(900)
  click('presetSafe')
  api.terminate()
  fake.gameHandlers, fake.creatureHandlers = {}, {}
  fake.window = nil
  api = fake:load(moduleDir .. "/autocatch.lua")
  api.init()
  api.show()
  equal(api.getIntervalMode(), 'safe')
  minEdit, maxEdit, click = speedWidgets(fake)
  equal(minEdit:getText(), '0,35')
  click('presetCustom')
  equal(minEdit:getText(), '4')
  equal(maxEdit:getText(), '6')
  equal(fake.settings.autoCatchQueueIntervalMin, 4000)
end)

check("an old profile with only min/max gets its mode from the values", function()
  local fake, api = boot({ enable = false, intervalMin = 350, intervalMax = 700 })
  equal(api.getIntervalMode(), 'safe')
  local fake2, api2 = boot({ enable = false, intervalMin = 1500, intervalMax = 1600 })
  equal(api2.getIntervalMode(), 'custom')
  local minEdit, maxEdit, click = speedWidgets(fake2)
  click('presetNormal')
  click('presetCustom')
  equal(minEdit:getText(), '1,5', "the old custom interval is remembered")
  equal(maxEdit:getText(), '1,6')
end)

check("safety checkboxes persist", function()
  local fake = boot({ enable = false })
  local window = fake.window
  local staff = window:recursiveGetChildById('staffGuard')
  staff.onCheckChange(staff, false)
  equal(fake.settings.autoCatchStaffGuard, false)
  local rearm = window:recursiveGetChildById('autoRearm')
  rearm.onCheckChange(rearm, true)
  equal(fake.settings.autoCatchAutoRearm, true)
end)

print(string.format("RESULT %d passed, %d failed", passed, failed))
if failed > 0 then error("Auto Catch runtime tests failed") end
