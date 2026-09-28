local CorpseRegistry = {}

function CorpseRegistry.remember(registry, itemId, ballId)
  itemId = tonumber(itemId) or 0
  ballId = tonumber(ballId) or 0
  if type(registry) ~= 'table' or itemId <= 0 or ballId <= 0 then return false end
  registry[itemId] = ballId
  return true
end

function CorpseRegistry.get(registry, itemId)
  if type(registry) ~= 'table' then return 0 end
  return tonumber(registry[tonumber(itemId) or 0]) or 0
end

function CorpseRegistry.clear(registry)
  if type(registry) ~= 'table' then return end
  for itemId in pairs(registry) do
    registry[itemId] = nil
  end
end

return CorpseRegistry
