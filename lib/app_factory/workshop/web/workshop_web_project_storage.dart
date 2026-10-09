import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum WorkshopWebProjectStatus {
  draft,
  proposalReady,
  approved,
  inProgress,
  blocked,
  completed,
}

final class WorkshopWebProject {
  const WorkshopWebProject({
    required this.id,
    required this.title,
    required this.goal,
    required this.platforms,
    required this.status,
    required this.progress,
    required this.currentPhase,
    required this.currentItem,
    required this.createdAt,
    required this.updatedAt,
    this.proposal,
    this.error,
  });

  final String id;
  final String title;
  final String goal;
  final List<String> platforms;
  final WorkshopWebProjectStatus status;
  final double progress;
  final String currentPhase;
  final String currentItem;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? proposal;
  final String? error;

  WorkshopWebProject copyWith({
    String? title,
    String? goal,
    List<String>? platforms,
    WorkshopWebProjectStatus? status,
    double? progress,
    String? currentPhase,
    String? currentItem,
    String? proposal,
    String? error,
    bool clearError = false,
  }) {
    return WorkshopWebProject(
      id: id,
      title: title ?? this.title,
      goal: goal ?? this.goal,
      platforms: List<String>.unmodifiable(platforms ?? this.platforms),
      status: status ?? this.status,
      progress: (progress ?? this.progress).clamp(0.0, 1.0),
      currentPhase: currentPhase ?? this.currentPhase,
      currentItem: currentItem ?? this.currentItem,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      proposal: proposal ?? this.proposal,
      error: clearError ? null : error ?? this.error,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'title': title,
        'goal': goal,
        'platforms': platforms,
        'status': status.name,
        'progress': progress,
        'currentPhase': currentPhase,
        'currentItem': currentItem,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'proposal': proposal,
        'error': error,
      };

  static WorkshopWebProject? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final id = raw['id'];
    final title = raw['title'];
    final goal = raw['goal'];
    final platforms = raw['platforms'];
    final statusName = raw['status'];
    final progress = raw['progress'];
    final currentPhase = raw['currentPhase'];
    final currentItem = raw['currentItem'];
    final createdAt = DateTime.tryParse(raw['createdAt']?.toString() ?? '');
    final updatedAt = DateTime.tryParse(raw['updatedAt']?.toString() ?? '');
    if (id is! String ||
        title is! String ||
        goal is! String ||
        platforms is! List ||
        statusName is! String ||
        progress is! num ||
        currentPhase is! String ||
        currentItem is! String ||
        createdAt == null ||
        updatedAt == null) {
      return null;
    }

    WorkshopWebProjectStatus? status;
    for (final candidate in WorkshopWebProjectStatus.values) {
      if (candidate.name == statusName) {
        status = candidate;
        break;
      }
    }
    if (status == null) return null;

    return WorkshopWebProject(
      id: id,
      title: title,
      goal: goal,
      platforms: List<String>.unmodifiable(
        platforms.whereType<String>().map((value) => value.trim()).where(
              (value) => value.isNotEmpty,
            ),
      ),
      status: status,
      progress: progress.toDouble().clamp(0.0, 1.0),
      currentPhase: currentPhase,
      currentItem: currentItem,
      createdAt: createdAt,
      updatedAt: updatedAt,
      proposal: raw['proposal'] is String ? raw['proposal'] as String : null,
      error: raw['error'] is String ? raw['error'] as String : null,
    );
  }
}

final class WorkshopWebProjectStorage {
  WorkshopWebProjectStorage._(this._preferences);

  static const String _storageKey = 'workshop.web.projects.v1';
  static const int _maxProjects = 100;

  final SharedPreferences _preferences;

  static Future<WorkshopWebProjectStorage> open() async {
    final preferences = await SharedPreferences.getInstance();
    return WorkshopWebProjectStorage._(preferences);
  }

  Future<List<WorkshopWebProject>> loadAll() async {
    final raw = _preferences.getString(_storageKey);
    if (raw == null || raw.trim().isEmpty) {
      return const <WorkshopWebProject>[];
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return const <WorkshopWebProject>[];
      }
      final rows = decoded['projects'];
      if (rows is! List<dynamic>) {
        return const <WorkshopWebProject>[];
      }

      final projects = rows
          .map(WorkshopWebProject.fromJson)
          .whereType<WorkshopWebProject>()
          .toList(growable: false)
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return List<WorkshopWebProject>.unmodifiable(projects);
    } catch (_) {
      return const <WorkshopWebProject>[];
    }
  }

  Future<void> save(Iterable<WorkshopWebProject> projects) async {
    final rows = projects.toList(growable: false)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final bounded =
        rows.length <= _maxProjects ? rows : rows.sublist(0, _maxProjects);
    await _preferences.setString(
      _storageKey,
      jsonEncode(<String, Object?>{
        'version': 1,
        'projects': bounded.map((project) => project.toJson()).toList(),
      }),
    );
  }
}
