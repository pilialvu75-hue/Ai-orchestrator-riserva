# Download Android dopo approvazione

Il tap di download già previsto dall'app avvia un trasferimento di Android
DownloadManager. La notifica di sistema ne mostra l'avanzamento. Uscire dalla
schermata, mandare l'app in background o chiudere normalmente il processo Flutter
non annulla la richiesta. L'arresto forzato nelle impostazioni Android, la
disinstallazione e i limiti imposti dal sistema non sono equivalenti alla normale
chiusura e non sono coperti da questa promessa.

Sono collegati aggiornamenti APK, catalogo LLM (inclusi URL personalizzati),
download/riparazione dei singoli modelli nelle impostazioni, archivio STT e Kokoro.
Le altre piattaforme conservano il trasporto esistente.

Alla riapertura l'aggiornamento APK approvato viene recuperato automaticamente.
Per i modelli, un tap su Scarica per lo stesso elemento recupera la richiesta
persistente senza duplicare il trasferimento. Verifica ed estrazione avvengono
con l'app in esecuzione; il completamento della notifica riguarda i byte
scaricati, non certifica che il pacchetto sia pronto. L'APK continua a passare
le verifiche esistenti e il consenso dell'installer Android.

DownloadManager conserva temporaneamente il file in uno spazio riservato
all'app. Il client copia il file completo in un nuovo parziale e lo pubblica
solo dopo la verifica prevista dal relativo percorso. Può essere necessario
spazio per entrambe le copie e per l'estrazione. I vecchi parziali Dio non vengono
usati come prova di completezza né importati nel gestore Android.

## Verifica

Test Flutter: completamento già disponibile al riavvio, rifiuto di file
troncati, fallimento nativo e annullamento prima/durante l'avvio.

Prima del rilascio verificare sul telefono:

1. Avviare un download approvato e controllare la notifica.
2. Uscire dalla schermata, spegnere lo schermo e poi chiudere normalmente l'app.
3. Riaprire e recuperare lo stesso download senza un secondo trasferimento.
4. Provare una breve perdita di rete e il pulsante di annullamento LLM.
5. Verificare che APK e Kokoro completati passino ancora i rispettivi controlli.

Riferimento: https://developer.android.com/reference/android/app/DownloadManager
