--===========================================================================
-- probe_peripheral.lua  ·  Peripheral discovery tool
--
-- Prints everything a block exposes to CC:Tweaked: its type(s), every method,
-- and the return value of each no-arg getter. Use this to find out EMPIRICALLY
-- whether the PneumaticCraft refinery (or any block) is readable, and what its
-- methods actually return -- before writing a monitor around them.
--
-- Usage:
--   probe_peripheral                      -- auto-find first refinery/tank match
--   probe_peripheral left                 -- probe a specific side/wired name
--   probe_peripheral back refinery        -- side + a type keyword to match
--
--   Output is also saved to probe_<target>.txt next to this script.
--
-- Nothing readable? The block isn't a CC:T peripheral. Either place the
-- computer adjacent to it, attach a Wired Modem + cable (right-click modem to
-- connect), or -- if still nothing -- the mod doesn't expose it at all and you
-- fall back to comparator/redstone signals.
--
-- Hardware: Computer + the target block adjacent or on a wired network.
--===========================================================================

-- ponytail: one-shot diagnostic. Output is tee'd to a log file by reassigning
-- the global print/printError once (cheaper than threading a logger through ~40
calls). Ceiling: the reassignment is process-wide -- fine for a diagnostic.

local args = { ... }
local keyword = args[2] or "refinery"   -- type substring to match in auto mode

---------------------------------------------------------------- formatters
local function sep(c)
    print(string.rep(c or "-", 50))
end

-- one-line, length-capped summary of any value
local function summarize(v, depth)
    depth = depth or 0
    if depth > 2 then return "..." end
    local tv = type(v)
    if tv == "nil" then return "nil" end
    if tv == "string" then
        v = v:gsub("\194\167.", "")  -- strip MC colour codes
        return #v > 40 and ('"' .. v:sub(1, 37) .. '..."') or ('"' .. v .. '"')
    end
    if tv == "number" or tv == "boolean" then return tostring(v) end
    if tv == "table" then
        -- count + sample of keys
        local keys, n = {}, 0
        for k in pairs(v) do n = n + 1; if #keys < 5 then keys[#keys + 1] = tostring(k) end end
        local sample = table.concat(keys, ", ")
        if #keys < n then sample = sample .. ", ..." end
        return "{n=" .. n .. "  [" .. sample .. "]}"
    end
    if tv == "function" then return "<function>" end
    return "<" .. tv .. ">"
end

-- full serialize for table drilldown
local function dump(v, indent)
    indent = indent or ""
    if type(v) ~= "table" then print(indent .. summarize(v)); return end
    -- arrays: show first 8 elements
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    if n == 0 then print(indent .. "{}"); return end
    for k, val in pairs(v) do
        local ks = type(k) == "string" and k or "[" .. tostring(k) .. "]"
        if type(val) == "table" then
            print(indent .. ks .. ":")
            dump(val, indent .. "  ")
        else
            print(indent .. ks .. " = " .. summarize(val))
        end
    end
end

---------------------------------------------------------------- find target
local function getTypes(name)
    -- CC:T: getType returns primary string; getTypes (newer) returns all.
    local t = peripheral.getType(name)
    if type(t) == "table" then return t end
    return { t }
end

local function typeMatches(name, kw)
    kw = kw:lower()
    for _, ty in ipairs(getTypes(name)) do
        if ty and ty:lower():find(kw) then return true end
    end
    return false
end

local function findTarget(kw)
    local hit = {}
    local all = {}
    for _, name in ipairs(peripheral.getNames()) do
        local types = getTypes(name)
        all[#all + 1] = name .. "  (" .. table.concat(types, ", ") .. ")"
        if typeMatches(name, kw) then hit[#hit + 1] = name end
    end
    return hit, all
end

---------------------------------------------------------------- probe
local function probe(name)
    local p = peripheral.wrap(name)
    if not p then
        printError("Cannot wrap '" .. name .. "'.")
        return
    end

    sep("=")
    print("PERIPHERAL:  " .. name)
    print("TYPE(S):     " .. table.concat(getTypes(name), ", "))
    local methods = peripheral.getMethods(name)
    print("METHODS:     " .. #methods)
    sep("-")

    -- 1. list every method
    for _, m in ipairs(methods) do print("  ." .. m) end
    sep("-")

    -- 2. call each method with NO args, show return; catch arity errors
    print("NO-ARG CALLS:")
    for _, m in ipairs(methods) do
        local fn = p[m]
        if type(fn) == "function" then
            local ok, res = pcall(fn)
            if ok then
                print(string.format("  %-22s -> %s", m, summarize(res)))
            else
                local err = tostring(res):match(":[^:]*$") or tostring(res)
                print(string.format("  %-22s -> (needs args) %s", m, err))
            end
        end
    end
    sep("-")

    -- 3. full dump of any table-returning no-arg getter (the interesting ones)
    print("TABLE DRILLDOWN (no-arg getters returning tables):")
    local any = false
    for _, m in ipairs(methods) do
        local fn = p[m]
        if type(fn) == "function" then
            local ok, res = pcall(fn)
            if ok and type(res) == "table" then
                any = true
                print("\n[" .. m .. "]")
                dump(res, "  ")
            end
        end
    end
    if not any then print("  (none -- all no-arg calls returned scalars/nil)") end
    sep("=")
end

---------------------------------------------------------------- output tee
-- ponytail: capture every print()/printError() line into a buffer AND echo it
-- to the terminal, then flush to disk at the end. One global swap beats
-- editing every call site.
local LOG_LINES, LOG_TARGET = {}, nil
local BUILTIN_PRINT = print
local BUILTIN_ERROR = printError

local function joinArgs(...)
    local t, parts = {...}, {}
    for i = 1, #t do parts[i] = tostring(t[i]) end
    return table.concat(parts, "\t")
end
print = function(...)
    local s = joinArgs(...)
    BUILTIN_PRINT(s)
    LOG_LINES[#LOG_LINES + 1] = s
end
printError = function(...)
    local s = joinArgs(...)
    BUILTIN_ERROR(s)
    LOG_LINES[#LOG_LINES + 1] = "[error] " .. s
end

local function saveLog()
    local base = LOG_TARGET and tostring(LOG_TARGET):gsub("[^%w_.-]", "_") or "output"
    local path = "probe_" .. base .. ".txt"
    local f = fs.open(path, "w")
    if not f then
        BUILTIN_PRINT("Could not write log to " .. path)
        return
    end
    f.write(table.concat(LOG_LINES, "\n"))
    f.close()
    BUILTIN_PRINT("\nLog written to: " .. path)
end

---------------------------------------------------------------- main
local function main()
    local name = args[1]

    if not name then
        -- auto mode: find by keyword
        print("Auto-finding peripherals matching '" .. keyword .. "'...")
        local hits, all = findTarget(keyword)
        if #hits == 0 then
            print("\nNo match. Peripherals connected to this computer:")
            if #all == 0 then
                print("  (NONE -- nothing is adjacent or wired to this computer)")
                print("  Wire the refinery via a Wired Modem + cable, or place the")
                print("  computer directly against the block, then re-run.")
            else
                for _, line in ipairs(all) do print("  " .. line) end
                print("\nIf the refinery isn't listed, PneumaticCraft does not expose")
                print("it as a CC:T peripheral -> use comparator/redstone signals.")
            end
            return
        end
        name = hits[1]
        if #hits > 1 then
            print("Multiple matches (" .. table.concat(hits, ", ") ..
                  "); probing '" .. name .. "'. Pass a name to choose another.")
        end
    end

    LOG_TARGET = name
    probe(name)
end

main()
saveLog()
