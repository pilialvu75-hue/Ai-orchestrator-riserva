import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_dashboard_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_progress_presentation.dart';

enum WorkshopProjectSurfaceStatus {
  idle,
  active,
  build,
  completed,
  failed,
  cancelled,
  blocked,
}

/// Stable presentation snapshot shared by Android progress notifications and
/// AppShell route-retention policy.
///
/// Task completion is not the same thing as final project completion: a project
/// whose tasks reached 100% but whose final build has not returned remains in
/// [build].
final class WorkshopProjectSurfaceSnapshot {
  const WorkshopProjectSurfaceSnapshot({
    required this.status,
    this.projectId,
    this.title,
    this.progressPercent = 0,
    this.completedTasks = 0,
    this.totalTasks = 0,
    this.stage = '',
  });

  factory WorkshopProjectSurfaceSnapshot.fromDashboardState(
    WorkshopDashboardControllerState state,
  ) {
    final projectId = state.projectId?.trim();
    if (projectId == null || projectId.isEmpty) {
      return const WorkshopProjectSurfaceSnapshot(
        status: WorkshopProjectSurfaceStatus.idle,
      );
    }

    final title = state.projectTitle?.trim();
    final presentationProgress =
        WorkshopProgressPresentation.displayValue(
      authoritativeProgress: state.progress,
      completedTasks: state.completedTasks,
      totalTasks: state.totalTasks,
      stage: state.progressPresentationStage ?? state.stage,
      actualStage: state.stage,
    );
    final progressPercent =
        (presentationProgress.clamp(0.0, 1.0) * 100).round();
    final buildResult = state.lastBuildResult;
    final hasError = state.lastError?.trim().isNotEmpty == true;

    WorkshopProjectSurfaceStatus status;
    if (hasError) {
      status = WorkshopProjectSurfaceStatus.failed;
    } else if (buildResult != null) {
      status = switch (buildResult.status) {
        WorkshopBuildStatus.succeeded =>
          WorkshopProjectSurfaceStatus.completed,
        WorkshopBuildStatus.cancelled =>
          WorkshopProjectSurfaceStatus.cancelled,
        WorkshopBuildStatus.failed =>
          WorkshopProjectSurfaceStatus.failed,
        _ => WorkshopProjectSurfaceStatus.build,
      };
    } else {
      status = switch (state.projectStatus) {
        WorkshopProjectStatus.cancelled =>
          WorkshopProjectSurfaceStatus.cancelled,
        WorkshopProjectStatus.blocked =>
          WorkshopProjectSurfaceStatus.blocked,
        WorkshopProjectStatus.completed =>
          WorkshopProjectSurfaceStatus.build,
        _ => WorkshopProjectSurfaceStatus.active,
      };
    }

    return WorkshopProjectSurfaceSnapshot(
      status: status,
      projectId: projectId,
      title: title == null || title.isEmpty ? 'Progetto Cantiere' : title,
      progressPercent: progressPercent,
      completedTasks: state.completedTasks,
      totalTasks: state.totalTasks,
      stage:
          (state.progressPresentationStage ?? state.stage)?.name ?? '',
    );
  }

  final WorkshopProjectSurfaceStatus status;
  final String? projectId;
  final String? title;
  final int progressPercent;
  final int completedTasks;
  final int totalTasks;
  final String stage;

  bool get isIdle => status == WorkshopProjectSurfaceStatus.idle;

  bool get isTerminal =>
      status == WorkshopProjectSurfaceStatus.completed ||
      status == WorkshopProjectSurfaceStatus.failed ||
      status == WorkshopProjectSurfaceStatus.cancelled ||
      status == WorkshopProjectSurfaceStatus.blocked;

  bool get shouldRetainSession =>
      status == WorkshopProjectSurfaceStatus.active ||
      status == WorkshopProjectSurfaceStatus.build;

  String get terminalOutcome => switch (status) {
        WorkshopProjectSurfaceStatus.completed => 'completed',
        WorkshopProjectSurfaceStatus.cancelled => 'cancelled',
        WorkshopProjectSurfaceStatus.blocked => 'blocked',
        _ => 'failed',
      };

  Map<String, Object> toChannelPayload() => <String, Object>{
        'projectId': projectId ?? '',
        'title': title ?? 'Progetto Cantiere',
        'progress': progressPercent,
        'completedTasks': completedTasks,
        'totalTasks': totalTasks,
        'stage': stage,
        'surfaceStatus': status.name,
      };
}

typedef WorkshopNotificationPermissionRequester = Future<void> Function();

/// Android adapter for one project-level Cantiere notification.
///
/// Native stage leases still protect individual inference calls. This adapter
/// additionally owns a project lease so the foreground notification remains
/// stable between roles and while the app is backgrounded.
final class WorkshopProjectNotificationService {
  WorkshopProjectNotificationService({
    MethodChannel? channel,
    TargetPlatform? platformOverride,
    WorkshopNotificationPermissionRequester? permissionRequester,
  })  : _channel = channel ?? const MethodChannel(_channelName),
        _platformOverride = platformOverride,
        _permissionRequester =
            permissionRequester ?? _requestNotificationPermission;

  static const String _channelName =
      'ai_orchestrator/cloud_background_execution';

  final MethodChannel _channel;
  final TargetPlatform? _platformOverride;
  final WorkshopNotificationPermissionRequester _permissionRequester;

  String? _activeProjectId;
  String? _lastPayloadSignature;
  bool _permissionRequested = false;

  bool get _isAndroid =>
      !kIsWeb &&
      (_platformOverride ?? defaultTargetPlatform) == TargetPlatform.android;

  Future<void> sync(WorkshopDashboardControllerState state) async {
    if (!_isAndroid) return;

    final snapshot =
        WorkshopProjectSurfaceSnapshot.fromDashboardState(state);

    if (snapshot.isIdle) {
      await clear();
      return;
    }

    final projectId = snapshot.projectId!;
    if (!_permissionRequested) {
      _permissionRequested = true;
      try {
        await _permissionRequester();
      } catch (error) {
        debugPrint(
          '[WORKSHOP_NOTIFICATION] permission_request_skipped error=' +
              error.toString(),
        );
      }
    }

    if (_activeProjectId != null && _activeProjectId != projectId) {
      await _invokeBestEffort(
        'clearWorkshopProject',
        <String, Object>{'projectId': _activeProjectId!},
      );
      _activeProjectId = null;
      _lastPayloadSignature = null;
    }

    final payload = snapshot.toChannelPayload();
    final signature = payload.entries
        .map((entry) => entry.key + '=' + entry.value.toString())
        .join('|');

    if (_activeProjectId == null) {
      await _invokeBestEffort('beginWorkshopProject', payload);
      _activeProjectId = projectId;
      _lastPayloadSignature = signature;
    } else if (_lastPayloadSignature != signature && !snapshot.isTerminal) {
      await _invokeBestEffort('updateWorkshopProject', payload);
      _lastPayloadSignature = signature;
    }

    if (snapshot.isTerminal) {
      await _invokeBestEffort(
        'finishWorkshopProject',
        <String, Object>{
          ...payload,
          'outcome': snapshot.terminalOutcome,
        },
      );
      _activeProjectId = null;
      _lastPayloadSignature = null;
    }
  }

  Future<void> clear() async {
    if (!_isAndroid) return;
    final projectId = _activeProjectId;
    if (projectId == null) return;
    await _invokeBestEffort(
      'clearWorkshopProject',
      <String, Object>{'projectId': projectId},
    );
    _activeProjectId = null;
    _lastPayloadSignature = null;
  }

  Future<void> _invokeBestEffort(
    String method,
    Map<String, Object> arguments,
  ) async {
    try {
      await _channel.invokeMethod<Object?>(method, arguments);
    } catch (error) {
      // Notification plumbing must never fail a valid Cantiere project.
      debugPrint(
        '[WORKSHOP_NOTIFICATION] method=' +
            method +
            ' skipped error=' +
            error.toString(),
      );
    }
  }

  static Future<void> _requestNotificationPermission() async {
    final status = await Permission.notification.status;
    if (status.isDenied) {
      await Permission.notification.request();
    }
  }
}
