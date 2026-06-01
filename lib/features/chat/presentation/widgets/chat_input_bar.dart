import 'dart:io';

import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/voice/voice_input_service.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/runtime/app_localizations.dart';
import 'package:ai_orchestrator/features/multimodal/data/services/file_attachment_service.dart';
import 'package:ai_orchestrator/features/multimodal/data/services/image_service.dart';
import 'package:ai_orchestrator/features/voice/presentation/widgets/voice_input_button.dart';
import 'package:ai_orchestrator/injection_container.dart' as di;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

class ChatInputBar extends StatefulWidget {
  const ChatInputBar({
    super.key,
    required this.onSend,
    this.isLoading = false,
    this.onStartLiveSession,
    this.liveSessionEnabled = true,
  });

  final void Function(String text, List<ChatAttachment> attachments) onSend;
  final bool isLoading;
  final VoidCallback? onStartLiveSession;
  final bool liveSessionEnabled;

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  static const _uuid = Uuid();

  final _controller = TextEditingController();
  final List<ChatAttachment> _attachments = <ChatAttachment>[];
  late final ImageService _imageService;
  late final FileAttachmentService _fileAttachmentService;
  late final VoiceInputService _voiceInputService;

  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _imageService = di.sl<ImageService>();
    _fileAttachmentService = di.sl<FileAttachmentService>();
    _voiceInputService = di.sl<VoiceInputService>();
    _controller.addListener(() {
      setState(() => _hasText = _controller.text.trim().isNotEmpty);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canSubmit => _hasText || _attachments.isNotEmpty;

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty && _attachments.isEmpty) return;
    
    debugPrint(
      '[UI_SEND] source=chat_input_bar state=${hashCode.toRadixString(16)} chars=${text.length} attachments=${_attachments.length}',
    );
    
    RuntimeEventLog.instance.emit(
      '[FORENSIC_CHAT_SEND] source=chat_input_bar state=${hashCode.toRadixString(16)} chars=${text.length} attachments=${_attachments.length}',
    );
    
    final outgoingAttachments = List<ChatAttachment>.from(_attachments);
    _controller.clear();
    setState(_attachments.clear);
    
    // 🔍 STRUMENTAZIONE FORENSE - TEST 1
    RuntimeEventLog.instance.emit('[FORENSIC_BEFORE_ONSEND]');
    
    widget.onSend(text, outgoingAttachments);
    
    RuntimeEventLog.instance.emit('[FORENSIC_AFTER_ONSEND]');
  }

  Future<void> _pickAttachment(_AttachmentPickerAction action) async {
    Navigator.of(context).pop();
    switch (action) {
      case _AttachmentPickerAction.image:
        final file = await _imageService.pickFromGallery();
        if (file != null) _addAttachment(_buildImageAttachment(file));
        break;
      case _AttachmentPickerAction.camera:
        final file = await _imageService.pickFromCamera();
        if (file != null) _addAttachment(_buildImageAttachment(file));
        break;
      case _AttachmentPickerAction.file:
        final file = await _fileAttachmentService.pickDocument();
        if (file != null) {
          _addAttachment(
            ChatAttachment(
              id: _uuid.v4(),
              type: ChatAttachmentType.file,
              path: file.path,
              name: file.name,
              mimeType: file.mimeType,
              sizeBytes: file.sizeBytes,
              uploadState: ChatAttachmentUploadState.ready,
            ),
          );
        }
        break;
      case _AttachmentPickerAction.video:
        final file = await _fileAttachmentService.pickVideo();
        if (file != null) {
          _addAttachment(
            ChatAttachment(
              id: _uuid.v4(),
              type: ChatAttachmentType.video,
              path: file.path,
              name: file.name,
              mimeType: file.mimeType,
              sizeBytes: file.sizeBytes,
              uploadState: ChatAttachmentUploadState.ready,
            ),
          );
        }
        break;
    }
  }

  ChatAttachment _buildImageAttachment(File file) {
    final stat = file.statSync();
    final name = p.basename(file.path);
    return ChatAttachment(
      id: _uuid.v4(),
      type: ChatAttachmentType.image,
      path: file.path,
      name: name,
      sizeBytes: stat.size,
      thumbnailPath: file.path,
      uploadState: ChatAttachmentUploadState.ready,
    );
  }

  void _addAttachment(ChatAttachment attachment) {
    setState(() => _attachments.add(attachment));
  }

  void _removeAttachment(String attachmentId) {
    setState(() {
      _attachments.removeWhere((attachment) => attachment.id == attachmentId);
    });
  }

  Future<void> _openAttachmentSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return _AttachmentPickerSheet(
          onSelected: _pickAttachment,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 18),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFF171F32).withValues(alpha: 0.98),
                const Color(0xFF0F131D).withValues(alpha: 0.98),
              ],
            ),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: const Color(0xFF8AB4F8).withValues(alpha: 0.24)),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x1F60A5FA),
                blurRadius: 26,
                spreadRadius: 2,
                offset: Offset(0, 14),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_attachments.isNotEmpty) ...[
                SizedBox(
                  height: 96,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _attachments.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (context, index) {
                      final attachment = _attachments[index];
                      return _AttachmentPreviewCard(
                        attachment: attachment,
                        onRemove: () => _removeAttachment(attachment.id),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Pulsante allegati multimodale (Sinistra)
                  _MultimodalMenuButton(onTap: _openAttachmentSheet),
                  const SizedBox(width: 8),
                  
                  // Blocco Centrale: Campo di testo espanso ed ergonomico
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: TextField(
                        controller: _controller,
                        style: const TextStyle(color: Colors.white, fontSize: 15),
                        maxLines: 5,
                        minLines: 1,
                        textInputAction: TextInputAction.newline,
                        decoration: InputDecoration(
                          hintText: l10n.t('message_hint'),
                          hintStyle: const TextStyle(color: Colors.white38),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                        ),
                        onSubmitted: (_) => _submit(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  
                  // Blocco Destro: Gruppo compatto dei pulsanti di azione della chat
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // 🔀 SWITCH DINAMICO: Sovrapposizione perfetta basata sul testo
                      if (!_hasText)
                        Tooltip(
                          message: 'Sessione Live',
                          child: IconButton(
                            style: IconButton.styleFrom(
                              backgroundColor: widget.liveSessionEnabled
                                  ? const Color(0xFF1F2A44)
                                  : Colors.white.withValues(alpha: 0.08),
                              foregroundColor:
                                  widget.liveSessionEnabled ? Colors.white : Colors.white30,
                              minimumSize: const Size(42, 42),
                              maximumSize: const Size(42, 42),
                            ),
                            onPressed: widget.liveSessionEnabled
                                ? widget.onStartLiveSession
                                : null,
                            icon: const Icon(Icons.graphic_eq_rounded, size: 20),
                          ),
                        )
                      else
                        VoiceInputButton(
                          voiceInputService: _voiceInputService,
                          size: 42,
                          onResult: (text, _) {
                            final value = TextEditingValue(
                              text: text,
                              selection: TextSelection.collapsed(offset: text.length),
                            );
                            _controller.value = value;
                          },
                        ),
                      const SizedBox(width: 6),
                      widget.isLoading
                          ? const SizedBox(
                              width: 42,
                              height: 42,
                              child: Padding(
                                padding: EdgeInsets.all(9),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xFF8AB4F8),
                                ),
                              ),
                            )
                          : Tooltip(
                              message: _canSubmit
                                  ? l10n.t('send_message')
                                  : l10n.t('enter_message_to_send'),
                              child: IconButton(
                                style: IconButton.styleFrom(
                                  backgroundColor: _canSubmit
                                      ? const Color(0xFF8AB4F8)
                                      : Colors.white.withValues(alpha: 0.08),
                                  foregroundColor:
                                      _canSubmit ? Colors.black : Colors.white30,
                                  shadowColor:
                                      const Color(0xFF8AB4F8).withValues(alpha: 0.34),
                                  elevation: _canSubmit ? 12 : 0,
                                  minimumSize: const Size(42, 42),
                                  maximumSize: const Size(42, 42),
                                ),
                                onPressed: _canSubmit ? _submit : null,
                                icon: const Icon(Icons.arrow_upward, size: 20),
                              ),
                            ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MultimodalMenuButton extends StatelessWidget {
  const _MultimodalMenuButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Ink(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              const Color(0xFF1D2740).withValues(alpha: 0.98),
              const Color(0xFF151B28).withValues(alpha: 0.98),
            ],
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF8AB4F8).withValues(alpha: 0.22)),
        ),
        child: const Icon(Icons.add, color: Colors.white70),
      ),
    );
  }
}

class _AttachmentPreviewCard extends StatelessWidget {
  const _AttachmentPreviewCard({
    required this.attachment,
    required this.onRemove,
  });

  final ChatAttachment attachment;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 164,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF111827).withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          _AttachmentThumb(attachment: attachment, size: 52),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  attachment.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _uploadLabel(attachment.uploadState),
                  style: TextStyle(
                    color: const Color(0xFF8AB4F8).withValues(alpha: 0.88),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onRemove,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, color: Colors.white54, size: 18),
          ),
        ],
      ),
    );
  }

  String _uploadLabel(ChatAttachmentUploadState state) {
    switch (state) {
      case ChatAttachmentUploadState.preparing:
        return 'Preparing';
      case ChatAttachmentUploadState.ready:
        return 'Ready to send';
      case ChatAttachmentUploadState.failed:
        return 'Failed';
    }
  }
}

class _AttachmentThumb extends StatelessWidget {
  const _AttachmentThumb({
    required this.attachment,
    this.size = 44,
  });

  final ChatAttachment attachment;
  final double size;

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(14);
    if (attachment.isImage && attachment.thumbnailPath != null) {
      return ClipRRect(
        borderRadius: borderRadius,
        child: Image.file(
          File(attachment.thumbnailPath!),
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _FallbackAttachmentIcon(
            attachment: attachment,
            size: size,
          ),
        ),
      );
    }
    return _FallbackAttachmentIcon(attachment: attachment, size: size);
  }
}

class _FallbackAttachmentIcon extends StatelessWidget {
  const _FallbackAttachmentIcon({
    required this.attachment,
    required this.size,
  });

  final ChatAttachment attachment;
  final double size;

  @override
  Widget build(BuildContext context) {
    IconData icon;
    if (attachment.type == ChatAttachmentType.video) {
      icon = Icons.videocam_rounded;
    } else if (attachment.type == ChatAttachmentType.image) {
      icon = Icons.image_rounded;
    } else {
      icon = Icons.description_rounded;
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: const Color(0xFF1E293B),
      ),
      child: Icon(icon, color: const Color(0xFF8AB4F8)),
    );
  }
}

enum _AttachmentPickerAction { image, camera, file, video }

class _AttachmentPickerSheet extends StatelessWidget {
  const _AttachmentPickerSheet({required this.onSelected});

  final ValueChanged<_AttachmentPickerAction> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 18),
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
      decoration: BoxDecoration(
        color: const Color(0xFF10141D).withValues(alpha: 0.98),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x2915B6FF),
            blurRadius: 28,
            offset: Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            'Attach',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _AttachmentActionTile(
                icon: Icons.image_outlined,
                label: 'Image',
                onTap: () => onSelected(_AttachmentPickerAction.image),
              ),
              _AttachmentActionTile(
                icon: Icons.photo_camera_outlined,
                label: 'Camera',
                onTap: () => onSelected(_AttachmentPickerAction.camera),
              ),
              _AttachmentActionTile(
                icon: Icons.insert_drive_file_outlined,
                label: 'File',
                onTap: () => onSelected(_AttachmentPickerAction.file),
              ),
              _AttachmentActionTile(
                icon: Icons.video_library_outlined,
                label: 'Video',
                onTap: () => onSelected(_AttachmentPickerAction.video),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AttachmentActionTile extends StatelessWidget {
  const _AttachmentActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Ink(
        width: 150,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              const Color(0xFF172134).withValues(alpha: 0.96),
              const Color(0xFF111827).withValues(alpha: 0.96),
            ],
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: const Color(0xFF8AB4F8), size: 22),
            const SizedBox(height: 12),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
