# Structural Collapse

A Project Zomboid Build 42 mod. When nothing is left holding an upper floor up, that floor and everything above it come down one level, keeping their shape.

## What it does

- **Supports:** walls (door and window frames, garage and truck doors included), pillars and stairs on the level below. An upper floor with its walls and pillars is one structure; one support left anywhere under it holds the whole thing.
- **Collapse:** the structure drops one level, with every level above it. The landing floor stays and the one below breaks (with its materials). Overlapping furniture moves to the nearest free tile without crossing walls, or breaks and drops its contents and materials.
- **Under it:** players are hit on the head (helmets reduce it), zombies are killed (health -3.7: all on normal and fragile toughness, about 99% on random, about two thirds on tough; the rest are knocked down), animals are hurt, vehicles lose part condition. Corpses and items fall with the floor; a car on an upper floor falls when the floor goes.
- **Roofs:** a roof layer with no wall, floor, ceiling or roof under it drops one level.
- **Free-standing and hanging objects:** street light heads, sign tops, billboards, tanks and lattice towers fall when what they stand on is removed (pieces of one object fall together). Ceiling lights and other hanging objects fall when what they hang on goes.
- **Wires:** sledging a wooden utility pole breaks the wires hanging on it (some `Base.ElectricWire` drops). A high-voltage pylon stands while any of its 12 legs is left; when the last one goes the tower falls and its lines break.
- **Dismantled floor tiles:** what stood on the tile falls, and a part of the floor cut off from every support comes down.
- Big collapses run over several ticks (2 ms per tick), starting next to the removed support. A collapse cut off by saving finishes after loading.

Checks happen only when an object is removed (no timed scans).

## Install

- Steam Workshop: https://steamcommunity.com/sharedfiles/filedetails/?id=3837209498
- Manual: copy `Contents/mods/StructuralCollapse` into `%USERPROFILE%\Zomboid\mods\`.

## Compatibility

- Lua only (`media/lua/server`), no vanilla files replaced. Runs where the world is simulated: single player, or the server in multiplayer.
- Multiplayer: not tested.
- Safe to add to an existing save: vanilla buildings only move when you remove their supports. Removing the mod keeps what already came down where it is (emptied upper squares count as indoor rooms again after loading).
- Checked on build 42.22.2. Vanilla code it relies on: `vanilla-deps.txt`.

## Testing

In-game tests use [PZTestHarness](../PZTestHarness): `bash ../PZTestHarness/pzt live` from this folder runs every scene (`tests/StructuralCollapse_Test.lua`) in one client. The save round trip uses two runs:

```
PZT_STEPS="wait 120;lua StructuralCollapseTest.persistStart();wait 40" bash ../PZTestHarness/pzt run
PZT_STEPS="wait 120;wait 300;lua StructuralCollapseTest.persistCheck()" bash ../PZTestHarness/pzt run KEEP_SAVE=1
```

`tools/mapcheck` holds the offline map check (rules applied to the whole vanilla map).

## Support

If this mod helps you, you can support it via [Ko-fi](https://ko-fi.com/talkinghands2285) or [PayPal](https://www.paypal.com/paypalme/TalkingHands619/3). It's optional; every feature stays free.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/talkinghands2285)
