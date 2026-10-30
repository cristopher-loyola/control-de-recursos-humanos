import 'package:flutter/material.dart';

import 'admin_auth.dart';

class AdminRecoveryPage extends StatefulWidget {
  const AdminRecoveryPage({super.key, required this.auth});
  final AdminAuth auth;

  @override
  State<AdminRecoveryPage> createState() => _AdminRecoveryPageState();
}

class _AdminRecoveryPageState extends State<AdminRecoveryPage> {
  final _form = GlobalKey<FormState>();
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.auth.recover(_code.text, _password.text);
    } on AuthenticationError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'No se pudo recuperar el acceso. Vuelve a intentarlo.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Recuperar acceso')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  'Usa el código que guardaste',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 12),
                const Text(
                  'No se necesita internet. El código anterior dejará de servir al cambiar la contraseña.',
                ),
                const SizedBox(height: 24),
                Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        controller: _code,
                        enabled: !_busy,
                        maxLength: 35,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                          labelText: 'Código de recuperación',
                        ),
                        validator: (value) =>
                            RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(
                              (value ?? '').replaceAll(RegExp(r'[\s-]'), ''),
                            )
                            ? null
                            : 'Escribe el código completo.',
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
                          labelText: 'Nueva contraseña',
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
                          labelText: 'Repetir nueva contraseña',
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
                        onPressed: _busy ? null : _submit,
                        child: Text(
                          _busy ? 'Espera un momento…' : 'Cambiar contraseña',
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
