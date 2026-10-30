
--Index on the table:
SET LINESIZE 200 PAGESIZE 100
COL index_name FORMAT A25
COL column_name FORMAT A15
COL sql_text FORMAT A60

SELECT i.index_name, i.index_type, i.uniqueness, c.column_name, c.column_position
FROM   dba_indexes i JOIN dba_ind_columns c ON c.index_owner = i.owner AND c.index_name = i.index_name
WHERE  i.table_owner = 'LAB' AND i.table_name = 'TRC_ORDERS'
ORDER  BY i.index_name, c.column_position;

--Find the different PHV of SQL_ID from AWR
-- c. AWR history of this statement: which plans it has had and how long each run took
SELECT s.snap_id, TO_CHAR(sn.end_interval_time,'MM-DD HH24:MI') snap_end, s.plan_hash_value phv, s.executions_delta execs,
       ROUND(s.elapsed_time_delta/NULLIF(s.executions_delta,0)/1000,2) ms_per_exec
FROM   dba_hist_sqlstat s JOIN dba_hist_snapshot sn ON sn.snap_id = s.snap_id AND sn.dbid = s.dbid AND sn.instance_number = s.instance_number
WHERE  s.sql_id = '&SQLID' ORDER BY s.snap_id;

--Find the sql_id and plan hash value
SELECT sql_id, child_number, plan_hash_value, executions, sql_text
FROM   v$sql
WHERE  sql_text LIKE '%lab.customers%cust_id%100%'
AND    sql_text NOT LIKE '%v$sql%';

--Show the plan
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR('&sql_id', &child_number, 'TYPICAL'));

SELECT /*+ GATHER_PLAN_STATISTICS */ * FROM lab.customers WHERE cust_id = 100;
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ALLSTATS LAST'));

--Alternatives
EXPLAIN PLAN FOR SELECT * FROM lab.customers WHERE cust_id = 100;
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);      -- the plan Oracle expects to use, the statement is not run

SET AUTOTRACE TRACEONLY EXPLAIN STATISTICS
SELECT * FROM lab.customers WHERE cust_id = 100;
SET AUTOTRACE OFF

--Lenght of SQL text
SELECT sql_id, parsing_schema_name, LENGTH(sql_text) len, sql_text
FROM   v$sql
WHERE  sql_id IN ('f3f76dabrqbwx','cwtumbxttr8uz');
--Child cursor
SELECT sql_id, child_number, plan_hash_value, optimizer_mode, executions FROM v$sql WHERE sql_id = '&sql_id';
SELECT child_number, optimizer_mode_mismatch FROM v$sql_shared_cursor WHERE sql_id = '&sql_id';

select * from table(DBMS_XPLAN.DISPLAY_AWR(sql_id => '65srpxvr09aju',format => 'TYPICAL +COST +BYTES -PROJECTION +OUTLINE'));

explain below, and how/when to use this
SQLHC
SQLRPT
SQL monitor report
Global index
Local Index
Row Id
Cluster wait