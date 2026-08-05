-- openhac4 child driver framework
-- Copyright (c) 2026 cajunflavoredbob. Licensed under the MIT License.
--
-- Shared plumbing for every entity child driver: locating the gateway,
-- registering the selected entity, receiving pushed state, and sending
-- service calls back. Drivers call Child.Setup{} once at load time.
--
-- Gateway <-> child messages travel over C4:SendToDevice and land in the
-- receiving driver's ExecuteCommand (EC) table. The OPENHAC4 control binding
-- exists for Composer visibility and Auto Setup, but message routing works
-- by device id so an unbound child still functions.

require ('openhac4.c4handlers')
require ('openhac4.c4timer')
require ('openhac4.c4lib')

local Debug = require ('openhac4.debug')
local Proto = require ('openhac4.protocol')

local Child = {}
Child.Debug = Debug

-- shared with the gateway via openhac4.protocol so they cannot drift
OPENHAC4_BINDING = Proto.BINDING
GATEWAY_C4Z = Proto.GATEWAY_C4Z
ENTITY_ID_VAR = Proto.ENTITY_ID_VAR

local gDomain = nil
local gOnState = nil
local gOnOffline = nil
local gOnReset = nil
local gOnServiceResult = nil
local gOnBrowseResult = nil
local gGatewayId = nil
local gVarsReady = false -- ENTITY_ID exists; set at late-init, gates applyState
local gLastRegisteredEntity = nil
local gUnavailable = nil -- nil until first state; true/false thereafter
local gSeenOnline = false -- true once the entity has been reported available
local gDecodeWarned = false -- latches the undecodable-state warning
local gGatewayOnline = nil -- nil unknown, true/false from gateway broadcast

local jsonEncode = Proto.jsonEncode

-- exposed for drivers that log structured params (e.g. proxy command dumps)
Child.jsonEncode = jsonEncode

-- Trace a proxy command and its params. The encode happens only when level-4
-- logging is actually on: these sit at the top of every control handler, so
-- building the JSON unconditionally is real work per command for no output.
function Child.TraceParams (label, tParams)
	if (Debug.Wants (4)) then
		Debug.Trace (label, jsonEncode (tParams))
	end
end

-- Dynamic per-entity attribute variables: expose every HA attribute as a
-- read-only Control4 programming variable named HA_<UPPER_KEY>. Created on first
-- sight, updated each state, deleted when the entity changes. Naming/denylist
-- are a first pass and open to revision.
local gAttrVars = {} -- variable name -> {t=c4type, k=source HA key, v=last value}
local ATTR_SKIP = {  -- noise attributes not worth a variable
	friendly_name = true, icon = true, supported_features = true,
	attribution = true, entity_picture = true, device_class = true,
	-- high-churn, low-programming-value: skip to spare Director evaluation load
	media_position = true, media_position_updated_at = true,
}

local function attrVarName (key)
	local name = tostring (key):upper ():gsub ('[^%w]', '_')
	return 'HA_' .. name
end

local function attrTypeValue (v)
	local t = type (v)
	if (t == 'number') then return 'NUMBER', v
	elseif (t == 'boolean') then return 'BOOL', (v and 1) or 0
	elseif (t == 'string') then return 'STRING', v
	elseif (t == 'table') then return 'STRING', (Proto.jsonEncode (v) or '') end
	return nil -- nil / unsupported: skip
end

local function addAttrVar (name, vtype)
	C4:AddVariable (name, (vtype == 'STRING') and '' or '0', vtype, true, false)
end

-- Ceiling on how many Home Assistant attributes become Control4 variables for
-- one entity. Attribute names come from Home Assistant, and an integration that
-- folds an id into the key (or a template entity building keys dynamically) can
-- otherwise create Director variables without limit, one per key ever seen.
-- Real entities sit far below this; hitting it means the entity is pathological.
local MAX_ATTR_VARS = 100
local gAttrVarCount = 0
local gAttrVarCapWarned = false

local function applyAttributeVar (key, val)
	local vtype, vval = attrTypeValue (val)
	if (not vtype) then return end
	local name = attrVarName (key)
	local rec = gAttrVars [name]
	if (rec) then
		if (rec.k == nil) then
			rec.k = key -- ownerless record (kept across an entity switch): claim it
		elseif (rec.k ~= key) then
			return -- two HA keys normalize to one name: first key owns it
		end
	end
	if (not rec) then
		if (gAttrVarCount >= MAX_ATTR_VARS) then
			if (not gAttrVarCapWarned) then
				gAttrVarCapWarned = true
				print ('openhac4: attribute variable cap of ' .. MAX_ATTR_VARS ..
					' reached; further attributes are not exposed as variables')
			end
			return
		end
		addAttrVar (name, vtype)
		rec = {t = vtype, k = key}
		gAttrVars [name] = rec
		gAttrVarCount = gAttrVarCount + 1
	elseif (rec.t ~= vtype) then
		-- The attribute changed Lua type. Recreating the variable would mint a
		-- new Control4 variable id and silently break any dealer programming that
		-- references this HA_ variable, so keep the original variable and coerce
		-- the value to its type instead; skip the update if it cannot be coerced.
		if (rec.t == 'STRING') then
			vval = (type (val) == 'table') and (Proto.jsonEncode (val) or '') or tostring (val)
		elseif (rec.t == 'NUMBER') then
			vval = tonumber (val)
		else -- BOOL
			if (type (val) == 'boolean') then
				vval = (val and 1) or 0
			else
				local n = tonumber (val)
				vval = n and ((n ~= 0) and 1 or 0) or nil
			end
		end
		if (vval == nil) then return end
	end
	if (rec.v ~= vval) then -- write only on change (cut Director churn)
		C4:SetVariable (name, vval)
		rec.v = vval
	end
end

local function applyAttributeVars (attributes)
	if (type (attributes) ~= 'table') then return end
	local seen = {}
	for key, val in pairs (attributes) do
		if (not ATTR_SKIP [key]) then
			-- ownership drives `seen`: a colliding non-owner key must not mark
			-- the owner's variable as fresh, or its stale value never clears
			local name = attrVarName (key)
			local rec = gAttrVars [name]
			if (rec == nil or rec.k == nil or rec.k == key) then
				seen [name] = true
			end
			-- one bad attribute (encode throw, type reject) must not abort the
			-- rest of the entity's updates, so isolate each in its own pcall.
			pcall (applyAttributeVar, key, val)
		end
	end
	-- An attribute the entity stopped reporting must not keep serving its old
	-- value to programming (media_title from the previous track). STRING
	-- variables clear to empty; NUMBER/BOOL hold their last value instead,
	-- because a fabricated 0 reads as a legitimate measurement.
	for name, rec in pairs (gAttrVars) do
		if (not seen [name] and rec.t == 'STRING' and rec.v ~= '') then
			pcall (function ()
				C4:SetVariable (name, '')
				rec.v = ''
			end)
		end
	end
end

local function clearAttributeVars ()
	if (C4.DeleteVariable) then
		-- blank before deleting, and keep (ownerless) any record whose delete
		-- throws: dropping it would leave an untracked Director variable stuck
		-- on the old entity's value, with later AddVariable calls for the same
		-- name failing silently
		local kept, keptCount = {}, 0
		for name, rec in pairs (gAttrVars) do
			pcall (function ()
				C4:SetVariable (name, (rec.t == 'STRING') and '' or 0)
				rec.v = (rec.t == 'STRING') and '' or 0
			end)
			local ok = pcall (function () C4:DeleteVariable (name) end)
			if (not ok) then
				rec.k = nil -- ownerless: the next entity's key claims it
				kept [name] = rec
				keptCount = keptCount + 1
			end
		end
		gAttrVars = kept
		gAttrVarCount = keptCount
	else
		-- Cannot delete on this OS build: blank the values but KEEP the
		-- records. Forgetting them while the Director variables live on would
		-- leave stale values showing, and a later AddVariable for the same
		-- name would throw; a tracked record reuses the variable instead.
		for name, rec in pairs (gAttrVars) do
			rec.k = nil -- ownerless: the next entity's key claims it
			pcall (function ()
				C4:SetVariable (name, (rec.t == 'STRING') and '' or 0)
				rec.v = (rec.t == 'STRING') and '' or 0
			end)
		end
	end
	gAttrVarCapWarned = false
end

local gSelfBound = nil -- device id of the gateway this child self-bound to

function Child.FindGateway ()
	-- a bound gateway wins; it is the explicit, multi-gateway-safe answer
	local bound = C4:GetBoundProviderDevice (C4:GetDeviceID (), OPENHAC4_BINDING)
	if (bound and bound ~= 0) then
		return bound
	end
	-- not bound: discover openhac4 gateways by driver name
	local gateways = {}
	for id in pairs (C4:GetDevicesByC4iName (GATEWAY_C4Z) or {}) do
		table.insert (gateways, id)
	end
	if (#gateways == 0) then
		-- no gateway in the project: clear the latch so a replacement gateway
		-- added later gets a fresh self-bind attempt
		gSelfBound = nil
		return nil
	end
	-- Exactly one gateway and we are not bound: self-bind so a manually-added
	-- driver ends up wired like an imported one. With more than one gateway,
	-- leave it unbound rather than guess which is correct; discovery still
	-- returns the first so the driver keeps working either way. The latch is
	-- the bound gateway's device id, so a swap to a DIFFERENT gateway (even
	-- with no zero-gateway interval between ticks) re-binds, and a bind that
	-- threw is retried.
	if (#gateways == 1 and gSelfBound ~= gateways [1]) then
		local ok = pcall (function ()
			C4:Bind (C4:GetDeviceID (), OPENHAC4_BINDING, gateways [1], OPENHAC4_BINDING, 'OPENHAC4')
		end)
		if (ok) then gSelfBound = gateways [1] end
	end
	return gateways [1]
end

function Child.GetEntity ()
	-- The persistent store is the 'Entity ID' string. The 'Entity' dynamic
	-- list is only a picker: DYNAMIC_LIST selections do not survive a driver
	-- reload, so we copy the pick into 'Entity ID' and read from there.
	return Properties ['Entity ID'] or ''
end

function Child.SendToGateway (command, tParams)
	-- resolve fresh on every send, never trust a cached id: SendToDevice to a
	-- deleted device id is a silent no-op, so a gateway replaced after this
	-- cache was set would swallow every command while we report success. The
	-- bound lookup is one cheap API call, and the unbound name-scan self-binds
	-- on its first hit, so repeated sends converge to the cheap path.
	gGatewayId = Child.FindGateway ()
	if (gGatewayId) then
		tParams = tParams or {}
		tParams.device_id = tostring (C4:GetDeviceID ())
		Debug.Trace ('-> gateway', tostring (gGatewayId), command)
		C4:SendToDevice (gGatewayId, command, tParams)
		return true
	end
	Debug.Warn ('SendToGateway: no gateway found for', command)
	return false
end

-- Enter the offline state and fire the driver's offline handler, but only after
-- the entity has been seen online at least once. A reload while the entity or
-- gateway is offline restores an offline state, and running the Offline
-- programming event then would fire on every reboot; a restored state must never
-- run programming. The Entity Status property is set by the caller regardless,
-- so the offline condition is still reflected in the UI.
local function goOffline (state)
	gUnavailable = true
	if (gSeenOnline and gOnOffline) then gOnOffline (state) end
end

function Child.Register ()
	gGatewayId = Child.FindGateway ()

	if (not gGatewayId) then
		-- no gateway in the project: the entity's state can no longer be
		-- trusted, so mark it unavailable rather than showing stale state
		UpdateProperty ('Gateway Status', 'Gateway Not Found')
		if (gUnavailable ~= true and Child.GetEntity () ~= '') then
			UpdateProperty ('Entity Status', 'unavailable')
			goOffline (nil)
		end
		return
	end
	-- the gateway broadcast owns the online/offline wording; don't overwrite
	-- a known-offline state just because the driver exists in the project
	if (gGatewayOnline ~= false) then
		UpdateProperty ('Gateway Status', 'Gateway Found')
	end

	local entity = Child.GetEntity ()

	-- release the old entity if the selection changed, and let the driver
	-- reset any per-entity capability detection it latched
	if (gLastRegisteredEntity and gLastRegisteredEntity ~= entity) then
		Child.SendToGateway ('OPENHAC4_UNREGISTER', {})
		gLastRegisteredEntity = nil
		gUnavailable = nil
		gSeenOnline = false -- the new entity has not been seen online yet
		gDecodeWarned = false -- a new entity gets a fresh chance to report
		if (gOnReset) then gOnReset () end
		clearAttributeVars ()
	end

	if (entity == '') then
		-- keep the ENTITY_ID variable in sync so a released entity is offered
		-- again by the import (claimedEntities reads this variable)
		C4:SetVariable ('ENTITY_ID', '')
		UpdateProperty ('Entity Status', 'No Entity Selected')
		return
	end

	C4:SetVariable ('ENTITY_ID', entity)
	-- honest status until the gateway confirms with a state push
	if (Properties ['Entity Status'] == 'No Entity Selected') then
		UpdateProperty ('Entity Status', 'Waiting for Home Assistant')
	end
	if (Child.SendToGateway ('OPENHAC4_REGISTER', {entity_id = entity, domain = gDomain})) then
		gLastRegisteredEntity = entity
	end
end

function Child.RequestEntityList ()
	if (not Child.SendToGateway ('OPENHAC4_GET_ENTITIES', {domain = gDomain})) then
		print ('openhac4: cannot refresh entity list - gateway not found')
	end
end

function Child.CallService (service, data)
	local entity = Child.GetEntity ()
	if (entity == '') then
		print ('openhac4: ' .. gDomain .. '.' .. service .. ' ignored - no entity selected')
		return
	end
	Debug.Info ('CallService', gDomain .. '.' .. service, 'on', entity)
	-- Serialize (base64) the service data: raw JSON with quotes/braces does
	-- not survive C4:SendToDevice's tParams serialization intact.
	local sent = Child.SendToGateway ('OPENHAC4_CALL_SERVICE', {
		domain = gDomain,
		service = service,
		entity_id = entity,
		data = Serialize (data or {}),
	})
	-- a dropped command must never be silent (default Debug Off)
	if (not sent) then
		print ('openhac4: ' .. gDomain .. '.' .. service .. ' not sent - gateway not found')
		UpdateProperty ('Gateway Status', 'Gateway Not Found')
	end
end

-- Ask the gateway to browse the bound media entity's library (media_service
-- children). The result comes back asynchronously via onBrowseResult, tagged
-- with the opaque token so the caller can match it to the request that made it.
function Child.Browse (mediaContentId, mediaContentType, token)
	local entity = Child.GetEntity ()
	if (entity == '') then
		print ('openhac4: browse ignored - no entity selected')
		return false
	end
	return Child.SendToGateway ('OPENHAC4_BROWSE', {
		entity_id = entity,
		media_content_id = mediaContentId or '',
		media_content_type = mediaContentType or '',
		token = tostring (token or ''),
	})
end

function Child.Setup (opts)
	gDomain = opts.domain
	gOnState = opts.onState
	gOnOffline = opts.onOffline
	gOnReset = opts.onReset
	gOnServiceResult = opts.onServiceResult
	gOnBrowseResult = opts.onBrowseResult

	-- Only messages carrying the current gateway's id are honored. This is a
	-- correctness filter against crossed wires (a second gateway, a stale
	-- reload), NOT an auth boundary: any project driver can read the gateway's
	-- device id, and DriverWorks has no message authentication. Control4's
	-- model is that in-project drivers are trusted.
	local function fromGateway (tParams)
		if (not gGatewayId) then gGatewayId = Child.FindGateway () end
		if (not gGatewayId) then return false end
		if (tostring (tParams.gateway_id) == tostring (gGatewayId)) then return true end
		-- mismatch: the gateway may have been removed and re-added with a new
		-- device id; re-discover once rather than dropping its pushes for up
		-- to a full re-register cycle
		gGatewayId = Child.FindGateway ()
		return gGatewayId and (tostring (tParams.gateway_id) == tostring (gGatewayId))
	end

	-- Route a pushed state, firing onOffline only on the available -> offline
	-- edge (our own 2-minute re-register prompts the gateway to re-push state,
	-- so an unconditional onOffline would repeat the Offline event forever).
	-- 'unknown' is
	-- a normal value (not offline) - many entities report it briefly at
	-- startup and it must not fire an offline event.
	local function applyState (state)
		-- ENTITY_ID must be the first variable this driver ever creates (the
		-- gateway reads it by its fixed id to detect claimed entities). A push
		-- landing between driver (re)load and OnDriverLateInit would mint HA_*
		-- variables first and silently break that contract, so drop it; the
		-- Register in late-init prompts a fresh push moments later.
		if (not gVarsReady) then return end
		local offline = (state.state == 'unavailable')
		-- 'or unknown': a decoded table without .state must not display the
		-- literal string "nil"
		UpdateProperty ('Entity Status', tostring (state.state or 'unknown'))
		if (offline) then
			if (gUnavailable ~= true) then
				goOffline (state)
			end
		else
			gUnavailable = false
			gSeenOnline = true
			if (gOnState) then gOnState (state) end
			applyAttributeVars (state.attributes)
		end
	end

	EC.OPENHAC4_STATE = function (tParams)
		if (not fromGateway (tParams)) then return end
		-- drop pushes for an entity we no longer own: an in-flight push for
		-- the previous entity landing after a reassignment would otherwise
		-- overwrite the fresh onReset state with the old entity's
		if (type (tParams.entity_id) == 'string' and tParams.entity_id ~= '' and
				tParams.entity_id ~= Child.GetEntity ()) then
			return
		end
		local state = Deserialize (tParams.state or '')
		if (type (state) ~= 'table') then
			-- The payload did not decode. The realistic cause is an entity whose
			-- serialized state exceeded what SendToDevice carries, in which case
			-- this entity silently stops updating while every other one works, so
			-- say so rather than returning in silence.
			-- latch: the cause is a property of the entity, not a one-off, so an
			-- unlatched print would repeat on every push for as long as it lasts
			if (not gDecodeWarned) then
				gDecodeWarned = true
				print ('openhac4: could not decode a state push for ' ..
					tostring (tParams.entity_id) .. '; the entity will not update')
			end
			return
		end
		applyState (state)
	end

	-- gateway asks us to re-register (it lost its in-memory registrations on
	-- reload); closes the up-to-2-minute orphan window without waiting
	EC.OPENHAC4_REREGISTER = function (tParams)
		if (not fromGateway (tParams)) then return end
		gLastRegisteredEntity = nil
		Child.Register ()
	end

	EC.OPENHAC4_ENTITIES = function (tParams)
		if (not fromGateway (tParams)) then return end
		-- leading comma gives an empty first item so nothing is preselected
		C4:UpdatePropertyList ('Entity', ',' .. (tParams.entities or ''))
	end

	EC.OPENHAC4_GATEWAY_STATUS = function (tParams)
		if (not fromGateway (tParams)) then return end
		if (tParams.status == 'online') then
			gGatewayOnline = true
			Child.Register ()
		else
			gGatewayOnline = false
			UpdateProperty ('Gateway Status', 'Gateway Offline')
			UpdateProperty ('Entity Status', 'unavailable')
			if (gUnavailable ~= true) then
				goOffline (nil)
			end
		end
	end

	-- the gateway reports a rejected service call so the driver can react
	-- (e.g. the alarm driver surfaces ARM_FAILED / DISARM_FAILED)
	EC.OPENHAC4_SERVICE_RESULT = function (tParams)
		if (not fromGateway (tParams)) then return end
		if (gOnServiceResult) then
			gOnServiceResult (tParams.service, tParams.success == 'true', tParams.error)
		end
	end

	-- the gateway returns a media browse tree for a request we made via
	-- Child.Browse; token echoes the request so the driver can route the reply
	EC.OPENHAC4_BROWSE_RESULT = function (tParams)
		if (not fromGateway (tParams)) then return end
		if (gOnBrowseResult) then
			local ok = (tParams.success == 'true')
			local result = ok and Deserialize (tParams.result or '') or nil
			if (ok and type (result) ~= 'table') then
				-- gateway claimed success but the payload did not decode to a
				-- table (truncated/oversized): report it as an error, not a
				-- silent empty success the caller can't distinguish
				gOnBrowseResult (tParams.token, nil, 'browse result unreadable')
			else
				gOnBrowseResult (tParams.token,
					(type (result) == 'table') and result or nil,
					(not ok) and (tParams.error ~= '' and tParams.error or 'browse failed') or nil)
			end
		end
	end

	-- the import pushes the assigned entity here after adding the driver
	EC.OPENHAC4_SET_ENTITY = function (tParams)
		if (not fromGateway (tParams)) then return end
		UpdateProperty ('Entity ID', tParams.entity_id or '', true)
	end

	EC.RefreshEntityList = function ()
		Child.RequestEntityList ()
	end

	-- 'Entity' is a momentary picker: copy the selection into the persistent
	-- 'Entity ID' string, then reset the picker to empty
	OPC.Entity = function (value)
		if (value and value ~= '') then
			UpdateProperty ('Entity ID', value)
			UpdateProperty ('Entity', '')
			Child.Register ()
		end
	end

	OPC.Entity_ID = function ()
		-- manual entry is the documented path on large installs, and a pasted
		-- id often carries a trailing newline; Home Assistant ids are
		-- lowercase and the gateway can only match exactly, so an untrimmed
		-- paste registers a key that matches nothing and the child sits at
		-- 'unavailable' forever. Same hazard the gateway trims from the
		-- address/port/token fields.
		local raw = Properties ['Entity ID'] or ''
		local norm = raw:gsub ('^%s+', ''):gsub ('%s+$', ''):lower ()
		if (norm ~= raw) then
			UpdateProperty ('Entity ID', norm)
		end
		Child.Register ()
	end

	-- logging property handlers (Log Mode / Log Level / Log Auto Off
	-- Minutes) are registered by the debug module itself

	function OnDriverLateInit ()
		local semver
		pcall (function ()
			semver = C4:GetDriverConfigInfo ('semver')
		end)
		if (not semver or semver == '') then
			-- also guarded: this fallback only runs when the 'semver' lookup above
			-- already misbehaved, which is exactly when it is least safe to trust,
			-- and a throw here would skip the rest of late-init and leave the child
			-- with no ENTITY_ID variable and no registration timer
			pcall (function ()
				semver = tostring (C4:GetDriverConfigInfo ('version'))
			end)
		end
		UpdateProperty ('Driver Version', tostring (semver or ''))

		-- first variable created: must stay first, see ENTITY_ID_VAR above.
		-- Guarded like the semver reads: a throw here would abort late-init
		-- before logging, registration, and the recovery timer are armed.
		pcall (function ()
			C4:AddVariable ('ENTITY_ID', '', 'STRING', true, true)
		end)
		gVarsReady = true -- state pushes may now mint HA_* variables (see applyState)

		if (opts.onInit) then
			-- guarded like everything else in this chain: a throw in a
			-- driver's init hook must not abort late-init, or the child never
			-- registers with the gateway and never arms its recovery timer
			local ok, err = pcall (opts.onInit)
			if (not ok) then
				print ('openhac4: onInit error: ' .. tostring (err))
			end
		end

		Debug.SyncFromProperties ()
		Child.Register ()
		Child.RequestEntityList ()

		-- if we were just imported with no entity yet, ask the gateway for
		-- the entity it created us for (import assignment is timing-independent)
		if (Child.GetEntity () == '') then
			Child.SendToGateway ('OPENHAC4_CLAIM', {})
		end

		-- periodic re-register covers gateway restarts, which lose the
		-- gateway's in-memory registration table
		SetTimer ('OpenHAC4Register', 2 * ONE_MINUTE, Child.Register, true)
	end

	function OnDriverDestroyed ()
		Child.SendToGateway ('OPENHAC4_UNREGISTER', {})
		KillAllTimers ()
	end
end

return Child
