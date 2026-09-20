local CorpseTarget = {}

local function validId(value)
  return (tonumber(value) or 0) > 0
end

local function isEntryList(value)
  return type(value) == 'table' and (value[1] == nil or type(value[1]) == 'table')
end

local function isEntryActive(entry)
  return entry.enabled ~= false
end

function CorpseTarget.hasConfigured(entries, corpse1Id, ball2Id, corpse2Id)
  if isEntryList(entries) then
    for _, entry in ipairs(entries) do
      if isEntryActive(entry) and validId(entry.ballId) and validId(entry.corpseId) then
        return true
      end
    end
    return false
  end

  -- Compatibilidade com os testes e perfis da versao anterior.
  return validId(entries) and validId(corpse1Id) or
    validId(ball2Id) and validId(corpse2Id)
end

function CorpseTarget.buildBallIndex(entries)
  local index = {}
  if not isEntryList(entries) then return index end

  for _, entry in ipairs(entries) do
    local corpseId = tonumber(entry.corpseId) or 0
    local ballId = tonumber(entry.ballId) or 0
    if isEntryActive(entry) and validId(corpseId) and validId(ballId) then
      index[corpseId] = ballId
    end
  end

  return index
end

-- Mapa corpseId -> card ativo, para estatisticas e mensagens.
function CorpseTarget.buildEntryIndex(entries)
  local index = {}
  if not isEntryList(entries) then return index end
  for _, entry in ipairs(entries) do
    local corpseId = tonumber(entry.corpseId) or 0
    if isEntryActive(entry) and validId(corpseId) and validId(entry.ballId) then
      index[corpseId] = entry
    end
  end
  return index
end

function CorpseTarget.resolveIndexed(itemId, index)
  itemId = tonumber(itemId) or 0
  local ballId = type(index) == 'table' and tonumber(index[itemId]) or 0
  if itemId <= 0 or not validId(ballId) then
    return false, nil, 0
  end

  return true, string.format('Corpo ID %d', itemId), ballId
end

function CorpseTarget.resolve(itemId, entries, corpse1Id, ball2Id, corpse2Id)
  itemId = tonumber(itemId) or 0
  if itemId <= 0 then return false, nil, 0 end

  if isEntryList(entries) then
    for index, entry in ipairs(entries) do
      local corpseId = tonumber(entry.corpseId) or 0
      local ballId = tonumber(entry.ballId) or 0
      if isEntryActive(entry) and itemId == corpseId and ballId > 0 then
        local name = entry.name or string.format('Pokemon %d', index)
        return true, name, ballId, entry
      end
    end
    return false, nil, 0
  end

  -- Compatibilidade com a assinatura antiga:
  -- resolve(itemId, ball1Id, corpse1Id, ball2Id, corpse2Id).
  local ball1Id = entries
  if itemId == (tonumber(corpse1Id) or 0) and validId(ball1Id) then
    return true, string.format('Corpo 1 (ID %d)', corpse1Id), tonumber(ball1Id)
  end
  if itemId == (tonumber(corpse2Id) or 0) and validId(ball2Id) then
    return true, string.format('Corpo 2 (ID %d)', corpse2Id), tonumber(ball2Id)
  end
  return false, nil, 0
end

return CorpseTarget
