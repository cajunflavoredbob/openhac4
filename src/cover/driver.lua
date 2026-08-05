-- openhac4 Home Assistant Cover
-- Copyright (c) 2026 cajunflavoredbob. Licensed under the MIT License.
--
-- Maps a Home Assistant cover entity onto a Control4 blind proxy.
-- Protocol (snap-one docs-driverworks-proxyprotocol):
--   config TX SET_HAS_LEVEL {HAS_LEVEL, LEVEL_OPEN, LEVEL_CLOSED, ...}, SET_CAN_STOP
--   state  TX MOVING {LEVEL_TARGET, RAMP_RATE}, STOPPED {LEVEL}
--   RX     SET_LEVEL_TARGET {LEVEL_TARGET 0-100}, SET_MOVEMENT
-- Control4 level and HA position share the same convention (100 = open,
-- 0 = closed), so no inversion is needed.

Child = require ('openhac4.child')

do -- globals
	BLIND_BINDING = 5001
	EVENT_OPENED = 1
	EVENT_CLOSED = 2
	EVENT_STOPPED = 3
	EVENT_OFFLINE = 4

	-- HA cover supported_features bits
	FEAT_SET_POSITION = 4

	gConfigured = false
	gPositional = false
	gLevel = nil
	gTarget = nil -- last commanded target level, for the MOVING notification
	gLastFeats = nil -- supported_features the current config was built from
	gZone = nil -- open/closed/mid latch, so settle jitter can't refire events
end

local FEAT_STOP = 8 -- HA cover STOP feature bit

local function sendConfig (state)
	local feats = tonumber (state.attributes and state.attributes.supported_features) or 0
	gPositional = (math.floor (feats / FEAT_SET_POSITION) % 2) == 1
	local canStop = (math.floor (feats / FEAT_STOP) % 2) == 1

	C4:SendToProxy (BLIND_BINDING, 'SET_HAS_LEVEL', {
		HAS_LEVEL = gPositional,
		LEVEL_OPEN = 100,
		LEVEL_CLOSED = 0,
		LEVEL_DISCRETE_CONTROL = gPositional,
	})
	-- advertise Stop only when the integration implements stop_cover; an
	-- unconditional true offers a button whose press HA rejects silently
	C4:SendToProxy (BLIND_BINDING, 'SET_CAN_STOP', {SET_CAN_STOP = canStop})
	gLastFeats = feats
	gConfigured = true
end

local function levelFromState (state)
	local pos = state.attributes and state.attributes.current_position
	if (pos ~= nil) then
		return tonumber (pos)
	end
	-- no feedback: derive from open/closed
	if (state.state == 'open') then return 100 end
	if (state.state == 'closed') then return 0 end
	return nil
end

Child.Setup {
	domain = 'cover',

	onState = function (state)
		-- reconfigure when the feature set changes, not just once: a first
		-- state with missing attributes would otherwise latch the cover as
		-- non-positional for the life of the session. A push that DROPS to 0
		-- features (missing attributes during an HA blip) is ignored so the
		-- config does not flap; a genuine 0 can only latch on the first push.
		local feats = tonumber (state.attributes and state.attributes.supported_features) or 0
		if (not gConfigured or (feats ~= gLastFeats and feats ~= 0)) then
			sendConfig (state)
		end

		local haState = state.state
		if (haState == 'opening' or haState == 'closing') then
			-- prefer the actual commanded target; fall back to full travel
			local target = gTarget or ((haState == 'opening') and 100 or 0)
			C4:SendToProxy (BLIND_BINDING, 'MOVING', {LEVEL_TARGET = target, RAMP_RATE = 0})
			UpdateProperty ('Current Position', haState)
			return
		end

		local level = levelFromState (state)
		if (level ~= nil) then
			local first = (gLevel == nil)
			local changed = (gLevel ~= level)
			gLevel = level
			gTarget = nil -- settled: clear the travel target
			C4:SendToProxy (BLIND_BINDING, 'STOPPED', {LEVEL = level})
			C4:SetVariable ('LEVEL', level)
			UpdateProperty ('Current Position', tostring (level) .. '%')
			-- Events on real transitions, never on the first sync after load.
			-- Open/Closed key on zone edges with 99/1 thresholds: slat covers
			-- settle just shy of the rail after full travel, and the zone latch
			-- keeps 100-then-99 from firing Opened twice. Stopped still fires
			-- on every mid-zone level change (a partial-position arrival is a
			-- real stop dealers program against).
			local zone = (level >= 99 and 'open') or (level <= 1 and 'closed') or 'mid'
			if (not first and changed) then
				if (zone == 'open' and gZone ~= 'open') then C4:FireEventByID (EVENT_OPENED)
				elseif (zone == 'closed' and gZone ~= 'closed') then C4:FireEventByID (EVENT_CLOSED)
				elseif (zone == 'mid') then C4:FireEventByID (EVENT_STOPPED) end
			end
			gZone = zone
		end
	end,

	onReset = function ()
		gConfigured = false
		gLevel = nil
		gLastFeats = nil
		gZone = nil
		gTarget = nil       -- drop the prior entity's move target...
		gPositional = false -- ...and its capability, so a first opening/closing
		                    -- push can't drive MOVING off stale state
	end,

	onInit = function ()
		C4:AddVariable ('LEVEL', '0', 'NUMBER', true, false)
	end,

	onOffline = function ()
		UpdateProperty ('Current Position', 'Unavailable')
		C4:FireEventByID (EVENT_OFFLINE)
	end,
}

do -- proxy commands
	RFP.SET_LEVEL_TARGET = function (idBinding, strCommand, tParams)
		Child.TraceParams ('RFP SET_LEVEL_TARGET', tParams)
		local target = tonumber (tParams.LEVEL_TARGET)
		if (target == nil) then return end
		-- only record the target when a service is actually dispatched, so a
		-- non-positional cover asked for a mid-level (no service sent) doesn't
		-- leave a stale gTarget driving a bogus MOVING indication.
		if (gPositional) then
			gTarget = target
			Child.CallService ('set_cover_position', {position = target})
		elseif (target >= 100) then
			gTarget = 100
			Child.CallService ('open_cover')
		elseif (target <= 0) then
			gTarget = 0
			Child.CallService ('close_cover')
		end
	end

	-- SET_MOVEMENT carries the direction (open/close/stop) for non-positional
	-- blinds and the stop press on positional ones. The enum value lives under
	-- one of a few keys depending on OS; read defensively.
	RFP.SET_MOVEMENT = function (idBinding, strCommand, tParams)
		Child.TraceParams ('RFP SET_MOVEMENT', tParams)
		local m = tostring (tParams.MOVEMENT or tParams.SET_MOVEMENT or tParams.MOVE or ''):lower ()
		if (m:find ('open') or m:find ('up') or m == '1') then
			gTarget = 100
			Child.CallService ('open_cover')
		elseif (m:find ('close') or m:find ('down') or m == '2') then
			gTarget = 0
			Child.CallService ('close_cover')
		else
			gTarget = nil
			Child.CallService ('stop_cover')
		end
	end

	-- direct commands, defensively supported
	RFP.OPEN = function () gTarget = 100 Child.CallService ('open_cover') end
	RFP.CLOSE = function () gTarget = 0 Child.CallService ('close_cover') end
	RFP.STOP = function () gTarget = nil Child.CallService ('stop_cover') end

	-- match the RFP paths: set gTarget so MOVING reports the right direction
	EC.Open = function () gTarget = 100 Child.CallService ('open_cover') end
	EC.Close = function () gTarget = 0 Child.CallService ('close_cover') end
	EC.Stop = function () gTarget = nil Child.CallService ('stop_cover') end
	EC.Set_Position = function (tParams)
		local p = tParams and tonumber (tParams.Position)
		if (p == nil) then return end
		-- mirror RFP.SET_LEVEL_TARGET: a non-positional cover has no
		-- set_cover_position service, so map the extremes to open/close and
		-- record gTarget only when a service is actually dispatched
		if (gPositional) then
			gTarget = p
			Child.CallService ('set_cover_position', {position = p})
		elseif (p >= 100) then
			gTarget = 100
			Child.CallService ('open_cover')
		elseif (p <= 0) then
			gTarget = 0
			Child.CallService ('close_cover')
		end
	end
end
