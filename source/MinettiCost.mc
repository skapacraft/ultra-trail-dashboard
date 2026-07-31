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

// MinettiCost.mc
//
// Modello del costo energetico della corsa in funzione della pendenza,
// da Minetti et al. (2002), "Energy cost of walking and running at extreme
// uphill and downhill slopes", J Appl Physiol 93:1039-1046.
//
// Questo modulo è la SINGOLA fonte di verità per il costo energetico in
// tutta l'app: lo usano sia il calcolo del GAP mostrato a schermo, sia il
// motore fisiologico (EnduranceEngine) sia l'autocalibrazione
// (SpeedCalibration). Prima esisteva una copia della formula dentro la
// View: tenerne una sola evita che i tre consumatori divergano nel tempo.
//
// È un "module" e non una "class" di proposito: sono funzioni pure, senza
// stato, quindi non serve allocare alcuna istanza. Su un Data Field che
// deve stare in 32KB (Fenix 6 base, FR935, Enduro 1) ogni oggetto in meno
// è memoria guadagnata.

import Toybox.Lang;

module MinettiCost {

    // Costo energetico della corsa in piano, C(0), in J/kg/m.
    // È il denominatore di tutti i rapporti calcolati qui sotto.
    const FLAT_COST as Float = 3.6;

    // Limite di validità del modello, in frazione di pendenza (0.45 = 45%).
    // Minetti ha misurato il costo energetico tra -45% e +45%: fuori da
    // quell'intervallo il polinomio non è più validato e produce valori
    // privi di senso fisico (può perfino diventare negativo). Le pendenze
    // oltre il limite vengono quindi "appiattite" sul limite stesso.
    const MAX_GRADE_FRACTION as Float = 0.45;

    // Tetto al rapporto di costo usato dal MOTORE e dalla CALIBRAZIONE
    // (non dal GAP mostrato a schermo, che resta fedele a Minetti puro).
    //
    // Perché serve: a +45% il rapporto C(i)/C(0) vale circa 5.4, cioè il
    // modello considera 1 m percorso su quella rampa equivalente a 5.4 m
    // in piano. Ma Minetti ha misurato la CORSA su tapis roulant, mentre
    // oltre il 20-25% di pendenza qualunque atleta cammina, e la camminata
    // in salita ripida è molto più economica della corsa che il polinomio
    // estrapola. Senza questo tetto ogni rampa ripida verrebbe letta dal
    // motore come uno sforzo enormemente sopra soglia, svuoterebbe la
    // riserva anaerobica in pochi secondi e farebbe lampeggiare un allarme
    // "limite" su ogni muro del percorso: un falso positivo sistematico.
    //
    // Il valore 3.0 corrisponde a circa il 25% di pendenza, cioè al punto
    // in cui la transizione corsa/camminata è ormai avvenuta per tutti.
    const MODEL_MAX_RATIO as Float = 3.0;

    // ------------------------------------------------------------------
    // Costo energetico C(i) in J/kg/m alla pendenza data (frazione, non
    // percentuale: 0.12 = 12%).
    //
    //   C(i) = 155.4*i^5 - 30.4*i^4 - 43.3*i^3 + 46.3*i^2 + 19.5*i + 3.6
    // ------------------------------------------------------------------
    function cost(gradeFraction as Float) as Float {
        var i = gradeFraction;

        if (i > MAX_GRADE_FRACTION) {
            i = MAX_GRADE_FRACTION;
        } else if (i < -MAX_GRADE_FRACTION) {
            i = -MAX_GRADE_FRACTION;
        }

        var i2 = i * i;
        var i3 = i2 * i;
        var i4 = i3 * i;
        var i5 = i4 * i;

        var c = (155.4 * i5) - (30.4 * i4) - (43.3 * i3) + (46.3 * i2) + (19.5 * i) + FLAT_COST;

        // Protezione difensiva: dentro l'intervallo limitato sopra il
        // polinomio non si annulla mai, ma chi divide per questo valore
        // non deve doverci pensare.
        if (c < 0.1) {
            c = 0.1;
        }
        return c;
    }

    // ------------------------------------------------------------------
    // Rapporto C(i)/C(0): quanto costa un metro su questa pendenza
    // rispetto a un metro in piano. È il fattore che converte velocità
    // reale in velocità equivalente in piano, e passo reale in GAP.
    //
    // In salita è > 1 (si fa più fatica), in discesa < 1 fino a circa
    // -20% (dove tocca il minimo, circa 0.50), poi risale perché la
    // frenata eccentrica torna a costare.
    // ------------------------------------------------------------------
    function ratio(gradeFraction as Float) as Float {
        return cost(gradeFraction) / FLAT_COST;
    }

    // ------------------------------------------------------------------
    // Come ratio(), ma con il tetto MODEL_MAX_RATIO applicato al ramo in
    // salita. Da usare per tutto ciò che alimenta un MODELLO (bilancio
    // anaerobico, lavoro accumulato, calibrazione di CS), mai per il
    // valore di GAP mostrato all'utente.
    //
    // Sul ramo in discesa non c'è alcun tetto: lo "sconto" energetico
    // della discesa è reale dal punto di vista aerobico, ed è corretto
    // che il motore veda la discesa come recupero. Ciò che manca è il
    // costo MECCANICO della discesa (danno eccentrico ai quadricipiti),
    // che non è un costo aerobico e va modellato a parte.
    // ------------------------------------------------------------------
    function modelRatio(gradeFraction as Float) as Float {
        var r = ratio(gradeFraction);
        if (r > MODEL_MAX_RATIO) {
            r = MODEL_MAX_RATIO;
        }
        return r;
    }

}
