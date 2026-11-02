import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/auth_provider.dart';

/// Blocks a screen behind authentication.
///
/// While the auth state is still loading it shows a spinner; if the user is
/// not signed in it replaces the route with the login screen.
class ProtectedRoute extends StatelessWidget {
  final Widget child;
  final List<String>? allowedRoles;

  const ProtectedRoute({super.key, required this.child, this.allowedRoles});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    if (auth.isLoading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (!auth.isAuthenticated) {
      // Replace so the back button cannot return to the protected screen.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        final nav = Navigator.of(context);
        if (nav.canPop()) {
          nav.pop();
        } else {
          nav.pushReplacementNamed('/login');
        }
      });
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    final role = auth.user?.role;
    if (allowedRoles != null &&
        allowedRoles!.isNotEmpty &&
        role != null &&
        !allowedRoles!.contains(role)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        Navigator.of(context).pushReplacementNamed('/use-app');
      });
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return child;
  }
}
