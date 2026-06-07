"""
Shapley 분산 계산용 env 파일 생성기 (codespace 에서 실행).

후보 6항의 모든 부분집합(2^6 = 64개, 공집합 EMPTY 포함)을 env 파일 1개당 1개씩 생성한다.
즉 env 파일 = 부분집합(경우의 수) 1개, 인스턴스 1대 = 부분집합 1개.
(Makefile: SERVER_INSTANCE_COUNT = ls envs/.env.* | wc -l).

vCPU 쿼터 주의:
    instance_type = m7i-flex.large = 2 vCPU.
    계정 On-Demand Standard vCPU 쿼터가 64 라면 동시 실행 가능 인스턴스 = 64/2 = 32대.
    따라서 64개를 한 번에 띄우면 128 vCPU 라 VcpuLimitExceeded 로 실패한다.
    → 64개를 만들되 32개씩 두 배치로 나누어 돌린다.
      배치1 = .env.1 .. .env.32, 배치2 = .env.33 .. .env.64.
    --batch_size 로 배치 크기(기본 32)를 조정한다.

번호 매기는 순서는 부분집합 크기 순이다:
    공집합(EMPTY) → |S|=1 → |S|=2 → ... → |S|=6.
이 순서대로 .env.1, .env.2, ... 번호를 매기고, batch_size 단위로 끊어 배치를 만든다.
(실행 시간 균형은 고려하지 않는다.)

각 env 파일에는 다음이 들어간다:
    - 시뮬레이션 공통 설정 (BASE_DATA_PATH, PM_ACTIVE 등)
    - SHAPLEY_TAG          : part 파일/업로드 이름에 쓰이는 고유 태그
    - SHAPLEY_BATCH        : 이 부분집합이 속한 배치 번호 (1=먼저, 2=나중)
    - SHAPLEY_SUBSETS      : 이 인스턴스가 맡은 부분집합 1개 (','=항 구분, EMPTY=공집합)
    - SHAPLEY_* PSO/N_RUNS : Shapley_cal.ipynb 가 읽는 설정

사용:
    python gen_shapley_envs.py                 # envs/.env.1 .. .env.64 (배치1: 1~32, 배치2: 33~64)
    python gen_shapley_envs.py --batch_size 32
    python gen_shapley_envs.py --candidate_terms PT,SLACK,SETUP,C_TRANSITION,COMPLETION_FAST,WAITING
"""
import os
import sys
import shutil
import argparse
import datetime
import math
from itertools import combinations

HERE = os.path.dirname(os.path.abspath(__file__))
ENVS_DIR = os.path.join(HERE, 'envs')

# DynamicCompositeEvaluator 가 TIME_UNIT='M' 를 강제하고 PM/DOWN 을 인자로 받으므로
# 아래 base 블록의 값은 Shapley_cal.ipynb 가 읽는 것 위주로만 의미가 있다.
BASE_ENV = """\
BASE_DATA_PATH=data
TIME_UNIT=H
MACHINE_RULE=INDEX
PM_HAZARD_THRESHOLD=0.1
JOB_RULE=COMPOSITE
PM_RULE=THRESHOLD
PM_ACTIVE=False
DOWN_ACTIVE=True
"""


def build_subsets(candidate_terms):
    """공집합 포함 모든 부분집합을 (terms_list, kind) 로 반환."""
    items = []
    # 공집합 (FIFO baseline)
    items.append(([], 'light'))
    for k in range(1, len(candidate_terms) + 1):
        for combo in combinations(candidate_terms, k):
            kind = 'light' if k == 1 else 'heavy'
            items.append((sorted(combo), kind))
    return items


def chunk_batches(items, batch_size):
    """부분집합 크기 순(build_subsets 순서)을 그대로 batch_size 단위로 끊어 배치 구성.

    반환: batches[b] = [(terms, kind), ...]  (배치별 부분집합 목록).
    """
    batches = [items[i:i + batch_size] for i in range(0, len(items), batch_size)]
    return batches


def fmt_subset(terms):
    return ','.join(terms) if terms else 'EMPTY'


def main():
    p = argparse.ArgumentParser(description='Shapley 분산 계산용 envs/.env.N 생성 (부분집합 1개당 env 1개)')
    p.add_argument('--candidate_terms',
                   default='PT,SLACK,SETUP,C_TRANSITION,COMPLETION_FAST,WAITING')
    p.add_argument('--batch_size', type=int, default=32,
                   help='한 배치(=동시 실행)당 인스턴스 수. 2vCPU 인스턴스 + 64vCPU 쿼터 → 32 권장')
    p.add_argument('--n_runs', type=int, default=10)
    p.add_argument('--swarm', type=int, default=8)
    p.add_argument('--n_iter', type=int, default=15)
    p.add_argument('--pso_seed', type=int, default=0)
    p.add_argument('--base_seed', type=int, default=0)
    p.add_argument('--no_backup', action='store_true',
                   help='기존 envs/.env.* 백업 없이 삭제')
    args = p.parse_args()

    candidate_terms = [t.strip().upper() for t in args.candidate_terms.split(',') if t.strip()]
    n_terms = len(candidate_terms)
    items = build_subsets(candidate_terms)
    n_subsets = len(items)  # 2^n
    print(f'후보 항 {n_terms}개: {candidate_terms}')
    print(f'부분집합 수(공집합 포함) = env 파일 수: {n_subsets}')

    n_batches = math.ceil(n_subsets / args.batch_size)
    print(f'배치 크기 {args.batch_size} → 배치 {n_batches}개로 나누어 실행 '
          f'(동시 {args.batch_size}대 × 2vCPU = {args.batch_size * 2}vCPU)')
    if args.batch_size > 32:
        print(f'[경고] batch_size={args.batch_size} > 32. 2vCPU 인스턴스 + 64vCPU 쿼터에서는 '
              f'동시 32대까지만 가능 → terraform apply 가 실패할 수 있습니다.')

    # 부분집합 크기 순(EMPTY → |S|=1 → ... → |S|=6)을 그대로 batch_size 단위로 끊는다.
    batches = chunk_batches(items, args.batch_size)

    # 기존 envs/.env.* 백업 후 삭제
    os.makedirs(ENVS_DIR, exist_ok=True)
    existing = [f for f in os.listdir(ENVS_DIR) if f.startswith('.env.')]
    if existing:
        if args.no_backup:
            for f in existing:
                os.remove(os.path.join(ENVS_DIR, f))
            print(f'기존 {len(existing)}개 .env.* 삭제(백업 없음)')
        else:
            ts = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
            backup = os.path.join(HERE, f'envs_backup_{ts}')
            os.makedirs(backup, exist_ok=True)
            for f in existing:
                shutil.move(os.path.join(ENVS_DIR, f), os.path.join(backup, f))
            print(f'기존 {len(existing)}개 .env.* → {backup} 로 백업')

    # 부분집합 크기 순 그대로 .env 번호를 매긴다 (배치1 = 1..batch_size, 배치2 = 그 다음, ...)
    written = 0
    total_heavy = 0
    idx = 0
    for b, subsets in enumerate(batches, start=1):
        for terms, kind in subsets:
            idx += 1
            tag = f'{idx:02d}'
            subset_str = fmt_subset(terms)
            if kind == 'heavy':
                total_heavy += 1
            body = (
                BASE_ENV
                + "\n# === Shapley 분산 계산 (gen_shapley_envs.py 자동 생성) ===\n"
                + f"SHAPLEY_TAG={tag}\n"
                + f"SHAPLEY_BATCH={b}\n"
                + f"SHAPLEY_N_RUNS={args.n_runs}\n"
                + f"SHAPLEY_PSO_SWARM={args.swarm}\n"
                + f"SHAPLEY_PSO_NITER={args.n_iter}\n"
                + f"SHAPLEY_PSO_SEED={args.pso_seed}\n"
                + f"SHAPLEY_BASE_SEED={args.base_seed}\n"
                + f"SHAPLEY_SUBSETS={subset_str}\n"
            )
            with open(os.path.join(ENVS_DIR, f'.env.{idx}'), 'w', encoding='utf-8', newline='\n') as f:
                f.write(body)
            written += 1

    print(f'\n{written}개 env 파일 작성 (부분집합 1개 = 파일 1개).')
    start = 0
    for b, subsets in enumerate(batches, start=1):
        env_lo = start + 1
        env_hi = start + len(subsets)
        start = env_hi
        n_heavy = sum(1 for _, kind in subsets if kind == 'heavy')
        sizes = sorted(len(terms) for terms, _ in subsets)
        print(f'  배치{b}: .env.{env_lo}..{env_hi}  '
              f'({len(subsets)}개, heavy {n_heavy}개, |S| {sizes[0]}~{sizes[-1]})')

    print(f'\n총 부분집합 {n_subsets}개 / heavy(|S|>=2) {total_heavy}개')
    print(f'\n실행 방법 (32개씩 두 배치):')
    print(f'  배치1만 띄우기 → envs/ 에 .env.1..{args.batch_size} 만 두고:  make simulation')
    print(f'  배치1 끝나면 → .env.{args.batch_size+1}.. 으로 교체 후:        make simulation')
    print(f'  (Makefile 이 ls envs/.env.* 로 인스턴스 수를 세므로, 한 번에 한 배치만 envs/ 에 두세요)')


if __name__ == '__main__':
    main()
