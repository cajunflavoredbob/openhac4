-- openhac4 Home Assistant Event
-- Copyright (c) 2026 cajunflavoredbob. Licensed under the MIT License.
--
-- Surfaces a Home Assistant event entity (stateless button/remote presses) to
-- Control4 programming. One Control4 driver event is created at runtime for
-- each event_type the entity advertises, and it fires whenever Home Assistant
-- reports that event_type. Pure programming device: no proxy, no navigator.

Child = require ('openhac4.child')

-- Ceiling on runtime-created Control4 events. The names come from Home
-- Assistant, and an entity whose list rotates (a template building them
-- dynamically) would otherwise add Director events without limit, one per
-- distinct string ever seen. Mirrors MAX_ATTR_VARS in the child framework.
local MAX_DYNAMIC_EVENTS = 64
local gDynamicCount = 0
local gDynamicCapWarned = false


do -- globals
	EVENT_UNAVAILABLE = 1 -- static event, declared in driver.xml
	DYNAMIC_BASE = 100    -- runtime event ids start clear of the static one

	gEventIds = {}   -- event_type -> C4 event id
	gUsedIds = {}    -- id -> event_type, to resolve rare hash collisions
	gLastState = nil -- last-seen entity state (a timestamp); nil until first sync
	gResync = false -- true after an offline edge: the next push is catch-up,
	                -- not a live press, and must not fire (see onState)
end

-- Stable event id derived from the event_type string (djb2 hash into the
-- dynamic range, probe on collision). Unlike a positional index, this never
-- shifts when the event_type set changes, so existing Composer programming
-- keeps firing on the right event across reloads and set changes.
local function stableId (key)
	local h = 5381
	for i = 1, #key do h = (h * 33 + key:byte (i)) % 2147483647 end
	local id = DYNAMIC_BASE + (h % 9000000)
	while (gUsedIds [id] and gUsedIds [id] ~= key) do id = id + 1 end
	gUsedIds [id] = key
	return id
end

-- "single_press" -> "Single Press"
local function prettyName (et)
	local s = tostring (et):gsub ('_', ' ')
	return (s:gsub ('(%a)(%w*)', function (a, b) return a:upper () .. b:lower () end))
end

-- One Control4 event per event_type. Sorted so ids stay stable across reloads
-- for a given entity; AddEvent updates in place if the id already exists.
local function registerEvents (types)
	local sorted = {}
	for _, et in ipairs (types) do table.insert (sorted, tostring (et)) end
	table.sort (sorted)
	for _, et in ipairs (sorted) do
		-- '' would register a nameless Composer event (select has the same guard)
		if (et ~= '' and not gEventIds [et]) then
			if (gDynamicCount >= MAX_DYNAMIC_EVENTS) then
				if (not gDynamicCapWarned) then
					gDynamicCapWarned = true
					print ('openhac4: dynamic event cap of ' .. MAX_DYNAMIC_EVENTS ..
						' reached; further event types are not exposed to programming')
				end
				break
			end
			gEventIds [et] = stableId (et)
			gDynamicCount = gDynamicCount + 1
			C4:AddEvent (gEventIds [et], prettyName (et), 'When Home Assistant reports the "' .. et .. '" event')
		end
	end
	-- report what actually has an event behind it, not what HA offered
	local registered = {}
	for _, et in ipairs (sorted) do
		if (gEventIds [et]) then table.insert (registered, et) end
	end
	UpdateProperty ('Detected Event Types', table.concat (registered, ', '))
end

Child.Setup {
	domain = 'event',

	onState = function (state)
		local attrs = state.attributes or {}
		if (type (attrs.event_types) == 'table' and next (attrs.event_types) ~= nil) then
			registerEvents (attrs.event_types)
		end

		-- an event entity's state is the timestamp of the last event; a change
		-- means a new one fired. The initial get_states snapshot carries the
		-- pre-load event, so suppress it (first sync fires nothing). The first
		-- push after an offline edge is the same shape: a catch-up snapshot
		-- whose changed timestamp is an event that happened during the outage,
		-- not a live press, and momentary programming (unlock on doorbell)
		-- must not replay it late.
		local first = (gLastState == nil) or gResync
		gResync = false
		local changed = (gLastState ~= state.state)
		gLastState = state.state

		-- a fired event_type may arrive as a string or a JSON number (an entity
		-- advertising numeric types fires them as numbers); both stringify to
		-- match the tostring'd advertised keys. A table is the null sentinel
		-- (absent) and must not be stringified into the property.
		local raw = attrs.event_type
		local et = (raw ~= nil and type (raw) ~= 'table') and tostring (raw) or nil
		if (et and et ~= '') then
			UpdateProperty ('Last Event Type', et)
			if (changed and not first) then
				local id = gEventIds [et]
				if (id) then
					C4:FireEventByID (id)
				else
					Child.Debug.Trace ('event_type not advertised, no C4 event fired:', et)
				end
			end
		end
	end,

	onOffline = function ()
		gResync = true
		UpdateProperty ('Last Event Type', 'Unavailable')
		C4:FireEventByID (EVENT_UNAVAILABLE)
	end,

	onReset = function ()
		-- entity changed: remove the dynamic events and re-learn from scratch.
		-- The cap counts events that currently exist, so clearing them must clear
		-- the counter too; otherwise reassigning the entity a few times exhausts a
		-- budget whose events have all already been deleted.
		for _, id in pairs (gEventIds) do C4:DeleteEvent (id) end
		gDynamicCount, gDynamicCapWarned = 0, false
		gEventIds = {}
		gUsedIds = {}
		gLastState = nil
		gResync = false
		UpdateProperty ('Last Event Type', '')
		UpdateProperty ('Detected Event Types', '')
	end,
}
