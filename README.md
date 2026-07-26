# Ultra-Trail Dashboard

Connect IQ Data Field for Garmin devices, built for trail and ultra runners. Pace, heart rate, smoothed grade, and Grade Adjusted Pace (GAP), all in one full-screen view.

**[Get it on the Connect IQ Store](https://apps.garmin.com/it-IT/apps/76cbcc4a-623e-40da-87c7-762187c3247c)** · **[Product page](https://skapacraft.com/tools/apps/ultra-trail-dashboard/)**

## What it shows

- **Pace**: current pace, from GPS speed
- **Heart rate**: live, from the wrist-based or chest-strap sensor
- **Smoothed grade**: a moving average over a configurable window (3-30s), instead of Garmin's native instant grade, which is often too jumpy on technical terrain. Turns orange above 12%, red above 20%.
- **GAP (Grade Adjusted Pace)**: your flat-equivalent pace, computed with the Minetti et al. energy-cost model. Written into the activity's `.FIT` file as a custom field, so it's graphable on Garmin Connect/Strava after the run.

## Compatible devices

Fenix 6/6S/6X, Fenix 7 (all variants), Fenix 8, Epix 2 (+ Pro), Enduro/Enduro 3, MARQ Adventurer/Expedition/Athlete, Forerunner 935/945/955/965/970, and Forerunner 170 (no barometric altimeter, grade falls back to GPS elevation).

## Project layout

```
manifest.xml                  Connect IQ app manifest (devices, permissions, GUID)
monkey.jungle                 Build configuration
source/                       Monkey C source (App entry point + main View logic)
resources/                    Strings (default/English), drawables, properties, settings
resources-ita/                Italian string overrides
```

## Building

Requires the [Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/) (9.2.0+) and a developer key.

```bash
monkeyc -o UltraTrailDashboard.prg -f monkey.jungle -y developer_key -d <device_id>
```

To build the Connect IQ Store submission package:

```bash
monkeyc -e -o UltraTrailDashboard.iq -f monkey.jungle -y developer_key -r
```

## Privacy

No data is collected, stored, or transmitted anywhere. All calculations run entirely on-device. Full [privacy policy](https://skapacraft.com/tools/apps/ultra-trail-dashboard/privacy/).

## Author

Built by [SkapaCraft](https://skapacraft.com) and [LivQTech](https://livq.it).
