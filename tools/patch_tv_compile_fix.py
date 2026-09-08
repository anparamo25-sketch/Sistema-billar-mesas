import json
from pathlib import Path

p = Path('/tmp/billar_app/lib/main.dart')
s = p.read_text()
start = s.find('  String _tvHtml()')
end = s.find('  Future<void> _connectToCentral()', start)

if start >= 0 and end > start:
    html = r'''<!doctype html>
<html lang="es">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Billares Don Miguel</title>
<style>body{margin:0;background:#111;color:#fff;font-family:Arial,sans-serif}header{padding:18px;text-align:center;font-size:28px;font-weight:bold}#grid{display:grid;grid-template-columns:repeat(5,1fr);gap:14px;padding:14px}.card{background:#222;border-radius:14px;padding:16px;text-align:center;min-height:180px}.free{border:3px solid #36c96b}.busy{border:3px solid #e0a82e}.done{border:3px solid #e05252}.name{font-size:24px;font-weight:bold}.state{font-size:18px;margin:12px 0}.value{font-size:20px;margin:7px 0}.small{font-size:15px;color:#bbb}@media(max-width:900px){#grid{grid-template-columns:repeat(2,1fr)}}</style>
</head><body><header>BILLARES DON MIGUEL</header><div id="grid"></div><script>
const rates=[120,120,100,100,70];const grid=document.getElementById("grid");let games={};
function money(v){return "C$"+Number(v||0).toFixed(0)}
function elapsed(a,b){if(!a)return "00:00:00";let x=new Date(a).getTime(),y=b?new Date(b).getTime():Date.now(),sec=Math.max(0,Math.floor((y-x)/1000)),h=Math.floor(sec/3600),m=Math.floor(sec%3600/60),s=sec%60;return [h,m,s].map(v=>String(v).padStart(2,"0")).join(":")}
function render(){grid.innerHTML="";for(let i=1;i<=5;i++){let g=games[i]||{},active=!!g.startedAt&&!g.finishedAt,finished=!!g.finishedAt,cls=active?"busy":finished?"done":"free",state=active?"EN JUEGO":finished?"PENDIENTE DE COBRO":"LIBRE",rate=rates[i-1],total=active?((Date.now()-new Date(g.startedAt).getTime())/3600000*rate):(g.total||0),card=document.createElement("div");card.className="card "+cls;card.innerHTML=`<div class="name">MESA ${i}</div><div class="state">${state}</div><div class="value">Tiempo: ${elapsed(g.startedAt,g.finishedAt)}</div><div class="value">Tarifa: ${money(rate)}/hora</div><div class="value">Total: ${money(total)}</div>`+(g.startedAt?`<div class="small">Inicio: ${new Date(g.startedAt).toLocaleTimeString()}</div>`:"")+(g.finishedAt?`<div class="small">Fin: ${new Date(g.finishedAt).toLocaleTimeString()}</div>`:"");grid.appendChild(card)}}
function update(data){games={};if(Array.isArray(data)){data.forEach(g=>{if(g&&g.tableId)games[g.tableId]=g})}else if(data&&data.games){data.games.forEach(g=>{if(g&&g.tableId)games[g.tableId]=g})}render()}
setInterval(render,1000);render();function connect(){try{let ws=new WebSocket("ws://"+location.host);ws.onmessage=e=>{try{update(JSON.parse(e.data))}catch(_){}};ws.onclose=()=>setTimeout(connect,2000)}catch(_){setTimeout(connect,2000)}}connect();
</script></body></html>'''
    # Solo una barra: \\$ produciría una interpolación Dart accidental.
    dart_html = json.dumps(html, ensure_ascii=False).replace('$', r'\$')
    method = '  String _tvHtml() => ' + dart_html + ';\n'
    s = s[:start] + method + s[end:]
    p.write_text(s)
    print('Parche TV aplicado correctamente.')
else:
    print('No fue necesario aplicar el parche TV.')
