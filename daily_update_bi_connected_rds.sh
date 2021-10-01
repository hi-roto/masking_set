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
  $aws_comand_path rds describe-db-snapshots \
  --query "reverse(sort_by(DBSnapshots[?DBInstanceIdentifier==$1],&SnapshotCreateTime))[0].DBSnapshotIdentifier"
}


# 各パラメータを変数に代入
BI_CONNECTED_RDS_IDENTIFIER=$(call_get_parameter BI_CONNECTED_RDS_IDENTIFIER | reject_double_quotation)
SNAPSHOT_AVAILABILITY_ZONE=$(call_get_parameter SNAPSHOT_AVAILABILITY_ZONE | reject_double_quotation)
SNAPSHOT_DB_SUBNET_GROUP_NAME=$(call_get_parameter SNAPSHOT_DB_SUBNET_GROUP_NAME | reject_double_quotation)
SNAPSHOT_VPC_SECURITY_GROUP_ID=$(call_get_parameter SNAPSHOT_VPC_SECURITY_GROUP_ID | reject_double_quotation)
SNAPSHOT_DB_PARAMETER_GROUP_NAME=$(call_get_parameter SNAPSHOT_DB_PARAMETER_GROUP_NAME | reject_double_quotation)

# マスキングRDSがあれば削除する（初回構築時は除く）
$aws_comand_path rds describe-db-instances --db-instance-identifier $BI_CONNECTED_RDS_IDENTIFIER > /dev/null 2>&1

if [ $? -eq 0 ]; then 
  $aws_comand_path rds delete-db-instance \
    --db-instance-identifier $BI_CONNECTED_RDS_IDENTIFIER \
    --skip-final-snapshot \
    > /dev/null 2>&1

  $aws_comand_path rds wait db-instance-deleted --db-instance-identifier $BI_CONNECTED_RDS_IDENTIFIER
fi

# 本番RDSからスナップショットを取る
MAIN_CONNECTED_RDS_IDENTIFIER=$(call_get_parameter MAIN_CONNECTED_RDS_IDENTIFIER | change_double_to_single_quotation)

main_snapshot_rds_identifier=$(get_latest_snapshot_rds_identifier $MAIN_CONNECTED_RDS_IDENTIFIER)
main_snapshot_rds_identifier=$(echo $main_snapshot_rds_identifier | reject_double_quotation)

MASKING_RDS_IDENTIFIER=$(call_get_parameter MASKING_RDS_IDENTIFIER | reject_double_quotation)

# スナップショットからRDSを復元する
$aws_comand_path rds --no-cli-pager restore-db-instance-from-db-snapshot  \
  --db-snapshot-identifier $main_snapshot_rds_identifier  \
  --db-instance-identifier $MASKING_RDS_IDENTIFIER  \
  --availability-zone $SNAPSHOT_AVAILABILITY_ZONE  \
  --db-subnet-group-name $SNAPSHOT_DB_SUBNET_GROUP_NAME  \
  --vpc-security-group-ids $SNAPSHOT_VPC_SECURITY_GROUP_ID  \
  --db-parameter-group-name $SNAPSHOT_DB_PARAMETER_GROUP_NAME \
  --db-instance-class db.t3.micro  \
  --no-multi-az \
  > /dev/null 2>&1

# RDSが作成するまで待機 
$aws_comand_path rds wait db-instance-available --db-instance-identifier $MASKING_RDS_IDENTIFIER

MASKING_RDS_CONNECT_PASSWORD=$(call_get_parameter MASKING_RDS_CONNECT_PASSWORD | reject_double_quotation)

$aws_comand_path rds modify-db-instance \
    --db-instance-identifier $MASKING_RDS_IDENTIFIER \
    --master-user-password $MASKING_RDS_CONNECT_PASSWORD > /dev/null 2>&1

sleep 1m

SNAPSHOT_RDS_ENDPOINT=$(call_get_parameter SNAPSHOT_RDS_ENDPOINT | reject_double_quotation)

# 復元RDSにSQL文を流し込んでデータをマスキング
mysql -h$SNAPSHOT_RDS_ENDPOINT -uroot -p$MASKING_RDS_CONNECT_PASSWORD dokugaku_engineer < ~/masking_set/masking_dayly_query.sql 

# マスキングRDSのDBインスタンス識別子を変更する
$aws_comand_path rds modify-db-instance \
    --db-instance-identifier $MASKING_RDS_IDENTIFIER \
    --new-db-instance-identifier $BI_CONNECTED_RDS_IDENTIFIER \
    --apply-immediately > /dev/null 2>&1