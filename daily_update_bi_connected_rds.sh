#!/bin/bash -l

set -eu

aws_comand_path=$(which aws)

call_get_parameter ()
{
  $aws_comand_path ssm get-parameter --name $1 --with-decryption --query Parameter.Value 
}

reject_double_quotation ()
{
  sed "s/\"//g"
}

change_double_to_single_quotation ()
{
  sed "s/\"/'/g"
}

get_latest_snapshot_rds_identifier () 
{
  $aws_comand_path rds describe-db-cluster-snapshots \
  --query "reverse(sort_by(DBClusterSnapshots[?DBClusterIdentifier==$1],&SnapshotCreateTime))[0].DBClusterSnapshotIdentifier"
}

# 各パラメータを変数に代入
ANALYTICS_DB_IDENTIFIER=$(call_get_parameter /Prod/DokugakuEngineer/Analytics/ANALYTICS_DB_IDENTIFIER | reject_double_quotation)
ANALYTICS_DB_INSTANCE_IDENTIFIER=$(call_get_parameter /Prod/DokugakuEngineer/Analytics/ANALYTICS_DB_INSTANCE_IDENTIFIER | reject_double_quotation)
ANALYTICS_DB_AVAILABILITY_ZONE=$(call_get_parameter /Prod/DokugakuEngineer/Analytics/ANALYTICS_DB_AVAILABILITY_ZONE | reject_double_quotation)
ANALYTICS_DB_SUBNET_GROUP_NAME=$(call_get_parameter /Prod/DokugakuEngineer/Analytics/ANALYTICS_DB_SUBNET_GROUP_NAME | reject_double_quotation)
ANYLITICS_DB_VPC_SECURITY_GROUP_ID=$(call_get_parameter /Prod/DokugakuEngineer/Analytics/ANYLITICS_DB_VPC_SECURITY_GROUP_ID | reject_double_quotation)
ANALYTICS_DB_PARAMETER_GROUP_NAME=$(call_get_parameter /Prod/DokugakuEngineer/Analytics/ANALYTICS_DB_PARAMETER_GROUP_NAME | reject_double_quotation)

# 本番AuroraMySQLからスナップショットを取る
DB_IDENTIFIER=$(call_get_parameter /Prod/DokugakuEngineer/Analytics/DB_IDENTIFIER | change_double_to_single_quotation)
main_snapshot_rds_identifier=$(get_latest_snapshot_rds_identifier $DB_IDENTIFIER)
main_snapshot_rds_identifier=$(echo $main_snapshot_rds_identifier | reject_double_quotation)

SYNC_DB_IDENTIFIER=$(call_get_parameter /Prod/DokugakuEngineer/Analytics/SYNC_DB_IDENTIFIER | reject_double_quotation)
SYNC_DB_INSTANCE_IDENTIFIER=$(call_get_parameter /Prod/DokugakuEngineer/Analytics/SYNC_DB_INSTANCE_IDENTIFIER | reject_double_quotation)

# スナップショットからAuroraを復元する クラスターの復元
$aws_comand_path rds --no-cli-pager restore-db-cluster-from-snapshot  \
  --snapshot-identifier $main_snapshot_rds_identifier  \
  --db-cluster-identifier $SYNC_DB_IDENTIFIER  \
  --engine "aurora-mysql" \
  --engine-version "5.7.mysql_aurora.2.08.1"\
  --availability-zone $ANALYTICS_DB_AVAILABILITY_ZONE  \
  --db-subnet-group-name $ANALYTICS_DB_SUBNET_GROUP_NAME  \
  --vpc-security-group-ids $ANYLITICS_DB_VPC_SECURITY_GROUP_ID  \
  > /dev/null 

if [ $? -eq 0 ]; then
    echo "success restore-sync-restore-db-cluster" >> ~/masking_set/masking.log 
fi

# インスタンスの復元
$aws_comand_path rds create-db-instance \
  --db-cluster-identifier $SYNC_DB_IDENTIFIER \
  --db-instance-identifier $SYNC_DB_INSTANCE_IDENTIFIER \
  --db-instance-class db.t3.small \
  --engine "aurora-mysql" \
  --availability-zone $ANALYTICS_DB_AVAILABILITY_ZONE \
  > /dev/null

if [ $? -eq 0 ]; then
    echo "success restore-sync-create-db-instance" >> ~/masking_set/masking.log 
fi

# sync_Auroraが作成するまで待機 
$aws_comand_path rds wait db-instance-available --db-instance-identifier $SYNC_DB_INSTANCE_IDENTIFIER

ANALYTICS_DB_PASSWORD=$(call_get_parameter /Prod/DokugakuEngineer/Analytics/ANALYTICS_DB_PASSWORD  | reject_double_quotation)

$aws_comand_path rds modify-db-cluster \
  --db-cluster-identifier $SYNC_DB_IDENTIFIER \
  --master-user-password $ANALYTICS_DB_PASSWORD \
  --apply-immediately > /dev/null

sleep 1m

if [ $? -eq 0 ]; then
    echo "success modify-db-cluster-passwword" >> ~/masking_set/masking.log 
fi

SYNC_DB_ENDPOINT=$(call_get_parameter /Prod/DokugakuEngineer/Analytics/SYNC_DB_ENDPOINT | reject_double_quotation)
SYNC_DB_USERNAME=$(call_get_parameter /Prod/DokugakuEngineer/Analytics/SYNC_DB_USERNAME | reject_double_quotation)

# sync_AuroraにSQL文を流し込んでデータをマスキング
mysql -h$SYNC_DB_ENDPOINT -u$SYNC_DB_USERNAME -p$ANALYTICS_DB_PASSWORD dokugaku_engineer < ~/masking_set/masking_dayly_query.sql 

if [ $? -eq 0 ]; then
    echo "success masking-query" >> ~/masking_set/masking.log 
fi

set +eu

# BIツールと連携済みのAuroraがあれば削除する（初回構築時は除く）
$aws_comand_path rds describe-db-instances --db-instance-identifier $ANALYTICS_DB_INSTANCE_IDENTIFIER > /dev/null 2>&1

if [ $? -eq 0 ]; then 

  $aws_comand_path rds delete-db-instance \
    --db-instance-identifier $ANALYTICS_DB_INSTANCE_IDENTIFIER \
    --skip-final-snapshot > /dev/null 

  if [ $? -eq 0 ]; then
    echo "success deleted-old-db-instance" >> ~/masking_set/masking.log
  fi

  $aws_comand_path rds wait db-instance-deleted --db-instance-identifier $ANALYTICS_DB_INSTANCE_IDENTIFIER

  $aws_comand_path rds delete-db-cluster \
    --db-cluster-identifier $ANALYTICS_DB_IDENTIFIER \
    --skip-final-snapshot > /dev/null
  
  if [ $? -eq 0 ]; then
    echo "success deleted-old-db-instance" >> ~/masking_set/masking.log
  fi  
  
  sleep 4m

fi

set -eu

sleep 2m

# 日次更新のAuroraインスタンス識別子を変更する

$aws_comand_path rds modify-db-cluster \
    --db-cluster-identifier $SYNC_DB_IDENTIFIER \
    --new-db-cluster-identifier $ANALYTICS_DB_IDENTIFIER \
    --apply-immediately > /dev/null

if [ $? -eq 0 ]; then
    echo "success modify-db-cluster-identifier" >> ~/masking_set/masking.log
fi  
  
sleep 2m

$aws_comand_path rds modify-db-instance \
    --db-instance-identifier $SYNC_DB_INSTANCE_IDENTIFIER \
    --new-db-instance-identifier $ANALYTICS_DB_INSTANCE_IDENTIFIER \
    --apply-immediately > /dev/null

if [ $? -eq 0 ]; then
    echo "Complete Daily Update!!" >> ~/masking_set/masking.log
fi
