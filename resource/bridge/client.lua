--[[
    Optional UI delegation to nex_uipack.

    When the `nex_uipack` resource is started, every NUI native used inside
    ox_lib routes through its exports so the redesigned iframe receives all
    traffic. When nex_uipack isn't present, isn't started, or its export
    call throws for any reason, these wrappers fall back to the real native
    and ox_lib keeps using its own bundled iframe — consumers never have to
    care which one is active, and a failing pack can never break ox_lib.

    The file lives under `resource/bridge/` so the existing
    `resource/**/client.lua` glob picks it up, and it sorts first
    alphabetically so the overrides are installed before any other ox_lib
    client file runs. No other ox_lib file needs to be touched.
]]

local PACK = 'nexdev_uipack'

-- Cache the real natives so fallback and restart paths still work after the
-- globals have been overridden below.
local nativeSendNUI      = SendNUIMessage
local nativeSendNui      = SendNuiMessage
local nativeSetFocus     = SetNuiFocus
local nativeSetFocusKeep = SetNuiFocusKeepInput
local nativeIsKeep       = IsNuiFocusKeepingInput
local nativeRegister     = RegisterNUICallback

local function packActive()
    return GetResourceState(PACK) == 'started'
end

-- Attempt a cross-resource export call. Returns (true, result) on success,
-- (false, nil) on any error. The caller falls back to the native on false.
--
-- "No such export" falls back SILENTLY: on client join the pack's resource
-- state already reads 'started' before its scripts have executed, so every
-- boot-time forward hits that error and then self-heals (callbacks are
-- replayed by the onClientResourceStart handler below). It's equally the
-- expected shape when the pack is absent or outdated — never a reason to
-- spam the console. Anything else is a real error inside the pack's export
-- and is logged once per distinct failure.
local warned = {}

local function tryPack(name, ...)
    if not packActive() then return false end
    local ok, result = pcall(function(...)
        return exports[PACK][name](exports[PACK], ...)
    end, ...)
    if not ok then
        local msg = tostring(result)
        local key = name .. '|' .. msg
        if not msg:find('No such export', 1, true) and not warned[key] then
            warned[key] = true
            print(('[ox_lib bridge] %s forward failed, falling back to native: %s'):format(name, msg))
        end
        return false
    end
    return true, result
end

function SendNUIMessage(data)
    local ok, result = tryPack('sendMessage', data)
    if ok then return result end
    return nativeSendNUI(data)
end

function SendNuiMessage(raw)
    local ok, result = tryPack('sendRawMessage', raw)
    if ok then return result end
    return nativeSendNui(raw)
end

function SetNuiFocus(focus, cursor)
    local ok, result = tryPack('setFocus', focus, cursor)
    if ok then return result end
    return nativeSetFocus(focus, cursor)
end

function SetNuiFocusKeepInput(keep)
    local ok, result = tryPack('setFocusKeepInput', keep)
    if ok then return result end
    return nativeSetFocusKeep(keep)
end

function IsNuiFocusKeepingInput()
    local ok, result = tryPack('isFocusKeepingInput')
    if ok then return result end
    return nativeIsKeep()
end

-- Remember every callback ox_lib registers so we can replay them onto
-- nex_uipack if it boots (or restarts) after ox_lib is already running.
local registered = {}

function RegisterNUICallback(name, handler)
    registered[name] = handler
    nativeRegister(name, handler) -- bind on ox_lib too, for the no-pack fallback path
    tryPack('registerCallback', name, handler)
end

AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= PACK then return end
    for name, handler in pairs(registered) do
        tryPack('registerCallback', name, handler)
    end
end)
