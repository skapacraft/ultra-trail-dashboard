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

// EnduranceEngine.mc
//
// The physiological engine. It receives a flat-equivalent speed (GAP speed, in
// m/s) once a second and keeps three states integrated over time:
//
//   1. ACCUMULATED WORK    how much energy has been spent so far (kJ/kg)
//   2. SUSTAINABLE SPEED   the CS of right now, which DECAYS as you run
//   3. ANAEROBIC RESERVE   what is left above threshold (D' balance)
//
// Point 2 is what separates this engine from everything else. Xert, Stryd and
// Garmin's own Real-Time Stamina all treat the threshold (CP, CS, FTP) as a
// constant for the whole activity. That is a fair approximation under two or
// three hours and a false one beyond: the durability literature (Maunder et al.
// 2021) documents threshold falling 10 to 20% after several hours of work. In
// an ultra that is exactly the difference between a model that works and one
// telling an athlete they are taking it easy while they blow up.
//
// A NOTE ON UNITS: everything here is SI (m/s, metres, seconds, J/kg).
// Conversion to pace (min/km or min/mi) happens only when the string to display
// is formatted, in the View.

import Toybox.Lang;
import Toybox.Math;

class EnduranceEngine {

    // ------------------------------------------------------------------
    // MODEL CONSTANTS
    // ------------------------------------------------------------------

    // Reference work for the decay of sustainable speed, in kJ per kg of body
    // mass. The durability factor the user sets is the percentage of CS lost
    // EACH time this much work accumulates.
    //
    // For a sense of scale: running on the flat at 3 m/s costs 3.6 J/kg/m, so
    // 10.8 W/kg, so around 39 kJ/kg per hour. 100 kJ/kg is therefore a little
    // over two and a half hours of steady running at a moderate pace.
    const WORK_REFERENCE_KJ_PER_KG as Float = 100.0;

    // Floor on the decay: sustainable speed never drops below this fraction of
    // the starting value. It stops a very long ultra from walking the model
    // down towards zero, where every step would read as "above threshold" and
    // the field would become useless.
    const MIN_SPEED_RETENTION as Float = 0.60;

    // Plausible range for a runner's critical speed, in m/s. 1.5 m/s is about
    // 11:07 min/km, 6.5 m/s about 2:34 min/km: any value outside that came from
    // dirty data rather than from an athlete, and should be rejected rather
    // than displayed.
    const MIN_PLAUSIBLE_CS as Float = 1.5;
    const MAX_PLAUSIBLE_CS as Float = 6.5;

    // Plausible range for D', the work capacity above threshold, expressed as
    // metres of "extra distance" coverable above CS. Trained runners sit
    // between roughly 100 and 300 m in the literature.
    const MIN_PLAUSIBLE_D_PRIME as Float = 50.0;
    const MAX_PLAUSIBLE_D_PRIME as Float = 500.0;

    // D' used when CS is known, for example because the user entered a
    // threshold pace, but there is not yet enough data to estimate D' from the
    // athlete's own curve.
    const DEFAULT_D_PRIME as Float = 200.0;

    // ------------------------------------------------------------------
    // STATE
    // ------------------------------------------------------------------

    // Reference critical speed at the start of the activity (m/s), that is,
    // from rest. 0.0 means "no model available".
    private var mBaseCriticalSpeed as Float;

    // Anaerobic work capacity (m).
    private var mDPrime as Float;

    // Fraction of critical speed lost per WORK_REFERENCE_KJ_PER_KG of
    // accumulated work (0.08 = 8%). Setting 0.0 turns the decay off and returns
    // the engine to the classic constant-threshold behaviour.
    private var mDurabilityFactor as Float;

    // --- State integrated during the activity --------------------------

    // Work accumulated since the activity started, kJ/kg.
    private var mWorkKjPerKg as Float;

    // Sustainable speed RIGHT NOW (m/s), that is, mBaseCriticalSpeed already
    // reduced by the durability decay.
    private var mEffectiveCriticalSpeed as Float;

    // Anaerobic reserve left (m), between 0 and mDPrime.
    private var mBalance as Float;

    // Estimated seconds before the reserve runs out at the current rate. Null
    // below sustainable speed, where the reserve is recharging rather than
    // draining, so there is no "time to failure" at all. Showing 0, or some
    // enormous number, would be inventing a value.
    private var mTimeToFailureSec as Float?;

    // True only once there is a usable critical speed. While it is false the
    // View shows "--" rather than numbers with nothing behind them.
    private var mHasModel as Boolean;

    // ------------------------------------------------------------------
    // CONSTRUCTOR
    // ------------------------------------------------------------------

    function initialize() {
        mBaseCriticalSpeed = 0.0;
        mDPrime = DEFAULT_D_PRIME;
        mDurabilityFactor = 0.0;

        mWorkKjPerKg = 0.0;
        mEffectiveCriticalSpeed = 0.0;
        mBalance = DEFAULT_D_PRIME;
        mTimeToFailureSec = null;
        mHasModel = false;
    }

    // ------------------------------------------------------------------
    // Sets the athlete parameters. Called at startup, whenever a setting
    // changes, and whenever calibration produces a new estimate.
    //
    // criticalSpeed <= 0 means "no estimate available": the engine declares
    // itself not ready rather than working from an invented number.
    // ------------------------------------------------------------------
    function setAthlete(criticalSpeed as Float, dPrime as Float, durabilityFactor as Float) as Void {
        if (criticalSpeed < MIN_PLAUSIBLE_CS || criticalSpeed > MAX_PLAUSIBLE_CS) {
            mHasModel = false;
            mBaseCriticalSpeed = 0.0;
            mEffectiveCriticalSpeed = 0.0;
            mTimeToFailureSec = null;
            return;
        }

        var d = dPrime;
        if (d < MIN_PLAUSIBLE_D_PRIME) {
            d = MIN_PLAUSIBLE_D_PRIME;
        } else if (d > MAX_PLAUSIBLE_D_PRIME) {
            d = MAX_PLAUSIBLE_D_PRIME;
        }

        // When D' changes mid-activity, what is preserved is the FRACTION
        // rather than the absolute value: a reserve "at 70%" stays at 70%.
        // Otherwise a mere settings change would hand energy to, or take it
        // from, the athlete halfway through a race.
        var fraction = 1.0;
        if (mDPrime > 0.0) {
            fraction = mBalance / mDPrime;
        }

        mBaseCriticalSpeed = criticalSpeed;
        mDPrime = d;
        mBalance = d * fraction;
        mDurabilityFactor = durabilityFactor;
        mHasModel = true;

        recomputeEffectiveCriticalSpeed();
    }

    // ------------------------------------------------------------------
    // Clears the integrated state (work, reserve, sustainable speed) while
    // leaving the athlete parameters alone. Called when the user resets the
    // activity to start a new one.
    // ------------------------------------------------------------------
    function reset() as Void {
        mWorkKjPerKg = 0.0;
        mBalance = mDPrime;
        mTimeToFailureSec = null;
        recomputeEffectiveCriticalSpeed();
    }

    // ------------------------------------------------------------------
    // Integration step, called once a second by the View.
    //
    //   gapSpeed  flat-equivalent speed (m/s), already computed through
    //             MinettiCost.modelRatio(), so with the uphill ceiling applied
    //   dt        seconds actually elapsed since the last call, NOT assumed to
    //             be 1: compute() can skip cycles, and the timer may have been
    //             paused
    // ------------------------------------------------------------------
    function update(gapSpeed as Float, dt as Float) as Void {
        if (dt <= 0.0) {
            return;
        }

        // --- 1) Accumulated work ----------------------------------------
        // Metabolic power per kg is C(i) * v, and by construction of the GAP
        // speed C(i) * v = C(0) * vGap: the cost of the grade is already
        // entirely inside vGap, so the flat cost is all that is needed here.
        mWorkKjPerKg += (MinettiCost.FLAT_COST * gapSpeed * dt) / 1000.0;

        // --- 2) Decay of sustainable speed ------------------------------
        recomputeEffectiveCriticalSpeed();

        if (!mHasModel) {
            mTimeToFailureSec = null;
            return;
        }

        // --- 3) Anaerobic reserve balance -------------------------------
        // Differential form from Clarke and Skiba (2013). Skiba's original
        // 2012 formulation requires integrating over the WHOLE history of
        // previous efforts at every single sample, which on a watch with 32KB
        // and a 20-hour ultra is simply not possible. This form is
        // mathematically equivalent, costs O(1) per sample, and keeps no
        // history in RAM.
        var deficit = gapSpeed - mEffectiveCriticalSpeed;

        if (deficit > 0.0) {
            // Above sustainable speed: the reserve drains at the rate by
            // which it is being exceeded.
            mBalance -= deficit * dt;
            if (mBalance < 0.0) {
                mBalance = 0.0;
            }
            mTimeToFailureSec = mBalance / deficit;
        } else {
            // Below sustainable speed: the reserve recharges, faster the
            // slower you go and the emptier it is.
            if (mDPrime > 0.0) {
                mBalance += ((mDPrime - mBalance) * (-deficit) * dt) / mDPrime;
                if (mBalance > mDPrime) {
                    mBalance = mDPrime;
                }
            }
            // No anaerobic failure in prospect: below threshold the limit
            // will be glycogen, heat, or descent damage instead, none of which
            // this engine models.
            mTimeToFailureSec = null;
        }
    }

    // ------------------------------------------------------------------
    // Applies the durability decay to the base critical speed.
    //
    //   CS_eff = CS0 * (1 - k * work / reference_work)
    //
    // with the result never below MIN_SPEED_RETENTION * CS0.
    // ------------------------------------------------------------------
    private function recomputeEffectiveCriticalSpeed() as Void {
        if (!mHasModel) {
            mEffectiveCriticalSpeed = 0.0;
            return;
        }

        var retention = 1.0 - (mDurabilityFactor * (mWorkKjPerKg / WORK_REFERENCE_KJ_PER_KG));
        if (retention < MIN_SPEED_RETENTION) {
            retention = MIN_SPEED_RETENTION;
        } else if (retention > 1.0) {
            // Defensive: a negative durability factor has no physical meaning
            // and must not be able to raise the threshold during a race.
            retention = 1.0;
        }

        mEffectiveCriticalSpeed = mBaseCriticalSpeed * retention;
    }

    // ------------------------------------------------------------------
    // ACCESSORS, read by the View to format the quadrants and to write the
    // custom fields into the FIT file.
    // ------------------------------------------------------------------

    function hasModel() as Boolean {
        return mHasModel;
    }

    // Fallback D' for when critical speed is known but there is not yet data
    // to estimate anaerobic capacity. Exposed as a method rather than as a
    // constant read from outside, because the Monkey C VM does not allow
    // reading a class const without an instance.
    function defaultDPrime() as Float {
        return DEFAULT_D_PRIME;
    }

    // Current sustainable speed in m/s, 0.0 when the model is not ready.
    function getSustainableSpeed() as Float {
        return mEffectiveCriticalSpeed;
    }

    // Anaerobic reserve left, as a percentage (0-100).
    function getReservePercent() as Float {
        if (!mHasModel || mDPrime <= 0.0) {
            return 0.0;
        }
        var pct = (mBalance / mDPrime) * 100.0;
        if (pct < 0.0) {
            pct = 0.0;
        } else if (pct > 100.0) {
            pct = 100.0;
        }
        return pct;
    }

    // Seconds to failure, or null when the reserve is not draining.
    function getTimeToFailureSec() as Float? {
        return mTimeToFailureSec;
    }

    // Work accumulated since the activity started, kJ/kg.
    function getWorkKjPerKg() as Float {
        return mWorkKjPerKg;
    }

    // Reference critical speed, from rest, m/s.
    function getBaseCriticalSpeed() as Float {
        return mBaseCriticalSpeed;
    }

    function getDPrime() as Float {
        return mDPrime;
    }

}
