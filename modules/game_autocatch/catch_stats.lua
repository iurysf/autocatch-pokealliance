-- Estatisticas da sessao e leitura das mensagens de captura do servidor.
--
-- As mesmas frases usadas por game_catch/catch.lua ("Voce capturou um X",
-- "Voce gastou: N Ball") confirmam o resultado real de um lancamento.
local CatchStats = {}
CatchStats.__index = CatchStats

local function trim(text)
  return (text or ''):gsub('^%s+', ''):gsub('%s+$', ''):gsub('%.$', '')
end

function CatchStats.new()
  return setmetatable({
    sent = 0,
    confirmed = 0,
    shinyConfirmed = 0,
    discarded = 0,
    ballsSpent = 0,
    bySpecies = {},
    byBall = {},
    lastConfirmedName = nil,
    lastConfirmedAt = 0
  }, CatchStats)
end

function CatchStats:reset()
  local fresh = CatchStats.new()
  for key, value in pairs(fresh) do self[key] = value end
end

function CatchStats:recordSent(ballId)
  self.sent = self.sent + 1
  ballId = tonumber(ballId) or 0
  if ballId > 0 then self.byBall[ballId] = (self.byBall[ballId] or 0) + 1 end
end

-- Devolve false quando a mesma captura chegou por dois caminhos (janela +
-- mensagem de chat) dentro de 3 segundos.
function CatchStats:recordConfirmed(name, isShiny, now)
  name = trim(tostring(name or ''))
  if name == '' then return false end
  now = tonumber(now) or 0
  local lower = name:lower()
  if self.lastConfirmedName == lower and (now - self.lastConfirmedAt) < 3000 then
    return false
  end
  self.lastConfirmedName = lower
  self.lastConfirmedAt = now
  self.confirmed = self.confirmed + 1
  if isShiny then self.shinyConfirmed = self.shinyConfirmed + 1 end
  self.bySpecies[name] = (self.bySpecies[name] or 0) + 1
  return true
end

function CatchStats:recordDiscard()
  self.discarded = self.discarded + 1
end

function CatchStats:recordBallsSpent(total)
  total = tonumber(total) or 0
  if total > 0 then self.ballsSpent = self.ballsSpent + total end
end

function CatchStats:summary()
  local shiny = self.shinyConfirmed > 0 and string.format(' (%d shiny)', self.shinyConfirmed) or ''
  return string.format('Lancadas %d | Capturas %d%s | Descartes %d | Balls gastas %d',
    self.sent, self.confirmed, shiny, self.discarded, self.ballsSpent)
end

-- "Voce capturou um Pokemon! (Bellsprout)" / "You caught a Bellsprout!"
function CatchStats.parseCatchMessage(text)
  if type(text) ~= 'string' then return nil end
  local lower = text:lower()
  if lower:find('jogador', 1, true) or lower:find('treinador', 1, true) or lower:find('player', 1, true) then
    return nil
  end
  local hasCatch = lower:find('capturou um', 1, true) or lower:find('caught a', 1, true)
  if not hasCatch then return nil end

  local inParen = text:match('%((.-)%)')
  if inParen then
    local candidate = trim(inParen)
    local candidateLower = candidate:lower()
    if #candidate > 0 and candidateLower ~= 'pokémon' and candidateLower ~= 'pokemon' then
      return candidate
    end
  end

  local candidate = text:match('[Cc]apturou%s+um[a]?%s+([^!%.]+)') or text:match('[Cc]aught%s+an?%s+([^!%.]+)')
  if candidate then
    candidate = trim(candidate)
    local afterPoke = candidate:match('^[Pp]ok[ée]mon!*%s*(.*)$')
    if afterPoke and #afterPoke > 0 then candidate = trim(afterPoke) end
    local candidateLower = candidate:lower()
    if #candidate > 0 and candidateLower ~= 'pokémon' and candidateLower ~= 'pokemon' then
      return candidate
    end
  end
  return nil
end

-- "Voce gastou: 3 Ultra Balls, 1 Great Ball" -> 4
function CatchStats.parseBallsSpent(text)
  if type(text) ~= 'string' then return nil end
  local lower = text:lower()
  if not (lower:find('gastou:', 1, true) or lower:find('spent:', 1, true)) then return nil end
  local afterColon = text:match(':[%s]*(.+)')
  if not afterColon then return nil end

  local total = 0
  for countStr in afterColon:gmatch('(%d+)%s+[%a%s]-[Bb]all[s]?') do
    total = total + (tonumber(countStr) or 0)
  end
  if total == 0 then
    local single = afterColon:match('(%d+)%s+[^%.,]+')
    total = tonumber(single) or 0
  end
  if total > 0 then return total end
  return nil
end

return CatchStats
