# AIVEXUS Computer Use — Windows MVP (11 novembre 2026)

## Obiettivo e confini

Questo checkpoint NON dichiara Computer Use autonomo pronto. E una prima
implementazione reale di input/cattura schermo Windows, montata dietro al
contratto tool e a un laboratorio manuale accessibile da **Impostazioni >
Computer Use — Laboratorio** su Windows.

- Windows: prima piattaforma, azioni OS effettive ma ancora senza test fisici.
- Android/Linux/macOS: adattatori futuri, non dichiarati supportati.
- Web: sandbox browser; non e possibile controllare il desktop dell'host.
- Nessuna dipendenza dal Cloud o da llama.cpp per le azioni manuali.
- Nessuna registrazione del tool nel loop del modello; il modello NON puo
  attivare la sessione di propria iniziativa.
- Screenshot in memoria; file temporaneo di cattura eliminato dopo la lettura.
- Testo digitato e immagini non vengono inviati a Diagnostics ne al Cloud.

## Checkpoint di implementazione

| Componente | Stato |
| --- | --- |
| Contratto ComputerUseAdapter | Implementato |
| Sessione temporanea e revocabile (10 min) | Implementato |
| Observe / screenshot PNG schermo primario | Implementato; da collaudare su Windows reale |
| Click coordinate e selezione finestra attiva | Implementato; da collaudare |
| Testo Unicode, tasti di navigazione | Implementato; da collaudare |
| UI di laboratorio con consenso e STOP | Implementato; da collaudare |
| Test autorizzazioni, STOP, concorrenza, allowlist e verifica | Aggiunti; CI del nuovo commit da verificare |
| Interpretazione visiva LLM | NON implementata |
| Motore autonomo astratto `ComputerUseAgentRunner` | Implementato e testato con planner e verificatore simulati; NON collegato a IA reale |
| Ciclo dinamico observe → decide → agisci → ri-osserva → verifica | Implementato nel runner isolato; manca il modello reale |
| Revoca durante inferenza / nuova sessione | Revisioni di autorizzazione implementate; test in CI |
| Ciclo autonomo con LLM configurato | NON implementato; esiste solo l'esecutore indipendente dal provider |
| UI Automation: verifica solo marcatore sintetico QA | Implementata sperimentalmente; non validata su Windows fisico |
| Sequenza controllata Blocco note → scrittura → verifica → screenshot | Implementata; CI da verificare e QA fisico necessario |
| Integrazione Diagnostics anonimizzata | NON implementata |
| Aggiornamento beta | NON rilasciato |

## Test manuale su ASUS Windows (senza disattivare Defender)

1. Installare solo tramite il canale aggiornamenti dell'app una futura
   beta che includa il commit verificato.
2. Aprire Impostazioni > Computer Use — Laboratorio.
3. Scegliere Osserva schermo e autorizzare: comparira l'immagine dello
   schermo primario; il pulsante Aggiorna acquisira un altro frame.
4. Fermare, avviare Abilita interazione, poi scegliere
   "Seleziona finestra attiva (4 secondi)". Subito dopo usare Alt+Tab per
   portare in primo piano il Blocco note senza informazioni riservate.
5. Tornare al laboratorio e premere Aggiorna: il sistema deve riportare la
   schermata della finestra selezionata; toccare una posizione nella preview
   e verificare che il clic arrivi alla finestra corretta.
6. Tornare al laboratorio, scrivere "Prova Computer Use Aivexus", premere
   Inserisci testo. Verificare che venga scritto nella finestra selezionata,
   non nei controlli Aivexus.
7. Provare Tab, Invio, frecce; premere STOP anche durante un'operazione.
8. Fermare e riavviare Abilita interazione. Premere
   **Test automatico: Blocco note** e non cambiare app durante l'esecuzione.
   Il test deve avviare Blocco note, selezionarlo, scrivere un marcatore QA,
   ritrovarlo tramite UI Automation e acquisire una schermata; conta come PASS
   **solo** se il testo esatto e verificato. In caso di impossibilita di
   leggere il controllo, segnare NON SUPERATO, non assumere un successo.
9. Controllare la scadenza a 10 minuti e ripetere dopo riavvio dell'app: le
   autorizzazioni non devono essere persistenti.

Non provare su finestre che contengono password, dati riservati o modifiche
irreversibili. Windows UAC/elevazione, sessioni bloccate e Secure Desktop
non sono in scope. Se Defender/SmartScreen blocca un binario non firmato,
risolvere firma e distribuzione: non disattivare le protezioni di Windows.

## Prossimo ciclo: agenti autonomi

1. Estendere la sonda UI Automation limitata ai marcatori QA a un backend
   di accessibilita strutturato e rilevamento contesto senza OCR obbligatorio.
2. Collegare un planner LLM LOCAL e un verificatore indipendente al runner,
   usando l'accessibilita strutturata o una visione locale. Cloud solo dopo
   consenso esplicito separato per le immagini; nessun upload automatico.
3. Consolidare il runner gia creato: limiti di step, durata, ripetizioni,
   anti-loop e STOP; estendere al recupero dagli errori reali, audit
   metadata-only e verifica dello stato finale.
4. Integrazione con l'orchestratore Aivexus e il Cantiere senza introdurre
   Main/Reviewer obbligatori.
5. Convalida fisica Windows e regressioni su Android; solo dopo espansione
   agli altri host.

**Criterio di completamento**: Aivexus deve eseguire da richiesta naturale
almeno tre scenari non distruttivi su Windows (aprire un'app, compilare un
campo di prova, verificare il risultato) senza passi manuali intermedi, con
STOP e consensi effettivi. Il solo PASS di Flutter test non basta.
