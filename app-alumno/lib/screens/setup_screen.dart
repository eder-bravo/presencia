import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class SetupScreen extends StatefulWidget {
  final Future<bool> Function(String matricula) onComplete;
  final String initialMatricula;

  const SetupScreen({
    super.key,
    required this.onComplete,
    this.initialMatricula = '',
  });

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final TextEditingController _matriculaController;
  bool _loading = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _matriculaController = TextEditingController(
      text: widget.initialMatricula.trim().toUpperCase(),
    );
  }

  @override
  void dispose() {
    _matriculaController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final matricula = _matriculaController.text.trim().toUpperCase();

    if (matricula.isEmpty) {
      setState(() => _errorText = 'Ingresa tu matrícula');
      return;
    }

    if (matricula.length < 5) {
      setState(() => _errorText = 'Revisa que tu matrícula esté completa');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _errorText = null;
    });
    HapticFeedback.mediumImpact();

    try {
      final registered = await widget.onComplete(matricula);
      if (registered) return;
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorText =
            'No pudimos registrar este celular. Revisa tu conexión e inténtalo de nuevo.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorText = 'No pudimos vincular este celular. Inténtalo de nuevo.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 28),
                      const _BrandHeader(),
                      SizedBox(height: constraints.maxHeight < 700 ? 44 : 76),
                      Text(
                        'Bienvenido a\nPresencia: Alumnos',
                        style: Theme.of(
                          context,
                        ).textTheme.headlineSmall?.copyWith(fontSize: 27),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Ingresa tu matrícula para vincular este celular a tu cuenta.',
                        style: Theme.of(
                          context,
                        ).textTheme.bodyLarge?.copyWith(height: 1.45),
                      ),
                      const SizedBox(height: 30),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(22),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                'Vincula tu celular',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Un cambio de celular deberá ser autorizado por un maestro.',
                                style: Theme.of(
                                  context,
                                ).textTheme.bodyMedium?.copyWith(height: 1.4),
                              ),
                              const SizedBox(height: 22),
                              TextField(
                                controller: _matriculaController,
                                enabled: !_loading,
                                textCapitalization:
                                    TextCapitalization.characters,
                                textInputAction: TextInputAction.done,
                                onSubmitted: (_) => _loading ? null : _submit(),
                                onChanged: (_) {
                                  if (_errorText != null) {
                                    setState(() => _errorText = null);
                                  }
                                },
                                inputFormatters: [
                                  FilteringTextInputFormatter.allow(
                                    RegExp(r'[a-zA-Z0-9]'),
                                  ),
                                  LengthLimitingTextInputFormatter(14),
                                  TextInputFormatter.withFunction(
                                    (oldValue, newValue) => newValue.copyWith(
                                      text: newValue.text.toUpperCase(),
                                      selection: newValue.selection,
                                    ),
                                  ),
                                ],
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                ),
                                decoration: InputDecoration(
                                  labelText: 'Matrícula',
                                  hintText: 'A2130587',
                                  errorText: _errorText,
                                  prefixIcon: const Icon(Icons.badge_rounded),
                                ),
                              ),
                              const SizedBox(height: 22),
                              SizedBox(
                                height: 56,
                                child: FilledButton(
                                  onPressed: _loading ? null : _submit,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    foregroundColor: Theme.of(
                                      context,
                                    ).colorScheme.onPrimary,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                  ),
                                  child: _loading
                                      ? SizedBox(
                                          width: 22,
                                          height: 22,
                                          child: CircularProgressIndicator(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onPrimary,
                                            strokeWidth: 2.4,
                                          ),
                                        )
                                      : const Text(
                                          'Continuar',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(
            Icons.school_rounded,
            color: Theme.of(context).colorScheme.onPrimary,
            size: 26,
          ),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Presencia',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: Theme.of(context).textTheme.titleLarge?.color,
              ),
            ),
            SizedBox(height: 2),
            Text(
              'Alumnos',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ],
    );
  }
}
