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

// EccentricModel.mc
//
// Accumulated muscle damage from descending.
//
// WHY IT EXISTS, AND WHY NOTHING ELSE HAS IT
// In a mountain ultra the first system to give out is almost never the aerobic
// one: it is the quadriceps. Descending imposes eccentric contractions, where
// the muscle produces force while lengthening in order to brake the body. That
// is the kind of contraction that causes structural damage, and the damage does
// not recover during the race; it only accumulates. Halfway through UTMB it is
// not breath that runs out, it is legs that no longer brake.
//
// No data field, and no native Garmin metric, models this. They all measure the
// cardiovascular system, which in long trail racing is frequently not the
// binding constraint. This is the most original part of the app.
//
// HOW IT IS MEASURED
// The negative work the body has to absorb going down is proportional to the
// height lost. But not every metre of descent costs the same: descending fast
// means harder impacts and more force to absorb at every step. So the height
// lost is weighted by a factor that grows with speed:
//
//   equivalent metres = height lost * phi(speed)
//
// The unit is therefore "equivalent metres of descent", the same unit every
// trail runner already thinks in when they look at a race profile. Running
// 1000 m of descent weighs more than walking the same 1000 m, which is exactly
// what happens to the legs.
//
// THE CAPACITY
// The user sets how much descent their legs take before it becomes the problem.
// It is a number mountain runners know about themselves better than any formula
// does: they know whether 2000 m of descent wrecks them or whether they take
// 6000. The 3000 m default is the estimate for a trained trail runner who is
// not a descending specialist.
//
// NOTE: unlike the other models, this one does NOT need critical speed. It
// works from the first second of first use, with no calibration at all.

import Toybox.Lang;
import Toybox.Math;

class EccentricModel {

    // ------------------------------------------------------------------
    // MODEL CONSTANTS
    // ------------------------------------------------------------------

    // Reference speed for the weighting factor, in m/s. 3 m/s is about 5:30 per
    // km: a descent run at a solid pace.
    const REFERENCE_SPEED as Float = 3.0;

    // How much the cost per metre of height lost grows with speed. At 0.5,
    // descending at 3 m/s weighs 50% more than descending nearly stationary,
    // and 6 m/s weighs double.
    const SPEED_COEFFICIENT as Float = 0.5;

    // Ceiling on the weighting factor: past a certain speed the model would
    // stop being credible, and nobody descends faster than this for hours
    // anyway.
    const MAX_WEIGHT as Float = 2.0;

    // Accepted range for the capacity the user sets, in metres.
    const MIN_CAPACITY_M as Float = 500.0;
    const MAX_CAPACITY_M as Float = 15000.0;

    // ------------------------------------------------------------------
    // STATE
    // ------------------------------------------------------------------

    // Equivalent descent the athlete can take (m).
    private var mCapacityMeters as Float;

    // Equivalent descent accumulated so far (m), that is, weighted by the
    // speed of descent.
    private var mEquivalentMeters as Float;

    // Raw descent accumulated (m), unweighted. Kept as a readable reference,
    // and so it can be compared afterwards against the descent the device
    // records on its own.
    private var mDescentMeters as Float;

    // Current rate of accumulation (equivalent metres per second). Zero when
    // not descending, which is what makes the time to limit null on climbs and
    // on the flat, where the legs are not getting worse.
    private var mEquivalentRate as Float;

    // ------------------------------------------------------------------
    // CONSTRUCTOR
    // ------------------------------------------------------------------

    function initialize() {
        mCapacityMeters = 3000.0;
        mEquivalentMeters = 0.0;
        mDescentMeters = 0.0;
        mEquivalentRate = 0.0;
    }

    // ------------------------------------------------------------------
    // Sets the athlete's descent capacity, in metres of descent. Values out of
    // range are clamped rather than rejected: unlike critical speed, there is
    // no "impossible" value here that would signal corrupt data, only more or
    // less optimistic ones.
    // ------------------------------------------------------------------
    function setCapacity(capacityMeters as Float) as Void {
        var c = capacityMeters;
        if (c < MIN_CAPACITY_M) {
            c = MIN_CAPACITY_M;
        } else if (c > MAX_CAPACITY_M) {
            c = MAX_CAPACITY_M;
        }
        mCapacityMeters = c;
    }

    function reset() as Void {
        mEquivalentMeters = 0.0;
        mDescentMeters = 0.0;
        mEquivalentRate = 0.0;
    }

    // ------------------------------------------------------------------
    // Integration step.
    //
    //   speed          real speed along the ground (m/s), NOT the flat
    //                  equivalent: what counts here is the actual movement of
    //                  the body, not its aerobic cost
    //   gradeFraction  grade as a fraction, negative when descending
    //   dt             seconds elapsed
    // ------------------------------------------------------------------
    function update(speed as Float, gradeFraction as Float, dt as Float) as Void {
        mEquivalentRate = 0.0;

        if (dt <= 0.0 || speed <= 0.0 || gradeFraction >= 0.0) {
            // No eccentric damage accumulates uphill or on the flat. That is
            // not a simplification: eccentric contraction of the quadriceps is
            // specific to braking on a descent.
            return;
        }

        // Height lost per metre travelled: the sine of the grade, not the
        // grade itself. On gentle slopes the difference is negligible, but at
        // 45% the grade is 0.45 and the sine is 0.41, and using the former
        // would overestimate the descent by 10% exactly where the ground is
        // steepest and the number matters most.
        // The explicit toFloat(): Math.sqrt() returns a Double, and without the
        // conversion that type propagates into the class's Float fields, which
        // strict type checking rejects.
        var g = -gradeFraction; // positive when descending
        var sinTheta = (g / Math.sqrt(1.0 + (g * g))).toFloat();

        var verticalRate = speed * sinTheta;

        var weight = 1.0 + (SPEED_COEFFICIENT * (speed / REFERENCE_SPEED));
        if (weight > MAX_WEIGHT) {
            weight = MAX_WEIGHT;
        }

        mEquivalentRate = verticalRate * weight;
        mEquivalentMeters += mEquivalentRate * dt;
        mDescentMeters += verticalRate * dt;
    }

    // ------------------------------------------------------------------
    // ACCESSORS
    // ------------------------------------------------------------------

    // Equivalent descent accumulated (m).
    function getEquivalentMeters() as Float {
        return mEquivalentMeters;
    }

    // Raw descent accumulated (m).
    function getDescentMeters() as Float {
        return mDescentMeters;
    }

    // Descent capacity left, as a percentage.
    function getRemainingPercent() as Float {
        if (mCapacityMeters <= 0.0) {
            return 0.0;
        }
        var pct = (1.0 - (mEquivalentMeters / mCapacityMeters)) * 100.0;
        if (pct < 0.0) {
            pct = 0.0;
        } else if (pct > 100.0) {
            pct = 100.0;
        }
        return pct;
    }

    // ------------------------------------------------------------------
    // Seconds before the descent capacity runs out at the current rate of
    // accumulation. Null when not descending: uphill the legs are not getting
    // worse, so there is no time to limit.
    // ------------------------------------------------------------------
    function getTimeToLimitSec() as Float? {
        if (mEquivalentRate <= 0.0) {
            return null;
        }
        var left = mCapacityMeters - mEquivalentMeters;
        if (left <= 0.0) {
            return 0.0;
        }
        return left / mEquivalentRate;
    }

}
