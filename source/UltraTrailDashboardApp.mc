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

// UltraTrailDashboardApp.mc
//
// The Application class: the entry point of the whole app. For a data field
// its only job is to create and hand back the View that draws the interface
// (UltraTrailDashboardView, in UltraTrailDashboardView.mc).
//
// It holds no computation. All the heavy logic lives in the View, because the
// View is what receives compute() and onUpdate() from the system.

import Toybox.Application; // Base module for a Connect IQ application
import Toybox.WatchUi;     // View handling
import Toybox.Lang;        // Base types (Dictionary, Array, and so on)

// The class name has to match the entry="UltraTrailDashboardApp" attribute in
// manifest.xml exactly.
class UltraTrailDashboardApp extends Application.AppBase {

    // The View created in getInitialView(), kept so the settings-changed event
    // can be forwarded to it (see onSettingsChanged()). Nullable, because it
    // does not exist until the system has asked for the View.
    private var mView as UltraTrailDashboardView?;

    // Constructor: called once, when the app starts.
    function initialize() {
        AppBase.initialize(); // Always call the base class constructor
        mView = null;
    }

    // onStart(): called when the app becomes active, for example when an
    // activity starts. Nothing to do here.
    function onStart(state as Dictionary?) as Void {
    }

    // onStop(): called when the app closes, for example at the end of an
    // activity. The system saves the FIT file itself, but the personal bests
    // the self-calibration uses live in the app's Storage and are ours to
    // write. The View already does it when the timer stops; this is the safety
    // net for the cases where that callback never arrives (activity closed from
    // a menu, app terminated by the system).
    function onStop(state as Dictionary?) as Void {
        var view = mView;
        if (view != null) {
            view.persistCalibration();
        }
    }

    // getInitialView(): the system calls this to find out which View to show.
    // A data field returns an array holding one instance of its View class. We
    // keep the reference as well, so the events the system delivers to the
    // Application rather than to the View can be forwarded.
    function getInitialView() as [Views] or [Views, InputDelegates] {
        var view = new UltraTrailDashboardView();
        mView = view;
        return [ view ];
    }

    // onSettingsChanged(): called when the user changes a setting in Garmin
    // Connect Mobile while the app is running.
    //
    // IMPORTANT: this callback belongs to Application.AppBase, NOT to
    // WatchUi.DataField. Defining it inside the View, which is the obvious
    // place since that is where the value is needed, does nothing at all: the
    // system would never call it. So it is caught here and forwarded to the
    // View, which reloads the smoothing window and clears its history.
    function onSettingsChanged() as Void {
        var view = mView;
        if (view != null) {
            view.applySettings();
        }
        WatchUi.requestUpdate();
    }

}
