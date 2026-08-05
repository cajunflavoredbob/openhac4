-- openhac4 Home Assistant Switch
-- Copyright (c) 2026 cajunflavoredbob. Licensed under the MIT License.
--
-- Maps a Home Assistant switch entity onto a Control4 experience button
-- (tap to toggle) with a relay provider binding for programming and for
-- binding Control4 relay consumer drivers.

Child = require ('openhac4.child')

do -- globals
	RELAY_BINDING = 200
	UIBUTTON_BINDING = 5001
	EVENT_ON = 1
	EVENT_OFF = 2
	EVENT_OFFLINE = 3

	gIsOn = nil -- nil until the first state arrives; suppresses events on load
end

local function reflectState (on)
	local first = (gIsOn == nil)
	local changed = (gIsOn ~= on)
	gIsOn = on

	if (on) then
		C4:SendToProxy (RELAY_BINDING, 'CLOSED', {})
		C4:SendToProxy (UIBUTTON_BINDING, 'ICON_CHANGED', {icon = 'Selected', icon_description = 'On'})
	else
		C4:SendToProxy (RELAY_BINDING, 'OPENED', {})
		-- 'Idle' is the uibutton proxy's off-state icon id (see driver.xml)
		C4:SendToProxy (UIBUTTON_BINDING, 'ICON_CHANGED', {icon = 'Idle', icon_description = 'Off'})
	end

	C4:SetVariable ('STATE', (on and 1) or 0)
	UpdateProperty ('Current State', (on and 'On') or 'Off')

	-- fire events only on real transitions, never on the initial sync after
	-- a project load or reconnect
	if (changed and not first) then
		C4:FireEventByID ((on and EVENT_ON) or EVENT_OFF)
	end
end

Child.Setup {
	domain = 'switch',

	onInit = function ()
		C4:AddVariable ('STATE', '0', 'BOOL', true, false)
	end,

	onState = function (state)
		-- 'unknown' is a transient (HA restart, integration blip), not a real
		-- off: hold the last state so no programming fires on it
		if (state.state == 'unknown') then
			UpdateProperty ('Current State', 'Unknown')
			return
		end
		reflectState (state.state == 'on')
	end,

	onOffline = function ()
		UpdateProperty ('Current State', 'Unavailable')
		C4:FireEventByID (EVENT_OFFLINE)
	end,

	onReset = function ()
		gIsOn = nil
	end,
}

do -- commands from bound proxies and programming
	RFP.SELECT = function ()
		Child.CallService ('toggle')
	end

	RFP.CLOSE = function ()
		Child.CallService ('turn_on')
	end

	RFP.OPEN = function ()
		Child.CallService ('turn_off')
	end

	RFP.TOGGLE = function ()
		Child.CallService ('toggle')
	end

	EC.Turn_On = function ()
		Child.CallService ('turn_on')
	end

	EC.Turn_Off = function ()
		Child.CallService ('turn_off')
	end

	EC.Toggle = function ()
		Child.CallService ('toggle')
	end
end
