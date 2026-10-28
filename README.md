# Grid Strike: 1v1 LoRa Battleship for WADAMESH (Lua 5.4) — v1.0

A high-contrast, tactical naval radar **Battleship** game ("Grid Strike") designed for the **LilyGo T-Deck Plus** (ESP32-S3) using the on-device **WADAMESH Lua App SDK (`wada.*` API v1)**.

Grid Strike implements a full 1v1 multiplayer loop over LoRa mesh featuring **strict lockstep turn-based combat with explicit ACK handshakes**, a **salted commit-reveal anti-cheat audit**, **crash recovery persistence**, and **tactile screen-shake / audio feedback**. It also includes a smart offline **Hunt/Target AI** mode for solo play.

---

## Project Structure

```text
├── battleship.lua                    # Standalone Lua app ready for SD card sideloading
├── battleship.json                   # App manifest (v1.0)
├── deploy/
│   └── apps/
│       └── battleship/
│           └── 1.0/
│               ├── battleship.json   # WADAMESH Store manifest bundle
│               └── battleship.lua    # Production release script
├── test_battleship.lua               # Instruction budget, UI, & state machine test suite
├── test_multiplayer.lua              # Full end-to-end 1v1 RF mesh network simulation (Host vs Challenger)
├── test_anti_cheat.lua               # Comprehensive 6-point anti-cheat audit verifier test suite
└── README.md                         # Documentation & reference guide
```

---

## Supported Hardware

| Device | Display Resolution | Layout Mode | Cell Size | Radar Dimensions | Input Support |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **LilyGo T-Deck Plus** | `320 × 240` (Native) | Split Landscape | `14 × 14` px | Two `144 × 144` px panels | Physical Keyboard, Trackball, Touchscreen |

---

## Game Loop & Features

### 1. Matchmaking & Lobby
- **Host Match:** Generates a random 4-character hex match ID (e.g., `A3F1`) and broadcasts `BS|SEEK` over the mesh channel.
- **Join Match:** Discovers active host beacons, parses the match ID, and connects via direct message (DM).
- **VS AI (Offline Mode):** Instant play against an on-device bot running a **Hunt/Target** algorithm with checkerboard parity and orthogonal target locking.
- **Persistent Career Record:** Tracks lifetime wins, losses, matches played, and hit accuracy in `wada.store("career_stats")`.

### 2. Fleet Deployment (`STATE_SETUP`)
Deploy the standard 5 naval warships:
1. **Carrier** (Length 5, `CV`)
2. **Battleship** (Length 4, `BB`)
3. **Cruiser** (Length 3, `CA`)
4. **Submarine** (Length 3, `SS`)
5. **Destroyer** (Length 2, `DD`)

Controls: Use `WASD` / Arrow keys to position the ghost preview, `R` to rotate between Horizontal and Vertical, `Enter` / `Space` to lock placement, or press `A` to auto-deploy a valid fleet instantly.

### 3. Compact LoRa Wire Protocol & Lockstep Handshake
Airtime is scarce; packets are formatted as terse pipe-delimited strings prefixed with `BS|` and `<match_id>`:

```text
Phase A: Match Handshake (Seq 0)
  Host Broadcast:     BS|SEEK|<match_id>|<callsign>
  Challenger Join:    BS|JOIN|<match_id>|0|<seed>|<board_hash>
  Host Ready + ACK:   BS|RDY|<match_id>|0|<seed>|<board_hash>
  Challenger Start:   BS|ACK|<match_id>|0

Phase B: Lockstep Combat Loop (Monotonic Seq = 1, 2, 3...)
  Attacker Shot:      BS|FIRE|<match_id>|<seq>|<x>,<y>
  Defender Result:    BS|RES|<match_id>|<seq>|<x>,<y>|<status>|<ship_id>
  Attacker Confirm:   BS|ACK|<match_id>|<seq>

Phase C: Post-Game Commit-Reveal Audit (Seq = final_seq + 1)
  Both Players:       BS|REV|<match_id>|<seq>|<salt>|<fleet_str>
  Confirmations:      BS|ACK|<match_id>|<seq>
  Crash Recovery:     BS|SYNC|<match_id>|<local_seq>
```

- **Implicit ACK & Piggybacking:** Receiving a matching `BS|RES` serves as an implicit ACK for `BS|FIRE`. The next turn's `BS|FIRE` also confirms receipt of the previous turn's result.
- **Dropped ACK Fix (Idempotency):** If the Defender is on `seq = N + 1` and receives duplicate `BS|FIRE|<N>` due to RF packet loss, the Defender does not re-apply damage or advance the turn. It immediately re-transmits its cached `last_sent_res.payload` to unblock the attacker.
- **Exponential Backoff Retry Engine:** Monitored by `"lora_tx_retry"` (intervals: 6s, 8s, 10s, 12s, 14s). Displays `[TX SEQ:N | RETRY X/5]` in the top bar. After 5 failed attempts, provides a modal dialog for manual resend or forfeit.

### 4. Post-Game Commit-Reveal Anti-Cheat Audit
Prevents modified clients from lying about hit results or moving ships mid-game:
1. **Canonical Fleet String:** Sorted 1 to 5: `<id>:<x>,<y>,<dir>;` (e.g. `1:0,0,H;2:2,4,V;3:5,1,H;4:7,3,V;5:8,8,H` — 39 bytes).
2. **Commitment:** During `Seq 0`, both players exchange an 8-char hex DJB2 hash of `<fleet_str>|<salt>` where `<salt>` is a 6-character random alphanumeric string.
3. **Three-Point Verification:** When a player wins (`status == "W"`), both reveal their salt and fleet string:
   - *Commitment Check:* `djb2_hex(fleet_str .. "|" .. salt) == enemy_board_hash`.
   - *Geometry Check:* Validates all 5 ships fit `0..9` bounds with zero overlapping cells.
   - *Combat Honesty Check:* Reconstructs the opponent's grid and cross-references all shots fired. Any shot reported as `M` that contains a ship, or reported as `H`/`S` on empty water, triggers immediate disqualification.
4. **Ghost Fleet Overlay:** Verified matches reveal unhit enemy ships on the Target Radar in dim purple (`#7755AA`).

### 5. Crash Recovery & Persistence
- Live state is packed into `wada.store("active_match")` (~304 bytes):
  `<match_id>|<opponent_id>|<state_enum>|<local_seq>|<my_salt>|<my_board_hash>|<enemy_board_hash>|<my_fleet_str>|<my_shots_100>|<enemy_shots_100>|<tx_pending>|<last_res>`
- Upon device reboot or app launch, `app.on_load()` detects unfinished matches and presents a hot-resume modal (`[RESUME MATCH]` or `[ABANDON]`).

### 6. Tactile FX: Screen-Shake & Audio Tones
- **Screen Shake (`fx_shake`):** Struck panels shake across 6 non-blocking 35ms ticks (`{-4, +4, -3, +3, -1, 0}` px offset) while flashing crimson (`#FF3333`) on Hit or amber (`#FFAA00`) on Sunk before snapping cleanly back to origin.
- **Audio Feedback (`sfx_play`):**
  - `"TURN_ALERT"`: Dual sonar ping (1200Hz, then 1600Hz)
  - `"FIRE"`: Torpedo launch blip (900Hz)
  - `"MISS"`: Low muted splash thud (220Hz)
  - `"HIT"`: Double-pulse klaxon (600Hz, then 450Hz)
  - `"SUNK"`: Descending 3-tone cadence (800Hz -> 500Hz -> 250Hz)
  - `"CHEAT_WARN"`: Alternating siren (1000Hz / 500Hz)

---

## Controls Summary

| Input | Context | Action |
| :--- | :--- | :--- |
| **Touchscreen** | Combat | Tap any cell on Target Radar to aim reticle and fire |
| **Touchscreen** | Setup | Tap Deployment Grid to position and place current warship |
| **Touchscreen** | Global | Tap top-right corner (`[VOL]` / `[MUTE]`) to toggle audio |
| **`WASD` / Arrows** | Combat / Setup | Move aiming reticle / position ship preview |
| **`Enter` / `Space`** | Combat | Fire torpedo at reticle coordinates |
| **`Enter` / `Space`** | Setup | Confirm placement of current ship |
| **`R`** | Setup | Rotate warship orientation (Horizontal $\leftrightarrow$ Vertical) |
| **`A`** | Setup | Auto-deploy all 5 ships in random valid configuration |
| **`C`** | Setup | Clear placed ships and restart deployment |
| **`M`** | Global | Toggle sound effects on/off |
| **`1` / `2` / `3`** | Lobby | Host Match (`1`), Join Match (`2`), Play vs Offline AI (`3`) |
| **`Q` / `Esc`** | Modal / Game Over | Abandon match / return to Lobby |

---

## Installing on Your Device

### Option 1: microSD Card (Recommended)
1. Copy `battleship.lua` and `battleship.json` to your microSD card:
   ```text
   /meshcomod/apps/battleship.lua
   /meshcomod/apps/battleship.json
   ```
2. Insert the card into your T-Deck Plus and open the **Apps** drawer. **Grid Strike** will appear with the game icon.

### Option 2: USB Serial Sideload
Using the WADAMESH repository's sideload script:
```bash
python scripts/sideload_app.py --port COM3 --reboot deploy/apps/battleship/1.0
```

---

## Running the Automated Test Suite

Run all verification tests using standard Lua 5.4:

```bash
# 1. Unit tests, instruction budget benchmark, and idempotency
lua test_battleship.lua

# 2. Complete 1v1 multi-hop network simulation (Host vs Challenger)
lua test_multiplayer.lua

# 3. Comprehensive 6-point anti-cheat audit test suite
lua test_anti_cheat.lua
```

