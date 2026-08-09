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

// UltraTrailDashboardView.mc
//
// The heart of Ultra-Trail Dashboard.
//
// A Connect IQ complex data field extends WatchUi.DataField and receives two
// main events from the system:
//
//   - compute(info)  -> called once a second with the raw activity data
//                       (pace, altitude, distance, HR, and so on). ALL the
//                       computation happens here: grade, GAP, updating the
//                       physiological engine, and writing the FIT fields.
//
//   - onUpdate(dc)   -> called whenever the screen has to be redrawn. NO
//                       computation happens here: it only draws the strings
//                       already prepared in compute(). That split is what
//                       keeps the field fast on Forerunners, which have less
//                       RAM and CPU than the Fenix line.
//
// THE MEMORY RULE:
// onUpdate() NEVER creates a new object, array or string. Everything it needs
// (fixed-size arrays, formatted strings) is allocated once in initialize() or
// recomputed in compute(), which runs once a second rather than once a frame.
//
// LAYERED ARCHITECTURE:
// this View is layer 0 (sensors) and layer 4 (decision). Between them sit
// three separate components, one per file:
//   MinettiCost        layer 1, the energy cost of the grade
//   EnduranceEngine    layers 2 and 3, physiological state and prediction
//   SpeedCalibration   automatic estimation of the athlete's parameters

import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.System;
import Toybox.Lang;
import Toybox.Activity;
import Toybox.FitContributor;
import Toybox.Math;
import Toybox.Application.Properties;

class UltraTrailDashboardView extends WatchUi.DataField {

    // ------------------------------------------------------------------
    // SOURCES AVAILABLE FOR THE QUADRANTS
    // ------------------------------------------------------------------
    // The user picks from Garmin Connect Mobile what each of the 4 quadrants
    // shows. These numbers are the contract with
    // resources/settings/settings.xml: the <listEntry value="..."> entries have
    // to match, and the values must NEVER be reordered after a release, or the
    // configuration already saved on people's watches would end up pointing at
    // the wrong field.
    private const SRC_PACE as Number = 0;
    private const SRC_HR as Number = 1;
    private const SRC_GRADE as Number = 2;
    private const SRC_GAP as Number = 3;
    private const SRC_RESERVE as Number = 4;
    private const SRC_TTF as Number = 5;
    private const SRC_SUSTAIN as Number = 6;
    private const SRC_CARB as Number = 7;
    private const SRC_QUADS as Number = 8;
    private const SRC_COUNT as Number = 9;

    // Which physiological system is limiting the athlete right now.
    //
    // This is the heart of the LIMIT field. Instead of adding unlike quantities
    // together into an invented index, each subsystem declares how long until
    // its own failure, and the field shows the minimum together with the name
    // of whichever imposes it. The limit is not a score, it is the first system
    // to give out, and knowing WHICH one is what tells the athlete what to do:
    // ease off, eat, or brake less on the descents. Those are three different
    // actions, and a single index could not tell them apart.
    private const BIND_NONE as Number = 0;
    private const BIND_ANAEROBIC as Number = 1;
    private const BIND_CARB as Number = 2;
    private const BIND_QUADS as Number = 3;

    // Number of quadrants on screen. Not configurable: the 2x2 grid is what
    // makes the field readable at a glance while running.
    private const QUADRANT_COUNT as Number = 4;

    // Alert levels used to colour a value. They are layer 4 of the
    // architecture: the step from a number to a judgement.
    private const LEVEL_NORMAL as Number = 0;
    private const LEVEL_WARNING as Number = 1;
    private const LEVEL_DANGER as Number = 2;

    // ------------------------------------------------------------------
    // CONFIGURATION CONSTANTS
    // ------------------------------------------------------------------

    // MAXIMUM size of the history arrays, allocated once at a fixed size in
    // initialize(). The user can choose a shorter smoothing window from Garmin
    // Connect Mobile (see resources/properties/properties.xml and
    // resources/settings/settings.xml) but never a longer one: this is where
    // the RAM is reserved up front, so no array is ever reallocated during an
    // activity.
    private const MAX_HISTORY_SIZE as Number = 30;

    // Accepted range for the user-configurable smoothing window, in seconds.
    // These have to match min/max in settings.xml, so that the Garmin Connect
    // Mobile UI and the app's own logic stay consistent.
    private const MIN_HISTORY_SIZE as Number = 3;
    private const DEFAULT_HISTORY_SIZE as Number = 10;

    // Below this distance covered (in metres) within the smoothing window, the
    // grade calculation would be too noisy, since it risks dividing by
    // something close to zero. In that case the last valid grade is kept.
    private const MIN_DISTANCE_FOR_GRADE as Float = 3.0;

    // Grade thresholds (absolute value, in percent) past which the value is
    // coloured, so it registers without having to be read. That matters late in
    // an ultra, when clarity of thought is the first thing to go. Past
    // GRADE_DANGER_THRESHOLD the colour is stronger than past
    // GRADE_WARNING_THRESHOLD.
    private const GRADE_WARNING_THRESHOLD as Float = 12.0;
    private const GRADE_DANGER_THRESHOLD as Float = 20.0;
    private const GRADE_HYSTERESIS as Float = 1.5;

    // Alert thresholds on the anaerobic reserve left, in percent.
    private const RESERVE_WARNING_THRESHOLD as Float = 50.0;
    private const RESERVE_DANGER_THRESHOLD as Float = 25.0;
    private const RESERVE_HYSTERESIS as Float = 5.0;

    // Alert thresholds on the percentage of carbohydrate and of descent
    // capacity left.
    private const FUEL_WARNING_THRESHOLD as Float = 40.0;
    private const FUEL_DANGER_THRESHOLD as Float = 20.0;
    private const FUEL_HYSTERESIS as Float = 5.0;

    // Alert thresholds on time to failure, in seconds.
    //
    // There are TWO different sets, and the reason is design rather than
    // convenience: a warning threshold should be worth as much as the time
    // needed to act on it. An anaerobic limit is fixed in seconds by slowing
    // down, so three minutes of notice is more than enough. Running out of
    // carbohydrate means eating and then waiting twenty minutes for the gut to
    // absorb it, and legs wrecked by descending do not recover at all; there,
    // three minutes of notice would be as useless as none. Hence half an hour
    // and ten minutes.
    private const ANAEROBIC_WARNING_SEC as Float = 180.0;
    private const ANAEROBIC_DANGER_SEC as Float = 60.0;
    private const ANAEROBIC_HYSTERESIS_SEC as Float = 15.0;
    private const SLOW_WARNING_SEC as Float = 1800.0;
    private const SLOW_DANGER_SEC as Float = 600.0;
    private const SLOW_HYSTERESIS_SEC as Float = 120.0;

    // Longest single integration step the engine will accept, in seconds.
    // compute() should run at 1 Hz, but the system can skip cycles under load,
    // and info.timerTime jumps outright if the user stays paused for a while.
    // Without this ceiling a twenty-minute pause would be integrated in one go
    // and would empty the reserve instantly.
    private const MAX_DT_SEC as Float = 5.0;

    // How often the automatic calibration is re-checked for usability. It only
    // matters when the engine started WITHOUT a model: as soon as calibration
    // becomes valid, the field stops showing "--" and starts working.
    private const CALIBRATION_CHECK_PERIOD_SEC as Number = 30;

    // Reference distance (in metres) for computing pace: 1000 on metric units,
    // 1609.344 (one mile) on imperial. Decided once in initialize() by reading
    // the device's own system settings.
    private const METERS_PER_KILOMETER as Float = 1000.0;
    private const METERS_PER_MILE as Float = 1609.344;

    // Ids of the custom fields written into the FIT file. Connect IQ allows at
    // most 16 per app, and these are spent on MODEL STATE rather than on
    // incidental metrics. That is what makes it possible, afterwards, to
    // recalibrate the athlete's parameters by comparing the prediction against
    // what actually happened in the race.
    private const FIT_FIELD_GAP as Number = 0;
    private const FIT_FIELD_RESERVE as Number = 1;
    private const FIT_FIELD_SUSTAIN as Number = 2;
    private const FIT_FIELD_WORK as Number = 3;
    private const FIT_FIELD_CS as Number = 4;
    private const FIT_FIELD_DPRIME as Number = 5;
    private const FIT_FIELD_CARB as Number = 6;
    private const FIT_FIELD_ECCENTRIC as Number = 7;

    // ------------------------------------------------------------------
    // INTERNAL STATE, allocated ONCE in initialize()
    // ------------------------------------------------------------------

    // The custom fields written into the .FIT file.
    // All nullable on purpose: if createField() fails on some device or
    // firmware, the app keeps working as a display instead of crashing on the
    // first write. All that is lost is the recording of that one field.
    private var mGapField as FitContributor.Field?;
    private var mReserveField as FitContributor.Field?;
    private var mSustainField as FitContributor.Field?;
    private var mWorkField as FitContributor.Field?;
    private var mCsField as FitContributor.Field?;
    private var mDPrimeField as FitContributor.Field?;
    private var mCarbField as FitContributor.Field?;
    private var mEccentricField as FitContributor.Field?;

    // The three physiological models and the automatic calibration.
    //
    // They are deliberately separate and independent: each integrates its own
    // state and declares its own time to failure, knowing nothing about the
    // others. That is what makes it possible to add a fourth, thermal load,
    // without touching the existing three, and to drop one of the three without
    // the others stopping.
    private var mEngine as EnduranceEngine;
    private var mCalibration as SpeedCalibration;
    private var mFuel as FuelModel;
    private var mEccentric as EccentricModel;

    // The binding constraint: how long until the first failure, and which
    // system imposes it. Recomputed in compute(), read by updateQuadrant().
    private var mBindingTtfSec as Float?;
    private var mBindingKind as Number;

    // Labels of the LIMIT field, preloaded once because they change every
    // second along with the binding constraint: reloading them from resources
    // in every compute() would allocate a string per second.
    private var mLabelLimit as String;
    private var mLabelAnaerobic as String;
    private var mLabelCarb as String;
    private var mLabelQuads as String;

    // FIXED-size ring buffers holding the altitude and distance history, used
    // to compute the smoothed grade.
    private var mAltHistory as Array<Float>;
    private var mDistHistory as Array<Float>;

    // Index of the next cell to write in the ring buffer, and how many valid
    // samples it currently holds, which matters until the buffer has filled for
    // the first time.
    private var mHistIndex as Number;
    private var mHistCount as Number;

    // ACTUAL size of the smoothing window in use, in seconds, read from the
    // user settings and always between MIN_HISTORY_SIZE and MAX_HISTORY_SIZE.
    // It is a sub-range of mAltHistory and mDistHistory, which stay allocated
    // at MAX_HISTORY_SIZE for the lifetime of the app.
    private var mHistorySize as Number;

    // Most recent computed values, written in compute() and read in onUpdate().
    // Pace is in seconds per whichever distance unit the user configured (km or
    // mile, see mUnitDistanceMeters). The GAP calculation is identical either
    // way, because the Minetti formula works on a RATIO of energy costs rather
    // than on any fixed unit.
    private var mSmoothedGradePercent as Float;
    private var mGapPaceSecPerUnit as Float;

    // Current pace and heart rate from the last compute(), kept as fields
    // because updateQuadrant() needs them whichever quadrant the user
    // configured.
    private var mCurrentPaceSecPerUnit as Float;
    private var mHasValidPace as Boolean;
    private var mHeartRate as Number?;

    // Becomes true only after the FIRST GAP computed from a valid pace. While
    // it is false nothing is written to the FIT file: writing 0.0 while
    // standing still at the start would record a zero as though it were real
    // data, putting a spike in the Garmin Connect graph and skewing the
    // activity averages.
    private var mHasValidGap as Boolean;

    // info.timerTime (in milliseconds) at the last compute(), used to derive
    // the engine's real integration step. It is -1 until the first sample.
    //
    // Why timerTime rather than "one second per call": timerTime does NOT
    // advance while the activity timer is paused, whereas compute() keeps being
    // called. Using it as the model's clock means a stop at an aid station
    // neither drains anaerobic reserve nor accumulates work, which is exactly
    // the physiologically correct behaviour.
    private var mLastTimerTimeMs as Number;

    // Counter for the periodic re-check of the calibration.
    private var mSecondsSinceCalibrationCheck as Number;

    // Reference distance (in metres) for turning speed into pace: 1000 m on
    // metric, 1609.344 m (one mile) on imperial. Read once in initialize() from
    // the device's system settings, not the app's: it is the same choice the
    // user already made for every other Garmin field.
    private var mUnitDistanceMeters as Float;

    // --- Configuration and state of the 4 quadrants --------------------
    // Parallel arrays, all of length QUADRANT_COUNT, allocated once. The index
    // is the position on screen:
    //   0 = top left      1 = top right
    //   2 = bottom left   3 = bottom right
    private var mQuadSource as Array<Number>;   // which quantity to show
    private var mQuadLabel as Array<String>;    // label, already loaded
    private var mQuadValue as Array<String>;    // value, already formatted
    private var mQuadLevel as Array<Number>;    // alert level

    // True when the screen is round or semi-round (Fenix 7 and FR955/965 all
    // are). It adds an extra safety margin when drawing, because towards the
    // edge of a round screen the horizontal and vertical space available
    // narrows compared with the centre. Read once in initialize(), never in
    // onUpdate().
    private var mIsRoundScreen as Boolean;

    // Candidate numeric fonts for the values, largest first. onUpdate()
    // measures the real width of the widest text across the 4 quadrants and
    // picks the largest font that fits the space available, so the numbers are
    // always as legible as possible WITHOUT ever spilling from one quadrant
    // into the next, on any device. The array is allocated once, here.
    private var mValueFontCandidates as Array<Graphics.FontType>;

    // Drawing values shared across the 4 quadrants, recomputed once at the top
    // of each onUpdate() and then read by drawQuadrant() as instance variables
    // rather than passed as parameters. Necessary because older devices (Fenix
    // 6, Forerunner 945, MARQ among them) run a Monkey C VM that limits
    // functions to a MAXIMUM OF 9 ARGUMENTS: passing all of these to
    // drawQuadrant() on every call, as you would in a modern language without
    // that constraint, exceeded the limit and would not compile for them.
    private var mDrawLabelFont as Graphics.FontType;
    private var mDrawValueFont as Graphics.FontType;
    private var mDrawLabelHeight as Number;
    private var mDrawValueHeight as Number;
    private var mDrawGap as Number;
    private var mDrawLabelColor as Graphics.ColorType;
    private var mDrawBackgroundColor as Graphics.ColorType;

    // --- Cache of the font choice ------------------------------------
    // Measuring 4 strings against 3 candidate fonts costs up to 12
    // getTextWidthInPixels() calls per redraw. The strings change at most once
    // a second, in compute(), while onUpdate() can run far more often, so
    // redoing the measurement every frame is wasted work, and expensive on the
    // devices with only 32KB for data fields (base Fenix 6, FR935, first
    // generation Enduro). It is therefore recomputed only when something that
    // genuinely affects the result changes: the strings to draw, or the screen
    // dimensions.
    private var mLayoutDirty as Boolean;
    private var mCachedValueFont as Graphics.FontType;
    private var mCachedLayoutWidth as Number;
    private var mCachedLayoutHeight as Number;

    // ------------------------------------------------------------------
    // CONSTRUCTOR
    // ------------------------------------------------------------------

    function initialize() {
        DataField.initialize();

        // Read the units BEFORE creating the FIT fields: they are needed both
        // for the ":units" labels and for every pace conversion in compute().
        if (System.getDeviceSettings().paceUnits == System.UNIT_STATUTE) {
            mUnitDistanceMeters = METERS_PER_MILE;
        } else {
            mUnitDistanceMeters = METERS_PER_KILOMETER;
        }
        var paceUnitLabel = (mUnitDistanceMeters == METERS_PER_MILE) ? "min/mi" : "min/km";

        // --- Creating the custom FIT fields ---------------------------
        // MESG_TYPE_RECORD = one value per second, so Garmin Connect and Strava
        // can draw a graph from it.
        // MESG_TYPE_SESSION = a single value for the whole activity, which
        // suits the athlete parameters, since those do not change second by
        // second.
        mGapField = makeField(
            WatchUi.loadResource(Rez.Strings.GapFieldLabel) as String,
            FIT_FIELD_GAP, FitContributor.DATA_TYPE_FLOAT,
            FitContributor.MESG_TYPE_RECORD, paceUnitLabel);

        mReserveField = makeField(
            WatchUi.loadResource(Rez.Strings.ReserveFieldLabel) as String,
            FIT_FIELD_RESERVE, FitContributor.DATA_TYPE_UINT8,
            FitContributor.MESG_TYPE_RECORD, "%");

        mSustainField = makeField(
            WatchUi.loadResource(Rez.Strings.SustainFieldLabel) as String,
            FIT_FIELD_SUSTAIN, FitContributor.DATA_TYPE_FLOAT,
            FitContributor.MESG_TYPE_RECORD, paceUnitLabel);

        mWorkField = makeField(
            WatchUi.loadResource(Rez.Strings.WorkFieldLabel) as String,
            FIT_FIELD_WORK, FitContributor.DATA_TYPE_FLOAT,
            FitContributor.MESG_TYPE_RECORD, "kJ/kg");

        mCsField = makeField(
            WatchUi.loadResource(Rez.Strings.CsFieldLabel) as String,
            FIT_FIELD_CS, FitContributor.DATA_TYPE_FLOAT,
            FitContributor.MESG_TYPE_SESSION, "m/s");

        mDPrimeField = makeField(
            WatchUi.loadResource(Rez.Strings.DPrimeFieldLabel) as String,
            FIT_FIELD_DPRIME, FitContributor.DATA_TYPE_FLOAT,
            FitContributor.MESG_TYPE_SESSION, "m");

        mCarbField = makeField(
            WatchUi.loadResource(Rez.Strings.CarbFieldLabel) as String,
            FIT_FIELD_CARB, FitContributor.DATA_TYPE_UINT16,
            FitContributor.MESG_TYPE_RECORD, "g");

        mEccentricField = makeField(
            WatchUi.loadResource(Rez.Strings.EccentricFieldLabel) as String,
            FIT_FIELD_ECCENTRIC, FitContributor.DATA_TYPE_UINT16,
            FitContributor.MESG_TYPE_RECORD, "m");

        // --- Fixed-size arrays for the smoothing ----------------------
        // Always allocated at the MAXIMUM possible size. The window actually in
        // use (mHistorySize) can be shorter and is read from the user settings
        // straight after, but the array itself is never reallocated while the
        // app is running.
        mAltHistory = new Array<Float>[MAX_HISTORY_SIZE];
        mDistHistory = new Array<Float>[MAX_HISTORY_SIZE];
        for (var i = 0; i < MAX_HISTORY_SIZE; i++) {
            mAltHistory[i] = 0.0;
            mDistHistory[i] = 0.0;
        }
        mHistIndex = 0;
        mHistCount = 0;
        mHistorySize = DEFAULT_HISTORY_SIZE;

        mSmoothedGradePercent = 0.0;
        mGapPaceSecPerUnit = 0.0;
        mCurrentPaceSecPerUnit = 0.0;
        mHasValidPace = false;
        mHeartRate = null;
        mHasValidGap = false;
        mLastTimerTimeMs = -1;
        mSecondsSinceCalibrationCheck = 0;

        // Models and calibration. The calibration loads the personal bests
        // saved by previous activities on its own.
        mEngine = new EnduranceEngine();
        mCalibration = new SpeedCalibration();
        mFuel = new FuelModel();
        mEccentric = new EccentricModel();

        mBindingTtfSec = null;
        mBindingKind = BIND_NONE;

        mLabelLimit = WatchUi.loadResource(Rez.Strings.LabelTtf) as String;
        mLabelAnaerobic = WatchUi.loadResource(Rez.Strings.LabelAnaerobic) as String;
        mLabelCarb = WatchUi.loadResource(Rez.Strings.LabelCarb) as String;
        mLabelQuads = WatchUi.loadResource(Rez.Strings.LabelQuads) as String;

        // Quadrant arrays: allocated here once, filled by applySettings()
        // along with every other user setting.
        mQuadSource = new Array<Number>[QUADRANT_COUNT];
        mQuadLabel = new Array<String>[QUADRANT_COUNT];
        mQuadValue = new Array<String>[QUADRANT_COUNT];
        mQuadLevel = new Array<Number>[QUADRANT_COUNT];
        for (var q = 0; q < QUADRANT_COUNT; q++) {
            mQuadSource[q] = q;
            mQuadLabel[q] = "";
            mQuadValue[q] = "--";
            mQuadLevel[q] = LEVEL_NORMAL;
        }

        // Screen shape is detected once. Every target device is round or
        // semi-round, but the code stays general in case the app is extended to
        // rectangular screens.
        var screenShape = System.getDeviceSettings().screenShape;
        mIsRoundScreen = (screenShape == System.SCREEN_SHAPE_ROUND)
            || (screenShape == System.SCREEN_SHAPE_SEMI_ROUND);

        // Candidate fonts for the values, largest first.
        //
        // CAREFUL when changing this list: the numeric fonts (FONT_NUMBER_*)
        // carry a reduced glyph set, historically digits, ':', '.' and '-'
        // only. The quadrant strings also use '%' and '+', which on some
        // firmware may not be present in a numeric font. FONT_NUMBER_MILD has
        // been checked visually on Fenix 7, Forerunner 170 and Enduro 3 (both
        // MIP and AMOLED) and renders both correctly; the fonts after it in the
        // list are text fonts, which carry the full set anyway. Before adding a
        // larger numeric font (FONT_NUMBER_MEDIUM or HOT, say), redo that same
        // visual check.
        mValueFontCandidates = [
            Graphics.FONT_NUMBER_MILD,
            Graphics.FONT_LARGE,
            Graphics.FONT_MEDIUM
        ] as Array<Graphics.FontType>;

        // Defaults for the shared drawing fields. Every onUpdate() overwrites
        // them before use, but they still have to be initialised here because
        // they are non-nullable typed members.
        mDrawLabelFont = Graphics.FONT_XTINY;
        mDrawValueFont = Graphics.FONT_NUMBER_MILD;
        mDrawLabelHeight = 0;
        mDrawValueHeight = 0;
        mDrawGap = 0;
        mDrawLabelColor = Graphics.COLOR_LT_GRAY;
        mDrawBackgroundColor = Graphics.COLOR_BLACK;

        // Cache of the font choice. It starts dirty so that the first
        // onUpdate() computes the real layout instead of using the defaults.
        mLayoutDirty = true;
        mCachedValueFont = Graphics.FONT_NUMBER_MILD;
        mCachedLayoutWidth = 0;
        mCachedLayoutHeight = 0;

        // Load every user setting and configure the engine.
        applySettings();
    }

    // ------------------------------------------------------------------
    // Creates a custom FIT field without being able to crash the app.
    //
    // Takes 5 arguments, well under the limit of 9 the Monkey C VM imposes on
    // older devices.
    // ------------------------------------------------------------------
    private function makeField(
        label as String,
        fieldId as Number,
        dataType as FitContributor.DataType,
        mesgType as FitContributor.MessageType,
        units as String
    ) as FitContributor.Field? {
        try {
            return createField(
                label, fieldId, dataType,
                { :mesgType => mesgType, :units => units }
            ) as FitContributor.Field;
        } catch (ex) {
            // No FIT recording for this field. The app stays fully usable as
            // an on-screen display.
            return null;
        }
    }

    // ------------------------------------------------------------------
    // Reads a numeric property from the user settings, always clamped into a
    // valid range. getValue() throws when the key does not exist, for instance
    // if it were renamed in properties.xml without updating the code, so the
    // exception is caught rather than crashing the app at startup.
    //
    // Takes 4 arguments, under the limit of 9 on older devices.
    // ------------------------------------------------------------------
    private function readNumberSetting(
        key as String,
        fallback as Number,
        minValue as Number,
        maxValue as Number
    ) as Number {
        var raw = null;
        try {
            raw = Properties.getValue(key);
        } catch (ex) {
            return fallback;
        }

        if (raw == null || !(raw instanceof Number)) {
            return fallback;
        }

        var value = raw as Number;
        if (value < minValue) {
            return minValue;
        }
        if (value > maxValue) {
            return maxValue;
        }
        return value;
    }

    // ------------------------------------------------------------------
    // applySettings(): reloads EVERY user setting and reconfigures smoothing,
    // quadrants and the physiological engine accordingly.
    //
    // CAREFUL: this method is NOT a system callback. onSettingsChanged()
    // belongs to Application.AppBase, not to WatchUi.DataField; defining it
    // here would do nothing, because the system would never call it. So
    // UltraTrailDashboardApp receives the event and invokes this method on the
    // View.
    // ------------------------------------------------------------------
    function applySettings() as Void {
        // --- Grade smoothing window -----------------------------------
        var newHistorySize = readNumberSetting(
            "SmoothingWindowSeconds", DEFAULT_HISTORY_SIZE,
            MIN_HISTORY_SIZE, MAX_HISTORY_SIZE);

        // The history is cleared only when the window has GENUINELY changed.
        // applySettings() also runs for changes that have nothing to do with it
        // (a different quadrant, say), and throwing the buffer away mid-race
        // would force the grade to rebuild from nothing for a handful of
        // seconds, for no reason.
        if (newHistorySize != mHistorySize) {
            mHistorySize = newHistorySize;
            resetGradeHistory();
        }

        // --- Sources of the 4 quadrants -------------------------------
        loadQuadrantSetting(0, "Quadrant1", SRC_PACE);
        loadQuadrantSetting(1, "Quadrant2", SRC_HR);
        loadQuadrantSetting(2, "Quadrant3", SRC_GRADE);
        loadQuadrantSetting(3, "Quadrant4", SRC_GAP);

        // --- Calibration reset on request -----------------------------
        // The setting is a switch that re-arms itself: as soon as it is seen
        // set, the bests are cleared and it is put back to false. The user does
        // not have to remember to turn it off, and the next activity does not
        // start with the calibration cleared by accident.
        var resetRequested = false;
        try {
            var raw = Properties.getValue("ResetCalibration");
            resetRequested = (raw != null) && (raw instanceof Boolean) && (raw as Boolean);
        } catch (ex) {
            resetRequested = false;
        }
        if (resetRequested) {
            mCalibration.clear();
            try {
                Properties.setValue("ResetCalibration", false);
            } catch (ex) {
                // If the switch cannot be re-armed, the worst that happens is a
                // second reset at the next start.
            }
        }

        // --- Athlete parameters for the engine ------------------------
        configureModels();
    }

    // ------------------------------------------------------------------
    // Reads the source configured for a quadrant and loads its label. A value
    // out of range, from a future version's settings or a corrupt config file,
    // falls back to the default rather than taking the app down.
    // ------------------------------------------------------------------
    private function loadQuadrantSetting(index as Number, key as String, fallback as Number) as Void {
        var source = readNumberSetting(key, fallback, 0, SRC_COUNT - 1);
        mQuadSource[index] = source;
        mQuadLabel[index] = loadSourceLabel(source);
        mQuadValue[index] = "--";
        mQuadLevel[index] = LEVEL_NORMAL;
        mLayoutDirty = true;
    }

    // ------------------------------------------------------------------
    // The short label shown above a quadrant's value. Loaded from resources
    // ONLY here, at startup or when settings change, never in onUpdate():
    // loadResource() allocates a new string every time.
    // ------------------------------------------------------------------
    private function loadSourceLabel(source as Number) as String {
        switch (source) {
            case SRC_HR:
                return WatchUi.loadResource(Rez.Strings.LabelHeartRate) as String;
            case SRC_GRADE:
                return WatchUi.loadResource(Rez.Strings.LabelGrade) as String;
            case SRC_GAP:
                return WatchUi.loadResource(Rez.Strings.LabelGap) as String;
            case SRC_RESERVE:
                return WatchUi.loadResource(Rez.Strings.LabelReserve) as String;
            case SRC_SUSTAIN:
                return WatchUi.loadResource(Rez.Strings.LabelSustain) as String;
            // The next three are already in memory: the LIMIT field needs them
            // too, and it changes label every second according to the binding
            // constraint, so it cannot afford a loadResource() per second. What
            // is returned is the reference, not a copy.
            case SRC_TTF:
                return mLabelLimit;
            case SRC_CARB:
                return mLabelCarb;
            case SRC_QUADS:
                return mLabelQuads;
            default:
                return WatchUi.loadResource(Rez.Strings.LabelPace) as String;
        }
    }

    // ------------------------------------------------------------------
    // Reads every athlete parameter from the settings and distributes them to
    // the three models: mass and intake plan to the carbohydrate balance,
    // descent capacity to the eccentric model, critical speed and durability to
    // the aerobic engine.
    //
    // ORDER OF PRECEDENCE for critical speed:
    //   1. the automatic calibration, once it has collected enough data
    //   2. the threshold pace the user typed in, if there is one
    //   3. neither: the engine declares itself not ready, and the quadrants
    //      that depend on it show "--"
    //
    // Calibration comes before the typed value because it comes from the
    // athlete's real performances on this terrain, whereas a typed threshold
    // pace is almost always a memory of a road race.
    // ------------------------------------------------------------------
    private function configureModels() as Void {
        // --- Carbohydrate balance --------------------------------------
        // Body mass is a setting rather than a read of the Garmin user profile
        // for one specific reason: reading the profile would require the
        // "UserProfile" permission, which the app does not ask for today.
        // Adding it to an already published app changes the permission list
        // shown in the store, to an audience that has been promised nothing
        // leaves the watch. One more numeric field costs less.
        var massKg = readNumberSetting("BodyMassKg", 70, 35, 150);
        var carbIntake = readNumberSetting("CarbIntakeGramsPerHour", 60, 0, 120);
        mFuel.setAthlete(massKg.toFloat(), carbIntake.toFloat());

        // --- Descent capacity -------------------------------------------
        var descentCapacity = readNumberSetting("DescentCapacityMeters", 3000, 500, 15000);
        mEccentric.setCapacity(descentCapacity.toFloat());

        // --- Aerobic engine ---------------------------------------------
        // Durability factor: percentage of sustainable speed lost per 100 kJ/kg
        // of accumulated work. 0 turns the decay off.
        var durabilityPercent = readNumberSetting("DurabilityPercent", 8, 0, 25);
        var durabilityFactor = durabilityPercent / 100.0;

        if (mCalibration.isValid()) {
            mEngine.setAthlete(
                mCalibration.getCriticalSpeed(),
                mCalibration.getDPrime(),
                durabilityFactor);
            return;
        }

        // Threshold pace as typed by the user, in seconds per the device's
        // distance unit (seconds/km on metric, seconds/mile on imperial).
        // 0 means "not set".
        var thresholdPace = readNumberSetting("ThresholdPaceSeconds", 0, 0, 1200);
        if (thresholdPace > 0) {
            // setAthlete() rejects implausible speeds on its own, so an absurd
            // value typed by mistake does not produce a wrong model. It
            // produces no model, and the quadrants stay at "--".
            mEngine.setAthlete(
                mUnitDistanceMeters / thresholdPace,
                mEngine.defaultDPrime(),
                durabilityFactor);
            return;
        }

        // No source available: the engine is not ready.
        mEngine.setAthlete(0.0, mEngine.defaultDPrime(), durabilityFactor);
    }

    // ------------------------------------------------------------------
    // onTimerStop(): DataField callback, fired when the user stops the activity
    // timer. It is the right moment to save the calibration's personal bests:
    // the activity is over, and writing to flash here costs once rather than
    // every second.
    // ------------------------------------------------------------------
    function onTimerStop() as Void {
        mCalibration.save();
    }

    // ------------------------------------------------------------------
    // Safety net for saving the bests, called from
    // UltraTrailDashboardApp.onStop(), that is, when the app closes.
    //
    // onTimerStop() covers the normal case, where the user stops the timer and
    // saves the activity, but not every case: if the activity is closed from a
    // menu, or the system terminates the app because the battery is going, that
    // callback may never arrive. save() does nothing when there is nothing new
    // to write, so calling it twice costs nothing.
    // ------------------------------------------------------------------
    function persistCalibration() as Void {
        mCalibration.save();
    }

    // ------------------------------------------------------------------
    // onTimerReset(): DataField callback, fired when the user resets the
    // activity to start a new one.
    //
    // Clearing the history here is essential: info.elapsedDistance restarts
    // from zero while the buffer would still hold the cumulative distances of
    // the previous activity (3000 m, say). The delta would come out NEGATIVE
    // and would never exceed MIN_DISTANCE_FOR_GRADE, leaving the grade frozen
    // at the last value of the previous run until the buffer refilled, which
    // takes up to 30 seconds.
    //
    // The same goes for the engine and the calibration: accumulated work and
    // anaerobic reserve belong to a SINGLE activity and have to be cleared,
    // while the calibration's personal bests survive, since they are the
    // athlete's long-term memory rather than the run's.
    // ------------------------------------------------------------------
    function onTimerReset() as Void {
        resetGradeHistory();

        mSmoothedGradePercent = 0.0;
        mGapPaceSecPerUnit = 0.0;
        mCurrentPaceSecPerUnit = 0.0;
        mHasValidPace = false;
        mHeartRate = null;
        mHasValidGap = false;
        mLastTimerTimeMs = -1;
        mSecondsSinceCalibrationCheck = 0;

        // Save the bests before restarting: if the user resets without ever
        // stopping the timer, they would otherwise be lost.
        mCalibration.save();
        mCalibration.resetSession();
        mEngine.reset();
        mFuel.reset();
        mEccentric.reset();

        mBindingTtfSec = null;
        mBindingKind = BIND_NONE;

        // The calibration may have become valid during the activity that just
        // ended, so apply it before a new one starts.
        configureModels();

        for (var q = 0; q < QUADRANT_COUNT; q++) {
            mQuadValue[q] = "--";
            mQuadLevel[q] = LEVEL_NORMAL;
        }
        mLayoutDirty = true;
    }

    // ------------------------------------------------------------------
    // Empties the altitude and distance ring buffer. The arrays are not
    // reallocated; they stay the fixed ones created in initialize(). Clearing
    // the index and the counter is enough to restart the window from zero.
    // ------------------------------------------------------------------
    private function resetGradeHistory() as Void {
        mHistIndex = 0;
        mHistCount = 0;
    }

    // ------------------------------------------------------------------
    // compute(info): called once a second by the system.
    // ------------------------------------------------------------------
    function compute(info as Activity.Info) as Numeric or Toybox.Time.Duration or String or Null {

        // --- 1) Real integration step ----------------------------------
        // See the comment on mLastTimerTimeMs: the clock is the activity
        // timer's, not a count of calls, so pauses are not integrated into the
        // model.
        var dt = 0.0;
        var timerTime = info.timerTime;
        if (timerTime != null) {
            if (mLastTimerTimeMs >= 0 && timerTime > mLastTimerTimeMs) {
                dt = (timerTime - mLastTimerTimeMs) / 1000.0;
                if (dt > MAX_DT_SEC) {
                    dt = MAX_DT_SEC;
                }
            }
            mLastTimerTimeMs = timerTime;
        }

        // --- 2) Updating the altitude and distance history -------------
        // The ring buffer is updated only when the device supplies both the
        // altitude (barometric altimeter) and the distance covered.
        //
        // Activity.Info fields are copied into locals BEFORE use: a "!= null"
        // check on a property does not guarantee the next read returns the same
        // value, so reading twice risks a null dereference. With a local copy,
        // the value checked is exactly the value used.
        var altitude = info.altitude;
        var elapsedDistance = info.elapsedDistance;
        if (altitude != null && elapsedDistance != null) {
            mAltHistory[mHistIndex] = altitude;
            mDistHistory[mHistIndex] = elapsedDistance;

            // Advance the ring index. It wraps after the last cell of the
            // CONFIGURED window, not of the whole array: only the first
            // mHistorySize elements of mAltHistory and mDistHistory are used.
            mHistIndex = (mHistIndex + 1) % mHistorySize;
            if (mHistCount < mHistorySize) {
                mHistCount++;
            }
        }

        // --- 3) Smoothed grade, as a moving average --------------------
        // Compare the oldest sample in the window with the newest: the average
        // grade over the whole window is far steadier than Garmin's own
        // instantaneous grade.
        if (mHistCount >= 2) {
            // When the buffer is full, the oldest sample is exactly the cell
            // about to be overwritten (mHistIndex). When it is not yet full,
            // the oldest sample is at [0].
            var oldestIndex = (mHistCount == mHistorySize) ? mHistIndex : 0;

            // The last sample written is the one just before mHistIndex.
            var newestIndex = (mHistIndex - 1 + mHistorySize) % mHistorySize;

            var deltaAlt = mAltHistory[newestIndex] - mAltHistory[oldestIndex];
            var deltaDist = mDistHistory[newestIndex] - mDistHistory[oldestIndex];

            // Only compute a new grade once we have moved far enough for the
            // number to mean something. It avoids dividing by something close
            // to zero, for instance standing still at a crossing or an aid
            // station.
            if (deltaDist > MIN_DISTANCE_FOR_GRADE) {
                mSmoothedGradePercent = (deltaAlt / deltaDist) * 100.0;
            }
            // Otherwise mSmoothedGradePercent keeps its last valid value, so
            // there is no jump to zero when you stop.
        }

        // --- 4) Current pace, from instantaneous speed -----------------
        // mUnitDistanceMeters is 1000 (km) or 1609.344 (mile) depending on the
        // units the user chose on the device. The rest of the calculation, GAP
        // and formatting included, never needs to know which unit is in use: it
        // always works in "seconds per unit".
        // Here too the speed is copied into a local before the null check:
        // without the copy the division would use a second read of the
        // property, which the check does not cover.
        mHasValidPace = false;
        var currentSpeed = info.currentSpeed;
        if (currentSpeed != null && currentSpeed > 0.1) {
            mCurrentPaceSecPerUnit = mUnitDistanceMeters / currentSpeed;
            mHasValidPace = true;
        }

        var gradeFraction = mSmoothedGradePercent / 100.0;

        // --- 5) GAP (Grade Adjusted Pace) ------------------------------
        // The GAP that is DISPLAYED uses pure Minetti, with no attenuation. It
        // is an explicit choice to stay faithful to the published model, even
        // when the number comes out aggressive: on a steep descent GAP can
        // approach twice the real pace.
        //
        // The formula works on a RATIO of energy costs, so the result is
        // correct whichever distance unit the incoming pace uses.
        if (mHasValidPace) {
            mGapPaceSecPerUnit = mCurrentPaceSecPerUnit / MinettiCost.ratio(gradeFraction);
            mHasValidGap = true;
        }

        // --- 6) Updating the physiological engine ----------------------
        // The ENGINE, unlike the displayed GAP, uses the ratio with the uphill
        // ceiling (MinettiCost.modelRatio). Without it, every steep wall taken
        // on foot would read as an effort enormously above threshold. See the
        // long comment in MinettiCost.mc. The on-screen value stays pure
        // Minetti regardless: the two are independent.
        // The condition is "speed AVAILABLE", not "speed above zero": standing
        // at an aid station with the timer running is recovery in every
        // meaningful sense, and the model should be recharging the reserve.
        // Skipping the update at zero speed would freeze the balance during
        // precisely the minutes the athlete recovers most. Doing nothing when
        // currentSpeed is null is still correct, though: with no GPS fix yet we
        // do not know they are stationary, we simply do not know.
        if (dt > 0.0 && currentSpeed != null) {
            var modelSpeed = currentSpeed * MinettiCost.modelRatio(gradeFraction);
            mEngine.update(modelSpeed, dt);
            mCalibration.update(modelSpeed, dt);

            // The carbohydrate balance depends on intensity RELATIVE to
            // sustainable speed. Without a critical speed there is no way to
            // know what fraction of the energy comes from sugar, so the model
            // stays put instead of guessing. Consumption reads straight off the
            // flat-equivalent speed, because by construction C(i)*v = C(0)*vGap.
            var sustainable = mEngine.getSustainableSpeed();
            if (mEngine.hasModel() && sustainable > 0.0) {
                mFuel.update(
                    MinettiCost.FLAT_COST * modelSpeed,
                    modelSpeed / sustainable,
                    dt);
            }

            // Descent damage uses the REAL speed over the ground, not the flat
            // equivalent: what counts here is the movement of the body and the
            // force the quadriceps have to absorb, not the aerobic cost. It is
            // also the only one of the three models that needs no calibration
            // at all: it works from the first second.
            mEccentric.update(currentSpeed, gradeFraction, dt);

            // If the engine started without a model, meaning no saved bests
            // and no threshold pace set, check now and again whether the
            // calibration has become usable in the meantime.
            if (!mEngine.hasModel()) {
                mSecondsSinceCalibrationCheck += 1;
                if (mSecondsSinceCalibrationCheck >= CALIBRATION_CHECK_PERIOD_SEC) {
                    mSecondsSinceCalibrationCheck = 0;
                    if (mCalibration.isValid()) {
                        configureModels();
                    }
                }
            }
        }

        // --- 7) Writing the values into the FIT file -------------------
        // Nothing is written until at least one valid GAP has been computed.
        // Before that the value would be 0.0, which would be recorded as real
        // data, a spike to zero in the graph and skewed averages, rather than
        // as "not available". Standing still with the timer running, the field
        // holds its last valid value: there is no way to write an "invalid"
        // value through setData(), which accepts only the type declared in
        // createField() and throws otherwise.
        writeFitFields();

        // --- 8) The binding constraint ----------------------------------
        updateBindingConstraint();

        // --- 9) Pre-formatting the strings for drawing -----------------
        // The expensive formatting work happens here, so that onUpdate() has
        // nothing to do but draw strings that are already prepared.
        mHeartRate = info.currentHeartRate;
        for (var q = 0; q < QUADRANT_COUNT; q++) {
            updateQuadrant(q);
        }

        // The return value is only a fallback, for when the system shows this
        // field in a simple layout such as the summary screen. On the activity
        // screen the custom drawing in onUpdate() always takes precedence. Null
        // is returned until there is a valid GAP, so the system shows "--"
        // rather than a misleading zero.
        if (!mHasValidGap) {
            return null;
        }
        return mGapPaceSecPerUnit / 60.0;
    }

    // ------------------------------------------------------------------
    // Works out which physiological system will give out first, and when.
    //
    // Each model declares its own time to failure, or null when at the current
    // rate it is not heading towards any limit at all: below threshold the
    // anaerobic reserve recharges, uphill the legs do not get worse, and eating
    // enough keeps carbohydrate from falling. The constraint is simply the
    // minimum of whatever is declared.
    //
    // This is the central design choice of the app: the common currency between
    // unlike systems is TIME, not a score. An index that multiplies reserve,
    // glycogen and muscle damage together produces a number that cannot be
    // checked against anything and does not say what to do. A time to failure,
    // by contrast, can be compared at the finish with what actually happened,
    // and the name of the system imposing it maps to one specific action: ease
    // off, eat, or brake less.
    // ------------------------------------------------------------------
    private function updateBindingConstraint() as Void {
        var best = null;
        var kind = BIND_NONE;

        var anaerobic = mEngine.getTimeToFailureSec();
        if (anaerobic != null) {
            best = anaerobic;
            kind = BIND_ANAEROBIC;
        }

        var carb = mFuel.getTimeToDepletionSec();
        if (carb != null && (best == null || carb < best)) {
            best = carb;
            kind = BIND_CARB;
        }

        var quads = mEccentric.getTimeToLimitSec();
        if (quads != null && (best == null || quads < best)) {
            best = quads;
            kind = BIND_QUADS;
        }

        mBindingTtfSec = best;
        mBindingKind = kind;
    }

    // ------------------------------------------------------------------
    // The label for the LIMIT field: the name of the system doing the binding.
    // Returns a reference to a string already in memory, so it allocates
    // nothing even when called once a second.
    // ------------------------------------------------------------------
    private function bindingLabel() as String {
        if (mBindingKind == BIND_ANAEROBIC) {
            return mLabelAnaerobic;
        }
        if (mBindingKind == BIND_CARB) {
            return mLabelCarb;
        }
        if (mBindingKind == BIND_QUADS) {
            return mLabelQuads;
        }
        return mLabelLimit;
    }

    // ------------------------------------------------------------------
    // Writes the model state into the FIT file. Called from compute(), once a
    // second.
    //
    // Why the STATE is recorded rather than the displayed values: the on-screen
    // fields can be derived from the state, but not the other way round. Saving
    // sustainable speed, reserve and accumulated work is what makes it possible
    // afterwards to compare what the model predicted against what actually
    // happened, and to correct the athlete's parameters accordingly. A purely
    // cosmetic field would not allow that.
    // ------------------------------------------------------------------
    private function writeFitFields() as Void {
        var gapField = mGapField;
        if (gapField != null && mHasValidGap) {
            gapField.setData(mGapPaceSecPerUnit / 60.0);
        }

        // Eccentric load is always recorded: it is the only model that does
        // not depend on critical speed, so it is available even on the very
        // first run, when the calibration has no data yet.
        var eccentricField = mEccentricField;
        if (eccentricField != null) {
            eccentricField.setData(Math.round(mEccentric.getEquivalentMeters()).toNumber());
        }

        if (!mEngine.hasModel()) {
            return;
        }

        var carbField = mCarbField;
        if (carbField != null) {
            carbField.setData(Math.round(mFuel.getRemainingGrams()).toNumber());
        }

        var reserveField = mReserveField;
        if (reserveField != null) {
            // DATA_TYPE_UINT8 takes integers 0 to 255 only. A percentage fits
            // comfortably, and costs one byte per record instead of four.
            reserveField.setData(Math.round(mEngine.getReservePercent()).toNumber());
        }

        var sustainField = mSustainField;
        if (sustainField != null) {
            var sustainSpeed = mEngine.getSustainableSpeed();
            if (sustainSpeed > 0.0) {
                sustainField.setData((mUnitDistanceMeters / sustainSpeed) / 60.0);
            }
        }

        var workField = mWorkField;
        if (workField != null) {
            workField.setData(mEngine.getWorkKjPerKg());
        }

        // The two session fields describe the athlete rather than the moment.
        // They are rewritten every cycle anyway, because setData() on a
        // MESG_TYPE_SESSION field only overwrites the value in memory, which is
        // saved once when the session closes.
        var csField = mCsField;
        if (csField != null) {
            csField.setData(mEngine.getBaseCriticalSpeed());
        }

        var dPrimeField = mDPrimeField;
        if (dPrimeField != null) {
            dPrimeField.setData(mEngine.getDPrime());
        }
    }

    // ------------------------------------------------------------------
    // Updates the text and the alert level of one quadrant, according to the
    // source the user assigned to it.
    //
    // The value goes through setQuadValue(), which marks the layout dirty ONLY
    // when the string has genuinely changed. That is what lets onUpdate() skip
    // the font measurements when nothing needs them.
    // ------------------------------------------------------------------
    private function updateQuadrant(index as Number) as Void {
        var source = mQuadSource[index];

        switch (source) {
            case SRC_HR:
                var hr = mHeartRate;
                setQuadValue(index, (hr != null) ? hr.toString() : "---");
                mQuadLevel[index] = LEVEL_NORMAL;
                break;

            case SRC_GRADE:
                setQuadValue(index, formatGrade(mSmoothedGradePercent));
                mQuadLevel[index] = levelAscending(
                    mSmoothedGradePercent.abs(),
                    GRADE_WARNING_THRESHOLD, GRADE_DANGER_THRESHOLD,
                    GRADE_HYSTERESIS, mQuadLevel[index]);
                break;

            case SRC_GAP:
                setQuadValue(index, mHasValidPace ? formatPace(mGapPaceSecPerUnit) : "--:--");
                mQuadLevel[index] = LEVEL_NORMAL;
                break;

            case SRC_RESERVE:
                if (mEngine.hasModel()) {
                    var reserve = mEngine.getReservePercent();
                    setQuadValue(index, Lang.format("$1$%", [reserve.format("%d")]));
                    mQuadLevel[index] = levelDescending(
                        reserve,
                        RESERVE_WARNING_THRESHOLD, RESERVE_DANGER_THRESHOLD,
                        RESERVE_HYSTERESIS, mQuadLevel[index]);
                } else {
                    setQuadValue(index, "--");
                    mQuadLevel[index] = LEVEL_NORMAL;
                }
                break;

            case SRC_TTF:
                // This quadrant changes its LABEL as well as its value: it
                // shows how long until the first failure and the name of the
                // system imposing it. It is the only part of the app that
                // answers "what should I do now" rather than "what is this
                // quantity worth".
                var ttf = mBindingTtfSec;
                if (ttf != null) {
                    setQuadValue(index, formatDuration(ttf));
                    mQuadLabel[index] = bindingLabel();
                    if (mBindingKind == BIND_ANAEROBIC) {
                        mQuadLevel[index] = levelDescending(
                            ttf,
                            ANAEROBIC_WARNING_SEC, ANAEROBIC_DANGER_SEC,
                            ANAEROBIC_HYSTERESIS_SEC, mQuadLevel[index]);
                    } else {
                        mQuadLevel[index] = levelDescending(
                            ttf,
                            SLOW_WARNING_SEC, SLOW_DANGER_SEC,
                            SLOW_HYSTERESIS_SEC, mQuadLevel[index]);
                    }
                } else {
                    // No system is approaching its limit: below threshold the
                    // reserve recharges, uphill the legs do not get worse, and
                    // intake covers consumption. Showing a number here would
                    // mean making one up.
                    setQuadValue(index, "--:--");
                    mQuadLabel[index] = mLabelLimit;
                    mQuadLevel[index] = LEVEL_NORMAL;
                }
                break;

            case SRC_CARB:
                // Depends on critical speed, because the fraction of energy
                // coming from sugar is derived from intensity relative to
                // threshold. Without calibration, "--".
                if (mEngine.hasModel()) {
                    var carbLeft = mFuel.getRemainingPercent();
                    setQuadValue(index, Lang.format("$1$%", [carbLeft.format("%d")]));
                    mQuadLevel[index] = levelDescending(
                        carbLeft,
                        FUEL_WARNING_THRESHOLD, FUEL_DANGER_THRESHOLD,
                        FUEL_HYSTERESIS, mQuadLevel[index]);
                } else {
                    setQuadValue(index, "--");
                    mQuadLevel[index] = LEVEL_NORMAL;
                }
                break;

            case SRC_QUADS:
                // No dependency on the calibration: it works straight away.
                var quadsLeft = mEccentric.getRemainingPercent();
                setQuadValue(index, Lang.format("$1$%", [quadsLeft.format("%d")]));
                mQuadLevel[index] = levelDescending(
                    quadsLeft,
                    FUEL_WARNING_THRESHOLD, FUEL_DANGER_THRESHOLD,
                    FUEL_HYSTERESIS, mQuadLevel[index]);
                break;

            case SRC_SUSTAIN:
                var sustainSpeed = mEngine.getSustainableSpeed();
                if (mEngine.hasModel() && sustainSpeed > 0.0) {
                    setQuadValue(index, formatPace(mUnitDistanceMeters / sustainSpeed));
                } else {
                    setQuadValue(index, "--:--");
                }
                mQuadLevel[index] = LEVEL_NORMAL;
                break;

            default:
                setQuadValue(index, mHasValidPace ? formatPace(mCurrentPaceSecPerUnit) : "--:--");
                mQuadLevel[index] = LEVEL_NORMAL;
                break;
        }
    }

    // ------------------------------------------------------------------
    // Updates a quadrant's text only when it has actually changed, and marks
    // the layout dirty when it has.
    // ------------------------------------------------------------------
    private function setQuadValue(index as Number, value as String) as Void {
        if (!value.equals(mQuadValue[index])) {
            mQuadValue[index] = value;
            mLayoutDirty = true;
        }
    }

    // ------------------------------------------------------------------
    // Alert level for the cases where LOW values are the critical ones:
    // anaerobic reserve left, time to failure.
    //
    // The hysteresis is not cosmetic. Without it, a value oscillating around a
    // threshold makes the colour flicker several times a second. In a race that
    // is the difference between a field you read at a glance and one the user
    // uninstalls. Coming DOWN in severity requires clearing the threshold by a
    // margin; going up does not, because a worsening should be shown at once.
    //
    // Takes 5 arguments, under the limit of 9 on older devices.
    // ------------------------------------------------------------------
    private function levelDescending(
        value as Float,
        warnAt as Float,
        dangerAt as Float,
        margin as Float,
        current as Number
    ) as Number {
        var level = LEVEL_NORMAL;
        if (value <= dangerAt) {
            level = LEVEL_DANGER;
        } else if (value <= warnAt) {
            level = LEVEL_WARNING;
        }

        if (level < current) {
            if (current == LEVEL_DANGER && value < dangerAt + margin) {
                return LEVEL_DANGER;
            }
            if (current == LEVEL_WARNING && value < warnAt + margin) {
                return LEVEL_WARNING;
            }
        }
        return level;
    }

    // ------------------------------------------------------------------
    // Alert level for the cases where HIGH values are the critical ones: the
    // absolute grade. Same hysteresis, opposite direction.
    // ------------------------------------------------------------------
    private function levelAscending(
        value as Float,
        warnAt as Float,
        dangerAt as Float,
        margin as Float,
        current as Number
    ) as Number {
        var level = LEVEL_NORMAL;
        if (value >= dangerAt) {
            level = LEVEL_DANGER;
        } else if (value >= warnAt) {
            level = LEVEL_WARNING;
        }

        if (level < current) {
            if (current == LEVEL_DANGER && value > dangerAt - margin) {
                return LEVEL_DANGER;
            }
            if (current == LEVEL_WARNING && value > warnAt - margin) {
                return LEVEL_WARNING;
            }
        }
        return level;
    }

    // ------------------------------------------------------------------
    // Turns a pace in seconds per distance unit (km or mile, according to the
    // user settings) into an "M:SS" string. Called only from compute(), once a
    // second, never from onUpdate().
    // ------------------------------------------------------------------
    private function formatPace(paceSecPerUnit as Float) as String {
        if (paceSecPerUnit <= 0.0 or paceSecPerUnit > 5940.0) {
            // Past 99:00, standing still for instance, show a placeholder
            // rather than a meaningless number.
            return "--:--";
        }
        var totalSeconds = Math.round(paceSecPerUnit).toNumber();
        var minutes = totalSeconds / 60;
        var seconds = totalSeconds % 60;
        return Lang.format("$1$:$2$", [minutes, seconds.format("%02d")]);
    }

    // ------------------------------------------------------------------
    // Formats a duration in seconds for the LIMIT field.
    //
    // Under an hour it uses "M:SS", the right shape for an anaerobic limit,
    // where seconds are what count. Over an hour it switches to "1h20", because
    // running out of carbohydrate or of legs is measured in hours and "82:14"
    // would leave the athlete doing mental arithmetic mid-race. Past ten hours
    // the estimate stops being informative or reliable, so a ceiling is shown
    // instead of a precise and false number.
    // ------------------------------------------------------------------
    private function formatDuration(seconds as Float) as String {
        if (seconds < 0.0) {
            return "0:00";
        }
        if (seconds >= 35999.0) {
            return "9h59";
        }

        var total = Math.round(seconds).toNumber();
        if (total >= 3600) {
            var hours = total / 3600;
            var remainderMinutes = (total % 3600) / 60;
            return Lang.format("$1$h$2$", [hours, remainderMinutes.format("%02d")]);
        }

        var minutes = total / 60;
        var secs = total % 60;
        return Lang.format("$1$:$2$", [minutes, secs.format("%02d")]);
    }

    // ------------------------------------------------------------------
    // Formats the grade with one decimal and a sign.
    // ------------------------------------------------------------------
    private function formatGrade(gradePercent as Float) as String {
        return Lang.format("$1$%", [gradePercent.format("%+.1f")]);
    }

    // ------------------------------------------------------------------
    // onUpdate(dc): draws the UI. NO computation here, only the drawing of the
    // strings already prepared in mQuadValue.
    //
    // Each quadrant is two vertically centred lines: a small, dimmed label
    // above ("PACE", "HR", and so on) and the value itself below, large and
    // high contrast. That visual hierarchy, label then value, is the standard
    // for Garmin data fields, and it is what makes the screen readable at a
    // glance while running, without having to interpret the numbers.
    // ------------------------------------------------------------------
    function onUpdate(dc as Graphics.Dc) as Void {
        var width = dc.getWidth();
        var height = dc.getHeight();
        var halfW = width / 2;
        var halfH = height / 2;

        // --- Colours driven by the device theme -----------------------
        // getBackgroundColor() comes from the DataField base class and reflects
        // the theme the user chose (light or dark background, MIP or AMOLED
        // screen). The text colour picked is whichever gives the most readable
        // contrast.
        var backgroundColor = getBackgroundColor();
        var isDarkBackground = (backgroundColor == Graphics.COLOR_BLACK);
        var valueColor = isDarkBackground
            ? Graphics.COLOR_WHITE
            : Graphics.COLOR_BLACK;

        // Labels and dividers have to be dimmer than the value, but which grey
        // is right DEPENDS on the background: a dark background needs a light
        // grey, a light one (the light MIP theme) needs a dark grey. A fixed
        // LT_GRAY left the labels nearly invisible on white.
        var labelColor;
        var dividerColor;
        if (isDarkBackground) {
            labelColor = Graphics.COLOR_LT_GRAY;
            dividerColor = Graphics.COLOR_DK_GRAY;
        } else {
            labelColor = Graphics.COLOR_DK_GRAY;
            dividerColor = Graphics.COLOR_LT_GRAY;
        }

        // Clear the background in the right colour.
        dc.setColor(valueColor, backgroundColor);
        dc.clear();

        // --- Floating dividers -------------------------------------------
        // On a round screen, full-width lines cut the corners abruptly. They
        // are shortened slightly so they do not touch the edge, which reads as
        // a cleaner floating cross.
        var lineInsetX = mIsRoundScreen ? (width * 0.08).toNumber() : 0;
        var lineInsetY = mIsRoundScreen ? (height * 0.08).toNumber() : 0;
        dc.setColor(dividerColor, backgroundColor);
        dc.setPenWidth(1);
        dc.drawLine(halfW, lineInsetY, halfW, height - lineInsetY);       // vertical
        dc.drawLine(lineInsetX, halfH, width - lineInsetX, halfH);        // horizontal

        // --- Safety margin for the quadrant centres ----------------------
        // On a round screen the horizontal and vertical space available narrows
        // towards the edge, so each quadrant's centre is moved an extra
        // fraction towards the middle of the screen. That keeps label and value
        // inside the visible area, and stops, say, the "P" of "PACE" from being
        // clipped by the curvature of the glass.
        var insetFraction = mIsRoundScreen ? 0.22 : 0.0;
        var quadInsetX = ((halfW / 2) * insetFraction).toNumber();
        var quadInsetY = ((halfH / 2) * insetFraction).toNumber();
        var leftCenterX = (halfW / 2) + quadInsetX;
        var rightCenterX = width - leftCenterX;
        var topCenterY = (halfH / 2) + quadInsetY;
        var bottomCenterY = height - topCenterY;

        // VALUE font: rather than guessing at fixed thresholds, measure the
        // REAL width in pixels of the widest text across the 4 quadrants and
        // pick the largest numeric font that fits the space available to that
        // quadrant. That guarantees the values NEVER overlap, whatever the
        // longest string turns out to be ("+15.0%" is far wider than "159" or
        // "--:--") and on any device. getTextWidthInPixels() allocates nothing,
        // so it is safe to call here in onUpdate().
        //
        // The space available is the distance from the quadrant centre to the
        // central divider, which is the tighter constraint now that the centres
        // have been pulled inwards above, doubled and with a small safety
        // margin. That margin is proportional to screen width (6%, minimum
        // 16px): a fixed value too small (6px was tried) left the two values on
        // a row practically touching the divider whenever both were wide
        // strings, "-13.6%" and "11:26" for example.
        var dividerPadding = (width * 0.06).toNumber();
        if (dividerPadding < 16) {
            dividerPadding = 16;
        }
        var maxValueWidth = ((halfW - leftCenterX) * 2) - dividerPadding;
        if (maxValueWidth < 20) {
            maxValueWidth = 20; // safety floor, should never be needed
        }

        // The measuring itself only happens when something changed: one of the
        // 4 strings (mLayoutDirty, set by setQuadValue() in compute()) or the
        // dimensions of the graphics context. Otherwise the font already chosen
        // is reused, saving up to 12 getTextWidthInPixels() calls per redraw.
        if (mLayoutDirty || width != mCachedLayoutWidth || height != mCachedLayoutHeight) {
            var chosenFont = mValueFontCandidates[mValueFontCandidates.size() - 1];
            for (var f = 0; f < mValueFontCandidates.size(); f++) {
                var candidateFont = mValueFontCandidates[f];
                var widestTextPx = 0;
                for (var q = 0; q < QUADRANT_COUNT; q++) {
                    var textPx = dc.getTextWidthInPixels(mQuadValue[q], candidateFont);
                    if (textPx > widestTextPx) {
                        widestTextPx = textPx;
                    }
                }

                if (widestTextPx <= maxValueWidth) {
                    chosenFont = candidateFont;
                    break;
                }
            }

            mCachedValueFont = chosenFont;
            mCachedLayoutWidth = width;
            mCachedLayoutHeight = height;
            mLayoutDirty = false;
        }

        var valueFont = mCachedValueFont;

        // LABEL font: always small and fixed, readable but clearly secondary
        // to the value.
        var labelFont = Graphics.FONT_XTINY;

        // The height of both fonts, needed to stack label and value one above
        // the other, centred as a single block in the quadrant.
        // getFontHeight() allocates nothing, so it is safe to call here.
        var labelHeight = dc.getFontHeight(labelFont);
        var valueHeight = dc.getFontHeight(valueFont);

        // Vertical gap between label and value, proportional to screen size:
        // wide enough to breathe, without visually splitting the label and
        // value apart.
        var gap = labelHeight / 2;

        // The shared values are stored as instance variables so drawQuadrant()
        // can stay under the 9-argument-per-function limit older devices
        // impose. See the comment where these fields are declared, higher up in
        // the class.
        mDrawLabelFont = labelFont;
        mDrawValueFont = valueFont;
        mDrawLabelHeight = labelHeight;
        mDrawValueHeight = valueHeight;
        mDrawGap = gap;
        mDrawLabelColor = labelColor;
        mDrawBackgroundColor = backgroundColor;

        // The 4 quadrants, in order: top left, top right, bottom left, bottom
        // right. The colour of each comes from the alert level computed in
        // compute(). That is the step from number to judgement, and the only
        // part of the decision layer that reaches the athlete's eye without
        // having to be read.
        drawQuadrant(dc, leftCenterX, topCenterY, 0, valueColor);
        drawQuadrant(dc, rightCenterX, topCenterY, 1, valueColor);
        drawQuadrant(dc, leftCenterX, bottomCenterY, 2, valueColor);
        drawQuadrant(dc, rightCenterX, bottomCenterY, 3, valueColor);
    }

    // ------------------------------------------------------------------
    // Draws one quadrant's label and value, centred on (centerX, centerY). It
    // only writes to the Dc: it allocates nothing and reads strings and
    // constants that are already prepared, so it respects the rule about no
    // allocations in onUpdate.
    //
    // Takes 5 arguments; the MAXIMUM the Monkey C VM allows on older devices is
    // 9. Everything shared across the 4 quadrants (fonts, heights, gap,
    // background and label colours) is read from instance variables rather than
    // passed as a parameter every time.
    // ------------------------------------------------------------------
    private function drawQuadrant(
        dc as Graphics.Dc,
        centerX as Number,
        centerY as Number,
        index as Number,
        normalColor as Graphics.ColorType
    ) as Void {
        var totalHeight = mDrawLabelHeight + mDrawGap + mDrawValueHeight;
        var blockTop = centerY - (totalHeight / 2);

        dc.setColor(mDrawLabelColor, mDrawBackgroundColor);
        dc.drawText(
            centerX, blockTop + (mDrawLabelHeight / 2),
            mDrawLabelFont, mQuadLabel[index],
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        var valueColor = normalColor;
        var level = mQuadLevel[index];
        if (level == LEVEL_DANGER) {
            valueColor = Graphics.COLOR_RED;
        } else if (level == LEVEL_WARNING) {
            valueColor = Graphics.COLOR_ORANGE;
        }

        dc.setColor(valueColor, mDrawBackgroundColor);
        dc.drawText(
            centerX, blockTop + mDrawLabelHeight + mDrawGap + (mDrawValueHeight / 2),
            mDrawValueFont, mQuadValue[index],
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

}
