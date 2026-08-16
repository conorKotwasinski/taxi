import random

import itch

def gen_random_stream(symbols, n_msgs=2000, seed=1, single_level_safe=True):
    rng = random.Random(seed)
    syms = [s if isinstance(s, str) else s.decode() for s in symbols]

    bodies = []
    live = {}
    next_ref = 1
    base_px = {s: 1000000 + 100000 * i for i, s in enumerate(syms)}

    if single_level_safe:
        for s in syms:
            for side, off in (('B', -50000), ('S', +50000)):
                bodies.append(itch._mk('A', ref=next_ref, side=side, shares=1,
                                       stock=s, price=base_px[s] + off))
                live[next_ref] = (s, side, base_px[s] + off, 1)
                next_ref += 1

    for _ in range(n_msgs):
        r = rng.random()
        if r < 0.5 or not live:
            s = rng.choice(syms)
            side = rng.choice(('B', 'S'))
            px = base_px[s] + rng.randint(-3, 3) * 100
            qty = rng.randint(1, 500) * 100
            bodies.append(itch._mk('A', ref=next_ref, side=side, shares=qty,
                                   stock=s, price=px))
            live[next_ref] = (s, side, px, qty)
            next_ref += 1
        elif r < 0.7:
            ref = rng.choice(list(live))
            s, side, px, qty = live[ref]
            take = rng.randint(1, qty)
            bodies.append(itch._mk('E', ref=ref, shares=take))
            if take >= qty:
                del live[ref]
            else:
                live[ref] = (s, side, px, qty - take)
        elif r < 0.8:
            ref = rng.choice(list(live))
            s, side, px, qty = live[ref]
            take = rng.randint(1, qty)
            bodies.append(itch._mk('X', ref=ref, shares=take))
            if take >= qty:
                del live[ref]
            else:
                live[ref] = (s, side, px, qty - take)
        elif r < 0.9:
            ref = rng.choice(list(live))
            bodies.append(itch._mk('D', ref=ref))
            del live[ref]
        else:
            ref = rng.choice(list(live))
            s, side, px, qty = live[ref]
            nqty = rng.randint(1, 500) * 100
            npx = base_px[s] + rng.randint(-3, 3) * 100
            bodies.append(itch._mk('U', ref=ref, new_ref=next_ref,
                                   shares=nqty, price=npx))
            del live[ref]
            live[next_ref] = (s, side, npx, nqty)
            next_ref += 1

    return itch._framed(*bodies), len(bodies)


def gen_stress_bodies(symbols, n_msgs=400, seed=1, levels=16):
    rng = random.Random(seed)
    syms = [s if isinstance(s, str) else s.decode() for s in symbols]
    base_px = {s: 1000000 + 100000 * i for i, s in enumerate(syms)}
    ticks = list(range(-10, 11))

    bodies = []
    live = {}
    next_ref = 1

    def live_prices(s, side):
        return {p for (ls, lsd, p, _q) in live.values() if ls == s and lsd == side}

    def px_of(s, side):
        cur = live_prices(s, side)
        cand = [base_px[s] + t * 100 for t in ticks]
        # if the ladder is nearly full on this side, reuse an existing price
        # (never exceed `levels` distinct live prices -> no RTL overflow, so the
        # bounded RTL ladder and the unbounded golden model stay in agreement)
        if len(cur) >= levels:
            cand = [p for p in cand if p in cur]
            return rng.choice(cand)
        # otherwise deliberately favour NEW prices so the ladder fills to depth
        new = [p for p in cand if p not in cur]
        if new and rng.random() < 0.7:
            return rng.choice(new)
        return rng.choice(cand)

    def add():
        nonlocal next_ref
        s = rng.choice(syms)
        side = rng.choice(('B', 'S'))
        px = px_of(s, side)
        qty = rng.randint(1, 5) * 100
        bodies.append(itch._mk('A', ref=next_ref, side=side, shares=qty,
                               stock=s, price=px))
        live[next_ref] = (s, side, px, qty)
        next_ref += 1

    def find_best_ref():
        if not live:
            return None
        by = {}
        for ref, (s, side, px, qty) in live.items():
            key = (s, side)
            if side == 'B':
                if key not in by or px > by[key][1]:
                    by[key] = (ref, px)
            else:
                if key not in by or px < by[key][1]:
                    by[key] = (ref, px)
        return rng.choice([v[0] for v in by.values()])

    for _ in range(n_msgs):
        r = rng.random()
        if r < 0.55 or not live:
            add()
        elif r < 0.72:
            ref = find_best_ref()
            bodies.append(itch._mk('D', ref=ref))
            del live[ref]
        elif r < 0.75:
            ref = rng.choice(list(live))
            s, side, px, qty = live[ref]
            take = rng.randint(1, qty)
            bodies.append(itch._mk('E', ref=ref, shares=take))
            if take >= qty:
                del live[ref]
            else:
                live[ref] = (s, side, px, qty - take)
        elif r < 0.85:
            ref = rng.choice(list(live))
            s, side, px, qty = live[ref]
            take = rng.randint(1, qty)
            bodies.append(itch._mk('X', ref=ref, shares=take))
            if take >= qty:
                del live[ref]
            else:
                live[ref] = (s, side, px, qty - take)
        else:
            ref = rng.choice(list(live))
            s, side, oldpx, oldq = live[ref]
            nqty = rng.randint(1, 5) * 100
            npx = px_of(s, side)
            bodies.append(itch._mk('U', ref=ref, new_ref=next_ref,
                                   shares=nqty, price=npx))
            del live[ref]
            live[next_ref] = (s, side, npx, nqty)
            next_ref += 1

    return bodies


def gen_depth_bodies(symbols, n_msgs=400, seed=1, levels=16, overflow=False):
    rng = random.Random(seed)
    syms = [s if isinstance(s, str) else s.decode() for s in symbols]
    base_px = {s: 1000000 + 100000 * i for i, s in enumerate(syms)}
    span = levels + (4 if overflow else 0)
    ticks = list(range(span))

    bodies = []
    live = {}
    next_ref = 1

    def live_prices(s, side):
        return {p for (ls, lsd, p, _q) in live.values() if ls == s and lsd == side}

    for _ in range(n_msgs):
        r = rng.random()
        if r < 0.82 or not live:
            s = rng.choice(syms)
            side = rng.choice(('B', 'S'))
            cur = live_prices(s, side)
            cand = [base_px[s] + t * 100 for t in ticks]
            new = [p for p in cand if p not in cur]
            if new:
                px = rng.choice(new)
            elif overflow:
                px = base_px[s] + rng.choice(ticks) * 100
            else:
                px = rng.choice(cand)
            qty = rng.randint(1, 5) * 100
            bodies.append(itch._mk('A', ref=next_ref, side=side, shares=qty,
                                   stock=s, price=px))
            live[next_ref] = (s, side, px, qty)
            next_ref += 1
        else:
            ref = rng.choice(list(live))
            s, side, px, qty = live[ref]
            take = rng.randint(1, qty)
            bodies.append(itch._mk('E', ref=ref, shares=take))
            if take >= qty:
                del live[ref]
            else:
                live[ref] = (s, side, px, qty - take)

    return bodies

if __name__ == '__main__':
    SYMS = ['AAPL', 'MSFT', 'NVDA', 'AMZN']
    stream, n = gen_random_stream(SYMS, n_msgs=2000, seed=1)
    book = itch.build_book(stream, symbols=SYMS)
    print(f"generated {n} book messages, {len(stream)} bytes")
    for s in SYMS:
        print(f"  {s}: {book.top_of_book(s)}")
