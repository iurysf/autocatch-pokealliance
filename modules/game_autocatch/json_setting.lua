-- Card lists kept in g_settings as JSON.
--
-- The settings file is OTML, and OTML reads a value written as "[...]" as an
-- inline list: it splits it at the commas and the string value comes back
-- empty. A JSON array saved with g_settings.set was therefore lost on the next
-- client start: Auto Catch fell back to its single-item legacy keys, so every
-- start on 24/09 loaded one Auto Item card with no buff learned and dropped
-- the others (the food card was added again as cards 3, 5, 6, 7 and 8).
-- The list is now saved inside an object, which OTML keeps as a string.

local JsonSetting = {}

function JsonSetting.wrap(list)
  return { list = list or {} }
end

-- The list inside a decoded value: the object form, or a bare array (still in
-- memory in the same session, or written by an older build).
function JsonSetting.unwrap(decoded)
  if type(decoded) ~= 'table' then return nil end
  if type(decoded.list) == 'table' then return decoded.list end
  if decoded[1] ~= nil or next(decoded) == nil then return decoded end
  return nil
end

local function trim(text)
  return (tostring(text):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function scalar(text)
  text = trim(text)
  if text == 'true' then return true end
  if text == 'false' then return false end
  return tonumber(text) or text
end

-- Rebuilds a list of flat objects (scalars and arrays of scalars) from the
-- pieces OTML left of an array of objects: '{"a":1', '"b":["x"', '"y"]}', ...
-- (quotes may or may not have been removed by the parser).
function JsonSetting.rebuild(pieces)
  local list, current, arrayKey = {}, nil, nil
  for _, rawPiece in ipairs(pieces or {}) do
    local piece = trim(tostring(rawPiece):gsub('"', ''))
    if piece:sub(1, 1) == '{' then
      current, arrayKey = {}, nil
      list[#list + 1] = current
      piece = trim(piece:sub(2))
    end
    local closes = piece:sub(-1) == '}'
    if closes then piece = trim(piece:sub(1, -2)) end
    if current then
      if arrayKey then
        local ends = piece:sub(-1) == ']'
        local item = ends and trim(piece:sub(1, -2)) or piece
        if item ~= '' then table.insert(current[arrayKey], scalar(item)) end
        if ends then arrayKey = nil end
      else
        local key, value = piece:match('^([^:]+):(.*)$')
        if key then
          key, value = trim(key), trim(value)
          if value:sub(1, 1) == '[' then
            local inner = trim(value:sub(2))
            local ends = inner:sub(-1) == ']'
            if ends then inner = trim(inner:sub(1, -2)) end
            current[key] = {}
            if inner ~= '' then table.insert(current[key], scalar(inner)) end
            if not ends then arrayKey = key end
          else
            current[key] = scalar(value)
          end
        end
      end
    end
    if closes then current, arrayKey = nil, nil end
  end
  return list
end

-- Reads a card list through `settings` (g_settings) and `decode` (json.decode).
-- Returns the list (or nil) and how it was found: 'object', 'array' (old
-- format, same session) or 'rebuilt' (old format after a restart).
function JsonSetting.read(settings, decode, key)
  local raw = settings.getString(key, '')
  if raw ~= '' then
    local ok, decoded = pcall(decode, raw)
    local list = ok and JsonSetting.unwrap(decoded) or nil
    if list then return list, type(decoded.list) == 'table' and 'object' or 'array' end
  end
  local ok, pieces = pcall(function() return settings.getList(key) end)
  if ok and type(pieces) == 'table' and #pieces > 0 then
    local list = JsonSetting.rebuild(pieces)
    if #list > 0 then return list, 'rebuilt' end
  end
  return nil
end

return JsonSetting
