from pathlib import Path

production = Path('lib/app_factory/workshop/workshop_production_dashboard_page.dart')
text = production.read_text()
old = '${selectedProject.title}'
new = '${selectedProject!.title}'
if text.count(old) != 1:
    raise SystemExit(f'nullable delete anchor count={text.count(old)}')
production.write_text(text.replace(old, new, 1))

page = Path('lib/app_factory/workshop/workshop_dashboard_page.dart')
text = page.read_text()
old = """    _chatController.clearConversation();
    _addWelcomeMessage();

    _messageController.clear();

    _showMessage(
      'Nuova conversazione del Cantiere.',
    );
"""
new = """    await widget._clearPendingPrompt?.call();

    _chatController.clearConversation();
    _addWelcomeMessage();

    _messageController.clear();

    _showMessage(
      'Nuova conversazione del Cantiere.',
    );
"""
if text.count(old) != 1:
    raise SystemExit(f'new conversation anchor count={text.count(old)}')
page.write_text(text.replace(old, new, 1))
