-- common/openhac4/c4lib.lua
--
-- The small slice of utility globals the openhac4 drivers use: Serialize,
-- Deserialize, VersionCheck. Independent implementation over the public C4 API
-- (JsonEncode/JsonDecode, Base64Encode/Base64Decode, GetVersionInfo).
--
-- PersistData is intentionally NOT provided here: it is a native global that the
-- Control4 Director persists across reloads, and the drivers initialize and use
-- it directly (PersistData = PersistData or {}). Temperature helpers are not
-- provided either; the climate driver passes the HA unit through as-is.
--
-- Contract (globals, matching how the drivers call them):
--   Serialize(v)   -> a table becomes base64(JSON); any other value is returned
--                     unchanged. Cross-driver messages ride C4:SendToDevice's
--                     tParams, whose transport mangles raw JSON punctuation, so
--                     wrapping the JSON in base64 keeps it intact end to end.
--   Deserialize(v) -> a base64(JSON) string becomes the decoded table; any other
--                     value (or undecodable input) is returned unchanged.
--   VersionCheck(required) -> true if the controller OS version is >= `required`
--                     (dotted string, compared component by component).

function Serialize (v)
	if (type (v) == 'table') then
		-- One pcall over both native calls: any throw (or a non-string result)
		-- falls through to returning v unchanged, honoring the contract.
		local ok, b64 = pcall (function ()
			local json = C4:JsonEncode (v)
			if (type (json) == 'string') then return C4:Base64Encode (json) end
		end)
		if (ok and type (b64) == 'string') then return b64 end
	end
	return v
end

-- Two Control4 JSON quirks are normalized here, on the cross-driver decode:
--
-- 1. A JSON null decodes to an empty table. Left as-is, an attribute Home
--    Assistant reports as null (media title while idle, an event entity's
--    event_type before any press, hvac_action) arrives as a table, and a driver
--    that stringifies it writes "table: 0x..." into a variable or property.
--    Empty tables become nil so a null reads as absent, which drivers handle.
--    DELIBERATE CONTRACT: C4:JsonDecode yields the same empty table for null,
--    [], and {}, so the three are indistinguishable here; all read as absent.
--    Drivers must treat "attribute missing" and "attribute empty" identically.
--
-- 2. A JSON array does not survive the encode-then-decode round-trip the state
--    takes to reach a child: it comes back as an object with string keys
--    "1".."n", so ipairs finds nothing and option/event/mode lists look empty.
--    A table whose keys are exactly "1".."n" is restored to a proper Lua array.
--    Array detection runs BEFORE null-stripping and permits empty-table (null)
--    elements, compacting them out: stripping first would leave a keyed gap
--    that breaks the "1".."n" test, and the value would stay object-shaped.
--
-- Bounded depth so a pathological payload cannot spin.
local function stringArrayLen (t)
	local n = 0
	for k in pairs (t) do
		if (type (k) ~= 'string' or not k:match ('^%d+$')) then return nil end
		n = n + 1
	end
	if (n == 0) then return nil end
	for i = 1, n do if (t [tostring (i)] == nil) then return nil end end
	return n
end

local function normalize (t, depth)
	if (type (t) ~= 'table' or depth > 8) then return t end
	local n = stringArrayLen (t)
	if (n) then
		-- array: normalize elements, compact null (empty-table) slots out
		local arr = {}
		for i = 1, n do
			local val = t [tostring (i)]
			if (type (val) == 'table') then
				val = normalize (val, depth + 1)
				if (val ~= nil and next (val) == nil) then val = nil end
			end
			if (val ~= nil) then arr [#arr + 1] = val end
		end
		return arr
	end
	-- object: normalize members first, then strip the ones that are (or have
	-- become) empty, so {a = {b = null}} reads as absent just like {a = null}
	for k, val in pairs (t) do
		if (type (val) == 'table') then
			val = normalize (val, depth + 1)
			if (val ~= nil and next (val) == nil) then val = nil end
			t [k] = val
		end
	end
	return t
end

function Deserialize (v)
	if (type (v) == 'string') then
		-- pcall covers Base64Decode and JsonDecode: a corrupt cross-driver
		-- payload can never throw out of here into the caller's message handler.
		local ok, decoded = pcall (function ()
			local json = C4:Base64Decode (v)
			if (json) then return C4:JsonDecode (json) end
		end)
		if (ok and type (decoded) == 'table') then return normalize (decoded, 1) end
	end
	return v
end

function VersionCheck (required)
	-- Guard GetVersionInfo too: a throw here would otherwise propagate, and
	-- url-style callers invoke VersionCheck at require time. On any failure the
	-- version reads as empty -> all-zero -> the gate stays closed (fail-safe).
	local ok, info = pcall (function () return C4:GetVersionInfo () end)
	local version = (ok and type (info) == 'table' and info.version) or ''
	-- No end-anchor: a version with a 5th component or build suffix (e.g.
	-- "3.3.2.1234") must still match on its leading four numeric parts.
	-- Anchor on the first digit-run FOLLOWED BY A DOT ("v3.3.2" -> "3.3.2").
	-- A bare first-digit anchor would latch onto a digit inside a product
	-- prefix ("X4 3.2.0" -> "4 3.2.0" -> 4.0.0.0) and fail OPEN with an
	-- inflated version; no dotted run means no parseable version -> zeros,
	-- which fails closed.
	version = tostring (version):match ('%d+%.[%d%.]*') or ''
	local cur = {tostring (version):match ('^(%d*)%.?(%d*)%.?(%d*)%.?(%d*)')}
	local req = {tostring (required):match ('^(%d*)%.?(%d*)%.?(%d*)%.?(%d*)')}
	for i = 1, 4 do
		local c = tonumber (cur [i]) or 0
		local r = tonumber (req [i]) or 0
		if (c > r) then return true end
		if (c < r) then return false end
	end
	return true
end
