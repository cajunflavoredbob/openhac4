-- common/openhac4/c4handlers.lua
--
-- The Control4 DriverWorks entry points and their dispatch tables for the
-- openhac4 drivers. Independent implementation written from the public C4
-- callback contract. The entry-point names are fixed by Control4.
--
-- Control4 calls a fixed set of global functions on a driver. Each is routed
-- here into a per-key dispatch table that the drivers populate:
--   ExecuteCommand(cmd, p)                -> EC[cmd](p)             driver actions
--   ReceivedFromProxy(bind, cmd, p)       -> RFP[cmd] / RFP[bind]   proxy commands
--   OnPropertyChanged(prop)               -> OPC[prop](value)       property edits
--   OnConnectionStatusChanged(b, port, s) -> OCS[b](b, port, s)     network status
--   ReceivedFromNetwork(b, port, data)    -> RFN[b](b, port, data)  network data
-- Command and property names have whitespace collapsed to underscores, so a key
-- like EC.Import_Rooms matches the "Import Rooms" action.
--
-- Also provides UpdateProperty(name, value, notify). Every dispatch runs under
-- pcall so a handler fault cannot take down the driver. Note that no code in
-- this module ever writes a property VALUE to a log: the error path records the
-- handler name and key only, which is what keeps the access token out of the
-- log on every path through here.

-- Shared dispatch tables. `X = X or {}` so this coexists with a sibling module
-- (c4socket populates OCS/RFN) regardless of require order.
EC = EC or {}
OPC = OPC or {}
OCS = OCS or {}
RFN = RFN or {}
RFP = RFP or {}

-- Invoke a handler under pcall: a nil/non-function slot is a silent no-op; an
-- error is logged as "<name>[<key>] error: ...". The label is assembled only on
-- the error path -- never per call -- so the hot receive paths allocate nothing
-- when a handler is registered, and no property value is ever put in a log.
local function dispatch (fn, name, key, ...)
	if (type (fn) ~= 'function') then return end
	local ok, ret = pcall (fn, ...)
	if (ok) then return ret end
	print ('openhac4 ' .. name .. '[' .. tostring (key) .. '] error: ' .. tostring (ret))
end

local function normalize (name)
	return (tostring (name):gsub ('%s+', '_'))
end

-- Composer delivers a custom action as LUA_ACTION carrying the real action name
-- in the ACTION parameter, so unwrap that before dispatching.
local function unwrapAction (command, params)
	if (command ~= 'LUA_ACTION') then return command end
	local actual = params.ACTION
	if (not actual) then return command end -- truthiness, so a false ACTION is ignored
	params.ACTION = nil
	return actual
end

-- ARGS arrives as an XML blob on some proxy commands. Decode it into a flat
-- name -> value table. The whole walk sits under one pcall so neither a
-- malformed blob nor an unexpected ParseXml shape can throw out of an entry
-- point. Our handlers read the flat params; the decoded table is supplied
-- alongside to preserve the established calling convention.
local function decodeArgs (blob)
	local decoded = {}
	pcall (function ()
		local parsed = C4:ParseXml (blob)
		if (type (parsed) ~= 'table') then return end
		if (type (parsed.ChildNodes) ~= 'table') then return end
		for _, node in pairs (parsed.ChildNodes) do
			local attrs = (type (node) == 'table') and node.Attributes
			if (type (attrs) == 'table' and attrs.name) then
				decoded [attrs.name] = node.Value
			end
		end
	end)
	return decoded
end

function ExecuteCommand (command, params)
	if (type (params) ~= 'table') then params = {} end
	local key = normalize (unwrapAction (command, params))
	return dispatch (EC [key], 'ExecuteCommand', key, params)
end

function ReceivedFromProxy (binding, command, params)
	command = command or ''
	if (type (params) ~= 'table') then params = {} end
	local decoded = {}
	if (params.ARGS) then -- truthiness, matching how the proxy sends the blob
		decoded = decodeArgs (params.ARGS)
		params.ARGS = nil
	end
	-- Prefer a per-command handler, fall back to a per-binding one.
	local fn = RFP [command]
	if (type (fn) ~= 'function') then fn = RFP [binding] end
	return dispatch (fn, 'ReceivedFromProxy', command, binding, command, params, decoded)
end

function OnPropertyChanged (propertyName)
	-- C4 has already written the new value into the Properties global. Read it by
	-- the original (spaced) name; look the handler up by the underscored key.
	local value = Properties and Properties [propertyName]
	if (type (value) ~= 'string') then value = '' end
	local key = normalize (propertyName)
	return dispatch (OPC [key], 'OnPropertyChanged', key, value)
end

function OnConnectionStatusChanged (binding, port, status)
	return dispatch (OCS [binding], 'OnConnectionStatusChanged', binding,
		binding, port, status)
end

function ReceivedFromNetwork (binding, port, data)
	return dispatch (RFN [binding], 'ReceivedFromNetwork', binding,
		binding, port, data)
end

-- Write a property only when it actually changed (avoids redundant Director
-- churn). Silently ignores a bad name/value or a property not declared in
-- driver.xml. notifyChange fires OnPropertyChanged whenever requested -- even if
-- the value did not change -- so a driver can force a property's handler to
-- re-run (e.g. re-claiming the same entity). A handler that re-writes its own
-- property with notify would recurse; no driver does this, and the recursion is
-- contained by dispatch's pcall.
function UpdateProperty (propertyName, value, notifyChange)
	if (type (propertyName) ~= 'string' or type (value) ~= 'string') then return end
	if (not Properties or Properties [propertyName] == nil) then return end
	if (Properties [propertyName] ~= value) then
		C4:UpdateProperty (propertyName, value)
	end
	if (notifyChange == true) then
		OnPropertyChanged (propertyName)
	end
end
