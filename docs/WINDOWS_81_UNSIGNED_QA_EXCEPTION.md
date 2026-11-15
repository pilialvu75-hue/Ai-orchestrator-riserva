# Eccezione di laboratorio AIVEXUS — Windows 8.1

**Autorizzazione del proprietario (15 novembre 2026):** permettere
specificamente sul PC Windows 8.1 un percorso QA che non richieda
una firma Authenticode attendibile. Il blocco Smart App Control
osservato su ASUS riguarda Windows 11; non disattivare protezioni.

## Limiti dell'eccezione

- La definizione Inno `AivexusWin81UnsignedQABuild` attiva
  `MinVersion=6.3` e `OnlyBelowVersion=10.0`. L'installer rifiuta
  Windows 7, 8.0, 10 e 11: il target è **solo Windows 8.1**.
- Senza `AivexusRecoveryHelper`, la compilazione fallisce.
  Il nuovo installer deve fare un backup verificato *prima* di
  sostituire il programma; il ripristino deve funzionare anche
  fuori dall'app.
- Questa definizione non viene aggiunta ai workflow di release
  ordinari né alla beta firmata Computer Use. È un percorso di
  prova che deve essere autorizzato, tracciato e collaudato.
- Un setup compilato NON prova che Flutter 3.47 sia compatibile
  con Win8.1: l'engine supporta ufficialmente Windows 10/11.
  Fare un test fisico con possibilità di tornare alla
  `v1.0.12.2` e verificare l'inferenza LOCAL.
- Non riutilizzare il tag `104238` e non pubblicare come
  aggiornamento generale un setup destinato esclusivamente a
  Win8.1: Windows 11 deve continuare a richiedere firma attendibile.
- Il normale updater Windows scarica l'asset generale dal
  canale di release. Una distribuzione **in-app mirata**
  richiede ancora l'identificazione dell'OS prima di scegliere
  l'asset legacy e un gate di pubblicazione dedicato.
  Questa PR **non rende già disponibile l'aggiornamento**
  sul Lenovo.
- La gestione dei profili dati quando UAC richiede credenziali
  di un altro account va verificata sul dispositivo reale.

Non disabilitare Defender, non disinstallare AIVEXUS, non
eseguire il setup `104238` aspettandosi un rollback.
