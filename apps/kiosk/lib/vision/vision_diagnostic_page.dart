import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// Diagnóstico local de cámara. No identifica personas ni guarda imágenes.
class VisionDiagnosticPage extends StatefulWidget {
  const VisionDiagnosticPage({super.key});

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
  DateTime? _lastAnalysis;
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
      if (mounted && !_disposed) {
        setState(() {
          _faces = faces.length;
          _latencyMs = timer.elapsedMilliseconds;
          _analyzedFrames++;
          _status = faces.isEmpty
              ? 'No hay rostros en el cuadro.'
              : faces.length == 1
              ? 'Se detectó un rostro.'
              : 'Se detectaron ${faces.length} rostros.';
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnóstico de cámara'),
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
                  'Detección local de rostros',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Esta prueba no identifica empleados, no registra checadas y no guarda imágenes.',
                ),
                const SizedBox(height: 16),
                Text(_status, style: Theme.of(context).textTheme.titleMedium),
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
