local CatchDispatch = {}

function CatchDispatch.decide(now, deadline, preflightReady, apiResult)
  if preflightReady and apiResult ~= false then
    return 'sent'
  end
  if deadline and now >= deadline then
    return 'drop'
  end
  return 'retry'
end

function CatchDispatch.retryDelay(now, deadline, interval)
  local delay = math.max(1, tonumber(interval) or 1)
  if deadline then
    delay = math.min(delay, math.max(1, deadline - now))
  end
  return delay
end

return CatchDispatch
