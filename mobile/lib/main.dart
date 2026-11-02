import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/theme.dart';
import 'screens/login_screen.dart';
import 'screens/police_stations_screen.dart';
import 'screens/register_screen.dart';
import 'screens/splash_screen.dart';
import 'screens/user_dashboard_screen.dart';
import 'services/voice_guard_service.dart';
import 'state/auth_provider.dart';
import 'state/contacts_provider.dart';
import 'state/police_stations_provider.dart';
import 'state/sos_controller.dart';
import 'widgets/protected_route.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await VoiceGuardService.flog('main-boot', 'main() entered, calling initialize');
  try {
    await VoiceGuardService.initialize()
        .timeout(const Duration(seconds: 20), onTimeout: () {
      throw StateError('VoiceGuardService.initialize() timed out after 20s');
    });
  } catch (e) {
    await VoiceGuardService.flog('main-boot', 'initialize FAILED (app continues): $e');
  }
  await VoiceGuardService.flog('main-boot', 'initialize done, runApp now');
  runApp(const ZeldApp());
}

class ZeldApp extends StatelessWidget {
  const ZeldApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => ContactsProvider()),
        ChangeNotifierProvider(create: (_) => SosController()),
        ChangeNotifierProvider(create: (_) => PoliceStationsProvider()),
      ],
      child: MaterialApp(
        title: 'ZELDA - Women Safety Guardian',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        home: const SplashScreen(),
        routes: {
          '/login': (_) => const LoginScreen(),
          '/register': (_) => const RegisterScreen(),
          '/dashboard': (_) => const UserDashboardScreen(),
          // The police-station directory is for signed-in users only.
          '/police-stations': (_) => ProtectedRoute(
                child: const PoliceStationsScreen(),
              ),
        },
      ),
    );
  }
}
