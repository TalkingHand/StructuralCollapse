# Reads a Project Zomboid .tiles definition file (tdef) and prints roof/slope property statistics.
# Usage: python -I tools/tdef_roofs.py <path to .tiles>   (used 2026-11-10 for the roof findings in _devnotes)
import struct,sys,collections
def rd(f):
    d=open(f,'rb').read(); p=0
    def i32():
        nonlocal p; v=struct.unpack('<i',d[p:p+4])[0]; p+=4; return v
    def s():
        nonlocal p; e=d.index(b'\n',p); v=d[p:e].decode('utf-8','replace'); p=e+1; return v
    magic=d[:4]; p=4
    ver=i32() if magic==b'tdef' else None
    if magic!=b'tdef': p=0
    n=i32(); out={}
    for _ in range(n):
        name=s(); img=s(); w=i32(); h=i32(); num=i32(); nt=i32()
        tiles=[]
        for t in range(nt):
            np_=i32(); pr={}
            for _ in range(np_): k=s(); v=s(); pr[k]=v
            tiles.append(pr)
        out[name]=tiles
    return out
f=sys.argv[1]; defs=rd(f)
slope=collections.Counter(); roofinfo=collections.Counter()
for name,tiles in defs.items():
    for i,pr in enumerate(tiles):
        if 'SlopedSurfaceDirection' in pr: slope[name.split('_0')[0] if False else name]+=1
        if name.startswith('roofs'):
            key=tuple(sorted(k for k in pr if k in('solidfloor','SlopedSurfaceDirection','collideN','collideW','solid','RoofGroup','WestRoofB','WestRoofM','WestRoofT','isEave','FloorHeight','SlopedSurfaceHeightMin','SlopedSurfaceHeightMax','BlockRain')))
            roofinfo[key]+=1
print('sheets with SlopedSurfaceDirection:', sorted(slope.items())[:40], 'total', sum(slope.values()))
print('roof tile property combos:')
for k,v in roofinfo.most_common(15): print(v,k)
