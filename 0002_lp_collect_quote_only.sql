ALTER TABLE lp_collect_history
    DROP COLUMN IF EXISTS token_amount,
    DROP COLUMN IF EXISTS c_amount,
    DROP COLUMN IF EXISTS ft_amount,
    DROP COLUMN IF EXISTS ct_amount;
