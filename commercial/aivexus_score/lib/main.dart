import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'score_session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  runApp(ScoreApp(store: ScoreStore(preferences)));
}

/// Each write is serialized so fast taps cannot leave an older score on disk.
class ScoreStore {
  ScoreStore(this._preferences);

  static const String storageKey = 'aivexus_score_session_v1';
  final SharedPreferences _preferences;
  Future<void> _pendingWrite = Future<void>.value();

  ScoreSession load() =>
      ScoreSession.fromEncoded(_preferences.getString(storageKey));

  Future<void> save(ScoreSession session) {
    final serialized = jsonEncode(session.toJson());
    _pendingWrite = _pendingWrite.catchError((Object _) {}).then((_) async {
      final saved = await _preferences.setString(storageKey, serialized);
      if (!saved) throw StateError('Could not save the score');
    });
    return _pendingWrite;
  }
}

class ScoreApp extends StatelessWidget {
  const ScoreApp({required this.store, super.key});

  final ScoreStore store;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'AIVEXUS Score',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF285CAB)),
      useMaterial3: true,
    ),
    home: ScorePage(store: store),
  );
}

String _t({
  required String it,
  required String en,
  required String fr,
  required String es,
}) {
  switch (WidgetsBinding.instance.platformDispatcher.locale.languageCode) {
    case 'it':
      return it;
    case 'fr':
      return fr;
    case 'es':
      return es;
    default:
      return en;
  }
}

class ScorePage extends StatefulWidget {
  const ScorePage({required this.store, super.key});

  final ScoreStore store;

  @override
  State<ScorePage> createState() => _ScorePageState();
}

class _ScorePageState extends State<ScorePage> {
  late final ScoreSession _session;

  @override
  void initState() {
    super.initState();
    _session = widget.store.load();
  }

  Future<void> _update(void Function() action) async {
    setState(action);
    try {
      await widget.store.save(_session);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _t(
              it: 'Salvataggio non riuscito. Riprova.',
              en: 'Save failed. Please try again.',
              fr: 'Enregistrement impossible. Réessayez.',
              es: 'No se pudo guardar. Inténtalo de nuevo.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _rename(bool isHome) async {
    var candidateName = isHome ? _session.homeName : _session.awayName;
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          _t(
            it: 'Nome partecipante',
            en: 'Player name',
            fr: 'Nom du joueur',
            es: 'Nombre del jugador',
          ),
        ),
        content: TextFormField(
          key: const Key('name-input'),
          initialValue: candidateName,
          maxLength: 24,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onChanged: (value) => candidateName = value,
          onFieldSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              _t(it: 'Annulla', en: 'Cancel', fr: 'Annuler', es: 'Cancelar'),
            ),
          ),
          FilledButton(
            key: const Key('confirm-name'),
            onPressed: () => Navigator.of(context).pop(candidateName),
            child: Text(
              _t(it: 'Salva', en: 'Save', fr: 'Enregistrer', es: 'Guardar'),
            ),
          ),
        ],
      ),
    );
    if (value != null && mounted) {
      await _update(() => _session.rename(isHome: isHome, value: value));
    }
  }

  Future<void> _confirmReset() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          _t(
            it: 'Azzerare la partita?',
            en: 'Reset this match?',
            fr: 'Réinitialiser la partie ?',
            es: '¿Reiniciar la partida?',
          ),
        ),
        content: Text(
          _t(
            it: 'Il punteggio torna a zero. Puoi usare Annulla subito dopo.',
            en: 'Scores return to zero. You can undo this action.',
            fr: 'Les scores reviennent à zéro. Vous pouvez annuler.',
            es: 'Los puntos volverán a cero. Puedes deshacerlo.',
          ),
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('cancel-reset'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              _t(it: 'Annulla', en: 'Cancel', fr: 'Annuler', es: 'Cancelar'),
            ),
          ),
          FilledButton(
            key: const Key('confirm-reset'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              _t(it: 'Azzera', en: 'Reset', fr: 'Effacer', es: 'Reiniciar'),
            ),
          ),
        ],
      ),
    );
    if (approved == true && mounted) {
      await _update(_session.reset);
    }
  }

  Widget _playerCard(bool isHome) {
    final name = isHome ? _session.homeName : _session.awayName;
    final score = isHome ? _session.home : _session.away;
    final prefix = isHome ? 'home' : 'away';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Flexible(
                  child: Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  key: Key('$prefix-rename'),
                  tooltip: _t(
                    it: 'Cambia nome',
                    en: 'Rename',
                    fr: 'Renommer',
                    es: 'Cambiar nombre',
                  ),
                  onPressed: () => _rename(isHome),
                  icon: const Icon(Icons.edit_outlined),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Semantics(
              label: '$name: $score',
              child: Text(
                score.toString(),
                key: Key('$prefix-score'),
                style: Theme.of(context).textTheme.displayLarge,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                OutlinedButton(
                  key: Key('$prefix-minus'),
                  onPressed: score == 0
                      ? null
                      : () => _update(
                            () => _session.adjust(isHome: isHome, by: -1),
                          ),
                  child: const Text('−1'),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  key: Key('$prefix-plus'),
                  onPressed: score >= ScoreSession.maxScore
                      ? null
                      : () => _update(
                            () => _session.adjust(isHome: isHome, by: 1),
                          ),
                  child: const Text('+1'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final description = _t(
      it: 'Segnapunti privato, senza account e senza pubblicità',
      en: 'Private scoreboard. No account. No ads.',
      fr: 'Scores privés, sans compte ni publicité',
      es: 'Marcador privado, sin cuenta ni anuncios',
    );

    return Scaffold(
      appBar: AppBar(title: const Text('AIVEXUS Score')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.all(14),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 820),
                child: Column(
                  children: <Widget>[
                    Text(
                      description,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    if (constraints.maxWidth < 570)
                      Column(
                        children: <Widget>[
                          _playerCard(true),
                          _playerCard(false),
                        ],
                      )
                    else
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Expanded(child: _playerCard(true)),
                          Expanded(child: _playerCard(false)),
                        ],
                      ),
                    const SizedBox(height: 18),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 12,
                      runSpacing: 12,
                      children: <Widget>[
                        OutlinedButton.icon(
                          key: const Key('undo-button'),
                          onPressed: _session.canUndo
                              ? () => _update(_session.undo)
                              : null,
                          icon: const Icon(Icons.undo),
                          label: Text(
                            _t(
                              it: 'Annulla mossa',
                              en: 'Undo last move',
                              fr: 'Annuler le dernier point',
                              es: 'Deshacer último punto',
                            ),
                          ),
                        ),
                        FilledButton.tonalIcon(
                          key: const Key('reset-button'),
                          onPressed: _confirmReset,
                          icon: const Icon(Icons.restart_alt),
                          label: Text(
                            _t(
                              it: 'Nuova partita',
                              en: 'New match',
                              fr: 'Nouvelle partie',
                              es: 'Nueva partida',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Text(
                      _t(
                        it: 'Punteggi salvati solo su questo dispositivo.',
                        en: 'Scores are saved on this device only.',
                        fr: 'Scores enregistrés uniquement sur cet appareil.',
                        es: 'Puntuaciones guardadas solo en este dispositivo.',
                      ),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
