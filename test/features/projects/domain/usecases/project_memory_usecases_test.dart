import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:dartz/dartz.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/usecases/usecase.dart';
import 'package:ai_orchestrator/features/projects/domain/entities/project_memory.dart';
import 'package:ai_orchestrator/features/projects/domain/repositories/project_memory_repository.dart';
import 'package:ai_orchestrator/features/projects/domain/usecases/get_project_memories.dart';
import 'package:ai_orchestrator/features/projects/domain/usecases/get_latest_project_memory.dart';
import 'package:ai_orchestrator/features/projects/domain/usecases/save_project_memory.dart';
import 'package:ai_orchestrator/features/projects/domain/usecases/update_project_memory.dart';
import 'package:ai_orchestrator/features/projects/domain/usecases/delete_project_memory.dart';

class MockProjectMemoryRepository extends Mock
    implements ProjectMemoryRepository {}

void main() {
  late MockProjectMemoryRepository mockRepo;

  const tMemory = ProjectMemory(
    id: 'test-id-1',
    masterGoal: 'Build an offline AI app',
    currentContext: 'Working on database layer',
    lastCodeSnippet: 'class DatabaseHelper {}',
    timestamp: 1700000000000,
  );

  setUp(() {
    mockRepo = MockProjectMemoryRepository();
  });

  // ── GetProjectMemories ──────────────────────────────────────────────────────
  group('GetProjectMemories', () {
    GetProjectMemories useCase() => GetProjectMemories(mockRepo);

    test('returns a list of memories on success', () async {
      when(() => mockRepo.getAllProjectMemories()).thenAnswer(
        (_) async => const Right<Failure, List<ProjectMemory>>([tMemory]),
      );

      final result = await useCase()(const NoParams());

      expect(result.isRight(), true);
      expect(result.getOrElse(() => []), const [tMemory]);
      verify(() => mockRepo.getAllProjectMemories()).called(1);
    });

    test('returns DatabaseFailure on error', () async {
      when(() => mockRepo.getAllProjectMemories())
          .thenAnswer((_) async => const Left(DatabaseFailure('DB error')));

      final result = await useCase()(const NoParams());

      expect(result, const Left(DatabaseFailure('DB error')));
    });
  });

  // ── GetLatestProjectMemory ──────────────────────────────────────────────────
  group('GetLatestProjectMemory', () {
    GetLatestProjectMemory useCase() => GetLatestProjectMemory(mockRepo);

    test('returns the latest memory on success', () async {
      when(() => mockRepo.getLatestProjectMemory())
          .thenAnswer((_) async => const Right(tMemory));

      final result = await useCase()(const NoParams());

      expect(result, const Right(tMemory));
      verify(() => mockRepo.getLatestProjectMemory()).called(1);
    });

    test('returns NotFoundFailure when no memory exists', () async {
      when(() => mockRepo.getLatestProjectMemory())
          .thenAnswer((_) async => const Left(NotFoundFailure()));

      final result = await useCase()(const NoParams());

      expect(result, const Left(NotFoundFailure()));
    });
  });

  // ── SaveProjectMemory ───────────────────────────────────────────────────────
  group('SaveProjectMemory', () {
    SaveProjectMemory useCase() => SaveProjectMemory(mockRepo);

    test('saves and returns the memory on success', () async {
      when(() => mockRepo.saveProjectMemory(tMemory))
          .thenAnswer((_) async => const Right(tMemory));

      final result = await useCase()(
        const SaveProjectMemoryParams(projectMemory: tMemory),
      );

      expect(result, const Right(tMemory));
      verify(() => mockRepo.saveProjectMemory(tMemory)).called(1);
    });
  });

  // ── UpdateProjectMemory ─────────────────────────────────────────────────────
  group('UpdateProjectMemory', () {
    UpdateProjectMemory useCase() => UpdateProjectMemory(mockRepo);

    final updatedMemory = tMemory.copyWith(masterGoal: 'Updated goal');

    test('updates and returns the memory on success', () async {
      when(() => mockRepo.updateProjectMemory(updatedMemory))
          .thenAnswer((_) async => Right(updatedMemory));

      final result = await useCase()(
        UpdateProjectMemoryParams(projectMemory: updatedMemory),
      );

      expect(result, Right(updatedMemory));
    });
  });

  // ── DeleteProjectMemory ─────────────────────────────────────────────────────
  group('DeleteProjectMemory', () {
    DeleteProjectMemory useCase() => DeleteProjectMemory(mockRepo);

    test('returns true on successful deletion', () async {
      when(() => mockRepo.deleteProjectMemory('test-id-1'))
          .thenAnswer((_) async => const Right(true));

      final result = await useCase()(
        const DeleteProjectMemoryParams(id: 'test-id-1'),
      );

      expect(result, const Right(true));
      verify(() => mockRepo.deleteProjectMemory('test-id-1')).called(1);
    });
  });
}
