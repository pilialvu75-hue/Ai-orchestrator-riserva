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
| Click coordinate e target window | Implementato; da collaudare |
| Testo Unicode, tasti di navigazione | Implementato; da collaudare |
| UI di laboratorio con consenso e STOP | Implementato; da collaudare |
| Test automatici del gate autorizzazioni | Aggiunti; CI da verificare |
| Interpretazione visiva LLM | NON implementata |
| Ciclo autonomo osserva/pianifica/agisci/verifica | NON implementato |
| Accessibilita/UI Automation | NON implementata |
| Integrazione Diagnostics anonimizzata | NON implementata |
| Aggiornamento beta | NON rilasciato |

## Test manuale su ASUS Windows (senza disattivare Defender)

1. Installare solo tramite il canale aggiornamenti dell'app una futura
   beta che includa il commit verificato.
2. Aprire Impostazioni > Computer Use — Laboratorio.
3. Scegliere Osserva schermo e autorizzare: comparira l'immagine dello
   schermo primario; il pulsante Aggiorna acquisira un altro frame.
4. Fermare, avviare Abilita interazione. Toccare sulla preview una finestra
   di prova (per esempio Blocco note) e verificare che riceva il clic.
5. Tornare al laboratorio, scrivere "Prova Computer Use Aivexus", premere
   Inserisci testo. Verificare che vada nella finestra selezionata.
6. Provare Tab, Invio, frecce e il pulsante STOP.
7. Controllare la scadenza a 10 minuti e ripetere dopo riavvio dell'app: le
   autorizzazioni non devono essere persistenti.

Non provare su finestre che contengono password, dati riservati o modifiche
irreversibili. Windows UAC/elevazione, sessioni bloccate e Secure Desktop
non sono in scope. Se Defender/SmartScreen blocca un binario non firmato,
risolvere firma e distribuzione: non disattivare le protezioni di Windows.

## Prossimo ciclo: agenti autonomi

1. Aggiungere backend di accessibilita Windows (UI Automation) e rilevamento
   del contesto senza OCR obbligatorio per ogni clic.
2. Collegare visione locale / Cloud con consensi separati a screenshot.
3. Implementare observe -> plan -> action -> verify -> recover con limiti
   di step e tempo, stop immediato, audit metadata-only e verifiche sullo
   stato di arrivo.
4. Integrazione con l'orchestratore Aivexus e il Cantiere senza introdurre
   Main/Reviewer obbligatori.
5. Convalida fisica Windows e regressioni su Android; solo dopo espansione
   agli altri host.

**Criterio di completamento**: Aivexus deve eseguire da richiesta naturale
almeno tre scenari non distruttivi su Windows (aprire un'app, compilare un
campo di prova, verificare il risultato) senza passi manuali intermedi, con
STOP e consensi effettivi. Il solo PASS di Flutter test non basta.
