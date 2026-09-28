"""
Reference port of PhotoForge's platform-neutral algorithms, line-for-line with the
Swift sources, used to validate logic and the expected values in the Swift tests
(this workspace has no Swift toolchain). Run: python3 tools/reference_check.py
"""
import math, random, datetime as dt
import numpy as np
from scipy.fft import dct as sp_dct

# ---------------- PerceptualHash.swift ----------------
def dct_matrix(n):
    return np.array([[math.cos(math.pi * (2 * x + 1) * u / (2 * n)) for x in range(n)] for u in range(n)])
C32 = dct_matrix(32)

def phash(img32):
    N, K = 32, 8
    tmp = C32[:K] @ img32                     # tmp[u][x] = sum_y C[u][y] X[y][x]
    low = tmp @ C32[:K].T                     # low[u][v] = sum_x tmp[u][x] C[v][x]
    med = np.median(low)
    h = 0
    for i, v in enumerate(low.flatten()):
        if v > med: h |= 1 << (63 - i)
    return h

def phash_imagehash_style(img32):
    d = sp_dct(sp_dct(img32, axis=0), axis=1)[:8, :8]
    med = np.median(d); h = 0
    for i, v in enumerate(d.flatten()):
        if v > med: h |= 1 << (63 - i)
    return h

def dhash(img9x8):
    h, bit = 0, 0
    for y in range(8):
        for x in range(8):
            if img9x8[y, x] < img9x8[y, x + 1]: h |= 1 << (63 - bit)
            bit += 1
    return h

ham = lambda a, b: bin(a ^ b).count("1")

class BKTree:
    def __init__(self): self.root = None
    def insert(self, h, id_):
        if self.root is None: self.root = [h, [id_], {}]; return
        n = self.root
        while True:
            d = ham(h, n[0])
            if d == 0: n[1].append(id_); return
            if d in n[2]: n = n[2][d]
            else: n[2][d] = [h, [id_], {}]; return
    def query(self, h, r):
        out, st = [], ([self.root] if self.root else [])
        while st:
            n = st.pop(); d = ham(h, n[0])
            if d <= r: out += [(i, d) for i in n[1]]
            st += [c for e, c in n[2].items() if d - r <= e <= d + r]
        return out

# ---------------- QualityMetrics.swift ----------------
def lap_var(img):
    l = img[:-2,1:-1] + img[2:,1:-1] + img[1:-1,:-2] + img[1:-1,2:] - 4*img[1:-1,1:-1]
    return float(l.var())

def immerkaer(img):
    k = np.array([[1,-2,1],[-2,4,-2],[1,-2,1]], float); h, w = img.shape
    acc = 0.0
    for dy in range(3):
        for dx in range(3):
            pass
    s = sum(k[dy,dx] * img[dy:h-2+dy, dx:w-2+dx] for dy in range(3) for dx in range(3))
    return float(np.abs(s).sum() * math.sqrt(math.pi/2) / (6*(w-2)*(h-2)))

# ---------------- FaceDetector.swift (FaceAligner) ----------------
TEMPLATE = np.array([[38.2946,51.6963],[73.5318,51.5014],[56.0252,71.7366],[41.5493,92.3655],[70.7299,92.2041]])
def similarity(src, dst):
    ms, md = src.mean(0), dst.mean(0); a = b = v = 0.0
    for p, q in zip(src - ms, dst - md):
        a += p[0]*q[0] + p[1]*q[1]; b += p[0]*q[1] - p[1]*q[0]; v += p @ p
    sc, ss = a/v, b/v
    tx = md[0] - (sc*ms[0] - ss*ms[1]); ty = md[1] - (ss*ms[0] + sc*ms[1])
    return lambda P: np.stack([sc*P[:,0] - ss*P[:,1] + tx, ss*P[:,0] + sc*P[:,1] + ty], 1)

# ---------------- DuplicateScoring.swift ----------------
class UF:
    def __init__(s): s.p = {}
    def find(s, x):
        s.p.setdefault(x, x)
        while s.p[x] != x: s.p[x] = s.p[s.p[x]]; x = s.p[x]
        return x
    def union(s, a, b): s.p[s.find(a)] = s.find(b)
    def comps(s):
        g = {}
        for k in list(s.p): g.setdefault(s.find(k), []).append(k)
        return list(g.values())

TH = dict(nearMaxPHash=6, nearMaxDHash=10, nearLoosePHash=12, nearEmbeddingMin=.95,
          burstWindow=4, burstEmbeddingMin=.85, similarWindow=900, similarEmbeddingMin=.90)
WEIGHTS = dict(technical=.30, faceQuality=.20, aesthetic=.15, resolution=.15, exposure=.10, preference=.10)
PHRASE = dict(technical="the sharpest, cleanest detail", faceQuality="the best face-capture quality",
              aesthetic="the strongest composition score", resolution="more usable resolution",
              exposure="the most balanced exposure", preference="your favourite/edit history")

def raw(a, f):
    q = a.get("quality")
    return {"technical": (0.75*(1-math.exp(-q["lap"]/300)) + 0.25*max(0, 1-q["noise"]/12)) if q else None,
            "faceQuality": a.get("face"), "aesthetic": a.get("aes"),
            "resolution": a["w"]*a["h"]/1e6,
            "exposure": q["exp"] if q else None,
            "preference": (0.7 if a.get("fav") else 0) + (0.2 if a.get("edited") else 0) + (0.1 if a.get("album") else 0)}[f]

def rank(members):
    norm = {}
    for f in WEIGHTS:
        vals = [(m["id"], raw(m, f)) for m in members if raw(m, f) is not None]
        if not vals: continue
        lo, hi = min(v for _, v in vals), max(v for _, v in vals)
        norm[f] = {i: ((v-lo)/(hi-lo) if hi > lo else 0) for i, v in vals}
    tot = sum(WEIGHTS[f] for f in norm)
    out = []
    for m in members:
        comps = {f: norm[f].get(m["id"], 0) for f in norm}
        out.append((m["id"], sum(WEIGHTS[f]/tot*v for f, v in comps.items()), comps))
    return sorted(out, key=lambda r: (-r[1], r[0]))

def explain(ranking):
    if len(ranking) < 2: return ""
    best, others = ranking[0], ranking[1:]
    rs = [f for f, v in best[2].items() if v > max(o[2].get(f, 0) for o in others) + 0.1]
    rs = sorted(rs, key=lambda f: -WEIGHTS[f]*best[2][f])[:3]
    if not rs: return "Recommended as the best overall balance; differences are small."
    lst = PHRASE[rs[0]] if len(rs) == 1 else ", ".join(PHRASE[r] for r in rs[:-1]) + ", and " + PHRASE[rs[-1]]
    return f"Recommended because it has {lst}."

def groups(assets, excluded=frozenset(), notsim=frozenset()):
    assets = [a for a in assets if a["id"] not in excluded]; by = {a["id"]: a for a in assets}
    blocks = lambda x, y: (min(x,y), max(x,y)) in notsim
    assigned, out = set(), []
    byh = {}
    for a in assets:
        if a.get("sha"): byh.setdefault((a["sha"], a.get("size")), []).append(a["id"])
    for ids in byh.values():
        if len(ids) > 1: out.append(("exact", sorted(ids))); assigned |= set(ids)
    t = BKTree()
    for a in assets:
        if a["id"] not in assigned and a.get("p") is not None: t.insert(a["p"], a["id"])
    uf = UF()
    for a in assets:
        if a["id"] in assigned or a.get("p") is None: continue
        for o, d in t.query(a["p"], TH["nearLoosePHash"]):
            if o == a["id"] or blocks(a["id"], o): continue
            b = by[o]
            dd = ham(a["d"], b["d"]) if a.get("d") is not None and b.get("d") is not None else None
            cos = float(np.dot(a["e"], b["e"])) if a.get("e") is not None and b.get("e") is not None else None
            if (d <= TH["nearMaxPHash"] and (dd or 0) <= TH["nearMaxDHash"]) or \
               (d <= TH["nearLoosePHash"] and cos is not None and cos >= TH["nearEmbeddingMin"]):
                uf.union(a["id"], o)
    for c in uf.comps():
        if len(c) > 1: out.append(("near", sorted(c))); assigned |= set(c)
    def window(rem, win, mins, burst):
        res, used = [], set()
        if burst:
            bb = {}
            for a in rem:
                if a.get("burst"): bb.setdefault(a["burst"], []).append(a["id"])
            for ids in bb.values():
                if len(ids) > 1: res.append(sorted(ids)); used |= set(ids)
        dated = sorted([a for a in rem if a.get("t") is not None and a.get("e") is not None and a["id"] not in used], key=lambda a: a["t"])
        for i, s in enumerate(dated):
            if s["id"] in used: continue
            mem = [s["id"]]
            for c in dated[i+1:]:
                if c["t"] - s["t"] > win: break
                if c["id"] not in used and not blocks(s["id"], c["id"]) and float(np.dot(s["e"], c["e"])) >= mins: mem.append(c["id"])
            if len(mem) > 1: res.append(sorted(mem)); used |= set(mem)
        return res
    rem = [a for a in assets if a["id"] not in assigned]
    for g in window(rem, TH["burstWindow"], TH["burstEmbeddingMin"], True): out.append(("burst", g)); assigned |= set(g)
    rest = [a for a in assets if a["id"] not in assigned]
    for g in window(rest, TH["similarWindow"], TH["similarEmbeddingMin"], False): out.append(("similar", g))
    return [(ty, ids, rank([by[i] for i in ids])) for ty, ids in out]

# ---------------- ConstrainedClustering.swift ----------------
CFG = dict(k=30, base=.45, qpen=.15, smallpx=64, smallpen=.05, minq=.3, minsize=3, iters=40, margin=.05)

def cluster(faces, must=(), cannot=(), confirmed=None):
    confirmed = confirmed or {}; review = []
    usable = []
    for f in faces:
        if f["q"] < CFG["minq"]: review.append((f["id"], "lowQuality"))
        else: usable.append(f)
    by = {f["id"]: f for f in usable}
    parent = {f["id"]: f["id"] for f in usable}
    def find(x):
        while parent[x] != x: parent[x] = parent[parent[x]]; x = parent[x]
        return x
    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb: parent[max(ra, rb)] = min(ra, rb)
    for a, b in must:
        if a in by and b in by: union(a, b)
    byp = {}
    for f, p in confirmed.items():
        if f in by: byp.setdefault(p, []).append(f)
    for fs in byp.values():
        for a, b in zip(fs, fs[1:]): union(a, b)
    cn = {}
    for a, b in cannot:
        if a in by and b in by and find(a) != find(b):
            cn.setdefault(find(a), set()).add(find(b)); cn.setdefault(find(b), set()).add(find(a))
    roots = {p: find(fs[0]) for p, fs in byp.items()}
    for p1, r1 in roots.items():
        for p2, r2 in roots.items():
            if p1 != p2: cn.setdefault(r1, set()).add(r2)
    def thr(a, b):
        t = CFG["base"] + CFG["qpen"] * (1 - min(a["q"], b["q"]))
        if min(a["px"], b["px"]) < CFG["smallpx"]: t += CFG["smallpen"]
        return t
    E = np.array([f["e"] for f in usable]); ids = [f["id"] for f in usable]
    S = E @ E.T
    graph = {}
    for i, f in enumerate(usable):
        rf = find(f["id"])
        order = [j for j in np.argsort(-S[i]) if j != i][:CFG["k"]]
        for j in order:
            g = usable[j]; rn = find(g["id"])
            if rn == rf or rn in cn.get(rf, set()): continue
            if S[i, j] >= thr(f, g):
                graph.setdefault(rf, {}).setdefault(rn, 0); graph[rf][rn] += S[i, j]
                graph.setdefault(rn, {}).setdefault(rf, 0); graph[rn][rf] += S[i, j]
    nodes = sorted({find(i) for i in ids}); label = {n: n for n in nodes}
    rng = random.Random(0x5EED)
    for _ in range(CFG["iters"]):
        ch = False; order = nodes[:]; rng.shuffle(order)
        for n in order:
            ed = graph.get(n)
            if not ed: continue
            sc = {}
            for m, w in ed.items(): sc[label[m]] = sc.get(label[m], 0) + w
            bl = cn.get(n, set())
            cands = [(v, k) for k, v in sc.items() if not any(label[x] == k for x in bl)]
            if not cands: continue
            best = max(cands, key=lambda t: (t[0], -t[1]))[1]
            if best != label[n]: label[n] = best; ch = True
        if not ch: break
    mem = {}
    for f in usable: mem.setdefault(label[find(f["id"])], []).append(f["id"])
    def mk(fids, person):
        if not fids: return dict(faces=[], c=None, mean=0, conf="low", person=person)
        c = sum(by[f]["q"] * np.array(by[f]["e"]) for f in fids); c = c / np.linalg.norm(c)
        mean = float(np.mean([np.dot(by[f]["e"], c) for f in fids]))
        conf = "confirmed" if person is not None else "likely" if mean >= .7 and len(fids) >= 5 else "needs_review" if mean >= .55 else "low"
        return dict(faces=fids, c=c, mean=mean, conf=conf, person=person)
    clusters = []
    for k in sorted(mem):
        fids = mem[k]; persons = {confirmed[f] for f in fids if f in confirmed}
        if len(fids) < CFG["minsize"] and not persons:
            review += [(f, "belowClusterThreshold") for f in fids]; continue
        clusters.append(mk(fids, next(iter(persons)) if len(persons) == 1 else None))
    cf = {}
    for a, b in cannot: cf.setdefault(a, set()).add(b); cf.setdefault(b, set()).add(a)
    protected = set(confirmed) | {f for pr in must for f in pr}
    for ci, c in enumerate(clusters):
        sc = [(f, float(np.dot(by[f]["e"], c["c"]))) for f in c["faces"]]
        sims = np.array([s for _, s in sc]); floor = max(CFG["base"], sims.mean() - 3 * sims.std())
        keep = []
        for f, s in sorted(sc, key=lambda t: (not (t[0] in protected), -t[1])):
            conf = f in protected
            if (cf.get(f, set()) & set(keep)) and not conf: review.append((f, "constraintConflict"))
            elif s < floor and not conf: review.append((f, "belowClusterThreshold"))
            else: keep.append(f)
        if len(keep) != len(c["faces"]): clusters[ci] = mk(keep, c["person"])
    if len(clusters) > 1:
        for ci in range(len(clusters)):
            keep = []
            for f in clusters[ci]["faces"]:
                if f in protected: keep.append(f); continue
                own = np.dot(by[f]["e"], clusters[ci]["c"])
                oth = max(np.dot(by[f]["e"], clusters[j]["c"]) for j in range(len(clusters)) if j != ci and clusters[j]["c"] is not None)
                if oth > own - CFG["margin"]: review.append((f, "ambiguous"))
                else: keep.append(f)
            if len(keep) != len(clusters[ci]["faces"]): clusters[ci] = mk(keep, clusters[ci]["person"])
    return [c for c in clusters if c["faces"]], review

# ---------------- GenerativeEditPolicy.swift ----------------
import re
SEX = ["nude","naked","topless","undress","nsfw","explicit","sexual","lingerie","porn"]
MIN = ["child","children","kid","kids","teen","teenage","underage","minor","schoolgirl","schoolboy","young-looking","loli","shota","baby","toddler"]
def check_request(prompt, src_exp, minor, real, adult):
    p = prompt.lower(); sx = any(t in p for t in SEX); mn = any(re.search(r"\b"+re.escape(t)+r"\b", p) for t in MIN)
    if (sx or src_exp >= .5) and (mn or minor >= .2): return ("block", True)
    if sx and real and src_exp < .5: return ("block", True)
    if sx and not adult: return ("block", False)
    return ("allow",)
def check_output(src_exp, out_exp, minor, real, adult):
    ex = out_exp >= .5
    if (ex or src_exp >= .5) and minor >= .2: return ("block", True)
    if real and ex and out_exp > src_exp + .15: return ("block", True)
    if ex and not adult: return ("block", False)
    return ("label",) if ex else ("allow",)

# =====================================================================
if __name__ == "__main__":
    rs = np.random.default_rng(7)
    ok = lambda c, m: print(("PASS " if c else "FAIL ") + m) or c
    results = []

    # --- pHash: matches imagehash's DCT definition exactly on the same raster
    for _ in range(50):
        img = rs.uniform(0, 255, (32, 32))
        if phash(img) != phash_imagehash_style(img): results.append(ok(False, "pHash != imagehash DCT")); break
    else: results.append(ok(True, "pHash bit-identical to imagehash-style scipy DCT on 50 random rasters"))

    # --- pHash robustness on a structured synthetic scene (used by Swift tests)
    def smooth_scene(seed):
        # 1/f ("natural image") spectrum, rescaled into 40…215 so edits don't clip.
        r = np.random.default_rng(seed); n = 256
        fy, fx = np.meshgrid(np.fft.fftfreq(n), np.fft.fftfreq(n), indexing="ij")
        amp = 1.0 / np.maximum(np.hypot(fx, fy), 1.0 / n)
        field = np.real(np.fft.ifft2(amp * np.exp(2j * np.pi * r.uniform(size=(n, n)))))
        field = (field - field.min()) / (field.max() - field.min())
        return 40 + 175 * field
    down = lambda im: im.reshape(32, 8, 32, 8).mean(axis=(1, 3))          # stands in for CG high-quality resize
    full = smooth_scene(11)
    scene = down(full)
    bright = down(np.clip(full * 1.08 + 10, 0, 255))                        # exposure change
    noisy = down(np.clip(full + rs.normal(0, 6, full.shape), 0, 255))      # sensor noise / recompression
    other = down(smooth_scene(12))
    d_b, d_n, d_o = ham(phash(scene), phash(bright)), ham(phash(scene), phash(noisy)), ham(phash(scene), phash(other))
    results.append(ok(d_b <= 6 and d_n <= 6 and d_o >= 20, f"pHash distances: brighter={d_b} noisy={d_n} different={d_o}"))

    # --- BK-tree == brute force
    hs = [int(rs.integers(0, 2**63)) for _ in range(2000)]; t = BKTree()
    for i, h in enumerate(hs): t.insert(h, i)
    q = hs[5] ^ 0b1011
    brute = sorted(i for i, h in enumerate(hs) if ham(q, h) <= 10)
    results.append(ok(sorted(i for i, _ in t.query(q, 10)) == brute, f"BK-tree radius query matches brute force ({len(brute)} hits)"))

    # --- Quality metrics order sensibly
    sharp = np.kron(rs.uniform(0, 255, (64, 64)), np.ones((4, 4)))
    blur = sharp.copy()
    for _ in range(4): blur[1:-1,1:-1] = (blur[:-2,1:-1]+blur[2:,1:-1]+blur[1:-1,:-2]+blur[1:-1,2:]+blur[1:-1,1:-1])/5
    flat = np.full((128, 128), 120.0); n8 = np.clip(flat + rs.normal(0, 8, flat.shape), 0, 255)
    results.append(ok(lap_var(sharp) > lap_var(blur) * 5, f"sharpness: sharp={lap_var(sharp):.0f} blurred={lap_var(blur):.0f}"))
    results.append(ok(abs(immerkaer(n8) - 8) < 1.0 and immerkaer(flat) < 0.01, f"Immerkær noise σ: est={immerkaer(n8):.2f} (true 8), flat={immerkaer(flat):.3f}"))

    # --- Umeyama alignment recovers a known similarity transform exactly
    th, s, t0 = 0.3, 2.4, np.array([130., 80.])
    R = np.array([[math.cos(th), -math.sin(th)], [math.sin(th), math.cos(th)]])
    src = (TEMPLATE - t0) @ np.linalg.inv(s*R).T      # points such that s·R·src + t0 = TEMPLATE
    err = np.abs(similarity(src, TEMPLATE)(src) - TEMPLATE).max()
    results.append(ok(err < 1e-9, f"5-point similarity alignment residual {err:.2e}"))

    # --- Duplicate grouping scenario (mirrors DuplicateGrouperTests.swift)
    def unit(v): v = np.asarray(v, float); return v / np.linalg.norm(v)
    base_e = unit(rs.normal(size=64)); other_e = unit(rs.normal(size=64))
    near_e = unit(base_e + rs.normal(0, .02, 64))
    q = lambda lap, noise, exp: dict(lap=lap, noise=noise, exp=exp)
    P = 0x0F0F_F0F0_1234_5678; D = 0x1111_2222_3333_4444
    t_ = 1_700_000_000
    assets = [
        dict(id=1, sha=b"A", size=100, w=4000, h=3000, p=P, d=D, e=base_e, t=t_, quality=q(200, 3, .8)),
        dict(id=2, sha=b"A", size=100, w=4000, h=3000, p=P, d=D, e=base_e, t=t_+60, quality=q(200, 3, .8)),
        dict(id=3, sha=b"B", size=90,  w=4000, h=3000, p=P ^ 0b111, d=D ^ 0b11, e=near_e, t=t_+120, quality=q(600, 2, .85), fav=True),
        dict(id=4, sha=b"C", size=40,  w=2000, h=1500, p=P ^ 0b11, d=D ^ 0b1, e=near_e, t=t_+130, quality=q(90, 6, .6)),
        dict(id=5, sha=b"D", size=80,  w=4000, h=3000, p=~P & (2**64-1), d=~D & (2**64-1), e=other_e, t=t_+5000, quality=q(300, 3, .7), burst="B1"),
        dict(id=6, sha=b"E", size=81,  w=4000, h=3000, p=(~P & (2**64-1)) ^ (2**40-1), d=(~D & (2**64-1)) ^ (2**40-1), e=other_e, t=t_+5001, quality=q(500, 2, .8), burst="B1"),
        dict(id=7, sha=b"F", size=70,  w=4000, h=3000, p=0xAAAA_5555_AAAA_5555, d=0x5555_AAAA_5555_AAAA, e=unit(rs.normal(size=64)), t=t_+9000, quality=q(300, 3, .7)),
    ]
    g = groups(assets)
    kinds = {ty: ids for ty, ids, _ in g}
    results.append(ok(kinds.get("exact") == [1, 2] and kinds.get("near") == [3, 4] and kinds.get("burst") == [5, 6] and len(g) == 3,
                      f"groups: {[(ty, ids) for ty, ids, _ in g]}"))
    near_rank = [r for ty, _, r in g if ty == "near"][0]
    results.append(ok(near_rank[0][0] == 3, f"best of near group = {near_rank[0][0]} — {explain(near_rank)}"))
    g2 = groups(assets, notsim={(3, 4)})
    results.append(ok("near" not in {ty for ty, _, _ in g2}, "'not similar' pair suppresses the near group"))

    # --- Face clustering scenario (mirrors ConstrainedClusteringTests.swift)
    def identity(n, seed, spread=.25):
        r = np.random.default_rng(seed); c = unit(r.normal(size=128))
        return [unit(c + r.normal(0, spread/np.sqrt(128), 128)) for _ in range(n)]
    A, B, C = identity(12, 1), identity(10, 2), identity(8, 3)
    faces = [dict(id=i+1, e=e, q=.9, px=150) for i, e in enumerate(A + B + C)]
    faces.append(dict(id=99, e=A[0], q=.1, px=40))                    # low quality → review
    cl, rv = cluster(faces)
    sizes = sorted(len(c["faces"]) for c in cl)
    results.append(ok(sizes == [8, 10, 12] and (99, "lowQuality") in rv, f"3 identities recovered: sizes={sizes}, review={rv}"))
    results.append(ok(all(c["conf"] == "likely" for c in cl), f"unconfirmed clusters labelled {[c['conf'] for c in cl]} (never 'confirmed')"))
    cl2, rv2 = cluster(faces, cannot=[(1, 2)])
    home = {f: i for i, c in enumerate(cl2) for f in c["faces"]}
    results.append(ok(not (1 in home and 2 in home and home[1] == home[2]), f"cannot-link(1,2) respected: 1→{home.get(1)} 2→{home.get(2)}"))
    cl3, _ = cluster(faces, must=[(1, 13)])     # user says face 1 (A) and 13 (B) are the same person
    home3 = {f: i for i, c in enumerate(cl3) for f in c["faces"]}
    results.append(ok(home3.get(1) is not None and home3.get(1) == home3.get(13), f"must-link(1,13) respected: 1→{home3.get(1)} 13→{home3.get(13)}"))
    cl4, _ = cluster(faces, confirmed={1: 501, 2: 501, 13: 777})
    persons = sorted(c["person"] for c in cl4 if c["person"])
    results.append(ok(persons == [501, 777] and sum(c["conf"] == "confirmed" for c in cl4) == 2, f"confirmed persons stay stable: {persons}"))

    # --- Safety policy truth table (mirrors GenerativeEditPolicyTests.swift)
    cases = [
        (check_request("make her nude", 0.0, 0.0, True, True), ("block", True), "sexualise real person → hard block even with adult mode"),
        (check_request("remove the lamp", 0.9, 0.3, True, True), ("block", True), "explicit source + possible minor → hard block"),
        (check_request("teen at the beach, nsfw", 0.0, 0.0, False, True), ("block", True), "minor term + sexual term → hard block"),
        (check_request("replace background with a beach", 0.9, 0.0, True, True), ("allow",), "own explicit media, adult mode on, neutral edit → allow"),
        (check_request("replace background with a beach", 0.9, 0.0, True, False), ("allow",), "request neutral; output gate handles adult-off"),
        (check_output(0.9, 0.9, 0.0, True, False), ("block", False), "explicit output, adult mode off → soft block"),
        (check_output(0.1, 0.8, 0.0, True, True), ("block", True), "output escalates real person → hard block"),
        (check_output(0.9, 0.92, 0.0, True, True), ("label",), "no escalation, adult mode on → allow with label"),
        (check_request("remove the kid's toy", 0.0, 0.0, True, False), ("allow",), "benign prompt mentioning a kid → allow"),
    ]
    for got, want, msg in cases: results.append(ok(got == want, f"policy: {msg} (got {got})"))

    print(f"\n{sum(results)}/{len(results)} checks passed")
