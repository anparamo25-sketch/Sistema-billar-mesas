from pathlib import Path
import re

p = Path('/tmp/billar_app/lib/main.dart')
s = p.read_text()

# Esta aplicación solo tiene un cliente: la CENTRAL/administrador.
# Las mesas no tienen pantalla de acceso ni modo operativo propio.
s = s.replace("  String mode = '';", "  String mode = 'central';")
s = s.replace("    mode = prefs!.getString('mode') ?? '';", "    mode = 'central';")
s = s.replace("    tableId = (prefs!.getInt('tableId') ?? 1).clamp(1, tableCount);", "    tableId = 1;")

# Nunca intentar conectar la app como una mesa.
s = s.replace("    if (mode == 'central') {\n      await _startServer();\n    } else if (mode == 'table' && centralIp.isNotEmpty) {\n      _connectToCentral();\n    }", "    await _startServer();")
s = s.replace("      if (mode == 'central') {\n        _updateLiveTotals();", "      if (mode == 'central') {\n        _updateLiveTotals();")
s = s.replace("      } else {\n        await _connectToCentral();\n      }", "      }")
s = s.replace("    return mode == 'central' ? _centralView() : _tableView();", "    return _centralView();")

# Reemplazar completamente la pantalla inicial para eliminar el selector CENTRAL/MESA.
start = s.find('class SetupScreen extends StatefulWidget {')
if start >= 0:
    s = s[:start] + r'''class SetupScreen extends StatefulWidget {
  final Future<void> Function(String, int, String, String) onSaved;
  const SetupScreen({super.key, required this.onSaved});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final pin = TextEditingController();
  bool obscure = true;

  @override
  void dispose() {
    pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
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
                            final p = pin.text.trim();
                            if (p.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Escriba la contraseña del administrador.')));
                              return;
                            }
                            await widget.onSaved('central', 1, '', p);
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
'''

# Reparar/normalizar el monitor TV con una implementación Dart válida y sencilla.
tv_start = s.find('  String _tvHtml() =>')
if tv_start >= 0:
    tv_end = s.find('  Future<void> _connectToCentral() async {', tv_start)
    if tv_end >= 0:
        tv = r'''  String _tvHtml() => r"""<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Billares Don Miguel</title>
<style>
html,body{margin:0;width:100%;height:100%;background:#111;color:#fff;font-family:Arial,sans-serif;overflow:hidden}body{display:flex;flex-direction:column}header{text-align:center;padding:14px;background:#191919}h1{margin:0;font-size:42px}#clock{font-size:24px;margin-top:5px}.grid{flex:1;display:grid;grid-template-columns:repeat(3,1fr);gap:14px;padding:14px}.card{border-radius:18px;padding:18px;display:flex;flex-direction:column;justify-content:center}.available{background:#176b3a}.playing{background:#a62029}.pending{background:#9a7300}.name{font-size:30px;font-weight:bold}.state{font-size:24px;margin:8px 0}.time{font-size:40px;font-weight:bold}.info,.total{font-size:22px;margin-top:6px}.total{font-weight:bold}@media(max-width:900px){.grid{grid-template-columns:repeat(2,1fr)}h1{font-size:32px}}
</style></head><body><header><h1>Billares Don Miguel</h1><div id="clock"></div></header><main id="grid" class="grid"></main>
<script>
const grid=document.getElementById('grid');
function money(v){return 'C$'+Number(v||0).toFixed(0)}
function fmt(d){return d?new Date(d).toLocaleTimeString('es-NI',{hour:'2-digit',minute:'2-digit',hour12:true}):'--'}
function elapsed(a,b){if(!a)return '00:00:00';let x=Math.max(0,new Date(b||Date.now())-new Date(a));let sec=Math.floor(x/1000);let h=Math.floor(sec/3600);let m=Math.floor((sec%3600)/60);let s=sec%60;return [h,m,s].map(v=>String(v).padStart(2,'0')).join(':')}
function render(data){const t=data.tables||[];grid.innerHTML=t.map(g=>{let cls=g.active?'playing':(g.finishedAt&&!g.paid?'pending':'available');let state=g.active?'EN JUEGO':(g.finishedAt&&!g.paid?'PENDIENTE DE COBRO':'DISPONIBLE');return '<section class="card '+cls+'"><div class="name">Mesa '+g.tableId+'</div><div class="state">'+state+'</div>'+(g.active?'<div class="time">'+elapsed(g.startedAt)+'</div><div class="info">Inicio: '+fmt(g.startedAt)+'</div><div class="info">Tarifa: '+money(g.rate)+'/hora</div><div class="total">Monto: '+money(g.total)+'</div>':(g.finishedAt?'<div class="info">Inicio: '+fmt(g.startedAt)+'</div><div class="info">Finalización: '+fmt(g.finishedAt)+'</div><div class="info">Tiempo jugado: '+elapsed(g.startedAt,g.finishedAt)+'</div><div class="total">A pagar: '+money(g.total)+'</div>':''))+'</section>'}).join('')}
function connect(){let ws=new WebSocket('ws://'+location.host);ws.onopen=()=>ws.send(JSON.stringify({type:'register',role:'tv'}));ws.onmessage=e=>{try{let d=JSON.parse(e.data);if(d.type==='tv_state')render(d)}catch(_){}};ws.onclose=()=>setTimeout(connect,1500)}
setInterval(()=>document.getElementById('clock').textContent=new Date().toLocaleString('es-NI',{dateStyle:'medium',timeStyle:'medium'}),1000);connect();
</script></body></html>""";
'''
        s = s[:tv_start] + tv + s[tv_end:]

# No permitir que una llamada accidental convierta la app en cliente de mesa.
s = re.sub(r"\n\s*if \(mode == 'table'[^\n]*\) \{", "\n", s)

p.write_text(s)
print('Acceso corregido: aplicación exclusiva para administrador; mesas solo se muestran en TV.')
'''}