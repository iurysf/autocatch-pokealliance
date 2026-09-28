local AutoItem = {}

-- The server rounds buff times, so a re-sent buff list can show an unchanged
-- buff up to ~1 s longer. Only a longer increase counts as a refresh.
AutoItem.REFRESH_TOLERANCE_MS = 1500

local function nowMillis()
  if g_clock and type(g_clock.millis) == 'function' then
    return g_clock.millis()
  end
  return os.time() * 1000
end

function AutoItem.normalizeId(value)
  if type(value) == 'number' or type(value) == 'string' then
    return math.max(0, tonumber(value) or 0)
  end

  if value and (type(value) == 'table' or type(value) == 'userdata') then
    local ok, itemId = pcall(function() return value:getId() end)
    if ok then return math.max(0, tonumber(itemId) or 0) end
  end

  return 0
end

local function readBuffField(buff, fieldName)
  if type(buff) ~= 'table' and type(buff) ~= 'userdata' then return nil end
  local ok, value = pcall(function() return buff[fieldName] end)
  return ok and value or nil
end

function AutoItem.makeBuffSnapshot(buffs, receivedAtMs)
  local snapshot = {}
  receivedAtMs = tonumber(receivedAtMs) or nowMillis()

  if type(buffs) ~= 'table' then return snapshot end

  for _, buff in ipairs(buffs) do
    local name = readBuffField(buff, 'name')
    if type(name) == 'string' and name ~= '' then
      local remainingMs = math.max(0,
        tonumber(readBuffField(buff, 'endTime')) or
        tonumber(readBuffField(buff, 'remainingMs')) or 0)
      snapshot[name] = {
        remainingMs = remainingMs,
        value = readBuffField(buff, 'value'),
        receivedAtMs = receivedAtMs
      }
    end
  end

  return snapshot
end

function AutoItem.wasItemConsumed(beforeCount, currentCount)
  beforeCount = tonumber(beforeCount)
  currentCount = tonumber(currentCount)
  return beforeCount and currentCount and currentCount < beforeCount or false
end

function AutoItem.snapshotRemainingMs(entry, currentTimeMs)
  if type(entry) == 'number' then
    return math.max(0, entry)
  end
  if type(entry) ~= 'table' then return 0 end

  currentTimeMs = tonumber(currentTimeMs) or nowMillis()
  local remainingMs = tonumber(entry.remainingMs) or tonumber(entry.endTime) or 0
  local receivedAtMs = tonumber(entry.receivedAtMs)
  if receivedAtMs then
    remainingMs = remainingMs - math.max(0, currentTimeMs - receivedAtMs)
  end
  return math.max(0, remainingMs)
end

function AutoItem.changedBuffNames(before, after, currentTimeMs)
  local changed = {}
  before = type(before) == 'table' and before or {}
  after = type(after) == 'table' and after or {}
  currentTimeMs = tonumber(currentTimeMs) or nowMillis()

  for name, current in pairs(after) do
    local previous = before[name]
    local currentRemaining = AutoItem.snapshotRemainingMs(current, currentTimeMs)
    local previousRemaining = AutoItem.snapshotRemainingMs(previous, currentTimeMs)
    local valueChanged = previous and current.value ~= previous.value
    if not previous or currentRemaining > previousRemaining + AutoItem.REFRESH_TOLERANCE_MS or valueChanged then
      table.insert(changed, name)
    end
  end

  table.sort(changed)
  return changed
end

-- Sorted union of two name lists (nil counts as empty).
function AutoItem.mergeNames(first, second)
  local merged, seen = {}, {}
  for _, list in ipairs({ first or {}, second or {} }) do
    for _, name in ipairs(list) do
      if not seen[name] then seen[name] = true; merged[#merged + 1] = name end
    end
  end
  table.sort(merged)
  return merged
end

-- Sorted names present in both lists.
function AutoItem.commonNames(first, second)
  local inFirst, common = {}, {}
  for _, name in ipairs(first or {}) do inFirst[name] = true end
  for _, name in ipairs(second or {}) do
    if inFirst[name] then inFirst[name] = nil; common[#common + 1] = name end
  end
  table.sort(common)
  return common
end

function AutoItem.maxBuffRemainingMs(buffNames, getRemainingMs)
  if type(buffNames) ~= 'table' or type(getRemainingMs) ~= 'function' then
    return 0
  end

  local maximum = 0
  for _, name in ipairs(buffNames) do
    local remaining = tonumber(getRemainingMs(name)) or 0
    maximum = math.max(maximum, remaining)
  end
  return maximum
end

-- "Use with" item (the client opens the crosshair for it), e.g. food, which
-- only works when used on the character.
function AutoItem.isMultiUse(item)
  local ok, multiUse = pcall(function() return item:isMultiUse() end)
  return ok and multiUse == true
end

-- Returns true (plus 'player' when the item went on the character) or false
-- and the reason.
function AutoItem.dispatch(itemId, gameApi)
  itemId = AutoItem.normalizeId(itemId)
  if itemId <= 0 then return false, 'invalid-item-id' end

  gameApi = gameApi or g_game
  if not gameApi or type(gameApi.findPlayerItem) ~= 'function' then
    return false, 'find-player-item-unavailable'
  end
  if type(gameApi.use) ~= 'function' then
    return false, 'use-item-unavailable'
  end

  local found, item = pcall(function()
    return gameApi.findPlayerItem(itemId, -1)
  end)
  if not found then
    return false, tostring(item)
  end
  if not item or AutoItem.normalizeId(item) ~= itemId then
    return false, 'item-not-in-inventory'
  end

  if AutoItem.isMultiUse(item) then
    if type(gameApi.useWith) ~= 'function' or type(gameApi.getLocalPlayer) ~= 'function' then
      return false, 'use-with-unavailable'
    end
    local player = gameApi.getLocalPlayer()
    if not player then return false, 'no-local-player' end
    -- Same call the client makes when the crosshair lands on the character.
    local ok, errorMessage = pcall(function() gameApi.useWith(item, player) end)
    if not ok then return false, tostring(errorMessage) end
    return true, 'player'
  end

  local ok, errorMessage = pcall(function()
    -- This is the same confirmed path used by the client's "Sim" button
    -- after a right-click use. The second argument prevents the generic
    -- onConfirmUse dialog from being opened by Auto Item.
    gameApi.use(item, true)
  end)
  if not ok then return false, tostring(errorMessage) end

  return true
end

return AutoItem
