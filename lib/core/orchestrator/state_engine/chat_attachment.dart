import 'package:equatable/equatable.dart';

enum ChatAttachmentType { image, file, video }

enum ChatAttachmentUploadState { preparing, ready, failed }

class ChatAttachment extends Equatable {
  const ChatAttachment({
    required this.id,
    required this.type,
    required this.path,
    required this.name,
    this.mimeType,
    this.sizeBytes,
    this.thumbnailPath,
    this.uploadState = ChatAttachmentUploadState.ready,
  });

  final String id;
  final ChatAttachmentType type;
  final String path;
  final String name;
  final String? mimeType;
  final int? sizeBytes;
  final String? thumbnailPath;
  final ChatAttachmentUploadState uploadState;

  bool get isImage => type == ChatAttachmentType.image;
  bool get isVideo => type == ChatAttachmentType.video;

  ChatAttachment copyWith({
    String? id,
    ChatAttachmentType? type,
    String? path,
    String? name,
    String? mimeType,
    int? sizeBytes,
    String? thumbnailPath,
    ChatAttachmentUploadState? uploadState,
  }) {
    return ChatAttachment(
      id: id ?? this.id,
      type: type ?? this.type,
      path: path ?? this.path,
      name: name ?? this.name,
      mimeType: mimeType ?? this.mimeType,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      uploadState: uploadState ?? this.uploadState,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'type': type.name,
      'path': path,
      'name': name,
      'mime_type': mimeType,
      'size_bytes': sizeBytes,
      'thumbnail_path': thumbnailPath,
      'upload_state': uploadState.name,
    };
  }

  factory ChatAttachment.fromJson(Map<String, dynamic> json) {
    final rawType = (json['type'] as String? ?? '').trim();
    final rawUploadState = (json['upload_state'] as String? ?? '').trim();
    return ChatAttachment(
      id: (json['id'] as String?) ?? '',
      type: _typeFromName(rawType),
      path: (json['path'] as String?) ?? '',
      name: (json['name'] as String?) ?? 'Attachment',
      mimeType: json['mime_type'] as String?,
      sizeBytes: json['size_bytes'] as int?,
      thumbnailPath: json['thumbnail_path'] as String?,
      uploadState: _uploadStateFromName(rawUploadState),
    );
  }

  static ChatAttachmentType _typeFromName(String rawType) {
    for (final value in ChatAttachmentType.values) {
      if (value.name == rawType) return value;
    }
    return ChatAttachmentType.file;
  }

  static ChatAttachmentUploadState _uploadStateFromName(String rawUploadState) {
    for (final value in ChatAttachmentUploadState.values) {
      if (value.name == rawUploadState) return value;
    }
    return ChatAttachmentUploadState.ready;
  }

  @override
  List<Object?> get props => <Object?>[
        id,
        type,
        path,
        name,
        mimeType,
        sizeBytes,
        thumbnailPath,
        uploadState,
      ];
}
