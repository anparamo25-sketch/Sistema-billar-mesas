from pathlib import Path
import re

p = Path('/tmp/billar_app/lib/main.dart')
s = p.read_text()

# La aplicación instalada solo funciona como CENTRAL/administrador.
s = s.replace("  String mode = '';", "  String mode = 'central';")
s = s.replace("    mode = prefs!.getString('mode') ?? '';", "    mode = 'central';")
s = s.replace("    tableId = (prefs!.getInt('tableId') ?? 1).clamp(1, tableCount);", "    tableId = 1;")
s = s.replace("    if (mode == 'central') {\n      await _startServer();\n    } else if (mode == 'table' && centralIp.isNotEmpty) {\n      _connectToCentral();\n    }", "    await _startServer();")
s = s.replace("    return mode == 'central' ? _centralView() : _tableView();", "    return _centralView();")

# Eliminar por completo la antigua pantalla que permitía escoger CENTRAL/MESA.
setup = s.find('class SetupScreen extends StatefulWidget {')
if setup >= 0:
    s = s[:setup]
    s += """class SetupScreen extends StatefulWidget {
  final Future<void> Function(String, int, String, String) onSaved;
  const SetupScreen({super.key, required this.onSaved});
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final pin = TextEditingController();
  bool obscure = true;

  @override
  void dispose() { pin.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 550),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const Icon(Icons.admin_panel_settings, size: 70),
                    const SizedBox(height: 10),
                    const Text('Billares Don Miguel', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    const Text('Acceso exclusivo del administrador', textAlign: TextAlign.center),
                    const SizedBox(height: 22),
                    TextField(
                      controller: pin,
                      obscureText: obscure,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: 'Contraseña del administrador',
                        hintText: 'Escríbala manualmente',
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          onPressed: () => setState(() => obscure = !obscure),
                          icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text('La contraseña no se muestra ni se autocompleta. Por defecto es 1234.', textAlign: TextAlign.center),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () async {
                          final value = pin.text.trim();
                          if (value.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Escriba la contraseña del administrador.')));
                            return;
                          }
                          await widget.onSaved('central', 1, '', value);
                        },
                        child: const Text('Entrar como administrador'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
"""

# Sustituir el monitor TV por HTML sencillo, evitando comillas Dart problemáticas.
tv_start = s.find('  String _tvHtml() =>')
if tv_start >= 0:
    tv_end = s.find('  Future<void> _connectToCentral() async {', tv_start)
    if tv_end >= 0:
        tv = '''  String _tvHtml() => """<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Billares Don Miguel</title><style>
html,body{margin:0;width:100%;height:100%;background:#111;color:#fff;font-family:Arial,sans-serif}body{display:flex;flex-direction:column}header{text-align:center;padding:12px;background:#191919}h1{margin:0;font-size:40px}.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:12px;padding:12px}.card{border-radius:16px;padding:18px;min-height:180px}.ok{background:#176b3a}.play{background:#a62029}.name{font-size:30px;font-weight:bold}.state{font-size:23px;margin:8px 0}.info{font-size:20px;margin:5px 0}.total{font-size:24px;font-weight:bold;margin-top:8px}@media(max-width:900px){.grid{grid-template-columns:repeat(2,1fr)}}
</style></head><body><header><h1>Billares Don Miguel</h1><div id="clock"></div></header><main id="grid" class="grid"></main><script>
const grid=document.getElementById('grid');
function money(v){return 'C$'+Number(v||0).toFixed(0)}
function time(v){return v?new Date(v).toLocaleTimeString('es-NI',{hour:'2-digit',minute:'2-digit',hour12:true}):'--'}
function render(d){const t=d.tables||[];grid.innerHTML=t.map(g=>{const active=!!g.active;return '<section class="card '+(active?'play':'ok')+'"><div class="name">Mesa '+g.tableId+'</div><div class="state">'+(active?'EN JUEGO':'DISPONIBLE')+'</div>'+(active?'<div class="info">Inicio: '+time(g.startedAt)+'</div><div class="info">Tarifa: '+money(g.rate)+'/hora</div><div class="total">Monto: '+money(g.total)+'</div>':'')+'</section>'}).join('')}
function connect(){const ws=new WebSocket('ws://'+location.host);ws.onopen=()=>ws.send(JSON.stringify({type:'register',role:'tv'}));ws.onmessage=e=>{try{const d=JSON.parse(e.data);if(d.type==='tv_state')render(d)}catch(_){}};ws.onclose=()=>setTimeout(connect,1500)}
setInterval(()=>document.getElementById('clock').textContent=new Date().toLocaleString('es-NI',{dateStyle:'medium',timeStyle:'medium'}),1000);connect();
</script></body></html>""";
'''
        s = s[:tv_start] + tv + s[tv_end:]

p.write_text(s)
print('Acceso corregido: solo administrador/CENTRAL; mesas únicamente en TV.')
