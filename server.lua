-- server.lua (fixed & improved)
-- AZ Tow server logic (full file with improved AI templates and forcing logic)

local Calls = {}
local Impounded = {}
local CallIdCounter = 0

local function makeCallId()
    CallIdCounter = CallIdCounter + 1
    return tostring(os.time()) .. '_' .. tostring(CallIdCounter)
end

-- Try several export names / strategies to fetch a player's job safely.
-- Returns either a string (job name) or a table (job object) or nil.
local function getPlayerJobSafe(playerId)
    if not playerId then return nil end

    -- try a global Az accessor if present
    if type(_G.Az) == 'table' and type(_G.Az.getPlayerJob) == 'function' then
        local ok, job = pcall(function() return _G.Az.getPlayerJob(playerId) end)
        if ok and job then return job end
    end

    -- try common export names (wrap in pcall to avoid exceptions)
    local exportCandidates = { 'Az-Framework', 'az-fw', 'az_framework', 'az-framework', 'az_framework_core' }
    for _, name in ipairs(exportCandidates) do
        if exports[name] then
            local ok, job = pcall(function() return exports[name]:getPlayerJob(playerId) end)
            if ok and job then return job end
            -- some exports use different function names; try a few variants
            ok, job = pcall(function() return exports[name]:GetPlayerJob(playerId) end)
            if ok and job then return job end
            ok, job = pcall(function() return exports[name]:GetJob(playerId) end)
            if ok and job then return job end
        end
    end

    -- fallback: some frameworks store job on a player object accessible via players table
    -- not reliable across frameworks, so return nil if nothing found
    return nil
end

local function jobMatchesTow(job, towName)
    if not job then return false end
    if type(job) == 'string' then
        return job == towName
    elseif type(job) == 'table' then
        -- common shapes: { name = "tow", label = "..."} or {job = "tow"} etc
        if job.name and job.name == towName then return true end
        if job.job and job.job == towName then return true end
        if job.id and job.id == towName then return true end
        -- sometimes job itself contains a nested structure
        for _, v in pairs(job) do
            if type(v) == 'string' and v == towName then return true end
            if type(v) == 'table' and (v.name == towName or v.id == towName) then return true end
        end
    end
    return false
end

-- notify only players on tow job (safe, with debug prints)
local function notifyTowPlayers(eventName, payload)
    for _, ply in ipairs(GetPlayers()) do
        local pid = tonumber(ply)
        if not pid then goto continue end
        local ok, job = pcall(function() return getPlayerJobSafe(pid) end)
        if ok and job and Config and Config.TowJobName and jobMatchesTow(job, Config.TowJobName) then
            print(('[az_tow] sending %s to tow player %s'):format(tostring(eventName), tostring(pid)))
            TriggerClientEvent(eventName, pid, payload)
        else
            -- debug: show that we skipped a player (optional, keep to debug problems)
            -- print(('[az_tow] skipped player %s for %s (job=%s)'):format(tostring(pid), tostring(eventName), tostring(job)))
        end
        ::continue::
    end
end

local function rnd(tbl) return tbl[math.random(1, #tbl)] end

-- AI templates for varied callouts
local AITemplates = {
    flat_tire = {
        npc = true,
        npcModels = { 'a_m_m_skater_01', 'a_f_m_bevhills_01', 'a_m_y_business_01' },
        vehicles = { 'sadler', 'bison', 'dubsta3' },
        smoking = false,
        messages = {
            "Hit a nail — tyre shredded. Can't move.",
            "Flat tire, stuck on the shoulder. Can you help?",
            "Blew a tyre, I'm stood next to the car. Need a tow."
        }
    },
    two_vehicle_wreck = {
        npc = true,
        npcModels = { 'a_m_m_skater_01', 'a_m_m_farmer_01', 'a_f_m_ktown_01' },
        vehicles = { 'journey', 'bobcat', 'bison', 'rebel' },
        smoking = true,
        messages = {
            "Two cars collided and one is smoking. Both drivers are shaken.",
            "Head-on crash blocking the lane — cars smoking and people outside.",
            "Bad wreck. Vehicles are hard to move, need recovery & tow.",
            "Major collision; both vehicles are damaged and leaking fluids."
        }
    },
    smoking_car = {
        npc = true,
        npcModels = { 'a_m_m_beach_01', 'a_f_y_hipster_01' },
        vehicles = { 'sadler', 'bison' },
        smoking = true,
        messages = {
            "My engine's smoking, I can smell burning. Parked at the side.",
            "Smoke coming from under the hood. I'm out of the car.",
            "Overheated and smoking, need recovery before it flames up."
        }
    },
    stalled = {
        npc = true,
        npcModels = { 'a_f_y_scdressy_01', 'a_m_m_aldinapoli' },
        vehicles = { 'sadler', 'bison' },
        smoking = false,
        messages = {
            "Car won't start and I'm blocking the lane.",
            "Battery dead and I'm stuck, need a flatbed or jump.",
            "Engine won't turn over, can't move — please tow."
        }
    }
}

-- Player-created call
RegisterNetEvent('tow:playerCall')
AddEventHandler('tow:playerCall', function(x, y, z, message)
    local src = source
    print(('[az_tow][server] received playerCall from %s coords=%.2f,%.2f,%.2f msg=%s'):format(
        tostring(src),
        tonumber(x) or 0,
        tonumber(y) or 0,
        tonumber(z) or 0,
        tostring(message)
    ))

    -- build a call object and store it server-side
    local callId = makeCallId()
    local callerName = nil
    local ok, name = pcall(function() return GetPlayerName(src) end)
    if ok and name then callerName = name else callerName = 'Caller' end

    local call = {
        id = callId,
        caller = src,
        src = src, -- legacy field some handlers expect
        callerName = callerName,
        message = tostring(message or ''),
        coords = { x = tonumber(x) or 0.0, y = tonumber(y) or 0.0, z = tonumber(z) or 0.0 },
        ai = false,
        assigned = nil,
        created = os.time(),
        type = 'player',
        description = tostring(message or '')
    }

    -- store & broadcast
    Calls[callId] = call
    print(('[az_tow][server] broadcasting player call id=%s'):format(callId))

    -- broadcast to tow players (job-filtered)
    if Config and Config.TowJobName then
        notifyTowPlayers('tow:receiveCall', call)
    else
        -- fallback: broadcast to all if no config set
        TriggerClientEvent('tow:receiveCall', -1, call)
    end
end)

-- Accept call
RegisterNetEvent('tow:acceptCall')
AddEventHandler('tow:acceptCall', function(callId)
    local src = source
    if not callId or not Calls[callId] then
        TriggerClientEvent('chat:addMessage', src, { args = { '^1Tow', 'This call has expired or does not exist.' } })
        return
    end
    if Calls[callId].assigned then
        TriggerClientEvent('chat:addMessage', src, { args = { '^1Tow', 'This call has already been accepted.' } })
        return
    end

    Calls[callId].assigned = src

    local caller = Calls[callId].caller or Calls[callId].src
    if caller then
        local ok, towName = pcall(function() return GetPlayerName(src) end)
        local towLabel = (ok and towName) and towName or 'a tow operator'
        TriggerClientEvent('chat:addMessage', caller, { args = { '^2Tow', towLabel .. ' is en route.' } })
    end

    -- notify other tow players that the call was taken
    notifyTowPlayers('tow:callTaken', { callId = callId, by = src })

    -- notify accepting client with the assigned call details
    TriggerClientEvent('tow:callAssigned', src, Calls[callId])
    print(('[az_tow] call accepted: %s by %s'):format(callId, tostring(src)))
end)

-- Request impound
RegisterNetEvent('tow:requestImpound')
AddEventHandler('tow:requestImpound', function(plate, netId)
    local src = source
    local job = getPlayerJobSafe(src)
    if not (Config and Config.TowJobName) or not job or not jobMatchesTow(job, Config.TowJobName) then
        TriggerClientEvent('chat:addMessage', src, { args = { '^1Tow', 'You must be on the tow job to impound vehicles.' } })
        return
    end
    if not plate then
        TriggerClientEvent('chat:addMessage', src, { args = { '^1Tow', 'No plate provided.' } })
        return
    end
    Impounded[plate] = { plate = plate, impoundedBy = src, time = os.time() }
    TriggerClientEvent('tow:doImpoundClient', src, netId, plate)
    TriggerClientEvent('chat:addMessage', src, { args = { '^2Tow', 'Vehicle with plate ' .. plate .. ' has been impounded.' } })
    print(('[az_tow] vehicle impounded: %s by %s'):format(tostring(plate), tostring(src)))
end)

RegisterNetEvent('tow:reportImpounded')
AddEventHandler('tow:reportImpounded', function(plate)
    print(('[az_tow] vehicle impounded report: %s'):format(tostring(plate)))
end)

-- Return active calls (only tow job)
RegisterNetEvent('tow:requestCalls')
AddEventHandler('tow:requestCalls', function()
    local src = source
    local job = getPlayerJobSafe(src)
    if not (Config and Config.TowJobName) or not job or not jobMatchesTow(job, Config.TowJobName) then
        TriggerClientEvent('chat:addMessage', src, { args = { '^1Tow', 'You must be on the tow job to view calls.' } })
        return
    end

    local out = {}
    for id, c in pairs(Calls) do
        table.insert(out, {
            id = c.id,
            callerName = c.callerName,
            message = c.message,
            coords = c.coords,
            created = c.created,
            assigned = c.assigned and true or false,
            ai = c.ai and true or false,
            type = c.type,
            description = c.description,
            npcModel = c.npcModel,
            vehicles = c.vehicles,
            smoking = c.smoking
        })
    end
    TriggerClientEvent('tow:receiveCallsList', src, out)
end)

-- Remove a call (only tow job)
RegisterNetEvent('tow:removeCall')
AddEventHandler('tow:removeCall', function(callId)
    local src = source
    local job = getPlayerJobSafe(src)
    if not (Config and Config.TowJobName) or not job or not jobMatchesTow(job, Config.TowJobName) then
        TriggerClientEvent('chat:addMessage', src, { args = { '^1Tow', 'You must be on the tow job to remove calls.' } })
        return
    end
    if not callId or not Calls[callId] then
        TriggerClientEvent('chat:addMessage', src, { args = { '^1Tow', 'Call not found.' } })
        return
    end

    Calls[callId] = nil
    notifyTowPlayers('tow:callRemoved', { callId = callId })
    TriggerClientEvent('chat:addMessage', src, { args = { '^2Tow', 'Call removed.' } })
    print(('[az_tow] call removed: %s by %s'):format(callId, tostring(src)))
end)

-- Validate open menu
RegisterNetEvent('tow:requestOpenMenu')
AddEventHandler('tow:requestOpenMenu', function()
    local src = source
    local job = getPlayerJobSafe(src)
    if not (Config and Config.TowJobName) or not job or not jobMatchesTow(job, Config.TowJobName) then
        TriggerClientEvent('tow:openMenu', src, false)
        return
    end
    TriggerClientEvent('tow:openMenu', src, true)
end)

-- AI call generator (interval)
Citizen.CreateThread(function()
    while true do
        local interval = (Config and Config.AICallIntervalMinutes) or 0
        if interval > 0 then
            Citizen.Wait(interval * 60 * 1000)
            local towOnline = false
            for _, ply in ipairs(GetPlayers()) do
                local pid = tonumber(ply)
                if pid then
                    local job = getPlayerJobSafe(pid)
                    if job and Config and jobMatchesTow(job, Config.TowJobName) then
                        towOnline = true
                        break
                    end
                end
            end

            if towOnline then
                if not (Config and Config.AICallAnchors) or #Config.AICallAnchors == 0 then
                    print('[az_tow] No AICallAnchors configured; skipping AI call creation.')
                else
                    local anchor = Config.AICallAnchors[math.random(1, #Config.AICallAnchors)]
                    local ox = math.random(-30,30)
                    local oy = math.random(-30,30)
                    local posx = anchor.x + ox
                    local posy = anchor.y + oy
                    local posz = anchor.z or 33.0

                    local types = { 'flat_tire', 'two_vehicle_wreck', 'smoking_car', 'stalled' }
                    local typeKey = types[math.random(1, #types)]
                    local tpl = AITemplates[typeKey] or AITemplates['stalled']
                    local description = tpl.messages[math.random(1, #tpl.messages)]

                    local callId = makeCallId()
                    local callData = {
                        id = callId,
                        src = nil,
                        caller = nil,
                        callerName = 'Civ (AI)',
                        coords = { x = posx, y = posy, z = posz },
                        message = ('AI: %s'):format(description),
                        created = os.time(),
                        assigned = nil,
                        ai = true,
                        type = typeKey,
                        description = description,
                        smoking = tpl.smoking or false
                    }

                    if tpl.npc then
                        callData.npcModel = tpl.npcModels[math.random(1, #tpl.npcModels)]
                        callData.npcHeading = math.random(0, 360)
                        callData.npcCoords = { x = posx + math.random(-3,3), y = posy + math.random(-3,3), z = posz }
                    end

                    callData.vehicles = {}
                    if tpl.vehicles and #tpl.vehicles > 0 then
                        local pool = {}
                        for _, m in ipairs(tpl.vehicles) do table.insert(pool, m) end
                        local want = (typeKey == 'two_vehicle_wreck') and math.min(2, #pool) or 1
                        for i=1,want do
                            local idx = math.random(1, #pool)
                            local model = pool[idx]
                            table.remove(pool, idx)
                            table.insert(callData.vehicles, {
                                model = model,
                                offset = { x = (i==1) and -2.5 or 2.5, y = math.random(-1,1), z = 0 }
                            })
                        end
                    else
                        if typeKey == 'stalled' or typeKey == 'flat_tire' or typeKey == 'smoking_car' then
                            table.insert(callData.vehicles, { model = 'sadler', offset = { x = -2.5, y = 0.0, z = 0 } })
                        end
                    end

                    Calls[callId] = callData
                    notifyTowPlayers('tow:receiveCall', Calls[callId])
                    print('[az_tow] AI call created: ' .. callId .. ' type=' .. tostring(typeKey))
                end
            end
        else
            Citizen.Wait(60 * 1000)
        end
    end
end)

-- Expire calls
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(30 * 1000)
        local now = os.time()
        for id, c in pairs(Calls) do
            if now - c.created > (Config and Config.CallTimeoutSeconds or 300) then
                Calls[id] = nil
                notifyTowPlayers('tow:callExpired', { callId = id })
                print(('[az_tow] call expired: %s'):format(id))
            end
        end
    end
end)

-- Force AI call (client may provide type)
RegisterNetEvent('tow:requestForceAICall')
AddEventHandler('tow:requestForceAICall', function(x, y, z, requestedType)
    local src = source
    if not x or not y or not z then
        print(('[az_tow] forceAICall: missing coords from %s'):format(tostring(src)))
        return
    end

    local types = { 'flat_tire', 'two_vehicle_wreck', 'smoking_car', 'stalled' }
    local typeKey = nil
    if requestedType and type(requestedType) == 'string' and AITemplates[requestedType] then
        typeKey = requestedType
    else
        typeKey = types[math.random(1, #types)]
    end
    local tpl = AITemplates[typeKey] or AITemplates['stalled']

    local ox = math.random(-10,10)
    local oy = math.random(-10,10)
    local posx = x + ox
    local posy = y + oy
    local posz = z

    local description = tpl.messages[math.random(1, #tpl.messages)]
    local callId = makeCallId()
    local callData = {
        id = callId,
        src = nil,
        caller = nil,
        callerName = 'Civ (AI)',
        coords = { x = posx, y = posy, z = posz },
        message = ('AI: %s'):format(description),
        created = os.time(),
        assigned = nil,
        ai = true,
        type = typeKey,
        description = description,
        smoking = tpl.smoking or false
    }

    if tpl.npc then
        callData.npcModel = tpl.npcModels[math.random(1,#tpl.npcModels)]
        callData.npcHeading = math.random(0, 360)
        callData.npcCoords = { x = posx + math.random(-3,3), y = posy + math.random(-3,3), z = posz }
    end

    callData.vehicles = {}
    if tpl.vehicles and #tpl.vehicles > 0 then
        local pool = {}
        for _, m in ipairs(tpl.vehicles) do table.insert(pool, m) end
        local want = (typeKey == 'two_vehicle_wreck') and math.min(2, #pool) or 1
        for i=1,want do
            local idx = math.random(1, #pool)
            local model = pool[idx]
            table.remove(pool, idx)
            table.insert(callData.vehicles, {
                model = model,
                offset = { x = (i==1) and -2.5 or 2.5, y = math.random(-1,1), z = 0 }
            })
        end
    else
        if typeKey == 'stalled' or typeKey == 'flat_tire' or typeKey == 'smoking_car' then
            table.insert(callData.vehicles, { model = 'sadler', offset = { x = -2.5, y = 0.0, z = 0 } })
        end
    end

    Calls[callId] = callData
    notifyTowPlayers('tow:receiveCall', Calls[callId])
    print('[az_tow] Forced AI call created: ' .. callId .. ' type=' .. tostring(typeKey) .. ' by=' .. tostring(src))
end)

-- Utility export
exports('GetImpoundedPlates', function()
    local out = {}
    for k,v in pairs(Impounded) do table.insert(out, k) end
    return out
end)
