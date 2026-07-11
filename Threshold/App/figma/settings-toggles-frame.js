// One-shot Figma builder for the "Settings — Toggles" screen.
// File: HZwKuOv80n6a2UOtd49prN, page "Top-Dock Reconstruction" (canvas 0:1).
// Places a 1000x640 frame at (0, 3400) mirroring the dock+rail+content chrome,
// with three quick-toggle cards (Lighting & Color, Space & Audio, Performance)
// matching the SwiftUI Toggles settings page (ContentView+SettingsTab.swift).
//
// Replay via a SINGLE use_figma call when the Starter-plan rate limit resets
// (the cap is the blocker, not the View seat — see memory figma-ui-port).

const FR = {family:"Inter", style:"Regular"};
const FSB = {family:"Inter", style:"Semi Bold"};
const FB = {family:"Inter", style:"Bold"};
await figma.loadFontAsync(FR);
await figma.loadFontAsync(FSB);
await figma.loadFontAsync(FB);

function hx(hex, a=1){
  const r=parseInt(hex.slice(1,3),16)/255, g=parseInt(hex.slice(3,5),16)/255, b=parseInt(hex.slice(5,7),16)/255;
  return [{type:"SOLID", color:{r,g,b}, opacity:a}];
}
function rgba(r,g,b,a){ return [{type:"SOLID", color:{r:r/255,g:g/255,b:b/255}, opacity:a}]; }
const W70 = rgba(255,255,255,0.7), W40 = rgba(255,255,255,0.4), W90 = rgba(255,255,255,0.9);
const SEC = hx("#98989d");
const BLUE_FILL = rgba(10,132,255,0.18), BLUE_BORDER = rgba(10,132,255,0.5);

function T(str, font, size, fill){
  const t=figma.createText(); t.fontName=font; t.fontSize=size; t.characters=str; t.fills=fill; return t;
}
function R(w,h,fill,corner){
  const r=figma.createRectangle(); r.resize(w,h); r.fills=fill; if(corner) r.cornerRadius=corner; return r;
}
function AF(name, dir, o={}){
  const f=figma.createFrame(); f.name=name; f.layoutMode=dir; f.fills=[]; f.clipsContent=false;
  f.primaryAxisSizingMode="AUTO"; f.counterAxisSizingMode="AUTO";
  if(o.gap!==undefined) f.itemSpacing=o.gap;
  if(o.pad!==undefined){f.paddingTop=f.paddingBottom=f.paddingLeft=f.paddingRight=o.pad;}
  if(o.px!==undefined){f.paddingLeft=f.paddingRight=o.px;}
  if(o.py!==undefined){f.paddingTop=f.paddingBottom=o.py;}
  if(o.corner!==undefined) f.cornerRadius=o.corner;
  if(o.fill) f.fills=o.fill;
  if(o.stroke){f.strokes=o.stroke; f.strokeWeight=o.sw||1;}
  if(o.pa) f.primaryAxisAlignItems=o.pa;
  if(o.ca) f.counterAxisAlignItems=o.ca;
  return f;
}

function pill(label, active){
  const p=AF("pill-"+label,"HORIZONTAL",{gap:8, px:14, py:10, corner:22, ca:"CENTER"});
  if(active){ p.fills=BLUE_FILL; p.strokes=BLUE_BORDER; } else { p.strokes=rgba(255,255,255,0.14); }
  p.strokeWeight=1;
  p.appendChild(R(15,15, active?W90:W40, 4));
  p.appendChild(T(label, FSB, 13, active?hx("#ffffff"):SEC));
  return p;
}
function railBtn(label, active){
  const b=AF("rail-btn-"+label,"HORIZONTAL",{gap:10, pad:10, corner:12, ca:"CENTER"});
  if(active){ b.fills=BLUE_FILL; b.strokes=BLUE_BORDER; } else { b.strokes=rgba(255,255,255,0.1); }
  b.strokeWeight=1;
  b.appendChild(R(15,15, active?W90:W40, 4));
  b.appendChild(T(label, FSB, 12, active?hx("#ffffff"):SEC));
  return b;
}
function sw(on, accent){
  const s=AF("switch","HORIZONTAL",{corner:11, ca:"CENTER"});
  s.paddingLeft=s.paddingRight=2; s.paddingTop=s.paddingBottom=2;
  s.primaryAxisSizingMode="FIXED"; s.counterAxisSizingMode="FIXED"; s.resize(36,22);
  s.primaryAxisAlignItems = on ? "MAX" : "MIN";
  s.fills = on ? accent : rgba(255,255,255,0.18);
  const knob=figma.createEllipse(); knob.resize(18,18); knob.fills=hx("#ffffff"); s.appendChild(knob);
  return s;
}
function toggleRow(label, on, accent){
  const row=AF("toggle-"+label,"HORIZONTAL",{gap:10, ca:"CENTER"});
  const lg=AF("lbl","HORIZONTAL",{gap:8, ca:"CENTER"});
  lg.appendChild(R(15,15, on?W90:W40, 4));
  lg.appendChild(T(label, FR, 13, on?hx("#ffffff"):W70));
  row.appendChild(lg);
  const sp=AF("sp","HORIZONTAL",{}); sp.resize(1,1); row.appendChild(sp); sp.layoutGrow=1;
  row.appendChild(sw(on, accent));
  return row;
}
function card(title, accentHex, rows){
  const accent=hx(accentHex);
  const c=AF("card-"+title,"VERTICAL",{gap:10, pad:12, corner:12, fill:hx(accentHex,0.08)});
  const h=AF("hdr","HORIZONTAL",{gap:8, ca:"CENTER"});
  h.appendChild(R(15,15, accent, 4));
  h.appendChild(T(title, FB, 14, hx("#ffffff")));
  c.appendChild(h);
  const built=[];
  rows.forEach(r=>{ const tr=toggleRow(r.l, r.on, accent); c.appendChild(tr); built.push(tr); });
  return {c, built};
}
function segmented(items, activeIdx){
  const seg=AF("subtab-picker","HORIZONTAL",{gap:2, pad:2, corner:8, fill:hx("#2c2c2e")});
  items.forEach((it,i)=>{
    const cell=AF("seg-"+it,"HORIZONTAL",{px:10, py:6, corner:6, pa:"CENTER", ca:"CENTER"});
    if(i===activeIdx) cell.fills=hx("#48484a");
    cell.appendChild(T(it, i===activeIdx?FSB:FR, 12, i===activeIdx?hx("#ffffff"):SEC));
    seg.appendChild(cell);
  });
  return seg;
}

const root=AF("Settings — Toggles","VERTICAL",{gap:10, px:12, py:10, corner:20, fill:hx("#1a1a1c"), stroke:rgba(255,255,255,0.08), sw:1});
root.x=0; root.y=3400;
figma.currentPage.appendChild(root);
root.primaryAxisSizingMode="FIXED"; root.counterAxisSizingMode="FIXED"; root.resize(1000,640);
root.clipsContent=true;

const topRow=AF("top","HORIZONTAL",{ca:"START"});
root.appendChild(topRow); topRow.layoutSizingHorizontal="FILL";
const dock=AF("dock-ornament","HORIZONTAL",{gap:10, px:14, py:10, corner:18, fill:rgba(5,5,5,0.92), stroke:rgba(255,255,255,0.1), sw:1, ca:"CENTER"});
["Explore","Shape","Visualizations","Music"].forEach(n=> dock.appendChild(pill(n,false)));
topRow.appendChild(dock);
const topSp=AF("sp","HORIZONTAL",{}); topSp.resize(1,1); topRow.appendChild(topSp); topSp.layoutGrow=1;

const body=AF("body","HORIZONTAL",{}); root.appendChild(body);
body.layoutSizingHorizontal="FILL"; body.layoutGrow=1; body.clipsContent=true;

const rail=AF("section-rail","VERTICAL",{gap:8, px:10, py:8}); body.appendChild(rail);
rail.primaryAxisSizingMode="FIXED"; rail.counterAxisSizingMode="FIXED"; rail.resize(190,560);
rail.layoutSizingVertical="FILL";
["Parameters","Formula","Space","Performance"].forEach(n=>{ const b=railBtn(n,false); rail.appendChild(b); b.layoutSizingHorizontal="FILL"; });
const railSp=AF("sp","VERTICAL",{}); railSp.resize(1,1); rail.appendChild(railSp); railSp.layoutGrow=1;
const railDiv=R(170,1, rgba(255,255,255,0.1)); rail.appendChild(railDiv); railDiv.layoutSizingHorizontal="FILL";
const gB=railBtn("Gestures",false); rail.appendChild(gB); gB.layoutSizingHorizontal="FILL";
const sB=railBtn("Settings",true); rail.appendChild(sB); sB.layoutSizingHorizontal="FILL";

const vdiv=R(1,560, rgba(255,255,255,0.1)); body.appendChild(vdiv); vdiv.layoutSizingVertical="FILL";

const rightCol=AF("right-col","VERTICAL",{}); body.appendChild(rightCol);
rightCol.layoutSizingHorizontal="FILL"; rightCol.layoutGrow=1; rightCol.clipsContent=true;

const panel=AF("content-panel","VERTICAL",{gap:14, px:16, py:14}); rightCol.appendChild(panel);
panel.layoutSizingHorizontal="FILL"; panel.layoutGrow=1;

const hdr=AF("header","HORIZONTAL",{gap:8, ca:"CENTER"}); panel.appendChild(hdr); hdr.layoutSizingHorizontal="FILL";
hdr.appendChild(R(15,15, W70, 4));
hdr.appendChild(T("Settings", FB, 15, hx("#ffffff")));
const hSp=AF("sp","HORIZONTAL",{}); hSp.resize(1,1); hdr.appendChild(hSp); hSp.layoutGrow=1;

const seg = segmented(["Display","Toggles","Gestures","Sharing","Export","Advanced"], 1);
panel.appendChild(seg); seg.layoutSizingHorizontal="FILL"; seg.children.forEach(c=> c.layoutGrow=1);

const desc=T("Master on/off switches for parameter categories scattered across the Effects, Shape, and Advanced tabs. Flipping one here is identical to toggling it on its home tab.", FR, 11, SEC);
panel.appendChild(desc); desc.layoutSizingHorizontal="FILL";

const c1=card("Lighting & Color","#ffd60a",[
  {l:"Glow",on:true},{l:"Bloom",on:false},{l:"Fog",on:true},{l:"Hue Rotation",on:false},
  {l:"Pulse",on:false},{l:"Gradient Cycle",on:true},{l:"Linear Rail",on:false},
  {l:"Beat Flash",on:false},{l:"Julia Drift",on:false},
]);
panel.appendChild(c1.c); c1.c.layoutSizingHorizontal="FILL"; c1.built.forEach(r=> r.layoutSizingHorizontal="FILL");

const c2=card("Space & Audio","#40c8e0",[
  {l:"Sphere Projection",on:true},{l:"Audio Reactive",on:false},
]);
panel.appendChild(c2.c); c2.c.layoutSizingHorizontal="FILL"; c2.built.forEach(r=> r.layoutSizingHorizontal="FILL");

const c3=card("Performance","#ff9f0a",[
  {l:"Coherent Packet",on:false},
  {l:"Self-Shadows",on:true},{l:"Bounding Sphere Skip",on:false},
]);
panel.appendChild(c3.c); c3.c.layoutSizingHorizontal="FILL"; c3.built.forEach(r=> r.layoutSizingHorizontal="FILL");

const hdiv=R(960,1, rgba(255,255,255,0.1)); rightCol.appendChild(hdiv); hdiv.layoutSizingHorizontal="FILL";
const bottom=AF("bottom-bar","HORIZONTAL",{gap:12, px:12, py:8, ca:"CENTER"}); rightCol.appendChild(bottom); bottom.layoutSizingHorizontal="FILL";
bottom.appendChild(T("Toggles persist per category — no separate state.", FR, 12, SEC));
const bSp=AF("sp","HORIZONTAL",{}); bSp.resize(1,1); bottom.appendChild(bSp); bSp.layoutGrow=1;
const exit=AF("exit","HORIZONTAL",{px:14, py:8, corner:18, fill:rgba(10,132,255,0.9), ca:"CENTER"});
exit.appendChild(T("Exit Immersive Space", FSB, 12, hx("#ffffff"))); bottom.appendChild(exit);

figma.currentPage.selection=[root];
figma.viewport.scrollAndZoomIntoView([root]);
return {id: root.id, name: root.name, x: root.x, y: root.y};
