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

  static Game fromJson(Map<String, dynamic> json) {
    return Game(
      tableId: (json['tableId'] as num?)?.toInt() ?? 1,
      rate: (json['rate'] as num?)?.toDouble() ?? 100,
      playing: json['playing'] == true,
      start: json['start'] == null
          ? null
          : DateTime.tryParse(json['start'].toString()),
      end: json['end'] == null
          ? null
          : DateTime.tryParse(json['end'].toString()),
      elapsedSeconds:
          (json['elapsedSeconds'] as num?)?.toInt() ??
          ((json['elapsedMinutes'] as num?)?.toInt() ?? 0) * 60,
      total: (json['total'] as num?)?.toDouble() ?? 0,
      finalized: json['finalized'] == true,
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
  late List<Game> games;

  final List<Map<String, dynamic>> history = [];

  final Map<WebSocket, int> clients = {};
  final Map<int, WebSocket> tableClients = {};

  HttpServer? server;
  WebSocket? tableSocket;

  Timer? ticker;
  Timer? reconnectTimer;

  String mode = 'unset';
  int selectedTable = 1;

  String centralIp = '';
  String adminPin = defaultAdminPin;

  bool serverOnline = false;
  bool connected = false;

  String connectionMessage = '';

  bool loading = true;

  @override
  void initState() {
    super.initState();

    games = List.generate(
      tableCount,
      (index) => Game(
        tableId: index + 1,
        rate: defaultRates[index],
      ),
    );

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

    if (selectedTable < 1 || selectedTable > tableCount) {
      selectedTable = 1;
    }

    final rawGames = prefs.getString('games');

    if (rawGames != null) {
      try {
        final decoded = jsonDecode(rawGames);

        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              final game = Game.fromJson(
                Map<String, dynamic>.from(item),
              );

              if (game.tableId >= 1 &&
                  game.tableId <= tableCount) {
                _copyGame(
                  games[game.tableId - 1],
                  game,
                );
              }
            }
          }
        }
      } catch (_) {}
    }

    final rawHistory = prefs.getString('history');

    if (rawHistory != null) {
      try {
        final decoded = jsonDecode(rawHistory);

        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              history.add(
                Map<String, dynamic>.from(item),
              );
            }
          }
        }
      } catch (_) {}
    }

    loading = false;

    if (mode == 'central') {
      await _startServer();
    } else if (mode == 'mesa') {
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
        games.map((game) => game.toJson()).toList(),
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

      for (final networkInterface in interfaces) {
        for (final address in networkInterface.addresses) {
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

      final message =
          Map<String, dynamic>.from(decoded);

      if (message['type'] != 'register') {
        return;
      }

      final value = message['tableId'];

      if (value is! num) {
        socket.close();
        return;
      }

      final tableId = value.toInt();

      if (tableId < 1 ||
          tableId > tableCount) {
        socket.close();
        return;
      }

      final previous =
          tableClients[tableId];

      if (previous != null &&
          !identical(previous, socket)) {
        try {
          previous.close();
        } catch (_) {}
      }

      clients[socket] = tableId;
      tableClients[tableId] = socket;

      _sendTableState(
        socket,
        tableId,
      );
    } catch (_) {}
  }

  void _sendTableState(
    WebSocket socket,
    int tableId,
  ) {
    if (tableId < 1 ||
        tableId > tableCount) {
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
  // Cada tablet recibe solamente los datos
  // de su propia mesa.
  void _broadcastTable(int tableId) {
    if (tableId < 1 ||
        tableId > tableCount) {
      return;
    }

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

    game
      ..playing = true
      ..start = DateTime.now()
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

  Future<void> finishGame(Game game) async {
    if (!game.playing ||
        game.start == null) {
      return;
    }

    game
      ..playing = false
      ..end = DateTime.now();

    game.elapsedSeconds =
        game.end!.difference(
          game.start!,
        ).inSeconds;

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
        'minutes':
            (game.elapsedSeconds / 60).ceil(),
        'rate': game.rate,
        'total': game.total,
      },
    );

    await _save();

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
                Map<String, dynamic>.from(
              decoded,
            );

            if (message['type'] !=
                'table_state') {
              return;
            }

            final rawGame =
                message['game'];

            if (rawGame is! Map) {
              return;
            }

            final game = Game.fromJson(
              Map<String, dynamic>.from(
                rawGame,
              ),
            );

            // SEGURIDAD:
            // Nunca mostrar información de otra mesa.
            if (game.tableId !=
                selectedTable) {
              return;
            }

            _copyGame(
              games[selectedTable - 1],
              game,
            );

            if (mounted) {
              setState(() {});
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
      connectionMessage =
          'Conectada al central';
    } catch (_) {
      _scheduleReconnect();
    }

    if (mounted) {
      setState(() {});
    }
  }

  void _scheduleReconnect() {
    connected = false;
    connectionMessage =
        'Reintentando conexión...';

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
    String title =
        'PIN de administrador',
  }) async {
    final controller =
        TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            obscureText: true,
            keyboardType:
                TextInputType.number,
            decoration:
                const InputDecoration(
              labelText: 'PIN',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(
                  dialogContext,
                  false,
                );
              },
              child:
                  const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(
                  dialogContext,
                  controller.text ==
                      adminPin,
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
    String newMode =
        mode == 'unset'
            ? 'central'
            : mode;

    int newTable = selectedTable;

    String newIp = centralIp;

    String newPin = adminPin;

    final ipController =
        TextEditingController(
      text: newIp,
    );

    final pinController =
        TextEditingController(
      text: newPin,
    );

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (
            builderContext,
            setDialogState,
          ) {
            return AlertDialog(
              title: const Text(
                'Configuración inicial',
              ),
              content:
                  SingleChildScrollView(
                child: Column(
                  mainAxisSize:
                      MainAxisSize.min,
                  children: [
                    const Text(
                      'Configura esta tablet como CENTRAL o como TABLET DE MESA.',
                    ),
                    const SizedBox(
                      height: 20,
                    ),
                    DropdownButtonFormField<
                        String>(
                      value: newMode,
                      decoration:
                          const InputDecoration(
                        labelText: 'Tipo de dispositivo',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'central',
                          child:
                              Text('CENTRAL'),
                        ),
                        DropdownMenuItem(
                          value: 'mesa',
                          child: Text(
                            'TABLET DE MESA',
                          ),
                        ),
                      ],
                      onChanged:
                          (value) {
                        if (value ==
                            null) {
                          return;
                        }

                        setDialogState(() {
                          newMode =
                              value;
                        });
                      },
                    ),
                    if (newMode ==
                        'mesa') ...[
                      const SizedBox(
                        height: 14,
                      ),
                      DropdownButtonFormField<
                          int>(
                        value: newTable,
                        decoration:
                            const InputDecoration(
                          labelText:
                              'Número de mesa',
                        ),
                        items:
                            List.generate(
                          tableCount,
                          (index) {
                            return DropdownMenuItem<
                                int>(
                              value:
                                  index + 1,
                              child:
                                  Text(
                                'Mesa ${index + 1}',
                              ),
                            );
                          },
                        ),
                        onChanged:
                            (value) {
                          if (value ==
                              null) {
                            return;
                          }

                          setDialogState(() {
                            newTable =
                                value;
                          });
                        },
                      ),
                      const SizedBox(
                        height: 14,
                      ),
                      TextField(
                        }
                        }
