import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'face_capture_quality.dart';
import 'face_engine.dart';
import 'face_matching.dart';

/// Pide una foto del siguiente cuadro de la cámara sin interrumpir la vista
/// ni mostrar nada en pantalla. Devuelve null si la cámara no responde.
class FaceSnapshots {
  Future<Uint8List?> Function()? _take;

  Future<Uint8List?> take() => _take?.call() ?? Future.value(null);
}

class FaceCapturePanel extends StatefulWidget {
  const FaceCapturePanel({
    super.key,
    required this.onSamples,
    this.beforeStart,
    this.guidedEnrollment = false,
    this.active = true,
    this.fill = false,
    this.highlight,
    this.snapshots,
  });

  /// Si se indica, permite tomar fotos del cuadro actual.
  final FaceSnapshots? snapshots;

  /// Ocupa todo el espacio disponible con la imagen recortada al centro y el
  /// estado encima. Lo usa el checador.
  final bool fill;

  /// Color del borde de la cámara en modo [fill] (por ejemplo, al reconocer).
  final Color? highlight;
  final Future<void> Function(List<List<double>>) onSamples;
  final Future<void> Function()? beforeStart;
  final bool guidedEnrollment;

  /// En pausa la cámara sigue encendida pero no analiza cuadros; al reactivarse
  /// empieza una lectura nueva sin esperar a que la cámara vuelva a abrir.
  final bool active;

  @override
  State<FaceCapturePanel> createState() => _FaceCapturePanelState();
}

class _FaceCapturePanelState extends State<FaceCapturePanel>
    with WidgetsBindingObserver {
  final _engine = FaceEngine();
  final _samples = <List<double>>[];
  // En el registro se espacian las tomas para obtener variación natural.
  Duration get _sampleSpacing => widget.guidedEnrollment
      ? const Duration(milliseconds: 400)
      : Duration.zero;
  CameraController? _controller;
  CameraDescription? _camera;
  Future<void> _operations = Future.value();
  Future<void>? _frameWork;
  bool _disposed = false;
  bool _finished = false;
  bool _halfTurn = false;
  bool _failed = false;
  // Giro extra que necesitó el análisis para ver el rostro derecho.
  int _analysisTurn = 0;
  int _emptyFrames = 0;
  Rect? _lastBox;
  DateTime? _lastSampleAt;
  int _epoch = 0;
  String _status = 'Preparando la cámara…';
  Completer<Uint8List?>? _pendingSnapshot;
  Future<void>? _snapshotWork;

  void _showStatus(String status) {
    if (mounted && !_disposed && _status != status) {
      setState(() => _status = status);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.snapshots?._take = _takeSnapshot;
    _operations = _operations.then((_) => _start());
  }

  Future<Uint8List?> _takeSnapshot() {
    if (_disposed || _controller == null) return Future.value(null);
    final pending = _pendingSnapshot ??= Completer<Uint8List?>();
    return pending.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        if (identical(_pendingSnapshot, pending)) _pendingSnapshot = null;
        return null;
      },
    );
  }

  Future<void> _snapshot(
    CameraImage frame,
    Completer<Uint8List?> pending,
  ) async {
    try {
      final rotation = _rotation();
      if (rotation == null ||
          frame.planes.length != 1 ||
          frame.format.group != ImageFormatGroup.nv21) {
        if (!pending.isCompleted) pending.complete(null);
        return;
      }
      final bytes = Uint8List.fromList(frame.planes.single.bytes);
      var angle = rotation;
      // Con el análisis en pausa (al usar PIN) se busca el giro que deja el
      // rostro derecho; así la foto sale bien aunque aún no se haya aprendido.
      if (!widget.active) {
        for (final turn in const [0, 90, 270, 180]) {
          final candidate = (rotation + turn) % 360;
          final detection = await _engine.detect(
            bytes: bytes,
            width: frame.width,
            height: frame.height,
            rotation: candidate,
          );
          final faces = FaceCaptureQuality.people(
            detection.faces,
            (face) => face.box,
          );
          if (faces.length == 1 &&
              FaceCaptureQuality.isUpright(faces.single.landmarks)) {
            angle = candidate;
            if (turn != 0) {
              _analysisTurn = (_analysisTurn + turn) % 360;
              unawaited(_engine.setAnalysisTurn(_analysisTurn));
            }
            break;
          }
        }
      }
      final jpeg = await _engine.snapshot(
        bytes: bytes,
        width: frame.width,
        height: frame.height,
        rotation: angle,
      );
      if (!pending.isCompleted) pending.complete(jpeg);
    } catch (_) {
      if (!pending.isCompleted) pending.complete(null);
    }
  }

  /// Grados para dejar derecho el cuadro de la cámara frontal.
  int? _rotation() {
    final camera = _camera;
    final controller = _controller;
    if (camera == null || controller == null) return null;
    const orientations = {
      DeviceOrientation.portraitUp: 0,
      DeviceOrientation.landscapeLeft: 90,
      DeviceOrientation.portraitDown: 180,
      DeviceOrientation.landscapeRight: 270,
    };
    final orientation = orientations[controller.value.deviceOrientation]!;
    return ((camera.lensDirection == CameraLensDirection.front
                ? camera.sensorOrientation + orientation
                : camera.sensorOrientation - orientation + 360) +
            (_halfTurn ? 180 : 0) +
            _analysisTurn) %
        360;
  }

  void _reset() {
    _samples.clear();
    _lastBox = null;
    _lastSampleAt = null;
  }

  Future<void> _start() async {
    if (_disposed || _controller != null || _finished) return;
    try {
      if (!Platform.isAndroid) throw StateError('Android requerido');
      await widget.beforeStart?.call();
      final setup = await Future.wait<Object>([
        _engine.initialize().then<Object>((_) => true),
        availableCameras(),
      ]);
      _halfTurn = await _engine.cameraRotation();
      _analysisTurn = await _engine.analysisTurn();
      final cameras = setup[1] as List<CameraDescription>;
      if (_disposed) return;
      if (cameras.isEmpty) throw StateError('Cámara no disponible');
      _camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        _camera!,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );
      await controller.initialize();
      if (_disposed) {
        await controller.dispose();
        return;
      }
      _controller = controller;
      _reset();
      _failed = false;
      await controller.startImageStream(_onFrame);
      _showStatus('Coloca tu rostro en el centro.');
    } catch (_) {
      await _stop();
      if (mounted) {
        setState(() {
          _failed = true;
          _status = 'No se pudo abrir la cámara o verificar el acceso. Revisa el permiso de cámara y vuelve a intentar.';
        });
      }
    }
  }

  Future<void> _stop() async {
    _epoch++;
    final controller = _controller;
    _controller = null;
    _camera = null;
    _reset();
    if (mounted && !_disposed) {
      setState(() => _status = 'Cámara pausada.');
      // Detach CameraPreview before disposing the controller it renders.
      await WidgetsBinding.instance.endOfFrame.timeout(
        const Duration(milliseconds: 300),
        onTimeout: () {},
      );
    }
    if (controller != null) {
      try {
        if (controller.value.isStreamingImages) {
          await controller.stopImageStream();
        }
      } on CameraException {
        /* Android may have already released the stream. */
      }
      await _frameWork;
      await controller.dispose();
    } else {
      await _frameWork;
    }
  }

  @override
  void didUpdateWidget(FaceCapturePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _epoch++;
      _finished = false;
      _reset();
      _showStatus('Coloca tu rostro en el centro.');
    }
  }

  void _onFrame(CameraImage frame) {
    final pending = _pendingSnapshot;
    if (!_disposed && pending != null && _snapshotWork == null) {
      _pendingSnapshot = null;
      _snapshotWork = _snapshot(
        frame,
        pending,
      ).whenComplete(() => _snapshotWork = null);
    }
    if (_disposed || _finished || !widget.active || _frameWork != null) {
      return;
    }
    final epoch = _epoch;
    _frameWork = _process(frame, epoch).whenComplete(() => _frameWork = null);
  }

  Future<void> _process(CameraImage frame, int epoch) async {
    try {
      final camera = _camera;
      final controller = _controller;
      if (camera == null ||
          controller == null ||
          frame.planes.length != 1 ||
          frame.format.group != ImageFormatGroup.nv21 ||
          frame.planes.single.bytes.length !=
              frame.width * frame.height * 3 ~/ 2) {
        _showStatus('La cámara no entrega un formato compatible.');
        return;
      }
      var degrees = _rotation()!;
      final bytes = Uint8List.fromList(frame.planes.single.bytes);
      Future<FaceDetection> detectAt(int angle) => _engine.detect(
        bytes: bytes,
        width: frame.width,
        height: frame.height,
        rotation: angle,
      );
      List<DetectedFace> peopleIn(FaceDetection detection) =>
          FaceCaptureQuality.people(detection.faces, (face) => face.box);

      var detection = await detectAt(degrees);
      var faces = peopleIn(detection);
      if (_disposed || epoch != _epoch || !mounted) return;
      // Si la cámara está montada girada, el rostro sale de lado o de cabeza:
      // se prueban los otros giros y se conserva el que lo deja derecho. Sin
      // rostro también se prueba de vez en cuando, porque YuNet casi no
      // detecta caras de lado.
      final turned =
          faces.length == 1 &&
          !FaceCaptureQuality.isUpright(faces.single.landmarks);
      if (turned || (faces.isEmpty && ++_emptyFrames % 15 == 0)) {
        for (final turn in const [90, 270, 180]) {
          final angle = (degrees + turn) % 360;
          final corrected = await detectAt(angle);
          final correctedFaces = peopleIn(corrected);
          if (_disposed || epoch != _epoch || !mounted) return;
          if (correctedFaces.length == 1 &&
              FaceCaptureQuality.isUpright(correctedFaces.single.landmarks)) {
            degrees = angle;
            detection = corrected;
            faces = correctedFaces;
            _analysisTurn = (_analysisTurn + turn) % 360;
            unawaited(_engine.setAnalysisTurn(_analysisTurn));
            _reset();
            break;
          }
        }
      }
      final face = faces.length == 1 ? faces.single : null;
      final issue = FaceCaptureQuality.issue(
        faceCount: faces.length,
        faceBounds: face?.box,
        imageSize: detection.size,
        headRoll: face?.roll,
        headYaw: face?.yaw,
        maxYaw: widget.guidedEnrollment ? 25 : 20,
      );
      if (issue != null || face == null) {
        _reset();
        _showStatus(issue ?? 'Muestra un solo rostro.');
        return;
      }
      // Sin seguimiento entre cuadros: si el rostro salta de lugar, se reinicia la lectura.
      final previous = _lastBox;
      _lastBox = face.box;
      if (previous != null &&
          (face.box.center - previous.center).distance >
              previous.width * 0.35) {
        _reset();
      }
      final now = DateTime.now();
      if (_lastSampleAt != null &&
          now.difference(_lastSampleAt!) < _sampleSpacing) {
        return;
      }
      final vector = await _engine.extractDetected(face.index);
      if (_disposed || epoch != _epoch || !mounted) return;
      _samples.add(vector);
      _lastSampleAt = now;
      _showStatus('Leyendo rostro ${_samples.length}/3. Mantente quieto.');
      if (_samples.length == FaceMatching.sampleCount) {
        final samples = FaceMatching.samples(_samples);
        _finished = true;
        _showStatus(
          widget.guidedEnrollment
              ? 'Guardando rostro…'
              : 'Procesando identificación…',
        );
        await widget.onSamples(samples);
      }
    } on FaceRuleError catch (error) {
      _finished = false;
      _reset();
      _showStatus(error.message);
    } catch (_) {
      _reset();
      _finished = false;
      _showStatus(
        'No se pudo leer el rostro. Mira de frente e inténtalo de nuevo.',
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _operations = _operations.then((_) => _stop());
    } else if (state == AppLifecycleState.resumed) {
      _operations = _operations.then((_) => _start());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (widget.snapshots?._take == _takeSnapshot) {
      widget.snapshots!._take = null;
    }
    _pendingSnapshot?.complete(null);
    _pendingSnapshot = null;
    WidgetsBinding.instance.removeObserver(this);
    _operations = _operations.then((_) => _stop());
    super.dispose();
  }

  Widget _filled(BuildContext context) {
    final camera = _controller;
    final ready = camera != null && camera.value.isInitialized;
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final ratio = ready ? camera.value.aspectRatio : 4 / 3;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0xFF151513)),
          if (ready)
            FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: landscape ? ratio * 300 : 300 / ratio,
                height: 300,
                child: RotatedBox(
                  quarterTurns: _halfTurn ? 2 : 0,
                  child: CameraPreview(camera),
                ),
              ),
            )
          else
            Center(
              child: _failed
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.no_photography_outlined,
                          color: Colors.white70,
                          size: 40,
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white38),
                          ),
                          onPressed: () =>
                              _operations = _operations.then((_) => _start()),
                          child: const Text('Volver a intentar'),
                        ),
                      ],
                    )
                  : const SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white70,
                      ),
                    ),
            ),
          if (ready)
            IgnorePointer(
              child: CustomPaint(painter: _FaceGuidePainter(shade: false)),
            ),
          IgnorePointer(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: widget.highlight ?? Colors.transparent,
                  width: 4,
                ),
              ),
            ),
          ),
          if (widget.active)
            Positioned(
              left: 20,
              right: 20,
              bottom: 20,
              child: Center(
                child: Semantics(
                  liveRegion: true,
                  child: _StatusPill(text: _status, live: ready),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.fill) return _filled(context);
    final camera = _controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          liveRegion: true,
          child: Text(_status, style: Theme.of(context).textTheme.titleMedium),
        ),
        const SizedBox(height: 12),
        if (widget.guidedEnrollment) ...[
          Text(
            'Lectura ${_samples.length} de 3 · Mira de frente dentro del contorno',
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: _samples.length / 3),
          const SizedBox(height: 12),
        ],
        SizedBox(
          // La vista completa debe caber en pantalla, también con la tablet horizontal.
          height: (MediaQuery.sizeOf(context).height - 330).clamp(180.0, 420.0),
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: ColoredBox(
                color: Colors.black,
                child: camera != null && camera.value.isInitialized
                    ? Stack(
                        fit: StackFit.expand,
                        children: [
                          Center(
                            child: RotatedBox(
                              quarterTurns: _halfTurn ? 2 : 0,
                              child: CameraPreview(camera),
                            ),
                          ),
                          if (widget.guidedEnrollment)
                            IgnorePointer(
                              child: CustomPaint(
                                painter: const _FaceGuidePainter(),
                              ),
                            ),
                        ],
                      )
                    : Center(
                        child: _failed
                            ? const Icon(
                                Icons.no_photography_outlined,
                                color: Colors.white,
                                size: 48,
                              )
                            : const CircularProgressIndicator(),
                      ),
              ),
            ),
          ),
        ),
        // Ajuste de instalación: solo lo ve RH al registrar rostros, no el empleado al checar.
        if (widget.guidedEnrollment)
          TextButton.icon(
            onPressed: _finished
                ? null
                : () async {
                    _epoch++;
                    _reset();
                    _analysisTurn = 0;
                    unawaited(_engine.setAnalysisTurn(0));
                    setState(() => _halfTurn = !_halfTurn);
                    await _engine.setCameraRotation(_halfTurn);
                  },
            icon: const Icon(Icons.rotate_right),
            label: const Text('Girar imagen 180 grados'),
          ),
        if (_failed)
          TextButton(
            onPressed: () => _operations = _operations.then((_) => _start()),
            child: const Text('Volver a intentar'),
          ),
      ],
    );
  }
}

class _FaceGuidePainter extends CustomPainter {
  const _FaceGuidePainter({this.shade = true});

  /// Oscurece lo que queda fuera del óvalo (registro de rostro).
  final bool shade;

  @override
  void paint(Canvas canvas, Size size) {
    final oval = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: size.height * 0.55,
      height: size.height * 0.82,
    );
    if (shade) {
      final outside = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addOval(oval);
      canvas.drawPath(outside, Paint()..color = Colors.black38);
    }
    canvas.drawOval(
      oval,
      Paint()
        ..color = shade ? Colors.white : Colors.white54
        ..style = PaintingStyle.stroke
        ..strokeWidth = shade ? 3 : 2,
    );
  }

  @override
  bool shouldRepaint(_FaceGuidePainter oldDelegate) =>
      oldDelegate.shade != shade;
}

/// Estado sobre la imagen de la cámara, con un punto que late mientras escanea.
class _StatusPill extends StatefulWidget {
  const _StatusPill({required this.text, required this.live});
  final String text;
  final bool live;

  @override
  State<_StatusPill> createState() => _StatusPillState();
}

class _StatusPillState extends State<_StatusPill>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.94),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FadeTransition(
          opacity: widget.live
              ? Tween(begin: 0.25, end: 1.0).animate(_pulse)
              : const AlwaysStoppedAnimation(0.25),
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              shape: BoxShape.circle,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            // Solo el mensaje nuevo: los cambios rápidos no se enciman.
            layoutBuilder: (current, _) => current ?? const SizedBox.shrink(),
            child: Text(
              widget.text,
              key: ValueKey(widget.text),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: Color(0xFF1C1B19),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
