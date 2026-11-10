# Offline run of the mod rule SC.breakWires("pylon") over the whole map (2026-11-10).
#   python -I hvlines.py out/wire_placements.tsv   (the dump from wires.py header: -Dwires=... incl. electricity_pylon)
# Rule as in StructuralCollapse.lua: own core = bbox of pylon columns (any level 0..7) connected to the removed leg
# within 6 squares; spans start within 3 of the core on levels 1..8 and stop within 3 of another pylon column.
import re, collections, sys
line, hold = set(), set()   # (x,y,z)
legs = []
for l in open(sys.argv[1]):
    p = l.split('\t')
    if 'electricity_pylon' not in p[0]: continue
    i = int(re.search(r'(\d+)$', p[0]).group(1)); x, y, z = int(p[1]), int(p[2]), int(p[3])
    if i <= 71: hold.add((x, y, z))
    if z >= 1 and 72 <= i <= 180 and i != 176: line.add((x, y, z))
    if z == 0 and i <= 11: legs.append((x, y))
holdcol = {(x, y) for x, y, z in hold if 0 <= z <= 7}
# one leg per pylon (cluster legs)
seenl, starts = set(), []
for lg in sorted(legs):
    if any(max(abs(lg[0]-a[0]), abs(lg[1]-a[1])) <= 6 for a in starts): continue
    starts.append(lg)
def box(x, y):
    x0 = x1 = x; y0 = y1 = y
    seen = {(x, y)}; q = [(x, y)]
    for c in q:
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                n = (c[0]+dx, c[1]+dy)
                if n in seen or abs(n[0]-x) > 6 or abs(n[1]-y) > 6: continue
                seen.add(n)
                if n in holdcol:
                    q.append(n); x0, x1, y0, y1 = min(x0, n[0]), max(x1, n[0]), min(y0, n[1]), max(y1, n[1])
    return (x0, x1, y0, y1)
CAP = 30000
covered = collections.Counter(); sizes = []
for (x, y) in starts:
    c0 = box(x, y); M = 3
    b = (c0[0]-M, c0[1]+M, c0[2]-M, c0[3]+M)
    inc = lambda tx, ty: c0[0] <= tx <= c0[1] and c0[2] <= ty <= c0[3]
    def near(nx, ny, lz):
        return any(not inc(nx+dx, ny+dy) and (nx+dx, ny+dy) in holdcol for dx in range(-M, M+1) for dy in range(-M, M+1))
    seen = set(); q = []
    for lz in range(1, 9):
        for sx in range(b[0], b[1]+1):
            for sy in range(b[2], b[3]+1):
                seen.add((sx, sy, lz)); q.append((sx, sy, lz))
    got = []
    for (qx, qy, lz) in q:
        if len(got) >= CAP: break
        if (qx, qy, lz) not in line: continue
        got.append((qx, qy, lz))
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                n = (qx+dx, qy+dy, lz)
                if n in seen: continue
                seen.add(n)
                if n in line and not near(n[0], n[1], lz): q.append(n)
    for g in got: covered[g] += 1
    sizes.append((len(got), (x, y), b))
sizes.sort()
print('pylons', len(starts), 'HV line squares', len(line))
print('squares per removal: min', sizes[0][0], 'median', sizes[len(sizes)//2][0], 'p90', sizes[int(len(sizes)*.9)][0], 'max', sizes[-1][0])
print('largest', sizes[-5:])
print('zero', [s for s in sizes if s[0] == 0][:10], sum(1 for s in sizes if s[0] == 0))
print('line squares reached by no pylon', len(line) - len(covered), ' by 2+', sum(1 for v in covered.values() if v > 1))
left = [s for s in line if s not in covered]
print('unreached by level', collections.Counter(z for _, _, z in left))
# group the unreached into runs
lefts = set(left); runs = []
while lefts:
    s = lefts.pop(); st = [s]; comp = [s]
    while st:
        c = st.pop()
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                n = (c[0]+dx, c[1]+dy, c[2])
                if n in lefts: lefts.remove(n); st.append(n); comp.append(n)
    runs.append(comp)
runs.sort(key=len, reverse=True)
print('unreached runs', len(runs), [(len(r), r[0]) for r in runs[:12]])
print('reach count distribution', sorted(collections.Counter(covered.values()).items()))
for r in runs[:8]:
    c=r[0]; d=min(max(abs(c[0]-s[0]),abs(c[1]-s[1])) for s in starts)
    xs=[a[0] for a in r]; ys=[a[1] for a in r]
    print('run', len(r), 'bbox', min(xs), max(xs), min(ys), max(ys), 'z', sorted(set(a[2] for a in r)), 'nearest pylon', d)
