import 'package:http/http.dart' as http;

import 'workshop_airlab_capability.dart';
import 'workshop_airlab_client.dart';
import 'workshop_airlab_staging_materializer_io.dart';
import 'workshop_airlab_staging_reader_io.dart';

/// Native Android/Windows/macOS/Linux composition for the opt-in AIrLab
/// capability.
///
/// This file is deliberately separate from [WorkshopAirLabCapability] because
/// its staging adapters depend on dart:io. A future Web factory can provide
/// browser storage adapters without changing the capability contract.
WorkshopAirLabCapability createWorkshopAirLabIoCapability({
  required Uri baseUri,
  required http.Client httpClient,
  bool enabled = false,
  String? authToken,
  Duration timeout = const Duration(seconds: 4),
  bool networkRequired = false,
  String displayName = 'AIrLab',
  int estimatedLatencyMs = 0,
  WorkshopAirLabStagingLimits stagingLimits =
      const WorkshopAirLabStagingLimits(),
  int maxPromotionFileBytes = 256 * 1024,
}) {
  return WorkshopAirLabCapability(
    enabled: enabled,
    client: WorkshopAirLabClient(
      baseUri: baseUri,
      httpClient: httpClient,
      timeout: timeout,
      authToken: authToken,
    ),
    stagingMaterializer: WorkshopAirLabIoStagingMaterializer(
      limits: stagingLimits,
    ),
    stagingReader: WorkshopAirLabIoStagingReader(
      maxFileBytes: maxPromotionFileBytes,
    ),
    networkRequired: networkRequired,
    displayName: displayName,
    estimatedLatencyMs: estimatedLatencyMs,
  );
}
