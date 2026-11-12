import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'package:ai_orchestrator/features/computer_use/computer_use_session.dart';
import 'package:ai_orchestrator/features/computer_use/windows_computer_use_accessibility_script.dart';

/// Windows desktop adapter. All scripts are constant, typed operations:
/// text/path values are encoded as data, never evaluated as PowerShell code.
///
/// No elevation, arbitrary process launch, command execution or network access.
final class WindowsComputerUseAdapter
    implements ComputerUseAdapter, ComputerUseDesktopTargetSelector {
  WindowsComputerUseAdapter();

  int? _targetWindow;
  // The smoke test must never silently type into another foreground app.
  // Process identity is checked before accepting the launched test window.
  int? _expectedLaunchedProcessId;
  Process? _activeProcess;
  bool _running = false;
  late final DynamicLibrary? _user32 =
      Platform.isWindows ? DynamicLibrary.open('user32.dll') : null;
  int _cancelGeneration = 0;

  @override
  void cancel() {
    _cancelGeneration++;
    _activeProcess?.kill();
    _activeProcess = null;
    _targetWindow = null;
    _expectedLaunchedProcessId = null;
  }

  @override
  bool get isSupported => Platform.isWindows;

  /// Pure policy for foreground selection, also exercised on non-Windows CI.
  /// A brokered app PID mismatch fails closed rather than typing elsewhere.
  static bool isExpectedForegroundProcess({
    required int foregroundProcessId,
    required int hostProcessId,
    int? launchedProcessId,
  }) =>
      foregroundProcessId > 0 &&
      foregroundProcessId != hostProcessId &&
      (launchedProcessId == null ||
          foregroundProcessId == launchedProcessId);

  @override
  Future<Uint8List> capturePng() async {
    _requireWindows();
    final directory = await Directory.systemTemp.createTemp('aivexus_cu_');
    final file = File('${directory.path}${Platform.pathSeparator}frame.png');
    try {
      final encodedPath = _encodeUtf16(file.path);
      // Observation must not reactivate the old selected application:
      // an agent needs to see other windows to plan a cross-app transition.
      await _runPowerShell(
        _screenScript.replaceFirst('__PATH__', encodedPath),
        timeout: const Duration(seconds: 20),
      );
      if (!await file.exists()) {
        throw const ComputerUseException(
          'SCREEN_CAPTURE_FAILED',
          'Windows did not create a screenshot.',
        );
      }
      return await file.readAsBytes();
    } finally {
      try {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      } catch (_) {
        // Temporary frame cleanup must not mask the original exception.
      }
    }
  }

  @override
  Future<void> openApplication(String application) async {
    _requireWindows();
    // No user/model-provided binary paths or shell expansion allowed here.
    final executable = switch (application) {
      'notepad' => 'notepad.exe',
      'calculator' => 'calc.exe',
      _ => throw const ComputerUseException(
          'APPLICATION_NOT_ALLOWED',
          'The selected application is not on the host allowlist.',
        ),
    };
    _targetWindow = null;
    _expectedLaunchedProcessId = null;
    final launched = await Process.start(
      executable,
      const <String>[],
      mode: ProcessStartMode.detached,
      runInShell: false,
    );
    _expectedLaunchedProcessId = launched.pid;
  }

  @override
  Future<void> selectForegroundWindow() async {
    _requireWindows();
    // Read foreground directly from Aivexus: a PowerShell child might
    // itself steal Windows foreground focus before reading it.
    final library = _user32!;
    final getForeground = library.lookupFunction<
        IntPtr Function(), int Function()>('GetForegroundWindow');
    final getProcessId = library.lookupFunction<
        Uint32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId');
    final handle = getForeground();
    if (handle == 0) {
      throw const ComputerUseException(
        'TARGET_NOT_FOUND', 'No foreground window is available.',
      );
    }
    final ownerPid = calloc<Uint32>();
    try {
      getProcessId(handle, ownerPid);
      if (ownerPid.value == pid || ownerPid.value == 0) {
        throw const ComputerUseException(
          'TARGET_NOT_FOUND',
          'Select another application, not the Aivexus window.',
        );
      }
      // If Aivexus just launched an allowlisted test app, reject any
      // unrelated window even when it happens to own keyboard focus.
      // On modern Windows, packaged apps may broker another PID: that
      // must be reported as an explicit non-PASS until validated on device.
      if (!isExpectedForegroundProcess(
        foregroundProcessId: ownerPid.value,
        hostProcessId: pid,
        launchedProcessId: _expectedLaunchedProcessId,
      )) {
        throw const ComputerUseException(
          'LAUNCHED_APP_NOT_FOREGROUND',
          'The launched test app is not the foreground window. '
          'No text or keyboard input was sent.',
        );
      }
    } finally {
      calloc.free(ownerPid);
    }
    _targetWindow = handle;
    _expectedLaunchedProcessId = null;
  }

  @override
  Future<void> selectWindowAt(int x, int y) async {
    _requireWindows();
    // Look up the visible top-level window under a screen coordinate.
    // No cursor movement, activation, mouse input or text is performed.
    final output = await _runPowerShell(
      '$_inputInterop\n'
      '[AivexusDesktopInput]::SelectWindowAt($x, $y, $pid)',
    );
    final handle = int.tryParse(output.trim());
    if (handle == null || handle == 0) {
      throw const ComputerUseException(
        'TARGET_NOT_FOUND',
        'No eligible desktop window was found at that position.',
      );
    }
    _targetWindow = handle;
    // This is an explicit transition to a new target, separate from the
    // single-application smoke test's foreground PID requirement.
    _expectedLaunchedProcessId = null;
  }

  /// LOCAL-only, bounded, read-only snapshot of the selected window's
  /// accessible controls. All text/edit/document values are omitted.
  Future<String> captureSelectedAccessibilityJson() async {
    _requireWindows();
    final handle = _requireTargetWindow();
    final output = await _runPowerShell(
      kWindowsUiAutomationSnapshotScript.replaceFirst('__HANDLE__', '$handle'),
      timeout: const Duration(seconds: 16),
    );
    if (output.trim().isEmpty || output.length > 12000) {
      throw const ComputerUseException(
        'INVALID_ACCESSIBILITY_SUMMARY',
        'Windows returned an invalid accessibility snapshot.',
      );
    }
    return output.trim();
  }

  @override
  Future<bool> verifyTestMarker(String marker) async {
    _requireWindows();
    final handle = _requireTargetWindow();
    if (!RegExp(r'^AIVEXUS-CU-QA-[0-9]{8,20}$').hasMatch(marker)) {
      throw const ComputerUseException(
        'INVALID_TEST_MARKER', 'Invalid synthetic QA marker.',
      );
    }
    final code = _verificationScript
        .replaceFirst('__HANDLE__', '$handle')
        .replaceFirst('__MARKER__', _encodeUtf16(marker));
    final result = await _runPowerShell(code);
    return result.trim() == 'FOUND';
  }

  @override
  Future<void> click(int x, int y) async {
    _requireWindows();
    // Never let a click implicitly choose or switch a controlled window.
    // The owner first selects a foreground window in the authorized lab.
    final handle = _requireTargetWindow();
    _focusTargetWindow();
    await _runPowerShell(
      '$_inputInterop\n'
      '[AivexusDesktopInput]::Focus($handle)\n'
      '[AivexusDesktopInput]::Click($x, $y, $handle)',
    );
  }

  @override
  Future<void> typeText(String text) async {
    _requireWindows();
    final handle = _requireTargetWindow();
    _focusTargetWindow();
    final script = '''
$_inputInterop
[AivexusDesktopInput]::Focus($handle)
\$payload = [System.Text.Encoding]::Unicode.GetString(
    [Convert]::FromBase64String("__TEXT__"))
[AivexusDesktopInput]::TypeText(\$payload)
''';
    await _runPowerShell(
      script.replaceFirst('__TEXT__', _encodeUtf16(text)),
    );
  }

  @override
  Future<void> pressKey(String key) async {
    _requireWindows();
    if (!ComputerUseSession.allowedKeys.contains(key)) {
      throw const ComputerUseException(
        'INVALID_KEY',
        'Navigation key is not allowlisted.',
      );
    }
    final handle = _requireTargetWindow();
    _focusTargetWindow();
    await _runPowerShell(
      '$_inputInterop\n[AivexusDesktopInput]::Focus($handle)\n'
      '[AivexusDesktopInput]::PressKey("$key")',
    );
  }

  /// Called on the Flutter application's foreground user gesture; Windows
  /// may deny SetForegroundWindow from a child PowerShell process.
  void _focusTargetWindow() {
    final target = _targetWindow;
    final library = _user32;
    if (target == null || library == null) return;
    final exists = library.lookupFunction<
        Int32 Function(IntPtr), int Function(int)>('IsWindow');
    final focus = library.lookupFunction<
        Int32 Function(IntPtr), int Function(int)>('SetForegroundWindow');
    final foreground = library.lookupFunction<
        IntPtr Function(), int Function()>('GetForegroundWindow');
    if (exists(target) == 0 ||
        (foreground() != target && focus(target) == 0)) {
      throw const ComputerUseException(
        'TARGET_FOCUS_DENIED',
        'Windows denied focus to the selected window. '
        'Select an unlocked application again.',
      );
    }
  }

  int _requireTargetWindow() {
    final handle = _targetWindow;
    if (handle == null || handle == 0) {
      throw const ComputerUseException(
        'NO_TARGET_WINDOW',
        'Choose a target window by clicking the screenshot first.',
      );
    }
    return handle;
  }

  void _requireWindows() {
    if (!isSupported) {
      throw const ComputerUseException(
        'UNSUPPORTED_HOST',
        'Windows desktop actions are unavailable on this platform.',
      );
    }
  }

  static String _encodeUtf16(String value) {
    final bytes = <int>[];
    for (final unit in value.codeUnits) {
      bytes.add(unit & 0xff);
      bytes.add((unit >> 8) & 0xff);
    }
    return base64.encode(bytes);
  }

  Future<String> _runPowerShell(
    String script, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    // -Command receives only code assembled from constant templates.
    // Never echo the script or stderr: it may contain desktop metadata.
    if (_running) {
      throw const ComputerUseException(
        'WINDOWS_BUSY',
        'Windows is completing another desktop operation.',
      );
    }
    _running = true;
    final generation = _cancelGeneration;
    Process? process;
    try {
      process = await Process.start(
        'powershell.exe',
        <String>['-NoProfile', '-NonInteractive', '-Command', script],
        runInShell: false,
      );
      _activeProcess = process;
      if (generation != _cancelGeneration) {
        process.kill();
        throw const ComputerUseException(
          'SESSION_CANCELLED',
          'Computer Use was stopped before the action started.',
        );
      }
      final stdoutResult = process.stdout.transform(utf8.decoder).join();
      final stderrDrain = process.stderr.drain<void>();
      int exitCode;
      try {
        exitCode = await process.exitCode.timeout(timeout);
      } on TimeoutException {
        process.kill();
        await Future.wait(<Future<dynamic>>[stdoutResult, stderrDrain]);
        throw const ComputerUseException(
          'WINDOWS_ACTION_TIMEOUT',
          'Windows did not finish the desktop operation in time.',
        );
      }
      final output = await stdoutResult;
      await stderrDrain;
      if (generation != _cancelGeneration) {
        throw const ComputerUseException(
          'SESSION_CANCELLED',
          'The user stopped Computer Use.',
        );
      }
      if (exitCode != 0) {
        throw const ComputerUseException(
          'WINDOWS_ACTION_FAILED',
          'Windows rejected the requested desktop operation.',
        );
      }
      return output;
    } finally {
      if (identical(_activeProcess, process)) {
        _activeProcess = null;
      }
      _running = false;
    }
  }

  /// Exposes only the fixed source template for an isolated Windows CI
  /// compilation check. Does not grant desktop permissions or run input.
  static String get inputInteropSourceForTest => _inputInterop;

  /// Parser-only Windows CI probe: never invokes UI Automation from tests.
  static String get accessibilityScriptForTest =>
      kWindowsUiAutomationSnapshotScript;

  // Verify only a synthetic marker; return FOUND/NOT_FOUND, never UI text.
  static const String _verificationScript = r'''
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$marker = [Text.Encoding]::Unicode.GetString(
    [Convert]::FromBase64String('__MARKER__'))
$root = [System.Windows.Automation.AutomationElement]::FromHandle(
    [IntPtr]__HANDLE__)
$found = $false
if ($null -ne $root) {
    $scope = [System.Windows.Automation.TreeScope]::Descendants
    $nodes = $root.FindAll($scope,
        [System.Windows.Automation.Condition]::TrueCondition)
    $limit = [Math]::Min($nodes.Count, 256)
    for ($i = -1; $i -lt $limit; $i++) {
        $node = if ($i -eq -1) { $root } else { $nodes[$i] }
        try {
            $text = $node.GetCurrentPattern(
                [System.Windows.Automation.TextPattern]::Pattern)
            if ($null -ne $text -and
                $text.DocumentRange.GetText(-1).Contains($marker)) {
                $found = $true
                break
            }
        } catch { }
        try {
            $value = $node.GetCurrentPattern(
                [System.Windows.Automation.ValuePattern]::Pattern)
            if ($null -ne $value -and $value.Current.Value.Contains($marker)) {
                $found = $true
                break
            }
        } catch { }
    }
}
if ($found) { Write-Output 'FOUND' }
else { Write-Output 'NOT_FOUND' }
''';

  static const String _screenScript = r'''
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$path = [System.Text.Encoding]::Unicode.GetString(
    [Convert]::FromBase64String('__PATH__'))
$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bitmap = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
try {
    $graphics.CopyFromScreen($bounds.Location,
        [System.Drawing.Point]::Empty, $bounds.Size)
    $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
} finally {
    $graphics.Dispose()
    $bitmap.Dispose()
}
''';

  static const String _inputInterop = r'''
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class AivexusDesktopInput {
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    private static extern void mouse_event(uint flags, uint x, uint y,
        uint data, UIntPtr extraInfo);

    [DllImport("user32.dll")]
    private static extern void keybd_event(byte key, byte scan,
        uint flags, UIntPtr extraInfo);

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyInput {
        public ushort vk;
        public ushort scan;
        public uint flags;
        public uint time;
        public UIntPtr extraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint flags;
        public uint time;
        public UIntPtr extraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion {
        [FieldOffset(0)] public KeyInput keyboard;
        [FieldOffset(0)] public MouseInput mouse;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Input {
        public uint type;
        public InputUnion data;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, Input[] inputs, int size);

    [StructLayout(LayoutKind.Sequential)]
    private struct ScreenPoint {
        public int x;
        public int y;
    }

    [DllImport("user32.dll")]
    private static extern IntPtr WindowFromPoint(ScreenPoint point);

    [DllImport("user32.dll")]
    private static extern IntPtr GetAncestor(IntPtr handle, uint flags);

    [DllImport("user32.dll")]
    private static extern bool IsWindow(IntPtr handle);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr handle);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr handle);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(
        IntPtr handle, out uint processId);

    public static long SelectForeground(int excludedProcessId) {
        var window = GetForegroundWindow();
        if (window == IntPtr.Zero)
            throw new InvalidOperationException("No foreground window");
        uint owningProcessId;
        GetWindowThreadProcessId(window, out owningProcessId);
        if (owningProcessId == (uint)excludedProcessId)
            throw new InvalidOperationException("Aivexus is in the foreground");
        return window.ToInt64();
    }

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr handle);

    public static void Click(int x, int y, long expectedHandle) {
        var expected = new IntPtr(expectedHandle);
        if (expected == IntPtr.Zero || !IsWindow(expected))
            throw new InvalidOperationException("The selected window is invalid");
        var position = new ScreenPoint {x=x, y=y};
        // Reject coordinates over another application before ANY input.
        var root = GetAncestor(WindowFromPoint(position), 2);
        if (root != expected)
            throw new InvalidOperationException("Click lies outside selected window");
        if (!SetCursorPos(x, y))
            throw new InvalidOperationException("Unable to move cursor");
        // A window can move/change while the pointer moves: check again.
        root = GetAncestor(WindowFromPoint(position), 2);
        if (root != expected || GetForegroundWindow() != expected)
            throw new InvalidOperationException("Selected window lost focus");
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
    }

    // Selection is deliberately passive. It does not click or activate an
    // app. A separate subsequent Click must still pass the HWND guard.
    public static long SelectWindowAt(int x, int y, int excludedProcessId) {
        var point = new ScreenPoint {x=x, y=y};
        var root = GetAncestor(WindowFromPoint(point), 2);
        if (root == IntPtr.Zero || !IsWindow(root) ||
            !IsWindowVisible(root) || IsIconic(root))
            throw new InvalidOperationException("No eligible desktop target");
        uint owningProcessId;
        GetWindowThreadProcessId(root, out owningProcessId);
        if (owningProcessId == 0 ||
            owningProcessId == (uint)excludedProcessId)
            throw new InvalidOperationException("Cannot select Aivexus or desktop system surface");
        return root.ToInt64();
    }

    public static void Focus(long handle) {
        var window = new IntPtr(handle);
        if (!IsWindow(window))
            throw new InvalidOperationException("Target window is no longer valid");
        // Flutter already brought the window to the foreground. Avoid a
        // redundant SetForegroundWindow call from the child PowerShell host,
        // which Windows may reject due to foreground activation policy.
        if (GetForegroundWindow() != window && !SetForegroundWindow(window))
            throw new InvalidOperationException("Unable to focus target window");
    }

    public static void TypeText(string text) {
        foreach (char c in text) {
            var down = new Input {
                type = 1,
                data = new InputUnion {
                    keyboard = new KeyInput {scan = c, flags = 0x0004}
                }
            };
            var up = new Input {
                type = 1,
                data = new InputUnion {
                    keyboard = new KeyInput {scan = c, flags = 0x0006}
                }
            };
            var input = new Input[] {down, up};
            if (SendInput(2, input, Marshal.SizeOf(typeof(Input))) != 2)
                throw new InvalidOperationException("Unable to send text");
        }
    }

    private static void Key(byte vk, bool release) {
        keybd_event(vk, 0, release ? 0x0002u : 0u, UIntPtr.Zero);
    }

    public static void PressKey(string key) {
        byte vk;
        switch (key) {
            case "enter": vk = 0x0D; break;
            case "tab": vk = 0x09; break;
            case "escape": vk = 0x1B; break;
            case "backspace": vk = 0x08; break;
            case "up": vk = 0x26; break;
            case "down": vk = 0x28; break;
            case "left": vk = 0x25; break;
            case "right": vk = 0x27; break;
            case "ctrl+a":
                Key(0x11, false);
                try { Key(0x41, false); Key(0x41, true); }
                finally { Key(0x11, true); }
                return;
            default: throw new ArgumentException("Unknown navigation key");
        }
        Key(vk, false);
        Key(vk, true);
    }
}
"@
''';
}
