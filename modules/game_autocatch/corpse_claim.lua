-- Registro de corpos ja tratados pelo Auto Catch.
--
-- A chave e posicao + ID do item, nunca o userdata do corpo: no OTClient cada
-- tile:getItems() devolve um userdata novo para o mesmo objeto, entao usar o
-- objeto como chave de tabela so funciona enquanto o mesmo valor for guardado.
-- Cada claim guarda quantos itens com aquele ID existiam no tile; quando a
-- contagem cai, o corpo tratado sumiu e o claim e liberado.
--
-- Um claim "bloqueado" marca um corpo esgotado (sem Ball, tentativas
-- esgotadas) para a varredura nao reenfileirar o mesmo corpo em loop.
local CorpseClaim = {}
CorpseClaim.__index = CorpseClaim

local function copyPosition(position)
  if type(position) ~= 'table' then return nil end
  local x, y, z = tonumber(position.x), tonumber(position.y), tonumber(position.z)
  if not x or not y or not z then return nil end
  return { x = x, y = y, z = z }
end

function CorpseClaim.key(position, itemId)
  local copy = copyPosition(position)
  itemId = tonumber(itemId) or 0
  if not copy or itemId <= 0 then return nil end
  return string.format('%d,%d,%d:%d', copy.x, copy.y, copy.z, itemId)
end

function CorpseClaim.new(ttl, now)
  return setmetatable({
    ttl = math.max(1, tonumber(ttl) or 1),
    now = now or function() return 0 end,
    items = {}
  }, CorpseClaim)
end

-- countAt(position, itemId) -> quantos itens com esse ID existem no tile agora
-- (nil quando o tile e desconhecido; nesse caso o claim e mantido).
function CorpseClaim:cleanup(countAt)
  local currentTime = self.now()
  for key, data in pairs(self.items) do
    local expired = not data.persistent and currentTime > data.expiresAt
    local gone = false
    if not expired and type(countAt) == 'function' then
      local current = countAt(data.position, data.itemId)
      if type(current) == 'number' then
        if current < data.count then
          gone = true
        elseif current > data.count then
          data.count = current
        end
      end
    end
    if expired or gone then self.items[key] = nil end
  end
end

function CorpseClaim:get(position, itemId)
  local key = CorpseClaim.key(position, itemId)
  return key and self.items[key] or nil
end

function CorpseClaim:isClaimed(position, itemId)
  return self:get(position, itemId) ~= nil
end

function CorpseClaim:isBlocked(position, itemId)
  local data = self:get(position, itemId)
  return data ~= nil and data.blocked == true
end

function CorpseClaim:isPositionClaimed(position)
  local copy = copyPosition(position)
  if not copy then return false end
  for _, data in pairs(self.items) do
    if data.position.x == copy.x and data.position.y == copy.y and data.position.z == copy.z then
      return true
    end
  end
  return false
end

-- options: count (itens iguais no tile), persistent (nao expira por tempo),
-- blocked (corpo esgotado), ttl (sobrescreve o ttl padrao)
function CorpseClaim:claim(position, itemId, options)
  local key = CorpseClaim.key(position, itemId)
  if not key then return false end
  if self.items[key] then return false end
  options = type(options) == 'table' and options or {}
  local now = self.now()
  self.items[key] = {
    position = copyPosition(position),
    itemId = tonumber(itemId),
    count = math.max(1, tonumber(options.count) or 1),
    expiresAt = now + math.max(1, tonumber(options.ttl) or self.ttl),
    persistent = options.persistent == true,
    blocked = options.blocked == true,
    createdAt = now
  }
  return true
end

-- Substitui qualquer claim existente por um bloqueio temporario.
function CorpseClaim:block(position, itemId, options)
  local key = CorpseClaim.key(position, itemId)
  if not key then return false end
  self.items[key] = nil
  options = type(options) == 'table' and options or {}
  return self:claim(position, itemId, {
    count = options.count,
    ttl = options.ttl,
    persistent = false,
    blocked = true
  })
end

function CorpseClaim:refresh(position, itemId)
  local data = self:get(position, itemId)
  if not data then return false end
  data.expiresAt = self.now() + self.ttl
  return true
end

function CorpseClaim:release(position, itemId)
  local key = CorpseClaim.key(position, itemId)
  if key then self.items[key] = nil end
end

function CorpseClaim:clear()
  self.items = {}
end

function CorpseClaim:size()
  local total = 0
  for _ in pairs(self.items) do total = total + 1 end
  return total
end

return CorpseClaim
