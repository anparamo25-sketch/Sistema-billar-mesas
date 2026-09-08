from pathlib import Path

p = Path('/tmp/billar_app/lib/main.dart')
s = p.read_text()

# El arranque debe ser lo mas simple posible en Android antiguos y equipos con 3 GB RAM.
s = s.replace("import 'package:url_launcher/url_launcher.dart';\n", "")
s = s.replace("  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);\n", "")
s = s.replace("      Future.delayed(const Duration(seconds: 2), _checkForUpdates);\n", "")
s = s.replace("    Future.delayed(const Duration(seconds: 2), _checkForUpdates);\n", "")

# Evitar cualquier comprobacion de actualizacion durante el arranque.
import re
s = re.sub(r"\n\s*Future<void> _checkForUpdates\(\) async \{.*?\n\s*\}\n\n", "\n", s, flags=re.S)
s = re.sub(r"\n\s*IconButton\(tooltip: 'Actualizar'.*?\),", "", s)

# Valores oficiales tambien en el codigo fuente base.
s = s.replace("const List<double> defaultRates = [100, 100, 100, 100, 70];", "const List<double> defaultRates = [120, 120, 100, 100, 70];")

p.write_text(s)
print('Estabilidad de arranque aplicada.')
