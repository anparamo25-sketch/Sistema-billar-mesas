from pathlib import Path
import re

p = Path('/tmp/billar_app/lib/main.dart')
s = p.read_text()

# Tarifas oficiales, únicas y permanentes.
s = re.sub(r"const List<double> defaultRates = \[[^\]]*\];", "const List<double> defaultRates = [120, 120, 100, 100, 70];", s, count=1)

# Nunca conservar una tarifa antigua guardada en el dispositivo.
marker = "    final savedGames = prefs!.getStringList('games') ?? [];"
force = "    for (int i = 0; i < tableCount; i++) { games[i].rate = defaultRates[i]; }\n\n"
if marker in s and force not in s:
    s = s.replace(marker, force + marker, 1)

# Después de cargar datos antiguos, volver a imponer la tarifa oficial.
needle = "        } catch (_) {}\n      }\n    }"
replacement = "        } catch (_) {}\n        games[i].rate = defaultRates[i];\n      }\n    }"
if needle in s:
    s = s.replace(needle, replacement, 1)

# El método ya no puede modificar tarifas.
start = s.find("  Future<void> _changeRate(int id) async {")
if start >= 0:
    end = s.find("\n  Future<bool> _confirm(", start)
    if end >= 0:
        s = s[:start] + "  Future<void> _changeRate(int id) async {\n    if (!mounted) return;\n    ScaffoldMessenger.of(context).showSnackBar(\n      SnackBar(content: Text('Tarifa fija: C$ ${defaultRates[id - 1].toStringAsFixed(0)} por hora')),\n    );\n  }\n" + s[end:]

# Eliminar cualquier boton visible que llame a _changeRate.
s = re.sub(r"\s*OutlinedButton\(\s*onPressed: \(\) => _changeRate\(id\),\s*child: const Text\('Tarifa'\),\s*\),", "", s, flags=re.S)

# Reemplazar por completo la configuracion para que SOLO permita IP de CENTRAL.
setup_start = s.find("  Future<void> _setup() async {")
logout_start = s.find("\n  void _logout()", setup_start)
if setup_start >= 0 and logout_start > setup_start:
    setup = r'''  Future<void> _setup() async {
    if (!adminUnlocked) return;
    final ip = TextEditingController(text: centralIp);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Configuración CENTRAL'),
        content: SizedBox(
          width: 600,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('IP de la CENTRAL para las tablets y el monitor TV'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: ip,
                decoration: const InputDecoration(
                  labelText: 'IP central',
                  hintText: 'Ejemplo: 192.168.1.20',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Las tarifas oficiales están bloqueadas y no se pueden modificar.\nMesa 1 y 2: C$120/h • Mesa 3 y 4: C$100/h • Mesa 5: C$70/h',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ip.text.trim()), child: const Text('Guardar')),
        ],
      ),
    );
    ip.dispose();
    if (result == null) return;
    centralIp = result;
    for (int i = 0; i < tableCount; i++) { games[i].rate = defaultRates[i]; }
    await _persist();
    if (mode == 'table') await _connectToCentral();
    if (mounted) setState(() {});
  }
'''
    s = s[:setup_start] + setup + s[logout_start:]

# Nuevas partidas siempre nacen con su tarifa oficial.
s = re.sub(
    r"final rate = games\[id - 1\]\.rate;\s*setState\(\(\) => games\[id - 1\] = Game\(tableId: id, rate: rate\)\);",
    "setState(() => games[id - 1] = Game(tableId: id, rate: defaultRates[id - 1]));",
    s,
)

p.write_text(s)
print('Tarifas bloqueadas: eliminados controles de edicion y configuracion de precios.')
