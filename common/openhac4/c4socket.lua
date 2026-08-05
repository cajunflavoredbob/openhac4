-- common/openhac4/c4socket.lua
--
-- RFC 6455 websocket client over the Control4 DriverWorks network API.
-- Independent implementation written from the public C4 network functions and
-- RFC 6455.
--
-- C4 delivers network events to the globals OnConnectionStatusChanged and
-- ReceivedFromNetwork, which the handlers module dispatches per binding through
-- the OCS / RFN tables. This module registers OCS[binding] / RFN[binding] for
-- its connection rather than owning those globals, so the handlers module stays
-- the single owner of every C4 entry point.
--
-- Consumed contract (everything the gateway uses):
--   WebSocket:new(url, headers, sslOptions) -> instance or nil
--   inst:Start() / :Send(text, sensitive) / :Close() / :delete(immediate)
--     sensitive: the caller knows this frame carries a credential, so it is
--       never written to the frame log regardless of log level
--     immediate: release the network binding synchronously, for driver
--       teardown where a deferred timer would never run
--   inst:SetProcessMessageFunction(fn)      -- fn(inst, message) per decoded text msg
--   inst:SetEstablishedFunction(fn)         -- handshake complete
--   inst:SetOfflineFunction(fn)             -- socket dropped/errored
--   inst:SetClosedByRemoteFunction(fn)      -- peer sent a close frame
--   fields: .running .connected .url .netBinding
--   sslOptions: { VERIFY_METHOD = 'tlsv1_2', VERIFY_MODE = 'peer'|'none' }

local Debug = require ('openhac4.debug')

local WebSocket = {}
WebSocket.__index = WebSocket

-- [binding] = instance. The handlers module may inspect this to suppress noisy
-- receive logging for socket bindings.
WebSocket.Sockets = {}

local BINDING_MIN, BINDING_MAX = 6100, 6200 -- dynamic net bindings, per C4 convention
local CLOSE_DEFER_MS = 3000                  -- let the close frame flush before NetDisconnect
-- Anti-wedge ceiling. Generous on purpose: a full get_states from a large Home
-- Assistant (thousands of entities with fat attributes) can pass 8 MB, and a
-- frame over the cap is fatal to the fetch-subscribe cycle, so the cap must sit
-- well above anything a real instance produces.
local MAX_FRAME = 32 * 1024 * 1024
local MAX_HANDSHAKE = 65536                  -- cap pre-handshake header bytes

local MAX_LOGGED_FRAME = 512                 -- truncate frames in the level-5 log

local OP_CONT, OP_TEXT, OP_CLOSE, OP_PING, OP_PONG = 0x0, 0x1, 0x8, 0x9, 0xA
local CLOSE_NORMAL = string.char (0x03, 0xE8) -- status code 1000

-- Frame text as it may appear in a log. Any frame mentioning access_token is
-- withheld in full rather than pattern-edited: a surgical substitution has to
-- model JSON string escaping to know where the value ends, and Lua patterns
-- cannot, so a token containing a quote would leak its tail. Nothing in an auth
-- frame is worth debugging, so dropping the whole payload costs nothing. The
-- check runs on both directions so a future caller cannot reintroduce a leak.
-- Long payloads (a full get_states response) are truncated to keep logs usable.
local function loggable (text)
	local s = tostring (text or '')
	-- Backstop only: senders declare a credential frame via sendFrame's
	-- `sensitive` flag. This catches an undeclared one without swallowing every
	-- frame that merely mentions the word, so an entity named
	-- sensor.access_token_expiry still logs normally. Case-insensitive because
	-- the guard must not depend on our own frames being the only source.
	if (s:lower ():find ('"access_token"', 1, true)) then
		return '<frame containing a credential; withheld>'
	end
	if (#s > MAX_LOGGED_FRAME) then
		s = s:sub (1, MAX_LOGGED_FRAME) .. '...<' .. #s .. ' bytes total>'
	end
	return s
end

-- Seeding touches os.* which a restrictive sandbox could withhold; a throw here
-- would run at require-time and brick the whole driver, so guard it.
pcall (function ()
	math.randomseed (os.time () + math.floor ((os.clock () or 0) * 1000000))
end)

-- Single-byte XOR by hand so the module carries no bit-library assumption. Only
-- runs over small outbound frames (server->client frames are unmasked).
local function bxor (a, b)
	local r, p = 0, 1
	for _ = 1, 8 do
		local ab, bb = a % 2, b % 2
		if (ab ~= bb) then r = r + p end
		a, b, p = (a - ab) / 2, (b - bb) / 2, p * 2
	end
	return r
end

local function randomBytes (n)
	local t = {}
	for i = 1, n do t [i] = string.char (math.random (0, 255)) end
	return table.concat (t)
end

local function parseUrl (url)
	url = tostring (url)
	-- bracketed IPv6 literal first (wss://[::1]:8123/path): the general
	-- pattern's [^:/]+ host class stops at the first colon and would hand
	-- NetConnect the string "[". Host is returned WITHOUT brackets (address
	-- APIs want the bare address); the Host header re-adds them.
	local scheme, host, port, path = url:match ('^(%w+)://%[([^%]]+)%]:?(%d*)(/?.*)$')
	if (not scheme) then
		scheme, host, port, path = url:match ('^(%w+)://([^:/]+):?(%d*)(/?.*)$')
	end
	if (not scheme or not host) then return nil end
	if (port == '') then port = (scheme == 'wss') and 443 or 80 end
	if (path == '') then path = '/' end
	return scheme, host, tonumber (port), path
end

-- Encode a client->server frame: FIN set, single frame, always masked per spec.
local function encodeFrame (opcode, payload)
	payload = payload or ''
	local len = #payload
	local b1 = 0x80 + opcode
	local header
	if (len < 126) then
		header = string.char (b1, 0x80 + len)
	elseif (len < 0x10000) then
		header = string.char (b1, 0x80 + 126, math.floor (len / 256) % 256, len % 256)
	else
		-- 64-bit length; our payloads never approach 2^32 so the high word is 0
		header = string.char (b1, 0x80 + 127, 0, 0, 0, 0,
			math.floor (len / 0x1000000) % 256, math.floor (len / 0x10000) % 256,
			math.floor (len / 256) % 256, len % 256)
	end
	local mask = randomBytes (4)
	local out = {}
	for i = 1, len do
		out [i] = string.char (bxor (payload:byte (i), mask:byte ((i - 1) % 4 + 1)))
	end
	return header .. mask .. table.concat (out)
end

-- First free binding whose C4 address slot is empty. delete() releases the slot
-- (SetBindingAddress ''), so a socket torn down mid-reconnect frees its binding
-- shortly after the replacement has already taken the next one -- old and new
-- never share a binding, which is what keeps late callbacks from crossing over.
local function allocBinding ()
	for i = BINDING_MIN, BINDING_MAX - 1 do
		if (not WebSocket.Sockets [i]) then
			local addr = C4.GetBindingAddress and C4:GetBindingAddress (i)
			if (addr == nil or addr == '') then return i end
		end
	end
	return nil
end

function WebSocket:new (url, headers, sslOptions)
	local scheme, host, port, path = parseUrl (url)
	if (not host) then return nil end
	local o = setmetatable ({}, WebSocket)
	o.url, o.host, o.port, o.path = url, host, port, path
	o.ssl = (scheme == 'wss')
	o.sslOptions = sslOptions
	o.extraHeaders = headers
	o.buffer = ''         -- decoded-frame input buffer (post-handshake)
	o.chunks = {}         -- inbound packets not yet folded into buffer
	o.chunkBytes = 0      -- total bytes across chunks
	o.handshakeBuf = ''   -- raw bytes until the HTTP 101 header terminator
	o.fragBuf = nil       -- fragment chunk list across continuation frames
	o.fragBytes = 0       -- total bytes across fragBuf
	o.fragOpcode = nil    -- opcode of the in-progress fragmented message
	o.handshakeDone = false
	o.connected = false   -- TCP up
	o.running = false     -- TCP up AND websocket handshake complete
	o.netBinding = allocBinding ()
	if (not o.netBinding) then return nil end
	WebSocket.Sockets [o.netBinding] = o
	o:setupConnection ()
	return o
end

-- Create the C4 connection and register per-binding dispatch. Done once at
-- construction; the gateway builds a fresh instance per reconnect.
function WebSocket:setupConnection ()
	if (self.ssl) then
		C4:CreateNetworkConnection (self.netBinding, self.host, 'SSL')
		C4:NetPortOptions (self.netBinding, self.port, 'SSL', self.sslOptions or {})
	else
		C4:CreateNetworkConnection (self.netBinding, self.host)
	end
	OCS = OCS or {}
	OCS [self.netBinding] = function (idBinding, nPort, strStatus)
		self:onStatus (strStatus)
	end
	RFN = RFN or {}
	RFN [self.netBinding] = function (idBinding, nPort, strData)
		self:onData (strData)
	end
end

function WebSocket:SetProcessMessageFunction (fn) self.processMessage = fn end
function WebSocket:SetEstablishedFunction (fn) self.established = fn end
function WebSocket:SetOfflineFunction (fn) self.offline = fn end
function WebSocket:SetClosedByRemoteFunction (fn) self.closedByRemote = fn end

function WebSocket:Start ()
	-- a retry on the same instance must be able to report its own failure:
	-- without this reset, an instance that already fired offline once would
	-- swallow the next offline callback and the owner would never reschedule
	self.offlineFired = false
	if (self.netBinding) then
		C4:NetDisconnect (self.netBinding, self.port)
		C4:NetConnect (self.netBinding, self.port)
	end
	return self
end

-- C4 reports the TCP state here (via OCS dispatch). ONLINE -> send the upgrade
-- request; anything else means the socket is gone.
-- Deliver the offline callback at most once per connection. Both the async
-- OFFLINE from the network stack and a synchronous protocol fail() route here,
-- so whichever happens first wins and the other is a no-op.
function WebSocket:fireOffline ()
	if (self.offlineFired) then return end
	self.offlineFired = true
	if (self.offline) then self.offline () end
end

function WebSocket:onStatus (status)
	if (status == 'ONLINE') then
		self.connected = true
		self.offlineFired = false -- a new life may go offline again
		-- fresh connection: drop any receive state left from a prior life
		self.buffer, self.handshakeBuf = '', ''
		self.chunks, self.chunkBytes = {}, 0
		self.fragBuf, self.fragOpcode, self.fragBytes = nil, nil, 0
		self.handshakeDone = false
		self:sendHandshake ()
	else
		self.connected = false
		self.running = false
		self.handshakeDone = false
		self:stopKeepalive ()
		self:fireOffline ()
	end
end

function WebSocket:sendHandshake ()
	if (not C4.Base64Encode) then
		self:fail ('C4:Base64Encode unavailable')
		return
	end
	self.key = C4:Base64Encode (randomBytes (16))
	local req = {
		'GET ' .. self.path .. ' HTTP/1.1',
		-- an IPv6 literal must be bracketed in the Host header (RFC 3986)
		'Host: ' .. (self.host:find (':', 1, true) and ('[' .. self.host .. ']') or self.host)
			.. ':' .. self.port,
		'Upgrade: websocket',
		'Connection: Upgrade',
		'Sec-WebSocket-Key: ' .. self.key,
		'Sec-WebSocket-Version: 13',
	}
	if (self.extraHeaders) then
		for k, v in pairs (self.extraHeaders) do table.insert (req, k .. ': ' .. v) end
	end
	table.insert (req, '') -- blank line + trailing CRLF terminate the headers
	table.insert (req, '')
	local bind, port = self.netBinding, self.port
	C4:SendToNetwork (bind, port, table.concat (req, '\r\n'))
end

-- Inbound bytes. Before the handshake completes we accumulate raw HTTP; after,
-- we feed the frame parser. Bytes that arrive in the same packet as the 101
-- response (a real case with HA) are the first frame and must not be dropped.
function WebSocket:onData (data)
	-- After a graceful Close the disconnect is deferred; ignore any frames that
	-- arrive in that window so a late payload can't drive a second teardown.
	if (not self.connected) then return end
	if (self.handshakeDone) then
		-- Accumulate packets in a chunk list and fold them into the parse
		-- buffer only when a complete frame is present. Appending each packet
		-- to a single string would re-copy the whole accumulated buffer per
		-- packet: O(n^2) over a multi-MB get_states, enough to stall all of
		-- Director for the duration of the fetch.
		self.chunks [#self.chunks + 1] = data
		self.chunkBytes = self.chunkBytes + #data
		self:pump ()
		return
	end
	self.handshakeBuf = self.handshakeBuf .. data
	local headerEnd = self.handshakeBuf:find ('\r\n\r\n', 1, true)
	if (not headerEnd) then
		if (#self.handshakeBuf > MAX_HANDSHAKE) then self:fail ('handshake headers too large') end
		return
	end
	local headers = self.handshakeBuf:sub (1, headerEnd - 1)
	local rest = self.handshakeBuf:sub (headerEnd + 4)
	self.handshakeBuf = ''
	local code = headers:match ('^HTTP/1%.[01] (%d+)')
	if (code ~= '101') then
		self:fail ('handshake rejected: HTTP ' .. tostring (code))
		return
	end
	-- Sec-WebSocket-Accept is advisory; over a trusted LAN the 101 is enough and
	-- validating it risks false negatives across C4:Hash encoding differences.
	self.handshakeDone = true
	self.running = true
	self:startKeepalive ()
	if (self.established) then self.established () end
	self.buffer = ''
	self.chunks, self.chunkBytes = {rest}, #rest
	self:pump ()
end

-- Peek the first `n` bytes across buffer + chunks without folding everything
-- into one string; frame headers are at most 10 bytes so this stays cheap.
function WebSocket:peekHeader (n)
	local s = self.buffer
	local i = 1
	while (#s < n and self.chunks [i]) do
		-- take only the bytes needed: appending a whole large chunk here would
		-- re-copy it on every packet while a split-header frame streams in
		s = s .. self.chunks [i]:sub (1, n - #s)
		i = i + 1
	end
	return s
end

-- Bytes required for the next complete frame (header + payload), or nil when
-- even the header is not here yet. Oversized frames fail here, before any
-- large concatenation happens.
function WebSocket:frameNeed ()
	local hdr = self:peekHeader (10)
	if (#hdr < 2) then return nil end
	local b2 = hdr:byte (2)
	local len = b2 % 0x80
	local pos = 3
	if (len == 126) then
		if (#hdr < 4) then return nil end
		len = hdr:byte (3) * 256 + hdr:byte (4)
		pos = 5
	elseif (len == 127) then
		if (#hdr < 10) then return nil end
		len = 0
		for i = 3, 10 do len = len * 256 + hdr:byte (i) end
		pos = 11
	end
	if (len > MAX_FRAME) then
		self:fail ('frame exceeds max size')
		return nil
	end
	return pos - 1 + len
end

-- Fold chunks into the parse buffer only when the next frame is complete,
-- then let parseBuffer drain every whole frame it can.
function WebSocket:pump ()
	local need = self:frameNeed ()
	if (not need or (#self.buffer + self.chunkBytes) < need) then return end
	if (#self.chunks > 0) then
		self.chunks [0] = self.buffer -- fold the leftover partial in front
		self.buffer = table.concat (self.chunks, '', 0, #self.chunks)
		self.chunks, self.chunkBytes = {}, 0
	end
	self:parseBuffer ()
end

-- Pull every complete frame out of self.buffer; leave a partial frame for the
-- next packet. Server frames are unmasked, but we honor the mask bit anyway.
function WebSocket:parseBuffer ()
	while (true) do
		local buf = self.buffer
		if (#buf < 2) then return end
		local b1, b2 = buf:byte (1), buf:byte (2)
		local fin = (b1 >= 0x80)
		if (math.floor (b1 / 16) % 8 ~= 0) then -- RSV1-3 set, no extension negotiated
			self:fail ('reserved bits set')
			return
		end
		local opcode = b1 % 0x10
		if (b2 >= 0x80) then -- a server MUST NOT mask its frames (RFC 6455 5.1)
			self:fail ('masked frame from server')
			return
		end
		local len = b2 % 0x80
		local pos = 3
		if (len == 126) then
			if (#buf < 4) then return end
			len = buf:byte (3) * 256 + buf:byte (4)
			pos = 5
		elseif (len == 127) then
			if (#buf < 10) then return end
			len = 0
			for i = 3, 10 do len = len * 256 + buf:byte (i) end
			pos = 11
		end
		if (len > MAX_FRAME) then
			self:fail ('frame exceeds max size')
			return
		end
		if (#buf < pos + len - 1) then return end -- full payload not here yet
		local payload = buf:sub (pos, pos + len - 1)
		self.buffer = buf:sub (pos + len)
		self:handleFrame (fin, opcode, payload)
		if (not self.connected) then return end -- a fail()/close during handling tore us down
	end
end

function WebSocket:handleFrame (fin, opcode, payload)
	-- Control frames (RFC 6455 5.4/5.5): never fragmented, <=125 byte payload.
	if (opcode == OP_PING or opcode == OP_PONG or opcode == OP_CLOSE) then
		if (not fin or #payload > 125) then
			self:fail ('malformed control frame')
			return
		end
		if (opcode == OP_PING) then
			self:sendFrame (OP_PONG, payload)
		elseif (opcode == OP_PONG) then
			self.gotPong = true
		else -- OP_CLOSE: Close() echoes a close frame (RFC 5.5.1 MUST) and defers
			 -- the disconnect so the echo flushes, then we notify the gateway.
			self:Close ()
			if (self.closedByRemote) then self.closedByRemote () end
			-- the socket is definitively dead: fire offline now rather than
			-- relying on the deferred NetDisconnect's OFFLINE echo, which is
			-- not guaranteed and whose absence would strand the reconnect
			self:fireOffline ()
		end
		return
	end
	-- Data frames: HA speaks JSON text, so text + its continuations only.
	-- Fragments accumulate in a list (concat once at fin): appending each
	-- continuation to a single string would be quadratic in message size.
	if ((self.fragBytes or 0) + #payload > MAX_FRAME) then -- fragments can't evade the cap
		self:fail ('message exceeds max size')
		return
	end
	if (opcode == OP_CONT) then
		if (not self.fragOpcode) then
			self:fail ('continuation with no message to continue')
			return
		end
		self.fragBuf [#self.fragBuf + 1] = payload
		self.fragBytes = self.fragBytes + #payload
	elseif (opcode == OP_TEXT) then
		if (self.fragOpcode) then
			self:fail ('new data frame during a fragmented message')
			return
		end
		self.fragBuf = {payload}
		self.fragBytes = #payload
		self.fragOpcode = opcode
	else
		self:fail ('unsupported opcode ' .. opcode) -- binary / reserved
		return
	end
	if (fin) then
		local msg = table.concat (self.fragBuf)
		self.fragBuf, self.fragOpcode, self.fragBytes = nil, nil, 0
		if (Debug.Wants (5)) then Debug.Dbg ('ws rx:', loggable (msg)) end
		-- two args: the gateway's callback is fn(ws, data) and reads the second.
		-- pcall so a callback error cannot abort the rest of the frame batch. The
		-- error is logged rather than dropped: swallowing it silently turns any
		-- fault in message handling into "that entity stopped updating" with
		-- nothing to diagnose.
		if (self.processMessage) then
			local ok, err = pcall (self.processMessage, self, msg)
			if (not ok) then
				print ('openhac4: websocket message handler error: ' .. tostring (err))
			end
		end
	end
end

-- `sensitive` marks a frame the caller knows carries a credential (the auth
-- handshake, a service call carrying an alarm code). Text inspection cannot be
-- trusted to find every one of those, so the caller declares it instead.
function WebSocket:sendFrame (opcode, payload, sensitive)
	if (not self.connected) then return false end
	-- guard the call: loggable() copies and scans the payload, which must not
	-- happen per frame when level-5 logging is off
	if (opcode == OP_TEXT and Debug.Wants (5)) then
		Debug.Dbg ('ws tx:', sensitive and '<frame carrying a credential; withheld>' or loggable (payload))
	end
	local bind, port = self.netBinding, self.port
	C4:SendToNetwork (bind, port, encodeFrame (opcode, payload))
	return true
end

function WebSocket:sendCloseFrame (payload)
	pcall (function () self:sendFrame (OP_CLOSE, payload or CLOSE_NORMAL) end)
end

function WebSocket:Send (data, sensitive)
	-- data frames only after the upgrade completes: `connected` means TCP is
	-- up, which includes the window before the server's 101, and a websocket
	-- frame injected into the raw HTTP stream kills the handshake
	if (not self.running) then return false end
	return self:sendFrame (OP_TEXT, data, sensitive)
end

-- Keepalive doubles as dead-peer detection: if no pong came back since the last
-- ping, the link is silently dead, so tear it down and let the gateway
-- reconnect. Guarded so the module still loads if the timer helper is absent.
function WebSocket:startKeepalive ()
	if (type (SetTimer) ~= 'function') then return end
	self.gotPong = true
	SetTimer ('OpenHAC4WSPing' .. self.netBinding, 30000, function ()
		if (not self.running) then
			self:stopKeepalive () -- outlived the socket: self-cancel the repeat
			return
		end
		if (not self.gotPong) then
			self:fail ('no pong from peer')
			return
		end
		self.gotPong = false
		self:sendFrame (OP_PING, '')
	end, true)
end

function WebSocket:stopKeepalive ()
	if (self.netBinding and type (CancelTimer) == 'function') then
		CancelTimer ('OpenHAC4WSPing' .. self.netBinding)
	end
end

function WebSocket:rawClose ()
	if (self.netBinding) then C4:NetDisconnect (self.netBinding, self.port) end
end

function WebSocket:fail (reason)
	-- Record why. Without this every protocol-level failure is indistinguishable
	-- from an unreachable host: the dealer only sees the reconnect countdown.
	self.lastFailure = tostring (reason or 'unspecified')
	Debug.Error ('websocket failed:', self.lastFailure)
	self.running = false
	self:stopKeepalive ()
	self.connected = false
	-- release receive state now: a dead instance lingers until the next
	-- Connect, and with the escalated backoff that can pin megabytes of
	-- partial frame/fragment data for many minutes
	self.buffer, self.handshakeBuf = '', ''
	self.chunks, self.chunkBytes = {}, 0
	self.fragBuf, self.fragOpcode, self.fragBytes = nil, nil, 0
	self:rawClose ()
	-- Fire offline() now rather than waiting only for the async OFFLINE. If the
	-- link is already gone the network stack may deliver no OFFLINE, and the
	-- reconnect is scheduled from offline(), so relying on it alone can wedge the
	-- driver offline for good. fireOffline() dedupes against the async OFFLINE,
	-- and the gateway's scheduleReconnect ignores a duplicate, so the backoff is
	-- not double-counted.
	self:fireOffline ()
end

-- Graceful close: send the close frame, then defer the TCP teardown so it can
-- flush. On delete we also release the binding address for reuse.
function WebSocket:Close ()
	self.running = false
	if (self.connected) then self:sendCloseFrame (CLOSE_NORMAL) end
	self:stopKeepalive ()
	self.connected = false
	local binding, port, release = self.netBinding, self.port, self.deleteAfterClosing
	local teardown = function ()
		C4:NetDisconnect (binding, port)
		if (release) then
			-- release the binding only now, so allocBinding cannot hand it to a
			-- new instance while this teardown is still pending
			if (C4.SetBindingAddress) then C4:SetBindingAddress (binding, '') end
			WebSocket.Sockets [binding] = nil
		end
	end
	if (type (SetTimer) == 'function') then
		SetTimer ('OpenHAC4WSClose' .. binding, CLOSE_DEFER_MS, teardown)
	else
		teardown ()
	end
end

-- Release every socket this driver still owns, including ones whose deferred
-- teardown is still pending. Connect() replaces a socket by calling delete(),
-- which arms a 3 second timer to free the binding; a driver reload inside that
-- window would otherwise kill the timer and strand the binding forever, and
-- allocBinding skips any binding whose address is still set. Called from
-- OnDriverDestroyed.
function WebSocket.DeleteAll ()
	for binding, inst in pairs (WebSocket.Sockets) do
		local done = false
		if (type (inst) == 'table' and inst.delete) then
			done = pcall (function () inst:delete (true) end)
		end
		if (not done) then
			-- No live instance, or its teardown threw. Either way the binding
			-- address may still be set, and leaving it set is precisely the leak
			-- this function exists to prevent, so release it directly.
			if (C4.SetBindingAddress) then
				pcall (function () C4:SetBindingAddress (binding, '') end)
			end
			WebSocket.Sockets [binding] = nil
		end
	end
end

function WebSocket:delete (immediate)
	self.deleteAfterClosing = true
	-- Stop dispatch immediately so no late callback reaches this instance; the
	-- binding slot in Sockets is released by the deferred teardown in Close(),
	-- which keeps allocBinding from reusing it before this connection is gone.
	if (self.netBinding) then
		if (OCS) then OCS [self.netBinding] = nil end
		if (RFN) then RFN [self.netBinding] = nil end
	end
	if (immediate) then
		-- Driver teardown: the Lua state is about to be discarded, so a deferred
		-- teardown timer would never run and the binding address would stay set
		-- forever. allocBinding skips any binding whose address is non-empty, so
		-- every reload would burn one of the hundred slots and the driver would
		-- eventually fail to open a socket at all. Release it here instead, at
		-- the cost of not flushing a close frame.
		self:stopKeepalive ()
		self.running, self.connected = false, false
		self:rawClose ()
		-- a deferred teardown armed by an earlier Close() still holds this
		-- binding's number; the binding is being freed for reuse right now, so
		-- that stale timer must not fire a NetDisconnect at whoever gets it next
		if (type (CancelTimer) == 'function') then
			CancelTimer ('OpenHAC4WSClose' .. self.netBinding)
		end
		if (C4.SetBindingAddress) then C4:SetBindingAddress (self.netBinding, '') end
		WebSocket.Sockets [self.netBinding] = nil
		return nil
	end
	self:Close ()
	return nil
end

return WebSocket
