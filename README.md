# cc-elevator

A self-discovering ComputerCraft elevator control system.

One **master computer** orchestrates the cart; many **floor computers** (one or more per level) handle redstone and displays. Floor numbers, redstone wiring sides, and per-level anchor assignments are all discovered automatically by a one-time calibration sweep — no per-floor config typing.

## What you need

- A working elevator built in Minecraft (cart + a way for redstone to call it to each floor).
- One CC: Tweaked computer per floor at minimum, plus one master computer.
- Per level: one computer wired so that the elevator's "arrival" redstone signal reaches one of its sides. The same wire (or a parallel one) carries the "call to this floor" pulse outward. This is the **anchor** computer for that level.
- A wireless modem (or a wired modem network) reaching every floor + master.
- GPS coverage at every floor (a standard 4-host GPS constellation overhead).
- Optional: monitors next to any floor computer to show floor info / a call button.
- HTTP enabled in CC: Tweaked (default), and `raw.githubusercontent.com` not blocklisted (default).

## Install

### 1. The master

On the master computer, run:

```
wget run https://raw.githubusercontent.com/viscoci/cc-elevator/main/install.lua
```

- Pick role: **master** (press M)
- Enter an elevator name (e.g. `storage-silo`) — this is just an identifier, used so multiple elevators in one world don't cross-talk.

The computer reboots and shows the **setup GUI**. Leave it open — it will live-update as floor computers register.

**Non-interactive shortcut**:

```
wget run https://raw.githubusercontent.com/viscoci/cc-elevator/main/install.lua -M storage-silo
```

### 2. Each floor computer

Run the same command on every CC that's part of the elevator (anchors and pure-display computers alike):

```
wget run https://raw.githubusercontent.com/viscoci/cc-elevator/main/install.lua
```

- Pick role: **floor** (press F)
- `Run sync? (y/n)` — say yes if this computer reads/writes redstone (anchors, or any computer that should fire calls).
- `Run display? (y/n)` — say yes if there's a monitor attached.
- `Elevator name (blank = auto-discover)` — press Enter for auto-discover (single-elevator world); type the name to lock to a specific elevator.

The computer reboots, GPS-locates itself, and registers with the master. You'll see the count tick up in the master's setup GUI.

**Non-interactive shortcuts**:

```
wget run .../install.lua -F                  # auto-discover elevator
wget run .../install.lua -F   storage-silo   # lock to "storage-silo"
wget run .../install.lua -FS  storage-silo   # sync only, locked
wget run .../install.lua -FD  storage-silo   # display only, locked
wget run .../install.lua -FSD storage-silo   # sync + display, locked (explicit)
```

Letter order after `-F` doesn't matter — `-FDS` works too. Elevator name is optional; omit it for auto-discovery (which is what you want unless you have multiple elevators in radio range).

### 3. Calibrate

Once every floor computer has registered (check the count in the setup GUI):

1. Park the cart anywhere.
2. On the master, type `calibrate` and press Enter.

The master walks the cart from the lowest Y to the highest. At each level it tells the floor computers there to fire redstone on all sides; whichever computer detects the elevator's arrival signal coming back becomes the anchor for that level, and the side that received the pulse is locked in. Topology is saved to `elevator_topology.json`. The setup GUI never reappears unless you delete that file.

That's it — the system is now running.

## Day-to-day commands

### On the master

| Command | Effect |
| --- | --- |
| `floors` | List currently registered floor stations |
| `topology` | Print the calibrated level list |
| `calibrate` | Re-run the full sweep |
| `recalibrate <Y>` | Recalibrate just one level (e.g. after fixing wiring) |
| `rename <N> <name...>` | Rename floor N (e.g. `rename 1 Lobby`) |
| `describe <N> <text...>` | Set a description for floor N |
| `setanchor <N> <id> <side>` | Manually set the anchor for floor N (use when calibration picked the wrong computer) |
| `floorspacing <N>` | Bucket Y values within `N-1` blocks of each other onto the same level (default 1 = strict). Use this if your display computers sit a few blocks above/below the floor's anchor. |
| `forget <Y>` | Ignore all floor computers at this exact locY (one-off stray) |
| `unforget <Y>` | Stop ignoring a Y |
| `reboot` | Reboot all floor stations (each pulls latest code from GitHub on the way back up) |
| `reboot all` | Reboot all floors *and* the master |
| `reboot self` | Reboot just the master |
| `reboot <id>` | Reboot one specific computer by ID |
| `setup` | Re-open the setup GUI |
| `help` | Command list |

### On any floor computer

| Command | Effect |
| --- | --- |
| `rename <name...>` | Ask the master to rename this floor |
| `describe <text...>` | Ask the master to set this floor's description |
| `status` | Show this computer's local state (anchor flag, side, master ID, etc.) |
| `redstone` | Print the current redstone input on every side (handy when debugging which computer is wired to the arrival sensor) |
| `claim <side>` | Claim *this* computer as the anchor for *this* floor with the given side. Master accepts and re-broadcasts topology. |

Floor renames propagate instantly — every display in the elevator updates within ~2s.

## Auto-update

Every boot, each computer pulls the latest scripts from this repo before running. Edit on GitHub, reboot the CC, done. If GitHub is unreachable at boot, the on-disk version runs and a warning is logged so a CC won't brick on a network blip.

To disable for a specific computer, set `"autoUpdate": false` in its `elevator_config.json`.

## Wiring assumptions

- Each level has **one** anchor computer wired so the elevator's arrival redstone signal feeds it as input. The side is auto-discovered during calibration.
- The same anchor's matching output side, when pulsed, calls the cart to that floor. (Calibration learns the input side; the system pulses the same side outward to call.)
- Multiple computers per level are fine — only the anchor handles redstone; the rest are passive (display only).
- Pure-display computers don't need any redstone wiring at all. They just need GPS + a modem + a monitor.

## Layout

```
install.lua                     One-shot installer
update.lua                      Pulls latest from GitHub on boot
manifest.lua                    File list per role
master/
  main.lua                      Master controller (REPL, broadcasts, position tracking)
  calibrate.lua                 Sweep algorithm
  setup_gui.lua                 First-run wizard
  startup.lua                   Boot entry: update + run main
floor/
  sync.lua                      Registration, heartbeats, redstone, calibration response
  display.lua                   Monitor rendering + touch-to-call
  startup.lua                   Boot entry: update + run sync/display in parallel
shared/
  protocol.lua                  Rednet message types and (de)serialization
  rednet_setup.lua              Modem auto-detect
  log.lua                       Prefixed logger
```

## Persisted state on each computer

- Master: `elevator_config.json` (role, repo, elevator name), `elevator_topology.json` (calibrated levels with anchor IDs and sides).
- Floor: `elevator_config.json`, `floor_state.json` (locY, anchor flag, anchor side).

Delete `elevator_topology.json` on the master to force a fresh setup GUI + recalibration.

## Troubleshooting

**Calibration skips a level (`Timeout: no arrival at Y=...`)**
That level's arrival redstone isn't reaching a computer (or the wired computer hadn't booted yet). Check wiring, then run `recalibrate <Y>` on the master.

**Two anchors detected on the same level**
The master keeps the first one to report and logs the runners-up as `also responded: computer N side=X`. If the wrong one was picked:
- From the master: `setanchor <floorNumber> <correctComputerId> <correctSide>`
- Or from the correct floor computer's terminal: `claim <side>`

Either propagates via topology broadcast within ~2s.

**Calibration says "WARNING: N computers responded"**
Multiple computers at the same Y are detecting redstone input when the cart arrives. This usually means their faces are on the same redstone bus. Use `claim` / `setanchor` to lock the right one.

**Trying to figure out which floor computer is actually wired to the arrival sensor**
Stand by the elevator, send the cart to that floor manually, and on each candidate floor computer's terminal type `redstone`. The one whose `back: true` (or whichever side) lights up when the cart arrives is the anchor.

**Calibration tries to go to a floor that doesn't exist**
A floor computer is registered at a slightly different Y than its companions on the same physical level (e.g., placed one block higher). Run `floors` on the master — Y values with only one computer are usually the culprits. Three fixes from least to most invasive:
- `floorspacing <N>` on the master where N is bigger than your typical "off by" gap (e.g., `floorspacing 4` if displays might be up to 3 blocks above the anchor). Computers within `N-1` blocks of each other become the same level. Run `calibrate` again afterward.
- Move the misplaced computer in-world so its Y matches the rest of that level, then `reboot` it.
- `forget <Y>` on the master to ignore that exact Y permanently.

**Display shows `---`**
The display hasn't received an `elevator_status` broadcast yet — usually because the master isn't running or the modem can't reach. Resolves within 2s once the master comes online.

**Floor computer never registers**
Check that GPS works (`gps locate` on the CC), that a modem is attached (`peripheral list` should show one), and that the master is broadcasting (`floors` on the master).

**HTTP fetch fails on install**
Confirm `http_enable = true` in `computercraft-server.toml`, and that `*.github.com` / `raw.githubusercontent.com` aren't blocklisted.

**Cart goes to the wrong floor on call**
Almost certainly a stale topology — the cart's wiring changed since the last calibration. Run `calibrate` again from the master.

## Protocol summary

All messages use rednet protocol `elevator-floor-protocol` and JSON-serialized payloads. See [shared/protocol.lua](shared/protocol.lua) for the full type list.

| Direction | Type | Purpose |
| --- | --- | --- |
| floor → master | `floor_register` | Hello, I'm at this Y |
| master → floor | `floor_registered` | Ack with floor number |
| floor → master | `floor_heartbeat` (every 10s) | Keepalive |
| master → all floors @ Y | `calibrate_call` | Fire redstone all sides |
| floor → master | `elevator_arrived` | I sensed the cart on side X |
| floor → master | `elevator_departed` | Cart left my floor |
| display → master | `elevator_call` | Touch-to-call |
| master → all | `elevator_call_request` | Anchor at Y, pulse your side |
| master → all (every 2s) | `elevator_status` | Broadcast: state, currentFloor, destination, floors[] |
| floor → master | `floor_rename` | Rename request |

## License

Do whatever you want with this — credit is nice but not required.
