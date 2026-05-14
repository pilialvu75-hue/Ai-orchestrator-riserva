#!/usr/bin/env python3
from __future__ import annotations

import argparse
from datetime import datetime, timezone
from pathlib import Path
import re


def parse_pubspec_version(pubspec_path: Path) -> str:
    content = pubspec_path.read_text(encoding="utf-8")
    match = re.search(r"^version:\s*([^\s]+)\s*$", content, re.MULTILINE)
    if not match:
        return "non disponibile"
    return match.group(1)


def build_content(version: str) -> str:
    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    return f"""# README Build — AI Orchestrator (Italiano)

> File generato automaticamente durante la build.
>
> Versione app: **{version}**  
> Generato il: **{generated_at}**

## Panoramica

AI Orchestrator è un'app Flutter multipiattaforma orientata alla produttività tecnica con:
- chat AI multi-provider
- gestione memoria di progetto
- supporto runtime locale (offline) e cloud (online)
- cronologia conversazioni
- onboarding, impostazioni e aggiornamenti in-app

## Funzioni dell'applicazione

1. **Chat AI**
   - invio/ricezione messaggi in sessioni persistenti
   - gestione contesto conversazionale e cache risposte
   - cronologia locale su SQLite

2. **Memoria di progetto**
   - salvataggio di obiettivo principale, contesto corrente e ultimo snippet
   - riuso automatico del contesto nelle richieste AI

3. **Provider AI multipli**
   - scelta provider cloud (OpenAI/Gemini/Grok/Copilot)
   - supporto inferenza locale offline con modelli scaricabili

4. **Gestione modelli locali**
   - elenco modelli disponibili
   - download, selezione e aggiornamento modello attivo

5. **Impostazioni utente**
   - preferenze applicative
   - configurazione chiavi API
   - scelta lingua interfaccia

6. **Aggiornamenti applicazione**
   - controllo versioni in background
   - download aggiornamenti Android e preparazione installazione

7. **Avvio guidato (onboarding)**
   - inizializzazione servizi principali
   - configurazione iniziale al primo avvio

## Manuale rapido (Italiano)

### 1) Primo avvio
1. Apri l'app.
2. Completa onboarding e controlla il modello/provider predefinito.
3. Inserisci le eventuali API key nelle Impostazioni.

### 2) Avviare una chat
1. Vai alla schermata Chat.
2. Scrivi il messaggio e invia.
3. La conversazione viene salvata automaticamente nella cronologia.

### 3) Usare la memoria di progetto
1. Apri la sezione memoria/progetto.
2. Aggiorna obiettivo, contesto e snippet.
3. Salva: il contesto verrà riutilizzato nelle risposte AI.

### 4) Cambiare modello/provider
1. Apri le Impostazioni.
2. Seleziona provider cloud o modello locale.
3. Se necessario scarica il modello e impostalo come attivo.

### 5) Risoluzione problemi base
- Se non arrivano risposte: verifica API key e connessione.
- Se usi runtime locale: controlla download completo del modello.
- Se la build/distribuzione Android fallisce: verificare firma, allineamento e artifact prodotti.

## Documentazione completa

Per guida estesa in italiano e dettagli architetturali:
- `docs/GUIDA_IT.md`
- `docs/MODULAR_ARCHITECTURE.md`
- `README.md`
"""


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Genera il README/manuale in italiano durante la build.",
    )
    parser.add_argument(
        "--output",
        default="BUILD_README_IT.md",
        help="Path del file markdown da generare.",
    )
    parser.add_argument(
        "--version",
        default=None,
        help="Versione da stampare nel file; se omessa viene letta da pubspec.yaml.",
    )
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[1]
    output_path = (repo_root / args.output).resolve()
    pubspec_path = repo_root / "pubspec.yaml"

    version = args.version or parse_pubspec_version(pubspec_path)
    content = build_content(version)
    output_path.write_text(content, encoding="utf-8")
    print(f"Generato {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
