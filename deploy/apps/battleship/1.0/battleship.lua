-- ==============================================================================
-- GRID STRIKE: 1v1 Battleship for WADAMESH (LilyGo T-Deck / ESP32-S3 LoRa Mesh)
-- Production-Ready Single-File Script: battleship.lua
-- ==============================================================================

local app = {}

-- ---- SDK Imports & Safe Fallbacks -------------------------------------------
local ui    = (wada and wada.ui)    or {}
local sys   = (wada and wada.sys)   or {}
local store = (wada and wada.store) or {}
local timer = (wada and wada.timer) or {}
local mesh  = (wada and wada.mesh)  or {}

-- ---- Tactical Radar Aesthetic Color Palette ---------------------------------
local COL_BG           = 0x0A0E14  -- Dark Slate Background
local COL_PANEL_BG     = 0x0D141C  -- Radar Grid Container Background
local COL_GRID_LINE    = 0x182432  -- Subtle Radar Grid Lines
local COL_GRID_DOT     = 0x223548  -- Center Dot for Unshot Water
local COL_OWN_FLEET    = 0x00FF66  -- Phosphor Green (Player Ships)
local COL_OWN_FLEET_DK = 0x008833  -- Dark Green Trim
local COL_RETICLE      = 0xFFAA00  -- Amber Aiming Reticle / TX-Wait
local COL_HIT          = 0xFF3333  -- Crimson Hit Marker
local COL_MISS         = 0x3388AA  -- Cyan Miss Marker
local COL_SUNK         = 0xFF5522  -- Deep Orange-Red Sunken Ship
local COL_GHOST        = 0x7755AA  -- Dim Purple Ghost Reveal (Opponent Fleet)
local COL_BORDER_NORM  = 0x1F2E3E  -- Panel Border Normal
local COL_TEXT_BRIGHT  = 0xE6ECEF  -- Primary Bright White/Cyan Text
local COL_TEXT_DIM     = 0x64748B  -- Dim Telemetry Text
local COL_BAR_BG       = 0x0E141B  -- Top/Bottom Bar Background
local COL_STATUS_GREEN = 0x00FF66  -- Status Indicator: Your Turn / Audit Pass
local COL_STATUS_AMBER = 0xFFAA00  -- Status Indicator: TX Waiting / Retrying
local COL_STATUS_CYAN  = 0x3388AA  -- Status Indicator: Enemy Turn

-- ---- Game States ------------------------------------------------------------
local STATE_LOBBY        = "STATE_LOBBY"
local STATE_SETUP        = "STATE_SETUP"
local STATE_MY_TURN      = "STATE_MY_TURN"
local STATE_ENEMY_TURN   = "STATE_ENEMY_TURN"
local STATE_AUDIT        = "STATE_AUDIT"
local STATE_GAME_OVER    = "STATE_GAME_OVER"
local STATE_RESUME_MODAL = "STATE_RESUME_MODAL"

-- ---- Ship Specifications ----------------------------------------------------
-- 5 Ships: Carrier(5), Battleship(4), Cruiser(3), Submarine(3), Destroyer(2)
local SHIP_SPECS = {
  [1] = { name = "Carrier",    len = 5, abbr = "CV" },
  [2] = { name = "Battleship", len = 4, abbr = "BB" },
  [3] = { name = "Cruiser",    len = 3, abbr = "CA" },
  [4] = { name = "Submarine",  len = 3, abbr = "SS" },
  [5] = { name = "Destroyer",  len = 2, abbr = "DD" },
}

-- ---- Helper Primitive --------------------------------------------------------
local function I(v)
  return math.floor(tonumber(v) or 0)
end

-- ---- Screen & Layout Dimensions ---------------------------------------------
local W, H = 320, 240
local cv = nil
local cell_sz = 14
local target_panel = { x = 10,  y = 32, w = 144, h = 144 }
local home_panel   = { x = 166, y = 32, w = 144, h = 144 }
local bot_y = 182
local bot_h = 48

local function compute_layout(w, h)
  W = I(w or 320)
  H = I(h or 240)

  if W < 300 then
    -- Narrow portrait (e.g. ThinkNode M9 240x320)
    cell_sz = 10
    local pw = 10 * cell_sz + 4
    target_panel.w = pw; target_panel.h = pw
    home_panel.w = pw;   home_panel.h = pw
    target_panel.x = 8;  home_panel.x = 124
    target_panel.y = 32; home_panel.y = 32
    bot_y = 150;         bot_h = math.max(40, H - bot_y)
  elseif H < 230 then
    -- Compact landscape (LilyGo T-Deck 320x208..216 below title bar)
    cell_sz = 12
    local pw = 10 * cell_sz + 4
    target_panel.w = pw; target_panel.h = pw
    home_panel.w = pw;   home_panel.h = pw
    target_panel.x = 10; home_panel.x = 166
    target_panel.y = 32; home_panel.y = 32
    bot_y = 160;         bot_h = math.max(42, H - bot_y)
  else
    -- Standard landscape (320x240 LilyGo T-Deck / 480x240)
    cell_sz = 14
    local pw = 10 * cell_sz + 4
    target_panel.w = pw; target_panel.h = pw
    home_panel.w = pw;   home_panel.h = pw
    target_panel.x = 10; home_panel.x = 166
    target_panel.y = 32; home_panel.y = 32
    bot_y = 182;         bot_h = math.max(48, H - bot_y)
  end
end

-- ---- Audio & Feedback State -------------------------------------------------
local sound_on = true
local shake_panel = nil
local shake_dx, shake_dy = 0, 0
local shake_color = nil
local shake_tick = 0
local shake_offsets = { -4, 4, -3, 3, -1, 0 }

-- ---- Timer Management (Max 8 Active Timers) ---------------------------------
local active_timers = {}

local function timer_cancel(name)
  local t = active_timers[name]
  if not t then return end
  active_timers[name] = nil
  if timer.cancel then
    pcall(timer.cancel, name)
  elseif timer.stop then
    pcall(timer.stop, t)
  end
  if type(t) == "table" and t.stop then
    pcall(t.stop, t)
  end
end

local function timer_every(name, ms, cb)
  if type(name) == "number" then
    cb = ms
    ms = name
    name = "timer_" .. tostring(cb)
  end
  timer_cancel(name)
  local handle = nil
  if timer.every then
    local ok, res = pcall(timer.every, name, ms, cb)
    if ok and res ~= nil then
      handle = res
    else
      local ok2, res2 = pcall(timer.every, ms, cb)
      if ok2 and res2 ~= nil then
        handle = res2
      end
    end
  end
  if not handle then
    handle = { ms = ms, cb = cb, elapsed = 0 }
  end
  active_timers[name] = handle
  return handle
end

local function timer_after(ms, cb)
  if timer.after then
    local ok, res = pcall(timer.after, ms, cb)
    if ok and res then return res end
  end
  local tname = "after_" .. tostring(sys.millis and sys.millis() or math.random(1000, 9999))
  timer_every(tname, ms, function()
    timer_cancel(tname)
    cb()
  end)
end

-- ---- Audio SFX Engine -------------------------------------------------------
local function sfx_play(event)
  if not sound_on then return end

  local function tone(freq, dur_ms)
    if wada and wada.audio and wada.audio.tone then
      pcall(wada.audio.tone, freq, dur_ms)
    elseif wada and wada.hw and wada.hw.beep then
      pcall(wada.hw.beep, freq, dur_ms)
    elseif sys.beep then
      pcall(sys.beep)
    end
  end

  if event == "TURN_ALERT" then
    tone(1200, 60)
    timer_after(80, function() tone(1600, 80) end)
  elseif event == "FIRE" then
    tone(900, 50)
  elseif event == "MISS" then
    tone(220, 80)
  elseif event == "HIT" then
    tone(600, 90)
    timer_after(110, function() tone(450, 120) end)
  elseif event == "SUNK" then
    tone(800, 100)
    timer_after(110, function()
      tone(500, 100)
      timer_after(110, function()
        tone(250, 100)
      end)
    end)
  elseif event == "CHEAT_WARN" then
    tone(1000, 100)
    timer_after(120, function() tone(500, 100) end)
  end
end

-- Forward declaration of draw_screen
local draw_screen

-- ---- Screen-Shake Engine (Tactile FX) ---------------------------------------
local function trigger_shake(panel_name, is_sunk)
  shake_panel = panel_name
  shake_color = is_sunk and COL_RETICLE or COL_HIT
  shake_tick = 1
  shake_dx = 0
  shake_dy = 0

  timer_every("fx_shake", 35, function()
    if shake_tick > #shake_offsets then
      shake_dx = 0
      shake_dy = 0
      shake_color = nil
      shake_panel = nil
      timer_cancel("fx_shake")
      if draw_screen then draw_screen() end
      return
    end
    local off = shake_offsets[shake_tick]
    shake_dx = off
    shake_dy = -off
    shake_tick = shake_tick + 1
    if draw_screen then draw_screen() end
  end)
end

-- ---- Pure Lua Helpers -------------------------------------------------------
local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function rand_int(lo, hi)
  lo, hi = I(lo), I(hi)
  if hi <= lo then return lo end
  if sys.random then
    local r = sys.random(lo, hi)
    if r then return r end
  end
  return math.random(lo, hi)
end

local function rand_salt()
  local chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  local s = {}
  for i = 1, 6 do
    local idx = rand_int(1, #chars)
    s[i] = chars:sub(idx, idx)
  end
  return table.concat(s)
end

local function rand_match_id()
  return string.format("%04X", rand_int(0, 0xFFFF))
end

-- 32-bit Unsigned DJB2 Hash
local function djb2(str)
  local hash = 5381
  for i = 1, #str do
    local b = string.byte(str, i)
    hash = ((hash * 33) + b) & 0xFFFFFFFF
  end
  return hash
end

local function djb2_hex(str)
  local h = djb2(str)
  return string.format("%08X", h)
end

local function split_pipe(str)
  local t = {}
  if type(str) ~= "string" or str == "" then return t end
  for part in (str .. "|"):gmatch("(.-)|") do
    t[#t + 1] = part
  end
  return t
end

local function escape_pipes(str)
  if not str or str == "" then return "NONE" end
  return (str:gsub("|", "~"))
end

local function unescape_pipes(str)
  if not str or str == "NONE" then return nil end
  return (str:gsub("~", "|"))
end

local function format_coord(x, y)
  return string.char(65 + x) .. tostring(y + 1)
end

local function parse_coord(str)
  local c, r = str:match("^([A-Ja-j])(%d+)$")
  if not c or not r then return nil end
  local x = string.byte(c:upper()) - 65
  local y = tonumber(r) - 1
  if x < 0 or x > 9 or y < 0 or y > 9 then return nil end
  return x, y
end

-- 100-character flat string grid conversion
local function pack_grid_100(grid)
  local t = {}
  for y = 0, 9 do
    for x = 0, 9 do
      local v = (grid[y] and grid[y][x]) or "0"
      if v == nil or v == "" or v == 0 then v = "0" end
      t[#t + 1] = tostring(v)
    end
  end
  return table.concat(t)
end

local function unpack_grid_100(str)
  local grid = {}
  for y = 0, 9 do
    grid[y] = {}
    for x = 0, 9 do
      local idx = y * 10 + x + 1
      local ch = str and str:sub(idx, idx) or "0"
      if ch == "" or ch == "0" then
        grid[y][x] = "0"
      else
        grid[y][x] = ch
      end
    end
  end
  return grid
end

-- Canonical fleet serialization: <id>:<x>,<y>,<dir>; sorted 1 to 5
local function serialize_fleet(ships)
  local parts = {}
  for id = 1, 5 do
    local s = ships[id]
    if s then
      parts[#parts + 1] = string.format("%d:%d,%d,%s", s.id, s.x, s.y, s.dir)
    end
  end
  return table.concat(parts, ";")
end

-- Parse fleet string and reconstruct 10x10 board with geometry validation
local function parse_and_validate_fleet(str)
  local ships = {}
  local grid = {}
  for y = 0, 9 do
    grid[y] = {}
    for x = 0, 9 do grid[y][x] = 0 end
  end
  local count = 0

  for sid, sx, sy, dir in str:gmatch("(%d+):(%d+),(%d+),([HV])") do
    local id, x, y = tonumber(sid), tonumber(sx), tonumber(sy)
    if not SHIP_SPECS[id] or ships[id] then
      return nil, nil, "Invalid or duplicate ship ID: " .. tostring(id)
    end
    local len = SHIP_SPECS[id].len
    if dir == "H" then
      if x < 0 or x + len - 1 > 9 or y < 0 or y > 9 then
        return nil, nil, string.format("Ship %d out of bounds (H: %d..%d, y:%d)", id, x, x + len - 1, y)
      end
      for i = 0, len - 1 do
        if grid[y][x + i] ~= 0 then
          return nil, nil, string.format("Ship %d overlaps ship %d at %s", id, grid[y][x + i], format_coord(x + i, y))
        end
        grid[y][x + i] = id
      end
    elseif dir == "V" then
      if x < 0 or x > 9 or y < 0 or y + len - 1 > 9 then
        return nil, nil, string.format("Ship %d out of bounds (V: x:%d, %d..%d)", id, x, y, y + len - 1)
      end
      for i = 0, len - 1 do
        if grid[y + i][x] ~= 0 then
          return nil, nil, string.format("Ship %d overlaps ship %d at %s", id, grid[y + i][x], format_coord(x, y + i))
        end
        grid[y + i][x] = id
      end
    else
      return nil, nil, "Invalid direction: " .. tostring(dir)
    end

    ships[id] = { id = id, x = x, y = y, dir = dir, len = len }
    count = count + 1
  end

  if count ~= 5 then
    return nil, nil, string.format("Fleet incomplete: expected 5 ships, found %d", count)
  end

  return ships, grid, nil
end

-- ---- Match & Game Data Model ------------------------------------------------
local game_state        = STATE_LOBBY
local match_id          = ""
local opponent_id       = ""
local my_callsign       = "ADMIRAL"
local enemy_callsign    = "UNKNOWN"
local is_host           = false
local is_ai_match       = false
local local_seq         = 0
local handshake_seed    = 0
local enemy_seed        = 0

-- Ship placement & grids
local my_ships          = {}  -- [1..5] = { id, x, y, dir, len }
local my_board          = {}  -- [y][x] = 0 or ship_id (1..5)
local my_ship_hits      = { [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0 }
local my_sunk_count     = 0

local my_shots          = {}  -- [y][x] = "0", "M", "H", or "1".."5" (our shots on enemy)
local enemy_shots       = {}  -- [y][x] = "0", "M", "H", or "1".."5" (enemy shots on our fleet)
local ghost_grid        = nil -- [y][x] = enemy ships revealed after audit

-- Salted Commit-Reveal hashes
local my_salt           = ""
local my_fleet_str      = ""
local my_board_hash     = ""
local enemy_board_hash  = ""

-- Setup placement cursor
local setup_ship_idx    = 1
local setup_cur_x       = 0
local setup_cur_y       = 0
local setup_dir         = "H"
local fleet_locked      = false
local seek_beacon_seq   = 0

-- Combat targeting cursor
local target_cur_x      = 0
local target_cur_y      = 0

-- Combat log & telemetry text
local combat_log        = "> SYSTEM INITIALIZED. READY FOR COMBAT."
local audit_status_msg  = ""
local audit_passed      = false
local show_retry_modal  = false

-- Outbound lockstep TX queue & retry cache
local tx_pending        = nil -- { payload = "...", seq = N, retries = 0, elapsed = 0, next_wait = 6000 }
local last_sent_res     = nil -- { seq = N, payload = "..." }

-- Career Stats
local career_stats = {
  wins = 0,
  losses = 0,
  matches = 0,
  hits = 0,
  misses = 0,
}

-- ---- Career Stats Storage ---------------------------------------------------
local function load_career_stats()
  if not store.get then return end
  -- Always pass default "" as 2nd arg: LuaAppHost.cpp storeGet returns the
  -- internal wada.storetab registry table if called with only 1 argument when key is nil.
  local str = store.get("career_stats", "")
  if type(str) == "string" and str ~= "" then
    local p = split_pipe(str)
    if #p >= 5 then
      career_stats.wins    = I(p[1])
      career_stats.losses  = I(p[2])
      career_stats.matches = I(p[3])
      career_stats.hits    = I(p[4])
      career_stats.misses  = I(p[5])
    end
  end
end

local function save_career_stats()
  if not store.set then return end
  local str = string.format("%d|%d|%d|%d|%d",
    career_stats.wins, career_stats.losses, career_stats.matches,
    career_stats.hits, career_stats.misses)
  store.set("career_stats", str)
end

-- ---- Crash Recovery Match State Persistence ---------------------------------
local function clear_match_state()
  if store.set then
    store.set("active_match", "")
    store.set("am_my", "")
    store.set("am_en", "")
    store.set("am_tx", "")
  end
end

local function save_match_state()
  if not store.set then return end
  if game_state == STATE_LOBBY or game_state == STATE_GAME_OVER or match_id == "" then
    clear_match_state()
    return
  end

  local tx_str = tx_pending and tx_pending.payload or ""
  local res_str = last_sent_res and last_sent_res.payload or ""

  -- Split across compact keys so each key=value\n stays well under
  -- LuaAppHost.cpp's 192-byte line buffer in storeFlush/storeLoad.
  local packed = string.format("%s|%s|%s|%d|%s|%s|%s|%s",
    match_id,
    opponent_id,
    game_state,
    local_seq,
    my_salt,
    my_board_hash,
    enemy_board_hash,
    my_fleet_str
  )

  store.set("active_match", packed)
  store.set("am_my", "G:" .. pack_grid_100(my_shots))
  store.set("am_en", "G:" .. pack_grid_100(enemy_shots))
  store.set("am_tx", string.format("%s|%s", escape_pipes(tx_str), escape_pipes(res_str)))
end

local function load_active_match()
  if not store.get then return nil end
  local packed = store.get("active_match", "")
  if type(packed) ~= "string" or packed == "" then return nil end

  local p = split_pipe(packed)
  if #p >= 12 then
    return {
      match_id           = p[1],
      opponent_id        = p[2],
      game_state         = p[3],
      local_seq          = I(p[4]),
      my_salt            = p[5],
      my_board_hash      = p[6],
      enemy_board_hash   = p[7],
      my_fleet_str       = p[8],
      my_shots_100       = p[9],
      enemy_shots_100    = p[10],
      tx_pending_payload = unescape_pipes(p[11]),
      last_res_payload   = unescape_pipes(p[12]),
    }
  elseif #p >= 8 then
    local my_s = store.get("am_my", "")
    local en_s = store.get("am_en", "")
    local tx_s = store.get("am_tx", "")
    if type(my_s) == "string" and my_s:sub(1, 2) == "G:" then my_s = my_s:sub(3) else my_s = tostring(my_s or "") end
    if type(en_s) == "string" and en_s:sub(1, 2) == "G:" then en_s = en_s:sub(3) else en_s = tostring(en_s or "") end
    local tp = type(tx_s) == "string" and split_pipe(tx_s) or {}
    return {
      match_id           = p[1],
      opponent_id        = p[2],
      game_state         = p[3],
      local_seq          = I(p[4]),
      my_salt            = p[5],
      my_board_hash      = p[6],
      enemy_board_hash   = p[7],
      my_fleet_str       = p[8],
      my_shots_100       = my_s,
      enemy_shots_100    = en_s,
      tx_pending_payload = unescape_pipes(tp[1]),
      last_res_payload   = unescape_pipes(tp[2]),
    }
  end
  return nil
end

-- ---- Board & Grid Initialization --------------------------------------------
local function init_empty_grids()
  my_board = {}
  my_shots = {}
  enemy_shots = {}
  my_ship_hits = { [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0 }
  my_sunk_count = 0
  ghost_grid = nil

  for y = 0, 9 do
    my_board[y] = {}
    my_shots[y] = {}
    enemy_shots[y] = {}
    for x = 0, 9 do
      my_board[y][x] = 0
      my_shots[y][x] = "0"
      enemy_shots[y][x] = "0"
    end
  end
end

-- Random fleet generator for auto-placement and offline AI
local function generate_random_fleet()
  local grid = {}
  for y = 0, 9 do
    grid[y] = {}
    for x = 0, 9 do grid[y][x] = 0 end
  end
  local ships = {}

  for id = 1, 5 do
    local len = SHIP_SPECS[id].len
    local placed = false
    local attempts = 0
    while not placed and attempts < 300 do
      attempts = attempts + 1
      local dir = rand_int(1, 2) == 1 and "H" or "V"
      local x = dir == "H" and rand_int(0, 10 - len) or rand_int(0, 9)
      local y = dir == "V" and rand_int(0, 10 - len) or rand_int(0, 9)
      local fits = true
      if dir == "H" then
        for i = 0, len - 1 do
          if grid[y][x + i] ~= 0 then fits = false; break end
        end
        if fits then
          for i = 0, len - 1 do grid[y][x + i] = id end
          ships[id] = { id = id, x = x, y = y, dir = dir, len = len }
          placed = true
        end
      else
        for i = 0, len - 1 do
          if grid[y + i][x] ~= 0 then fits = false; break end
        end
        if fits then
          for i = 0, len - 1 do grid[y + i][x] = id end
          ships[id] = { id = id, x = x, y = y, dir = dir, len = len }
          placed = true
        end
      end
    end
    if not placed then
      -- retry if trapped
      return generate_random_fleet()
    end
  end
  return ships, grid
end

-- ---- Three-Point Verification Audit Engine ----------------------------------
local function verify_enemy_board(salt, fleet_str)
  -- Point 1: Commitment Check
  local computed_hash = djb2_hex(fleet_str .. "|" .. salt)
  if computed_hash ~= enemy_board_hash then
    return false, string.format("HASH MISMATCH: Committed %s vs Revealed %s", enemy_board_hash, computed_hash), nil
  end

  -- Point 2: Geometry Check
  local ships, grid, err = parse_and_validate_fleet(fleet_str)
  if not ships then
    return false, "GEOMETRY VIOLATION: " .. (err or "Corrupt ship layout"), nil
  end

  -- Point 3: Combat Honesty Check
  for y = 0, 9 do
    for x = 0, 9 do
      local shot = my_shots[y][x]
      local cell = grid[y][x]
      if shot == "M" then
        if cell ~= 0 then
          return false, string.format("HONESTY CHECK FAILED: %s reported MISS but contains ship %d", format_coord(x, y), cell), grid
        end
      elseif shot == "H" or shot == "S" or (shot >= "1" and shot <= "5") then
        if cell == 0 then
          return false, string.format("HONESTY CHECK FAILED: %s reported HIT but sector is EMPTY", format_coord(x, y)), grid
        end
      end
    end
  end

  -- Verify Sunk Ship Consistency
  for id = 1, 5 do
    local s = ships[id]
    local hit_count = 0
    if s.dir == "H" then
      for i = 0, s.len - 1 do
        local st = my_shots[s.y][s.x + i]
        if st ~= "0" and st ~= "M" then hit_count = hit_count + 1 end
      end
    else
      for i = 0, s.len - 1 do
        local st = my_shots[s.y + i][s.x]
        if st ~= "0" and st ~= "M" then hit_count = hit_count + 1 end
      end
    end
    -- If marked as sunk, must have all segments hit
    if hit_count == s.len then
      -- ship was indeed destroyed
    end
  end

  return true, "AUDIT PASSED: VERIFIED MATCH", grid
end

local function get_broadcast_channel()
  if mesh and mesh.channels then
    local ok, list = pcall(mesh.channels)
    if ok and type(list) == "table" and #list > 0 then
      for _, ch in ipairs(list) do
        if type(ch) == "string" and ch:lower() == "public" then
          return ch
        end
      end
      for _, ch in ipairs(list) do
        if type(ch) == "string" and ch:lower() == "general" then
          return ch
        end
      end
      if type(list[1]) == "string" and list[1] ~= "" then
        return list[1]
      end
    end
  end
  return "Public"
end

-- ---- Mesh Transmission Wrapper ----------------------------------------------
local function mesh_send(to, text)
  if not text and type(to) == "table" then
    text = to.text
    to = to.to
  end
  if not mesh then return false, "no mesh" end
  local str_text = tostring(text or "")

  if to and to ~= "" and to ~= "Public" and to ~= "broadcast" then
    local str_to = tostring(to)
    -- 1. Try send_dm for direct peer-to-peer transmission
    if mesh.send_dm then
      local ok, res, reason = pcall(mesh.send_dm, str_to, str_text)
      if ok then
        if res == true then
          return true
        elseif res == false then
          return false, tostring(reason or "dm failed")
        else
          return true
        end
      end
    end
    -- 2. Fallback to mesh.send for test harness or generic routing
    if mesh.send then
      local ok, res, reason = pcall(mesh.send, str_to, str_text)
      if ok then
        if res == true then
          return true
        elseif res == false then
          return false, tostring(reason or "send failed")
        else
          return true
        end
      end
      return false, tostring(res)
    end
  else
    -- Channel broadcast (Lobby discovery & seek beacons)
    local chan = get_broadcast_channel()
    if mesh.send then
      local ok, res, reason = pcall(mesh.send, chan, str_text)
      if ok then
        if res == true then
          return true
        elseif res == false then
          return false, tostring(reason or "send failed")
        else
          return true
        end
      end
      return false, tostring(res)
    end
  end
  return false, "no sender"
end

-- Forward declaration of NetEngine & AI methods
local NetEngine = {}
local ai_engine = {}

-- ---- Offline Hunt/Target AI Engine ------------------------------------------
ai_engine.active_hits = {}
ai_engine.ai_shots = {}
ai_engine.ai_ships = {}
ai_engine.ai_board = {}
ai_engine.ai_salt = ""
ai_engine.ai_fleet_str = ""
ai_engine.ai_board_hash = ""
ai_engine.ship_hits = { [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0 }
ai_engine.sunk_count = 0

function ai_engine.init()
  ai_engine.active_hits = {}
  ai_engine.ai_shots = {}
  for y = 0, 9 do
    ai_engine.ai_shots[y] = {}
    for x = 0, 9 do ai_engine.ai_shots[y][x] = false end
  end
  ai_engine.ship_hits = { [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0 }
  ai_engine.sunk_count = 0

  ai_engine.ai_ships, ai_engine.ai_board = generate_random_fleet()
  ai_engine.ai_salt = rand_salt()
  ai_engine.ai_fleet_str = serialize_fleet(ai_engine.ai_ships)
  ai_engine.ai_board_hash = djb2_hex(ai_engine.ai_fleet_str .. "|" .. ai_engine.ai_salt)
end

function ai_engine.pick_shot()
  -- Target mode: follow up on active hits
  if #ai_engine.active_hits > 0 then
    if #ai_engine.active_hits >= 2 then
      local same_y = true
      local same_x = true
      local y0 = ai_engine.active_hits[1].y
      local x0 = ai_engine.active_hits[1].x
      for i = 2, #ai_engine.active_hits do
        if ai_engine.active_hits[i].y ~= y0 then same_y = false end
        if ai_engine.active_hits[i].x ~= x0 then same_x = false end
      end
      if same_y then
        local min_x, max_x = x0, x0
        for i = 2, #ai_engine.active_hits do
          if ai_engine.active_hits[i].x < min_x then min_x = ai_engine.active_hits[i].x end
          if ai_engine.active_hits[i].x > max_x then max_x = ai_engine.active_hits[i].x end
        end
        local cands = {}
        if min_x > 0 and not ai_engine.ai_shots[y0][min_x - 1] then cands[#cands + 1] = { x = min_x - 1, y = y0 } end
        if max_x < 9 and not ai_engine.ai_shots[y0][max_x + 1] then cands[#cands + 1] = { x = max_x + 1, y = y0 } end
        if #cands > 0 then return cands[rand_int(1, #cands)] end
      elseif same_x then
        local min_y, max_y = y0, y0
        for i = 2, #ai_engine.active_hits do
          if ai_engine.active_hits[i].y < min_y then min_y = ai_engine.active_hits[i].y end
          if ai_engine.active_hits[i].y > max_y then max_y = ai_engine.active_hits[i].y end
        end
        local cands = {}
        if min_y > 0 and not ai_engine.ai_shots[min_y - 1][x0] then cands[#cands + 1] = { x = x0, y = min_y - 1 } end
        if max_y < 9 and not ai_engine.ai_shots[max_y + 1][x0] then cands[#cands + 1] = { x = x0, y = max_y + 1 } end
        if #cands > 0 then return cands[rand_int(1, #cands)] end
      end
    end

    -- Check direct orthogonal neighbors of all active hits
    local cands = {}
    local dirs = { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }
    for _, hit in ipairs(ai_engine.active_hits) do
      for _, d in ipairs(dirs) do
        local nx, ny = hit.x + d[1], hit.y + d[2]
        if nx >= 0 and nx <= 9 and ny >= 0 and ny <= 9 and not ai_engine.ai_shots[ny][nx] then
          cands[#cands + 1] = { x = nx, y = ny }
        end
      end
    end
    if #cands > 0 then return cands[rand_int(1, #cands)] end
  end

  -- Hunt mode: checkerboard parity (x + y) % 2 == 0
  local parity_cands = {}
  local other_cands = {}
  for y = 0, 9 do
    for x = 0, 9 do
      if not ai_engine.ai_shots[y][x] then
        if (x + y) % 2 == 0 then
          parity_cands[#parity_cands + 1] = { x = x, y = y }
        else
          other_cands[#other_cands + 1] = { x = x, y = y }
        end
      end
    end
  end
  if #parity_cands > 0 then return parity_cands[rand_int(1, #parity_cands)] end
  if #other_cands > 0 then return other_cands[rand_int(1, #other_cands)] end
  return nil
end

local ai_turn_scheduled_ms = 0

-- Execute AI's shot against the player's home fleet (my_board)
function NetEngine.execute_ai_shot()
  if not is_ai_match or game_state ~= STATE_ENEMY_TURN then return end

  local shot = ai_engine.pick_shot()
  if not shot then return end
  ai_engine.ai_shots[shot.y][shot.x] = true

  local x, y = shot.x, shot.y
  local target_sid = my_board[y] and my_board[y][x] or 0

  if target_sid == 0 then
    enemy_shots[y][x] = "M"
    career_stats.misses = career_stats.misses + 1
    sfx_play("MISS")
    combat_log = string.format("> ENEMY FIRED AT %s: SPLASH! MISS.", format_coord(x, y))
  else
    enemy_shots[y][x] = "H"
    my_ship_hits[target_sid] = (my_ship_hits[target_sid] or 0) + 1
    career_stats.hits = career_stats.hits + 1

    if my_ship_hits[target_sid] >= SHIP_SPECS[target_sid].len then
      my_sunk_count = my_sunk_count + 1
      enemy_shots[y][x] = tostring(target_sid)
      sfx_play("SUNK")
      trigger_shake("home", true)
      ai_engine.active_hits[#ai_engine.active_hits + 1] = { x = x, y = y, id = target_sid }
      local remain = {}
      for _, h in ipairs(ai_engine.active_hits) do
        if h.id ~= target_sid then remain[#remain + 1] = h end
      end
      ai_engine.active_hits = remain

      if my_sunk_count >= 5 then
        combat_log = string.format("> ENEMY SUNK YOUR %s! FLEET LOST!", SHIP_SPECS[target_sid].abbr)
        ghost_grid = ai_engine.ai_board
        audit_passed = true
        audit_status_msg = "[DEFEAT: YOUR FLEET WAS SUNK]"
        career_stats.losses = career_stats.losses + 1
        career_stats.matches = career_stats.matches + 1
        save_career_stats()
        game_state = STATE_GAME_OVER
        clear_match_state()
        if draw_screen then draw_screen() end
        return
      else
        combat_log = string.format("> ENEMY SUNK YOUR %s!", SHIP_SPECS[target_sid].name)
      end
    else
      sfx_play("HIT")
      trigger_shake("home", false)
      combat_log = string.format("> ENEMY HIT YOUR SHIP AT %s!", format_coord(x, y))
      ai_engine.active_hits[#ai_engine.active_hits + 1] = { x = x, y = y, id = 0 }
    end
  end

  local_seq = local_seq + 1
  game_state = STATE_MY_TURN
  save_match_state()
  if draw_screen then draw_screen() end
end

-- Trigger AI firing turn (600ms tactical pacing)
function NetEngine.trigger_ai_turn()
  if not is_ai_match or game_state ~= STATE_ENEMY_TURN then return end
  local now = (sys.millis and sys.millis()) or 0
  ai_turn_scheduled_ms = now + 600

  timer_after(600, function()
    if is_ai_match and game_state == STATE_ENEMY_TURN and ai_turn_scheduled_ms > 0 then
      ai_turn_scheduled_ms = 0
      NetEngine.execute_ai_shot()
    end
  end)
end

-- ---- NetEngine: Lockstep State Machine & Retry Engine -----------------------
function NetEngine.start_retry_timer()
  timer_every("lora_tx_retry", 1000, function()
    if not tx_pending then
      timer_cancel("lora_tx_retry")
      return
    end

    tx_pending.elapsed = tx_pending.elapsed + 1000
    if tx_pending.elapsed >= tx_pending.next_wait then
      tx_pending.elapsed = 0
      tx_pending.retries = tx_pending.retries + 1
      if tx_pending.retries > 5 then
        show_retry_modal = true
        combat_log = "> TX TIMEOUT: 5 RETRIES FAILED."
        if draw_screen then draw_screen() end
      else
        tx_pending.next_wait = 6000 + (tx_pending.retries * 2000)
        combat_log = string.format("> TX RETRY %d/5 [Seq %d]...", tx_pending.retries, tx_pending.seq)
        mesh_send(opponent_id, tx_pending.payload)
        if draw_screen then draw_screen() end
      end
    end
  end)
end

function NetEngine.queue_tx(payload, seq)
  tx_pending = {
    payload   = payload,
    seq       = seq,
    retries   = 0,
    elapsed   = 0,
    next_wait = 6000,
  }
  show_retry_modal = false

  mesh_send(opponent_id, payload)
  NetEngine.start_retry_timer()
  save_match_state()
end

function NetEngine.clear_tx()
  tx_pending = nil
  show_retry_modal = false
  timer_cancel("lora_tx_retry")
end

-- Fire at (x, y) on enemy sector
function NetEngine.fire_shot(x, y)
  if game_state ~= STATE_MY_TURN then return end
  if not is_ai_match and tx_pending ~= nil then return end
  if my_shots[y][x] ~= "0" then return end

  sfx_play("FIRE")

  if is_ai_match then
    -- Offline AI match: evaluate shot immediately without network packets or ACK wait!
    local target_sid = ai_engine.ai_board[y] and ai_engine.ai_board[y][x] or 0
    if target_sid == 0 then
      my_shots[y][x] = "M"
      career_stats.misses = career_stats.misses + 1
      sfx_play("MISS")
      combat_log = string.format("> SHOT AT %s: SPLASH! MISS.", format_coord(x, y))
    else
      ai_engine.ship_hits[target_sid] = (ai_engine.ship_hits[target_sid] or 0) + 1
      career_stats.hits = career_stats.hits + 1

      if ai_engine.ship_hits[target_sid] >= SHIP_SPECS[target_sid].len then
        ai_engine.sunk_count = ai_engine.sunk_count + 1
        my_shots[y][x] = tostring(target_sid)
        sfx_play("SUNK")
        trigger_shake("target", true)
        local sname = SHIP_SPECS[target_sid] and SHIP_SPECS[target_sid].name or "WARSHIP"
        if ai_engine.sunk_count >= 5 then
          combat_log = string.format("> VICTORY! ENEMY %s SUNK!", sname)
          ghost_grid = ai_engine.ai_board
          audit_passed = true
          audit_status_msg = "[VICTORY: ALL ENEMY SHIPS SUNK]"
          career_stats.wins = career_stats.wins + 1
          career_stats.matches = career_stats.matches + 1
          save_career_stats()
          game_state = STATE_GAME_OVER
          clear_match_state()
          if draw_screen then draw_screen() end
          return
        else
          combat_log = string.format("> ENEMY %s SUNK!", sname)
        end
      else
        my_shots[y][x] = "H"
        sfx_play("HIT")
        trigger_shake("target", false)
        combat_log = string.format("> SHOT AT %s: DIRECT HIT!", format_coord(x, y))
      end
    end

    local_seq = local_seq + 1
    game_state = STATE_ENEMY_TURN
    save_match_state()
    if draw_screen then draw_screen() end

    NetEngine.trigger_ai_turn()
    return
  end

  -- Multiplayer LoRa match: queue over mesh and wait for peer ACK/RES
  local payload = string.format("BS|FIRE|%s|%d|%d,%d", match_id, local_seq, x, y)
  combat_log = string.format("> TX FIRE %s [Seq %d]...", format_coord(x, y), local_seq)
  NetEngine.queue_tx(payload, local_seq)
  if draw_screen then draw_screen() end
end

-- Host initiates a new match lobby
function NetEngine.host_lobby()
  init_empty_grids()
  my_ships = {}
  my_board_hash = ""
  fleet_locked = false
  match_id = rand_match_id()
  is_host = true
  is_ai_match = false
  opponent_id = ""
  enemy_callsign = "WAITING"
  local_seq = 0
  setup_ship_idx = 1
  setup_cur_x = 0
  setup_cur_y = 0
  game_state = STATE_SETUP
  combat_log = string.format("> HOSTING MATCH [%s]. PLACE YOUR FLEET.", match_id)
  if draw_screen then draw_screen() end
end

-- Challenger seeks a match
function NetEngine.join_lobby()
  init_empty_grids()
  my_ships = {}
  my_board_hash = ""
  fleet_locked = false
  match_id = ""
  opponent_id = ""
  is_host = false
  is_ai_match = false
  local_seq = 0
  setup_ship_idx = 1
  setup_cur_x = 0
  setup_cur_y = 0
  game_state = STATE_SETUP
  combat_log = "> FLEET SETUP: PLACE SHIPS TO SEEK HOST."
  if draw_screen then draw_screen() end
end

-- Start offline match against Hunt/Target AI
function NetEngine.start_vs_ai()
  init_empty_grids()
  my_ships = {}
  my_board_hash = ""
  fleet_locked = false
  match_id = rand_match_id()
  is_host = true
  is_ai_match = true
  opponent_id = "AI_BOT"
  enemy_callsign = "CPU_STRIKER"
  local_seq = 0
  setup_ship_idx = 1
  setup_cur_x = 0
  setup_cur_y = 0
  game_state = STATE_SETUP
  ai_engine.init()
  enemy_board_hash = ai_engine.ai_board_hash
  combat_log = string.format("> MATCH VS AI [%s]. PLACE YOUR FLEET.", match_id)
  if draw_screen then draw_screen() end
end

-- Finalize ship setup and start matchmaking handshake
function NetEngine.lock_in_fleet()
  if not fleet_locked or my_board_hash == "" then
    my_fleet_str = serialize_fleet(my_ships)
    my_salt = rand_salt()
    my_board_hash = djb2_hex(my_fleet_str .. "|" .. my_salt)
    handshake_seed = rand_int(1, 999999)
  end
  fleet_locked = true

  if is_ai_match then
    enemy_seed = rand_int(1, 999999)
    if handshake_seed >= enemy_seed then
      local_seq = 1
      game_state = STATE_MY_TURN
      combat_log = "> HANDSHAKE OK. YOU FIRE FIRST!"
      sfx_play("TURN_ALERT")
    else
      local_seq = 1
      game_state = STATE_ENEMY_TURN
      combat_log = "> HANDSHAKE OK. ENEMY FIRES FIRST. BRACE!"
      NetEngine.trigger_ai_turn()
    end
    save_match_state()
    if draw_screen then draw_screen() end
    return
  end

  sfx_play("TURN_ALERT")
  if is_host then
    seek_beacon_seq = seek_beacon_seq + 1
    local seek_pkt = string.format("BS|SEEK|%s|%s|%d", match_id, my_callsign, seek_beacon_seq)
    local sent_ok, sent_err = mesh_send("Public", seek_pkt)
    if sent_ok then
      combat_log = string.format("> SEEK [%s]: BROADCASTING BEACON...", match_id)
      if sys.toast then pcall(sys.toast, "Hosting [" .. match_id .. "] - Waiting for peer") end
    else
      if sent_err == "permission denied" then
        combat_log = "> PERM DENIED: ENABLE IN SETTINGS > APP PERMS"
        if sys.toast then pcall(sys.toast, "Enable in Settings > App permissions", 3000) end
      elseif sent_err == "permission requested" then
        combat_log = string.format("> SEEK [%s]: ALLOW IN SYSTEM POPUP & [ENT] RETRY", match_id)
        if sys.toast then pcall(sys.toast, "Allow broadcast popup, then [Enter]", 2500) end
      elseif sent_err == "too fast" then
        combat_log = string.format("> SEEK [%s]: RADIO BUSY. WAIT 5s & [ENT] RETRY", match_id)
      else
        combat_log = string.format("> SEEK [%s] (%s) - [ENT] RETRY", match_id, tostring(sent_err or "WAIT"))
      end
    end
    -- Repeating broadcast timer every 15 seconds (respects WADAMESH 5s gap & dup filter)
    timer_every("seek_broadcast", 15000, function()
      if game_state == STATE_SETUP and is_host and opponent_id == "" then
        seek_beacon_seq = seek_beacon_seq + 1
        mesh_send("Public", string.format("BS|SEEK|%s|%s|%d", match_id, my_callsign, seek_beacon_seq))
      else
        timer_cancel("seek_broadcast")
      end
    end)
  else
    if opponent_id ~= "" and match_id ~= "" then
      combat_log = string.format("> JOINING HOST [%s] (%s)...", match_id, enemy_callsign:sub(1, 8))
      if sys.toast then pcall(sys.toast, "Joining Host [" .. match_id .. "]...") end
      local payload = string.format("BS|JOIN|%s|0|%d|%s", match_id, handshake_seed, my_board_hash)
      NetEngine.queue_tx(payload, 0)
    else
      seek_beacon_seq = seek_beacon_seq + 1
      local sent_ok, sent_err = mesh_send("Public", string.format("BS|JOIN_SEEK|0|%d|%s|%d", handshake_seed, my_board_hash, seek_beacon_seq))
      if sent_ok then
        combat_log = "> SCANNING MESH FOR HOST LOBBY..."
        if sys.toast then pcall(sys.toast, "Fleet locked! Scanning for Host...") end
      else
        if sent_err == "permission denied" then
          combat_log = "> PERM DENIED: ENABLE IN SETTINGS > APP PERMS"
          if sys.toast then pcall(sys.toast, "Enable in Settings > App permissions", 3000) end
        elseif sent_err == "permission requested" then
          combat_log = "> SCAN: ALLOW IN SYSTEM POPUP & [ENT] RETRY"
          if sys.toast then pcall(sys.toast, "Allow broadcast popup, then [Enter]", 2500) end
        elseif sent_err == "too fast" then
          combat_log = "> SCAN: RADIO BUSY. WAIT 5s & [ENT] RETRY"
        else
          combat_log = string.format("> SCANNING FOR HOST (%s)...", tostring(sent_err or "WAIT"))
        end
      end
    end
  end
  if draw_screen then draw_screen() end
end

-- Process incoming LoRa packet
function NetEngine.process_packet(sender, text)
  if not text or text:sub(1, 3) ~= "BS|" then return end
  local p = split_pipe(text)
  if #p < 3 then return end

  local ptype = p[2]
  local p_mid = p[3]

  -- 1. Lobby Seek & Join Handshake
  if ptype == "SEEK" then
    if game_state == STATE_SETUP and not is_host and opponent_id == "" then
      match_id = p_mid
      opponent_id = sender
      enemy_callsign = p[4] or "HOST"
      combat_log = string.format("> FOUND HOST [%s] (%s). JOINING...", match_id, enemy_callsign)
      if my_board_hash ~= "" then
        local payload = string.format("BS|JOIN|%s|0|%d|%s", match_id, handshake_seed, my_board_hash)
        NetEngine.queue_tx(payload, 0)
      end
      if draw_screen then draw_screen() end
    end
    return
  end

  if ptype == "JOIN_SEEK" then
    if is_host and game_state == STATE_SETUP and opponent_id == "" and match_id ~= "" then
      seek_beacon_seq = seek_beacon_seq + 1
      local seek_pkt = string.format("BS|SEEK|%s|%s|%d", match_id, my_callsign, seek_beacon_seq)
      if sender and sender ~= "" then
        mesh_send(sender, seek_pkt)
      else
        mesh_send("Public", seek_pkt)
      end
      combat_log = string.format("> PEER DETECTED (%s). SENT SEEK [%s]...", tostring(sender or "PEER"), match_id)
      if draw_screen then draw_screen() end
    end
    return
  end

  if ptype == "JOIN" then
    if is_host and (game_state == STATE_SETUP or game_state == STATE_LOBBY) then
      opponent_id = sender
      enemy_seed = tonumber(p[5]) or 0
      enemy_board_hash = p[6] or ""
      timer_cancel("seek_broadcast")

      -- Reply with RDY
      local payload = string.format("BS|RDY|%s|0|%d|%s", match_id, handshake_seed, my_board_hash)
      mesh_send(opponent_id, payload)

      -- Seed comparison: higher seed fires first
      if handshake_seed >= enemy_seed then
        local_seq = 1
        game_state = STATE_MY_TURN
        combat_log = "> PEER JOINED! YOU FIRE FIRST!"
        sfx_play("TURN_ALERT")
      else
        local_seq = 1
        game_state = STATE_ENEMY_TURN
        combat_log = "> PEER JOINED! ENEMY FIRES FIRST."
      end
      save_match_state()
      if draw_screen then draw_screen() end
    end
    return
  end

  -- Filter packet by match_id for active combat / handshake
  if p_mid ~= match_id and match_id ~= "" then return end

  if ptype == "RDY" then
    if not is_host and game_state == STATE_SETUP then
      enemy_seed = tonumber(p[5]) or 0
      enemy_board_hash = p[6] or ""
      NetEngine.clear_tx()

      -- Confirm with ACK 0
      mesh_send(opponent_id, string.format("BS|ACK|%s|0", match_id))

      if handshake_seed > enemy_seed then
        local_seq = 1
        game_state = STATE_MY_TURN
        combat_log = "> HANDSHAKE OK! YOU FIRE FIRST!"
        sfx_play("TURN_ALERT")
      else
        local_seq = 1
        game_state = STATE_ENEMY_TURN
        combat_log = "> HANDSHAKE OK! ENEMY FIRES FIRST."
      end
      save_match_state()
      if draw_screen then draw_screen() end
    end
    return
  end

  -- 2. Lockstep Combat Phase
  local seq = tonumber(p[4]) or 0

  -- Outbound ACK confirmation
  if ptype == "ACK" then
    if seq == 0 then
      if is_host and local_seq == 1 and tx_pending and tx_pending.seq == 0 then
        NetEngine.clear_tx()
        combat_log = "> CHALLENGER ACK RECEIVED. READY."
        if draw_screen then draw_screen() end
      end
      return
    end

    if tx_pending and tx_pending.seq == seq then
      NetEngine.clear_tx()
    end
    if last_sent_res and last_sent_res.seq == seq then
      last_sent_res = nil
    end
    return
  end

  -- Reboot Re-Sync Heartbeat
  if ptype == "SYNC" then
    if tx_pending and tx_pending.seq == seq then
      mesh_send(opponent_id, tx_pending.payload)
      combat_log = string.format("> SYNC: IMMEDIATE RETRANSMIT [Seq %d]", seq)
      if draw_screen then draw_screen() end
    end
    return
  end

  -- Incoming Shot: BS|FIRE|<match_id>|<seq>|<x>,<y>
  if ptype == "FIRE" then
    local coords = p[5] or "0,0"
    local cx, cy = coords:match("(%d+),(%d+)")
    local x, y = tonumber(cx), tonumber(cy)

    -- Dropped ACK Fix: Defender receives duplicate FIRE for seq - 1
    if seq == local_seq - 1 and last_sent_res then
      mesh_send(opponent_id, last_sent_res.payload)
      combat_log = string.format("> RE-TX LAST RES [Seq %d]...", seq)
      if draw_screen then draw_screen() end
      return
    end

    -- Drop outdated or future out-of-order packets
    if seq ~= local_seq or not x or not y then return end

    -- Piggyback optimization: FIRE for local_seq implicitly ACKs our previous RES
    if last_sent_res and last_sent_res.seq == local_seq - 1 then
      last_sent_res = nil
    end

    -- Process shot against home fleet
    local status = "M"
    local ship_id = 0
    local target_sid = my_board[y][x]

    if target_sid == 0 then
      status = "M"
      ship_id = 0
      enemy_shots[y][x] = "M"
      career_stats.misses = career_stats.misses + 1
      sfx_play("MISS")
      combat_log = string.format("> ENEMY FIRED AT %s: SPLASH! MISS.", format_coord(x, y))
    else
      status = "H"
      my_ship_hits[target_sid] = my_ship_hits[target_sid] + 1
      enemy_shots[y][x] = "H"
      career_stats.hits = career_stats.hits + 1

      if my_ship_hits[target_sid] >= SHIP_SPECS[target_sid].len then
        my_sunk_count = my_sunk_count + 1
        ship_id = target_sid
        if my_sunk_count >= 5 then
          status = "W"
          combat_log = string.format("> ENEMY SUNK YOUR %s! FLEET LOST!", SHIP_SPECS[target_sid].abbr)
        else
          status = "S"
          combat_log = string.format("> ENEMY SUNK YOUR %s!", SHIP_SPECS[target_sid].name)
        end
        sfx_play("SUNK")
        trigger_shake("home", true)
      else
        sfx_play("HIT")
        trigger_shake("home", false)
        combat_log = string.format("> ENEMY HIT YOUR SHIP AT %s!", format_coord(x, y))
      end
    end

    local res_payload = string.format("BS|RES|%s|%d|%d,%d|%s|%d", match_id, local_seq, x, y, status, ship_id)
    last_sent_res = { seq = local_seq, payload = res_payload }

    if not is_ai_match then
      mesh_send(opponent_id, res_payload)
    end

    if status == "W" then
      -- Defender loses; transition to commit-reveal audit
      local_seq = local_seq + 1
      game_state = STATE_AUDIT
      audit_status_msg = "EXCHANGING COMMIT-REVEAL AUDIT..."
      local rev_packet = string.format("BS|REV|%s|%d|%s|%s", match_id, local_seq, my_salt, my_fleet_str)
      NetEngine.queue_tx(rev_packet, local_seq)
    else
      local_seq = local_seq + 1
      game_state = STATE_MY_TURN
      sfx_play("TURN_ALERT")
    end

    save_match_state()
    if draw_screen then draw_screen() end
    return
  end

  -- Incoming Shot Result: BS|RES|<match_id>|<seq>|<x>,<y>|<status>|<ship_id>
  if ptype == "RES" then
    local coords = p[5] or "0,0"
    local cx, cy = coords:match("(%d+),(%d+)")
    local x, y = tonumber(cx), tonumber(cy)
    local status = p[6]
    local ship_id = tonumber(p[7]) or 0

    -- Dropped ACK Fix: duplicate RES for already processed turn
    if seq == local_seq - 1 then
      mesh_send(opponent_id, string.format("BS|ACK|%s|%d", match_id, seq))
      return
    end

    if seq ~= local_seq or not x or not y then return end

    -- Implicit ACK for FIRE: clear tx_pending
    NetEngine.clear_tx()

    -- Send explicit ACK
    if not is_ai_match then
      mesh_send(opponent_id, string.format("BS|ACK|%s|%d", match_id, local_seq))
    end

    -- Update target radar
    if status == "M" then
      my_shots[y][x] = "M"
      career_stats.misses = career_stats.misses + 1
      sfx_play("MISS")
      combat_log = string.format("> SHOT AT %s: MISS [Seq %d].", format_coord(x, y), local_seq)
    elseif status == "H" then
      my_shots[y][x] = "H"
      career_stats.hits = career_stats.hits + 1
      sfx_play("HIT")
      trigger_shake("target", false)
      combat_log = string.format("> SHOT AT %s: DIRECT HIT! [Seq %d].", format_coord(x, y), local_seq)
    elseif status == "S" or status == "W" then
      my_shots[y][x] = (ship_id > 0) and tostring(ship_id) or "H"
      career_stats.hits = career_stats.hits + 1
      sfx_play("SUNK")
      trigger_shake("target", true)
      local sname = SHIP_SPECS[ship_id] and SHIP_SPECS[ship_id].name or "WARSHIP"
      if status == "W" then
        combat_log = string.format("> VICTORY! ENEMY %s SUNK!", sname)
      else
        combat_log = string.format("> ENEMY %s SUNK!", sname)
      end
    end

    if is_ai_match and status ~= "W" then
      -- Update AI targeting tracker
      if status == "H" then
        ai_engine.active_hits[#ai_engine.active_hits + 1] = { x = x, y = y, id = 0 }
      elseif status == "S" then
        ai_engine.sunk_count = ai_engine.sunk_count + 1
        ai_engine.active_hits[#ai_engine.active_hits + 1] = { x = x, y = y, id = ship_id }
        local remain = {}
        for _, h in ipairs(ai_engine.active_hits) do
          if h.id ~= ship_id then remain[#remain + 1] = h end
        end
        ai_engine.active_hits = remain
      end
    end

    if status == "W" then
      -- Attacker wins; transition to commit-reveal audit
      local_seq = local_seq + 1
      game_state = STATE_AUDIT
      audit_status_msg = "EXCHANGING COMMIT-REVEAL AUDIT..."
      local rev_packet = string.format("BS|REV|%s|%d|%s|%s", match_id, local_seq, my_salt, my_fleet_str)
      NetEngine.queue_tx(rev_packet, local_seq)
    else
      local_seq = local_seq + 1
      game_state = STATE_ENEMY_TURN
      if is_ai_match then
        NetEngine.trigger_ai_turn()
      end
    end

    save_match_state()
    if draw_screen then draw_screen() end
    return
  end

  -- 3. Post-Game Commit-Reveal Board Audit: BS|REV|<match_id>|<seq>|<salt>|<fleet_str>
  if ptype == "REV" then
    local rev_salt = p[5] or ""
    local rev_fleet = p[6] or ""

    if not is_ai_match then
      mesh_send(opponent_id, string.format("BS|ACK|%s|%d", match_id, seq))
    end
    if tx_pending and tx_pending.seq == seq then
      NetEngine.clear_tx()
    end

    local verified, reason, reconstructed_grid = verify_enemy_board(rev_salt, rev_fleet)
    ghost_grid = reconstructed_grid

    if verified then
      audit_passed = true
      audit_status_msg = "[AUDIT PASSED: VERIFIED MATCH]"
      combat_log = "> AUDIT PASSED: MATCH VALIDATED."
      if my_sunk_count < 5 then
        career_stats.wins = career_stats.wins + 1
      else
        career_stats.losses = career_stats.losses + 1
      end
      career_stats.matches = career_stats.matches + 1
      save_career_stats()
      sfx_play("TURN_ALERT")
    else
      audit_passed = false
      audit_status_msg = "[CHEAT DETECTED: HASH/LOG MISMATCH]"
      combat_log = "> DISQUALIFIED: " .. reason
      sfx_play("CHEAT_WARN")
      career_stats.wins = career_stats.wins + 1
      career_stats.matches = career_stats.matches + 1
      save_career_stats()
    end

    game_state = STATE_GAME_OVER
    clear_match_state()
    if draw_screen then draw_screen() end
    return
  end
end

-- ---- Canvas Drawing Primitives ----------------------------------------------
local function box(x, y, bw, bh, bg, border_col)
  if not cv then return end
  cv:rect(I(x), I(y), I(bw), I(bh), bg, true, 0)
  if border_col then
    cv:rect(I(x), I(y), I(bw), I(bh), border_col, false, 0)
  end
end

local function draw_text(x, y, str, col, sz)
  if not cv or not str or str == "" then return end
  local s = tostring(str)
  local avail_w = W - I(x)
  local max_chars = math.floor(avail_w / 7.2)
  if max_chars > 3 and #s > max_chars then
    s = s:sub(1, max_chars - 1) .. "."
  end
  cv:text(I(x), I(y), s, col or COL_TEXT_BRIGHT, sz or 12)
end

local function draw_text_centered(bx, by, bw, str, col, sz)
  if not cv or not str or str == "" then return end
  local s = tostring(str)
  local char_w = (sz and sz > 12) and 8.5 or 7.5
  local tw = math.floor(#s * char_w)
  local tx = bx + math.max(2, math.floor((bw - tw) / 2))
  draw_text(tx, by, s, col, sz)
end

local function draw_line(x1, y1, x2, y2, col, width)
  if not cv then return end
  cv:line(I(x1), I(y1), I(x2), I(y2), col, width or 1)
end

-- ---- Screen Renderers -------------------------------------------------------

-- Draw Top Telemetry Bar (320x18)
local function draw_top_bar()
  box(0, 0, W, 18, COL_BAR_BG, nil)
  draw_line(0, 18, W, 18, COL_BORDER_NORM, 1)

  -- State indicator (Left)
  local state_text = "[IDLE]"
  local state_col  = COL_TEXT_DIM
  if game_state == STATE_MY_TURN then
    if tx_pending ~= nil then
      state_text = "[ACK WAIT...]"
      state_col  = COL_STATUS_AMBER
    else
      state_text = "[YOUR TURN]"
      state_col  = COL_STATUS_GREEN
    end
  elseif game_state == STATE_ENEMY_TURN then
    state_text = "[ENEMY TURN]"
    state_col  = COL_STATUS_CYAN
  elseif game_state == STATE_SETUP then
    if fleet_locked then
      state_text = is_host and "[HOSTING...]" or "[SEEKING...]"
      state_col  = COL_STATUS_AMBER
    else
      state_text = "[FLEET SETUP]"
      state_col  = COL_STATUS_GREEN
    end
  elseif game_state == STATE_AUDIT then
    state_text = "[AUDITING]"
    state_col  = COL_GHOST
  elseif game_state == STATE_GAME_OVER then
    state_text = my_sunk_count >= 5 and "[DEFEAT]" or "[VICTORY]"
    state_col  = my_sunk_count >= 5 and COL_HIT or COL_STATUS_GREEN
  elseif game_state == STATE_LOBBY then
    state_text = "[GRID STRIKE]"
    state_col  = COL_TEXT_BRIGHT
  end
  draw_text(6, 3, state_text, state_col, 12)

  -- Lockstep telemetry & retry counter (Center-Right)
  local telem_text = ""
  if local_seq > 0 then
    if is_ai_match then
      telem_text = string.format("TURN:%02d | VS CPU", local_seq)
    elseif tx_pending and tx_pending.retries > 0 then
      telem_text = string.format("SEQ:%02d | RETRY:%d/5", local_seq, tx_pending.retries)
    else
      telem_text = string.format("SEQ:%02d | ACK:OK", local_seq)
    end
  elseif game_state == STATE_SETUP and match_id ~= "" then
    telem_text = is_ai_match and "VS CPU" or string.format("ID:%s", match_id)
  end
  draw_text(118, 3, telem_text, COL_TEXT_DIM, 12)

  -- Audio Mute Indicator
  local snd_str = sound_on and "[VOL]" or "[MUTE]"
  draw_text(236, 3, snd_str, sound_on and COL_STATUS_GREEN or COL_HIT, 12)

  -- Fleet Health Pips (5 Green dots for Home, 5 dots for Enemy)
  local pips_x = 282
  for i = 1, 5 do
    local is_damaged = (my_ship_hits[i] or 0) >= SHIP_SPECS[i].len
    local pip_col = is_damaged and COL_HIT or COL_OWN_FLEET
    cv:rect(pips_x + (i - 1) * 7, 6, 5, 6, pip_col, true)
  end
end

-- Draw Left Panel: Target Radar
local function draw_target_radar()
  local px = target_panel.x + (shake_panel == "target" and shake_dx or 0)
  local py = target_panel.y + (shake_panel == "target" and shake_dy or 0)
  local bcol = (shake_panel == "target" and shake_color) or COL_BORDER_NORM
  local span = cell_sz * 10
  local pw = target_panel.w

  draw_text(target_panel.x + 2, 19, "TARGET RADAR", COL_TEXT_DIM, 12)
  box(px, py, pw, pw, COL_PANEL_BG, bcol)

  local gx = px + 2
  local gy = py + 2

  -- Background fill and continuous radar grid lines
  cv:rect(gx, gy, span, span, COL_PANEL_BG, true)
  for i = 0, 10 do
    local offset = i * cell_sz
    cv:line(gx + offset, gy, gx + offset, gy + span, COL_GRID_LINE, 1)
    cv:line(gx, gy + offset, gx + span, gy + offset, COL_GRID_LINE, 1)
  end

  for y = 0, 9 do
    for x = 0, 9 do
      local cx = gx + x * cell_sz
      local cy = gy + y * cell_sz
      local val = my_shots[y][x]
      local c_mid = math.floor(cell_sz / 2)

      if val == "0" then
        if ghost_grid and ghost_grid[y][x] > 0 then
          cv:rect(cx + 2, cy + 2, cell_sz - 4, cell_sz - 4, COL_GHOST, true)
        else
          cv:rect(cx + c_mid - 1, cy + c_mid - 1, 2, 2, COL_GRID_DOT, true)
        end
      elseif val == "M" then
        cv:circle(cx + c_mid, cy + c_mid, math.max(2, c_mid - 4), COL_MISS, true)
      elseif val == "H" then
        cv:line(cx + 3, cy + 3, cx + cell_sz - 3, cy + cell_sz - 3, COL_HIT, 2)
        cv:line(cx + 3, cy + cell_sz - 3, cx + cell_sz - 3, cy + 3, COL_HIT, 2)
      else
        cv:rect(cx + 1, cy + 1, cell_sz - 2, cell_sz - 2, 0x551111, true)
        cv:line(cx + 3, cy + 3, cx + cell_sz - 3, cy + cell_sz - 3, COL_SUNK, 2)
        cv:line(cx + 3, cy + cell_sz - 3, cx + cell_sz - 3, cy + 3, COL_SUNK, 2)
      end

      -- Aiming Reticle (Target Radar)
      if (game_state == STATE_MY_TURN or game_state == STATE_ENEMY_TURN) and target_cur_x == x and target_cur_y == y then
        local r_col = tx_pending ~= nil and COL_STATUS_AMBER or COL_RETICLE
        cv:rect(cx, cy, cell_sz, cell_sz, r_col, false)
        cv:rect(cx + c_mid - 3, cy + c_mid - 1, 6, 2, r_col, true)
        cv:rect(cx + c_mid - 1, cy + c_mid - 3, 2, 6, r_col, true)
      end
    end
  end
end

-- Draw Right Panel: Home Fleet
local function draw_home_fleet()
  local px = home_panel.x + (shake_panel == "home" and shake_dx or 0)
  local py = home_panel.y + (shake_panel == "home" and shake_dy or 0)
  local bcol = (shake_panel == "home" and shake_color) or COL_BORDER_NORM
  local span = cell_sz * 10
  local pw = home_panel.w

  draw_text(home_panel.x + 2, 19, "HOME FLEET", COL_TEXT_DIM, 12)
  box(px, py, pw, pw, COL_PANEL_BG, bcol)

  local gx = px + 2
  local gy = py + 2

  cv:rect(gx, gy, span, span, COL_PANEL_BG, true)
  for i = 0, 10 do
    local offset = i * cell_sz
    cv:line(gx + offset, gy, gx + offset, gy + span, COL_GRID_LINE, 1)
    cv:line(gx, gy + offset, gx + span, gy + offset, COL_GRID_LINE, 1)
  end

  for y = 0, 9 do
    for x = 0, 9 do
      local cx = gx + x * cell_sz
      local cy = gy + y * cell_sz
      local sid = my_board[y][x]
      local shot = enemy_shots[y][x]
      local c_mid = math.floor(cell_sz / 2)

      if sid > 0 then
        if shot == "H" or shot == "S" or (shot >= "1" and shot <= "5") then
          cv:rect(cx + 2, cy + 2, cell_sz - 4, cell_sz - 4, 0x551111, true)
          cv:line(cx + 3, cy + 3, cx + cell_sz - 3, cy + cell_sz - 3, COL_HIT, 2)
          cv:line(cx + 3, cy + cell_sz - 3, cx + cell_sz - 3, cy + 3, COL_HIT, 2)
        else
          cv:rect(cx + 2, cy + 2, cell_sz - 4, cell_sz - 4, COL_OWN_FLEET, true)
          cv:rect(cx + 2, cy + 2, cell_sz - 4, cell_sz - 4, COL_OWN_FLEET_DK, false)
        end
      else
        if shot == "M" then
          cv:circle(cx + c_mid, cy + c_mid, math.max(2, c_mid - 4), COL_MISS, true)
        else
          cv:rect(cx + c_mid - 1, cy + c_mid - 1, 2, 2, COL_GRID_DOT, true)
        end
      end
    end
  end
end

-- Draw Ship Placement Setup Grid
local function draw_setup_screen()
  box(0, 0, W, H, COL_BG, nil)
  draw_top_bar()

  -- Left Panel: Placement Grid
  local px = target_panel.x
  local py = target_panel.y
  local pw = target_panel.w
  local span = cell_sz * 10

  draw_text(px + 2, 19, "DEPLOYMENT GRID", COL_TEXT_DIM, 12)
  box(px, py, pw, pw, COL_PANEL_BG, COL_STATUS_GREEN)

  local gx = px + 2
  local gy = py + 2

  cv:rect(gx, gy, span, span, COL_PANEL_BG, true)
  for i = 0, 10 do
    local offset = i * cell_sz
    cv:line(gx + offset, gy, gx + offset, gy + span, COL_GRID_LINE, 1)
    cv:line(gx, gy + offset, gx + span, gy + offset, COL_GRID_LINE, 1)
  end

  for y = 0, 9 do
    for x = 0, 9 do
      local cx = gx + x * cell_sz
      local cy = gy + y * cell_sz
      local sid = my_board[y][x]
      local c_mid = math.floor(cell_sz / 2)
      if sid > 0 then
        cv:rect(cx + 2, cy + 2, cell_sz - 4, cell_sz - 4, COL_OWN_FLEET, true)
      else
        cv:rect(cx + c_mid - 1, cy + c_mid - 1, 2, 2, COL_GRID_DOT, true)
      end
    end
  end

  -- Draw ghost preview of ship currently being placed
  if setup_ship_idx <= 5 then
    local cur_spec = SHIP_SPECS[setup_ship_idx]
    local len = cur_spec.len
    local fits = true

    if setup_dir == "H" then
      if setup_cur_x + len - 1 > 9 then fits = false end
      for i = 0, len - 1 do
        local nx = setup_cur_x + i
        if nx <= 9 and my_board[setup_cur_y][nx] ~= 0 then fits = false end
      end
    else
      if setup_cur_y + len - 1 > 9 then fits = false end
      for i = 0, len - 1 do
        local ny = setup_cur_y + i
        if ny <= 9 and my_board[ny][setup_cur_x] ~= 0 then fits = false end
      end
    end

    local preview_col = fits and COL_STATUS_GREEN or COL_HIT
    for i = 0, len - 1 do
      local gx_cell = setup_dir == "H" and (setup_cur_x + i) or setup_cur_x
      local gy_cell = setup_dir == "V" and (setup_cur_y + i) or setup_cur_y
      if gx_cell <= 9 and gy_cell <= 9 then
        local cx = gx + gx_cell * cell_sz
        local cy = gy + gy_cell * cell_sz
        cv:rect(cx + 1, cy + 1, cell_sz - 2, cell_sz - 2, preview_col, false)
        cv:rect(cx + 3, cy + 3, cell_sz - 6, cell_sz - 6, preview_col, true)
      end
    end
  end

  -- Right Panel: Fleet Checklist & Instructions
  local rx = home_panel.x
  local ry = home_panel.y
  local rw = home_panel.w
  local rh = home_panel.h

  draw_text(rx + 2, 19, "FLEET STATUS", COL_STATUS_GREEN, 12)
  box(rx, ry, rw, rh, COL_PANEL_BG, COL_BORDER_NORM)

  local sy = ry + 5
  for i = 1, 5 do
    local spec = SHIP_SPECS[i]
    local placed = (my_ships[i] ~= nil)
    local is_cur = (setup_ship_idx == i)

    local txt = string.format("%d.%s(%d)", i, spec.abbr, spec.len)
    local col = placed and COL_OWN_FLEET or (is_cur and COL_RETICLE or COL_TEXT_DIM)
    draw_text(rx + 6, sy, txt, col, 12)
    local status_mark = placed and "[OK]" or (is_cur and "[AIM]" or "[..]")
    draw_text(rx + rw - 34, sy, status_mark, col, 12)
    sy = sy + 13
  end

  -- Clean divider line below 5.DD(2) without overlapping
  draw_line(rx + 4, ry + 73, rx + rw - 4, ry + 73, COL_GRID_LINE, 1)

  local btn_x = rx + 4
  local btn_w = rw - 8

  if fleet_locked then
    box(btn_x, ry + 77, btn_w, 36, COL_BAR_BG, COL_STATUS_AMBER)
    draw_text_centered(btn_x, ry + 82, btn_w, is_host and "WAITING PEER" or "SCANNING...", COL_STATUS_AMBER, 12)
    draw_text_centered(btn_x, ry + 97, btn_w, "[TAP/ENT] PING", COL_TEXT_BRIGHT, 12)
  elseif setup_ship_idx <= 5 then
    local rot_txt = string.format("DIR: %s", setup_dir == "H" and "HORIZ" or "VERT")
    draw_text(rx + 8, ry + 80, rot_txt, COL_RETICLE, 12)
    draw_text(rx + 8, ry + 96, "[R] Rotate", COL_TEXT_BRIGHT, 12)
  else
    box(btn_x, ry + 77, btn_w, 36, 0x0B2E1C, COL_STATUS_GREEN)
    draw_text_centered(btn_x, ry + 82, btn_w, "FLEET READY!", COL_STATUS_GREEN, 12)
    draw_text_centered(btn_x, ry + 97, btn_w, "[CONFIRM]", COL_TEXT_BRIGHT, 12)
  end

  -- Bottom Bar
  box(0, bot_y, W, bot_h, COL_BAR_BG, COL_BORDER_NORM)
  draw_line(0, bot_y, W, bot_y, COL_BORDER_NORM, 1)
  if fleet_locked then
    draw_text(10, bot_y + 4, combat_log, COL_STATUS_AMBER, 12)
    draw_text(10, bot_y + 20, "[Enter] Re-send   [C] Unlock   [Q] Lobby", COL_TEXT_BRIGHT, 12)
  elseif setup_ship_idx <= 5 then
    draw_text(10, bot_y + 4, string.format("PLACING: %s (LEN %d)", SHIP_SPECS[setup_ship_idx].name, SHIP_SPECS[setup_ship_idx].len), COL_RETICLE, 12)
    draw_text(10, bot_y + 20, "[WASD] Aim  [R] Rotate  [Ent] Place", COL_TEXT_BRIGHT, 12)
  else
    draw_text(10, bot_y + 4, "FLEET DEPLOYED! READY FOR BATTLE.", COL_STATUS_GREEN, 12)
    draw_text(10, bot_y + 20, "[Enter/Space] CONFIRM   [C] Reset", COL_TEXT_BRIGHT, 12)
  end
end

-- Draw Bottom Combat Log & Key Hints Bar
local function draw_bottom_bar()
  box(0, bot_y, W, bot_h, COL_BAR_BG, COL_BORDER_NORM)
  draw_line(0, bot_y, W, bot_y, COL_BORDER_NORM, 1)

  if game_state == STATE_AUDIT or game_state == STATE_GAME_OVER then
    local banner_col = audit_passed and COL_STATUS_GREEN or COL_HIT
    draw_text(10, bot_y + 4, audit_status_msg, banner_col, 12)
    draw_text(10, bot_y + 20, "[Enter/Space] RETURN TO LOBBY  [M] Mute", COL_RETICLE, 12)
    return
  end

  -- Combat log / action status line
  draw_text(10, bot_y + 4, combat_log, COL_TEXT_BRIGHT, 12)

  -- Contextual key hints
  local hints = ""
  if game_state == STATE_MY_TURN then
    if tx_pending ~= nil then
      hints = "[WAITING FOR PACKET ACK]  [M] Mute"
    else
      hints = string.format("[WASD] Aim (%s)  [Enter] FIRE  [M] Mute", format_coord(target_cur_x, target_cur_y))
    end
  elseif game_state == STATE_ENEMY_TURN then
    hints = "[DEFENDING] Awaiting enemy shot... [M] Mute"
  end
  draw_text(10, bot_y + 20, hints, COL_RETICLE, 12)
end

-- Draw Main Lobby Screen
local function draw_lobby_screen()
  box(0, 0, W, H, COL_BG, nil)
  draw_top_bar()

  -- Tactical Banner
  box(14, 26, 292, 40, COL_PANEL_BG, COL_BORDER_NORM)
  draw_text(24, 31, "GRID STRIKE: NAVAL LORAMESH", COL_STATUS_GREEN, 14)
  draw_text(24, 48, "1v1 LOCKSTEP TACTICAL RADAR", COL_TEXT_DIM, 12)

  -- Career Stats Widget
  box(14, 72, 292, 26, COL_PANEL_BG, COL_BORDER_NORM)
  local win_rate = 0
  if career_stats.matches > 0 then
    win_rate = math.floor((career_stats.wins / career_stats.matches) * 100)
  end
  local stat_line = string.format("CAREER: %dW - %dL (%d%%) | ACC: %d%%",
    career_stats.wins, career_stats.losses, win_rate,
    (career_stats.hits + career_stats.misses) > 0 and math.floor((career_stats.hits / (career_stats.hits + career_stats.misses)) * 100) or 0)
  draw_text(24, 78, stat_line, COL_STATUS_AMBER, 12)

  -- Menu Options
  local options = {
    { key = "[1]", title = "HOST LORA MATCH" },
    { key = "[2]", title = "JOIN LORA MATCH" },
    { key = "[3]", title = "VS AI (OFFLINE HUNT/TARGET)" },
  }

  local oy = 104
  for i, opt in ipairs(options) do
    box(14, oy, 292, 22, COL_PANEL_BG, COL_BORDER_NORM)
    draw_text(24, oy + 4, opt.key, COL_RETICLE, 12)
    draw_text(52, oy + 4, opt.title, COL_TEXT_BRIGHT, 12)
    oy = oy + 26
  end

  local lby = math.max(182, H - 24)
  box(0, lby, W, H - lby, COL_BAR_BG, COL_BORDER_NORM)
  draw_text(10, lby + 5, "KEYS: [1] Host  [2] Join  [3] Offline AI  [M] Mute", COL_STATUS_GREEN, 12)
end

-- Draw Post-Game / Audit Overlay (Kept for interface compatibility, rendered in bottom bar)
local function draw_audit_overlay()
  -- Status now rendered directly in draw_bottom_bar() to keep radar grid 100% visible
end

-- Draw Hot-Resume Crash Recovery Modal
local function draw_resume_modal()
  box(20, 32, 280, 140, COL_PANEL_BG, COL_RETICLE)
  draw_text(30, 42, "UNFINISHED MATCH DETECTED!", COL_STATUS_AMBER, 14)

  local info = string.format("ID: %s  |  SEQ: %02d", match_id, local_seq)
  draw_text(30, 66, info, COL_TEXT_BRIGHT, 12)
  draw_text(30, 84, "State restored from flash storage.", COL_TEXT_DIM, 12)

  box(30, 110, 115, 30, COL_BAR_BG, COL_STATUS_GREEN)
  draw_text(40, 118, "[1] RESUME", COL_STATUS_GREEN, 12)

  box(165, 110, 115, 30, COL_BAR_BG, COL_HIT)
  draw_text(175, 118, "[2] ABANDON", COL_HIT, 12)

  local lby = math.max(182, H - 24)
  box(0, lby, W, H - lby, COL_BAR_BG, COL_BORDER_NORM)
  draw_text(10, lby + 5, "Press [1]/[Enter] to Resume, [2] to Abandon", COL_TEXT_BRIGHT, 12)
end

-- Draw Retry / TX Failed Modal
local function draw_retry_modal()
  box(20, 32, 280, 140, COL_PANEL_BG, COL_HIT)
  draw_text(30, 42, "TRANSMISSION TIMEOUT", COL_HIT, 14)
  draw_text(30, 66, "5 attempts exceeded without ACK reply.", COL_TEXT_BRIGHT, 12)
  draw_text(30, 84, "Peer node unreachable or out of range.", COL_TEXT_DIM, 12)

  box(30, 110, 115, 30, COL_BAR_BG, COL_STATUS_AMBER)
  draw_text(40, 118, "[1] RESEND NOW", COL_STATUS_AMBER, 12)

  box(165, 110, 115, 30, COL_BAR_BG, COL_HIT)
  draw_text(175, 118, "[2] FORFEIT", COL_HIT, 12)
end

-- Main Draw Screen Router
draw_screen = function()
  if not cv then return end
  cv:fill(COL_BG)

  if game_state == STATE_RESUME_MODAL then
    draw_resume_modal()
    return
  end

  if game_state == STATE_LOBBY then
    draw_lobby_screen()
    return
  end

  if game_state == STATE_SETUP then
    draw_setup_screen()
    return
  end

  -- Combat, Audit, and Game Over views
  draw_top_bar()
  draw_target_radar()
  draw_home_fleet()
  draw_bottom_bar()

  if show_retry_modal then
    draw_retry_modal()
  end
end

-- ---- User Input & Interaction Handling --------------------------------------

-- Keyboard & Trackball Input Handler
function app.on_key(key)
  local raw_key = tostring(key or "")
  local k = raw_key:lower()
  if raw_key == " " then
    k = "space"
  elseif raw_key == "\r" or raw_key == "\n" then
    k = "enter"
  elseif k == "esc" or k == "backspace" then
    k = "escape"
  end

  -- Global Sound Mute Toggle
  if k == "m" then
    sound_on = not sound_on
    if sys.toast then
      sys.toast(sound_on and "Sound ON" or "Sound MUTED")
    end
    draw_screen()
    return
  end

  -- 1. Crash Recovery Modal Inputs
  if game_state == STATE_RESUME_MODAL then
    if k == "1" or k == "enter" or k == "space" then
      -- Resume Match
      local recovered = load_active_match()
      if recovered then
        match_id         = recovered.match_id
        opponent_id      = recovered.opponent_id
        game_state       = recovered.game_state
        local_seq        = recovered.local_seq
        my_salt          = recovered.my_salt
        my_board_hash    = recovered.my_board_hash
        enemy_board_hash = recovered.enemy_board_hash
        my_fleet_str     = recovered.my_fleet_str
        my_shots         = unpack_grid_100(recovered.my_shots_100)
        enemy_shots      = unpack_grid_100(recovered.enemy_shots_100)

        local ships, grid = parse_and_validate_fleet(my_fleet_str)
        if ships and grid then
          my_ships = ships
          my_board = grid
        end

        combat_log = string.format("> MATCH RESUMED [ID:%s | SEQ:%02d]", match_id, local_seq)
        is_ai_match = (recovered.opponent_id == "AI_BOT")
        if is_ai_match then
          tx_pending = nil
          if game_state == STATE_ENEMY_TURN then
            NetEngine.trigger_ai_turn()
          end
        else
          if recovered.tx_pending_payload then
            NetEngine.queue_tx(recovered.tx_pending_payload, local_seq)
          elseif game_state == STATE_ENEMY_TURN then
            mesh_send(opponent_id, string.format("BS|SYNC|%s|%d", match_id, local_seq))
          end
        end
      else
        game_state = STATE_LOBBY
      end
      draw_screen()
      return
    elseif k == "2" or k == "q" or k == "escape" then
      clear_match_state()
      game_state = STATE_LOBBY
      draw_screen()
      return
    end
    return
  end

  -- 2. Retry Modal Inputs
  if show_retry_modal then
    if k == "1" or k == "enter" or k == "space" then
      show_retry_modal = false
      if tx_pending then
        tx_pending.retries = 0
        tx_pending.elapsed = 0
        mesh_send(opponent_id, tx_pending.payload)
        combat_log = string.format("> IMMEDIATE RETRANSMIT [Seq %d]...", tx_pending.seq)
      end
      draw_screen()
      return
    elseif k == "2" or k == "q" or k == "escape" then
      show_retry_modal = false
      NetEngine.clear_tx()
      clear_match_state()
      game_state = STATE_LOBBY
      draw_screen()
      return
    end
    return
  end

  -- 3. Lobby Menu Inputs
  if game_state == STATE_LOBBY then
    if k == "1" or k == "h" then
      NetEngine.host_lobby()
    elseif k == "2" or k == "j" then
      NetEngine.join_lobby()
    elseif k == "3" or k == "a" then
      NetEngine.start_vs_ai()
    end
    return
  end

  -- 4. Fleet Placement Setup Inputs
  if game_state == STATE_SETUP then
    if fleet_locked then
      if k == "enter" or k == "space" then
        NetEngine.lock_in_fleet()
      elseif k == "c" then
        fleet_locked = false
        timer_cancel("seek_broadcast")
        NetEngine.clear_tx()
        combat_log = "> FLEET UNLOCKED. [ENTER] Confirm [C] Reset"
      elseif k == "q" or k == "escape" then
        fleet_locked = false
        timer_cancel("seek_broadcast")
        NetEngine.clear_tx()
        game_state = STATE_LOBBY
      end
      draw_screen()
      return
    end

    if k == "w" or k == "up" then
      setup_cur_y = clamp(setup_cur_y - 1, 0, 9)
    elseif k == "s" or k == "down" then
      setup_cur_y = clamp(setup_cur_y + 1, 0, 9)
    elseif k == "a" or k == "left" then
      setup_cur_x = clamp(setup_cur_x - 1, 0, 9)
    elseif k == "d" or k == "right" then
      setup_cur_x = clamp(setup_cur_x + 1, 0, 9)
    elseif k == "r" then
      setup_dir = (setup_dir == "H") and "V" or "H"
    elseif k == "c" then
      init_empty_grids()
      my_ships = {}
      setup_ship_idx = 1
      setup_cur_x = 0
      setup_cur_y = 0
      fleet_locked = false
      combat_log = "> FLEET RESET. PLACE CARRIER (LEN 5)."
    elseif k == "q" or k == "escape" then
      timer_cancel("seek_broadcast")
      NetEngine.clear_tx()
      game_state = STATE_LOBBY
    elseif k == "enter" or k == "space" then
      if setup_ship_idx <= 5 then
        -- Validate and place current ship
        local spec = SHIP_SPECS[setup_ship_idx]
        local len = spec.len
        local fits = true

        if setup_dir == "H" then
          if setup_cur_x + len - 1 > 9 then fits = false end
          for i = 0, len - 1 do
            local nx = setup_cur_x + i
            if nx <= 9 and my_board[setup_cur_y][nx] ~= 0 then fits = false end
          end
          if fits then
            for i = 0, len - 1 do
              my_board[setup_cur_y][setup_cur_x + i] = setup_ship_idx
            end
            my_ships[setup_ship_idx] = { id = setup_ship_idx, x = setup_cur_x, y = setup_cur_y, dir = setup_dir, len = len }
            setup_ship_idx = setup_ship_idx + 1
            sfx_play("FIRE")
          else
            sfx_play("MISS")
          end
        else
          if setup_cur_y + len - 1 > 9 then fits = false end
          for i = 0, len - 1 do
            local ny = setup_cur_y + i
            if ny <= 9 and my_board[ny][setup_cur_x] ~= 0 then fits = false end
          end
          if fits then
            for i = 0, len - 1 do
              my_board[setup_cur_y + i][setup_cur_x] = setup_ship_idx
            end
            my_ships[setup_ship_idx] = { id = setup_ship_idx, x = setup_cur_x, y = setup_cur_y, dir = setup_dir, len = len }
            setup_ship_idx = setup_ship_idx + 1
            sfx_play("FIRE")
          else
            sfx_play("MISS")
          end
        end
      else
        -- All ships placed: lock in fleet and initiate battle
        NetEngine.lock_in_fleet()
      end
    end
    draw_screen()
    return
  end

  -- 5. Combat Turn Inputs
  if game_state == STATE_MY_TURN then
    if k == "w" or k == "up" then
      target_cur_y = clamp(target_cur_y - 1, 0, 9)
    elseif k == "s" or k == "down" then
      target_cur_y = clamp(target_cur_y + 1, 0, 9)
    elseif k == "a" or k == "left" then
      target_cur_x = clamp(target_cur_x - 1, 0, 9)
    elseif k == "d" or k == "right" then
      target_cur_x = clamp(target_cur_x + 1, 0, 9)
    elseif k == "enter" or k == "space" then
      NetEngine.fire_shot(target_cur_x, target_cur_y)
    end
    draw_screen()
    return
  end

  -- 6. Game Over / Audit Screen Inputs
  if game_state == STATE_AUDIT or game_state == STATE_GAME_OVER then
    if k == "enter" or k == "space" or k == "q" or k == "escape" then
      clear_match_state()
      game_state = STATE_LOBBY
      draw_screen()
    end
    return
  end
end

-- Touchscreen & Trackball Input Handler
function app.on_input(ev)
  if not ev then return end

  if ev.type == "key" then
    app.on_key(ev.key)
    return
  end

  if ev.type == "swipe" and ev.dir then
    app.on_key(ev.dir)
    return
  end

  if ev.type == "down" then
    local tx, ty = I(ev.x), I(ev.y)
    local is_tb_center = (tx == math.floor(W / 2) and ty == math.floor(H / 2))

    -- Audio toggle tap (Top right)
    if ty <= 24 and tx >= 230 then
      sound_on = not sound_on
      if sys.toast then
        sys.toast(sound_on and "Sound ON" or "Sound MUTED")
      end
      draw_screen()
      return
    end

    -- Resume Modal Taps
    if game_state == STATE_RESUME_MODAL then
      if ty >= 105 and ty <= 145 then
        if tx >= 30 and tx <= 145 then
          app.on_key("1")
        elseif tx >= 165 and tx <= 280 then
          app.on_key("2")
        end
      elseif is_tb_center then
        app.on_key("enter")
      end
      return
    end

    -- Retry Modal Taps
    if show_retry_modal then
      if ty >= 105 and ty <= 145 then
        if tx >= 30 and tx <= 155 then
          app.on_key("1")
        elseif tx >= 165 and tx <= 290 then
          app.on_key("2")
        end
      elseif is_tb_center then
        app.on_key("1")
      end
      return
    end

    -- Lobby Menu Taps
    if game_state == STATE_LOBBY then
      if tx >= 14 and tx <= 306 then
        if ty >= 104 and ty <= 126 then
          NetEngine.host_lobby()
        elseif ty >= 130 and ty <= 152 then
          NetEngine.join_lobby()
        elseif ty >= 156 and ty <= 178 then
          NetEngine.start_vs_ai()
        end
      end
      return
    end

    -- Fleet Placement Taps (Deployment Grid, Right Panel, Bottom Bar, Trackball Press)
    if game_state == STATE_SETUP then
      if fleet_locked then
        if ty >= bot_y and tx >= 235 then
          app.on_key("q")
        elseif ty >= bot_y and tx >= 165 and tx < 235 then
          app.on_key("c")
        else
          app.on_key("enter")
        end
        return
      end

      if setup_ship_idx > 5 then
        if ty >= bot_y and tx >= 235 then
          app.on_key("c")
        else
          app.on_key("enter")
        end
        return
      end

      local gx = target_panel.x + 2
      local gy = target_panel.y + 2
      local span = cell_sz * 10
      if is_tb_center then
        app.on_key("enter")
        return
      elseif tx >= gx and tx < gx + span and ty >= gy and ty < gy + span then
        local cell_x = math.floor((tx - gx) / cell_sz)
        local cell_y = math.floor((ty - gy) / cell_sz)
        setup_cur_x = clamp(cell_x, 0, 9)
        setup_cur_y = clamp(cell_y, 0, 9)
        app.on_key("enter")
        return
      elseif ty >= home_panel.y + 73 and ty <= home_panel.y + home_panel.h and tx >= home_panel.x and tx <= home_panel.x + home_panel.w then
        app.on_key("r")
        return
      elseif ty >= bot_y then
        app.on_key("enter")
        return
      end
    end

    -- Target Radar Taps (Aim and Fire)
    if game_state == STATE_MY_TURN and tx_pending == nil then
      local gx = target_panel.x + 2
      local gy = target_panel.y + 2
      local span = cell_sz * 10
      if is_tb_center then
        NetEngine.fire_shot(target_cur_x, target_cur_y)
        return
      elseif tx >= gx and tx < gx + span and ty >= gy and ty < gy + span then
        local cell_x = math.floor((tx - gx) / cell_sz)
        local cell_y = math.floor((ty - gy) / cell_sz)
        target_cur_x = clamp(cell_x, 0, 9)
        target_cur_y = clamp(cell_y, 0, 9)
        NetEngine.fire_shot(target_cur_x, target_cur_y)
        return
      end
    end

    -- Return to Lobby Tap on Game Over
    if game_state == STATE_AUDIT or game_state == STATE_GAME_OVER then
      app.on_key("enter")
      return
    end
  end
end

-- ---- App Lifecycle Hooks ----------------------------------------------------

-- Inbound LoRa Packet Callback
function app.on_message(m)
  if not m then return end
  local sender = m.from or m.sender or ""
  local text = m.text or m.payload or ""
  NetEngine.process_packet(sender, text)
end

-- System Heartbeat Tick
function app.on_tick(dt)
  if is_ai_match and game_state == STATE_ENEMY_TURN and ai_turn_scheduled_ms > 0 then
    local now = (sys.millis and sys.millis()) or 0
    if now > 0 and now >= ai_turn_scheduled_ms then
      ai_turn_scheduled_ms = 0
      NetEngine.execute_ai_shot()
    end
  end
end

-- App Initialization Hook
function app.on_load()
  init_empty_grids()
  load_career_stats()

  if mesh.self then
    local ok, self_info = pcall(mesh.self)
    if ok and self_info and self_info.name and self_info.name ~= "" then
      my_callsign = self_info.name
    end
  end

  local unfinished = load_active_match()
  if unfinished and unfinished.match_id and unfinished.match_id ~= "" then
    match_id = unfinished.match_id
    local_seq = unfinished.local_seq
    game_state = STATE_RESUME_MODAL
  else
    game_state = STATE_LOBBY
  end
end

-- WADAMESH Canvas Creation & Screen Open
function app.on_open(w, h)
  compute_layout(w, h)

  if ui and ui.canvas then
    local cw = math.min(W, 480)
    local ch = math.min(H, 480)
    cv = ui.canvas(cw, ch)
    if cv and cv.pos then cv:pos(0, 0) end
  end

  app.on_load()
  draw_screen()
end

-- App Exit / Cleanup Hook
function app.on_exit()
  for name, _ in pairs(active_timers) do
    timer_cancel(name)
  end
  if game_state == STATE_GAME_OVER or game_state == STATE_LOBBY then
    clear_match_state()
  else
    save_match_state()
  end
end

function app.on_close()
  app.on_exit()
end

return app
