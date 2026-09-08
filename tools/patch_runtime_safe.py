from pathlib import Path
import re

p = Path('/tmp/billar_app/lib/main.dart')
s = p.read_text()

# El arranque de Flutter debe ser lo mas simple posible. No se ejecutan
# plugins ni configuraciones del sistema antes de que exista la primera vista.
s = re.sub(
    r"void main\(\) async \{.*?\n\}",
    "void main() {\n  WidgetsFlutterBinding.ensureInitialized();\n  runApp(const BillarApp());\n}",
    s,
    count=1,
    flags=re.S,
)

# Evita que una excepcion de SharedPreferences, red o datos guardados cierre
# la aplicacion durante el primer arranque. La interfaz siempre queda visible.
start = s.find('  Future<void> _load() async {')
if start >= 0:
    end = s.find('\n  String _dayKey(', start)
    if end > start:
        safe_load = '''  Future<void> _load() async {
    try {
      prefs = await SharedPreferences.getInstance();
      adminPin = prefs!.getString('adminPin') ?? defaultAdminPin;
      currentDay = prefs!.getString('currentDay') ?? _dayKey(DateTime.now());
      dailyTotal = prefs!.getDouble('dailyTotal') ?? 0;

      final savedGames = prefs!.getStringList('games') ?? [];
      if (savedGames.length == tableCount) {
        for (int i = 0; i < tableCount; i++) {
          try {
            games[i] = Game.fromJson(jsonDecode(savedGames[i]));
          } catch (_) {}
        }
      }
      final savedHistory = prefs!.getStringList('history') ?? [];
      history.clear();
      for (final raw in savedHistory) {
        try {
          history.add(Game.fromJson(jsonDecode(raw)));
        } catch (_) {}
      }

      // Las tarifas son fijas y nunca se recuperan de datos antiguos.
      for (int i = 0; i < tableCount; i++) {
        games[i].rate = defaultRates[i];
      }

      if (currentDay != _dayKey(DateTime.now())) {
        currentDay = _dayKey(DateTime.now());
        dailyTotal = 0;
        await _persist();
      }
    } catch (_) {
      // Si el almacenamiento falla, se continua con valores limpios.
      prefs = null;
      currentDay = _dayKey(DateTime.now());
      dailyTotal = 0;
      for (int i = 0; i < tableCount; i++) {
        games[i] = Game(tableId: i + 1, rate: defaultRates[i]);
      }
    }

    if (!mounted) return;
    setState(() {
      loading = false;
      mode = 'central';
      status = 'Iniciando CENTRAL...';
    });

    // El servidor y el temporizador se inician despues de mostrar la UI.
    try {
      await _startServer();
    } catch (_) {
      if (mounted) setState(() => status = 'CENTRAL lista');
    }

    ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      try {
        _updateLiveTotals();
        _persist();
        for (int i = 1; i <= tableCount; i++) {
          _broadcast(i);
        }
        _updateTvDisplay();
      } catch (_) {}
      setState(() {});
    });
  }
'''
        s = s[:start] + safe_load + s[end:]

# Persistencia defensiva: un fallo de almacenamiento nunca debe tumbar la UI.
s = s.replace(
    "  Future<void> _persist() async {\n    final p = prefs ?? await SharedPreferences.getInstance();",
    "  Future<void> _persist() async {\n    try {\n      final p = prefs ?? await SharedPreferences.getInstance();\n      prefs ??= p;",
    1,
)
# Cierra el try/catch al final de _persist, justo antes de _updateLiveTotals.
marker = "  void _updateLiveTotals() {"
if marker in s and "} catch (_) {}\n\n" not in s[:s.find(marker)]:
    pos = s.find(marker)
    # Encontrar el ultimo cierre de _persist antes del marcador.
    s = s[:pos].rstrip() + "\n    } catch (_) {}\n  }\n\n" + s[pos:]

p.write_text(s)
print('Arranque y persistencia blindados para evitar cierres inmediatos.')
