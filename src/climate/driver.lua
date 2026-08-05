-- openhac4 Home Assistant Climate
-- Copyright (c) 2026 cajunflavoredbob. Licensed under the MIT License.
--
-- Maps a Home Assistant climate entity onto a Control4 thermostatV2 proxy.
-- Protocol (snap-one docs-driverworks-proxyprotocol):
--   RX  SET_MODE_HVAC {MODE}, SET_MODE_FAN {MODE},
--       SET_SETPOINT_HEAT/COOL/SINGLE {CELSIUS|FAHRENHEIT}, INC/DEC_SETPOINT_*
--   TX  TEMPERATURE_CHANGED, HVAC_MODE_CHANGED, HVAC_STATE_CHANGED,
--       FAN_MODE_CHANGED, HEAT/COOL/SINGLE_SETPOINT_CHANGED,
--       ALLOWED_HVAC_MODES_CHANGED, ALLOWED_FAN_MODES_CHANGED,
--       DYNAMIC_CAPABILITIES_CHANGED
--
-- Temperatures pass through in the HA unit system; set the Temperature Scale
-- property to match Home Assistant (Fahrenheit or Celsius).

Child = require ('openhac4.child')

do -- globals
	THERM_BINDING = 5001
	EVENT_MODE = 1
	EVENT_OFFLINE = 2

	gScale = 'F'
	gConfigSig = nil -- signature of the last pushed mode config; nil = resend
	gLastMode = nil
	gLastLow = nil -- last known Auto heat/cool setpoints, for the inclusive
	gLastHigh = nil -- pair HA's set_temperature requires in range mode
	gLastSingle = nil -- last single-target setpoint, baseline for INC/DEC
	gHasRange = false -- does the entity report target_temp_low/high? An HA
	                  -- 'auto' entity with a single target must never be sent
	                  -- the range payload, which such integrations reject
	gStep = 1 -- setpoint step from target_temp_step, for INC/DEC
	gPresetModes = {} -- for the Set Preset Mode picker
	gSwingModes = {}  -- for the Set Swing Mode picker
end

-- HA hvac_mode <-> C4 mode string
local HA_TO_C4_MODE = {
	off = 'Off', heat = 'Heat', cool = 'Cool',
	heat_cool = 'Auto', auto = 'Auto', fan_only = 'Fan Only', dry = 'Dry',
}
local C4_TO_HA_MODE = {
	Off = 'off', Heat = 'heat', Cool = 'cool',
	['Fan Only'] = 'fan_only', Dry = 'dry',
	-- Auto resolved at runtime (heat_cool preferred, else auto)
}
-- HA hvac_action <-> C4 state
local HA_TO_C4_STATE = {
	off = 'Off', heating = 'Heating', cooling = 'Cooling',
	idle = 'Idle', drying = 'Cooling', fan = 'Idle',
	preheating = 'Heating', defrosting = 'Heating',
}

local gSupportedModes = {}

local function autoHaMode ()
	-- prefer heat_cool (dual setpoint) if the entity supports it
	for _, m in ipairs (gSupportedModes) do
		if (m == 'heat_cool') then return 'heat_cool' end
	end
	return 'auto'
end

-- setpoint value from the proxy in the configured scale
local function setpointFromParams (tParams)
	if (gScale == 'C') then
		return tonumber (tParams.CELSIUS) or tonumber (tParams.VALUE)
	end
	return tonumber (tParams.FAHRENHEIT) or tonumber (tParams.VALUE)
end

local function sendConfig (state)
	local attrs = state.attributes or {}
	gSupportedModes = (type (attrs.hvac_modes) == 'table' and attrs.hvac_modes) or {}

	local c4modes = {}
	for _, m in ipairs (gSupportedModes) do
		local c4 = HA_TO_C4_MODE [m]
		if (c4) then c4modes [c4] = true end
	end
	-- fixed presentation order: pairs() iteration order changes across reloads
	-- and would reshuffle the mode picker between sessions
	local list = {}
	for _, m in ipairs ({'Off', 'Heat', 'Cool', 'Auto', 'Fan Only', 'Dry'}) do
		if (c4modes [m]) then table.insert (list, m) end
	end
	if (#list > 0) then
		C4:SendToProxy (THERM_BINDING, 'ALLOWED_HVAC_MODES_CHANGED', {MODES = table.concat (list, ',')}, 'NOTIFY')
	end

	local fanModes = attrs.fan_modes
	if (type (fanModes) == 'table' and #fanModes > 0) then
		C4:SendToProxy (THERM_BINDING, 'ALLOWED_FAN_MODES_CHANGED', {MODES = table.concat (fanModes, ',')}, 'NOTIFY')
	end

	C4:SendToProxy (THERM_BINDING, 'SCALE_CHANGED', {SCALE = gScale}, 'NOTIFY')
end

-- Config signature: resend whenever the entity's mode lists change. A degraded
-- first push (HA startup snapshot with no hvac_modes yet) must not latch an
-- empty mode picker for the whole session; when the real attributes arrive the
-- signature differs and the config goes out again.
local function configSig (attrs)
	-- prefixed so {hvac_modes only} and {fan_modes only} with the same list
	-- cannot collide into the same signature
	local parts = {gScale}
	if (type (attrs.hvac_modes) == 'table') then
		parts [#parts + 1] = 'h:' .. table.concat (attrs.hvac_modes, ',')
	end
	if (type (attrs.fan_modes) == 'table') then
		parts [#parts + 1] = 'f:' .. table.concat (attrs.fan_modes, ',')
	end
	return table.concat (parts, '|')
end

local function reflect (state)
	local attrs = state.attributes or {}

	-- resend config on the first push and whenever the mode lists genuinely
	-- change. A degraded push with hvac_modes absent (HA startup snapshot)
	-- must neither latch an empty picker nor wipe a good gSupportedModes, so
	-- it only counts when the attribute is actually present.
	local sig = configSig (attrs)
	if (gConfigSig == nil or
			(type (attrs.hvac_modes) == 'table' and sig ~= gConfigSig)) then
		sendConfig (state)
		gConfigSig = sig
	end

	-- current temperature
	local cur = attrs.current_temperature
	if (cur ~= nil) then
		C4:SendToProxy (THERM_BINDING, 'TEMPERATURE_CHANGED', {TEMPERATURE = tostring (cur), SCALE = gScale}, 'NOTIFY')
		UpdateProperty ('Current Temperature', tostring (cur) .. ' ' .. gScale)
	end

	-- hvac mode
	local c4mode = HA_TO_C4_MODE [state.state]
	if (c4mode) then
		C4:SendToProxy (THERM_BINDING, 'HVAC_MODE_CHANGED', {MODE = c4mode}, 'NOTIFY')
		C4:SetVariable ('HVAC_MODE', c4mode)
		UpdateProperty ('HVAC Mode', c4mode)
		if (gLastMode ~= nil and gLastMode ~= c4mode) then
			C4:FireEventByID (EVENT_MODE)
		end
		gLastMode = c4mode
	end

	-- hvac action / running state
	local action = attrs.hvac_action
	if (action and HA_TO_C4_STATE [action]) then
		C4:SendToProxy (THERM_BINDING, 'HVAC_STATE_CHANGED', {STATE = HA_TO_C4_STATE [action]}, 'NOTIFY')
	end

	-- fan mode feedback: the proxy's fan selector is feedback-driven and only
	-- updates on FAN_MODE_CHANGED, so without this it never confirms a change
	-- from either side (a C4 tap or an HA-side switch)
	local fanMode = attrs.fan_mode
	if (type (fanMode) == 'string' and fanMode ~= '') then
		C4:SendToProxy (THERM_BINDING, 'FAN_MODE_CHANGED', {MODE = fanMode}, 'NOTIFY')
	end

	-- humidity display (thermostatV2 shows it when the entity reports it)
	local hum = attrs.current_humidity
	if (hum ~= nil) then
		C4:SendToProxy (THERM_BINDING, 'HUMIDITY_CHANGED', {HUMIDITY = tostring (hum)}, 'NOTIFY')
		UpdateProperty ('Current Humidity', tostring (hum) .. ' %')
	end

	-- preset / swing option lists for the pickers (control is via the actions;
	-- the current values are also exposed as HA_PRESET_MODE / HA_SWING_MODE vars)
	if (type (attrs.preset_modes) == 'table') then gPresetModes = attrs.preset_modes end
	if (type (attrs.swing_modes) == 'table') then gSwingModes = attrs.swing_modes end

	-- setpoints: range in Auto, single otherwise. Home Assistant reports stale
	-- target_temp_low/high even in single-setpoint modes, so branch on the mode
	-- (matching the RFP side's gLastMode test), not on their mere presence.
	-- tonumber at ingestion: template/MQTT climates report these as numeric
	-- strings, and a string baseline would throw in sendHeat/sendCool's
	-- relational compare, silently dropping every Auto-mode setpoint command
	local low = tonumber (attrs.target_temp_low)
	local high = tonumber (attrs.target_temp_high)
	gHasRange = (low ~= nil and high ~= nil)
	gLastSingle = tonumber (attrs.temperature) or gLastSingle
	local step = tonumber (attrs.target_temp_step)
	if (step and step > 0) then gStep = step end
	if (c4mode == 'Auto' and low ~= nil and high ~= nil) then
		gLastLow, gLastHigh = low, high
		C4:SendToProxy (THERM_BINDING, 'DYNAMIC_CAPABILITIES_CHANGED',
			{HAS_SINGLE_SETPOINT = false, CAN_HEAT = true, CAN_COOL = true, CAN_AUTO = true}, 'NOTIFY')
		C4:SendToProxy (THERM_BINDING, 'HEAT_SETPOINT_CHANGED', {SETPOINT = tostring (low), SCALE = gScale}, 'NOTIFY')
		C4:SendToProxy (THERM_BINDING, 'COOL_SETPOINT_CHANGED', {SETPOINT = tostring (high), SCALE = gScale}, 'NOTIFY')
	elseif (attrs.temperature ~= nil) then
		C4:SendToProxy (THERM_BINDING, 'DYNAMIC_CAPABILITIES_CHANGED',
			{HAS_SINGLE_SETPOINT = false, CAN_HEAT = true, CAN_COOL = true, CAN_AUTO = true}, 'NOTIFY')
		-- The thermostatV2 UI shows Heat and Cool setpoint spinners, and the
		-- proxy sends SET_SETPOINT_HEAT/COOL, not SET_SETPOINT_SINGLE. A single-
		-- setpoint HA mode has one target; drive the spinner that matches the
		-- mode so the feedback lands on the visible control.
		local sp = tostring (attrs.temperature)
		if (state.state == 'cool' or state.state == 'dry') then
			C4:SendToProxy (THERM_BINDING, 'COOL_SETPOINT_CHANGED', {SETPOINT = sp, SCALE = gScale}, 'NOTIFY')
		else
			C4:SendToProxy (THERM_BINDING, 'HEAT_SETPOINT_CHANGED', {SETPOINT = sp, SCALE = gScale}, 'NOTIFY')
		end
	end
end

local function setTemperature (data)
	Child.CallService ('set_temperature', data)
end

Child.Setup {
	domain = 'climate',

	onInit = function ()
		C4:AddVariable ('HVAC_MODE', '', 'STRING', true, false)
		-- restore the configured scale; it does not default correctly across
		-- a reboot otherwise
		gScale = (Properties ['Temperature Scale'] == 'Celsius') and 'C' or 'F'
	end,

	onState = function (state)
		reflect (state)
	end,

	onOffline = function ()
		UpdateProperty ('HVAC Mode', 'Unavailable')
		C4:FireEventByID (EVENT_OFFLINE)
	end,

	onReset = function ()
		gConfigSig = nil
		gLastLow, gLastHigh = nil, nil
		-- clear everything learned from the old entity: a stale gLastMode would
		-- fire a spurious Mode Changed on the new entity's first push and
		-- misroute a setpoint command arriving before it
		gLastMode = nil
		gLastSingle = nil
		gHasRange = false
		gStep = 1
		gSupportedModes = {}
		gPresetModes = {}
		gSwingModes = {}
		-- clear per-entity displays so the previous entity's values do not
		-- linger on the new one until its first push
		UpdateProperty ('Current Temperature', '')
		UpdateProperty ('Current Humidity', '')
		UpdateProperty ('HVAC Mode', '')
	end,
}

OPC.Temperature_Scale = function (value)
	gScale = (value == 'Celsius') and 'C' or 'F'
	gConfigSig = nil -- resend scale + config on next state
	Child.Register ()
end

do -- proxy commands
	RFP.SET_MODE_HVAC = function (idBinding, strCommand, tParams)
		Child.TraceParams ('RFP SET_MODE_HVAC', tParams)
		local c4mode = tParams.MODE
		local haMode = C4_TO_HA_MODE [c4mode]
		if (c4mode == 'Auto') then haMode = autoHaMode () end
		if (haMode) then
			Child.CallService ('set_hvac_mode', {hvac_mode = haMode})
		end
	end

	RFP.SET_MODE_FAN = function (idBinding, strCommand, tParams)
		Child.TraceParams ('RFP SET_MODE_FAN', tParams)
		if (tParams.MODE) then
			Child.CallService ('set_fan_mode', {fan_mode = tParams.MODE})
		end
	end

	-- Route a heat/cool setpoint. The range payload is only valid when the
	-- entity actually reports a low/high pair: an HA 'auto' entity with a
	-- single target rejects it, which would make setpoints uncontrollable
	-- from Control4 while displaying fine.
	-- Both senders refresh the optimistic baselines with the value sent, so a
	-- nudge arriving inside the echo window computes from the latest command
	-- rather than yanking the setpoint back to a pre-command value. HA's next
	-- real push overwrites them with the truth.
	local function sendHeat (v)
		if (gLastMode == 'Auto' and gHasRange) then
			-- HA requires target_temp_low AND target_temp_high together; keep
			-- the pair ordered so a low pushed past the high is not rejected
			local high = gLastHigh or v
			if (high < v) then high = v end
			gLastLow, gLastHigh = v, high
			setTemperature ({target_temp_low = v, target_temp_high = high})
		else
			gLastSingle = v
			setTemperature ({temperature = v})
		end
	end

	local function sendCool (v)
		if (gLastMode == 'Auto' and gHasRange) then
			local low = gLastLow or v
			if (low > v) then low = v end
			gLastLow, gLastHigh = low, v
			setTemperature ({target_temp_low = low, target_temp_high = v})
		else
			gLastSingle = v
			setTemperature ({temperature = v})
		end
	end

	RFP.SET_SETPOINT_HEAT = function (idBinding, strCommand, tParams)
		Child.TraceParams ('RFP SET_SETPOINT_HEAT', tParams)
		local v = setpointFromParams (tParams)
		if (v ~= nil) then sendHeat (v) end
	end

	RFP.SET_SETPOINT_COOL = function (idBinding, strCommand, tParams)
		Child.TraceParams ('RFP SET_SETPOINT_COOL', tParams)
		local v = setpointFromParams (tParams)
		if (v ~= nil) then sendCool (v) end
	end

	RFP.SET_SETPOINT_SINGLE = function (idBinding, strCommand, tParams)
		Child.TraceParams ('RFP SET_SETPOINT_SINGLE', tParams)
		local v = setpointFromParams (tParams)
		if (v ~= nil) then
			gLastSingle = v -- keep the nudge baseline current (see sendHeat)
			setTemperature ({temperature = v})
		end
	end

	-- Nudge commands. Baseline is the last setpoint Home Assistant reported;
	-- with no baseline yet (no state since load) the nudge is dropped rather
	-- than guessed.
	local function nudge (which, dir)
		local d = dir * gStep
		-- bump the baseline optimistically so rapid taps accumulate instead of
		-- all computing from the same pre-echo value; HA's next state push
		-- overwrites it with the truth either way
		if (gLastMode == 'Auto' and gHasRange) then
			if (which == 'heat' and gLastLow ~= nil) then
				gLastLow = gLastLow + d
				sendHeat (gLastLow)
			elseif (which == 'cool' and gLastHigh ~= nil) then
				gLastHigh = gLastHigh + d
				sendCool (gLastHigh)
			end
		elseif (gLastSingle ~= nil) then
			gLastSingle = gLastSingle + d
			setTemperature ({temperature = gLastSingle})
		end
	end

	RFP.INC_SETPOINT_HEAT = function () nudge ('heat', 1) end
	RFP.DEC_SETPOINT_HEAT = function () nudge ('heat', -1) end
	RFP.INC_SETPOINT_COOL = function () nudge ('cool', 1) end
	RFP.DEC_SETPOINT_COOL = function () nudge ('cool', -1) end
	RFP.INC_SETPOINT_SINGLE = function () nudge ('single', 1) end
	RFP.DEC_SETPOINT_SINGLE = function () nudge ('single', -1) end

	EC.Set_HVAC_Mode = function (tParams)
		if (tParams and tParams.Mode) then
			RFP.SET_MODE_HVAC (nil, nil, {MODE = tParams.Mode})
		end
	end

	EC.SetPreset = function (tParams)
		local p = tParams and tParams.Preset
		if (p and tostring (p) ~= '') then
			Child.CallService ('set_preset_mode', {preset_mode = tostring (p)})
		end
	end

	EC.SetSwing = function (tParams)
		local s = tParams and tParams.Swing
		if (s and tostring (s) ~= '') then
			Child.CallService ('set_swing_mode', {swing_mode = tostring (s)})
		end
	end
end

-- CUSTOM_SELECT populators for the Set Preset / Set Swing actions
function GetPresetModes () return gPresetModes end
function GetSwingModes () return gSwingModes end
