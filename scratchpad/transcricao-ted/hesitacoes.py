# Para cada candidato a hesitação, quantas ocorrências na saída não existem
# na referência (alinhamento por caractere, sem pontuação).
import difflib, re, sys, unicodedata
def load(p):
    t=open(p,encoding='utf-8').read().replace('\r','')
    out=[]
    for b in t.split('\n\n'):
        l=[x for x in b.split('\n') if x.strip()]
        if len(l)>=3 and '-->' in l[1]:
            txt=''.join(l[2:])
            if '字幕:' in txt: continue
            out.append(txt)
    return ''.join(out)
def norm(s):
    s=unicodedata.normalize('NFKC',s).lower()
    return ''.join(c for c in s if c.isalnum())
ref=norm(load(sys.argv[1]))
cands=['まあ','まぁ','ま','あの','あのー','えー','えっと','ええ','うーん','こう','その','なんか','で','ね','あ']
for p in sys.argv[2:]:
    raw=load(p)
    hyp=norm(raw)
    sm=difflib.SequenceMatcher(None,ref,hyp,autojunk=False)
    inserted=[False]*len(hyp)
    for tag,i1,i2,j1,j2 in sm.get_opcodes():
        if tag in('insert','replace'):
            for j in range(j1,j2): inserted[j]=True
    print(p.split('/')[-2]+'/'+p.split('/')[-1])
    for c in cands:
        tot=ext=0
        for m in re.finditer(re.escape(c),hyp):
            # só a ocorrência que não é pedaço de palavra maior do mesmo tipo
            tot+=1
            if all(inserted[m.start():m.end()]): ext+=1
        if tot: print(f'  {c}: {ext}/{tot} a mais')
