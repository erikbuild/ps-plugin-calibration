# Calibration Plugin for PrusaSlicer 3

Printer calibration tools for the Lua plugin system introduced in PrusaSlicer 3.0.

![PA Pattern printed on a Prusa CORE One](pa-pattern_demo.jpg)

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
- **Max Volumetric Flow** — OrcaSlicer's max-flow tower: a single-wall comb
  whose wall speed rises every layer, so the commanded flow climbs 0.5 mm³/s
  per millimeter of height (5 to 21 mm³/s by default). Find the height where
  the wall turns rough or gappy, or the extruder starts clicking; your
  maximum flow is 5 + 0.5 × that height. Enter it, with a margin, as the
  filament's *Max volumetric speed*. Unlike the Flow Tower that ships with
  PrusaSlicer 3, it removes the cooling slowdown that caps that tower's top
  bands.
- **Firmware Probe** — diagnostic that reports what the plugin API can read
  from your printer profile and which G-code dialect it resolves to. Run
  PrusaSlicer from a terminal to see its output; useful when reporting
  issues.

## Install

Copy (or symlink) the `build.erik.calibration` directory into PrusaSlicer's
user plugin folder, then **Menu ▸ Plugins ▸ Rescan Plugins**:

| OS | Plugin folder |
|---|---|
| macOS | `~/Library/Application Support/PrusaSlicer3-dev/lua/` |
| Windows | `%APPDATA%\PrusaSlicer3-dev\lua\` |
| Linux | `~/.var/app/com.prusa3d.PrusaSlicer/config/PrusaSlicer3-dev/lua/` |

(The `-dev` suffix applies to alpha/beta builds.)

A plugin's dialog remembers the values you last ran it with until you run
another plugin or restart PrusaSlicer. To get the defaults back, use
**Menu ▸ Plugins ▸ Rescan Plugins**.

**Requires PrusaSlicer 3.0.0-alpha11 or newer.**

## PA Pattern notes

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

![Flow Ratio plate sliced in PrusaSlicer 3 on a Prusa CORE One L](flow-ratio-demo.png)

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

![Retraction test demo on a Prusa CORE One L](retraction-demo.png)

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

## Max Volumetric Flow notes

- The tower follows OrcaSlicer's recipe: layers 0.8 × the nozzle (0.32 mm on
  a 0.4), a 1.75 × nozzle wide wall, and one speed per layer. Flow at height
  `z` is `start + z × step`; the top layer tests `end + 1`, so the default
  5–20 run is 100 layers, 32 mm tall, and tops out at 21 mm³/s.
- The badge in front of the comb prints the nozzle temperature, the nozzle
  (`HF` for high-flow), the flow range, and the step, with your note (up to
  about 45 characters) centered on a second line, so the print explains
  itself later.
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
- The comb is 180 mm wide; the bed must be at least 200 mm wide (Bed Width
  defaults to 250).
- Ranges above 300 layers are refused. Check *Actual volumetric flow* in the
  preview before printing: the printer's own speed and acceleration limits
  still apply on the turns at high flow.
- Failures are shown as an embossed text object on the plate.

## License

**OCL v1.1 + SWAtt v1** — Prusa's [Open Community License](https://github.com/OpenCommunityLicence/OpenCommunityLicence)
with the Software Attribution add-on. Free to use, modify, and hack;
derivatives must stay under OCL and credit the creator ("built on …") in
their UI and source. See [LICENSE](LICENSE).
