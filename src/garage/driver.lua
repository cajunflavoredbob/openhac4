-- openhac4 Home Assistant Garage Door
-- Copyright (c) 2026 cajunflavoredbob. Licensed under the MIT License.
--
-- Presents a Home Assistant garage cover (cover entity, device_class garage) as
-- the classic Control4 garage building block: a momentary RELAY plus a CLOSED
-- and an OPEN contact sensor. Bind Control4's stock Garage Door driver onto
-- these three connections to get the native garage tile.
--
-- The relay is momentary: a pulse from the stock driver triggers the opener, so
-- we toggle the HA door. The contacts report position (in-transit shows both
-- open). This assumes the momentary-relay garage drivers Control4 ships; a
-- maintained-relay driver would instead need CLOSE/OPEN mapped directly to
-- close_cover/open_cover.

Child = require ('openhac4.child')

do -- globals
	RELAY_BINDING = 300
	CLOSED_CONTACT = 200 -- senses the door fully closed
	OPEN_CONTACT = 201   -- senses the door fully open
	EVENT_OPENED = 1
	EVENT_CLOSED = 2
	EVENT_OFFLINE = 3

	gState = nil -- nil until first state; suppresses events on load
end

-- drive the two contact sensors (CLOSED = contact detected)
local function contacts (closedDetected, openDetected)
	C4:SendToProxy (CLOSED_CONTACT, (closedDetected and 'CLOSED') or 'OPENED', {})
	C4:SendToProxy (OPEN_CONTACT, (openDetected and 'CLOSED') or 'OPENED', {})
end

Child.Setup {
	domain = 'cover',

	onState = function (state)
		local s = state.state
		-- 'unknown' is a transient (HA restart, integration blip), not a door
		-- position: hold the contacts so it does not read as door-in-motion,
		-- and no Opened/Closed event fires on the recovery edge
		if (s == 'unknown') then
			UpdateProperty ('Current State', 'Unknown')
			return
		end
		local first = (gState == nil)
		local changed = (gState ~= s)
		gState = s

		if (s == 'open') then
			contacts (false, true)
		elseif (s == 'closed') then
			contacts (true, false)
		else
			contacts (false, false) -- opening / closing: both open (in transit)
		end
		UpdateProperty ('Current State', tostring (s))

		if (changed and not first) then
			if (s == 'open') then C4:FireEventByID (EVENT_OPENED)
			elseif (s == 'closed') then C4:FireEventByID (EVENT_CLOSED) end
		end
	end,

	onOffline = function ()
		UpdateProperty ('Current State', 'Unavailable')
		contacts (false, false)
		C4:FireEventByID (EVENT_OFFLINE)
	end,

	onReset = function ()
		gState = nil
	end,
}

do -- relay commands from the bound stock garage driver + programming
	-- a momentary relay pulse triggers the opener; toggle the HA garage door
	RFP.CLOSE = function () Child.CallService ('toggle') end
	RFP.TRIGGER = function () Child.CallService ('toggle') end
	RFP.TOGGLE = function () Child.CallService ('toggle') end
	RFP.OPEN = function () end -- relay release (end of pulse): no-op

	EC.Open = function () Child.CallService ('open_cover') end
	EC.Close = function () Child.CallService ('close_cover') end
	EC.Stop = function () Child.CallService ('stop_cover') end
	EC.Toggle = function () Child.CallService ('toggle') end
end
