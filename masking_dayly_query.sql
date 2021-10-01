
use dokugaku_engineer;

-- usernameのマスキング処理 `new_dummy_id`で記載
update users set username= replace(username, username, concat('masking_dummy_',id));


-- emailのマスキング処理 `new_dummy_email_id`で記載
update users set email= replace(email, left(email,instr(email,'@')- 1), concat('masking_dummy_email_',id));
