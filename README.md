# マスキング処理の流れ
1. BIと連携済みのRDSを削除（初回構築時は除く）
2. 最新のスナップショットを復元
3. 復元したRDSのMySqlパスワードを変更
4. 復元したRDSに対してマスキング処理（SQL実行）
5. マスキングしたRDSの識別子を変更して、BIツールと連携

### 処理時間　約30分
