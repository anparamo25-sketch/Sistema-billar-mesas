from pathlib import Path

p = Path('/tmp/billar_app/lib/main.dart')
s = p.read_text()

# Avoid double :8080 and accept either a plain IP or IP:port in the Mesa setup.
s = s.replace(
"  String centralIp = '';\n  String adminPin = defaultAdminPin;",
"  String centralIp = '';\n  String adminPin = defaultAdminPin;\n  bool reconnectScheduled = false;"
)

old_ip = """  Future<String> _localIp() async {\n    try {\n      final interfaces = await NetworkInterface.list(\n        includeLoopback: false,\n        type: InternetAddressType.IPv4,\n      );\n      for (final n in interfaces) {\n        for (final a in n.addresses) {\n          if (!a.isLoopback && a.type == InternetAddressType.IPv4) {\n            return a.address;\n          }\n        }\n      }\n    } catch (_) {}\n    return '';\n  }\n"""
new_ip = """  Future<String> _localIp() async {\n    try {\n      final interfaces = await NetworkInterface.list(\n        includeLoopback: false,\n        type: InternetAddressType.IPv4,\n      );\n      String? fallback;\n      for (final n in interfaces) {\n        for (final a in n.addresses) {\n          if (a.isLoopback || a.type != InternetAddressType.IPv4) continue;\n          final ip = a.address;\n          fallback ??= ip;\n          final privateLan =\n              ip.startsWith('192.168.') ||\n              ip.startsWith('10.') ||\n              RegExp(r'^172\\.(1[6-9]|2[0-9]|3[0-1])\\.').hasMatch(ip);\n          if (privateLan) return ip;\n        }\n      }\n      return fallback ?? '';\n    } catch (_) {\n      return '';\n    }\n  }\n"""
if old_ip not in s:
    raise SystemExit('No se encontró _localIp')
s = s.replace(old_ip, new_ip)

old_connect = """  Future<void> _connectToCentral() async {\n    if (centralIp.trim().isEmpty) {\n      if (mounted) setState(() => status = 'Falta la IP de la CENTRAL');\n      return;\n    }\n    try {\n      await tableSocket?.close();\n      final socket =\n          await WebSocket.connect('ws://${centralIp.trim()}:$serverPort');\n      tableSocket = socket;\n      if (mounted) setState(() => status = 'Conectado a CENTRAL');\n      socket.listen((data) {\n        try {\n          final m = Map<String, dynamic>.from(jsonDecode(data));\n          if (m['type'] != 'state') return;\n\n          // SEGURIDAD: esta tablet solo acepta datos de SU mesa.\n          final receivedId = (m['tableId'] as num?)?.toInt() ?? 0;\n          if (receivedId != tableId) return;\n\n          final raw = m['game'];\n          if (raw is! Map) return;\n          games[tableId - 1] =\n              Game.fromJson(Map<String, dynamic>.from(raw));\n          if (mounted) setState(() {});\n        } catch (_) {}\n      }, onDone: _scheduleReconnect, onError: (_, __) {\n        _scheduleReconnect();\n      });\n      socket.add(jsonEncode({'type': 'register', 'tableId': tableId}));\n    } catch (_) {\n      if (mounted) setState(() => status = 'No conectado');\n      _scheduleReconnect();\n    }\n  }\n\n  void _scheduleReconnect() {\n    Future.delayed(const Duration(seconds: 3), () {\n      if (mounted && mode == 'table') _connectToCentral();\n    });\n  }\n"""
new_connect = """  String _centralWsUrl() {\n    var value = centralIp.trim();\n    value = value.replaceFirst(RegExp(r'^wss?://', caseSensitive: false), '');\n    value = value.replaceFirst(RegExp(r'/+$'), '');\n    // The setup field may contain either 192.168.1.20 or 192.168.1.20:8080.\n    // If a port is supplied, keep it; otherwise use the application's port.\n    final uri = Uri.tryParse('ws://$value');\n    if (uri != null && uri.host.isNotEmpty && uri.port != 0) {\n      return 'ws://${uri.host}:${uri.port}';\n    }\n    return 'ws://$value:$serverPort';\n  }\n\n  Future<void> _connectToCentral() async {\n    if (centralIp.trim().isEmpty) {\n      if (mounted) setState(() => status = 'Falta la IP de la CENTRAL');\n      return;\n    }\n    try {\n      await tableSocket?.close();\n      final url = _centralWsUrl();\n      if (mounted) setState(() => status = 'Conectando a $url...');\n      final socket = await WebSocket.connect(\n        url,\n        timeout: const Duration(seconds: 5),\n      );\n      reconnectScheduled = false;\n      tableSocket = socket;\n      if (mounted) setState(() => status = 'Conectado a CENTRAL');\n      socket.listen((data) {\n        try {\n          final m = Map<String, dynamic>.from(jsonDecode(data));\n          if (m['type'] != 'state') return;\n\n          // SEGURIDAD: esta tablet solo acepta datos de SU mesa.\n          final receivedId = (m['tableId'] as num?)?.toInt() ?? 0;\n          if (receivedId != tableId) return;\n\n          final raw = m['game'];\n          if (raw is! Map) return;\n          games[tableId - 1] =\n              Game.fromJson(Map<String, dynamic>.from(raw));\n          if (mounted) setState(() {});\n        } catch (_) {}\n      }, onDone: _scheduleReconnect, onError: (_, __) {\n        _scheduleReconnect();\n      });\n      socket.add(jsonEncode({'type': 'register', 'tableId': tableId}));\n    } catch (e) {\n      if (mounted) setState(() => status = 'No conectado: ${e.toString()}');\n      _scheduleReconnect();\n    }\n  }\n\n  void _scheduleReconnect() {\n    if (reconnectScheduled) return;\n    reconnectScheduled = true;\n    Future.delayed(const Duration(seconds: 3), () {\n      reconnectScheduled = false;\n      if (mounted && mode == 'table') _connectToCentral();\n    });\n  }\n"""
if old_connect not in s:
    raise SystemExit('No se encontró _connectToCentral')
s = s.replace(old_connect, new_connect)

# Make the UI explicit: the user should normally enter only the IP; both forms are accepted.
s = s.replace(
"labelText: 'IP de la CENTRAL',\n                            hintText: 'Ejemplo: 192.168.1.20',",
"labelText: 'IP de la CENTRAL',\n                            hintText: 'Ejemplo: 192.168.1.20 o 192.168.1.20:8080',"
)
s = s.replace(
"'La CENTRAL usa el puerto 8080. Todas las tablets deben estar en la misma Wi-Fi.',",
"'Puede escribir solo la IP o IP:puerto. Si escribe solo la IP, se usará automáticamente el puerto 8080. Todas las tablets deben estar en la misma Wi-Fi.',"
)

p.write_text(s)
print('Parche de red aplicado correctamente')
