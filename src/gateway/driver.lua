-- openhac4 Home Assistant Gateway
-- Copyright (c) 2026 cajunflavoredbob. Licensed under the MIT License.
--
-- Maintains the websocket connection to Home Assistant, authenticates with a
-- long-lived access token, caches entity states, and routes state changes to
-- registered child drivers. Also provides the room-aware import: actions that add
-- and configures child drivers for discovered entities.

require ('openhac4.c4handlers')
require ('openhac4.c4timer')
require ('openhac4.c4lib')

-- Must be the global named WebSocket: c4handlers/c4socket share the OCS/RFN
-- dispatch tables keyed by network binding, and WebSocket.Sockets tracks the
-- live sockets by that binding.
WebSocket = require ('openhac4.c4socket')

local Debug = require ('openhac4.debug')
local Proto = require ('openhac4.protocol')

do -- globals
	-- shared with the children via openhac4.protocol so they cannot drift
	OPENHAC4_BINDING = Proto.BINDING
	ENTITY_ID_VAR = Proto.ENTITY_ID_VAR

	RECONNECT_START_DELAY = 5 -- seconds, initial reconnect backoff
	IMPORT_STAGGER_SECONDS = 2 -- delay between device adds during an import
	MAX_CACHED_ENTITIES = 10000 -- ceiling on the state cache (see handleEvent)

	-- domain -> child driver c4z filename, extended as new drivers land
	DOMAIN_DRIVERS = {
		switch = 'openhac4_switch.c4z',
		binary_sensor = 'openhac4_binarysensor.c4z',
		light = 'openhac4_light.c4z',
		sensor = 'openhac4_sensor.c4z',
		lock = 'openhac4_lock.c4z',
		vacuum = 'openhac4_vacuum.c4z',
		cover = 'openhac4_cover.c4z',
		fan = 'openhac4_fan.c4z',
		climate = 'openhac4_climate.c4z',
		event = 'openhac4_event.c4z',
		select = 'openhac4_select.c4z',
		alarm_control_panel = 'openhac4_alarm.c4z',
		humidifier = 'openhac4_humidifier.c4z',
		media_player = 'openhac4_media_player.c4z',
		-- not a real HA domain: garage covers (cover + device_class garage) are
		-- routed here during import (see the c4z lookup).
		garage = 'openhac4_garage.c4z',
	}

	-- Every openhac4 child c4z, for the project-wide scans (re-register after a
	-- gateway reload, and working out which entities are already claimed).
	-- DOMAIN_DRIVERS alone is not enough: media_source is added by hand rather
	-- than by import, so it has no domain entry, but it is still a child that
	-- must be prompted to re-register and whose entity must count as claimed.
	ALL_CHILD_C4Z = {'openhac4_media_source.c4z'}
	for _, c4z in pairs (DOMAIN_DRIVERS) do
		table.insert (ALL_CHILD_C4Z, c4z)
	end

	gWS = nil
	gAuthed = false
	gStates = {} -- entity_id -> latest state object from HA
	gStatesLoaded = false -- true once get_states has populated gStates at least once
	gEntityCount = 0
	gEntityCapWarned = false -- so the cache-cap warning prints once, not per event
	gLateInitDone = false -- true once OnDriverLateInit has run; gates config reconnects
	gMsgId = 0
	gPending = {} -- outstanding request id -> result handler
	gReconnectDelay = RECONNECT_START_DELAY -- doubles per failure up to 60
	gReconnectPending = false -- a reconnect is already armed; guards duplicate OFFLINEs
	gSuppressReconnect = false
	gHAVersion = ''
	gToken = ''

	gRegistrations = {} -- entity_id -> {childDeviceId = true, ...}
	gChildEntities = {} -- childDeviceId -> entity_id
	BROWSE_MAX_CHILDREN = 500 -- cap a browse level so its serialized payload stays under the message limit
	BROWSE_MAX_BYTES = 150000 -- and a byte budget on the serialized result:
	-- rows are not bytes (media-source ids are routinely signed URIs hundreds
	-- of characters long), and an oversized payload arrives undecodable,
	-- leaving that library level permanently unbrowsable. The true
	-- SendToDevice ceiling is undocumented; this is a conservative guess, and
	-- the halving loop below degrades to a shorter list either way.
	ENTITY_LIST_MAX = 500 -- cap the entity picker list for the same reason

	gTemplateId = nil -- ws message id of the area-map render_template subscription
	gEntityArea = {} -- entity_id -> HA area name
	gAreaNames = {} -- ordered list of HA area names
	gEntityLabels = {} -- entity_id -> {label_name = true}

	-- import run state
	gImportQueue = {} -- pending {entityId, c4z, name, roomId} to add
	gImporting = {} -- entity_id -> true while queued/in-flight (re-entry guard)
	gImportRunning = false
	gPendingImport = {} -- new child device id -> entity_id it should claim

	-- PersistData.AreaRooms: HA area name -> C4 room id, for rooms this
	-- driver created (so re-runs don't duplicate). Loaded in OnDriverLateInit.
end

-- forward declarations so definition order below doesn't matter
local processMessage, handleEvent, fetchStates, subscribeAndFetch
local scheduleReconnect, cancelReconnect

local jsonEncode = Proto.jsonEncode
local jsonDecode = Proto.jsonDecode

local function setStatus (s)
	UpdateProperty ('Connection Status', s)
end

-- Credential detection: service-data keys whose value is a secret the user
-- typed. A frame carrying one of these is never written to the frame log, no
-- matter the log level. Detecting this at the source beats scanning the
-- serialized frame: the alarm's disarm PIN travels as an ordinary
-- service_data field and looks like any other value once it is JSON.
-- Substring match, not exact: integrations name their secret parameters
-- freely (usercode, access_code, new_password, secret), and an exact list
-- misses every variant it did not predict. Over-matching only withholds a
-- frame from the debug log, which is the safe direction to be wrong in.
local CREDENTIAL_PATTERNS = {'code', 'pin', 'pass', 'secret', 'token', 'key'}
local function isCredentialKey (k)
	k = tostring (k):lower ()
	for _, p in ipairs (CREDENTIAL_PATTERNS) do
		if (k:find (p, 1, true)) then return true end
	end
	return false
end

-- Walk the whole service_data, not just its top level: a service that nests its
-- arguments would otherwise hide a code from the check. Depth-limited so a
-- cyclic or pathological table cannot spin here.
local function hasCredentialKey (data, depth)
	if (type (data) ~= 'table' or depth > 4) then return false end
	for k, v in pairs (data) do
		if (isCredentialKey (k)) then return true end
		if (hasCredentialKey (v, depth + 1)) then return true end
	end
	return false
end

local function carriesCredential (t)
	if (type (t) ~= 'table') then return false end
	return hasCredentialKey (t.service_data, 1)
end

-- Send a JSON message without an id. Only valid for the auth phase, which is
-- the one part of the HA websocket protocol where ids are forbidden.
local function wsSendRaw (t, sensitive)
	if (gWS and gWS.running) then
		local body = jsonEncode (t)
		if (not body) then
			-- refuse to put a placeholder on the wire: Home Assistant would reject
			-- it with a null id, so any callback registered for this message would
			-- never be matched and would sit in gPending for the session
			print ('openhac4: could not encode an outgoing message, dropping it')
			return false
		end
		gWS:Send (body, sensitive or carriesCredential (t))
		return true
	end
	return false
end

-- Send a JSON command message with an auto-incremented id; optional callback
-- fires when the matching result message arrives. The callback is only
-- registered if the message actually went out, so a send during a dead
-- window does not strand a callback in gPending.
local function wsSend (t, callback)
	gMsgId = gMsgId + 1
	t.id = gMsgId
	if (not wsSendRaw (t)) then
		-- nil rather than an id: a caller that stores the id (the area-map
		-- template subscription) would otherwise wait forever for an event that
		-- belongs to a frame which never left
		return nil
	end
	if (callback) then
		gPending [gMsgId] = callback
	end
	return gMsgId
end

local function entityDomain (entityId)
	return string.match (entityId or '', '^(.-)%.')
end

-- children compare this against their own FindGateway() result and ignore
-- pushes that do not carry it, so an unrelated driver cannot spoof state
local function gatewayId ()
	return tostring (C4:GetDeviceID ())
end

local function sendStateToChild (deviceId, entityId, state)
	-- a removed entity is pushed as unavailable so the child reacts sanely
	state = state or {entity_id = entityId, state = 'unavailable', attributes = {}}
	-- Serialize (base64): raw JSON does not survive C4:SendToDevice's tParams
	-- serialization once it contains quotes/braces/nested tables.
	C4:SendToDevice (deviceId, 'OPENHAC4_STATE', {
		entity_id = entityId,
		state = Serialize (state),
		gateway_id = gatewayId (),
	})
end

local function pushStateToRegistered (entityId)
	local registered = gRegistrations [entityId]
	if (not registered) then return end
	-- Per-child pcall: a single bad registration (a deleted device id, an
	-- oversized payload) must not abort the fan-out and silently deprive every
	-- remaining child of this state change.
	for deviceId in pairs (registered) do
		local ok, err = pcall (sendStateToChild, deviceId, entityId, gStates [entityId])
		if (not ok) then
			print ('openhac4: state push to device ' .. tostring (deviceId) ..
				' failed for ' .. tostring (entityId) .. ': ' .. tostring (err))
		end
	end
end

local function broadcastGatewayStatus (status)
	-- per-child pcall, as in pushStateToRegistered: a stale device id must not
	-- abort the loop, and this runs first in OnDriverDestroyed where a throw
	-- would skip the socket release and strand a network binding
	for deviceId in pairs (gChildEntities) do
		pcall (C4.SendToDevice, C4, deviceId, 'OPENHAC4_GATEWAY_STATUS',
			{status = status, gateway_id = gatewayId ()})
	end
end

-- After a gateway reload our in-memory registrations are empty, so pushes
-- reach nobody until each child's own 2-minute timer re-registers. Prompt
-- every openhac4 child in the project to re-register now instead.
local function requestChildrenReregister ()
	for _, c4zName in ipairs (ALL_CHILD_C4Z) do
		local ok, devices = pcall (C4.GetDevicesByC4iName, C4, c4zName)
		for deviceId in pairs ((ok and devices) or {}) do
			-- contain per child: a throw here would abort auth_ok before the
			-- subscription and state fetch, leaving the gateway connected but idle
			pcall (C4.SendToDevice, C4, deviceId, 'OPENHAC4_REREGISTER',
				{gateway_id = gatewayId ()})
		end
	end
end

-- Bound what a single cached state can hold. The entity-count cap bounds how
-- many states are cached but not their size; one entity with a multi-megabyte
-- attribute (a camera snapshot blob, a huge forecast list) would otherwise sit
-- in controller memory and ride every push to its child. Oversized attribute
-- values are dropped; a missing attributes table is normalized so nothing
-- downstream indexes a scalar.
local MAX_ATTR_STRING = 32 * 1024
local MAX_ATTR_NODES = 1000

-- Budget counts nodes AND string bytes (in MAX_ATTR_STRING units per byte
-- fraction), so a small table wrapping a multi-MB string cannot evade the cap.
local function tableTooBig (t, budget)
	for k, v in pairs (t) do
		budget = budget - 1
		if (type (k) == 'string') then budget = budget - (#k / MAX_ATTR_STRING) * MAX_ATTR_NODES end
		if (type (v) == 'string') then budget = budget - (#v / MAX_ATTR_STRING) * MAX_ATTR_NODES end
		if (budget <= 0) then return true, 0 end
		if (type (v) == 'table') then
			local big
			big, budget = tableTooBig (v, budget)
			if (big) then return true, 0 end
		end
	end
	return false, budget
end

local function slimState (st)
	if (type (st.attributes) ~= 'table') then
		st.attributes = {}
		return st
	end
	local drop
	for k, v in pairs (st.attributes) do
		local fat = false
		if (type (v) == 'string' and #v > MAX_ATTR_STRING) then
			fat = true
		elseif (type (v) == 'table') then
			fat = tableTooBig (v, MAX_ATTR_NODES)
		end
		if (fat) then
			drop = drop or {}
			drop [#drop + 1] = k
		end
	end
	for _, k in ipairs (drop or {}) do
		Debug.Dbg ('dropped oversized attribute', k, 'from', tostring (st.entity_id))
		st.attributes [k] = nil
	end
	return st
end

function handleEvent (event)
	if (not (event and event.event_type == 'state_changed')) then
		return
	end
	local data = event.data
	if (type (data) ~= 'table') then
		return -- a scalar data field would throw on every index below
	end
	local entityId = data.entity_id
	-- must be a string: a table or number id would key gStates and later throw
	-- inside table.sort/table.concat when the entity picker is built
	if (type (entityId) ~= 'string' or entityId == '') then
		return
	end

	-- new_state is null when an entity is removed from HA; keep Entity Count
	-- current as entities appear and disappear
	if (data.new_state == nil) then
		if (gStates [entityId] ~= nil) then
			gStates [entityId] = nil
			gEntityCount = gEntityCount - 1
			UpdateProperty ('Entity Count', tostring (gEntityCount))
		end
	elseif (type (data.new_state) ~= 'table') then
		-- a scalar state object would sit in the cache and later throw inside
		-- Import Devices and Display Devices, which both index it as a table
		return
	else
		if (gStates [entityId] == nil) then
			-- Entity ids arrive from the server. A malfunctioning or hostile Home
			-- Assistant emitting events for synthetic ids would otherwise grow this
			-- cache without limit, and a controller has far less headroom than the
			-- host it is talking to. Real installs are orders of magnitude below.
			if (gEntityCount >= MAX_CACHED_ENTITIES) then
				if (not gEntityCapWarned) then
					gEntityCapWarned = true
					print ('openhac4: entity cache cap of ' .. MAX_CACHED_ENTITIES ..
						' reached; new entities are being ignored')
				end
				return
			end
			gEntityCount = gEntityCount + 1
			UpdateProperty ('Entity Count', tostring (gEntityCount))
		end
		gStates [entityId] = slimState (data.new_state)
	end

	local s = (data.new_state and data.new_state.state) or 'removed'
	Debug.Info ('state_changed:', entityId, '->', s)

	pushStateToRegistered (entityId)
end

function fetchStates ()
	wsSend ({type = 'get_states'}, function (msg)
		if (msg.success and type (msg.result) == 'table') then
			gStates = {}
			local n, dropped = 0, 0
			for _, st in ipairs (msg.result) do
				-- type-check both: one malformed element would otherwise throw
				-- inside this callback and leave the cache empty for good
				if (type (st) == 'table' and type (st.entity_id) == 'string') then
					if (n >= MAX_CACHED_ENTITIES) then
						dropped = dropped + 1
					elseif (gStates [st.entity_id] == nil) then
						gStates [st.entity_id] = slimState (st)
						n = n + 1
					end
				end
			end
			if (dropped > 0) then
				print ('openhac4: Home Assistant reported more than ' ..
					MAX_CACHED_ENTITIES .. ' entities; ' .. dropped .. ' were not cached')
			end
			gEntityCount = n
			gStatesLoaded = true
			-- fresh cache, so let the cap warn again if it is hit next time
			gEntityCapWarned = false
			UpdateProperty ('Entity Count', tostring (n))
			print ('openhac4: loaded ' .. n .. ' entities from Home Assistant')

			-- sync every registered child with the fresh cache. Children
			-- register at auth, before this fetch returns, so this loop (not
			-- registration time) is where a reload with an already-typo'd
			-- Entity ID surfaces: warn here too, or that case stays silent
			-- behind a bare 'unavailable' forever.
			for entityId in pairs (gRegistrations) do
				if (gStates [entityId] == nil) then
					print ('openhac4: a child is registered for "' .. tostring (entityId) ..
						'", which Home Assistant does not report; check its Entity ID')
				end
				pushStateToRegistered (entityId)
			end
		else
			-- retry once shortly rather than leaving a stale/empty cache
			print ('openhac4: get_states failed, retrying')
			SetTimer ('RetryStates', 5 * ONE_SECOND, function ()
				if (gAuthed) then fetchStates () end
			end)
		end
	end)
end

-- Template that emits one compact "entity_id|Area Name|Label,Label" line per
-- entity that has an area or a label. Resolving areas from the full entity
-- registry is not viable: for a large Home Assistant that response is hundreds
-- of KB in a single websocket frame, which the controller does not deliver
-- reliably. area_name()/labels() already fold in device-level area inheritance
-- and give display names (so the label filter matches what the dealer sees).
-- Emit JSON rather than a delimited format. Area and label names are free text
-- in Home Assistant, so any separator we picked would eventually appear inside a
-- name: an area called "Kitchen | Bar", a label containing a comma, or a name
-- with an embedded newline all corrupt a hand-rolled parse, and the failure is
-- invisible (entities silently land in the wrong room, or a label filter matches
-- nothing). to_json quotes and escapes for us.
local AREA_TEMPLATE = table.concat ({
	'{%- set ns = namespace(out=[]) -%}',
	'{%- for s in states -%}',
	'{%- set a = area_name(s.entity_id) -%}',
	"{%- set l = labels(s.entity_id) | map('label_name') | list -%}",
	'{%- if a or l -%}',
	"{%- set ns.out = ns.out + [{'e': s.entity_id, 'a': a or '', 'l': l}] -%}",
	'{%- endif -%}',
	'{%- endfor -%}',
	'{{ ns.out | to_json }}',
})

-- Fetch the HA areas (small, for Import Rooms) and, separately, the compact
-- entity -> area / labels map via a rendered template (see AREA_TEMPLATE).
function fetchRegistries ()
	wsSend ({type = 'config/area_registry/list'}, function (msg)
		-- keep the previous list on failure (a reconnect fails this callback
		-- synthetically): wiping it would empty Import Rooms and the area
		-- filter until the next successful fetch
		if (msg.success and type (msg.result) == 'table') then
			gAreaNames = {}
			for _, a in ipairs (msg.result) do
				if (a.name) then
					table.insert (gAreaNames, a.name)
				end
			end
		end
		table.sort (gAreaNames)
		Debug.Info ('areas loaded:', #gAreaNames)
	end)

	-- render_template replies with a result, then pushes the rendered value as
	-- an event (and would keep pushing on change); we take the first render
	-- and unsubscribe. gTemplateId routes that event in processMessage.
	gTemplateId = wsSend ({type = 'render_template', template = AREA_TEMPLATE, report_errors = false},
		function (msg)
			if (msg.success) then return end -- the render itself arrives as an event
			-- outright rejection (template failed to compile): no event will ever
			-- come, so say what that means instead of leaving the map silently
			-- empty. labels()/label_name need Home Assistant 2024.4 or newer.
			gTemplateId = nil
			if (msg.error and msg.error.code == 'reset') then return end -- reconnect flush; the refetch re-sends
			print ('openhac4: Home Assistant rejected the area-map template (' ..
				tostring (msg.error and msg.error.message or 'unknown error') ..
				'); imported devices will go to the gateway\'s room and label ' ..
				'filters will not match. Labels need Home Assistant 2024.4 or newer.')
		end)
end

-- Parse the rendered area map (called from processMessage for the template
-- event) and stop the subscription.
function applyAreaMap (rendered)
	local n = 0
	-- Home Assistant may deliver the render as a JSON string, or already decoded
	-- into a structure by its native-type handling, so accept either.
	local rows = rendered
	if (type (rows) ~= 'table') then
		rows = jsonDecode (tostring (rendered or ''))
	end
	if (type (rows) ~= 'table') then
		-- Keep whatever map we already had: a failed render should not discard a
		-- good map and silently send the next import to the gateway's room.
		print ('openhac4: could not read the area map from Home Assistant; ' ..
			'keeping the previous map. If this is the first render, imported ' ..
			'devices will go to the gateway\'s room and label filters will not match')
	else
		gEntityArea = {}
		gEntityLabels = {}
		for _, row in ipairs (rows) do
			local eid = (type (row) == 'table') and row.e
			if (type (eid) == 'string' and eid ~= '') then
				if (type (row.a) == 'string' and row.a ~= '') then
					gEntityArea [eid] = row.a
					n = n + 1
				end
				if (type (row.l) == 'table' and next (row.l) ~= nil) then
					local set = {}
					for _, lbl in ipairs (row.l) do
						if (lbl ~= nil and lbl ~= '') then set [tostring (lbl)] = true end
					end
					if (next (set) ~= nil) then gEntityLabels [eid] = set end
				end
			end
		end
	end
	Debug.Info ('area map loaded:', n, 'entities with an area')
	if (gTemplateId) then
		wsSend ({type = 'unsubscribe_events', subscription = gTemplateId})
		gTemplateId = nil
	end
end

function subscribeAndFetch ()
	wsSend ({type = 'subscribe_events', event_type = 'state_changed'}, function (msg)
		if (msg.success) then return end
		if (msg.error and msg.error.code == 'reset') then return end -- reconnect flush
		-- an authed session without the subscription looks fully healthy but
		-- no state change ever reaches any child; reconnect rather than sit deaf
		print ('openhac4: Home Assistant refused the state subscription; reconnecting')
		scheduleReconnect ({force = true, reason = 'state subscription refused'})
	end)
	fetchStates ()
	fetchRegistries ()
end

-- Disarm any pending reconnect. Called whenever a connection proves itself, so
-- a retry armed while this attempt was still in flight cannot fire later and
-- tear down the connection that succeeded.
function cancelReconnect ()
	CancelTimer ('Reconnect')
	gReconnectPending = false
end

-- opts.force schedules even while the socket is up, for the case where the
-- transport is fine but the session is not (Home Assistant rejecting our token).
-- opts.reason overrides the text shown alongside the countdown.
function scheduleReconnect (opts)
	opts = opts or {}
	if (gSuppressReconnect) then
		return
	end
	if (not opts.force and gWS and gWS.running) then
		-- The socket is up. A stale OFFLINE from the NetDisconnect that precedes
		-- every NetConnect must not arm a retry against a live connection.
		return
	end
	if (gReconnectPending) then
		return -- already armed; a duplicate OFFLINE must not re-arm or double the backoff
	end
	-- Carry a reason into the status. Without it every cause (wrong address,
	-- blocked port, TLS refusal, rejected upgrade, bad token) shows the
	-- identical countdown and the dealer has nothing to work from.
	local why = opts.reason or (gWS and gWS.lastFailure)
	-- An oversized state payload fails identically on every attempt, and each
	-- attempt re-downloads megabytes just to hit the same wall. Back way off so
	-- the condition is visible and cheap instead of a 60-second hammer loop.
	if (why and tostring (why):find ('exceeds max size', 1, true)) then
		gReconnectDelay = math.max (gReconnectDelay, 600)
	end
	local suffix = (why and (' - ' .. tostring (why))) or ''
	setStatus ('Disconnected - Reconnecting in ' .. gReconnectDelay .. 's' .. suffix)
	local timer = SetTimer ('Reconnect', gReconnectDelay * ONE_SECOND, function ()
		Connect ()
	end)
	if (not timer) then
		-- Claiming a reconnect is pending when no timer exists would park the
		-- driver for good: every later call returns early on the flag and nothing
		-- would ever fire. Leave the flag clear so the next OFFLINE can retry.
		print ('openhac4: could not arm the reconnect timer; will retry on the next disconnect')
		return
	end
	gReconnectPending = true
	gReconnectDelay = math.min (gReconnectDelay * 2, 60)
end

function processMessage (ws, data)
	local msg = jsonDecode (data)
	if (not msg) then
		print ('openhac4: undecodable message from Home Assistant (' ..
			#tostring (data) .. ' bytes)')
		return
	end

	local msgType = msg.type

	if (msgType == 'auth_required') then
		setStatus ('Connected - Authenticating')
		wsSendRaw ({type = 'auth', access_token = gToken or ''}, true)
		Debug.Trace ('TX auth (token redacted)')

	elseif (msgType == 'auth_ok') then
		CancelTimer ('Handshake')
		cancelReconnect () -- belt and braces: nothing should retry over a live session
		gAuthed = true
		gReconnectDelay = RECONNECT_START_DELAY
		gHAVersion = msg.ha_version or ''
		UpdateProperty ('Home Assistant Version', gHAVersion)
		setStatus ('Connected - Authenticated')
		requestChildrenReregister ()
		broadcastGatewayStatus ('online')
		subscribeAndFetch ()

	elseif (msgType == 'auth_invalid') then
		-- Usually a bad token, but HA restarting mid-handshake can also cause
		-- this transiently. Retry slowly instead of parking permanently, so a
		-- transient recovers on its own; a truly bad token just shows the
		-- status and retries harmlessly.
		CancelTimer ('Handshake')
		gAuthed = false
		gReconnectDelay = 60
		-- force: the transport is healthy here, only the session was refused, so
		-- the running-socket guard would otherwise suppress the retry entirely
		-- and a mistyped token would never recover on its own.
		scheduleReconnect {force = true, reason = 'authentication failed, check the Access Token'}

	elseif (msgType == 'result') then
		-- Indexing gPending with a nil id would throw ("table index is nil" on
		-- assignment, even when assigning nil), so a result frame with no id must
		-- not reach the lookup. HA always sends one; a malformed peer might not.
		local cb
		if (type (msg.id) == 'number') then
			cb = gPending [msg.id]
			gPending [msg.id] = nil
		end
		if (not msg.success) then
			local err = (msg.error and ((msg.error.code or '') .. ' ' .. (msg.error.message or ''))) or 'unknown error'
			print ('openhac4: HA rejected request ' .. tostring (msg.id) .. ': ' .. err)
		end
		if (cb) then
			pcall (cb, msg)
		end

	elseif (msgType == 'event') then
		-- the area-map render_template pushes its value as an event on our
		-- template id; everything else is a state_changed event
		if (gTemplateId and msg.id == gTemplateId) then
			applyAreaMap (msg.event and msg.event.result)
		else
			handleEvent (msg.event)
		end
	end
end

function Connect ()
	CancelTimer ('Reconnect')
	-- and any prior attempt's handshake watchdog: an early return below (blank
	-- token, invalid address) would otherwise leave it armed to fire a bogus
	-- "handshake timed out" over the Not Configured status
	CancelTimer ('Handshake')
	gReconnectPending = false
	gAuthed = false
	-- fail outstanding request callbacks rather than dropping them: a child
	-- waiting on a browse reply would otherwise hang its Navigator screen
	-- across every reconnect. Snapshot first: mutating gPending inside a
	-- callback while pairs() walks it is undefined behavior in Lua 5.1.
	local pending = {}
	for _, cb in pairs (gPending or {}) do pending [#pending + 1] = cb end
	gPending = {}
	for _, cb in ipairs (pending) do
		pcall (cb, {success = false, error = {code = 'reset', message = 'connection reset'}})
	end
	gSuppressReconnect = false

	-- tear the old socket down first, so an invalid new config never leaves a
	-- prior authenticated connection alive feeding stale state to children
	if (gWS) then
		gWS = gWS:delete ()
	end

	-- trim whitespace: browser-copied tokens/addresses often carry a newline
	local function trim (s) return (tostring (s or ''):gsub ('^%s+', ''):gsub ('%s+$', '')) end
	local addr = trim (Properties ['Home Assistant Address'])
	local portStr = trim (Properties ['Port'])
	if (portStr == '') then portStr = '8123' end
	local token = trim (Properties ['Access Token'])

	if (addr == '') then
		setStatus ('Not Configured - enter Home Assistant Address')
		broadcastGatewayStatus ('offline')
		return
	end
	if (token == '') then
		gToken = nil -- a cleared token must not survive in memory
		setStatus ('Not Configured - enter Access Token')
		broadcastGatewayStatus ('offline')
		return
	end
	gToken = token

	local port = tonumber (portStr)
	if (not port or port < 1 or port > 65535 or port ~= math.floor (port)) then
		setStatus ('Invalid Port')
		broadcastGatewayStatus ('offline')
		return
	end
	-- only a bare host is valid; a pasted scheme/path breaks the URL
	if (addr:find ('/') or addr:find ('\\') or addr:find ('%s')) then
		setStatus ('Invalid Address - use host or IP only, no http:// or path')
		broadcastGatewayStatus ('offline')
		return
	end
	-- A colon is the common paste: Home Assistant displays itself as host:8123,
	-- and appending our own port to that yields host:8123:8123, whose bad
	-- handshake target every server rejects with no clue why. An IPv6 literal
	-- is the one legitimate colon-bearing address; require the bracketed form
	-- ([fd00::5]) so it cannot be confused with a host:port paste.
	if (addr:find ('^%[.+%]$')) then
		-- bracketed IPv6: pass through as-is, the socket layer parses it
	elseif (addr:find (':')) then
		setStatus ('Invalid Address - remove the port and set it in the Port property. For IPv6, use brackets: [fd00::5]')
		broadcastGatewayStatus ('offline')
		return
	end

	local ssl = (Properties ['Use SSL'] == 'On')
	local scheme = (ssl and 'wss') or 'ws'
	local url = scheme .. '://' .. addr .. ':' .. port .. '/api/websocket'

	-- SSL options: modern TLS; verify the peer only when the dealer opts in
	-- (most Home Assistant installs use HTTP or a self-signed cert)
	local wssOptions = nil
	if (ssl) then
		wssOptions = {VERIFY_METHOD = 'tlsv1_2'}
		if (Properties ['Verify Certificate'] == 'On') then
			wssOptions.VERIFY_MODE = 'peer'
		else
			wssOptions.VERIFY_MODE = 'none'
		end
	end

	setStatus ('Connecting')
	gWS = WebSocket:new (url, nil, wssOptions)
	if (not gWS) then
		-- new() returns nil either because the URL would not parse or because no
		-- network binding was free. The first is a config error, the second is
		-- transient (a long outage can burn bindings faster than they release).
		-- We cannot tell them apart here, and scheduling a retry recovers the
		-- transient case while costing nothing in the config case, where the
		-- retry simply fails the same way instead of parking the driver forever.
		setStatus ('Cannot Open Socket')
		scheduleReconnect ()
		return
	end

	gWS:SetProcessMessageFunction (processMessage)
	gWS:SetEstablishedFunction (function ()
		-- The websocket handshake completed, so this attempt is real. Disarm any
		-- retry armed earlier in the attempt (Start() issues a NetDisconnect
		-- before NetConnect, and a controller that echoes OFFLINE for it arms one
		-- at t=0) before it can fire and kill this connection.
		cancelReconnect ()
		setStatus ('Connected - Waiting for Auth Request')
	end)
	gWS:SetOfflineFunction (function ()
		CancelTimer ('Handshake')
		if (gAuthed) then
			broadcastGatewayStatus ('offline')
		end
		gAuthed = false
		-- the cache is now a pre-disconnect snapshot; do not push it to a child
		-- that re-registers before the next get_states lands
		gStatesLoaded = false
		scheduleReconnect ()
	end)
	gWS:SetClosedByRemoteFunction (function ()
		CancelTimer ('Handshake')
		if (gAuthed) then
			broadcastGatewayStatus ('offline')
		end
		gAuthed = false
		-- Close() drives NetDisconnect, which fires the Offline handler and
		-- schedules the reconnect. Scheduling here too would double-count the
		-- backoff, so we do not.
		if (gWS) then
			gWS:Close ()
		end
	end)
	gWS:Start ()

	-- handshake watchdog: if we do not reach auth_ok in 20s (dead port, a
	-- reverse proxy that answers but never upgrades, etc.), force a reconnect
	-- instead of sitting on "Connecting" forever.
	SetTimer ('Handshake', 20 * ONE_SECOND, function ()
		if (not gAuthed) then
			print ('openhac4: handshake timed out, reconnecting')
			if (gWS) then gWS:Close () end
			scheduleReconnect ()
		end
	end)
end

do -- messages from child drivers

	-- A freshly imported child asks for the entity it was created for. This
	-- makes entity assignment independent of add/init timing.
	EC.OPENHAC4_CLAIM = function (tParams)
		local deviceId = tonumber (tParams.device_id)
		if (not deviceId) then
			return
		end
		local entityId = gPendingImport [deviceId]
		if (entityId) then
			gPendingImport [deviceId] = nil
			gImporting [entityId] = nil
			C4:SendToDevice (deviceId, 'OPENHAC4_SET_ENTITY', {entity_id = entityId, gateway_id = gatewayId ()})
		end
	end

	EC.OPENHAC4_REGISTER = function (tParams)
		local deviceId = tonumber (tParams.device_id)
		local entityId = tParams.entity_id
		if (not (deviceId and entityId)) then
			return
		end

		-- drop any previous registration this child held, pruning empty tables
		local previous = gChildEntities [deviceId]
		if (previous and gRegistrations [previous]) then
			gRegistrations [previous] [deviceId] = nil
			if (next (gRegistrations [previous]) == nil) then
				gRegistrations [previous] = nil
			end
		end

		gChildEntities [deviceId] = entityId
		gRegistrations [entityId] = gRegistrations [entityId] or {}
		gRegistrations [entityId] [deviceId] = true

		-- this child is now configured, so clear any import bookkeeping for it
		gPendingImport [deviceId] = nil
		gImporting [entityId] = nil

		-- Only push once the entity cache is populated. Children re-register the
		-- instant the gateway authenticates, which is well before get_states
		-- returns, so pushing here on an empty cache would synthesize
		-- 'unavailable' and fire an Offline event on every device in the project
		-- after every Director restart or driver update. fetchStates syncs every
		-- registration as soon as the real data lands.
		if (gAuthed and gStatesLoaded) then
			-- a registration for an entity the loaded cache has never seen is
			-- almost always a typo in a manually entered Entity ID; the child
			-- will only ever show 'unavailable', so say what that means here.
			-- Gated on a CHANGED registration: the two-minute re-register tick
			-- must not repeat this forever
			if (gStates [entityId] == nil and previous ~= entityId) then
				print ('openhac4: a child registered for "' .. tostring (entityId) ..
					'", which Home Assistant does not report; check its Entity ID')
			end
			sendStateToChild (deviceId, entityId, gStates [entityId])
		end

		-- Children re-register every two minutes, which doubles as a recovery
		-- tick: if a reconnect timer ever failed to arm (scheduleReconnect
		-- leaves gReconnectPending clear on a SetTimer failure), this is the
		-- recurring path that gets the gateway retrying again. offlineFired
		-- means the socket is definitively dead, not mid-connect, so this never
		-- aborts a healthy in-flight handshake; gWS is nil when the driver is
		-- unconfigured, so it never nags an unconfigured state either.
		if (gWS and gWS.offlineFired and not gWS.running
			and not gReconnectPending and not gSuppressReconnect) then
			scheduleReconnect ()
		end
	end

	EC.OPENHAC4_UNREGISTER = function (tParams)
		local deviceId = tonumber (tParams.device_id)
		if (not deviceId) then
			return
		end
		local entityId = gChildEntities [deviceId]
		gChildEntities [deviceId] = nil
		if (entityId and gRegistrations [entityId]) then
			gRegistrations [entityId] [deviceId] = nil
			-- prune the empty table, as REGISTER does: otherwise every child ever
			-- removed leaves a dead entity that fetchStates re-walks forever
			if (next (gRegistrations [entityId]) == nil) then
				gRegistrations [entityId] = nil
			end
		end
	end

	EC.OPENHAC4_GET_ENTITIES = function (tParams)
		local deviceId = tonumber (tParams.device_id)
		local domain = tParams.domain
		if (not deviceId) then
			return
		end

		local ids = {}
		for entityId in pairs (gStates) do
			if (domain == nil or entityDomain (entityId) == domain) then
				table.insert (ids, entityId)
			end
		end
		table.sort (ids)
		-- Same reasoning as BROWSE_MAX_CHILDREN: this whole list travels as one
		-- SendToDevice parameter, which truncates silently when it is too long.
		-- Trim deterministically and say so, rather than shipping a picker that
		-- is quietly short or cut mid-entity-id.
		local dropped = 0
		if (#ids > ENTITY_LIST_MAX) then
			dropped = #ids - ENTITY_LIST_MAX
			for i = #ids, ENTITY_LIST_MAX + 1, -1 do ids [i] = nil end
		end
		if (dropped > 0) then
			print ('openhac4: entity list for ' .. tostring (domain or 'all') ..
				' trimmed to ' .. ENTITY_LIST_MAX .. '; ' .. dropped ..
				' not offered. Type the entity id into Entity ID instead.')
		end
		C4:SendToDevice (deviceId, 'OPENHAC4_ENTITIES', {entities = table.concat (ids, ','), gateway_id = gatewayId ()})
	end

	EC.OPENHAC4_CALL_SERVICE = function (tParams)
		Debug.Info ('call_service from child:', tostring (tParams.domain) .. '.' .. tostring (tParams.service), 'ent', tostring (tParams.entity_id))
		if (not gAuthed) then
			print ('openhac4: service call dropped - not connected to Home Assistant')
			return
		end

		-- Consistency check, NOT a security boundary: the caller must be a
		-- registered openhac4 child and may only act on the entity it registered,
		-- in that entity's domain. It catches a malformed or stale child message.
		-- It stops nothing hostile, because C4:SendToDevice carries no verified
		-- sender identity and device_id is supplied by the caller. Any driver in
		-- the project can register an entity and then act on it. The real trust
		-- model is Control4's: every driver a dealer installs is trusted, and all
		-- of them inherit this gateway's Home Assistant authority. Documented for
		-- dealers in www/documentation.html.
		local deviceId = tonumber (tParams.device_id)
		local entityId = tParams.entity_id
		if (not (deviceId and entityId and gChildEntities [deviceId] == entityId)) then
			print ('openhac4: service call rejected - sender is not the registered child for ' .. tostring (entityId))
			return
		end
		if (tParams.domain ~= entityDomain (entityId)) then
			print ('openhac4: service call rejected - domain does not match entity')
			return
		end

		local serviceData = Deserialize (tParams.data or '')
		if (type (serviceData) ~= 'table') then
			serviceData = {}
		end
		local svc = tParams.service
		wsSend ({
			type = 'call_service',
			domain = tParams.domain,
			service = svc,
			service_data = serviceData,
			target = {entity_id = tParams.entity_id},
		}, function (msg)
			-- report a rejected service call back to the requesting child so it
			-- can surface the failure (e.g. alarm ARM_FAILED / DISARM_FAILED)
			if (not msg.success) then
				C4:SendToDevice (deviceId, 'OPENHAC4_SERVICE_RESULT', {
					service = svc,
					success = 'false',
					error = (msg.error and msg.error.message) or 'call failed',
					gateway_id = gatewayId (),
				})
			end
		end)
	end

	-- Relay a media browse request (media_service child) to Home Assistant and
	-- return the tree to the requesting child. Same trusted-child validation as
	-- OPENHAC4_CALL_SERVICE: the caller must be the registered child for the
	-- entity it names. Read-only, but validated for consistency.
	EC.OPENHAC4_BROWSE = function (tParams)
		if (not gAuthed) then
			print ('openhac4: browse dropped - not connected to Home Assistant')
			return
		end
		local deviceId = tonumber (tParams.device_id)
		local entityId = tParams.entity_id
		if (not (deviceId and entityId and gChildEntities [deviceId] == entityId)) then
			print ('openhac4: browse rejected - sender is not the registered child for ' .. tostring (entityId))
			return
		end
		local req = {type = 'media_player/browse_media', entity_id = entityId}
		if (tParams.media_content_id and tParams.media_content_id ~= '') then
			req.media_content_id = tParams.media_content_id
		end
		if (tParams.media_content_type and tParams.media_content_type ~= '') then
			req.media_content_type = tParams.media_content_type
		end
		local token = tParams.token
		wsSend (req, function (msg)
			local ok = (msg.success == true) and (type (msg.result) == 'table')
			-- cap a single browse level so the serialized payload cannot exceed
			-- the inter-driver message limit and get silently truncated; log the
			-- drop so a trimmed library is never mistaken for a complete one
			if (ok and type (msg.result.children) == 'table' and #msg.result.children > BROWSE_MAX_CHILDREN) then
				local n = #msg.result.children
				for i = n, BROWSE_MAX_CHILDREN + 1, -1 do msg.result.children[i] = nil end
				-- flag it so the child can show a truncation row instead of the
				-- list silently appearing complete
				msg.result.truncated = true
				Debug.Warn ('browse: truncated', n, 'children to', BROWSE_MAX_CHILDREN, 'for', entityId)
			end
			local body = ok and Serialize (msg.result) or ''
			-- byte budget on top of the row cap: halve the children until the
			-- serialized payload fits (see BROWSE_MAX_BYTES)
			while (ok and #body > BROWSE_MAX_BYTES and
					type (msg.result.children) == 'table' and #msg.result.children > 1) do
				local n = #msg.result.children
				local keep = math.floor (n / 2)
				for i = n, keep + 1, -1 do msg.result.children [i] = nil end
				msg.result.truncated = true
				Debug.Warn ('browse: payload over byte budget; halved children to', keep, 'for', entityId)
				body = Serialize (msg.result)
			end
			C4:SendToDevice (deviceId, 'OPENHAC4_BROWSE_RESULT', {
				token = token,
				success = ok and 'true' or 'false',
				result = body,
				error = (not ok) and ((msg.error and msg.error.message) or 'browse failed') or '',
				gateway_id = gatewayId (),
			})
		end)
	end
end

do -- Room-aware import (Lutron-style: Add Rooms, then Import Devices)

	-- entity_ids that already have a child driver (any domain)
	local function claimedEntities ()
		local claimed = {}
		for _, c4zName in ipairs (ALL_CHILD_C4Z) do
			for deviceId in pairs (C4:GetDevicesByC4iName (c4zName) or {}) do
				local entityId = C4:GetDeviceVariable (deviceId, ENTITY_ID_VAR)
				if (entityId and entityId ~= '') then
					claimed [entityId] = true
				end
			end
		end
		return claimed
	end

	-- strip control chars and cap length before a name becomes a project object
	local function sanitizeName (name)
		name = tostring (name or ''):gsub ('[%c]', ' ')
		if (#name > 60) then name = string.sub (name, 1, 60) end
		return name
	end

	local function friendlyName (state, entityId)
		local name = state and state.attributes and state.attributes.friendly_name
		if (name and name ~= '') then
			return sanitizeName (name)
		end
		return entityId
	end

	-- Find the floor to parent new rooms under. In GetProjectHierarchy the
	-- location type is a NUMBER: 2=Site, 3=Building, 4=Floor, 8=Room. A project
	-- can have several floors; prefer one named "Main", otherwise the lowest
	-- id for a deterministic choice.
	local LOCATION_TYPE_FLOOR = 4
	local function findFloor (node)
		local floors = {}
		local function walk (n)
			if (type (n) ~= 'table') then return end
			for id, child in pairs (n) do
				if (type (child) == 'table') then
					if (tonumber (child.type) == LOCATION_TYPE_FLOOR) then
						table.insert (floors, {id = tonumber (id) or id, name = tostring (child.name or '')})
					end
					walk (child)
				end
			end
		end
		walk (node)
		if (#floors == 0) then return nil end
		table.sort (floors, function (a, b) return tostring (a.id) < tostring (b.id) end)
		for _, f in ipairs (floors) do
			if (f.name:lower () == 'main') then return f.id end
		end
		return floors [1].id
	end

	-- True if the given location id still exists anywhere in the hierarchy.
	local function roomStillExists (node, roomId)
		if (type (node) ~= 'table') then
			return false
		end
		for id, child in pairs (node) do
			if (tostring (id) == tostring (roomId)) then
				return true
			end
			if (type (child) == 'table') then
				if (roomStillExists (child.children or child, roomId)) then
					return true
				end
			end
		end
		return false
	end

	-- Build the working list of entities to import, honoring the domain,
	-- area, and label filters from the action dialog. filters = {domain,
	-- area, label}. Returns a list of {entityId, c4z, name, roomId}.
	local function selectEntities (filters)
		local claimed = claimedEntities ()
		-- entities added by a prior import but not yet claimed by their child
		-- (the child writes ENTITY_ID_VAR only after it initializes). Without
		-- this, a second import in that window re-adds them, and a child whose
		-- c4z never initializes would be duplicated on every subsequent run.
		local pending = {}
		for _, entityId in pairs (gPendingImport) do pending [entityId] = true end
		local domainFilter = filters.domain
		if (domainFilter == nil or domainFilter == '' or domainFilter == 'All Supported') then domainFilter = nil end
		local areaFilter = filters.area
		if (areaFilter == nil or areaFilter == '' or areaFilter == 'All Areas') then areaFilter = nil end
		local labelFilter = filters.label or ''
		local defaultRoom = C4:RoomGetId ()

		-- validate mapped rooms once against the live project; a room deleted
		-- in Composer falls back to the gateway's room rather than failing
		local rooms = {}
		local hierarchy = C4:GetProjectHierarchy ()
		for area, roomId in pairs ((PersistData and PersistData.AreaRooms) or {}) do
			if (roomStillExists (hierarchy, roomId)) then
				rooms [area] = roomId
			end
		end

		local list = {}
		for entityId, state in pairs (gStates) do
			local domain = entityDomain (entityId)
			local c4z = DOMAIN_DRIVERS [domain]
			-- garage covers get the dedicated garage-door driver, not the blind
			if (domain == 'cover' and state.attributes and state.attributes.device_class == 'garage') then
				c4z = DOMAIN_DRIVERS.garage
			end
			if (c4z and not claimed [entityId] and not gImporting [entityId] and not pending [entityId]) then
				local area = gEntityArea [entityId]
				local ok = true
				if (domainFilter and domain ~= domainFilter) then ok = false end
				if (areaFilter and area ~= areaFilter) then ok = false end
				if (labelFilter ~= '' and not (gEntityLabels [entityId] and gEntityLabels [entityId] [labelFilter])) then ok = false end
				-- diagnostic/text sensors with no unit are noise
				if (domain == 'sensor') then
					local unit = state.attributes and state.attributes.unit_of_measurement
					if (unit == nil or unit == '') then ok = false end
				end
				if (ok) then
					table.insert (list, {
						entityId = entityId,
						c4z = c4z,
						name = friendlyName (state, entityId),
						area = area,
						roomId = (area and rooms [area]) or defaultRoom,
					})
				end
			end
		end
		-- stable order so Preview matches the import order
		table.sort (list, function (a, b) return a.entityId < b.entityId end)
		return list
	end

	EC.ImportRooms = function ()
		if (not VersionCheck ('3.4.0')) then
			print ('openhac4: Import Rooms requires Control4 OS 3.4.0 or later')
			return
		end
		if (not gAuthed) then
			print ('openhac4: not connected to Home Assistant')
			return
		end
		if (#gAreaNames == 0) then
			print ('openhac4: no Home Assistant areas found (registries still loading, or none defined)')
			return
		end
		local floorId = findFloor (C4:GetProjectHierarchy ())
		if (not floorId) then
			print ('openhac4: could not find a floor to add rooms to')
			return
		end

		-- refuse a pathological area registry outright: room creation is
		-- synchronous, uncapped it would wedge Director, and rooms cannot be
		-- bulk-removed by this driver afterward
		if (#gAreaNames > 500) then
			print ('openhac4: Import Rooms refused - Home Assistant reports ' ..
				#gAreaNames .. ' areas, which exceeds the 500-room safety cap')
			return
		end

		PersistData.AreaRooms = PersistData.AreaRooms or {}
		local hierarchy = C4:GetProjectHierarchy ()

		-- drop stale mappings whose room was deleted
		for area, roomId in pairs (PersistData.AreaRooms) do
			if (not roomStillExists (hierarchy, roomId)) then
				PersistData.AreaRooms [area] = nil
			end
		end

		local created, reused = 0, 0
		for _, area in ipairs (gAreaNames) do
			if (PersistData.AreaRooms [area]) then
				reused = reused + 1
			else
				local roomId = C4:AddLocation (floorId, sanitizeName (area), 'ROOM')
				if (roomId and roomId ~= 0) then
					PersistData.AreaRooms [area] = roomId
					created = created + 1
				else
					print ('openhac4: failed to create room for area ' .. area)
				end
			end
		end
		print ('openhac4: Import Rooms complete - ' .. created .. ' created, ' .. reused .. ' already present')
	end

	-- Add the queued devices one at a time. Each add takes real time in
	-- Director, so we stagger to avoid flooding it; large imports are meant
	-- to run unattended. Entity assignment does not depend on this timing:
	-- the callback records a pending assignment and the child claims it in
	-- its own init (OPENHAC4_CLAIM), so a slow-loading child still gets set.
	local function importNext ()
		CancelTimer ('ImportWedge')
		-- from the front, so the add order matches the sorted Preview order
		local item = table.remove (gImportQueue, 1)
		if (not item) then
			gImportRunning = false
			gImporting = {}
			print ('openhac4: Import Devices complete')
			return
		end

		-- watchdog: if the AddDevice callback never fires (Director hiccup,
		-- c4z missing, project locked), advance anyway rather than wedging
		-- the whole import with gImportRunning stuck true.
		SetTimer ('ImportWedge', 30 * ONE_SECOND, function ()
			print ('openhac4: import step timed out, continuing')
			importNext ()
		end)

		local entityId = item.entityId
		C4:AddDevice (item.c4z, item.roomId, item.name, function (deviceId)
			if (deviceId and deviceId ~= 0) then
				gPendingImport [deviceId] = entityId
				C4:Bind (C4:GetDeviceID (), OPENHAC4_BINDING, deviceId, OPENHAC4_BINDING, 'OPENHAC4')
				C4:SendToDevice (deviceId, 'OPENHAC4_SET_ENTITY', {entity_id = entityId, gateway_id = gatewayId ()})
			else
				print ('openhac4: failed to add driver for ' .. entityId)
				gImporting [entityId] = nil
			end
			SetTimer ('ImportNext', IMPORT_STAGGER_SECONDS * ONE_SECOND, importNext)
		end)
	end

	local function runImport (previewOnly, filters)
		if (not previewOnly and not VersionCheck ('3.4.0')) then
			print ('openhac4: Import Devices requires Control4 OS 3.4.0 or later')
			return
		end
		if (not gAuthed) then
			print ('openhac4: not connected to Home Assistant')
			return
		end
		if (not previewOnly and gImportRunning) then
			print ('openhac4: import already running - wait for it to finish')
			return
		end

		local list = selectEntities (filters)

		if (#list == 0) then
			print ('openhac4: nothing to import (all matching entities already added, or filters exclude everything)')
			return
		end

		-- preview is inspection only, so it is never blocked by the cap
		if (previewOnly) then
			print ('openhac4: Preview - would import ' .. #list .. ' devices:')
			for _, item in ipairs (list) do
				print (string.format ('  %-55s -> %s', item.entityId, item.area or '(gateway room)'))
			end
			if (#list > filters.max) then
				print ('openhac4: note - ' .. #list .. ' exceeds Max of ' .. filters.max .. '; raise Max to import them all')
			end
			return
		end

		if (#list > filters.max) then
			print ('openhac4: ' .. #list .. ' entities match, exceeds Max of ' .. filters.max ..
				'. Narrow the Domain / Area / Label, or raise Max (No Limit imports all).')
			return
		end

		-- mark everything in-flight up front so a second run cannot duplicate
		gImportQueue = list
		for _, item in ipairs (list) do
			gImporting [item.entityId] = true
		end
		gImportRunning = true
		print ('openhac4: importing ' .. #list .. ' devices, roughly ' ..
			math.ceil (#list * IMPORT_STAGGER_SECONDS / 60) .. ' min - safe to leave running')
		importNext ()
	end

	EC.ImportDevices = function (tParams)
		tParams = tParams or {}
		local maxRaw = tParams.Max
		local cap
		if (maxRaw == 'No Limit') then
			cap = math.huge
		elseif (maxRaw == nil or maxRaw == '') then
			cap = 150 -- an untouched Max defaults to a safe ceiling, not unlimited
		else
			cap = tonumber (maxRaw) or 150
		end
		local filters = {
			domain = tParams.Domain,
			area = tParams.Area,
			label = tParams.Label,
			max = cap,
		}
		local previewOnly = (tParams.Mode ~= 'Import')
		runImport (previewOnly, filters)
	end
end

-- CUSTOM_SELECT source for the Import Devices dialog's Area param
function GetImportAreas ()
	local list = {'All Areas'}
	for _, a in ipairs (gAreaNames) do
		table.insert (list, a)
	end
	return list
end

do -- composer actions
	-- Generic HA service call from Composer programming/actions. Sender
	-- validation is omitted deliberately: like every other driver->gateway
	-- command this is reachable via SendToDevice, but C4's trusted-driver
	-- model already governs that boundary (the validated child path is itself
	-- bypassable), so validating here would add no real security. Covers
	-- scenes/scripts/automations and any entity without a dedicated child.
	-- Reachable two ways with one implementation: the Actions tab sends
	-- LUA_ACTION with ACTION='CallService', while the Programming command
	-- 'Call Service' normalizes to Call_Service. Alias below.
	EC.CallService = function (tParams)
		local function trim (s) return (tostring (s or ''):gsub ('^%s*(.-)%s*$', '%1')) end
		local domain, service = trim (tParams.Domain), trim (tParams.Service)
		if (domain == '' or service == '') then
			print ('openhac4: Call Service needs both a Domain and a Service')
			return
		end
		if (not gAuthed) then
			print ('openhac4: Call Service dropped - not connected to Home Assistant')
			return
		end
		-- Data (optional): a JSON object of service_data, e.g. {"brightness":128}
		local data, raw = {}, trim (tParams.Data)
		if (raw ~= '') then
			local ok, decoded = pcall (function () return C4:JsonDecode (raw) end)
			if (ok and type (decoded) == 'table') then
				data = decoded
			else
				-- length only, never the content: a dealer hand-typing Data can easily
				-- include a code or key, and a JSON typo must not echo it to the log
				print ('openhac4: Call Service - Data is not valid JSON (' ..
					#tostring (raw) .. ' characters), ignoring')
			end
		end
		local msg = {type = 'call_service', domain = domain, service = service, service_data = data}
		local entity = trim (tParams.Entity)
		if (entity ~= '') then msg.target = {entity_id = entity} end
		wsSend (msg)
		Debug.Info ('Call Service', domain .. '.' .. service, 'entity', (entity ~= '' and entity) or '(none)')
	end

	EC.Call_Service = EC.CallService

	EC.Connect = function ()
		gReconnectDelay = RECONNECT_START_DELAY
		Connect ()
	end

	EC.DiscoverDevices = function ()
		if (gAuthed) then
			fetchStates ()
			-- also re-read areas and labels: they are otherwise a connect-time
			-- snapshot, so an area added in Home Assistant after the gateway
			-- connected would never appear in Import Rooms or the Area filter,
			-- and this action is where a dealer looks for exactly that refresh
			fetchRegistries ()
		else
			print ('openhac4: not connected to Home Assistant')
		end
	end

	EC.DisplayDevices = function ()
		local ids = {}
		for id in pairs (gStates) do
			table.insert (ids, id)
		end
		table.sort (ids)
		print ('openhac4: ' .. #ids .. ' entities known')
		for _, id in ipairs (ids) do
			local st = gStates [id]
			print (string.format ('%-60s %s', id, tostring (st.state)))
		end
	end

	EC.DisplayDiagnostics = function ()
		local pendingCount = 0
		for _ in pairs (gPending) do
			pendingCount = pendingCount + 1
		end
		local childCount = 0
		for _ in pairs (gChildEntities) do
			childCount = childCount + 1
		end

		print ('--- openhac4 gateway diagnostics ---')
		print ('URL:               ' .. ((gWS and gWS.url) or 'not connected'))
		print ('Net binding:       ' .. ((gWS and tostring (gWS.netBinding)) or 'none'))
		print ('Socket connected:  ' .. tostring (gWS and gWS.connected or false))
		print ('WS running:        ' .. tostring (gWS and gWS.running or false))
		print ('Authenticated:     ' .. tostring (gAuthed))
		print ('HA version:        ' .. gHAVersion)
		print ('Entities cached:   ' .. tostring (gEntityCount))
		print ('Registered children: ' .. tostring (childCount))
		print ('Reconnect delay:   ' .. tostring (gReconnectDelay) .. 's')
		print ('Pending requests:  ' .. tostring (pendingCount))
		for deviceId, entityId in pairs (gChildEntities) do
			print (string.format ('  child %-8s -> %s', tostring (deviceId), entityId))
		end
	end
end

do -- property change handlers (spaces become underscores in the OPC keys)
	-- Director replays OnPropertyChanged for every property at load, before
	-- OnDriverLateInit runs. Reconnecting on each of those replays would build
	-- and tear down five sockets per load, each taking a separate network
	-- binding that is only released seconds later, and all of it before the
	-- logging config is live so none of it is visible. Connect once, from
	-- OnDriverLateInit; only respond to genuine edits after that.
	local function reconnectOnEdit ()
		if (gLateInitDone) then
			Connect ()
		end
	end

	OPC.Home_Assistant_Address = reconnectOnEdit
	OPC.Port = reconnectOnEdit
	OPC.Use_SSL = reconnectOnEdit
	OPC.Verify_Certificate = reconnectOnEdit
	OPC.Access_Token = reconnectOnEdit

	-- logging property handlers (Log Mode / Log Level / Log Auto Off
	-- Minutes) are registered by the debug module itself
end

do -- update check (opt-in, default Off; one HTTPS GET to api.github.com)
	local UPDATE_API = 'https://api.github.com/repos/cajunflavoredbob/openhac4/releases/latest'

	gUpdateStatus = nil -- suffix shown after the version in Driver Version

	local function driverSemver ()
		local semver
		pcall (function () semver = C4:GetDriverConfigInfo ('semver') end)
		return tostring (semver or '')
	end

	function ShowDriverVersion ()
		local v = driverSemver ()
		UpdateProperty ('Driver Version', v .. (gUpdateStatus or ''))
	end

	-- true when remote (x.y.z) is newer than local, compared component-wise
	local function isNewer (remote, current)
		local r = {remote:match ('^(%d+)%.(%d+)%.(%d+)')}
		local c = {current:match ('^(%d+)%.(%d+)%.(%d+)')}
		if (#r < 3 or #c < 3) then return false end
		for i = 1, 3 do
			local rn, cn = tonumber (r [i]), tonumber (c [i])
			if (rn > cn) then return true end
			if (rn < cn) then return false end
		end
		return false
	end

	function CheckForUpdate ()
		if (Properties ['Check for Updates'] ~= 'On') then return end
		local ok = pcall (function ()
			-- api.github.com rejects requests without a User-Agent
			C4:urlGet (UPDATE_API, {
				['User-Agent'] = 'openhac4',
				['Accept'] = 'application/vnd.github+json',
			}, false, function (ticket, data, responseCode)
				-- late reply after the dealer turned the check off: discard
				if (Properties ['Check for Updates'] ~= 'On') then return end
				local tag
				if (responseCode == 200 and type (data) == 'string') then
					local msg = jsonDecode (data)
					tag = msg and type (msg.tag_name) == 'string'
						and msg.tag_name:gsub ('^v', '') or nil
				end
				if (not tag) then
					gUpdateStatus = ' (Update check failed)'
					Debug.Warn ('update check failed: HTTP', tostring (responseCode))
				elseif (isNewer (tag, driverSemver ())) then
					gUpdateStatus = ' (Update available: ' .. tag .. ')'
					print ('openhac4: update available: ' .. tag)
				else
					gUpdateStatus = ' (Up to Date)'
				end
				ShowDriverVersion ()
			end)
		end)
		if (not ok) then
			gUpdateStatus = ' (Update check unavailable)'
			ShowDriverVersion ()
		end
	end

	function ArmUpdateCheck ()
		if (Properties ['Check for Updates'] == 'On') then
			CheckForUpdate ()
			SetTimer ('UpdateCheck', ONE_DAY, CheckForUpdate, true)
		else
			CancelTimer ('UpdateCheck')
			gUpdateStatus = nil
			ShowDriverVersion ()
		end
	end

	OPC.Check_for_Updates = function ()
		ArmUpdateCheck ()
	end
end

function OnDriverLateInit ()
	-- Set the gate first, and run the rest under pcall: if any of this throws,
	-- the driver must still be recoverable by editing a config property. With
	-- the gate set last, a throw here left the driver permanently inert with no
	-- dealer-reachable way back short of removing and re-adding it.
	gLateInitDone = true

	local ok, err = pcall (function ()
		PersistData = PersistData or {}
		PersistData.AreaRooms = PersistData.AreaRooms or {}

		local semver
		pcall (function ()
			semver = C4:GetDriverConfigInfo ('semver')
		end)
		if (not semver or semver == '') then
			pcall (function ()
				semver = tostring (C4:GetDriverConfigInfo ('version'))
			end)
		end
		UpdateProperty ('Driver Version', tostring (semver or ''))

		-- sync logging config from saved properties before anything logs
		Debug.SyncFromProperties ()

		Connect ()
		ArmUpdateCheck ()
	end)
	if (not ok) then
		-- surface it: a silently inert driver is undiagnosable
		print ('openhac4: late init error: ' .. tostring (err))
	end
end

function OnDriverDestroyed ()
	-- Stop anything from re-arming a connection while we are tearing down, then
	-- release the socket BEFORE killing timers: delete(immediate) frees the
	-- network binding synchronously, because a deferred teardown timer would
	-- never fire in a Lua state that is being discarded.
	gSuppressReconnect = true
	if (gWS) then
		gWS = gWS:delete (true)
	end
	-- also release any socket replaced moments ago whose deferred teardown has
	-- not run yet; KillAllTimers below would otherwise strand its binding
	WebSocket.DeleteAll ()
	KillAllTimers ()
	-- courtesy last: children show offline instead of stale state. Done after the
	-- socket and timers are released so a throw in here cannot strand a binding.
	broadcastGatewayStatus ('offline')
end
