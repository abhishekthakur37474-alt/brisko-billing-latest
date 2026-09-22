import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../app/shell/pos_shell.dart';
import '../controllers/auth_controller.dart';
import '../screens/login_screen.dart';

/// Chooses between the login screen and the till, based on the sign-in state.
///
/// The application's entry point. It shows the [PosShell] when the terminal is
/// authenticated — or when the build has no cloud at all, in which case there is nothing
/// to sign in to and the till opens straight away — and the [LoginScreen] otherwise.
///
/// The decision is on the *presence* of a session, not on reachability. A terminal that
/// signed in yesterday and starts today with the internet down is still authenticated: it
/// opens the till and works offline, and synchronisation resumes on its own when the link
/// returns. Sign-in is only ever required when there is no session to begin with.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final bool authenticated = context.select<AuthController, bool>(
      (AuthController controller) => controller.isAuthenticated,
    );
    return authenticated ? const PosShell() : const LoginScreen();
  }
}
