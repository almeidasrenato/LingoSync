import json, sys
S=sys.argv[1]; srt=sys.argv[2]
v=json.load(open(S,encoding="utf-8"))
def sec(t):
    h,m,r=t.split(":"); s,ms=r.split(","); return int(h)*3600+int(m)*60+int(s)+int(ms)/1000
mist=0
for b in open(srt,encoding="utf-8").read().strip().split("\n\n"):
    L=[l for l in b.split("\n") if l.strip()]
    tc=[l for l in L if "-->" in l]
    if not tc: continue
    a,bb=[x.strip() for x in tc[0].split("-->")]
    ini,fim=sec(a),sec(bb)
    quem={}
    for f in v:
        ov=min(fim,f["fim"])-max(ini,f["inicio"])
        if ov>0.3: quem[f["quem"]]=quem.get(f["quem"],0)+round(ov,1)
    if len(quem)>1: mist+=1
    corpo=" ".join(L[L.index(tc[0])+1:])
    print(f"  {ini:5.2f}-{fim:5.2f} {str(quem):<20} {corpo[:56]}")
print(f"  → {mist} legendas com duas pessoas")
