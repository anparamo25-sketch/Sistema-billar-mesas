from pathlib import Path
import re

p = Path('/tmp/billar_app/lib/main.dart')
s = p.read_text()

# Tarifas oficiales e inmutables.
s = s.replace("const List<double> defaultRates = [100, 100, 100, 100, 70];", "const List<double> defaultRates = [120, 120, 100, 100, 70];")

# Modelo: estado de cobro.
s = s.replace("  bool active;\n  DateTime? startedAt;", "  bool active;\n  bool paid;\n  DateTime? startedAt;")
s = s.replace("    required this.tableId,\n    this.active = false,\n    this.startedAt,", "    required this.tableId,\n    this.active = false,\n    this.paid = false,\n    this.startedAt,")
s = s.replace("        'tableId': tableId,\n        'active': active,\n        'startedAt':", "        'tableId': tableId,\n        'active': active,\n        'paid': paid,\n        'startedAt':")
s = s.replace("        tableId: (j['tableId'] as num?)?.toInt() ?? 1,\n        active: j['active'] == true,\n        startedAt:", "        tableId: (j['tableId'] as num?)?.toInt() ?? 1,\n        active: j['active'] == true,\n        paid: j['paid'] == true,\n        startedAt:")

# Fuerza tarifas oficiales incluso si existen datos antiguos guardados.
needle = "    final savedGames = prefs!.getStringList('games') ?? [];"
if needle in s:
    s = s.replace(needle, "    for (int i = 0; i < tableCount; i++) { games[i].rate = defaultRates[i]; }\n\n" + needle, 1)
needle2 = "        } catch (_) {}\n      }\n    }"
if needle2 in s:
    s = s.replace(needle2, "        } catch (_) {}\n        games[i].rate = defaultRates[i];\n      }\n    }", 1)

# Tarifas no editables: el método antiguo ya no cambia ningún valor.
start = s.find("  Future<void> _changeRate(int id) async {")
if start >= 0:
    end = s.find("\n  Future<bool> _confirm(", start)
    if end >= 0:
        s = s[:start] + "  Future<void> _changeRate(int id) async {\n    if (!mounted) return;\n    ScaffoldMessenger.of(context).showSnackBar(\n      SnackBar(content: Text('Tarifa fija: C$ ${defaultRates[id - 1].toStringAsFixed(0)} por hora')),\n    );\n  }\n" + s[end:]
s = s.replace("Cambiar tarifa", "Tarifa fija")

# Finalizar deja la mesa pendiente de cobro; cobrar es la única acción que la libera.
old_finish = """  Future<void> _finishGame(int id) async {
    if (mode != 'central' || !adminUnlocked) return;
    final g = games[id - 1];
    if (!g.active) return;
    _updateLiveTotals();
    setState(() {
      g.active = false;
      g.finishedAt = DateTime.now();
      dailyTotal += g.total;
      history.insert(0, Game.fromJson(g.toJson()));
    });
    await _persist();
    _broadcast(id);
  }"""
new_finish = """  Future<void> _finishGame(int id) async {
    if (mode != 'central' || !adminUnlocked) return;
    final g = games[id - 1];
    if (!g.active) return;
    _updateLiveTotals();
    setState(() {
      g.active = false;
      g.paid = false;
      g.finishedAt = DateTime.now();
      history.insert(0, Game.fromJson(g.toJson()));
    });
    await _persist();
    _broadcast(id);
  }"""
if old_finish in s:
    s = s.replace(old_finish, new_finish)

old_clear = """  Future<void> _clearBilling(int id) async {
    if (mode != 'central' || !adminUnlocked) return;
    final ok = await _confirm(
      'Borrar cobro de mesa $id',
      'Se eliminará el cobro/estado actual de esta mesa. El historial de partidas finalizadas se conserva.',
    );
    if (!ok) return;
    final rate = games[id - 1].rate;
    setState(() => games[id - 1] = Game(tableId: id, rate: rate));
    await _persist();
    _broadcast(id);
  }"""
new_clear = """  Future<void> _clearBilling(int id) async {
    await _payGame(id);
  }

  Future<void> _payGame(int id) async {
    if (mode != 'central' || !adminUnlocked) return;
    final g = games[id - 1];
    if (g.active || g.paid || g.finishedAt == null) return;
    final ok = await _confirm(
      'Cobrar mesa $id',
      'Confirmar cobro de C$ ${g.total.toStringAsFixed(0)}. La mesa quedará disponible después del cobro.',
    );
    if (!ok) return;
    setState(() {
      g.paid = true;
      dailyTotal += g.total;
    });
    await _persist();
    _broadcast(id);
  }"""
if old_clear in s:
    s = s.replace(old_clear, new_clear)
s = s.replace("Borrar cobro", "Cobrar")

# Reiniciar mesa después del cobro conserva únicamente la tarifa oficial.
old_new = """  Future<void> _newGame(int id) async {
    if (mode != 'central' || !adminUnlocked) return;
    final rate = games[id - 1].rate;
    setState(() => games[id - 1] = Game(tableId: id, rate: rate));
    await _persist();
    _broadcast(id);
  }"""
new_new = """  Future<void> _newGame(int id) async {
    if (mode != 'central' || !adminUnlocked) return;
    setState(() => games[id - 1] = Game(tableId: id, rate: defaultRates[id - 1]));
    await _persist();
    _broadcast(id);
  }"""
if old_new in s:
    s = s.replace(old_new, new_new)

# ---------------------------------------------------------------------------
# Monitor TV: la CENTRAL sirve una página /tv. La TV se conecta por Wi-Fi al
# servidor de la tablet y recibe únicamente el estado de las 5 mesas.
# ---------------------------------------------------------------------------
s = s.replace("  final Map<int, WebSocket> tableSockets = {};", "  final Map<int, WebSocket> tableSockets = {};\n  final Set<WebSocket> tvSockets = <WebSocket>{};")
s = s.replace("    for (final s in tableSockets.values) {\n      s.close();\n    }", "    for (final s in tableSockets.values) {\n      s.close();\n    }\n    for (final s in tvSockets) {\n      s.close();\n    }")

old_server = """  Future<void> _startServer() async {
    try {
      await server?.close(force: true);
      server = await HttpServer.bind(InternetAddress.anyIPv4, serverPort);
      if (mounted) setState(() => status = 'Servidor activo');
      server!.listen((request) async {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          final socket = await WebSocketTransformer.upgrade(request);
          _handleSocket(socket);
        } else {
          request.response.headers.contentType = ContentType.html;
          request.response.write(
            '<h2>Billar Control Pro</h2><p>Servidor activo en puerto $serverPort</p>',
          );
          await request.response.close();
        }
      });
    } catch (_) {
      if (mounted) setState(() => status = 'Error de servidor: puerto $serverPort');
    }
  }"""
new_server = """  Future<void> _startServer() async {
    try {
      await server?.close(force: true);
      server = await HttpServer.bind(InternetAddress.anyIPv4, serverPort);
      if (mounted) setState(() => status = 'Servidor activo');
      server!.listen((request) async {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          final socket = await WebSocketTransformer.upgrade(request);
          _handleSocket(socket);
          return;
        }
        if (request.uri.path == '/tv' || request.uri.path == '/tv/') {
          request.response.headers.contentType = ContentType.html;
          request.response.headers.set('Cache-Control', 'no-store');
          request.response.write(_tvHtml());
          await request.response.close();
          return;
        }
        request.response.headers.contentType = ContentType.html;
        request.response.write('<h2>Billares Don Miguel</h2><p>Servidor activo en puerto $serverPort</p><p>Monitor TV: /tv</p>');
        await request.response.close();
      });
    } catch (e, st) {
      debugPrint('SERVER ERROR: $e\\n$st');
      if (mounted) setState(() => status = 'Error de servidor: $e');
    }
  }"""
if old_server not in s:
    raise SystemExit('No se encontró _startServer')
s = s.replace(old_server, new_server)

old_handle = """  void _handleSocket(WebSocket socket) {
    socket.listen((data) {
      try {
        final m = Map<String, dynamic>.from(jsonDecode(data));
        if (m['type'] != 'register') return;
        final id = (m['tableId'] as num?)?.toInt() ?? 0;
        if (id < 1 || id > tableCount) return;
        tableSockets[id]?.close();
        tableSockets[id] = socket;
        socket.add(jsonEncode(_stateForTable(id)));
        if (mounted) setState(() {});
      } catch (_) {}
    }, onDone: () {
      _removeSocket(socket);
    }, onError: (_) {
      _removeSocket(socket);
    });
  }

  void _removeSocket(WebSocket socket) {
    tableSockets.removeWhere((_, value) => value == socket);
    if (mounted) setState(() {});
  }"""
new_handle = """  void _handleSocket(WebSocket socket) {
    socket.listen((data) {
      try {
        final m = Map<String, dynamic>.from(jsonDecode(data));
        if (m['type'] != 'register') return;
        if (m['role'] == 'tv') {
          tvSockets.add(socket);
          socket.add(jsonEncode(_tvState()));
          return;
        }
        final id = (m['tableId'] as num?)?.toInt() ?? 0;
        if (id < 1 || id > tableCount) return;
        tableSockets[id]?.close();
        tableSockets[id] = socket;
        socket.add(jsonEncode(_stateForTable(id)));
        if (mounted) setState(() {});
      } catch (_) {}
    }, onDone: () {
      _removeSocket(socket);
    }, onError: (_) {
      _removeSocket(socket);
    });
  }

  void _removeSocket(WebSocket socket) {
    tableSockets.removeWhere((_, value) => value == socket);
    tvSockets.remove(socket);
    if (mounted) setState(() {});
  }"""
if old_handle not in s:
    raise SystemExit('No se encontró _handleSocket')
s = s.replace(old_handle, new_handle)

old_broadcast = """  void _broadcast(int id) {
    final socket = tableSockets[id];
    if (socket == null) return;
    try {
      socket.add(jsonEncode(_stateForTable(id)));
    } catch (_) {
      _removeSocket(socket);
    }
  }"""
new_broadcast = """  void _broadcast(int id) {
    final socket = tableSockets[id];
    if (socket != null) {
      try { socket.add(jsonEncode(_stateForTable(id))); } catch (_) { _removeSocket(socket); }
    }
    _broadcastTv();
  }

  Map<String, dynamic> _tvState() => {
    'type': 'tv_state',
    'tables': games.map((g) => g.toJson()).toList(),
  };

  void _broadcastTv() {
    if (tvSockets.isEmpty) return;
    final message = jsonEncode(_tvState());
    for (final socket in List<WebSocket>.from(tvSockets)) {
      try { socket.add(message); } catch (_) { _removeSocket(socket); }
    }
  }"""
if old_broadcast not in s:
    raise SystemExit('No se encontró _broadcast')
s = s.replace(old_broadcast, new_broadcast)

marker = "  Future<void> _connectToCentral() async {"
tv_method = r'''  String _tvHtml() => r''' + "'''" + r'''<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Billares Don Miguel</title>
<style>
*{box-sizing:border-box}html,body{margin:0;width:100%;height:100%;font-family:Arial,sans-serif;background:#101216;color:#fff;overflow:hidden}body{display:flex;flex-direction:column}header{padding:16px 24px 10px;text-align:center;background:#171a20;border-bottom:2px solid #2b3038}h1{margin:0;font-size:clamp(28px,4vw,52px);letter-spacing:2px}#clock{font-size:clamp(18px,2.2vw,30px);opacity:.9;margin-top:4px}#summary{font-size:clamp(13px,1.5vw,20px);margin-top:6px;opacity:.85}.grid{flex:1;display:grid;grid-template-columns:repeat(2,1fr);gap:14px;padding:14px}.card{border-radius:22px;padding:18px 22px;display:flex;flex-direction:column;justify-content:center;min-height:0;box-shadow:0 8px 24px rgba(0,0,0,.3);transition:background .5s,transform .35s,box-shadow .35s}.available{background:#126b35}.playing{background:#a51f28}.pending{background:#a87900}.flash{animation:flash .75s ease 2}@keyframes flash{0%,100%{transform:scale(1)}50%{transform:scale(1.025);box-shadow:0 0 32px rgba(255,255,255,.45)}}.name{font-size:clamp(22px,2.8vw,38px);font-weight:800}.state{font-size:clamp(18px,2.2vw,30px);font-weight:700;margin:7px 0 10px}.time{font-size:clamp(28px,4vw,58px);font-weight:900;letter-spacing:1px}.info{font-size:clamp(14px,1.8vw,23px);margin-top:5px;line-height:1.35}.total{font-size:clamp(20px,2.7vw,38px);font-weight:900;margin-top:7px}@media(min-width:1200px){.grid{grid-template-columns:repeat(3,1fr)}.card:last-child{grid-column:2}}
</style></head><body><header><h1>Billares Don Miguel</h1><div id="clock">--:-- --</div><div id="summary">Conectando...</div></header><main id="grid" class="grid"></main>
<script>
let tables=[];const grid=document.getElementById('grid'),clock=document.getElementById('clock'),summary=document.getElementById('summary'),last={};
const money=v=>'C$'+Number(v||0).toFixed(0);const fmt=d=>d?new Date(d).toLocaleTimeString('es-NI',{hour:'2-digit',minute:'2-digit',hour12:true}):'--';
function elapsed(a,b){if(!a)return'00:00:00';let x=Math.max(0,new Date(b||Date.now())-new Date(a))/1000,h=Math.floor(x/3600),m=Math.floor(x%3600/60),s=Math.floor(x%60);return[String(h).padStart(2,'0'),String(m).padStart(2,'0'),String(s).padStart(2,'0')].join(':')}
function state(g){return g.active?'playing':(g.finishedAt&&!g.paid?'pending':'available')}
function render(){grid.innerHTML='';let c={playing:0,pending:0,available:0};tables.forEach(g=>{let st=state(g);c[st]++;let el=document.createElement('section');el.className='card '+st;if(last[g.tableId]&&last[g.tableId]!==st)el.classList.add('flash');last[g.tableId]=st;let h='<div class="name">MESA '+g.tableId+'</div><div class="state">'+(st==='playing'?'EN JUEGO':st==='pending'?'PENDIENTE DE COBRO':'DISPONIBLE')+'</div>';if(st==='available')h+='<div class="info">Lista para jugar</div>';if(st==='playing')h+='<div class="time">'+elapsed(g.startedAt)+'</div><div class="info">Inicio: '+fmt(g.startedAt)+'</div><div class="total">'+money(g.total)+'</div>';if(st==='pending')h+='<div class="info">Inicio: '+fmt(g.startedAt)+'</div><div class="info">Finalización: '+fmt(g.finishedAt)+'</div><div class="info">Tiempo jugado: '+elapsed(g.startedAt,g.finishedAt)+'</div><div class="total">TOTAL: '+money(g.total)+'</div>';el.innerHTML=h;grid.appendChild(el)});summary.textContent=c.playing+' en juego • '+c.pending+' pendientes de cobro • '+c.available+' disponibles'}
function tick(){clock.textContent=new Date().toLocaleTimeString('es-NI',{hour:'2-digit',minute:'2-digit',second:'2-digit',hour12:true});document.querySelectorAll('.playing .time').forEach((e,i)=>{const id=Number(e.parentElement.querySelector('.name').textContent.replace('MESA ','')),g=tables.find(x=>x.tableId===id);if(g)e.textContent=elapsed(g.startedAt)})}setInterval(tick,1000);tick();
function connect(){let w=new WebSocket('ws://'+location.host);w.onopen=()=>w.send(JSON.stringify({type:'register',role:'tv'}));w.onmessage=e=>{try{let m=JSON.parse(e.data);if(m.type==='tv_state'){tables=m.tables||[];render();}}catch(_){}};w.onclose=()=>setTimeout(connect,2000)}connect();
</script></body></html>''' + "'''" + ";"
if marker not in s:
    raise SystemExit('No se encontró punto para TV')
s = s.replace(marker, tv_method + "\n" + marker, 1)

# TV receives a fresh state every second while the CENTRAL is running.
s = s.replace("        for (int i = 1; i <= tableCount; i++) {\n          _broadcast(i);\n        }", "        for (int i = 1; i <= tableCount; i++) {\n          _broadcast(i);\n        }\n        _broadcastTv();")

p.write_text(s)
print('Parche Billares Don Miguel aplicado correctamente.')
