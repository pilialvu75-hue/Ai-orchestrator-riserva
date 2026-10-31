import 'package:flutter/material.dart';

/// A compact conversation entry shared by the mobile drawer and desktop
/// sidebar. The parent owns navigation, the menu and all session actions.
/// This widget intentionally does not read or modify stored conversations.
class ChatSessionTile extends StatelessWidget {
  const ChatSessionTile({
    super.key,
    required this.title,
    required this.pinned,
    required this.selected,
    required this.trailing,
    required this.onTap,
    required this.onLongPress,
  });

  final String title;
  final bool pinned;
  final bool selected;
  final Widget trailing;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Material(
        color: selected ? const Color(0xFF23344A) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          selected: selected,
          selectedTileColor: Colors.transparent,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10),
          minLeadingWidth: 18,
          horizontalTitleGap: 8,
          minVerticalPadding: 0,
          leading: Icon(
            pinned ? Icons.push_pin : Icons.chat_bubble_outline,
            color: pinned
                ? const Color(0xFF8AB4F8)
                : selected
                    ? const Color(0xFFD1E4FF)
                    : Colors.white60,
            size: 17,
          ),
          title: Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected ? Colors.white : Colors.white.withValues(alpha: 0.88),
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              height: 1.2,
            ),
          ),
          trailing: trailing,
          onTap: onTap,
          onLongPress: onLongPress,
        ),
      ),
    );
  }
}
