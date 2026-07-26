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

    // Costruttore: viene chiamato una sola volta all'avvio dell'app.
    function initialize() {
        AppBase.initialize(); // Richiama sempre il costruttore della classe base
    }

    // onStart(): chiamato quando l'app diventa attiva (es. inizio allenamento).
    // Qui non serve fare nulla di speciale.
    function onStart(state as Dictionary?) as Void {
    }

    // onStop(): chiamato quando l'app viene chiusa (es. fine allenamento).
    // Anche qui non serve nulla di speciale: il sistema salva già il file
    // FIT autonomamente.
    function onStop(state as Dictionary?) as Void {
    }

    // getInitialView(): il sistema chiama questa funzione per sapere quale
    // View (interfaccia) mostrare. Per i Campi Dati bisogna restituire un
    // array con una singola istanza della classe View del campo dati.
    function getInitialView() as [Views] or [Views, InputDelegates] {
        return [ new UltraTrailDashboardView() ];
    }

}
