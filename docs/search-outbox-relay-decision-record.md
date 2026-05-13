# A-1 Search Outbox Relay 의사결정 기록

이 문서는 `test: search outbox lease guard 검증` 작업부터 Search outbox relay 1차 개선까지의 흐름을 정리한 기록입니다. benchmark report가 아니라, relay 안정성 문제를 어떻게 좁혔고 어떤 기준으로 backlog 처리 전략을 선택했는지 남기는 의사결정 기록입니다.

상세 실험 조건과 원본 결과는 `db/experiments/a1-search-outbox-indexing-latency/observations.md`에 남겨 두었습니다.

## 정리 범위

이번 1차 정리는 OpenSearch read path를 안정적으로 동기화하기 위해 필요한 outbox relay의 안전성, 관측성, backlog latency 판단 기준을 다룹니다.

포함한 내용은 다음과 같습니다.

- outbox lease guard 검증
- `claim_token` 기반 stale worker 보호
- `claimed_by`, `claimed_at` 기반 claim 관측성
- relay indexing latency 관측
- Spring app replica scaling smoke
- `fixedDelayMs` 기반 queueWait attribution
- Prometheus 기반 distributed backlog 전략 비교
- `maxDrainRounds=5` 기본 전략 선택
- batch-local `productId` duplicate reindex 감소

이번 범위에는 cross-batch merge, payload snapshot, OpenSearch Bulk API, queue/broker 도입 같은 구조 변경은 포함하지 않았습니다.

## 출발점

Search outbox relay는 DB에 기록된 상품 변경 이벤트를 읽어서 OpenSearch의 product search index를 최신 상태로 맞추는 역할을 합니다.

이 index는 이벤트 이력을 저장하지 않습니다. 검색에서 필요한 것은 각 상품의 최신 상태입니다. 그래서 이번 개선에서는 다음 두 가지를 중요한 기준으로 두었습니다.

- 같은 outbox row가 여러 replica나 worker에 의해 잘못 DONE 처리되지 않아야 합니다.
- backlog가 쌓였을 때 최신 상태 반영이 늦어지는 원인을 분리해서 볼 수 있어야 합니다.

성능 개선보다 먼저 확인해야 했던 것은 안전성이었습니다. 처리 시간을 줄이더라도 stale worker가 새로 claim된 row를 덮어쓰거나, 실패한 row가 잘못 DONE 처리되면 read path 신뢰성이 깨지기 때문입니다.

## Lease guard

먼저 outbox row를 claim한 뒤 상태 전이가 안전한지 검증했습니다.

핵심 문제는 stale worker가 이미 다른 worker에게 다시 claim된 row를 뒤늦게 DONE 또는 FAILED로 바꿀 수 있다는 점이었습니다. 이를 막기 위해 claim 시 `claim_token`을 부여하고, 상태 전이 시 token이 일치할 때만 update되도록 했습니다.

이 결정으로 relay의 기본 안전 기준이 정해졌습니다.

- 여러 replica가 동시에 claim을 시도할 수 있습니다.
- 상태 전이는 `claim_token` 검사를 통과해야 합니다.
- stale worker의 늦은 상태 전이는 무시되어야 합니다.

이 guard가 있었기 때문에 이후 replica scaling, multi-batch 처리, `productId` grouping 같은 변경을 검토할 수 있었습니다.

## 관측성 추가

다음 문제는 relay가 실제로 어떻게 분산 처리되는지 보기 어렵다는 점이었습니다.

`claimed_by`, `claimed_at`을 추가해 어떤 replica가 어떤 row를 claim했는지 DB에서 확인할 수 있게 했습니다. 이 정보는 replica 수를 늘렸을 때 claim이 실제로 분산되는지, 특정 replica에 몰리는지, batch claim count가 어떻게 바뀌는지 확인하는 기준이 되었습니다.

또한 relay indexing latency를 다음 요소로 나누어 볼 수 있게 했습니다.

- `queueWait`
- source document load
- OpenSearch write/delete
- outbox state transition
- relay processing time

이후 실험에서는 전체 Docker log를 수집해서 해석하는 방식 대신, DB 집계와 metric을 중심으로 판단했습니다.

## Replica scaling 확인

Spring app replica를 1개, 2개, 4개로 늘리는 steady-state smoke를 실행했습니다.

초기의 작은 smoke는 하나의 worker나 replica가 한 번에 모든 row를 claim할 수 있어, replica 증가 효과를 판단하는 근거로 보기 어려웠습니다. 그래서 Spring app을 먼저 띄우고 health 상태가 `UP`인 것을 확인한 뒤 row를 넣는 조건으로 다시 확인했습니다.

그 결과 replica 수 증가는 backlog 처리 시간을 줄이는 방향으로 작동했습니다. 다만 남은 latency의 큰 부분은 OpenSearch write 자체보다 `queueWait`이었습니다. 이 관찰이 `fixedDelayMs` attribution으로 이어졌습니다.

## QueueWait 원인 확인

backlog가 남아 있는데도 다음 batch claim이 바로 이어지지 않는지 확인하기 위해 `fixedDelayMs` 값을 바꿔 실험했습니다.

비교한 값은 5000, 1000, 100이었습니다. 같은 `eventCount=1000`, `batchSize=100`, `replicaCount=1` 조건에서 `fixedDelayMs`를 줄일수록 `queueWait` p95와 total processing time이 함께 줄었습니다.

이를 통해 남은 `queueWait`의 주요 원인 중 하나가 batch-to-batch polling delay라는 점을 확인했습니다. 즉, backlog가 남아 있어도 scheduler의 fixed delay가 다음 batch claim을 늦출 수 있었습니다.

이 시점에서 비교할 선택지는 세 가지였습니다.

- polling interval을 줄입니다.
- 한 번에 claim하는 `batchSize`를 키웁니다.
- 한 번의 scheduler run에서 여러 batch를 연속 처리합니다.

## Backlog 처리 전략 비교

다음 단계에서는 세 선택지를 같은 조건에서 비교했습니다.

비교 대상은 다음과 같았습니다.

- baseline: `batchSize=100`, `fixedDelayMs=5000`, `maxDrainRounds=1`
- shorter polling: `batchSize=100`, `fixedDelayMs=1000`, `maxDrainRounds=1`
- larger batch: `batchSize=500`, `fixedDelayMs=5000`, `maxDrainRounds=1`
- multi-batch per scheduler run: `batchSize=100`, `fixedDelayMs=5000`, `maxDrainRounds=5`

초기 Prometheus run에서는 DB의 DONE row 수와 Prometheus의 `processedRowsTotal`이 맞지 않았습니다. 원인은 DONE 직후 바로 PromQL을 조회하면 Prometheus scrape timing 때문에 마지막 drain phase metric 일부가 window에서 빠질 수 있다는 점이었습니다.

그래서 corrected run에서는 모든 row가 DONE이 된 뒤 바로 조회하지 않고, Prometheus가 추가로 scrape할 시간을 기다린 뒤 DB DONE과 `processedRowsTotal`이 일치하는지 확인했습니다. 의사결정에는 이 corrected run만 사용했습니다.

비교 결과는 다음 기준으로 해석했습니다.

- shorter polling은 latency를 줄였지만, idle polling을 늘렸습니다.
- larger batch는 `queueWait`을 줄였지만, per-claim batch size를 키웠습니다.
- multi-batch per scheduler run은 backlog가 있을 때만 연속 처리했고, idle polling을 늘리지 않았으며, `fixedDelayMs`와 `batchSize`를 유지했습니다.

## 기본 전략 결정

A-1 relay의 기본 backlog 처리 전략으로 `maxDrainRounds=5`를 선택했습니다.

선택 기준은 다음과 같습니다.

- corrected Prometheus 비교에서 `totalProcessingTimeMs`와 `totalIndexingLagMs p95`가 가장 좋았습니다.
- `fixedDelayMs=5000`을 유지했습니다.
- `batchSize=100`을 유지했습니다.
- idle polling을 늘리지 않았습니다.
- claim SQL, retry, fallback, mapping 동작을 바꾸지 않았습니다.

shorter polling은 구현은 단순하지만 idle 상태에서도 DB polling을 늘리는 방향이므로 기본값으로 선택하지 않았습니다. larger batch는 claim 횟수를 줄일 수 있지만, 한 번에 소유하는 row 수를 키우고 burst load를 만들 수 있어 기본값으로 선택하지 않았습니다.

따라서 Bulk Indexing이나 payload snapshot 같은 더 큰 구조 변경으로 넘어가기 전에, 기존 relay 구조 안에서 적용 가능한 보수적 개선으로 multi-batch per scheduler run을 먼저 선택했습니다.

## ProductId duplicate reindex 감소

다음으로 같은 relay batch 안에 동일한 `productId`가 여러 번 들어오는 경우를 정리했습니다.

기존 동작에서는 같은 `productId`가 N번 등장하면 source document load도 N번, OpenSearch write/delete도 N번 수행될 수 있었습니다. 하지만 search index는 이벤트 이력이 아니라 최신 product state를 저장합니다.

따라서 이미 claim된 하나의 batch 안에서는 같은 `productId`를 한 번만 처리하도록 했습니다.

- 같은 `productId` group마다 최신 product state를 한 번 load합니다.
- active/current product가 있으면 OpenSearch에 한 번 upsert합니다.
- missing 또는 inactive/deleted 상태이면 OpenSearch에서 한 번 delete합니다.
- 해당 group의 모든 outbox row는 기존 `claim_token` 안전 경로로 DONE 처리합니다.

이 변경의 범위는 batch-local grouping입니다. 서로 다른 batch에 나뉜 같은 `productId`는 merge하지 않습니다.

side effect도 명확히 남겼습니다.

- 처리 단위가 단일 outbox row에서 `productId` group으로 바뀝니다.
- 특정 `productId` group이 실패하면 그 `productId`의 여러 row가 함께 retry될 수 있습니다.
- intermediate state는 index되지 않습니다.
- 이 결정은 search index가 최신 product state를 저장한다는 전제에서만 유효합니다.

## 이번 1차에서 하지 않은 것

이번 단계에서는 다음 변경을 의도적으로 미뤘습니다.

- OpenSearch Bulk API
- payload snapshot
- queue/broker 도입
- claim SQL redesign
- retry, fallback, mapping redesign
- cross-batch `productId` merge
- insert-time outbox merge
- Testcontainers 기반 성능 검증

이 변경들은 효과가 있을 수 있지만, relay의 기본 안전성, 관측성, backlog 처리 기준을 먼저 닫은 뒤 판단할 문제로 남겼습니다.

## 현재 정리

이번 1차 개선 이후 A-1 search outbox relay는 다음 상태가 되었습니다.

- `claim_token` 검사를 통해 stale worker의 늦은 상태 전이를 막습니다.
- `claimed_by`, `claimed_at`으로 replica별 claim 분포를 확인할 수 있습니다.
- latency와 scheduler 동작을 DB와 metric 기반으로 볼 수 있습니다.
- backlog 처리 기본 전략은 `maxDrainRounds=5`입니다.
- 같은 batch 안의 동일 `productId`는 한 번만 source load와 OpenSearch write/delete를 수행합니다.

이 문서의 결론은 relay 최적화가 모두 끝났다는 뜻이 아닙니다. 1차로는 안전성과 관측성을 먼저 닫고, backlog `queueWait`에 대한 기본 처리 전략을 선택했으며, 최신 상태를 저장하는 search model 특성에 맞춰 batch-local duplicate reindex를 줄인 상태입니다.
