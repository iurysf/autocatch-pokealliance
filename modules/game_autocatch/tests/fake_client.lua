-- Ambiente falso do OTClient para testar autocatch.lua fora do jogo.
-- Reproduz o que o modulo usa: relogio, eventos agendados, g_game, g_map,
-- g_settings, widgets minimos e criaturas/itens. Cada tile:getItems() devolve
-- wrappers novos (== compara o objeto real), como os userdata do cliente.
local Fake = {}

function Fake.new()
  local env = {}
  local self = { env = env, time = 1000, events = {}, log = {}, uses = {}, settings = {}, creatureHandlers = {}, gameHandlers = {} }

  local function copyPos(p) return { x = p.x, y = p.y, z = p.z } end

  -- ---------------------------------------------------------------- relogio
  env.g_clock = { millis = function() return self.time end }

  -- ---------------------------------------------------------------- eventos
  local nextEventId = 0
  local function newEvent(fn, delay, cycle)
    nextEventId = nextEventId + 1
    local event = { id = nextEventId, at = self.time + delay, fn = fn, cycle = cycle, cancelled = false }
    function event:cancel() self.cancelled = true end
    self.events[#self.events + 1] = event
    return event
  end
  env.scheduleEvent = function(fn, delay) return newEvent(fn, delay or 0, nil) end
  env.addEvent = function(fn) return newEvent(fn, 0, nil) end
  env.cycleEvent = function(fn, ms) return newEvent(fn, ms, ms) end
  env.removeEvent = function(event) if event then event.cancelled = true end end

  -- avanca o relogio executando os eventos na ordem
  function self:advance(ms)
    local target = self.time + ms
    while true do
      local nextEvent = nil
      for _, event in ipairs(self.events) do
        if not event.cancelled and event.at <= target and (not nextEvent or event.at < nextEvent.at) then
          nextEvent = event
        end
      end
      if not nextEvent then break end
      self.time = math.max(self.time, nextEvent.at)
      if nextEvent.cycle then
        nextEvent.at = self.time + nextEvent.cycle
      else
        nextEvent.cancelled = true
      end
      nextEvent.fn()
    end
    self.time = target
    local kept = {}
    for _, event in ipairs(self.events) do
      if not event.cancelled then kept[#kept + 1] = event end
    end
    self.events = kept
  end

  -- ---------------------------------------------------------------- settings
  env.g_settings = {
    getString = function(key, default) local v = self.settings[key]; if v == nil then return default or '' end return tostring(v) end,
    getNumber = function(key, default) local v = tonumber(self.settings[key]); if v == nil then return default or 0 end return v end,
    getBoolean = function(key, default) local v = self.settings[key]; if v == nil then return default == true end return v == true or v == 'true' end,
    set = function(key, value) self.settings[key] = value end,
    save = function() self.saves = (self.saves or 0) + 1 end,
    getNode = function() return nil end
  }

  -- ---------------------------------------------------------------- json
  local function encode(value)
    local t = type(value)
    if t == 'nil' then return 'null' end
    if t == 'boolean' then return tostring(value) end
    if t == 'number' then return string.format('%.14g', value) end
    if t == 'string' then return '"' .. value:gsub('[%c"\\]', function(c) return string.format('\\u%04x', c:byte()) end) .. '"' end
    if t == 'table' then
      if #value > 0 or next(value) == nil then
        local parts = {}
        for _, item in ipairs(value) do parts[#parts + 1] = encode(item) end
        return '[' .. table.concat(parts, ',') .. ']'
      end
      local parts = {}
      for k, v in pairs(value) do parts[#parts + 1] = encode(tostring(k)) .. ':' .. encode(v) end
      return '{' .. table.concat(parts, ',') .. '}'
    end
    error('json: tipo nao suportado ' .. t)
  end
  local function decode(text)
    local pos = 1
    local function skip() pos = text:find('%S', pos) or (#text + 1) end
    local parseValue
    local function parseString()
      local out = {}
      pos = pos + 1
      while true do
        local c = text:sub(pos, pos)
        if c == '"' then pos = pos + 1; break end
        if c == '\\' then
          local n = text:sub(pos + 1, pos + 1)
          if n == 'u' then
            out[#out + 1] = string.char(tonumber(text:sub(pos + 2, pos + 5), 16)); pos = pos + 6
          else
            out[#out + 1] = ({ n = '\n', t = '\t', r = '\r' })[n] or n; pos = pos + 2
          end
        else
          out[#out + 1] = c; pos = pos + 1
        end
      end
      return table.concat(out)
    end
    parseValue = function()
      skip()
      local c = text:sub(pos, pos)
      if c == '{' then
        local obj = {}
        pos = pos + 1; skip()
        if text:sub(pos, pos) == '}' then pos = pos + 1; return obj end
        while true do
          skip(); local key = parseString(); skip(); pos = pos + 1
          obj[key] = parseValue(); skip()
          local d = text:sub(pos, pos); pos = pos + 1
          if d == '}' then return obj end
        end
      elseif c == '[' then
        local arr = {}
        pos = pos + 1; skip()
        if text:sub(pos, pos) == ']' then pos = pos + 1; return arr end
        while true do
          arr[#arr + 1] = parseValue(); skip()
          local d = text:sub(pos, pos); pos = pos + 1
          if d == ']' then return arr end
        end
      elseif c == '"' then
        return parseString()
      elseif text:sub(pos, pos + 3) == 'true' then pos = pos + 4; return true
      elseif text:sub(pos, pos + 4) == 'false' then pos = pos + 5; return false
      elseif text:sub(pos, pos + 3) == 'null' then pos = pos + 4; return nil
      else
        local num = text:match('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
        pos = pos + #num
        return tonumber(num)
      end
    end
    return parseValue()
  end
  env.json = { encode = encode, decode = decode }

  -- ---------------------------------------------------------------- itens e tiles
  local nextItemId = 0
  local ItemProxyMT = { __eq = function(a, b) return rawget(a, '__item') == rawget(b, '__item') end }
  local function wrap(item)
    local proxy = { __item = item }
    proxy.getId = function() return item.id end
    proxy.isItem = function() return true end
    proxy.isGround = function() return item.ground == true end
    proxy.getName = function() return item.name or ('item ' .. item.id) end
    proxy.getDescription = function() return '' end
    proxy.getPosition = function() return copyPos(item.position) end
    return setmetatable(proxy, ItemProxyMT)
  end
  self.tiles = {}
  local function tileKey(p) return p.x .. ',' .. p.y .. ',' .. p.z end
  function self:tile(position)
    local key = tileKey(position)
    local tile = self.tiles[key]
    if not tile then
      tile = { items = {}, position = copyPos(position) }
      function tile:getItems()
        local out = {}
        for _, item in ipairs(self.items) do out[#out + 1] = wrap(item) end
        return out
      end
      function tile:getTopUseThing()
        local top = self.items[#self.items]
        return top and wrap(top) or nil
      end
      function tile:getTopMoveThing() return self:getTopUseThing() end
      self.tiles[key] = tile
    end
    return tile
  end
  function self:addItem(position, id, name)
    nextItemId = nextItemId + 1
    local item = { uid = nextItemId, id = id, name = name, position = copyPos(position) }
    local tile = self:tile(position)
    tile.items[#tile.items + 1] = item
    return item
  end
  function self:removeItem(item)
    local tile = self:tile(item.position)
    for index, current in ipairs(tile.items) do
      if current == item then table.remove(tile.items, index); return true end
    end
    return false
  end
  env.g_map = {
    getTile = function(position)
      if not self.knownTiles or self.knownTiles[tileKey(position)] ~= false then
        return self:tile(position)
      end
      return nil
    end,
    getSpectators = function() return self.spectators or {} end
  }
  env.Item = { create = function(id) return { id = id } end }

  -- ---------------------------------------------------------------- jogador e jogo
  self.online = true
  self.inventory = {}
  self.playerPos = { x = 100, y = 100, z = 7 }
  local player = {
    getPosition = function() return copyPos(self.playerPos) end,
    getItemCount = function(_, id) return self.inventory[id] or 0 end
  }
  env.g_game = {
    isOnline = function() return self.online end,
    getLocalPlayer = function() return player end,
    getPing = function() return self.ping or 40 end,
    useInventoryItemWith = function(ballId, thing)
      self.uses[#self.uses + 1] = { ballId = ballId, itemId = thing:getId(), at = self.time, position = thing:getPosition() }
      if self.onUse then self.onUse(ballId, thing) end
      return nil
    end,
    findPlayerItem = function(id) if (self.inventory[id] or 0) > 0 then return wrap({ id = id, position = self.playerPos }) end return nil end,
    use = function(item) self.itemUses = (self.itemUses or 0) + 1; self.inventory[item:getId()] = (self.inventory[item:getId()] or 1) - 1 end,
    getCharacterName = function() return 'Tester' end,
    getWorldName = function() return 'World' end
  }

  -- ---------------------------------------------------------------- criaturas
  local nextCreatureId = 1000
  function self:creature(options)
    nextCreatureId = nextCreatureId + 1
    local creature = {
      id = nextCreatureId,
      name = options.name or 'Rattata',
      position = copyPos(options.position or self.playerPos),
      monster = options.monster ~= false,
      shiny = options.shiny == true,
      health = 100
    }
    local proxy = {}
    proxy.getId = function() return creature.id end
    proxy.getName = function() return creature.name end
    proxy.getPosition = function() return copyPos(creature.position) end
    proxy.isMonster = function() return creature.monster end
    proxy.isPlayer = function() return not creature.monster end
    proxy.isNpc = function() return false end
    proxy.getType = function() return creature.monster and 1 or 0 end
    proxy.getHealthPercent = function() return creature.health end
    proxy.getOutfit = function() return { type = options.lookType or 0 } end
    if creature.shiny then proxy.isShiny = function() return true end end
    proxy.__data = creature
    return proxy
  end

  -- ---------------------------------------------------------------- widgets
  local function widget(id)
    local w = { id = id or '', children = {}, text = '', checked = false, visible = true, fields = {} }
    function w:getId() return self.id end
    function w:setText(t) self.text = t end
    function w:getText() return self.text end
    function w:setColor(c) self.color = c end
    function w:setChecked(v) self.checked = v == true end
    function w:isChecked() return self.checked end
    function w:setOn(v) self.on = v end
    function w:setVisible(v) self.visible = v end
    function w:isVisible() return self.visible end
    function w:show() self.visible = true end
    function w:hide() self.visible = false end
    function w:raise() end
    function w:focus() end
    function w:destroy() self.destroyed = true end
    function w:destroyChildren() self.children = {} end
    function w:getChildren() return self.children end
    function w:setItem() end
    function w:setItemId() end
    function w:setItemVisible() end
    function w:setShowCount() end
    function w:setImageColor(c) self.imageColor = c end
    function w:setFocusable() end
    function w:grabMouse() self.grabbed = true end
    function w:ungrabMouse() self.grabbed = false end
    function w:getClassName() return 'UIWidget' end
    function w:recursiveGetChildById(childId)
      if not self.byId then self.byId = {} end
      if not self.byId[childId] then self.byId[childId] = widget(childId) end
      return self.byId[childId]
    end
    return w
  end
  self.widget = widget
  env.g_ui = {
    importStyle = function() end,
    createWidget = function(name, parent)
      local w = widget(name)
      w.styleName = name
      if parent and parent.children then parent.children[#parent.children + 1] = w end
      if name == 'AutoCatchWindow' then self.window = w end
      if name == 'UIWidget' and not parent then self.lastGrabber = w end
      return w
    end,
    isMouseGrabbed = function() return false end
  }
  env.g_mouse = { pushCursor = function() end, popCursor = function() end }
  env.g_logger = { warning = function(m) self.log[#self.log + 1] = 'WARN ' .. m end, info = function(m) self.log[#self.log + 1] = m end, error = function(m) self.log[#self.log + 1] = 'ERROR ' .. m end }
  env.print = function(...) local parts = {} for i = 1, select('#', ...) do parts[#parts + 1] = tostring(select(i, ...)) end self.log[#self.log + 1] = table.concat(parts, ' ') end
  env.modules = {
    game_interface = { getRootPanel = function() return widget('root') end },
    client_topmenu = { addMiddleGameToggleButton = function() return widget('autoCatchButton') end }
  }
  env.Creature = {}
  env.connect = function(target, handlers)
    local store = target == env.Creature and self.creatureHandlers or self.gameHandlers
    for name, fn in pairs(handlers) do store[name] = fn end
  end
  env.disconnect = function(target, handlers)
    local store = target == env.Creature and self.creatureHandlers or self.gameHandlers
    for name in pairs(handlers) do store[name] = nil end
  end
  env.tr = function(s) return s end
  env.timeFormat = function(s) return tostring(s) end
  env.MouseLeftButton = 1
  env.MouseRightButton = 2
  env.KeyEnter = 13
  env.CreatureTypePlayer, env.CreatureTypeNpc, env.CreatureTypeSummonOwn, env.CreatureTypeSummonOther = 0, 2, 3, 4

  -- ---------------------------------------------------------------- carga do modulo (sandbox)
  function self:load(path)
    env.modules.game_autocatch = env
    setmetatable(env, { __index = _G })
    local function loadWithEnv(path)
      if setfenv then
        local fn = assert(loadfile(path))
        setfenv(fn, env)
        return fn
      end
      local file = assert(io.open(path, 'r'))
      local source = file:read('*a')
      file:close()
      return assert(load(source, '@' .. path, 't', env))
    end
    env.dofile = function(file)
      local resolved = file:gsub('^/modules/game_autocatch/', self.moduleDir .. '/')
      return loadWithEnv(resolved)()
    end
    loadWithEnv(path)()
    return env
  end

  -- atalhos para os eventos do cliente
  function self:appear(creature) if self.creatureHandlers.onAppear then self.creatureHandlers.onAppear(creature) end end
  function self:health(creature, percent)
    creature.__data.health = percent
    if self.creatureHandlers.onHealthPercentChange then self.creatureHandlers.onHealthPercentChange(creature, percent) end
  end
  function self:disappear(creature) if self.creatureHandlers.onDisappear then self.creatureHandlers.onDisappear(creature) end end
  function self:gameEvent(name, ...) if self.gameHandlers[name] then self.gameHandlers[name](...) end end

  return self
end

return Fake
