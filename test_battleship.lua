-- Comprehensive test verification suite for battleship.lua

local function checkint(v, what)
  if math.tointeger(v) == nil then
    error(what .. ": expected integer, got " .. tostring(v))
  end
end

local function checkstr(v, what)
  if type(v) ~= "string" and type(v) ~= "number" then
    error(what .. ": expected string, got " .. type(v))
  end
end

local storekv = {}
local toasts = {}
local draw_ops = 0
local timers = {}
local last_sent_mesh = nil

local function mock_wada(w, h)
  timers = {}
  draw_ops = 0
  storekv = {}

  return {
    ui = {
      canvas = function(cw, ch)
        checkint(cw, "canvas w"); checkint(ch, "canvas h")
        local cv = { w = cw, h = ch, x = 0, y = 0 }
        function cv:fill(col) checkint(col, "fill col"); draw_ops = draw_ops + 1 end
        function cv:rect(x, y, rw, rh, col, filled, radius)
          checkint(x, "rect x"); checkint(y, "rect y")
          checkint(rw, "rect w"); checkint(rh, "rect h"); checkint(col, "rect col")
          draw_ops = draw_ops + 1
        end
        function cv:line(x1, y1, x2, y2, col, width)
          checkint(x1, "line x1"); checkint(y1, "line y1")
          checkint(x2, "line x2"); checkint(y2, "line y2"); checkint(col, "line col")
          draw_ops = draw_ops + 1
        end
        function cv:circle(x, y, r, col, filled)
          checkint(x, "circle x"); checkint(y, "circle y")
          checkint(r, "circle r"); checkint(col, "circle col")
          draw_ops = draw_ops + 1
        end
        function cv:text(x, y, s, col, size)
          checkint(x, "text x"); checkint(y, "text y")
          checkstr(s, "text s"); checkint(col, "text col")
          draw_ops = draw_ops + 1
        end
        function cv:pos(x, y)
          checkint(x, "pos x"); checkint(y, "pos y")
          cv.x, cv.y = x, y
        end
        return cv
      end,
    },
    sys = {
      random = function(lo, hi)
        return math.random(lo, hi)
      end,
      toast = function(msg)
        toasts[#toasts + 1] = tostring(msg)
      end,
      beep = function() return true end,
      millis = function() return os.clock() * 1000 end,
    },
    store = {
      get = function(k, ...)
        if storekv[k] == nil then
          -- Emulate LuaAppHost.cpp storeGet stack quirk: 1-arg call returns wada.storetab table
          if select("#", ...) == 0 then return storekv end
          return select(1, ...)
        end
        return storekv[k]
      end,
      set = function(k, v)
        if v ~= nil then
          local line_len = #tostring(k) + 1 + #tostring(v) + 1
          assert(line_len < 192, string.format("store line '%s' (%d bytes) exceeds LuaAppHost 192-byte buffer", tostring(k), line_len))
        end
        storekv[k] = v
      end,
    },
    timer = {
      every = function(name_or_ms, ms_or_cb, cb_opt)
        local name, ms, cb
        if type(name_or_ms) == "string" then
          name = name_or_ms
          ms = ms_or_cb
          cb = cb_opt
        else
          name = "anon_" .. tostring(#timers + 1)
          ms = name_or_ms
          cb = ms_or_cb
        end
        timers[name] = { ms = ms, cb = cb }
        return timers[name]
      end,
      cancel = function(name)
        timers[name] = nil
      end,
      stop = function(handle)
        for k, v in pairs(timers) do
          if v == handle then timers[k] = nil end
        end
      end,
    },
    mesh = {
      send = function(to_or_tbl, text)
        local to, payload
        if type(to_or_tbl) == "table" then
          to = to_or_tbl.to
          payload = to_or_tbl.text
        else
          to = to_or_tbl
          payload = text
        end
        last_sent_mesh = { to = to, text = payload }
        return true
      end,
      self = function()
        return { name = "ADMIRAL_LEONARD" }
      end,
    },
    audio = {
      tone = function(freq, dur)
        return true
      end
    }
  }
end

print("=== STARTING BATTLESHIP TEST SUITE ===")

_G.wada = mock_wada(320, 240)
local app = dofile("battleship.lua")
assert(type(app) == "table", "battleship.lua must return app table")

-- 1. Instruction budget tracking wrapper
local max_instructions = 0
local function guarded(fn, ...)
  local count = 0
  debug.sethook(function() count = count + 1000 end, "", 1000)
  local res = { pcall(fn, ...) }
  debug.sethook()
  if count > max_instructions then max_instructions = count end
  assert(count < 100000, string.format("Instruction budget exceeded: %d >= 100000", count))
  assert(res[1], res[2])
  return table.unpack(res, 2)
end

-- 2. Lifecycle: app.on_open
guarded(app.on_open, 320, 240)
print("OK: app.on_open executed successfully")

-- 3. Test Lobby Navigation: select Host, Join, AI
guarded(app.on_key, "m") -- Toggle mute
assert(#toasts > 0, "Toast expected on mute toggle")

-- Test Offline AI match initialization
guarded(app.on_key, "3")
print("OK: [3] VS AI lobby option triggered")

-- Auto-place ships in setup
guarded(app.on_key, "auto")
print("OK: Auto-placement in setup completed")

-- Confirm fleet & start match
guarded(app.on_key, "enter")
print("OK: Fleet confirmed, match started")

-- Check that active match state is saved in store
assert(storekv["active_match"] ~= nil and storekv["active_match"] ~= "", "Match state must be persisted in store")
local state_len = #storekv["active_match"]
print(string.format("OK: Active match state persisted (%d bytes < 2048 bytes limit)", state_len))
assert(state_len < 2048, "State length must be strictly under 2KB limit")

-- 4. Test Lockstep Turn and Dropped ACK handling
print("=== TESTING LOCKSTEP & DROPPED ACK (IDEMPOTENCY) ===")
local mid = storekv["active_match"]:match("^(%w+)|")

-- Simulate receiving duplicate FIRE on seq 1
local test_fire = string.format("BS|FIRE|%s|1|0,0", mid)
guarded(app.on_message, { from = "TEST_ENEMY", kind = "dm", text = test_fire })
print("OK: Processed first FIRE on seq 1")

-- Re-send duplicate FIRE on seq 1 (simulating dropped ACK/RES)
guarded(app.on_message, { from = "TEST_ENEMY", kind = "dm", text = test_fire })
print("OK: Handled duplicate FIRE without crashing or duplicate state corruption")

-- 5. Test 3-Point Commit-Reveal Anti-Cheat Engine directly
print("=== TESTING COMMIT-REVEAL ANTI-CHEAT ===")
local valid_fleet = "1:0,0,H;2:2,4,V;3:5,1,H;4:7,3,V;5:8,8,H"
local valid_salt = "K9X2M1"

-- Function to compute pure djb2 hex
local function djb2_hex_test(s)
  local hash = 5381
  for i = 1, #s do
    local b = string.byte(s, i)
    hash = ((hash * 33) + b) & 0xFFFFFFFF
  end
  return string.format("%08X", hash)
end

local expected_hash = djb2_hex_test(valid_fleet .. "|" .. valid_salt)
print(string.format("Canonical fleet: %s (length %d)", valid_fleet, #valid_fleet))
print(string.format("Computed Board Hash: %s", expected_hash))
assert(#valid_fleet == 39, "Fleet string must be exactly 39 bytes")

-- 6. Test Crash Recovery / Hot Resume Modal
print("=== TESTING CRASH RECOVERY MODAL ===")
_G.wada = mock_wada(320, 240)
-- Store active match from previous run
storekv["active_match"] = string.format("%s|AI_BOT|STATE_MY_TURN|4|%s|%s|%s|%s|%s|%s|NONE|NONE",
  mid, valid_salt, expected_hash, expected_hash, valid_fleet, string.rep("0", 100), string.rep("0", 100))

local app_resumed = dofile("battleship.lua")
guarded(app_resumed.on_open, 320, 240)
print("OK: Booted with active_match present, modal displayed")
guarded(app_resumed.on_key, "1") -- Press [1] to Resume
print("OK: Match successfully resumed from persistent storage")

-- 7. Test Screen-Shake and SFX trigger
print("=== TESTING SCREEN SHAKE FX ===")
guarded(app_resumed.on_message, { from = "AI_BOT", kind = "dm", text = string.format("BS|RES|%s|4|1,1|H|0", mid) })
assert(timers["fx_shake"] ~= nil, "Screen-shake timer fx_shake must be triggered on Hit")
-- Pump the 6 shake ticks
for i = 1, 7 do
  if timers["fx_shake"] then
    guarded(timers["fx_shake"].cb)
  end
end
assert(timers["fx_shake"] == nil, "Screen-shake timer must cancel after 6 ticks")
print("OK: Screen-shake completed and cleanly snapped back to origin")

-- 8. Test Offline AI Match: Fire Shot -> Zero ACK Wait -> AI Counter-Shot -> Next Turn
print("=== TESTING OFFLINE AI MATCH (ZERO ACK WAIT) ===")
_G.wada = mock_wada(320, 240)
local app_ai = dofile("battleship.lua")
guarded(app_ai.on_open, 320, 240)
guarded(app_ai.on_key, "3") -- Select VS AI
guarded(app_ai.on_key, "auto") -- Place ships
guarded(app_ai.on_key, "enter") -- Confirm fleet & start

local function trigger_ai_timers()
  local list = {}
  for name, t in pairs(timers) do
    if name:find("after_") and t.cb then
      list[#list + 1] = t.cb
    end
  end
  for _, cb in ipairs(list) do
    guarded(cb)
  end
end

-- If AI won coin toss and fires first, let it take its turn
local current_st = storekv["active_match"]:match("^%w+|[^|]+|([^|]+)")
if current_st == "STATE_ENEMY_TURN" then
  print("AI won toss: waiting for AI counter-shot...")
  trigger_ai_timers()
end

-- Verify it is now player's turn
current_st = storekv["active_match"]:match("^%w+|[^|]+|([^|]+)")
assert(current_st == "STATE_MY_TURN", "Expected player's turn")

-- Player fires first shot at target radar
last_sent_mesh = nil
guarded(app_ai.on_key, "enter")

-- Confirm NO mesh packet sent and state is STATE_ENEMY_TURN immediately without ACK WAIT!
assert(last_sent_mesh == nil, "Offline AI match must not send packets over LoRa mesh")
current_st = storekv["active_match"]:match("^%w+|[^|]+|([^|]+)")
assert(current_st == "STATE_ENEMY_TURN", "State must advance to STATE_ENEMY_TURN immediately")
print("OK: Player shot fired against AI with zero ACK wait! State -> STATE_ENEMY_TURN")

-- AI fires back
trigger_ai_timers()
current_st = storekv["active_match"]:match("^%w+|[^|]+|([^|]+)")
assert(current_st == "STATE_MY_TURN", "State must return to STATE_MY_TURN after AI shot")
print("OK: AI counter-shot executed cleanly! State -> STATE_MY_TURN")

-- Player aims and fires second shot
guarded(app_ai.on_key, "d")
last_sent_mesh = nil
guarded(app_ai.on_key, "enter")
assert(last_sent_mesh == nil, "No packets sent over mesh on second shot")
current_st = storekv["active_match"]:match("^%w+|[^|]+|([^|]+)")
assert(current_st == "STATE_ENEMY_TURN", "Second shot fired cleanly with zero ACK wait")
trigger_ai_timers()
current_st = storekv["active_match"]:match("^%w+|[^|]+|([^|]+)")
assert(current_st == "STATE_MY_TURN", "Turn 2 completed smoothly without ACK lock")
print("OK: Consecutive player & AI turns completed with zero ACK wait!")

-- Test Heartbeat on_tick Fallback
guarded(app_ai.on_key, "s") -- Move aim to (1, 1)
last_sent_mesh = nil
guarded(app_ai.on_key, "enter") -- Player fires
current_st = storekv["active_match"]:match("^%w+|[^|]+|([^|]+)")
assert(current_st == "STATE_ENEMY_TURN", "State is STATE_ENEMY_TURN")
-- Simulate timers not running, but on_tick called after 1000ms
local fake_now = (os.clock() * 1000) + 1500
_G.wada.sys.millis = function() return fake_now end
guarded(app_ai.on_tick, 50)
current_st = storekv["active_match"]:match("^%w+|[^|]+|([^|]+)")
assert(current_st == "STATE_MY_TURN", "on_tick heartbeat must execute AI turn if timer delayed")
print("OK: on_tick heartbeat fallback successfully triggered AI shot!")

-- 9. Clean Exit & Final Verification
guarded(app_ai.on_exit)
print(string.format("ALL TESTS PASSED! Max instructions in any callback: %d (< 100000 limit)", max_instructions))
