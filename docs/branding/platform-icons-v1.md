# Branding Aivexus / AI-Orchestrator — Icone approvate v1

**Fonte originale dell'utente:** `AI-Orchestrator-Platform-Icons-v1.zip`, creato il **16 settembre 2026**, 109 elementi, anteprima `PREVIEW_all_platforms.png`, istruzioni originali `README_IT.md`.
**SHA-256 archivio:** `c4355dd078a26861f98f8f643c9a88aa947d8a13b95c14e2dd292e21e84bd414`.

Varianti approvate: icona neon blu scuro con bacchetta e logo AO; macOS (rete neurale), Android (robot), Windows (finestre), iOS (telefono), Linux (pinguino), Web/PWA (globo), Raspberry Pi/ARM (circuito). Utilizzare **le immagini esatte**, non icone generate di nuovo né segnaposto.

## Applicazione verificabile (su un branch di PR, senza creare una release)

1. Recuperare l'archivio originale (non è copiato nel repository: asset binario fornito dall'utente; non scaricare da host sconosciuti).
2. `python3 scripts/install_platform_icons.py /percorso/AI-Orchestrator-Platform-Icons-v1.zip --dry-run`
3. `python3 scripts/install_platform_icons.py /percorso/AI-Orchestrator-Platform-Icons-v1.zip --apply`
4. Verificare diff, immagini, densità, test e compilazioni; proporre PR separata di **soli asset**. Non modificare SQL, package ID, versioni o il percorso di aggiornamento.

## Destinazioni del loader

- **Android:** `android/app/src/main/res/mipmap-*/ic_launcher*.png/xml` e risorsa colore `ic_launcher_background`. Conservare le altre risorse di `values/colors.xml`.
- **Windows:** `windows/runner/resources/app_icon.ico` (utilizzato anche da `SetupIconFile` in Inno Setup).
- **macOS:** `macos/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json` e PNG relativi.
- **iOS / Web:** applicare soltanto se i relativi scaffold sono presenti. Su Web aggiornare le icone `web/icons/` e `favicon.png` senza riscrivere automaticamente un manifest personalizzato.
- **Linux / Raspberry Pi:** gli asset originali esistono nel pack; integrazione del launcher `.desktop` e packaging va effettuata quando presente un percorso di distribuzione verificato, senza inventare installer.

Il loader fallisce se SHA-256 non corrisponde; non modifica nulla in modalità dry-run. `test/scripts/test_install_platform_icons.py` copre copia, sicurezza, idempotenza e preservazione colori.

**Sequenza prioritaria:** completare installatore Windows + controllo OTA SQLite sulla release 103679 e blocco Mac firmato/notarizzato, poi asset branding su una **nuova release ufficiale** raggiungibile attraverso `Impostazioni → Aggiornamenti`. Non alterare la release 103679 già pubblicata. Nessun APK/EXE/DMG manuale, nessuna disinstallazione o cancellazione dati.
