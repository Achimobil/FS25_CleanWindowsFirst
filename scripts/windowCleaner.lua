--[[
Copyright (C) Achimobil

Important:
It is not allowed to copy in own Mods.
No changes are to be made to this script without permission from Achimobil.

Darf nicht in eigene Mods kopiert werden.
An diesem Skript dürfen ohne Genehmigung von Achimobil keine Änderungen vorgenommen werden.

No change Log because not allowed to use in other mods.
]]

print("FS25_CleanWindowsFirst: Load WindowCleaner")

WindowCleaner = {};
WindowCleaner.Debug = false;

--- Print the given Table to the log
-- @param string text parameter Text before the table
-- @param table myTable The table to print
-- @param number maxDepth depth of print, default 2
function WindowCleaner.DebugTable(text, myTable, maxDepth)
    if not WindowCleaner.Debug then return end
    if myTable == nil then
        Logging.info("WindowCleanerDebug: " .. text .. " is nil");
    else
        Logging.info("WindowCleanerDebug: " .. text)
        DebugUtil.printTableRecursively(myTable,"_",0, maxDepth or 2);
    end
end

---Print the text to the log. Example: WindowCleaner.DebugText("Alter: %s", age)
-- @param string text the text to print formated
-- @param any ... format parameter
function WindowCleaner.DebugText(text, ...)
    if not WindowCleaner.Debug then return end
    Logging.info("WindowCleanerDebug: " .. string.format(text, ...));
end

function WindowCleaner:cleanVehicle(superFunc, amount)

    local spec = self.spec_washable
    for i=1, #spec.washableNodes do
        local nodeData = spec.washableNodes[i]

        local nodeAmount = amount * (nodeData.cleaningMultiplier or 1)
        local nodeAmountWindow = amount * (nodeData.cleaningMultiplier or 1) * 5;

        -- zuerst nur Fenster putzen
        if nodeData.dirtAmountWindows >= 0.01 then
            nodeAmount = 0;
        end

        self:setNodeDirtAmount(nodeData, nodeData.dirtAmount - nodeAmount, true, nodeData.dirtAmountWindows - nodeAmountWindow)
        if nodeAmount ~= 0 then
            self:setNodeWetness(nodeData, nodeData.wetness + nodeAmount * 5, true);
        end
    end
end

Washable.cleanVehicle = Utils.overwrittenFunction(Washable.cleanVehicle, WindowCleaner.cleanVehicle)

-- replace, weil die mit blendet auf window gehen müssen und sich das mit dem window durch den normalen dirt wieder überschreibt
function WindowCleaner:setNodeDirtAmount(superFunc, nodeData, dirtAmount, force, dirtAmountWindows)
    -- Der Wert wird beim ersten aufruf aus der normalen dirt übernommen. Erst mal nicht syncronisiert
    if nodeData.dirtAmountWindows == nil then
        nodeData.dirtAmountWindows = nodeData.dirtAmount;
    end
    if dirtAmountWindows == nil then
        dirtAmountWindows = dirtAmount;
    end

    local spec = self.spec_washable
    nodeData.dirtAmount = math.clamp(dirtAmount, 0, 1)
    nodeData.dirtAmountWindows = math.clamp(dirtAmountWindows, 0, 1)

--     WindowCleaner.DebugText("setNodeDirtAmount(%s, %s)", nodeData.dirtAmount, nodeData.dirtAmountWindows)

    local diff = nodeData.dirtAmountSent - nodeData.dirtAmount - nodeData.dirtAmountWindows
    if math.abs(diff) > Washable.SEND_THRESHOLD or force or (nodeData.dirtAmount == 0 and nodeData.dirtAmountSent ~= 0) then
        for node, _ in pairs(nodeData.nodes) do
            local materialId = getMaterial(node, 0);
            local blendet = getMaterialIsAlphaBlended(materialId);
            if blendet == true then
                setShaderParameter(node, "scratches_dirt_snow_wetness", nil, nodeData.dirtAmountWindows, nil, nil, false);
            else
                setShaderParameter(node, "scratches_dirt_snow_wetness", nil, nodeData.dirtAmount, nil, nil, false);
            end
        end

        for node, _ in pairs(nodeData.mudNodes) do
            g_animationManager:setPrevShaderParameter(node, "mudAmount", nodeData.dirtAmount, 0, 0, 0, false, "prevMudAmount")
        end

        if self.isServer then
            self:raiseDirtyFlags(spec.dirtyFlag)
            nodeData.dirtAmountSent = nodeData.dirtAmount + nodeData.dirtAmountWindows
        end
    end
end

Washable.setNodeDirtAmount = Utils.overwrittenFunction(Washable.setNodeDirtAmount, WindowCleaner.setNodeDirtAmount)


--- Überschreiben um zusätzlichen clean parameter zu setzen
function WindowCleaner:onUpdateTick(superFunc, dt, isActive, isActiveForInput, isSelected)
    if self.isServer then
        local spec = self.spec_washable
        spec.lastDirtMultiplier = self:getDirtMultiplier() * Washable.getIntervalMultiplier() * Platform.gameplay.dirtDurationScale

        local allowsWashingByRain = self:getAllowsWashingByType(Washable.WASHTYPE_RAIN)
        local rainScale, timeSinceLastRain, temperature = 0, 0, 0
        if allowsWashingByRain then
            local weather = g_currentMission.environment.weather
            rainScale = weather:getRainFallScale()
            timeSinceLastRain = weather:getTimeSinceLastRain()
            temperature = weather:getCurrentTemperature()
        end

        for i=1, #spec.washableNodes do
            local nodeData = spec.washableNodes[i]
            local changeDirt, changeWetness = nodeData.updateFunc(self, nodeData, dt, allowsWashingByRain, rainScale, timeSinceLastRain, temperature)
            if changeDirt ~= 0 then
                self:setNodeDirtAmount(nodeData, nodeData.dirtAmount + changeDirt, false, nodeData.dirtAmountWindows + changeDirt)
            end
            if changeWetness ~= 0 then
                self:setNodeWetness(nodeData, nodeData.wetness + changeWetness)
            end
        end
    end
end

Washable.onUpdateTick = Utils.overwrittenFunction(Washable.onUpdateTick, WindowCleaner.onUpdateTick)


---
function WindowCleaner:readWashableNodeData(superFunc, streamId, connection)
    local spec = self.spec_washable
    for i=1, #spec.washableNodes do
        local nodeData = spec.washableNodes[i]
        local dirtAmount = streamReadUIntN(streamId, Washable.SEND_NUM_BITS) / Washable.SEND_MAX_VALUE
        local dirtAmountWindows = streamReadUIntN(streamId, Washable.SEND_NUM_BITS) / Washable.SEND_MAX_VALUE
        self:setNodeDirtAmount(nodeData, dirtAmount, true, dirtAmountWindows)

        local wetness = streamReadUIntN(streamId, Washable.SEND_NUM_BITS_WETNESS) / Washable.SEND_MAX_VALUE_WETNESS
        self:setNodeWetness(nodeData, wetness, true)

        if streamReadBool(streamId) then
            local r = streamReadUIntN(streamId, Washable.SEND_NUM_BITS) / Washable.SEND_MAX_VALUE
            local g = streamReadUIntN(streamId, Washable.SEND_NUM_BITS) / Washable.SEND_MAX_VALUE
            local b = streamReadUIntN(streamId, Washable.SEND_NUM_BITS) / Washable.SEND_MAX_VALUE

            self:setNodeDirtColor(nodeData, r, g, b, true)
        end
    end
end

Washable.readWashableNodeData = Utils.overwrittenFunction(Washable.readWashableNodeData, WindowCleaner.readWashableNodeData)

---
function WindowCleaner:writeWashableNodeData(superFunc, streamId, connection)
    local spec = self.spec_washable
    for i=1, #spec.washableNodes do
        local nodeData = spec.washableNodes[i]
        if nodeData.dirtAmountWindows == nil then nodeData.dirtAmountWindows = nodeData.dirtAmount end;
        streamWriteUIntN(streamId, math.floor(nodeData.dirtAmount * Washable.SEND_MAX_VALUE + 0.5), Washable.SEND_NUM_BITS)
        streamWriteUIntN(streamId, math.floor(nodeData.dirtAmountWindows * Washable.SEND_MAX_VALUE + 0.5), Washable.SEND_NUM_BITS)
        streamWriteUIntN(streamId, math.floor(nodeData.wetness * Washable.SEND_MAX_VALUE_WETNESS + 0.5), Washable.SEND_NUM_BITS_WETNESS)

        streamWriteBool(streamId, nodeData.colorChanged)
        if nodeData.colorChanged then
            streamWriteUIntN(streamId, math.floor(nodeData.color[1] * Washable.SEND_MAX_VALUE + 0.5), Washable.SEND_NUM_BITS)
            streamWriteUIntN(streamId, math.floor(nodeData.color[2] * Washable.SEND_MAX_VALUE + 0.5), Washable.SEND_NUM_BITS)
            streamWriteUIntN(streamId, math.floor(nodeData.color[3] * Washable.SEND_MAX_VALUE + 0.5), Washable.SEND_NUM_BITS)
            nodeData.colorChanged = false
        end
    end
end

Washable.writeWashableNodeData = Utils.overwrittenFunction(Washable.writeWashableNodeData, WindowCleaner.writeWashableNodeData)