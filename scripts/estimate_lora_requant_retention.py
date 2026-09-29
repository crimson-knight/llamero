"""Offline numpy replica of QLoRALinear.fused(): dequantize -> + scale*(B^T A^T) -> re-quantize (MLX affine, 4-bit, group 64)."""
import json, struct, sys, numpy as np
MODEL='/Users/crimsonknight/.llamero/models/mlx-community--gemma-3-4b-it-4bit'
class ST:
    def __init__(s,p):
        s.f=open(p,'rb'); n=struct.unpack('<Q',s.f.read(8))[0]; s.h=json.loads(s.f.read(n)); s.o=8+n
    def get(s,k):
        m=s.h[k]; a,b=m['data_offsets']; s.f.seek(s.o+a); raw=s.f.read(b-a)
        dt=m['dtype']
        if dt=='BF16':
            u=np.frombuffer(raw,np.uint16).astype(np.uint32)<<16; return u.view(np.float32).reshape(m['shape'])
        return np.frombuffer(raw,{'F32':np.float32,'U32':np.uint32,'F16':np.float16}[dt]).reshape(m['shape']).astype(np.float32) if dt!='U32' else np.frombuffer(raw,np.uint32).reshape(m['shape'])
def bf16(x):
    u=x.astype(np.float32).view(np.uint32); r=((u>>16)&1)+0x7FFF; return ((u+r)&0xFFFF0000).view(np.float32)
def dequant(w,sc,bi,g=64):
    q=np.stack([(w>>(4*i))&0xF for i in range(8)],-1).reshape(w.shape[0],-1).astype(np.float32)
    return (q.reshape(q.shape[0],-1,g)*sc[...,None]+bi[...,None]).reshape(q.shape)
def quant_dequant(w,g=64,bits=4):
    n=(1<<bits)-1; W=w.reshape(w.shape[0],-1,g)
    wmax=W.max(-1,keepdims=True); wmin=W.min(-1,keepdims=True)
    mask=np.abs(wmin)>np.abs(wmax)
    sc=np.maximum((wmax-wmin)/n,1e-7); sc=np.where(mask,sc,-sc)
    edge=np.where(mask,wmin,wmax); q0=np.round(edge/sc)
    sc=np.where(q0!=0,edge/q0,sc); bi=np.where(q0==0,0,edge)
    sc=bf16(sc); bi=bf16(bi)
    q=np.clip(np.round((W-bi)/sc),0,n)
    return (q*sc+bi).reshape(w.shape)

base=ST(MODEL+'/model.safetensors')
adir=sys.argv[1]; layers=[int(x) for x in sys.argv[2].split(',')]
ad=ST(adir+'/adapters.safetensors'); cfg=json.load(open(adir+'/adapter_config.json')); scale=cfg['lora_parameters']['scale']
pre='language_model.model.layers' if any(k.startswith('language_model') for k in ad.h) else 'model.layers'
tot={'d':0,'kept':0,'err':0}
for L in layers:
  for p in ['self_attn.q_proj','self_attn.v_proj','self_attn.o_proj','mlp.gate_proj','mlp.down_proj']:
    bk=f'language_model.model.layers.{L}.{p}'
    W=dequant(base.get(bk+'.weight'),base.get(bk+'.scales'),base.get(bk+'.biases'))
    A=ad.get(f'{pre}.{L}.{p}.lora_a'); B=ad.get(f'{pre}.{L}.{p}.lora_b')
    d=scale*(A@B).T
    Wf=bf16(bf16(W)+bf16(d))                 # bf16 add as in fused()
    R=quant_dequant(Wf)-W                    # delta that survives re-quantization
    Rb=Wf-W                                   # delta surviving only the bf16 add
    cos=float((R*d).sum()/np.linalg.norm(R)/np.linalg.norm(d))
    step=np.abs(W.reshape(W.shape[0],-1,64).max(-1)-W.reshape(W.shape[0],-1,64).min(-1))/15
    print(f'L{L} {p:16s} |d|rms={np.sqrt((d**2).mean()):.2e} max={np.abs(d).max():.2e} qstep_med={np.median(step):.2e} '
          f'bf16_kept={np.linalg.norm(Rb)/np.linalg.norm(d):.3f} requant: |R|/|d|={np.linalg.norm(R)/np.linalg.norm(d):.2f} cos(R,d)={cos:.3f} '
          f'proj_kept={(R*d).sum()/(d*d).sum():.3f} changed_levels={(np.abs(R)>1e-6).mean():.3f}')
