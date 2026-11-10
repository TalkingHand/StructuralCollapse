import java.io.*;
import java.nio.*;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;

/**
 * StructuralCollapse map check (offline, never launches the game).
 *
 * Applies the mod's collapse rules (StructuralCollapse.lua: isGroupTile, wallEdges, isPole, isStairs,
 * SC.tileSupported, isRoofObj, SC.roofSupported) to the untouched vanilla map and reports:
 * floor groups (z >= 1, 4-connected group tiles) with their supported-tile counts, roof layers that the
 * roof rule already counts as unsupported, size distributions, the largest groups, and definition checks.
 *
 * Tile properties come from media/tile_definitions/*.tiles, read the way IsoWorld.LoadTileDefinitions
 * reads them (property names that are IsoObjectType names set the tile type, IsoFlagType names set flags,
 * WallN/WallW/... add the derived flags). Map objects come from *.lotheader + world_X_Y.lotpack (the
 * format IsoLot / IsoMetaGrid read; parsing taken from RotateView/tools/MapAdjacency.java). The object
 * class a map tile becomes (IsoDoor, IsoWindow, IsoCurtain, overlay sprites that are attached instead of
 * added) follows CellLoader.DoTileObjectCreation.
 *
 *   java -Xmx1g MapCheck.java <map dir> <tile_definitions dir> <out dir> [probe x,y,z ...]
 *   -Dcells=<regex on X_Y>    only those cells (testing)
 *   -Dprogress=<file>         append a progress line every 500 cells
 *   -Drules=v1                the first rules (floor groups of group tiles only). Default v2 = the mod as of
 *                             2026-11-10 evening: structures of nodes f/N/W/P (floor-floor, wall-wall at end points,
 *                             floor-wall, post-wall; a structure stands while any node rests on something), garage /
 *                             truck doors are walls, longer POLE_SPRITES list, flat roofs (solidfloor + RoofGroup) are
 *                             roof pieces not floors, attached roof pieces are roof, a ceiling at z-1 >= 1 holds a roof
 *   -Dorphans=1               also count objects at z >= 1 that no rule brings down once everything under them is gone
 *                             (v2: floor columns, wall edges / outer faces, posts, roofs, free pieces standing on
 *                             something, wires, things on a roof square; orphans_*.tsv = what stays up, orphans_list.tsv =
 *                             each one with what is around it, floating_by_sheet.tsv)
 *   -Dwires=<regex>           also dump every placement of matching sprites (wire_placements.tsv; see wires.py)
 *
 * Output (out dir): summary.txt, floor_groups.tsv (v2: one row per structure, size = nodes, node counts by kind),
 * roof_layers.tsv, zero_support.tsv, unsupported_roofs.tsv, largest.tsv, defs_*.tsv. "probe x,y,z": print the
 * floor group / structure and roof layer holding that square (used to check the in-game measured group sizes).
 * Some summary lines (tiles on roof/floor, halfheight/solid what-ifs) are computed for v1 floor groups only.
 */
public class MapCheck {
    // ---------------------------------------------------------------- tile definitions
    static final String[] FLAG_NAMES = ("collideW collideN solidfloor noStart windowW windowN hidewalls exterior NoWallLighting doorW doorN "
        + "transparentW transparentN WallOverlay FloorOverlay vegitation burning burntOut unflamable cutW cutN tableN tableNW tableW tableSW "
        + "tableS tableSE tableE tableNE halfheight HasRainSplashes HasRaindrop solid trans pushable solidtrans invisible floorS floorE shelfS "
        + "shelfE alwaysDraw ontable transparentFloor climbSheetW climbSheetN climbSheetTopN climbSheetTopW attachtostairs sheetCurtains "
        + "waterPiped HoppableN HoppableW bed blueprint canPathW canPathN blocksight climbSheetE climbSheetS climbSheetTopE climbSheetTopS "
        + "makeWindowInvincible water canBeCut canBeRemoved taintedWater smoke attachedN attachedS attachedE attachedW attachedFloor "
        + "attachedSurface attachedCeiling attachedNW ForceAmbient WallSE WindowN WindowW FloorHeightOneThird FloorHeightTwoThirds CantClimb "
        + "diamondFloor attachedSE TallHoppableW WallWTrans TallHoppableN WallNTrans container DoorWallW DoorWallN WallW WallN WallNW "
        + "SpearOnlyAttackThrough forceRender open SpriteConfig BlockRain EntityScript isEave openAir HasLightOnSprite unlit NeverCutaway "
        + "DoubleDoor1 DoubleDoor2 IsFloorAttached FloorAttachmentN FloorAttachmentS FloorAttachmentE FloorAttachmentW").split(" ");
    static final String[] TYPE_NAMES = ("normal jukebox wall stairsTW stairsTN stairsMW stairsMN stairsBW stairsBN UNUSED9 UNUSED10 doorW doorN "
        + "lightswitch radio curtainN curtainS curtainW curtainE doorFrW doorFrN tree windowFN windowFW UNUSED24 WestRoofB WestRoofM WestRoofT "
        + "isMoveAbleObject").split(" ");
    static final Map<String, Integer> FLAG = new HashMap<>(), TYPE = new HashMap<>();
    static {
        for (int i = 0; i < FLAG_NAMES.length; i++) FLAG.put(FLAG_NAMES[i], i);
        for (int i = 0; i < TYPE_NAMES.length; i++) TYPE.put(TYPE_NAMES[i], i);
    }
    // -Drules=v1: the rules of the first check (floor groups); default v2: the 2026-11-10 evening rules (structures)
    static final boolean V2 = !"v1".equals(System.getProperty("rules"));
    static final Set<String> POLE_SPRITES = new HashSet<>(Set.of("walls_exterior_wooden_01_27", "carpentry_02_94", "carpentry_02_95"));
    static {
        if (V2) {   // StructuralCollapse.lua POLE_SPRITES (2026-11-10 evening)
            POLE_SPRITES.addAll(List.of("fixtures_stairs_01_14", "fixtures_railings_01_78", "industry_01_28", "industry_01_29",
                "industry_01_30", "industry_01_49", "electricity_pylon_176", "electricity_pylon_181"));
            for (int i : new int[]{3, 7, 11, 15, 16, 17, 18, 19, 43}) POLE_SPRITES.add("carpentry_03_" + i);
            for (int i = 16; i <= 26; i++) POLE_SPRITES.add("construction_01_" + i);
            for (int i = 48; i <= 55; i++) POLE_SPRITES.add("construction_01_" + i);
        }
    }

    static class Spr {
        String name;
        int type = 0;
        BitSet flags = new BitSet();
        Map<String, String> props = new LinkedHashMap<>();
        boolean f(String n) { return flags.get(FLAG.get(n)); }
        void set(String n) { flags.set(FLAG.get(n)); }
        String t() { return TYPE_NAMES[type]; }
    }
    static final Map<String, Spr> SPR = new HashMap<>();

    static void setProp(Spr s, String prop, String val) {   // PropertyContainer.set(name, val): flag names become flags
        Integer f = FLAG.get(prop);
        if (f != null) s.flags.set(f); else s.props.put(prop, val);
    }

    // IsoWorld.LoadTileDefinitions, one property
    static void applyProp(Spr s, String prop, String val) {
        Integer t = TYPE.get(prop);
        if (t != null) {
            if (!((s.type == TYPE.get("doorW") || s.type == TYPE.get("doorN")) && t == TYPE.get("wall"))) s.type = t;
            if (prop.equals("doorW")) s.set("doorW");
            else if (prop.equals("doorN")) s.set("doorN");
        } else if (prop.equals("firerequirement") || prop.equals("fireRequirement") || prop.equals("BurntTile")) {
            // no property
        } else if (prop.equals("FloorHeight")) {
            if (val.equals("OneThird")) s.set("FloorHeightOneThird");
            else if (val.equals("TwoThirds")) s.set("FloorHeightTwoThirds");
        } else {
            setProp(s, prop, val);
        }
        if (prop.equals("HoppableN")) { s.set("collideN"); s.set("canPathN"); s.set("transparentN"); }
        if (prop.equals("HoppableW")) { s.set("collideW"); s.set("canPathW"); s.set("transparentW"); }
        if (prop.equals("WallN")) { s.set("collideN"); s.set("cutN"); s.type = 2; s.props.put("WallN", ""); }
        switch (prop) {
            case "WallNTrans" -> { s.set("collideN"); s.set("cutN"); s.set("transparentN"); s.type = 2; }
            case "WallW" -> { s.set("collideW"); s.set("cutW"); s.type = 2; s.props.put("WallW", ""); }
            case "windowN" -> { s.set("WindowN"); s.set("transparentN"); }
            case "windowW" -> { s.set("WindowW"); s.set("transparentW"); }
            case "cutW" -> s.set("cutW");
            case "cutN" -> s.set("cutN");
            case "WallWTrans" -> { s.set("collideW"); s.set("transparentW"); s.set("cutW"); s.type = 2; }
            case "DoorWallN", "DoorWallNTrans" -> s.set("cutN");
            case "DoorWallW", "DoorWallWTrans" -> s.set("cutW");
            case "WallNW", "WallNWTrans" -> { s.set("collideN"); s.set("cutN"); s.set("collideW"); s.set("cutW"); s.type = 2; }
            case "WallSE" -> { s.set("cutW"); s.set("WallSE"); }
            case "WindowW" -> { s.set("canPathW"); s.set("collideW"); s.set("cutW"); s.set("transparentW"); s.type = TYPE.get("windowFW"); s.flags.clear(FLAG.get("HoppableW")); }
            case "WindowN" -> { s.set("canPathN"); s.set("collideN"); s.set("cutN"); s.set("transparentN"); s.type = TYPE.get("windowFN"); s.flags.clear(FLAG.get("HoppableN")); }
            case "UnbreakableWindowW" -> { s.set("canPathW"); s.set("collideW"); s.set("cutW"); s.set("transparentW"); s.type = 2; }
            case "UnbreakableWindowN" -> { s.set("canPathN"); s.set("collideN"); s.set("cutN"); s.set("transparentN"); s.type = 2; }
            case "UnbreakableWindowNW" -> { s.set("cutN"); s.set("transparentN"); s.set("collideN"); s.set("collideW"); s.set("cutW"); s.type = 2; }
            default -> { }
        }
    }

    static void loadTdef(Path f) throws IOException {
        boolean patch = f.getFileName().toString().endsWith(".patch.tiles");
        ByteBuffer b = ByteBuffer.wrap(Files.readAllBytes(f)).order(ByteOrder.LITTLE_ENDIAN);
        byte[] magic = new byte[4];
        b.get(magic);
        if (!new String(magic, StandardCharsets.US_ASCII).equals("tdef")) throw new IOException("not tdef " + f);
        b.getInt(); // version
        int sheets = b.getInt();
        for (int n = 0; n < sheets; n++) {
            String name = line(b).trim();
            line(b);
            b.getInt(); b.getInt(); b.getInt();
            int nt = b.getInt();
            for (int m = 0; m < nt; m++) {
                String tn = name + "_" + m;
                Spr s = SPR.get(tn);
                boolean skip = false;
                if (s == null) {
                    if (patch) skip = true;
                    else { s = new Spr(); s.name = tn; SPR.put(tn, s); }
                } else if (!patch) {   // AddSprite with the same name again: a fresh sprite replaces it
                    s = new Spr(); s.name = tn; SPR.put(tn, s);
                }
                int np = b.getInt();
                for (int l = 0; l < np; l++) {
                    String k = line(b).trim(), v = line(b).trim();
                    if (!skip) applyProp(s, k, v);
                }
                if (!skip && s.props.containsKey("StopCar") && s.type != TYPE.get("tree")) s.type = TYPE.get("isMoveAbleObject");
            }
        }
    }

    // ---------------------------------------------------------------- per-sprite classification (the Lua rules)
    // object bits
    static final int O_FLOOR = 1, O_STAIRS = 2, O_WN = 4, O_WW = 8, O_POLE = 16, O_ROOF = 32, O_SKIP = 64, O_HALF = 128, O_SOLID = 256,
        O_DOOR = 512, O_WINDOW = 1024, O_EDGE = 2048, O_DEFINED = 4096;
    // square bits (stored per square)
    static final int G = 1, R = 2, ST = 4, EW = 8, EN = 16, P = 32, HALF = 64, SOLID = 128;

    static final Map<String, Integer> OBITS = new HashMap<>();

    static int objBits(String name) {
        Integer c = OBITS.get(name);
        if (c != null) return c;
        Spr s = SPR.get(name);
        int r = 0;
        if (s == null) {
            r = 0;   // undefined sprite: no properties
        } else {
            r |= O_DEFINED;
            String t = s.t();
            boolean door = t.equals("doorW") || t.equals("doorN");
            boolean curtain = t.startsWith("curtain");
            boolean light = t.equals("lightswitch");
            boolean window = !door && !curtain && !light && (s.f("windowW") || s.f("windowN"));
            boolean overlay = !door && !curtain && !light && !window && !s.f("WindowW") && !s.f("WindowN")
                && (s.f("WallOverlay") || s.f("FloorOverlay"));
            if (overlay) r |= O_SKIP;
            boolean wn = false, ww = false;
            boolean garage = V2 && door && (s.f("WallN") || s.f("WallW") || s.f("WallNW"));
            if (garage && !s.f("halfheight")) {   // v2: garage / truck doors are walls
                boolean nw = s.f("WallNW");
                wn = nw || s.f("WallN");
                ww = nw || s.f("WallW");
            } else if (!s.f("halfheight") && !door && !window && !curtain) {
                boolean nw = s.f("WallNW");
                wn = nw || s.f("WallN") || s.f("cutN");
                ww = nw || s.f("WallW") || s.f("cutW");
            }
            boolean stairs = t.startsWith("stairs");
            boolean edge = wn || ww || s.f("WallSE") || door || window || curtain
                || s.f("attachedN") || s.f("WindowN") || s.f("HoppableN") || s.f("TallHoppableN") || s.f("DoorWallN")
                || s.f("attachedW") || s.f("WindowW") || s.f("HoppableW") || s.f("TallHoppableW") || s.f("DoorWallW");
            boolean floor = s.f("solidfloor") && !edge && !stairs && !(V2 && s.props.containsKey("RoofGroup"));
            boolean roofProp = t.startsWith("WestRoof") || s.f("isEave") || s.props.containsKey("RoofGroup");
            boolean roof = V2 ? (!floor && !wn && !ww && roofProp) : (!edge && !floor && roofProp);
            boolean pole = s.f("WallSE") || POLE_SPRITES.contains(name);
            boolean half = s.f("halfheight") && !door && !window && !curtain
                && (s.f("WallN") || s.f("WallW") || s.f("WallNW") || s.f("cutN") || s.f("cutW"));
            boolean solid = (s.f("solid") || s.f("solidtrans")) && !edge && !floor && !stairs;
            if (floor) r |= O_FLOOR;
            if (stairs) r |= O_STAIRS;
            if (wn) r |= O_WN;
            if (ww) r |= O_WW;
            if (pole) r |= O_POLE;
            if (roof) r |= O_ROOF;
            if (half) r |= O_HALF;
            if (solid) r |= O_SOLID;
            if (door) r |= O_DOOR;
            if (window) r |= O_WINDOW;
            if (edge) r |= O_EDGE;
        }
        OBITS.put(name, r);
        return r;
    }

    static int sqBits(int o) {
        if ((o & O_SKIP) != 0) return 0;
        int b = 0;
        if ((o & (O_FLOOR | O_STAIRS)) != 0) b |= G;
        if ((o & O_ROOF) != 0) b |= R;
        if ((o & O_STAIRS) != 0) b |= ST;
        if ((o & O_WW) != 0) b |= EW;
        if ((o & O_WN) != 0) b |= EN;
        if ((o & O_POLE) != 0) b |= P;
        if ((o & O_HALF) != 0) b |= HALF;
        if ((o & O_SOLID) != 0) b |= SOLID;
        return b;
    }

    // ---------------------------------------------------------------- map storage
    static final Map<Long, byte[]> LAYERS = new HashMap<>();    // kept (cell, z) layers, [x*256+y]
    static final Map<Long, byte[]> BORDER = new HashMap<>();    // other layers: column x=0 [0..255] and row y=0 [256..511]
    static final Map<Long, long[]> VISITED = new HashMap<>();
    static final Map<String, long[]> PLACED = new HashMap<>();  // sprite -> {z0, z>=1, z>=1 on a group tile square}
    static long squaresRead, objectsRead;
    static int minZ = 99, maxZ = -99;

    static long key(int cx, int cy, int z) { return (((long) (cx + 4096)) << 24) | ((long) (cy + 4096) << 8) | (z + 64); }

    static int get(int x, int y, int z) {
        int cx = Math.floorDiv(x, 256), cy = Math.floorDiv(y, 256);
        int lx = x - cx * 256, ly = y - cy * 256;
        byte[] l = LAYERS.get(key(cx, cy, z));
        if (l != null) return l[lx * 256 + ly] & 255;
        if (lx == 0 || ly == 0) {
            byte[] b = BORDER.get(key(cx, cy, z));
            if (b != null) return (lx == 0 ? b[ly] : b[256 + lx]) & 255;
        }
        return 0;
    }

    static boolean visit(int x, int y, int z, int slot) {   // slot 0 floor, 1 roof; true when newly visited
        int cx = Math.floorDiv(x, 256), cy = Math.floorDiv(y, 256);
        long k = key(cx, cy, z) * 8 + slot;
        long[] v = VISITED.computeIfAbsent(k, q -> new long[1024]);
        int i = (x - cx * 256) * 256 + (y - cy * 256);
        if ((v[i >> 6] & (1L << (i & 63))) != 0) return false;
        v[i >> 6] |= 1L << (i & 63);
        return true;
    }

    // ---------------------------------------------------------------- cell reading
    static class Header {
        int cx, cy, version, minLevel, maxLevel;
        String[] tiles;
        int[] roomBuilding;   // room index -> building index (-1)
        int[] roomLevel;
        String[] roomName;
        int[][] roomRects;    // room index -> x,y,w,h,... (cell-local)
        int roomAt(int lx, int ly, int z) {   // RoomDef rects: the lotpack room field is -1 in B42 maps
            for (int r = 0; r < roomRects.length; r++) {
                if (roomLevel[r] != z) continue;
                int[] q = roomRects[r];
                for (int i = 0; i < q.length; i += 4)
                    if (lx >= q[i] && lx < q[i] + q[i + 2] && ly >= q[i + 1] && ly < q[i + 1] + q[i + 3]) return r;
            }
            return -1;
        }
    }

    static ByteBuffer map(Path p) throws IOException {
        try (FileChannel c = FileChannel.open(p)) {
            ByteBuffer b = c.map(FileChannel.MapMode.READ_ONLY, 0, c.size());
            b.order(ByteOrder.LITTLE_ENDIAN);
            return b;
        }
    }

    static Header header(Path h) throws IOException {
        Header r = new Header();
        String[] xy = h.getFileName().toString().replace(".lotheader", "").split("_");
        r.cx = Integer.parseInt(xy[0]); r.cy = Integer.parseInt(xy[1]);
        ByteBuffer b = map(h);
        byte[] magic = new byte[4];
        b.get(magic);
        if (!new String(magic, StandardCharsets.US_ASCII).equals("LOTH")) b.position(0);
        r.version = b.getInt();
        int tc = b.getInt();
        r.tiles = new String[tc];
        for (int i = 0; i < tc; i++) r.tiles[i] = line(b).trim();
        if (r.version == 0) b.get();
        b.getInt(); b.getInt();
        if (r.version == 0) { r.minLevel = 0; r.maxLevel = b.getInt() - 1; }
        else { r.minLevel = b.getInt(); r.maxLevel = b.getInt(); }
        int nr = b.getInt();
        r.roomBuilding = new int[nr];
        r.roomLevel = new int[nr];
        r.roomName = new String[nr];
        r.roomRects = new int[nr][];
        Arrays.fill(r.roomBuilding, -1);
        for (int n = 0; n < nr; n++) {
            r.roomName[n] = line(b).trim();
            r.roomLevel[n] = b.getInt();
            int rects = b.getInt();
            r.roomRects[n] = new int[rects * 4];
            for (int i = 0; i < rects * 4; i++) r.roomRects[n][i] = b.getInt();
            int no = b.getInt();
            for (int i = 0; i < no; i++) { b.getInt(); b.getInt(); b.getInt(); }
        }
        int nb = b.getInt();
        for (int n = 0; n < nb; n++) {
            int k = b.getInt();
            for (int i = 0; i < k; i++) {
                int ri = b.getInt();
                if (ri >= 0 && ri < nr) r.roomBuilding[ri] = n;
            }
        }
        return r;
    }

    interface SquareSink { void square(int gx, int gy, int z, int room, int[] objs, int n); }

    // IsoLot.load order: per chunk (lwx, lwy), z from minLevel, x, y; count -1 = skip run; count>1 = room + count-1 tiles
    static void readPack(Header h, Path pack, SquareSink sink) throws IOException {
        ByteBuffer b = map(pack);
        byte[] m2 = new byte[4];
        b.get(m2);
        int pv = 0;
        if (new String(m2, StandardCharsets.US_ASCII).equals("LOTP")) pv = b.getInt();
        else b.position(0);
        int zmin = Math.max(h.minLevel, -32), zmax = Math.min(h.maxLevel, 31);
        int[] objs = new int[64];
        for (int lwx = 0; lwx < 32; lwx++) {
            for (int lwy = 0; lwy < 32; lwy++) {
                int index = lwx * 32 + lwy;
                b.position((pv >= 1 ? 8 : 0) + 4 + index * 8);
                int pos = b.getInt();
                if (pos <= 0 || pos >= b.limit()) continue;
                b.position(pos);
                int skip = 0;
                for (int z = zmin; z <= zmax; z++) {
                    for (int x = 0; x < 8; x++) {
                        for (int y = 0; y < 8; y++) {
                            if (skip > 0) { skip--; continue; }
                            int count = b.getInt();
                            if (count == -1) {
                                skip = b.getInt();
                                if (skip > 0) { skip--; continue; }
                            }
                            if (count > 1) {
                                int room = b.getInt();
                                int n = 0;
                                if (objs.length < count) objs = new int[count * 2];
                                for (int k = 1; k < count; k++) {
                                    int d = b.getInt();
                                    if (d >= 0 && d < h.tiles.length) objs[n++] = d;
                                }
                                sink.square(lwx * 8 + x, lwy * 8 + y, z, room, objs, n);
                            }
                        }
                    }
                }
            }
        }
    }

    static void pass1Cell(Header h, Path pack) throws IOException {
        int zmin = Math.max(h.minLevel, 0), zmax = Math.min(h.maxLevel, 31);
        if (zmax < zmin) return;
        int levels = zmax + 1;
        byte[][] lv = new byte[levels][];
        int[] tb = new int[h.tiles.length];
        for (int i = 0; i < tb.length; i++) tb[i] = sqBits(objBits(h.tiles[i]));
        readPack(h, pack, (gx, gy, z, room, objs, n) -> {
            if (z < 0) return;
            squaresRead++;
            objectsRead += n;
            int bits = 0;
            for (int i = 0; i < n; i++) bits |= tb[objs[i]];
            for (int i = 0; i < n; i++) {
                long[] c = PLACED.computeIfAbsent(h.tiles[objs[i]], q -> new long[3]);
                if (z == 0) c[0]++; else { c[1]++; if ((bits & G) != 0) c[2]++; }
            }
            if (bits == 0) return;
            if (lv[z] == null) lv[z] = new byte[65536];
            lv[z][gx * 256 + gy] = (byte) bits;
        });
        boolean[] upper = new boolean[levels + 1];
        for (int z = 1; z < levels; z++) {
            if (lv[z] == null) continue;
            int want = V2 ? (G | R | EN | EW | P | ST) : (G | R);   // v2: wall-only upper levels are structures too
            for (byte v : lv[z]) if ((v & want) != 0) { upper[z] = true; break; }
        }
        for (int z = 0; z < levels; z++) {
            if (lv[z] == null) continue;
            minZ = Math.min(minZ, z); maxZ = Math.max(maxZ, z);
            if ((z >= 1 && upper[z]) || upper[z + 1]) LAYERS.put(key(h.cx, h.cy, z), lv[z]);
            else {
                byte[] bd = new byte[512];
                boolean any = false;
                for (int i = 0; i < 256; i++) {
                    bd[i] = lv[z][i];               // x = 0, y = i
                    bd[256 + i] = lv[z][i * 256];   // x = i, y = 0
                    any |= bd[i] != 0 || bd[256 + i] != 0;
                }
                if (any) BORDER.put(key(h.cx, h.cy, z), bd);
            }
        }
    }

    // ---------------------------------------------------------------- rules
    // SC.tileSupported(x, y, z) for z >= 1. Returns a mask of support kinds found: 1 wall, 2 stairs, 4 pole (0 = not supported)
    static int support(int x, int y, int z) {
        int zb = z - 1, k = 0;
        int a = get(x, y, zb);
        if ((a & (EW | EN)) != 0) k |= 1;
        if ((a & ST) != 0) k |= 2;
        if ((a & P) != 0) k |= 4;
        if ((get(x + 1, y, zb) & EW) != 0) k |= 1;
        if ((get(x, y + 1, zb) & EN) != 0) k |= 1;
        if ((get(x + 1, y, zb) & P) != 0) k |= 4;
        if ((get(x, y + 1, zb) & P) != 0) k |= 4;
        if ((get(x + 1, y + 1, zb) & P) != 0) k |= 4;
        return k;
    }

    // what-if: halfheight walls (8) and solid objects (16) on the same square / edges
    static int supportExtra(int x, int y, int z) {
        int zb = z - 1, k = 0;
        int a = get(x, y, zb);
        if ((a & HALF) != 0 || (get(x + 1, y, zb) & HALF) != 0 || (get(x, y + 1, zb) & HALF) != 0) k |= 8;
        if ((a & SOLID) != 0) k |= 16;
        return k;
    }

    static boolean roofSupported(int x, int y, int z) {
        if (z < 1) return true;
        if ((get(x, y, z) & G) != 0) return true;
        if ((get(x, y, z - 1) & R) != 0) return true;
        if (V2 && z - 1 >= 1 && (get(x, y, z - 1) & G) != 0) return true;   // v2: a ceiling/floor below, not the ground
        return support(x, y, z) != 0;
    }

    // ---------------------------------------------------------------- v2 structure search (Lua "Structure search")
    // node kinds: 0 f (floor/stairs square), 1 N (wall on the north edge of x,y), 2 W (west edge), 3 P (post)
    static final String KN = "fNWP";
    static boolean exists(int k, int x, int y, int z) {
        int b = get(x, y, z);
        return switch (k) { case 0 -> (b & G) != 0; case 1 -> (b & EN) != 0; case 2 -> (b & EW) != 0; default -> (b & P) != 0; };
    }

    static boolean pAt(int x, int y, int z) { return (get(x, y, z) & P) != 0; }

    static boolean nodeSupported(int k, int x, int y, int z) {
        int zb = z - 1;
        switch (k) {
            case 0: return support(x, y, z) != 0;
            case 1: return (get(x, y, zb) & EN) != 0 || pAt(x, y, zb) || pAt(x - 1, y, zb) || pAt(x, y - 1, zb) || pAt(x - 1, y - 1, zb)
                || pAt(x + 1, y, zb) || pAt(x + 1, y - 1, zb);
            case 2: return (get(x, y, zb) & EW) != 0 || pAt(x, y, zb) || pAt(x - 1, y, zb) || pAt(x, y - 1, zb) || pAt(x - 1, y - 1, zb)
                || pAt(x, y + 1, zb) || pAt(x - 1, y + 1, zb);
            default: return pAt(x, y, zb) || (get(x, y, zb) & (EN | EW)) != 0 || (get(x + 1, y, zb) & EW) != 0 || (get(x, y + 1, zb) & EN) != 0;
        }
    }

    static void atPoint(List<int[]> c, int px, int py) {
        c.add(new int[]{1, px, py}); c.add(new int[]{1, px - 1, py}); c.add(new int[]{2, px, py}); c.add(new int[]{2, px, py - 1});
        c.add(new int[]{3, px, py}); c.add(new int[]{3, px - 1, py}); c.add(new int[]{3, px, py - 1}); c.add(new int[]{3, px - 1, py - 1});
    }

    static List<int[]> candidates(int k, int x, int y) {
        List<int[]> c = new ArrayList<>(36);
        switch (k) {
            case 0 -> {
                c.add(new int[]{0, x + 1, y}); c.add(new int[]{0, x - 1, y}); c.add(new int[]{0, x, y + 1}); c.add(new int[]{0, x, y - 1});
                c.add(new int[]{1, x, y}); c.add(new int[]{2, x, y}); c.add(new int[]{1, x, y + 1}); c.add(new int[]{2, x + 1, y}); c.add(new int[]{3, x, y});
            }
            case 1 -> { atPoint(c, x, y); atPoint(c, x + 1, y); c.add(new int[]{0, x, y}); c.add(new int[]{0, x, y - 1}); }
            case 2 -> { atPoint(c, x, y); atPoint(c, x, y + 1); c.add(new int[]{0, x, y}); c.add(new int[]{0, x - 1, y}); }
            default -> { atPoint(c, x, y); atPoint(c, x + 1, y); atPoint(c, x, y + 1); atPoint(c, x + 1, y + 1); c.add(new int[]{0, x, y}); }
        }
        return c;
    }

    static int[] qk = new int[1 << 16];

    // a whole structure (no early stop): counts nodes by kind and supported nodes
    static Grp sbfs(int k0, int x0, int y0, int z, boolean keepTiles) {
        Grp g = new Grp();
        g.z = z; g.sx = x0; g.sy = y0; g.k0 = k0;
        int head = 0, tail = 0;
        visit(x0, y0, z, k0);
        qk[tail] = k0; qx[tail] = x0; qy[tail++] = y0;
        Set<Long> squares = keepTiles ? new LinkedHashSet<>() : null;
        while (head < tail) {
            int k = qk[head], x = qx[head], y = qy[head++];
            g.size++;
            g.kinds[k]++;
            g.minx = Math.min(g.minx, x); g.maxx = Math.max(g.maxx, x);
            g.miny = Math.min(g.miny, y); g.maxy = Math.max(g.maxy, y);
            if (squares != null) squares.add(((long) x << 32) | (y & 0xFFFFFFFFL));
            if (nodeSupported(k, x, y, z)) {
                g.sup++;
                g.supKinds[k]++;
                if (k == 0) {
                    int s = support(x, y, z);
                    if (s == 2) g.supStairsOnly++;
                    if (s == 4) g.supPoleOnly++;
                    if ((s & 1) != 0) g.supWall++;
                }
            }
            for (int[] c : candidates(k, x, y)) {
                if (!exists(c[0], c[1], c[2], z)) continue;
                if (!visit(c[1], c[2], z, c[0])) continue;
                if (tail == qx.length) { qx = Arrays.copyOf(qx, tail * 2); qy = Arrays.copyOf(qy, tail * 2); qk = Arrays.copyOf(qk, tail * 2); }
                qk[tail] = c[0]; qx[tail] = c[1]; qy[tail++] = c[2];
            }
        }
        if (squares != null) {
            g.tx = new int[squares.size()]; g.ty = new int[squares.size()];
            int i = 0;
            for (long s : squares) { g.tx[i] = (int) (s >> 32); g.ty[i++] = (int) s; }
        }
        return g;
    }

    static class Grp {
        int z, size, minx = Integer.MAX_VALUE, miny = Integer.MAX_VALUE, maxx = Integer.MIN_VALUE, maxy = Integer.MIN_VALUE, sx, sy;
        int sup, supWall, supStairsOnly, supPoleOnly, supHalf, supSolid, cells, onRoof, onFloor;
        boolean roof;
        int k0; int[] kinds = new int[4], supKinds = new int[4];   // v2 structures: nodes f N W P, supported nodes by kind
        int[] tx, ty;   // tiles / node squares (kept only when asked)
        String bbox() { return minx + "," + miny + ".." + maxx + "," + maxy; }
    }

    static int[] qx = new int[1 << 16], qy = new int[1 << 16];

    static Grp bfs(int x0, int y0, int z, boolean roof, boolean keepTiles) {
        int bit = roof ? R : G;
        Grp g = new Grp();
        g.z = z; g.sx = x0; g.sy = y0; g.roof = roof;
        int head = 0, tail = 0;
        visit(x0, y0, z, roof ? 4 : 0);
        qx[tail] = x0; qy[tail++] = y0;
        Set<Long> cells = new HashSet<>();
        while (head < tail) {
            int x = qx[head], y = qy[head++];
            g.size++;
            g.minx = Math.min(g.minx, x); g.maxx = Math.max(g.maxx, x);
            g.miny = Math.min(g.miny, y); g.maxy = Math.max(g.maxy, y);
            cells.add(key(Math.floorDiv(x, 256), Math.floorDiv(y, 256), 0));
            if (roof) {
                if (roofSupported(x, y, z)) g.sup++;
                if ((get(x, y, z - 1) & G) != 0) g.onFloor++;
            } else {
                int k = support(x, y, z);
                if (k != 0) {
                    g.sup++;
                    if ((k & 1) != 0) g.supWall++;
                    if (k == 2) g.supStairsOnly++;
                    if (k == 4) g.supPoleOnly++;
                }
                int below = get(x, y, z - 1);
                if ((below & R) != 0) g.onRoof++;
                if ((below & G) != 0) g.onFloor++;
                int e = supportExtra(x, y, z);
                if (k != 0 || (e & 8) != 0) g.supHalf++;
                if (k != 0 || (e & 16) != 0) g.supSolid++;
            }
            int[][] d = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
            for (int[] dd : d) {
                int nx = x + dd[0], ny = y + dd[1];
                if ((get(nx, ny, z) & bit) == 0) continue;
                if (!visit(nx, ny, z, roof ? 4 : 0)) continue;
                if (tail == qx.length) { qx = Arrays.copyOf(qx, tail * 2); qy = Arrays.copyOf(qy, tail * 2); }
                qx[tail] = nx; qy[tail++] = ny;
            }
        }
        g.cells = cells.size();
        if (keepTiles) { g.tx = Arrays.copyOf(qx, tail); g.ty = Arrays.copyOf(qy, tail); }
        return g;
    }

    // ---------------------------------------------------------------- pass 2: names and buildings for chosen groups
    static class SqInfo { List<String> names = new ArrayList<>(); long building = -1; String roomName; }
    static final Map<Long, SqInfo> NEED = new HashMap<>();
    static long sk(int x, int y, int z) { return (((long) (x + 100000)) << 28) | ((long) (y + 100000) << 8) | (z + 64); }

    static void need(Grp g) {
        for (int i = 0; i < g.tx.length; i++) {
            NEED.putIfAbsent(sk(g.tx[i], g.ty[i], g.z), new SqInfo());
            NEED.putIfAbsent(sk(g.tx[i], g.ty[i], g.z - 1), new SqInfo());
        }
    }

    static String top(Map<String, Integer> m, int n) {
        List<Map.Entry<String, Integer>> l = new ArrayList<>(m.entrySet());
        l.sort((a, b) -> b.getValue() - a.getValue());
        StringBuilder s = new StringBuilder();
        for (int i = 0; i < Math.min(n, l.size()); i++) {
            if (i > 0) s.append(' ');
            s.append(l.get(i).getKey()).append('x').append(l.get(i).getValue());
        }
        return s.toString();
    }

    static class Desc { String floors, below, rooms; int buildings, roomless; }

    static Desc describe(Grp g) {
        Map<String, Integer> fl = new HashMap<>(), bl = new HashMap<>(), rn = new HashMap<>();
        Set<Long> b = new HashSet<>();
        int roomless = 0;
        for (int i = 0; i < g.tx.length; i++) {
            SqInfo a = NEED.get(sk(g.tx[i], g.ty[i], g.z));
            if (a != null) {
                for (String n : a.names) {
                    int o = objBits(n);
                    if (g.roof ? (o & O_ROOF) != 0 : (o & (O_FLOOR | O_STAIRS)) != 0) fl.merge(n, 1, Integer::sum);
                }
                if (a.building >= 0) b.add(a.building); else roomless++;
                if (a.roomName != null) rn.merge(a.roomName, 1, Integer::sum);
            }
            SqInfo u = NEED.get(sk(g.tx[i], g.ty[i], g.z - 1));
            if (u != null) for (String n : u.names) {
                int o = objBits(n);
                if ((o & O_FLOOR) == 0) bl.merge(n, 1, Integer::sum);
            }
        }
        Desc d = new Desc();
        d.floors = top(fl, 4); d.below = top(bl, 6); d.rooms = top(rn, 3); d.buildings = b.size(); d.roomless = roomless;
        return d;
    }

    // ---------------------------------------------------------------- main
    static Map<String, Path[]> cellFiles = new TreeMap<>();

    public static void main(String[] args) throws Exception {
        long t0 = System.currentTimeMillis();
        Path mapDir = Paths.get(args[0]), tdir = Paths.get(args[1]), out = Paths.get(args[2]);
        Files.createDirectories(out);
        for (String f : new String[]{"newtiledefinitions.tiles", "tiledefinitions_erosion.tiles", "tiledefinitions_overlays.tiles",
            "tiledefinitions_b42chunkcaching.tiles", "tiledefinitions_noiseworks.patch.tiles", "jumbo_trees_big.tiles", "jumbo_trees.tiles"})
            loadTdef(tdir.resolve(f));
        System.err.println("sprites " + SPR.size());
        String only = System.getProperty("cells");
        try (var s = Files.list(mapDir)) {
            s.filter(p -> p.toString().endsWith(".lotheader")).forEach(p -> {
                String base = p.getFileName().toString().replace(".lotheader", "");
                if (only != null && !base.matches(only)) return;
                Path pack = p.resolveSibling("world_" + base + ".lotpack");
                if (Files.exists(pack)) cellFiles.put(base, new Path[]{p, pack});
            });
        }
        String prog = System.getProperty("progress");
        int done = 0, failed = 0;
        for (var e : cellFiles.entrySet()) {
            try {
                pass1Cell(header(e.getValue()[0]), e.getValue()[1]);
            } catch (Exception ex) {
                failed++;
                System.err.println("skip " + e.getKey() + ": " + ex);
            }
            if (++done % 500 == 0 || done == cellFiles.size()) {
                String msg = String.format("pass1 cells %d/%d, layers kept %d, borders %d, elapsed %ds, heap used %dMB", done, cellFiles.size(),
                    LAYERS.size(), BORDER.size(), (System.currentTimeMillis() - t0) / 1000,
                    (Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory()) >> 20);
                System.err.println(msg);
                if (prog != null) Files.writeString(Paths.get(prog), new java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss").format(new Date()) + " " + msg + "\n",
                    StandardOpenOption.CREATE, StandardOpenOption.APPEND);
            }
        }

        // probes
        List<String> probes = new ArrayList<>();
        for (int i = 3; i < args.length; i++) probes.add(args[i]);
        List<Grp> probeGroups = new ArrayList<>();
        for (String p : probes) {
            String[] a = p.split(",");
            int x = Integer.parseInt(a[0]), y = Integer.parseInt(a[1]), z = Integer.parseInt(a[2]);
            for (int r = 0; r < 2; r++) {
                if ((get(x, y, z) & (r == 0 ? G : R)) == 0) { System.out.println("probe " + p + (r == 0 ? " floor" : " roof") + ": none"); continue; }
                VISITED.clear();
                Grp g = (V2 && r == 0) ? sbfs(0, x, y, z, true) : bfs(x, y, z, r == 1, true);
                probeGroups.add(g);
            }
        }
        VISITED.clear();

        // all floor groups and roof layers
        List<Grp> floors = new ArrayList<>(), roofs = new ArrayList<>();
        List<Long> keys = new ArrayList<>(LAYERS.keySet());
        Collections.sort(keys);
        for (long k : keys) {
            int z = (int) (k & 255) - 64;
            if (z < 1) continue;
            int cx = (int) (k >>> 24) - 4096, cy = (int) ((k >>> 8) & 0xFFFF) - 4096;
            byte[] l = LAYERS.get(k);
            for (int i = 0; i < 65536; i++) {
                int v = l[i] & 255;
                if (v == 0) continue;
                int x = cx * 256 + i / 256, y = cy * 256 + i % 256;
                if (V2) {
                    for (int kk = 0; kk < 4; kk++)
                        if (exists(kk, x, y, z) && visit(x, y, z, kk)) { unvisit(x, y, z, kk); floors.add(sbfs(kk, x, y, z, false)); }
                    if ((v & R) != 0 && visit(x, y, z, 4)) { unvisit(x, y, z, 4); roofs.add(bfs(x, y, z, true, false)); }
                } else {
                    if ((v & G) != 0 && visit(x, y, z, 0)) { unvisit(x, y, z, 0); floors.add(bfs(x, y, z, false, false)); }
                    if ((v & R) != 0 && visit(x, y, z, 4)) { unvisit(x, y, z, 4); roofs.add(bfs(x, y, z, true, false)); }
                }
            }
        }
        System.err.println("floor groups " + floors.size() + ", roof layers " + roofs.size());

        // chosen groups: tiles again
        List<Grp> zero = new ArrayList<>(), roofBad = new ArrayList<>(), largest = new ArrayList<>(floors);
        for (Grp g : floors) if (g.sup == 0) zero.add(g);
        for (Grp g : roofs) if (g.sup == 0) roofBad.add(g);
        largest.sort((a, b) -> b.size - a.size);
        largest = new ArrayList<>(largest.subList(0, Math.min(10, largest.size())));
        List<Grp> chosen = new ArrayList<>();
        chosen.addAll(zero); chosen.addAll(roofBad); chosen.addAll(largest);
        List<Grp> withTiles = new ArrayList<>();
        for (Grp g : chosen) {
            VISITED.clear();
            Grp t = (V2 && !g.roof) ? sbfs(g.k0, g.sx, g.sy, g.z, true) : bfs(g.sx, g.sy, g.z, g.roof, true);
            g.tx = t.tx; g.ty = t.ty;
            need(g);
        }
        for (Grp g : probeGroups) need(g);
        VISITED.clear();
        // pass 2: read the cells that hold needed squares
        Set<String> needCells = new TreeSet<>();
        for (long k : NEED.keySet()) {
            int x = (int) (k >>> 28) - 100000, y = (int) ((k >>> 8) & 0xFFFFF) - 100000;
            needCells.add(Math.floorDiv(x, 256) + "_" + Math.floorDiv(y, 256));
        }
        for (String c : needCells) {
            Path[] f = cellFiles.get(c);
            if (f == null) continue;
            Header h = header(f[0]);
            readPack(h, f[1], (gx, gy, z, room, objs, n) -> {
                SqInfo s = NEED.get(sk(h.cx * 256 + gx, h.cy * 256 + gy, z));
                if (s == null) return;
                for (int i = 0; i < n; i++) s.names.add(h.tiles[objs[i]]);
                if (room < 0) room = h.roomAt(gx, gy, z);
                if (room >= 0 && room < h.roomBuilding.length) {
                    s.roomName = h.roomName[room];
                    if (h.roomBuilding[room] >= 0) s.building = ((long) (h.cx + 4096) << 40) | ((long) (h.cy + 4096) << 20) | h.roomBuilding[room];
                }
            });
        }
        System.err.println("pass2 cells " + needCells.size());

        // ---------------------------------------------------------------- output
        try (PrintWriter w = pw(out.resolve("floor_groups.tsv"))) {
            // v2: size = nodes; supported_tiles = supported nodes; f/N/W/P node counts and supported counts per kind
            w.println("z\tsize\tsupported_tiles\twall_tiles\tstairs_only_tiles\tpole_only_tiles\tsup_if_halfheight\tsup_if_solid\tcells\tseed_x\tseed_y\tbbox"
                + "\tnodes_f\tnodes_N\tnodes_W\tnodes_P\tsup_f\tsup_N\tsup_W\tsup_P");
            for (Grp g : floors) w.println(g.z + "\t" + g.size + "\t" + g.sup + "\t" + g.supWall + "\t" + g.supStairsOnly + "\t" + g.supPoleOnly + "\t"
                + g.supHalf + "\t" + g.supSolid + "\t" + g.cells + "\t" + g.sx + "\t" + g.sy + "\t" + g.bbox()
                + "\t" + g.kinds[0] + "\t" + g.kinds[1] + "\t" + g.kinds[2] + "\t" + g.kinds[3]
                + "\t" + g.supKinds[0] + "\t" + g.supKinds[1] + "\t" + g.supKinds[2] + "\t" + g.supKinds[3]);
        }
        try (PrintWriter w = pw(out.resolve("roof_layers.tsv"))) {
            w.println("z\tsize\tsupported_tiles\tseed_x\tseed_y\tbbox");
            for (Grp g : roofs) w.println(g.z + "\t" + g.size + "\t" + g.sup + "\t" + g.sx + "\t" + g.sy + "\t" + g.bbox());
        }
        writeDetail(out.resolve("zero_support.tsv"), zero);
        writeDetail(out.resolve("unsupported_roofs.tsv"), roofBad);
        writeDetail(out.resolve("largest.tsv"), largest);
        writeDetail(out.resolve("probes.tsv"), probeGroups);
        for (Grp g : probeGroups) {
            Desc d = describe(g);
            System.out.println("probe " + (g.roof ? "roof" : "floor") + " seed " + g.sx + "," + g.sy + "," + g.z + ": size " + g.size + ", supported " + g.sup
                + ", nodes f/N/W/P " + Arrays.toString(g.kinds) + ", supported f/N/W/P " + Arrays.toString(g.supKinds)
                + ", bbox " + g.bbox() + ", buildings " + d.buildings + ", floors " + d.floors);
        }
        defs(out);
        try (PrintWriter w = pw(out.resolve("summary.txt"))) {
            w.println("cells " + cellFiles.size() + " (failed " + failed + "), squares with objects z>=0 " + squaresRead + ", objects " + objectsRead + ", levels " + minZ + ".." + maxZ);
            w.println("sprites defined " + SPR.size() + ", kept layers " + LAYERS.size() + ", elapsed " + (System.currentTimeMillis() - t0) / 1000 + "s");
            w.println("rules " + (V2 ? "v2 (structures: nodes f/N/W/P; size = nodes)" : "v1 (floor groups; size = tiles)"));
            w.println("floor groups z>=1: " + floors.size() + ", with 0 supports: " + zero.size() + " (tiles " + zero.stream().mapToInt(g -> g.size).sum() + ")");
            if (V2) {
                int[] kz = new int[4];
                for (Grp g : zero) for (int i = 0; i < 4; i++) kz[i] += g.kinds[i];
                w.println("v2 unsupported structures: nodes f/N/W/P " + Arrays.toString(kz) + "; with no floor node " + zero.stream().filter(g -> g.kinds[0] == 0).count()
                    + "; structures with no floor node in all " + floors.stream().filter(g -> g.kinds[0] == 0).count());
            }
            w.println("roof layers z>=1: " + roofs.size() + ", unsupported: " + roofBad.size() + " (tiles " + roofBad.stream().mapToInt(g -> g.size).sum() + ")");
            int[] sz = floors.stream().mapToInt(g -> g.size).sorted().toArray();
            w.println("floor group size: " + dist(sz));
            int[] multi = floors.stream().filter(g -> g.size >= 4).mapToInt(g -> g.size).sorted().toArray();
            w.println("floor group size (groups >= 4 tiles, " + multi.length + "): " + dist(multi));
            int[] sup = floors.stream().mapToInt(g -> g.sup).sorted().toArray();
            w.println("supported tiles per group: " + dist(sup));
            Map<Integer, Integer> byZ = new TreeMap<>();
            for (Grp g : floors) byZ.merge(g.z, 1, Integer::sum);
            w.println("floor groups by z: " + byZ);
            Map<Integer, Integer> zeroZ = new TreeMap<>();
            for (Grp g : zero) zeroZ.merge(g.z, 1, Integer::sum);
            w.println("0-support groups by z: " + zeroZ);
            Map<Integer, Integer> zsz = new TreeMap<>();
            for (Grp g : zero) zsz.merge(g.size >= 10 ? 10 : g.size, 1, Integer::sum);
            w.println("0-support group sizes (10 = 10+): " + zsz);
            int[] buckets = {0, 1, 2, 3, 4, 5, 10, 20, 50, 100, 1000000};
            StringBuilder sb = new StringBuilder("supported-tile buckets: ");
            for (int i = 0; i < buckets.length - 1; i++) {
                int lo = buckets[i], hi = buckets[i + 1];
                long n = floors.stream().filter(g -> g.sup >= lo && g.sup < hi).count();
                sb.append(lo).append(hi - lo > 1 ? "-" + (hi - 1) : "").append(':').append(n).append(' ');
            }
            w.println(sb);
            w.println("groups with 1..3 supported tiles: " + floors.stream().filter(g -> g.sup >= 1 && g.sup <= 3).count()
                + ", of them size >= 10: " + floors.stream().filter(g -> g.sup >= 1 && g.sup <= 3 && g.size >= 10).count());
            w.println("groups whose supported tiles are all stairs-only: " + floors.stream().filter(g -> g.sup > 0 && g.supStairsOnly == g.sup).count()
                + ", size >= 10: " + floors.stream().filter(g -> g.sup > 0 && g.supStairsOnly == g.sup && g.size >= 10).count());
            w.println("groups whose supported tiles are all pole-only: " + floors.stream().filter(g -> g.sup > 0 && g.supPoleOnly == g.sup).count());
            w.println("0-support groups with a roof object under some tile: " + zero.stream().filter(g -> g.onRoof > 0).count()
                + " (tiles " + zero.stream().filter(g -> g.onRoof > 0).mapToInt(g -> g.size).sum() + "), with a floor/stairs under some tile: "
                + zero.stream().filter(g -> g.onFloor > 0).count() + ", with neither: " + zero.stream().filter(g -> g.onRoof == 0 && g.onFloor == 0).count());
            w.println("0-support groups that halfheight walls would hold: " + zero.stream().filter(g -> g.supHalf > 0).count()
                + ", solid objects would hold: " + zero.stream().filter(g -> g.supSolid > 0).count());
            int[] rsz = roofs.stream().mapToInt(g -> g.size).sorted().toArray();
            w.println("roof layer size: " + dist(rsz));
            Map<Integer, Integer> rz = new TreeMap<>();
            for (Grp g : roofBad) rz.merge(g.z, 1, Integer::sum);
            w.println("unsupported roof layers by z: " + rz);
            w.println("unsupported roof layers with a floor/stairs (e.g. ceilings_01_0) under some tile: " + roofBad.stream().filter(g -> g.onFloor > 0).count()
                + ", under every tile: " + roofBad.stream().filter(g -> g.onFloor == g.size).count());
        }
        if (System.getProperty("orphans") != null) orphans(out);
        if (System.getProperty("wires") != null) dumpPlacements(out.resolve("wire_placements.tsv"), System.getProperty("wires"));
        System.err.println("done " + (System.currentTimeMillis() - t0) / 1000 + "s");
    }

    // ---------------------------------------------------------------- "what stays in the air" (-Dorphans=1)
    // An object at z >= 1 can move only if (a) its square is in a floor group's column (a group tile on that square at
    // some level 1..z), (b) it is an edge object on the east (W edge) / south (N edge) / south-east (WallSE) neighbour
    // of such a column, or (c) it is a roof object. Everything else is an orphan: never judged, never moves.
    static final int E_N = 1, E_W = 2, E_SE = 4;
    static final Map<String, Integer> EDGE = new HashMap<>();

    static int edgeDir(String name) {   // Lua edgeOf
        Integer c = EDGE.get(name);
        if (c != null) return c;
        Spr s = SPR.get(name);
        int o = objBits(name), r = 0;
        if (s != null) {
            String t = s.t();
            if ((o & O_WN) != 0) r |= E_N;
            if ((o & O_WW) != 0) r |= E_W;
            if (r == 0) {
                if (s.f("WallSE")) r = E_SE;
                else if ((o & O_DOOR) != 0) r = t.equals("doorN") ? E_N : E_W;
                else if ((o & O_WINDOW) != 0) r = s.f("windowN") ? E_N : E_W;
                else if (t.startsWith("curtain")) r = (t.equals("curtainN") || t.equals("curtainS")) ? E_N : E_W;
                else if (s.f("attachedN") || s.f("WindowN") || s.f("HoppableN") || s.f("TallHoppableN") || s.f("DoorWallN")) r = E_N;
                else if (s.f("attachedW") || s.f("WindowW") || s.f("HoppableW") || s.f("TallHoppableW") || s.f("DoorWallW")) r = E_W;
            }
        }
        EDGE.put(name, r);
        return r;
    }

    static String kind(String name) {
        Spr s = SPR.get(name);
        int o = objBits(name);
        if (s == null) return "undefined";
        if ((o & (O_WN | O_WW)) != 0) return "wall";
        if ((o & O_ROOF) != 0) return "roof";
        if ((o & (O_FLOOR | O_STAIRS)) != 0) return "floor";
        if ((o & (O_DOOR | O_WINDOW)) != 0 || s.t().startsWith("curtain")) return "door/window";
        if (s.f("WallSE")) return "post";
        if (s.f("HoppableN") || s.f("HoppableW") || s.f("TallHoppableN") || s.f("TallHoppableW")) return "fence/railing";
        if (s.f("solid") || s.f("solidtrans") || s.f("container") || s.props.containsKey("IsMoveAble")) return "solid/furniture";
        if (s.f("WallOverlay") || s.f("FloorOverlay") || s.f("attachedN") || s.f("attachedW") || s.f("attachedS") || s.f("attachedE")
            || s.f("attachedSE") || s.f("attachedNW") || s.f("attachedFloor") || s.f("attachedSurface") || s.f("attachedCeiling"))
            return "attached/decoration";
        return "other";
    }

    static boolean multiTop(String name) {   // upper piece of a multi-level sprite (SpriteGridPos x,y,z with z > 0) or a tree
        Spr s = SPR.get(name);
        if (s == null) return false;
        String g = s.props.get("SpriteGridPos");
        if (g != null) {
            String[] p = g.split(",");
            if (p.length >= 3 && !p[2].trim().equals("0")) return true;
        }
        String cn = (s.props.getOrDefault("CustomName", "") + " " + name).toLowerCase();
        // trees, street lights (2-level poles: the lit head is a separate tile one level up), chimneys
        return s.t().equals("tree") || s.props.containsKey("streetlight") || cn.contains("chimney");
    }

    // v2: does any structure at a level 1..z own this object once everything under it is gone? Every floor, wall and
    // post at z >= 1 is a node of some structure, and a structure with nothing left below comes down, so coverage
    // follows buildColumns: floor square "all" (and the walls on its E/S edges, its SE post, the attachedS/E faces
    // north/west of it), wall node: its edge + the other face, post node: its posts; roofs (roof layers); free pieces
    // (SC.isFreeObj on a square with no floor) that stand on something (they fall when that goes).
    // 1 floor column, 2 wall edge / edge of a floor column, 3 roof, 7 post, 8 free piece, 9 outer face; 0 stays up
    static boolean colAny(int x, int y, int z, int mask) {
        for (int k = 1; k <= z; k++) if ((get(x, y, k) & mask) != 0) return true;
        return false;
    }

    static int coverV2(int x, int y, int z, String name, int o, int ed, int below) {
        if (colAny(x, y, z, G)) return 1;
        if ((o & O_ROOF) != 0) return 3;
        if ((o & O_POLE) != 0) return 7;
        if ((ed & E_W) != 0 && (colAny(x, y, z, EW) || colAny(x - 1, y, z, G))) return 2;
        if ((ed & E_N) != 0 && (colAny(x, y, z, EN) || colAny(x, y - 1, z, G))) return 2;
        Spr s = SPR.get(name);
        if (s != null && s.f("attachedS") && colAny(x, y + 1, z, EN | G)) return 9;
        if (s != null && s.f("attachedE") && colAny(x + 1, y, z, EW | G)) return 9;
        // overhead wires: broken when a pole/pylon piece goes (SC.breakWires; reach checked offline by hvsim/wires.py)
        if (isWireName(name)) return 10;
        // things on a roof square (SC.onRoofLayer): they come down with the roof layer
        int here = get(x, y, z);
        if ((here & R) != 0 && (o & (O_WN | O_WW | O_FLOOR | O_STAIRS | O_POLE)) == 0) return 11;
        // SC.isFreeObj: no edge, or an edge thing with no wall on its edge (railing, window without a wall)
        boolean edgeFree = ed != 0 && (o & (O_WN | O_WW)) == 0
            && ((ed & E_N) == 0 || (here & EN) == 0) && ((ed & E_W) == 0 || (here & EW) == 0) && (ed & E_SE) == 0;
        boolean free = (ed == 0 || edgeFree) && (o & (O_FLOOR | O_STAIRS | O_POLE | O_ROOF)) == 0;
        if (free && (below & 1) != 0) return 8;
        return 0;
    }

    static final java.util.regex.Pattern WIRE_RE = java.util.regex.Pattern.compile(
        "appliances_com_01_(9[6-9]|1[0-2][0-9]|13[0-5]|14[3-7])|electricity_pylon_(7[2-9]|[89][0-9]|1[0-6][0-9]|17[0-57-9]|180)");
    static final Map<String, Boolean> WIRE_NAME = new HashMap<>();
    static boolean isWireName(String name) { return WIRE_NAME.computeIfAbsent(name, n -> WIRE_RE.matcher(n).matches()); }

    // what is next to an object that stays up (same level 8 neighbours and its own square; one level above; below)
    static String neighbours(int x, int y, int z) {
        int same = 0;
        for (int dx = -1; dx <= 1; dx++) for (int dy = -1; dy <= 1; dy++) same |= get(x + dx, y + dy, z);
        int up = 0, down = 0;
        for (int dx = -1; dx <= 1; dx++) for (int dy = -1; dy <= 1; dy++) { up |= get(x + dx, y + dy, z + 1); down |= get(x + dx, y + dy, z - 1); }
        StringBuilder b = new StringBuilder();
        b.append("same:").append(bitsStr(same)).append(" up:").append(bitsStr(up)).append(" down:").append(bitsStr(down));
        // how many levels up the nearest roof or floor/ceiling is: on the square itself, within 1, within 2 (0 = none in 8)
        for (int r = 0; r <= 2; r++) {
            int found = 0;
            for (int k = 1; k <= 8 && found == 0; k++)
                for (int dx = -r; dx <= r && found == 0; dx++) for (int dy = -r; dy <= r && found == 0; dy++)
                    if ((get(x + dx, y + dy, z + k) & (R | G)) != 0) found = k;
            b.append(" above").append(r).append(':').append(found);
        }
        return b.toString();
    }

    static String bitsStr(int v) {
        StringBuilder b = new StringBuilder();
        if ((v & R) != 0) b.append("roof,");
        if ((v & (EW | EN)) != 0) b.append("wall,");
        if ((v & P) != 0) b.append("post,");
        if ((v & G) != 0) b.append("floor,");
        if ((v & ST) != 0) b.append("stairs,");
        if ((v & SOLID) != 0) b.append("solid,");
        return b.length() == 0 ? "-" : b.substring(0, b.length() - 1);
    }

    // -Dwires=<regex on sprite name>: every placement of matching sprites (sprite, x, y, z, other objects on the square)
    static void dumpPlacements(Path p, String regex) throws IOException {
        java.util.regex.Pattern re = java.util.regex.Pattern.compile(regex);
        try (PrintWriter w = pw(p)) {
            w.println("sprite\tx\ty\tz\tothers");
            for (var e : cellFiles.values()) {
                Header h = header(e[0]);
                boolean[] want = new boolean[h.tiles.length];
                boolean any = false;
                for (int i = 0; i < want.length; i++) { want[i] = re.matcher(h.tiles[i]).matches(); any |= want[i]; }
                if (!any) continue;
                readPack(h, e[1], (gx, gy, z, room, objs, n) -> {
                    for (int i = 0; i < n; i++) {
                        if (!want[objs[i]]) continue;
                        StringBuilder o = new StringBuilder();
                        for (int j = 0; j < n; j++) if (j != i) o.append(o.length() > 0 ? " " : "").append(h.tiles[objs[j]]);
                        w.println(h.tiles[objs[i]] + "\t" + (h.cx * 256 + gx) + "\t" + (h.cy * 256 + gy) + "\t" + z + "\t" + o);
                    }
                });
            }
        }
    }

    static boolean column(int x, int y, int z) {
        for (int k = 1; k <= z; k++) if ((get(x, y, k) & G) != 0) return true;
        return false;
    }

    static class Tally { long n; String kind; Map<Integer, Long> byZ = new TreeMap<>(); List<String> ex = new ArrayList<>(); Set<Long> exCells = new HashSet<>(); }

    static void tally(Map<String, Tally> m, String key, String kind, int x, int y, int z) {
        Tally t = m.computeIfAbsent(key + "	" + kind, q -> new Tally());
        t.n++;
        t.kind = kind;
        t.byZ.merge(z, 1L, Long::sum);
        long c = key(Math.floorDiv(x, 256), Math.floorDiv(y, 256), 0);
        if (t.ex.size() < 3 && t.exCells.add(c)) t.ex.add(x + "," + y + "," + z);
    }

    static void orphans(Path out) throws IOException {
        long t0 = System.currentTimeMillis();
        Map<String, Tally> orphanSheet = new HashMap<>(), floatSheet = new HashMap<>(), multiSheet = new HashMap<>(), wallSheet = new HashMap<>(),
            nbSheet = new HashMap<>();
        Map<String, Long> nbKind = new TreeMap<>();
        PrintWriter olist = pw(out.resolve("orphans_list.tsv"));
        olist.println("sprite	x	y	z	kind	neighbours");
        long[] total = new long[12];  // 0 objects z>=1, 1 covered a, 2 covered b, 3 covered c, 4 orphans, 5 floating, 6 floating orphans
        Map<String, Long> orphanKind = new TreeMap<>(), floatKind = new TreeMap<>();
        long[] wall = new long[6];    // 0 orphan walls, 1 same-edge wall below, 2 other wall/pole below, 3 none below, 4 in a building, 5 no building
        Set<Long> wallBuildings = new HashSet<>();
        long multiTotal = 0, multiOrphan = 0;
        String prog = System.getProperty("progress");
        int done = 0;
        for (var e : cellFiles.entrySet()) {
            Header h;
            try { h = header(e.getValue()[0]); } catch (Exception ex) { done++; continue; }
            int zmax = Math.min(h.maxLevel, 31);
            if (zmax < 1) { done++; continue; }
            byte[][] any = new byte[zmax + 1][];      // per level: 1 any object, 2 W-edge wall, 4 N-edge wall, 8 pole
            List<int[]> sq = new ArrayList<>();
            readPack(h, e.getValue()[1], (gx, gy, z, room, objs, n) -> {
                if (z < 0 || n == 0) return;
                if (any[z] == null) any[z] = new byte[65536];
                int b = 1;
                for (int i = 0; i < n; i++) {
                    int o = objBits(h.tiles[objs[i]]);
                    if ((o & O_SKIP) != 0) continue;
                    if ((o & O_WW) != 0) b |= 2;
                    if ((o & O_WN) != 0) b |= 4;
                    if ((o & O_POLE) != 0) b |= 8;
                }
                any[z][gx * 256 + gy] |= (byte) b;
                if (z >= 1) {
                    int[] r = new int[n + 3];
                    r[0] = gx; r[1] = gy; r[2] = z;
                    System.arraycopy(objs, 0, r, 3, n);
                    sq.add(r);
                }
            });
            for (int[] r : sq) {
                int gx = r[0], gy = r[1], z = r[2];
                int x = h.cx * 256 + gx, y = h.cy * 256 + gy;
                boolean colA = column(x, y, z);
                int colW = -1, colN = -1, colSE = -1;
                // floating in vanilla: nothing at z-1 on this square, no W wall east, no N wall south, no pole on the 3 corners
                byte[] lb = any[z - 1];
                int below = lb == null ? 0 : lb[gx * 256 + gy];
                boolean held = (below & 1) != 0;
                if (!held) held = edgeBits(lb, h, gx + 1, gy, z - 1, true) || edgeBits(lb, h, gx, gy + 1, z - 1, false)
                    || poleAt(lb, h, gx + 1, gy, z - 1) || poleAt(lb, h, gx, gy + 1, z - 1) || poleAt(lb, h, gx + 1, gy + 1, z - 1);
                for (int i = 3; i < r.length; i++) {
                    String name = h.tiles[r[i]];
                    int o = objBits(name);
                    if ((o & O_SKIP) != 0) continue;
                    total[0]++;
                    String sheet = name.replaceAll("_\\d+$", "");
                    String k = kind(name);
                    boolean mt = multiTop(name);
                    if (mt) multiTotal++;
                    int cover = 0;
                    int ed = edgeDir(name);
                    if (V2) cover = coverV2(x, y, z, name, o, ed, below);
                    else if (colA) cover = 1;
                    else if ((o & O_ROOF) != 0) cover = 3;
                    else {
                        if ((ed & E_W) != 0) { if (colW < 0) colW = column(x - 1, y, z) ? 1 : 0; if (colW == 1) cover = 2; }
                        if (cover == 0 && (ed & E_N) != 0) { if (colN < 0) colN = column(x, y - 1, z) ? 1 : 0; if (colN == 1) cover = 2; }
                        if (cover == 0 && (ed & E_SE) != 0) { if (colSE < 0) colSE = column(x - 1, y - 1, z) ? 1 : 0; if (colSE == 1) cover = 2; }
                    }
                    if (cover > 0) total[cover]++;
                    else {
                        total[4]++;
                        orphanKind.merge(k, 1L, Long::sum);
                        tally(orphanSheet, sheet, k, x, y, z);
                        String nb = neighbours(x, y, z);
                        tally(nbSheet, sheet, k + "	" + nb, x, y, z);
                        nbKind.merge(k + "	" + nb, 1L, Long::sum);
                        olist.println(name + "	" + x + "	" + y + "	" + z + "	" + k + "	" + nb);
                        if (mt) { multiOrphan++; tally(multiSheet, sheet, k, x, y, z); }
                        if (k.equals("wall")) {
                            wall[0]++;
                            tally(wallSheet, sheet, k, x, y, z);
                            boolean same = ((ed & E_W) != 0 && (below & 2) != 0) || ((ed & E_N) != 0 && (below & 4) != 0);
                            if (same) wall[1]++; else if ((below & 14) != 0) wall[2]++; else wall[3]++;
                            int room = -1;
                            for (int zz = z; zz >= 0 && room < 0; zz--) {
                                room = h.roomAt(gx, gy, zz);
                                if (room < 0 && (ed & E_W) != 0 && gx > 0) room = h.roomAt(gx - 1, gy, zz);
                                if (room < 0 && (ed & E_N) != 0 && gy > 0) room = h.roomAt(gx, gy - 1, zz);
                            }
                            if (room >= 0 && h.roomBuilding[room] >= 0) {
                                wall[4]++;
                                wallBuildings.add(((long) (h.cx + 4096) << 40) | ((long) (h.cy + 4096) << 20) | h.roomBuilding[room]);
                            } else wall[5]++;
                        }
                    }
                    if (!held) {
                        total[5]++;
                        if (cover == 0) total[6]++;
                        floatKind.merge(k, 1L, Long::sum);
                        tally(floatSheet, sheet, k, x, y, z);
                    }
                }
            }
            if (++done % 500 == 0 || done == cellFiles.size()) {
                String msg = String.format("orphans cells %d/%d, objects z>=1 %d, orphans %d, elapsed %ds", done, cellFiles.size(), total[0], total[4],
                    (System.currentTimeMillis() - t0) / 1000);
                System.err.println(msg);
                if (prog != null) Files.writeString(Paths.get(prog), new java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss").format(new Date()) + " " + msg + "\n",
                    StandardOpenOption.CREATE, StandardOpenOption.APPEND);
            }
        }
        writeTally(out.resolve("orphans_by_sheet.tsv"), orphanSheet);
        writeTally(out.resolve("floating_by_sheet.tsv"), floatSheet);
        writeTally(out.resolve("multilevel_tops_orphan.tsv"), multiSheet);
        writeTally(out.resolve("orphan_walls_by_sheet.tsv"), wallSheet);
        writeTally(out.resolve("orphans_neighbours.tsv"), nbSheet);
        olist.close();
        try (PrintWriter w = pw(out.resolve("orphans_summary.txt"))) {
            w.println("rules " + (V2 ? "v2" : "v1"));
            if (V2) w.println("objects z>=1 " + total[0] + ": floor column " + total[1] + ", wall edge / floor-column edge " + total[2] + ", roof " + total[3]
                + ", post node " + total[7] + ", free piece on something " + total[8] + ", outer face (attachedS/E) " + total[9]
                + ", wire " + total[10] + ", on a roof square " + total[11] + ", stays up " + total[4]);
            else w.println("objects z>=1 " + total[0] + ": group column (a) " + total[1] + ", edge next to a column (b) " + total[2] + ", roof (c) " + total[3] + ", orphans " + total[4]);
            w.println("orphans by kind: " + orphanKind);
            w.println("orphans by kind and what is next to them (same level 3x3, level above 3x3, level below 3x3):");
            nbKind.entrySet().stream().sorted((a, b) -> Long.compare(b.getValue(), a.getValue())).limit(40)
                .forEach(en -> w.println("  " + en.getValue() + "	" + en.getKey()));
            w.println("orphan walls: " + wall[0] + " placements; same-edge wall straight below " + wall[1] + ", other wall/pole below " + wall[2]
                + ", no wall below " + wall[3] + "; in a map building " + wall[4] + " (" + wallBuildings.size() + " buildings), no building " + wall[5]);
            w.println("multi-level tops (SpriteGridPos z>0 or tree) z>=1: " + multiTotal + ", orphans " + multiOrphan);
            w.println("floating in vanilla (nothing at z-1 on the square, no wall on its E/S edges, no pole on its corners): " + total[5] + ", of them orphans " + total[6]);
            w.println("floating by kind: " + floatKind);
        }
    }

    static boolean edgeBits(byte[] lb, Header h, int gx, int gy, int z, boolean west) {
        if (gx < 256 && gy < 256) return lb != null && (lb[gx * 256 + gy] & (west ? 2 : 4)) != 0;
        return (get(h.cx * 256 + gx, h.cy * 256 + gy, z) & (west ? EW : EN)) != 0;
    }

    static boolean poleAt(byte[] lb, Header h, int gx, int gy, int z) {
        if (gx < 256 && gy < 256) return lb != null && (lb[gx * 256 + gy] & 8) != 0;
        return (get(h.cx * 256 + gx, h.cy * 256 + gy, z) & P) != 0;
    }

    static void writeTally(Path p, Map<String, Tally> m) throws IOException {
        List<Map.Entry<String, Tally>> l = new ArrayList<>(m.entrySet());
        l.sort((a, b) -> Long.compare(b.getValue().n, a.getValue().n));
        try (PrintWriter w = pw(p)) {
            w.println("sheet\tkind\tplacements\tby_z\texamples");
            for (var e : l) w.println(e.getKey() + "\t" + e.getValue().n + "\t" + e.getValue().byZ + "\t" + String.join(" ", e.getValue().ex));
        }
    }

    static void unvisit(int x, int y, int z, int slot) {
        int cx = Math.floorDiv(x, 256), cy = Math.floorDiv(y, 256);
        long[] v = VISITED.get(key(cx, cy, z) * 8 + slot);
        int i = (x - cx * 256) * 256 + (y - cy * 256);
        v[i >> 6] &= ~(1L << (i & 63));
    }

    static String dist(int[] a) {
        if (a.length == 0) return "n=0";
        return "n=" + a.length + " median=" + a[a.length / 2] + " p90=" + a[(int) (a.length * 0.9)] + " p99=" + a[(int) (a.length * 0.99)] + " max=" + a[a.length - 1];
    }

    static void writeDetail(Path p, List<Grp> l) throws IOException {
        try (PrintWriter w = pw(p)) {
            w.println("kind\tz\tsize\tsupported_tiles\tsup_if_halfheight\tsup_if_solid\ttiles_on_roof\ttiles_on_floor\tseed_x\tseed_y\tbbox\tbuildings\troomless_tiles\trooms\tmain_sprites\tbelow_z-1_non_floor");
            for (Grp g : l) {
                Desc d = describe(g);
                w.println((g.roof ? "roof" : "floor") + "\t" + g.z + "\t" + g.size + "\t" + g.sup + "\t" + g.supHalf + "\t" + g.supSolid + "\t" + g.onRoof + "\t" + g.onFloor + "\t" + g.sx + "\t" + g.sy + "\t"
                    + g.bbox() + "\t" + d.buildings + "\t" + d.roomless + "\t" + d.rooms + "\t" + d.floors + "\t" + d.below);
            }
        }
    }

    // definition checks (question 5): sprite property combos, by map placements
    static void defs(Path out) throws IOException {
        try (PrintWriter w = pw(out.resolve("defs_sprites.tsv"))) {
            w.println("check\tsprite\tplaced_z0\tplaced_z1plus\tplaced_on_group_squares\ttype\tflags\tprops");
            List<String> names = new ArrayList<>(PLACED.keySet());
            Collections.sort(names);
            for (String n : names) {
                long[] c = PLACED.get(n);
                Spr s = SPR.get(n);
                int o = objBits(n);
                List<String> checks = new ArrayList<>();
                if (s == null) { checks.add("undefined"); }
                else {
                    String sheet = n.replaceAll("_\\d+$", "");
                    if ((o & O_FLOOR) != 0 && !sheet.startsWith("floors_") && !sheet.startsWith("blends_") && !sheet.startsWith("roofs_"))
                        checks.add("floor_not_floors_sheet");
                    if ((o & O_FLOOR) != 0 && (s.f("solid") || s.f("solidtrans") || s.f("container"))) checks.add("floor_also_solid_or_container");
                    if (s.f("solidfloor") && (o & O_FLOOR) == 0 && (o & O_STAIRS) == 0) checks.add("solidfloor_but_edge");
                    if (s.f("cutN") && !s.f("WallN") && !s.f("WallNW") && (o & O_WN) != 0) checks.add("cutN_without_WallN");
                    if (s.f("cutW") && !s.f("WallW") && !s.f("WallNW") && (o & O_WW) != 0 && !s.f("WallSE")) checks.add("cutW_without_WallW");
                    if ((s.f("WallN") || s.f("WallW") || s.f("WallNW")) && (o & (O_WN | O_WW)) == 0) checks.add("wall_not_counted");
                    if (s.f("halfheight") && (o & O_HALF) != 0) checks.add("halfheight_wall");
                    String cn = (s.props.getOrDefault("CustomName", "") + " " + s.props.getOrDefault("GroupName", "") + " " + n).toLowerCase();
                    if ((o & O_POLE) == 0 && (cn.matches(".*\\b(pole|post|pillar|column|beam|support|stilt)s?\\b.*") || cn.contains("pillar") || cn.contains("column")))
                        checks.add("pole_like_name_not_pole");
                    if ((o & O_POLE) != 0) checks.add("pole");
                    if ((o & O_ROOF) != 0 && s.f("solidfloor")) checks.add("roof_solidfloor");
                    if ((o & O_STAIRS) != 0) checks.add("stairs");
                    if ((o & O_DOOR) != 0 && (s.f("cutN") || s.f("cutW"))) checks.add("door_with_cut");
                }
                for (String ch : checks)
                    w.println(ch + "\t" + n + "\t" + c[0] + "\t" + c[1] + "\t" + c[2] + "\t" + (s == null ? "" : s.t()) + "\t" + (s == null ? "" : flagStr(s)) + "\t"
                        + (s == null ? "" : s.props.keySet().toString()));
            }
        }
    }

    static String flagStr(Spr s) {
        StringBuilder b = new StringBuilder();
        for (int i = s.flags.nextSetBit(0); i >= 0; i = s.flags.nextSetBit(i + 1)) b.append(FLAG_NAMES[i]).append(' ');
        return b.toString().trim();
    }

    static PrintWriter pw(Path p) throws IOException {
        return new PrintWriter(Files.newBufferedWriter(p, StandardCharsets.UTF_8));
    }

    static String line(ByteBuffer b) {
        StringBuilder s = new StringBuilder();
        while (b.hasRemaining()) {
            byte c = b.get();
            if (c == '\n') break;
            s.append((char) c);
        }
        return s.toString();
    }
}
