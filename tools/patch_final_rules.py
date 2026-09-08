from pathlib import Path
import re

p = Path('/tmp/billar_app/lib/main.dart')
s = p.read_text()

s = re.sub(
    r"const List<double> defaultRates = \[[^\]]*\];",
    "const List<double> defaultRates = [120, 120, 100, 100, 70];",
    s,
    count=1,
)

marker = "    final savedHistory = prefs!.getStringList('history') ?? [];"
insert = "    for (int i = 0; i < tableCount; i++) {\n      games[i].rate = defaultRates[i];\n    }\n\n"
if marker in s and insert not in s:
    s = s.replace(marker, insert + marker, 1)

pattern = re.compile(r"  Future<void> _changeRate\(int id\) async \{.*?\n  \}\n\n  Future<bool> _confirm", re.S)
replacement = "  Future<void> _changeRate(int id) async {\n    if (!mounted) return;\n    ScaffoldMessenger.of(context).showSnackBar(\n      const SnackBar(content: Text('Las tarifas oficiales no se pueden modificar.')),\n    );\n  }\n\n  Future<bool> _confirm"
s, _ = pattern.subn(replacement, s, count=1)

s = s.replace(
    "final rate = games[id - 1].rate;\n    setState(() => games[id - 1] = Game(tableId: id, rate: rate));",
    "setState(() => games[id - 1] = Game(tableId: id, rate: defaultRates[id - 1]));",
)

p.write_text(s)
print('Reglas finales aplicadas: tarifas oficiales y migracion de tarifas antiguas.')
