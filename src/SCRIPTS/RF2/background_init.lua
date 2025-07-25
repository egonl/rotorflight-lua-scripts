local initializationDone = false
local crsfCustomTelemetryEnabled = false

local settings = rf2.loadSettings()
local autoSetName = settings.autoSetName == 1 or false
local useAdjustmentTeller = settings.useAdjustmentTeller == 1 or false

local pilotConfigSetMagic = -765
local function pilotConfigSet()
    model.setGlobalVariable(7, 8, pilotConfigSetMagic)
end

local function pilotConfigReset()
    model.setGlobalVariable(7, 8, 0)
end

local function pilotConfigHasBeenSet()
    return model.getGlobalVariable(7, 8) == pilotConfigSetMagic
end

local function setTimer(index, paramValue)
    model.resetTimer(index)
    local timer = model.getTimer(index)
    timer.value = paramValue
    model.setTimer(index, timer)
end

local function setParam(paramType, paramValue)
    --rf2.print(paramType .. ": " .. paramValue)
    if paramType == "NONE" then return end
    if paramType == "TIMER1" then
        setTimer(0, paramValue)
    elseif paramType == "TIMER2" then
        setTimer(1, paramValue)
    elseif paramType == "TIMER3" then
        setTimer(2, paramValue)
    elseif paramType == "GV1" then
        model.setGlobalVariable(0, 0, paramValue)
    elseif paramType == "GV2" then
        model.setGlobalVariable(1, 0, paramValue)
    elseif paramType == "GV3" then
        model.setGlobalVariable(2, 0, paramValue)
    elseif paramType == "GV4" then
        model.setGlobalVariable(3, 0, paramValue)
    elseif paramType == "GV5" then
        model.setGlobalVariable(4, 0, paramValue)
    elseif paramType == "GV6" then
        model.setGlobalVariable(5, 0, paramValue)
    elseif paramType == "GV7" then
        model.setGlobalVariable(6, 0, paramValue)
    elseif paramType == "GV8" then
        model.setGlobalVariable(7, 0, paramValue)
    elseif paramType == "GV9" then
        model.setGlobalVariable(8, 0, paramValue)
    end
end

local function setModelName(name)
    if not name then return end
    --local newName = ">" .. ((name and #name > 0) and name or "Rotorflight")
    local newName = name

    local info = model.getInfo()
    if info.name == newName then return end
    settings.previousModelName = info.name
    rf2.saveSettings(settings)
    info.name = newName
    model.setInfo(info)
end

local function resetModelName()
    if not settings.previousModelName then return end
    local info = model.getInfo()
    info.name = settings.previousModelName
    model.setInfo(info)
    settings.previousModelName = nil
    rf2.saveSettings(settings)
end

local function onPilotConfigReceived(_, config)
    if rf2.apiVersion >= 12.09 then
        -- RF 2.0 to 2.2 (MSP API 12.06 to 12.08) used settings.autoSetName (a global radio setting) to set the model name.
        -- RF 2.3+ (MSP API 12.09+) uses a setting on the model to set the model name.
        autoSetName = rf2.getBit(config.model_flags.value, config.model_flags.MODEL_SET_NAME) == 1 or false
        --rf2.print("MODEL_SET_NAME: " .. tostring(autoSetName))
    end

    local paramValue = config.model_param1_value.value
    local paramType = config.model_param1_type.table[config.model_param1_type.value]
    setParam(paramType, paramValue)

    paramValue = config.model_param2_value.value
    paramType = config.model_param2_type.table[config.model_param2_type.value]
    setParam(paramType, paramValue)

    paramValue = config.model_param3_value.value
    paramType = config.model_param3_type.table[config.model_param3_type.value]
    setParam(paramType, paramValue)

    pilotConfigSet()
end

local sensorsDiscoveredTimeout = 0
local customTelemetryTask
local function waitForCustomSensorsDiscovery()
    -- OpenTX and EdgeTX reference sensors by their ID. In order to always have the
    -- same ID when using custom CRSF/ELRS telemetry, follow this procedure:
    -- 1. Power off the model
    -- 2. "Delete all" sensors from the model
    -- 3. Select "Discover new"
    -- 4. Power on the model
    -- 5. Wait for the sensors to be discovered.
    -- MSP calls during this procedure can interfere with discovering custom sensors.
    -- waitForCustomSensorsDiscovery facilitates waiting for the sensors to be discovered
    -- before continuing with MSP calls.

    if not crossfireTelemetryPush() or rf2.runningInSimulator then
        -- Model does not use CRSF/ELRS
        return 0
    end

    local sensorsDiscovered
    if getFieldInfo ~= nil then
        -- EdgeTX
        sensorsDiscovered = getFieldInfo("TPWR") ~= nil
    else
        -- OpenTX
        sensorsDiscovered = getValue("TPWR") ~= nil
    end

    if not sensorsDiscovered then
        -- Wait 10 secs for telemetry script to discover sensors before continuing with MSP calls,
        -- since MSP can interfere with discovering custom sensors
        sensorsDiscoveredTimeout = rf2.clock() + 10
    end

    if sensorsDiscoveredTimeout ~= 0 then
        if rf2.clock() < sensorsDiscoveredTimeout then
            --rf2.print("Waiting for sensors to be discovered...")
            customTelemetryTask = customTelemetryTask or rf2.executeScript("rf2tlm")
            customTelemetryTask.run()
            return 1 -- wait for sensors to be discovered
        end
        sensorsDiscoveredTimeout = 0
        customTelemetryTask = nil
        collectgarbage()
        return 2 -- sensors might just have been discovered
    end

    --rf2.print("Sensors already discovered")
    return 0
end

local queueInitialized = false
local function initializeQueue()
    --rf2.print("Initializing MSP queue")

    rf2.mspQueue.maxRetries = -1       -- retry indefinitely

    rf2.useApi("mspApiVersion").getApiVersion(
        function(_, version)
            rf2.apiVersion = version

            rf2.useApi("mspName").getModelName(function(_, name) rf2.modelName = name end)

            if rf2.apiVersion >= 12.07 then
                if not pilotConfigHasBeenSet() then
                    rf2.useApi("mspPilotConfig").read(onPilotConfigReceived)
                end

                if crossfireTelemetryPush() then
                    rf2.useApi("mspTelemetryConfig").getTelemetryConfig(
                        function(_, config)
                            crsfCustomTelemetryEnabled = config.crsf_telemetry_mode.value == 1
                        end)
                end
            end

            rf2.useApi("mspSetRtc").setRtc(
                function()
                    if autoSetName then
                        setModelName(rf2.modelName)
                    end
                    playTone(1600, 300, 0, PLAY_BACKGROUND)
                    --rf2.print("RTC set")
                    rf2.mspQueue.maxRetries = rf2.protocol.maxRetries
                    initializationDone = true
                end)
        end)
end

local function initialize(modelIsConnected)
    local sensorsDiscoveryWaitState = waitForCustomSensorsDiscovery()
    if sensorsDiscoveryWaitState == 1 then
        return false
    end

    if not modelIsConnected then
        resetModelName()
        return false
    end

    if not queueInitialized then
        initializeQueue()
        queueInitialized = true
    end

    rf2.mspQueue:processQueue()

    return initializationDone
end

local function run(modelIsConnected)
    return
    {
        isInitialized = initialize(modelIsConnected),
        crsfCustomTelemetryEnabled = crsfCustomTelemetryEnabled
    }
end

local function reset()
    rf2.mspQueue:clear()
    rf2.apiVersion = nil
end

return { run = run, reset = reset, useAdjustmentTeller = useAdjustmentTeller }
