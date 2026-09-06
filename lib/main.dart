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

  await SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.immersiveSticky,
  );

  runApp(const BillarApp());
}

class Game {
  final int tableId;

  double rate;
  bool playing;
  DateTime? start;
  DateTime? end;
  int elapsedSeconds;
  double total;
  bool finalized;

  Game({
    required this.tableId,
    required this.rate,
    this.playing = false,
    this.start,
    this.end,
    this.elapsedSeconds = 0,
    this.total = 0,
    this.finalized = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'tableId': tableId,
      'rate': rate,
      'playing': playing,
      'start': start?.toIso8601String(),
      'end': end?.toIso8601String(),
      'elapsedSeconds': elapsedSeconds,
      'total': total,
      'finalized': finalized,
    };
  }

  static Game fromJson(Map<String, dynamic> j) {
    return Game(
      tableId: (j['tableId'] as num).toInt(),
      rate: (j['rate'] as num).toDouble(),
      playing: j['playing'] == true,
      start: j['start'] == null
          ? null
          : DateTime.parse(j['start'].toString()),
      end: j['end'] == null
          ? null
          : DateTime.parse(j['end'].toString()),
      elapsedSeconds:
          (j['elapsedSeconds'] as num?)?.toInt() ??
          ((j['elapsedMinutes'] as num?)?.toInt() ?? 0) * 60,
      total: (j['total'] as num?)?.toDouble() ?? 0,
      finalized: j['finalized'] == true,
    );
  }
}

class BillarApp extends StatelessWidget {
  const BillarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Billar Control Pro',
      theme: ThemeData.dark(useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final List<Game> games = List.generate(
    tableCount,
    (i) => Game(
      tableId: i + 1,
      rate: defaultRates[i],
    ),
  );

  final List<Map<String, dynamic>> history = [];

  final Map<WebSocket, int> clients = {};
  final Map<int, WebSocket> tableClients = {};

  Timer? ticker;
  Timer? reconnectTimer;

  HttpServer? server;
  WebSocket? tableSocket;

  String mode = 'unset';
  int selectedTable = 1;

  String centralIp = '';
  String adminPin = defaultAdminPin;

  bool serverOnline = false;
  bool connected = false;

  String connectionMessage = '';

  bool _loading = true;

  @override
  void initState() {
    super.initState();

    _load();

    ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (mounted) {
          setState(() {});
        }
      },
    );
  }

  @override
  void dispose() {
    ticker?.cancel();
    reconnectTimer?.cancel();

    try {
      tableSocket?.close();
    } catch (_) {}

    try {
      server?.close(force: true);
    } catch (_) {}

    for (final socket in clients.keys.toList()) {
      try {
        socket.close();
      } catch (_) {}
    }

    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();

    mode = prefs.getString('mode') ?? 'unset';
    selectedTable = prefs.getInt('table') ?? 1;
    centralIp = prefs.getString('centralIp') ?? '';
    adminPin = prefs.getString('adminPin') ?? defaultAdminPin;

    final rawGames = prefs.getString('games');

    if (rawGames != null) {
      try {
        final decoded = jsonDecode(rawGames) as List;

        final savedGames = decoded
            .map(
              (x) => Game.fromJson(
                Map<String, dynamic>.from(x as Map),
              ),
            )
            .toList();

        for (final game in savedGames) {
          if (game.tableId >= 1 && game.tableId <= tableCount) {
            _copyGame(
              games[game.tableId - 1],
              game,
            );
          }
        }
      } catch (_) {}
    }

    final rawHistory = prefs.getString('history');

    if (rawHistory != null) {
      try {
        final decoded = jsonDecode(rawHistory) as List;

        history.addAll(
          decoded.map(
            (x) => Map<String, dynamic>.from(x as Map),
          ),
        );
      } catch (_) {}
    }

    if (selectedTable < 1 || selectedTable > tableCount) {
      selectedTable = 1;
    }

    _loading = false;

    if (mode == 'central') {
      await _startServer();
    }

    if (mode == 'mesa') {
      await _connectToCentral();
    }

    if (mounted) {
      setState(() {});
    }
  }

  void _copyGame(Game target, Game source) {
    target
      ..rate = source.rate
      ..playing = source.playing
      ..start = source.start
      ..end = source.end
      ..elapsedSeconds = source.elapsedSeconds
      ..total = source.total
      ..finalized = source.finalized;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(
      'games',
      jsonEncode(
        games.map((g) => g.toJson()).toList(),
      ),
    );

    await prefs.setString(
      'history',
      jsonEncode(history),
    );
  }

  String hm(DateTime? date) {
    if (date == null) {
      return '--:--';
    }

    return '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}';
  }

  String dateTime(DateTime? date) {
    if (date == null) {
      return '--/--/---- --:--';
    }

    return '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/'
        '${date.year} ${hm(date)}';
  }

  int elapsedFor(Game game) {
    if (game.start == null) {
      return game.elapsedSeconds;
    }

    final finish = game.playing
        ? DateTime.now()
        : (game.end ?? DateTime.now());

    return finish.difference(game.start!).inSeconds;
  }

  String duration(Game game) {
    final seconds = elapsedFor(game);

    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;

    return '${hours.toString().padLeft(2, '0')} h '
        '${minutes.toString().padLeft(2, '0')} min';
  }

  double liveTotal(Game game) {
    if (!game.playing || game.start == null) {
      return game.total;
    }

    return elapsedFor(game) / 3600.0 * game.rate;
  }

  Future<String> localIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      for (final interfaceItem in interfaces) {
        for (final address in interfaceItem.addresses) {
          if (!address.isLoopback &&
              address.type == InternetAddressType.IPv4) {
            return address.address;
          }
        }
      }
    } catch (_) {}

    return 'No disponible';
  }

  Future<void> _startServer() async {
    try {
      await server?.close(force: true);
    } catch (_) {}

    try {
      server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        serverPort,
        shared: true,
      );

      serverOnline = true;

      server!.listen(
        (request) async {
          try {
            if (WebSocketTransformer.isUpgradeRequest(request)) {
              final socket =
                  await WebSocketTransformer.upgrade(request);

              socket.listen(
                (raw) {
                  _handleSocket(socket, raw);
                },
                onDone: () {
                  _removeClient(socket);
                },
                onError: (_, __) {
                  _removeClient(socket);
                },
              );
            } else {
              request.response
                ..statusCode = 200
                ..headers.contentType = ContentType.json
                ..write(
                  jsonEncode({
                    'app': 'Billar Control Pro',
                    'status': 'ok',
                    'port': serverPort,
                  }),
                );

              await request.response.close();
            }
          } catch (_) {}
        },
        onError: (_) {
          serverOnline = false;

          if (mounted) {
            setState(() {});
          }
        },
      );
    } catch (_) {
      serverOnline = false;
    }

    if (mounted) {
      setState(() {});
    }
  }

  void _removeClient(WebSocket socket) {
    final table = clients.remove(socket);

    if (table != null &&
        identical(tableClients[table], socket)) {
      tableClients.remove(table);
    }
  }

  void _handleSocket(
    WebSocket socket,
    dynamic raw,
  ) {
    try {
      if (raw is! String) {
        return;
      }

      final decoded = jsonDecode(raw);

      if (decoded is! Map) {
        return;
      }

      final message = Map<String, dynamic>.from(decoded);

      if (message['type'] == 'register') {
        final tableValue = message['tableId'];

        if (tableValue is! num) {
          socket.close();
          return;
        }

        final table = tableValue.toInt();

        if (table < 1 || table > tableCount) {
          socket.close();
          return;
        }

        final previous = tableClients[table];

        if (previous != null &&
            !identical(previous, socket)) {
          try {
            previous.close();
          } catch (_) {}
        }

        clients[socket] = table;
        tableClients[table] = socket;

        _sendTableState(
          socket,
          table,
        );
      }
    } catch (_) {}
  }

  void _sendTableState(
    WebSocket socket,
    int tableId,
  ) {
    if (tableId < 1 || tableId > tableCount) {
      return;
    }

    try {
      socket.add(
        jsonEncode({
          'type': 'table_state',
          'game': games[tableId - 1].toJson(),
        }),
      );
    } catch (_) {}
  }

  // PRIVACIDAD:
  // Cada tablet solamente recibe el estado correspondiente
  // a la mesa que tiene registrada.
  void _broadcastTable(int tableId) {
    final socket = tableClients[tableId];

    if (socket != null) {
      _sendTableState(
        socket,
        tableId,
      );
    }
  }

  Future<void> startGame(Game game) async {
    if (game.playing) {
      return;
    }

    game.playing = true;
    game.start = DateTime.now();
    game.end = null;
    game.elapsedSeconds = 0;
    game.total = 0;
    game.finalized = false;

    await _save();

    _broadcastTable(game.tableId);

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> finishGame(Game game) async {
    if (!game.playing || game.start == null) {
      return;
    }

    game.playing = false;
    game.end = DateTime.now();

    game.elapsedSeconds =
        game.end!.difference(game.start!).inSeconds;

    game.total = double.parse(
      (
        game.elapsedSeconds /
            3600.0 *
            game.rate
      ).toStringAsFixed(2),
    );

    game.finalized = true;

    history.insert(
      0,
      {
        'tableId': game.tableId,
        'start': game.start!.toIso8601String(),
        'end': game.end!.toIso8601String(),
        'seconds': game.elapsedSeconds,
        'minutes': (game.elapsedSeconds / 60).ceil(),
        'rate': game.rate,
        'total': game.total,
      },
    );

    await _save();

    // Solo el central y la tablet de ESTA mesa
    // reciben el resultado final.
    _broadcastTable(game.tableId);

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> newGame(Game game) async {
    if (game.playing) {
      return;
    }

    game
      ..start = null
      ..end = null
      ..elapsedSeconds = 0
      ..total = 0
      ..finalized = false;

    await _save();

    _broadcastTable(game.tableId);

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _connectToCentral() async {
    reconnectTimer?.cancel();

    try {
      await tableSocket?.close();
    } catch (_) {}

    connected = false;

    if (centralIp.trim().isEmpty) {
      connectionMessage =
          'Configura la IP del central';

      if (mounted) {
        setState(() {});
      }

      return;
    }

    try {
      tableSocket = await WebSocket.connect(
        'ws://${centralIp.trim()}:$serverPort',
      ).timeout(
        const Duration(seconds: 5),
      );

      tableSocket!.listen(
        (raw) {
          try {
            if (raw is! String) {
              return;
            }

            final decoded = jsonDecode(raw);

            if (decoded is! Map) {
              return;
            }

            final message =
                Map<String, dynamic>.from(decoded);

            if (message['type'] == 'table_state') {
              final gameData =
                  Map<String, dynamic>.from(
                message['game'] as Map,
              );

              final game = Game.fromJson(gameData);

              // Nunca mostrar otra mesa.
              if (game.tableId != selectedTable) {
                return;
              }

              _copyGame(
                games[selectedTable - 1],
                game,
              );

              if (mounted) {
                setState(() {});
              }
            }
          } catch (_) {}
        },
        onDone: _scheduleReconnect,
        onError: (_, __) {
          _scheduleReconnect();
        },
      );

      tableSocket!.add(
        jsonEncode({
          'type': 'register',
          'tableId': selectedTable,
        }),
      );

      connected = true;
      connectionMessage = 'Conectada al central';
    } catch (_) {
      _scheduleReconnect();
    }

    if (mounted) {
      setState(() {});
    }
  }

  void _scheduleReconnect() {
    connected = false;
    connectionMessage = 'Reintentando conexión...';

    reconnectTimer?.cancel();

    reconnectTimer = Timer(
      const Duration(seconds: 3),
      _connectToCentral,
    );

    if (mounted) {
      setState(() {});
    }
  }

  Future<bool> _pinDialog({
    String title = 'PIN de administrador',
  }) async {
    final controller = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            obscureText: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'PIN',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context, false);
              },
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(
                  context,
                  controller.text == adminPin,
                );
              },
              child: const Text('Entrar'),
            ),
          ],
        );
      },
    );

    controller.dispose();

    return result == true;
  }

  Future<void> _setupWizard() async {
    String newMode = mode == 'unset' ? 'central' : mode;
    int newTable = selectedTable;
    String ip = centralIp;
    String pin = adminPin;

    final ipController = TextEditingController(
      text: ip,
    );

    final pinController = TextEditingController(
      text: pin,
    );

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) {
        return StatefulBuilder(
          builder: (ctx, setD) {
            return AlertDialog(
              title: const Text(
                'Configuración inicial',
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Instala el mismo APK en las 6 tablets y selecciona el rol de cada una.',
                    ),
                    const SizedBox(height: 18),
                    DropdownButtonFormField<String>(
                      value: newMode,
                      items: const [
                        DropdownMenuItem(
                          value: 'central',
                          child: Text('CENTRAL'),
                        ),
                        DropdownMenuItem(
                          value: 'mesa',
                          child: Text('TABLET DE MESA'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setD(() {
                            newMode = value;
                          });
                        }
                      },
                    ),
                    if (newMode == 'mesa') ...[
                      const SizedBox(height: 12),
                      DropdownButtonFormField<int>(
                        value: newTable,
                        items: List.generate(
                          tableCount,
                          (i) {
                            return DropdownMenuItem(
                              value: i + 1,
                              child: Text(
                                'Mesa ${i + 1}',
                              ),
                            );
                          },
                        ),
                        onChanged: (value) {
                          if (value != null) {
                            setD(() {
                              newTable = value;
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: ipController,
                        onChanged: (value) {
                          ip = value;
                        },
                        keyboardType:
                            TextInputType.number,
                        decoration:
                            const InputDecoration(
                          labelText:
                              'IP de la tablet CENTRAL',
                          hintText:
                              'Ej. 192.168.1.20',
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: pinController,
                      obscureText: true,
                      onChanged: (value) {
                        pin = value;
                      },
                      keyboardType:
                          TextInputType.number,
                      decoration:
                          const InputDecoration(
                        labelText:
                            'PIN administrador',
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                FilledButton(
                  onPressed: () async {
                    final prefs =
                        await SharedPreferences
                            .getInstance();

                    final finalPin =
                        pin.trim().isEmpty
                            ? defaultAdminPin
                            : pin.trim();

                    await prefs.setString(
                      'mode',
                      newMode,
                    );

                    await prefs.setInt(
                      'table',
                      newTable,
                    );
                      }
                  }
