---
name: Promuovere una funzione sperimentale
about: Collaudo reale completato e convergenza nella AIVEXUS ordinaria
title: "[promotion] "
labels: []
assignees: []
---

## Feature e perimetro

- Feature sperimentale:
- Issue / PR / SHA integrato in `main`:
- Versione beta testata (tag + link asset):
- Piattaforme realmente verificate:
- Piattaforme da mantenere sperimentali / non supportate:

## Evidenze del collaudo reale (obbligatorie)

- [ ] Esecuzione su dispositivo/OS reale, con log non personali e passaggi riproducibili
- [ ] Risultato della funzione realmente osservato (non soltanto simulato o CI)
- [ ] CI e test di regressione PASS sulla HEAD candidata
- [ ] Permessi/consenso, STOP e limiti di sicurezza rispettati
- [ ] Aggiornamento in-app e installazione fisica riusciti
- [ ] Dati conservati e **rollback fuori dall'app** collaudato se applicabile
- [ ] Firma e criteri di sicurezza OS rispettati; nessuna protezione disabilitata
- [ ] Rischi noti, vincoli piattaforma e regressioni documentati

## Convergenza nel prodotto

- [ ] PR di promozione aperta sulla HEAD corrente di `main`
- [ ] Nessuna seconda implementazione/fork da mantenere
- [ ] Flag QA rimosso o sostituito da consenso/impostazione necessaria
- [ ] Feature visibile nella **build ordinaria sulle sole piattaforme validate**
- [ ] Review + CI PASS e merge verificato
- [ ] Release ordinaria autorizzata e disponibile tramite updater
- [ ] Installazione reale della release ordinaria collaudata
- [ ] Branch sperimentale originale riconciliato e chiuso; nessun commit unico perso

## Link e stato

- PR di promozione:
- Test fisici / Diagnostics anonimizzati:
- Release ordinaria:
- Esito: Integrato ma non testato / Validato / Promosso / Rilasciato / Bloccato

> La sola integrazione su `main` o una build CI PASS **non autorizzano**
> a dichiarare il prodotto stabile. La pubblicazione resta soggetta alle
> approvazioni del proprietario e ai gate di release.
