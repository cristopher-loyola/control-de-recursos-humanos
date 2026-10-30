import 'package:flutter/material.dart';

class RecoveryCodePage extends StatelessWidget {
  const RecoveryCodePage({
    super.key,
    required this.code,
    required this.onContinue,
  });

  final String code;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Código de recuperación')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                'Guarda este código',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 16),
              const Text(
                'Anótalo o guárdalo fuera de la tablet. Si olvidas la contraseña, podrás recuperar el acceso sin internet. Se muestra una sola vez y deja de servir después de usarlo o generar otro.',
              ),
              const SizedBox(height: 24),
              SelectableText(
                code,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 32),
              FilledButton(
                onPressed: onContinue,
                child: const Text('Ya guardé el código'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
