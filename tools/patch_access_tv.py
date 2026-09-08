from pathlib import Path

p = Path('/tmp/billar_app/lib/main.dart')
s = p.read_text()

# Solo CENTRAL/administrador.
s = s.replace("  String mode = '';", "  String mode = 'central';")
s = s.replace("    mode = prefs!.getString('mode') ?? '';", "    mode = 'central';")
s = s.replace("    tableId = (prefs!.getInt('tableId') ?? 1).clamp(1, tableCount);", "    tableId = 1;")
s = s.replace("    if (mode == 'central') {\n      await _startServer();\n    } else if (mode == 'table' && centralIp.isNotEmpty) {\n      _connectToCentral();\n    }", "    await _startServer();")
s = s.replace("    return mode == 'central' ? _centralView() : _tableView();", "    return _centralView();")

# Pantalla exclusiva de mesas para un monitor externo/TV. No usa navegador ni URL.
if "static const MethodChannel _tvChannel" not in s:
    marker = "class _HomePageState extends State<HomePage> {"
    helper = '''class _HomePageState extends State<HomePage> {\n  static const MethodChannel _tvChannel = MethodChannel('billar_control/tv');\n\n  Future<void> _showTvConnection() async {\n    try {\n      final result = await _tvChannel.invokeMethod('startTv');\n      if (!mounted) return;\n      final text = result == 'connected'\n          ? 'La pantalla de mesas ya se está mostrando en el televisor.'\n          : 'No se encontró una pantalla externa. Conecta la tablet al televisor mediante HDMI o activa la función de duplicación/pantalla inalámbrica del televisor.';\n      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));\n      await _updateTvDisplay();\n    } on PlatformException catch (e) {\n      if (!mounted) return;\n      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo enlazar el televisor: ${e.message ?? 'error'}')));\n    }\n  }\n\n  Future<void> _updateTvDisplay() async {\n    try {\n      final data = games.map((g) => {\n        'tableId': g.tableId,\n        'active': g.active,\n        'startedAt': g.startedAt?.toIso8601String(),\n        'finishedAt': g.finishedAt?.toIso8601String(),\n        'rate': g.rate,\n        'total': g.total,\n      }).toList();\n      await _tvChannel.invokeMethod('updateTv', {'tables': jsonEncode(data)});\n    } catch (_) {}\n  }\n\n'''
    if marker in s:
        s = s.replace(marker, helper, 1)

# Enviar el estado de las mesas al monitor externo cada segundo.
old = "      if (mode == 'central') {\n        _updateLiveTotals();\n        _persist();\n        for (int i = 1; i <= tableCount; i++) {\n          _broadcast(i);\n        }\n      }"
new = "      if (mode == 'central') {\n        _updateLiveTotals();\n        _persist();\n        for (int i = 1; i <= tableCount; i++) {\n          _broadcast(i);\n        }\n        _updateTvDisplay();\n      }"
s = s.replace(old, new, 1)

# Inserta el botón en la barra superior de CENTRAL.
if "tooltip: 'Enlazar TV'" not in s:
    appbar = s.find('AppBar(')
    if appbar >= 0:
        actions = s.find('actions: [', appbar)
        if actions >= 0:
            s = s[:actions] + "actions: [\n              IconButton(tooltip: 'Enlazar TV', icon: const Icon(Icons.tv), onPressed: _showTvConnection),\n" + s[actions + len('actions: ['):]

# Pantalla de acceso exclusiva del administrador.
setup = s.find('class SetupScreen extends StatefulWidget {')
if setup >= 0:
    s = s[:setup]
    s += """class SetupScreen extends StatefulWidget {
  final Future<void> Function(String, int, String, String) onSaved;
  const SetupScreen({super.key, required this.onSaved});
  @override State<SetupScreen> createState() => _SetupScreenState();
}
class _SetupScreenState extends State<SetupScreen> {
  final pin = TextEditingController(); bool obscure = true;
  @override void dispose() { pin.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => Scaffold(body: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Card(child: Padding(padding: const EdgeInsets.all(24), child: Column(children: [
    const Icon(Icons.admin_panel_settings, size: 70), const SizedBox(height: 10),
    const Text('Billares Don Miguel', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
    const SizedBox(height: 8), const Text('Acceso exclusivo del administrador'), const SizedBox(height: 22),
    TextField(controller: pin, obscureText: obscure, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: 'Contraseña del administrador', hintText: 'Escríbala manualmente', border: const OutlineInputBorder(), suffixIcon: IconButton(onPressed: () => setState(() => obscure = !obscure), icon: Icon(obscure ? Icons.visibility : Icons.visibility_off)))),
    const SizedBox(height: 20), SizedBox(width: double.infinity, child: FilledButton(onPressed: () async { final v = pin.text.trim(); if (v.isEmpty) return; await widget.onSaved('central', 1, '', v); }, child: const Text('Entrar como administrador'))),
  ])))));
}
"""

p.write_text(s)
print('Acceso administrador y TV externa por segunda pantalla aplicados.')
