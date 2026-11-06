import 'package:flutter/material.dart';

import '../attendance/pin_store.dart';
import '../theme/app_theme.dart';

/// Teclado en pantalla para checar con número de empleado y PIN cuando el
/// rostro no se reconoce. Devuelve el PIN ya comprobado.
class PinPadDialog extends StatefulWidget {
  const PinPadDialog({super.key, required this.pins});
  final PinStore pins;

  @override
  State<PinPadDialog> createState() => _PinPadDialogState();
}

class _PinPadDialogState extends State<PinPadDialog> {
  String _number = '';
  String _pin = '';
  bool _askingPin = false;
  bool _checking = false;
  String? _error;

  String get _value => _askingPin ? _pin : _number;

  void _type(String digit) {
    if (_checking) return;
    setState(() {
      _error = null;
      if (_askingPin) {
        if (_pin.length < 6) _pin += digit;
      } else if (_number.length < 10) {
        _number += digit;
      }
    });
  }

  void _erase() {
    if (_checking || _value.isEmpty) return;
    setState(() {
      _error = null;
      if (_askingPin) {
        _pin = _pin.substring(0, _pin.length - 1);
      } else {
        _number = _number.substring(0, _number.length - 1);
      }
    });
  }

  Future<void> _continue() async {
    if (_checking) return;
    if (!_askingPin) {
      if (_number.isEmpty) return;
      setState(() => _askingPin = true);
      return;
    }
    if (_pin.length < 4) {
      setState(() => _error = 'El PIN tiene de 4 a 6 números.');
      return;
    }
    setState(() => _checking = true);
    try {
      final check = await widget.pins.verify(_number, _pin);
      if (mounted) Navigator.of(context).pop(check);
    } on PinRuleError catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _pin = '';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'No se pudo comprobar el PIN. Intenta de nuevo.';
          _pin = '';
        });
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  void _back() {
    if (_askingPin) {
      setState(() {
        _askingPin = false;
        _pin = '';
        _error = null;
      });
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    Widget key(Widget child, VoidCallback? onTap, {bool primary = false}) =>
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: SizedBox(
              height: 50,
              child: primary
                  ? FilledButton(onPressed: onTap, child: child)
                  : OutlinedButton(onPressed: onTap, child: child),
            ),
          ),
        );
    Widget digit(String value) => key(
      Text(value, style: const TextStyle(fontSize: 24)),
      _checking ? null : () => _type(value),
    );
    return AlertDialog(
      scrollable: true,
      title: const Text('Checar con PIN'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _askingPin
                  ? 'Escribe tu PIN. Tu checada pasará a revisión de RH.'
                  : 'Escribe tu número de empleado.',
              style: text.bodyMedium?.copyWith(color: AppColors.muted),
            ),
            const SizedBox(height: 8),
            Container(
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _error == null ? AppColors.line : AppColors.danger,
                ),
              ),
              child: Text(
                _value.isEmpty
                    ? (_askingPin ? 'PIN' : 'No. de empleado')
                    : _askingPin
                    ? '•' * _pin.length
                    : _number,
                style: TextStyle(
                  fontSize: _value.isEmpty ? 18 : 26,
                  letterSpacing: _askingPin && _value.isNotEmpty ? 8 : 1,
                  color: _value.isEmpty ? AppColors.muted : AppColors.ink,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            SizedBox(
              height: 30,
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _error ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(color: AppColors.danger),
                ),
              ),
            ),
            for (final row in const [
              ['1', '2', '3'],
              ['4', '5', '6'],
              ['7', '8', '9'],
            ])
              Row(children: [for (final value in row) digit(value)]),
            Row(
              children: [
                key(
                  const Icon(Icons.backspace_outlined),
                  _checking ? null : _erase,
                ),
                digit('0'),
                key(
                  _checking
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.arrow_forward),
                  _checking || _value.isEmpty ? null : _continue,
                  primary: true,
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _checking ? null : _back,
          child: Text(_askingPin ? 'Cambiar número' : 'Cancelar'),
        ),
      ],
    );
  }
}
