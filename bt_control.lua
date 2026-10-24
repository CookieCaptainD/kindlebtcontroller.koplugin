--[[
Kindle Bluetooth control through the btfd LIPC service.

Everything here talks to Amazon's `com.lab126.btfd` daemon with the stock
`lipc-get-prop` / `lipc-set-prop` / `lipc-hash-prop` tools:

  * power on/off, with several fallbacks. Which property/value format
    actually (re)starts the stack differs between Kindle models and between a
    warm state and a cold boot with Bluetooth off, so the attempts are tried
    in order and each one is given time to take effect.
  * scanning (`triggerBTscan`, then `ListDiscovered`)
  * bonding / connecting (`Bond`, `Connect`, then `ListPaired`)

The property names and the output format of `lipc-hash-prop` are the ones
documented by the audiobook.koplugin project (stradichenko/audiobook.koplugin),
which verified them on a Paperwhite 5. This file is an independent
implementation written for this plugin.

UNTESTED ON REAL HARDWARE by its author: the logic is covered by tests that use
fake lipc binaries, which can not prove how a real Kindle firmware behaves.

All waiting is done with an injected scheduler (UIManager:scheduleIn in the
plugin) so the KOReader UI never blocks while the radio comes up.
]]

local BtControl = {}

local SERVICE = "com.lab126.btfd"

-- How long (in polls) each power attempt gets before the next one is tried.
BtControl.POLL_INTERVAL = 0.5
BtControl.FIRST_ATTEMPT_POLLS = 20   -- 10 s: a cold start can be slow
BtControl.OTHER_ATTEMPT_POLLS = 14   -- 7 s

-- ---------------------------------------------------------------
--  shell helpers
-- ---------------------------------------------------------------

local function readCommand(cmd)
    local handle = io.popen(cmd)
    if not handle then return "" end
    local out = handle:read("*a") or ""
    handle:close()
    return (out:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function exec(cmd)
    local a, _b, c = os.execute(cmd)
    if type(a) == "number" then return a == 0 end
    return a == true and (c == nil or c == 0)
end

local function isMac(mac)
    return type(mac) == "string" and mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end
BtControl.isMac = isMac

local function setProp(prop, value)
    -- value is quoted; it only ever comes from this file or a validated MAC
    return exec(string.format("lipc-set-prop %s %s '%s' 2>/dev/null", SERVICE, prop, value))
end

-- ---------------------------------------------------------------
--  state
-- ---------------------------------------------------------------

--- BTstate: 0 = off, anything above 0 = on (2+ can mean "connected").
function BtControl.getState()
    local out = readCommand(string.format("timeout 2 lipc-get-prop %s BTstate 2>/dev/null", SERVICE))
    return tonumber(out:match("%-?%d+")) or 0
end

function BtControl.isOn()
    return BtControl.getState() > 0
end

--- 1 = Audible available, 0 = not, nil = unknown. Without Audible some
--- firmware only accepts the "1:1" / "0:1" pair format for BTenable.
local function audibleAvailable()
    local out = readCommand(string.format("lipc-get-prop %s isAudibleAvailable 2>/dev/null", SERVICE))
    if out:match("^%d") then return tonumber(out:match("^%d+")) end
    return nil
end

-- ---------------------------------------------------------------
--  generic polling
-- ---------------------------------------------------------------

--- Call check() immediately and then every `interval` seconds, up to
--- `max_polls` extra times. on_done(true) as soon as check() is truthy,
--- on_done(false) when the polls are used up.
function BtControl.poll(check, schedule, interval, max_polls, on_done)
    local polls = 0
    local function step()
        if check() then
            on_done(true)
            return
        end
        polls = polls + 1
        if polls > max_polls then
            on_done(false)
            return
        end
        schedule(interval, step)
    end
    step()
end

-- ---------------------------------------------------------------
--  power
-- ---------------------------------------------------------------

--- Ordered list of { label, set = function } power attempts.
function BtControl.buildAttempts(enable)
    local attempts = {}
    local function add(label, prop, value)
        table.insert(attempts, {
            label = label,
            run = function() return setProp(prop, value) end,
        })
    end

    local pair_first = audibleAvailable() == 0
    if enable then
        add("BTflightMode 0", "BTflightMode", "0")
        if pair_first then
            add("BTenable 1:1", "BTenable", "1:1")
            add("BTenable true", "BTenable", "true")
        else
            add("BTenable true", "BTenable", "true")
            add("BTenable 1:1", "BTenable", "1:1")
        end
    else
        add("BTflightMode 1", "BTflightMode", "1")
        if pair_first then
            add("BTenable 0:1", "BTenable", "0:1")
            add("BTenable false", "BTenable", "false")
        else
            add("BTenable false", "BTenable", "false")
            add("BTenable 0:1", "BTenable", "0:1")
        end
    end
    return attempts
end

--- Turn Bluetooth on or off without blocking.
--- opts.schedule(delay, fn)  required (UIManager:scheduleIn)
--- opts.on_done(ok, info)    info = { tried = {labels}, via = label, state = n }
function BtControl.setPower(enable, opts)
    local schedule = opts.schedule
    local on_done = opts.on_done
    local interval = opts.interval or BtControl.POLL_INTERVAL

    local function reached()
        return (BtControl.getState() > 0) == enable
    end

    if reached() then
        on_done(true, { tried = {}, via = "already", state = BtControl.getState() })
        return
    end

    local attempts = BtControl.buildAttempts(enable)
    local tried = {}
    local index = 0

    local function nextAttempt()
        index = index + 1
        if index > #attempts then
            on_done(false, { tried = tried, state = BtControl.getState() })
            return
        end
        local attempt = attempts[index]
        table.insert(tried, attempt.label)
        attempt.run()

        local max_polls = index == 1 and BtControl.FIRST_ATTEMPT_POLLS or BtControl.OTHER_ATTEMPT_POLLS
        BtControl.poll(reached, schedule, interval, max_polls, function(ok)
            if ok then
                on_done(true, { tried = tried, via = attempt.label, state = BtControl.getState() })
            else
                nextAttempt()
            end
        end)
    end

    nextAttempt()
end

-- ---------------------------------------------------------------
--  device lists
-- ---------------------------------------------------------------

--- Parse `lipc-hash-prop` output:
---   Hash Index: 0
---     bd_address = "AA:BB:CC:DD:EE:FF"
---     bd_name = "Some Controller"
---     is_paired = (1)
function BtControl.parseHash(text)
    local entries = {}
    local current
    for line in (text or ""):gmatch("[^\r\n]+") do
        if line:match("^%s*Hash Index") then
            current = {}
            table.insert(entries, current)
        elseif current then
            local key, str = line:match('^%s*([%w_]+)%s*=%s*"(.*)"%s*$')
            if key then
                current[key] = str
            else
                local key2, num = line:match("^%s*([%w_]+)%s*=%s*%(?(%-?%d+)%)?%s*$")
                if key2 then current[key2] = tonumber(num) end
            end
        end
    end
    return entries
end

local function listProp(prop)
    local out = readCommand(string.format("lipc-hash-prop %s %s 2>/dev/null", SERVICE, prop))
    local devices = {}
    for _i, entry in ipairs(BtControl.parseHash(out)) do
        if isMac(entry.bd_address) then
            table.insert(devices, {
                address = entry.bd_address:upper(),
                name = entry.bd_name or "",
                paired = entry.is_paired == 1,
                connected = entry.is_connected == 1,
            })
        end
    end
    return devices
end

function BtControl.getPaired()
    return listProp("ListPaired")
end

function BtControl.getConnected()
    return listProp("ListConnected")
end

function BtControl.isPaired(mac)
    mac = (mac or ""):upper()
    for _i, device in ipairs(BtControl.getPaired()) do
        if device.address == mac then return true, device end
    end
    return false
end

--- Devices found by the last scan, de-duplicated by address. Unnamed entries
--- (mostly BLE beacons) are left out unless opts.include_unnamed is set.
--- Sorted: not yet paired first, then by name.
function BtControl.getDiscovered(opts)
    opts = opts or {}
    local by_address, devices = {}, {}

    local function absorb(list)
        for _i, device in ipairs(list) do
            local known = by_address[device.address]
            if not known then
                known = { address = device.address, name = "", paired = false, connected = false }
                by_address[device.address] = known
                table.insert(devices, known)
            end
            if device.name ~= "" then known.name = device.name end
            known.paired = known.paired or device.paired
            known.connected = known.connected or device.connected
        end
    end
    absorb(listProp("ListDiscovered"))
    absorb(listProp("ListPaired"))

    local result = {}
    for _i, device in ipairs(devices) do
        if device.name ~= "" or opts.include_unnamed then
            table.insert(result, device)
        end
    end
    table.sort(result, function(a, b)
        if a.paired ~= b.paired then return not a.paired end
        return a.name:lower() < b.name:lower()
    end)
    return result
end

-- ---------------------------------------------------------------
--  actions
-- ---------------------------------------------------------------

function BtControl.startScan()
    return setProp("triggerBTscan", "1")
end

function BtControl.bond(mac)
    if not isMac(mac) then return false end
    return setProp("Bond", mac)
end

function BtControl.connect(mac)
    if not isMac(mac) then return false end
    return setProp("Connect", mac)
end

return BtControl
