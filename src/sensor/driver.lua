-- openhac4 Home Assistant Sensor
-- Copyright (c) 2026 cajunflavoredbob. Licensed under the MIT License.
--
-- Maps a Home Assistant sensor entity (numeric or string) to Control4
-- device variables and properties for use in programming. No proxy: sensors
-- are informational, surfaced through the SENSOR_VALUE variable.

Child = require ('openhac4.child')

do -- globals
	EVENT_CHANGED = 1
	EVENT_OFFLINE = 2
	gLastValue = nil
end

Child.Setup {
	domain = 'sensor',

	onInit = function ()
		C4:AddVariable ('SENSOR_VALUE', '', 'STRING', true, false)
		C4:AddVariable ('SENSOR_VALUE_NUMBER', '0', 'NUMBER', true, false)
		C4:AddVariable ('UNIT', '', 'STRING', true, false)
	end,

	onState = function (state)
		local value = tostring (state.state or '') -- never store the literal "nil"
		-- 'unknown' is a transient (HA restart, integration blip), not a
		-- reading: hold the last real value. Writing 0 here would look like a
		-- legitimate reading and misfire threshold programming. An empty
		-- string is NOT filtered: text sensors legitimately report it.
		if (value == 'unknown') then
			UpdateProperty ('Current Value', 'Unknown')
			return
		end
		local attrs = state.attributes or {}
		local unit = attrs.unit_of_measurement or ''

		C4:SetVariable ('SENSOR_VALUE', value)
		-- the numeric variable updates only on numeric readings; a string
		-- sensor leaves it at its previous (or initial 0) value
		local n = tonumber (value)
		if (n ~= nil) then
			C4:SetVariable ('SENSOR_VALUE_NUMBER', n)
		end
		C4:SetVariable ('UNIT', unit)

		UpdateProperty ('Current Value', value)
		UpdateProperty ('Unit', unit)

		if (gLastValue ~= nil and gLastValue ~= value) then
			C4:FireEventByID (EVENT_CHANGED)
		end
		gLastValue = value
	end,

	onOffline = function ()
		UpdateProperty ('Current Value', 'Unavailable')
		C4:FireEventByID (EVENT_OFFLINE)
	end,

	onReset = function ()
		gLastValue = nil
	end,
}
