import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const int tableCount = 5;
const int serverPort = 8080;
const String defaultAdminPin = '1234';
const List<double> defaultRates = <double>[100, 100, 100, 100, 70];

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
    this.rate = 100,
    this.total = 0,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'tableId': tableId,
        'active': active,
        'startedAt': startedAt?.toIso8601String(),
        'finishedAt': finishedAt?.toIso8601String(),
        'rate': rate,
        'total': total,
      };

  factory Game.fromJson(Map<String, dynamic> json) => Game(
        tableId: json['tableId'] as int? ?? 1,
        active: json['active'] as bool? ?? false,
        startedAt: json['startedAt'] == null
            ? null
            : DateTime.tryParse(json['startedAt'] as String),
        finishedAt: json['finishedAt'] == null
            ? null
            : DateTime.tryParse(json['finishedAt'] as String),
        rate: (json['rate'] as num?)?.toDouble() ?? 100,
        total: (json['total'] as num?)?.toDouble() ?? 0,
      );
}

class SetupResult {
  final String mode;
  final int tableId;
  final String centralIp;
  final String pin;

  const SetupResult({
    required this.mode,
    required this.tableId,
    required this.centralIp,
    required this.pin,
  });
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
  String status = 'Sin configurar';

  HttpServer? server;
  WebSocket? centralSocket;
  final Map<int, WebSocket> tableSockets = <int, WebSocket>{};

  final List<Game> games = List<Game>.generate(
    tableCount,
    (int index) => Game(
      tableId: index + 1,
      rate: defaultRates[index],
    ),
  );

  Timer? timer;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    timer?.cancel();
    server?.close(force: true);
    centralSocket?.close();
    for (final WebSocket socket in tableSockets.values) {
      socket.close();
    }
    super.dispose();
  }

  Future<void> _loadSettings() async {
    prefs = await SharedPreferences.getInstance();
    final String savedMode = prefs!.getString('mode') ?? '';
    final int savedTable = prefs!.getInt('tableId') ?? 1;
    final String savedIp = prefs!.getString('centralIp') ?? '';
    final String savedPin = prefs!.getString('adminPin') ?? defaultAdminPin;

    if (!mounted) return;
    setState(() {
      mode = savedMode;
      tableId = savedTable.clamp(1, tableCount);
      centralIp = savedIp;
      adminPin = savedPin;
      status = savedMode.isEmpty ? 'Sin configurar' : 'Listo';
    });

    if (mode == 'central') {
      await _startServer();
    } else if (mode == 'table' && centralIp.isNotEmpty) {
      await _connectToCentral();
    }
    _startTimer();
  }

  void _startTimer() {
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (mode == 'central') _updateTotals();
      setState(() {});
    });
  }

  void _updateTotals() {
    for (final Game game in games) {
      if (game.active && game.startedAt != null) {
        final int seconds = DateTime.now().difference(game.startedAt!).inSeconds;
        game.total = (seconds / 3600.0) * game.rate;
      }
    }
  }

  Future<String> _localIp() async {
    try {
      final List<NetworkInterface> interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final NetworkInterface network in interfaces) {
        for (final InternetAddress address in network.addresses) {
          if (!address.isLoopback && address.type == InternetAddressType.IPv4) {
            return address.address;
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
      status = 'Servidor activo';
      if (mounted) setState(() {});

      server!.listen((HttpRequest request) async {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          final WebSocket socket = await WebSocketTransformer.upgrade(request);
          _handleSocket(socket);
          return;
        }
        request.response.headers.contentType = ContentType.html;
        request.response.write('<h2>Billar Control Pro</h2><p>Servidor activo</p>');
        await request.response.close();
      });
    } catch (e) {
      status = 'Error de servidor';
      if (mounted) setState(() {});
    }
  }

  void _handleSocket(WebSocket socket) {
    socket.listen(
      (dynamic data) {
        try {
          final Map<String, dynamic> message =
              Map<String, dynamic>.from(jsonDecode(data as String));
          final String type = message['type'] as String? ?? '';
          if (type == 'register') {
            final int id = message['tableId'] as int? ?? 1;
            if (id < 1 || id > tableCount) return;
            tableSockets[id]?.close();
            tableSockets[id] = socket;
            socket.add(jsonEncode(_stateForTable(id)));
          }
          if (type == 'command') {
            final int id = message['tableId'] as int? ?? 0;
            if (id < 1 || id > tableCount) return;
            if (message['action'] == 'refresh') {
              socket.add(jsonEncode(_stateForTable(id)));
            }
          }
        } catch (_) {}
      },
      onDone: () => _removeSocket(socket),
      onError: (_) => _removeSocket(socket),
    );
  }

  void _removeSocket(WebSocket socket) {
    tableSockets.removeWhere((int key, WebSocket value) => value == socket);
  }

  Map<String, dynamic> _stateForTable(int id) => <String, dynamic>{
        'type': 'state',
        'tableId': id,
        'game': games[id - 1].toJson(),
      };

  void _broadcastTable(int id) {
    final WebSocket? socket = tableSockets[id];
    if (socket == null) return;
    try {
      socket.add(jsonEncode(_stateForTable(id)));
    } catch (_) {}
  }

  Future<void> _connectToCentral() async {
    if (centralIp.trim().isEmpty) {
      status = 'Falta la IP central';
      if (mounted) setState(() {});
      return;
    }
    try {
      await centralSocket?.close();
      final WebSocket socket = await WebSocket.connect(
        'ws://${centralIp.trim()}:$serverPort',
      );
      centralSocket = socket;
      status = 'Conectado a central';
      if (mounted) setState(() {});

      socket.listen(
        (dynamic data) {
          try {
            final Map<String, dynamic> message =
                Map<String, dynamic>.from(jsonDecode(data as String));
            if (message['type'] != 'state') return;
            final int receivedId = message['tableId'] as int? ?? 0;

            // Cada tablet acepta solamente el estado de su propia mesa.
            if (receivedId != tableId) return;

            final dynamic rawGame = message['game'];
            if (rawGame is! Map) return;
            final Game receivedGame =
                Game.fromJson(Map<String, dynamic>.from(rawGame));
            if (!mounted) return;
            setState(() {
              games[tableId - 1] = receivedGame;
            });
          } catch (_) {}
        },
        onDone: () {
          if (mounted) setState(() => status = 'Desconectado');
        },
        onError: (_) {
          if (mounted) setState(() => status = 'Error de conexión');
        },
      );

      socket.add(jsonEncode(<String, dynamic>{
        'type': 'register',
        'tableId': tableId,
      }));
    } catch (_) {
      status = 'No se pudo conectar';
      if (mounted) setState(() {});
    }
  }

  Future<void> _saveSettings(SetupResult result) async {
    final SharedPreferences p = prefs ?? await SharedPreferences.getInstance();
    await p.setString('mode', result.mode);
    await p.setInt('tableId', result.tableId);
    await p.setString('centralIp', result.centralIp);
    await p.setString('adminPin', result.pin);

    setState(() {
      mode = result.mode;
      tableId = result.tableId;
      centralIp = result.centralIp;
      adminPin = result.pin;
    });

    if (mode == 'central') {
      await _startServer();
    } else {
      await _connectToCentral();
    }
  }

  Future<void> _openSetup() async {
    final SetupResult? result = await Navigator.push<SetupResult>(
      context,
      MaterialPageRoute<SetupResult>(
        builder: (_) => SetupPage(
          initialMode: mode,
          initialTableId: tableId,
          initialIp: centralIp,
          initialPin: adminPin,
        ),
      ),
    );
    if (result != null) await _saveSettings(result);
  }

  Future<bool> _askPin() async {
    final TextEditingController controller = TextEditingController();
    final bool? result = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Acceso administrador'),
        content: TextField(
          controller: controller,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'PIN',
            border: OutlineInputBorder(),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text == adminPin),
            child: const Text('Entrar'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result == true;
  }

  void _startGame(int id) {
    if (mode != 'central') return;
    final Game game = games[id - 1];
    setState(() {
      game.active = true;
      game.startedAt = DateTime.now();
      game.finishedAt = null;
      game.total = 0;
    });
    _broadcastTable(id);
  }

  void _finishGame(int id) {
    if (mode != 'central') return;
    final Game game = games[id - 1];
    if (!game.active) return;
    _updateTotals();
    setState(() {
      game.active = false;
      game.finishedAt = DateTime.now();
    });
    _broadcastTable(id);
  }

  void _newGame(int id) {
    if (mode != 'central') return;
    final double rate = games[id - 1].rate;
    setState(() {
      games[id - 1] = Game(tableId: id, rate: rate);
    });
    _broadcastTable(id);
  }

  Future<void> _changeRate(int id) async {
    if (mode != 'central') return;
    final TextEditingController controller = TextEditingController(
      text: games[id - 1].rate.toStringAsFixed(0),
    );
    final double? value = await showDialog<double>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text('Tarifa mesa $id'),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Córdobas por hora',
            border: OutlineInputBorder(),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, double.tryParse(controller.text)),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value <= 0) return;
    setState(() => games[id - 1].rate = value);
    _broadcastTable(id);
  }

  String _money(double value) => 'C\$ ${value.toStringAsFixed(2)}';

  String _elapsed(Game game) {
    if (game.startedAt == null) return '00:00:00';
    final DateTime end =
        game.active ? DateTime.now() : (game.finishedAt ?? DateTime.now());
    final Duration d = end.difference(game.startedAt!);
    final String h = d.inHours.toString().padLeft(2, '0');
    final String m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final String s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  Widget _centralView() => Scaffold(
        appBar: AppBar(
          title: const Text('Billar Control Pro'),
          actions: <Widget>[
            IconButton(
              tooltip: 'Configuración',
              onPressed: () async {
                if (await _askPin()) await _openSetup();
              },
              icon: const Icon(Icons.settings),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: <Widget>[
                    const Icon(Icons.router, size: 32),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FutureBuilder<String>(
                        future: _localIp(),
                        builder: (context, snapshot) {
                          final String ip = snapshot.data ?? 'Buscando...';
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              const Text(
                                'Central',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text('IP: $ip:$serverPort'),
                              Text(status),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            for (int i = 0; i < tableCount; i++) _tableCard(i + 1),
          ],
        ),
      );

  Widget _tableCard(int id) {
    final Game game = games[id - 1];
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                CircleAvatar(child: Text('$id')),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Mesa $id',
                    style: const TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Text(
                  game.active ? 'OCUPADA' : 'LIBRE',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: game.active ? Colors.orange : Colors.green,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Tiempo: ${_elapsed(game)}'),
            Text('Tarifa: ${_money(game.rate)} / hora'),
            Text(
              'Total: ${_money(game.total)}',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                if (!game.active)
                  ElevatedButton.icon(
                    onPressed: () => _startGame(id),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Iniciar'),
                  ),
                if (game.active)
                  ElevatedButton.icon(
                    onPressed: () => _finishGame(id),
                    icon: const Icon(Icons.stop),
                    label: const Text('Finalizar'),
                  ),
                OutlinedButton.icon(
                  onPressed: () => _changeRate(id),
                  icon: const Icon(Icons.attach_money),
                  label: const Text('Tarifa'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _newGame(id),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Nueva'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _tableView() {
    final Game game = games[tableId - 1];
    return Scaffold(
      appBar: AppBar(
        title: Text('Mesa $tableId'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Reconectar',
            onPressed: _connectToCentral,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Configuración',
            onPressed: _openSetup,
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.sports, size: 70),
                  const SizedBox(height: 16),
                  Text(
                    game.active ? 'Mesa en juego' : 'Mesa disponible',
                    style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _elapsed(game),
                    style: const TextStyle(fontSize: 42, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _money(game.total),
                    style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Text('Tarifa: ${_money(game.rate)} / hora'),
                  const SizedBox(height: 20),
                  Text(status),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _welcome() => Scaffold(
        appBar: AppBar(title: const Text('Billar Control Pro')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(Icons.sports, size: 80),
                    const SizedBox(height: 20),
                    const Text(
                      'Bienvenido',
                      style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Configura esta tablet como Central o como una de las 5 mesas.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: _openSetup,
                      icon: const Icon(Icons.settings),
                      label: const Text('Configurar sistema'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (mode.isEmpty) return _welcome();
    if (mode == 'central') return _centralView();
    return _tableView();
  }
}

class SetupPage extends StatefulWidget {
  final String initialMode;
  final int initialTableId;
  final String initialIp;
  final String initialPin;

  const SetupPage({
    super.key,
    required this.initialMode,
    required this.initialTableId,
    required this.initialIp,
    required this.initialPin,
  });

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  late String mode;
  late int tableId;
  late TextEditingController ipController;
  late TextEditingController pinController;

  @override
  void initState() {
    super.initState();
    mode = widget.initialMode.isEmpty ? 'central' : widget.initialMode;
    tableId = widget.initialTableId.clamp(1, tableCount);
    ipController = TextEditingController(text: widget.initialIp);
    pinController = TextEditingController(
      text: widget.initialPin.isEmpty ? defaultAdminPin : widget.initialPin,
    );
  }

  @override
  void dispose() {
    ipController.dispose();
    pinController.dispose();
    super.dispose();
  }

  void _save() {
    if (mode == 'table' && ipController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Escribe la IP de la tablet central.')),
      );
      return;
    }
    Navigator.pop(
      context,
      SetupResult(
        mode: mode,
        tableId: tableId,
        centralIp: ipController.text.trim(),
        pin: pinController.text.trim().isEmpty
            ? defaultAdminPin
            : pinController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Configuración inicial')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: <Widget>[
            const Text(
              'Modo de funcionamiento',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: mode,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem(value: 'central', child: Text('Tablet Central')),
                DropdownMenuItem(value: 'table', child: Text('Tablet de Mesa')),
              ],
              onChanged: (String? value) {
                if (value == null) return;
                setState(() => mode = value);
              },
            ),
            const SizedBox(height: 20),
            if (mode == 'table') ...<Widget>[
              const Text(
                'Número de mesa',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                value: tableId,
                decoration: const InputDecoration(border: OutlineInputBorder()),
                items: List<DropdownMenuItem<int>>.generate(
                  tableCount,
                  (int index) => DropdownMenuItem<int>(
                    value: index + 1,
                    child: Text('Mesa ${index + 1}'),
                  ),
                ),
                onChanged: (int? value) {
                  if (value == null) return;
                  setState(() => tableId = value);
                },
              ),
              const SizedBox(height: 20),
              const Text(
                'IP de la tablet central',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: ipController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  hintText: 'Ejemplo: 192.168.1.100',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),
            ],
            const Text(
              'PIN administrador',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: pinController,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
              ],
              decoration: const InputDecoration(
                hintText: '1234',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 30),
            ElevatedButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: const Text('Guardar configuración'),
            ),
            const SizedBox(height: 12),
            if (mode == 'central')
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'La tablet central debe estar conectada a la misma red Wi-Fi que las 5 tablets de mesa.',
                  ),
                ),
              ),
          ],
        ),
      );
}
