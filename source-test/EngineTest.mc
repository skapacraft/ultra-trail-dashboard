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

// EngineTest.mc
//
// Unit tests for the physiological engine.
//
// NOT part of the published app: this folder enters the build only when
// test.jungle is passed to the compiler as well (see the README). A release
// build uses monkey.jungle alone and sees none of this, so the tests cost not
// one byte on the watch.
//
// Why they exist: the formulas in this engine produce numbers that look
// plausible even when they are wrong. A flipped sign in the durability decay,
// or a factor of 1000 in the accumulated work, crashes nothing. It simply tells
// the athlete a lie, and we would find out only after a race went badly. A test
// against a value worked out by hand is the only defence.
//
// Running them:
//   monkeyc -f monkey.jungle -f test.jungle -o bin/test.prg \
//           -y developer_key -d fenix7 --unit-test
//   monkeydo bin/test.prg fenix7 -t

import Toybox.Lang;
import Toybox.Test;

// ----------------------------------------------------------------------
// Floating point comparison. Exact comparison with == is unusable here: every
// formula goes through polynomials and divisions, and the result differs in the
// last bit even when the arithmetic is right.
// ----------------------------------------------------------------------
function approx(actual as Float, expected as Float, tolerance as Float, label as String, logger as Logger) as Boolean {
    var delta = actual - expected;
    if (delta < 0.0) {
        delta = -delta;
    }
    if (delta > tolerance) {
        logger.error(Lang.format("$1$: expected $2$, got $3$", [label, expected, actual]));
        return false;
    }
    return true;
}

// ======================================================================
// MinettiCost
// ======================================================================

// The flat cost is the reference value for the whole model: if it changes,
// every GAP and every energy balance in the app changes with it.
(:test)
function testMinettiFlatCost(logger as Logger) as Boolean {
    if (!approx(MinettiCost.cost(0.0), 3.6, 0.0001, "C(0)", logger)) { return false; }
    if (!approx(MinettiCost.ratio(0.0), 1.0, 0.0001, "ratio(0)", logger)) { return false; }
    return true;
}

// Values worked out by hand from the polynomial, not read back off the code,
// which is the whole point of the test.
//   C(0.10) = 155.4*1e-5 - 30.4*1e-4 - 43.3*1e-3 + 46.3*0.01 + 1.95 + 3.6
//           = 5.968 J/kg/m
//   C(-0.20) = 1.800 J/kg/m  (the minimum of the curve, where descending costs
//              half of the flat, before braking starts to weigh again)
(:test)
function testMinettiKnownPoints(logger as Logger) as Boolean {
    if (!approx(MinettiCost.cost(0.10), 5.968, 0.001, "C(+10%)", logger)) { return false; }
    if (!approx(MinettiCost.cost(-0.20), 1.800, 0.001, "C(-20%)", logger)) { return false; }
    if (!approx(MinettiCost.ratio(-0.20), 0.500, 0.001, "ratio(-20%)", logger)) { return false; }
    return true;
}

// Past 45% the polynomial is no longer validated: the grade has to be clamped
// to the limit, not extrapolated.
(:test)
function testMinettiClampsBeyondValidRange(logger as Logger) as Boolean {
    var atLimit = MinettiCost.cost(0.45);
    var beyondLimit = MinettiCost.cost(0.90);
    if (!approx(beyondLimit, atLimit, 0.0001, "C beyond the limit", logger)) { return false; }

    var atLimitDown = MinettiCost.cost(-0.45);
    var beyondLimitDown = MinettiCost.cost(-0.90);
    if (!approx(beyondLimitDown, atLimitDown, 0.0001, "C beyond the downhill limit", logger)) { return false; }
    return true;
}

// The model ceiling must act on the uphill branch ONLY. Downhill the energy
// discount is real and must not be touched.
(:test)
function testMinettiModelRatioCap(logger as Logger) as Boolean {
    // At +45% the raw ratio is about 5.4. The model has to see it as 3.0, or
    // every steep wall taken on foot would read as an effort enormously above
    // threshold.
    if (MinettiCost.ratio(0.45) < 5.0) {
        logger.error("the raw ratio at +45% should exceed 5");
        return false;
    }
    if (!approx(MinettiCost.modelRatio(0.45), 3.0, 0.0001, "modelRatio(+45%)", logger)) { return false; }

    // Below the ceiling the two ratios have to agree.
    if (!approx(MinettiCost.modelRatio(0.10), MinettiCost.ratio(0.10), 0.0001, "modelRatio(+10%)", logger)) { return false; }

    // No ceiling downhill.
    if (!approx(MinettiCost.modelRatio(-0.20), 0.500, 0.001, "modelRatio(-20%)", logger)) { return false; }
    return true;
}

// ======================================================================
// EnduranceEngine
// ======================================================================

// An implausible critical speed, or none at all, must not produce an
// "almost right" model. It must produce no model, so the View shows "--"
// rather than an invented number.
(:test)
function testEngineRejectsImplausibleAthlete(logger as Logger) as Boolean {
    var engine = new EnduranceEngine();

    engine.setAthlete(0.0, 200.0, 0.08);
    if (engine.hasModel()) {
        logger.error("a zero critical speed was accepted");
        return false;
    }

    engine.setAthlete(12.0, 200.0, 0.08); // faster than the 100 m world record
    if (engine.hasModel()) {
        logger.error("an absurd critical speed was accepted");
        return false;
    }

    engine.setAthlete(3.0, 200.0, 0.08);
    if (!engine.hasModel()) {
        logger.error("a plausible critical speed was rejected");
        return false;
    }
    return true;
}

// Above threshold the reserve drains at the rate by which it is exceeded, and
// the time to failure is simply how long emptying it takes.
// CS = 3.0 m/s, D' = 200 m, running at 4.0 m/s for 10 s:
//   drain   = (4.0 - 3.0) * 10 = 10 m
//   reserve = 200 - 10 = 190 m  (95%)
//   failure = 190 / 1.0 = 190 s
(:test)
function testEngineDrainsReserveAboveThreshold(logger as Logger) as Boolean {
    var engine = new EnduranceEngine();
    engine.setAthlete(3.0, 200.0, 0.0); // durability off, to isolate the balance

    engine.update(4.0, 10.0);

    if (!approx(engine.getReservePercent(), 95.0, 0.1, "reserve", logger)) { return false; }

    var ttf = engine.getTimeToFailureSec();
    if (ttf == null) {
        logger.error("no time to failure above threshold");
        return false;
    }
    if (!approx(ttf, 190.0, 0.5, "time to failure", logger)) { return false; }
    return true;
}

// Below threshold the reserve recharges and there is no time to failure:
// returning 0, or some enormous number, would mean inventing a value.
(:test)
function testEngineRechargesBelowThreshold(logger as Logger) as Boolean {
    var engine = new EnduranceEngine();
    engine.setAthlete(3.0, 200.0, 0.0);

    engine.update(4.0, 60.0); // drain it partway
    var drained = engine.getReservePercent();
    if (drained >= 100.0) {
        logger.error("the reserve did not drain");
        return false;
    }

    if (engine.getTimeToFailureSec() == null) {
        logger.error("no time to failure during the effort");
        return false;
    }

    engine.update(2.0, 60.0); // recovery below threshold
    if (engine.getReservePercent() <= drained) {
        logger.error("the reserve did not recharge below threshold");
        return false;
    }
    if (engine.getTimeToFailureSec() != null) {
        logger.error("a time to failure was present below threshold");
        return false;
    }
    return true;
}

// The aid station case: stationary with the timer running. Recovery is at its
// maximum and accumulated work does not grow. It sounds obvious, but the first
// draft of the View skipped the engine update entirely at zero speed, freezing
// the balance during precisely the minutes the athlete recovers most.
(:test)
function testEngineRecoversWhenStationary(logger as Logger) as Boolean {
    var engine = new EnduranceEngine();
    engine.setAthlete(3.0, 200.0, 0.08);

    engine.update(4.5, 100.0); // an effort that drains reserve
    var drained = engine.getReservePercent();
    var workAfterEffort = engine.getWorkKjPerKg();

    engine.update(0.0, 120.0); // two minutes standing at an aid station

    if (engine.getReservePercent() <= drained) {
        logger.error("no recovery while stationary");
        return false;
    }
    if (!approx(engine.getWorkKjPerKg(), workAfterEffort, 0.001, "work while stationary", logger)) { return false; }
    if (engine.getTimeToFailureSec() != null) {
        logger.error("a time to failure was present while stationary");
        return false;
    }
    return true;
}

// The reserve can neither go below zero nor exceed D'.
(:test)
function testEngineReserveStaysInRange(logger as Logger) as Boolean {
    var engine = new EnduranceEngine();
    engine.setAthlete(3.0, 200.0, 0.0);

    engine.update(6.0, 600.0); // an unsustainable effort, held far too long
    if (engine.getReservePercent() < 0.0) {
        logger.error("negative reserve");
        return false;
    }
    if (!approx(engine.getReservePercent(), 0.0, 0.001, "reserve at the floor", logger)) { return false; }

    engine.update(1.0, 100000.0); // a very long recovery
    if (engine.getReservePercent() > 100.0) {
        logger.error("reserve above its maximum");
        return false;
    }
    return true;
}

// Accumulated work is the integral of metabolic power:
//   3.6 J/kg/m * 2.5 m/s = 9 W/kg, over 1000 s = 9 kJ/kg
(:test)
function testEngineAccumulatesWork(logger as Logger) as Boolean {
    var engine = new EnduranceEngine();
    engine.setAthlete(3.0, 200.0, 0.0);

    engine.update(2.5, 1000.0);
    if (!approx(engine.getWorkKjPerKg(), 9.0, 0.01, "accumulated work", logger)) { return false; }
    return true;
}

// THE MOST IMPORTANT TEST IN THE APP.
// Durability is what separates this engine from Xert, Stryd and Garmin's own
// Stamina, all of which treat the threshold as a constant. With a factor of 10%
// per 100 kJ/kg, after exactly 100 kJ/kg of work the sustainable speed has to
// be 90% of the starting value.
//
//   3.6 J/kg/m * 2.5 m/s = 9 W/kg
//   100 kJ/kg / 9 W/kg   = 11111.11 s
//   expected CS          = 3.0 * 0.90 = 2.70 m/s
(:test)
function testEngineDurabilityDecay(logger as Logger) as Boolean {
    var engine = new EnduranceEngine();
    engine.setAthlete(3.0, 200.0, 0.10);

    if (!approx(engine.getSustainableSpeed(), 3.0, 0.001, "CS at rest", logger)) { return false; }

    engine.update(2.5, 11111.11);

    if (!approx(engine.getWorkKjPerKg(), 100.0, 0.05, "work at 100 kJ/kg", logger)) { return false; }
    if (!approx(engine.getSustainableSpeed(), 2.70, 0.005, "CS after 100 kJ/kg", logger)) { return false; }
    return true;
}

// A durability factor of zero has to restore exactly the classic
// constant-threshold behaviour. It is what the user gets by setting 0, and it
// has to genuinely work.
(:test)
function testEngineDurabilityDisabled(logger as Logger) as Boolean {
    var engine = new EnduranceEngine();
    engine.setAthlete(3.0, 200.0, 0.0);

    engine.update(2.5, 50000.0);
    if (!approx(engine.getSustainableSpeed(), 3.0, 0.001, "CS with durability off", logger)) { return false; }
    return true;
}

// The decay must not be able to drive sustainable speed to zero. Below the 60%
// floor every single step would read as above threshold, and the field would
// become a permanent alarm, which is noise.
(:test)
function testEngineDurabilityFloor(logger as Logger) as Boolean {
    var engine = new EnduranceEngine();
    engine.setAthlete(3.0, 200.0, 0.25); // the maximum the settings allow

    engine.update(2.5, 100000.0); // about 900 kJ/kg, well beyond any ultra
    if (!approx(engine.getSustainableSpeed(), 1.80, 0.001, "decay floor", logger)) { return false; }
    return true;
}

// Changing D' mid-activity must neither hand over nor take away energy: the
// reserve is preserved as a fraction, not as an absolute value.
(:test)
function testEnginePreservesReserveFractionOnReconfigure(logger as Logger) as Boolean {
    var engine = new EnduranceEngine();
    engine.setAthlete(3.0, 200.0, 0.0);

    engine.update(4.0, 100.0); // reserve at 100/200 = 50%
    if (!approx(engine.getReservePercent(), 50.0, 0.1, "reserve before", logger)) { return false; }

    engine.setAthlete(3.0, 300.0, 0.0);
    if (!approx(engine.getReservePercent(), 50.0, 0.1, "reserve after", logger)) { return false; }
    return true;
}

// reset() clears the activity but not the athlete.
(:test)
function testEngineResetClearsSessionOnly(logger as Logger) as Boolean {
    var engine = new EnduranceEngine();
    engine.setAthlete(3.0, 200.0, 0.10);

    engine.update(4.0, 500.0);
    engine.reset();

    if (!approx(engine.getWorkKjPerKg(), 0.0, 0.001, "work after reset", logger)) { return false; }
    if (!approx(engine.getReservePercent(), 100.0, 0.001, "reserve after reset", logger)) { return false; }
    if (!approx(engine.getSustainableSpeed(), 3.0, 0.001, "CS after reset", logger)) { return false; }
    if (!engine.hasModel()) {
        logger.error("the reset cleared the athlete as well");
        return false;
    }
    return true;
}

// ======================================================================
// FuelModel
// ======================================================================

// Carbohydrate consumption at threshold, worked out by hand:
//   metabolic power                        = 3.6 J/kg/m * 3.0 m/s = 10.8 W/kg
//   over 70 kg                             = 756 W
//   carbohydrate fraction at intensity 1.0 = 0.78
//   energy from carbohydrate               = 589.7 J/s
//   divided by 17.5 kJ per gram            = 0.0337 g/s
//   over an hour                           = 121.3 g/h
(:test)
function testFuelOxidationAtThreshold(logger as Logger) as Boolean {
    var fuel = new FuelModel();
    fuel.setAthlete(70.0, 0.0);

    fuel.update(10.8, 1.0, 1.0);

    if (!approx(fuel.getOxidationGramsPerHour(), 121.3, 1.0, "consumption at threshold", logger)) { return false; }
    return true;
}

// The carbohydrate utilisation curve has to be monotonically increasing and to
// respect both ends: at very low intensity fat dominates, at high intensity
// almost all the energy comes from sugar.
//   155.5 g/h would correspond to a fraction of 1.0, so the expected fraction
//   is read by dividing the consumption by 155.5
(:test)
function testFuelCarbFractionCurve(logger as Logger) as Boolean {
    var fuel = new FuelModel();
    fuel.setAthlete(70.0, 0.0);

    fuel.update(10.8, 0.20, 1.0);
    var veryEasy = fuel.getOxidationGramsPerHour();
    if (!approx(veryEasy / 155.5, 0.20, 0.02, "fraction at intensity 0.2", logger)) { return false; }

    fuel.update(10.8, 0.90, 1.0);
    var moderate = fuel.getOxidationGramsPerHour();
    if (!approx(moderate / 155.5, 0.68, 0.02, "fraction at intensity 0.9", logger)) { return false; }

    fuel.update(10.8, 2.0, 1.0);
    var hard = fuel.getOxidationGramsPerHour();
    if (!approx(hard / 155.5, 0.95, 0.02, "fraction at intensity 2.0", logger)) { return false; }

    if (!(veryEasy < moderate && moderate < hard)) {
        logger.error("the carbohydrate curve is not monotonic");
        return false;
    }
    return true;
}

// Without eating, a 70 kg athlete's store of 490 g lasts a little over four
// hours at threshold: 490 / 0.0337 = 14540 s.
(:test)
function testFuelDepletionWithoutIntake(logger as Logger) as Boolean {
    var fuel = new FuelModel();
    fuel.setAthlete(70.0, 0.0);

    fuel.update(10.8, 1.0, 1.0);

    var ttd = fuel.getTimeToDepletionSec();
    if (ttd == null) {
        logger.error("no time to depletion with no intake");
        return false;
    }
    if (!approx(ttd, 14540.0, 100.0, "time to depletion", logger)) { return false; }
    if (!approx(fuel.getRemainingPercent(), 100.0, 0.1, "starting store", logger)) { return false; }
    return true;
}

// THE GASTRIC DELAY, which is what separates this model from a timer.
// At 60 g/h for one hour, 60 g are swallowed, but the stomach still holds about
// 19 (steady state is 60/3600 * 1200 = 20 g, reached after three time
// constants), so about 41 reach the bloodstream. A model ignoring transit would
// count 60, and would tell the athlete they are fine while they are already in
// deficit.
(:test)
function testFuelGutTransitDelay(logger as Logger) as Boolean {
    var withoutIntake = new FuelModel();
    withoutIntake.setAthlete(70.0, 0.0);
    var withIntake = new FuelModel();
    withIntake.setAthlete(70.0, 60.0);

    for (var t = 0; t < 3600; t++) {
        withoutIntake.update(10.8, 1.0, 1.0);
        withIntake.update(10.8, 1.0, 1.0);
    }

    var absorbed = withIntake.getRemainingGrams() - withoutIntake.getRemainingGrams();
    if (!approx(absorbed, 41.0, 2.0, "absorbed in one hour", logger)) { return false; }

    // And in the first minute almost nothing should have arrived.
    var early = new FuelModel();
    early.setAthlete(70.0, 60.0);
    var earlyReference = new FuelModel();
    earlyReference.setAthlete(70.0, 0.0);
    for (var t = 0; t < 60; t++) {
        early.update(10.8, 1.0, 1.0);
        earlyReference.update(10.8, 1.0, 1.0);
    }
    var earlyAbsorbed = early.getRemainingGrams() - earlyReference.getRemainingGrams();
    if (earlyAbsorbed > 0.5) {
        logger.error(Lang.format("$1$ g absorbed in the first minute, transit is not being applied", [earlyAbsorbed]));
        return false;
    }
    return true;
}

// Eating more than the absorption ceiling produces no energy: the model has to
// cap intake rather than pile it up in the stomach without limit.
(:test)
function testFuelIntakeIsCapped(logger as Logger) as Boolean {
    var capped = new FuelModel();
    capped.setAthlete(70.0, 200.0);
    var atCap = new FuelModel();
    atCap.setAthlete(70.0, 120.0);

    for (var t = 0; t < 3600; t++) {
        capped.update(10.8, 1.0, 1.0);
        atCap.update(10.8, 1.0, 1.0);
    }

    if (!approx(capped.getRemainingGrams(), atCap.getRemainingGrams(), 0.5, "absorption ceiling", logger)) { return false; }
    return true;
}

// When intake covers consumption there is no time to depletion at all:
// returning some enormous number would be noise.
(:test)
function testFuelNoDepletionWhenIntakeCoversBurn(logger as Logger) as Boolean {
    var fuel = new FuelModel();
    fuel.setAthlete(70.0, 90.0);

    // Low intensity: carbohydrate consumption is well under 90 g/h.
    for (var t = 0; t < 3600; t++) {
        fuel.update(4.0, 0.30, 1.0);
    }

    if (fuel.getTimeToDepletionSec() != null) {
        logger.error("a time to depletion was present while eating more than is burned");
        return false;
    }
    return true;
}

// ======================================================================
// EccentricModel
// ======================================================================

// Worked out by hand on a grade chosen to give exact numbers.
// Grade -75%: the sine is 0.75 / sqrt(1 + 0.5625) = 0.75 / 1.25 = 0.60.
//   height lost per second      = 1.0 m/s * 0.60  = 0.60 m/s
//   weight at 1 m/s             = 1 + 0.5 * (1/3) = 1.1667
//   equivalent metres per second = 0.60 * 1.1667  = 0.70 m/s
// Over 100 seconds: 70 equivalent metres, 60 m of raw descent.
(:test)
function testEccentricAccumulation(logger as Logger) as Boolean {
    var ecc = new EccentricModel();
    ecc.setCapacity(3000.0);

    ecc.update(1.0, -0.75, 100.0);

    if (!approx(ecc.getEquivalentMeters(), 70.0, 0.1, "equivalent metres", logger)) { return false; }
    if (!approx(ecc.getDescentMeters(), 60.0, 0.1, "raw descent", logger)) { return false; }
    if (!approx(ecc.getRemainingPercent(), 97.667, 0.05, "capacity left", logger)) { return false; }

    var ttl = ecc.getTimeToLimitSec();
    if (ttl == null) {
        logger.error("no time to limit while descending");
        return false;
    }
    if (!approx(ttl, 4185.7, 5.0, "time to limit", logger)) { return false; }
    return true;
}

// Uphill and on the flat, eccentric damage does not grow. That is not a
// simplification: eccentric contraction of the quadriceps is specific to
// braking on a descent.
(:test)
function testEccentricIgnoresUphillAndFlat(logger as Logger) as Boolean {
    var ecc = new EccentricModel();
    ecc.setCapacity(3000.0);

    ecc.update(3.0, 0.20, 600.0);  // uphill
    ecc.update(3.0, 0.0, 600.0);   // flat

    if (!approx(ecc.getEquivalentMeters(), 0.0, 0.001, "accumulation uphill and flat", logger)) { return false; }
    if (ecc.getTimeToLimitSec() != null) {
        logger.error("a time to limit was present while not descending");
        return false;
    }
    return true;
}

// THE POINT OF THE MODEL: for the same height lost, descending fast costs more
// than descending slowly. If that property fell over, the field would be a
// descent counter, which the watch already provides.
(:test)
function testEccentricPenalisesFastDescending(logger as Logger) as Boolean {
    var slow = new EccentricModel();
    slow.setCapacity(3000.0);
    var fast = new EccentricModel();
    fast.setCapacity(3000.0);

    // Same height lost (60 m), different times: 1 m/s for 100 s against
    // 4 m/s for 25 s.
    slow.update(1.0, -0.75, 100.0);
    fast.update(4.0, -0.75, 25.0);

    if (!approx(slow.getDescentMeters(), fast.getDescentMeters(), 0.1, "same height lost", logger)) { return false; }

    if (!(fast.getEquivalentMeters() > slow.getEquivalentMeters())) {
        logger.error("descending fast does not weigh more than descending slowly");
        return false;
    }

    // slow weight = 1.1667, fast weight = 1 + 0.5*(4/3) = 1.6667
    if (!approx(fast.getEquivalentMeters() / slow.getEquivalentMeters(), 1.4286, 0.01, "ratio between the weights", logger)) { return false; }
    return true;
}

// The weighting factor has a ceiling: past a certain speed the model would
// stop being credible.
(:test)
function testEccentricWeightIsCapped(logger as Logger) as Boolean {
    var ecc = new EccentricModel();
    ecc.setCapacity(3000.0);

    // At 20 m/s the raw weight would be 4.33; it has to be 2.0.
    // height lost per second = 20 * 0.6 = 12 m/s, over 1 s = 12 m
    // equivalent metres      = 12 * 2.0 = 24 m
    ecc.update(20.0, -0.75, 1.0);

    if (!approx(ecc.getEquivalentMeters(), 24.0, 0.1, "weighting factor ceiling", logger)) { return false; }
    return true;
}

// The capacity left cannot leave the 0 to 100 range, even after a descent that
// blows well past the configured limit.
(:test)
function testEccentricRemainingStaysInRange(logger as Logger) as Boolean {
    var ecc = new EccentricModel();
    ecc.setCapacity(500.0);

    ecc.update(3.0, -0.75, 10000.0);

    var remaining = ecc.getRemainingPercent();
    if (remaining < 0.0 || remaining > 100.0) {
        logger.error(Lang.format("capacity left out of range: $1$", [remaining]));
        return false;
    }
    if (!approx(remaining, 0.0, 0.001, "capacity emptied", logger)) { return false; }

    var ttl = ecc.getTimeToLimitSec();
    if (ttl == null) {
        logger.error("no time to limit while still descending");
        return false;
    }
    if (!approx(ttl, 0.0, 0.001, "time to limit at zero capacity", logger)) { return false; }
    return true;
}

// ======================================================================
// SpeedCalibration
// ======================================================================

// At constant speed the line d(t) = CS*t + D' degenerates into a line through
// the origin: the slope is the speed itself and D' is zero.
(:test)
function testCalibrationConstantSpeed(logger as Logger) as Boolean {
    var cal = new SpeedCalibration();
    cal.clear();
    cal.resetSession();

    if (cal.isValid()) {
        logger.error("the calibration declared itself valid with no data");
        return false;
    }

    // 20 minutes at 3.0 m/s, one sample per second.
    for (var t = 0; t < 1200; t++) {
        cal.update(3.0, 1.0);
    }

    if (!cal.isValid()) {
        logger.error("the calibration is invalid after 20 minutes of data");
        return false;
    }
    if (!approx(cal.getCriticalSpeed(), 3.0, 0.01, "CS at constant speed", logger)) { return false; }
    if (!approx(cal.getDPrime(), 0.0, 1.0, "D' at constant speed", logger)) { return false; }

    cal.clear();
    return true;
}

// A realistic case: a steady run plus a 3-minute effort at the end.
//   3 min best  = 4.0 * 180 = 720 m
//   12 min best = 3.0 * 540 + 4.0 * 180 = 2340 m
//   CS = (2340 - 720) / (720 - 180) = 3.0 m/s
//   D' = 720 - 3.0 * 180 = 180 m
(:test)
function testCalibrationSeparatesCsFromDPrime(logger as Logger) as Boolean {
    var cal = new SpeedCalibration();
    cal.clear();
    cal.resetSession();

    for (var t = 0; t < 1200; t++) {
        cal.update(3.0, 1.0);
    }
    for (var t = 0; t < 180; t++) {
        cal.update(4.0, 1.0);
    }

    if (!cal.isValid()) {
        logger.error("the calibration is invalid after a steady run plus an effort");
        return false;
    }
    if (!approx(cal.getCriticalSpeed(), 3.0, 0.02, "CS with a final effort", logger)) { return false; }
    if (!approx(cal.getDPrime(), 180.0, 5.0, "D' with a final effort", logger)) { return false; }

    cal.clear();
    return true;
}

// A session that is too short produces no estimate: no data beats data
// invented over a window that never closed.
(:test)
function testCalibrationRejectsShortSession(logger as Logger) as Boolean {
    var cal = new SpeedCalibration();
    cal.clear();
    cal.resetSession();

    for (var t = 0; t < 300; t++) { // 5 minutes: the 12-minute window never closes
        cal.update(3.0, 1.0);
    }

    if (cal.isValid()) {
        logger.error("an estimate was produced without a 12-minute window");
        return false;
    }

    cal.clear();
    return true;
}

// resetSession() clears the run but NOT the personal bests: those are the
// athlete's long-term memory and have to outlive the activity.
(:test)
function testCalibrationKeepsRecordsAcrossSessions(logger as Logger) as Boolean {
    var cal = new SpeedCalibration();
    cal.clear();
    cal.resetSession();

    for (var t = 0; t < 1200; t++) {
        cal.update(3.0, 1.0);
    }
    var csBefore = cal.getCriticalSpeed();

    cal.resetSession();

    if (!cal.isValid()) {
        logger.error("the bests were lost when the session was reset");
        return false;
    }
    if (!approx(cal.getCriticalSpeed(), csBefore, 0.001, "CS after a session reset", logger)) { return false; }

    cal.clear();
    return true;
}
