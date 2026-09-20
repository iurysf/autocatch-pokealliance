-- Deteccao de staff (GM, CM, ADM, GOD, Tutor) entre as criaturas visiveis.
-- Mesmos padroes usados pelo CaveBot PKA (cavebot_pka/adapters/pka.lua).
local StaffGuard = {}

StaffGuard.PATTERNS = {
  '^%[gm%]', '^%[cm%]', '^%[adm%]', '^%[god%]', '^%[tutor%]', '^%[staff%]',
  '^gm%s+', '^cm%s+', '^adm%s+', '^god%s+', '^tutor%s+', '^staff%s+'
}

local function normalize(name)
  return tostring(name or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
end

function StaffGuard.isStaffName(name)
  local lower = normalize(name)
  if lower == '' then return false end
  for _, pattern in ipairs(StaffGuard.PATTERNS) do
    if lower:match(pattern) then return true end
  end
  return false
end

local function creatureName(creature)
  if type(creature) == 'table' and creature.name and not creature.getName then
    return tostring(creature.name)
  end
  local ok, name = pcall(function() return creature:getName() end)
  return ok and name and tostring(name) or ''
end

local function creatureFlag(creature, methodName)
  local ok, value = pcall(function()
    local method = creature[methodName]
    return type(method) == 'function' and method(creature) or nil
  end)
  return ok and value == true
end

-- Devolve o nome do primeiro staff encontrado (ou nil). knownNames e um
-- conjunto opcional de nomes (minusculos) confirmados por outro canal.
function StaffGuard.findStaff(creatures, knownNames)
  for _, creature in ipairs(creatures or {}) do
    local name = creatureName(creature)
    if StaffGuard.isStaffName(name) then return name end
    if knownNames and knownNames[normalize(name)] then return name end
    if creatureFlag(creature, 'isGamemaster') or creatureFlag(creature, 'isStaff') then
      return name ~= '' and name or 'staff'
    end
  end
  return nil
end

return StaffGuard
