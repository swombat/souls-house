import sys
import json,re
d=json.load(open(sys.argv[2] if len(sys.argv) > 2 else 'regexes.json'))
def combine(src):
    # \udXXX high + low literal or low class  ->  code points
    out=[];i=0;n=len(src)
    def cp(h,l): return 0x10000+((h-0xD800)<<10)+(l-0xDC00)
    hi=re.compile(r'\\u(d[89ab][0-9a-f]{2})',re.I)
    while i<n:
        m=hi.match(src,i)
        if m:
            h=int(m.group(1),16); j=m.end()
            lm=re.match(r'\\u(d[c-f][0-9a-f]{2})',src[j:],re.I)
            if lm:
                out.append('\\u{%X}'%cp(h,int(lm.group(1),16))); i=j+lm.end(); continue
            if src[j]=='[':
                k=src.index(']',j); body=src[j+1:k]
                items=re.findall(r'\\u(d[c-f][0-9a-f]{2})(?:-\\u(d[c-f][0-9a-f]{2}))?',body,re.I)
                rebuilt=''.join(('\\u{%X}'%cp(h,int(a,16)))+(('-\\u{%X}'%cp(h,int(b,16))) if b else '') for a,b in items)
                assert re.sub(r'\\u(d[c-f][0-9a-f]{2})(?:-\\u(d[c-f][0-9a-f]{2}))?','',body,flags=re.I)=='', body
                out.append('['+rebuilt+']'); i=k+1; continue
            raise Exception('lone high at %d: %s'%(i,src[i:i+30]))
        if src[i]=='\\':
            if src[i+1]=='x':
                out.append('\\u00'+src[i+2:i+4].upper()); i+=4; continue
            out.append(src[i:i+2]); i+=2; continue
        out.append(src[i]); i+=1
    return ''.join(out)
def anchors(src):
    # outside character classes, JS ^ and $ (no m flag) mean start/end of input
    out=[];i=0;cls=False
    while i<len(src):
        c=src[i]
        if c=='\\': out.append(src[i:i+2]); i+=2; continue
        if cls:
            if c==']': cls=False
            out.append(c)
        else:
            if c=='[':
                cls=True; out.append(c)
                if src[i+1:i+2]=='^': out.append('^'); i+=1
                if src[i+1:i+2]==']': out.append(']'); i+=1
            elif c=='^': out.append('\\A')
            elif c=='$': out.append('\\z')
            else: out.append(c)
        i+=1
    return ''.join(out)
res={"source":"twitter-text 3.1.0 (npm) and twemoji-parser 11.0.2, converted from their JS regexes by surrogate-pair → code-point rewriting and ^/$ → \\A/\\z outside classes; regenerate rather than edit",
     "config":d["config"]}
for k in ['extractUrl','invalidUrlWithoutProtocolPrecedingChars','validAsciiDomain','validTcoUrl','emoji']:
    s,f=d[k]; res[k]={"source":anchors(combine(s)),"ignore_case":'i' in f}
json.dump(res,open(sys.argv[1],'w'),ensure_ascii=True,indent=1)
print({k:len(v["source"]) for k,v in res.items() if isinstance(v,dict) and "source" in v})

# Ruby's /i folds some characters to several (ß ~ ss); JS /i does not. So
# instead of /i, spell out both cases of every single-character letter.
def swap(ch):
    alts={ch.lower(),ch.upper()}
    return sorted(a for a in alts if len(a)==1 and a!=ch)
def tok_char(src,i):
    # returns (char or None, token text, next index)
    if src[i]=='\\':
        m=re.match(r'\\u\{([0-9A-Fa-f]+)\}',src[i:]) or re.match(r'\\u([0-9A-Fa-f]{4})',src[i:])
        if m: return chr(int(m.group(1),16)), m.group(0), i+len(m.group(0))
        return None, src[i:i+2], i+2
    return src[i], src[i], i+1
def esc(ch):
    return '\\u{%X}'%ord(ch) if ord(ch)>127 or not ch.isalnum() else ch
def caseless(src):
    out=[];i=0;cls=False
    while i<len(src):
        c=src[i]
        if not cls and c=='[':
            cls=True; out.append('['); i+=1
            if src[i:i+1]=='^': out.append('^'); i+=1
            if src[i:i+1]==']': out.append(']'); i+=1
            continue
        if cls and c==']':
            cls=False; out.append(']'); i+=1; continue
        ch,text,j=tok_char(src,i)
        if cls:
            # range?
            if ch is not None and src[j:j+1]=='-' and src[j+1:j+2] not in (']',''):
                ch2,text2,k=tok_char(src,j+1)
                out.append(text+'-'+text2)
                if ch2 is not None:
                    lo,hi=ord(ch),ord(ch2)
                    if hi-lo<2000:
                        extra=set()
                        for cp in range(lo,hi+1):
                            for a in swap(chr(cp)):
                                if not (lo<=ord(a)<=hi): extra.add(a)
                        out.extend(esc(a) for a in sorted(extra))
                i=k; continue
            out.append(text)
            if ch is not None: out.extend(esc(a) for a in swap(ch))
            i=j; continue
        if ch is not None and swap(ch):
            out.append('['+text+''.join(esc(a) for a in swap(ch))+']')
        else:
            out.append(text)
        i=j
    return ''.join(out)
import json as _j
res=_j.load(open(sys.argv[1]))
for k in ['extractUrl','invalidUrlWithoutProtocolPrecedingChars','validAsciiDomain','validTcoUrl','emoji']:
    if res[k]['ignore_case']:
        res[k]['source']=caseless(res[k]['source']); res[k]['ignore_case']=False
res['source']=res['source']+"; JS /i spelled out as explicit case alternatives because Ruby /i folds ß to ss"
_j.dump(res,open(sys.argv[1],'w'),ensure_ascii=True,indent=1)
print({k:len(v['source']) for k,v in res.items() if isinstance(v,dict) and 'source' in v})
