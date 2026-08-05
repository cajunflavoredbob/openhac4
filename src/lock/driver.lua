-- openhac4 Home Assistant Lock
-- Copyright (c) 2026 cajunflavoredbob. Licensed under the MIT License.
--
-- Maps a Home Assistant lock entity onto a Control4 lock proxy.
-- Protocol (snap-one docs-driverworks-proxyprotocol):
--   RX  LOCK / UNLOCK / TOGGLE / CLOSE (=lock) / OPEN (=unlock)
--   TX  LOCK_STATUS_CHANGED {LOCK_STATUS = locked|unlocked|unknown|fault}

Child = require ('openhac4.child')

do -- globals
	LOCK_BINDING = 5001
	EVENT_LOCKED = 1
	EVENT_UNLOCKED = 2
	EVENT_JAMMED = 3
	EVENT_OFFLINE = 4

	gStatus = nil -- last reported status; nil until first state
end

-- HA lock states: locked, unlocked, locking, unlocking, jammed, open, unknown.
-- locking/unlocking are transient; keep the last known status so the lock
-- does not flash "unknown" during every operation.
local function haToStatus (haState)
	if (haState == 'locked') then return 'locked' end
	if (haState == 'unlocked' or haState == 'open') then return 'unlocked' end
	if (haState == 'jammed') then return 'fault' end
	-- 'opening' is the latch-open transient on locks with an open feature
	if (haState == 'locking' or haState == 'unlocking' or haState == 'opening') then return gStatus or 'unknown' end
	-- 'unknown' (and anything unmapped) is a transient, not a bolt movement:
	-- hold the last state so the unknown -> locked recovery edge cannot fire
	-- a spurious Locked/Unlocked event
	return gStatus or 'unknown'
end

local function reflect (status)
	local first = (gStatus == nil)
	local changed = (gStatus ~= status)
	-- a change FROM 'unknown' is a report catching up, not a bolt movement;
	-- it must not fire Locked/Unlocked programming
	local wasUnknown = (gStatus == 'unknown')
	gStatus = status

	C4:SendToProxy (LOCK_BINDING, 'LOCK_STATUS_CHANGED', {LOCK_STATUS = status})
	C4:SetVariable ('LOCK_STATE', status)
	UpdateProperty ('Current State', status)

	if (changed and not first and not wasUnknown) then
		if (status == 'locked') then
			C4:FireEventByID (EVENT_LOCKED)
		elseif (status == 'unlocked') then
			C4:FireEventByID (EVENT_UNLOCKED)
		elseif (status == 'fault') then
			C4:FireEventByID (EVENT_JAMMED)
		end
	end
end

Child.Setup {
	domain = 'lock',

	onInit = function ()
		C4:AddVariable ('LOCK_STATE', '', 'STRING', true, false)
	end,

	onState = function (state)
		reflect (haToStatus (state.state))
	end,

	onOffline = function ()
		UpdateProperty ('Current State', 'Unavailable')
		C4:SendToProxy (LOCK_BINDING, 'LOCK_STATUS_CHANGED', {LOCK_STATUS = 'unknown'})
		C4:FireEventByID (EVENT_OFFLINE)
	end,

	onReset = function ()
		gStatus = nil
	end,
}

do -- proxy commands
	RFP.LOCK = function ()
		Child.CallService ('lock')
	end

	RFP.UNLOCK = function ()
		Child.CallService ('unlock')
	end

	RFP.TOGGLE = function ()
		if (gStatus == 'locked') then
			Child.CallService ('unlock')
		else
			Child.CallService ('lock')
		end
	end

	-- CLOSE/OPEN arrive from a bound relay driver
	RFP.CLOSE = function ()
		Child.CallService ('lock')
	end

	RFP.OPEN = function ()
		Child.CallService ('unlock')
	end

	EC.Lock = function ()
		Child.CallService ('lock')
	end

	EC.Unlock = function ()
		Child.CallService ('unlock')
	end

	EC.Toggle = function ()
		RFP.TOGGLE ()
	end
end
