from pathlib import Path

p = Path('/tmp/billar_app/lib/main.dart')
s = p.read_text()

# Asegurar que cobrar deje la mesa realmente disponible y conserve la partida en historial.
old = '''  Future<void> _payGame(int id) async {
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
  }'''
new = '''  Future<void> _payGame(int id) async {
    if (mode != 'central' || !adminUnlocked) return;
    final g = games[id - 1];
    if (g.active || g.paid || g.finishedAt == null) return;
    final ok = await _confirm(
      'Cobrar mesa $id',
      'Confirmar cobro de C$ ${g.total.toStringAsFixed(0)}. La mesa quedará disponible después del cobro.',
    );
    if (!ok) return;
    final amount = g.total;
    setState(() {
      g.paid = true;
      dailyTotal += amount;
    });
    await _persist();
    _broadcast(id);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (!mounted) return;
    setState(() => games[id - 1] = Game(tableId: id, rate: defaultRates[id - 1]));
    await _persist();
    _broadcast(id);
  }'''
if old in s:
    s = s.replace(old, new, 1)

# Evitar que una tarifa guardada antiguamente vuelva a aparecer en una partida nueva.
for i in range(5):
    s = s.replace(f"games[{i}].rate = games[{i}].rate;", f"games[{i}].rate = defaultRates[{i}];")

p.write_text(s)
