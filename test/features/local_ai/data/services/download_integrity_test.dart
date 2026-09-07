import 'package:ai_orchestrator/features/local_ai/data/services/download_integrity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('70 percent cannot complete a transfer', () {
    expect(
      hasCompleteDownload(
        savedBytes: 700,
        receivedBytes: 700,
        remoteTotal: 1000,
        responseLength: 1000,
      ),
      isFalse,
    );
    expect(isClearlyTruncatedModel(700, 1000), isTrue);
  });

  test('resume must complete both the response and the whole object', () {
    expect(
      hasCompleteDownload(
        savedBytes: 1000,
        receivedBytes: 300,
        remoteTotal: 1000,
        responseLength: 300,
      ),
      isTrue,
    );
    expect(
      hasCompleteDownload(
        savedBytes: 900,
        receivedBytes: 200,
        remoteTotal: 1000,
        responseLength: 300,
      ),
      isFalse,
    );
    expect(
      hasCompleteDownload(
        savedBytes: 1000,
        receivedBytes: 200,
        remoteTotal: 1000,
        responseLength: 300,
      ),
      isFalse,
    );
  });

  test('unknown totals and oversized transfers are not proven complete', () {
    expect(
      hasCompleteDownload(
        savedBytes: 700,
        receivedBytes: 700,
        remoteTotal: null,
        responseLength: null,
      ),
      isFalse,
    );
    expect(
      hasCompleteDownload(
        savedBytes: 1100,
        receivedBytes: 1100,
        remoteTotal: 1000,
        responseLength: 1000,
      ),
      isFalse,
    );
  });

  test('catalogue estimate is not an exact integrity check', () {
    expect(isClearlyTruncatedModel(990, 1000), isFalse);
  });

  test('HTTP 206 appends only from the exact persisted part offset', () {
    expect(
      resolveDownloadResumeAction(
        statusCode: 206,
        existingBytes: 700,
        rangeStart: 700,
        rangeTotal: 1000,
        rangeNotSatisfiableTotal: null,
        partialIsValidGguf: false,
      ),
      DownloadResumeAction.append,
    );
    expect(
      resolveDownloadResumeAction(
        statusCode: 206,
        existingBytes: 700,
        rangeStart: 0,
        rangeTotal: 1000,
        rangeNotSatisfiableTotal: null,
        partialIsValidGguf: false,
      ),
      DownloadResumeAction.reject,
    );
  });

  test('HTTP 200 after a partial download restarts instead of appending', () {
    expect(
      resolveDownloadResumeAction(
        statusCode: 200,
        existingBytes: 700,
        rangeStart: null,
        rangeTotal: null,
        rangeNotSatisfiableTotal: null,
        partialIsValidGguf: false,
      ),
      DownloadResumeAction.restartFromZero,
    );
  });

  test('HTTP 416 promotes only an exact valid GGUF partial', () {
    expect(
      resolveDownloadResumeAction(
        statusCode: 416,
        existingBytes: 1000,
        rangeStart: null,
        rangeTotal: null,
        rangeNotSatisfiableTotal: 1000,
        partialIsValidGguf: true,
      ),
      DownloadResumeAction.promotePartial,
    );
    expect(
      resolveDownloadResumeAction(
        statusCode: 416,
        existingBytes: 900,
        rangeStart: null,
        rangeTotal: null,
        rangeNotSatisfiableTotal: 1000,
        partialIsValidGguf: true,
      ),
      DownloadResumeAction.restartFromZero,
    );
  });
}
