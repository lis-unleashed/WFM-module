"""
REFERENCE PROTOTYPE: exact roster optimiser (OR-Tools + SCIP), weekly-pattern model.

Used during design to prove the planner's rosters optimal (expected scenario:
1 full-time + 8 part-time = 197.5 paid hours, proven optimal).
Port this into the planning service; don't run it as production code as-is.

What to change when porting:
  * Read the requirement from staffing_requirement (people needed per 15 minutes)
    instead of requirements.json.
  * Read the rules from work_pattern and break_rule instead of the hard-coded `ru` dict.
    Units are 15-minute slots: ftLen 30 = 7.5 hrs, ptWeek 80 = 20 hrs, meal 2 = 30 min.
  * Decompose the solution into roster_position, shift and shift_activity rows.
  * Save a roster_optimisation_run with paid_minutes, lower_bound_paid_minutes and proven_optimal.

Usage (prototype): python roster_exact_model.py <scenario> <full-timers...|free>
"""
"""Exact roster optimum via weekly patterns. A part-time pattern = a set of days + a paid length per day,
totalling ptWeek over ptMinDays..ptMaxDays days. z[pattern] counts people on it; each (day, length)
it uses must be matched by a shift with a chosen start and meal time. People on the same pattern are
interchangeable, so this is exact without symmetry problems."""
import json, sys, time, itertools
from ortools.linear_solver import pywraplp
req_all = json.load(open('/home/claude/roster/requirements.json'))
ru = dict(ftLen=30, ftDays=5, ptWeek=80, ptMinDays=3, ptMinLen=20, ptMaxLen=30, meal=2, mealAfter=20)
ru['ptMaxDays'] = min(7, ru['ptWeek'] // ru['ptMinLen'])
def span(L): return L + (ru['meal'] if L > ru['mealAfter'] else 0)
def window(L):
    S = span(L)
    if not L > ru['mealAfter']: return [-1]
    lo, hi = max(4, S - ru['meal'] - ru['mealAfter']), min(ru['mealAfter'], S - ru['meal'] - 4)
    if lo > hi: lo = hi = round((S - ru['meal']) / 2)
    return list(range(lo, hi + 1))
def covered(s, L, m): return [s + k for k in range(span(L)) if not (m >= 0 and m <= k < m + ru['meal'])]

def solve(days, F=None, time_limit=240):
    D = [None if not ds else dict(o=ds[0]['t'] // 15, c=ds[-1]['t'] // 15 + 1, req=[x['N'] for x in ds]) for ds in days]
    cap = [0 if not x else max([L for L in range(1, x['c'] - x['o'] + 1) if span(L) <= x['c'] - x['o']] or [0]) for x in D]
    sv = pywraplp.Solver.CreateSolver('SCIP'); sv.SetTimeLimit(time_limit * 1000)
    # Part-time weekly patterns
    pats = []
    for k in range(ru['ptMinDays'], ru['ptMaxDays'] + 1):
        for ds in itertools.combinations([d for d in range(7) if cap[d] >= ru['ptMinLen']], k):
            ranges = [range(ru['ptMinLen'], min(ru['ptMaxLen'], cap[d]) + 1) for d in ds]
            for Ls in itertools.product(*ranges):
                if sum(Ls) == ru['ptWeek']: pats.append(tuple(zip(ds, Ls)))
    z = [sv.IntVar(0, 50, '') for _ in pats]
    Fv = sv.IntVar(0, 20, 'F') if F is None else F
    cover, need = {}, {}
    for d, x in enumerate(D):
        if not x: continue
        for t in range(x['o'], x['c']): cover[(d, t)] = []
        for L in range(ru['ptMinLen'], min(ru['ptMaxLen'], cap[d]) + 1):
            opts = []
            for s0 in range(x['o'], x['c'] - span(L) + 1):
                for mo in window(L):
                    v = sv.IntVar(0, 50, ''); opts.append(v)
                    for t in covered(s0, L, mo): cover[(d, t)].append(v)
            need[(d, L)] = opts
        if cap[d] >= ru['ftLen']:
            fts = []
            for s0 in range(x['o'], x['c'] - span(ru['ftLen']) + 1):
                for mo in window(ru['ftLen']):
                    v = sv.IntVar(0, 20, ''); fts.append(v)
                    for t in covered(s0, ru['ftLen'], mo): cover[(d, t)].append(v)
            need[(d, 'ft')] = fts
    for (d, t), vs in cover.items(): sv.Add(sv.Sum(vs) >= D[d]['req'][t - D[d]['o']])
    for (d, L), opts in need.items():
        if L == 'ft': continue
        sv.Add(sv.Sum(opts) == sv.Sum([z[i] for i, p in enumerate(pats) if (d, L) in p] or [0]))
    ft_days = [d for d in range(7) if (d, 'ft') in need]
    ftsum = [v for d in ft_days for v in need[(d, 'ft')]]
    sv.Add(sv.Sum(ftsum or [0]) == ru['ftDays'] * Fv)
    for d in ft_days: sv.Add(sv.Sum(need[(d, 'ft')]) <= Fv)
    paid = ru['ftLen'] * ru['ftDays'] * Fv + ru['ptWeek'] * sv.Sum(z)
    sv.Minimize(paid)
    st = sv.Solve()
    if st not in (pywraplp.Solver.OPTIMAL, pywraplp.Solver.FEASIBLE): return None
    Fval = F if F is not None else int(round(Fv.solution_value()))
    P = int(round(sum(v.solution_value() for v in z)))
    return Fval, P, st == pywraplp.Solver.OPTIMAL, len(pats)

sc = sys.argv[1]
for arg in sys.argv[2:]:
    F = None if arg == 'free' else int(arg)
    t0 = time.time(); r = solve(req_all[sc], F)
    if not r: print(f"{sc} FT {arg}: no solution", flush=True); continue
    Fv, P, opt, npat = r
    print(f"{sc} FT {Fv} + PT {P}: paid {Fv*37.5 + P*20} hrs (proven optimal: {opt}, {npat} patterns) {time.time()-t0:.0f}s", flush=True)
