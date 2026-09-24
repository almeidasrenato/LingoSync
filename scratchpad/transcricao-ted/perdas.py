# Legendas da referência que a saída não alcança (mais de metade apagada).
import difflib,sys,unicodedata
def load(p):
    t=open(p,encoding='utf-8').read().replace('\r','')
    out=[]
    for b in t.split('\n\n'):
        l=[x for x in b.split('\n') if x.strip()]
        if len(l)>=3 and '-->' in l[1]:
            txt=''.join(l[2:])
            if '字幕:' in txt: continue
            out.append((l[1][:12],txt))
    return out
norm=lambda s:''.join(c for c in unicodedata.normalize('NFKC',s).lower() if c.isalnum())
R=load(sys.argv[1]); H=load(sys.argv[2])
ref='';owner=[]
for k,(t,x) in enumerate(R):
    n=norm(x); ref+=n; owner+= [k]*len(n)
hyp=norm(''.join(x for _,x in H))
sm=difflib.SequenceMatcher(None,ref,hyp,autojunk=False)
lost=[0]*len(R)
for tag,i1,i2,j1,j2 in sm.get_opcodes():
    if tag=='delete':
        for i in range(i1,i2): lost[owner[i]]+=1
for k,(t,x) in enumerate(R):
    n=len(norm(x))
    if n and lost[k]/n>0.5: print(t,f'{lost[k]}/{n}',x)
