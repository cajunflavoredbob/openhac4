-- openhac4 logging helper
-- Copyright (c) 2026 cajunflavoredbob. Licensed under the MIT License.
--
-- A single Debug on/off property gates the logging controls: when Debug is
-- Off, the Log Mode / Level / Auto Off properties are hidden and no logging
-- happens. When On, they appear.
--
-- Sinks, either or both:
--   Print - Composer Lua output window, live and transient
--   Log   - C4:DebugLog, the director log stream
--
-- Severity threshold 0-5 (Alert..Debug). Auto-reverts Debug to Off after a
-- configurable number of minutes so a session never runs forever.

require ('openhac4.c4handlers')
require ('openhac4.c4timer')

local Debug = {}

local LEVEL_TAGS = {[0] = 'ALERT', [1] = 'ERROR', [2] = 'WARN', [3] = 'INFO', [4] = 'TRACE', [5] = 'DEBUG'}

-- properties hidden when Debug is Off
local GATED = {'Log Mode', 'Log Level', 'Log Auto Off Minutes'}

local gDebug = false
local gLevel = 2
local gPrint = false
local gLog = false
local gDurationMinutes = 30

local function applyVisibility ()
	-- SetPropertyAttribs: 1 = hidden, 0 = shown. Not valid during OnDriverInit.
	local hidden = (gDebug and 0) or 1
	for _, p in ipairs (GATED) do
		pcall (function () C4:SetPropertyAttribs (p, hidden) end)
	end
end

local function armAutoOff ()
	CancelTimer ('OpenHAC4LogOff')
	-- auto-off whenever Debug is On, even if no sink is selected yet, so
	-- leaving Debug On never persists indefinitely
	if (gDebug) then
		SetTimer ('OpenHAC4LogOff', gDurationMinutes * ONE_MINUTE, function ()
			-- reverting Debug to Off stops every sink and re-hides the controls
			UpdateProperty ('Debug', 'Off', true)
		end)
	end
end

function Debug.SetMode (value)
	gPrint = (value == 'Print' or value == 'Print and Log')
	gLog = (value == 'Log' or value == 'Print and Log')
	armAutoOff ()
end

function Debug.SetLevel (value)
	-- property values look like '2 - Warning'; the leading digit is the level
	gLevel = tonumber (string.match (tostring (value or ''), '^(%d)')) or 2
end

function Debug.SetDuration (value)
	gDurationMinutes = tonumber (value) or 30
	armAutoOff ()
end

function Debug.SetDebug (value)
	gDebug = (value == 'On')
	applyVisibility ()
	if (gDebug) then
		armAutoOff ()
	else
		CancelTimer ('OpenHAC4LogOff')
	end
end

local function emit (level, ...)
	if (not gDebug) then
		return
	end
	if (not (gPrint or gLog)) then
		return
	end
	if (level > gLevel) then
		return
	end
	local parts = {}
	for i = 1, select ('#', ...) do
		-- select('#') rather than ipairs: a nil argument would otherwise truncate
		-- the rest of the line silently
		table.insert (parts, tostring ((select (i, ...))))
	end
	local msg = LEVEL_TAGS [level] .. ': ' .. table.concat (parts, ' ')
	if (gPrint) then
		print (msg)
	end
	if (gLog) then
		C4:DebugLog (msg)
	end
end

-- Cheap predicate for callers that must build an expensive argument (formatting
-- a whole websocket frame, say). Without this the argument is constructed on
-- every call and thrown away whenever logging is off, which on a busy Home
-- Assistant is real work per frame for no output.
function Debug.Wants (level)
	return gDebug and (gPrint or gLog) and (level <= gLevel)
end

function Debug.Alert (...) emit (0, ...) end
function Debug.Error (...) emit (1, ...) end
function Debug.Warn (...) emit (2, ...) end
function Debug.Info (...) emit (3, ...) end
function Debug.Trace (...) emit (4, ...) end
function Debug.Dbg (...) emit (5, ...) end

-- Call from OnDriverLateInit (NOT OnDriverInit - SetPropertyAttribs is invalid
-- there) after the Properties table is live.
function Debug.SyncFromProperties ()
	Debug.SetLevel (Properties ['Log Level'])
	Debug.SetDuration (Properties ['Log Auto Off Minutes'])
	Debug.SetMode (Properties ['Log Mode'])
	Debug.SetDebug (Properties ['Debug'])
end

OPC.Debug = function (value)
	Debug.SetDebug (value)
end

OPC.Log_Mode = function (value)
	Debug.SetMode (value)
end

OPC.Log_Level = function (value)
	Debug.SetLevel (value)
end

OPC.Log_Auto_Off_Minutes = function (value)
	Debug.SetDuration (value)
end

return Debug
