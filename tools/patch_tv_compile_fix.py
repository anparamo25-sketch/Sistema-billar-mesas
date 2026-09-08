from pathlib import Path

p = Path('/tmp/billar_app/lib/main.dart')
s = p.read_text()
start = s.find('  String _tvHtml()')
end = s.find('  Future<void> _connectToCentral()', start)

if start >= 0 and end > start:
    method = '''  String _tvHtml() => r"""<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Billares Don Miguel</title>
<style>html,body{margin:0;width:100%;height:100%;font-family:Arial,sans-serif;background:#101216;color:#fff}body{display:flex;flex-direction:column}header{text-align:center;padding:18px;background:#171a20}h1{margin:0;font-size:42px}#clock{font-size:24px;margin-top:5px}.grid{flex:1;display:grid;grid-template-columns:repeat(2,1fr);gap:14px;padding:14px}.card{border-radius:18px;padding:18px;background:#126b35}.playing{background:#a51f28}.pending{background:#a87900}.name{font-size:30px;font-weight:bold}.state{font-size:24px;margin:8px 0}.time{font-size:42px;font-weight:bold}.info{font-size:20px;margin-top:6px}.total{font-size:28px;font-weight:bold;margin-top:6px}@media(min-width:1200px){.grid{grid-template-columns:repeat(3,1fr)}.card:last-child{grid-column:2}}</style></head>
<body><header><h1>Billares Don Miguel</h1><div id="clock">--:-- --</div></header><main id="grid" class="grid"></main>
<script>
const grid=document.getElementById("grid");
function money(v){return "C$"+Number(v||0).toFixed(0)}
function clock(){document.getElementById("clock").textContent=new Date().toLocaleTimeString("es-NI",{hour:"2-digit",minute:"2-digit",second:"2-digit",hour12:true})}setInterval(clock,1000);clock();
function elapsed(a,b){if(!a)return"00:00:00";let x=Math.max(0,new Date(b||Date.now()).getTime()-new Date(a).getTime())/1000,h=Math.floor(x/3600),m=Math.floor(x%3600/60),s=Math.floor(x%60);return String(h).padStart(2,"0")+":"+String(m).padStart(2,"0")+":"+String(s).padStart(2,"0")}
function render(tables){grid.innerHTML=tables.map(g=>{let c=g.active?"playing":(g.finishedAt&&!g.paid?"pending":"");let state=g.active?"OCUPADA":(g.finishedAt&&!g.paid?"PENDIENTE DE COBRO":"DISPONIBLE");let tm=elapsed(g.startedAt,g.active?null:g.finishedAt);return "<section class=\"card "+c+"\"><div class=\"name\">Mesa "+g.tableId+"</div><div class=\"state\">"+state+"</div><div class=\"time\">"+tm+"</div><div class=\"info\">Inicio: "+(g.startedAt?new Date(g.startedAt).toLocaleTimeString("es-NI",{hour:"2-digit",minute:"2-digit",hour12:true}):"--")+"</div><div class=\"info\">Tarifa: "+money(g.rate)+"/hora</div><div class=\"total\">Total: "+money(g.total)+"</div></section>"}).join("")}
function connect(){let p=location.protocol==="https:"?"wss://":"ws://";let ws=new WebSocket(p+location.host);ws.onopen=()=>ws.send(JSON.stringify({type:"register",role:"tv"}));ws.onmessage=e=>{try{let m=JSON.parse(e.data);if(m.type==="tv_state")render(m.tables||[])}catch(x){}};ws.onclose=()=>setTimeout(connect,2000)}connect();
</script></body></html>""";
'''
    s = s[:start] + method + s[end:]
    p.write_text(s)
    print('Parche TV de compilacion aplicado correctamente')
else:
    print('No fue necesario reemplazar _tvHtml')
