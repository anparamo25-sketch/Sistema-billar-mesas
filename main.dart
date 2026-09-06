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
  final int tableId;
  double rate;
  bool playing;
  DateTime? start;
  DateTime? end;
  int elapsedSeconds;
  double total;
  bool finalized;

  Game({required this.tableId, required this.rate, this.playing = false, this.start,
    this.end, this.elapsedSeconds = 0, this.total = 0, this.finalized = false});

  Map<String, dynamic> toJson() => {
    'tableId': tableId, 'rate': rate, 'playing': playing,
    'start': start?.toIso8601String(), 'end': end?.toIso8601String(),
    'elapsedSeconds': elapsedSeconds, 'total': total, 'finalized': finalized,
  };

  static Game fromJson(Map<String, dynamic> j) => Game(
    tableId: (j['tableId'] as num).toInt(),
    rate: (j['rate'] as num).toDouble(),
    playing: j['playing'] == true,
    start: j['start'] == null ? null : DateTime.parse(j['start']),
    end: j['end'] == null ? null : DateTime.parse(j['end']),
    elapsedSeconds: (j['elapsedSeconds'] as num?)?.toInt() ?? ((j['elapsedMinutes'] as num?)?.toInt() ?? 0) * 60,
    total: (j['total'] as num?)?.toDouble() ?? 0,
    finalized: j['finalized'] == true,
  );
}

class BillarApp extends StatelessWidget {
  const BillarApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Billar Control Pro',
    theme: ThemeData.dark(useMaterial3: true),
    home: const HomePage(),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final games = List.generate(tableCount, (i) => Game(tableId: i + 1, rate: defaultRates[i]));
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
    ticker = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() {}); });
  }

  @override
  void dispose() {
    ticker?.cancel();
    reconnectTimer?.cancel();
    tableSocket?.close();
    server?.close(force: true);
    for (final s in clients.keys.toList()) { s.close(); }
    super.dispose();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    mode = p.getString('mode') ?? 'unset';
    selectedTable = p.getInt('table') ?? 1;
    centralIp = p.getString('centralIp') ?? '';
    adminPin = p.getString('adminPin') ?? defaultAdminPin;
    final raw = p.getString('games');
    if (raw != null) {
      final list = (jsonDecode(raw) as List).map((x) => Game.fromJson(x)).toList();
      for (final g in list) {
        if (g.tableId >= 1 && g.tableId <= tableCount) _copyGame(games[g.tableId - 1], g);
      }
    }
    final hist = p.getString('history');
    if (hist != null) history.addAll((jsonDecode(hist) as List).map((x) => Map<String, dynamic>.from(x)));
    _loading = false;
    if (mode == 'central') await _startServer();
    if (mode == 'mesa') await _connectToCentral();
    if (mounted) setState(() {});
  }

  void _copyGame(Game target, Game source) {
    target..rate = source.rate..playing = source.playing..start = source.start..end = source.end
      ..elapsedSeconds = source.elapsedSeconds..total = source.total..finalized = source.finalized;
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('games', jsonEncode(games.map((g) => g.toJson()).toList()));
    await p.setString('history', jsonEncode(history));
  }

  String hm(DateTime? d) => d == null ? '--:--' : '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  String dateTime(DateTime? d) => d == null ? '--/--/---- --:--' : '${d.day.toString().padLeft(2,'0')}/${d.month.toString().padLeft(2,'0')}/${d.year} ${hm(d)}';

  int elapsedFor(Game g) {
    if (g.start == null) return g.elapsedSeconds;
    final finish = g.playing ? DateTime.now() : (g.end ?? DateTime.now());
    return finish.difference(g.start!).inSeconds;
  }

  String duration(Game g) {
    final s = elapsedFor(g);
    return '${(s ~/ 3600).toString().padLeft(2,'0')} h ${((s % 3600) ~/ 60).toString().padLeft(2,'0')} min';
  }

  double liveTotal(Game g) {
    if (!g.playing || g.start == null) return g.total;
    return elapsedFor(g) / 3600.0 * g.rate;
  }

  String localIp() {
    try {
      for (final i in NetworkInterface.listSync()) {
        for (final a in i.addresses) {
          if (a.type == InternetAddressType.IPv4 && !a.isLoopback) return a.address;
        }
      }
    } catch (_) {}
    return 'No disponible';
  }

  Future<void> _startServer() async {
    await server?.close(force: true);
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, serverPort, shared: true);
      serverOnline = true;
      server!.listen((request) async {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          final socket = await WebSocketTransformer.upgrade(request);
          socket.listen((raw) => _handleSocket(socket, raw), onDone: () => _removeClient(socket), onError: (_, __) => _removeClient(socket));
        } else {
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'app': 'Billar Control Pro', 'status': 'ok', 'port': serverPort}));
          await request.response.close();
        }
      });
    } catch (_) { serverOnline = false; }
    if (mounted) setState(() {});
  }

  void _removeClient(WebSocket socket) {
    final table = clients.remove(socket);
    if (table != null && identical(tableClients[table], socket)) tableClients.remove(table);
  }

  void _handleSocket(WebSocket socket, dynamic raw) {
    try {
      final m = jsonDecode(raw as String) as Map<String, dynamic>;
      if (m['type'] == 'register') {
        final table = (m['tableId'] as num).toInt();
        if (table < 1 || table > tableCount) { socket.close(); return; }
        final previous = tableClients[table];
        if (previous != null && !identical(previous, socket)) { try { previous.close(); } catch (_) {} }
        clients[socket] = table;
        tableClients[table] = socket;
        _sendTableState(socket, table);
      }
    } catch (_) {}
  }

  void _sendTableState(WebSocket socket, int tableId) {
    if (tableId < 1 || tableId > tableCount) return;
    try { socket.add(jsonEncode({'type': 'table_state', 'game': games[tableId - 1].toJson()})); } catch (_) {}
  }

  // Privacidad por mesa: solamente el socket registrado con el tableId recibe ese estado.
  void _broadcastTable(int tableId) {
    final socket = tableClients[tableId];
    if (socket != null) _sendTableState(socket, tableId);
  }

  Future<void> startGame(Game g) async {
    if (g.playing) return;
    g.playing = true; g.start = DateTime.now(); g.end = null; g.elapsedSeconds = 0; g.total = 0; g.finalized = false;
    await _save();
    _broadcastTable(g.tableId);
    if (mounted) setState(() {});
  }

  Future<void> finishGame(Game g) async {
    if (!g.playing || g.start == null) return;
    g.playing = false; g.end = DateTime.now(); g.elapsedSeconds = g.end!.difference(g.start!).inSeconds;
    g.total = double.parse((g.elapsedSeconds / 3600.0 * g.rate).toStringAsFixed(2));
    g.finalized = true;
    history.insert(0, {'tableId': g.tableId, 'start': g.start!.toIso8601String(), 'end': g.end!.toIso8601String(), 'seconds': g.elapsedSeconds, 'minutes': (g.elapsedSeconds / 60).ceil(), 'rate': g.rate, 'total': g.total});
    await _save();
    // Solo Central y la tablet de ESTA mesa reciben el resultado final.
    _broadcastTable(g.tableId);
    if (mounted) setState(() {});
  }

  Future<void> newGame(Game g) async {
    if (g.playing) return;
    g..start = null..end = null..elapsedSeconds = 0..total = 0..finalized = false;
    await _save();
    _broadcastTable(g.tableId);
    if (mounted) setState(() {});
  }

  Future<void> _connectToCentral() async {
    reconnectTimer?.cancel();
    await tableSocket?.close();
    connected = false;
    if (centralIp.trim().isEmpty) { connectionMessage = 'Configura la IP del central'; if (mounted) setState(() {}); return; }
    try {
      tableSocket = await WebSocket.connect('ws://${centralIp.trim()}:$serverPort').timeout(const Duration(seconds: 5));
      tableSocket!.listen((raw) {
        try {
          final m = jsonDecode(raw as String) as Map<String, dynamic>;
          if (m['type'] == 'table_state') {
            final g = Game.fromJson(m['game']);
            if (g.tableId != selectedTable) return; // Nunca mostrar otra mesa.
            _copyGame(games[selectedTable - 1], g);
            if (mounted) setState(() {});
          }
        } catch (_) {}
      }, onDone: _scheduleReconnect, onError: (_, __) => _scheduleReconnect());
      tableSocket!.add(jsonEncode({'type': 'register', 'tableId': selectedTable}));
      connected = true; connectionMessage = 'Conectada al central';
    } catch (_) { _scheduleReconnect(); }
    if (mounted) setState(() {});
  }

  void _scheduleReconnect() {
    connected = false; connectionMessage = 'Reintentando conexión...';
    reconnectTimer?.cancel();
    reconnectTimer = Timer(const Duration(seconds: 3), _connectToCentral);
    if (mounted) setState(() {});
  }

  Future<bool> _pinDialog({String title = 'PIN de administrador'}) async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: Text(title), content: TextField(controller: c, obscureText: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'PIN')),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')), FilledButton(onPressed: () => Navigator.pop(context, c.text == adminPin), child: const Text('Entrar'))],
    ));
    c.dispose();
    return ok == true;
  }

  Future<void> _setupWizard() async {
    String newMode = 'central'; int newTable = 1; String ip = centralIp; String pin = adminPin;
    await showDialog(context: context, barrierDismissible: false, builder: (_) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
      title: const Text('Configuración inicial'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Instala el mismo APK en las 6 tablets y selecciona el rol de cada una.'),
        const SizedBox(height: 18),
        DropdownButtonFormField<String>(value: newMode, items: const [DropdownMenuItem(value:'central',child:Text('CENTRAL')),DropdownMenuItem(value:'mesa',child:Text('TABLET DE MESA'))], onChanged:(v){if(v!=null)setD(()=>newMode=v);}),
        if (newMode == 'mesa') ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(value:newTable, items:List.generate(tableCount,(i)=>DropdownMenuItem(value:i+1,child:Text('Mesa ${i+1}'))), onChanged:(v){if(v!=null)setD(()=>newTable=v);}),
          const SizedBox(height: 12),
          TextField(controller: TextEditingController(text: ip)..selection = TextSelection.collapsed(offset: ip.length), onChanged:(v)=>ip=v, keyboardType:TextInputType.number, decoration:const InputDecoration(labelText:'IP de la tablet CENTRAL', hintText:'Ej. 192.168.1.20')),
        ],
        const SizedBox(height: 12),
        TextField(obscureText:true, controller:TextEditingController(text:pin), onChanged:(v)=>pin=v, keyboardType:TextInputType.number, decoration:const InputDecoration(labelText:'PIN administrador')),
      ])),
      actions:[FilledButton(onPressed:() async { final p=await SharedPreferences.getInstance(); await p.setString('mode',newMode); await p.setInt('table',newTable); await p.setString('centralIp',ip.trim()); await p.setString('adminPin',pin.trim().isEmpty?defaultAdminPin:pin.trim()); mode=newMode;selectedTable=newTable;centralIp=ip.trim();adminPin=pin.trim().isEmpty?defaultAdminPin:pin.trim();Navigator.pop(ctx);if(mode=='central'){await _startServer();}else{await _connectToCentral();}if(mounted)setState((){});}, child:const Text('Guardar y comenzar'))]
    )));
  }

  Future<void> settings() async {
    if (mode == 'central' && !await _pinDialog()) return;
    await _setupWizard();
  }

  Future<void> closeDay() async {
    if (!await _pinDialog(title:'Cerrar día')) return;
    final total = history.fold<double>(0, (s,h)=>s+(h['total'] as num).toDouble());
    if (!mounted) return;
    await showDialog(context:context,builder:(_)=>AlertDialog(title:const Text('Cierre del día'),content:Text('Partidas finalizadas: ${history.length}\nTotal: C$ ${total.toStringAsFixed(2)}'),actions:[FilledButton(onPressed:()=>Navigator.pop(context),child:const Text('OK'))]));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body:Center(child:CircularProgressIndicator()));
    if (mode == 'unset') return _welcome();
    if (mode == 'mesa') return _tableView(games[selectedTable-1]);
    final active=games.where((g)=>g.playing).length;
    final dayTotal=history.fold<double>(0,(s,h)=>s+(h['total'] as num).toDouble());
    return Scaffold(
      appBar:AppBar(title:const Text('BILLAR CONTROL PRO'),actions:[Padding(padding:const EdgeInsets.symmetric(horizontal:12),child:Center(child:Text(serverOnline?'CENTRAL ONLINE':'CENTRAL OFFLINE'))),IconButton(onPressed:closeDay,icon:const Icon(Icons.summarize)),IconButton(onPressed:settings,icon:const Icon(Icons.settings))]),
      body:Padding(padding:const EdgeInsets.all(16),child:Column(children:[
        Row(children:[_stat('MESAS EN JUEGO','$active / $tableCount'),_stat('PARTIDAS HOY','${history.length}'),_stat('TOTAL HOY','C$ ${dayTotal.toStringAsFixed(2)}')]),
        const SizedBox(height:12),
        Card(child:ListTile(leading:const Icon(Icons.wifi),title:const Text('IP DEL CENTRAL'),subtitle:Text(localIp()),trailing:const Text('PUERTO 8080'))),
        const SizedBox(height:8),
        Expanded(child:GridView.builder(gridDelegate:const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount:2,childAspectRatio:1.25,crossAxisSpacing:12,mainAxisSpacing:12),itemCount:tableCount,itemBuilder:(_,i){final g=games[i];return Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Row(children:[Text('MESA ${g.tableId}',style:const TextStyle(fontSize:25,fontWeight:FontWeight.bold)),const Spacer(),Text(g.playing?'EN JUEGO':'LIBRE',style:TextStyle(fontWeight:FontWeight.bold,color:g.playing?Colors.greenAccent:Colors.orangeAccent))]),
          Text('C$ ${g.rate.toStringAsFixed(0)} / hora'),const Spacer(),Text('Inicio: ${hm(g.start)}'),Text('Fin: ${hm(g.end)}'),Text('Tiempo: ${duration(g)}'),Text('Total: C$ ${liveTotal(g).toStringAsFixed(2)}',style:const TextStyle(fontSize:22,fontWeight:FontWeight.bold)),
          const SizedBox(height:8),Row(children:[Expanded(child:FilledButton.icon(onPressed:g.playing?null:()=>startGame(g),icon:const Icon(Icons.play_arrow),label:const Text('INICIAR'))),const SizedBox(width:8),Expanded(child:FilledButton.tonalIcon(onPressed:g.playing?()=>finishGame(g):null,icon:const Icon(Icons.stop),label:const Text('FINALIZAR'))),IconButton(tooltip:'Nueva partida',onPressed:!g.playing&&g.finalized?()=>newGame(g):null,icon:const Icon(Icons.refresh))])
        ])));})),
        SizedBox(height:110,child:ListView.builder(itemCount:history.length>10?10:history.length,itemBuilder:(_,i){final h=history[i];return ListTile(leading:CircleAvatar(child:Text('${h['tableId']}')),title:Text('Mesa ${h['tableId']} • C$ ${(h['total'] as num).toDouble().toStringAsFixed(2)}'),subtitle:Text('${dateTime(DateTime.parse(h['start']))} → ${hm(DateTime.parse(h['end']))} • ${(h['minutes'] as num).toInt()} min'));}))
      ])));
  }

  Widget _welcome()=>Scaffold(body:Center(child:Card(child:Padding(padding:const EdgeInsets.all(30),child:Column(mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.sports_bar,size:70),const SizedBox(height:16),const Text('BILLAR CONTROL PRO',style:TextStyle(fontSize:30,fontWeight:FontWeight.bold)),const SizedBox(height:8),const Text('Configuración inicial del dispositivo'),const SizedBox(height:24),FilledButton.icon(onPressed:_setupWizard,icon:const Icon(Icons.settings),label:const Text('CONFIGURAR TABLET'))]))));

  Widget _stat(String a,String b)=>Expanded(child:Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(children:[Text(a),const SizedBox(height:4),Text(b,style:const TextStyle(fontSize:21,fontWeight:FontWeight.bold))]))));

  Widget _tableView(Game g)=>Scaffold(backgroundColor:Colors.black,appBar:AppBar(title:Text('MESA ${g.tableId}'),actions:[Padding(padding:const EdgeInsets.all(12),child:Center(child:Text(connected?'ONLINE':'OFFLINE'))),IconButton(onPressed:settings,icon:const Icon(Icons.settings))]),body:Center(child:Padding(padding:const EdgeInsets.all(28),child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[
    Text('MESA ${g.tableId}',style:const TextStyle(fontSize:52,fontWeight:FontWeight.bold)),const SizedBox(height:20),
    Text(g.playing?'EN JUEGO':(g.finalized?'PARTIDA FINALIZADA':'ESPERANDO'),style:TextStyle(fontSize:30,fontWeight:FontWeight.bold,color:g.playing?Colors.greenAccent:(g.finalized?Colors.blueAccent:Colors.orangeAccent))),
    const SizedBox(height:28),_line('Hora de inicio',hm(g.start)),_line('Hora de finalización',hm(g.end)),_line('Tiempo total',duration(g)),
    const Divider(height:50),const Text('TOTAL A PAGAR',style:TextStyle(fontSize:24)),Text('C$ ${liveTotal(g).toStringAsFixed(2)}',style:const TextStyle(fontSize:58,fontWeight:FontWeight.bold)),const SizedBox(height:16),Text('Tarifa: C$ ${g.rate.toStringAsFixed(0)} por hora'),const SizedBox(height:16),Text(connectionMessage,style:const TextStyle(fontSize:16))
  ])));

  Widget _line(String a,String b)=>Padding(padding:const EdgeInsets.symmetric(vertical:8),child:Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[Text(a,style:const TextStyle(fontSize:22)),Text(b,style:const TextStyle(fontSize:22,fontWeight:FontWeight.bold))]));
}
