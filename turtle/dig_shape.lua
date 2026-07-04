--[[
  dig_shape.lua — turtle dig tool. Two modes:

  === ROOM ===  carve a rectangular room.
  Turtle starts at the LOWER-LEFT-FRONT corner, facing the LENGTH direction.

    WIDTH  = blocks across  (left/right)
    HEIGHT = blocks up       (1 is fine; 1x1x1 is rejected — nothing to dig)
    LENGTH = blocks forward  (face this way at start)

  Pattern: vertical wave (boustrophedon in the vertical plane). The turtle
  mines a 1x1 shaft UP through HEIGHT at the first floor cell, steps sideways
  at the TOP to the next cell, mines DOWN, steps sideways at the FLOOR, mines
  UP, and so on. Every block is mined with exactly one move into it — no
  wasted descent. Across the W x L floor the path also snakes.

  === HILL ===  smooth the interior terrain to match the outside perimeter.
  Turtle starts at the (0,0) corner of a W x L rectangle, ground level.

    WIDTH  = blocks across  (left/right)
    LENGTH = blocks forward  (face this way at start)

  Two phases:
    1. SURVEY — walk the outside ring (the cells just beyond the rectangle),
       probing each cell's ground height by descending to the floor WITHOUT
       digging (non-destructive: terrain is climbed over, never carved).
    2. CARVE  — for each interior column, smoothstep+bilinear-blend the four
       edge samples into a target surface height, then shave the column down
       to that height. Carve-only: pits below the target surface are left.

  The result is a smooth basin/ramp that meets the surrounding ground at every
  edge, with no hard ridge. ponytail: column-wave carve (fly to each column's
  terrain top, descend-digging to target, never touching ground below target).
  A layer model can't express arbitrary non-monotonic surfaces; columns are
  independent and correct.

  === Inventory (both modes) ===
    slot 1 = FUEL  only (never dropped as loot, never mined into)
    slot 2 = CHEST (auto-placed; chained into a row when one fills up)
    slots 3-16 = loot. Fuel is ONLY slot 1 — add more there when it empties.

  Extras (both modes):
    - Pre-flight fuel check + greedy burn of slot 1
    - Inventory-full mid-dig: returns to start, offloads into chests (places/
      chains them, ground-dump fallback if out of chests), then resumes at the
      exact cell it left off
    - Resume after restart: progress saved to .dig_shape_state each step;
      re-running with the same dims+mode resumes (hill skips the survey too),
      else starts fresh
    - Block logging: every block is inspected before digging; all blocks are
      tallied and reported at the end, shown live
    - Gravel/falling-block re-dig, live status display with live block
      counts + ETA, chat alerts

  Alerts: uses a Plethora/Sc-Peripherals `chatBox` if present, else falls
  back to `rednet.broadcast` if a modem is attached, else just prints.

  Usage:  dig_shape <width> <height> <length>   -- room mode (CLI)
          dig_shape                              -- guided: pick shape + dims
--]]

local args = { ... }

-- --- argument parsing: CLI if given, else interactive guided prompts -----
local WIDTH, HEIGHT, LENGTH
local mode = "room"   -- "room" or "hill"; CLI defaults to room

local function readNumber(prompt)
  while true do
    io.write(prompt)
    local s = io.read()
    if not s then return nil end   -- EOF / Ctrl-D
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then
      print("  (enter a number)")
    else
      local n = tonumber(s)
      if n and n == math.floor(n) and n >= 1 then return n end
      print("  must be a positive integer")
    end
  end
end

local function readChoice(prompt, options)
  while true do
    print(prompt)
    for i, opt in ipairs(options) do
      print(("  %d) %s"):format(i, opt.label))
    end
    io.write("Choice [1-" .. #options .. "]: ")
    local s = io.read()
    if not s then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    local n = tonumber(s)
    if n and n >= 1 and n <= #options then return options[n].value end
    print("  invalid choice")
  end
end

if #args >= 3 then
  -- CLI: always room mode
  WIDTH  = tonumber(args[1])
  HEIGHT = tonumber(args[2])
  LENGTH = tonumber(args[3])
  if not (WIDTH and HEIGHT and LENGTH)
     or WIDTH < 1 or HEIGHT < 1 or LENGTH < 1 then
    printError("width, height and length must be positive integers")
    return
  end
else
  -- guided mode
  term.clear(); term.setCursorPos(1, 1)
  print("=== dig_shape guided setup ===")
  print("")
  local shape = readChoice("Mine which shape?", {
    { label = "rectangular room",                              value = "room" },
    { label = "smooth terrain to perimeter (probe + carve)",   value = "hill" },
  })
  if not shape then return end   -- EOF
  mode = shape
  print("")
  WIDTH  = readNumber("Width  (blocks across, left/right):  ")
  LENGTH = readNumber("Length (blocks forward, face this way): ")
  if not (WIDTH and LENGTH) then return end
  if mode == "room" then
    HEIGHT = readNumber("Height (blocks up, 1 ok):            ")
    if not HEIGHT then return end
    if WIDTH * HEIGHT * LENGTH < 2 then
      printError("1x1x1 has nothing to dig (the turtle is already in the only cell).")
      printError("Increase at least one dimension.")
      return
    end
  end
end

local FUEL_SLOT   = 1
local CHEST_SLOT  = 2
local STUCK_LIMIT = 15   -- failed move attempts before declaring stuck
local STATE_FILE  = ".dig_shape_state"

-- --- chat / log alerts -------------------------------------------------
local chatBox = peripheral.find("chatBox")
local modem   = peripheral.find("modem")
if modem and modem.isOpen then
  pcall(function() modem.open(65535) end)  -- ponytail: ignore if already open
end

local function notify(level, msg)
  local full = ("[%s] %s"):format(level or "INFO", msg)
  print(full)
  if chatBox then
    pcall(function() chatBox.say(full) end)   -- Plethora: broadcast nearby
  elseif modem then
    pcall(function() rednet.broadcast(full, "dig_shape") end)
  end
end

-- --- run state (declared early so display/loops close over it) ---------
local totalColumns = WIDTH * LENGTH   -- progress total (both modes)
local doneColumns  = 0                -- progress done
local startTime    = os.clock()       -- for ETA (process time)
local pos          = { x = 0, y = 0, z = 0 }
local heading      = { x = 0, z = 1 }
-- room sweep cursors
local w            = 0          -- current width index  [0..WIDTH-1]
local l            = 0          -- current length index [0..LENGTH-1]
local lengthDir    = 1          -- +1 or -1 (snake direction along z)
local goingUp      = true       -- vertical direction of the current column
-- hill cursors
local carveX       = 0          -- next interior column to carve [0..WIDTH-1]
local carveZ       = 0          -- [0..LENGTH-1]
local carveDir     = 1          -- +1 / -1 along z within a width row
local surveyed     = false      -- hill: perimeter survey completed?
local aborting     = false
local chestsUsed   = 0
local blockLog     = {}         -- block name (no namespace) -> count
local fillerName   = nil        -- hill fill mode: item name to place in pits
                                -- (nil = carve-only). Set from slot 3 at startup.

-- terminal width cache (stock turtle is 39x13; no resize in CC:T)
local TW = select(1, term.getSize()) or 39
local function trunc(s, width)
  width = width or TW
  return #s <= width and s or s:sub(1, width)
end

-- --- live status display ----------------------------------------------
-- Format seconds into a short human-ish duration (e.g. "2m 13s", "1h 4m").
local function fmtTime(s)
  s = math.floor(s or 0)
  if s < 60 then return s .. "s" end
  if s < 3600 then return math.floor(s/60) .. "m " .. (s%60) .. "s" end
  return math.floor(s/3600) .. "h " .. math.floor((s%3600)/60) .. "m"
end

local function setStatus(msg)
  term.setCursorPos(1, 1); term.clearLine(); term.write(trunc(msg or ""))
  term.setCursorPos(1, 2); term.clearLine()
  term.write(trunc(("Progress: %d / %d  (%d%%)"):format(
        doneColumns, totalColumns,
        math.floor(doneColumns / totalColumns * 100))))
  -- ponytail: os.clock() is CPU time, excludes sleep/idle (e.g. fuel pause),
  -- so ETA skews low during waits — acceptable on a small terminal.
  term.setCursorPos(1, 3); term.clearLine()
  local elapsed = os.clock() - startTime
  local eta = (doneColumns > 0) and (elapsed / doneColumns) * (totalColumns - doneColumns) or nil
  local etaStr = eta and (" ETA %s"):format(fmtTime(eta)) or ""
  term.write(trunc(("Fuel: %s%s"):format(tostring(turtle.getFuelLevel()), etaStr)))
end

local function log(msg)
  local _, h = term.getSize()
  term.setCursorPos(1, h); term.scroll(1); term.write(trunc(msg or ""))
end

-- Live block-count panel: lines 4..(h-1), one block per line, top counts
-- first. Bottom line (h) stays reserved for log() event messages.
local function drawBlockCounts()
  local _, th = term.getSize()
  local last = th - 1
  local names = {}
  for n in pairs(blockLog) do names[#names + 1] = n end
  table.sort(names, function(a, b)
    if blockLog[a] ~= blockLog[b] then return blockLog[a] > blockLog[b] end
    return a < b
  end)
  for y = 4, last do term.setCursorPos(1, y); term.clearLine() end
  local y = 4
  for _, n in ipairs(names) do
    if y > last then break end
    term.setCursorPos(1, y)
    -- ponytail: "name xNNNN" must fit terminal width; truncate the NAME,
    -- keep the count visible.
    local suffix = (" x%d"):format(blockLog[n])
    local maxName = TW - #suffix
    local display = (#n <= maxName) and n or (n:sub(1, maxName - 1) .. "~")
    term.write(display .. suffix)
    y = y + 1
  end
end

-- --- state persistence ------------------------------------------------
local function saveState(extra)
  local f = fs.open(STATE_FILE, "w")
  if not f then return end
  local tbl = {
    mode         = mode,
    dims         = { WIDTH, HEIGHT or 0, LENGTH },
    pos          = pos,
    heading      = heading,
    -- room cursors
    w            = w,
    l            = l,
    lengthDir    = lengthDir,
    goingUp      = goingUp,
    -- hill cursors
    carveX       = carveX,
    carveZ       = carveZ,
    carveDir     = carveDir,
    surveyed     = surveyed,
    perimeter    = (mode == "hill") and _G.perimeterHeights or nil,
    -- shared
    doneColumns  = doneColumns,
    aborting     = aborting,
    chestsUsed   = chestsUsed,
    blockLog     = blockLog,
  }
  for k, v in pairs(extra or {}) do tbl[k] = v end
  f.write(textutils.serialize(tbl))
  f.close()
end

local function clearState()
  if fs.exists(STATE_FILE) then fs.delete(STATE_FILE) end
end

-- Returns true if a matching in-progress job was restored.
local function tryResume()
  if not fs.exists(STATE_FILE) then return false end
  local f = fs.open(STATE_FILE, "r")
  if not f then return false end
  local ok, data = pcall(textutils.unserialize, f.readAll())
  f.close()
  if not ok or type(data) ~= "table" or not data.dims then return false end
  if data.mode ~= mode then return false end   -- different mode; start fresh
  local d = data.dims
  if d[1] ~= WIDTH or d[3] ~= LENGTH then return false end
  if mode == "room" and d[2] ~= HEIGHT then return false end
  -- opt-in: never silently resume. Ask the user first.
  local dc = data.doneColumns or 0
  print(("Found in-progress %s job: %d/%d columns done."):format(mode, dc, totalColumns))
  print("Place the turtle back at the ORIGINAL start corner, facing the")
  print("ORIGINAL start direction, then answer 'y'.")
  io.write("Resume it? [y/N]: ")
  local s = io.read()
  if not s or s:sub(1,1):lower() ~= "y" then return false end   -- start fresh
  -- RE-ANCHOR: assume the user re-placed the turtle at the home corner.
  -- The dig loop navigates via goTo to the saved cursor before continuing.
  pos, heading     = { x = 0, y = 0, z = 0 }, { x = 0, z = 1 }
  w, l, lengthDir  = data.w or 0, data.l or 0, data.lengthDir or 1
  goingUp          = data.goingUp
  if goingUp == nil then goingUp = true end
  carveX, carveZ, carveDir = data.carveX or 0, data.carveZ or 0, data.carveDir or 1
  surveyed         = data.surveyed or false
  doneColumns      = dc
  aborting         = data.aborting or false
  chestsUsed       = data.chestsUsed or 0
  blockLog         = data.blockLog or data.oreLog or {}
  if mode == "hill" and data.perimeter then _G.perimeterHeights = data.perimeter end
  notify("RESUME", ("Resuming %s at column %d/%d"):format(mode, dc, totalColumns))
  return true
end

-- --- fuel -------------------------------------------------------------
-- Burn from `slot` until level reaches `target` (default: greedy/all) or the
-- slot is empty.
local function refuelFrom(slot, target)
  if turtle.getFuelLevel() == "unlimited" then return end
  target = target or math.huge
  turtle.select(slot)
  while turtle.getFuelLevel() < target and turtle.refuel(1) do end
  turtle.select(1)
end

-- --- block logging ----------------------------------------------------
-- ponytail: CC:T turtle.inspect() has no displayName for blocks, so derive a
-- readable name from the registry id: strip ANY namespace, swap '_' for
-- spaces, Title Case.
local function niceName(id)
  if not id then return "" end
  local short = id:gsub("^.*:", "")
  short = short:gsub("_", " ")
  short = short:gsub("%a", function(c) return c:upper() end, 1)
  short = short:gsub(" (%a)", function(c) return c:upper() end)
  return short
end

-- hill fill: pull a filler block from any loot slot matching fillerName.
-- Returns true if a slot was selected, false if out of filler.
local function selectFiller()
  if not fillerName then return false end
  for s = 3, 16 do
    local item = turtle.getItemDetail(s)
    if item and item.name == fillerName then
      turtle.select(s)
      return true
    end
  end
  return false
end

local function noteBlock(info)
  if not info then return end
  local display = niceName(info.name)
  if display == "" then return end
  blockLog[display] = (blockLog[display] or 0) + 1
  drawBlockCounts()
end

-- --- falling-block-safe dig/move helpers ------------------------------
local function digUntilClear(detect, dig, inspectFn)
  local tries = 0
  while detect() and tries < 40 do
    if inspectFn then
      local ok, info = inspectFn()
      if ok then noteBlock(info) end
    end
    dig(); sleep(0.3); tries = tries + 1
  end
end

-- ponytail: one table-driven mover replaces three near-identical functions.
local MOVERS = {
  forward = { name = "forward", detect = turtle.detect,     dig = turtle.dig,     insp = turtle.inspect,
              move = turtle.forward },
  up      = { name = "up",      detect = turtle.detectUp,    dig = turtle.digUp,    insp = turtle.inspectUp,
              move = turtle.up },
  down    = { name = "down",    detect = turtle.detectDown,  dig = turtle.digDown,  insp = turtle.inspectDown,
              move = turtle.down },
}

local function safeMove(m)
  digUntilClear(m.detect, m.dig, m.insp)
  local tries = 0
  while not m.move() do
    if turtle.getFuelLevel() == 0 then
      refuelFrom(FUEL_SLOT)
      if turtle.getFuelLevel() == 0 then
        notify("FUEL", "Out of fuel! Add fuel to slot 1, then press any key.")
        setStatus("OUT OF FUEL — waiting for refuel...")
        os.pullEvent("key")
        refuelFrom(FUEL_SLOT)
      end
    end
    digUntilClear(m.detect, m.dig, m.insp)
    sleep(0.2); tries = tries + 1
    if tries >= STUCK_LIMIT then
      notify("STUCK", ("Can't move %s after %d tries. Aborting dig, returning home.")
             :format(m.name, STUCK_LIMIT))
      aborting = true
      return false
    end
  end
  return true
end

local function safeForward() return safeMove(MOVERS.forward) end
local function safeUp()      return safeMove(MOVERS.up) end
local function safeDown()    return safeMove(MOVERS.down) end

-- --- position / heading tracking --------------------------------------
local function turnRight()
  turtle.turnRight()
  heading = { x = heading.z, z = -heading.x }
end
local function turnTo(target)
  local guard = 0
  while (heading.x ~= target.x or heading.z ~= target.z) and guard < 4 do
    turnRight(); guard = guard + 1
  end
end
local function step()
  if not safeForward() then return false end
  pos.x = pos.x + heading.x
  pos.z = pos.z + heading.z
  return true
end

-- Navigate to a cell (tx, ty, tz) through carved air. Returns false (and
-- sets aborting) if blocked. Vertical legs use safeUp/safeDown.
local function goTo(tx, ty, tz)
  if pos.x < tx then turnTo({ x = 1, z = 0 })
  elseif pos.x > tx then turnTo({ x = -1, z = 0 }) end
  while pos.x ~= tx do if not step() then return false end end
  if pos.z < tz then turnTo({ x = 0, z = 1 })
  elseif pos.z > tz then turnTo({ x = 0, z = -1 }) end
  while pos.z ~= tz do if not step() then return false end end
  while pos.y < ty do if not safeUp() then return false end; pos.y = pos.y + 1 end
  while pos.y > ty do if not safeDown() then return false end; pos.y = pos.y - 1 end
  return true
end

-- --- shared loot drop (mid-dig offload and final drop) ----------------
local function ensureChestAhead()
  if turtle.detect() then
    local ok, info = turtle.inspect()
    if ok and info and info.name == "minecraft:chest" then return true end
    return false
  end
  -- only place if slot 2 genuinely holds a chest (not whatever's there)
  local item = turtle.getItemDetail(CHEST_SLOT)
  if not item or item.name ~= "minecraft:chest" then return false end
  turtle.select(CHEST_SLOT)
  if turtle.place() then
    chestsUsed = chestsUsed + 1
    log(("Placed chest #%d"):format(chestsUsed))
    turtle.select(1)
    return true
  end
  turtle.select(1)
  return false
end

-- Assumes turtle is at (0,0,0). Tries to place/reuse a chest facing the
-- entrance (-z) first; falls back to the interior (+z). Chains along +x.
-- If NO chest can be placed (slot 2 empty / blocked both ways), PAUSES for a
-- keypress and retries — never dumps loot on the ground.
-- Leaves the turtle back at (0,0,0) facing +z.
local function waitForChest()
  -- Loop until a chest is placed/reused ahead. Tries -z then +z each round.
  while true do
    for _, d in ipairs({ { x = 0, z = -1 }, { x = 0, z = 1 } }) do
      turnTo(d)
      if ensureChestAhead() then return d end
    end
    notify("CHEST", "Can't place a chest. Put one in slot 2 and clear the cell " ..
           "ahead (-z or +z), then press any key.")
    setStatus("WAITING FOR CHEST — add to slot 2, then press a key...")
    os.pullEvent("key")
  end
end

local function dropLootAtHome()
  local chestDir = waitForChest()
  for s = 3, 16 do
    -- keep filler-type items in inventory for pit-filling; don't offload them
    if fillerName then
      local item = turtle.getItemDetail(s)
      if item and item.name == fillerName then goto nextslot end
    end
    if turtle.getItemCount(s) == 0 then goto nextslot end

    turtle.select(s)
    -- Drop this slot, chaining chests along +x as they fill. Each pass: face
    -- the chest ahead, try to drop. If the chest is full, step +x to the next
    -- cell and ensure a chest there (place or reuse). When the slot empties,
    -- return to x=0 before the next slot so every slot starts at chest #1.
    while turtle.getItemCount(s) > 0 do
      turnTo(chestDir)
      if turtle.drop() then
        -- something fit; keep dropping into this chest until full or slot empty
      else
        -- chest full (or no chest ahead): advance +x to chain a new chest
        while true do
          turnTo({ x = 1, z = 0 })
          if not step() then
            -- blocked: wait for the user to clear the row
            notify("CHEST", "Can't advance along +x. Clear the cell, then press any key.")
            setStatus("WAITING — clear +x row, then press a key...")
            os.pullEvent("key")
          else
            break
          end
        end
        turnTo(chestDir)
        -- place/reuse a chest ahead; if none in slot 2 or blocked, wait + retry
        while not ensureChestAhead() do
          notify("CHEST", "Need a chest in slot 2 (or clear the cell ahead). Press any key.")
          setStatus("WAITING FOR CHEST — add to slot 2, then press a key...")
          os.pullEvent("key")
        end
      end
    end
    -- return to x=0 so the next slot starts at chest #1 (which may have space)
    if pos.x ~= 0 then
      turnTo({ x = -1, z = 0 })
      while pos.x ~= 0 do if not step() then break end end
    end
    ::nextslot::
  end
  turtle.select(1)
  turnTo({ x = 0, z = 1 })
end

local function inventoryFull()
  for s = 3, 16 do
    if turtle.getItemCount(s) == 0 then return false end
  end
  return true
end

-- Offload now: remember where we are, go home, drop, come back. Returns
-- false if aborted during the trip.
local function offloadIfFull(returnDir)
  if not inventoryFull() then return true end
  local tx, ty, tz = pos.x, pos.y, pos.z
  setStatus("Inventory full — returning to drop loot...")
  notify("FULL", "Inventory full; returning to start to offload loot.")
  if not goTo(0, 0, 0) then return false end
  dropLootAtHome()
  goTo(tx, ty, tz)
  if returnDir then turnTo(returnDir) end
  return not aborting
end

-- === ROOM =============================================================
local function mineColumn(up)
  if up then
    for _ = 2, HEIGHT do
      if not safeUp() then return false end
      pos.y = pos.y + 1
    end
  else
    for _ = 2, HEIGHT do
      if not safeDown() then return false end
      pos.y = pos.y - 1
    end
  end
  return true
end

local function fuelNeededRoom()
  local columns    = WIDTH * LENGTH
  local vertical   = columns * (HEIGHT - 1)
  local horizontal = columns - 1
  local goHome     = (WIDTH - 1) + (LENGTH - 1) + (HEIGHT - 1)
  return vertical + horizontal + goHome
end

local function digRoom()
  -- Re-anchor resume: navigate from the home corner (0,0,0) to the saved
  -- cursor (w, l) before continuing. The turtle must be physically placed
  -- back at the home corner facing the original start direction.
  if doneColumns > 0 and not (w == 0 and l == 0) then
    setStatus(("Resuming: navigating to W%d L%d..."):format(w + 1, l + 1))
    if not goTo(w, 0, l) then return end
    turnTo({ x = 0, z = lengthDir })
  end
  while w < WIDTH do
    if aborting then break end
    turnTo({ x = 0, z = lengthDir })
    while l < LENGTH do
      if aborting then break end
      if not offloadIfFull({ x = 0, z = lengthDir }) then break end
      setStatus(("Digging column W%d L%d (%s)"):format(
            w + 1, l + 1, goingUp and "up" or "down"))
      if not mineColumn(goingUp) then break end
      doneColumns = doneColumns + 1
      goingUp = not goingUp
      l = l + 1
      if l < LENGTH then
        setStatus(("Moving to L%d"):format(l + 1))
        if not step() then break end
      end
      saveState()
    end
    if aborting then break end
    l = 0
    w = w + 1
    if w < WIDTH then
      setStatus(("Stepping to width row %d"):format(w + 1))
      turnTo({ x = 1, z = 0 })
      if not step() then break end
      lengthDir = -lengthDir
      saveState()
    end
  end
end

-- === HILL =============================================================
-- Smooth the interior to the outside perimeter's ground heights.
perimeterHeights = {}   -- ["x,z"] -> ground air-cell height (relative to start)
local function pkey(x, z) return x .. "," .. z end

local function smoothstep(t) return t * t * (3 - 2 * t) end

-- --- Geo Scanner (Advanced Peripherals 0.7.x) ------------------------
-- AP exposes the scanner as a turtle upgrade; the call surface is either
-- `turtle.scan(r)` or via peripheral.wrap on the upgrade's side. Probe both.
-- Returns the scanner table (with .scan) or nil. ponytail: AP 0.7 docs only
-- document the peripheral form; the turtle-upgrade wrapping is undocumented,
-- so we sniff at runtime instead of guessing a side.
local geoScanner = nil
local function detectGeoScanner()
  if type(turtle.scan) == "function" then
    return { scan = function(r) return turtle.scan(r) end,
             fuel  = function() return (turtle.getFuelLevel and turtle.getFuelLevel()) or 0 end,
             maxFuel = function() return (turtle.getMaxFuelLevel and turtle.getMaxFuelLevel()) or 0 end }
  end
  for _, side in ipairs({ "left", "right", "top", "bottom", "front", "back" }) do
    if peripheral.isPresent(side) and peripheral.hasType(side, "geoScanner") then
      local p = peripheral.wrap(side)
      if p and type(p.scan) == "function" then return p end
    end
  end
  return nil
end

-- Is the block `name` solid ground for height purposes? Fluff sitting on top
-- of real ground (grass, crops, leaves, water, snow layers, flowers, vines)
-- is NOT counted — we descend through it to find the real surface.
-- ponytail: substring blacklist catches every vanilla variant + most modded
-- foliage/liquid without a curated list. Unknown blocks are treated as solid
-- (conservative — better to stop than to dig indefinitely).
local function isGroundSolid(name)
  if not name then return true end
  local n = name:gsub("^.*:", "")
  if n == "water" or n == "lava" then return false end
  if n == "air" then return false end
  if n:find("leaves", 1, true) then return false end
  if n:find("grass", 1, true) and n ~= "grass_block" and n ~= "dirt_path" then return false end
  if n:find("_sapling", 1, true) then return false end
  if n == "wheat" or n == "carrots" or n == "potatoes" or n == "beetroots"
     or n:find("_stem", 1, true) or n:find("crop", 1, true) then return false end
  if n:find("flower", 1, true) or n == "dandelion" or n == "poppy"
     or n == "cornflower" or n:find("tulip", 1, true)
     or n:find("lily", 1, true) or n == "dead_bush" or n:find("fern", 1, true) then return false end
  if n:find("vine", 1, true) or n == "ladder" then return false end
  if n == "snow" or n:find("snow_layer", 1, true) then return false end
  if n:find("seagrass", 1, true) or n:find("kelp", 1, true) then return false end
  if n:find("mushroom", 1, true) then return false end
  return true
end

-- Probe the ground height at the current (x,z): descend through AIR and
-- non-solid fluff (no dig — move through them) until a SOLID block is below,
-- return that air-cell height, restore position. survey must not modify
-- terrain, so it never digs; if a non-solid block can't be moved through
-- (e.g. some modded foliage), probing gives up at that height.
local function probeGround()
  local drops = 0
  while drops < 256 do
    local detected = turtle.detectDown()
    if not detected then
      if not turtle.down() then break end
      pos.y = pos.y - 1; drops = drops + 1
    else
      local ok, info = turtle.inspectDown()
      if not ok then break end
      if isGroundSolid(info.name) then break end   -- real ground reached
      -- non-solid fluff: try to descend through it without mining
      if not turtle.down() then break end
      pos.y = pos.y - 1; drops = drops + 1
    end
  end
  local groundY = pos.y
  for _ = 1, drops do
    if turtle.up() then pos.y = pos.y + 1 end
  end
  return groundY
end

-- Move one cell along heading, climbing OVER obstacles without digging
-- forward (preserves terrain). Returns false if it can't clear (overhang).
local function flyMove()
  local tries = 0
  while not turtle.forward() do
    if turtle.detect() then
      if not turtle.up() then return false end   -- can't climb (overhang/ceiling)
      pos.y = pos.y + 1
    else
      return false   -- entity or unknown obstruction
    end
    tries = tries + 1
    if tries > 80 then return false end
  end
  pos.x = pos.x + heading.x
  pos.z = pos.z + heading.z
  return true
end

local function flyStep(dir)
  turnTo(dir)
  return flyMove()
end

-- Navigate horizontally to (tx,tz) by climbing over terrain, never digging
-- forward (preserves ground). Vertical (pos.y) is left as-is. The caller
-- shaves down to target afterwards, so crossing above terrain is correct.
local function flyTo(tx, tz)
  if pos.x < tx then turnTo({ x = 1, z = 0 })
  elseif pos.x > tx then turnTo({ x = -1, z = 0 }) end
  while pos.x ~= tx do if not flyMove() then return false end end
  if pos.z < tz then turnTo({ x = 0, z = 1 })
  elseif pos.z > tz then turnTo({ x = 0, z = -1 }) end
  while pos.z ~= tz do if not flyMove() then return false end end
  return true
end

local function probeHere()
  perimeterHeights[pkey(pos.x, pos.z)] = probeGround()
end

-- Walk one edge: probe current cell, then move `steps` cells in dir, probing
-- each arrival. Returns false on fly failure.
local function walkEdge(dir, steps)
  probeHere()
  for _ = 1, steps do
    if not flyStep(dir) then return false end
    probeHere()
  end
  return true
end

-- Run the perimeter survey. On completion the turtle is back near (0,0).
local function runSurvey()
  notify("SURVEY", "Probing outside perimeter (non-destructive)...")
  -- position at outside corner (-1,-1)
  flyStep({ x = -1, z = 0 }); flyStep({ x = 0, z = -1 })
  walkEdge({ x = 1, z = 0 }, WIDTH + 1)   -- south edge z=-1, x: -1..W   -> (W,-1)
  walkEdge({ x = 0, z = 1 }, LENGTH + 1)  -- east  edge x= W, z: -1..L  -> (W,L)
  walkEdge({ x = -1, z = 0 }, WIDTH + 1)  -- north edge z= L, x:  W..-1 -> (-1,L)
  walkEdge({ x = 0, z = -1 }, LENGTH + 1) -- west  edge x=-1, z:  L..-1 -> (-1,-1)
  -- step into the interior corner (0,0)
  flyStep({ x = 1, z = 0 }); flyStep({ x = 0, z = 1 })
  surveyed = true
  notify("SURVEY", ("Done: %d perimeter cells probed."):format(
         (function() local n=0 for _ in pairs(perimeterHeights) do n=n+1 end return n end)()))
end

-- Build the interior target-surface table by smoothstep+bilinear blend of
-- the four edge samples. surface[x][z] = target air-cell height.
local function buildSurface()
  -- Average of all probed heights; used as fallback for cells the survey
  -- couldn't reach (obstacle aborted an edge mid-walk).
  local sum, count = 0, 0
  for _, h in pairs(perimeterHeights) do sum = sum + h; count = count + 1 end
  local avg = (count > 0) and (sum / count) or 0
  local function H(x, z)
    local v = perimeterHeights[pkey(x, z)]
    if v == nil then return avg end
    return v
  end
  local surf = {}
  for x = 0, WIDTH - 1 do
    surf[x] = {}
    local hS = H(x, -1)
    local hN = H(x, LENGTH)
    local tx = (WIDTH > 1) and smoothstep(x / (WIDTH - 1)) or 0.5
    for z = 0, LENGTH - 1 do
      local hW = H(-1, z)
      local hE = H(WIDTH, z)
      local tz = (LENGTH > 1) and smoothstep(z / (LENGTH - 1)) or 0.5
      local hNS = hS + (hN - hS) * tz
      local hWE = hW + (hE - hW) * tx
      surf[x][z] = math.floor((hNS + hWE) / 2 + 0.5)
    end
  end
  return surf
end

-- Carve one column at (carveX, carveZ) down to target. The turtle is at the
-- column at some height >= terrain top (after flying in). Manual descent so
-- we NEVER dig below the target surface. In fill mode (fillerName set), pits
-- below the target are filled back up to the surface with filler blocks.
local fillerWarned = false
local function shaveColumn(target)
  -- phase 1: descend to target, digging through material ABOVE target only
  while pos.y > target do
    local ok, info = turtle.inspectDown()
    if ok then noteBlock(info); turtle.digDown() end
    if turtle.down() then pos.y = pos.y - 1 else break end
  end
  if not fillerName then
    -- carve-only: ascend to target if we undershot (air pocket)
    while pos.y < target do
      if turtle.up() then pos.y = pos.y + 1 else break end
    end
    return
  end
  -- fill mode: if the cell below target isn't solid, it's a pit — descend to
  -- the floor then place filler upward until the surface block sits at target-1.
  local ok, info = turtle.inspectDown()
  if ok and isGroundSolid(info.name) then return end   -- surface already there
  -- descend to pit floor (don't dig — we want to fill, not deepen)
  while true do
    local detOk, detInfo = turtle.inspectDown()
    if detOk and isGroundSolid(detInfo.name) then break end
    if not turtle.down() then break end
    pos.y = pos.y - 1
  end
  -- place filler going up until the turtle stands at target on a fresh block
  while pos.y < target do
    if selectFiller() then
      if not turtle.up() then break end
      pos.y = pos.y + 1
      turtle.placeDown()   -- fills cell at pos.y - 1
      turtle.select(1)
    else
      -- out of filler: pause for a refill (same pattern as the fuel pause).
      notify("FILLER", "Out of filler! Add more " .. niceName(fillerName) ..
             " to slots 3-16, then press any key.")
      setStatus("OUT OF FILLER — waiting for refill...")
      os.pullEvent("key")   -- loop retries selectFiller after the keypress
    end
  end
end

local surface = {}   -- filled after survey / on resume
local maxSurface = 0  -- highest target across all columns (traverse above this)

local function fuelNeededHill()
  -- ponytail: rough. Survey ~ 4*(W+L) probe cells; carve ~ W*L * guessed
  -- average height (use LENGTH as a loose stand-in). Real cost depends on
  -- terrain shape and is unknown pre-dig.
  local survey  = 4 * (WIDTH + LENGTH) * 2
  local carve   = WIDTH * LENGTH * math.max(1, math.floor(LENGTH / 2))
  local goHome  = WIDTH + LENGTH + 16
  return survey + carve + goHome
end

-- Scan-survey: one Geo Scanner call from the start corner. Fills
-- perimeterHeights directly from the returned block table. The scanner
-- returns block POSITIONS relative to itself, so for each perimeter cell we
-- look up the highest solid block below the turtle's Y (start ground = 0).
-- Returns true on success, false if the scanner can't cover the area or fails.
local function scanSurvey()
  if not geoScanner then return false end
  -- perimeter spans x:[-1,W], z:[-1,L]; need radius >= max(W,L)+1
  local radius = math.max(WIDTH, LENGTH) + 1
  -- ponytail: AP max radius is 16 by default; bigger rooms need stitching.
  -- We don't stitch — fall back to walking if it doesn't fit.
  if radius > 16 then
    notify("SURVEY", ("Room needs scan radius %d > 16; falling back to walk survey."):format(radius))
    return false
  end
  -- FE check: Geo Scanner costs Forge Energy, not turtle fuel.
  local maxFuel = (type(geoScanner.getMaxFuelLevel) == "function") and geoScanner.getMaxFuelLevel() or 0
  local cost    = (type(geoScanner.cost) == "function") and geoScanner.cost(radius) or 0
  if maxFuel > 0 and cost > maxFuel then
    notify("SURVEY", ("Geo Scanner needs %d FE, has %d. Charge it or use walk survey."):format(cost, maxFuel))
    return false
  end
  notify("SURVEY", ("Scanning radius %d via Geo Scanner (cost %d FE)..."):format(radius, cost))
  local blocks, err = geoScanner.scan(radius)
  if not blocks then
    notify("SURVEY", "Scan failed: " .. tostring(err) .. ". Falling back to walk.")
    return false
  end
  -- Index blocks by (x,z). Keep the HIGHEST solid block at each column: that's
  -- the ground surface (scanner sees everything in the cube, including caves
  -- below — we want the topmost solid).
  local colHighest = {}   -- [pkey] -> y of topmost solid block
  for _, b in ipairs(blocks) do
    if b and b.name and isGroundSolid(b.name) then
      local k = pkey(b.x, b.z)
      if colHighest[k] == nil or b.y > colHighest[k] then colHighest[k] = b.y end
    end
  end
  -- Air-cell height = topmost solid y + 1 (turtle stands above the surface).
  for x = -1, WIDTH do
    for z = -1, LENGTH do
      if x == -1 or x == WIDTH or z == -1 or z == LENGTH then
        local topSolid = colHighest[pkey(x, z)]
        if topSolid then
          perimeterHeights[pkey(x, z)] = topSolid + 1
        end
      end
    end
  end
  surveyed = true
  notify("SURVEY", ("Scanned %d blocks; %d perimeter cells measured."):format(#blocks, (function() local n=0 for _ in pairs(perimeterHeights) do n=n+1 end return n end)()))
  return true
end

local function digHill()
  if not surveyed then
    if not scanSurvey() then
      runSurvey()   -- walk fallback (non-destructive probe of each perimeter cell)
    end
    surface = buildSurface()
    saveState()
    if aborting then return end
  end
  -- compute the highest target so horizontal traversal stays above all ground
  maxSurface = 0
  for x = 0, WIDTH - 1 do
    for z = 0, LENGTH - 1 do
      if surface[x][z] > maxSurface then maxSurface = surface[x][z] end
    end
  end
  -- boustrophedon over interior columns. Resume continues from (carveX,carveZ).
  while carveX < WIDTH do
    if aborting then break end
    while (carveDir == 1 and carveZ <= LENGTH - 1) or (carveDir == -1 and carveZ >= 0) do
      if aborting then break end
      if not offloadIfFull({ x = 0, z = carveDir }) then break end
      -- traverse to (carveX, carveZ) ABOVE every target (maxSurface+1), using
      -- the DIGGING goTo: any block above the surface was going to be removed
      -- anyway, so digging through it is correct and never blocks. Staying
      -- above maxSurface guarantees no ground (at/below target) is touched.
      if not goTo(carveX, maxSurface + 1, carveZ) then break end
      setStatus(("Smoothing column W%d L%d"):format(carveX + 1, carveZ + 1))
      shaveColumn(surface[carveX][carveZ])
      doneColumns = doneColumns + 1
      carveZ = carveZ + carveDir
      saveState()
    end
    if aborting then break end
    -- advance one width row, reverse z direction
    carveX = carveX + 1
    if carveX < WIDTH then
      carveZ = (carveDir == 1) and (LENGTH - 1) or 0
      carveDir = -carveDir
      saveState()
    end
  end
end

-- --- pre-flight --------------------------------------------------------
local function fuelNeeded()
  return (mode == "hill") and fuelNeededHill() or fuelNeededRoom()
end

refuelFrom(FUEL_SLOT)   -- greedy: burn everything in the dedicated fuel slot
-- note slot 2 chest status at startup (loot offload will pause if missing)
local slot2 = turtle.getItemDetail(CHEST_SLOT)
if not slot2 or slot2.name ~= "minecraft:chest" then
  notify("INFO", "No chest in slot 2 — loot offload will pause and wait when needed.")
end
-- hill fill mode: if slot 3 holds a block on startup, use it as the filler
-- type and pull matching blocks from anywhere in the inventory when filling pits.
if mode == "hill" then
  local item = turtle.getItemDetail(3)
  if item and item.name then
    fillerName = item.name
    log(("Fill mode: %s (from slot 3, pulled from any slot)"):format(
        niceName(fillerName)))
  end
end
do
  local have  = turtle.getFuelLevel()
  local need  = fuelNeeded()
  local level = (have == "unlimited") and math.huge or have
  if level < need then
    notify("FUEL", ("Need ~%d fuel, have %s. Starting anyway; will pause for refuel.")
           :format(need, tostring(have)))
  end
  term.clear()
  if mode == "hill" then
    log(("Hill %dx%d  (rough need ~%d fuel, have %s)"):format(
          WIDTH, LENGTH, need, tostring(have)))
  else
    log(("Room %dx%dx%d  (need ~%d fuel, have %s)"):format(
          WIDTH, HEIGHT, LENGTH, need, tostring(have)))
  end
end

-- start or resume
if not tryResume() then
  clearState()
  pos, heading   = { x = 0, y = 0, z = 0 }, { x = 0, z = 1 }
  w, l, lengthDir, goingUp = 0, 0, 1, true
  carveX, carveZ, carveDir, surveyed = 0, 0, 1, false
  doneColumns, aborting, chestsUsed, blockLog = 0, false, 0, {}
  if mode == "hill" then perimeterHeights = {} end
end
-- hill: rebuild surface table from probed heights (or empty if not surveyed)
if mode == "hill" and surveyed then surface = buildSurface() end
-- hill: detect Geo Scanner upgrade (Advanced Peripherals). If present and
-- charged, the survey uses one scan() instead of walking the perimeter.
if mode == "hill" then
  geoScanner = detectGeoScanner()
  if geoScanner then
    local mf = (type(geoScanner.getMaxFuelLevel) == "function") and geoScanner.getMaxFuelLevel() or "?"
    notify("SURVEY", ("Geo Scanner detected (FE: %s). Will scan instead of walk."):format(tostring(mf)))
  end
end
saveState()

-- --- main dig dispatch ------------------------------------------------
if mode == "hill" then digHill() else digRoom() end

-- --- return to start ---------------------------------------------------
if aborting then
  setStatus("ABORTED — returning home with loot...")
  notify("ABORT", "Dig aborted. Returning to start to drop what was mined.")
else
  setStatus("Returning to start...")
end
goTo(0, 0, 0)
turnTo({ x = 0, z = -1 })

-- --- drop loot ---------------------------------------------------------
setStatus("Dropping loot...")
dropLootAtHome()

-- --- final report ------------------------------------------------------
local blockBits = {}
for name, count in pairs(blockLog) do
  blockBits[#blockBits + 1] = ("%s x%d"):format(name, count)
end
table.sort(blockBits)
local blockSummary = (#blockBits > 0)
  and (" | mined: " .. table.concat(blockBits, ", ")) or ""

local summary = ("Done. %d/%d columns, %d chest(s) used.%s%s"):format(
  doneColumns, totalColumns, chestsUsed,
  aborting and " (ABORTED early)" or "", blockSummary)
setStatus(summary)
notify("DONE", summary)
clearState()
print("")
