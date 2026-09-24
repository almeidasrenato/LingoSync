import csv,re,sys
rows=list(csv.DictReader(open(sys.argv[1]),delimiter='\t'))
def txt(s): return re.sub(r'\s*\{[^}]*\}','',s).strip()
F=[(float(r['rawDiff']),int(r['cellsOn']),int(r['cellXor'])) for r in rows]
S=[(int(r['quadro']),txt(r['texto'])) for r in rows if r['ocrMs']]
noiseT,noiseE,sig=[],[],[]   # quadros internos: legenda constante / faixa vazia / trocas
for (qa,ta),(qb,tb) in zip(S,S[1:]):
    inner=F[qa+1:qb+1]
    if ta==tb and ta: noiseT+=inner
    elif ta==tb: noiseE+=inner
    else: sig.append((qa,ta[:28],tb[:28],max(x[0] for x in inner),max(x[2] for x in inner)))
def q(v,p): v=sorted(v); return v[min(len(v)-1,int(len(v)*p))]
for nome,col in (('rawDiff',0),('cellXor',2)):
    nt=[x[col] for x in noiseT]; ne=[x[col] for x in noiseE]; sg=[s[3 if col==0 else 4] for s in sig]
    print(f"{nome}: legenda parada p50 {q(nt,.5)} p99 {q(nt,.99)} max {max(nt)} | faixa vazia p99 {q(ne,.99)} max {max(ne)} | trocas: min {min(sg)} p10 {q(sg,.1)} mediana {q(sg,.5)}")
print('cellsOn com legenda p5 %d p50 %d | vazio p50 %d p99 %d max %d'%(q([x[1] for x in noiseT],.05),q([x[1] for x in noiseT],.5),q([x[1] for x in noiseE],.5),q([x[1] for x in noiseE],.99),max(x[1] for x in noiseE)))
print('trocas com menor sinal de mascara:')
for s in sorted(sig,key=lambda s:s[4])[:6]: print('  q%d %r -> %r raw %.1f xor %d'%s)
print('trocas com menor sinal cru:')
for s in sorted(sig,key=lambda s:s[3])[:4]: print('  q%d %r -> %r raw %.1f xor %d'%s)
