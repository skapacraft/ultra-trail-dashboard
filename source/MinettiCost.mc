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

// MinettiCost.mc
//
// Energy cost of running as a function of grade, from Minetti et al. (2002),
// "Energy cost of walking and running at extreme uphill and downhill slopes",
// J Appl Physiol 93:1039-1046.
//
// This module is the SINGLE source of truth for energy cost across the whole
// app: the GAP shown on screen, the physiological engine (EnduranceEngine) and
// the self-calibration (SpeedCalibration) all go through it. A copy of the
// formula used to live inside the View. Keeping exactly one is what stops the
// three consumers from drifting apart over time.
//
// A "module" rather than a "class" on purpose: these are pure functions with no
// state, so there is no instance to allocate. On a data field that has to fit
// in 32KB (base Fenix 6, FR935, Enduro 1) every object not created is memory
// gained.

import Toybox.Lang;

module MinettiCost {

    // Energy cost of running on the flat, C(0), in J/kg/m.
    // It is the denominator of every ratio computed below.
    const FLAT_COST as Float = 3.6;

    // Where the model stops being valid, as a grade fraction (0.45 = 45%).
    // Minetti measured energy cost between -45% and +45%. Outside that range
    // the polynomial is no longer validated and produces values with no
    // physical meaning (it can even go negative), so grades beyond the limit
    // are clamped to the limit itself.
    const MAX_GRADE_FRACTION as Float = 0.45;

    // Ceiling on the cost ratio used by the ENGINE and by CALIBRATION, not by
    // the GAP shown on screen, which stays faithful to pure Minetti.
    //
    // Why it is needed: at +45% the ratio C(i)/C(0) is about 5.4, meaning the
    // model treats one metre up that ramp as equivalent to 5.4 metres on the
    // flat. But Minetti measured RUNNING on a treadmill, and past 20 to 25%
    // every athlete hikes; hiking a steep climb is far more economical than the
    // running the polynomial extrapolates. Without this ceiling the engine
    // would read every steep ramp as an effort enormously above threshold,
    // empty the anaerobic reserve in seconds, and flash a "limit" warning on
    // every wall of the course: a systematic false positive.
    //
    // 3.0 corresponds to roughly 25% grade, which is where the run-to-hike
    // transition has happened for everybody.
    const MODEL_MAX_RATIO as Float = 3.0;

    // ------------------------------------------------------------------
    // Energy cost C(i) in J/kg/m at the given grade, as a fraction rather than
    // a percentage: 0.12 = 12%.
    //
    //   C(i) = 155.4*i^5 - 30.4*i^4 - 43.3*i^3 + 46.3*i^2 + 19.5*i + 3.6
    // ------------------------------------------------------------------
    function cost(gradeFraction as Float) as Float {
        var i = gradeFraction;

        if (i > MAX_GRADE_FRACTION) {
            i = MAX_GRADE_FRACTION;
        } else if (i < -MAX_GRADE_FRACTION) {
            i = -MAX_GRADE_FRACTION;
        }

        var i2 = i * i;
        var i3 = i2 * i;
        var i4 = i3 * i;
        var i5 = i4 * i;

        var c = (155.4 * i5) - (30.4 * i4) - (43.3 * i3) + (46.3 * i2) + (19.5 * i) + FLAT_COST;

        // Defensive: inside the range clamped above the polynomial never
        // reaches zero, but whoever divides by this value should not have to
        // think about that.
        if (c < 0.1) {
            c = 0.1;
        }
        return c;
    }

    // ------------------------------------------------------------------
    // Ratio C(i)/C(0): what a metre at this grade costs relative to a metre on
    // the flat. It is the factor that turns real speed into flat-equivalent
    // speed, and real pace into GAP.
    //
    // Uphill it is above 1, because it is harder. Downhill it is below 1 down
    // to about -20%, where it bottoms out around 0.50, then rises again as
    // eccentric braking starts to cost.
    // ------------------------------------------------------------------
    function ratio(gradeFraction as Float) as Float {
        return cost(gradeFraction) / FLAT_COST;
    }

    // ------------------------------------------------------------------
    // Like ratio(), but with MODEL_MAX_RATIO applied to the uphill branch. Use
    // it for anything feeding a MODEL (anaerobic balance, accumulated work, CS
    // calibration), never for the GAP value shown to the user.
    //
    // The downhill branch has no ceiling. The energy discount of running
    // downhill is real in aerobic terms, and it is correct for the engine to
    // see descent as recovery. What is missing there is the MECHANICAL cost of
    // descending, the eccentric damage to the quadriceps, which is not an
    // aerobic cost and is modelled separately.
    // ------------------------------------------------------------------
    function modelRatio(gradeFraction as Float) as Float {
        var r = ratio(gradeFraction);
        if (r > MODEL_MAX_RATIO) {
            r = MODEL_MAX_RATIO;
        }
        return r;
    }

}
