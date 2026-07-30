# Changelog

All notable changes to Ultra-Trail Dashboard are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [semantic versioning](https://semver.org/).

## [1.2.0] - 2026-07-30

Two more systems, and the field that ties them together.

Up to 1.1 the app modelled one way to blow up: running out of anaerobic
reserve. In a mountain ultra that is rarely the one that gets you. This
release adds the two that actually do, and stops treating them as separate
readouts.

### Added

- **Carbohydrate balance.** A real accounting of glycogen, not a 30-minute
  timer. Oxidation is derived from the energy cost of the terrain and from
  intensity relative to your sustainable pace, because the share of energy
  coming from sugar rises steeply as you approach threshold. Intake is
  modelled with a 20 minute gastric transit and an absorption ceiling, so
  what you eat now is not available now. This is why "eat when you are
  hungry" fails in a race: by the time you are hungry, you are already
  twenty minutes late.
- **Eccentric damage from descending.** Nothing else on Connect IQ, and no
  native Garmin metric, models the system that actually ends most mountain
  ultras: the quadriceps. Descent is accumulated as *weighted* vertical
  metres, because running a descent costs the legs more than walking the
  same descent. The unit is metres of equivalent vertical drop, which is
  what trail runners already think in. Needs no calibration and works from
  the first second.
- **Binding constraint display.** The "time to limit" field now reports the
  minimum across all three systems and *renames itself* to the one that is
  binding: `ANAER`, `CARBS` or `QUADS`. The common currency between systems
  is time, not a score. A composite index cannot be checked against anything
  and does not tell you what to do; a time to failure can be compared with
  what actually happened, and the name of the system maps to one specific
  action: ease off, eat, or brake less.
- Alert thresholds are now per system, set to the time needed to *act*: three
  minutes of warning for an anaerobic limit, which you fix by slowing down,
  and thirty minutes for carbohydrate or leg limits, which you cannot.
- Two new quadrant sources: carbohydrate left (%) and descending capacity (%).
- Two new FIT fields: carbohydrate remaining (g) and eccentric load (m).
- Three new settings: body mass, carbohydrate plan (g/h), descent capacity.
- 11 more unit tests, 30 in total.

### Notes

- Body mass is a setting rather than a read of the Garmin user profile. That
  read needs the `UserProfile` permission, and adding a permission to a
  published app changes what the store shows to an audience we tell that
  nothing leaves the watch. One numeric field is the cheaper trade.
- The carbohydrate model assumes you follow the intake plan you set. A data
  field receives no button events, so it cannot know when you actually eat.
  The assumption is stated in the setting rather than buried in the code.
- Carbohydrate tracking needs critical speed, so it shows `--` until
  calibration has data. Descent damage does not, and works immediately.

## [1.1.0] - 2026-07-30

The endurance engine. Version 1.0 showed you numbers; this one keeps a model
of your physiological state and tells you what it implies.

### Added

- **Configurable quadrants.** Each of the four positions can now show any of
  seven sources, picked from Garmin Connect Mobile. Defaults are unchanged
  from 1.0.0, so an existing install looks exactly as it did.
- **Sustainable pace.** The pace you can hold *right now*, which drops as the
  effort accumulates. Every comparable product (Xert, Stryd, Garmin's own
  Real-Time Stamina) treats the threshold as a constant for the whole
  activity. That holds up to two or three hours and stops holding beyond it,
  which is the entire domain this app is built for.
- **Anaerobic reserve.** How much is left above threshold, as a percentage,
  using the differential form of the balance model (Clarke and Skiba, 2013).
  Colour-coded, with hysteresis so the colour does not flicker on a
  threshold.
- **Time to limit.** Seconds before the reserve runs out at the current
  effort. Shows `--` below threshold, where no anaerobic failure is pending,
  rather than inventing a number.
- **Automatic calibration.** Critical speed and D' are estimated from the
  athlete's own personal bests over 3 and 12 minute windows, kept across
  activities. No mandatory configuration: an optional threshold pace can seed
  the model for the first outings, and is ignored once real data exists.
- **Durability setting.** How much sustainable pace is lost per 100 kJ/kg of
  accumulated work. Defaults to 8%; set 0 for the classic constant-threshold
  behaviour.
- **Five new FIT fields**: anaerobic reserve, sustainable pace and
  accumulated work per record, plus critical speed and D' per session. These
  record the *model state*, not the displayed values, so a past activity can
  be replayed against a corrected model.
- **Unit tests** for the whole engine (19 tests, in `source-test/`), built
  separately so they cost nothing on the watch.

### Changed

- The Minetti cost model moved out of the view into `MinettiCost.mc` and is
  now the single source of truth for grade cost across the app.
- The displayed GAP is unchanged: still pure Minetti, with no attenuation.
  The engine internally caps the uphill cost ratio at 3.0 (about 25% grade),
  because beyond that everybody hikes and the running model overestimates.
  Without the cap every steep wall would read as a massive over-threshold
  effort. The two paths are independent, and the number on screen is exactly
  what it was.
- The grade smoothing buffer is no longer cleared when unrelated settings
  change.

### Fixed

- Standing still with the timer running now counts as recovery. Previously
  the engine skipped its update at zero speed, which froze the reserve
  during the minutes when an athlete recovers most.

## [1.0.0] - 2026-07-19

First public release on the Connect IQ Store.

### Added

- Four-quadrant full-screen data field: pace, heart rate, smoothed grade, GAP.
- Grade smoothed over a configurable 3 to 30 second window, instead of
  Garmin's instant grade, which is too jumpy on technical terrain.
- Grade Adjusted Pace from the Minetti et al. (2002) energy cost model,
  written to the activity FIT file as a custom field.
- Dynamic font sizing so values never overlap on any screen size.
- Italian and English localisation, metric and imperial units.
- Support for 35 devices, from Forerunner 935 to Fenix 8.
