-- openhac4 Home Assistant Light
-- Copyright (c) 2026 cajunflavoredbob. Licensed under the MIT License.
--
-- Maps a Home Assistant light entity onto a Control4 light_v2 proxy with
-- brightness, full color (CIE xy) and color temperature. Actual behavior
-- adapts to the entity's reported supported_color_modes; C4's own Hue
-- driver likewise declares full color capability statically and adapts.
--
-- Protocol reference (snap-one docs-driverworks-proxyprotocol):
--   RX  SET_BRIGHTNESS_TARGET {LIGHT_BRIGHTNESS_TARGET (0-100 float), RATE ms}
--   RX  SET_COLOR_TARGET      {LIGHT_COLOR_TARGET_X/Y (CIE 1931), MODE, RATE}
--   RX  ON / OFF / SYNCHRONIZE
--   TX  LIGHT_BRIGHTNESS_CHANGED {LIGHT_BRIGHTNESS_CURRENT}
--   TX  LIGHT_COLOR_CHANGED     {LIGHT_COLOR_CURRENT_X/Y, ..._COLOR_MODE}
--   TX  ONLINE_CHANGED          {STATE}

Child = require ('openhac4.child')

do -- globals
	LIGHT_BINDING = 5001
	EVENT_OFFLINE = 1

	-- HA brightness is 0-255; C4 light_v2 brightness is 0-100
	gBrightnessPct = 0   -- last brightness we reported to C4 (0-100)
	gHasBrightness = false
	gHasColor = false    -- xy / hs / rgb family
	gHasCCT = false      -- color_temp
	gLastColor = nil     -- last color pushed to the proxy, for SYNCHRONIZE
	gOnline = false      -- last online state pushed, for SYNCHRONIZE
end

local function haToPct (b255)
	b255 = tonumber (b255)
	if (not b255) then return 0 end
	local pct = math.floor ((b255 / 255 * 100) + 0.5)
	-- a barely-on light (brightness 1-2) rounds to 0; keep it visibly on
	if (pct < 1) then pct = 1 end
	return pct
end

local function pctTo255 (pct)
	return math.floor ((tonumber (pct) / 100 * 255) + 0.5)
end

local function tableHas (t, v)
	if (type (t) ~= 'table') then return false end
	for _, x in ipairs (t) do
		if (x == v) then return true end
	end
	return false
end

local function detectCaps (state)
	local modes = state.attributes and state.attributes.supported_color_modes
	if (type (modes) ~= 'table') then modes = {} end
	gHasCCT = tableHas (modes, 'color_temp')
	gHasColor = tableHas (modes, 'xy') or tableHas (modes, 'hs') or
		tableHas (modes, 'rgb') or tableHas (modes, 'rgbw') or tableHas (modes, 'rgbww')
	-- brightness is implied by any mode other than onoff
	gHasBrightness = (#modes > 0 and not (#modes == 1 and modes [1] == 'onoff'))

	local tags = {}
	if (gHasBrightness) then table.insert (tags, 'dim') end
	if (gHasCCT) then table.insert (tags, 'cct') end
	if (gHasColor) then table.insert (tags, 'color') end
	if (#tags == 0) then table.insert (tags, 'on/off') end
	UpdateProperty ('Detected Capabilities', table.concat (tags, ', '))
end

-- Push current HA state into the C4 proxy
-- Optional color-mode preference (advisory): some HA lights misbehave when
-- addressed via CIE xy, so the dealer can force RGB or HS. Conversions start
-- from the xy the light_v2 proxy provides.
local function xyToRGB (x, y)
	if (y <= 0) then return 0, 0, 0 end
	local Y = 1.0
	local X = (Y / y) * x
	local Z = (Y / y) * (1 - x - y)
	local r =  X * 3.2406 - Y * 1.5372 - Z * 0.4986
	local g = -X * 0.9689 + Y * 1.8758 + Z * 0.0415
	local b =  X * 0.0557 - Y * 0.2040 + Z * 1.0570
	local function gamma (c)
		c = math.max (0, c)
		return (c <= 0.0031308) and (12.92 * c) or (1.055 * c ^ (1 / 2.4) - 0.055)
	end
	r, g, b = gamma (r), gamma (g), gamma (b)
	local m = math.max (r, g, b, 1)
	return math.floor (r / m * 255 + 0.5), math.floor (g / m * 255 + 0.5), math.floor (b / m * 255 + 0.5)
end

local function rgbToHS (r, g, b)
	r, g, b = r / 255, g / 255, b / 255
	local mx, mn = math.max (r, g, b), math.min (r, g, b)
	local h, s, d = 0, 0, mx - mn
	if (d > 0 and mx > 0) then
		s = d / mx
		if (mx == r) then h = ((g - b) / d) % 6
		elseif (mx == g) then h = (b - r) / d + 2
		else h = (r - g) / d + 4 end
		h = h * 60
		if (h < 0) then h = h + 360 end
	end
	return h, s * 100
end

-- HA color service params for the configured Color Mode preference
local function colorParams (x, y, rate)
	local p = {transition = rate / 1000}
	local pref = Properties ['Color Mode'] or 'Auto'
	if (pref == 'RGB') then
		local r, g, b = xyToRGB (x, y)
		p.rgb_color = {r, g, b}
	elseif (pref == 'HS') then
		local r, g, b = xyToRGB (x, y)
		local h, s = rgbToHS (r, g, b)
		p.hs_color = {math.floor (h + 0.5), math.floor (s + 0.5)}
	else -- Auto / XY
		p.xy_color = {x, y}
	end
	return p
end

local function reflectState (state)
	-- 'unknown' is a transient (HA restart, integration blip), not a real
	-- off: hold the last state so the proxy does not see a spurious off/on
	if (state.state == 'unknown') then
		return
	end
	local on = (state.state == 'on')
	local attrs = state.attributes or {}

	detectCaps (state)

	-- brightness: on/off-only lights report 100 when on, 0 when off. A
	-- dimmable light that is on but momentarily reports no brightness holds
	-- the last known level rather than claiming full.
	local pct
	if (not on) then
		pct = 0
	elseif (gHasBrightness and attrs.brightness ~= nil) then
		pct = haToPct (attrs.brightness)
	elseif (gHasBrightness and gBrightnessPct > 0) then
		pct = gBrightnessPct
	else
		pct = 100
	end
	gBrightnessPct = pct
	C4:SendToProxy (LIGHT_BINDING, 'LIGHT_BRIGHTNESS_CHANGED', {LIGHT_BRIGHTNESS_CURRENT = pct})

	-- color: report xy + mode when the light is on and has color info
	if (on) then
		local x, y, mode
		if (attrs.color_mode == 'color_temp' and tonumber (attrs.color_temp_kelvin)) then
			x, y = C4:ColorCCTtoXY (tonumber (attrs.color_temp_kelvin))
			mode = 1
		elseif (type (attrs.xy_color) == 'table') then
			x, y = tonumber (attrs.xy_color [1]), tonumber (attrs.xy_color [2])
			mode = 0
		end
		if (x and y) then
			gLastColor = {x = x, y = y, mode = mode} -- for SYNCHRONIZE replay
			C4:SendToProxy (LIGHT_BINDING, 'LIGHT_COLOR_CHANGED', {
				LIGHT_COLOR_CURRENT_X = x,
				LIGHT_COLOR_CURRENT_Y = y,
				LIGHT_COLOR_CURRENT_COLOR_MODE = mode,
			})
		end
	end

	-- Entity Status holds the raw HA state like every other driver; the
	-- brightness percentage lives in its own Current Level property
	UpdateProperty ('Entity Status', state.state)
	UpdateProperty ('Current Level', on and (tostring (pct) .. '%') or 'off')
end

Child.Setup {
	domain = 'light',

	onState = function (state)
		gOnline = true
		C4:SendToProxy (LIGHT_BINDING, 'ONLINE_CHANGED', {STATE = true})
		reflectState (state)
	end,

	onOffline = function ()
		gOnline = false
		C4:SendToProxy (LIGHT_BINDING, 'ONLINE_CHANGED', {STATE = false})
		UpdateProperty ('Entity Status', 'unavailable')
		C4:FireEventByID (EVENT_OFFLINE)
	end,

	onReset = function ()
		gBrightnessPct = 0
		gLastColor = nil
		gOnline = false
	end,
}

do -- light_v2 proxy commands
	-- a resync replays everything the proxy shows, not just brightness: a
	-- brightness-only reply leaves stale color and a default online status
	RFP.SYNCHRONIZE = function ()
		C4:SendToProxy (LIGHT_BINDING, 'ONLINE_CHANGED', {STATE = gOnline})
		C4:SendToProxy (LIGHT_BINDING, 'LIGHT_BRIGHTNESS_CHANGED', {LIGHT_BRIGHTNESS_CURRENT = gBrightnessPct})
		if (gLastColor) then
			C4:SendToProxy (LIGHT_BINDING, 'LIGHT_COLOR_CHANGED', {
				LIGHT_COLOR_CURRENT_X = gLastColor.x,
				LIGHT_COLOR_CURRENT_Y = gLastColor.y,
				LIGHT_COLOR_CURRENT_COLOR_MODE = gLastColor.mode,
			})
		end
	end

	RFP.ON = function ()
		Child.Debug.Trace ('RFP ON')
		Child.CallService ('turn_on')
	end

	RFP.OFF = function ()
		Child.Debug.Trace ('RFP OFF')
		Child.CallService ('turn_off')
	end

	RFP.SET_BRIGHTNESS_TARGET = function (idBinding, strCommand, tParams)
		Child.TraceParams ('RFP SET_BRIGHTNESS_TARGET', tParams)
		local target = tonumber (tParams.LIGHT_BRIGHTNESS_TARGET or tParams.LEVEL) or 0
		local rate = tonumber (tParams.RATE or tParams.TIME) or 0

		-- acknowledge we are acting on it
		C4:SendToProxy (LIGHT_BINDING, 'LIGHT_BRIGHTNESS_CHANGING', {
			LIGHT_BRIGHTNESS_CURRENT = gBrightnessPct,
			LIGHT_BRIGHTNESS_TARGET = target,
			RATE = rate,
		})

		if (target <= 0) then
			Child.CallService ('turn_off', {transition = rate / 1000})
		elseif (gHasBrightness) then
			Child.CallService ('turn_on', {brightness = pctTo255 (target), transition = rate / 1000})
		else
			-- on/off-only light: any positive target means on
			Child.CallService ('turn_on')
		end
	end

	RFP.SET_COLOR_TARGET = function (idBinding, strCommand, tParams)
		Child.TraceParams ('SET_COLOR_TARGET params:', tParams)
		local x = tonumber (tParams.LIGHT_COLOR_TARGET_X or tParams.LIGHT_COLOR_TARGET_X_CIE_1931)
		local y = tonumber (tParams.LIGHT_COLOR_TARGET_Y)
		local mode = tonumber (tParams.LIGHT_COLOR_TARGET_MODE or tParams.LIGHT_COLOR_TARGET_COLOR_MODE) or 0
		local rate = tonumber (tParams.LIGHT_COLOR_TARGET_RATE or tParams.RATE) or 0

		if (not (x and y)) then
			return
		end

		-- Pick the action BEFORE acknowledging: sending LIGHT_COLOR_CHANGING
		-- and then dropping the command leaves the UI stuck mid-"changing".
		-- Cross-fallbacks cover a UI wheel the entity's family doesn't match:
		-- a color pick on a CCT-only bulb converts to the nearest Kelvin, a
		-- CCT pick on a color-only bulb goes through as xy.
		local action
		if (mode == 1) then
			action = (gHasCCT and 'cct') or (gHasColor and 'color') or nil
		else
			action = (gHasColor and 'color') or (gHasCCT and 'cct') or nil
		end
		if (not action) then
			return -- neither color family: nothing to act on
		end

		-- resolve the CCT conversion BEFORE the ack: a saturated xy from the
		-- color wheel can make the conversion fail or produce garbage, and a
		-- throw after LIGHT_COLOR_CHANGING would strand the UI mid-"changing"
		local kelvin
		if (action == 'cct') then
			local ok, k = pcall (function () return C4:ColorXYtoCCT (x, y) end)
			k = ok and tonumber (k) or nil
			if (not k or k ~= k or k == math.huge or k == -math.huge) then
				return -- unconvertible pick: drop it before acking
			end
			-- clamp to a sane emitter range; HA rejects absurd kelvins
			kelvin = math.floor (math.max (1000, math.min (10000, k)) + 0.5)
		end

		C4:SendToProxy (LIGHT_BINDING, 'LIGHT_COLOR_CHANGING', {
			LIGHT_COLOR_TARGET_X_CIE_1931 = x,
			LIGHT_COLOR_TARGET_Y = y,
			LIGHT_COLOR_TARGET_COLOR_MODE = mode,
			LIGHT_COLOR_TARGET_COLOR_RATE = rate,
		})

		if (action == 'cct') then
			Child.CallService ('turn_on', {color_temp_kelvin = kelvin, transition = rate / 1000})
		else
			Child.CallService ('turn_on', colorParams (x, y, rate))
		end
	end
end
