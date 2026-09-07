import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const int tableCount = 5;
const int serverPort = 8080;
const String defaultAdminPin = '1234';
const List<double> defaultRates = [100, 100, 100, 100, 70];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const BillarApp());
}

class Game {
  int tableId;
  bool active;
  DateTime? startedAt;
  DateTime? finishedAt;
  double rate;
  double total;

  Game({
    required this.tableId,
    this.active = false,
    this.startedAt,
    this.finishedAt,
    required this.rate,
    this.total = 0,
  });

  Map<String, dynamic> toJson() => {
        'tableId': tableId,
        'active': active,
        'startedAt': startedAt?.toIso8601String(),
        'finishedAt': finishedAt?.toIso8601String(),
        'rate': rate,
        'total': total,
      };

  factory Game.fromJson(Map<String, dynamic> j) => Game(
        tableId: (j['tableId'] as num?)?.toInt() ?? 1,
        active: j['active'] == true,
        startedAt:
            j['startedAt'] == null ? null : DateTime.tryParse(j['startedAt']),
        finishedAt:
            j['finishedAt'] == null ? null : DateTime.tryParse(j['finishedAt']),
        rate: (j['rate'] as num?)?.toDouble() ?? 100,
        total: (j['total'] as num?)?.toDouble() ?? 0,
      );
}

class BillarApp extends StatelessWidget {
  const BillarApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Billar Control Pro',
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorSchemeSeed: Colors.blue,
        ),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  SharedPreferences? prefs;
  String mode = '';
  int tableId = 1;
  String centralIp = '';
  String adminPin = defaultAdminPin;
  bool loading = true;
  bool adminUnlocked = false;

  HttpServer? server;
  WebSocket? tableSocket;
  final Map<int, WebSocket> tableSockets = {};
  final List<Game> games = List.generate(
    tableCount,
    (i) => Game(tableId: i + 1, rate: defaultRates[i]),
  );
  final List<Game> history = [];
  Timer? ticker;
  String status = 'Sin configurar';
  String currentDay = '';
  double dailyTotal = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    ticker?.cancel();
    server?.close(force: true);
    tableSocket?.close();
    for (final s in tableSockets.values) {
      s.close();
    }
    super.dispose();
  }

  Future<void> _load() async {
    prefs = await SharedPreferences.getInstance();
    mode = prefs!.getString('mode') ?? '';
    tableId = (prefs!.getInt('tableId') ?? 1).clamp(1, tableCount);
    centralIp = prefs!.getString('centralIp') ?? '';
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

    if (currentDay != _dayKey(DateTime.now())) {
      currentDay = _dayKey(DateTime.now());
      dailyTotal = 0;
      await _persist();
    }

    if (mounted) setState(() => loading = false);

    if (mode == 'central') {
      await _startServer();
    } else if (mode == 'table' && centralIp.isNotEmpty) {
      _connectToCentral();
    }

    ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (mode == 'central') {
        _updateLiveTotals();
        _persist();
        for (int i = 1; i <= tableCount; i++) {
          _broadcast(i);
        }
      }
      setState(() {});
    });
  }

  String _dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _persist() async {
    final p = prefs ?? await SharedPreferences.getInstance();
    await p.setString('mode', mode);
    await p.setInt('tableId', tableId);
    await p.setString('centralIp', centralIp);
    await p.setString('adminPin', adminPin);
    await p.setString('currentDay', currentDay);
    await p.setDouble('dailyTotal', dailyTotal);
    await p.setStringList(
      'games',
      games.map((g) => jsonEncode(g.toJson())).toList(),
    );
    await p.setStringList(
      'history',
      history.map((g) => jsonEncode(g.toJson())).toList(),
    );
  }

  void _updateLiveTotals() {
    for (final g in games) {
      if (g.active && g.startedAt != null) {
        final seconds = DateTime.now().difference(g.startedAt!).inSeconds;
        g.total = seconds / 3600 * g.rate;
      }
    }
  }

  Future<String> _localIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final n in interfaces) {
        for (final a in n.addresses) {
          if (!a.isLoopback && a.type == InternetAddressType.IPv4) {
            return a.address;
          }
        }
      }
    } catch (_) {}
    return '';
  }

  Future<void> _startServer() async {
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
  }

  void _handleSocket(WebSocket socket) {
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
  }

  Map<String, dynamic> _stateForTable(int id) => {
        'type': 'state',
        'tableId': id,
        'game': games[id - 1].toJson(),
      };

  void _broadcast(int id) {
    final socket = tableSockets[id];
    if (socket == null) return;
    try {
      socket.add(jsonEncode(_stateForTable(id)));
    } catch (_) {
      _removeSocket(socket);
    }
  }

  Future<void> _connectToCentral() async {
    if (centralIp.trim().isEmpty) {
      if (mounted) setState(() => status = 'Falta la IP de la CENTRAL');
      return;
    }
    try {
      await tableSocket?.close();
      final socket =
          await WebSocket.connect('ws://${centralIp.trim()}:$serverPort');
      tableSocket = socket;
      if (mounted) setState(() => status = 'Conectado a CENTRAL');
      socket.listen((data) {
        try {
          final m = Map<String, dynamic>.from(jsonDecode(data));
          if (m['type'] != 'state') return;

          // SEGURIDAD: esta tablet solo acepta datos de SU mesa.
          final receivedId = (m['tableId'] as num?)?.toInt() ?? 0;
          if (receivedId != tableId) return;

          final raw = m['game'];
          if (raw is! Map) return;
          games[tableId - 1] =
              Game.fromJson(Map<String, dynamic>.from(raw));
          if (mounted) setState(() {});
        } catch (_) {}
      }, onDone: _scheduleReconnect, onError: (_, __) {
        _scheduleReconnect();
      });
      socket.add(jsonEncode({'type': 'register', 'tableId': tableId}));
    } catch (_) {
      if (mounted) setState(() => status = 'No conectado');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && mode == 'table') _connectToCentral();
    });
  }

  Future<bool> _askPin({String title = 'Acceso administrador'}) async {
    final controller = TextEditingController();
    bool obscure = true;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller, // SIEMPRE empieza vacío.
            obscureText: obscure,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'PIN de administrador',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: obscure ? 'Mostrar PIN' : 'Ocultar PIN',
                onPressed: () => setLocal(() => obscure = !obscure),
                icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx, controller.text == adminPin);
              },
              child: const Text('Entrar'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (result != true && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('PIN incorrecto')));
    }
    return result == true;
  }

  void _startGame(int id) {
    if (mode != 'central' || !adminUnlocked) return;
    final g = games[id - 1];
    if (g.active) return;
    setState(() {
      g.active = true;
      g.startedAt = DateTime.now();
      g.finishedAt = null;
      g.total = 0;
    });
    _persist();
    _broadcast(id);
  }

  Future<void> _finishGame(int id) async {
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
  }

  Future<void> _newGame(int id) async {
    if (mode != 'central' || !adminUnlocked) return;
    final rate = games[id - 1].rate;
    setState(() => games[id - 1] = Game(tableId: id, rate: rate));
    await _persist();
    _broadcast(id);
  }

  Future<void> _clearBilling(int id) async {
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
  }

  Future<void> _changeRate(int id) async {
    if (mode != 'central' || !adminUnlocked) return;
    final c =
        TextEditingController(text: games[id - 1].rate.toStringAsFixed(0));
    final value = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Tarifa mesa $id'),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Córdobas por hora',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, double.tryParse(c.text)),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    c.dispose();
    if (value == null || value <= 0) return;
    setState(() => games[id - 1].rate = value);
    await _persist();
    _broadcast(id);
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirmar')),
          ],
        ),
      ) ??
      false;

  String _money(double v) => 'C\$ ${v.toStringAsFixed(2)}';

  String _time(DateTime? d) {
    if (d == null) return '--:--:--';
    final l = d.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}:${l.second.toString().padLeft(2, '0')}';
  }

  String _elapsed(Game g) {
    if (g.startedAt == null) return '00:00:00';
    final end = g.active ? DateTime.now() : (g.finishedAt ?? DateTime.now());
    final d = end.difference(g.startedAt!);
    return '${d.inHours.toString().padLeft(2, '0')}:${(d.inMinutes % 60).toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _showHistory() async {
    if (!adminUnlocked) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Historial de partidas'),
        content: SizedBox(
          width: 700,
          height: 450,
          child: history.isEmpty
              ? const Center(child: Text('No hay partidas finalizadas.'))
              : ListView.builder(
                  itemCount: history.length,
                  itemBuilder: (_, i) {
                    final g = history[i];
                    return ListTile(
                      title: Text('Mesa ${g.tableId} • ${_money(g.total)}'),
                      subtitle: Text(
                        'Inicio ${_time(g.startedAt)}  •  Fin ${_time(g.finishedAt)}  •  Tiempo ${_elapsed(g)}',
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar')),
        ],
      ),
    );
  }

  Future<void> _dailyClose() async {
    if (!adminUnlocked) return;
    if (games.any((g) => g.active)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se puede cerrar el día mientras haya mesas jugando.')),
      );
      return;
    }
    if (!await _askPin(title: 'Confirmar cierre diario')) return;
    final total = dailyTotal;
    setState(() {
      dailyTotal = 0;
      currentDay = _dayKey(DateTime.now());
    });
    await _persist();
    if (mounted) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Cierre diario'),
          content: Text('Total cerrado: ${_money(total)}'),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Aceptar')),
          ],
        ),
      );
    }
  }

  Future<void> _changePin() async {
    if (!adminUnlocked) return;
    final oldC = TextEditingController();
    final newC = TextEditingController();
    bool oldObs = true, newObs = true;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Cambiar PIN'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: oldC,
                obscureText: oldObs,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'PIN actual',
                  suffixIcon: IconButton(
                    onPressed: () => setLocal(() => oldObs = !oldObs),
                    icon: Icon(oldObs ? Icons.visibility : Icons.visibility_off),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: newC,
                obscureText: newObs,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Nuevo PIN',
                  suffixIcon: IconButton(
                    onPressed: () => setLocal(() => newObs = !newObs),
                    icon: Icon(newObs ? Icons.visibility : Icons.visibility_off),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(
              onPressed: () {
                if (oldC.text != adminPin || newC.text.length < 4) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('PIN actual incorrecto o nuevo PIN inválido.')),
                  );
                  return;
                }
                Navigator.pop(ctx, newC.text);
              },
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );
    oldC.dispose();
    newC.dispose();
    if (result == null) return;
    adminPin = result;
    await _persist();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('PIN cambiado correctamente.')));
    }
  }

  Future<void> _setup() async {
    if (!adminUnlocked) return;
    final ip = TextEditingController(text: centralIp);
    final rates = List.generate(
      tableCount,
      (i) => TextEditingController(text: games[i].rate.toStringAsFixed(0)),
    );
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Configuración CENTRAL'),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: Column(
              children: [
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('IP de la CENTRAL para las tablets de mesa'),
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
                const SizedBox(height: 18),
                ...List.generate(
                  tableCount,
                  (i) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: TextField(
                      controller: rates[i],
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: 'Tarifa mesa ${i + 1} (C\$/hora)',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx, {
                'ip': ip.text.trim(),
                'rates': rates.map((c) => double.tryParse(c.text)).toList(),
              });
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    ip.dispose();
    for (final c in rates) c.dispose();
    if (result == null) return;
    centralIp = result['ip'] as String;
    final rr = result['rates'] as List;
    for (int i = 0; i < tableCount; i++) {
      final v = rr[i] as double?;
      if (v != null && v > 0) games[i].rate = v;
    }
    await _persist();
    if (mode == 'table') await _connectToCentral();
    if (mounted) setState(() {});
  }

  void _logout() {
    if (!adminUnlocked) return;
    setState(() => adminUnlocked = false);
  }

  Future<void> _adminLogin() async {
    if (await _askPin()) {
      setState(() => adminUnlocked = true);
    }
  }

  Widget _gameCard(int id) {
    final g = games[id - 1];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Mesa $id', style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                Chip(
                  label: Text(g.active
                      ? 'JUGANDO'
                      : (g.finishedAt != null ? 'FINALIZADA' : 'LIBRE')),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('Hora de inicio: ${_time(g.startedAt)}'),
            Text('Hora de finalización: ${_time(g.finishedAt)}'),
            Text('Tiempo jugado: ${_elapsed(g)}'),
            Text('Tarifa: ${_money(g.rate)}/hora'),
            Text(
              'Monto a pagar: ${_money(g.total)}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            if (adminUnlocked)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (!g.active)
                    FilledButton.icon(
                      onPressed: () => _startGame(id),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Iniciar'),
                    ),
                  if (g.active)
                    FilledButton.icon(
                      onPressed: () => _finishGame(id),
                      icon: const Icon(Icons.stop),
                      label: const Text('Finalizar'),
                    ),
                  OutlinedButton(
                    onPressed: () => _newGame(id),
                    child: const Text('Nueva partida'),
                  ),
                  OutlinedButton(
                    onPressed: () => _changeRate(id),
                    child: const Text('Tarifa'),
                  ),
                  OutlinedButton(
                    onPressed: () => _clearBilling(id),
                    child: const Text('Borrar cobro'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _centralView() {
    final ipFuture = _localIp();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Billar Control Pro • CENTRAL'),
        actions: [
          IconButton(
            tooltip: 'Historial',
            onPressed: adminUnlocked ? _showHistory : null,
            icon: const Icon(Icons.history),
          ),
          IconButton(
            tooltip: 'Configuración',
            onPressed: adminUnlocked ? _setup : null,
            icon: const Icon(Icons.settings),
          ),
          if (adminUnlocked)
            IconButton(
              tooltip: 'Cambiar PIN',
              onPressed: _changePin,
              icon: const Icon(Icons.lock_reset),
            ),
          if (adminUnlocked)
            IconButton(
              tooltip: 'Cerrar sesión',
              onPressed: _logout,
              icon: const Icon(Icons.logout),
            ),
        ],
      ),
      body: !adminUnlocked
          ? Center(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(30),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.admin_panel_settings, size: 70),
                      const SizedBox(height: 15),
                      const Text(
                        'Acceso de administrador',
                        style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      const Text('Ingrese el PIN para administrar las mesas.'),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: _adminLogin,
                        icon: const Icon(Icons.login),
                        label: const Text('Ingresar'),
                      ),
                    ],
                  ),
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(14),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: FutureBuilder<String>(
                      future: ipFuture,
                      builder: (_, snap) => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Estado: $status'),
                          Text('Puerto: $serverPort'),
                          Text('IP actual de esta CENTRAL: ${snap.data ?? 'Buscando...'}'),
                          Text('Mesas conectadas: ${tableSockets.length}/$tableCount'),
                          const SizedBox(height: 8),
                          Text('Total del día: ${_money(dailyTotal)}',
                              style: const TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 8),
                          FilledButton.icon(
                            onPressed: _dailyClose,
                            icon: const Icon(Icons.point_of_sale),
                            label: const Text('Cerrar día'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                ...List.generate(tableCount, (i) => _gameCard(i + 1)),
              ],
            ),
    );
  }

  Widget _tableView() {
    final g = games[tableId - 1];
    return Scaffold(
      appBar: AppBar(
        title: Text('Mesa $tableId'),
        automaticallyImplyLeading: false,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 650),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(26),
                child: Column(
                  children: [
                    Text('MESA $tableId',
                        style: const TextStyle(
                            fontSize: 34, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 15),
                    Chip(
                      label: Text(g.active
                          ? 'JUGANDO'
                          : (g.finishedAt != null ? 'FINALIZADA' : 'LIBRE')),
                    ),
                    const SizedBox(height: 25),
                    _info('Hora de inicio', _time(g.startedAt)),
                    _info('Hora de finalización', _time(g.finishedAt)),
                    _info('Tiempo jugado', _elapsed(g)),
                    _info('Monto a pagar', _money(g.total), big: true),
                    const SizedBox(height: 20),
                    Text('Estado de conexión: $status'),
                    const SizedBox(height: 5),
                    const Text(
                      'Esta tablet no puede iniciar, finalizar, borrar cobros, cambiar tarifas ni modificar la configuración.',
                      textAlign: TextAlign.center,
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

  Widget _info(String label, String value, {bool big = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(
                child: Text(label,
                    style: TextStyle(
                        fontSize: big ? 19 : 16,
                        fontWeight: FontWeight.w600))),
            Text(value,
                style: TextStyle(
                    fontSize: big ? 26 : 18,
                    fontWeight: FontWeight.bold)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (mode.isEmpty) return SetupScreen(onSaved: (m, t, ip, pin) async {
      mode = m;
      tableId = t;
      centralIp = ip;
      adminPin = pin;
      await _persist();
      if (mode == 'central') {
        await _startServer();
      } else {
        await _connectToCentral();
      }
      if (mounted) setState(() {});
    });
    return mode == 'central' ? _centralView() : _tableView();
  }
}

class SetupScreen extends StatefulWidget {
  final Future<void> Function(String, int, String, String) onSaved;
  const SetupScreen({super.key, required this.onSaved});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  String mode = 'central';
  int table = 1;
  final ip = TextEditingController();
  final pin = TextEditingController();
  bool obscure = true;

  @override
  void dispose() {
    ip.dispose();
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
                      const Icon(Icons.sports_bar, size: 70),
                      const SizedBox(height: 10),
                      const Text('Billar Control Pro',
                          style: TextStyle(
                              fontSize: 28, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 22),
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'central', label: Text('CENTRAL')),
                          ButtonSegment(value: 'table', label: Text('MESA')),
                        ],
                        selected: {mode},
                        onSelectionChanged: (s) =>
                            setState(() => mode = s.first),
                      ),
                      const SizedBox(height: 20),
                      if (mode == 'table') ...[
                        DropdownButtonFormField<int>(
                          value: table,
                          decoration: const InputDecoration(
                              labelText: 'Número de mesa',
                              border: OutlineInputBorder()),
                          items: List.generate(
                            tableCount,
                            (i) => DropdownMenuItem(
                                value: i + 1, child: Text('Mesa ${i + 1}')),
                          ),
                          onChanged: (v) => setState(() => table = v ?? 1),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: ip,
                          decoration: const InputDecoration(
                            labelText: 'IP de la CENTRAL',
                            hintText: 'Ejemplo: 192.168.1.20',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'La CENTRAL usa el puerto 8080. Todas las tablets deben estar en la misma Wi-Fi.',
                          textAlign: TextAlign.center,
                        ),
                      ] else ...[
                        TextField(
                          controller: pin,
                          obscureText: obscure,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: 'PIN inicial del administrador',
                            hintText: 'Escriba el PIN; no se mostrará automáticamente.',
                            border: const OutlineInputBorder(),
                            suffixIcon: IconButton(
                              onPressed: () =>
                                  setState(() => obscure = !obscure),
                              icon: Icon(obscure
                                  ? Icons.visibility
                                  : Icons.visibility_off),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'PIN inicial: 1234. Debe escribirlo manualmente; nunca se autocompleta.',
                          textAlign: TextAlign.center,
                        ),
                      ],
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: () async {
                            final p = mode == 'central'
                                ? (pin.text.isEmpty ? defaultAdminPin : pin.text)
                                : defaultAdminPin;
                            if (mode == 'table' && ip.text.trim().isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text('Escriba la IP de la CENTRAL.')),
                              );
                              return;
                            }
                            await widget.onSaved(
                                mode, table, ip.text.trim(), p);
                          },
                          child: const Text('Guardar y continuar'),
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
