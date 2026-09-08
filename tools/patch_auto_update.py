from pathlib import Path

p = Path('/tmp/billar_app/lib/main.dart')
s = p.read_text()

if "package:url_launcher/url_launcher.dart" not in s:
    s = s.replace("import 'package:shared_preferences/shared_preferences.dart';", "import 'package:shared_preferences/shared_preferences.dart';\nimport 'package:url_launcher/url_launcher.dart';")

if 'Future<void> _checkForUpdates' not in s:
    marker = "  Future<void> _connectToCentral() async {"
    code = '''  Future<void> _checkForUpdates() async {\n    try {\n      final client = HttpClient();\n      final request = await client.getUrl(Uri.parse('https://raw.githubusercontent.com/anparamo25-sketch/Sistema-billar-mesas/main/pubspec.yaml'));\n      final response = await request.close();\n      final body = await response.transform(const SystemEncoding().decoder).join();\n      client.close();\n      final match = RegExp(r'^version:\\s*([0-9]+\\.[0-9]+\\.[0-9]+)', multiLine: true).firstMatch(body);\n      const current = '2.1.0';\n      if (!mounted) return;\n      if (match != null && match.group(1) != current) {\n        final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(\n          title: const Text('Nueva actualización disponible'),\n          content: Text('Hay una nueva versión (${match.group(1)}). ¿Deseas descargarla?'),\n          actions: [\n            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Después')),\n            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Actualizar')),\n          ],\n        )) ?? false;\n        if (ok) {\n          await launchUrl(Uri.parse('https://github.com/anparamo25-sketch/Sistema-billar-mesas/releases/latest'), mode: LaunchMode.externalApplication);\n        }\n      }\n    } catch (_) {}\n  }\n\n'''
    if marker in s:
        s = s.replace(marker, code + marker, 1)

if 'onPressed: _checkForUpdates' not in s:
    appbar = s.find('AppBar(')
    if appbar >= 0:
        actions = s.find('actions: [', appbar)
        if actions >= 0:
            pos = actions + len('actions: [')
            button = "\n              IconButton(tooltip: 'Actualizar', icon: const Icon(Icons.system_update), onPressed: _checkForUpdates),"
            s = s[:pos] + button + s[pos:]

# Comprobar automáticamente al abrir la CENTRAL, una sola vez por arranque.
needle = "    await _startServer();"
if 'await _checkForUpdates();' not in s and needle in s:
    s = s.replace(needle, needle + "\n    Future.delayed(const Duration(seconds: 2), _checkForUpdates);", 1)

p.write_text(s)
print('Comprobador de actualizaciones agregado.')
