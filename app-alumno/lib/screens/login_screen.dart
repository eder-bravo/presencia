import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/local_storage_service.dart';
import '../services/student_auth_service.dart';
import '../theme/app_theme.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.storage,
    required this.onAuthenticated,
  });

  final LocalStorageService storage;
  final Future<void> Function(
    String username,
    String password,
    StudentAuthResult result,
  )
  onAuthenticated;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _emailFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();
  final _emailFieldKey = GlobalKey();
  final _passwordFieldKey = GlobalKey();
  final _auth = StudentAuthService();
  bool _loading = false;
  bool _obscurePassword = true;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _emailFocusNode.addListener(() {
      if (_emailFocusNode.hasFocus) _scrollToField(_emailFieldKey);
    });
    _passwordFocusNode.addListener(() {
      if (_passwordFocusNode.hasFocus) _scrollToField(_passwordFieldKey);
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _emailFocusNode.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  void _scrollToField(GlobalKey key) {
    Future<void>.delayed(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      final target = key.currentContext;
      if (target == null) return;
      if (!target.mounted) return;
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 220),
        alignment: .28,
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _submit() async {
    final username = _emailController.text.trim().toLowerCase();
    final password = _passwordController.text;
    if (username.isEmpty || !username.contains('@')) {
      setState(() => _errorText = 'Ingresa tu correo institucional.');
      return;
    }
    if (password.isEmpty) {
      setState(() => _errorText = 'Ingresa tu contraseña.');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _errorText = null;
    });
    HapticFeedback.mediumImpact();
    StudentAuthResult? pendingResult;
    try {
      pendingResult = await _auth.loginAndBind(
        username: username,
        password: password,
        storage: widget.storage,
      );
      await widget.onAuthenticated(username, password, pendingResult);
      pendingResult = null;
    } on StudentAuthException catch (error) {
      if (pendingResult != null) {
        await _auth.discardSession(pendingResult.sessionId);
      }
      if (mounted) setState(() => _errorText = error.message);
    } catch (_) {
      if (pendingResult != null) {
        await _auth.discardSession(pendingResult.sessionId);
      }
      if (mounted) {
        setState(
          () => _errorText = 'No pudimos iniciar sesión. Inténtalo de nuevo.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: AppPalette.of(context).background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, viewport) => Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: SizedBox(
                height: viewport.maxHeight,
                child: Stack(
                  children: [
                    Positioned(
                      top: -76,
                      right: -42,
                      child: Container(
                        width: 210,
                        height: 194,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withValues(
                            alpha: dark ? .16 : .09,
                          ),
                          borderRadius: BorderRadius.circular(100),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: SingleChildScrollView(
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: const EdgeInsets.fromLTRB(30, 24, 30, 28),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const _BrandHeader(),
                            const SizedBox(height: 56),
                            _LoginCard(
                              emailController: _emailController,
                              passwordController: _passwordController,
                              emailFocusNode: _emailFocusNode,
                              passwordFocusNode: _passwordFocusNode,
                              emailFieldKey: _emailFieldKey,
                              passwordFieldKey: _passwordFieldKey,
                              obscurePassword: _obscurePassword,
                              errorText: _errorText,
                              loading: _loading,
                              onTogglePassword: () => setState(
                                () => _obscurePassword = !_obscurePassword,
                              ),
                              onEmailSubmitted: (_) => FocusScope.of(
                                context,
                              ).requestFocus(_passwordFocusNode),
                              onSubmit: _submit,
                            ),
                            const SizedBox(height: 32),
                            Text(
                              '¿Necesitas ayuda? Contacta con administración',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.labelSmall,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              '© 2026 Universidad Autónoma de Tamaulipas',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.textTheme.bodySmall?.color
                                    ?.withValues(alpha: .65),
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
    );
  }
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Container(
        width: 64,
        height: 64,
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: const [
            BoxShadow(
              color: Color(0x18081F38),
              blurRadius: 14,
              offset: Offset(0, 5),
            ),
          ],
        ),
        child: Image.asset('assets/images/fiuat-2024.png', fit: BoxFit.contain),
      ),
      const SizedBox(height: 12),
      Text(
        'Presencia: Alumnos',
        style: TextStyle(
          fontSize: 23,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).textTheme.headlineSmall?.color,
        ),
      ),
      const SizedBox(height: 3),
      Text(
        'Gestión Escolar · Facultad de Ingeniería',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).textTheme.labelSmall?.color,
        ),
      ),
    ],
  );
}

class _LoginCard extends StatelessWidget {
  const _LoginCard({
    required this.emailController,
    required this.passwordController,
    required this.emailFocusNode,
    required this.passwordFocusNode,
    required this.emailFieldKey,
    required this.passwordFieldKey,
    required this.obscurePassword,
    required this.errorText,
    required this.loading,
    required this.onTogglePassword,
    required this.onEmailSubmitted,
    required this.onSubmit,
  });

  final TextEditingController emailController;
  final TextEditingController passwordController;
  final FocusNode emailFocusNode;
  final FocusNode passwordFocusNode;
  final GlobalKey emailFieldKey;
  final GlobalKey passwordFieldKey;
  final bool obscurePassword;
  final String? errorText;
  final bool loading;
  final VoidCallback onTogglePassword;
  final ValueChanged<String> onEmailSubmitted;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppPalette.of(context).surface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: dark
            ? null
            : const [
                BoxShadow(
                  color: Color(0x12081F38),
                  blurRadius: 20,
                  offset: Offset(0, 8),
                ),
              ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _FieldLabel(text: 'Correo institucional'),
          const SizedBox(height: 6),
          TextField(
            key: emailFieldKey,
            controller: emailController,
            focusNode: emailFocusNode,
            enabled: !loading,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            textInputAction: TextInputAction.next,
            textAlignVertical: TextAlignVertical.center,
            onSubmitted: onEmailSubmitted,
            decoration: const InputDecoration(
              hintText: 'matrícula@alumnos.uat.edu.mx',
              prefixIcon: Icon(Icons.mail_outline_rounded),
            ),
          ),
          const SizedBox(height: 12),
          _FieldLabel(text: 'Contraseña'),
          const SizedBox(height: 6),
          TextField(
            key: passwordFieldKey,
            controller: passwordController,
            focusNode: passwordFocusNode,
            enabled: !loading,
            obscureText: obscurePassword,
            textInputAction: TextInputAction.done,
            textAlignVertical: TextAlignVertical.center,
            onSubmitted: (_) => loading ? null : onSubmit(),
            decoration: InputDecoration(
              hintText: '••••••••',
              errorText: errorText,
              prefixIcon: const Icon(Icons.lock_outline_rounded),
              suffixIcon: IconButton(
                onPressed: onTogglePassword,
                icon: Icon(
                  obscurePassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Contacta con administración para recuperar tu acceso.',
                ),
              ),
            ),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              alignment: Alignment.centerLeft,
              foregroundColor: theme.colorScheme.primary,
            ),
            child: const Text(
              '¿Olvidaste tu contraseña?',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 48,
            child: FilledButton(
              onPressed: loading ? null : onSubmit,
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.onPrimary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
              child: loading
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: theme.colorScheme.onPrimary,
                        strokeWidth: 2.4,
                      ),
                    )
                  : const Text(
                      'Iniciar sesión  →',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: Theme.of(context).textTheme.bodyLarge?.color,
    ),
  );
}
