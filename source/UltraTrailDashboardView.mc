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
// Cuore dell'applicazione "Ultra-Trail Dashboard".
//
// Un Campo Dati Connect IQ di tipo "Complex Data Field" estende la classe
// WatchUi.DataField e riceve due eventi principali dal sistema:
//
//   - compute(info)  -> chiamato 1 volta al secondo, riceve i dati grezzi
//                        dell'attività (passo, quota, distanza, HR, ...).
//                        Qui facciamo TUTTI i calcoli (pendenza, GAP,
//                        aggiornamento del motore fisiologico) e scriviamo
//                        i valori nel file FIT.
//
//   - onUpdate(dc)    -> chiamato ogni volta che lo schermo deve essere
//                        ridisegnato. Qui NON facciamo calcoli: disegniamo
//                        solamente le stringhe già pronte, calcolate in
//                        compute(). Questo è fondamentale per le
//                        performance sui Forerunner (meno RAM/CPU della
//                        serie Fenix).
//
// REGOLA D'ORO SULLA MEMORIA:
// dentro onUpdate() non creiamo MAI nuovi oggetti, array o stringhe.
// Tutto ciò che serve (array a dimensione fissa, stringhe formattate) è
// allocato una sola volta in initialize() oppure ricalcolato in compute()
// (che gira comunque solo 1 volta al secondo, non ad ogni frame).
//
// ARCHITETTURA A LIVELLI:
// questa View è il livello 0 (sensori) e il livello 4 (decisione). In mezzo
// stanno tre componenti separati, uno per file:
//   MinettiCost        livello 1, il costo energetico della pendenza
//   EnduranceEngine    livello 2 e 3, lo stato fisiologico e la previsione
//   SpeedCalibration   stima automatica dei parametri dell'atleta

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
    // SORGENTI DISPONIBILI PER I QUADRANTI
    // ------------------------------------------------------------------
    // L'utente sceglie da Garmin Connect Mobile quale grandezza mostrare in
    // ognuno dei 4 quadranti. Questi numeri sono il contratto con
    // resources/settings/settings.xml: i <listEntry value="..."> devono
    // combaciare, e i valori NON vanno mai riordinati dopo una
    // pubblicazione, altrimenti la configurazione già salvata sugli
    // orologi degli utenti si ritroverebbe a puntare al campo sbagliato.
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

    // Quale sistema fisiologico sta limitando l'atleta in questo momento.
    //
    // È il cuore del campo LIMITE: invece di sommare grandezze diverse in
    // un indice inventato, ogni sottosistema dichiara quanto manca al
    // proprio cedimento, e mostriamo il minimo insieme al nome di chi lo
    // impone. Il limite non è un punteggio, è il primo sistema che cede, e
    // sapere QUALE è ciò che dice all'atleta cosa fare: rallentare, mangiare,
    // o frenare meno in discesa. Sono tre azioni diverse, e un indice unico
    // non saprebbe distinguerle.
    private const BIND_NONE as Number = 0;
    private const BIND_ANAEROBIC as Number = 1;
    private const BIND_CARB as Number = 2;
    private const BIND_QUADS as Number = 3;

    // Numero di quadranti sullo schermo. Non è configurabile: la griglia
    // 2x2 è ciò che rende il campo leggibile a colpo d'occhio in corsa.
    private const QUADRANT_COUNT as Number = 4;

    // Livelli di allerta usati per colorare un valore. Sono il "livello 4"
    // dell'architettura: la traduzione da numero a giudizio.
    private const LEVEL_NORMAL as Number = 0;
    private const LEVEL_WARNING as Number = 1;
    private const LEVEL_DANGER as Number = 2;

    // ------------------------------------------------------------------
    // COSTANTI DI CONFIGURAZIONE
    // ------------------------------------------------------------------

    // Dimensione MASSIMA dell'array di storico (allocato una sola volta,
    // a dimensione fissa, in initialize()). L'utente può scegliere una
    // finestra di smoothing più corta da Garmin Connect Mobile (vedi
    // resources/properties/properties.xml e resources/settings/settings.xml),
    // ma mai più lunga di questo limite: qui decidiamo quanta RAM riservare
    // in anticipo, senza mai riallocare array durante l'attività.
    private const MAX_HISTORY_SIZE as Number = 30;

    // Limiti ammessi per la finestra di smoothing configurabile dall'utente
    // (in secondi). Devono combaciare con min/max in settings.xml, così la
    // UI di Garmin Connect Mobile e la logica dell'app restano coerenti.
    private const MIN_HISTORY_SIZE as Number = 3;
    private const DEFAULT_HISTORY_SIZE as Number = 10;

    // Sotto questa distanza percorsa (in metri) all'interno della finestra
    // di smoothing, il calcolo della pendenza sarebbe troppo "rumoroso"
    // (rischio di dividere per un numero quasi zero): in quel caso teniamo
    // semplicemente l'ultimo valore di pendenza valido calcolato.
    private const MIN_DISTANCE_FOR_GRADE as Float = 3.0;

    // Soglie di pendenza (valore assoluto, in percentuale) oltre le quali
    // coloriamo il valore della pendenza per attirare l'attenzione senza
    // dover "leggere" il numero, utile a fine ultra quando la lucidità
    // cala. Sopra GRADE_DANGER_THRESHOLD il colore è più acceso di sopra
    // GRADE_WARNING_THRESHOLD.
    private const GRADE_WARNING_THRESHOLD as Float = 12.0;
    private const GRADE_DANGER_THRESHOLD as Float = 20.0;
    private const GRADE_HYSTERESIS as Float = 1.5;

    // Soglie di allerta sulla riserva anaerobica residua (in percentuale).
    private const RESERVE_WARNING_THRESHOLD as Float = 50.0;
    private const RESERVE_DANGER_THRESHOLD as Float = 25.0;
    private const RESERVE_HYSTERESIS as Float = 5.0;

    // Soglie di allerta sulla percentuale residua di carboidrati e di
    // capacità di discesa.
    private const FUEL_WARNING_THRESHOLD as Float = 40.0;
    private const FUEL_DANGER_THRESHOLD as Float = 20.0;
    private const FUEL_HYSTERESIS as Float = 5.0;

    // Soglie di allerta sul tempo al cedimento, in secondi.
    //
    // Sono DUE serie diverse, e la ragione è di progetto, non di comodo:
    // la soglia di allarme deve valere quanto il tempo necessario a
    // rimediare. Un limite anaerobico si risolve in pochi secondi,
    // rallentando: tre minuti di preavviso bastano e avanzano. Un
    // esaurimento di carboidrati richiede di mangiare e aspettare venti
    // minuti che l'intestino assorba, e le gambe rovinate dalla discesa
    // non si recuperano affatto: lì tre minuti di preavviso sarebbero
    // inutili quanto nessun preavviso. Da cui mezz'ora e dieci minuti.
    private const ANAEROBIC_WARNING_SEC as Float = 180.0;
    private const ANAEROBIC_DANGER_SEC as Float = 60.0;
    private const ANAEROBIC_HYSTERESIS_SEC as Float = 15.0;
    private const SLOW_WARNING_SEC as Float = 1800.0;
    private const SLOW_DANGER_SEC as Float = 600.0;
    private const SLOW_HYSTERESIS_SEC as Float = 120.0;

    // Tempo massimo (in secondi) accettato come singolo passo di
    // integrazione del motore. compute() dovrebbe girare a 1 Hz, ma il
    // sistema può saltare cicli quando è sotto carico, e info.timerTime
    // fa un salto netto se l'utente resta in pausa a lungo. Senza questo
    // tetto, una pausa di venti minuti verrebbe integrata tutta in un
    // colpo solo e svuoterebbe la riserva istantaneamente.
    private const MAX_DT_SEC as Float = 5.0;

    // Ogni quanti secondi ricontrolliamo se la calibrazione automatica è
    // diventata utilizzabile. Serve solo nel caso in cui il motore fosse
    // partito SENZA modello: appena la calibrazione diventa valida, il
    // campo smette di mostrare "--" e inizia a funzionare.
    private const CALIBRATION_CHECK_PERIOD_SEC as Number = 30;

    // Distanza (in metri) di riferimento per calcolare il passo: 1000 se
    // l'utente usa unità metriche, 1609.344 (miglio) se usa quelle
    // imperiali. Determinata una sola volta in initialize() leggendo le
    // impostazioni di sistema del dispositivo.
    private const METERS_PER_KILOMETER as Float = 1000.0;
    private const METERS_PER_MILE as Float = 1609.344;

    // Identificativi dei campi personalizzati scritti nel file FIT.
    // Connect IQ ne consente al massimo 16 per app: questi sei sono spesi
    // per lo STATO DEL MODELLO, non per metriche di contorno. È ciò che
    // permetterà, a posteriori, di ricalibrare i parametri dell'atleta
    // confrontando la previsione con l'esito reale della gara.
    private const FIT_FIELD_GAP as Number = 0;
    private const FIT_FIELD_RESERVE as Number = 1;
    private const FIT_FIELD_SUSTAIN as Number = 2;
    private const FIT_FIELD_WORK as Number = 3;
    private const FIT_FIELD_CS as Number = 4;
    private const FIT_FIELD_DPRIME as Number = 5;
    private const FIT_FIELD_CARB as Number = 6;
    private const FIT_FIELD_ECCENTRIC as Number = 7;

    // ------------------------------------------------------------------
    // STATO INTERNO (allocato UNA SOLA VOLTA in initialize())
    // ------------------------------------------------------------------

    // Campi personalizzati scritti nel file .FIT.
    // Tutti nullable per scelta: se createField() dovesse fallire su un
    // dispositivo/firmware particolare, l'app continua a funzionare come
    // display invece di andare in crash alla prima scrittura. Si perde
    // solo la registrazione di quel campo nel FIT.
    private var mGapField as FitContributor.Field?;
    private var mReserveField as FitContributor.Field?;
    private var mSustainField as FitContributor.Field?;
    private var mWorkField as FitContributor.Field?;
    private var mCsField as FitContributor.Field?;
    private var mDPrimeField as FitContributor.Field?;
    private var mCarbField as FitContributor.Field?;
    private var mEccentricField as FitContributor.Field?;

    // I tre modelli fisiologici e la calibrazione automatica.
    //
    // Sono deliberatamente separati e indipendenti: ognuno integra il
    // proprio stato e dichiara il proprio tempo al cedimento, senza sapere
    // nulla degli altri. È ciò che permette di aggiungerne un quarto
    // (il carico termico) senza toccare i tre esistenti, e di far cadere
    // uno dei tre senza che gli altri smettano di funzionare.
    private var mEngine as EnduranceEngine;
    private var mCalibration as SpeedCalibration;
    private var mFuel as FuelModel;
    private var mEccentric as EccentricModel;

    // Vincolo dominante: quanto manca al primo cedimento e quale sistema
    // lo impone. Ricalcolati in compute(), letti da updateQuadrant().
    private var mBindingTtfSec as Float?;
    private var mBindingKind as Number;

    // Etichette del campo LIMITE, precaricate una sola volta perché
    // cambiano a ogni secondo insieme al vincolo dominante: ricaricarle
    // dalle risorse a ogni compute() allocherebbe una stringa al secondo.
    private var mLabelLimit as String;
    private var mLabelAnaerobic as String;
    private var mLabelCarb as String;
    private var mLabelQuads as String;

    // Array circolari a dimensione FISSA per lo storico di quota e
    // distanza, usati per calcolare la pendenza stabilizzata.
    private var mAltHistory as Array<Float>;
    private var mDistHistory as Array<Float>;

    // Indice della prossima cella da scrivere nell'array circolare, e
    // numero di campioni validi attualmente presenti (serve finché il
    // buffer non si è riempito la prima volta).
    private var mHistIndex as Number;
    private var mHistCount as Number;

    // Dimensione EFFETTIVA della finestra di smoothing in uso (in secondi),
    // letta dalle impostazioni utente e sempre compresa tra MIN_HISTORY_SIZE
    // e MAX_HISTORY_SIZE. È una sotto-porzione degli array mAltHistory/
    // mDistHistory, che restano allocati a MAX_HISTORY_SIZE per tutta la
    // durata dell'app.
    private var mHistorySize as Number;

    // Ultimi valori calcolati (aggiornati in compute(), letti in onUpdate()).
    // Il "passo" è espresso in secondi per unità di distanza configurata
    // dall'utente (km o miglio, vedi mUnitDistanceMeters): il calcolo del
    // GAP resta identico in entrambi i casi, perché la formula di Minetti
    // lavora su un RAPPORTO tra costi energetici, non su un'unità fissa.
    private var mSmoothedGradePercent as Float;
    private var mGapPaceSecPerUnit as Float;

    // Passo attuale e frequenza cardiaca dell'ultimo compute(): li teniamo
    // come campi perché updateQuadrant() ne ha bisogno per qualunque
    // quadrante l'utente abbia configurato.
    private var mCurrentPaceSecPerUnit as Float;
    private var mHasValidPace as Boolean;
    private var mHeartRate as Number?;

    // Diventa true solo dopo il PRIMO GAP calcolato su un passo valido.
    // Finché resta false non scriviamo nulla nel file FIT: scrivere 0.0
    // mentre si è fermi in partenza registrerebbe uno zero come se fosse
    // un dato reale, creando un picco nel grafico di Garmin Connect e
    // falsando le medie dell'attività.
    private var mHasValidGap as Boolean;

    // Valore di info.timerTime (millisecondi) all'ultimo compute(), usato
    // per ricavare il passo di integrazione reale del motore. Vale -1
    // finché non abbiamo ancora visto un campione.
    //
    // Perché timerTime e non "un secondo per chiamata": timerTime NON
    // avanza quando il timer dell'attività è in pausa, mentre compute()
    // continua a essere chiamato. Usarlo come orologio del modello fa sì
    // che una sosta a un ristoro non consumi riserva anaerobica e non
    // accumuli lavoro, che è esattamente il comportamento fisiologico
    // corretto.
    private var mLastTimerTimeMs as Number;

    // Contatore per il ricontrollo periodico della calibrazione.
    private var mSecondsSinceCalibrationCheck as Number;

    // Distanza di riferimento (in metri) per convertire la velocità in
    // passo: 1000 m per il sistema metrico, 1609.344 m (1 miglio) per
    // quello imperiale. Letta una sola volta in initialize() dalle
    // impostazioni di sistema del dispositivo (non dell'app: è lo stesso
    // valore che l'utente ha scelto per tutti gli altri campi Garmin).
    private var mUnitDistanceMeters as Float;

    // --- Configurazione e stato dei 4 quadranti ------------------------
    // Tre array paralleli, tutti di lunghezza QUADRANT_COUNT, allocati una
    // sola volta. L'indice è la posizione sullo schermo:
    //   0 = alto a sinistra   1 = alto a destra
    //   2 = basso a sinistra  3 = basso a destra
    private var mQuadSource as Array<Number>;   // quale grandezza mostrare
    private var mQuadLabel as Array<String>;    // etichetta già caricata
    private var mQuadValue as Array<String>;    // valore già formattato
    private var mQuadLevel as Array<Number>;    // livello di allerta

    // true se lo schermo è tondo o semi-tondo (Fenix7, FR955/965 sono
    // tutti tondi): serve per applicare un margine di sicurezza extra
    // nel disegno, perché sui bordi di uno schermo tondo lo spazio
    // orizzontale/verticale disponibile si restringe rispetto al centro.
    // Letto una sola volta in initialize(), mai in onUpdate().
    private var mIsRoundScreen as Boolean;

    // Elenco dei font "numerici" candidati per i valori, dal più grande al
    // più piccolo. In onUpdate() misuriamo la larghezza reale del testo più
    // largo tra i 4 quadranti e scegliamo il font più grande che ci sta
    // nello spazio disponibile: così i numeri sono sempre il più leggibili
    // possibile SENZA mai sovrapporsi tra un quadrante e l'altro, su
    // qualunque dispositivo. L'array è allocato una sola volta qui.
    private var mValueFontCandidates as Array<Graphics.FontType>;

    // Valori di disegno condivisi tra i 4 quadranti, ricalcolati una volta
    // all'inizio di ogni onUpdate() e poi letti da drawQuadrant() come
    // variabili di istanza invece che come parametri. Necessario perché
    // alcuni dispositivi meno recenti (es. Fenix 6, Forerunner 945, MARQ)
    // girano su una VM Monkey C che limita le funzioni a un MASSIMO DI 9
    // ARGOMENTI: passare tutti questi valori come parametri di
    // drawQuadrant() ad ogni chiamata (come si farebbe su un linguaggio
    // moderno senza questo vincolo) superava il limite e impediva la
    // compilazione su quei device.
    private var mDrawLabelFont as Graphics.FontType;
    private var mDrawValueFont as Graphics.FontType;
    private var mDrawLabelHeight as Number;
    private var mDrawValueHeight as Number;
    private var mDrawGap as Number;
    private var mDrawLabelColor as Graphics.ColorType;
    private var mDrawBackgroundColor as Graphics.ColorType;

    // --- Cache della scelta del font ---------------------------------
    // Misurare la larghezza di 4 stringhe su 3 font candidati costa fino a
    // 12 chiamate a getTextWidthInPixels() per ogni ridisegno. Le stringhe
    // però cambiano al massimo 1 volta al secondo (in compute()), mentre
    // onUpdate() può essere invocato molto più spesso: rifare la misura ad
    // ogni frame è lavoro sprecato, pesante soprattutto sui dispositivi con
    // solo 32KB per i Data Field (Fenix 6 base, FR935, Enduro 1ª gen).
    // Ricalcoliamo quindi solo quando cambia qualcosa che influisce davvero
    // sul risultato: le stringhe da disegnare o le dimensioni dello schermo.
    private var mLayoutDirty as Boolean;
    private var mCachedValueFont as Graphics.FontType;
    private var mCachedLayoutWidth as Number;
    private var mCachedLayoutHeight as Number;

    // ------------------------------------------------------------------
    // COSTRUTTORE
    // ------------------------------------------------------------------

    function initialize() {
        DataField.initialize();

        // Leggiamo le unità di misura PRIMA di creare i campi FIT, perché
        // ci servono sia per le etichette ":units" sia per tutte le
        // conversioni di passo fatte in compute().
        if (System.getDeviceSettings().paceUnits == System.UNIT_STATUTE) {
            mUnitDistanceMeters = METERS_PER_MILE;
        } else {
            mUnitDistanceMeters = METERS_PER_KILOMETER;
        }
        var paceUnitLabel = (mUnitDistanceMeters == METERS_PER_MILE) ? "min/mi" : "min/km";

        // --- Creazione dei campi FIT personalizzati -------------------
        // MESG_TYPE_RECORD = un valore ogni secondo, così Garmin Connect e
        // Strava possono disegnarci sopra un grafico.
        // MESG_TYPE_SESSION = un unico valore per l'intera attività, adatto
        // ai parametri dell'atleta, che non cambiano secondo per secondo.
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

        // --- Allocazione array a dimensione fissa per lo smoothing -----
        // Allochiamo sempre alla dimensione MASSIMA possibile: la finestra
        // effettivamente usata (mHistorySize) può essere più corta e viene
        // letta subito dopo dalle impostazioni utente, ma l'array in sé
        // non viene mai riallocato durante l'esecuzione dell'app.
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

        // Modelli e calibrazione. La calibrazione carica da sola i record
        // personali salvati dalle attività precedenti.
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

        // Array dei quadranti: allocati qui una volta sola, riempiti da
        // applySettings() insieme a tutte le altre impostazioni utente.
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

        // Rileviamo la forma dello schermo una sola volta: tutti i device
        // target sono tondi o semi-tondi, ma teniamo il codice generico nel
        // caso l'app venga estesa a dispositivi con schermo rettangolare.
        var screenShape = System.getDeviceSettings().screenShape;
        mIsRoundScreen = (screenShape == System.SCREEN_SHAPE_ROUND)
            || (screenShape == System.SCREEN_SHAPE_SEMI_ROUND);

        // Font candidati per i valori, dal più grande al più piccolo.
        //
        // ATTENZIONE se si modifica questa lista: i font numerici
        // (FONT_NUMBER_*) contengono un set ridotto di glifi, storicamente
        // limitato a cifre, ':', '.' e '-'. Le stringhe dei quadranti usano
        // anche '%' e '+', che su alcuni firmware potrebbero non essere
        // presenti nel font numerico. FONT_NUMBER_MILD è stato verificato
        // visivamente su Fenix 7, Forerunner 170 ed Enduro 3 (MIP e AMOLED)
        // e rende correttamente entrambi i caratteri; i font successivi
        // della lista sono font di testo, che hanno comunque il set completo.
        // Prima di introdurre un font numerico più grande (es. FONT_NUMBER_
        // MEDIUM/HOT) va rifatta la stessa verifica visiva.
        mValueFontCandidates = [
            Graphics.FONT_NUMBER_MILD,
            Graphics.FONT_LARGE,
            Graphics.FONT_MEDIUM
        ] as Array<Graphics.FontType>;

        // Valori di default per i campi di disegno condivisi: verranno
        // sovrascritti ad ogni onUpdate() prima di essere usati, ma vanno
        // comunque inizializzati qui perché membri tipizzati non-nullable.
        mDrawLabelFont = Graphics.FONT_XTINY;
        mDrawValueFont = Graphics.FONT_NUMBER_MILD;
        mDrawLabelHeight = 0;
        mDrawValueHeight = 0;
        mDrawGap = 0;
        mDrawLabelColor = Graphics.COLOR_LT_GRAY;
        mDrawBackgroundColor = Graphics.COLOR_BLACK;

        // Cache della scelta del font: parte "sporca" così il primo
        // onUpdate() calcola il layout reale invece di usare i default.
        mLayoutDirty = true;
        mCachedValueFont = Graphics.FONT_NUMBER_MILD;
        mCachedLayoutWidth = 0;
        mCachedLayoutHeight = 0;

        // Carica tutte le impostazioni utente e configura il motore.
        applySettings();
    }

    // ------------------------------------------------------------------
    // Crea un campo FIT personalizzato senza poter far crashare l'app.
    //
    // Riceve 5 argomenti, ben sotto il limite di 9 imposto dalla VM Monkey C
    // dei dispositivi meno recenti.
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
            // Nessuna registrazione FIT per questo campo: l'app resta
            // pienamente utilizzabile come display a schermo.
            return null;
        }
    }

    // ------------------------------------------------------------------
    // Legge una proprietà numerica dalle impostazioni utente riportandola
    // sempre in un intervallo valido. getValue() solleva un'eccezione se
    // la chiave non esiste (es. se venisse rinominata in properties.xml
    // senza aggiornare il codice): la intercettiamo per non far crashare
    // l'app all'avvio.
    //
    // Riceve 4 argomenti: sotto il limite di 9 dei device meno recenti.
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
    // applySettings(): ricarica TUTTE le impostazioni utente e riconfigura
    // di conseguenza smoothing, quadranti e motore fisiologico.
    //
    // ATTENZIONE: questo metodo NON è un callback di sistema. Il callback
    // onSettingsChanged() appartiene a Application.AppBase, non a
    // WatchUi.DataField: definirlo qui non avrebbe alcun effetto perché il
    // sistema non lo chiamerebbe mai. È quindi UltraTrailDashboardApp a
    // ricevere l'evento e a invocare questo metodo sulla View.
    // ------------------------------------------------------------------
    function applySettings() as Void {
        // --- Finestra di smoothing della pendenza ---------------------
        var newHistorySize = readNumberSetting(
            "SmoothingWindowSeconds", DEFAULT_HISTORY_SIZE,
            MIN_HISTORY_SIZE, MAX_HISTORY_SIZE);

        // Azzeriamo lo storico solo se la finestra è DAVVERO cambiata:
        // applySettings() viene richiamata anche per modifiche che non
        // c'entrano nulla (per esempio un quadrante diverso), e buttare via
        // il buffer a metà gara costringerebbe a ricostruire la pendenza da
        // zero per una manciata di secondi senza alcun motivo.
        if (newHistorySize != mHistorySize) {
            mHistorySize = newHistorySize;
            resetGradeHistory();
        }

        // --- Sorgenti dei 4 quadranti ---------------------------------
        loadQuadrantSetting(0, "Quadrant1", SRC_PACE);
        loadQuadrantSetting(1, "Quadrant2", SRC_HR);
        loadQuadrantSetting(2, "Quadrant3", SRC_GRADE);
        loadQuadrantSetting(3, "Quadrant4", SRC_GAP);

        // --- Azzeramento calibrazione su richiesta --------------------
        // L'impostazione è un interruttore che si "riarma" da solo: appena
        // la vediamo attiva cancelliamo i record e la riportiamo a false,
        // così l'utente non deve ricordarsi di spegnerla e la prossima
        // attività non riparte a calibrazione azzerata senza volerlo.
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
                // Se non riusciamo a riarmare l'interruttore, il peggio che
                // succede è un secondo azzeramento al prossimo avvio.
            }
        }

        // --- Parametri dell'atleta per il motore ----------------------
        configureModels();
    }

    // ------------------------------------------------------------------
    // Legge la sorgente configurata per un quadrante e ne carica
    // l'etichetta. Un valore fuori range (impostazione di una versione
    // futura, o file di configurazione corrotto) ricade sul default invece
    // di far saltare l'app.
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
    // Etichetta breve da mostrare sopra il valore di un quadrante.
    // Caricata dalle risorse SOLO qui (all'avvio o al cambio impostazioni),
    // mai in onUpdate(): loadResource() alloca una stringa nuova ogni volta.
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
            // Le tre seguenti sono già in memoria: servono anche al campo
            // LIMITE, che cambia etichetta a ogni secondo in base al
            // vincolo dominante e non può permettersi una loadResource() al
            // secondo. Restituiamo il riferimento, non una copia.
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
    // Legge dalle impostazioni tutti i parametri dell'atleta e li distribuisce
    // ai tre modelli: massa e piano di alimentazione al bilancio dei
    // carboidrati, capacità di discesa al modello eccentrico, velocità
    // critica e durabilità al motore aerobico.
    //
    // ORDINE DI PRIORITÀ per la velocità critica:
    //   1. la calibrazione automatica, se ha raccolto dati sufficienti
    //   2. il passo soglia inserito a mano dall'utente, se presente
    //   3. nessuno dei due: il motore si dichiara non pronto e i quadranti
    //      che dipendono da lui mostrano "--"
    //
    // La calibrazione viene prima del valore inserito a mano perché nasce
    // dalle prestazioni reali dell'atleta su questo terreno, mentre il
    // passo soglia digitato è quasi sempre un ricordo di una gara su strada.
    // ------------------------------------------------------------------
    private function configureModels() as Void {
        // --- Bilancio dei carboidrati ----------------------------------
        // La massa corporea è un'impostazione e non una lettura dal profilo
        // utente Garmin per una ragione precisa: leggere il profilo
        // richiederebbe il permesso "UserProfile", che l'app oggi non
        // chiede. Aggiungerlo a un'app già pubblicata cambia l'elenco dei
        // permessi mostrato nello store a un pubblico a cui promettiamo che
        // nulla lascia l'orologio. Un campo numerico in più costa meno.
        var massKg = readNumberSetting("BodyMassKg", 70, 35, 150);
        var carbIntake = readNumberSetting("CarbIntakeGramsPerHour", 60, 0, 120);
        mFuel.setAthlete(massKg.toFloat(), carbIntake.toFloat());

        // --- Capacità di discesa ----------------------------------------
        var descentCapacity = readNumberSetting("DescentCapacityMeters", 3000, 500, 15000);
        mEccentric.setCapacity(descentCapacity.toFloat());

        // --- Motore aerobico --------------------------------------------
        // Fattore di durabilità: percentuale di velocità sostenibile persa
        // ogni 100 kJ/kg di lavoro accumulato. 0 disattiva il decadimento.
        var durabilityPercent = readNumberSetting("DurabilityPercent", 8, 0, 25);
        var durabilityFactor = durabilityPercent / 100.0;

        if (mCalibration.isValid()) {
            mEngine.setAthlete(
                mCalibration.getCriticalSpeed(),
                mCalibration.getDPrime(),
                durabilityFactor);
            return;
        }

        // Passo soglia inserito dall'utente, in secondi per unità di
        // distanza del dispositivo (secondi/km per chi usa il sistema
        // metrico, secondi/miglio per chi usa quello imperiale).
        // 0 significa "non impostato".
        var thresholdPace = readNumberSetting("ThresholdPaceSeconds", 0, 0, 1200);
        if (thresholdPace > 0) {
            // setAthlete() rifiuta da sé le velocità implausibili, quindi
            // un valore assurdo digitato per errore non produce un modello
            // sbagliato: produce nessun modello, e i quadranti restano "--".
            mEngine.setAthlete(
                mUnitDistanceMeters / thresholdPace,
                mEngine.defaultDPrime(),
                durabilityFactor);
            return;
        }

        // Nessuna fonte disponibile: motore non pronto.
        mEngine.setAthlete(0.0, mEngine.defaultDPrime(), durabilityFactor);
    }

    // ------------------------------------------------------------------
    // onTimerStop(): callback di DataField, invocato quando l'utente ferma
    // il timer dell'attività. È il momento giusto per salvare i record
    // personali della calibrazione: l'attività è finita, e scrivere in
    // memoria flash qui costa una volta sola invece che ogni secondo.
    // ------------------------------------------------------------------
    function onTimerStop() as Void {
        mCalibration.save();
    }

    // ------------------------------------------------------------------
    // Rete di sicurezza per il salvataggio dei record: invocata da
    // UltraTrailDashboardApp.onStop(), cioè alla chiusura dell'app.
    //
    // onTimerStop() copre il caso normale (l'utente ferma il timer e salva
    // l'attività), ma non tutti: se l'utente chiude l'attività da un menu,
    // o se il sistema termina l'app perché sta finendo la batteria, quel
    // callback può non arrivare mai. save() non fa nulla se non c'è niente
    // di nuovo da scrivere, quindi chiamarla due volte non costa nulla.
    // ------------------------------------------------------------------
    function persistCalibration() as Void {
        mCalibration.save();
    }

    // ------------------------------------------------------------------
    // onTimerReset(): callback di DataField, invocato quando l'utente
    // resetta l'attività per iniziarne una nuova.
    //
    // È indispensabile azzerare qui lo storico: info.elapsedDistance
    // riparte da zero, mentre il buffer conterrebbe ancora le distanze
    // cumulate dell'attività precedente (es. 3000 m). Il delta risulterebbe
    // NEGATIVO e non supererebbe mai MIN_DISTANCE_FOR_GRADE, lasciando la
    // pendenza congelata sull'ultimo valore della corsa precedente fino al
    // completo riempimento del buffer (fino a 30 secondi).
    //
    // Vale lo stesso per motore e calibrazione: lavoro accumulato e riserva
    // anaerobica sono grandezze della SINGOLA attività e vanno azzerate,
    // mentre i record personali della calibrazione sopravvivono (sono la
    // memoria di lungo periodo dell'atleta, non della corsa).
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

        // Salviamo i record prima di ripartire: se l'utente resetta senza
        // essere passato da uno stop del timer, li perderemmo.
        mCalibration.save();
        mCalibration.resetSession();
        mEngine.reset();
        mFuel.reset();
        mEccentric.reset();

        mBindingTtfSec = null;
        mBindingKind = BIND_NONE;

        // La calibrazione può essere diventata valida durante l'attività
        // appena conclusa: applichiamola prima che ne inizi una nuova.
        configureModels();

        for (var q = 0; q < QUADRANT_COUNT; q++) {
            mQuadValue[q] = "--";
            mQuadLevel[q] = LEVEL_NORMAL;
        }
        mLayoutDirty = true;
    }

    // ------------------------------------------------------------------
    // Svuota il buffer circolare di quota/distanza. Non riallochiamo gli
    // array (restano quelli fissi creati in initialize()): azzerare indice
    // e contatore basta a far ripartire la finestra da zero.
    // ------------------------------------------------------------------
    private function resetGradeHistory() as Void {
        mHistIndex = 0;
        mHistCount = 0;
    }

    // ------------------------------------------------------------------
    // compute(info): chiamato 1 volta al secondo dal sistema.
    // ------------------------------------------------------------------
    function compute(info as Activity.Info) as Numeric or Toybox.Time.Duration or String or Null {

        // --- 1) Passo di integrazione reale ----------------------------
        // Vedi il commento su mLastTimerTimeMs: usiamo l'orologio del timer
        // dell'attività, non il conteggio delle chiamate, così le pause non
        // vengono integrate nel modello.
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

        // --- 2) Aggiornamento storico quota/distanza -------------------
        // Aggiorniamo l'array circolare solo se il dispositivo fornisce
        // sia la quota (altimetro barometrico) sia la distanza percorsa.
        //
        // Copiamo i campi di Activity.Info in variabili locali PRIMA di
        // usarli: il controllo "!= null" su una proprietà non garantisce
        // che la lettura successiva restituisca lo stesso valore, quindi
        // leggere due volte è un rischio di dereferenziazione nulla. Con
        // una copia locale il valore verificato è esattamente quello usato.
        var altitude = info.altitude;
        var elapsedDistance = info.elapsedDistance;
        if (altitude != null && elapsedDistance != null) {
            mAltHistory[mHistIndex] = altitude;
            mDistHistory[mHistIndex] = elapsedDistance;

            // Avanziamo l'indice circolare (torna a 0 dopo l'ultima cella
            // della finestra CONFIGURATA, non dell'array intero: usiamo
            // solo i primi mHistorySize elementi di mAltHistory/mDistHistory).
            mHistIndex = (mHistIndex + 1) % mHistorySize;
            if (mHistCount < mHistorySize) {
                mHistCount++;
            }
        }

        // --- 3) Calcolo della pendenza stabilizzata (media mobile) ----
        // Confrontiamo il campione più vecchio nella finestra con quello
        // più recente: la pendenza media sull'intera finestra è molto
        // più stabile della pendenza "istantanea" nativa di Garmin.
        if (mHistCount >= 2) {
            // Se il buffer è pieno, il campione più vecchio è proprio
            // nella cella che stiamo per sovrascrivere (mHistIndex).
            // Se non è ancora pieno, il campione più vecchio è in [0].
            var oldestIndex = (mHistCount == mHistorySize) ? mHistIndex : 0;

            // L'ultimo campione scritto è quello appena prima di mHistIndex.
            var newestIndex = (mHistIndex - 1 + mHistorySize) % mHistorySize;

            var deltaAlt = mAltHistory[newestIndex] - mAltHistory[oldestIndex];
            var deltaDist = mDistHistory[newestIndex] - mDistHistory[oldestIndex];

            // Calcoliamo la nuova pendenza solo se ci siamo mossi
            // abbastanza da avere un dato significativo (evita divisioni
            // per numeri quasi zero, es. da fermi a un semaforo/ristoro).
            if (deltaDist > MIN_DISTANCE_FOR_GRADE) {
                mSmoothedGradePercent = (deltaAlt / deltaDist) * 100.0;
            }
            // Altrimenti mSmoothedGradePercent mantiene il suo ultimo
            // valore valido: niente "sbalzi" a zero quando ci si ferma.
        }

        // --- 4) Passo attuale (da velocità istantanea) ------------------
        // mUnitDistanceMeters vale 1000 (km) o 1609.344 (miglio) a seconda
        // delle unità di misura scelte dall'utente sul dispositivo: il
        // resto del calcolo (GAP, formattazione) non deve sapere quale
        // unità sia in uso, lavora sempre su "secondi per unità".
        // Anche qui la velocità viene copiata in una locale prima del
        // controllo di nullità: senza la copia, la divisione userebbe una
        // seconda lettura della proprietà, non coperta dal controllo.
        mHasValidPace = false;
        var currentSpeed = info.currentSpeed;
        if (currentSpeed != null && currentSpeed > 0.1) {
            mCurrentPaceSecPerUnit = mUnitDistanceMeters / currentSpeed;
            mHasValidPace = true;
        }

        var gradeFraction = mSmoothedGradePercent / 100.0;

        // --- 5) Calcolo del GAP (Grade Adjusted Pace) ------------------
        // Il GAP MOSTRATO usa il modello di Minetti puro, senza alcuna
        // attenuazione: è una scelta esplicita di fedeltà al modello
        // scientifico, anche quando il numero risulta aggressivo (su una
        // discesa ripida il GAP può avvicinarsi al doppio del passo reale).
        //
        // La formula lavora su un RAPPORTO di costi energetici, quindi il
        // risultato è corretto qualunque sia l'unità di distanza usata per
        // il passo in ingresso (km o miglio).
        if (mHasValidPace) {
            mGapPaceSecPerUnit = mCurrentPaceSecPerUnit / MinettiCost.ratio(gradeFraction);
            mHasValidGap = true;
        }

        // --- 6) Aggiornamento del motore fisiologico --------------------
        // Il MOTORE, a differenza del GAP mostrato, usa il rapporto con il
        // tetto in salita (MinettiCost.modelRatio): senza di esso ogni muro
        // ripido affrontato camminando verrebbe letto come uno sforzo
        // enormemente sopra soglia. Vedi il commento esteso in
        // MinettiCost.mc. Il valore a schermo resta comunque Minetti puro:
        // le due cose sono indipendenti.
        // La condizione è "velocità DISPONIBILE", non "velocità maggiore di
        // zero": stare fermi a un ristoro con il timer avviato è a tutti gli
        // effetti recupero, e il modello deve ricaricare la riserva. Saltare
        // l'aggiornamento a velocità nulla congelerebbe il bilancio proprio
        // nei minuti in cui l'atleta sta recuperando di più. Resta invece
        // corretto non fare nulla quando currentSpeed è null (GPS non ancora
        // agganciato): lì non sappiamo se è fermo, non sappiamo e basta.
        if (dt > 0.0 && currentSpeed != null) {
            var modelSpeed = currentSpeed * MinettiCost.modelRatio(gradeFraction);
            mEngine.update(modelSpeed, dt);
            mCalibration.update(modelSpeed, dt);

            // Il bilancio dei carboidrati dipende dall'intensità RELATIVA
            // alla velocità sostenibile: senza velocità critica non sappiamo
            // quale frazione dell'energia venga dagli zuccheri, quindi il
            // modello resta fermo invece di ipotizzare. Il consumo si legge
            // direttamente dalla velocità equivalente in piano, perché per
            // costruzione C(i)*v vale C(0)*vGap.
            var sustainable = mEngine.getSustainableSpeed();
            if (mEngine.hasModel() && sustainable > 0.0) {
                mFuel.update(
                    MinettiCost.FLAT_COST * modelSpeed,
                    modelSpeed / sustainable,
                    dt);
            }

            // Il danno da discesa usa la velocità REALE sul terreno, non
            // quella equivalente in piano: qui conta il movimento del corpo
            // e la forza che i quadricipiti devono assorbire, non il costo
            // aerobico. Ed è l'unico dei tre modelli che non ha bisogno di
            // alcuna calibrazione: funziona dal primo secondo.
            mEccentric.update(currentSpeed, gradeFraction, dt);

            // Se il motore è partito senza modello (nessun record salvato e
            // nessun passo soglia impostato), ricontrolliamo ogni tanto se
            // la calibrazione è nel frattempo diventata utilizzabile.
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

        // --- 7) Scrittura dei valori nel file FIT -----------------------
        // Scriviamo SOLO dopo aver calcolato almeno un GAP valido: prima di
        // allora il valore sarebbe 0.0, che verrebbe registrato come un dato
        // reale (picco a zero nel grafico e medie falsate) invece che come
        // "dato non disponibile". Da fermi con il timer avviato il campo
        // conserva l'ultimo valore valido: non esiste un modo di scrivere un
        // valore "invalido" via setData(), che accetta solo il tipo
        // dichiarato in createField() e altrimenti solleva un'eccezione.
        writeFitFields();

        // --- 8) Vincolo dominante ---------------------------------------
        updateBindingConstraint();

        // --- 9) Pre-formattazione delle stringhe per il disegno --------
        // Facciamo qui il lavoro "costoso" di formattazione, così
        // onUpdate() dovrà solo disegnare stringhe già pronte.
        mHeartRate = info.currentHeartRate;
        for (var q = 0; q < QUADRANT_COUNT; q++) {
            updateQuadrant(q);
        }

        // Il valore restituito viene usato solo come fallback se il
        // sistema dovesse mostrare questo campo in un layout semplice
        // (es. nella schermata di riepilogo); il nostro disegno custom
        // in onUpdate() ha comunque sempre la precedenza sullo schermo
        // di allenamento. Restituiamo null finché non c'è un GAP valido,
        // così il sistema mostra "--" invece di uno zero fuorviante.
        if (!mHasValidGap) {
            return null;
        }
        return mGapPaceSecPerUnit / 60.0;
    }

    // ------------------------------------------------------------------
    // Determina quale sistema fisiologico cederà per primo e fra quanto.
    //
    // Ogni modello dichiara il proprio tempo al cedimento, oppure null se
    // al ritmo attuale non sta andando verso alcun limite (sotto soglia la
    // riserva anaerobica si ricarica, in salita le gambe non peggiorano,
    // mangiando abbastanza i carboidrati non calano). Il vincolo è
    // semplicemente il minimo tra quelli dichiarati.
    //
    // Questa è la scelta di progetto centrale dell'app: la valuta comune
    // tra sistemi diversi è il TEMPO, non un punteggio. Un indice che
    // moltiplichi fra loro riserva, glicogeno e danno muscolare produce un
    // numero che non si può verificare contro nulla e che non dice cosa
    // fare. Un tempo al cedimento, invece, a fine gara si confronta con
    // quello che è successo davvero, e il nome del sistema che lo impone
    // corrisponde a un'azione precisa: rallentare, mangiare, o frenare meno.
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
    // Etichetta da mostrare sul campo LIMITE: il nome del sistema che sta
    // vincolando. Restituisce un riferimento a una stringa già in memoria,
    // quindi non alloca nulla nemmeno venendo chiamata a ogni secondo.
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
    // Scrive nel file FIT lo stato del modello. Chiamata da compute(),
    // una volta al secondo.
    //
    // Perché registriamo lo STATO e non i valori mostrati: i campi a
    // schermo si ricavano dallo stato, ma non viceversa. Salvare velocità
    // sostenibile, riserva e lavoro accumulato è ciò che permetterà, a
    // posteriori, di confrontare quanto il modello aveva previsto con come
    // è andata davvero, e di correggere i parametri dell'atleta di
    // conseguenza. Un campo puramente estetico non lo consentirebbe.
    // ------------------------------------------------------------------
    private function writeFitFields() as Void {
        var gapField = mGapField;
        if (gapField != null && mHasValidGap) {
            gapField.setData(mGapPaceSecPerUnit / 60.0);
        }

        // Il carico eccentrico si registra sempre: è l'unico modello che non
        // dipende dalla velocità critica, quindi è disponibile anche alla
        // primissima uscita, quando la calibrazione non ha ancora dati.
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
            // DATA_TYPE_UINT8 accetta solo interi 0-255: la percentuale ci
            // sta comodamente, e costa un byte per record invece di quattro.
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

        // I due campi di sessione descrivono l'atleta, non l'istante: li
        // riscriviamo comunque a ogni ciclo perché setData() su un campo
        // MESG_TYPE_SESSION si limita a sovrascrivere il valore in memoria,
        // che verrà salvato una volta sola alla chiusura della sessione.
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
    // Aggiorna testo e livello di allerta di un quadrante, in base alla
    // sorgente che l'utente gli ha assegnato.
    //
    // Il valore viene scritto tramite setQuadValue(), che marca il layout
    // come da ricalcolare SOLO se la stringa è davvero cambiata: è ciò che
    // permette a onUpdate() di saltare le misure dei font quando non serve.
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
                // Questo quadrante cambia ETICHETTA oltre che valore: mostra
                // quanto manca al primo cedimento e il nome del sistema che
                // lo impone. È l'unica parte dell'app che risponde alla
                // domanda "cosa devo fare adesso" invece che "quanto vale
                // questa grandezza".
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
                    // Nessun sistema si sta avvicinando al proprio limite:
                    // sotto soglia la riserva si ricarica, in salita le gambe
                    // non peggiorano, e l'alimentazione copre il consumo.
                    // Mostrare un numero qui sarebbe inventarlo.
                    setQuadValue(index, "--:--");
                    mQuadLabel[index] = mLabelLimit;
                    mQuadLevel[index] = LEVEL_NORMAL;
                }
                break;

            case SRC_CARB:
                // Dipende dalla velocità critica, perché la frazione di
                // energia che arriva dagli zuccheri si ricava dall'intensità
                // relativa alla soglia. Senza calibrazione, "--".
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
                // Nessuna dipendenza dalla calibrazione: funziona subito.
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
    // Aggiorna il testo di un quadrante solo se è effettivamente cambiato
    // e, in quel caso, marca il layout come da ricalcolare.
    // ------------------------------------------------------------------
    private function setQuadValue(index as Number, value as String) as Void {
        if (!value.equals(mQuadValue[index])) {
            mQuadValue[index] = value;
            mLayoutDirty = true;
        }
    }

    // ------------------------------------------------------------------
    // Livello di allerta quando sono i valori BASSI a essere critici
    // (riserva anaerobica residua, tempo al cedimento).
    //
    // L'isteresi non è un dettaglio estetico: senza di essa, un valore che
    // oscilla attorno a una soglia fa lampeggiare il colore più volte al
    // secondo. In gara è la differenza tra un campo che si legge a colpo
    // d'occhio e uno che l'utente disinstalla. Per SCENDERE di gravità
    // serve superare la soglia di un margine; per salire, no: un
    // peggioramento va segnalato subito.
    //
    // Riceve 5 argomenti, sotto il limite di 9 dei device meno recenti.
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
    // Livello di allerta quando sono i valori ALTI a essere critici
    // (pendenza in valore assoluto). Stessa isteresi, direzione opposta.
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
    // Converte un passo espresso in secondi per unità di distanza (km o
    // miglio, a seconda delle impostazioni utente) in una stringa "M:SS".
    // Chiamata solo da compute() (1 volta al secondo), mai da onUpdate().
    // ------------------------------------------------------------------
    private function formatPace(paceSecPerUnit as Float) as String {
        if (paceSecPerUnit <= 0.0 or paceSecPerUnit > 5940.0) {
            // Oltre i 99:00 (es. da fermi) mostriamo un placeholder invece
            // di un numero senza senso.
            return "--:--";
        }
        var totalSeconds = Math.round(paceSecPerUnit).toNumber();
        var minutes = totalSeconds / 60;
        var seconds = totalSeconds % 60;
        return Lang.format("$1$:$2$", [minutes, seconds.format("%02d")]);
    }

    // ------------------------------------------------------------------
    // Formatta una durata in secondi per il campo LIMITE.
    //
    // Sotto l'ora usa "M:SS", che è la forma giusta per un limite
    // anaerobico: lì contano i secondi. Sopra l'ora passa a "1h20", perché
    // un esaurimento di carboidrati o di gambe si misura in ore e "82:14"
    // costringerebbe l'atleta a fare una divisione mentale a metà gara.
    // Oltre le dieci ore la stima non è più informativa e nemmeno
    // affidabile: mostriamo un tetto invece di un numero preciso e falso.
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
    // Formatta la pendenza con un decimale e il segno (+/-).
    // ------------------------------------------------------------------
    private function formatGrade(gradePercent as Float) as String {
        return Lang.format("$1$%", [gradePercent.format("%+.1f")]);
    }

    // ------------------------------------------------------------------
    // onUpdate(dc): disegna la UI. NESSUN calcolo qui: solo disegno delle
    // stringhe già pronte in mQuadValue.
    //
    // Ogni quadrante è composto da DUE righe centrate verticalmente:
    // un'etichetta piccola e attenuata sopra ("PASSO", "HR", ...) e il
    // valore vero e proprio sotto, grande e ad alto contrasto. Questa
    // gerarchia visiva (etichetta -> valore) è lo standard dei campi dati
    // Garmin ed è ciò che rende leggibile lo schermo a colpo d'occhio
    // mentre si corre, senza dover "interpretare" i numeri.
    // ------------------------------------------------------------------
    function onUpdate(dc as Graphics.Dc) as Void {
        var width = dc.getWidth();
        var height = dc.getHeight();
        var halfW = width / 2;
        var halfH = height / 2;

        // --- Colori dinamici in base al tema del dispositivo -----------
        // getBackgroundColor() è fornito dalla classe base DataField e
        // riflette il tema scelto dall'utente (sfondo chiaro/scuro,
        // schermo MIP o AMOLED). Scegliamo il colore del testo che
        // garantisce sempre il massimo contrasto leggibile.
        var backgroundColor = getBackgroundColor();
        var isDarkBackground = (backgroundColor == Graphics.COLOR_BLACK);
        var valueColor = isDarkBackground
            ? Graphics.COLOR_WHITE
            : Graphics.COLOR_BLACK;

        // Etichette e linee divisorie devono essere attenuate rispetto al
        // valore, ma il grigio giusto DIPENDE dallo sfondo: su fondo scuro
        // serve un grigio chiaro, su fondo chiaro (tema MIP chiaro) serve un
        // grigio scuro. Usare LT_GRAY fisso rendeva le etichette quasi
        // invisibili su sfondo bianco.
        var labelColor;
        var dividerColor;
        if (isDarkBackground) {
            labelColor = Graphics.COLOR_LT_GRAY;
            dividerColor = Graphics.COLOR_DK_GRAY;
        } else {
            labelColor = Graphics.COLOR_DK_GRAY;
            dividerColor = Graphics.COLOR_LT_GRAY;
        }

        // Puliamo lo sfondo con il colore corretto.
        dc.setColor(valueColor, backgroundColor);
        dc.clear();

        // --- Linee divisorie "sospese" -----------------------------------
        // Su schermo tondo le linee a tutto schermo tagliano gli angoli in
        // modo brusco; le accorciamo leggermente (non toccano il bordo) per
        // un effetto più pulito e moderno, tipo "croce fluttuante".
        var lineInsetX = mIsRoundScreen ? (width * 0.08).toNumber() : 0;
        var lineInsetY = mIsRoundScreen ? (height * 0.08).toNumber() : 0;
        dc.setColor(dividerColor, backgroundColor);
        dc.setPenWidth(1);
        dc.drawLine(halfW, lineInsetY, halfW, height - lineInsetY);       // verticale
        dc.drawLine(lineInsetX, halfH, width - lineInsetX, halfH);        // orizzontale

        // --- Margine di sicurezza per il centro dei quadranti ------------
        // Su schermo tondo lo spazio orizzontale/verticale disponibile si
        // restringe avvicinandosi al bordo: spostiamo il centro di ogni
        // quadrante verso il centro dello schermo di una frazione extra,
        // così etichetta e valore restano sempre dentro l'area visibile
        // (evita che, ad esempio, la "P" di "PASSO" venga tagliata dalla
        // curvatura del vetro).
        var insetFraction = mIsRoundScreen ? 0.22 : 0.0;
        var quadInsetX = ((halfW / 2) * insetFraction).toNumber();
        var quadInsetY = ((halfH / 2) * insetFraction).toNumber();
        var leftCenterX = (halfW / 2) + quadInsetX;
        var rightCenterX = width - leftCenterX;
        var topCenterY = (halfH / 2) + quadInsetY;
        var bottomCenterY = height - topCenterY;

        // Font del VALORE: invece di soglie fisse indovinate, misuriamo la
        // larghezza REALE (in pixel) del testo più largo tra i 4 quadranti
        // e scegliamo il font numerico più grande che ci sta nello spazio
        // disponibile per quel quadrante. Questo garantisce che i valori
        // non si sovrappongano MAI tra loro, qualunque sia la stringa più
        // lunga (es. "+15.0%" è molto più larga di "159" o "--:--") e su
        // qualunque dispositivo. getTextWidthInPixels() non alloca memoria,
        // quindi è sicuro chiamarlo qui in onUpdate().
        //
        // Lo spazio disponibile è la distanza tra il centro del quadrante
        // e la linea divisoria centrale (il vincolo più stretto, dato che
        // i centri sono già stati avvicinati al centro schermo sopra),
        // moltiplicata per 2 e con un piccolo margine di sicurezza.
        // Il margine è proporzionale alla larghezza schermo (6%, minimo 16px):
        // un valore fisso troppo piccolo (provato: 6px) lasciava i due valori
        // della stessa riga praticamente attaccati sulla linea divisoria
        // quando entrambi erano stringhe larghe (es. "-13.6%" e "11:26").
        var dividerPadding = (width * 0.06).toNumber();
        if (dividerPadding < 16) {
            dividerPadding = 16;
        }
        var maxValueWidth = ((halfW - leftCenterX) * 2) - dividerPadding;
        if (maxValueWidth < 20) {
            maxValueWidth = 20; // pavimento di sicurezza, non dovrebbe mai servire
        }

        // La misura vera e propria si fa solo se qualcosa è cambiato: una
        // delle 4 stringhe (mLayoutDirty, impostato da setQuadValue() in
        // compute()) oppure le dimensioni del contesto grafico. Altrimenti
        // riusiamo il font già calcolato, risparmiando fino a 12 chiamate a
        // getTextWidthInPixels() per ogni ridisegno.
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

        // Font dell'ETICHETTA: sempre piccolo e fisso, leggibile ma
        // chiaramente secondario rispetto al valore.
        var labelFont = Graphics.FONT_XTINY;

        // Altezza dei due font: serve per impilare etichetta e valore uno
        // sopra l'altro, centrati come blocco unico nel quadrante.
        // getFontHeight() non alloca memoria, quindi è sicuro chiamarlo qui.
        var labelHeight = dc.getFontHeight(labelFont);
        var valueHeight = dc.getFontHeight(valueFont);

        // Margine verticale tra etichetta e valore, proporzionato alla
        // dimensione dello schermo: abbastanza ampio da respirare, senza
        // separare visivamente la coppia etichetta-valore.
        var gap = labelHeight / 2;

        // Salviamo i valori condivisi come variabili di istanza: servono a
        // drawQuadrant() per restare sotto il limite di 9 argomenti per
        // funzione richiesto dai dispositivi meno recenti (vedi commento
        // sulla dichiarazione di questi campi, più sopra nella classe).
        mDrawLabelFont = labelFont;
        mDrawValueFont = valueFont;
        mDrawLabelHeight = labelHeight;
        mDrawValueHeight = valueHeight;
        mDrawGap = gap;
        mDrawLabelColor = labelColor;
        mDrawBackgroundColor = backgroundColor;

        // I 4 quadranti, nell'ordine: alto-sinistra, alto-destra,
        // basso-sinistra, basso-destra. Il colore di ciascuno dipende dal
        // livello di allerta calcolato in compute(): è la traduzione da
        // numero a giudizio, l'unica parte del "livello decisione" che
        // arriva davvero all'occhio dell'atleta senza doverla leggere.
        drawQuadrant(dc, leftCenterX, topCenterY, 0, valueColor);
        drawQuadrant(dc, rightCenterX, topCenterY, 1, valueColor);
        drawQuadrant(dc, leftCenterX, bottomCenterY, 2, valueColor);
        drawQuadrant(dc, rightCenterX, bottomCenterY, 3, valueColor);
    }

    // ------------------------------------------------------------------
    // Disegna la coppia etichetta+valore di un quadrante, centrata attorno
    // al punto (centerX, centerY). Funzione di sola scrittura sul Dc: non
    // alloca nulla, legge solo stringhe e costanti già pronte, quindi
    // rispetta la regola "niente allocazioni in onUpdate".
    //
    // Riceve 5 argomenti (il MASSIMO consentito dalla VM Monkey C dei
    // device meno recenti è 9): tutto ciò che è condiviso tra i 4 quadranti
    // (font, altezze, margine, colori di sfondo/etichetta) viene letto da
    // variabili di istanza invece che passato ogni volta come parametro.
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
