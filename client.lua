-- client.lua (cleaned + dialog NUI integration)
-- AZ Tow client (consolidated & cleaned + dialog -> NUI notifications)
-- Sends driver dialog to NUI instead of chat for a consistent UI experience.

-- State
local displayCall = nil
local currentAssignedCallId = nil
local currentCallBlip = nil
local spawnedAI = {} -- [callId] = { peds = {}, vehs = {}, blip = <blip>, dialogLines = {}, dialogShown = false, tirePopped = false }
local trafficMode = 'normal' -- 'normal' | 'slow' | 'stopped'
local trafficThreadHandle = nil
local placedCones = {}
local blockingVeh = nil
local localCallMeta = {} -- [callId] = { serverCreated = <num>, receivedAt = <GetGameTimer()> }
local nuiOpen = false
local lastShownCallId = nil
local popupsEnabled = true -- toggleable (e.g. Off Duty disables popups)

-- Helpers
local function dbg(fmt, ...)
    print(('[az_tow] ' .. tostring(fmt)):format(...))
end

local function sendDialogToNui(callId, callerName, lines)
    if not lines or #lines == 0 then return end
    SendNUIMessage({
        action = 'showDialog',
        callId = callId,
        caller = callerName or 'Unknown',
        lines = lines
    })
end

local function sendSmallToast(msg)
    if not msg then return end
    SendNUIMessage({ action = 'showToast', message = tostring(msg) })
end

local function getRelativeAgeString(callId)
    local meta = localCallMeta[callId]
    if not meta then return 'N/A' end
    local now = GetGameTimer()
    local ageMs = now - meta.receivedAt
    local ageS = math.floor(ageMs / 1000)
    if ageS < 60 then
        return tostring(ageS) .. 's'
    elseif ageS < 3600 then
        return tostring(math.floor(ageS / 60)) .. 'm'
    else
        return tostring(math.floor(ageS / 3600)) .. 'h'
    end
end

-- Blip helpers
local function removeCurrentCallBlip()
    if currentCallBlip then
        if DoesBlipExist(currentCallBlip) then
            SetBlipRoute(currentCallBlip, false)
            RemoveBlip(currentCallBlip)
        end
        currentCallBlip = nil
    end
    SetWaypointOff()
    currentAssignedCallId = nil
end

local function createCallBlip(coords, callId)
    if not coords or not coords.x or not coords.y then return end

    if callId and spawnedAI[callId] and spawnedAI[callId].blip and DoesBlipExist(spawnedAI[callId].blip) then
        if currentCallBlip and DoesBlipExist(currentCallBlip) and currentCallBlip ~= spawnedAI[callId].blip then
            SetBlipRoute(currentCallBlip, false)
        end
        currentCallBlip = spawnedAI[callId].blip
        SetBlipSprite(currentCallBlip, 488)
        SetBlipScale(currentCallBlip, 1.0)
        SetBlipColour(currentCallBlip, 5)
        SetBlipRoute(currentCallBlip, true)
        SetNewWaypoint(coords.x, coords.y)
        currentAssignedCallId = callId
        return
    end

    if currentCallBlip and DoesBlipExist(currentCallBlip) then
        RemoveBlip(currentCallBlip)
    end

    local b = AddBlipForCoord(coords.x, coords.y, coords.z or 0.0)
    SetBlipSprite(b, 488)
    SetBlipScale(b, 1.0)
    SetBlipColour(b, 5)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentString("Tow Call")
    EndTextCommandSetBlipName(b)
    SetBlipRoute(b, true)
    SetNewWaypoint(coords.x, coords.y)
    currentCallBlip = b
    currentAssignedCallId = callId or nil
end

-- Traffic control
local function startTrafficThread()
    if trafficThreadHandle then return end
    trafficThreadHandle = true
    Citizen.CreateThread(function()
        while trafficThreadHandle do
            if trafficMode == 'slow' then
                SetVehicleDensityMultiplierThisFrame(0.25)
                SetRandomVehicleDensityMultiplierThisFrame(0.25)
                SetParkedVehicleDensityMultiplierThisFrame(0.25)
            elseif trafficMode == 'normal' then
                SetVehicleDensityMultiplierThisFrame(1.0)
                SetRandomVehicleDensityMultiplierThisFrame(1.0)
                SetParkedVehicleDensityMultiplierThisFrame(1.0)
            elseif trafficMode == 'stopped' then
                SetVehicleDensityMultiplierThisFrame(0.05)
                SetRandomVehicleDensityMultiplierThisFrame(0.05)
                SetParkedVehicleDensityMultiplierThisFrame(0.05)
            end
            Citizen.Wait(0)
        end
    end)
end

local function stopTrafficThread()
    trafficThreadHandle = nil
end

-- Blocking vehicle
local function spawnBlockingVehicle()
    if DoesEntityExist(blockingVeh) then
        SetEntityAsMissionEntity(blockingVeh, true, true)
        DeleteEntity(blockingVeh)
        blockingVeh = nil
    end

    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)
    local fwd = GetEntityForwardVector(ped)
    local spawnPos = pos + fwd * 8.0
    local model = GetHashKey('boxville2')
    RequestModel(model)
    local tries = 0
    while not HasModelLoaded(model) and tries < 100 do
        Citizen.Wait(10)
        tries = tries + 1
    end
    if not HasModelLoaded(model) then return end
    blockingVeh = CreateVehicle(model, spawnPos.x, spawnPos.y, spawnPos.z, GetEntityHeading(ped), true, false)
    SetVehicleOnGroundProperly(blockingVeh)
    SetEntityInvincible(blockingVeh, true)
    SetVehicleUndriveable(blockingVeh, true)
    SetEntityAsMissionEntity(blockingVeh, true, true)
    SetModelAsNoLongerNeeded(model)
end

local function removeBlockingVehicle()
    if DoesEntityExist(blockingVeh) then
        SetEntityAsMissionEntity(blockingVeh, true, true)
        DeleteVehicle(blockingVeh)
        blockingVeh = nil
    end
end

-- Cones
local function placeCones(count, spacing)
    count = tonumber(count) or 3
    spacing = tonumber(spacing) or 1.2

    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)
    local fwd = GetEntityForwardVector(ped)
    local basePos = pos + fwd * 2.0
    local heading = GetEntityHeading(ped)

    local model = GetHashKey('prop_roadcone02a')
    RequestModel(model)
    local tries = 0
    while not HasModelLoaded(model) and tries < 100 do
        Citizen.Wait(10)
        tries = tries + 1
    end
    if not HasModelLoaded(model) then
        dbg('placeCones: failed to load cone model')
        return
    end

    for i = 1, count do
        local off = (i - 1) * spacing
        local spawn = basePos + (fwd * off)
        local obj = CreateObject(model, spawn.x, spawn.y, spawn.z + 0.5, true, true, true)
        PlaceObjectOnGroundProperly(obj)
        SetEntityHeading(obj, heading)
        SetEntityAsMissionEntity(obj, true, true)
        table.insert(placedCones, obj)
        Citizen.Wait(30)
    end

    SetModelAsNoLongerNeeded(model)
end

local function removeCones()
    for _, obj in ipairs(placedCones) do
        if DoesEntityExist(obj) then
            SetEntityAsMissionEntity(obj, true, true)
            DeleteObject(obj)
        end
    end
    placedCones = {}
end

-- Road helpers
local function findRoadPosNear(x, y, z, maxRadius)
    maxRadius = maxRadius or 160.0
    if not x or not y or not z then
        return vector3(0.0, 0.0, 0.0)
    end

    local ok, fx, fy, fz = pcall(function()
        return GetClosestVehicleNodeWithHeading(x, y, z)
    end)

    if ok and fx and fy and fz then
        fx, fy, fz = tonumber(fx), tonumber(fy), tonumber(fz)
        if fx and fy and fz then
            return vector3(fx, fy, fz)
        end
    end

    for r = 10, maxRadius, 10 do
        for ang = 0, 360, 30 do
            local rad = math.rad(ang)
            local sx = x + r * math.cos(rad)
            local sy = y + r * math.sin(rad)
            local sOk, nx, ny, nz = pcall(function()
                return GetClosestVehicleNode(sx, sy, z)
            end)
            if sOk and nx and ny and nz then
                nx, ny, nz = tonumber(nx), tonumber(ny), tonumber(nz)
                if nx and ny and nz then
                    return vector3(nx, ny, nz)
                end
            end
        end
    end

    return vector3(tonumber(x) or 0.0, tonumber(y) or 0.0, tonumber(z) or 0.0)
end

local function safeGroundZ(x, y, z)
    local groundZ = tonumber(z) or 0.0
    local ok, gz = pcall(function()
        local success, ground = GetGroundZFor_3dCoord(x, y, z + 50.0, false)
        if success then return ground end
        return nil
    end)
    if ok and gz and type(gz) == 'number' then
        groundZ = gz
    end
    return groundZ
end

-- cleanup visuals
local function cleanupAICall(callId)
    if not callId then return end
    local entry = spawnedAI[callId]
    if not entry then return end

    if entry.blip and currentCallBlip and entry.blip == currentCallBlip then
        SetBlipRoute(currentCallBlip, false)
        currentCallBlip = nil
        currentAssignedCallId = nil
        SetWaypointOff()
    end

    if entry.blip and DoesBlipExist(entry.blip) then
        RemoveBlip(entry.blip)
    end

    if entry.peds then
        for _, ped in ipairs(entry.peds) do
            if DoesEntityExist(ped) then
                SetEntityAsMissionEntity(ped, true, true)
                DeletePed(ped)
            end
        end
    end
    if entry.vehs then
        for _, veh in ipairs(entry.vehs) do
            if DoesEntityExist(veh) then
                SetEntityAsMissionEntity(veh, true, true)
                DeleteVehicle(veh)
            end
        end
    end

    spawnedAI[callId] = nil
end

local function dismissAIPeds(callId)
    local entry = spawnedAI[callId]
    if not entry then
        TriggerEvent('chat:addMessage', { args = { '^1Tow', 'No spawned AI for that call.' } })
        return
    end
    if not entry.peds or #entry.peds == 0 then
        TriggerEvent('chat:addMessage', { args = { '^1Tow', 'No peds to dismiss.' } })
        return
    end
    for _, ped in ipairs(entry.peds) do
        if DoesEntityExist(ped) then
            SetEntityAsMissionEntity(ped, true, true)
            DeletePed(ped)
        end
    end
    entry.peds = {}
    TriggerEvent('chat:addMessage', { args = { '^2Tow', 'AI pedestrians dismissed for call ' .. tostring(callId) } })
end

local function removeAIVehicles(callId)
    local entry = spawnedAI[callId]
    if not entry then
        TriggerEvent('chat:addMessage', { args = { '^1Tow', 'No spawned AI for that call.' } })
        return
    end
    if not entry.vehs or #entry.vehs == 0 then
        TriggerEvent('chat:addMessage', { args = { '^1Tow', 'No vehicles to remove.' } })
        return
    end
    for _, veh in ipairs(entry.vehs) do
        if DoesEntityExist(veh) then
            SetEntityAsMissionEntity(veh, true, true)
            DeleteVehicle(veh)
        end
    end
    entry.vehs = {}
    TriggerEvent('chat:addMessage', { args = { '^2Tow', 'AI vehicles removed for call ' .. tostring(callId) } })
end

local function popCallTire(callId)
    local entry = spawnedAI[callId]
    if not entry then
        TriggerEvent('chat:addMessage', { args = { '^1Tow', 'No spawned AI for that call.' } })
        return
    end
    if entry.tirePopped then
        TriggerEvent('chat:addMessage', { args = { '^2Tow', 'Tire already popped for that call.' } })
        return
    end
    if not entry.vehs or #entry.vehs == 0 then
        TriggerEvent('chat:addMessage', { args = { '^1Tow', 'No vehicle found to pop tire on.' } })
        return
    end

    local veh = entry.vehs[1]
    if DoesEntityExist(veh) then
        local tyreIndex = math.random(0,5)
        local ok, _ = pcall(function()
            SetVehicleTyreBurst(veh, tyreIndex, true, 1000.0)
        end)
        entry.tirePopped = true
        SetVehicleEngineHealth(veh, 40.0)
        TriggerEvent('chat:addMessage', { args = { '^2Tow', 'Popped a tyre on the primary vehicle ('..tostring(tyreIndex)..').' } })
    else
        TriggerEvent('chat:addMessage', { args = { '^1Tow', 'Vehicle entity not present.' } })
    end
end

-- Small help notification
local function ShowHelpNotification(text)
    BeginTextCommandDisplayHelp("STRING")
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayHelp(0, false, true, -1)
end

-- Single robust spawn function
local function spawnAICallVisuals(call)
    if not call or not call.id or not call.coords then
        dbg('spawnAICallVisuals: invalid call data')
        return
    end

    if spawnedAI[call.id] then
        dbg('spawnAICallVisuals: visuals already exist for id=%s, skipping', tostring(call.id))
        return
    end

    dbg('spawnAICallVisuals called - id=%s type=%s ai=%s npcModel=%s vehicles=%s coords=%.2f,%.2f,%.2f',
        tostring(call.id),
        tostring(call.type),
        tostring(call.ai),
        tostring(call.npcModel),
        tostring((call.vehicles and #call.vehicles) or 0),
        tonumber(call.coords.x) or 0.0, tonumber(call.coords.y) or 0.0, tonumber(call.coords.z) or 0.0
    )

    local ped = PlayerPedId()
    local myPos = GetEntityCoords(ped)
    local minDist = 40.0
    local maxAttempts = 20
    local chosenRoad = nil

    for attempt = 1, maxAttempts do
        local dist = math.random(40, 120)
        local ang = math.rad(math.random(0,359))
        local candX = myPos.x + dist * math.cos(ang)
        local candY = myPos.y + dist * math.sin(ang)
        local candZ = myPos.z
        local node = findRoadPosNear(candX, candY, candZ, 160.0)
        if node and Vdist(node.x, node.y, node.z, myPos.x, myPos.y, myPos.z) >= minDist then
            chosenRoad = node
            break
        end
    end

    if not chosenRoad then
        chosenRoad = findRoadPosNear(call.coords.x, call.coords.y, call.coords.z, 160.0)
    end

    if chosenRoad then
        local distToPlayer = Vdist(chosenRoad.x, chosenRoad.y, chosenRoad.z, myPos.x, myPos.y, myPos.z)
        if distToPlayer < minDist then
            local dx = chosenRoad.x - myPos.x
            local dy = chosenRoad.y - myPos.y
            local mag = math.max(0.0001, math.sqrt(dx*dx + dy*dy))
            local push = (minDist - distToPlayer) + 20.0
            chosenRoad = vector3(chosenRoad.x + (dx / mag) * push, chosenRoad.y + (dy / mag) * push, chosenRoad.z)
        end
    else
        chosenRoad = vector3(myPos.x + (minDist + 20.0), myPos.y, myPos.z)
    end

    local cx = tonumber(chosenRoad.x) or tonumber(call.coords.x) or 0.0
    local cy = tonumber(chosenRoad.y) or tonumber(call.coords.y) or 0.0
    local cz = safeGroundZ(cx, cy, tonumber(chosenRoad.z) or tonumber(call.coords.z) or 0.0)
    call.coords = { x = cx, y = cy, z = cz }

    -- scene blip (no route)
    local sceneBlip = AddBlipForCoord(cx, cy, cz)
    SetBlipSprite(sceneBlip, 488)
    SetBlipScale(sceneBlip, 0.9)
    SetBlipColour(sceneBlip, 5)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentString("AI Tow Call")
    EndTextCommandSetBlipName(sceneBlip)

    local entry = { peds = {}, vehs = {}, blip = sceneBlip, dialogLines = {}, dialogShown = false, tirePopped = false }

    if (not call.vehicles or #call.vehicles == 0) and call.ai then
        call.vehicles = call.vehicles or {}
        table.insert(call.vehicles, { model = 'sadler', offset = { x = -2.5, y = 0.0, z = 0 } })
    end

    if call.vehicles and type(call.vehicles) == 'table' and #call.vehicles > 0 then
        for i, vehInfo in ipairs(call.vehicles) do
            local modelName = tostring(vehInfo.model or vehInfo.modelName or 'sadler')
            local offsetX = (vehInfo.offset and vehInfo.offset.x) or ((i == 1) and -2.5 or 2.5)
            local offsetY = (vehInfo.offset and vehInfo.offset.y) or ( (i==1) and math.random(-1,1) or math.random(-1,1) )
            local spawnX = cx + (offsetX or 0)
            local spawnY = cy + (offsetY or 0)
            local spawnZ = safeGroundZ(spawnX, spawnY, cz + ((vehInfo.offset and vehInfo.offset.z) or 0))

            dbg('spawn vehicle attempt - model=%s at %.2f, %.2f, %.2f', modelName, spawnX, spawnY, spawnZ)

            local hash = GetHashKey(modelName)
            RequestModel(hash)
            local tries = 0
            while not HasModelLoaded(hash) and tries < 200 do Citizen.Wait(10); tries = tries + 1 end
            if not HasModelLoaded(hash) then
                dbg('spawn vehicle failed to load model: %s (tries=%d)', modelName, tries)
            else
                local veh = CreateVehicle(hash, spawnX, spawnY, spawnZ, math.random(0,360), true, false)
                Citizen.Wait(60)
                if DoesEntityExist(veh) then
                    SetEntityAsMissionEntity(veh, true, true)
                    SetVehicleOnGroundProperly(veh)
                    SetEntityCoordsNoOffset(veh, spawnX, spawnY, spawnZ, false, false, false)
                    SetVehicleNumberPlateText(veh, 'AI' .. tostring(math.random(1000,9999)))
                    SetVehicleEngineOn(veh, false, true, true)
                    SetVehicleUndriveable(veh, true)
                    SetVehicleEngineHealth(veh, 50.0)
                    if call.smoking then SetVehicleEngineHealth(veh, 20.0) end
                    table.insert(entry.vehs, veh)
                    dbg('vehicle spawned ok id=%s', tostring(veh))
                else
                    dbg('vehicle creation returned no entity for model=%s', modelName)
                end
                SetModelAsNoLongerNeeded(hash)
                Citizen.Wait(40)
            end
        end
    end

    local pedModelsToSpawn = {}
    if call.type == 'two_vehicle_wreck' then
        for i=1, 2 do
            local modelName = call.npcModel or 'a_m_m_skater_01'
            table.insert(pedModelsToSpawn, modelName)
        end
    else
        if call.npcModel then table.insert(pedModelsToSpawn, call.npcModel) end
    end

    if #pedModelsToSpawn == 0 and (#entry.vehs > 0) then
        table.insert(pedModelsToSpawn, 'a_m_m_skater_01')
    end

    for i, modelName in ipairs(pedModelsToSpawn) do
        local pedX, pedY = cx + (i * 1.7), cy + (i * 0.3)
        if entry.vehs and entry.vehs[i] and DoesEntityExist(entry.vehs[i]) then
            local vehCoords = GetEntityCoords(entry.vehs[i])
            pedX = vehCoords.x + 1.2
            pedY = vehCoords.y + (i==1 and -1.0 or 1.0)
        end
        local pedZ = safeGroundZ(pedX, pedY, cz)
        local pedHash = GetHashKey(modelName)
        RequestModel(pedHash)
        local tries = 0
        while not HasModelLoaded(pedHash) and tries < 200 do Citizen.Wait(10); tries = tries + 1 end
        if HasModelLoaded(pedHash) then
            local spawnedPed = CreatePed(4, pedHash, pedX, pedY, pedZ, call.npcHeading or math.random(0,360), true, false)
            if DoesEntityExist(spawnedPed) then
                SetEntityAsMissionEntity(spawnedPed, true, true)
                SetEntityCoordsNoOffset(spawnedPed, pedX, pedY, pedZ, false, false, false)
                TaskStandStill(spawnedPed, 30000)
                SetBlockingOfNonTemporaryEvents(spawnedPed, true)
                table.insert(entry.peds, spawnedPed)
                dbg('ped spawned ok id=%s model=%s', tostring(spawnedPed), tostring(modelName))
            end
            SetModelAsNoLongerNeeded(pedHash)
        else
            dbg('spawn ped failed to load model: %s (tries=%d)', tostring(modelName), tries)
        end
    end

    local dialogLines = {}
    if call.description and type(call.description) == 'string' then table.insert(dialogLines, call.description) end
    if call.type == 'flat_tire' then
        table.insert(dialogLines, "Driver: I hit something sharp and ripped the tire.")
        table.insert(dialogLines, "Driver: I'm near the guardrail, can't move.")
    elseif call.type == 'two_vehicle_wreck' then
        table.insert(dialogLines, "Driver 1: I didn't see them come across the lane!")
        table.insert(dialogLines, "Driver 2: My bumper's gone and it's smoking.")
    elseif call.type == 'smoking_car' then
        table.insert(dialogLines, "Driver: There's lots of smoke — I don't want to get back in the car.")
        table.insert(dialogLines, "Driver: Please hurry, it's getting worse.")
    elseif call.type == 'stalled' then
        table.insert(dialogLines, "Driver: Car won't start, possibly battery or starter.")
        table.insert(dialogLines, "Driver: I'm blocking traffic, be careful.")
    end

    entry.dialogLines = dialogLines
    entry.dialogShown = false
    entry.tirePopped = false

    spawnedAI[call.id] = entry

    if call.type == 'flat_tire' and entry.vehs and #entry.vehs > 0 then
        local ok, _ = pcall(function()
            local veh = entry.vehs[1]
            if DoesEntityExist(veh) then
                local tyreIndex = math.random(0,5)
                SetVehicleTyreBurst(veh, tyreIndex, true, 1000.0)
                entry.tirePopped = true
                SetVehicleEngineHealth(veh, 40.0)
                dbg('spawnAICallVisuals: popped tyre %d on veh %s for call %s', tyreIndex, tostring(veh), tostring(call.id))
            end
        end)
    end

    TriggerEvent('chat:addMessage', { args = { '^2Tow', 'AI call spawned nearby. Approach the scene and press E to speak to the driver.' } })
end

-- COMMANDS
RegisterCommand('calltow', function(source, args, raw)
    local msg = table.concat(args, ' ')
    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)
    print(('[az_tow][client] sending playerCall at %.2f,%.2f,%.2f msg=%s'):format(pos.x, pos.y, pos.z, tostring(msg)))
    TriggerServerEvent('tow:playerCall', pos.x, pos.y, pos.z, msg)
end, false)


RegisterCommand('spawntow', function(source, args, raw)
    local model = args[1] or (Config and Config.TowTruckModels and Config.TowTruckModels[1]) or 'flatbed'
    local hash = GetHashKey(model)
    RequestModel(hash)
    local tries = 0
    while not HasModelLoaded(hash) and tries < 100 do
        Citizen.Wait(10); tries = tries + 1
    end
    if not HasModelLoaded(hash) then
        TriggerEvent('chat:addMessage', { args = { '^1Tow', 'Model not found: ' .. model } })
        return
    end
    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)
    local veh = CreateVehicle(hash, pos.x + 2.0, pos.y + 2.0, pos.z, GetEntityHeading(ped), true, false)
    SetPedIntoVehicle(ped, veh, -1)
    SetEntityAsMissionEntity(veh, true, true)
    SetVehicleNumberPlateText(veh, 'AZTOW' .. tostring(math.random(100,999)))
    SetModelAsNoLongerNeeded(hash)
end, false)

RegisterCommand('impound', function(source, args, raw)
    local ped = PlayerPedId()
    local vehicle = nil
    vehicle = GetVehiclePedIsIn(ped, true)
    if vehicle == 0 then
        local pos = GetEntityCoords(ped)
        local fwd = GetEntityForwardVector(ped)
        local target = pos + fwd * 6.0
        local ray = StartShapeTestCapsule(pos.x, pos.y, pos.z, target.x, target.y, target.z, 3.0, 10, ped, 7)
        local _, hit, endCoords, surfaceNormal, entityHit = GetShapeTestResult(ray)
        if hit == 1 and DoesEntityExist(entityHit) and IsEntityAVehicle(entityHit) then vehicle = entityHit end
    end
    if not vehicle or vehicle == 0 then
        TriggerEvent('chat:addMessage', { args = { '^1Tow', 'No vehicle found to impound.' } })
        return
    end
    local plate = GetVehicleNumberPlateText(vehicle)
    local netId = NetworkGetNetworkIdFromEntity(vehicle)
    TriggerServerEvent('tow:requestImpound', plate, netId)
end, false)

RegisterCommand('forceaicall', function(source, args, raw)
    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)
    local requestedType = args[1]
    TriggerServerEvent('tow:requestForceAICall', pos.x, pos.y, pos.z, requestedType)
    TriggerEvent('chat:addMessage', { args = { '^2Tow', 'Requested forced AI call at your location.' } })
end, false)

RegisterCommand('towmenu', function()
    dbg('/towmenu pressed by client')
    SendNUIMessage({ action = 'hideCall' })
    SetNuiFocus(false, false)
    nuiOpen = false
    lastShownCallId = nil
    TriggerServerEvent('tow:requestOpenMenu')
end, false)

RegisterCommand('toggledispatch', function()
    popupsEnabled = not popupsEnabled
    if not popupsEnabled and nuiOpen then
        SendNUIMessage({ action = 'hideCall' })
        SetNuiFocus(false, false)
        nuiOpen = false
        lastShownCallId = nil
    end
    TriggerEvent('chat:addMessage', { args = { '^2Tow', 'Dispatch popups: ' .. (popupsEnabled and 'ENABLED' or 'DISABLED') } })
end, false)

-- Local test command to spawn a local AI call (no server)
RegisterCommand('testaicalllocal', function()
    local pos = GetEntityCoords(PlayerPedId())
    local fake = {
        id = 'localtest' .. tostring(math.random(1000,9999)),
        coords = { x = pos.x + 6.0, y = pos.y, z = pos.z },
        ai = true,
        type = 'stalled',
        npcModel = 'a_m_m_skater_01',
        vehicles = { { model = 'sadler' } },
        description = 'Local test call'
    }
    spawnAICallVisuals(fake)
end, false)

-- Ensure NUI hidden at start (one-time)
AddEventHandler('onClientResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    SendNUIMessage({ action = 'hideCall' })
    SendNUIMessage({ action = 'hideDialog' })
    SetNuiFocus(false, false)
    nuiOpen = false
    lastShownCallId = nil
    dbg('client init: NUI hide (immediate)')
    Citizen.SetTimeout(100, function()
        SendNUIMessage({ action = 'hideCall' })
        SendNUIMessage({ action = 'hideDialog' })
        SetNuiFocus(false, false)
        nuiOpen = false
        lastShownCallId = nil
        dbg('client init: NUI hide (100ms)')
    end)
    Citizen.SetTimeout(500, function()
        SendNUIMessage({ action = 'hideCall' })
        SendNUIMessage({ action = 'hideDialog' })
        SetNuiFocus(false, false)
        nuiOpen = false
        lastShownCallId = nil
        dbg('client init: NUI hide (500ms)')
    end)
    Citizen.SetTimeout(1000, function()
        SendNUIMessage({ action = 'hideCall' })
        SendNUIMessage({ action = 'hideDialog' })
        SetNuiFocus(false, false)
        nuiOpen = false
        lastShownCallId = nil
        dbg('client init: NUI hide (1000ms)')
    end)
end)

-- NUI / call display (receive calls)
RegisterNetEvent('tow:receiveCall')
AddEventHandler('tow:receiveCall', function(call)
    dbg('tow:receiveCall fired - id=%s ai=%s assigned=%s coords=%s',
        tostring(call and call.id),
        tostring(call and call.ai),
        tostring(call and call.assigned),
        tostring(call and call.coords and ('%.2f,%.2f'):format(call.coords.x or 0, call.coords.y or 0))
    )

    if not call then return end

    if call.id and call.created then
        localCallMeta[call.id] = { serverCreated = call.created, receivedAt = GetGameTimer() }
    end

    if not popupsEnabled then
        dbg('receiveCall ignored (popups disabled) - id=%s', tostring(call.id))
        return
    end

    if call.assigned then
        dbg('receiveCall ignored (already assigned) - id=%s', tostring(call.id))
        return
    end

    if call.id and lastShownCallId == call.id and nuiOpen then
        dbg('receiveCall ignored (duplicate) - id=%s', tostring(call.id))
        return
    end

    if call.ai then
        spawnAICallVisuals(call)
    end

    if Config and Config.NUI_ENABLED then
        lastShownCallId = call.id
        nuiOpen = true
        SendNUIMessage({ action = 'showCall', call = call })
        -- do NOT set NUI focus for the dialog notifications; keep focus only when dispatch UI needs it
        SetNuiFocus(true, true)
        dbg('showCall NUI opened - id=%s', tostring(call.id))
    else
        TriggerEvent('chat:addMessage', { args = { '^2Tow Call', ('Call from %s - %s'):format(call.callerName or 'Unknown', call.message or '') } })
    end
end)

-- When assigned
RegisterNetEvent('tow:callAssigned')
AddEventHandler('tow:callAssigned', function(call)
    SendNUIMessage({ action = 'hideCall', callId = call and call.id or nil })
    SetNuiFocus(false, false)
    nuiOpen = false
    lastShownCallId = nil
    SendNUIMessage({ action = 'hideDialog' })

    if call and call.id and call.created then
        localCallMeta[call.id] = { serverCreated = call.created, receivedAt = GetGameTimer() }
    end

    if not call or not call.coords then return end
    currentAssignedCallId = call.id
    createCallBlip(call.coords, call.id)
    TriggerEvent('chat:addMessage', { args = { '^2Tow', 'You accepted the call. Waypoint & blip set.' } })
end)

RegisterNetEvent('tow:callTaken')
AddEventHandler('tow:callTaken', function(data)
    SendNUIMessage({ action = 'hideCall', callId = data.callId })
    SetNuiFocus(false, false)
    nuiOpen = false
    lastShownCallId = nil
    SendNUIMessage({ action = 'hideDialog' })

    if currentAssignedCallId and data.callId == currentAssignedCallId and data.by and tonumber(data.by) ~= GetPlayerServerId(PlayerId()) then
        removeCurrentCallBlip()
    end

    local takenBy = data and data.by and tonumber(data.by) or nil
    local myServerId = GetPlayerServerId(PlayerId())

    if data and data.callId then
        if takenBy and takenBy == myServerId then
            dbg('tow:callTaken: call %s taken by us (%s) — preserving visuals', tostring(data.callId), tostring(myServerId))
        elseif currentAssignedCallId and data.callId == currentAssignedCallId and not takenBy then
            dbg('tow:callTaken: call %s matches our assigned call but no "by" field — preserving visuals', tostring(data.callId))
        else
            cleanupAICall(data.callId)
        end
    end

    TriggerEvent('chat:addMessage', { args = { '^2Tow', 'A call was accepted by another tow operator.' } })
end)

RegisterNetEvent('tow:callExpired')
AddEventHandler('tow:callExpired', function(data)
    SendNUIMessage({ action = 'hideCall', callId = data.callId })
    SetNuiFocus(false, false)
    nuiOpen = false
    lastShownCallId = nil
    SendNUIMessage({ action = 'hideDialog' })

    if currentAssignedCallId and data.callId == currentAssignedCallId then
        removeCurrentCallBlip()
    end

    if data and data.callId then
        if currentAssignedCallId and data.callId == currentAssignedCallId then
            dbg('tow:callExpired: call %s expired but is our assigned call — preserving visuals.', tostring(data.callId))
        else
            localCallMeta[data.callId] = nil
            cleanupAICall(data.callId)
        end
    end
end)

-- Receive list for menu
RegisterNetEvent('tow:receiveCallsList')
AddEventHandler('tow:receiveCallsList', function(list)
    dbg('tow:receiveCallsList received. itemCount=%s', tostring((list and #list) or 0))
    SetNuiFocus(false, false)

    if list then
        for _, c in ipairs(list) do
            if c.id and c.created then
                localCallMeta[c.id] = { serverCreated = c.created, receivedAt = GetGameTimer() }
            end
        end
    end

    local options = {}
    if not list or #list == 0 then
        table.insert(options, { title = 'No active calls' })
    else
        for i,call in ipairs(list) do
            local title = ('%s - %s'):format(call.callerName or 'Unknown', call.message or 'Tow request')
            local createdRaw = call.created and tostring(call.created) or 'N/A'
            local createdAge = call.id and getRelativeAgeString(call.id) or 'N/A'
            local desc = ('Assigned: %s\nAI: %s\nCreated: %s (%s)\nCoords: %.1f, %.1f'):format(
                call.assigned and 'Yes' or 'No',
                call.ai and 'Yes' or 'No',
                createdRaw,
                createdAge,
                (call.coords and call.coords.x) or 0.0,
                (call.coords and call.coords.y) or 0.0
            )
            table.insert(options, {
                title = title,
                description = desc,
                icon = 'truck',
                onSelect = function()
                    SetNuiFocus(false, false)
                    createCallBlip(call.coords, call.id)
                    TriggerEvent('chat:addMessage', { args = {'^2Tow', 'Waypoint set to selected call.'} })
                end,
                metadata = {
                    { label = 'ID', value = call.id or 'N/A' },
                    { label = 'Created (raw)', value = createdRaw },
                    { label = 'Age', value = createdAge }
                },
                arrow = true,
                event = 'tow:openCallSubmenu',
                args = { call = call }
            })
        end
    end

    lib.registerContext({
        id = 'tow_calls_menu',
        title = 'Active Tow Calls',
        options = options
    })
    lib.showContext('tow_calls_menu')
end)

-- Call submenu
RegisterNetEvent('tow:openCallSubmenu')
AddEventHandler('tow:openCallSubmenu', function(args)
    if not args or not args.call then return end
    local call = args.call

    local extraOptions = {}

    table.insert(extraOptions, {
        title = 'Set Waypoint & Blip',
        description = ('Coords: %.1f, %.1f'):format(call.coords.x, call.coords.y),
        icon = 'map-marker-alt',
        onSelect = function()
            SetNuiFocus(false, false)
            createCallBlip(call.coords, call.id)
            lib.hideContext(false)
            TriggerEvent('chat:addMessage', { args = {'^2Tow', 'Waypoint set.'} })
        end
    })

    table.insert(extraOptions, {
        title = 'Accept Call (Server)',
        description = 'Accept this call and assign to you',
        icon = 'check',
        onSelect = function()
            TriggerServerEvent('tow:acceptCall', call.id)
            lib.hideContext(false)
        end
    })

    table.insert(extraOptions, {
        title = 'Remove Call (Server)',
        description = 'Remove this call from dispatch (server-authoritative)',
        icon = 'trash',
        onSelect = function()
            TriggerServerEvent('tow:removeCall', call.id)
            lib.hideContext(false)
        end
    })

    if spawnedAI[call.id] then
        table.insert(extraOptions, {
            title = 'Dismiss Peds (Scene)',
            description = 'Remove pedestrians spawned for this call (client-only)',
            icon = 'walking',
            onSelect = function()
                SetNuiFocus(false, false)
                dismissAIPeds(call.id)
                lib.hideContext(false)
            end
        })
        table.insert(extraOptions, {
            title = 'Remove Vehicles (Scene)',
            description = 'Remove vehicles spawned for this call (client-only)',
            icon = 'car-crash',
            onSelect = function()
                SetNuiFocus(false, false)
                removeAIVehicles(call.id)
                lib.hideContext(false)
            end
        })
        if call.type == 'flat_tire' then
            table.insert(extraOptions, {
                title = 'Pop Tire (Scene)',
                description = 'Force a tyre to burst on the primary vehicle',
                icon = 'circle-notch',
                onSelect = function()
                    SetNuiFocus(false, false)
                    popCallTire(call.id)
                    lib.hideContext(false)
                end
            })
        end
        table.insert(extraOptions, {
            title = 'Play Dialog (Scene)',
            description = 'Play the dialog of the spawned scene (client-only)',
            icon = 'comments',
            onSelect = function()
                local entry = spawnedAI[call.id]
                if entry and entry.dialogLines and #entry.dialogLines > 0 then
                    if entry.dialogShown then
                        sendSmallToast("They're already spoken.")
                    else
                        entry.dialogShown = true
                        sendDialogToNui(call.id, call.callerName, entry.dialogLines)
                    end
                else
                    sendSmallToast("No dialog available for that scene.")
                end
                lib.hideContext(false)
            end
        })
    end

    table.insert(extraOptions, { title = 'Back', menu = 'tow_calls_menu' })

    lib.registerContext({
        id = 'tow_call_' .. call.id,
        title = ('Call: %s'):format(call.callerName or 'Unknown'),
        menu = 'tow_calls_menu',
        options = extraOptions
    })

    lib.showContext('tow_call_' .. call.id)
end)

RegisterNetEvent('tow:callRemoved')
AddEventHandler('tow:callRemoved', function(data)
    SetNuiFocus(false, false)
    nuiOpen = false
    lastShownCallId = nil
    SendNUIMessage({ action = 'hideDialog' })

    if data and data.callId and data.callId == currentAssignedCallId then
        removeCurrentCallBlip()
    end

    if data and data.callId then
        if currentAssignedCallId and data.callId == currentAssignedCallId then
            dbg('tow:callRemoved: call %s removed from dispatch but is our assigned call — preserving visuals.', tostring(data.callId))
        else
            localCallMeta[data.callId] = nil
            cleanupAICall(data.callId)
        end
    end

    TriggerEvent('chat:addMessage', { args = { '^2Tow', 'A call has been removed.' } })
end)

-- NUI callbacks
RegisterNUICallback('acceptCall', function(data, cb)
    local callIdToAccept = data and data.callId or lastShownCallId
    TriggerServerEvent('tow:acceptCall', callIdToAccept)
    SendNUIMessage({ action = 'hideCall', callId = callIdToAccept })
    SetNuiFocus(false, false)
    nuiOpen = false
    lastShownCallId = nil
    Citizen.SetTimeout(100, function()
        SendNUIMessage({ action = 'hideCall', callId = callIdToAccept })
        SetNuiFocus(false, false)
        nuiOpen = false
        lastShownCallId = nil
    end)
    cb('ok')
end)

RegisterNUICallback('declineCall', function(data, cb)
    cb('ok')

    -- hide the NUI
    SendNUIMessage({ action = 'hideCall' })
    SetNuiFocus(false, false)
    nuiOpen = false

    -- prefer explicit id from NUI, fallback to lastShownCallId
    local cid = (data and data.callId) or lastShownCallId

    -- remove client-side meta and visuals for AI calls (and any blip)
    if cid then
        -- clear stored meta so age/created info doesn't remain
        localCallMeta[cid] = nil

        -- if this was our assigned route/blip, clear it
        if currentAssignedCallId and cid == currentAssignedCallId then
            removeCurrentCallBlip()
        end

        -- cleanup any AI scene visuals (blips, peds, vehicles)
        cleanupAICall(cid)
    end
end)


-- NUI callback when dialog finishes (not strictly required, but available)
RegisterNUICallback('dialogComplete', function(data, cb)
    -- data.callId optional
    cb('ok')
end)

-- Menu open (server-validated)
RegisterNetEvent('tow:openMenu')
AddEventHandler('tow:openMenu', function(allowed)
    dbg('tow:openMenu received - allowed=%s', tostring(allowed))
    if not allowed then
        TriggerEvent('chat:addMessage', { args = { '^1Tow', 'You must be on the tow job to open the menu.' } })
        return
    end

    local options = {
        {
            title = "View Active Calls",
            description = "Open the calls list from dispatch",
            icon = "list",
            onSelect = function() TriggerServerEvent('tow:requestCalls') end
        },
        {
            title = "Accept Nearest Call (Quick)",
            description = "Request calls then accept via list",
            icon = "check",
            onSelect = function()
                TriggerServerEvent('tow:requestCalls')
                TriggerEvent('chat:addMessage', { args = {'^2Tow', 'Requested active calls — select one from the list to accept.'} })
            end
        },
        {
            title = "Spawn Tow Truck",
            description = "Spawn a tow truck near you",
            icon = "truck",
            onSelect = function() ExecuteCommand('spawntow') end
        },
        {
            title = "Cones",
            description = "Place or remove cones",
            icon = "traffic-cone",
            event = 'tow:openConesSubmenu'
        },
        {
            title = "Traffic Controls",
            description = "Change local traffic behaviour (normal / slow / stopped)",
            icon = "car-side",
            event = 'tow:openTrafficSubmenu'
        },
        {
            title = "Blocking Vehicle",
            description = "Spawn / remove a blocking vehicle to secure scene",
            icon = "box",
            options = {
                {
                    title = "Spawn Blocking Vehicle",
                    description = "Spawn immobile blocking vehicle ahead of you",
                    onSelect = function()
                        spawnBlockingVehicle()
                        TriggerEvent('chat:addMessage', { args = {'^2Tow', 'Blocking vehicle spawned.'} })
                    end
                },
                {
                    title = "Remove Blocking Vehicle",
                    description = "Remove any spawned blocking vehicle",
                    onSelect = function()
                        removeBlockingVehicle()
                        TriggerEvent('chat:addMessage', { args = {'^2Tow', 'Blocking vehicle removed.'} })
                    end
                },
                { title = "Back", menu = nil }
            }
        },
        {
            title = "Impound Nearest Vehicle",
            description = "Impound a nearby vehicle (tow job only)",
            icon = "anchor",
            onSelect = function()
                local ped = PlayerPedId()
                local veh = GetVehiclePedIsIn(ped, true)
                if veh == 0 then
                    local pos = GetEntityCoords(ped)
                    local fwd = GetEntityForwardVector(ped)
                    local target = pos + fwd * 6.0
                    local ray = StartShapeTestCapsule(pos.x, pos.y, pos.z, target.x, target.y, target.z, 3.0, 10, ped, 7)
                    local _, hit, endCoords, surfaceNormal, entityHit = GetShapeTestResult(ray)
                    if hit == 1 and DoesEntityExist(entityHit) and IsEntityAVehicle(entityHit) then veh = entityHit end
                end
                if not veh or veh == 0 then
                    TriggerEvent('chat:addMessage', { args = { '^1Tow', 'No nearby vehicle found to impound.' } })
                    return
                end
                local plate = GetVehicleNumberPlateText(veh)
                local netId = NetworkGetNetworkIdFromEntity(veh)
                TriggerServerEvent('tow:requestImpound', plate, netId)
                TriggerEvent('chat:addMessage', { args = { '^2Tow', 'Impound requested for plate: ' .. tostring(plate) } })
            end
        },
        {
            title = "Toggle Dispatch Popups",
            description = "Toggle showing incoming dispatch popups",
            icon = "bell",
            onSelect = function()
                popupsEnabled = not popupsEnabled
                TriggerEvent('chat:addMessage', { args = { '^2Tow', 'Dispatch popups: ' .. (popupsEnabled and 'ENABLED' or 'DISABLED') } })
                if not popupsEnabled and nuiOpen then
                    SendNUIMessage({ action = 'hideCall' })
                    SetNuiFocus(false, false)
                    nuiOpen = false
                    lastShownCallId = nil
                end
            end
        },
        {
            title = "Close",
            description = "Close this menu",
            icon = "times",
            onSelect = function() end
        }
    }

    lib.registerContext({
        id = 'tow_cones_submenu',
        title = 'Cones',
        options = {
            { title = 'Place 1 Cone', onSelect = function() placeCones(1); TriggerEvent('chat:addMessage',{args={'^2Tow','Placed 1 cone.'}}) end },
            { title = 'Place 3 Cones', onSelect = function() placeCones(3); TriggerEvent('chat:addMessage',{args={'^2Tow','Placed 3 cones.'}}) end },
            { title = 'Place 5 Cones', onSelect = function() placeCones(5); TriggerEvent('chat:addMessage',{args={'^2Tow','Placed 5 cones.'}}) end },
            { title = 'Remove All Cones', onSelect = function() removeCones(); TriggerEvent('chat:addMessage',{args={'^2Tow','Removed all cones.'}}) end },
            { title = 'Back', menu = 'tow_main_menu' }
        }
    })

    lib.registerContext({
        id = 'tow_traffic_submenu',
        title = 'Traffic Controls',
        options = {
            { title = 'Normal Traffic', description = 'Restore normal traffic density', onSelect = function() trafficMode = 'normal'; stopTrafficThread(); startTrafficThread(); TriggerEvent('chat:addMessage', { args = {'^2Tow','Traffic set to NORMAL.'} }) end },
            { title = 'Slow Traffic', description = 'Reduce vehicle density', onSelect = function() trafficMode = 'slow'; stopTrafficThread(); startTrafficThread(); TriggerEvent('chat:addMessage', { args = {'^2Tow','Traffic set to SLOW.'} }) end },
            { title = 'Stop Traffic', description = 'Nearly stop vehicles', onSelect = function() trafficMode = 'stopped'; stopTrafficThread(); startTrafficThread(); TriggerEvent('chat:addMessage', { args = {'^2Tow','Traffic set to STOPPED.'} }) end },
            { title = 'Back', menu = 'tow_main_menu' }
        }
    })

    lib.registerContext({
        id = 'tow_main_menu',
        title = 'Tow Menu',
        options = options
    })

    lib.showContext('tow_main_menu')
end)

-- One-time registrations for sub-menu events (avoid registering repeatedly inside tow:openMenu)
RegisterNetEvent('tow:openConesSubmenu')
AddEventHandler('tow:openConesSubmenu', function() lib.showContext('tow_cones_submenu') end)

RegisterNetEvent('tow:openTrafficSubmenu')
AddEventHandler('tow:openTrafficSubmenu', function() lib.showContext('tow_traffic_submenu') end)

-- Clean up on resource stop
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then
        SendNUIMessage({ action = 'hideCall' })
        SendNUIMessage({ action = 'hideDialog' })
        SetNuiFocus(false, false)
        nuiOpen = false
        lastShownCallId = nil
        removeCurrentCallBlip()
        removeCones()
        removeBlockingVehicle()
        trafficMode = 'normal'
        stopTrafficThread()
        for id, _ in pairs(spawnedAI) do cleanupAICall(id) end
    end
end)

-- Interaction thread: show "Press E" when near AI ped and play dialog on E press (sends dialog to NUI)
Citizen.CreateThread(function()
    while true do
        local sleep = 500
        local playerPed = PlayerPedId()
        local pcoords = GetEntityCoords(playerPed)
        local foundNear = false

        for callId, entry in pairs(spawnedAI) do
            if entry and entry.peds and #entry.peds > 0 then
                for _, aiPed in ipairs(entry.peds) do
                    if DoesEntityExist(aiPed) then
                        local aiCoords = GetEntityCoords(aiPed)
                        local dist = Vdist(pcoords.x, pcoords.y, pcoords.z, aiCoords.x, aiCoords.y, aiCoords.z)
                        if dist < 3.0 then
                            foundNear = true
                            sleep = 0
                            if not entry.dialogShown then
                                ShowHelpNotification("Press ~INPUT_CONTEXT~ to speak")
                            end
                            if not nuiOpen and not IsPauseMenuActive() and IsControlJustPressed(0, 38) then -- 38 = E
                                dbg('interaction: E pressed near callId=%s (dist=%.2f)', tostring(callId), dist)
                                if entry.dialogShown then
                                    -- brief toast to show they've already spoken
                                    sendSmallToast("They've already told you everything.")
                                else
                                    entry.dialogShown = true
                                    -- send dialog lines to NUI (UI will play them sequentially)
                                    sendDialogToNui(callId, (entry.callerName or 'Driver'), entry.dialogLines or {})
                                end
                            end
                        end
                    end
                end
            end
        end

        if not foundNear then
            Citizen.Wait(sleep)
        else
            Citizen.Wait(0)
        end
    end
end)

dbg('client.lua loaded')
