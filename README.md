# マルチAZ対応のAuroraMySQLのDaily Update
1. 最新のスナップショットを復元
2. 復元したAuroraMySQLのMySQLパスワードを変更
3. 復元したAuroraMySQLに対してマスキング処理（SQL実行）
4. BIと連携済みのAuroraMySQLを削除（初回構築時は除く）
5. 日次更新したマスキング済みのAuroraMySQL識別子を変更

### total processing time 30m
