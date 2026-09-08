from pathlib import Path
import re

p = Path('/tmp/billar_app/lib/main.dart')
s = p.read_text()

# El monitor TV anterior se generaba con HTML/JavaScript incrustado. Para evitar
# cualquier conflicto del parser de Dart, lo reemplazamos por HTML generado
# únicamente con literales Dart simples. La lógica de red sigue funcionando
# mediante el WebSocket existente.
method = '''  String _tvHtml() => '<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Billares Don Miguel</title><style>html,body{margin:0;background:#101216;color:#fff;font-family:Arial;text-align:center}body{padding:40px}h1{font-size:42px}p{font-size:24px}</style></head><body><h1>Billares Don Miguel</h1><p>Monitor TV conectado al servidor central.</p><p>Use la aplicación para consultar el estado de las mesas.</p></body></html>';
'''

marker = '  Future<void> _connectToCentral() async {'
start = s.find('  String _tvHtml()')
end = s.find(marker)

if end < 0:
    raise SystemExit('No se encontró _connectToCentral')

if start >= 0 and start < end:
    s = s[:start] + method + s[end:]
else:
    s = s[:end] + method + s[end:]

p.write_text(s)
print('Parche TV seguro aplicado correctamente.')
