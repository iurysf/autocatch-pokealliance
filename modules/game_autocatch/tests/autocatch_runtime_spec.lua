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
  fake.settings.autoCatchQueueIntervalMin = 200
  fake.settings.autoCatchQueueIntervalMax = 200
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
  local saved = fake.env.json.decode(fake.settings.autoCatchAutoItems)
  equal(saved[1].enabled, false)
  equal(contains(fake.log, "card desativado"), true)
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
  local saved = fake.env.json.decode(fake.settings.autoCatchCorpseEntries)
  equal(saved[2].ballId, 9999)
  local enabledBox = row:recursiveGetChildById('entryEnabled')
  enabledBox.onCheckChange(enabledBox, false)
  saved = fake.env.json.decode(fake.settings.autoCatchCorpseEntries)
  equal(saved[2].enabled, false)
  local deleteButton = row:recursiveGetChildById('deleteEntry')
  deleteButton.onClick(deleteButton)
  saved = fake.env.json.decode(fake.settings.autoCatchCorpseEntries)
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
  equal(fake.env.json.decode(fake.settings.autoCatchCorpseEntries)[1].ballId, 8888)
  clickTarget = mapWidget
  local selectCorpse = row:recursiveGetChildById('selectCorpse')
  selectCorpse.onClick(selectCorpse)
  grabber = fake.lastGrabber
  grabber.onMouseRelease(grabber, { x = 1, y = 1 }, 1)
  equal(fake.env.json.decode(fake.settings.autoCatchCorpseEntries)[1].corpseId, 7777)
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
  minEdit:setText('3'); minEdit.onTextChange(minEdit)
  equal(minEdit.color, '#ff7676')
  equal(fake.saves or 0, savesBefore, "typing must not save")
  minEdit:setText('350'); minEdit.onTextChange(minEdit)
  maxEdit:setText('700'); maxEdit.onTextChange(maxEdit)
  equal(minEdit.color, '#dbe5ec')
  equal(fake.settings.autoCatchQueueIntervalMin, 200, "still not saved before confirming")
  equal(minEdit.onKeyPress(minEdit, 13), true)
  equal(fake.settings.autoCatchQueueIntervalMin, 350)
  equal(fake.settings.autoCatchQueueIntervalMax, 700)
  maxEdit:setText('900'); maxEdit.onTextChange(maxEdit)
  maxEdit.onFocusChange(maxEdit, false)
  equal(fake.settings.autoCatchQueueIntervalMax, 900)
  local presetTurbo = window:recursiveGetChildById('presetTurbo')
  presetTurbo.onClick(presetTurbo)
  equal(fake.settings.autoCatchQueueIntervalMin, 80)
  equal(fake.settings.autoCatchQueueIntervalMax, 180)
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
