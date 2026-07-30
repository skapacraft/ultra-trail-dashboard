# Ultra-Trail Dashboard

Connect IQ Data Field for Garmin devices, built for trail and ultra runners.
Four configurable quadrants on one full-screen view, backed by a physiological
model that keeps track of what the effort is costing you.

**[Get it on the Connect IQ Store](https://apps.garmin.com/it-IT/apps/76cbcc4a-623e-40da-87c7-762187c3247c)** · **[Product page](https://skapacraft.com/tools/apps/ultra-trail-dashboard/)** · **[Changelog](CHANGELOG.md)**

## What it shows

Each of the four quadrants can be set from Garmin Connect Mobile to any of:

| Field | What it is |
|---|---|
| **Pace** | Current pace, from GPS speed |
| **Heart rate** | Live, from the wrist-based or chest-strap sensor |
| **Grade** | Moving average over a configurable window (3-30s), instead of Garmin's instant grade, which is too jumpy on technical terrain. Orange above 12%, red above 20%. |
| **GAP** | Grade Adjusted Pace: your flat-equivalent pace, from the Minetti et al. (2002) energy cost model |
| **Sustainable pace** | The pace you can hold *right now*. Unlike every comparable product, this one decays as the effort accumulates. |
| **Anaerobic reserve** | How much is left above threshold, as a percentage |
| **Carbohydrate left** | Glycogen remaining, as a percentage, from a real energy balance |
| **Descending capacity** | How much your quads have left before braking becomes the limit |
| **Time to limit** | Time before the *first* of those systems gives out, labelled with which one |

Defaults are pace, heart rate, grade and GAP, which is the 1.0 layout.

## The model

Most Connect IQ fields show a number. This one keeps a state and projects it
forward. One file per concern:

```
MinettiCost.mc        cost of a metre at a given grade, the single source
                      of truth for the whole app
EnduranceEngine.mc    accumulated work, sustainable speed, anaerobic reserve
FuelModel.mc          carbohydrate balance: oxidation, gastric transit,
                      absorption ceiling
EccentricModel.mc     muscle damage from descending, in weighted vertical
                      metres
SpeedCalibration.mc   estimates critical speed and D' from the athlete's own
                      personal bests, no configuration required
```

The three physiological models are deliberately independent. None of them
knows the others exist; each integrates its own state and declares how long
until *it* fails. Adding a fourth (thermal load) touches none of the three.

### The binding constraint

The "time to limit" field shows the minimum across the three, and renames
itself to the system imposing it: `ANAER`, `CARBS` or `QUADS`.

That choice is the point of the whole design. The common currency between
systems is **time**, not a score. An index that multiplies reserve, glycogen
and muscle damage together produces a number that cannot be checked against
anything and does not say what to do. A time to failure can be compared with
what actually happened at the finish, and the name of the system maps to one
specific action: ease off, eat, or brake less. Those are three different
actions, and a single index cannot tell them apart.

Warning thresholds follow from the same reasoning: they are set to the time
needed to *act*. Three minutes for an anaerobic limit, which you fix by
slowing down. Thirty minutes for carbohydrates, which need eating plus twenty
minutes of absorption, and for legs, which do not recover at all.

### Three decisions worth knowing about

**The threshold is not constant.** Xert, Stryd and Garmin's own Real-Time
Stamina all treat critical power or critical speed as fixed for the whole
activity. That is a fair approximation up to two or three hours and a bad one
beyond, which is exactly the range this app targets. Here the sustainable
speed decays with accumulated work, at a rate the user can tune (default 8%
per 100 kJ/kg, roughly 2.5 hours of steady running).

**The reserve uses the differential form** of the balance model (Clarke and
Skiba, 2013) rather than the original integral form. It is mathematically
equivalent, costs O(1) per sample and needs no history in RAM. On a device
with 32KB for data fields and a 20-hour race, nothing else is viable.

**The displayed GAP stays pure Minetti,** with no attenuation, even when the
number looks aggressive on a steep descent. The engine separately caps the
uphill cost ratio at 3.0 (about 25% grade), because past that everybody hikes
and the running model overestimates badly. The two paths never touch.

**Descending is not free.** A metre of descent run fast costs the legs more
than a metre walked, so descent accumulates as *weighted* vertical metres.
Without that weighting the field would just be a descent counter, which the
watch already provides. This is also the only model needing no calibration:
it works from the first second of the first run.

Calibration needs a hard 3-minute and a hard 12-minute effort to separate
critical speed from D'. Until it has them, the fields that depend on it
(sustainable pace, reserve, carbohydrates) show `--` rather than a guess. An
optional threshold pace setting can seed it, and is ignored once real data
exists.

Two assumptions are stated rather than hidden. The carbohydrate model assumes
you follow the intake plan you set, because a data field receives no button
events and cannot know when you actually eat. And body mass is a setting, not
a read of the Garmin profile, so the app still asks for no permission beyond
writing to the FIT file.

## FIT fields

Six custom fields are written into the activity file, so everything is
graphable on Garmin Connect and Strava afterwards:

| Field | Message | Unit |
|---|---|---|
| GAP Pace | record | min/km or min/mi |
| Anaerobic Reserve | record | % |
| Sustainable Pace | record | min/km or min/mi |
| Accumulated Work | record | kJ/kg |
| Carbohydrate Remaining | record | g |
| Eccentric Load | record | m (weighted) |
| Critical Speed | session | m/s |
| D Prime | session | m |

The record fields carry the model *state*, not the displayed values: a past
activity can be replayed against corrected parameters.

## Compatible devices

Fenix 6/6S/6X, Fenix 7 (all variants), Fenix 8, Epix 2 (+ Pro),
Enduro/Enduro 3, MARQ Adventurer/Expedition/Athlete, Forerunner
935/945/955/965/970, and Forerunner 170 (no barometric altimeter, grade falls
back to GPS elevation).

35 devices in total. The tightest (Fenix 6 base, Enduro 1, FR935, FR945,
MARQ) allow 32KB for a data field; the current build uses about 17.8KB of
static code and data on those.

## Project layout

```
manifest.xml                  Connect IQ app manifest (devices, permissions, GUID)
monkey.jungle                 Build configuration
test.jungle                   Extra build config, unit tests only
source/                       Monkey C source (app entry, view, engine)
source-test/                  Unit tests, never part of a release build
resources/                    Strings (default/English), drawables, properties, settings
resources-ita/                Italian string overrides
```

## Building

Requires the [Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/)
(9.2.0+) and a developer key.

```bash
monkeyc -o UltraTrailDashboard.prg -f monkey.jungle -y developer_key -d fenix7 -O2
```

Store submission package:

```bash
monkeyc -e -o UltraTrailDashboard.iq -f monkey.jungle -y developer_key -r
```

## Tests

30 unit tests cover the cost model, the endurance engine, the carbohydrate
balance, the eccentric model and the calibration. They check values worked
out by hand, not values read back off the code: a sign error in the
durability decay or a factor of 1000 in the energy balance does not crash
anything, it just quietly tells the athlete a lie. They live in
`source-test/`, which is pulled in only by `test.jungle`, so a release build
never sees them.

Start the simulator, then:

```bash
monkeyc -f "monkey.jungle;test.jungle" -o bin/test.prg -y developer_key -d fenix7 --unit-test && monkeydo bin/test.prg fenix7 -t
```

## Privacy

No data is collected, stored, or transmitted anywhere. All calculations run
entirely on-device, including the calibration, whose personal bests never
leave the watch. Full [privacy policy](https://skapacraft.com/tools/apps/ultra-trail-dashboard/privacy/).

## Author

Built by [SkapaCraft](https://skapacraft.com) and [LivQTech](https://livq.it).
