-- openhac4 shared protocol constants and helpers
-- Copyright (c) 2026 cajunflavoredbob. Licensed under the MIT License.
--
-- Single source of truth for the values that the gateway and every child
-- driver must agree on. Both require this module so they cannot drift.

local P = {}

-- control binding class shared by the gateway and its children
P.BINDING = 1

-- children create ENTITY_ID as their first user variable, so it is always
-- variable id 1001; the gateway reads it by this id to find configured children
P.ENTITY_ID_VAR = 1001

-- the gateway's driver filename, used by children to locate it
P.GATEWAY_C4Z = 'openhac4_gateway.c4z'

-- Never let an encode failure escape. Most callers are logging, where a throw
-- would abort the surrounding handler and drop a real command (a light that
-- does not turn on) purely because a debug line could not be built.
function P.jsonEncode (t)
	local ok, out = pcall (C4.JsonEncode, C4, t)
	if (ok and type (out) == 'string') then return out end
	return nil
end

function P.jsonDecode (s)
	local ok, ret = pcall (function () return C4:JsonDecode (s) end)
	if (ok and type (ret) == 'table') then
		return ret
	end
	return nil
end

return P
