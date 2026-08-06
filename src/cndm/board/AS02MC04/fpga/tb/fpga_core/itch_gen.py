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

if __name__ == '__main__':
    SYMS = ['AAPL', 'MSFT', 'NVDA', 'AMZN']
    stream, n = gen_random_stream(SYMS, n_msgs=2000, seed=1)
    book = itch.build_book(stream, symbols=SYMS)
    print(f"generated {n} book messages, {len(stream)} bytes")
    for s in SYMS:
        print(f"  {s}: {book.top_of_book(s)}")
