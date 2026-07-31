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
// Questa è la classe "Application": il punto di ingresso di tutta l'app.
// Il suo unico compito, per un Campo Dati (Data Field), è creare e
// restituire l'istanza della View che disegnerà l'interfaccia grafica
// (UltraTrailDashboardView, definita in UltraTrailDashboardView.mc).
//
// Non contiene logica di calcolo: tutta la logica "pesante" vive nella View,
// perché è la View a ricevere gli eventi compute()/onUpdate() dal sistema.

import Toybox.Application; // Modulo base per creare un'applicazione Connect IQ
import Toybox.WatchUi;     // Modulo per la gestione delle View (interfacce grafiche)
import Toybox.Lang;        // Modulo con i tipi di base (Dictionary, Array, ecc.)

// La classe deve chiamarsi esattamente come indicato nell'attributo
// entry="UltraTrailDashboardApp" del manifest.xml.
class UltraTrailDashboardApp extends Application.AppBase {

    // Riferimento alla View creata in getInitialView(). Serve per poterle
    // inoltrare l'evento di cambio impostazioni (vedi onSettingsChanged()).
    // È nullable perché esiste solo dopo che il sistema ha richiesto la View.
    private var mView as UltraTrailDashboardView?;

    // Costruttore: viene chiamato una sola volta all'avvio dell'app.
    function initialize() {
        AppBase.initialize(); // Richiama sempre il costruttore della classe base
        mView = null;
    }

    // onStart(): chiamato quando l'app diventa attiva (es. inizio allenamento).
    // Qui non serve fare nulla di speciale.
    function onStart(state as Dictionary?) as Void {
    }

    // onStop(): chiamato quando l'app viene chiusa (es. fine allenamento).
    // Il file FIT lo salva già il sistema per conto suo, ma i record
    // personali usati dall'autocalibrazione vivono nello Storage dell'app
    // e li dobbiamo scrivere noi. La View lo fa già allo stop del timer:
    // questa è la rete di sicurezza per i casi in cui quel callback non
    // arriva (attività chiusa da menu, app terminata dal sistema).
    function onStop(state as Dictionary?) as Void {
        var view = mView;
        if (view != null) {
            view.persistCalibration();
        }
    }

    // getInitialView(): il sistema chiama questa funzione per sapere quale
    // View (interfaccia) mostrare. Per i Campi Dati bisogna restituire un
    // array con una singola istanza della classe View del campo dati.
    // Ne conserviamo anche il riferimento, per poterle inoltrare gli eventi
    // che il sistema consegna all'Application e non alla View.
    function getInitialView() as [Views] or [Views, InputDelegates] {
        var view = new UltraTrailDashboardView();
        mView = view;
        return [ view ];
    }

    // onSettingsChanged(): il sistema lo chiama quando l'utente modifica le
    // impostazioni da Garmin Connect Mobile mentre l'app è in esecuzione.
    //
    // IMPORTANTE: questo callback appartiene ad Application.AppBase e NON a
    // WatchUi.DataField. Definirlo dentro la View (come si potrebbe pensare,
    // visto che è lì che serve il dato) non produce alcun effetto: il sistema
    // non lo invocherebbe mai. Va quindi intercettato qui e inoltrato alla
    // View, che ricarica la finestra di smoothing e azzera lo storico.
    function onSettingsChanged() as Void {
        var view = mView;
        if (view != null) {
            view.applySettings();
        }
        WatchUi.requestUpdate();
    }

}
