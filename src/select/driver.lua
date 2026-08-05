-- openhac4 Home Assistant Select
-- Copyright (c) 2026 cajunflavoredbob. Licensed under the MIT License.
--
-- Two-way bridge for a Home Assistant select entity. Feedback: one Control4
-- programming event is created at runtime per option and fires when that option
-- becomes active. Control: the Set Option action calls select.select_option
-- with the chosen option. Pure programming device: no proxy, no navigator.

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

	gOptionIds = {}  -- option -> C4 event id
	gUsedIds = {}    -- id -> option, to resolve rare hash collisions
	gOptions = {}    -- current option list, in HA order, for the Set Option picker
	gCurrent = nil   -- last-seen selection; nil until first sync
end

-- Stable event id derived from the option string (djb2 hash into the dynamic
-- range, probe on collision). Unlike a positional index, this never shifts when
-- the option set changes, so existing Composer programming keeps firing on the
-- right option across reloads and set changes.
local function stableId (key)
	local h = 5381
	for i = 1, #key do h = (h * 33 + key:byte (i)) % 2147483647 end
	local id = DYNAMIC_BASE + (h % 9000000)
	while (gUsedIds [id] and gUsedIds [id] ~= key) do id = id + 1 end
	gUsedIds [id] = key
	return id
end

-- One Control4 event per option. AddEvent updates in place if the id already
-- exists. The event name is the raw option (the value Home Assistant displays).
local function registerOptions (options)
	local display = {} -- stringified, HA order, for the picker + property
	for _, o in ipairs (options) do table.insert (display, tostring (o)) end
	-- assign ids over a sorted copy so that, in the rare event two options hash
	-- to the same id, the collision-probe order is deterministic regardless of
	-- the order HA lists them (keeps ids stable across reloads; matches event).
	local ordered = {}
	for _, o in ipairs (display) do table.insert (ordered, o) end
	table.sort (ordered)
	for _, o in ipairs (ordered) do
		-- an empty-string option would register a nameless, unfireable event
		if (o ~= '' and not gOptionIds [o]) then
			if (gDynamicCount >= MAX_DYNAMIC_EVENTS) then
				if (not gDynamicCapWarned) then
					gDynamicCapWarned = true
					print ('openhac4: dynamic event cap of ' .. MAX_DYNAMIC_EVENTS ..
						' reached; further options are not exposed to programming')
				end
				break
			end
			gOptionIds [o] = stableId (o)
			gDynamicCount = gDynamicCount + 1
			C4:AddEvent (gOptionIds [o], o, 'When Home Assistant selects the "' .. o .. '" option')
		end
	end
	gOptions = display
	UpdateProperty ('Detected Options', table.concat (display, ', '))
end

Child.Setup {
	domain = 'select',

	onState = function (state)
		local attrs = state.attributes or {}
		if (type (attrs.options) == 'table' and next (attrs.options) ~= nil) then
			registerOptions (attrs.options)
		end

		local option = state.state and tostring (state.state)
		-- 'unknown' is HA's no-selection sentinel UNLESS the entity genuinely
		-- advertises an option named "unknown", in which case it is a real
		-- selection and must update and fire like any other
		local sentinel = (option == 'unknown' and not gOptionIds [option])
		if (option and option ~= '' and not sentinel) then
			local first = (gCurrent == nil)
			local changed = (gCurrent ~= option)
			gCurrent = option
			UpdateProperty ('Current Selection', option)
			if (changed and not first) then
				local id = gOptionIds [option]
				if (id) then
					C4:FireEventByID (id)
				else
					Child.Debug.Trace ('selection not in advertised options, no C4 event:', option)
				end
			end
		end
	end,

	onOffline = function ()
		UpdateProperty ('Current Selection', 'Unavailable')
		C4:FireEventByID (EVENT_UNAVAILABLE)
	end,

	onReset = function ()
		-- see the event driver: the cap counts live events, so deleting them must
		-- also reset the counter
		for _, id in pairs (gOptionIds) do C4:DeleteEvent (id) end
		gDynamicCount, gDynamicCapWarned = 0, false
		gOptionIds = {}
		gUsedIds = {}
		gOptions = {}
		gCurrent = nil
		UpdateProperty ('Current Selection', '')
		UpdateProperty ('Detected Options', '')
	end,
}

-- Populates the Set Option action's CUSTOM_SELECT with the entity's live options.
function GetSelectOptions ()
	return gOptions
end

-- Set Option: send the chosen option to Home Assistant. Routes through the
-- child's call-service path (select.select_option on the bound entity).
EC.SetOption = function (tParams)
	local option = tParams.Option
	if (option == nil or tostring (option) == '') then
		print ('openhac4 select: Set Option needs an Option')
		return
	end
	Child.CallService ('select_option', {option = tostring (option)})
end

-- 'Set Option' from programming normalizes to Set_Option; alias to the handler
-- so the Actions-tab route (SetOption) and the programming route both work.
EC.Set_Option = EC.SetOption
