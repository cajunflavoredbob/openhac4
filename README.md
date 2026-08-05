# openhac4

Open source Control4 driver suite for Home Assistant. Home Assistant entities
appear in Control4 as native devices, with HA-side state changes pushed to C4 in
real time over the Home Assistant websocket API. Most drivers are controllable
from Control4 interfaces and programming; a few (sensor, media player, select,
humidifier) are programming and status devices rather than navigator devices.
No cloud, no license server, LAN only.

**Status: 1.0.** Gateway plus drivers for switch, binary sensor, light, sensor,
lock, vacuum, cover, garage, fan, climate, alarm, humidifier, media player,
media source, select, and event. Real-time two-way sync; imports Home Assistant
areas as Control4 rooms and their devices.

## Requirements

- Control4 X4 (primary target; OS 3.4.x may work but is not a gate)
- Composer Pro
- Any hardware running Home Assistant, reachable from the controller
- Python 3.9 or newer, to run the build script

## Install

1. Download the `.c4z` files from the latest release, or build from source
   with `python3 build.py` (output lands in `dist/`).

2. In Composer Pro: Driver > Add or Update Driver or Agent, and add **every**
   `.c4z` file from `dist/`, not just the gateway. This only loads them into
   Composer's driver database; you do not add them to the project by hand.

3. Add `Home Assistant Gateway (openhac4)` to a room in your project, then follow
   its Documentation tab to point it at your Home Assistant instance and
   authenticate.

4. With the gateway connected, use its **Import Rooms** action to create Control4
   rooms from your Home Assistant areas, then **Import Devices** to create the
   child drivers for your entities. Import Devices can only create a driver that
   is already in Composer's driver database, which is why step 2 loads all of
   them and not just the gateway.

## Layout

- `src/<driver>/` - one directory per driver (driver.xml, driver.lua, www/)
- `common/` - Lua shared between openhac4 drivers, packed into each c4z
- `build.py` - packs each `src/<driver>` into `dist/openhac4_<driver>.c4z`

## License

openhac4 is MIT. See [LICENSE](LICENSE).

The Control4 support code (the websocket, timer, utility, and handler libraries
under `common/openhac4/c4*.lua`) is an independent implementation written against
the public DriverWorks protocol references.

Contributions are subject to the provenance rules in
[CONTRIBUTING.md](CONTRIBUTING.md).
