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
  pos, heading     = data.pos, data.heading
  w, l, lengthDir  = data.w, data.l, data.lengthDir
  goingUp          = data.goingUp
  if goingUp == nil then goingUp = true end
  carveX, carveZ, carveDir = data.carveX or 0, data.carveZ or 0, data.carveDir or 1
  surveyed         = data.surveyed or false
  doneColumns      = data.doneColumns or 0
  aborting         = data.aborting or false
  chestsUsed       = data.chestsUsed or 0
  blockLog         = data.blockLog or data.oreLog or {}
  if mode == "hill" and data.perimeter then _G.perimeterHeights = data.perimeter end
  notify("RESUME", ("Resuming %s at column %d/%d"):format(
         mode, doneColumns, totalColumns))
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
  if turtle.getItemCount(CHEST_SLOT) == 0 then return false end
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
-- Leaves the turtle back at (0,0,0) facing +z.
local function dropLootAtHome()
  local chestDirs = { { x = 0, z = -1 }, { x = 0, z = 1 } }
  local chestDir  = chestDirs[1]
  local placed    = false
  for _, d in ipairs(chestDirs) do
    turnTo(d)
    if ensureChestAhead() then chestDir = d; placed = true; break end
  end
  local groundFallback = not placed
  if groundFallback then
    notify("WARN", "Could not place a chest (slot 2 empty or blocked both ways). " ..
           "Dumping loot into the room.")
  end
  for s = 3, 16 do
    if turtle.getItemCount(s) > 0 then
      turtle.select(s)
      if groundFallback then
        turnTo({ x = 0, z = 1 }); turtle.drop(); turnTo(chestDir)
      else
        while turtle.getItemCount(s) > 0 do
          if turtle.drop() then
          else
            if turtle.getItemCount(CHEST_SLOT) == 0 then
              notify("WARN", "Ran out of chests! Dumping remaining loot on the ground.")
              groundFallback = true; break
            end
            turnTo({ x = 1, z = 0 })
            if not step() then break end
            turnTo(chestDir)
            if not ensureChestAhead() then groundFallback = true; break end
          end
        end
      end
    end
  end
  turtle.select(1)
  if pos.x ~= 0 then
    turnTo({ x = -1, z = 0 })
    while pos.x ~= 0 do if not step() then break end end
  end
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

-- Probe the ground height at the current (x,z): descend through AIR (no dig)
-- until solid below, return the air-cell height above it, restore position.
-- ponytail: survey must not modify terrain, so never digs. If the turtle is
-- below the surface (in a hole), it can't see up; rare for surface smoothing.
local function probeGround()
  local drops = 0
  while not turtle.detectDown() and drops < 256 do
    if not turtle.down() then break end
    pos.y = pos.y - 1
    drops = drops + 1
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
  local surf = {}
  for x = 0, WIDTH - 1 do
    surf[x] = {}
    local hS = perimeterHeights[pkey(x, -1)]
    local hN = perimeterHeights[pkey(x, LENGTH)]
    local tx = (WIDTH > 1) and smoothstep(x / (WIDTH - 1)) or 0.5
    for z = 0, LENGTH - 1 do
      local hW = perimeterHeights[pkey(-1, z)]
      local hE = perimeterHeights[pkey(WIDTH, z)]
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
-- we NEVER dig below the target surface (safeDown would eat into ground).
local function shaveColumn(target)
  while pos.y > target do
    local ok, info = turtle.inspectDown()
    if ok then noteBlock(info); turtle.digDown() end
    if turtle.down() then pos.y = pos.y - 1 else break end
  end
  while pos.y < target do       -- pit: terrain below target; ascend (air)
    if turtle.up() then pos.y = pos.y + 1 else break end
  end
end

local surface = {}   -- filled after survey / on resume

local function fuelNeededHill()
  -- ponytail: rough. Survey ~ 4*(W+L) probe cells; carve ~ W*L * guessed
  -- average height (use LENGTH as a loose stand-in). Real cost depends on
  -- terrain shape and is unknown pre-dig.
  local survey  = 4 * (WIDTH + LENGTH) * 2
  local carve   = WIDTH * LENGTH * math.max(1, math.floor(LENGTH / 2))
  local goHome  = WIDTH + LENGTH + 16
  return survey + carve + goHome
end

local function digHill()
  if not surveyed then
    runSurvey()
    surface = buildSurface()
    saveState()
    if aborting then return end
  end
  -- boustrophedon over interior columns. Resume continues from (carveX,carveZ).
  while carveX < WIDTH do
    if aborting then break end
    while (carveDir == 1 and carveZ <= LENGTH - 1) or (carveDir == -1 and carveZ >= 0) do
      if aborting then break end
      if not offloadIfFull({ x = 0, z = carveDir }) then break end
      -- fly to (carveX, carveZ) over terrain (no ground dig), then shave down
      if not flyTo(carveX, carveZ) then break end
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
