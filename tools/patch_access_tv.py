from pathlib import Path

p = Path('/tmp/billar_app/lib/main.dart')
s = p.read_text()

# Solo CENTRAL/administrador.
s = s.replace("  String mode = '';", "  String mode = 'central';")
s = s.replace("    mode = prefs!.getString('mode') ?? '';", "    mode = 'central';")
s = s.replace("    tableId = (prefs!.getInt('tableId') ?? 1).clamp(1, tableCount);", "    tableId = 1;")
s = s.replace("    if (mode == 'central') {\n      await _startServer();\n    } else if (mode == 'table' && centralIp.isNotEmpty) {\n      _connectToCentral();\n    }", "    await _startServer();")
s = s.replace("    return mode == 'central' ? _centralView() : _tableView();", "    return _centralView();")

# Botón TV visible en la barra superior de CENTRAL.
if "tooltip: 'Enlazar TV'" not in s:
    marker = "  Future<void> _connectToCentral() async {"
    helper = '''  Future<void> _showTvConnection() async {\n    final ip = await _localIp();\n    if (!mounted) return;\n    final address = ip.isEmpty ? 'No se pudo obtener la IP de la CENTRAL.' : 'http://$ip:$serverPort/tv';\n    await showDialog<void>(context: context, builder: (ctx) => AlertDialog(\n      title: const Text('Enlazar monitor TV'),\n      content: SelectableText(address, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),\n      actions: [\n        TextButton(onPressed: () async { await Clipboard.setData(ClipboardData(text: address)); if (ctx.mounted) Navigator.pop(ctx); }, child: const Text('Copiar dirección')),\n        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar')),\n      ],\n    ));\n  }\n\n'''
    if marker in s:
        s = s.replace(marker, helper + marker, 1)

    # Inserta los botones en el primer AppBar de la CENTRAL.
    appbar = s.find('AppBar(')
    if appbar >= 0:
        actions = s.find('actions: [', appbar)
        if actions >= 0:
            s = s[:actions] + '''actions: [\n              IconButton(tooltip: 'Enlazar TV', icon: const Icon(Icons.tv), onPressed: _showTvConnection),\n''' + s[actions + len('actions: ['):]

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
print('Acceso administrador y botón TV aplicados.')
