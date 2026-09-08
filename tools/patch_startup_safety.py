from pathlib import Path

p = Path('/tmp/billar_app/lib/main.dart')
s = p.read_text()
old = "void main() async {\n  WidgetsFlutterBinding.ensureInitialized();\n  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);\n  runApp(const BillarApp());\n}"
new = "void main() async {\n  WidgetsFlutterBinding.ensureInitialized();\n  try {\n    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);\n  } catch (_) {}\n  runApp(const BillarApp());\n}"
if old in s:
    s = s.replace(old, new, 1)
p.write_text(s)
print('Arranque blindado contra fallos del modo inmersivo.')
