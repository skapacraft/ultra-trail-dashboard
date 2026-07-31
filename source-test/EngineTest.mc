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
// Test unitari del motore fisiologico.
//
// NON fanno parte dell'app pubblicata: questa cartella viene inclusa nella
// build solo passando anche test.jungle al compilatore (vedi il README).
// La build di rilascio usa il solo monkey.jungle e non vede nulla di
// quanto sta qui, quindi i test non costano un byte sull'orologio.
//
// Perché servono: le formule di questo motore producono numeri che sembrano
// plausibili anche quando sono sbagliati. Un segno invertito nel
// decadimento di durabilità, o un fattore 1000 sbagliato nel lavoro
// accumulato, non fa crashare nulla: fa semplicemente dire all'atleta una
// bugia, e ce ne accorgeremmo solo dopo una gara andata male. Un test che
// verifica un valore atteso calcolato a mano è l'unica difesa.
//
// Esecuzione:
//   monkeyc -f monkey.jungle -f test.jungle -o bin/test.prg \
//           -y developer_key -d fenix7 --unit-test
//   monkeydo bin/test.prg fenix7 -t

import Toybox.Lang;
import Toybox.Test;

// ----------------------------------------------------------------------
// Confronto tra numeri in virgola mobile. Il confronto esatto con == è
// inutilizzabile qui: ogni formula passa da polinomi e divisioni, e il
// risultato differisce dall'ultimo bit anche quando la matematica è giusta.
// ----------------------------------------------------------------------
function approx(actual as Float, expected as Float, tolerance as Float, label as String, logger as Logger) as Boolean {
    var delta = actual - expected;
    if (delta < 0.0) {
        delta = -delta;
    }
    if (delta > tolerance) {
        logger.error(Lang.format("$1$: atteso $2$, ottenuto $3$", [label, expected, actual]));
        return false;
    }
    return true;
}

// ======================================================================
// MinettiCost
// ======================================================================

// Il costo in piano è il valore di riferimento di tutto il modello: se
// cambia, ogni GAP e ogni bilancio energetico dell'app cambia con lui.
(:test)
function testMinettiFlatCost(logger as Logger) as Boolean {
    if (!approx(MinettiCost.cost(0.0), 3.6, 0.0001, "C(0)", logger)) { return false; }
    if (!approx(MinettiCost.ratio(0.0), 1.0, 0.0001, "ratio(0)", logger)) { return false; }
    return true;
}

// Valori calcolati a mano dal polinomio, non ricavati dal codice stesso:
// è il punto del test.
//   C(0.10) = 155.4*1e-5 - 30.4*1e-4 - 43.3*1e-3 + 46.3*0.01 + 1.95 + 3.6
//           = 5.968 J/kg/m
//   C(-0.20) = 1.800 J/kg/m  (il minimo della curva, dove la discesa costa
//              la metà del piano prima che la frenata torni a pesare)
(:test)
function testMinettiKnownPoints(logger as Logger) as Boolean {
    if (!approx(MinettiCost.cost(0.10), 5.968, 0.001, "C(+10%)", logger)) { return false; }
    if (!approx(MinettiCost.cost(-0.20), 1.800, 0.001, "C(-20%)", logger)) { return false; }
    if (!approx(MinettiCost.ratio(-0.20), 0.500, 0.001, "ratio(-20%)", logger)) { return false; }
    return true;
}

// Oltre il 45% il polinomio non è più validato: la pendenza va appiattita
// sul limite, non estrapolata.
(:test)
function testMinettiClampsBeyondValidRange(logger as Logger) as Boolean {
    var atLimit = MinettiCost.cost(0.45);
    var beyondLimit = MinettiCost.cost(0.90);
    if (!approx(beyondLimit, atLimit, 0.0001, "C oltre il limite", logger)) { return false; }

    var atLimitDown = MinettiCost.cost(-0.45);
    var beyondLimitDown = MinettiCost.cost(-0.90);
    if (!approx(beyondLimitDown, atLimitDown, 0.0001, "C oltre il limite in discesa", logger)) { return false; }
    return true;
}

// Il tetto del modello deve agire SOLO in salita. In discesa lo sconto
// energetico è reale e non va toccato.
(:test)
function testMinettiModelRatioCap(logger as Logger) as Boolean {
    // A +45% il rapporto grezzo vale circa 5.4: il modello lo deve vedere
    // come 3.0, altrimenti ogni muro ripido affrontato camminando
    // risulterebbe uno sforzo enormemente sopra soglia.
    if (MinettiCost.ratio(0.45) < 5.0) {
        logger.error("il rapporto grezzo a +45% dovrebbe superare 5");
        return false;
    }
    if (!approx(MinettiCost.modelRatio(0.45), 3.0, 0.0001, "modelRatio(+45%)", logger)) { return false; }

    // Sotto il tetto i due rapporti devono coincidere.
    if (!approx(MinettiCost.modelRatio(0.10), MinettiCost.ratio(0.10), 0.0001, "modelRatio(+10%)", logger)) { return false; }

    // In discesa nessun tetto.
    if (!approx(MinettiCost.modelRatio(-0.20), 0.500, 0.001, "modelRatio(-20%)", logger)) { return false; }
    return true;
}

// ======================================================================
// EnduranceEngine
// ======================================================================

// Una velocità critica implausibile (o assente) non deve produrre un
// modello "quasi giusto": deve produrre nessun modello, così la View
// mostra "--" invece di un numero inventato.
(:test)
function testEngineRejectsImplausibleAthlete(logger as Logger) as Boolean {
    var engine = new EnduranceEngine();

    engine.setAthlete(0.0, 200.0, 0.08);
    if (engine.hasModel()) {
        logger.error("velocità critica nulla accettata");
        return false;
    }

    engine.setAthlete(12.0, 200.0, 0.08); // più veloce del record del mondo sui 100 m
    if (engine.hasModel()) {
        logger.error("velocità critica assurda accettata");
        return false;
    }

    engine.setAthlete(3.0, 200.0, 0.08);
    if (!engine.hasModel()) {
        logger.error("velocità critica plausibile rifiutata");
        return false;
    }
    return true;
}

// Sopra soglia la riserva si consuma alla velocità del sorpasso, e il
// tempo al cedimento è semplicemente quanto ci vuole a svuotarla.
// CS = 3.0 m/s, D' = 200 m, si corre a 4.0 m/s per 10 s:
//   consumo   = (4.0 - 3.0) * 10 = 10 m
//   riserva   = 200 - 10 = 190 m  (95%)
//   cedimento = 190 / 1.0 = 190 s
(:test)
function testEngineDrainsReserveAboveThreshold(logger as Logger) as Boolean {
    var engine = new EnduranceEngine();
    engine.setAthlete(3.0, 200.0, 0.0); // durabilità disattivata per isolare il bilancio

    engine.update(4.0, 10.0);

    if (!approx(engine.getReservePercent(), 95.0, 0.1, "riserva", logger)) { return false; }

    var ttf = engine.getTimeToFailureSec();
    if (ttf == null) {
        logger.error("nessun tempo al cedimento sopra soglia");
        return false;
    }
    if (!approx(ttf, 190.0, 0.5, "tempo al cedimento", logger)) { return false; }
    return true;
}

// Sotto soglia la riserva si ricarica e il tempo al cedimento non esiste:
// restituire 0, o un numero enorme, sarebbe inventarsi un dato.
(:test)
function testEngineRechargesBelowThreshold(logger as Logger) as Boolean {
    var engine = new EnduranceEngine();
    engine.setAthlete(3.0, 200.0, 0.0);

    engine.update(4.0, 60.0); // svuota parzialmente
    var drained = engine.getReservePercent();
    if (drained >= 100.0) {
        logger.error("la riserva non si è consumata");
        return false;
    }

    if (engine.getTimeToFailureSec() == null) {
        logger.error("nessun tempo al cedimento durante lo sforzo");
        return false;
    }

    engine.update(2.0, 60.0); // recupero sotto soglia
    if (engine.getReservePercent() <= drained) {
        logger.error("la riserva non si è ricaricata sotto soglia");
        return false;
    }
    if (engine.getTimeToFailureSec() != null) {
        logger.error("tempo al cedimento presente sotto soglia");
        return false;
    }
    return true;
}

// Il caso del ristoro: fermi con il timer avviato. Il recupero è massimo,
// e il lavoro accumulato non cresce. Sembra ovvio, ma la prima stesura
// della View saltava del tutto l'aggiornamento del motore a velocità nulla,
// congelando il bilancio proprio nei minuti in cui l'atleta recupera di più.
(:test)
function testEngineRecoversWhenStationary(logger as Logger) as Boolean {
    var engine = new EnduranceEngine();
    engine.setAthlete(3.0, 200.0, 0.08);

    engine.update(4.5, 100.0); // sforzo che consuma riserva
    var drained = engine.getReservePercent();
    var workAfterEffort = engine.getWorkKjPerKg();

    engine.update(0.0, 120.0); // due minuti fermi al ristoro

    if (engine.getReservePercent() <= drained) {
        logger.error("nessun recupero da fermo");
        return false;
    }
    if (!approx(engine.getWorkKjPerKg(), workAfterEffort, 0.001, "lavoro da fermo", logger)) { return false; }
    if (engine.getTimeToFailureSec() != null) {
        logger.error("tempo al cedimento presente da fermo");
        return false;
    }
    return true;
}

// La riserva non può scendere sotto zero né superare D'.
(:test)
function testEngineReserveStaysInRange(logger as Logger) as Boolean {
    var engine = new EnduranceEngine();
    engine.setAthlete(3.0, 200.0, 0.0);

    engine.update(6.0, 600.0); // sforzo insostenibile e prolungato
    if (engine.getReservePercent() < 0.0) {
        logger.error("riserva negativa");
        return false;
    }
    if (!approx(engine.getReservePercent(), 0.0, 0.001, "riserva a fondo", logger)) { return false; }

    engine.update(1.0, 100000.0); // recupero lunghissimo
    if (engine.getReservePercent() > 100.0) {
        logger.error("riserva oltre il massimo");
        return false;
    }
    return true;
}

// Il lavoro accumulato è l'integrale della potenza metabolica:
//   3.6 J/kg/m * 2.5 m/s = 9 W/kg, per 1000 s = 9 kJ/kg
(:test)
function testEngineAccumulatesWork(logger as Logger) as Boolean {
    var engine = new EnduranceEngine();
    engine.setAthlete(3.0, 200.0, 0.0);

    engine.update(2.5, 1000.0);
    if (!approx(engine.getWorkKjPerKg(), 9.0, 0.01, "lavoro accumulato", logger)) { return false; }
    return true;
}

// IL TEST PIÙ IMPORTANTE DELL'APP.
// È la durabilità a distinguere questo motore da Xert, Stryd e dalla
// Stamina nativa Garmin, che trattano tutti la soglia come una costante.
// Con un fattore del 10% ogni 100 kJ/kg, dopo esattamente 100 kJ/kg di
// lavoro la velocità sostenibile deve valere il 90% di quella iniziale.
//
//   3.6 J/kg/m * 2.5 m/s = 9 W/kg
//   100 kJ/kg / 9 W/kg   = 11111.11 s
//   CS attesa            = 3.0 * 0.90 = 2.70 m/s
(:test)
function testEngineDurabilityDecay(logger as Logger) as Boolean {
    var engine = new EnduranceEngine();
    engine.setAthlete(3.0, 200.0, 0.10);

    if (!approx(engine.getSustainableSpeed(), 3.0, 0.001, "CS a riposo", logger)) { return false; }

    engine.update(2.5, 11111.11);

    if (!approx(engine.getWorkKjPerKg(), 100.0, 0.05, "lavoro a 100 kJ/kg", logger)) { return false; }
    if (!approx(engine.getSustainableSpeed(), 2.70, 0.005, "CS dopo 100 kJ/kg", logger)) { return false; }
    return true;
}

// Un fattore di durabilità a zero deve riportare esattamente il
// comportamento classico a soglia costante: è ciò che l'utente ottiene
// mettendo 0 nelle impostazioni, e deve funzionare davvero.
(:test)
function testEngineDurabilityDisabled(logger as Logger) as Boolean {
    var engine = new EnduranceEngine();
    engine.setAthlete(3.0, 200.0, 0.0);

    engine.update(2.5, 50000.0);
    if (!approx(engine.getSustainableSpeed(), 3.0, 0.001, "CS con durabilità disattivata", logger)) { return false; }
    return true;
}

// Il decadimento non deve poter azzerare la velocità sostenibile: sotto il
// pavimento del 60% ogni singolo passo risulterebbe sopra soglia e il campo
// diventerebbe un allarme permanente, cioè rumore.
(:test)
function testEngineDurabilityFloor(logger as Logger) as Boolean {
    var engine = new EnduranceEngine();
    engine.setAthlete(3.0, 200.0, 0.25); // il massimo consentito dalle impostazioni

    engine.update(2.5, 100000.0); // circa 900 kJ/kg, ben oltre qualunque ultra
    if (!approx(engine.getSustainableSpeed(), 1.80, 0.001, "pavimento del decadimento", logger)) { return false; }
    return true;
}

// Cambiare D' a metà attività non deve regalare né togliere energia:
// la riserva va conservata come frazione, non come valore assoluto.
(:test)
function testEnginePreservesReserveFractionOnReconfigure(logger as Logger) as Boolean {
    var engine = new EnduranceEngine();
    engine.setAthlete(3.0, 200.0, 0.0);

    engine.update(4.0, 100.0); // riserva a 100/200 = 50%
    if (!approx(engine.getReservePercent(), 50.0, 0.1, "riserva prima", logger)) { return false; }

    engine.setAthlete(3.0, 300.0, 0.0);
    if (!approx(engine.getReservePercent(), 50.0, 0.1, "riserva dopo", logger)) { return false; }
    return true;
}

// reset() azzera l'attività ma non l'atleta.
(:test)
function testEngineResetClearsSessionOnly(logger as Logger) as Boolean {
    var engine = new EnduranceEngine();
    engine.setAthlete(3.0, 200.0, 0.10);

    engine.update(4.0, 500.0);
    engine.reset();

    if (!approx(engine.getWorkKjPerKg(), 0.0, 0.001, "lavoro dopo reset", logger)) { return false; }
    if (!approx(engine.getReservePercent(), 100.0, 0.001, "riserva dopo reset", logger)) { return false; }
    if (!approx(engine.getSustainableSpeed(), 3.0, 0.001, "CS dopo reset", logger)) { return false; }
    if (!engine.hasModel()) {
        logger.error("il reset ha cancellato anche l'atleta");
        return false;
    }
    return true;
}

// ======================================================================
// FuelModel
// ======================================================================

// Il consumo di carboidrati a soglia, calcolato a mano:
//   potenza metabolica = 3.6 J/kg/m * 3.0 m/s      = 10.8 W/kg
//   su 70 kg                                        = 756 W
//   frazione da carboidrati a intensità 1.0         = 0.78
//   energia da carboidrati                          = 589.7 J/s
//   diviso 17.5 kJ per grammo                       = 0.0337 g/s
//   in un'ora                                       = 121.3 g/h
(:test)
function testFuelOxidationAtThreshold(logger as Logger) as Boolean {
    var fuel = new FuelModel();
    fuel.setAthlete(70.0, 0.0);

    fuel.update(10.8, 1.0, 1.0);

    if (!approx(fuel.getOxidationGramsPerHour(), 121.3, 1.0, "consumo a soglia", logger)) { return false; }
    return true;
}

// La curva di utilizzo dei carboidrati deve essere monotona crescente e
// rispettare i due estremi: a bassissima intensità prevalgono i grassi, a
// intensità alta quasi tutta l'energia viene dagli zuccheri.
//   a 155.5 g/h corrisponderebbe una frazione di 1.0, quindi la frazione
//   attesa si legge dividendo il consumo per 155.5
(:test)
function testFuelCarbFractionCurve(logger as Logger) as Boolean {
    var fuel = new FuelModel();
    fuel.setAthlete(70.0, 0.0);

    fuel.update(10.8, 0.20, 1.0);
    var veryEasy = fuel.getOxidationGramsPerHour();
    if (!approx(veryEasy / 155.5, 0.20, 0.02, "frazione a intensità 0.2", logger)) { return false; }

    fuel.update(10.8, 0.90, 1.0);
    var moderate = fuel.getOxidationGramsPerHour();
    if (!approx(moderate / 155.5, 0.68, 0.02, "frazione a intensità 0.9", logger)) { return false; }

    fuel.update(10.8, 2.0, 1.0);
    var hard = fuel.getOxidationGramsPerHour();
    if (!approx(hard / 155.5, 0.95, 0.02, "frazione a intensità 2.0", logger)) { return false; }

    if (!(veryEasy < moderate && moderate < hard)) {
        logger.error("la curva dei carboidrati non è monotona");
        return false;
    }
    return true;
}

// Senza mangiare, la riserva di un atleta di 70 kg (490 g) dura poco più di
// quattro ore a soglia: 490 / 0.0337 = 14540 s.
(:test)
function testFuelDepletionWithoutIntake(logger as Logger) as Boolean {
    var fuel = new FuelModel();
    fuel.setAthlete(70.0, 0.0);

    fuel.update(10.8, 1.0, 1.0);

    var ttd = fuel.getTimeToDepletionSec();
    if (ttd == null) {
        logger.error("nessun tempo all'esaurimento senza alimentazione");
        return false;
    }
    if (!approx(ttd, 14540.0, 100.0, "tempo all'esaurimento", logger)) { return false; }
    if (!approx(fuel.getRemainingPercent(), 100.0, 0.1, "riserva iniziale", logger)) { return false; }
    return true;
}

// IL RITARDO GASTRICO, che è ciò che distingue questo modello da un timer.
// Con 60 g/h per un'ora si ingeriscono 60 g, ma lo stomaco ne trattiene
// circa 19 (il regime è 60/3600 * 1200 = 20 g, raggiunto a tre costanti di
// tempo), quindi ne arrivano in circolo circa 41. Un modello che ignorasse
// il transito ne conterebbe 60, e direbbe all'atleta che è a posto mentre
// è già in debito.
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
    if (!approx(absorbed, 41.0, 2.0, "assorbito in un'ora", logger)) { return false; }

    // E nel primo minuto non deve essere arrivato quasi nulla.
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
        logger.error(Lang.format("assorbiti $1$ g nel primo minuto, il transito non viene applicato", [earlyAbsorbed]));
        return false;
    }
    return true;
}

// Mangiare più del tetto di assorbimento non produce energia: il modello
// deve tagliare l'assunzione, non accumulare all'infinito nello stomaco.
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

    if (!approx(capped.getRemainingGrams(), atCap.getRemainingGrams(), 0.5, "tetto di assorbimento", logger)) { return false; }
    return true;
}

// Se si mangia abbastanza da coprire il consumo, non esiste un tempo
// all'esaurimento: restituire un numero enorme sarebbe rumore.
(:test)
function testFuelNoDepletionWhenIntakeCoversBurn(logger as Logger) as Boolean {
    var fuel = new FuelModel();
    fuel.setAthlete(70.0, 90.0);

    // Intensità bassa: il consumo di carboidrati è molto sotto i 90 g/h.
    for (var t = 0; t < 3600; t++) {
        fuel.update(4.0, 0.30, 1.0);
    }

    if (fuel.getTimeToDepletionSec() != null) {
        logger.error("tempo all'esaurimento presente mentre si mangia più di quanto si consuma");
        return false;
    }
    return true;
}

// ======================================================================
// EccentricModel
// ======================================================================

// Conto a mano su una pendenza scelta per avere numeri esatti.
// Pendenza -75%: il seno vale 0.75 / sqrt(1 + 0.5625) = 0.75 / 1.25 = 0.60.
//   quota persa al secondo   = 1.0 m/s * 0.60           = 0.60 m/s
//   peso a 1 m/s             = 1 + 0.5 * (1/3)          = 1.1667
//   metri equivalenti al sec = 0.60 * 1.1667            = 0.70 m/s
// Su 100 secondi: 70 m equivalenti, 60 m di dislivello grezzo.
(:test)
function testEccentricAccumulation(logger as Logger) as Boolean {
    var ecc = new EccentricModel();
    ecc.setCapacity(3000.0);

    ecc.update(1.0, -0.75, 100.0);

    if (!approx(ecc.getEquivalentMeters(), 70.0, 0.1, "metri equivalenti", logger)) { return false; }
    if (!approx(ecc.getDescentMeters(), 60.0, 0.1, "dislivello grezzo", logger)) { return false; }
    if (!approx(ecc.getRemainingPercent(), 97.667, 0.05, "capacità residua", logger)) { return false; }

    var ttl = ecc.getTimeToLimitSec();
    if (ttl == null) {
        logger.error("nessun tempo al limite mentre si scende");
        return false;
    }
    if (!approx(ttl, 4185.7, 5.0, "tempo al limite", logger)) { return false; }
    return true;
}

// In salita e in piano il danno eccentrico non cresce. Non è una
// semplificazione: la contrazione eccentrica del quadricipite è specifica
// della frenata in discesa.
(:test)
function testEccentricIgnoresUphillAndFlat(logger as Logger) as Boolean {
    var ecc = new EccentricModel();
    ecc.setCapacity(3000.0);

    ecc.update(3.0, 0.20, 600.0);  // salita
    ecc.update(3.0, 0.0, 600.0);   // piano

    if (!approx(ecc.getEquivalentMeters(), 0.0, 0.001, "accumulo in salita e piano", logger)) { return false; }
    if (ecc.getTimeToLimitSec() != null) {
        logger.error("tempo al limite presente mentre non si scende");
        return false;
    }
    return true;
}

// IL PUNTO DEL MODELLO: a parità di quota persa, scendere veloce costa più
// che scendere piano. Se questa proprietà cadesse, il campo sarebbe solo un
// contatore di dislivello negativo, cioè un dato che l'orologio dà già.
(:test)
function testEccentricPenalisesFastDescending(logger as Logger) as Boolean {
    var slow = new EccentricModel();
    slow.setCapacity(3000.0);
    var fast = new EccentricModel();
    fast.setCapacity(3000.0);

    // Stessa quota persa (60 m), tempi diversi: 1 m/s per 100 s contro
    // 4 m/s per 25 s.
    slow.update(1.0, -0.75, 100.0);
    fast.update(4.0, -0.75, 25.0);

    if (!approx(slow.getDescentMeters(), fast.getDescentMeters(), 0.1, "quota persa uguale", logger)) { return false; }

    if (!(fast.getEquivalentMeters() > slow.getEquivalentMeters())) {
        logger.error("scendere veloce non pesa più che scendere piano");
        return false;
    }

    // peso lento = 1.1667, peso veloce = 1 + 0.5*(4/3) = 1.6667
    if (!approx(fast.getEquivalentMeters() / slow.getEquivalentMeters(), 1.4286, 0.01, "rapporto tra i pesi", logger)) { return false; }
    return true;
}

// Il fattore di peso ha un tetto: oltre una certa velocità il modello
// smetterebbe di essere credibile.
(:test)
function testEccentricWeightIsCapped(logger as Logger) as Boolean {
    var ecc = new EccentricModel();
    ecc.setCapacity(3000.0);

    // A 20 m/s il peso grezzo varrebbe 4.33, deve valere 2.0.
    // quota persa al secondo = 20 * 0.6 = 12 m/s, per 1 s = 12 m
    // metri equivalenti      = 12 * 2.0 = 24 m
    ecc.update(20.0, -0.75, 1.0);

    if (!approx(ecc.getEquivalentMeters(), 24.0, 0.1, "tetto del fattore di peso", logger)) { return false; }
    return true;
}

// La capacità residua non può uscire dall'intervallo 0-100 nemmeno dopo una
// discesa che sfonda ampiamente il limite impostato.
(:test)
function testEccentricRemainingStaysInRange(logger as Logger) as Boolean {
    var ecc = new EccentricModel();
    ecc.setCapacity(500.0);

    ecc.update(3.0, -0.75, 10000.0);

    var remaining = ecc.getRemainingPercent();
    if (remaining < 0.0 || remaining > 100.0) {
        logger.error(Lang.format("capacità residua fuori scala: $1$", [remaining]));
        return false;
    }
    if (!approx(remaining, 0.0, 0.001, "capacità azzerata", logger)) { return false; }

    var ttl = ecc.getTimeToLimitSec();
    if (ttl == null) {
        logger.error("tempo al limite assente mentre si continua a scendere");
        return false;
    }
    if (!approx(ttl, 0.0, 0.001, "tempo al limite a capacità esaurita", logger)) { return false; }
    return true;
}

// ======================================================================
// SpeedCalibration
// ======================================================================

// A velocità costante la retta d(t) = CS*t + D' degenera in una retta per
// l'origine: la pendenza è la velocità stessa e D' vale zero.
(:test)
function testCalibrationConstantSpeed(logger as Logger) as Boolean {
    var cal = new SpeedCalibration();
    cal.clear();
    cal.resetSession();

    if (cal.isValid()) {
        logger.error("calibrazione dichiarata valida senza dati");
        return false;
    }

    // 20 minuti a 3.0 m/s, un campione al secondo.
    for (var t = 0; t < 1200; t++) {
        cal.update(3.0, 1.0);
    }

    if (!cal.isValid()) {
        logger.error("calibrazione non valida dopo 20 minuti di dati");
        return false;
    }
    if (!approx(cal.getCriticalSpeed(), 3.0, 0.01, "CS a velocità costante", logger)) { return false; }
    if (!approx(cal.getDPrime(), 0.0, 1.0, "D' a velocità costante", logger)) { return false; }

    cal.clear();
    return true;
}

// Caso realistico: fondo costante più un allungo finale di 3 minuti.
//   record 3 min  = 4.0 * 180 = 720 m
//   record 12 min = 3.0 * 540 + 4.0 * 180 = 2340 m
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
        logger.error("calibrazione non valida dopo fondo e allungo");
        return false;
    }
    if (!approx(cal.getCriticalSpeed(), 3.0, 0.02, "CS con allungo", logger)) { return false; }
    if (!approx(cal.getDPrime(), 180.0, 5.0, "D' con allungo", logger)) { return false; }

    cal.clear();
    return true;
}

// Una sessione troppo breve non produce una stima: nessun dato è meglio di
// un dato inventato su una finestra mai completata.
(:test)
function testCalibrationRejectsShortSession(logger as Logger) as Boolean {
    var cal = new SpeedCalibration();
    cal.clear();
    cal.resetSession();

    for (var t = 0; t < 300; t++) { // 5 minuti: la finestra da 12 non si chiude mai
        cal.update(3.0, 1.0);
    }

    if (cal.isValid()) {
        logger.error("stima prodotta senza una finestra da 12 minuti");
        return false;
    }

    cal.clear();
    return true;
}

// resetSession() azzera la corsa ma NON i record personali: sono la
// memoria di lungo periodo dell'atleta e devono sopravvivere all'attività.
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
        logger.error("record persi al reset della sessione");
        return false;
    }
    if (!approx(cal.getCriticalSpeed(), csBefore, 0.001, "CS dopo reset sessione", logger)) { return false; }

    cal.clear();
    return true;
}
