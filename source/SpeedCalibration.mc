// Copyright (C) 2026 SkapaCraft
//
// This file is part of Ultra-Trail Dashboard.
//
// Ultra-Trail Dashboard is free software: you can redistribute it and/or
// modify it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Ultra-Trail Dashboard is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
// Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with Ultra-Trail Dashboard. If not, see <https://www.gnu.org/licenses/>.

// SpeedCalibration.mc
//
// Estimates critical speed (CS) and anaerobic capacity (D') from the athlete's
// own running, with nothing for the user to enter.
//
// WHY THIS CLASS EXISTS
// Every model of this kind (Xert, Stryd, WKO) needs two athlete parameters to
// work at all. Asking the user for them is the fastest way to lose the user:
// those who do not know them stop at installation, and those who do often type
// in a value from two seasons ago. A data field that works on first use and
// improves by itself is worth far more than one that demands correct
// configuration.
//
// HOW IT WORKS
// The hyperbolic performance model says the distance coverable in a time t is:
//
//     d(t) = CS * t + D'
//
// That is a straight line, so two points fix its slope (CS) and intercept (D').
// What is taken, then, is the athlete's BEST result over two durations (3 and
// 12 minutes), measured in flat-equivalent distance.
//
// HOW IT FITS IN MEMORY
// The obvious approach needs the maximum rolling average over 3 and 12 minute
// windows, so in principle 720 one-second samples held in RAM. Instead the
// CUMULATIVE distance is sampled every 5 seconds into a 145-cell ring buffer:
// the distance covered in a window is the difference between two cells, so each
// update costs two subtractions and two comparisons, and the RAM used is about
// one twentieth.

import Toybox.Lang;
import Toybox.Application.Storage;

class SpeedCalibration {

    // ------------------------------------------------------------------
    // BUFFER GEOMETRY
    // ------------------------------------------------------------------

    // How often a cumulative-distance sample is stored. 5 seconds is the
    // compromise: dense enough to locate the edges of a 3-minute window to
    // within 3%, sparse enough to fit in a little over 1KB of RAM.
    const SAMPLE_PERIOD_SEC as Float = 5.0;

    // The two durations the maximum is measured over, in samples.
    // 36 samples = 180 s = 3 minutes; 144 samples = 720 s = 12 minutes.
    const SHORT_SLOTS as Number = 36;
    const LONG_SLOTS as Number = 144;

    // The same two durations in seconds, used in the regression.
    const SHORT_SEC as Float = 180.0;
    const LONG_SEC as Float = 720.0;

    // The buffer has to hold the long window PLUS the current sample.
    const BUFFER_SIZE as Number = 145;

    // Persistence keys. The personal bests stay on the watch between
    // activities, which is what lets the model be ready by the second or third
    // run.
    const KEY_BEST_SHORT as String = "calBestShort";
    const KEY_BEST_LONG as String = "calBestLong";

    // ------------------------------------------------------------------
    // STATE
    // ------------------------------------------------------------------

    // Ring buffer of cumulative flat-equivalent distance (m).
    private var mCumulative as Array<Float>;
    private var mIndex as Number;
    private var mCount as Number;

    // Flat-equivalent distance accumulated since the activity started (m).
    private var mDistance as Float;

    // Seconds elapsed since the last sample was written to the buffer.
    private var mSinceSample as Float;

    // Personal bests: the greatest flat-equivalent distance covered in a
    // 3-minute and a 12-minute window. These outlive the activity.
    private var mBestShort as Float;
    private var mBestLong as Float;

    // True when the bests have changed and need writing back to Storage. It
    // avoids pointless flash writes at every timer stop.
    private var mDirty as Boolean;

    // ------------------------------------------------------------------
    // CONSTRUCTOR
    // ------------------------------------------------------------------

    function initialize() {
        mCumulative = new Array<Float>[BUFFER_SIZE];
        for (var i = 0; i < BUFFER_SIZE; i++) {
            mCumulative[i] = 0.0;
        }
        mIndex = 0;
        mCount = 0;
        mDistance = 0.0;
        mSinceSample = 0.0;
        mBestShort = 0.0;
        mBestLong = 0.0;
        mDirty = false;

        load();
    }

    // ------------------------------------------------------------------
    // Loads the personal bests from persistent storage. Any problem at all (no
    // key on first installation, an unexpected type written by an earlier
    // version) is handled by starting from zero: the calibration rebuilds
    // itself over a few runs, whereas a crash at startup is permanent.
    // ------------------------------------------------------------------
    private function load() as Void {
        try {
            var short = Storage.getValue(KEY_BEST_SHORT);
            if (short instanceof Float || short instanceof Number) {
                mBestShort = short.toFloat();
            }
            var long = Storage.getValue(KEY_BEST_LONG);
            if (long instanceof Float || long instanceof Number) {
                mBestLong = long.toFloat();
            }
        } catch (ex) {
            mBestShort = 0.0;
            mBestLong = 0.0;
        }
    }

    // ------------------------------------------------------------------
    // Saves the bests, when they have changed. Called at timer stop and at app
    // close, never while running: writing to flash every second would shorten
    // the life of the device for no benefit at all.
    // ------------------------------------------------------------------
    function save() as Void {
        if (!mDirty) {
            return;
        }
        try {
            Storage.setValue(KEY_BEST_SHORT, mBestShort);
            Storage.setValue(KEY_BEST_LONG, mBestLong);
            mDirty = false;
        } catch (ex) {
            // Storage full or unavailable: the bests stay valid in RAM for
            // this activity and are lost at the next one. That is not a reason
            // to interrupt somebody's run.
        }
    }

    // ------------------------------------------------------------------
    // Clears the personal bests, in RAM and in Storage. Exposed to the user as
    // a setting: it is needed after a long layoff, after a change of terrain
    // category, or when one bad session (a GPS track gone wrong) left an
    // unreachable best that pins the estimate too high.
    // ------------------------------------------------------------------
    function clear() as Void {
        mBestShort = 0.0;
        mBestLong = 0.0;
        mDirty = false;
        try {
            Storage.deleteValue(KEY_BEST_SHORT);
            Storage.deleteValue(KEY_BEST_LONG);
        } catch (ex) {
            // Nothing to do: the values in RAM are cleared regardless.
        }
    }

    // ------------------------------------------------------------------
    // Clears the SESSION state (buffer and cumulative distance) without
    // touching the personal bests. Called when the activity is reset: distance
    // restarts from zero, and comparing samples from the previous run against
    // the new one would produce negative windows.
    // ------------------------------------------------------------------
    function resetSession() as Void {
        mIndex = 0;
        mCount = 0;
        mDistance = 0.0;
        mSinceSample = 0.0;
    }

    // ------------------------------------------------------------------
    // Update step, once a second.
    //
    //   gapSpeed  flat-equivalent speed (m/s), computed through
    //             MinettiCost.modelRatio(). The uphill ceiling is essential
    //             here: without it a steep ramp covered on foot would produce
    //             an unrealistically high 3-minute best, and the estimated CS
    //             would stay inflated forever
    //   dt        seconds actually elapsed
    // ------------------------------------------------------------------
    function update(gapSpeed as Float, dt as Float) as Void {
        if (dt <= 0.0) {
            return;
        }

        mDistance += gapSpeed * dt;
        mSinceSample += dt;

        // One sample per call: the View caps dt at 5 seconds, so mSinceSample
        // can never reach twice the sampling period in one go.
        if (mSinceSample >= SAMPLE_PERIOD_SEC) {
            mSinceSample -= SAMPLE_PERIOD_SEC;
            pushSample();
        }
    }

    // ------------------------------------------------------------------
    // Writes the current cumulative distance into the ring buffer and updates
    // the two bests when they are beaten.
    // ------------------------------------------------------------------
    private function pushSample() as Void {
        mCumulative[mIndex] = mDistance;
        mIndex = (mIndex + 1) % BUFFER_SIZE;
        if (mCount < BUFFER_SIZE) {
            mCount++;
        }

        // Distance covered in the 3-minute window: the difference between the
        // sample just written and the one 36 slots earlier.
        if (mCount > SHORT_SLOTS) {
            var oldShort = (mIndex - 1 - SHORT_SLOTS + BUFFER_SIZE) % BUFFER_SIZE;
            var covered = mDistance - mCumulative[oldShort];
            if (covered > mBestShort) {
                mBestShort = covered;
                mDirty = true;
            }
        }

        // The same over the 12-minute window.
        if (mCount > LONG_SLOTS) {
            var oldLong = (mIndex - 1 - LONG_SLOTS + BUFFER_SIZE) % BUFFER_SIZE;
            var covered = mDistance - mCumulative[oldLong];
            if (covered > mBestLong) {
                mBestLong = covered;
                mDirty = true;
            }
        }
    }

    // ------------------------------------------------------------------
    // True when the two bests support a sensible estimate.
    //
    // The mBestLong > mBestShort condition is not a formality: if the long best
    // does not exceed the short one, the athlete has never held an effort for
    // 12 minutes, or the two bests come from inconsistent sessions. Either way
    // the line would have a negative slope and produce a meaningless CS.
    // ------------------------------------------------------------------
    function isValid() as Boolean {
        if (mBestShort <= 0.0 || mBestLong <= 0.0) {
            return false;
        }
        if (mBestLong <= mBestShort) {
            return false;
        }
        var cs = getCriticalSpeed();
        return (cs >= 1.5 && cs <= 6.5);
    }

    // ------------------------------------------------------------------
    // Slope of the line d(t) = CS*t + D', that is, critical speed in m/s. Call
    // only after isValid().
    // ------------------------------------------------------------------
    function getCriticalSpeed() as Float {
        return (mBestLong - mBestShort) / (LONG_SEC - SHORT_SEC);
    }

    // ------------------------------------------------------------------
    // Intercept of the same line, that is, D' in metres.
    // ------------------------------------------------------------------
    function getDPrime() as Float {
        var d = mBestShort - (getCriticalSpeed() * SHORT_SEC);
        if (d < 0.0) {
            d = 0.0;
        }
        return d;
    }

}
