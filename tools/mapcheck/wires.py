# Overhead wire geometry from MapCheck's wire dump (offline).
#   java MapCheck.java <maps> <tiledefs> <out> "-Dwires=appliances_com_01_(8[89]|9[0-9]|1[0-5][0-9])|electricity_pylon_[0-9]+"
#   python -I wires.py out/wire_placements.tsv > out/wires_report.txt
# Sprite roles (from the .tiles properties and where they are placed):
#   wooden utility pole  appliances_com_01_88/89/94/95 (Material Log, StopCar, PhysicsShape Tree; z0 foot, z1 middle)
#                        appliances_com_01_90..93 (Log + Wood + MetalScrap: the cross-arm top, z2)
#   pole wires           the other appliances_com_01_96..159 pieces at z >= 1, except the street lights 136..141
#   pylon                electricity_pylon pieces standing in a column over a z0 foot; HV lines = pieces at z >= 3 that are
#                        not over a pylon foot
import sys, collections

rows = []
with open(sys.argv[1], encoding='utf-8') as f:
    next(f)
    for line in f:
        p = line.rstrip('\n').split('\t')
        rows.append((p[0], int(p[1]), int(p[2]), int(p[3]), p[4] if len(p) > 4 else ''))

def idx(s): return int(s.rsplit('_', 1)[1])
def sheet(s): return s.rsplit('_', 1)[0]

POLE_LOW = {88, 89, 94, 95}
POLE_TOP = {90, 91, 92, 93}
LIGHT = set(range(136, 142))
role = {}
for s, x, y, z, o in rows:
    if sheet(s) == 'appliances_com_01':
        i = idx(s)
        role[s] = 'pole' if i in POLE_LOW else 'poletop' if i in POLE_TOP else 'light' if i in LIGHT else 'wire'

byz = collections.defaultdict(collections.Counter)
for s, x, y, z, o in rows: byz[s][z] += 1
print('== appliances_com_01 roles by level')
agg = collections.defaultdict(collections.Counter)
for s in byz:
    if s in role:
        for z, n in byz[s].items(): agg[role[s]][z] += n
for r, c in agg.items(): print(r, dict(sorted(c.items())), 'sprites', sorted(idx(s) for s in role if role[s] == r))

# ---------------------------------------------------------------- wooden poles and their wires (z2)
poles = {(x, y) for s, x, y, z, o in rows if role.get(s) == 'pole' and z == 0}
tops = {}
for s, x, y, z, o in rows:
    if role.get(s) == 'poletop': tops[(x, y, z)] = s
wires = collections.defaultdict(set)
for s, x, y, z, o in rows:
    if role.get(s) == 'wire': wires[z].add((x, y))
print('\n== wooden poles (z0 foot):', len(poles), ' pole tops:', len(tops), 'by z', collections.Counter(k[2] for k in tops))
print('pole tops over a pole foot:', sum(1 for (x, y, z) in tops if (x, y) in poles))
print('wire squares by level', {z: len(v) for z, v in sorted(wires.items())})
W = wires[2]
T = {(x, y) for (x, y, z) in tops if z == 2}
print('pole tops on a wire square (same x,y at z2):', len(T & W), ' next to a wire square (8-neighbour):',
      sum(1 for t in T if t not in W and any((t[0] + dx, t[1] + dy) in W for dx in (-1, 0, 1) for dy in (-1, 0, 1))),
      ' with no wire around:', sum(1 for t in T if t not in W and not any((t[0] + dx, t[1] + dy) in W for dx in (-1, 0, 1) for dy in (-1, 0, 1))))
both = W | T
def comps(sq):
    seen = set(); out = []
    for st in sq:
        if st in seen: continue
        comp = []; q = [st]; seen.add(st)
        while q:
            c = q.pop(); comp.append(c)
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    n = (c[0] + dx, c[1] + dy)
                    if n in sq and n not in seen: seen.add(n); q.append(n)
        out.append(comp)
    return out
lines = comps(both)
print('\n== pole lines (wire + pole-top squares joined, 8-connected, z2):', len(lines))
L = sorted(len(c) for c in lines)
print('line size (squares): median', L[len(L) // 2], 'p90', L[int(len(L) * .9)], 'max', L[-1])
print('poles per line: median', sorted(sum(1 for c in comp if c in T) for comp in lines)[len(lines) // 2],
      'lines with no pole top:', sum(1 for comp in lines if not any(c in T for c in comp)))
# spans: cut the line at its pole tops (remove each top and its 8 neighbours), measure what remains
spans = []
span_sq = []
for comp in lines:
    cut = set(comp)
    for c in comp:
        if c in T:
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1): cut.discard((c[0] + dx, c[1] + dy))
    for sp in comps(cut):
        xs = [c[0] for c in sp]; ys = [c[1] for c in sp]
        spans.append(max(max(xs) - min(xs), max(ys) - min(ys)) + 1); span_sq.append(len(sp))
spans.sort(); span_sq.sort()
print('spans between pole tops: n', len(spans), 'length median', spans[len(spans) // 2], 'p10', spans[int(len(spans) * .1)],
      'p90', spans[int(len(spans) * .9)], 'p99', spans[int(len(spans) * .99)], 'max', spans[-1])
print('span squares (objects per span): median', span_sq[len(span_sq) // 2], 'p90', span_sq[int(len(span_sq) * .9)], 'max', span_sq[-1])
# branching: wire squares whose 8-neighbourhood holds wire in 3+ directions that are not one straight 2-row band
def dirs(c, sq):
    d = set()
    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        if (c[0] + dx, c[1] + dy) in sq or (c[0] + dx, c[1] + dy + 1) in sq or (c[0] + dx + 1, c[1] + dy) in sq: d.add((dx, dy))
    return d
tee = sum(1 for c in T if len(dirs(c, W)) >= 3)
corner = sum(1 for c in T if len(dirs(c, W)) == 2 and (1, 0) not in dirs(c, W) | {(9, 9)} and False)
print('pole tops with wire leaving in 3-4 directions (branch points):', tee, 'of', len(T))
# wire sprite pairs: which sprites lie side by side (the 2-row band)
pair = collections.Counter()
name = {}
for s, x, y, z, o in rows:
    if role.get(s) == 'wire' and z == 2: name[(x, y)] = idx(s)
for (x, y), i in name.items():
    if (x, y + 1) in name: pair[(i, name[(x, y + 1)], 'y')] += 1
    if (x + 1, y) in name and name[(x + 1, y)] != i: pair[(i, name[(x + 1, y)], 'x')] += 1
print('wire sprite neighbours (a, b, axis): ', pair.most_common(10))
under = sum(1 for s, x, y, z, o in rows if role.get(s) == 'wire' and o)
print('wire placements sharing their square (same level) with another object:', under)
print('examples: biggest lines')
for comp in sorted(lines, key=len, reverse=True)[:5]:
    ts = sorted(c for c in comp if c in T)
    print(' ', len(comp), 'squares', len(ts), 'poles, first pole tops', ts[:4])

# ---------------------------------------------------------------- pylons and HV lines
feet = {(x, y) for s, x, y, z, o in rows if sheet(s) == 'electricity_pylon' and z == 0}
pyl = collections.defaultdict(list)
for s, x, y, z, o in rows:
    if sheet(s) == 'electricity_pylon': pyl[(x, y)].append(z)
hv = collections.defaultdict(set)
for s, x, y, z, o in rows:
    if sheet(s) == 'electricity_pylon' and z >= 3 and 0 not in pyl[(x, y)]: hv[z].add((x, y))
print('\n== pylon squares with a z0 piece:', len(feet), ' HV line squares by level (no pylon piece at z0 below):', {z: len(v) for z, v in sorted(hv.items())})
hvsq = set().union(*hv.values()) if hv else set()
hvl = comps(hvsq)
print('HV runs (8-connected, levels merged):', len(hvl), 'sizes top', sorted((len(c) for c in hvl), reverse=True)[:8])
# pylon towers: clusters of z0 feet (a pylon stands on several squares)
towers = comps(feet)
print('pylon towers (8-connected z0 squares):', len(towers), 'squares per tower', collections.Counter(len(t) for t in towers).most_common(4))
cent = [(sum(c[0] for c in t) / len(t), sum(c[1] for c in t) / len(t)) for t in towers]
# HV span: nearest-neighbour distance between towers
nn = []
for i, a in enumerate(cent):
    d = min((max(abs(a[0] - b[0]), abs(a[1] - b[1])) for j, b in enumerate(cent) if j != i), default=0)
    nn.append(d)
nn.sort()
if nn: print('tower to nearest tower (squares, Chebyshev): median', nn[len(nn) // 2], 'p10', nn[int(len(nn) * .1)], 'p90', nn[int(len(nn) * .9)])
print('example towers', [tuple(round(v) for v in c) for c in cent[:5]])

# ---------------------------------------------------------------- refinements
# branch count at a pole: how many separate spans touch its 3x3 neighbourhood
span_of = {}
for comp in lines:
    cut = set(comp)
    for c in comp:
        if c in T:
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1): cut.discard((c[0] + dx, c[1] + dy))
    for k, sp in enumerate(comps(cut)):
        for c in sp: span_of[c] = (id(comp), k)
deg = collections.Counter()
for t in T:
    near = set()
    for dx in range(-2, 3):
        for dy in range(-2, 3):
            c = (t[0] + dx, t[1] + dy)
            if c in span_of: near.add(span_of[c])
    deg[min(len(near), 5)] += 1
print('\n== spans meeting at a pole top (1 = line end, 2 = straight or corner, 3+ = branch):', dict(sorted(deg.items())))

# pylons: cluster the z0 base pieces electricity_pylon_0..11 (Chebyshev distance <= 6)
base = sorted({(x, y) for s, x, y, z, o in rows if sheet(s) == 'electricity_pylon' and z == 0 and idx(s) <= 11})
clusters = []
for b in base:
    for cl in clusters:
        if any(max(abs(b[0] - c[0]), abs(b[1] - c[1])) <= 6 for c in cl): cl.append(b); break
    else: clusters.append([b])
cent = [(sum(c[0] for c in t) / len(t), sum(c[1] for c in t) / len(t)) for t in clusters]
print('pylons (clusters of base pieces 0..11):', len(clusters), 'base squares per pylon', collections.Counter(len(t) for t in clusters).most_common(3))
nn = sorted(min((max(abs(a[0] - b[0]), abs(a[1] - b[1])) for j, b in enumerate(cent) if j != i), default=0) for i, a in enumerate(cent))
if nn: print('pylon to nearest pylon (squares): median', round(nn[len(nn) // 2]), 'p10', round(nn[int(len(nn) * .1)]), 'p90', round(nn[int(len(nn) * .9)]), 'max', round(nn[-1]))
# which HV squares are close to a pylon (where the line meets the tower)
near_hv = collections.Counter()
for z, sq in hv.items():
    for c in sq:
        d = min(max(abs(c[0] - a[0]), abs(c[1] - a[1])) for a in cent) if cent else 99
        near_hv['<=4' if d <= 4 else '5-10' if d <= 10 else '>10'] += 1
print('HV line squares by distance to the nearest pylon centre:', dict(near_hv))
print('HV squares per pylon span (all levels): about', round(sum(len(v) for v in hv.values()) / max(1, len(clusters))))
print('example pylons', [tuple(round(v) for v in c) for c in cent[:6]])
