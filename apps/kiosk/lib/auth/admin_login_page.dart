import 'package:flutter/material.dart';

import 'admin_auth.dart';
import 'admin_recovery_page.dart';

class AdminLoginPage extends StatefulWidget {
  const AdminLoginPage({super.key, required this.auth, required this.setup});
  final AdminAuth auth;
  final bool setup;

  @override
  State<AdminLoginPage> createState() => _AdminLoginPageState();
}

class _AdminLoginPageState extends State<AdminLoginPage> {
  final _form = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool _busy = false;
  bool _visible = false;
  String? _error;

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.setup) {
        await widget.auth.create(_username.text, _password.text);
      } else {
        await widget.auth.login(_username.text, _password.text);
      }
    } on AuthenticationError catch (error) {
      if (mounted) {
        setState(() => _error = error.message);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'No se pudo completar el acceso. Vuelve a intentarlo.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          widget.setup ? 'Configurar administrador' : 'Administración',
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  widget.setup
                      ? 'Tu tablet, lista para trabajar'
                      : 'Acceso de administrador',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 12),
                Text(
                  widget.setup
                      ? 'Crea la cuenta que podrá administrar empleados y respaldos. Funcionará sin internet.'
                      : 'Ingresa tus credenciales para administrar esta tablet.',
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
                        decoration: const InputDecoration(labelText: 'Usuario'),
                        validator: validateAdminUsername,
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _password,
                        enabled: !_busy,
                        obscureText: !_visible,
                        autocorrect: false,
                        enableSuggestions: false,
                        maxLength: 128,
                        decoration: InputDecoration(
                          labelText: 'Contraseña',
                          helperText: widget.setup
                              ? 'Al menos 12 caracteres. Puedes usar una frase.'
                              : null,
                          helperMaxLines: 2,
                          suffixIcon: IconButton(
                            tooltip: _visible
                                ? 'Ocultar contraseña'
                                : 'Mostrar contraseña',
                            onPressed: _busy
                                ? null
                                : () => setState(() => _visible = !_visible),
                            icon: Icon(
                              _visible
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                            ),
                          ),
                        ),
                        validator: widget.setup
                            ? validateAdminPassword
                            : (value) => value == null || value.isEmpty
                                  ? 'Escribe la contraseña.'
                                  : null,
                        onFieldSubmitted: widget.setup
                            ? null
                            : (_) => _submit(),
                      ),
                      if (widget.setup) ...[
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _confirmation,
                          enabled: !_busy,
                          obscureText: !_visible,
                          autocorrect: false,
                          enableSuggestions: false,
                          maxLength: 128,
                          decoration: const InputDecoration(
                            labelText: 'Repetir contraseña',
                          ),
                          validator: (value) => value == _password.text
                              ? null
                              : 'Las contraseñas no coinciden.',
                          onFieldSubmitted: (_) => _submit(),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Al crear la cuenta recibirás un código de recuperación. Guárdalo fuera de la tablet para poder cambiar la contraseña sin internet.',
                        ),
                      ],
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: _busy ? null : _submit,
                        child: Text(
                          _busy
                              ? 'Espera un momento…'
                              : widget.setup
                              ? 'Crear administrador'
                              : 'Entrar',
                        ),
                      ),
                      if (!widget.setup) ...[
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) =>
                                        AdminRecoveryPage(auth: widget.auth),
                                  ),
                                ),
                          child: const Text('¿Olvidaste la contraseña?'),
                        ),
                      ],
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
