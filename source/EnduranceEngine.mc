// EnduranceEngine.mc
//
// Il motore fisiologico dell'app. Riceve una velocità equivalente in piano
// (GAP speed, in m/s) una volta al secondo e mantiene tre stati integrati
// nel tempo:
//
//   1. LAVORO ACCUMULATO      quanta energia hai speso dall'inizio (kJ/kg)
//   2. VELOCITÀ SOSTENIBILE   la CS di adesso, che CALA mentre corri
//   3. RISERVA ANAEROBICA     quanto ti resta sopra soglia (D' balance)
//
// Il punto 2 è ciò che distingue questo motore da tutto il resto.
// Xert, Stryd e la Stamina nativa Garmin trattano la soglia (CP, CS, FTP)
// come una costante per tutta l'attività. È un'approssimazione ragionevole
// sotto le 2-3 ore e falsa oltre: la letteratura sulla "durabilità"
// (Maunder et al. 2021) documenta cali della soglia del 10-20% dopo diverse
// ore di lavoro. In un ultra è esattamente la differenza tra un modello che
// funziona e uno che dice all'atleta che sta andando piano mentre sta
// esplodendo.
//
// NOTA SULLE UNITÀ: qui si lavora sempre in unità SI (m/s, metri, secondi,
// J/kg). La conversione in passo (min/km o min/mi) avviene solo al momento
// di formattare la stringa da mostrare, nella View.

import Toybox.Lang;
import Toybox.Math;

class EnduranceEngine {

    // ------------------------------------------------------------------
    // COSTANTI DEL MODELLO
    // ------------------------------------------------------------------

    // Lavoro di riferimento per il decadimento della velocità sostenibile,
    // in kJ per kg di massa corporea. Il fattore di durabilità impostato
    // dall'utente esprime la percentuale di CS persa OGNI volta che si
    // accumula questa quantità di lavoro.
    //
    // Ordine di grandezza: correre in piano a 3 m/s costa 3.6 J/kg/m, cioè
    // 10.8 W/kg, cioè circa 39 kJ/kg all'ora. 100 kJ/kg equivalgono quindi
    // a poco più di 2 ore e mezza di corsa continua a ritmo moderato.
    const WORK_REFERENCE_KJ_PER_KG as Float = 100.0;

    // Pavimento del decadimento: la velocità sostenibile non scende mai
    // sotto questa frazione del valore di partenza. Serve a impedire che
    // un ultra molto lungo porti il modello verso lo zero, dove ogni passo
    // risulterebbe "sopra soglia" e il campo diventerebbe inutile.
    const MIN_SPEED_RETENTION as Float = 0.60;

    // Intervallo plausibile per la velocità critica di un corridore, in
    // m/s. 1.5 m/s sono circa 11:07 min/km, 6.5 m/s circa 2:34 min/km:
    // qualunque valore fuori da qui viene da dati sporchi, non da un
    // atleta, e va rifiutato invece che mostrato.
    const MIN_PLAUSIBLE_CS as Float = 1.5;
    const MAX_PLAUSIBLE_CS as Float = 6.5;

    // Intervallo plausibile per D' (capacità di lavoro sopra soglia,
    // espressa in metri di "distanza extra" percorribile sopra CS).
    // In letteratura i corridori allenati stanno tra circa 100 e 300 m.
    const MIN_PLAUSIBLE_D_PRIME as Float = 50.0;
    const MAX_PLAUSIBLE_D_PRIME as Float = 500.0;

    // Valore di D' usato quando conosciamo CS (per esempio perché l'utente
    // ha inserito il passo soglia) ma non abbiamo ancora abbastanza dati
    // per stimare D' dalla curva dell'atleta.
    const DEFAULT_D_PRIME as Float = 200.0;

    // ------------------------------------------------------------------
    // STATO
    // ------------------------------------------------------------------

    // Velocità critica di riferimento a inizio attività (m/s), cioè da
    // riposo. 0.0 significa "modello non disponibile".
    private var mBaseCriticalSpeed as Float;

    // Capacità di lavoro anaerobico (m).
    private var mDPrime as Float;

    // Frazione di velocità critica persa ogni WORK_REFERENCE_KJ_PER_KG di
    // lavoro accumulato (0.08 = 8%). 0.0 disattiva il decadimento e riporta
    // il motore al comportamento classico a soglia costante.
    private var mDurabilityFactor as Float;

    // --- Stato integrato durante l'attività ---------------------------

    // Lavoro accumulato dall'inizio dell'attività, kJ/kg.
    private var mWorkKjPerKg as Float;

    // Velocità sostenibile ADESSO (m/s), cioè mBaseCriticalSpeed già
    // ridotta dal decadimento di durabilità.
    private var mEffectiveCriticalSpeed as Float;

    // Riserva anaerobica residua (m), tra 0 e mDPrime.
    private var mBalance as Float;

    // Tempo stimato prima dell'esaurimento della riserva al ritmo attuale,
    // in secondi. Vale null quando si sta sotto la velocità sostenibile:
    // in quel caso la riserva non si sta consumando ma ricaricando, quindi
    // un "tempo al cedimento" non esiste. Mostrare 0, o un numero enorme,
    // sarebbe inventarsi un dato.
    private var mTimeToFailureSec as Float?;

    // true solo se abbiamo una velocità critica utilizzabile. Finché è
    // false la View mostra "--" invece di numeri privi di fondamento.
    private var mHasModel as Boolean;

    // ------------------------------------------------------------------
    // COSTRUTTORE
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
    // Imposta i parametri dell'atleta. Chiamata all'avvio e ogni volta che
    // cambiano le impostazioni o arriva una nuova stima dalla calibrazione.
    //
    // criticalSpeed <= 0 significa "nessuna stima disponibile": il motore
    // si dichiara non pronto invece di lavorare su un numero inventato.
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

        // Se D' cambia mentre l'attività è in corso, conserviamo la riserva
        // come FRAZIONE invece che come valore assoluto: una riserva "al
        // 70%" resta al 70%, altrimenti un semplice cambio di impostazioni
        // regalerebbe o toglierebbe energia all'atleta a metà gara.
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
    // Azzera lo stato integrato (lavoro, riserva, velocità sostenibile)
    // lasciando intatti i parametri dell'atleta. Da chiamare quando
    // l'utente resetta l'attività per iniziarne una nuova.
    // ------------------------------------------------------------------
    function reset() as Void {
        mWorkKjPerKg = 0.0;
        mBalance = mDPrime;
        mTimeToFailureSec = null;
        recomputeEffectiveCriticalSpeed();
    }

    // ------------------------------------------------------------------
    // Passo di integrazione, chiamato una volta al secondo dalla View.
    //
    //   gapSpeed  velocità equivalente in piano (m/s), già calcolata con
    //             MinettiCost.modelRatio() e quindi con il tetto in salita
    //   dt        secondi realmente trascorsi dall'ultima chiamata (NON
    //             assunti pari a 1: compute() può saltare cicli e il timer
    //             può essere stato in pausa)
    // ------------------------------------------------------------------
    function update(gapSpeed as Float, dt as Float) as Void {
        if (dt <= 0.0) {
            return;
        }

        // --- 1) Lavoro accumulato ---------------------------------------
        // La potenza metabolica per kg è C(i) * v, e per costruzione della
        // GAP speed vale C(i) * v = C(0) * vGap: il costo della pendenza è
        // già interamente dentro vGap, quindi qui basta il costo in piano.
        mWorkKjPerKg += (MinettiCost.FLAT_COST * gapSpeed * dt) / 1000.0;

        // --- 2) Decadimento della velocità sostenibile ------------------
        recomputeEffectiveCriticalSpeed();

        if (!mHasModel) {
            mTimeToFailureSec = null;
            return;
        }

        // --- 3) Bilancio della riserva anaerobica -----------------------
        // Forma differenziale di Clarke e Skiba (2013). La formulazione
        // originale di Skiba (2012) richiede di integrare su TUTTO lo
        // storico degli sforzi precedenti a ogni singolo campione: su un
        // orologio con 32KB e un ultra da 20 ore è semplicemente
        // impossibile. Questa forma è matematicamente equivalente, ha
        // costo O(1) per campione e nessuno storico da tenere in RAM.
        var deficit = gapSpeed - mEffectiveCriticalSpeed;

        if (deficit > 0.0) {
            // Sopra la velocità sostenibile: la riserva si consuma alla
            // velocità del sorpasso.
            mBalance -= deficit * dt;
            if (mBalance < 0.0) {
                mBalance = 0.0;
            }
            mTimeToFailureSec = mBalance / deficit;
        } else {
            // Sotto la velocità sostenibile: la riserva si ricarica, tanto
            // più in fretta quanto più si va piano e quanto più è vuota.
            if (mDPrime > 0.0) {
                mBalance += ((mDPrime - mBalance) * (-deficit) * dt) / mDPrime;
                if (mBalance > mDPrime) {
                    mBalance = mDPrime;
                }
            }
            // Nessun cedimento previsto per via anaerobica: sotto soglia il
            // limite sarà semmai il glicogeno, il calore o il danno da
            // discesa, che questo motore ancora non modella.
            mTimeToFailureSec = null;
        }
    }

    // ------------------------------------------------------------------
    // Applica il decadimento di durabilità alla velocità critica di base.
    //
    //   CS_eff = CS0 * (1 - k * lavoro / lavoro_di_riferimento)
    //
    // con il risultato mai sotto MIN_SPEED_RETENTION * CS0.
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
            // Difensivo: un fattore di durabilità negativo non ha senso
            // fisico e non deve poter far salire la soglia durante la gara.
            retention = 1.0;
        }

        mEffectiveCriticalSpeed = mBaseCriticalSpeed * retention;
    }

    // ------------------------------------------------------------------
    // ACCESSORI (letti dalla View per formattare i quadranti e per
    // scrivere i campi nel file FIT)
    // ------------------------------------------------------------------

    function hasModel() as Boolean {
        return mHasModel;
    }

    // Valore di ripiego per D' quando conosciamo la velocità critica ma non
    // abbiamo ancora dati per stimare la capacità anaerobica. Esposto come
    // metodo e non come costante letta dall'esterno perché la VM Monkey C
    // non consente di leggere una const di classe senza un'istanza.
    function defaultDPrime() as Float {
        return DEFAULT_D_PRIME;
    }

    // Velocità sostenibile attuale in m/s (0.0 se il modello non è pronto).
    function getSustainableSpeed() as Float {
        return mEffectiveCriticalSpeed;
    }

    // Riserva anaerobica residua in percentuale (0-100).
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

    // Secondi al cedimento, oppure null se non si sta consumando riserva.
    function getTimeToFailureSec() as Float? {
        return mTimeToFailureSec;
    }

    // Lavoro accumulato dall'inizio dell'attività, kJ/kg.
    function getWorkKjPerKg() as Float {
        return mWorkKjPerKg;
    }

    // Velocità critica di riferimento (a riposo), m/s.
    function getBaseCriticalSpeed() as Float {
        return mBaseCriticalSpeed;
    }

    function getDPrime() as Float {
        return mDPrime;
    }

}
