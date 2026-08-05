-- openhac4 Home Assistant Fan
-- Copyright (c) 2026 cajunflavoredbob. Licensed under the MIT License.
--
-- Maps a Home Assistant fan entity onto a Control4 fan proxy. Control4 fans
-- use discrete speeds 0-N; this driver presents 4 speeds and maps them to HA
-- percentage (25/50/75/100). Speed 0 is off.
-- Protocol: RX ON/OFF/TOGGLE/SET_SPEED/CYCLE_SPEED_UP/DOWN; TX CURRENT_SPEED.

Child = require ('openhac4.child')

do -- globals
	FAN_BINDING = 5001
	SPEED_COUNT = 4
	EVENT_ON = 1
	EVENT_OFF = 2
	EVENT_OFFLINE = 3

	gSpeed = nil -- last C4 speed (0-4)
	gLastPct = nil -- last HA percentage, for step-accurate cycling
	gStep = 100 / SPEED_COUNT -- HA percentage_step; refined on state
	gHasPercentage = true -- does the HA fan support set_percentage? refined on state
	gPendingSpeed = nil -- C4 speed of the last command, so the reflected state
	gPendingPct = nil   -- displays the speed the user tapped (see onState)
	gFanPresets = {} -- for the Set Preset Mode picker
end

local function pctToSpeed (pct)
	if (not pct or pct <= 0) then return 0 end
	local s = math.floor ((pct / 100 * SPEED_COUNT) + 0.5)
	if (s < 1) then s = 1 end
	if (s > SPEED_COUNT) then s = SPEED_COUNT end
	return s
end

-- Snap a target percentage onto the entity's own step grid. HA integrations
-- quantize set_percentage to their speed count (a 3-speed fan snaps 75 up to
-- 100), so sending unsnapped values makes the reflected state land on a
-- different C4 speed than the one tapped. Snapping here keeps the value HA
-- reports equal to the value sent.
local function snapPct (pct)
	local i = math.floor ((pct / gStep) + 0.5)
	if (i < 1) then i = 1 end
	local maxI = math.floor ((100 / gStep) + 0.5)
	if (i > maxI) then i = maxI end
	return i * gStep
end

local function speedToPct (speed)
	return snapPct (speed / SPEED_COUNT * 100)
end

-- Drive the HA fan to a C4 speed. On a fan without set_percentage support
-- (on/off only), any nonzero speed degrades to a plain turn_on.
local function setSpeed (s)
	if (s <= 0) then
		gPendingSpeed, gPendingPct = nil, nil
		Child.CallService ('turn_off')
	elseif (gHasPercentage) then
		local pct = speedToPct (s)
		gPendingSpeed, gPendingPct = s, pct
		Child.CallService ('set_percentage', {percentage = pct})
	else
		Child.CallService ('turn_on')
	end
end

Child.Setup {
	domain = 'fan',

	onInit = function ()
		C4:AddVariable ('SPEED', '0', 'NUMBER', true, false)
	end,

	onState = function (state)
		-- 'unknown' is a transient (HA restart, integration blip), not a real
		-- off: hold the last state so no programming fires on it
		if (state.state == 'unknown') then
			UpdateProperty ('Current Speed', 'Unknown')
			return
		end
		local on = (state.state == 'on')
		local attrs = state.attributes or {}
		local pct = attrs.percentage
		-- HA fan SET_SPEED feature is bit 0 of supported_features; fall back to
		-- the presence of a percentage attribute
		local sf = tonumber (attrs.supported_features) or 0
		gHasPercentage = (sf % 2 == 1) or (pct ~= nil)
		local step = tonumber (attrs.percentage_step)
		if (step and step > 0 and step <= 100) then gStep = step end
		if (type (attrs.preset_modes) == 'table') then gFanPresets = attrs.preset_modes end
		local speed
		if (not on) then
			speed = 0
			gLastPct = nil
			gPendingSpeed, gPendingPct = nil, nil
		elseif (tonumber (pct) and tonumber (pct) > 0) then
			local n = tonumber (pct)
			gLastPct = n
			-- reflected echo of our own command: display the speed the user
			-- tapped rather than remapping (a 4-speed UI onto a 3-speed fan has
			-- no stable inverse, so the echo is the only faithful answer)
			if (gPendingPct and math.abs (n - gPendingPct) < (gStep / 2)) then
				speed = gPendingSpeed
			else
				speed = pctToSpeed (n)
			end
			gPendingSpeed, gPendingPct = nil, nil
		elseif (gSpeed and gSpeed > 0) then
			-- on with percentage 0 or unparseable: a spin-up/spin-down
			-- transient on some integrations, not a real off. Hold the last
			-- speed so no Turned Off event fires while HA still says on; the
			-- real off arrives as state 'off' and takes the branch above.
			speed = gSpeed
		else
			speed = SPEED_COUNT -- on with no percentage: assume full
			-- this push carries no percentage to compare an echo against; a
			-- held pending would suppress a later unrelated change
			gPendingSpeed, gPendingPct = nil, nil
		end

		local first = (gSpeed == nil)
		local changed = (gSpeed ~= speed)
		local wasOn = (gSpeed ~= nil and gSpeed > 0)
		gSpeed = speed

		C4:SendToProxy (FAN_BINDING, 'CURRENT_SPEED', {SPEED = speed})
		C4:SetVariable ('SPEED', speed)
		UpdateProperty ('Current Speed', (speed == 0) and 'Off' or tostring (speed))

		if (changed and not first) then
			if (speed > 0 and not wasOn) then C4:FireEventByID (EVENT_ON)
			elseif (speed == 0 and wasOn) then C4:FireEventByID (EVENT_OFF) end
		end
	end,

	onOffline = function ()
		UpdateProperty ('Current Speed', 'Unavailable')
		C4:FireEventByID (EVENT_OFFLINE)
	end,

	onReset = function ()
		gSpeed = nil
		gLastPct = nil
		gStep = 100 / SPEED_COUNT
		gPendingSpeed, gPendingPct = nil, nil
	end,
}

do -- proxy commands
	RFP.ON = function ()
		Child.CallService ('turn_on')
	end

	RFP.OFF = function ()
		Child.CallService ('turn_off')
	end

	RFP.TOGGLE = function ()
		Child.CallService ('toggle')
	end

	RFP.SET_SPEED = function (idBinding, strCommand, tParams)
		Child.TraceParams ('RFP SET_SPEED', tParams)
		local speed = tonumber (tParams.SPEED)
		if (speed == nil) then return end
		setSpeed (speed)
	end

	-- Cycle through the fan's own steps, not the 4 C4 speeds: on a fan whose
	-- step grid is coarser than 25% the C4-speed walk re-sends values HA
	-- snaps back to the current step, so the fan never actually changes.
	local function cyclePct (dir)
		if (not gHasPercentage or gLastPct == nil) then
			-- no percentage picture: fall back to the C4-speed walk
			local s = (gSpeed or 0) + dir
			if (s > SPEED_COUNT) then s = SPEED_COUNT end
			setSpeed (s)
			return
		end
		local delta = math.max (gStep, 100 / SPEED_COUNT)
		local target = gLastPct + (dir * delta)
		if (target < (gStep / 2)) then
			setSpeed (0)
			return
		end
		local pct = snapPct (target)
		gPendingSpeed, gPendingPct = pctToSpeed (pct), pct
		Child.CallService ('set_percentage', {percentage = pct})
	end

	RFP.CYCLE_SPEED_UP = function ()
		cyclePct (1)
	end

	RFP.CYCLE_SPEED_DOWN = function ()
		cyclePct (-1)
	end

	-- state query: reply on the binding (a ReceivedFromProxy return value is
	-- discarded by Director; only SendToProxy reaches the proxy)
	RFP.GET_CURRENT_STATE = function ()
		C4:SendToProxy (FAN_BINDING, 'CURRENT_SPEED', {SPEED = gSpeed or 0})
	end
	RFP.GET_STATE = RFP.GET_CURRENT_STATE
	RFP.GET_SETUP = RFP.GET_CURRENT_STATE

	EC.Turn_On = function () Child.CallService ('turn_on') end
	EC.Turn_Off = function () Child.CallService ('turn_off') end
	EC.Toggle = function () Child.CallService ('toggle') end
	EC.Set_Speed = function (tParams)
		local s = tParams and tonumber (tParams.Speed)
		if (s ~= nil) then
			RFP.SET_SPEED (nil, nil, {SPEED = s})
		end
	end

	EC.SetPreset = function (tParams)
		local p = tParams and tParams.Preset
		if (p and tostring (p) ~= '') then
			Child.CallService ('set_preset_mode', {preset_mode = tostring (p)})
		end
	end

	EC.SetOscillation = function (tParams)
		local on = (tParams and tParams.Oscillating == 'On')
		Child.CallService ('oscillate', {oscillating = on})
	end
end

-- CUSTOM_SELECT populator for the Set Preset Mode action
function GetFanPresets () return gFanPresets end
