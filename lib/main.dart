import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const rates = <double>[120, 120, 100, 100, 70];
const defaultPin = '1234';
const port = 8080;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BillarApp());
}

class Game {
  Game(this.id, {this.active = false, this.start, this.end, this.total = 0});
  final int id;
  bool active;
  DateTime? start, end;
  double total;
  double get rate => rates[id - 1];

  Map<String, dynamic> toJson() => {
        'id': id,
        'active': active,
        'start': start?.toIso8601String(),
        'end': end?.toIso8601String(),
        'total': total,
      };

  static Game fromJson(Map<String, dynamic> j) {
    final id = ((j['id'] as num?)?.toInt() ?? 1).clamp(1, 5);
    return Game(
      id,
      active: j['active'] == true,
      start: DateTime.tryParse(j['start']?.toString() ?? ''),
      end: DateTime.tryParse(j['end']?.toString() ?? ''),
      total: (j['total'] as num?)?.toDouble() ?? 0,
    );
  }
}

class BillarApp extends StatelessWidget {
  const BillarApp({super.key});

  @override
  Widget build(BuildContext c) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Billar Control Pro',
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorSchemeSeed: Colors.blue,
        ),
        home: const Central(),
      );
}

class Central extends StatefulWidget {
  const Central({super.key});

  @override
  State<Central> createState() => _CentralState();
}

class _CentralState extends State<Central> {
  static const tv = MethodChannel('billar_control/tv');
  SharedPreferences? prefs;
  String pin = defaultPin;
  bool loading = true, unlocked = false, tvOn = false;
  HttpServer? server;
  Timer? timer;
  final games = List.generate(5, (i) => Game(i + 1));
  final history = <Game>[];

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    timer?.cancel();
    server?.close(force: true);
    super.dispose();
  }

  Future<void> load() async {
    try {
      prefs = await SharedPreferences.getInstance();
      pin = prefs!.getString('pin') ?? defaultPin;
      for (final raw in prefs!.getStringList('games') ?? []) {
        try {
          final g = Game.fromJson(jsonDecode(raw));
          games[g.id - 1] = g;
        } catch (_) {}
      }
      for (final raw in prefs!.getStringList('history') ?? []) {
        try {
          history.add(Game.fromJson(jsonDecode(raw)));
        } catch (_) {}
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => loading = false);
    await startServer();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      updateTotals();
      if (tvOn) sendTv();
      setState(() {});
    });
  }

  Future<void> startServer() async {
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      server!.listen((r) async {
        if (WebSocketTransformer.isUpgradeRequest(r)) {
          try {
            final s = await WebSocketTransformer.upgrade(r);
            s.listen((data) {
              try {
                final m = jsonDecode(data) as Map<String, dynamic>;
                if (m['type'] == 'register') {
                  final id = (m['tableId'] as num?)?.toInt() ?? 0;
                  if (id >= 1 && id <= 5) {
                    s.add(jsonEncode({
                      'type': 'state',
                      'tableId': id,
                      'game': games[id - 1].toJson(),
                    }));
                  }
                }
              } catch (_) {}
            });
          } catch (_) {}
        } else {
          r.response
            ..headers.contentType = ContentType.html
            ..write('Billar Control Pro');
          await r.response.close();
        }
      });
    } catch (_) {}
  }

  void updateTotals() {
    final now = DateTime.now();
    for (final g in games) {
      if (g.active && g.start != null) {
        g.total = now.difference(g.start!).inSeconds / 3600 * g.rate;
      }
    }
  }

  Future<void> save() async {
    try {
      final p = prefs ?? await SharedPreferences.getInstance();
      prefs = p;
      await p.setString('pin', pin);
      await p.setStringList(
        'games',
        games.map((g) => jsonEncode(g.toJson())).toList(),
      );
      await p.setStringList(
        'history',
        history.map((g) => jsonEncode(g.toJson())).toList(),
      );
    } catch (_) {}
  }

  Future<bool> login() async {
    final c = TextEditingController();
    bool hidden = true;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (d) => StatefulBuilder(
        builder: (d, set) => AlertDialog(
          title: const Text('Acceso administrador'),
          content: TextField(
            controller: c,
            autofocus: true,
            obscureText: hidden,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'PIN de administrador',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.visibility),
                onPressed: () => set(() => hidden = !hidden),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(d, c.text == pin),
              child: const Text('Entrar'),
            ),
          ],
        ),
      ),
    );
    c.dispose();
    if (ok == true) {
      setState(() => unlocked = true);
      return true;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PIN incorrecto')),
      );
    }
    return false;
  }

  void startGame(int id) {
    if (!unlocked) return;
    final g = games[id - 1];
    if (g.active) return;
    setState(() {
      g.active = true;
      g.start = DateTime.now();
      g.end = null;
      g.total = 0;
    });
    save();
    sendTv();
  }

  Future<void> finishGame(int id) async {
    if (!unlocked) return;
    final g = games[id - 1];
    if (!g.active) return;
    updateTotals();
    setState(() {
      g.active = false;
      g.end = DateTime.now();
      history.insert(
        0,
        Game(g.id, start: g.start, end: g.end, total: g.total),
      );
    });
    await save();
    sendTv();
  }

  Future<void> resetGame(int id) async {
    if (!unlocked) return;
    final yes = await confirm(
      'Limpiar mesa $id',
      'Se eliminará el estado actual de la mesa.',
    );
    if (!yes) return;
    setState(() => games[id - 1] = Game(id));
    await save();
    sendTv();
  }

  Future<bool> confirm(String title, String msg) async =>
      await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(title),
          content: Text(msg),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(d, true),
              child: const Text('Confirmar'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> changePin() async {
    final a = TextEditingController();
    final b = TextEditingController();
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Cambiar PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: a,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'PIN actual'),
            ),
            TextField(
              controller: b,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Nuevo PIN'),
            ),
            TextField(
              controller: c,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Confirmar PIN'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              if (a.text == pin && b.text.isNotEmpty && b.text == c.text) {
                pin = b.text;
                Navigator.pop(d, true);
              }
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    a.dispose();
    b.dispose();
    c.dispose();
    if (ok == true) await save();
  }

  Future<void> linkTv() async {
    if (!unlocked) return;
    try {
      final r = await tv.invokeMethod<String>('startTv');
      tvOn = r == 'connected';
      sendTv();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tvOn
                  ? 'TV enlazado correctamente'
                  : 'No se encontró una pantalla externa compatible',
            ),
          ),
        );
      }
    } catch (_) {
      tvOn = false;
    }
    if (mounted) setState(() {});
  }

  void sendTv() {
    if (!tvOn) return;
    try {
      tv.invokeMethod('updateTv', {
        'tables': games.map((g) => g.toJson()).toList(),
      });
    } catch (_) {}
  }

  String time(DateTime? d) => d == null
      ? '--:--'
      : '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  String duration(Game g) {
    if (g.start == null) return '00:00:00';
    final s = ((g.end ?? DateTime.now()).difference(g.start!).inSeconds)
        .clamp(0, 999999);
    return '${(s ~/ 3600).toString().padLeft(2, '0')}:${((s % 3600) ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  String money(double n) => 'C\\$ ${n.toStringAsFixed(2)}';

  @override
  Widget build(BuildContext c) {
    if (loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('BILLAR CONTROL PRO'),
        actions: unlocked
            ? [
                IconButton(
                  tooltip: 'Enlazar TV',
                  onPressed: linkTv,
                  icon: Icon(tvOn ? Icons.tv : Icons.tv_off),
                ),
                IconButton(
                  tooltip: 'Historial',
                  onPressed: showHistory,
                  icon: const Icon(Icons.history),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'pin') changePin();
                    if (v == 'lock') setState(() => unlocked = false);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'pin',
                      child: Text('Cambiar PIN'),
                    ),
                    PopupMenuItem(
                      value: 'lock',
                      child: Text('Bloquear CENTRAL'),
                    ),
                  ],
                ),
              ]
            : [
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: FilledButton.icon(
                    onPressed: login,
                    icon: const Icon(Icons.lock),
                    label: const Text('Administrador'),
                  ),
                ),
              ],
      ),
      body: unlocked ? dashboard() : locked(),
    );
  }

  Widget locked() => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.sports_bar, size: 76),
            const SizedBox(height: 18),
            const Text(
              'BILLARES DON MIGUEL',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),
            const Text('CENTRAL DE CONTROL'),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: login,
              icon: const Icon(Icons.lock_open),
              label: const Text('Ingresar como administrador'),
            ),
          ],
        ),
      );

  Widget dashboard() => LayoutBuilder(
        builder: (c, b) {
          final cols = b.maxWidth > 900 ? 3 : 2;
          return GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              crossAxisSpacing: 14,
              mainAxisSpacing: 14,
              childAspectRatio: 1.18,
            ),
            itemCount: 5,
            itemBuilder: (_, i) => card(games[i]),
          );
        },
      );

  Widget card(Game g) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'MESA ${g.id}',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Chip(label: Text(g.active ? 'OCUPADA' : 'DISPONIBLE')),
                ],
              ),
              Text('Tarifa fija: ${money(g.rate)} / hora'),
              Text('Inicio: ${time(g.start)}'),
              Text('Final: ${time(g.end)}'),
              Text('Tiempo: ${duration(g)}'),
              Text(
                'Monto: ${money(g.total)}',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: g.active ? null : () => startGame(g.id),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Iniciar'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: g.active ? () => finishGame(g.id) : null,
                      icon: const Icon(Icons.stop),
                      label: const Text('Finalizar'),
                    ),
                  ),
                  IconButton(
                    onPressed: () => resetGame(g.id),
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ],
          ),
        ),
      );

  Future<void> showHistory() async => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (_) => SizedBox(
          height: MediaQuery.of(context).size.height * .8,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Historial de partidas',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: history.isEmpty
                      ? const Center(
                          child: Text('No hay partidas finalizadas.'),
                        )
                      : ListView.builder(
                          itemCount: history.length,
                          itemBuilder: (_, i) {
                            final g = history[i];
                            return ListTile(
                              leading: CircleAvatar(child: Text('${g.id}')),
                              title: Text(
                                'Mesa ${g.id} • ${money(g.total)}',
                              ),
                              subtitle: Text(
                                'Inicio ${time(g.start)} • Final ${time(g.end)} • ${duration(g)}',
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      );
}
