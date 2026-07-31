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

// SpeedCalibration.mc
//
// Stima automatica di velocità critica (CS) e capacità anaerobica (D')
// dai dati dell'atleta, senza che l'utente debba inserire nulla.
//
// PERCHÉ ESISTE QUESTA CLASSE
// Ogni modello di questo tipo (Xert, Stryd, WKO) ha bisogno di due
// parametri dell'atleta per funzionare. Chiederli all'utente è il modo
// più rapido per perdere l'utente: chi non li conosce si ferma
// all'installazione, e chi li conosce spesso inserisce il valore di due
// stagioni fa. Un campo dati che funziona al primo utilizzo e migliora da
// solo vale molto di più di uno che pretende una configurazione corretta.
//
// COME FUNZIONA
// Il modello iperbolico della prestazione dice che la distanza percorribile
// in un tempo t vale:
//
//     d(t) = CS * t + D'
//
// È una retta: bastano due punti per determinarne pendenza (CS) e
// intercetta (D'). Prendiamo quindi il MIGLIOR risultato dell'atleta su due
// durate (3 e 12 minuti), misurato in distanza equivalente in piano.
//
// COME STA IN MEMORIA
// Servirebbe la media mobile massima su finestre di 3 e 12 minuti, cioè in
// teoria 720 campioni al secondo da tenere in RAM. Invece teniamo la
// distanza CUMULATA campionata ogni 5 secondi in un buffer circolare di 145
// celle: la distanza percorsa in una finestra è la differenza tra due celle,
// quindi ogni aggiornamento costa due sottrazioni e due confronti, e la RAM
// occupata è circa un ventesimo.

import Toybox.Lang;
import Toybox.Application.Storage;

class SpeedCalibration {

    // ------------------------------------------------------------------
    // GEOMETRIA DEL BUFFER
    // ------------------------------------------------------------------

    // Ogni quanti secondi salviamo un campione di distanza cumulata.
    // 5 secondi sono un compromesso: abbastanza fitti da individuare i
    // bordi di una finestra di 3 minuti con un errore sotto il 3%,
    // abbastanza radi da entrare in poco più di 1KB di RAM.
    const SAMPLE_PERIOD_SEC as Float = 5.0;

    // Le due durate su cui misuriamo il massimo, in numero di campioni.
    // 36 campioni = 180 s = 3 minuti; 144 campioni = 720 s = 12 minuti.
    const SHORT_SLOTS as Number = 36;
    const LONG_SLOTS as Number = 144;

    // Le stesse due durate in secondi, usate nella regressione.
    const SHORT_SEC as Float = 180.0;
    const LONG_SEC as Float = 720.0;

    // Il buffer deve contenere la finestra lunga PIÙ il campione corrente.
    const BUFFER_SIZE as Number = 145;

    // Chiavi di persistenza. I record restano sull'orologio tra un'attività
    // e l'altra: è ciò che permette al modello di essere già pronto alla
    // seconda o terza uscita.
    const KEY_BEST_SHORT as String = "calBestShort";
    const KEY_BEST_LONG as String = "calBestLong";

    // ------------------------------------------------------------------
    // STATO
    // ------------------------------------------------------------------

    // Buffer circolare della distanza equivalente in piano cumulata (m).
    private var mCumulative as Array<Float>;
    private var mIndex as Number;
    private var mCount as Number;

    // Distanza equivalente in piano accumulata da inizio attività (m).
    private var mDistance as Float;

    // Secondi trascorsi dall'ultimo campione salvato nel buffer.
    private var mSinceSample as Float;

    // Record personali: massima distanza equivalente in piano coperta in
    // una finestra di 3 e di 12 minuti. Sopravvivono all'attività.
    private var mBestShort as Float;
    private var mBestLong as Float;

    // true se i record sono cambiati e vanno riscritti su Storage: evita
    // scritture inutili in memoria flash a ogni stop del timer.
    private var mDirty as Boolean;

    // ------------------------------------------------------------------
    // COSTRUTTORE
    // ------------------------------------------------------------------

    function initialize() {
        mCumulative = new Array<Float>[BUFFER_SIZE];
        for (var i = 0; i < BUFFER_SIZE; i++) {
            mCumulative[i] = 0.0;
        }
        mIndex = 0;
        mCount = 0;
        mDistance = 0.0;
        mSinceSample = 0.0;
        mBestShort = 0.0;
        mBestLong = 0.0;
        mDirty = false;

        load();
    }

    // ------------------------------------------------------------------
    // Carica i record personali dalla memoria persistente. Qualunque
    // problema (chiave assente alla prima installazione, valore di tipo
    // inatteso perché scritto da una versione precedente) si risolve
    // ripartendo da zero: la calibrazione si ricostruisce da sola in
    // qualche uscita, mentre un crash all'avvio è definitivo.
    // ------------------------------------------------------------------
    private function load() as Void {
        try {
            var short = Storage.getValue(KEY_BEST_SHORT);
            if (short instanceof Float || short instanceof Number) {
                mBestShort = short.toFloat();
            }
            var long = Storage.getValue(KEY_BEST_LONG);
            if (long instanceof Float || long instanceof Number) {
                mBestLong = long.toFloat();
            }
        } catch (ex) {
            mBestShort = 0.0;
            mBestLong = 0.0;
        }
    }

    // ------------------------------------------------------------------
    // Salva i record, se cambiati. Chiamata allo stop del timer e alla
    // chiusura dell'app, mai durante la corsa: scrivere in flash ogni
    // secondo accorcerebbe la vita del dispositivo senza alcun beneficio.
    // ------------------------------------------------------------------
    function save() as Void {
        if (!mDirty) {
            return;
        }
        try {
            Storage.setValue(KEY_BEST_SHORT, mBestShort);
            Storage.setValue(KEY_BEST_LONG, mBestLong);
            mDirty = false;
        } catch (ex) {
            // Storage pieno o non disponibile: i record restano validi in
            // RAM per questa attività, si perdono alla successiva. Non è
            // un motivo per interrompere l'attività dell'utente.
        }
    }

    // ------------------------------------------------------------------
    // Cancella i record personali, in RAM e su Storage. Esposto all'utente
    // come impostazione: serve dopo un lungo stop, un cambio di categoria
    // di terreno, o se una sessione anomala (dato GPS impazzito) ha
    // lasciato un record irraggiungibile che blocca la stima troppo in alto.
    // ------------------------------------------------------------------
    function clear() as Void {
        mBestShort = 0.0;
        mBestLong = 0.0;
        mDirty = false;
        try {
            Storage.deleteValue(KEY_BEST_SHORT);
            Storage.deleteValue(KEY_BEST_LONG);
        } catch (ex) {
            // Niente da fare: i valori in RAM sono comunque azzerati.
        }
    }

    // ------------------------------------------------------------------
    // Azzera lo stato della SESSIONE (buffer e distanza cumulata) senza
    // toccare i record personali. Da chiamare al reset dell'attività:
    // la distanza riparte da zero, e confrontare campioni della corsa
    // precedente con quelli della nuova produrrebbe finestre negative.
    // ------------------------------------------------------------------
    function resetSession() as Void {
        mIndex = 0;
        mCount = 0;
        mDistance = 0.0;
        mSinceSample = 0.0;
    }

    // ------------------------------------------------------------------
    // Passo di aggiornamento, una volta al secondo.
    //
    //   gapSpeed  velocità equivalente in piano (m/s), calcolata con
    //             MinettiCost.modelRatio(): il tetto in salita è
    //             indispensabile qui, perché senza di esso una rampa
    //             ripida percorsa camminando produrrebbe un record di
    //             3 minuti irrealisticamente alto e la CS stimata
    //             resterebbe gonfiata per sempre
    //   dt        secondi realmente trascorsi
    // ------------------------------------------------------------------
    function update(gapSpeed as Float, dt as Float) as Void {
        if (dt <= 0.0) {
            return;
        }

        mDistance += gapSpeed * dt;
        mSinceSample += dt;

        // Un solo campione per chiamata: la View limita dt a un massimo di
        // 5 secondi, quindi mSinceSample non può mai raggiungere il doppio
        // del periodo di campionamento in un colpo solo.
        if (mSinceSample >= SAMPLE_PERIOD_SEC) {
            mSinceSample -= SAMPLE_PERIOD_SEC;
            pushSample();
        }
    }

    // ------------------------------------------------------------------
    // Inserisce la distanza cumulata corrente nel buffer circolare e
    // aggiorna i due record, se superati.
    // ------------------------------------------------------------------
    private function pushSample() as Void {
        mCumulative[mIndex] = mDistance;
        mIndex = (mIndex + 1) % BUFFER_SIZE;
        if (mCount < BUFFER_SIZE) {
            mCount++;
        }

        // Distanza coperta nella finestra di 3 minuti: differenza tra il
        // campione appena scritto e quello di 36 posizioni prima.
        if (mCount > SHORT_SLOTS) {
            var oldShort = (mIndex - 1 - SHORT_SLOTS + BUFFER_SIZE) % BUFFER_SIZE;
            var covered = mDistance - mCumulative[oldShort];
            if (covered > mBestShort) {
                mBestShort = covered;
                mDirty = true;
            }
        }

        // Stessa cosa sulla finestra di 12 minuti.
        if (mCount > LONG_SLOTS) {
            var oldLong = (mIndex - 1 - LONG_SLOTS + BUFFER_SIZE) % BUFFER_SIZE;
            var covered = mDistance - mCumulative[oldLong];
            if (covered > mBestLong) {
                mBestLong = covered;
                mDirty = true;
            }
        }
    }

    // ------------------------------------------------------------------
    // true se i due record consentono una stima sensata.
    //
    // La condizione mBestLong > mBestShort non è una formalità: se il
    // record lungo non supera quello corto significa che l'atleta non ha
    // mai sostenuto uno sforzo per 12 minuti (o che i due record vengono
    // da sessioni incoerenti). In quel caso la retta avrebbe pendenza
    // negativa e produrrebbe una CS senza senso.
    // ------------------------------------------------------------------
    function isValid() as Boolean {
        if (mBestShort <= 0.0 || mBestLong <= 0.0) {
            return false;
        }
        if (mBestLong <= mBestShort) {
            return false;
        }
        var cs = getCriticalSpeed();
        return (cs >= 1.5 && cs <= 6.5);
    }

    // ------------------------------------------------------------------
    // Pendenza della retta d(t) = CS*t + D', cioè la velocità critica in
    // m/s. Chiamare solo dopo isValid().
    // ------------------------------------------------------------------
    function getCriticalSpeed() as Float {
        return (mBestLong - mBestShort) / (LONG_SEC - SHORT_SEC);
    }

    // ------------------------------------------------------------------
    // Intercetta della stessa retta, cioè D' in metri.
    // ------------------------------------------------------------------
    function getDPrime() as Float {
        var d = mBestShort - (getCriticalSpeed() * SHORT_SEC);
        if (d < 0.0) {
            d = 0.0;
        }
        return d;
    }

}
