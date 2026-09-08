import base64
from pathlib import Path

p = Path('/tmp/billar_app/lib/main.dart')
s = p.read_text()
start = s.find('  String _tvHtml()')
end = s.find('  Future<void> _connectToCentral()', start)

if start >= 0 and end > start:
    html = '''<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Billares Don Miguel</title><style>html,body{margin:0;background:#101216;color:#fff;font-family:Arial;height:100%;overflow:hidden}header{text-align:center;padding:12px;font-size:28px;font-weight:bold}.grid{display:grid;grid-template-columns:repeat(2,1fr);gap:12px;padding:12px}.card{padding:16px;border-radius:16px;background:#252830}.playing{background:#9d2525}.pending{background:#9b7600}.free{background:#146b39}.name{font-size:25px;font-weight:bold}.state{font-size:20px;margin:6px 0}.time{font-size:30px;font-weight:bold}.info{font-size:17px;margin-top:5px}@media(min-width:1100px){.grid{grid-template-columns:repeat(3,1fr)}}</style></head><body><header>BILLARES DON MIGUEL</header><main id="grid" class="grid"></main><script>var games=[];var grid=document.getElementById("grid");var rates=[120,120,100,100,70];function money(v){return "C$"+Number(v||0).toFixed(0)}function time(a,b){if(!a)return"00:00:00";var x=Math.max(0,new Date(b||Date.now())-new Date(a));var s=Math.floor(x/1000),h=Math.floor(s/3600);s%=3600;var m=Math.floor(s/60);s%=60;return[h,m,s].map(function(v){return String(v).padStart(2,"0")}).join(":")}function render(){grid.innerHTML="";for(var i=1;i<=5;i++){var g=games[i-1]||{},active=!!g.startedAt&&!g.finishedAt,finished=!!g.finishedAt;var c=document.createElement("div");c.className="card "+(active?"playing":finished?"pending":"free");c.innerHTML="<div class='name'>MESA "+i+"</div><div class='state'>"+(active?"EN JUEGO":finished?"PENDIENTE DE COBRO":"LIBRE")+"</div><div class='time'>"+time(g.startedAt,g.finishedAt)+"</div><div class='info'>Tarifa: "+money(rates[i-1])+"/hora</div><div class='info'>Total: "+money(active?((Date.now()-new Date(g.startedAt).getTime())/3600000*rates[i-1]):(g.total||0))+"</div>"+(g.startedAt?"<div class='info'>Inicio: "+new Date(g.startedAt).toLocaleTimeString()+"</div>":"")+(g.finishedAt?"<div class='info'>Fin: "+new Date(g.finishedAt).toLocaleTimeString()+"</div>":"");grid.appendChild(c)}}function update(m){if(m&&m.type==="tv_state"&&Array.isArray(m.tables))games=m.tables;else if(Array.isArray(m))games=m;else if(m&&Array.isArray(m.games))games=m.games;render()}function connect(){var ws;try{ws=new WebSocket("ws://"+location.host);ws.onmessage=function(e){try{update(JSON.parse(e.data))}catch(_){} };ws.onclose=function(){setTimeout(connect,2000)}}catch(_){setTimeout(connect,2000)}}setInterval(render,1000);render();connect();</script></body></html>'''
    encoded = base64.b64encode(html.encode('utf-8')).decode('ascii')
    method = "  String _tvHtml() => utf8.decode(base64Decode('" + encoded + "'));\n"
    s = s[:start] + method + s[end:]
    p.write_text(s)
    print('Parche TV definitivo aplicado correctamente.')
else:
    print('No fue necesario aplicar el parche TV.')
