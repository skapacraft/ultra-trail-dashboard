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

// FuelModel.mc
//
// Real-time carbohydrate balance.
//
// WHAT IT DOES THAT THE EXISTING NUTRITION TIMERS DO NOT
// The nutrition data fields on the Connect IQ Store today are almost all
// alarm clocks: they buzz every 30 minutes. They do not know how much you are
// burning, they do not know what intensity you are running at, and they say the
// same thing to somebody hiking as to somebody pushing up a climb. This model
// does the actual arithmetic:
//
//   starting store + absorbed - oxidised = what is left
//
// and from there works out how long until it runs out at the current rate.
//
// THE THREE PARTS OF THE SUM
//
// 1. OXIDATION. The fraction of energy coming from carbohydrate is not
//    constant: at low intensity the body burns mostly fat, near threshold
//    mostly sugar. The curve is driven by intensity relative to sustainable
//    speed, which is the same model that feeds the other fields.
//
// 2. ABSORPTION. What you eat now is not available now. The stomach is
//    modelled as a reservoir emptying with a time constant of about 20
//    minutes, and with a ceiling: past a certain hourly amount the gut cannot
//    absorb it, and the surplus stays there (in reality too, with consequences
//    familiar to anyone who has run an ultra).
//
// 3. STORE. Glycogen usable for running, in grams per kg.
//
// STATED LIMIT: the model assumes the athlete actually follows the intake plan
// they set. It has no way of knowing whether you ate: data fields receive no
// button events. That is an explicit assumption rather than a hidden
// approximation, and it is why the plan is a visible setting instead of a
// constant buried in the code.

import Toybox.Lang;

class FuelModel {

    // ------------------------------------------------------------------
    // MODEL CONSTANTS
    // ------------------------------------------------------------------

    // Glycogen usable for running, in grams per kg of body mass. Total stores
    // (muscle plus liver) in a trained athlete run between 10 and 12 g/kg, but
    // only the share held in the muscles doing the work is actually spendable:
    // glycogen in the biceps does not help you run. 7 g/kg is the conservative
    // estimate of what is genuinely available, which for a 70 kg athlete is
    // about 490 g, a little under 8600 kJ.
    const STORE_GRAMS_PER_KG as Float = 7.0;

    // Energy released by oxidising one gram of carbohydrate, in kJ.
    const ENERGY_PER_GRAM_KJ as Float = 17.5;

    // Time constant of gastric emptying, in seconds. Twenty minutes is the
    // typical delay between eating and availability in the blood. It is why
    // "eat when you are hungry" is a poor race strategy: by the time hunger
    // arrives you are already twenty minutes late.
    const GUT_TRANSIT_SEC as Float = 1200.0;

    // Ceiling on intestinal absorption, in grams per hour. On glucose and
    // maltodextrin alone the limit sits around 60 g/h; glucose and fructose
    // mixes reach 90 to 120 g/h in athletes with a trained gut. The upper limit
    // is what is used here: past it, what you swallow stays in the stomach and
    // produces no energy.
    const MAX_ABSORPTION_GRAMS_PER_HOUR as Float = 120.0;

    // Points on the carbohydrate utilisation curve, as a function of intensity
    // relative to sustainable speed (1.0 = at threshold).
    //
    // Piecewise linear interpolation instead of the sigmoid you would use on a
    // computer: Monkey C exposes no exponential function, and rebuilding one
    // would cost cycles on a device that has to finish compute() in a few
    // milliseconds. Five points reproduce the sigmoid to within a few
    // percentage points, which is far less than the uncertainty in the
    // underlying physiological data anyway.
    const INTENSITY_0 as Float = 0.40;
    const INTENSITY_1 as Float = 0.60;
    const INTENSITY_2 as Float = 0.80;
    const INTENSITY_3 as Float = 1.00;
    const INTENSITY_4 as Float = 1.20;
    const FRACTION_0 as Float = 0.20;
    const FRACTION_1 as Float = 0.38;
    const FRACTION_2 as Float = 0.58;
    const FRACTION_3 as Float = 0.78;
    const FRACTION_4 as Float = 0.95;

    // ------------------------------------------------------------------
    // STATE
    // ------------------------------------------------------------------

    private var mMassKg as Float;

    // Total store at the start of the activity (g), and how much is left (g).
    private var mStoreGrams as Float;
    private var mRemainingGrams as Float;

    // Carbohydrate swallowed but not yet absorbed (g).
    private var mGutGrams as Float;

    // Intake plan, in grams per second.
    private var mIntakeGramsPerSec as Float;

    // Most recent rates (g/s): how much is being burned, and how much is
    // actually reaching the bloodstream.
    private var mOxidationGramsPerSec as Float;
    private var mAbsorptionGramsPerSec as Float;

    private var mHasModel as Boolean;

    // ------------------------------------------------------------------
    // CONSTRUCTOR
    // ------------------------------------------------------------------

    function initialize() {
        mMassKg = 70.0;
        mStoreGrams = 70.0 * STORE_GRAMS_PER_KG;
        mRemainingGrams = mStoreGrams;
        mGutGrams = 0.0;
        mIntakeGramsPerSec = 0.0;
        mOxidationGramsPerSec = 0.0;
        mAbsorptionGramsPerSec = 0.0;
        mHasModel = false;
    }

    // ------------------------------------------------------------------
    // Configures the athlete and the intake plan.
    //
    //   massKg                body mass
    //   intakeGramsPerHour    carbohydrate the athlete plans to take per hour,
    //                         0 if there is no plan
    //
    // As in EnduranceEngine, when the store changes mid-activity what is
    // preserved is the FRACTION: changing the body mass setting must not hand
    // energy to, or take it from, somebody already running.
    // ------------------------------------------------------------------
    function setAthlete(massKg as Float, intakeGramsPerHour as Float) as Void {
        var fraction = 1.0;
        if (mStoreGrams > 0.0) {
            fraction = mRemainingGrams / mStoreGrams;
        }

        mMassKg = massKg;
        mStoreGrams = massKg * STORE_GRAMS_PER_KG;
        mRemainingGrams = mStoreGrams * fraction;

        var intake = intakeGramsPerHour;
        if (intake < 0.0) {
            intake = 0.0;
        } else if (intake > MAX_ABSORPTION_GRAMS_PER_HOUR) {
            // Swallowing more than the absorption ceiling does not increase
            // available energy, it only piles up in the stomach. Cap it here
            // rather than letting the gastric reservoir grow without limit for
            // the whole race.
            intake = MAX_ABSORPTION_GRAMS_PER_HOUR;
        }
        mIntakeGramsPerSec = intake / 3600.0;

        mHasModel = true;
    }

    function reset() as Void {
        mRemainingGrams = mStoreGrams;
        mGutGrams = 0.0;
        mOxidationGramsPerSec = 0.0;
        mAbsorptionGramsPerSec = 0.0;
    }

    // ------------------------------------------------------------------
    // Integration step.
    //
    //   metabolicPowerWPerKg  current metabolic power (W/kg), that is,
    //                         C(0) * flat-equivalent speed
    //   intensity             current speed divided by sustainable speed
    //                         (1.0 = exactly at threshold)
    //   dt                    seconds elapsed
    // ------------------------------------------------------------------
    function update(metabolicPowerWPerKg as Float, intensity as Float, dt as Float) as Void {
        if (!mHasModel || dt <= 0.0) {
            return;
        }

        // --- Oxidation -------------------------------------------------
        var fraction = carbFraction(intensity);
        var powerWatts = metabolicPowerWPerKg * mMassKg;
        mOxidationGramsPerSec = (powerWatts * fraction) / (ENERGY_PER_GRAM_KJ * 1000.0);

        // --- Absorption, with the gastric delay ------------------------
        mGutGrams += mIntakeGramsPerSec * dt;

        var rate = mGutGrams / GUT_TRANSIT_SEC;
        var maxRate = MAX_ABSORPTION_GRAMS_PER_HOUR / 3600.0;
        if (rate > maxRate) {
            rate = maxRate;
        }

        var absorbed = rate * dt;
        if (absorbed > mGutGrams) {
            absorbed = mGutGrams;
        }
        mGutGrams -= absorbed;
        mAbsorptionGramsPerSec = (dt > 0.0) ? (absorbed / dt) : 0.0;

        // --- Balance ----------------------------------------------------
        mRemainingGrams += absorbed - (mOxidationGramsPerSec * dt);
        if (mRemainingGrams < 0.0) {
            mRemainingGrams = 0.0;
        } else if (mRemainingGrams > mStoreGrams) {
            // Eating more than you burn does not create new stores: muscle
            // glycogen has a physical ceiling.
            mRemainingGrams = mStoreGrams;
        }
    }

    // ------------------------------------------------------------------
    // Fraction of energy coming from carbohydrate, by linear interpolation
    // between the five points of the curve.
    // ------------------------------------------------------------------
    private function carbFraction(intensity as Float) as Float {
        if (intensity <= INTENSITY_0) {
            return FRACTION_0;
        }
        if (intensity < INTENSITY_1) {
            return interpolate(intensity, INTENSITY_0, INTENSITY_1, FRACTION_0, FRACTION_1);
        }
        if (intensity < INTENSITY_2) {
            return interpolate(intensity, INTENSITY_1, INTENSITY_2, FRACTION_1, FRACTION_2);
        }
        if (intensity < INTENSITY_3) {
            return interpolate(intensity, INTENSITY_2, INTENSITY_3, FRACTION_2, FRACTION_3);
        }
        if (intensity < INTENSITY_4) {
            return interpolate(intensity, INTENSITY_3, INTENSITY_4, FRACTION_3, FRACTION_4);
        }
        return FRACTION_4;
    }

    // Linear interpolation between two points. Five arguments, well under the
    // limit of 9 the Monkey C VM imposes on older devices.
    private function interpolate(x as Float, x0 as Float, x1 as Float, y0 as Float, y1 as Float) as Float {
        return y0 + ((y1 - y0) * (x - x0)) / (x1 - x0);
    }

    // ------------------------------------------------------------------
    // ACCESSORS
    // ------------------------------------------------------------------

    function hasModel() as Boolean {
        return mHasModel;
    }

    function getRemainingGrams() as Float {
        return mRemainingGrams;
    }

    function getRemainingPercent() as Float {
        if (mStoreGrams <= 0.0) {
            return 0.0;
        }
        var pct = (mRemainingGrams / mStoreGrams) * 100.0;
        if (pct < 0.0) {
            pct = 0.0;
        } else if (pct > 100.0) {
            pct = 100.0;
        }
        return pct;
    }

    // Carbohydrate burned per hour at the current rate (g/h).
    function getOxidationGramsPerHour() as Float {
        return mOxidationGramsPerSec * 3600.0;
    }

    // ------------------------------------------------------------------
    // Seconds until the store runs out, or null when absorption covers
    // consumption at the current rate, so nothing is running out, or when the
    // model has not been configured.
    // ------------------------------------------------------------------
    function getTimeToDepletionSec() as Float? {
        if (!mHasModel) {
            return null;
        }
        var netDrain = mOxidationGramsPerSec - mAbsorptionGramsPerSec;
        if (netDrain <= 0.0) {
            return null;
        }
        return mRemainingGrams / netDrain;
    }

}
