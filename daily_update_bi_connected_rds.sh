#!/bin/bash -l

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
  $aws_comand_path rds describe-db-cluster-snapshots --query "reverse(sort_by(DBClusterSnapshots[?DBClusterIdentifier==$1],&SnapshotCreateTime))[0].DBClusterSnapshotIdentifier"
}

# 各パラメータを変数に代入
ANALYTICS_RDS_IDENTIFIER=$(call_get_parameter /Prod/DokugakuEngineer/Analytics/ANALYTICS_RDS_IDENTIFIER | reject_double_quotation)
ANALYTICS_DB_AVAILABILITY_ZONE=$(call_get_parameter /Prod/DokugakuEngineer/Analytics/ANALYTICS_DB_AVAILABILITY_ZONE | reject_double_quotation)
ANALYTICS_DB_SUBNET_GROUP_NAME=$(call_get_parameter /Prod/DokugakuEngineer/Analytics/ANALYTICS_DB_SUBNET_GROUP_NAME | reject_double_quotation)
ANYLITICS_DB_VPC_SECURITY_GROUP_ID=$(call_get_parameter /Prod/DokugakuEngineer/Analytics/ANYLITICS_DB_VPC_SECURITY_GROUP_ID | reject_double_quotation)
ANALYTICS_DB_PARAMETER_GROUP_NAME=$(call_get_parameter /Prod/DokugakuEngineer/Analytics/ANALYTICS_DB_PARAMETER_GROUP_NAME | reject_double_quotation)

# マスキングRDSがあれば削除する（初回構築時は除く）
$aws_comand_path rds describe-db-instances --db-instance-identifier $ANALYTICS_RDS_IDENTIFIER > /dev/null

if [ $? -eq 0 ]; then 
  $aws_comand_path rds delete-db-instance \
    --db-instance-identifier $ALYTICS_RDS_IDENTIFIER \
    --skip-final-snapshot \
    > /dev/null 2>&1

  if [ $? -eq 0 ]; then
    echo "success_delete_old_maskingRDS" >> ~/masking_set/masking.log 2>&1
  else
    echo "error_delete_old_maskingRDS" >> ~/masking_set/masking.log 2>&1
  fi

  $aws_comand_path rds wait db-instance-deleted --db-instance-identifier $ALYTICS_RDS_IDENTIFIER
fi

# 本番RDSからスナップショットを取る
DB_IDENTIFIER=$(call_get_parameter /Prod/DokugakuEngineer/Analytics/DB_IDENTIFIER | change_double_to_single_quotation)

main_snapshot_rds_identifier=$(get_latest_snapshot_rds_identifier $DB_IDENTIFIER)
main_snapshot_rds_identifier=$(echo $main_snapshot_rds_identifier | reject_double_quotation)

SYNC_DB_IDENTIFIER=$(call_get_parameter /Prod/DokugakuEngineer/Analytics/SYNC_DB_IDENTIFIER | reject_double_quotation)

# スナップショットからRDSを復元する
$aws_comand_path rds --no-cli-pager restore-db-instance-from-db-snapshot  \
  --db-snapshot-identifier $main_snapshot_rds_identifier  \
  --db-instance-identifier $SYNC_DB_IDENTIFIER  \
  --availability-zone $ANALYTICS_DB_AVAILABILITY_ZONE  \
  --db-subnet-group-name $ANALYTICS_DB_SUBNET_GROUP_NAME  \
  --vpc-security-group-ids $ANYLITICS_DB_VPC_SECURITY_GROUP_ID  \
  --db-parameter-group-name $ANALYTICS_DB_PARAMETER_GROUP_NAME \
  --db-instance-class db.t3.micro  \
  --no-multi-az \
  > /dev/null 

if [ $? -eq 0 ]; then
    echo "success_snapshot_restore_maskingRDS" >> ~/masking_set/masking.log 2>&1
else
    echo "error_snapshot_restore_maskingRDS" >> ~/masking_set/masking.log 2>&1
fi

# RDSが作成するまで待機 
$aws_comand_path rds wait db-instance-available --db-instance-identifier $SYNC_DB_IDENTIFIER

ANALYTICS_DB_PASSWORD=$(call_get_parameter /Prod/DokugakuEngineer/Analytics/ANALYTICS_DB_PASSWORD | reject_double_quotation)

$aws_comand_path rds modify-db-instance \
    --db-instance-identifier $SYNC_DB_IDENTIFIER \
    --master-user-password $ANALYTICS_DB_PASSWORD > /dev/null 

if [ $? -eq 0 ]; then
    echo "success_change_restore_maskingRDS_identifire_passwword" >> ~/masking_set/masking.log 2>&1
else
    echo "error_change_restore_maskingRDS_identifire_passwword" >> ~/masking_set/masking.log 2>&1
fi

sleep 1m

SYNC_DB_ENDPOINT=$(call_get_parameter /Prod/DokugakuEngineer/Analytics/SYNC_DB_ENDPOINT | reject_double_quotation)

# 復元RDSにSQL文を流し込んでデータをマスキング
mysql -h$SYNC_DB_ENDPOINT -uroot -p$ANALYTICS_DB_PASSWORD dokugaku_engineer < ~/masking_set/masking_dayly_query.sql 

if [ $? -eq 0 ]; then
    echo "success_masking_query" >> ~/masking_set/masking.log 2>&1
else
    echo "error_masking_query" >> ~/masking_set/masking.log 2>&1
fi

# マスキングRDSのDBインスタンス識別子を変更する
$aws_comand_path rds modify-db-instance \
    --db-instance-identifier $SYNC_DB_IDENTIFIER \
    --new-db-instance-identifier $ALYTICS_RDS_IDENTIFIER \
    --apply-immediately > /dev/null

if [ $? -eq 0 ]; then
    echo "Success_change_maskingRDS_identifier" >> ~/masking_set/masking.log 2>&1
else
    echo "Error_change_maskingRDS_identifier" >> ~/masking_set/masking.log 2>&1
fi
