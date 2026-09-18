import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/cloud_auth.dart';
import '../state/auth.dart';
import '../state/settings.dart';
import '../widgets/ui.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  /// 0 = Manager (cloud shop account), 1 = Staff (this device's till
  /// account, created by the Manager).
  int _tab = 0;
  final _managerName = TextEditingController();
  final _managerEmail = TextEditingController();
  final _managerPass = TextEditingController();
  bool _managerObscure = true;
  bool _managerBusy = false;
  String? _managerError;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _managerName.dispose();
    _managerEmail.dispose();
    _managerPass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await context.read<AuthProvider>().login(
          _email.text,
          _password.text,
        );
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
    // On success AuthProvider notifies and _Root swaps to HomeShell.
  }

  Future<void> _managerSubmit({required bool create}) async {
    final email = _managerEmail.text.trim();
    final pass = _managerPass.text;
    setState(() => _managerError = null);
    if (!email.contains('@')) {
      setState(() => _managerError = 'Enter a valid email.');
      return;
    }
    if (pass.length < 6) {
      setState(() => _managerError = 'Password must be at least 6 characters.');
      return;
    }
    if (create && _managerName.text.trim().isEmpty) {
      setState(() => _managerError = 'Enter your shop name to create a new shop.');
      return;
    }
    setState(() => _managerBusy = true);
    final err = create
        ? await CloudAuth.signUp(
            email: email,
            password: pass,
            name: _managerName.text,
            shopName: _managerName.text,
          )
        : await CloudAuth.signIn(email: email, password: pass);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _managerBusy = false;
        _managerError = err == 'confirm'
            ? 'Account created! Check your email for a confirmation link, '
                'then sign in here.'
            : err;
      });
    }
    // On success CloudAuth opens the local session; _Root swaps to HomeShell.
  }

  void _toggleObscure() => setState(() => _obscure = !_obscure);

  void _toggleManagerObscure() =>
      setState(() => _managerObscure = !_managerObscure);

  /// Public so the stateless form widgets can switch the tab safely.
  void switchTab(int t) => setState(() => _tab = t);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= 880 && c.maxHeight >= 560;
        if (wide) {
          return Center(
            child: Container(
              width: 920,
              height: 580,
              margin: const EdgeInsets.all(AppSpace.s6),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppRadius.xl), // M3 extra-large
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x14101828),
                    blurRadius: 40,
                    offset: Offset(0, 18),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Row(
                children: [
                  const Expanded(child: _BrandPane()),
                  SizedBox(width: 460, child: _LoginForm(this)),
                ],
              ),
            ),
          );
        }
        return SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _LogoBadge(size: 64, iconSize: 32),
                    const SizedBox(height: 12),
                    _LoginForm(this, compactHeader: true),
                  ],
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

/// Left brand panel (wide layout).
class _BrandPane extends StatelessWidget {
  const _BrandPane();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF4338CA), Color(0xFF4F46E5), Color(0xFF6D28D9)],
        ),
      ),
      padding: const EdgeInsets.all(AppSpace.s10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: const Icon(Icons.storefront_rounded, color: Colors.white, size: 24),
              ),
              const SizedBox(width: AppSpace.s3),
              const Text(
                'StylePOS',
                style: TextStyle(
                  fontFamily: 'Carlito',
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
          const Spacer(),
          const Text(
            'Run your shop\nlike a pro.',
            style: TextStyle(
              fontFamily: 'Carlito',
              fontSize: 32, // M3 headlineLarge
              height: 1.15,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: AppSpace.s4),
          Text(
            'Fast checkout, live stock levels and clear reports —\nyour shop in your pocket, synced to every device.',
            style: TextStyle(
              fontFamily: 'Carlito',
              fontSize: 14.5,
              height: 1.45,
              color: Colors.white.withValues(alpha: 0.82),
            ),
          ),
          const Spacer(),
          const _FeatureRow(Icons.bolt_rounded, 'Scan & sell in seconds',
              'Barcode scanner ready, keyboard friendly'),
          const SizedBox(height: AppSpace.s4),
          const _FeatureRow(Icons.sync_rounded, 'Every device, one shop',
              'Phone, PC and web share the same live data'),
          const SizedBox(height: AppSpace.s4),
          const _FeatureRow(Icons.insights_rounded, 'Reports that matter',
              'Revenue, best sellers and category share'),
        ],
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _FeatureRow(this.icon, this.title, this.subtitle);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Icon(icon, size: 19, color: Colors.white),
        ),
        const SizedBox(width: AppSpace.s3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontFamily: 'Carlito',
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Colors.white)),
              Text(subtitle,
                  style: TextStyle(
                      fontFamily: 'Carlito',
                      fontSize: 12.5,
                      color: Colors.white.withValues(alpha: 0.75))),
            ],
          ),
        ),
      ],
    );
  }
}

class _LogoBadge extends StatelessWidget {
  final double size;
  final double iconSize;

  const _LogoBadge({required this.size, required this.iconSize});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF4F46E5), Color(0xFF6D28D9)],
        ),
        borderRadius: BorderRadius.circular(AppRadius.lg), // M3 large
        boxShadow: const [BoxShadow(color: Color(0x294F46E5), blurRadius: 18, offset: Offset(0, 8))],
      ),
      child: Icon(Icons.storefront_rounded, color: Colors.white, size: iconSize),
    );
  }
}

/// Right-hand sign-in form (shared by both layouts).
class _LoginForm extends StatelessWidget {
  final _LoginScreenState state;
  final bool compactHeader;

  const _LoginForm(this.state, {this.compactHeader = false});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.symmetric(
          horizontal: compactHeader ? 0 : AppSpace.s10,
          vertical: compactHeader ? 0 : AppSpace.s8),
      child: Form(
        key: state._formKey,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (compactHeader) ...[
              Text(
                settings.shopName,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: AppSpace.s1),
              const Text(
                'Sign in to continue',
                textAlign: TextAlign.center,
                style: TextStyle(fontFamily: 'Carlito', fontSize: 13.5, color: AppColors.muted),
              ),
              const SizedBox(height: AppSpace.s5),
            ] else ...[
              Text('Welcome back', style: theme.textTheme.headlineSmall),
              const SizedBox(height: AppSpace.s2),
              Text(
                'Sign in to ${settings.shopName} to open the register.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpace.s5),
            ],
            SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: 0,
                  label: Text('Manager'),
                  icon: Icon(Icons.admin_panel_settings_outlined, size: 18),
                ),
                ButtonSegment(
                  value: 1,
                  label: Text('Staff'),
                  icon: Icon(Icons.badge_outlined, size: 18),
                ),
              ],
              selected: {state._tab},
              onSelectionChanged: (s) => state.switchTab(s.first),
            ),
            const SizedBox(height: AppSpace.s5),
            if (state._tab == 0)
              _ManagerFields(state: state)
            else
              _StaffFields(state: state),
          ],
        ),
      ),
    );
  }
}

/// Staff (offline till) sign-in — local account created by the Manager.
class _StaffFields extends StatelessWidget {
  final _LoginScreenState state;
  const _StaffFields({required this.state});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: state._email,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Email',
            prefixIcon: Icon(Icons.alternate_email_rounded, size: 20),
          ),
          validator: (v) =>
              (v == null || !v.contains('@')) ? 'Enter a valid email' : null,
        ),
        const SizedBox(height: AppSpace.s4),
        TextFormField(
          controller: state._password,
          obscureText: state._obscure,
          autofocus: true,
          onFieldSubmitted: (_) => state._submit(),
          decoration: InputDecoration(
            labelText: 'Password',
            prefixIcon: const Icon(Icons.lock_outline_rounded, size: 20),
            suffixIcon: IconButton(
              icon: Icon(state._obscure
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined),
              onPressed: state._toggleObscure,
            ),
          ),
          validator: (v) =>
              (v == null || v.isEmpty) ? 'Enter your password' : null,
        ),
        if (state._error != null) ...[
          const SizedBox(height: AppSpace.s4),
          _ErrorBox(text: state._error!),
        ],
        const SizedBox(height: 20),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
          onPressed: state._busy ? null : state._submit,
          child: state._busy
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('Sign in'),
        ),
        const SizedBox(height: AppSpace.s4),
        Container(
          padding: const EdgeInsets.all(AppSpace.s3),
          decoration: BoxDecoration(
            color: AppColors.surfaceTint,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(color: AppColors.borderSoft),
          ),
          child: Row(
            children: [
              const Icon(Icons.info_outline_rounded, size: 16, color: AppColors.faint),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Staff accounts are created by your Manager '
                  '(Settings → Staff accounts) and work offline on this '
                  'device. Managers: use the Manager tab.',
                  style: TextStyle(
                      fontFamily: 'Carlito', fontSize: 12, color: AppColors.muted, height: 1.35),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Manager tab — the cloud shop account. Sign in on any device to open
/// the same shop; "Create shop account" starts a NEW shop (first account
/// becomes the Manager).
class _ManagerFields extends StatelessWidget {
  final _LoginScreenState state;
  const _ManagerFields({required this.state});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: state._managerName,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Shop name (when creating a new shop)',
            prefixIcon: Icon(Icons.storefront_outlined, size: 20),
          ),
        ),
        const SizedBox(height: AppSpace.s4),
        TextField(
          controller: state._managerEmail,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Email',
            prefixIcon: Icon(Icons.alternate_email_rounded, size: 20),
          ),
        ),
        const SizedBox(height: AppSpace.s4),
        TextField(
          controller: state._managerPass,
          obscureText: state._managerObscure,
          onSubmitted: (_) => state._managerSubmit(create: false),
          decoration: InputDecoration(
            labelText: 'Password',
            prefixIcon: const Icon(Icons.lock_outline_rounded, size: 20),
            suffixIcon: IconButton(
              icon: Icon(state._managerObscure
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined),
              onPressed: state._toggleManagerObscure,
            ),
          ),
        ),
        if (state._managerError != null) ...[
          const SizedBox(height: AppSpace.s4),
          _ErrorBox(text: state._managerError!),
        ],
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: state._managerBusy
                    ? null
                    : () => state._managerSubmit(create: false),
                child: const Text('Sign in'),
              ),
            ),
            const SizedBox(width: AppSpace.s3),
            Expanded(
              flex: 2,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: state._managerBusy
                    ? null
                    : () => state._managerSubmit(create: true),
                icon: const Icon(Icons.add_business_rounded, size: 18),
                label: const Text('Create shop account'),
              ),
            ),
          ],
        ),
        if (state._managerBusy) ...[
          const SizedBox(height: AppSpace.s3),
          const LinearProgressIndicator(),
        ],
        const SizedBox(height: AppSpace.s4),
        Container(
          padding: const EdgeInsets.all(AppSpace.s3),
          decoration: BoxDecoration(
            color: AppColors.surfaceTint,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(color: AppColors.borderSoft),
          ),
          child: Row(
            children: [
              const Icon(Icons.admin_panel_settings_outlined, size: 16, color: AppColors.faint),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'The cloud account IS the Manager account. New shop? '
                  'Create one — you become the Manager and can add staff '
                  'accounts from Settings. Same account on another phone, '
                  'the PC or the web shows ONLY this shop\'s data.',
                  style: TextStyle(
                      fontFamily: 'Carlito', fontSize: 12, color: AppColors.muted, height: 1.35),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final String text;
  const _ErrorBox({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpace.s3),
      decoration: BoxDecoration(
        color: AppColors.dangerSoft,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, size: 18, color: AppColors.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                  fontFamily: 'Carlito', fontSize: 13, color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }
}
