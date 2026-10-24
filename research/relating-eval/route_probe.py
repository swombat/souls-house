# Route probe (2026-10-08): replay real conversation moments from results/v0-full through the
# routes the house actually serves, at the house's 16k output budget. Needs OPENROUTER_API_KEY.
# Writes results/route-probe.jsonl.
import json,glob,os,time,urllib.request,concurrent.futures as cf
KEY=os.environ['OPENROUTER_API_KEY']
base=os.path.join(os.path.dirname(os.path.abspath(__file__)),'results','v0-full','deepseek_deepseek-v4.1-flash')
ctxs=[]
for f in sorted(glob.glob(base+'/p*_r0/main.json')):
    d=json.load(open(f));T=d['turns']
    for k in (5,10,15):
        msgs=[{"role":"system","content":d['system_prompt']}]
        for t in T[:k-1]:
            msgs+= [{"role":"user","content":t['user']},{"role":"assistant","content":t['assistant']}]
        msgs.append({"role":"user","content":T[k-1]['user']})
        ctxs.append((os.path.basename(os.path.dirname(f))+f'/t{k}',msgs))
ARMS={'ds_fireworks16k':('deepseek/deepseek-v4.1-flash','fireworks/us',16384),
      'ds_deepseek16k':('deepseek/deepseek-v4.1-flash','deepseek',16384),
      'haiku_anthropic':('anthropic/claude-haiku-5.5','anthropic',16384)}
def call(arm,ctx):
    model,prov,mt=ARMS[arm];name,msgs=ctx
    body={"model":model,"messages":msgs,"max_tokens":mt,"provider":{"order":[prov],"allow_fallbacks":False},"usage":{"include":True}}
    t0=time.time()
    try:
        r=urllib.request.urlopen(urllib.request.Request("https://openrouter.ai/api/v1/chat/completions",json.dumps(body).encode(),{"Authorization":"Bearer "+KEY,"Content-Type":"application/json"}),timeout=300)
        d=json.load(r);ch=d['choices'][0];u=d.get('usage',{})
        txt=(ch['message'].get('content') or '').strip()
        return dict(arm=arm,ctx=name,ok=True,empty=not txt,finish=ch.get('finish_reason'),provider=d.get('provider'),secs=round(time.time()-t0,1),
            out=u.get('completion_tokens'),reasoning=(u.get('completion_tokens_details') or {}).get('reasoning_tokens'),
            cost=u.get('cost') or (u.get('cost_details') or {}).get('upstream_inference_cost') or 0,words=len(txt.split()))
    except Exception as e:
        return dict(arm=arm,ctx=name,ok=False,error=str(e)[:200],secs=round(time.time()-t0,1))
jobs=[(a,c) for a in ARMS for c in ctxs]
out=open(os.path.join(os.path.dirname(os.path.abspath(__file__)),'results','route-probe.jsonl'),'w')
with cf.ThreadPoolExecutor(12) as ex:
    for r in ex.map(lambda j: call(*j), jobs):
        out.write(json.dumps(r)+'\n'); out.flush()
