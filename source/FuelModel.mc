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
// Bilancio dei carboidrati in tempo reale.
//
// COSA FA DI DIVERSO DAI TIMER DI NUTRIZIONE ESISTENTI
// I campi dati di nutrizione oggi sul Connect IQ Store sono quasi tutti
// sveglie: vibrano ogni 30 minuti. Non sanno quanto stai consumando, non
// sanno a che intensità stai andando, e dicono la stessa cosa a chi cammina
// e a chi sta spingendo in salita. Questo modello fa il conto vero:
//
//   riserva iniziale + assorbito - ossidato = quanto ti resta
//
// e da lì ricava quanto manca all'esaurimento al ritmo attuale.
//
// LE TRE PARTI DEL CONTO
//
// 1. OSSIDAZIONE. La frazione di energia che arriva dai carboidrati non è
//    costante: a bassa intensità il corpo usa soprattutto grassi, vicino
//    alla soglia usa soprattutto zuccheri. La curva è ricavata dalla
//    intensità relativa alla velocità sostenibile, cioè dallo stesso
//    modello che alimenta gli altri campi.
//
// 2. ASSORBIMENTO. Quello che mangi adesso non è disponibile adesso.
//    Modelliamo lo stomaco come un serbatoio che si svuota con una costante
//    di tempo di circa 20 minuti, e con un tetto: oltre una certa quantità
//    oraria l'intestino non riesce ad assorbire, e il resto resta lì (nella
//    realtà, con conseguenze note a chiunque abbia corso un ultra).
//
// 3. RISERVA. Il glicogeno utilizzabile per la corsa, in grammi per kg.
//
// LIMITE DICHIARATO: il modello assume che l'atleta segua davvero il piano
// di alimentazione impostato. Non ha modo di sapere se hai mangiato: sui
// Data Field non arrivano eventi dei tasti. È un'assunzione esplicita, non
// un'approssimazione nascosta, ed è per questo che il piano è
// un'impostazione visibile e non una costante sepolta nel codice.

import Toybox.Lang;

class FuelModel {

    // ------------------------------------------------------------------
    // COSTANTI DEL MODELLO
    // ------------------------------------------------------------------

    // Glicogeno utilizzabile per la corsa, in grammi per kg di massa
    // corporea. Le riserve totali (muscolo più fegato) di un atleta
    // allenato stanno tra 10 e 12 g/kg, ma solo la quota nei muscoli che
    // stanno lavorando è realmente spendibile: il glicogeno dei bicipiti
    // non aiuta a correre. 7 g/kg è la stima prudente di quanto è davvero
    // disponibile, e per un atleta di 70 kg corrisponde a circa 490 g,
    // cioè poco meno di 8600 kJ.
    const STORE_GRAMS_PER_KG as Float = 7.0;

    // Energia resa dall'ossidazione di un grammo di carboidrati, in kJ.
    const ENERGY_PER_GRAM_KJ as Float = 17.5;

    // Costante di tempo dello svuotamento gastrico, in secondi. Venti
    // minuti è il ritardo tipico tra l'assunzione e la disponibilità nel
    // sangue. È il motivo per cui "mangia quando hai fame" è una pessima
    // strategia in gara: quando la fame arriva, sei già in ritardo di venti
    // minuti.
    const GUT_TRANSIT_SEC as Float = 1200.0;

    // Tetto di assorbimento intestinale, in grammi/ora. Con soli glucosio
    // e maltodestrine il limite sta intorno ai 60 g/h; con miscele
    // glucosio-fruttosio si arriva a 90-120 g/h in atleti con intestino
    // allenato. Prendiamo il limite superiore: oltre quello, quello che
    // ingerisci resta nello stomaco e non produce energia.
    const MAX_ABSORPTION_GRAMS_PER_HOUR as Float = 120.0;

    // Punti della curva di utilizzo dei carboidrati, in funzione
    // dell'intensità relativa alla velocità sostenibile (1.0 = a soglia).
    //
    // Interpolazione lineare a tratti invece della sigmoide che si userebbe
    // su un computer: Monkey C non espone la funzione esponenziale, e
    // ricostruirla costerebbe cicli su un dispositivo che deve chiudere
    // compute() in pochi millisecondi. Cinque punti riproducono la sigmoide
    // entro pochi punti percentuali, che è comunque molto meno
    // dell'incertezza dei dati fisiologici sottostanti.
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
    // STATO
    // ------------------------------------------------------------------

    private var mMassKg as Float;

    // Riserva totale all'inizio dell'attività (g) e quanto ne resta (g).
    private var mStoreGrams as Float;
    private var mRemainingGrams as Float;

    // Carboidrati ingeriti ma non ancora assorbiti (g).
    private var mGutGrams as Float;

    // Piano di alimentazione, in grammi al secondo.
    private var mIntakeGramsPerSec as Float;

    // Ultimi tassi calcolati (g/s): quanto stiamo bruciando e quanto sta
    // effettivamente entrando in circolo.
    private var mOxidationGramsPerSec as Float;
    private var mAbsorptionGramsPerSec as Float;

    private var mHasModel as Boolean;

    // ------------------------------------------------------------------
    // COSTRUTTORE
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
    // Configura atleta e piano di alimentazione.
    //
    //   massKg                massa corporea
    //   intakeGramsPerHour    carboidrati che l'atleta prevede di assumere
    //                         ogni ora, 0 se non ha un piano
    //
    // Come in EnduranceEngine, se la riserva cambia a metà attività la
    // conserviamo come FRAZIONE: cambiare il peso nelle impostazioni non
    // deve regalare o togliere energia a chi sta già correndo.
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
            // Ingerire più del tetto di assorbimento non aumenta l'energia
            // disponibile: accumula solo roba nello stomaco. Tagliamo qui
            // invece di lasciare che il serbatoio gastrico cresca senza
            // limite per tutta la gara.
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
    // Passo di integrazione.
    //
    //   metabolicPowerWPerKg  potenza metabolica attuale (W/kg), cioè
    //                         C(0) * velocità equivalente in piano
    //   intensity             velocità attuale divisa per quella
    //                         sostenibile (1.0 = esattamente a soglia)
    //   dt                    secondi trascorsi
    // ------------------------------------------------------------------
    function update(metabolicPowerWPerKg as Float, intensity as Float, dt as Float) as Void {
        if (!mHasModel || dt <= 0.0) {
            return;
        }

        // --- Ossidazione -----------------------------------------------
        var fraction = carbFraction(intensity);
        var powerWatts = metabolicPowerWPerKg * mMassKg;
        mOxidationGramsPerSec = (powerWatts * fraction) / (ENERGY_PER_GRAM_KJ * 1000.0);

        // --- Assorbimento con ritardo gastrico -------------------------
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

        // --- Bilancio ---------------------------------------------------
        mRemainingGrams += absorbed - (mOxidationGramsPerSec * dt);
        if (mRemainingGrams < 0.0) {
            mRemainingGrams = 0.0;
        } else if (mRemainingGrams > mStoreGrams) {
            // Mangiare più di quanto si consuma non crea riserve nuove:
            // il glicogeno muscolare ha un tetto fisico.
            mRemainingGrams = mStoreGrams;
        }
    }

    // ------------------------------------------------------------------
    // Frazione di energia proveniente dai carboidrati, per interpolazione
    // lineare tra i cinque punti della curva.
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

    // Interpolazione lineare tra due punti. Cinque argomenti, ben sotto il
    // limite di 9 della VM Monkey C sui dispositivi meno recenti.
    private function interpolate(x as Float, x0 as Float, x1 as Float, y0 as Float, y1 as Float) as Float {
        return y0 + ((y1 - y0) * (x - x0)) / (x1 - x0);
    }

    // ------------------------------------------------------------------
    // ACCESSORI
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

    // Carboidrati bruciati per ora al ritmo attuale (g/h).
    function getOxidationGramsPerHour() as Float {
        return mOxidationGramsPerSec * 3600.0;
    }

    // ------------------------------------------------------------------
    // Secondi all'esaurimento della riserva, oppure null se al ritmo
    // attuale l'assorbimento copre il consumo (nessun esaurimento in vista)
    // o se il modello non è configurato.
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
