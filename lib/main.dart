import 'package:flutter/material.dart';

import 'screens/connections_screen.dart';
import 'screens/console_screen.dart';
import 'screens/sync_screen.dart';
import 'screens/templates_screen.dart';
import 'store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppStore.instance.load();
  runApp(const SqlSnapApp());
}

class SqlSnapApp extends StatelessWidget {
  const SqlSnapApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF2E6BE6);
    return MaterialApp(
      title: 'SQL Snap',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: seed,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    const pages = [
      TemplatesScreen(),
      ConsoleScreen(),
      ConnectionsScreen(),
      SyncScreen(),
    ];
    return Scaffold(
      body: IndexedStack(index: _tab, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.bookmarks_outlined), selectedIcon: Icon(Icons.bookmarks), label: 'Шаблоны'),
          NavigationDestination(icon: Icon(Icons.terminal_outlined), selectedIcon: Icon(Icons.terminal), label: 'SQL'),
          NavigationDestination(icon: Icon(Icons.storage_outlined), selectedIcon: Icon(Icons.storage), label: 'Базы'),
          NavigationDestination(icon: Icon(Icons.sync_outlined), selectedIcon: Icon(Icons.sync), label: 'Синхр.'),
        ],
      ),
    );
  }
}
