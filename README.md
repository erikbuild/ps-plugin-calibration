# Calibration Plugin for PrusaSlicer 3

Printer calibration tools for the Lua plugin system introduced in PrusaSlicer 3.0.

![PA Pattern printed on a Prusa CORE One](images/pa-pattern_demo.jpg)

## Plugins

The `build.erik.calibration` bundle contains:

- **PA Pattern** — the Ellis pressure-advance calibration pattern:
  V-chevrons printed at stepped PA values with printed value labels.
  Pick the chevron with the crispest corner; its label is your PA value —
  enter it under *Filament → Extrusion & Calibration → Pressure advance*.
  Supports Marlin, Marlin 2,
  Prusa Buddy, Klipper, RepRapFirmware, and Repetier dialects, detected
  automatically from the printer profile with a manual override.
- **Flow Ratio** — OrcaSlicer's YOLO flow calibration: a plate of
  Orca-standard coupons, each printed at a stepped flow multiplier and
  labeled with the resulting absolute value. Pick the coupon with the
  smoothest top surface; its label is your new extrusion multiplier —
  enter it under *Filament → Filament → Extrusion multiplier*. Pure
  `G1` output, so it works on every firmware.
- **Retraction** — OrcaSlicer's retraction tower: two slender posts whose
  connecting travel retracts 0.1 mm more per 1 mm of height (0 to 2 mm by
  default). Find the height where strings between the posts stop, measure
  the clean millimeters above the 0.4 mm base, and divide by 10 — enter
  the result under *Printer → Extruder → Retraction → Length*. Pure `G1`
  output; the retraction values are baked into the G-code, so it works on
  every firmware.
- **Max Volumetric Speed** — OrcaSlicer's max-flow tower: a single-wall comb
  whose wall speed rises every layer, so the commanded flow climbs 0.5 mm³/s
  per millimeter of height (5 to 20 mm³/s by default). Find the height where
  the wall turns rough or gappy, or the extruder starts clicking; your
  maximum flow is 5 + 0.5 × that height. Enter it, with a margin, as the
  filament's *Max volumetric speed*. Unlike the Flow Tower that ships with
  PrusaSlicer 3, it removes the cooling slowdown that caps that tower's top
  bands.
- **Voron Test Cube** — adds Voron Design's official 30 mm test cube
  (Voron_Design_Cube_v7) to the plate, centered on the bed. It changes no
  settings; give it whichever tool you like in the object list.

## Install

Copy (or symlink) the `build.erik.calibration` directory into PrusaSlicer's
user plugin folder, then **Menu ▸ Plugins ▸ Rescan Plugins**. The tools
appear under **Plugins ▸ Ultimate Calibration**:

| OS | Plugin folder |
|---|---|
| macOS | `~/Library/Application Support/PrusaSlicer3-dev/lua/` |
| Windows | `%APPDATA%\PrusaSlicer3-dev\lua\` |
| Linux | `~/.var/app/com.prusa3d.PrusaSlicer/config/PrusaSlicer3-dev/lua/` |

(The `-dev` suffix applies to alpha/beta builds.)

A plugin's dialog remembers the values you last ran it with until you run
another plugin or restart PrusaSlicer. To get the defaults back, use
**Menu ▸ Plugins ▸ Rescan Plugins**.

**Requires PrusaSlicer 3.0.0-alpha11 or newer; Max Volumetric Speed needs
alpha12** (alpha11 ignores the badge text's depth).

## PA Pattern notes

OrcaSlicer's guide: [Pressure Advance calibration](https://github.com/OrcaSlicer/OrcaSlicer/wiki/pressure_advance_calib).

- Defaults suit a direct-drive 0.4 mm nozzle (PA 0–0.08, step 0.005).
  For Bowden extruders try 0–1.0 with step 0.05. Both ranges come from
  OrcaSlicer's PA calibration dialog defaults; the Bowden range matches
  Klipper's pressure-advance tuning guidance but hasn't been tested with
  this plugin (developed on direct-drive printers).
- PA Start/End/Step are text fields on purpose — the dialog's numeric
  float fields round to whole numbers in current alphas.
- Bed Width/Depth default to the CORE One (250×220); set them for your
  printer, they anchor the pattern's placement.
- The printer profile must use relative extruder distances (Prusa profiles
  do). Failures are shown as an embossed text object on the plate.
- The extra number after the PA scale is the volumetric flow rate
  (mm³/s) the chevrons printed at — the same label OrcaSlicer's pattern
  prints (print speed × bead cross-section × flow multiplier; both
  slicers model the bead identically).

## Flow Ratio notes

![Flow Ratio plate sliced in PrusaSlicer 3 on a Prusa CORE One L](images/flow-ratio-demo.png)

OrcaSlicer's guide: [Flow Ratio calibration](https://github.com/OrcaSlicer/OrcaSlicer/wiki/flow_ratio_calib).

- **Coarse** prints 11 coupons at 0, ±0.01 … ±0.05 around your current
  extrusion multiplier; **fine** prints 15 at ±0.005 … ±0.035 — OrcaSlicer's
  YOLO delta sets. Labels are absolute values, so the winning coupon reads
  as the exact number to type into the filament profile.
- Judge the top surface: pinholes and gaps mean under-extrusion, ridges
  and a rough nap mean over. With the default **archimedean** top pattern
  the corner chords collide with the center spiral and raise a tactile lip
  (Orca's trick) — run a fingernail across each coupon and pick the
  smoothest. **monotonic** gives a plain 45° top instead.
- Coupons are Orca's standard size (30×20 mm plus label tab); a coarse
  plate is ~13 g and ~35 minutes at 0.4 mm.
- Bed Width/Depth default to the CORE One (250×220); set them for your
  printer.
- The printer profile must use relative extruder distances (Prusa profiles
  do). Failures are shown as an embossed text object on the plate.

## Retraction notes

![Retraction test demo on a Prusa CORE One L](images/retraction-demo.png)

OrcaSlicer's guide: [Retraction test](https://github.com/OrcaSlicer/OrcaSlicer/wiki/retraction_calib).

- The tower prints ~21 mm tall by default: 21 bands, one retraction step
  per millimeter, starting just above the 0.4 mm base. A different
  start/end/step changes the height to match.
- Retraction fires at the posts' interior closest points (like OrcaSlicer),
  so strings form across the gap you read; the outer flanks stay clean.
- The small cylinder at bed center is the plugin's required handle object —
  the slicer needs a real object on every layer to carry the custom G-code.
  Run on an empty plate so it lands at bed center.
- The printer profile must use relative extruder distances (Prusa profiles
  do). Failures are shown as an embossed text object on the plate.

## Max Volumetric Speed notes

![Max Volumetric Speed tower in PrusaSlicer 3's Actual volumetric flow preview on a Prusa CORE One INDX](images/max-flow-demo.png)

OrcaSlicer's guide: [Max Volumetric Speed calibration](https://github.com/OrcaSlicer/OrcaSlicer/wiki/volumetric_speed_calib).

- The tower follows OrcaSlicer's recipe: layers 0.8 × the nozzle (0.32 mm on
  a 0.4), a 1.75 × nozzle wide wall, and one speed per layer. Flow at height
  `z` is `start + z × step`, and the tower stops at `end`: the default
  5–20 run is 94 layers, 30 mm tall.
- The badge in front of the comb prints the filament type, the nozzle
  temperature, the nozzle (`HF` for high-flow), the flow range, and the step,
  with your note (up to about 45 characters) centered on a second line, so
  the print explains itself later. PrusaSlicer doesn't let plugins read the
  filament preset's name yet, so put it in the note.
- **Tool/Extruder** is numbered from 1, as in PrusaSlicer's tool list. The
  tower prints with it, and its filament is the one whose limits are zeroed.
- **It changes the project's presets and cannot change them back.** On the
  chosen extruder's filament it sets *Max volumetric speed*, the cooling
  slowdown (*Slow down if layer print time is below*) and Z shrinkage
  compensation to 0; on the print it sets the layer and first-layer height
  and turns off the volumetric limits and slopes. Discard these changes
  after printing — don't save them into your filament preset.
- **It clears the bed's custom G-code** — pauses and color changes as well as
  the leftover blobs other calibrations leave behind.
- The tower must be the only object on the bed: other objects would pick up
  the zeroed limits, and on multi-tool printers another tool's first layer
  shifts the speed bands. Run it on an empty plate.
- The comb is 180 mm wide; the bed must be at least 200 mm wide. Set Bed
  Width for your printer (it defaults to the CORE One's 250).
- The tower is at most 300 layers: (End − Start) / Step can be up to 96 mm
  on a 0.4 nozzle, so End can go up to 53 with the default Start and Step.
  Longer ranges are refused with `BAD RANGE`. Check *Actual volumetric flow*
  in the preview before printing: the printer's own speed and acceleration
  limits still apply on the turns at high flow.
- Failures are shown as an embossed text object on the plate.

## Voron Test Cube notes

- The cube is Voron Design's `Voron_Design_Cube_v7.stl`, shipped unmodified
  from the [Voron-2 repository](https://github.com/VoronDesign/Voron-2/blob/3b4c0e4a4e88086b04474fec28a54ab82917fc8a/STLs/Test_Prints/Voron_Design_Cube_v7.stl).
  It is licensed under the GNU GPL v3.0, not this bundle's license: see
  `Voron_Design_Cube_v7-NOTICE.txt` and `Voron_Design_Cube_v7-LICENSE.txt`
  next to it in the bundle.
- Running it twice stacks two cubes at bed center; move one by hand.

## License

**OCL v1.1 + SWAtt v1** — Prusa's [Open Community License](https://github.com/OpenCommunityLicence/OpenCommunityLicence)
with the Software Attribution add-on. Free to use, modify, and hack;
derivatives must stay under OCL and credit the creator ("built on …") in
their UI and source. See [LICENSE](LICENSE).

The one exception is the Voron Design cube STL used by Voron Test Cube, a
separate work licensed under GPL-3.0 and shipped unmodified with its own
license text and notice.
