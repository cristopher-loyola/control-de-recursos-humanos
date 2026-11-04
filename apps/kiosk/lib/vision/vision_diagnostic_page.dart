import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'consent_store.dart';
import 'face_capture_quality.dart';

/// Diagnóstico local de cámara. No identifica personas ni guarda imágenes.
class VisionDiagnosticPage extends StatefulWidget {
  const VisionDiagnosticPage({
    super.key,
    this.employeeNumber,
    this.consentStore,
  });

  final String? employeeNumber;
  final ConsentStore? consentStore;

  @override
  State<VisionDiagnosticPage> createState() => _VisionDiagnosticPageState();
}

class _VisionDiagnosticPageState extends State<VisionDiagnosticPage>
    with WidgetsBindingObserver {
  final _detector = FaceDetector(
    options: FaceDetectorOptions(performanceMode: FaceDetectorMode.fast),
  );
  CameraController? _controller;
  CameraDescription? _camera;
  Future<void> _cameraOperation = Future.value();
  bool _processing = false;
  bool _disposed = false;
  bool _rotateHalfTurn = false;
  int _faces = 0;
  int? _latencyMs;
  int _analyzedFrames = 0;
  int _goodFrames = 0;
  DateTime? _lastAnalysis;
  String? _employeeName;
  String _status = 'Iniciando cámara…';

  static const _orientations = <DeviceOrientation, int>{
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _queueStart();
  }

  void _queueStart() {
    _cameraOperation = _cameraOperation.then((_) => _startCamera());
  }

  void _queueStop() {
    _cameraOperation = _cameraOperation.then((_) => _stopCamera());
  }

  Future<void> _startCamera() async {
    if (_controller != null) return;
    if (_disposed || !Platform.isAndroid) {
      if (mounted) {
        setState(() => _status = 'Esta prueba requiere una tablet Android.');
      }
      return;
    }
    try {
      final employeeNumber = widget.employeeNumber;
      if (employeeNumber != null) {
        final consentStore = widget.consentStore;
        if (consentStore == null) {
          throw const ConsentRuleError(
            'No se pudo verificar el consentimiento.',
          );
        }
        final employee = await consentStore.requireActiveConsent(
          employeeNumber,
        );
        if (_disposed || !mounted) return;
        setState(() => _employeeName = employee.employeeName);
      }
      final cameras = await availableCameras();
      if (_disposed || !mounted) return;
      if (cameras.isEmpty) {
        setState(() => _status = 'No se encontró una cámara.');
        return;
      }
      final camera = cameras.firstWhere(
        (item) => item.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );
      _camera = camera;
      _controller = controller;
      await controller.initialize();
      if (_disposed || !mounted) {
        await _stopCamera();
        return;
      }
      await controller.startImageStream(_onFrame);
      if (mounted) {
        setState(() => _status = 'Buscando rostros…');
      }
    } on ConsentRuleError catch (error) {
      if (mounted) {
        setState(() => _status = error.message);
      }
    } on CameraException catch (error) {
      await _stopCamera();
      if (mounted) {
        setState(
          () => _status = error.code == 'CameraAccessDenied'
              ? 'Permite el acceso a la cámara para iniciar la prueba.'
              : 'No se pudo iniciar la cámara (${error.code}).',
        );
      }
    } catch (_) {
      await _stopCamera();
      if (mounted) {
        setState(() => _status = 'No se pudo iniciar la prueba de cámara.');
      }
    }
  }

  Future<void> _stopCamera() async {
    final controller = _controller;
    _controller = null;
    _camera = null;
    if (controller == null) return;
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } on CameraException {
      // La cámara puede haberse cerrado al suspender Android.
    } finally {
      await controller.dispose();
    }
  }

  void _onFrame(CameraImage frame) {
    final now = DateTime.now();
    if (_processing ||
        _disposed ||
        (_lastAnalysis != null &&
            now.difference(_lastAnalysis!) <
                const Duration(milliseconds: 300))) {
      return;
    }
    final image = _toInputImage(frame);
    if (image == null) {
      if (_analyzedFrames == 0 && mounted) {
        setState(() => _status = 'La cámara no entregó imágenes compatibles.');
      }
      return;
    }
    _processing = true;
    _lastAnalysis = now;
    unawaited(_detect(image));
  }

  InputImage? _toInputImage(CameraImage frame) {
    final camera = _camera;
    final controller = _controller;
    if (camera == null || controller == null || frame.planes.length != 1) {
      return null;
    }
    final format = InputImageFormatValue.fromRawValue(frame.format.raw);
    final orientation = _orientations[controller.value.deviceOrientation];
    if (format == null ||
        format != InputImageFormat.nv21 ||
        orientation == null) {
      return null;
    }
    final rotationDegrees = camera.lensDirection == CameraLensDirection.front
        ? (camera.sensorOrientation + orientation) % 360
        : (camera.sensorOrientation - orientation + 360) % 360;
    final rotation = InputImageRotationValue.fromRawValue(
      (rotationDegrees + (_rotateHalfTurn ? 180 : 0)) % 360,
    );
    if (rotation == null) return null;
    final plane = frame.planes.single;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(frame.width.toDouble(), frame.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  Future<void> _detect(InputImage image) async {
    final timer = Stopwatch()..start();
    try {
      final faces = await _detector.processImage(image);
      timer.stop();
      final rotated =
          image.metadata?.rotation == InputImageRotation.rotation90deg ||
          image.metadata?.rotation == InputImageRotation.rotation270deg;
      final rawSize = image.metadata?.size ?? Size.zero;
      final size = rotated ? Size(rawSize.height, rawSize.width) : rawSize;
      final issue = FaceCaptureQuality.issue(
        faceCount: faces.length,
        faceBounds: faces.length == 1 ? faces.single.boundingBox : null,
        imageSize: size,
        headRoll: faces.length == 1 ? faces.single.headEulerAngleZ : null,
        headYaw: faces.length == 1 ? faces.single.headEulerAngleY : null,
      );
      if (mounted && !_disposed) {
        setState(() {
          _faces = faces.length;
          _latencyMs = timer.elapsedMilliseconds;
          _analyzedFrames++;
          _goodFrames = issue == null
              ? (_goodFrames < 3 ? _goodFrames + 1 : 3)
              : 0;
          _status = widget.employeeNumber == null
              ? faces.isEmpty
                    ? 'No hay rostros en el cuadro.'
                    : faces.length == 1
                    ? 'Se detectó un rostro.'
                    : 'Se detectaron ${faces.length} rostros.'
              : issue ?? 'Encuadre estable ($_goodFrames/3 cuadros).';
        });
      }
    } catch (_) {
      if (mounted && !_disposed) {
        setState(() => _status = 'No se pudo analizar la imagen.');
      }
    } finally {
      _processing = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _queueStop();
    } else if (state == AppLifecycleState.resumed) {
      _queueStart();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _queueStop();
    unawaited(_cameraOperation.then((_) => _detector.close()));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final preparing = widget.employeeNumber != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          preparing ? 'Preparar captura facial' : 'Diagnóstico de cámara',
        ),
        actions: [
          IconButton(
            tooltip: 'Girar imagen 180 grados',
            onPressed: () => setState(() => _rotateHalfTurn = !_rotateHalfTurn),
            icon: const Icon(Icons.rotate_right),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  preparing
                      ? 'Encuadre de ${_employeeName ?? 'empleado'}'
                      : 'Detección local de rostros',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  preparing
                      ? 'Comprueba que la cámara vea un solo rostro, centrado y completo. Esta prueba no guarda imágenes ni datos biométricos y todavía no registra al empleado por su rostro.'
                      : 'Esta prueba no identifica empleados, no registra checadas y no guarda imágenes.',
                ),
                const SizedBox(height: 16),
                Text(_status, style: Theme.of(context).textTheme.titleMedium),
                if (preparing && _goodFrames >= 3) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Encuadre listo para el futuro enrolamiento. La identificación y la prueba de vida aún están pendientes.',
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  'Rostros: $_faces  ·  Análisis: ${_latencyMs == null ? '—' : '$_latencyMs ms'}  ·  Cuadros analizados: $_analyzedFrames',
                ),
                const SizedBox(height: 16),
                AspectRatio(
                  aspectRatio: 4 / 3,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: ColoredBox(
                      color: Colors.black,
                      child:
                          controller != null && controller.value.isInitialized
                          ? RotatedBox(
                              quarterTurns: _rotateHalfTurn ? 2 : 0,
                              child: CameraPreview(controller),
                            )
                          : const Center(
                              child: Icon(
                                Icons.camera_alt_outlined,
                                color: Colors.white,
                                size: 48,
                              ),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
