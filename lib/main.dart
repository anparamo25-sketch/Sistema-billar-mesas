import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const rates = <double>[120, 120, 100, 100, 70];
const defaultPin = '1234';
const tv = MethodChannel('billar_control/tv');

void main() {
  runApp(const BillarApp());
}

class Game {
  Game({required this.id, required this.rate, this.start, this.end});

  final int id;
  final double rate;
  DateTime? start;
  DateTime? end;

  bool get active => start != null && end == null;

  double get total {
    if (start == null) return 0;
    final seconds = ((end ?? DateTime.now()).difference(start!).inSeconds).clamp(0, 999999);
    return seconds / 3600 * rate;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'rate': rate,
        'start': start?.toIso8601String(),
        'end': end?.toIso8601String(),
        'active': active,
        'total': total,
      };

  static Game fromJson(Map<String, dynamic> json) {
    DateTime? parse(Object? value) => value is String ? DateTime.tryParse(value) : null;
    return Game(
      id: (json['id'] as num).toInt(),
      rate: (json['rate'] as num).toDouble(),
      start: parse(json['start']),
      end: parse(json['end']),
    );
  }
}

class BillarApp extends StatelessWidget {
  const BillarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Billares Don Miguel',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.green),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final games = List<Game>.generate(5, (i) => Game(id: i + 1, rate: rates[i]));
  final pinController = TextEditingController();
  final ipController = TextEditingController();
  Timer? timer;
  HttpServer? server;
  List<WebSocket> sockets = [];
  bool loading = true;
  bool tvConnected = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
        broadcast();
        updateTv();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    server?.close(force: true);
    for (final socket in sockets) {
      socket.close();
    }
    pinController.dispose();
    ipController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      load();
      connectTv();
    }
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('games');
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        for (var i = 0; i < games.length && i < list.length; i++) {
          games[i] = Game.fromJson(Map<String, dynamic>.from(list[i] as Map));
        }
      } catch (_) {}
    }
    final ip = prefs.getString('tv_ip');
    if (ip != null) ipController.text = ip;
    if (mounted) setState(() => loading = false);
    await startServer();
    await connectTv();
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('games', jsonEncode(games.map((g) => g.toJson()).toList()));
    await prefs.setString('tv_ip', ipController.text.trim());
  }

  Future<void> startServer() async {
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, 8080, shared: true);
      server!.listen((request) async {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          try {
            final socket = await WebSocketTransformer.upgrade(request);
            sockets.add(socket);
            socket.add(jsonEncode(games.map((g) => g.toJson()).toList()));
            socket.done.whenComplete(() => sockets.remove(socket));
          } catch (_) {}
        } else {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType('application', 'json', charset: 'utf-8')
            ..write(jsonEncode(games.map((g) => g.toJson()).toList()));
          await request.response.close();
        }
      });
    } catch (_) {}
  }

  void broadcast() {
    final message = jsonEncode(games.map((g) => g.toJson()).toList());
    for (final socket in List<WebSocket>.from(sockets)) {
      try {
        socket.add(message);
      } catch (_) {}
    }
  }

  Future<void> connectTv() async {
    try {
      final result = await tv.invokeMethod<String>('startTv');
      if (mounted) setState(() => tvConnected = result == 'connected');
      updateTv();
    } catch (_) {
      if (mounted) setState(() => tvConnected = false);
    }
  }

  void updateTv() {
    try {
      tv.invokeMethod('updateTv', {
        'tables': games.map((g) => g.toJson()).toList(),
      });
    } catch (_) {}
  }

  void startGame(Game game) {
    if (game.active) return;
    setState(() {
      game.start = DateTime.now();
      game.end = null;
    });
    save();
    broadcast();
    updateTv();
  }

  void stopGame(Game game) {
    if (!game.active) return;
    setState(() => game.end = DateTime.now());
    save();
    broadcast();
    updateTv();
  }

  void resetGame(Game game) {
    setState(() {
      game.start = null;
      game.end = null;
    });
    save();
    broadcast();
    updateTv();
  }

  String duration(Game g) {
    if (g.start == null) return '00:00:00';
    final s = ((g.end ?? DateTime.now()).difference(g.start!).inSeconds).clamp(0, 999999);
    return '${(s ~/ 3600).toString().padLeft(2, '0')}:${((s % 3600) ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  String money(double n) => 'C' + r'$' + ' ${n.toStringAsFixed(2)}';

  @override
  Widget build(BuildContext c) {
    if (loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Billares Don Miguel'),
        actions: [
          IconButton(onPressed: connectTv, icon: Icon(tvConnected ? Icons.tv : Icons.tv_off)),
          IconButton(onPressed: openAdmin, icon: const Icon(Icons.admin_panel_settings)),
        ],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: games.length,
        itemBuilder: (_, i) => card(games[i]),
      ),
    );
  }

  Widget card(Game game) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Mesa ${game.id}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                Text(money(game.rate) + '/hora'),
              ],
            ),
            const SizedBox(height: 8),
            Text(game.active ? 'EN USO' : game.end != null ? 'FINALIZADA' : 'DISPONIBLE'),
            Text(duration(game), style: const TextStyle(fontSize: 30, fontFeatures: [FontFeature.tabularFigures()])),
            Text(money(game.total), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(onPressed: game.active ? null : () => startGame(game), child: const Text('Iniciar')),
                OutlinedButton(onPressed: game.active ? () => stopGame(game) : null, child: const Text('Finalizar')),
                TextButton(onPressed: () => resetGame(game), child: const Text('Reiniciar')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> openAdmin() async {
    pinController.clear();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Administrador'),
        content: TextField(controller: pinController, obscureText: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'PIN')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, pinController.text == defaultPin), child: const Text('Entrar')),
        ],
      ),
    );
    if (ok == true && mounted) showAdminSettings();
  }

  Future<void> showAdminSettings() async {
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Configuración'),
        content: TextField(
          controller: ipController,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(labelText: 'IP de la TV o dispositivo secundario', hintText: '192.168.1.100'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () {
              save();
              Navigator.pop(context);
              connectTv();
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
  }
}
