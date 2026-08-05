-- openhac4 Home Assistant Alarm Control Panel
-- Copyright (c) 2026 cajunflavoredbob. Licensed under the MIT License.
--
-- Maps a Home Assistant alarm_control_panel entity onto a Control4 security
-- panel + partition proxy (single partition). Control4 arm/disarm commands call
-- the matching Home Assistant services with the entered code passed straight
-- through; Home Assistant state is reflected to the partition, including HA's
-- native arming/pending as exit/entry delay. Zones, local PIN validation, and
-- notifications are not included in this version.

Child = require ('openhac4.child')

do -- globals
	PANEL_BINDING = 5001     -- securitypanel proxy
	PARTITION_BINDING = 5002 -- security (partition) proxy
	PARTITION_ID = 1         -- single partition; binding id is PARTITION_ID + 5001
	                         -- (numeric: PANEL_PARTITION_STATE types PARTITION_ID as num)
	EVENT_UNAVAILABLE = 1

	gInitSent = false -- first state goes as PARTITION_STATE_INIT (no programming)
	gLastState = 'DISARMED_NOT_READY' -- last partition state; NOT_READY until an
	gLastType = nil                   -- entity is bound and reports in
end

-- Control4 ArmType (from PARTITION_ARM) -> Home Assistant arm service. Keys are
-- the arm_states labels declared in driver.xml; matched case-insensitively.
local ARM_SERVICE = {
	Away = 'alarm_arm_away',
	Home = 'alarm_arm_home',
	Night = 'alarm_arm_night',
	Vacation = 'alarm_arm_vacation',
	['Custom Bypass'] = 'alarm_arm_custom_bypass',
}

-- Home Assistant armed_* state -> Control4 PARTITION_STATE TYPE label
local ARM_TYPE = {
	armed_away = 'Away',
	armed_home = 'Home',
	armed_night = 'Night',
	armed_vacation = 'Vacation',
	armed_custom_bypass = 'Custom Bypass',
}

local function armService (armType)
	armType = tostring (armType or '')
	if (ARM_SERVICE [armType]) then return ARM_SERVICE [armType] end
	local low = armType:lower ()
	for k, v in pairs (ARM_SERVICE) do
		if (k:lower () == low) then return v end
	end
	-- unmapped ArmType: fail the arm rather than substituting a different
	-- mode. Home/stay is the LEAST protective armed mode, so silently arming
	-- it in place of an intended Away would downgrade protection.
	Child.Debug.Warn ('alarm: unrecognized ArmType "' .. armType .. '", arm rejected')
	return nil
end

-- HA state -> Control4 partition (STATE, TYPE)
local function partitionState (s)
	if (s == 'disarmed') then return 'DISARMED_READY'
	-- 'disarming' intentionally unmapped: reporting DISARMED_READY while HA is
	-- still disarming lies in the armed->disarmed direction; hold the previous
	-- state until 'disarmed' arrives. 'unknown' likewise holds.
	elseif (s == 'arming') then return 'EXIT_DELAY'
	elseif (s == 'pending') then return 'ENTRY_DELAY'
	elseif (s == 'triggered') then return 'ALARM', 'Burglary'
	elseif (ARM_TYPE [s]) then return 'ARMED', ARM_TYPE [s] end
	return nil
end

-- Partition roster for the panel proxy, in the security protocol's wire shape:
-- an XML string payload (not a params table) listing each partition's id,
-- enabled flag, partition binding, and current state with the arm type as the
-- state element's type attribute. Sent as the ALL_PARTITIONS_INFO notification,
-- both unsolicited at init and as the answer to GET_ALL_PARTITION_INFO /
-- GET_PANEL_SETUP. This is what ComposerPro's Partitions display reads.
function SendAllPartitionsInfo ()
	local xml = '<partitions><partition>' ..
		'<id>' .. PARTITION_ID .. '</id>' ..
		'<enabled>true</enabled>' ..
		'<binding_id>' .. PARTITION_BINDING .. '</binding_id>' ..
		'<state type="' .. tostring (gLastType or '') .. '">' ..
		tostring (gLastState) .. '</state>' ..
		'</partition></partitions>'
	C4:SendToProxy (PANEL_BINDING, 'ALL_PARTITIONS_INFO', xml, 'NOTIFY')
end

Child.Setup {
	domain = 'alarm_control_panel',

	onInit = function ()
		-- Announce the partition to the panel unprompted: the panel proxy's
		-- runtime partition table starts empty, GET_ALL_PARTITION_INFO is not
		-- guaranteed to ever arrive, and a driver that stays quiet reads as
		-- "No Partition Found" in ComposerPro forever. Announced at init, before
		-- any entity is bound, so the partition shows even with no Home
		-- Assistant connection.
		C4:SendToProxy (PARTITION_BINDING, 'PARTITION_ENABLED', {ENABLED = 'true'}, 'NOTIFY')
		C4:SendToProxy (PARTITION_BINDING, 'PARTITION_STATE_INIT', {STATE = gLastState}, 'NOTIFY')
		C4:SendToProxy (PANEL_BINDING, 'PANEL_PARTITION_STATE',
			{PARTITION_ID = PARTITION_ID, STATE = gLastState}, 'NOTIFY')
		C4:SendToProxy (PANEL_BINDING, 'PANEL_INITIALIZED', {}, 'NOTIFY')
		SendAllPartitionsInfo ()
		Child.Debug.Info ('alarm init announce: PARTITION_ENABLED+STATE_INIT(5002), PANEL_PARTITION_STATE+PANEL_INITIALIZED+ALL_PARTITIONS_INFO(5001)')
	end,

	onState = function (ha)
		local s = ha.state
		local attrs = ha.attributes or {}

		C4:SendToProxy (PARTITION_BINDING, 'CODE_REQUIRED', {
			CODE_REQUIRED_TO_ARM = (attrs.code_arm_required == false) and 'False' or 'True',
		}, 'NOTIFY')

		local state, armType = partitionState (s)
		if (state) then
			gLastState, gLastType = state, armType
			Child.Debug.Info ('alarm state:', tostring (s), '->', tostring (state))
			local p = {STATE = state}
			if (armType) then p.TYPE = armType end
			-- first push initializes the partition without firing programming
			C4:SendToProxy (PARTITION_BINDING,
				gInitSent and 'PARTITION_STATE' or 'PARTITION_STATE_INIT', p, 'NOTIFY')
			-- mirror every state to the panel proxy: this feeds the ComposerPro
			-- Partitions display
			local pp = {PARTITION_ID = PARTITION_ID, STATE = state}
			if (armType) then pp.TYPE = armType end
			C4:SendToProxy (PANEL_BINDING, 'PANEL_PARTITION_STATE', pp, 'NOTIFY')
			gInitSent = true
		end
		UpdateProperty ('Alarm Panel State', tostring (s))
	end,

	onOffline = function ()
		UpdateProperty ('Alarm Panel State', 'Unavailable')
		gLastState, gLastType = 'OFFLINE', nil -- a stale TYPE must not ride
		C4:SendToProxy (PARTITION_BINDING, 'PARTITION_STATE', {STATE = 'OFFLINE'}, 'NOTIFY')
		C4:SendToProxy (PANEL_BINDING, 'PANEL_PARTITION_STATE',
			{PARTITION_ID = PARTITION_ID, STATE = 'OFFLINE'}, 'NOTIFY')
		C4:FireEventByID (EVENT_UNAVAILABLE)
	end,

	onReset = function ()
		gInitSent = false
		gLastState, gLastType = 'DISARMED_NOT_READY', nil
		-- push the reset state to both proxies: without this the partition
		-- keeps displaying the previous entity's state (possibly ARMED) until
		-- the new entity's first push. INIT form so no programming fires.
		C4:SendToProxy (PARTITION_BINDING, 'PARTITION_STATE_INIT', {STATE = gLastState}, 'NOTIFY')
		C4:SendToProxy (PANEL_BINDING, 'PANEL_PARTITION_STATE',
			{PARTITION_ID = PARTITION_ID, STATE = gLastState}, 'NOTIFY')
		UpdateProperty ('Alarm Panel State', '')
	end,

	-- Home Assistant rejected an arm/disarm call: tell the partition so the
	-- navigator shows the failure instead of silently ignoring it.
	onServiceResult = function (service, success)
		if (success) then return end
		if (service == 'alarm_disarm') then
			C4:SendToProxy (PARTITION_BINDING, 'DISARM_FAILED', {}, 'NOTIFY')
		elseif (type (service) == 'string' and service:find ('^alarm_arm')) then
			C4:SendToProxy (PARTITION_BINDING, 'ARM_FAILED', {}, 'NOTIFY')
		end
	end,
}

do -- proxy commands (Control4 -> Home Assistant). PIN passed straight through.
	local function withCode (tp)
		local c = tp.UserCode
		if (c ~= nil and tostring (c) ~= '') then return {code = tostring (c)} end
		return {}
	end

	RFP.PARTITION_ARM = function (idBinding, strCommand, tp)
		local service = armService (tp.ArmType)
		if (not service) then
			-- fail-safe: an unmapped ArmType surfaces as a failed arm rather
			-- than silently arming some other mode
			C4:SendToProxy (PARTITION_BINDING, 'ARM_FAILED', {}, 'NOTIFY')
			return
		end
		Child.CallService (service, withCode (tp))
	end

	RFP.PARTITION_DISARM = function (idBinding, strCommand, tp)
		Child.CallService ('alarm_disarm', withCode (tp))
	end

	-- ARM_CANCEL carries no user code in the proxy protocol, so on a panel
	-- that requires a code to disarm, HA rejects this and the partition shows
	-- DISARM_FAILED via onServiceResult: canceling an exit delay from
	-- Control4 needs a codeless panel; otherwise the user disarms with the
	-- code instead. Documented limitation.
	RFP.ARM_CANCEL = function ()
		Child.CallService ('alarm_disarm', {})
	end

	-- The securitypanel proxy (binding 5001) asks the driver to enumerate its
	-- partitions; the answer is the ALL_PARTITIONS_INFO notification, not a
	-- return value. GET_PANEL_SETUP is the same request one level up.
	RFP.GET_ALL_PARTITION_INFO = function (idBinding)
		Child.Debug.Info ('alarm: GET_ALL_PARTITION_INFO on binding', idBinding)
		SendAllPartitionsInfo ()
	end

	RFP.GET_PANEL_SETUP = function (idBinding)
		Child.Debug.Info ('alarm: GET_PANEL_SETUP on binding', idBinding)
		SendAllPartitionsInfo ()
	end

	RFP.READ_PANEL_INFO = function (idBinding)
		Child.Debug.Info ('alarm: READ_PANEL_INFO on binding', idBinding)
		SendAllPartitionsInfo ()
	end

	-- no zones in this version; answer with an empty roster so the panel's
	-- Zones view settles instead of waiting
	RFP.GET_ALL_ZONE_INFO = function (idBinding)
		Child.Debug.Info ('alarm: GET_ALL_ZONE_INFO on binding', idBinding)
		C4:SendToProxy (PANEL_BINDING, 'ALL_ZONES_INFO', '<zones></zones>', 'NOTIFY')
	end

	-- The panel can enable or disable a partition. Single partition here, so this
	-- is acknowledged and logged rather than acted on.
	RFP.SET_PARTITION_ENABLED = function (idBinding, strCommand, tParams)
		Child.Debug.Info ('alarm: SET_PARTITION_ENABLED', tostring (tParams.ENABLED))
	end

	-- Catch-all for the panel binding: log any other command the panel sends so
	-- the exact panel-to-driver handshake is observable during bring-up. Named
	-- handlers above take precedence over this per-binding fallback.
	RFP [PANEL_BINDING] = function (idBinding, strCommand, tParams)
		Child.Debug.Info ('alarm: panel binding', idBinding, 'cmd', tostring (strCommand))
	end
end
