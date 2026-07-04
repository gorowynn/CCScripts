--[[
  dig_room.lua — carve a rectangular room.
  Turtle starts at the LOWER-LEFT-FRONT corner, facing the LENGTH direction.

    WIDTH  = blocks across  (left/right)
    HEIGHT = blocks up       (1 is fine; 1x1x1 is rejected — nothing to dig)
    LENGTH = blocks forward  (face this way at start)

  Pattern: vertical wave (boustrophedon in the vertical plane). The turtle
  mines a 1x1 shaft UP through HEIGHT at the first floor cell, steps sideways
  at the TOP to the next cell, mines DOWN, steps sideways at the FLOOR, mines
  UP, and so on. Every block is mined with exactly one move into it — no
  wasted descent. Across the W x L floor the path also snakes (length
  direction reverses each width row).

  Inventory:
    slot 1 = FUEL  (never dropped as loot)
    slot 2 = CHEST (auto-placed; chained into a row when one fills up)

  Extras:
    - Pre-flight fuel check + refuel from slot 1
    - Loot-fuel fallback: when slot 1 empties, burn coal/lava/etc. from any
      loot slot (3-16) before pausing for a manual refuel
    - Inventory-full mid-dig: returns to start, offloads into chests (places/
      chains them, ground-dump fallback if out of chests), then resumes at the
      exact column it left off
    - Resume after restart: progress is saved every column to .dig_room_state;
      re-running with the same <w h l> resumes, a different size starts fresh
    - Ore logging: every block is inspected before digging; ores are tallied
      and reported at the end
    - Gravel/falling-block re-dig, live status display, chat alerts

  Alerts: uses a Plethora/Sc-Peripherals `chatBox` if present, else falls
  back to `rednet.broadcast` if a modem is attached, else just prints.

  Usage:  dig_room <width> <height> <length>
          dig_room                         -- interactive: prompts for shape + dims
--]]]

local args = { ... }
-- --- argument parsing: CLI if given, else interactive guided prompts -----
local WIDTH, HEIGHT, LENGTH

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
    local n = tonumber(s:gsub("^%s+", ""):gsub("%s+$", ""))
    if n and n >= 1 and n <= #options then return options[n].value end
    print("  invalid choice")
  end
end

if #args >= 3 then
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
  print("=== dig_room guided setup ===")
  print("")
  local shape = readChoice("Mine which shape?", {
    { label = "rectangular room", value = "room" },
    -- add more shapes here when implemented
  })
  if shape ~= "room" then
    printError("only 'room' is implemented so far.")
    return
  end
  print("")
  WIDTH  = readNumber("Width  (blocks across, left/right):  ")
  LENGTH = readNumber("Length (blocks forward, face this way): ")
  HEIGHT = readNumber("Height (blocks up, 1 ok):            ")
  if not (WIDTH and HEIGHT and LENGTH) then return end   -- user bailed (EOF)
end

if WIDTH * HEIGHT * LENGTH < 2 then
  -- only 1x1x1 reaches here: the turtle already occupies the sole cell
  printError("1x1x1 has nothing to dig (the turtle is already in the only cell).")
  printError("Increase at least one dimension.")
  return
end

local FUEL_SLOT   = 1
local CHEST_SLOT  = 2
local STUCK_LIMIT = 15   -- failed move attempts before declaring stuck
local STATE_FILE  = ".dig_room_state"

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
    pcall(function() rednet.broadcast(full, "dig_room") end)
  end
end

-- --- live status display ----------------------------------------------
local totalColumns = WIDTH * LENGTH

local function setStatus(msg, done)
  term.setCursorPos(1, 1); term.clearLine(); term.write(msg or "")
  term.setCursorPos(1, 2); term.clearLine()
  term.write(("Progress: %d / %d columns  (%d%%)"):format(
        done, totalColumns,
        math.floor(done / totalColumns * 100)))
  term.setCursorPos(1, 3); term.clearLine()
  term.write(("Fuel: %s   |   loot slots 3-16   |   chests used: see log")
             :format(tostring(turtle.getFuelLevel())))
end

local function log(msg)
  local _, h = term.getSize()
  term.setCursorPos(1, h); term.scroll(1); term.write(msg or "")
end

-- --- run state (all resumable) ----------------------------------------
local pos         = { x = 0, y = 0, z = 0 }
local heading     = { x = 0, z = 1 }
local w           = 0          -- current width index  [0..WIDTH-1]
local l           = 0          -- current length index [0..LENGTH-1]
local lengthDir   = 1          -- +1 or -1 (snake direction along z)
local goingUp     = true       -- vertical direction of the current column
local doneColumns = 0
local aborting    = false
local chestsUsed  = 0
local blockLog    = {}         -- block name (no namespace) -> count

-- --- state persistence ------------------------------------------------
local function saveState()
  local f = fs.open(STATE_FILE, "w")
  if not f then return end
  f.write(textutils.serialize({
    dims         = { WIDTH, HEIGHT, LENGTH },
    pos          = pos,
    heading      = heading,
    w            = w,
    l            = l,
    lengthDir    = lengthDir,
    goingUp      = goingUp,
    doneColumns  = doneColumns,
    aborting     = aborting,
    chestsUsed   = chestsUsed,
    blockLog      = blockLog,
  }))
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
  local d = data.dims
  if d[1] ~= WIDTH or d[2] ~= HEIGHT or d[3] ~= LENGTH then
    return false   -- different job; caller will start fresh
  end
  pos, heading     = data.pos, data.heading
  w, l, lengthDir  = data.w, data.l, data.lengthDir
  goingUp          = data.goingUp
  if goingUp == nil then goingUp = true end
  doneColumns      = data.doneColumns or 0
  aborting         = data.aborting or false
  chestsUsed       = data.chestsUsed or 0
  blockLog         = data.blockLog or data.oreLog or {}
  notify("RESUME", ("Resuming at W%d L%d (%d/%d columns)")
         :format(w + 1, l + 1, doneColumns, totalColumns))
  return true
end

-- --- fuel -------------------------------------------------------------
-- Burn fuel from `slot` until level reaches `target` (default: max) or slot
-- is empty. Greedy by default — pre-flight passes no target so all of slot 1
-- is consumed.
local function refuelFrom(slot, target)
  if turtle.getFuelLevel() == "unlimited" then return end
  target = target or math.huge
  turtle.select(slot)
  while turtle.getFuelLevel() < target and turtle.refuel(1) do end
  turtle.select(1)
end

-- Burns slot 1 first, then any fuel in loot slots 3-16. Mid-dig fallback tops
-- up to `target` (default 4000) rather than torching all the loot coal.
local function refuelAll(target)
  target = target or 4000
  refuelFrom(FUEL_SLOT, target)
  if turtle.getFuelLevel() < target then
    for s = 3, 16 do refuelFrom(s, target) end
  end
end

-- --- block logging --------------------------------------------------
-- ponytail: substring match catches every *_ore and deepslate variant plus
-- ancient_debris; used only to highlight ores in the live log.
local function isOre(name)
  return name and (name:find("_ore", 1, true) ~= nil
                   or name == "minecraft:ancient_debris")
end

-- Tally every mined block by nice name; ores also get a live log line.
local function noteBlock(info)
  if not info then return end
  local short = (info.name or ""):gsub("^minecraft:", "")
  if short == "" then return end
  blockLog[short] = (blockLog[short] or 0) + 1
  if isOre(info.name) then log(("ore: %s"):format(short)) end
end

-- --- falling-block-safe dig/move helpers -----------------------------
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

local function safeForward()
  digUntilClear(turtle.detect, turtle.dig, turtle.inspect)
  local tries = 0
  while not turtle.forward() do
    if turtle.getFuelLevel() == 0 then
      refuelAll()
      if turtle.getFuelLevel() == 0 then
        notify("FUEL", "Out of fuel! Add fuel to slot 1, then press any key.")
        setStatus("OUT OF FUEL — waiting for refuel...", doneColumns)
        os.pullEvent("key")
        refuelAll()
      end
    end
    digUntilClear(turtle.detect, turtle.dig, turtle.inspect)
    sleep(0.2); tries = tries + 1
    if tries >= STUCK_LIMIT then
      notify("STUCK", "Can't move forward after " .. STUCK_LIMIT ..
             " tries (unbreakable block?). Aborting dig, returning home.")
      aborting = true
      return false
    end
  end
  return true
end

local function safeUp()
  digUntilClear(turtle.detectUp, turtle.digUp, turtle.inspectUp)
  local tries = 0
  while not turtle.up() do
    if turtle.getFuelLevel() == 0 then refuelAll() end
    digUntilClear(turtle.detectUp, turtle.digUp, turtle.inspectUp)
    sleep(0.2); tries = tries + 1
    if tries >= STUCK_LIMIT then
      notify("STUCK", "Can't move up after " .. STUCK_LIMIT ..
             " tries. Aborting dig, returning home.")
      aborting = true
      return false
    end
  end
  return true
end

local function safeDown()
  digUntilClear(turtle.detectDown, turtle.digDown, turtle.inspectDown)
  local tries = 0
  while not turtle.down() do
    if turtle.getFuelLevel() == 0 then refuelAll() end
    digUntilClear(turtle.detectDown, turtle.digDown, turtle.inspectDown)
    sleep(0.2); tries = tries + 1
    if tries >= STUCK_LIMIT then
      notify("STUCK", "Can't move down after " .. STUCK_LIMIT ..
             " tries. Aborting dig, returning home.")
      aborting = true
      return false
    end
  end
  return true
end

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

-- --- the room (vertical wave / boustrophedon) -------------------------
-- Mine one column in the given vertical direction. Returns false on stuck.
-- For HEIGHT==1 this is a no-op (the cell is already air under the turtle).
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

local function fuelNeeded()
  local columns   = WIDTH * LENGTH
  local vertical  = columns * (HEIGHT - 1)   -- one pass per column, not up+down
  local horizontal = columns - 1             -- stepping between columns
  local goHome    = (WIDTH - 1) + (LENGTH - 1) + (HEIGHT - 1)  -- worst case
  return vertical + horizontal + goHome
end

-- --- loot drop (reused by mid-dig offload and final drop) -------------
-- Assumes turtle is at (0,0). Places/reuses chests along +x at z=-1; chains
-- a new chest when one fills. Falls back to dumping into the room if chests
-- run out. Leaves the turtle back at (0,0) facing +z (into the room).
local function ensureChestAhead()
  if turtle.detect() then
    local ok, info = turtle.inspect()
    if ok and info and info.name == "minecraft:chest" then return true end
    return false   -- non-chest block in the way; can't loot here
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

local function dropLootAtHome()
  -- Prefer placing chests at the entrance (-z); fall back to the room interior
  -- (+z), which is guaranteed carved air with a solid floor. The entrance cell
  -- is often solid if the turtle wasn't placed at a pre-dug tunnel mouth.
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
        -- face into the room (+z, carved air) and dump on the ground
        turnTo({ x = 0, z = 1 }); turtle.drop(); turnTo(chestDir)
      else
        while turtle.getItemCount(s) > 0 do
          if turtle.drop() then
            -- slot emptied into the chest
          else
            -- chest full: chain a new one along +x (perpendicular to chestDir)
            if turtle.getItemCount(CHEST_SLOT) == 0 then
              notify("WARN", "Ran out of chests! Dumping remaining loot on the ground.")
              groundFallback = true
              break
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
  -- return to origin so callers know where we are
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

-- --- pre-flight --------------------------------------------------------
refuelAll(math.huge)   -- greedy: burn all fuel in every slot before reporting
do
  local have  = turtle.getFuelLevel()
  local need  = fuelNeeded()
  local level = (have == "unlimited") and math.huge or have
  if level < need then
    -- warn but proceed; the turtle will pause for fuel mid-dig when it runs out
    notify("FUEL", ("Need ~%d fuel, have %s. Starting anyway; will pause for refuel.")
           :format(need, tostring(have)))
  end
  term.clear()
  log(("Room %dx%dx%d  (need ~%d fuel, have %s)"):format(
        WIDTH, HEIGHT, LENGTH, need, tostring(have)))
end

-- start or resume
if not tryResume() then
  clearState()   -- discard any stale state from a different job
  pos, heading   = { x = 0, y = 0, z = 0 }, { x = 0, z = 1 }
  w, l, lengthDir, goingUp = 0, 0, 1, true
  doneColumns, aborting, chestsUsed, blockLog = 0, false, 0, {}
end
saveState()

-- --- main dig loop ----------------------------------------------------
while w < WIDTH do
  if aborting then break end
  turnTo({ x = 0, z = lengthDir })
  while l < LENGTH do
    if aborting then break end

    -- mid-dig offload when every loot slot is occupied
    if inventoryFull() then
      local tx, ty, tz = pos.x, pos.y, pos.z
      setStatus("Inventory full — returning to drop loot...", doneColumns)
      notify("FULL", "Inventory full; returning to start to offload loot.")
      if goTo(0, 0, 0) then
        dropLootAtHome()
        goTo(tx, ty, tz)
      end
      turnTo({ x = 0, z = lengthDir })
      saveState()
      if aborting then break end
    end

    setStatus(("Digging column W%d L%d (%s)"):format(
          w + 1, l + 1, goingUp and "up" or "down"), doneColumns)
    if not mineColumn(goingUp) then break end
    doneColumns = doneColumns + 1
    goingUp = not goingUp    -- reverse vertical direction for the next column

    l = l + 1
    if l < LENGTH then
      setStatus(("Moving to L%d"):format(l + 1), doneColumns)
      if not step() then break end
    end
    saveState()   -- invariant: saved (w,l,goingUp) = next column to dig
  end
  if aborting then break end

  l = 0
  w = w + 1
  if w < WIDTH then
    setStatus(("Stepping to width row %d"):format(w + 1), doneColumns)
    turnTo({ x = 1, z = 0 })
    if not step() then break end
    lengthDir = -lengthDir
    saveState()
  end
end

-- --- return to start ---------------------------------------------------
if aborting then
  setStatus("ABORTED — returning home with loot...", doneColumns)
  notify("ABORT", "Dig aborted. Returning to start to drop what was mined.")
else
  setStatus("Returning to start...", doneColumns)
end
goTo(0, 0, 0)
turnTo({ x = 0, z = -1 })   -- face the entrance (-z) for the final drop

-- --- drop loot ---------------------------------------------------------
setStatus("Dropping loot...", doneColumns)
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
setStatus(summary, doneColumns)
notify("DONE", summary)
clearState()
print("")
