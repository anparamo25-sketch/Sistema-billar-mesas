from pathlib import Path

# Correcciones de compatibilidad para Flutter 3.24.5 / Dart 3.5.
p = Path('/tmp/billar_app/lib/main.dart')
s = p.read_text()

# clamp() devuelve num; tableId necesita int.
old = "tableId = (prefs!.getInt('tableId') ?? 1).clamp(1, tableCount);"
new = "tableId = (prefs!.getInt('tableId') ?? 1).clamp(1, tableCount).toInt();"
if old in s:
    s = s.replace(old, new, 1)

p.write_text(s)
print('Correcciones de compatibilidad Dart aplicadas')
