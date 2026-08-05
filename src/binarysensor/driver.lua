-- openhac4 Home Assistant Binary Sensor
-- Copyright (c) 2026 cajunflavoredbob. Licensed under the MIT License.
--
-- Maps a Home Assistant binary_sensor entity onto a Control4 contact sensor
-- provider binding. Bind a Control4 sensor driver (door contact, motion,
-- etc.) to the Contact State connection to surface it in navigators.

Child = require ('openhac4.child')

do -- globals
	CONTACT_BINDING = 200
	EVENT_BREACHED = 1
	EVENT_RESET = 2
	EVENT_OFFLINE = 3

	gBreached = nil -- nil until the first state arrives; suppresses events on load
end

local function reflectState (breached)
	local first = (gBreached == nil)
	local changed = (gBreached ~= breached)
	gBreached = breached

	-- Control4 contact convention: OPENED = breached, CLOSED = secure
	C4:SendToProxy (CONTACT_BINDING, (breached and 'OPENED') or 'CLOSED', {})
	C4:SetVariable ('STATE', (breached and 1) or 0)
	UpdateProperty ('Current State', (breached and 'Breached') or 'Clear')

	if (changed and not first) then
		C4:FireEventByID ((breached and EVENT_BREACHED) or EVENT_RESET)
	end
end

Child.Setup {
	domain = 'binary_sensor',

	onInit = function ()
		C4:AddVariable ('STATE', '0', 'BOOL', true, false)
	end,

	onState = function (state)
		-- 'unknown' is a transient (HA restart, integration blip), not a real
		-- clear: hold the last state so no breach/reset programming fires on
		-- it (with Invert on, treating it as off would report Breached)
		if (state.state == 'unknown') then
			UpdateProperty ('Current State', 'Unknown')
			return
		end
		local on = (state.state == 'on')
		if (Properties ['Invert'] == 'On') then
			on = not on
		end
		reflectState (on)
	end,

	onOffline = function ()
		UpdateProperty ('Current State', 'Unavailable')
		C4:FireEventByID (EVENT_OFFLINE)
	end,

	onReset = function ()
		gBreached = nil
	end,
}

-- re-evaluate when Invert flips. Clear gBreached first so the re-pushed
-- state counts as a fresh first sync and does not fire a breach/reset event
-- from a pure Composer configuration change.
OPC.Invert = function ()
	gBreached = nil
	Child.Register ()
end
