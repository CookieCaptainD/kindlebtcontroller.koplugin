--[[
System preparation helpers for kindlebtcontroller.koplugin

Replaces the manual SSH steps that used to be required before the plugin could
talk to a Bluetooth HID controller:

  1. mntroot rw
  2. create /usr/local/bin/dev_is_keyboard.sh (+ chmod +x)
  3. create /etc/udev/rules.d/99-bt-keyboard.rules and reload udev
  4. touch DISABLE_CORE_DUMP / DISABLE_CORE_DUMP_ALERT
  5. remove the "!" from the first `if` of /usr/bin/dmcc.sh

Everything here is idempotent: running it twice is harmless.

NOTE: this module has NOT been tested on real Kindle hardware by its author.
The file contents are taken verbatim from the project README / MobileRead guide.
The dmcc.sh edit is deliberately conservative (see patchDmcc) and is skipped
with a warning when the file does not look as expected.
]]

local Device = require("device")
local logger = require("logger")
local _ = require("gettext_btcontroller")

local SystemSetup = {}

local SCRIPT_PATH = "/usr/local/bin/dev_is_keyboard.sh"
local RULES_PATH = "/etc/udev/rules.d/99-bt-keyboard.rules"
local DMCC_PATH = "/usr/bin/dmcc.sh"
local DMCC_BACKUP = "/usr/bin/dmcc.sh.kindlebtcontroller.bak"
local MARKER_FILES = {
    "/mnt/us/DISABLE_CORE_DUMP",
    "/mnt/us/DISABLE_CORE_DUMP_ALERT",
}
local PAIR_LOG = "/tmp/kindlebtcontroller_pair.log"

local SCRIPT_CONTENT = [[
#!/bin/sh
DEVICE=$1
if evtest info $DEVICE | grep -q 'Event type 1 (Key)'; then
  if evtest info $DEVICE | grep -q 'Event code 16 (Q)'; then
    # Don't set these just because Key is supported -- that will
    # detect the touchscreen as a keyboard which breaks the UI
    echo ID_INPUT=1
    echo ID_INPUT_KEY=1
    echo ID_INPUT_KEYBOARD=1
  fi
fi
]]

local RULES_CONTENT = [[
KERNEL=="uhid", MODE="0660", GROUP="bluetooth"
ACTION=="add", SUBSYSTEM=="input", IMPORT+="/usr/local/bin/dev_is_keyboard.sh %N"
]]

-- Kindle models older than the tested ones (KPW5, KPW6, Kindle 2024).
-- The README warns that the pairing method can white-screen these devices.
-- Names are KOReader's Device.model values; unknown names are NOT blocked, the
-- user still has to confirm a dialog that shows the detected model.
local UNSUPPORTED_MODELS = {
    Kindle = true, Kindle2 = true, KindleDXG = true, Kindle3 = true, Kindle4 = true,
    KindleTouch = true, KindlePaperWhite = true, KindlePaperWhite2 = true,
    KindleBasic = true, KindleVoyage = true, KindlePaperWhite3 = true,
    KindleOasis = true, KindleBasic2 = true, KindleOasis2 = true,
    KindlePaperWhite4 = true, KindleBasic3 = true, KindleOasis3 = true,
}

-- ---------------------------------------------------------------
--  small helpers
-- ---------------------------------------------------------------

local function readFile(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read("*all")
    file:close()
    return content
end

local function writeFile(path, content)
    local file, err = io.open(path, "w")
    if not file then return false, err end
    file:write(content)
    file:close()
    return true
end

--- Run a shell command; true when it exits with status 0 (LuaJIT/5.1 and 5.2+).
local function exec(cmd)
    local a, _b, c = os.execute(cmd)
    if type(a) == "number" then return a == 0 end
    return a == true and (c == nil or c == 0)
end

--- mkdir -p for the directory that contains `path`.
local function ensureParentDir(path)
    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" then
        exec("mkdir -p '" .. dir .. "'")
    end
end

local function isRoot()
    local handle = io.popen("id -u 2>/dev/null")
    if not handle then return false end
    local uid = handle:read("*l")
    handle:close()
    return uid == "0"
end

-- ---------------------------------------------------------------
--  device / environment checks
-- ---------------------------------------------------------------

function SystemSetup.getModel()
    return tostring(Device.model or "unknown")
end

function SystemSetup.isUnsupportedModel()
    return UNSUPPORTED_MODELS[Device.model or ""] == true
end

--- Are the system tools used by the setup present on this device?
function SystemSetup.hasTools()
    return exec("command -v evtest >/dev/null 2>&1 && command -v udevadm >/dev/null 2>&1 && command -v mntroot >/dev/null 2>&1")
end

-- ---------------------------------------------------------------
--  dmcc.sh handling (conservative)
-- ---------------------------------------------------------------

--- Locate the first line that starts with `if`. Returns start, end, text.
local function findFirstIf(content)
    local pos = 1
    local length = #content
    while pos <= length do
        local newline = content:find("\n", pos, true)
        local line_end = newline and (newline - 1) or length
        local line = content:sub(pos, line_end)
        if line:match("^%s*if%s") then
            return pos, line_end, line
        end
        pos = (newline or length) + 1
    end
    return nil
end

--- Classify the first `if` line of dmcc.sh.
--- Returns "patched" | "unpatched" | "unknown", plus the corrected line when "unpatched".
--- Only a line that mentions "core" and has an unambiguous negation is touched.
local function analyzeDmccLine(line)
    if not line:lower():find("core", 1, true) then
        return "unknown"
    end
    -- `if ! cmd ...`
    local fixed, count = line:gsub("^(%s*if%s+)!%s*", "%1")
    if count == 0 then
        -- `if [ ! -f file ]`
        fixed, count = line:gsub("(%[%s+)!%s+", "%1", 1)
    end
    if count > 0 then
        return "unpatched", fixed
    end
    if not line:find("!", 1, true) then
        return "patched"
    end
    return "unknown"
end

local function getDmccState()
    local content = readFile(DMCC_PATH)
    if not content then return "missing" end
    local _s, _e, line = findFirstIf(content)
    if not line then return "unknown" end
    return (analyzeDmccLine(line))
end

local function patchDmcc()
    local content = readFile(DMCC_PATH)
    if not content then return "missing" end
    local s, e, line = findFirstIf(content)
    if not line then return "unknown" end
    local state, fixed = analyzeDmccLine(line)
    if state ~= "unpatched" then return state, line end

    if not readFile(DMCC_BACKUP) then
        local ok = writeFile(DMCC_BACKUP, content)
        if not ok then return "error" end
    end
    local new_content = content:sub(1, s - 1) .. fixed .. content:sub(e + 1)
    local ok = writeFile(DMCC_PATH, new_content)
    if not ok then return "error" end
    return "patched"
end

-- ---------------------------------------------------------------
--  state
-- ---------------------------------------------------------------

--- Inspect the system. `ok` is true when nothing is left to do.
function SystemSetup.getState()
    local script = readFile(SCRIPT_PATH)
    local rules = readFile(RULES_PATH)

    local state = {
        script = script ~= nil and script:find("Event code 16 (Q)", 1, true) ~= nil,
        rules = rules ~= nil and rules:find("dev_is_keyboard.sh", 1, true) ~= nil,
        markers = true,
        dmcc = getDmccState(),
    }
    for _i, path in ipairs(MARKER_FILES) do
        local file = io.open(path, "r")
        if file then file:close() else state.markers = false end
    end
    state.ok = state.script and state.rules and state.markers and state.dmcc ~= "unpatched"
    return state
end

-- ---------------------------------------------------------------
--  apply
-- ---------------------------------------------------------------

--- Perform the whole system preparation.
--- Returns success (bool) and a list of { level = "ok"|"warn"|"error", msg = string }.
function SystemSetup.apply()
    local steps = {}
    local function add(level, msg)
        table.insert(steps, { level = level, msg = msg })
        logger.info("BT Plugin setup [" .. level .. "]: " .. msg)
    end

    if SystemSetup.isUnsupportedModel() then
        add("error", string.format(_("设备型号 %s 不受支持"), SystemSetup.getModel()))
        return false, steps
    end
    if not isRoot() then
        add("error", _("需要 root 权限才能修改系统文件"))
        return false, steps
    end
    if not exec("mntroot rw") then
        add("error", _("无法将系统分区切换为可写"))
        return false, steps
    end

    local core_ok = true
    local pcall_ok, pcall_err = pcall(function()
        ensureParentDir(SCRIPT_PATH)
        ensureParentDir(RULES_PATH)

        local ok, err = writeFile(SCRIPT_PATH, SCRIPT_CONTENT)
        if ok and exec("chmod +x " .. SCRIPT_PATH) then
            add("ok", _("已安装输入设备识别脚本"))
        else
            core_ok = false
            add("error", string.format(_("写入 %s 失败：%s"), SCRIPT_PATH, tostring(err or "chmod")))
        end

        ok, err = writeFile(RULES_PATH, RULES_CONTENT)
        if ok then
            add("ok", _("已安装 udev 规则"))
        else
            core_ok = false
            add("error", string.format(_("写入 %s 失败：%s"), RULES_PATH, tostring(err)))
        end

        if core_ok then
            if exec("udevadm control --reload-rules && udevadm trigger") then
                add("ok", _("已重载 udev 规则"))
            else
                add("warn", _("udev 规则重载失败，重启 Kindle 后生效"))
            end
        end

        local markers_ok = true
        for _i, path in ipairs(MARKER_FILES) do
            local file = io.open(path, "r")
            if file then
                file:close()
            elseif not writeFile(path, "") then
                markers_ok = false
            end
        end
        if markers_ok then
            add("ok", _("已关闭断开连接时的核心转储日志"))
        else
            add("warn", _("无法创建核心转储标记文件"))
        end

        local dmcc_state = patchDmcc()
        if dmcc_state == "patched" then
            add("ok", _("已调整 dmcc.sh（原文件已备份）"))
        elseif dmcc_state == "error" then
            add("warn", _("修改 dmcc.sh 失败，已跳过"))
        else
            add("warn", _("dmcc.sh 与预期不符，已跳过（可选步骤，详见 README）"))
        end
    end)

    if not pcall_ok then
        core_ok = false
        add("error", tostring(pcall_err))
    end

    -- always give the root filesystem back as read-only
    exec("mntroot ro")

    return core_ok, steps
end

-- ---------------------------------------------------------------
--  pairing (experimental)
-- ---------------------------------------------------------------

function SystemSetup.isValidMac(mac)
    return type(mac) == "string" and mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

function SystemSetup.hasPairTool()
    return exec("command -v ace_bt_cli >/dev/null 2>&1")
end

--- Feed `pair <mac>` + `connectedlist` to ace_bt_cli and return its (cleaned) output.
--- The CLI is interactive and its exact behaviour with piped input has not been
--- verified, so callers must confirm success by looking at the system state
--- (paired list / input device) instead of parsing this output.
function SystemSetup.pair(mac)
    if not SystemSetup.isValidMac(mac) then return false, "invalid_mac" end
    if not SystemSetup.hasPairTool() then return false, "missing_tool" end

    os.remove(PAIR_LOG)
    local cmd = string.format(
        "(sleep 1; printf 'pair %s\\n'; sleep 15; printf 'connectedlist\\n'; sleep 3) | timeout 40 ace_bt_cli > %s 2>&1",
        mac, PAIR_LOG)
    exec(cmd)

    local log = readFile(PAIR_LOG) or ""
    log = log:gsub("[%c]", function(c) return c == "\n" and c or "" end)
    return true, log
end

return SystemSetup
