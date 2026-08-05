-- openhac4 Home Assistant Humidifier
-- Copyright (c) 2026 cajunflavoredbob. Licensed under the MIT License.
--
-- Maps a Home Assistant humidifier entity to Control4 programming: on/off with
-- Turn On/Off/Toggle, a Set Humidity action (target %), and a Set Mode action
-- (from the entity's available modes). Current/target humidity and mode are
-- exposed as properties and variables. Pure programming device (no proxy).

Child = require ('openhac4.child')

do -- globals
	EVENT_ON = 1
	EVENT_OFF = 2
	EVENT_OFFLINE = 3

	gIsOn = nil  -- nil until first state; suppresses events on load
	gModes = {}  -- available_modes, for the Set Mode picker
end

Child.Setup {
	domain = 'humidifier',

	onInit = function ()
		C4:AddVariable ('STATE', '0', 'BOOL', true, false)
		C4:AddVariable ('HUMIDITY', '0', 'NUMBER', true, false)
	end,

	onState = function (state)
		-- 'unknown' is a transient (HA restart, integration blip), not a real
		-- off: hold the last state so no programming fires on it
		if (state.state == 'unknown') then
			UpdateProperty ('Current State', 'Unknown')
			return
		end
		local attrs = state.attributes or {}
		if (type (attrs.available_modes) == 'table') then gModes = attrs.available_modes end
		-- entity humidity bounds, for clamping Set Humidity
		gMinH = tonumber (attrs.min_humidity) or gMinH
		gMaxH = tonumber (attrs.max_humidity) or gMaxH

		local on = (state.state == 'on')
		local first = (gIsOn == nil)
		local changed = (gIsOn ~= on)
		gIsOn = on

		C4:SetVariable ('STATE', (on and 1) or 0)
		UpdateProperty ('Current State', (on and 'On') or 'Off')
		if (attrs.humidity ~= nil) then
			-- only write the variable when the value is really numeric: a
			-- fabricated 0 for a garbage string reads as a legitimate reading
			-- to programming (the property still shows the raw value)
			local h = tonumber (attrs.humidity)
			if (h ~= nil) then C4:SetVariable ('HUMIDITY', h) end
			UpdateProperty ('Target Humidity', tostring (attrs.humidity) .. ' %')
		end
		if (attrs.current_humidity ~= nil) then
			UpdateProperty ('Current Humidity', tostring (attrs.current_humidity) .. ' %')
		end
		if (attrs.mode ~= nil) then
			UpdateProperty ('Current Mode', tostring (attrs.mode))
		end

		if (changed and not first) then
			C4:FireEventByID ((on and EVENT_ON) or EVENT_OFF)
		end
	end,

	onOffline = function ()
		UpdateProperty ('Current State', 'Unavailable')
		C4:FireEventByID (EVENT_OFFLINE)
	end,

	onReset = function ()
		gIsOn = nil
		gModes = {} -- entity changed: drop the old Set Mode picker list
		gMinH, gMaxH = nil, nil
		-- clear per-entity displays so the previous entity's values do not
		-- linger on the new one until its first push
		UpdateProperty ('Target Humidity', '')
		UpdateProperty ('Current Humidity', '')
		UpdateProperty ('Current Mode', '')
	end,
}

do -- actions
	EC.Turn_On = function () Child.CallService ('turn_on') end
	EC.Turn_Off = function () Child.CallService ('turn_off') end
	EC.Toggle = function () Child.CallService ('toggle') end

	EC.SetHumidity = function (tParams)
		local h = tParams and tonumber (tParams.Humidity)
		if (h ~= nil) then
			-- clamp to the entity's own range: the action offers 0-100 but HA
			-- rejects a set_humidity outside min/max_humidity outright
			if (gMinH and h < gMinH) then h = gMinH end
			if (gMaxH and h > gMaxH) then h = gMaxH end
			Child.CallService ('set_humidity', {humidity = h})
		end
	end

	EC.SetMode = function (tParams)
		local m = tParams and tParams.Mode
		if (m and tostring (m) ~= '') then
			Child.CallService ('set_mode', {mode = tostring (m)})
		end
	end
end

-- CUSTOM_SELECT populator for the Set Mode action
function GetHumidifierModes () return gModes end

-- Programming Device Specific Commands normalize the display name (spaces to
-- underscores), so 'Set Humidity'/'Set Mode' arrive as Set_Humidity/Set_Mode.
-- Alias them to the Actions-tab handlers so both routes reach the same code.
EC.Set_Humidity = EC.SetHumidity
EC.Set_Mode = EC.SetMode
