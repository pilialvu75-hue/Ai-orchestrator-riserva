import 'package:flutter/material.dart';

/// Explicit, non-dismissible-by-accident confirmation for a destructive
/// operation that applies only to conversations already in the local trash.
class EmptyTrashConfirmationDialog extends StatelessWidget {
  const EmptyTrashConfirmationDialog({super.key, required this.chatCount});

  final int chatCount;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Svuotare il cestino?'),
        content: Text(
          'Eliminare definitivamente $chatCount '
          '${chatCount == 1 ? 'conversazione' : 'conversazioni'} dal cestino? '
          'Non sarà possibile ripristinarle. Le chat attive e i ricordi '
          'condivisi tra chat resteranno. I ricordi salvati soltanto nelle '
          'conversazioni cestinate saranno eliminati.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annulla'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Elimina definitivamente'),
          ),
        ],
      );
}
