// UltraTrailDashboardView.mc
//
// Cuore dell'applicazione "Ultra-Trail Dashboard".
//
// Un Campo Dati Connect IQ di tipo "Complex Data Field" estende la classe
// WatchUi.DataField e riceve due eventi principali dal sistema:
//
//   - compute(info)  -> chiamato 1 volta al secondo, riceve i dati grezzi
//                        dell'attività (passo, quota, distanza, HR, ...).
//                        Qui facciamo TUTTI i calcoli (pendenza, GAP) e
//                        scriviamo il valore nel file FIT.
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

    // Limite di pendenza (in valore assoluto, frazione non percentuale)
    // oltre il quale "blocchiamo" la formula del GAP: sopra il 45% di
    // pendenza il modello di Minetti non è più stato validato e darebbe
    // risultati assurdi (o addirittura negativi).
    private const MAX_GRADE_FRACTION as Float = 0.45;

    // Soglie di pendenza (valore assoluto, in percentuale) oltre le quali
    // coloriamo il valore della pendenza per attirare l'attenzione senza
    // dover "leggere" il numero — utile a fine ultra quando la lucidità
    // cala. Sopra GRADE_DANGER_THRESHOLD il colore è più acceso di sopra
    // GRADE_WARNING_THRESHOLD.
    private const GRADE_WARNING_THRESHOLD as Float = 12.0;
    private const GRADE_DANGER_THRESHOLD as Float = 20.0;

    // Distanza (in metri) di riferimento per calcolare il passo: 1000 se
    // l'utente usa unità metriche, 1609.344 (miglio) se usa quelle
    // imperiali. Determinata una sola volta in initialize() leggendo le
    // impostazioni di sistema del dispositivo.
    private const METERS_PER_KILOMETER as Float = 1000.0;
    private const METERS_PER_MILE as Float = 1609.344;

    // ------------------------------------------------------------------
    // STATO INTERNO (allocato UNA SOLA VOLTA in initialize())
    // ------------------------------------------------------------------

    // Riferimento al campo personalizzato che scriviamo nel file .FIT.
    // Nullable per scelta: se createField() dovesse fallire su un
    // dispositivo/firmware particolare, l'app continua a funzionare come
    // display (i 4 quadranti restano corretti) invece di andare in crash
    // alla prima scrittura. Si perde solo la registrazione del GAP nel FIT.
    private var mGapField as FitContributor.Field?;

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

    // Diventa true solo dopo il PRIMO GAP calcolato su un passo valido.
    // Finché resta false non scriviamo nulla nel file FIT: scrivere 0.0
    // mentre si è fermi in partenza registrerebbe uno zero come se fosse
    // un dato reale, creando un picco nel grafico di Garmin Connect e
    // falsando le medie dell'attività.
    private var mHasValidGap as Boolean;

    // Distanza di riferimento (in metri) per convertire la velocità in
    // passo: 1000 m per il sistema metrico, 1609.344 m (1 miglio) per
    // quello imperiale. Letta una sola volta in initialize() dalle
    // impostazioni di sistema del dispositivo (non dell'app: è lo stesso
    // valore che l'utente ha scelto per tutti gli altri campi Garmin).
    private var mUnitDistanceMeters as Float;

    // Stringhe già formattate e pronte per il disegno: evitano qualunque
    // allocazione/formattazione dentro onUpdate().
    private var mPaceStr as String;
    private var mHrStr as String;
    private var mGradeStr as String;
    private var mGapStr as String;

    // true se lo schermo è tondo o semi-tondo (Fenix7, FR255/265/955/965
    // sono tutti tondi): serve per applicare un margine di sicurezza extra
    // nel disegno, perché sui bordi di uno schermo tondo lo spazio
    // orizzontale/verticale disponibile si restringe rispetto al centro.
    // Letto una sola volta in initialize(), mai in onUpdate().
    private var mIsRoundScreen as Boolean;

    // Etichette dei 4 quadranti: sono FISSE (non cambiano mai durante
    // l'attività), quindi le carichiamo una sola volta qui in initialize()
    // invece di ricaricarle ad ogni onUpdate().
    private var mLabelPace as String;
    private var mLabelHr as String;
    private var mLabelGrade as String;
    private var mLabelGap as String;

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

        // --- Creazione del campo FIT personalizzato -------------------
        // createField(nomeInterno, id, tipoDato, opzioni)
        //   - etichetta        : letta da resources/strings/strings.xml
        //                        (GapFieldLabel), così il nome che compare
        //                        nei grafici di Garmin Connect/Strava resta
        //                        in un unico punto centralizzato e traducibile
        //   - 0                : id numerico del campo, deve essere unico
        //                        all'interno di QUESTA app (0 va benissimo
        //                        perché è il nostro unico campo custom)
        //   - DATA_TYPE_FLOAT  : il GAP lo salviamo come numero decimale
        //   - :mesgType        : MESG_TYPE_RECORD = un valore ogni
        //                        secondo, così Garmin Connect/Strava
        //                        possono disegnarci sopra un grafico
        //   - :units           : etichetta unità mostrata nei grafici,
        //                        coerente con le unità di misura scelte
        //                        dall'utente sul dispositivo (km o miglia)
        //
        // Leggiamo le unità di misura PRIMA di creare il campo, perché ci
        // servono sia per l'etichetta ":units" sia per tutte le conversioni
        // di passo fatte in compute().
        if (System.getDeviceSettings().paceUnits == System.UNIT_STATUTE) {
            mUnitDistanceMeters = METERS_PER_MILE;
        } else {
            mUnitDistanceMeters = METERS_PER_KILOMETER;
        }
        var paceUnitLabel = (mUnitDistanceMeters == METERS_PER_MILE) ? "min/mi" : "min/km";

        var gapFieldLabel = WatchUi.loadResource(Rez.Strings.GapFieldLabel) as String;
        try {
            mGapField = createField(
                gapFieldLabel,
                0,
                FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => paceUnitLabel }
            ) as FitContributor.Field;
        } catch (ex) {
            // Nessuna registrazione FIT disponibile: l'app resta comunque
            // pienamente utilizzabile come display a schermo.
            mGapField = null;
        }

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

        // Legge la finestra di smoothing dalle impostazioni utente
        // (Garmin Connect Mobile), con fallback sicuro al default.
        mHistorySize = loadSmoothingWindowSetting();

        mSmoothedGradePercent = 0.0;
        mGapPaceSecPerUnit = 0.0;
        mHasValidGap = false;

        // Valori "placeholder" mostrati finché non arriva il primo dato
        // valido (es. subito dopo l'avvio dell'attività).
        mPaceStr = "--:--";
        mHrStr = "---";
        mGradeStr = "0.0%";
        mGapStr = "--:--";

        // Etichette dei quadranti: caricate una sola volta dalle risorse.
        mLabelPace = WatchUi.loadResource(Rez.Strings.LabelPace) as String;
        mLabelHr = WatchUi.loadResource(Rez.Strings.LabelHeartRate) as String;
        mLabelGrade = WatchUi.loadResource(Rez.Strings.LabelGrade) as String;
        mLabelGap = WatchUi.loadResource(Rez.Strings.LabelGap) as String;

        // Rileviamo la forma dello schermo una sola volta: tutti i device
        // target (Fenix7, FR255/265/955/965) sono tondi o semi-tondi, ma
        // teniamo il codice generico nel caso l'app venga estesa in futuro
        // a dispositivi con schermo rettangolare.
        var screenShape = System.getDeviceSettings().screenShape;
        mIsRoundScreen = (screenShape == System.SCREEN_SHAPE_ROUND)
            || (screenShape == System.SCREEN_SHAPE_SEMI_ROUND);

        // Font candidati per i valori, dal più grande al più piccolo.
        //
        // ATTENZIONE se si modifica questa lista: i font numerici
        // (FONT_NUMBER_*) contengono un set ridotto di glifi, storicamente
        // limitato a cifre, ':', '.' e '-'. La stringa della pendenza usa
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
    }

    // ------------------------------------------------------------------
    // Legge la proprietà "SmoothingWindowSeconds" impostata dall'utente in
    // Garmin Connect Mobile e la valida, riportandola sempre nel range
    // [MIN_HISTORY_SIZE, MAX_HISTORY_SIZE]. Se la proprietà non è ancora
    // stata impostata (es. prima installazione) o ha un valore inatteso,
    // usiamo il default sicuro invece di far fallire l'app.
    // ------------------------------------------------------------------
    private function loadSmoothingWindowSetting() as Number {
        // getValue() solleva un'eccezione se la chiave non esiste (es. se
        // in futuro venisse rinominata in properties.xml senza aggiornare
        // qui): la intercettiamo per non far crashare l'app all'avvio.
        var rawValue = null;
        try {
            rawValue = Properties.getValue("SmoothingWindowSeconds");
        } catch (ex) {
            return DEFAULT_HISTORY_SIZE;
        }

        if (rawValue == null || !(rawValue instanceof Number)) {
            return DEFAULT_HISTORY_SIZE;
        }

        var value = rawValue as Number;
        if (value < MIN_HISTORY_SIZE) {
            return MIN_HISTORY_SIZE;
        }
        if (value > MAX_HISTORY_SIZE) {
            return MAX_HISTORY_SIZE;
        }
        return value;
    }

    // ------------------------------------------------------------------
    // applySettings(): ricarica la finestra di smoothing dalle impostazioni
    // utente e azzera lo storico (mischiare campioni raccolti con una
    // finestra diversa da quella nuova darebbe una pendenza incoerente per
    // i primi secondi).
    //
    // ATTENZIONE: questo metodo NON è un callback di sistema. Il callback
    // onSettingsChanged() appartiene a Application.AppBase, non a
    // WatchUi.DataField: definirlo qui non avrebbe alcun effetto perché il
    // sistema non lo chiamerebbe mai. È quindi UltraTrailDashboardApp a
    // ricevere l'evento e a invocare questo metodo sulla View.
    // ------------------------------------------------------------------
    function applySettings() as Void {
        mHistorySize = loadSmoothingWindowSetting();
        resetGradeHistory();
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
    // ------------------------------------------------------------------
    function onTimerReset() as Void {
        resetGradeHistory();

        mSmoothedGradePercent = 0.0;
        mGapPaceSecPerUnit = 0.0;
        mHasValidGap = false;

        mPaceStr = "--:--";
        mHrStr = "---";
        mGradeStr = "0.0%";
        mGapStr = "--:--";
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
    // Qui aggiorniamo lo storico, calcoliamo pendenza e GAP, e scriviamo
    // il valore nel file FIT.
    // ------------------------------------------------------------------
    function compute(info as Activity.Info) as Numeric or Toybox.Time.Duration or String or Null {

        // --- 1) Aggiornamento storico quota/distanza -------------------
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

        // --- 2) Calcolo della pendenza stabilizzata (media mobile) ----
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

        // --- 3) Passo attuale (da velocità istantanea) ------------------
        // mUnitDistanceMeters vale 1000 (km) o 1609.344 (miglio) a seconda
        // delle unità di misura scelte dall'utente sul dispositivo: il
        // resto del calcolo (GAP, formattazione) non deve sapere quale
        // unità sia in uso, lavora sempre su "secondi per unità".
        // Anche qui la velocità viene copiata in una locale prima del
        // controllo di nullità: senza la copia, la divisione userebbe una
        // seconda lettura della proprietà, non coperta dal controllo.
        var currentPaceSecPerUnit = 0.0;
        var hasValidPace = false;
        var currentSpeed = info.currentSpeed;
        if (currentSpeed != null && currentSpeed > 0.1) {
            currentPaceSecPerUnit = mUnitDistanceMeters / currentSpeed;
            hasValidPace = true;
        }

        // --- 4) Calcolo del GAP (Grade Adjusted Pace) ------------------
        // La formula di Minetti lavora su un RAPPORTO di costi energetici,
        // quindi il risultato è corretto qualunque sia l'unità di distanza
        // usata per il passo in ingresso (km o miglio).
        if (hasValidPace) {
            mGapPaceSecPerUnit = calculateGap(currentPaceSecPerUnit, mSmoothedGradePercent);
            mHasValidGap = true;
        }

        // --- 5) Scrittura del valore nel file FIT -----------------------
        // Salviamo il GAP in minuti per unità (float): l'etichetta ":units"
        // dichiarata in createField() (min/km o min/mi) riflette la stessa
        // unità usata qui, così i grafici su Garmin Connect/Strava restano
        // coerenti con le impostazioni dell'utente.
        //
        // Scriviamo SOLO dopo aver calcolato almeno un GAP valido: prima di
        // allora il valore sarebbe 0.0, che verrebbe registrato come un dato
        // reale (picco a zero nel grafico e medie falsate) invece che come
        // "dato non disponibile". Da fermi con il timer avviato il campo
        // conserva l'ultimo GAP valido: non esiste un modo di scrivere un
        // valore "invalido" via setData(), che accetta solo il tipo
        // dichiarato in createField() e altrimenti solleva un'eccezione.
        var gapField = mGapField;
        if (gapField != null && mHasValidGap) {
            gapField.setData(mGapPaceSecPerUnit / 60.0);
        }

        // --- 6) Pre-formattazione delle stringhe per il disegno --------
        // Facciamo qui il lavoro "costoso" di formattazione, così
        // onUpdate() dovrà solo disegnare stringhe già pronte.
        //
        // Segnaliamo con mLayoutDirty se una stringa è cambiata davvero:
        // solo in quel caso onUpdate() dovrà rimisurare i font (vedi la
        // cache del layout più avanti).
        var currentHeartRate = info.currentHeartRate;
        setPaceStr(hasValidPace ? formatPace(currentPaceSecPerUnit) : "--:--");
        setHrStr((currentHeartRate != null) ? currentHeartRate.toString() : "---");
        setGradeStr(formatGrade(mSmoothedGradePercent));
        setGapStr(hasValidPace ? formatPace(mGapPaceSecPerUnit) : "--:--");

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
    // Setter delle 4 stringhe visualizzate. Aggiornano il valore solo se è
    // effettivamente cambiato e, in quel caso, marcano il layout come da
    // ricalcolare: è ciò che permette a onUpdate() di saltare le misure dei
    // font quando non serve rifarle.
    // ------------------------------------------------------------------
    private function setPaceStr(value as String) as Void {
        if (!value.equals(mPaceStr)) {
            mPaceStr = value;
            mLayoutDirty = true;
        }
    }

    private function setHrStr(value as String) as Void {
        if (!value.equals(mHrStr)) {
            mHrStr = value;
            mLayoutDirty = true;
        }
    }

    private function setGradeStr(value as String) as Void {
        if (!value.equals(mGradeStr)) {
            mGradeStr = value;
            mLayoutDirty = true;
        }
    }

    private function setGapStr(value as String) as Void {
        if (!value.equals(mGapStr)) {
            mGapStr = value;
            mLayoutDirty = true;
        }
    }

    // ------------------------------------------------------------------
    // Formula del GAP basata sul modello del costo energetico della corsa
    // di Minetti et al. (2002).
    //
    // C(i) = costo energetico per kg per metro percorso, in funzione
    // della pendenza "i" (frazione, es. 0.10 = 10% di salita):
    //
    //   C(i) = 155.4*i^5 - 30.4*i^4 - 43.3*i^3 + 46.3*i^2 + 19.5*i + 3.6
    //
    // Il GAP è il passo che, in piano (i=0, dove C(0)=3.6), richiederebbe
    // lo stesso "sforzo energetico per metro" del passo attuale sulla
    // pendenza corrente:
    //
    //   passoGAP = passoAttuale * C(0) / C(i)
    //
    // In salita C(i) > C(0) => passoGAP < passoAttuale (il GAP è più
    // "veloce" del passo reale, perché in salita si fa più fatica a
    // parità di velocità). In discesa vale il contrario.
    //
    // Nota sulle unità: la funzione è agnostica rispetto all'unità di
    // distanza (km o miglio) perché applica solo un fattore moltiplicativo
    // (un rapporto di costi energetici) al passo in ingresso — qualunque
    // unità abbia paceSecPerUnit, il risultato la eredita correttamente.
    // ------------------------------------------------------------------
    private function calculateGap(paceSecPerUnit as Float, gradePercent as Float) as Float {
        // Convertiamo la pendenza da percentuale a frazione (es. 12% -> 0.12)
        var i = gradePercent / 100.0;

        // Limitiamo la pendenza usata nella formula per restare nel range
        // in cui il modello di Minetti è affidabile (evita risultati
        // assurdi su pendenze estreme o dati GPS/altimetro rumorosi).
        if (i > MAX_GRADE_FRACTION) {
            i = MAX_GRADE_FRACTION;
        } else if (i < -MAX_GRADE_FRACTION) {
            i = -MAX_GRADE_FRACTION;
        }

        var i2 = i * i;
        var i3 = i2 * i;
        var i4 = i3 * i;
        var i5 = i4 * i;

        var costoPendenza = (155.4 * i5) - (30.4 * i4) - (43.3 * i3) + (46.3 * i2) + (19.5 * i) + 3.6;
        var costoPiano = 3.6; // C(0)

        // Protezione difensiva: il polinomio non può annullarsi nel range
        // limitato sopra, ma per sicurezza evitiamo comunque una divisione
        // per zero.
        if (costoPendenza < 0.1) {
            costoPendenza = 0.1;
        }

        return paceSecPerUnit * (costoPiano / costoPendenza);
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
    // Formatta la pendenza con un decimale e il segno (+/-).
    // ------------------------------------------------------------------
    private function formatGrade(gradePercent as Float) as String {
        return Lang.format("$1$%", [gradePercent.format("%+.1f")]);
    }

    // ------------------------------------------------------------------
    // onUpdate(dc): disegna la UI. NESSUN calcolo qui: solo disegno delle
    // stringhe già pronte (mPaceStr, mHrStr, mGradeStr, mGapStr).
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
        // delle 4 stringhe (mLayoutDirty, impostato dai setter in compute())
        // oppure le dimensioni del contesto grafico. Altrimenti riusiamo il
        // font già calcolato, risparmiando fino a 12 getTextWidthInPixels()
        // per ogni ridisegno.
        if (mLayoutDirty || width != mCachedLayoutWidth || height != mCachedLayoutHeight) {
            var chosenFont = mValueFontCandidates[mValueFontCandidates.size() - 1];
            for (var f = 0; f < mValueFontCandidates.size(); f++) {
                var candidateFont = mValueFontCandidates[f];
                var widestTextPx = dc.getTextWidthInPixels(mPaceStr, candidateFont);
                var hrWidthPx = dc.getTextWidthInPixels(mHrStr, candidateFont);
                if (hrWidthPx > widestTextPx) { widestTextPx = hrWidthPx; }
                var gradeWidthPx = dc.getTextWidthInPixels(mGradeStr, candidateFont);
                if (gradeWidthPx > widestTextPx) { widestTextPx = gradeWidthPx; }
                var gapWidthPx = dc.getTextWidthInPixels(mGapStr, candidateFont);
                if (gapWidthPx > widestTextPx) { widestTextPx = gapWidthPx; }

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

        // --- Colore di allerta per la pendenza ---------------------------
        // Sopra una certa pendenza (in salita O in discesa) coloriamo il
        // valore per renderlo riconoscibile a colpo d'occhio, senza dover
        // leggere il numero — utile quando si è stanchi durante un'ultra.
        // .abs() non alloca memoria: è sicuro chiamarlo in onUpdate().
        var gradeAbs = mSmoothedGradePercent.abs();
        var gradeValueColor = valueColor;
        if (gradeAbs >= GRADE_DANGER_THRESHOLD) {
            gradeValueColor = Graphics.COLOR_RED;
        } else if (gradeAbs >= GRADE_WARNING_THRESHOLD) {
            gradeValueColor = Graphics.COLOR_ORANGE;
        }

        drawQuadrant(dc, leftCenterX, topCenterY, mLabelPace, mPaceStr, valueColor);
        drawQuadrant(dc, rightCenterX, topCenterY, mLabelHr, mHrStr, valueColor);
        drawQuadrant(dc, leftCenterX, bottomCenterY, mLabelGrade, mGradeStr, gradeValueColor);
        drawQuadrant(dc, rightCenterX, bottomCenterY, mLabelGap, mGapStr, valueColor);
    }

    // ------------------------------------------------------------------
    // Disegna una coppia etichetta+valore centrata attorno al punto
    // (centerX, centerY) di un quadrante. Funzione di sola scrittura sul
    // Dc: non alloca nulla, riceve solo riferimenti a stringhe e costanti
    // già pronte, quindi rispetta la regola "niente allocazioni in onUpdate".
    //
    // Riceve solo 6 argomenti (il MASSIMO consentito dalla VM Monkey C dei
    // device meno recenti è 9): tutto ciò che è condiviso tra i 4 quadranti
    // (font, altezze, margine, colori di sfondo/etichetta) viene letto da
    // variabili di istanza invece che passato ogni volta come parametro.
    // ------------------------------------------------------------------
    private function drawQuadrant(
        dc as Graphics.Dc,
        centerX as Number,
        centerY as Number,
        label as String,
        value as String,
        valueColor as Graphics.ColorType
    ) as Void {
        var totalHeight = mDrawLabelHeight + mDrawGap + mDrawValueHeight;
        var blockTop = centerY - (totalHeight / 2);

        dc.setColor(mDrawLabelColor, mDrawBackgroundColor);
        dc.drawText(
            centerX, blockTop + (mDrawLabelHeight / 2),
            mDrawLabelFont, label,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        dc.setColor(valueColor, mDrawBackgroundColor);
        dc.drawText(
            centerX, blockTop + mDrawLabelHeight + mDrawGap + (mDrawValueHeight / 2),
            mDrawValueFont, value,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

}
