import 'package:flutter/material.dart';

import 'admin_auth.dart';

class RhAccountPage extends StatefulWidget {
  const RhAccountPage({super.key, required this.auth});
  final AdminAuth auth;

  @override
  State<RhAccountPage> createState() => _RhAccountPageState();
}

class _RhAccountPageState extends State<RhAccountPage> {
  final _form = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.auth.createRhAccount(_username.text, _password.text);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on AuthenticationError catch (error) {
      if (mounted) {
        setState(() => _error = error.message);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'No se pudo crear la cuenta. Vuelve a intentarlo.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Nueva cuenta de RH')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  'Acceso de Recursos Humanos',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Esta cuenta podrá gestionar empleados y consultar asistencia. Los respaldos, la auditoría y la seguridad quedan a cargo del administrador.',
                ),
                const SizedBox(height: 24),
                Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        controller: _username,
                        enabled: !_busy,
                        maxLength: 40,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                          labelText: 'Usuario de RH',
                        ),
                        validator: validateAdminUsername,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _password,
                        enabled: !_busy,
                        maxLength: 128,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                          labelText: 'Contraseña',
                        ),
                        validator: validateAdminPassword,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _confirmation,
                        enabled: !_busy,
                        maxLength: 128,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                          labelText: 'Repetir contraseña',
                        ),
                        validator: (value) => value == _password.text
                            ? null
                            : 'Las contraseñas no coinciden.',
                      ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: _busy ? null : _save,
                        child: Text(
                          _busy ? 'Guardando…' : 'Crear cuenta de RH',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
