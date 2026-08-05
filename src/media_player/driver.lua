-- openhac4 Home Assistant Media Player
-- Copyright (c) 2026 cajunflavoredbob. Licensed under the MIT License.
--
-- Transport, volume, source, and now-playing control of a Home Assistant
-- media_player from Control4 programming. This is a control + status device (no
-- navigator "Listen" source tile): the full media_service (MSP) room-audio-
-- source integration is a separate, larger effort and is not included here.

Child = require ('openhac4.child')

do -- globals
	EVENT_PLAYING = 1
	EVENT_PAUSED = 2
	EVENT_STOPPED = 3
	EVENT_OFFLINE = 4

	gState = nil      -- raw HA state string
	gEventClass = nil -- playing/paused/stopped class the last event reflected
	gSynced = false   -- first state after load fires no events
	gSources = {}     -- source_list, for the Select Source picker
end

-- Collapse HA states into the three event classes so transient states do not
-- refire events: playing -> buffering -> playing is one Playing, not two.
-- unknown maps to nil (hold: no event either way).
local function eventClass (s)
	if (s == 'playing' or s == 'buffering') then return 'playing'
	elseif (s == 'paused') then return 'paused'
	elseif (s == 'idle' or s == 'off' or s == 'standby' or s == 'on') then return 'stopped' end
	return nil
end

Child.Setup {
	domain = 'media_player',

	onInit = function ()
		C4:AddVariable ('STATE', '', 'STRING', true, false)
		C4:AddVariable ('MEDIA_TITLE', '', 'STRING', true, false)
		C4:AddVariable ('MEDIA_ARTIST', '', 'STRING', true, false)
		C4:AddVariable ('MEDIA_ALBUM', '', 'STRING', true, false)
		C4:AddVariable ('VOLUME', '0', 'NUMBER', true, false)
		C4:AddVariable ('SOURCE', '', 'STRING', true, false)
	end,

	onState = function (state)
		local s = state.state
		local attrs = state.attributes or {}
		if (type (attrs.source_list) == 'table') then gSources = attrs.source_list end

		local sText = tostring (s or '') -- never write the literal "nil"
		C4:SetVariable ('STATE', sText)
		C4:SetVariable ('MEDIA_TITLE', tostring (attrs.media_title or ''))
		C4:SetVariable ('MEDIA_ARTIST', tostring (attrs.media_artist or ''))
		C4:SetVariable ('MEDIA_ALBUM', tostring (attrs.media_album_name or ''))
		C4:SetVariable ('SOURCE', tostring (attrs.source or ''))
		UpdateProperty ('Current State', sText)
		UpdateProperty ('Now Playing', tostring (attrs.media_title or ''))
		if (attrs.volume_level ~= nil) then
			local vol = math.floor ((tonumber (attrs.volume_level) or 0) * 100 + 0.5)
			C4:SetVariable ('VOLUME', vol)
			UpdateProperty ('Volume', tostring (vol) .. ' %')
		end

		gState = s
		local class = eventClass (s)
		if (gSynced and class and class ~= gEventClass) then
			if (class == 'playing') then C4:FireEventByID (EVENT_PLAYING)
			elseif (class == 'paused') then C4:FireEventByID (EVENT_PAUSED)
			else C4:FireEventByID (EVENT_STOPPED) end
		end
		-- sync only on a classifiable state: an 'unknown' first push must not
		-- count as the baseline, or the first real state fires a false event
		if (class) then
			gEventClass = class
			gSynced = true
		end
	end,

	onOffline = function ()
		UpdateProperty ('Current State', 'Unavailable')
		-- keep the STATE variable honest during the outage, and clear the event
		-- class so the state the entity returns in fires its event again
		C4:SetVariable ('STATE', 'unavailable')
		gEventClass = nil
		C4:FireEventByID (EVENT_OFFLINE)
	end,

	onReset = function ()
		gState = nil
		gEventClass = nil
		gSynced = false
		gSources = {} -- entity changed: drop the old Select Source picker list
		-- clear the previous entity's values from variables and displays: if
		-- the new entity never reports an attribute (a player without volume),
		-- the old entity's value would otherwise stand in for it permanently
		C4:SetVariable ('STATE', '')
		C4:SetVariable ('MEDIA_TITLE', '')
		C4:SetVariable ('MEDIA_ARTIST', '')
		C4:SetVariable ('MEDIA_ALBUM', '')
		C4:SetVariable ('VOLUME', 0)
		C4:SetVariable ('SOURCE', '')
		UpdateProperty ('Now Playing', '')
		UpdateProperty ('Volume', '')
	end,
}

do -- transport / volume / source actions
	EC.Play = function () Child.CallService ('media_play') end
	EC.Pause = function () Child.CallService ('media_pause') end
	EC.Play_Pause = function () Child.CallService ('media_play_pause') end
	EC.Stop = function () Child.CallService ('media_stop') end
	EC.Next = function () Child.CallService ('media_next_track') end
	EC.Previous = function () Child.CallService ('media_previous_track') end
	EC.Turn_On = function () Child.CallService ('turn_on') end
	EC.Turn_Off = function () Child.CallService ('turn_off') end
	EC.Volume_Up = function () Child.CallService ('volume_up') end
	EC.Volume_Down = function () Child.CallService ('volume_down') end
	EC.Mute = function () Child.CallService ('volume_mute', {is_volume_muted = true}) end
	EC.Unmute = function () Child.CallService ('volume_mute', {is_volume_muted = false}) end

	EC.SetVolume = function (tParams)
		local v = tParams and tonumber (tParams.Volume)
		if (v ~= nil) then
			Child.CallService ('volume_set', {volume_level = math.max (0, math.min (100, v)) / 100})
		end
	end

	EC.SelectSource = function (tParams)
		local src = tParams and tParams.Source
		if (src and tostring (src) ~= '') then
			Child.CallService ('select_source', {source = tostring (src)})
		end
	end
end

-- CUSTOM_SELECT populator for the Select Source action
function GetMediaSources () return gSources end

-- Programming Device Specific Commands normalize the display name (spaces to
-- underscores). Alias the two-word commands to the Actions-tab handlers so both
-- routes reach the same code.
EC.Set_Volume = EC.SetVolume
EC.Select_Source = EC.SelectSource
