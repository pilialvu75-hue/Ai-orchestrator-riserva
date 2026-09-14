import 'package:ai_orchestrator/app_factory/workshop/workshop_library_remote_client.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_module_assembly_plan.dart';

abstract interface class WorkshopLibraryReadClient {
  Future<WorkshopLibraryRemoteState> loadState();

  Future<WorkshopReusableModulePackage> loadPackage({
    required WorkshopLibraryRemoteState state,
    required String pin,
  });
}

final class WorkshopLibraryReadAdapter implements WorkshopLibraryReadClient {
  WorkshopLibraryReadAdapter({WorkshopLibraryRemoteClient? client})
      : _client = client ?? WorkshopLibraryRemoteClient();

  final WorkshopLibraryRemoteClient _client;

  @override
  Future<WorkshopLibraryRemoteState> loadState() => _client.loadState();

  @override
  Future<WorkshopReusableModulePackage> loadPackage({
    required WorkshopLibraryRemoteState state,
    required String pin,
  }) =>
      _client.loadPackage(state: state, pin: pin);
}
