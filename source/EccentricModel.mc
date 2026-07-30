// EccentricModel.mc
//
// Accumulo del danno muscolare da discesa.
//
// PERCHÉ ESISTE, E PERCHÉ NON ESISTE ALTROVE
// In un ultra di montagna il primo sistema a cedere quasi mai è quello
// aerobico: sono i quadricipiti. La discesa impone contrazioni eccentriche,
// cioè il muscolo genera forza mentre si allunga per frenare il corpo. È il
// tipo di contrazione che produce danno strutturale, e il danno non recupera
// durante la gara: si accumula e basta. A metà UTMB non è il fiato a
// mancare, sono le gambe che non frenano più.
//
// Nessun campo dati, e nessuna metrica nativa Garmin, modella questa cosa.
// Tutti misurano il sistema cardiovascolare, che nel trail lungo spesso non
// è il vincolo. È il pezzo più originale di questa app.
//
// COME LO MISURIAMO
// Il lavoro negativo che il corpo deve assorbire scendendo è proporzionale
// alla quota persa. Ma non tutti i metri di discesa costano uguale: scendere
// veloce significa impatti più violenti e più forza da assorbire a ogni
// passo. Pesiamo quindi la quota persa con un fattore che cresce con la
// velocità:
//
//   metri equivalenti = quota persa * phi(velocità)
//
// L'unità è quindi "metri di dislivello negativo equivalente": la stessa
// unità in cui ogni trail runner già ragiona quando guarda il profilo di
// una gara. Scendere 1000 m di corsa pesa più che scenderne 1000 camminando,
// ed è esattamente quello che succede alle gambe.
//
// LA CAPACITÀ
// L'utente imposta quanto dislivello negativo regge prima che la discesa
// diventi un problema. È un numero che chi corre in montagna conosce di sé
// meglio di qualunque formula: sa se dopo 2000 m di discesa è a pezzi o se
// ne regge 6000. Il default di 3000 m è la stima per un trail runner
// allenato ma non specialista di discesa.
//
// NOTA: a differenza degli altri modelli, questo NON ha bisogno della
// velocità critica. Funziona dal primo secondo del primo utilizzo, senza
// alcuna calibrazione.

import Toybox.Lang;
import Toybox.Math;

class EccentricModel {

    // ------------------------------------------------------------------
    // COSTANTI DEL MODELLO
    // ------------------------------------------------------------------

    // Velocità di riferimento per il fattore di peso, in m/s (3 m/s sono
    // circa 5:30 al km: una discesa corsa a ritmo sostenuto).
    const REFERENCE_SPEED as Float = 3.0;

    // Quanto cresce il costo per metro di quota persa al crescere della
    // velocità. Con 0.5, scendere a 3 m/s pesa il 50% in più che scendere
    // quasi fermi, e a 6 m/s il doppio.
    const SPEED_COEFFICIENT as Float = 0.5;

    // Tetto al fattore di peso: oltre una certa velocità il modello
    // smetterebbe di essere credibile, e comunque nessuno scende più
    // veloce di così per ore.
    const MAX_WEIGHT as Float = 2.0;

    // Limiti accettati per la capacità impostata dall'utente, in metri.
    const MIN_CAPACITY_M as Float = 500.0;
    const MAX_CAPACITY_M as Float = 15000.0;

    // ------------------------------------------------------------------
    // STATO
    // ------------------------------------------------------------------

    // Dislivello negativo equivalente che l'atleta regge (m).
    private var mCapacityMeters as Float;

    // Dislivello negativo equivalente accumulato finora (m), cioè pesato
    // per la velocità di discesa.
    private var mEquivalentMeters as Float;

    // Dislivello negativo grezzo accumulato (m), non pesato. Serve come
    // riferimento leggibile e per il confronto a posteriori con il dato
    // di dislivello che registra il dispositivo per conto suo.
    private var mDescentMeters as Float;

    // Tasso di accumulo attuale (m equivalenti al secondo). Vale 0 quando
    // non si sta scendendo: è ciò che rende il tempo al limite null in
    // salita e in piano, dove le gambe non stanno peggiorando.
    private var mEquivalentRate as Float;

    // ------------------------------------------------------------------
    // COSTRUTTORE
    // ------------------------------------------------------------------

    function initialize() {
        mCapacityMeters = 3000.0;
        mEquivalentMeters = 0.0;
        mDescentMeters = 0.0;
        mEquivalentRate = 0.0;
    }

    // ------------------------------------------------------------------
    // Imposta la capacità di discesa dell'atleta, in metri di dislivello
    // negativo. Valori fuori scala vengono riportati nei limiti invece di
    // essere rifiutati: qui, a differenza della velocità critica, non
    // esiste un valore "impossibile" che indichi un dato corrotto, solo
    // valori più o meno ottimistici.
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
    // Passo di integrazione.
    //
    //   speed          velocità reale lungo il terreno (m/s), NON quella
    //                  equivalente in piano: qui conta il movimento vero
    //                  del corpo, non il suo costo aerobico
    //   gradeFraction  pendenza come frazione (negativa in discesa)
    //   dt             secondi trascorsi
    // ------------------------------------------------------------------
    function update(speed as Float, gradeFraction as Float, dt as Float) as Void {
        mEquivalentRate = 0.0;

        if (dt <= 0.0 || speed <= 0.0 || gradeFraction >= 0.0) {
            // In salita e in piano non si accumula danno eccentrico. Non è
            // una semplificazione: la contrazione eccentrica del
            // quadricipite è specifica della frenata in discesa.
            return;
        }

        // Quota persa per metro percorso: seno della pendenza, non la
        // pendenza stessa. Sulle pendenze dolci la differenza è
        // trascurabile, ma al 45% la pendenza vale 0.45 e il seno 0.41,
        // e usare la prima sovrastimerebbe la discesa del 10% proprio dove
        // il terreno è più ripido e il conto conta di più.
        // toFloat() esplicito: Math.sqrt() restituisce un Double, e senza la
        // conversione il tipo si propaga fino ai campi Float della classe,
        // cosa che il controllo di tipo stretto rifiuta.
        var g = -gradeFraction; // positivo in discesa
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
    // ACCESSORI
    // ------------------------------------------------------------------

    // Dislivello negativo equivalente accumulato (m).
    function getEquivalentMeters() as Float {
        return mEquivalentMeters;
    }

    // Dislivello negativo grezzo accumulato (m).
    function getDescentMeters() as Float {
        return mDescentMeters;
    }

    // Capacità di discesa residua, in percentuale.
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
    // Secondi prima di esaurire la capacità di discesa, al ritmo di
    // accumulo attuale. Vale null quando non si sta scendendo: in salita le
    // gambe non peggiorano, quindi un tempo al limite non esiste.
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
