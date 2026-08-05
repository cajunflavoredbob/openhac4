-- openhac4 Home Assistant Vacuum
-- Copyright (c) 2026 cajunflavoredbob. Licensed under the MIT License.
--
-- Maps a Home Assistant vacuum entity onto a Control4 experience button.
-- Tapping toggles clean/dock; programming exposes the full command set.

Child = require ('openhac4.child')

-- Composer calls this to fill the Set Fan Speed picker
function GetVacuumFanSpeeds ()
	return gFanSpeeds
end

do -- globals
	UIBUTTON_BINDING = 5001
	EVENT_CLEANING = 1
	EVENT_DOCKED = 2
	EVENT_RETURNING = 3
	EVENT_PAUSED = 4
	EVENT_ERROR = 5
	EVENT_OFFLINE = 6

	gState = nil -- last HA vacuum state
	-- the entity's own fan speed names; vacuums differ wildly (low/medium/high/max
	-- versus Silent/Balanced/Turbo/Max versus Quiet/Standard/Strong), so the
	-- picker is populated from the entity rather than hardcoded
	gFanSpeeds = {}
end

local EVENT_FOR = {
	cleaning = EVENT_CLEANING,
	docked = EVENT_DOCKED,
	returning = EVENT_RETURNING,
	paused = EVENT_PAUSED,
	error = EVENT_ERROR,
}

local function reflect (state)
	local haState = state.state
	-- 'unknown' (or a state that failed to decode) is a transient, not a
	-- vacuum activity: hold the last state so no Docked/Cleaning programming
	-- fires on it or on the recovery edge, and SetVariable never gets a nil
	if (haState == nil or haState == 'unknown') then
		UpdateProperty ('Current State', 'Unknown')
		return
	end
	local attrs = state.attributes or {}
	local first = (gState == nil)
	local changed = (gState ~= haState)
	gState = haState

	-- experience button icon: Selected while actively cleaning
	local icon = (haState == 'cleaning') and 'Selected' or 'Idle'
	C4:SendToProxy (UIBUTTON_BINDING, 'ICON_CHANGED', {icon = icon, icon_description = haState})

	C4:SetVariable ('VACUUM_STATE', haState)
	UpdateProperty ('Current State', haState)

	local fan = attrs.fan_speed
	if (fan ~= nil) then
		C4:SetVariable ('FAN_SPEED', tostring (fan))
	end

	if (type (attrs.fan_speed_list) == 'table') then
		local list = {}
		for _, v in ipairs (attrs.fan_speed_list) do list [#list + 1] = tostring (v) end
		gFanSpeeds = list
	end

	local battery = attrs.battery_level
	if (battery ~= nil) then
		C4:SetVariable ('BATTERY_LEVEL', tostring (battery))
		UpdateProperty ('Battery', tostring (battery) .. '%')
	end

	if (changed and not first and EVENT_FOR [haState]) then
		C4:FireEventByID (EVENT_FOR [haState])
	end
end

Child.Setup {
	domain = 'vacuum',

	onInit = function ()
		C4:AddVariable ('VACUUM_STATE', '', 'STRING', true, false)
		C4:AddVariable ('FAN_SPEED', '', 'STRING', true, false)
		C4:AddVariable ('BATTERY_LEVEL', '', 'STRING', true, false)
	end,

	onState = function (state)
		gAvailable = true
		reflect (state)
	end,

	onOffline = function ()
		gAvailable = false
		UpdateProperty ('Current State', 'Unavailable')
		C4:FireEventByID (EVENT_OFFLINE)
	end,

	onReset = function ()
		gState = nil
		gFanSpeeds = {}
		gAvailable = nil -- new entity: let taps through until told otherwise
		-- clear the previous entity's values: a new vacuum without a
		-- battery_level would otherwise inherit the old one's forever
		C4:SetVariable ('VACUUM_STATE', '')
		C4:SetVariable ('FAN_SPEED', '')
		C4:SetVariable ('BATTERY_LEVEL', '')
		UpdateProperty ('Current State', '')
		UpdateProperty ('Battery', '')
	end,
}

do -- commands
	-- experience button tap: toggle clean/dock. Dropped while the entity is
	-- unavailable: gState is stale then, and the service call would be
	-- rejected with no visible feedback.
	RFP.SELECT = function ()
		if (gAvailable == false) then
			Child.Debug.Warn ('vacuum: tap ignored, entity unavailable')
			return
		end
		if (gState == 'cleaning') then
			Child.CallService ('return_to_base')
		else
			Child.CallService ('start')
		end
	end

	EC.Start = function ()
		Child.CallService ('start')
	end

	EC.Pause = function ()
		Child.CallService ('pause')
	end

	EC.Stop = function ()
		Child.CallService ('stop')
	end

	EC.Return_to_Dock = function ()
		Child.CallService ('return_to_base')
	end

	EC.Locate = function ()
		Child.CallService ('locate')
	end

	EC.Set_Fan_Speed = function (tParams)
		local speed = tParams and tParams.Speed
		if (speed and speed ~= '') then
			Child.CallService ('set_fan_speed', {fan_speed = speed})
		end
	end

	-- vacuum.send_command passes a raw command to the vacuum's integration.
	-- This is how room, zone, and segment cleaning is driven on vacuums that
	-- support it, e.g. Valetudo segment cleaning. Command is the command name;
	-- Params is an optional JSON object of arguments for it.
	-- Reachable from both the Actions tab (SendCommand) and Programming
	-- ('Send Command' normalizes to Send_Command). Alias below.
	EC.SendCommand = function (tParams)
		local cmd = tParams and tParams.Command
		if (not cmd or cmd == '') then
			print ('openhac4 vacuum: Send Command needs a Command')
			return
		end
		local data = {command = cmd}
		local raw = tParams.Params
		if (raw and raw ~= '') then
			local ok, decoded = pcall (function () return C4:JsonDecode (raw) end)
			if (ok and type (decoded) == 'table') then
				data.params = decoded
			else
				-- length only, never the content (see the gateway's Call Service handler)
				print ('openhac4 vacuum: Params is not valid JSON (' ..
					#tostring (raw) .. ' characters), ignoring')
			end
		end
		Child.CallService ('send_command', data)
	end

	EC.Send_Command = EC.SendCommand
end
