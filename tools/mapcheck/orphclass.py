# Classify what stays up (MapCheck -Dorphans=1 out/orphans_list.tsv) by what it is attached to (2026-11-10).
#   python -I orphclass.py out/orphans_list.tsv <dump of the orphan sheets: MapCheck -Dwires=(sheet|...)_[0-9]+>
#   piece    another piece of the same big object (same sheet, touching in 3x3x3) that is not stuck: on the ground
#            (z0) or a piece some rule already brings down. A "same-object cluster" rule would bring it down.
#   cluster  part of a same-sheet cluster that is stuck as a whole (no piece on the ground or brought down)
#   wall     a decoration / fixture with a wall in its 3x3 on its own level (outer faces on a neighbour square)
#   ceiling  floor or roof right above it (3x3 one level up): hangs from the ceiling
#   nothing  none of these
import sys, collections, re
olist, dump = sys.argv[1], sys.argv[2]
orph = []
for l in open(olist, encoding='utf-8'):
    p = l.rstrip('\n').split('\t')
    if p[0] == 'sprite': continue
    orph.append((p[0], int(p[1]), int(p[2]), int(p[3]), p[4], p[5]))
oset = {(s, x, y, z) for s, x, y, z, k, nb in orph}
sheet = lambda n: re.sub(r'_\d+$', '', n)
pieces = collections.defaultdict(set)   # sheet -> {(x,y,z)}
for l in open(dump, encoding='utf-8'):
    p = l.split('\t')
    if p[0] == 'sprite': continue
    pieces[sheet(p[0])].add((int(p[1]), int(p[2]), int(p[3])))
onames = collections.defaultdict(set)
for s, x, y, z, k, nb in orph: onames[sheet(s)].add((x, y, z))
memo = {}
def cluster(sh, start):
    if (sh, start) in memo: return memo[(sh, start)]
    P = pieces[sh]; seen = {start}; st = [start]
    while st:
        c = st.pop()
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for dz in (-1, 0, 1):
                    n = (c[0] + dx, c[1] + dy, c[2] + dz)
                    if n in P and n not in seen: seen.add(n); st.append(n)
    free = any(c[2] == 0 or c not in onames[sh] for c in seen)
    r = (free, len(seen))
    for c in seen: memo[(sh, c)] = r
    return r
cls = collections.Counter(); bysheet = collections.defaultdict(collections.Counter); ex = {}
for s, x, y, z, k, nb in orph:
    sh = sheet(s)
    same, up, down = nb.split(' ')
    if sh in pieces and (x, y, z) in pieces[sh]:
        free, n = cluster(sh, (x, y, z))
        c = 'piece' if free else ('cluster' if n > 1 else None)
    else:
        c = None
    if c is None:
        if 'wall' in same: c = 'wall'
        elif 'floor' in up or 'roof' in up: c = 'ceiling'
        else: c = 'nothing'
    cls[c] += 1; bysheet[c][sh] += 1
    ex.setdefault((c, sh), '%d,%d,%d' % (x, y, z))
print('orphans', len(orph), dict(cls))
for c in ('piece', 'cluster', 'wall', 'ceiling', 'nothing'):
    print(c, [(sh, n, ex[(c, sh)]) for sh, n in bysheet[c].most_common(10)])
