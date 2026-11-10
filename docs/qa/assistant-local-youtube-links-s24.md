# Collaudo mirato — link YouTube in Chat LOCAL (issue #1102)

**Piattaforma primaria:** Samsung Galaxy S24 FE / Android, installazione unicamente da **Impostazioni → Aggiornamenti**. Non scaricare APK manuali e non disinstallare l'app.

**Prerequisiti:** versione beta con PR #1103 effettivamente inclusa, Qwen2.5 3B Instruct in modalità LOCAL, chat nuova. Controllare versione e release notes prima di iniziare.

## Contratto del rilascio

- Il link `youtube.com/shorts`, `watch?v=`, `youtu.be` viene riconosciuto come video YouTube pubblico senza esporre parametri di tracciamento.
- Con Internet consentito, usa solo metadati pubblici oEmbed: **titolo e canale**. Non legge audio, fotogrammi, sottotitoli o descrizione completa.
- Quando titolo/canale non sono recuperabili, dichiara la limitazione **una volta**, in italiano, senza inventare una trama.
- Con Internet disabilitato o richiesta `Non usare internet` / `Non aprire questo link`, nessuna richiesta Web esterna per il video.
- Nessuna modifica alla selezione del modello, memoria condivisa o consensi HYBRID/Cloud.
- La risposta deve evitare loop di frasi. Se si ripresentano, segnalare a #1101 (bug intermittente monitorato, non considerato risolto).

## Test sul dispositivo

| ID | Input / operazione | Atteso |
| --- | --- | --- |
| L1 | `ecco il link: https://youtube.com/shorts/hZdi0JUEFSc` | Dati titolo/canale **solo se** oEmbed accessibile; altrimenti risposta di indisponibilità, mai un riassunto inventato |
| L2 | `https://youtube.com/shorts/upY-jceP0vM?is=tracking\ndescrizione del video` | Riconosce il video e chiarisce che l'API metadati non equivale alla descrizione completa; nessun doppio testo |
| L3 | Disabilitare Wi-Fi e dati mobili, poi reinviare L1 in nuova chat | Nessun crash; breve avviso di indisponibilità; verifica log senza contenuto del prompt |
| L4 | Ristabilire rete. `Non aprire questo link: https://youtu.be/hZdi0JUEFSc` | Nessun fetch del video; risposta che rispetta divieto |
| L5 | `cerca informazioni su https://youtube.com/shorts/hZdi0JUEFSc` | Tratta come link YouTube, non come una generica ricerca testuale Web |
| L6 | `https://youtube.com.evil.example/watch?v=hZdi0JUEFSc` | Rifiuta riconoscimento YouTube ufficiale; nessun fetch via percorso oEmbed |
| L7 | Domanda normale senza URL: `Spiega cos'è il glucosio.` | La chat e la selezione Qwen restano funzionanti (regressione) |

## Diagnostica e verdetto

Registrare per ogni caso: versione completa, modello selezionato, connettività, durata percepita, esito PASS/FAIL, screenshot e (se presenti) eventi `[ASSISTANT_YOUTUBE_LINK]`. Nessun log deve contenere link con token di tracking, contenuto di chat, ricordi o credenziali.

I test unitari con `MockClient` e CI su desktop **non sostituiscono** il collaudo fisico S24 FE. Non affermare che il video è stato visto o riassunto finché la funzione di trascrizione non sarà realmente implementata e verificata.
