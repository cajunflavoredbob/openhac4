-- openhac4 Home Assistant Media Source
-- Copyright (c) 2026 cajunflavoredbob. Licensed under the MIT License.
--
-- Presents a Home Assistant media_player as a Control4 room "Listen" source via
-- the media_service proxy (MSP): browse the entity's media library, play items,
-- now-playing metadata + progress, transport, shuffle/repeat, and per-room
-- select/volume. Audio plays on the Home Assistant device itself (this is the
-- non-Control4-Digital-Audio streaming-service model), so it suits media_players
-- that ARE a room's endpoint (a Sonos, a receiver, a smart speaker) rather than
-- zones fed from a Control4 audio matrix. The control+status media_player driver
-- remains the right choice for programming and matrix-fed cases.

Child = require ('openhac4.child')

do -- globals
	MSP = 5001 -- media_service proxy binding

	-- HA media_player supported_features bits
	FEAT_SHUFFLE_SET = 32768
	FEAT_REPEAT_SET = 262144

	gState = nil    -- HA state string; nil until first sync
	gAttrs = {}     -- last-seen attributes
	gLast = {}      -- last payload pushed per event, to skip redundant traffic
	gBrowse = {}    -- browse correlation: token -> {navId, seq, binding, timer}
	-- token base offset per load, so a gateway reply from before a driver
	-- reload cannot collide with a token issued after it
	gToken = (function ()
		local ok, t = pcall (os.time)
		return (ok and ((t % 1000000) * 1000)) or 0
	end) ()
	BROWSE_TIMEOUT_MS = 15000 -- a browse with no reply by now gets an error, not a spinner

	-- rooms currently using this device as their source: playback stops only
	-- when the LAST room deselects, not when any one of several does.
	-- Keyed rooms live in the set; selects whose params carry no room id are
	-- counted anonymously. Deliberately NOT cleared on reset/offline: the
	-- Control4 rooms still have the device selected either way.
	gSelectedRooms = {}
	gAnonSelects = 0

	-- HA media_player supported_features bits used for the deselect path
	FEAT_PAUSE = 1
	FEAT_TURN_OFF = 256
	FEAT_STOP = 4096
end

-- XML-escape text placed into DATA / EVTARGS payloads. Control bytes are
-- stripped too: escaping alone leaves them in, and one stray byte in a
-- library tag makes the whole list unparseable.
local function esc (s)
	s = tostring (s or '')
	s = s:gsub ('[%z\1-\8\11\12\14-\31]', '')
	s = s:gsub ('&', '&amp;'):gsub ('<', '&lt;'):gsub ('>', '&gt;')
	s = s:gsub ('"', '&quot;'):gsub ("'", '&apos;')
	return s
end

-- Only forward art Navigators can fetch directly. Home Assistant entity_picture
-- is usually a relative /api/... path needing the HA base URL + token, which
-- Navigators cannot always resolve; re-serving art from controller-local
-- storage is a known future enhancement. Absolute http(s) art is passed through.
local function absUrl (u)
	u = tostring (u or '')
	return (u:match ('^https?://')) and u or nil
end

local function fmtTime (sec)
	sec = math.max (0, math.floor (tonumber (sec) or 0))
	local h = math.floor (sec / 3600)
	local m = math.floor ((sec % 3600) / 60)
	local s = sec % 60
	if (h > 0) then return string.format ('%d:%02d:%02d', h, m, s) end
	return string.format ('%d:%02d', m, s)
end

local function hasFeature (bit)
	local sf = tonumber (gAttrs.supported_features) or 0
	return (math.floor (sf / bit) % 2) == 1
end

-- ---- proxy send helpers -------------------------------------------------

local function dataReceived (binding, navId, seq, data)
	C4:SendToProxy (binding, 'DATA_RECEIVED', {NAVID = navId, SEQ = seq, DATA = data or ''})
end

local function dataError (binding, navId, seq, msg)
	C4:SendToProxy (binding, 'DATA_RECEIVED', {NAVID = navId, SEQ = seq, DATA = '', ERROR = msg or 'error'})
end

local function sendEvent (navId, roomId, name, evtargs)
	C4:SendToProxy (MSP, 'SEND_EVENT', {NAVID = navId, ROOMS = roomId, NAME = name, EVTARGS = evtargs}, 'COMMAND')
end

-- ---- now-playing pushes -------------------------------------------------

local function updateMediaInfo ()
	local a = gAttrs
	local title = tostring (a.media_title or a.app_name or '')
	local artist = tostring (a.media_artist or '')
	local album = tostring (a.media_album_name or '')
	local art = absUrl (a.entity_picture) or ''
	-- \1 separator: a literal '|' in metadata must not alias two different
	-- title/artist splits into the same dedup key
	local key = table.concat ({title, artist, album, art}, '\1')
	if (key == gLast.info) then return end
	gLast.info = key
	-- send both the documented LINE* keys and the tutorial TITLE/ARTIST keys;
	-- whichever set the running proxy honors renders, the other is ignored
	C4:SendToProxy (MSP, 'UPDATE_MEDIA_INFO', {
		LINE1 = title, LINE2 = artist, LINE3 = album,
		TITLE = title, ARTIST = artist, ALBUM = album,
		IMAGEURL = art, MERGE = 'false',
	}, 'COMMAND', true)
end

local function dashItems ()
	if (gState == 'playing' or gState == 'buffering') then return 'Pause Stop SkipRev SkipFwd'
	elseif (gState == 'paused') then return 'Play Stop SkipRev SkipFwd'
	else return 'Play SkipRev SkipFwd' end
end

local function sendDashboard (navId, roomId)
	local items = dashItems ()
	if (navId == nil) then
		if (items == gLast.dash) then return end
		gLast.dash = items
	end
	sendEvent (navId, roomId, 'DashboardChanged', '<Items>' .. items .. '</Items>')
end

local function sendProgress (navId, roomId)
	local a = gAttrs
	local dur = tonumber (a.media_duration)
	local pos = tonumber (a.media_position)
	local evt
	if (not (dur and pos) or dur <= 0) then
		-- no duration (live stream, radio, nothing playing): clear the bar
		-- instead of leaving the previous track's frozen progress on screen
		evt = '<length>0</length><offset>0</offset><label></label>'
	else
		if (pos > dur) then pos = dur end
		-- HA reports position as a snapshot at media_position_updated_at (it
		-- does not tick); the bar advances as Home Assistant pushes new state,
		-- not smoothly. A local extrapolating ticker is a possible future
		-- enhancement.
		local label = fmtTime (pos) .. ' / -' .. fmtTime (dur - pos)
		evt = '<length>' .. math.floor (dur) .. '</length><offset>' .. math.floor (pos)
			.. '</offset><label>' .. esc (label) .. '</label>'
	end
	if (navId == nil) then
		-- skip a broadcast that would repeat the last one (a volume-only state
		-- push must not re-emit progress to every room)
		if (evt == gLast.progress) then return end
		gLast.progress = evt
	end
	sendEvent (navId, roomId, 'ProgressChanged', evt)
end

local function sendQueue (navId, roomId)
	local a = gAttrs
	local title = esc (a.media_title or a.app_name or 'Nothing playing')
	local artist = esc (a.media_artist or '')
	local dur = tonumber (a.media_duration)
	local durTag = dur and ('<duration>' .. fmtTime (dur) .. '</duration>') or ''
	-- a single-item now-playing "queue": Home Assistant does not expose a full
	-- media_player queue across integrations, so we present the current track
	local list = '<item><title>Now Playing</title><isHeader>true</isHeader></item>'
		.. '<item><title>' .. title .. '</title><subtitle>' .. artist .. '</subtitle>' .. durTag .. '</item>'
	local repeatOn = (a['repeat'] ~= nil and a['repeat'] ~= 'off')
	local np = '<can_shuffle>' .. tostring (hasFeature (FEAT_SHUFFLE_SET)) .. '</can_shuffle>'
		.. '<can_repeat>' .. tostring (hasFeature (FEAT_REPEAT_SET)) .. '</can_repeat>'
		.. '<shufflemode>' .. tostring (a.shuffle == true) .. '</shufflemode>'
		.. '<repeatmode>' .. tostring (repeatOn) .. '</repeatmode>'
	local evt = '<List>' .. list .. '</List><NowPlayingIndex>1</NowPlayingIndex><NowPlaying>' .. np .. '</NowPlaying>'
	if (navId == nil) then
		if (evt == gLast.queue) then return end
		gLast.queue = evt
	end
	sendEvent (navId, roomId, 'QueueChanged', evt)
end

local function pushAll ()
	updateMediaInfo ()
	sendDashboard (nil, nil)
	sendQueue (nil, nil)
	sendProgress (nil, nil)
end

-- ---- driver lifecycle ---------------------------------------------------

Child.Setup {
	domain = 'media_player',

	onInit = function ()
		C4:AddVariable ('STATE', '', 'STRING', true, false)
		C4:AddVariable ('MEDIA_TITLE', '', 'STRING', true, false)
		C4:AddVariable ('VOLUME', '0', 'NUMBER', true, false)
	end,

	onState = function (state)
		gState = state.state
		gAttrs = state.attributes or {}

		C4:SetVariable ('STATE', tostring (gState or ''))
		C4:SetVariable ('MEDIA_TITLE', tostring (gAttrs.media_title or gAttrs.app_name or ''))
		UpdateProperty ('Now Playing', tostring (gAttrs.media_title or gAttrs.app_name or ''))
		UpdateProperty ('Current State', tostring (gState or ''))
		if (gAttrs.volume_level ~= nil) then
			C4:SetVariable ('VOLUME', math.floor ((tonumber (gAttrs.volume_level) or 0) * 100 + 0.5))
		end

		pushAll ()
	end,

	onOffline = function ()
		UpdateProperty ('Current State', 'Unavailable')
		gState = nil
		gAttrs = {}
		gLast = {}
		-- clear everything Navigators show, not just the dashboard: a frozen
		-- title/queue/progress from before the outage reads as current
		pushAll ()
	end,

	-- Home Assistant rejected a service call (a stale item id after the
	-- library changed, an unsupported command). The Navigator has already
	-- moved on, so a proper error dialog needs the media proxy's error
	-- surface (queued for the media-driver pass); at minimum say why Now
	-- Playing is empty instead of failing in complete silence.
	onServiceResult = function (service, success)
		if (success) then return end
		print ('openhac4: media_source: Home Assistant rejected ' .. tostring (service))
	end,

	onReset = function ()
		gState = nil
		gAttrs = {}
		gLast = {}
		-- clear the previous entity's values from variables and displays: a
		-- new entity that never reports volume would otherwise inherit the
		-- old one's VOLUME forever
		C4:SetVariable ('STATE', '')
		C4:SetVariable ('MEDIA_TITLE', '')
		C4:SetVariable ('VOLUME', 0)
		UpdateProperty ('Now Playing', '')
		UpdateProperty ('Current State', '')
		pushAll ()
		-- fail any in-flight browse so a Navigator mid-browse during an entity
		-- reassignment gets an error instead of spinning forever
		for _, p in pairs (gBrowse) do
			if (p.timer) then p.timer:Cancel () end
			dataError (p.binding, p.navId, p.seq, 'entity changed')
		end
		gBrowse = {}
	end,

	-- gateway returned a browse tree for a request we made; format and reply
	onBrowseResult = function (token, result, err)
		if (token == nil) then return end -- malformed echo: assigning gBrowse[nil] below throws
		local p = gBrowse [token]
		gBrowse [token] = nil
		if (not p) then return end -- already timed out and replied
		if (p.timer) then p.timer:Cancel () end
		if (err or type (result) ~= 'table') then
			dataError (p.binding, p.navId, p.seq, err or 'no data')
			return
		end
		local items = {}
		-- Build under pcall. The timeout has already been cancelled, so a throw
		-- in here would leave the Navigator browsing screen spinning with nothing
		-- left to answer it. A malformed row is the realistic cause.
		local ok = pcall (function ()
		for _, c in ipairs (result.children or {}) do
			if (type (c) ~= 'table') then
				-- skip a row that is not an object rather than indexing it
			else
			local canExpand = (c.can_expand == true)
			local canPlay = (c.can_play == true)
			local id = tostring (c.media_content_id or '')
			-- every row needs a content id: a play without one calls play_media
			-- with an empty id (HA errors), and an expand without one browses
			-- as root, silently looping the user back to the top level
			if ((canExpand or canPlay) and id ~= '') then
				local row = {'<item><title>', esc (c.title), '</title>'}
				row[#row + 1] = '<id>' .. esc (id) .. '</id>'
				row[#row + 1] = '<itemType>' .. esc (c.media_content_type or '') .. '</itemType>'
				row[#row + 1] = '<nav>' .. (canExpand and 'dir' or 'play') .. '</nav>'
				row[#row + 1] = '<default_action>SelectItem</default_action>'
				if (canExpand) then row[#row + 1] = '<isLink>true</isLink>' end
				local art = absUrl (c.thumbnail)
				if (art) then row[#row + 1] = '<image_list width="80" height="80">' .. esc (art) .. '</image_list>' end
				row[#row + 1] = '</item>'
				items[#items + 1] = table.concat (row)
			end
			end
		end
		end)
		if (not ok) then
			dataError (p.binding, p.navId, p.seq, 'browse result unreadable')
			return
		end
		-- the gateway caps a browse level; say so rather than letting a trimmed
		-- list read as the whole library
		if (result.truncated) then
			items [#items + 1] = '<item><title>List truncated - showing the first '
				.. #items .. ' items</title><isHeader>true</isHeader></item>'
		end
		dataReceived (p.binding, p.navId, p.seq, '<List>' .. table.concat (items) .. '</List>')
	end,
}

-- ---- proxy commands (media_service) ------------------------------------

do
	local function svc (service, data) Child.CallService (service, data) end

	-- Browse: ask HA for this node's children (async via the gateway relay).
	-- id/itemType are the tapped item's media_content_id/type (empty at root).
	RFP.Browse = function (idBinding, strCommand, tParams, args)
		gToken = gToken + 1
		local token = tostring (gToken)
		local navId, seq = tParams.NAVID, tParams.SEQ
		gBrowse[token] = {navId = navId, seq = seq, binding = idBinding}
		local id = (args.id ~= '' and args.id) or nil
		local itemType = (args.itemType ~= '' and args.itemType) or nil
		if (not Child.Browse (id, itemType, token)) then
			gBrowse[token] = nil
			dataError (idBinding, navId, seq, 'gateway unavailable')
			return
		end
		-- a browse that never comes back (gateway not authed, socket dropped, or
		-- Home Assistant never answers) must not spin the Navigator forever
		gBrowse[token].timer = C4:SetTimer (BROWSE_TIMEOUT_MS, function ()
			pcall (function ()
				local p = gBrowse[token]
				if (p) then
					gBrowse[token] = nil
					dataError (p.binding, p.navId, p.seq, 'browse timed out')
				end
			end)
		end)
	end

	-- A list item was tapped: drill into a container, or play a leaf and jump
	-- to Now Playing.
	RFP.SelectItem = function (idBinding, strCommand, tParams, args)
		if (args.nav == 'dir') then
			dataReceived (idBinding, tParams.NAVID, tParams.SEQ, '<NextScreen>browse</NextScreen>')
		else
			if (args.id and args.id ~= '') then
				svc ('play_media', {
					media_content_id = args.id,
					media_content_type = (args.itemType ~= '' and args.itemType) or 'music',
				})
			end
			dataReceived (idBinding, tParams.NAVID, tParams.SEQ, '<NextScreen>#nowplaying</NextScreen>')
		end
	end

	-- transport (room-issued PLAY/PAUSE/... and Now Playing dashboard buttons)
	RFP.PLAY = function () svc ('media_play') end
	RFP.PAUSE = function () svc ('media_pause') end
	RFP.STOP = function () svc ('media_stop') end
	RFP.SKIP_FWD = function () svc ('media_next_track') end
	RFP.SKIP_REV = function () svc ('media_previous_track') end

	RFP.ToggleShuffle = function () svc ('shuffle_set', {shuffle = not (gAttrs.shuffle == true)}) end
	RFP.ToggleRepeat = function ()
		-- default a missing repeat attribute to 'off' so the first tap turns it
		-- on (to 'all') rather than wasting a press re-sending 'off'
		local cur = gAttrs['repeat'] or 'off'
		local nextMode = (cur == 'off' and 'all') or (cur == 'all' and 'one') or 'off'
		svc ('repeat_set', {['repeat'] = nextMode})
	end

	-- Now Playing screen loaded / dashboard requested: reply to that Navigator
	RFP.GetQueue = function (idBinding, strCommand, tParams)
		sendQueue (tParams.NAVID, tParams.ROOMID)
		sendProgress (tParams.NAVID, tParams.ROOMID)
	end
	RFP.GetDashboard = function (idBinding, strCommand, tParams)
		sendDashboard (tParams.NAVID, tParams.ROOMID)
	end
	RFP.GetDashBoard = RFP.GetDashboard -- proxy casing varies across OS versions

	-- room select / deselect. A refcount tracks how many rooms have this
	-- device as their source; playback stops only when the last one leaves.
	-- Keyed by room id when the proxy provides one, plain count otherwise.
	local function roomKey (tParams)
		local r = tParams and (tParams.ROOM_ID or tParams.ROOMID or tParams.LOCATION)
		r = tostring (r or '')
		return (r ~= '' and r) or nil
	end

	local function selectionCount ()
		local n = gAnonSelects
		for _ in pairs (gSelectedRooms) do n = n + 1 end
		return n
	end

	RFP.DEVICE_SELECTED = function (idBinding, strCommand, tParams)
		local room = roomKey (tParams)
		-- trace the param shape: whether the proxy sends a room id decides if
		-- the anonymous count (which cannot dedupe re-selects) is ever used
		Child.TraceParams ('DEVICE_SELECTED', tParams)
		if (room) then
			gSelectedRooms [room] = true
		else
			gAnonSelects = gAnonSelects + 1
		end
		svc ('turn_on')
	end

	RFP.DEVICE_DESELECTED = function (idBinding, strCommand, tParams)
		local room = roomKey (tParams)
		if (room and gSelectedRooms [room]) then
			gSelectedRooms [room] = nil
		elseif (gAnonSelects > 0) then
			gAnonSelects = gAnonSelects - 1
		else
			-- unkeyed deselect against a keyed selection (mixed param shapes):
			-- retire one keyed entry rather than desyncing the count
			local any = next (gSelectedRooms)
			if (any ~= nil) then gSelectedRooms [any] = nil end
		end
		if (selectionCount () > 0) then return end -- other rooms still listening
		-- Stop playback with what the entity actually supports: many
		-- integrations (Spotify-class) implement pause but not stop, and a
		-- rejected media_stop would leave audio playing after room-off. With
		-- no attributes yet (reload window before the first state push), fall
		-- back to the plain media_stop attempt rather than doing nothing.
		if (gAttrs.supported_features == nil) then
			svc ('media_stop')
		elseif (gState == 'on') then
			if (hasFeature (FEAT_TURN_OFF)) then svc ('turn_off') end
		elseif (hasFeature (FEAT_STOP)) then
			svc ('media_stop')
		elseif (hasFeature (FEAT_PAUSE)) then
			svc ('media_pause')
		elseif (hasFeature (FEAT_TURN_OFF)) then
			svc ('turn_off')
		end
	end

	-- volume / mute (LEVEL is 0-100 in the proxy)
	RFP.SET_VOLUME_LEVEL = function (idBinding, strCommand, tParams)
		local lvl = tonumber (tParams.LEVEL)
		if (lvl ~= nil) then svc ('volume_set', {volume_level = math.max (0, math.min (100, lvl)) / 100}) end
	end
	RFP.MUTE_ON = function () svc ('volume_mute', {is_volume_muted = true}) end
	RFP.MUTE_OFF = function () svc ('volume_mute', {is_volume_muted = false}) end
	RFP.MUTE_TOGGLE = function () svc ('volume_mute', {is_volume_muted = not (gAttrs.is_volume_muted == true)}) end
	RFP.PULSE_VOL_UP = function () svc ('volume_up') end
	RFP.PULSE_VOL_DOWN = function () svc ('volume_down') end

	-- Navigator finished with the driver: drop any pending browse it owned
	local function destroyNav (idBinding, strCommand, tParams)
		for token, p in pairs (gBrowse) do
			if (p.navId == tParams.NAVID) then
				if (p.timer) then p.timer:Cancel () end
				gBrowse[token] = nil
			end
		end
	end
	RFP.DESTROY_NAV = destroyNav
	RFP.DESTROY_NAVIGATOR = destroyNav
end
