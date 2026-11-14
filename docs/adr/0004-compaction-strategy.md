# ADR 0004: Compaction 方式に L0 tiered + L1 以降 leveled を採用する

- Status: Accepted
- Date: 2026-11-14
- Related: [ADR 0001](0001-storage-engine-b-plus-tree.md) / [ADR 0002](0002-lsm-tree-adoption-decision.md) / [設計・実装チェックリスト](../design-checklist.md) 1.1.1

## Context

ADR 0001 / ADR 0002 の Open Question「Compaction の方式（leveled / tiered / size-tiered）と世代管理」を決定する。

前提となる設計:

- 書き込み経路は LSM 的（WAL → memtable → immutable memtable → Compaction）、読み取り構造は**不変 B+木セグメント**（[ADR 0001](0001-storage-engine-b-plus-tree.md)）
- 対象ワークロードは読み書きの**両方**を重視し、範囲検索・`ORDER BY`・セカンダリインデックス・一意性制約を扱う（[ADR 0002](0002-lsm-tree-adoption-decision.md)）
- セグメントは不変で、フッタに最小キー / 最大キー / エントリ数 / チェックサムを持つ。読み取り時にキー範囲で足切りできる
- Zig の手動メモリ管理。読み手は参照中のセグメントを保持するため、回収は参照カウントまたはエポックベースになる

評価軸は ADR 0002 の 3 増幅率（Write / Read / Space Amplification）に、**write stall** と**実装量**を加える。

## Decision

1. **L0 は tiered とする。** L0 のセグメントはキー範囲の重複を許し、`segment_id` の降順（新しい順）で参照する。L0 の Compaction は複数の L0 セグメントをまとめて L1 へマージする。
2. **L1 以降は leveled とする。** 各レベルはキー範囲が重複しないセグメント群で構成し、レベルの総サイズをサイズ比 `T` で制限する。
3. 初期パラメータは以下を起点とし、実測で調整する。

   | パラメータ | 初期値 |
   | --- | --- |
   | memtable サイズ | 64 MiB |
   | L0 の Compaction トリガ | 4 セグメント |
   | L0 slowdown / stop | 8 / 12 セグメント |
   | L1 の基準サイズ（base） | 256 MiB |
   | サイズ比 `T` | 10 |
   | 最大レベル数 | 7 |
   | 出力セグメントの目標サイズ | 64 MiB |
   | 同時バックグラウンド Compaction | 2〜4 |
   | Compaction の IO レート制限 | ストレージ帯域の 50% 目安 |

4. **Compaction の選択規則**
   - **L0 → L1**: L0 がトリガに達したら、L0 の全セグメントと、キー範囲が重複する L1 セグメントをマージし、L1 に**非重複**のセグメント群として出力する。
   - **Ln → Ln+1 (n ≥ 1)**: Ln の総サイズが容量 `base × T^(n-1)` を超えたら、Ln からキー範囲の重複が小さいセグメントを選び、Ln+1 の重複セグメントとマージする。
   - 出力は必ず次のレベルへ書き、**降格はしない**。
   - 出力はキー境界で目標サイズに分割し、L1 以降ではレベル内の非重複を保つ。分割後の各セグメントはボトムアップの bulk load で B+木を構築する。
5. **読み取り経路**は `memtable → immutable memtable → L0（新しい順）→ L1 → … → Ln` とする。
   - 点検索は各 L0 セグメントと各レベルの 1 セグメントを、フッタの min/max キー（必要なら bloom filter）で絞ってから B+木を辿る。
   - 範囲検索は候補セグメントのリーフを k-way merge する。
   - L0 は通常 4 本以下に保たれるため、read amplification の上限を設計できる。
6. **世代管理**は「物理世代」「論理世代」「世代交代ポリシー」の 3 層に分けて扱う（後述）。
7. **段階的に実装する。** 最初は L0 → L1 のみ（L1 が実質的な最下段）で動かし、その後に L1 → L2 以降の leveled 選択を追加する。

### 構成

```
INSERT / UPDATE
   │
   ▼
WAL → memtable → immutable memtable
                        │ flush
                        ▼
L0:  [seg][seg][seg][seg]         ← tiered（キー範囲の重複を許す）
      ＼   |   |   /
       ＼  |  /            L0 が 4 本に達したら全 L0 + 重複 L1 をマージ
        ▼ ▼ ▼
L1:  [────seg────][────seg────]   ← leveled（レベル内は非重複）
L2:  [──seg──][──seg──][──seg──]  ← leveled（サイズ比 T=10）
L3:  [─seg─][─seg─][─seg─][─seg─]
```

## 判断基準

### 1. 3 つの増幅率

| 方式 | Write amp | Read amp（点） | Read amp（範囲） | Space amp |
| --- | --- | --- | --- | --- |
| Size-tiered | 低い | run 数（対数オーダー） | 全 run のマージ | 定常 ~1.5 倍、実行中 ~2 倍 |
| Tiered（全レベル） | 低い（数倍〜10 倍） | 最悪 T × レベル数 | 重複 run のマージ | 最大 T 倍（実用 ~2 倍） |
| Leveled（全レベル） | 高い（10〜30 倍） | レベル数 | レベルごとに 1 本 | ≒1.1 |
| **L0 tiered + L1+ leveled（採用）** | 中（L0 のバッチ化で leveled より低減） | L0 本数 + レベル数 | レベルごとに 1 本 + L0 | ≒1.1 + L0 分 |

L0 を leveled にすると、flush のたびに L1 の重複範囲を書き直すことになり、書き込みバーストで write amp と stall が増える。一方、L1 以降を tiered / size-tiered にすると、範囲検索と点検索の read amp、および space amp が悪化し、B+木の利点（順序・範囲走査・セカンダリインデックス）を打ち消す。**L0 だけを tiered にして書き込みをバッチ化し、下段を leveled にして読み取りと容量を締める**のが、本エンジンの要件に最も合う。

### 2. ワークロードとの整合

| 要件 | 本方式での扱い |
| --- | --- |
| 点検索 | 各レベル 1 セグメント + L0 数本。min/max と bloom で足切り |
| 範囲検索 / `ORDER BY` | レベル内が非重複なので、レベルごとに 1 本のリーフ走査で済む |
| セカンダリインデックス | インデックスごとに同じ L0 tiered + L1+ leveled を適用できる |
| 一意性制約 | 点検索の read amp が小さいため、挿入前チェックのコストを抑えられる |
| 書き込みバースト | L0 がバッファとして吸収し、4 本まとめてマージする |
| 不変 B+木セグメント | 出力は bulk load で構築。レベル内非重複を保てる |

### 3. 代替案と採用しなかった理由

| 方式 | 判断 |
| --- | --- |
| Size-tiered のみ | 実装は最小だが、run 数・space amp・範囲検索のマージコストが上限なく増える。v1 の簡易版としては可 |
| 全レベル tiered | write amp は最小だが、read amp が T × レベル数になり、範囲検索と 2 次索引が苦しい |
| 全レベル leveled | read / space は最良だが、L0 の flush ごとに L1 を書き直すため write amp と stall が大きい |
| Lazy leveling（最下段のみ leveled） | 将来の移行候補。write amp を下げたい場合に再評価する |
| Incremental Compaction (ICS) | 将来の移行候補。巨大 Compaction の p99 スパイクが問題になった場合に検討する |
| TWCS / FIFO | 時系列・TTL 専用。汎用 RDBMS の主ストレージには適用しない |

## Rationale

- L0 は本質的にキー範囲が重複する（複数 memtable の flush が並ぶ）ため、tiered として扱うのが自然で、flush ごとの書き直しを避けられる
- L1 以降を leveled にすることで、点検索は「レベルごとに 1 セグメント」、範囲検索は「レベルごとに 1 本のリーフ列」という**予測可能な read amp** になる
- 最下段が leveled なので space amp を ≒1.1 に保ち、tombstone と古いバージョンを回収しやすい
- 実装は「L0 のマージ」と「レベルの容量管理・重複選択」に分割でき、L0 → L1 だけなら早期に動かせる
- セグメントが不変 B+木なので、Compaction 出力の構築は bulk load で済み、in-place 分割の並行性制御が不要

## Consequences

### 良い面

- 書き込みバーストを L0 で吸収しつつ、下段で read / space amplification を抑えられる
- 範囲検索・`ORDER BY`・セカンダリインデックスの性能を B+木のまま維持できる
- レベルごとのサイズ上限により、データ量に対する増幅率の見積もりができる
- L0 → L1 のみの実装から始められ、段階的に leveled を追加できる

### 悪い面 / 注意点

- write amp は全レベル leveled よりは低いが、依然として 10〜30 倍程度になり得る。SSD 寿命と書き込みスループットを監視する
- L0 のセグメント数が増えると点検索の read amp が増える。トリガと stall 閾値のチューニングが必要
- Compaction スケジューラ（容量計算・重複セグメント選択・優先度）の実装量が増える
- L0 → L1 で全 L0 をマージするため、L0 が大きいと 1 回の Compaction が重くなる。目標セグメントサイズで分割し、レート制限を入れる
- tombstone は最下段に到達するまで落とせない。長いスナップショットがあると space amp が増える
- レベル内の非重複を保つため、出力分割時にキー境界の管理が必要
- L0 の参照順（`segment_id` 降順）だけでは MVCC の可視性を保証できない。**可視性は必ず `seq` で判定する**

## 世代管理

### 1. 物理世代 — セグメント ID と可視性

- セグメント生成時に**単調増加の `segment_id`** を割り当てる。ID は再利用しない
- L0 は `segment_id` の降順で参照する。L1 以降はキー範囲で二分探索するため、ID は識別子としてのみ使う
- **manifest（version set）** に `(segment_id, level, min_key, max_key, smallest_seq, largest_seq, size, checksum)` を記録し、これを唯一の真実源とする
- 読み手は参照中の version を保持する。Compaction 後は version をアトミックに差し替え、**参照カウントがゼロになったセグメントだけ**を削除する（Zig ではエポックベース回収も可）
- クラッシュ安全な順序:
  1. 新セグメントを一時ファイルへ書き、fsync
  2. rename で確定
  3. manifest に VersionEdit を追記し、fsync
  4. メモリ上の version を差し替え
  5. 入力セグメントを退役させ、参照がなくなったら削除

### 2. 論理世代 — MVCC の seq とスナップショット

- 各エントリに**コミット seq**（単調増加）を持たせ、`seq <= snapshot` で可視性を判定する
- Compaction は以下を保持する
  - `oldest_active_snapshot` 以下で最新のバージョン
  - `oldest_active_snapshot` より新しいバージョン（進行中のスナップショットが参照する）
  - 上記以外の古いバージョンは破棄
- **tombstone を落とせる条件**
  1. 対象範囲が**最下段**に到達している（下位レベルに古いデータが存在しない）
  2. 削除対象の古いバージョンが他のセグメントに残っていない
  3. その削除を参照するスナップショットが存在しない
- `oldest_active_snapshot` を **GC ホライズン**として監視する。長時間のスナップショットやレプリカ遅延があるとホライズンが進まず、space amp が増大する

### 3. 世代交代ポリシー — level / run の昇格

- flush: memtable 満杯 → immutable → L0 セグメント
- L0 → L1: L0 が 4 本に達したら、L0 全セグメント + 重複する L1 セグメントをマージ
- Ln → Ln+1: Ln の総サイズが `base × T^(n-1)` を超えたら、重複の小さいセグメントから選んで昇格
- 降格はしない。出力は常に次レベル
- write stall 制御: L0 本数と `pending_compaction_bytes` で slow down / stop を切り替える。Compaction には IO レートリミッタを適用する

### 4. 計測する指標

- Write amplification（書いたバイト / 論理書き込みバイト）
- Read amplification（点検索・範囲検索ごとの参照セグメント数）
- Space amplification（実ストレージ / 論理データ量）
- p50 / p99 の書き込み・読み取りレイテンシ
- L0 セグメント数、レベルごとのサイズ、pending compaction bytes、stall 回数

## 実装計画

1. **M1: L0 tiered + L1 のみ** — L0 が 4 本で全 L0 を L1 にマージ。L1 は実質的な最下段。読み取り経路と増幅率を計測
2. **M2: L1 → L2 以降の leveled** — レベル容量、重複セグメント選択、出力分割を実装
3. **M3: 世代管理の完成** — manifest、クラッシュリカバリ、スナップショット連動の GC、参照カウント / エポック回収
4. **M4: チューニングと可観測性** — `T` / base / セグメントサイズ / stall 閾値の調整、bloom filter、レート制限、初期ロードの ingest 経路

## Open Questions

- `T` と base の実測チューニング（対象ワークロードの書き込み比率による）
- write amp が支配的になった場合に lazy leveling へ移行するか
- p99 スパイクが問題になった場合に ICS（断片化 Compaction）を導入するか
- セグメントごとの bloom filter の要否とサイズ（B+木の内部ノードはセグメント内にしか効かない）
- Compaction の並列度・優先度・レート制限の具体値
- 長時間スナップショットによる space amp 増加の扱い（強制 GC / 警告 / 上限）
- 初期ロードを L0 経由にせず、L1 以降へ直接 bulk load する ingest 経路の設計

## Revisit Conditions

以下に該当したら本 ADR を見直す。

- write amplification が SSD 寿命や書き込みスループットの制約になった（→ lazy leveling / tiered）
- Compaction による p99 レイテンシのスパイクが SLO を超えた（→ ICS / レート制限の再設計）
- L0 のセグメント数増加で点検索の read amp が問題になった（→ L0 トリガの見直し / L0 の leveled 化）
- ワークロードが追記専用・時系列に寄った（→ TWCS / size-tiered）
- 範囲検索が不要になり、点検索と追記だけで足りるようになった
