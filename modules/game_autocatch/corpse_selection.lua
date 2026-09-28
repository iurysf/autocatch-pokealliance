-- Escolha e ordenacao de corpos candidatos.
local CorpseSelection = {}

-- Devolve o item mais alto da pilha com o ID esperado que ainda nao foi
-- tratado. options: expectedId, getId(item), isClaimed(item)
function CorpseSelection.pick(items, options)
  options = options or {}
  local getId = options.getId or function(item) return item and item.id end
  local expectedId = options.expectedId
  local isClaimed = options.isClaimed or function() return false end
  local hasMatch = false

  for index = #(items or {}), 1, -1 do
    local item = items[index]
    if item and expectedId ~= nil and getId(item) == expectedId then
      hasMatch = true
      if not isClaimed(item) then
        return item, index, hasMatch
      end
    end
  end

  return nil, nil, hasMatch
end

-- Distancia de Chebyshev entre duas posicoes no mesmo andar (nil se diferente).
function CorpseSelection.distance(left, right)
  if not left or not right or left.z ~= right.z then return nil end
  return math.max(math.abs(left.x - right.x), math.abs(left.y - right.y))
end

-- Ordena candidatos {position, firstSeenAt, ...}: mais proximo primeiro e,
-- em empate, o corpo visto ha mais tempo (mais perto de desaparecer).
function CorpseSelection.sortCandidates(candidates, playerPosition)
  local list = candidates or {}
  for _, candidate in ipairs(list) do
    candidate.distance = CorpseSelection.distance(playerPosition, candidate.position) or math.huge
  end
  table.sort(list, function(a, b)
    if a.distance ~= b.distance then return a.distance < b.distance end
    local seenA, seenB = tonumber(a.firstSeenAt) or 0, tonumber(b.firstSeenAt) or 0
    if seenA ~= seenB then return seenA < seenB end
    return tostring(a.key or '') < tostring(b.key or '')
  end)
  return list
end

return CorpseSelection
