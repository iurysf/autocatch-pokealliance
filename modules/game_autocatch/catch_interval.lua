-- Ritmo dos lancamentos de Ball.
--
-- O intervalo entre lancamentos e sorteado entre o minimo configurado (nunca
-- abaixo de ping + buffer) e o maximo. A cada poucos lancamentos o pacer
-- acrescenta uma pausa curta, imitando o tempo de reacao de um jogador.
local Interval = {}

Interval.DEFAULT_MINIMUM = 220
Interval.DEFAULT_MAXIMUM = 260
-- Limits in milliseconds (settings keep ms; the panel shows seconds). The old
-- 2000 ms ceiling is gone (28/09/2026): one hour only guards against typos.
Interval.LOWER_LIMIT = 50
Interval.UPPER_LIMIT = 60 * 60 * 1000
Interval.PING_BUFFER = 30
Interval.BURST_PAUSE_EVERY_MIN = 6
Interval.BURST_PAUSE_EVERY_MAX = 12
Interval.BURST_PAUSE_MIN_MS = 400
Interval.BURST_PAUSE_MAX_MS = 900

function Interval.defaultRandom(lower, upper)
  lower, upper = math.floor(lower), math.floor(upper)
  if upper <= lower then return lower end
  return math.random(lower, upper)
end

function Interval.validate(minimum, maximum)
  minimum, maximum = tonumber(minimum), tonumber(maximum)
  if not minimum or not maximum or minimum ~= math.floor(minimum) or maximum ~= math.floor(maximum) then
    return nil, "limits-must-be-integers"
  end
  if minimum < Interval.LOWER_LIMIT or minimum > Interval.UPPER_LIMIT or
      maximum < Interval.LOWER_LIMIT or maximum > Interval.UPPER_LIMIT then
    return nil, "limits-out-of-range"
  end
  if minimum > maximum then return nil, "minimum-greater-than-maximum" end
  return minimum, maximum
end

-- Segundos digitados no painel ("5", "0,35", "0.35", "2s") -> milissegundos
-- inteiros. nil para texto que nao e um numero de segundos.
function Interval.parseSeconds(text)
  local cleaned = tostring(text or ''):gsub('^%s+', ''):gsub('%s+$', ''):gsub('[sS]$', ''):gsub('%s+$', '')
  cleaned = cleaned:gsub(',', '.')
  if not cleaned:match('^%d+%.?%d*$') and not cleaned:match('^%.%d+$') then return nil end
  local seconds = tonumber(cleaned)
  if not seconds then return nil end
  return math.floor(seconds * 1000 + 0.5)
end

-- Milissegundos -> segundos para o painel, com virgula e sem zeros sobrando:
-- 5000 -> "5", 350 -> "0,35", 1250 -> "1,25".
function Interval.formatSeconds(milliseconds)
  milliseconds = math.floor(tonumber(milliseconds) or 0)
  local whole = math.floor(milliseconds / 1000)
  local fraction = milliseconds % 1000
  if fraction == 0 then return tostring(whole) end
  local digits = string.format('%03d', fraction):gsub('0+$', '')
  return tostring(whole) .. ',' .. digits
end

-- Valida os dois campos do painel, em segundos. Devolve ms ou nil, motivo.
function Interval.validateSeconds(minimumText, maximumText)
  local minimum, maximum = Interval.parseSeconds(minimumText), Interval.parseSeconds(maximumText)
  if not minimum or not maximum then return nil, 'limits-must-be-seconds' end
  return Interval.validate(minimum, maximum)
end

-- Piso do intervalo: o minimo configurado, nunca abaixo do ping + buffer.
function Interval.floor(ping, minimum, maximum)
  local validMinimum, validMaximum = Interval.validate(minimum, maximum)
  if not validMinimum then
    validMinimum, validMaximum = Interval.DEFAULT_MINIMUM, Interval.DEFAULT_MAXIMUM
  end
  ping = math.max(0, tonumber(ping) or 0)
  return math.min(validMaximum, math.max(validMinimum, math.floor(ping + Interval.PING_BUFFER))), validMaximum
end

-- Intervalo sorteado entre o piso e o maximo. random(lower, upper) e
-- injetavel para testes.
function Interval.calculate(ping, minimum, maximum, random)
  local lower, upper = Interval.floor(ping, minimum, maximum)
  if lower >= upper then return upper end
  random = random or Interval.defaultRandom
  local value = tonumber(random(lower, upper)) or lower
  return math.min(upper, math.max(lower, math.floor(value)))
end

-- Pacer: mantem a contagem de lancamentos e injeta pausas curtas.
function Interval.newPacer(options)
  options = options or {}
  local pacer = {
    random = options.random or Interval.defaultRandom,
    pauseEveryMin = options.pauseEveryMin or Interval.BURST_PAUSE_EVERY_MIN,
    pauseEveryMax = options.pauseEveryMax or Interval.BURST_PAUSE_EVERY_MAX,
    pauseMinMs = options.pauseMinMs or Interval.BURST_PAUSE_MIN_MS,
    pauseMaxMs = options.pauseMaxMs or Interval.BURST_PAUSE_MAX_MS,
    throwsSincePause = 0,
    nextPauseAt = nil
  }

  function pacer:reset()
    self.throwsSincePause = 0
    self.nextPauseAt = nil
  end

  -- Chamado apos cada lancamento; devolve o tempo ate o proximo permitido.
  function pacer:nextDelay(ping, minimum, maximum)
    local delay = Interval.calculate(ping, minimum, maximum, self.random)
    if not self.nextPauseAt then
      self.nextPauseAt = math.floor(tonumber(self.random(self.pauseEveryMin, self.pauseEveryMax)) or self.pauseEveryMin)
    end
    self.throwsSincePause = self.throwsSincePause + 1
    local paused = false
    if self.throwsSincePause >= self.nextPauseAt then
      delay = delay + math.floor(tonumber(self.random(self.pauseMinMs, self.pauseMaxMs)) or self.pauseMinMs)
      self.throwsSincePause = 0
      self.nextPauseAt = nil
      paused = true
    end
    return delay, paused
  end

  return pacer
end

return Interval
