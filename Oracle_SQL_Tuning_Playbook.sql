# Oracle SQL Tuning Playbook (RAC-ready)

For: you **know which SQL** is the problem and need to understand or control its execution plan: a plan that changed ("fast yesterday, slow today"),
a plan you cannot fix by changing the application, or a statement you need to watch while it runs.
Companions: `Oracle_Wait_Event_Playbook.sql` (live waits), `Oracle_ORA_Error_Playbook.sql` (errors and logs), `Oracle_Historical_Analysis_Playbook.sql` (past problems: AWR, ASH, ADDM),
`00_Playbook_Index.md` (which file to open).
Conventions: queries are read-only unless marked ACTION. `gv$` and `inst_id` for RAC. Tested on Oracle AI Database 26ai Free in the Colima/Docker lab; entries marked "(not reproduced)" come from Oracle documentation.

---

## 1. Which tool for which situation? (decision guide)

| Situation | Tool | Why | Changes the application? |
|---|---|---|---|
| A plan **regressed** and you have (or can get) the good plan; you want to **lock the plan** and stop future flips | **SQL plan baseline (SPM)** | Oracle only uses accepted plans; new plans are held back until verified | No |
| The optimizer **misestimates** (wrong cardinality, correlated columns), you cannot edit the SQL, and want better estimates | **SQL profile** (from the SQL Tuning Advisor), section 3 | stores correction hints/statistics for this statement | No |
| You **can edit** the SQL (or a developer can) and know the right access path | **Hint** in the SQL text, section 4 | simplest and most direct; verify with the Hint Report | Yes |
| You cannot edit the SQL but need a hint | **SQL patch** (`DBMS_SQLDIAG`), section 4.4 | attaches hints to a statement; qualify aliases (`o@sel$1`) and check the Hint Report | No |
| The statistics are simply wrong | **Fix the statistics** first (`DBMS_STATS`, unlock, extended stats; section 3.3) | the root cause; the tools above only compensate | No |
| One **long-running execution** ("is it stuck, which step, when will it finish?") | **SQL Monitor report**, section 5 | plan with actual rows, executions and time per step, live | No |

Rule of thumb: fix the cause (statistics, missing index, SQL) when you can; use a baseline when you need **stability**, a profile when the optimizer **estimates badly**, a hint when you **own the SQL**.

## 2. SQL plan baseline (SQL Plan Management, SPM)  (lab 10, tested on 26ai Free)

### 2.1 What it is: three phases
```
1. CAPTURE  plans get into the baseline (manual load, or automatic capture of repeated statements)
2. SELECT   at every hard parse only ACCEPTED plans may be used; a new plan the optimizer comes up with is stored as NOT accepted and held back
3. EVOLVE   test a held-back plan with real binds; promote it to ACCEPTED only if it is clearly better (otherwise a baseline would freeze a statement forever)
```
Columns of `dba_sql_plan_baselines`: `ENABLED` (eligible), `ACCEPTED` (verified, may be used), `FIXED` (preferred over non-fixed), `REPRODUCED` (Oracle can rebuild it; NO = ignored), `ORIGIN` (MANUAL-LOAD-FROM-STS / -FROM-CURSOR-CACHE / AUTO-CAPTURE).
Use a baseline when: a plan regressed and you want stability for this one statement, statistics are locked or under change control, or you cannot change the SQL. It does NOT repair the cause (wrong statistics stay wrong; other statements stay exposed).

### 2.2 Case: plan regression after a statistics change (lab 10)
Symptom: sessions ON CPU plus `direct path read` (a full scan), one statement 99.8% of DB time. Ticket said "was 10 ms, now slow, the stats job ran".
1. Wait summary (Oracle_Wait_Event_Playbook.sql 2.1), then ASH top SQL with `sql_plan_hash_value` (3.1).
2. Cost per run (3.3): 48,137 gets and 48,123 physical reads per execution = the whole table (48,400 blocks) for 1 returned row; plan `TABLE ACCESS FULL` with the 15-day range as a `filter`; estimated rows (63,995) were right, so not a cardinality problem.
3. Why the full scan? Index statistics and history:
```sql
SELECT i.index_name, i.clustering_factor, t.blocks table_blocks, t.num_rows table_rows, TO_CHAR(i.last_analyzed,'MM-DD HH24:MI') idx_analyzed
FROM   dba_indexes i JOIN dba_tables t ON t.owner = i.table_owner AND t.table_name = i.table_name WHERE i.table_owner = '&owner' AND i.table_name = '&table';
SELECT operation, target, TO_CHAR(start_time,'MM-DD HH24:MI:SS') started FROM dba_optstat_operations WHERE start_time > SYSTIMESTAMP - INTERVAL '1' DAY ORDER BY start_time DESC FETCH FIRST 10 ROWS ONLY;
SELECT stattype_locked FROM dba_tab_statistics WHERE owner = '&owner' AND table_name = '&table' AND partition_name IS NULL;
-- plan history of the statement in AWR (is there an older plan, how fast was it?)
SELECT s.snap_id, TO_CHAR(sn.end_interval_time,'MM-DD HH24:MI') snap_end, s.plan_hash_value phv, s.executions_delta execs, ROUND(s.elapsed_time_delta/NULLIF(s.executions_delta,0)/1000,2) ms_per_exec
FROM   dba_hist_sqlstat s JOIN dba_hist_snapshot sn ON sn.snap_id = s.snap_id AND sn.dbid = s.dbid AND sn.instance_number = s.instance_number WHERE s.sql_id = '&sql_id' ORDER BY s.snap_id;
```
Findings: clustering factor = number of rows (3,000,000, impossible for data loaded in date order; the primary key index had 53,464, near the 48,400 blocks); `set_index_stats` entries (statistics set by hand), table statistics locked (`ALL`); AWR showed two plans: the index plan at 12 ms and the full scan at 189 ms. Note: `gather_database_stats (auto)` also ran, and the damage came after it. Logs can tell a different story than the ticket.

### 2.3 Fix A: baseline from the old plan in AWR (tested)
```sql
-- 0. pre-checks: the old plan is in AWR, and the DBID its rows are stored under (in a CDB use the dbid stored in dba_hist_sqlstat, not the PDB's)
SELECT plan_hash_value, COUNT(*) plan_lines FROM dba_hist_sql_plan WHERE sql_id = '&sql_id' GROUP BY plan_hash_value;
SELECT DISTINCT dbid, plan_hash_value FROM dba_hist_sqlstat WHERE sql_id = '&sql_id';
-- lookup that gives the values for the &variables below: one row per plan the statement has had, fastest first (pick the good plan's row)
SELECT sql_id, plan_hash_value good_plan_hash, MIN(snap_id) - 1 begin_snap, MAX(snap_id) end_snap, MAX(dbid) dbid, SUM(executions_delta) execs,
       ROUND(SUM(elapsed_time_delta)/NULLIF(SUM(executions_delta),0)/1000,2) ms_per_exec
FROM   dba_hist_sqlstat WHERE sql_id = '&sql_id' GROUP BY sql_id, plan_hash_value ORDER BY ms_per_exec;
-- Two actions: (1) put the old plan from AWR into a SQL tuning set (a container the baseline loader can read), (2) load it from the set into the baseline.
-- 1. SQL tuning set from AWR with only the good plan. begin_snap must be EARLIER than the first snapshot that contains the statement
EXEC DBMS_SQLTUNE.CREATE_SQLSET(sqlset_name => 'STS_PLAN_FIX', description => 'good plan from AWR');
DECLARE c DBMS_SQLTUNE.SQLSET_CURSOR; BEGIN
  OPEN c FOR SELECT VALUE(p) FROM TABLE(DBMS_SQLTUNE.SELECT_WORKLOAD_REPOSITORY(begin_snap => &begin_snap, end_snap => &end_snap,
             basic_filter => 'sql_id = ''&sql_id'' AND plan_hash_value = &good_plan_hash', attribute_list => 'ALL', dbid => &dbid)) p;
  DBMS_SQLTUNE.LOAD_SQLSET('STS_PLAN_FIX', c); CLOSE c;
END;
/
SELECT sql_id, plan_hash_value, executions FROM dba_sqlset_statements WHERE sqlset_name = 'STS_PLAN_FIX';      -- must list the statement
-- 2. load it as a baseline
SET SERVEROUTPUT ON
DECLARE n PLS_INTEGER; BEGIN
  n := DBMS_SPM.LOAD_PLANS_FROM_SQLSET(sqlset_name => 'STS_PLAN_FIX', basic_filter => 'sql_id = ''&sql_id'' AND plan_hash_value = &good_plan_hash');
  DBMS_OUTPUT.PUT_LINE('plans loaded: '||n);
END;
/
SELECT sql_handle, plan_name, enabled, accepted, fixed, reproduced, origin FROM dba_sql_plan_baselines;          -- want ENABLED YES, ACCEPTED YES, REPRODUCED YES
-- 3. a baseline is used at the NEXT hard parse: purge only that cursor (RAC: on each instance that has it), not the whole shared pool
BEGIN FOR r IN (SELECT address, hash_value FROM v$sqlarea WHERE sql_id = '&sql_id') LOOP SYS.DBMS_SHARED_POOL.PURGE(r.address || ',' || r.hash_value, 'C'); END LOOP; END;
/
-- 4. verify: plan hash is the good one and the baseline name appears in sql_plan_baseline
SELECT inst_id, child_number, plan_hash_value, executions, ROUND(elapsed_time/NULLIF(executions,0)/1000,2) ms_per_exec, sql_plan_baseline FROM gv$sql WHERE sql_id = '&sql_id';
```
Result in the lab: 33 -> about 425 to 486 executions/s, 190 ms -> 13 ms per run, with the wrong index statistics still in place and locked.
Gotchas: (1) `SELECT_WORKLOAD_REPOSITORY` returned nothing with the PDB's dbid or with begin_snap equal to the first snapshot; use the dbid stored in the AWR rows and an earlier begin_snap. (2) A baseline does not change an already cached cursor until a hard parse (purge it). (3) Baselines are stored in the database (SYSAUX, shared by all RAC instances), but cursors and the purge are per instance.

### 2.4 Fix B: when the old plan is not in AWR: produce it and transplant it (tested)
Run a copy of the statement with a hint that forces the good plan, then load that plan as the baseline of the ORIGINAL statement text.
```sql
-- the hinted copy must use the SAME table reference as the original (no alias if the original has none), otherwise REPRODUCED = NO
DECLARE c NUMBER; s NUMBER; d DATE := DATE '2025-03-01'; BEGIN
  SELECT /*+ INDEX(plan_orders ix_plan_date) */ COUNT(*), SUM(amount) INTO c, s FROM lab.plan_orders WHERE order_date >= d AND order_date < d + 15;
END;
/
DECLARE n PLS_INTEGER; l_id VARCHAR2(20); l_phv NUMBER; BEGIN
  SELECT sql_id, plan_hash_value INTO l_id, l_phv FROM v$sql WHERE sql_text LIKE '%INDEX(plan_orders ix_plan_date)%' AND sql_text NOT LIKE '%v$sql%' AND sql_text NOT LIKE 'DECLARE%' AND ROWNUM = 1;
  n := DBMS_SPM.LOAD_PLANS_FROM_CURSOR_CACHE(sql_id => l_id, plan_hash_value => l_phv, sql_text => '<exact text of the ORIGINAL statement>');
END;
/
```
Trap found in the lab: my first copy used the alias `o` (`FROM lab.plan_orders o`, `INDEX(o ...)`); the baseline loaded but showed `REPRODUCED = NO` and was ignored, because the stored hints referred to alias O, which the original statement does not have. Rebuilt without the alias: `REPRODUCED = YES`. Always check `REPRODUCED` after loading.

### 2.5 Evolve: promote a held-back plan only if it is proven better
SPM stores the optimizer's own new plan as `ACCEPTED = NO` (origin AUTO-CAPTURE) and keeps using the accepted one. To decide whether the new plan may ever be used:
```sql
-- call from PL/SQL, NOT from a SELECT (ORA-14552). commit => 'NO' only reports; 'YES' accepts the plan if it is better. verify => 'NO' accepts WITHOUT testing (risky)
SET LINESIZE 200 PAGESIZE 0 SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
DECLARE r CLOB; pos PLS_INTEGER := 1; len PLS_INTEGER; BEGIN
  r := DBMS_SPM.EVOLVE_SQL_PLAN_BASELINE(sql_handle => '&sql_handle', verify => 'YES', commit => 'NO');
  len := DBMS_LOB.GETLENGTH(r);
  WHILE pos <= len LOOP DBMS_OUTPUT.PUT_LINE(DBMS_LOB.SUBSTR(r, 200, pos)); pos := pos + 200; END LOOP;
END;
/
```
Read "Execution Statistics": base plan against test plan (elapsed, buffer gets, cost) and the number of recommendations. Lab: base 0.009 s / 1,130 gets, test 0.141 s / 48,108 gets, 0 recommendations; the optimizer's cost said the opposite (64,183 vs 13,143) because of the bad statistic. Evolve measures reality.
Ways: the function above; the task API (`CREATE_EVOLVE_TASK`, `EXECUTE_EVOLVE_TASK`, `REPORT_EVOLVE_TASK`, `IMPLEMENT_EVOLVE_TASK`, not run in the lab); the automatic nightly task controlled by `AUTO_SPM_EVOLVE_TASK` (OFF in the lab; check edition and licence).
```sql
SELECT parameter_name, parameter_value FROM dba_sql_management_config ORDER BY 1;                               -- AUTO_SPM_EVOLVE_TASK, retention, space budget
SELECT sql_handle, plan_name, origin, created FROM dba_sql_plan_baselines WHERE accepted = 'NO' ORDER BY created;  -- plans waiting for evolve
```

### 2.6 Maintenance (syntax from the documentation; the user ran these in the lab, I did not capture the output)
```sql
SET SERVEROUTPUT ON
DECLARE n PLS_INTEGER; BEGIN   -- FIXED: prefer this plan over every non-fixed one; ENABLED: switch a plan off without deleting it
  n := DBMS_SPM.ALTER_SQL_PLAN_BASELINE(sql_handle => '&h', plan_name => '&p', attribute_name => 'FIXED', attribute_value => 'YES');
END;
/
DECLARE n PLS_INTEGER; BEGIN n := DBMS_SPM.DROP_SQL_PLAN_BASELINE(sql_handle => '&h'); DBMS_OUTPUT.PUT_LINE('plans dropped: '||n); END;   -- rollback of everything
/
```
After dropping, purge the cursor if you want an immediate re-parse. Settings: `optimizer_use_sql_plan_baselines` (TRUE = baselines are used), `optimizer_capture_sql_plan_baselines` (FALSE = no automatic capture of repeated statements; turn on only for chosen workloads).

### 2.7 Decision and prevention
- Correct statistics = fixes the cause for all statements (needs approval, may change other plans); baseline = protects one statement and gives stability. Often do both: baseline now, statistics fix later.
- Prevent: load baselines for critical statements while the plan is good (from the cursor cache or an AWR/STS), before upgrades, patches, big stats changes; keep AWR retention long enough to find old plans; lock statistics only with a documented reason; review `accepted = 'NO'` plans regularly.
- Statistics jobs both break and heal plans: the automatic job re-gathered statistics in the middle of the lab and silently fixed my simulated problem. If you lock statistics to hold a bad state, note it.

## 3. SQL profile  (lab 11, tested on 26ai Free)

What it is: a stored set of **corrections to the optimizer's row estimates** for one statement. It does not store a plan (that is a baseline). The optimizer still chooses the plan, now with better numbers.
Use it when: the plan is bad because an **estimate is wrong**, the SQL cannot be edited (vendor code), and you don't know the cause yet.
Licence: SQL Tuning Advisor and SQL profiles need the Tuning Pack (plus Diagnostics Pack). Check before using on production.

### 3.1 Case: vendor report is CPU-bound, nothing changed (lab 11)
Ticket: "the segment report shipped last week is slow and uses a lot of CPU; we cannot edit the SQL".
Tables: LAB.PROF_CUST (200,000 rows, SEG/TIER/GRP always equal = correlated), LAB.PROF_ORDERS (2,000,000 rows, index on CUST_ID).

Step 1: what are sessions doing (all RAC nodes). Lab result: 6 of 6 sessions ON CPU; ASH: one sql_id, one plan, ~97% ON CPU, only tiny read waits (data cached).
  Meaning: pure work on cached blocks = too many logical reads (e.g. repeated index probes), not I/O.

Step 2: cost per execution and the plan (RAC)
  SELECT inst_id, sql_id, plan_hash_value phv, executions execs,
         ROUND(elapsed_time/NULLIF(executions,0)/1e6,5) ela_per_exec_s, ROUND(cpu_time/NULLIF(executions,0)/1e6,5) cpu_per_exec_s,
         ROUND(buffer_gets/NULLIF(executions,0)) gets_per_exec, ROUND(rows_processed/NULLIF(executions,0),1) rows_per_exec
  FROM   gv$sqlstats WHERE sql_id = '&sql_id' ORDER BY inst_id;
  SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR('&sql_id', NULL, 'TYPICAL'));
  Lab: 242,818 gets and 0.39 s to return 1 row.
  Then run a copy with /*+ GATHER_PLAN_STATISTICS */ and DISPLAY_CURSOR(NULL,NULL,'ALLSTATS LAST'):
  find the FIRST step where E-Rows and A-Rows are far apart. Lab: PROF_CUST E-Rows 200 vs A-Rows 20,000 (100x), so the index on PROF_ORDERS was probed 20,000 times (Starts) and 200K rows fetched one by one.
  Rule: a wrong first row count poisons every step that depends on it (join method, join order).

Step 3: why is the estimate wrong (dba_ views, same on every node, no gv$ needed)
  SELECT t.num_rows, c.column_name, c.num_distinct, c.histogram FROM dba_tables t JOIN dba_tab_col_statistics c
         ON c.owner = t.owner AND c.table_name = t.table_name
  WHERE  t.owner = '&owner' AND t.table_name = '&table' AND c.column_name IN (&cols);
  Compare the real counts with COUNT(*) filtering 1, 2, then all columns; check dba_stat_extensions.
  Lab: 200,000 x 1/10 x 1/10 x 1/10 = 200 (independence assumption); real 20,000, only 10 distinct (seg,tier,grp) combinations. Columns are correlated.

### 3.2 Fix A: SQL Tuning Advisor + SQL profile (tested)
  DECLARE t VARCHAR2(64); BEGIN
    t := DBMS_SQLTUNE.CREATE_TUNING_TASK(sql_id => '&sql_id', task_name => 'TUNE_PROF', time_limit => 120);
    DBMS_SQLTUNE.EXECUTE_TUNING_TASK(task_name => 'TUNE_PROF'); END; /
  SET LONG 100000 LONGCHUNKSIZE 100000 PAGESIZE 0 LINESIZE 250
  SELECT DBMS_SQLTUNE.REPORT_TUNING_TASK('TUNE_PROF') FROM dual;
  The cursor must be in the shared pool of the instance where the task runs (on RAC use the node with the heaviest cursor).
  Reading the report: Findings (SQL Profile / Statistics / Index / Restructure), Validation table (it really ran both plans: buffer gets, elapsed), and "Original With Adjusted Cost" = the original plan with corrected estimates (lab: 18,559 rows, cost 223K vs 4,994 for the hash join, so the optimizer now prefers the hash join).
  Lab: 244,061 -> 18,183 gets, 0.60 -> 0.076 s (-92.54% gets).
  Accept (accepting invalidates the cursor, no purge needed):
  EXEC DBMS_SQLTUNE.ACCEPT_SQL_PROFILE(task_name => 'TUNE_PROF', task_owner => 'SYS', replace => TRUE);
  SELECT name, category, status, type, force_matching, created FROM dba_sql_profiles;
  Verify (RAC): new child with new plan hash and the profile name in sql_profile:
  SELECT inst_id, child_number, plan_hash_value, executions, ROUND(elapsed_time/NULLIF(executions,0)/1e3,1) ela_ms, ROUND(buffer_gets/NULLIF(executions,0)) gets, sql_profile
  FROM   gv$sql WHERE sql_id = '&sql_id' ORDER BY inst_id, child_number;
  Lab result: plan 1912197898 -> 3981533769; ~390 ms -> 126 ms; ~243K -> ~17.9K gets; 17 -> 48 exec/s.
  Remove: EXEC DBMS_SQLTUNE.DROP_SQL_PROFILE(name => '&profile'); (ALTER_SQL_PROFILE with status DISABLED to switch off without deleting).
  Elapsed fell less than gets (hash join scans all 2M rows): "better", not necessarily "best".

### 3.3 Fix B: fix the root cause with extended statistics (tested)
  Fixes every query on those columns, not just one statement.
  SELECT DBMS_STATS.CREATE_EXTENDED_STATS('&owner', '&table', '(SEG,TIER,GRP)') FROM dual;
  EXEC DBMS_STATS.GATHER_TABLE_STATS('&owner', '&table', method_opt => 'FOR ALL COLUMNS SIZE 1', no_invalidate => FALSE);
  Traps: if the member columns have histograms and the group has none, the group is ignored (estimate stays 200): gather with SIZE 1 (or let the group get a histogram too). no_invalidate => FALSE re-parses at once.
  Lab result: PROF_CUST estimate 20,000, plan 3981533769, 121 ms, 18,051 gets, sql_profile empty.
  Drop: DBMS_STATS.DROP_EXTENDED_STATS(owner, table, extension => '(SEG,TIER,GRP)') (needs the column list, not the SYS_STU... name).

### 3.4 Profile vs extended stats vs baseline
  Extended stats : cause known (correlated columns, expression), want it fixed for all queries; needs access to stats, not the SQL.
  SQL profile    : cause unknown or varied, SQL cannot change, one statement; needs Tuning Pack.
  Baseline       : you know which plan is good and need it frozen regardless of estimates (section 2).
  Always try to find the cause (section 3.1 step 3) before accepting a profile: a profile hides the symptom, it can go stale if data skew changes.

### 3.5 Lab notes
  optimizer_adaptive_plans was set FALSE (SCOPE=MEMORY) in the PDB for this lab, because adaptive plans switched nested loops to hash join at run time and hid the problem. Revert: ALTER SYSTEM SET optimizer_adaptive_plans = TRUE SCOPE=MEMORY;
  Scripts: lab/11_profile_lab.sh setup | start | stop | reset.

### 3.6 Literals: force_match (tested, lab 11)
  Without bind variables every literal is a different sql_id (WHERE seg = 1, seg = 2, seg = 3 gave three sql_ids). A profile is matched by the normalised text signature:
    force_match => FALSE (default): matches only the exact text, so one profile helps one literal value only.
    force_match => TRUE            : literals are replaced by placeholders before matching, so one profile covers all literal values (binds are already covered either way).
  EXEC DBMS_SQLTUNE.ACCEPT_SQL_PROFILE(task_name => 'T', task_owner => 'SYS', name => 'PROF_X', force_match => TRUE, replace => TRUE);
  Check: dba_sql_profiles.force_matching = YES/NO.
  Lab: profile accepted with FALSE on the seg=1 text: only that sql_id showed the profile name. Re-accepted with TRUE: seg=3, never run before, picked up the profile on its first execution (sql_profile = PROF_LIT_FORCE, plan 3981533769).
  Observation (do not over-read): in the FALSE run the seg=2 statement also moved to the hash join but with no profile name; I did not isolate why (probably automatic re-optimisation); judge by the sql_profile column, not by the plan alone.
  Dropping a profile does not purge cursors already in the shared pool; they keep the profile plan until invalidated or aged out.
  force_match is only a workaround; the real fix for literal-heavy code is binds (or cursor_sharing as in the parse storm case, wait-event playbook 8.3).

### 3.7 What a profile really contains, and how it ages
  The hints stored in a profile (from sys.sqlobj$data, tested):
    OPT_ESTIMATE(@"SEL$58A6D7F6", TABLE, "C"@"SEL$1", SCALE_ROWS=92.80215)
    OPTIMIZER_FEATURES_ENABLE(default)
  So it is one MULTIPLIER: "the rows of table C (PROF_CUST) after its filters are 92.8 times what you computed". 200 x 92.8 = 18,559, the figure in the advisor report. No plan is stored.
  Consequences (reasoning from this, not separately tested):
   - Table grows with the same correlation: the base estimate grows too, the multiplier stays right, the profile keeps working.
   - Correlation or skew changes (columns stop moving together, new values): 92.8 stays fixed and becomes wrong. The profile can then hurt, and nothing warns you.
   - Index added, stats gathered, upgrade: the optimizer still uses the multiplier, but may choose another plan with it (that is intended).
  Review: list profiles regularly (SELECT name, created, status, force_matching FROM dba_sql_profiles ORDER BY created) and re-run the tuning advisor on the statement; if it recommends nothing or a different factor, drop the profile. Better: fix the cause (3.3) and remove the profile.
  Remember a profile follows the SQL text, not the object: it is not exported with the schema unless you pack it (DBMS_SQLTUNE.CREATE_STGTAB_SQLPROF / PACK_STGTAB_SQLPROF / UNPACK_STGTAB_SQLPROF) to move it between databases.

## 4. SQL hints and SQL patch  (lab 12, tested on 26ai Free)

A hint is an instruction written as a comment right after SELECT: /*+ USE_HASH(o) */. The optimizer follows it IF it can; an invalid hint is ignored SILENTLY (no error). A hint written in the SQL text changes the text, so it is a new sql_id and needs a code change.
Without changing code, the same hints can be delivered from outside: SQL patch (hints you write), SQL profile (hints the advisor writes, section 3), baseline (a frozen plan, section 2).

### 4.1 Case: our own report is slow (lab 12)
Same data as lab 11 (LAB.PROF_CUST / LAB.PROF_ORDERS, correlated SEG/TIER/GRP), statement sql_id 8smz4qxjbx9th, module CUSTOMER_REPORT. ASH: 100% ON CPU, one plan 2433189415 (nested loops), ~231K-241K gets and 260-336 ms per run, E-Rows 200 vs A-Rows 20,000, inner index probed 20,000 times.
Gotcha (my Step 1 query was wrong at first): gv$session.event keeps the LAST wait after the session goes back on CPU. Always test state:
  CASE WHEN state = 'WAITING' THEN event ELSE 'ON CPU' END
Gotcha: /*+ GATHER_PLAN_STATISTICS */ can change the plan you are diagnosing. The second run of the copy showed child number 1, E-Rows 20000, "Note: statistics feedback used" (hash join), while child 0 was still the bad nested loops plan (v$sql.is_reoptimizable = Y). The application cursor (no row-source statistics) stayed N and never learned. Always read child number and Note; test on a text not run before, or read child 0:
  SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR('&sql_id', 0, 'ALLSTATS LAST'));

### 4.2 Test hints on a copy and read the Hint Report
  SELECT /*+ GATHER_PLAN_STATISTICS USE_HASH(o) */ c.seg, COUNT(*), SUM(o.amount) FROM lab.prof_cust c JOIN lab.prof_orders o ON o.cust_id = c.cust_id WHERE c.seg = 7 AND c.tier = 7 AND c.grp = 7 GROUP BY c.seg;
  SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ALLSTATS LAST +HINT_REPORT'));
  ALLSTATS LAST alone does NOT print the Hint Report in this version; add +HINT_REPORT (TYPICAL prints it).
  Valid hint: listed under its object, e.g. 4 - SEL$58A6D7F6 / "O"@"SEL$1"   - USE_HASH(o). Plan became a hash join: 18,185 gets.
  Wrong names (USE_HASH(x) FULL(z)): the query ran, correct rows, plan unchanged, no error; only the report shows "N - Unresolved (2)". A hint nobody verifies is a time bomb.
  Hint Report flags: no flag = used; N unresolved (name not found); E error (invalid use); U unused (valid but not applicable); P partially used.
  Remember the estimate is still wrong (E-Rows 200); the hint steers the join method only. Fix the cause (section 3.3) when you can.

### 4.3 Common hints (from documentation, only USE_HASH and GATHER_PLAN_STATISTICS were run in the lab)
  Access: FULL(t), INDEX(t ix), INDEX_FFS(t ix), NO_INDEX(t ix)
  Join method: USE_NL(t), USE_HASH(t), USE_MERGE(t), NO_USE_NL(t); join order: LEADING(a b c)
  Other: NO_MERGE, MATERIALIZE, PARALLEL(n), APPEND, CARDINALITY (undocumented-style, avoid), OPT_ESTIMATE (used by profiles, do not write by hand)
  Query block names: qb_name(x) then @x inside other hints, or take the name from the Hint Report.

### 4.4 Deliver a hint without touching the code: SQL patch (tested)
  DECLARE n VARCHAR2(128); BEGIN
    n := DBMS_SQLDIAG.CREATE_SQL_PATCH(sql_id => '&sql_id', hint_text => 'USE_HASH(o@sel$1)', name => 'PATCH_REPORT_HASH', description => '&ticket');
  END; /
  Tested forms that resolved: USE_HASH(o@sel$1), USE_HASH(@"SEL$1" "O"@"SEL$1"), USE_HASH(@"SEL$58A6D7F6" "O"@"SEL$1").
  Plain USE_HASH(o) inside a patch stayed "N - Unresolved" (same hint resolves in the SQL text). Always take the target from the Hint Report format and verify.
  View: SELECT name, status, created FROM dba_sql_patches;   Drop: EXEC DBMS_SQLDIAG.DROP_SQL_PATCH('&name');   Disable: DBMS_SQLDIAG.ALTER_SQL_PATCH(name, 'STATUS', 'DISABLED')
  dba_sql_patches is a dictionary view (all RAC nodes); create once. DBMS_SHARED_POOL.PURGE is per instance.
  Verify (RAC):
  SELECT inst_id, child_number, plan_hash_value, executions, ROUND(elapsed_time/NULLIF(executions,0)/1e3,1) ela_ms, ROUND(buffer_gets/NULLIF(executions,0)) gets, sql_patch FROM gv$sql WHERE sql_id = '&sql_id' ORDER BY 1, 2;
  SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR('&sql_id', NULL, 'TYPICAL +HINT_REPORT +NOTE'));   -- Note: SQL patch "..." used
  Lab: 2433189415 -> 1590490485, 260-336 ms -> 92 ms, ~241K -> 17,962 gets, SQL text untouched.
  Trap found in the lab: dropping a patch does NOT remove its cursor, and creating a patch did not always replace a cursor already in memory. A DISPLAY_CURSOR showed a patch I had already dropped. Check sql_patch, executions and last_active_time in gv$sql; purge if needed:
  BEGIN FOR r IN (SELECT address, hash_value FROM v$sqlarea WHERE sql_id = '&sql_id') LOOP SYS.DBMS_SHARED_POOL.PURGE(r.address || ',' || r.hash_value, 'C'); END LOOP; END; /
  The statement is only in the shared pool while it runs; "SQL_ID cannot be found" can simply mean the workload is not running.

### 4.5 Which delivery route?
  Hint in the SQL text : you own the code and the fix is permanent; needs a release; must be verified with the Hint Report.
  SQL patch            : you know the exact hint, code cannot change; fast; per sql_id text; licensing not verified here, check your Oracle licence terms before using on production.
  SQL profile          : cause is a wrong estimate, you want the optimizer to choose (section 3).
  Baseline             : you want one specific plan frozen (section 2).
  Always: prefer fixing the cause (statistics, section 3.3); every hint/patch is a manual decision that outlives the data it was tuned for.

### 4.6 Lab notes
  Scripts: lab/12_hint_lab.sh start [sessions] [secs] | stop | reset (drops profiles, patches, extended stats, purges the cursor). start sets optimizer_adaptive_plans = FALSE in memory.

## 5. SQL Monitor report  (lab 13, tested on 26ai Free)

Use it when ONE execution is the problem: "the job has been running 10 minutes: is it stuck, which step, when will it finish?" Averages (gv$sqlstats, AWR) cannot answer that; SQL Monitor records a single execution step by step (rows, time, I/O, wait samples per plan line).
What is monitored (documentation, not all tested): statements with more than about 5 s of CPU or I/O time, parallel statements, and any statement with /*+ MONITOR */ (/*+ NO_MONITOR */ switches it off). Fast statements never appear. Licence: part of the Tuning Pack; check your terms.

### 5.1 Case: month-end balance job, 3+ minutes (lab 13)
Ticket: "the job has been running for minutes; is it stuck, what is it doing, when does it finish?" Table LAB.RPT_ORDERS (2,000,000 rows, 16,942 blocks, NO index); job = one SELECT with a per-customer scalar lookup for 4,000 customers (module MONTH_END_BALANCE).

Step 1: what is running long right now (RAC)
  SELECT inst_id, sql_id, sql_exec_id, status, username, module, ROUND(elapsed_time/1e6) ela_s, ROUND(cpu_time/1e6) cpu_s,
         ROUND(user_io_wait_time/1e6) io_s, buffer_gets, TO_CHAR(sql_exec_start,'HH24:MI:SS') started
  FROM   gv$sql_monitor WHERE status = 'EXECUTING' ORDER BY elapsed_time DESC;
  Run it 2-3 times, a minute apart.
  Stuck vs working: working = elapsed AND cpu AND buffer_gets all grow (lab: 52 s/16.9M, 116 s/38.4M, 140 s/46.9M gets, ~330K gets/s, CPU = elapsed). Stuck = elapsed grows, CPU and gets flat, a real wait event in gv$session (state = 'WAITING').
  A PL/SQL block and the SELECT inside it appear as two rows with the same sql_exec_id and the same totals: use the SELECT's sql_id for the report (the block has no plan section).
  sql_exec_id identifies ONE run: sql_id + sql_exec_id (+ start time). Same sql_id run again = new sql_exec_id (lab: 16777217, 16777218, 16777219).

Step 2: the report
  SET LONG 1000000 LONGCHUNKSIZE 1000000 LINESIZE 250 PAGESIZE 0 TRIMSPOOL ON
  SELECT DBMS_SQLTUNE.REPORT_SQL_MONITOR(sql_id => '&sql_id', type => 'TEXT', report_level => 'ALL') FROM dual;
  Without sql_exec_id you get the latest run; add inst_id => n and sql_exec_id => n to pick one (RAC, or several runs).
  Read in this order:
   1. Global Information: Status, Duration, Module/Action.
   2. Global Stats: CPU vs IO vs Other waits, buffer gets, read bytes.
   3. SQL Plan Monitoring Details:
      Execs   = how many times the step ran (lab: inner full scan 403 after 22 s, 4000 at the end)
      Rows (Estim) vs Rows (Actual) = estimate vs reality, live (lab: estimate 10 per lookup was right)
      Activity (%) and Activity Detail = where the sampled time goes (lab: step 2 = 100%: Cpu 73%, direct path read 27%)
      "->" in the first column = steps still running
  When will it finish: progress = rows delivered by the OUTER step / its total. Lab: 402 of 4,000 customers after 22 s = 10% => about 220 s in total (actual 198 s). Assumes a steady rate; check with two reports.

Step 3: why is the step so heavy
  Estimates right but one step executed thousands of times scanning everything = a missing access path:
  SELECT table_name, num_rows, blocks FROM dba_tables WHERE owner = '&owner' AND table_name = '&table';
  SELECT i.index_name, c.column_name, c.column_position FROM dba_indexes i JOIN dba_ind_columns c ON c.index_owner = i.owner AND c.index_name = i.index_name
  WHERE  i.owner = '&owner' AND i.table_name = '&table' ORDER BY 1, 3;
  Lab: no index on RPT_ORDERS => 4,000 lookups x 16,942 blocks = 67.8M gets = what the report showed (67M gets, 512GB read, direct path read because a full scan of a big table bypasses the buffer cache).

### 5.2 Fix and proof
  CREATE INDEX lab.ix_rpt_cust ON lab.rpt_orders (cust_id);      -- production: add ONLINE, and think about DML load / space first
  EXEC DBMS_STATS.GATHER_TABLE_STATS('LAB', 'RPT_ORDERS', cascade => TRUE);
  Result: 198 s -> 0.25 s, 67,096,008 -> 41,017 gets, plan 1291290544 -> 1615654193, step 2 = TABLE ACCESS BY INDEX ROWID BATCHED via IX_RPT_CUST, direct path read gone (index lookups read a few cached single blocks).
  Prove with a new report (compare duration, gets, Execs).

### 5.3 After the fact, and other forms
  Finished runs stay in gv$sql_monitor for a limited time (lab: DONE rows from 22:55 were still listed at 23:20). Status values seen: EXECUTING, DONE (ALL ROWS), DONE (ERROR) (a killed session), DONE (first-n; documentation). Others in documentation: QUEUED.
  Longer retention is documented via AWR (DBA_HIST_REPORTS / DBMS_AUTO_REPORT); not tested here, planned for the historical playbook.
  type => 'ACTIVE' gives an HTML report with graphics (documentation; needs a browser, not tested here); type => 'TEXT' is what you can paste in a ticket.
  Parallel queries: all PX servers appear in one report (documentation, not testable on Free).
  Always: the report shows facts, not the cause. After reading it go back to the plan, the estimates and the access paths.

### 5.4 Lab notes
  Scripts: lab/13_monitor_lab.sh setup | start [customers] | stop | fix | reset | drop. Table LAB.RPT_ORDERS is about 130 MB: run drop when finished.
  Tried and rejected as "long" queries: a hash-join self-join with window sort finished in 13 s (too fast to watch). The per-customer lookup with /*+ NO_UNNEST */ (without it Oracle merges it into one hash join and finishes in 0.05 s) gave a steady ~3-minute run.

---

## 6. Real Application Testing: Database Replay (test a change with the real production workload)  (NOT runnable on the lab)

Not reproduced: on Oracle AI Database 26ai Free (checked 2026-10-27) `v$option` shows "Real Application Testing = FALSE" and DBMS_WORKLOAD_CAPTURE.START_CAPTURE fails with ORA-00438: Real Application Testing Option not installed. Everything below is from the Oracle documentation; check the argument names in the manual of your version. Licence: Real Application Testing is a separately licensed Enterprise Edition option (needed on production and on the test system).

### 6.1 What it is, and when to use it
Question it answers: "Will the whole system hold up under production load after the change (patch, upgrade, parameter, hardware, RAC conversion, migration, consolidation)?" It records the real client workload on production (every call with timing and concurrency), replays it on a TEST COPY that has the change applied, and compares the result with production. It finds concurrency, locking, latch, memory, I/O and capacity problems and errors or wrong results, which single-statement checks cannot see.
Not the right tool for "will this one query change its plan": run that query on the test database before and after the change and compare plan and buffer gets (sections 2 to 5).
If response times are worse in the replay, find the cause with AWR compare reports (Oracle_Historical_Analysis_Playbook.sql, section 2.7).

### 6.2 The setup
  PRODUCTION (heavy workload)                      TEST DATABASE (clone of production)
    1. archivelog + backup exist                     3. restore a CLONE of production to the capture start SCN
    2. record the workload (capture)  ------------>  4. process the capture, map connections
                                                     5. (recommended) baseline replay on the UNCHANGED clone
                                                     6. APPLY THE CHANGE (patch / upgrade / parameter)
                                                     7. replay again, then compare divergence and performance
Production is never changed. The test database is a clone, measured before and after the change.
Needed: RAT licence; a test server able to hold a full copy of production with similar CPU/memory/storage (a much smaller server makes absolute timings incomparable); space for the capture files (they grow with the call volume; capture 10 minutes first and extrapolate) and for the processed copy; one or more machines for the replay clients (`wrc`), sized by the calibration step; written pass criteria (for example: no divergence, DB time within +10 percent, no new top wait events).

### 6.3 Phase 1: prepare production (just before the window)
  1. Pick the window: a representative busy period (for example Monday 09:00-10:00), plus any batch you care about.
  2. Nothing special is needed on production beyond: ARCHIVELOG mode, an existing backup and the archived logs after it. The capture records its start SCN (DBA_WORKLOAD_CAPTURES, START_SCN; check the column in your version); or note `SELECT current_scn FROM v$database;` just before starting. Avoid a GUARANTEED restore point on production (flashback logs are kept until dropped: FRA space and I/O overhead); a normal restore point only names an SCN. A storage snapshot, or a restore point on a STANDBY, are alternatives.
  3. Directory object on a path with enough space (empty; on RAC shared storage reachable from every node, or each node writes its own part):
       CREATE OR REPLACE DIRECTORY cap_dir AS '/u01/rat/capture';
  4. Optional: restart of the instance so that no transaction is in flight at the start. Rarely acceptable on production. Without it, transactions open at the start are only partly recorded, which gives some errors/divergence at the beginning of the replay for those sessions; start at a quiet moment to reduce it.
  5. Optional filters, for workloads you do not want to replay:
       EXEC DBMS_WORKLOAD_CAPTURE.ADD_FILTER(fname => 'no_batch', fattribute => 'USER', fvalue => 'BATCH_USER');

### 6.4 Phase 2: capture on production
  6. Start (1 hour); watch the status:
       EXEC DBMS_WORKLOAD_CAPTURE.START_CAPTURE(name => 'peak_1h', dir => 'CAP_DIR', duration => 3600, default_action => 'INCLUDE');
       SELECT id, name, status FROM dba_workload_captures;
  7. Let production run normally; change nothing.
  8. When it ends (or call FINISH_CAPTURE), export its AWR and read the capture report (what was captured, what was filtered, what could not be captured):
       EXEC DBMS_WORKLOAD_CAPTURE.FINISH_CAPTURE;
       EXEC DBMS_WORKLOAD_CAPTURE.EXPORT_AWR(capture_id => <id>);
       SELECT DBMS_WORKLOAD_CAPTURE.REPORT(capture_id => <id>, format => 'HTML') FROM dual;
  Recorded: client requests (SQL text, binds, calls, order, timing, commits, session/user/service, SCN) with the concurrency. Not recorded: background processes and a documented list of unsupported features (check the list for your version).
  Overhead is documented at about 5 percent or less.

### 6.5 Phase 3: build the test system
  9. Restore a CLONE of production to the capture start SCN (RMAN restore, or DUPLICATE ... UNTIL SCN <start_scn>, from the existing backup and archived logs). Same data as at the start of the capture. Do NOT apply the change yet: the clone must equal production for the baseline.
 10. Neutralise the environment on the clone: disable database links, set job_queue_processes = 0 (or disable scheduler jobs), check directory objects, UTL_HTTP / e-mail / external calls. Otherwise the clone can write into production.
 11. Copy the capture files to the test host; directory:
       CREATE OR REPLACE DIRECTORY replay_dir AS '/u01/rat/replay';
 12. Process the capture (heavy; depends on the database version, redo it if you upgrade afterwards):
       EXEC DBMS_WORKLOAD_REPLAY.PROCESS_CAPTURE(capture_dir => 'REPLAY_DIR');

### 6.6 Phase 4: baseline replay on the UNCHANGED clone (recommended)
  It shows how much difference the test environment itself introduces, before the change is blamed.
 13. Take a restore point on the clone: CREATE RESTORE POINT clone_start GUARANTEE FLASHBACK DATABASE; (fine on a test system).
 14. Run a full replay (steps 17 to 21) on the unchanged clone; keep its replay id.
 15. Return the clone to the starting data (FLASHBACK DATABASE TO RESTORE POINT clone_start, or restore again).

### 6.7 Phase 5: apply the change and replay
 16. Apply the change to the clone (patch, upgrade, parameter, hardware).
 17. Initialise and remap the recorded connections (they point to production):
       EXEC DBMS_WORKLOAD_REPLAY.INITIALIZE_REPLAY(replay_name => 'after_change', replay_dir => 'REPLAY_DIR');
       SELECT conn_id, capture_conn, replay_conn FROM dba_workload_connection_map;
       EXEC DBMS_WORKLOAD_REPLAY.REMAP_CONNECTION(connection_id => 1, replay_connection => '//testhost:1521/svc');
 18. Prepare:
       EXEC DBMS_WORKLOAD_REPLAY.PREPARE_REPLAY(synchronization => 'SCN', connect_time_scale => 100, think_time_scale => 100, think_time_auto_correct => TRUE, scale_up_multiplier => 1);
     synchronization 'SCN' keeps the commit order ('OBJECT_ID' and 'OFF' are looser; check the values of your version). Scale values of 100 mean the original timing; lower think/connect time scales compress the timeline (more stress); scale_up_multiplier above 1 repeats sessions to simulate growth.
 19. Calibrate and start the replay clients (operating system):
       wrc mode=calibrate replaydir=/u01/rat/replay
       wrc system/<password>@//testhost:1521/svc mode=replay replaydir=/u01/rat/replay
     Start as many wrc processes (on one or several machines) as the calibration says.
     How many: calibrate prints a recommended number of clients, CPUs and memory per client (about 150 MB each); it uses process_per_cpu (default 4) and threads_per_process (default 50), i.e. a client drives up to about 50 replayed sessions. Treat it as a minimum; if the replay runs behind the original timeline (or V$WORKLOAD_REPLAY_THREAD shows busy clients and an idle database), add clients and replay again.
     Several on one server is fine (each wrc is an OS process); the limit is that server's CPU and memory. Prefer separate client machines, not the database nodes (the clients would take CPU from the system under test). On RAC the clients connect through the connect strings given in REMAP_CONNECTION (SCAN/service; keep instance affinity if the capture had it). Every client machine needs access to the processed replay directory (copy or share it). START_REPLAY is run once, in the database. (Documentation, not reproduced.)
 20. Start and watch:
       EXEC DBMS_WORKLOAD_REPLAY.START_REPLAY;
       SELECT id, name, status FROM dba_workload_replays;      -- also V$WORKLOAD_REPLAY_THREAD; DBMS_WORKLOAD_REPLAY.CANCEL_REPLAY if needed

### 6.8 Phase 6: compare and decide
 21. Report:
       SELECT DBMS_WORKLOAD_REPLAY.REPORT(replay_id => <id>, format => 'HTML') FROM dual;
 22. Read in this order:
       1. Data divergence and error divergence: did anything return different rows or fail?
       2. Total duration and DB time, against the capture and against the baseline replay.
       3. Top SQL and top wait events: AWR compare between the capture's AWR export and the replay's AWR (DBMS_WORKLOAD_REPLAY.COMPARE_PERIOD_REPORT, or an AWR compare report as in the historical playbook, section 2.7).
 23. If something is worse, decide whether it is the change or the environment (compare with the baseline replay), fix it, replay again.
 24. Check the result against the pass criteria written in the plan, then go / no-go.
  Before go-live: keep an AWR baseline of the good production period (DBMS_WORKLOAD_REPOSITORY.CREATE_BASELINE), have the rollback plan written.

### 6.9 Common mistakes
  - Taking the backup after starting the capture, or not being able to restore to the capture start SCN (no ARCHIVELOG/backup): the clone no longer matches the start and the replay diverges.
  - Forgetting to disable database links and jobs on the clone (it can write into production).
  - Too few replay clients, so the replay lags and looks slower than it is.
  - Comparing a cold replay with warm production, or testing on a much smaller server.
  - Treating small differences as real: run the baseline replay first.
  - Using a guaranteed restore point on production for this.

### 6.10 Other RAT tool (not covered here)
  SQL Performance Analyzer (DBMS_SQLPA) compares single statements before and after a change (plans and timing, no concurrency). It also needs the RAT option; the lab fails with the same ORA-00438. The SQL tuning set it uses (DBMS_SQLTUNE) works on Free.

---

## 7. SQL health check: by hand and with SQLHC  (lab 16, tested on 26ai Free)

Use it when: "the SQL did not change but it got slow" and you do not yet know why. A health check collects everything around one statement (plan, indexes, statistics, optimizer settings, history, controls) and lists findings. Then you decide which finding is the CAUSE, which is NOISE and which is a FOLLOW-UP. Do not change five things at once.

### 7.1 By hand (all queries tested; RAC form)
  1. The statement and its cost (module of the application):
     SELECT inst_id, sql_id, plan_hash_value phv, module, executions execs, ROUND(elapsed_time/NULLIF(executions,0)/1e3,1) ela_ms, ROUND(cpu_time/NULLIF(executions,0)/1e3,1) cpu_ms,
            ROUND(buffer_gets/NULLIF(executions,0)) gets_per_exec, ROUND(rows_processed/NULLIF(executions,0),1) rows_per_exec, sql_text
     FROM   gv$sql WHERE module = '&module' AND executions > 0 ORDER BY elapsed_time DESC FETCH FIRST 5 ROWS ONLY;
     Rule: gets per run versus what the statement SHOULD need (10 rows through an index = about 13 gets; 20,803 = a full scan of the table).
  2. The plan with the peeked bind values:
     SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR('&sql_id', NULL, 'TYPICAL +PEEKED_BINDS'));
  3. Indexes on the tables: read EVERY column, especially VISIBILITY and STATUS:
     SELECT i.index_name, i.visibility, i.status, c.column_name, c.column_position FROM dba_indexes i JOIN dba_ind_columns c ON c.index_owner = i.owner AND c.index_name = i.index_name
     WHERE  i.owner = '&owner' AND i.table_name = '&table' ORDER BY i.index_name, c.column_position;
     An existing index is not used when: INVISIBLE, UNUSABLE, a function or data-type conversion on the column, the optimizer prices another path cheaper (statistics, selectivity, parameters), or a hint/profile/baseline/patch forces another plan.
  4. Statistics: rows in statistics versus real, stale, locked, last analyzed:
     SELECT t.table_name, t.num_rows stats_rows, (SELECT COUNT(*) FROM &owner..&table) actual_rows, t.stale_stats, t.stattype_locked locked, TO_CHAR(t.last_analyzed,'MM-DD HH24:MI') last_analyzed
     FROM   dba_tab_statistics t WHERE t.owner = '&owner' AND t.table_name = '&table' AND t.partition_name IS NULL;
     (plus dba_tab_col_statistics for histograms of the predicate columns, section 3.1.)
  5. Optimizer settings the cursor was parsed with that are not default:
     SELECT inst_id, name, value FROM gv$sql_optimizer_env WHERE sql_id = '&sql_id' AND child_number = 0 AND isdefault = 'NO' ORDER BY inst_id, name;
  6. History of the plan / what changed: higher child number with a different plan hash in gv$sql; dba_hist_sqlstat by plan_hash_value (Oracle_Historical_Analysis_Playbook.sql 2.3).
  7. Controls attached to the statement: gv$sql columns sql_profile, sql_patch, sql_plan_baseline (sections 2 to 4).
  8. Prove a hypothesis in YOUR session only (nothing changes for the application):
     ALTER SESSION SET optimizer_use_invisible_indexes = TRUE;
     EXPLAIN PLAN FOR <the statement with a literal>;   SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY(NULL, NULL, 'BASIC +COST'));
  9. Fix and prove: fix the cause only, then compare before/after (gv$sql: plan hash, ms per run, gets per run).

### 7.2 Lab 16 case
  Portal lookup `SELECT COUNT(*), NVL(SUM(AMOUNT),0) FROM LAB.PROF_ORDERS WHERE CUST_ID = :B1` (sql_id cdy8kdv7k7x9f, module PORTAL_LOOKUP). Ticket: slow after the release, "the SQL did not change".
  Symptom: 58.3 ms and 20,803 gets per run for 1 row (should be about 13 gets). Plan: TABLE ACCESS FULL, cost 4601, estimate 10 rows (correct).
  Findings by hand: (a) index IX_PROF_CUST on CUST_ID exists, VALID but INVISIBLE; (b) statistics 2,000,000 rows versus 2,500,000 real, stale and locked; (c) non-default settings: optimizer_index_cost_adj = 50 (set on purpose in the portal sessions), optimizer_adaptive_plans = false with three hidden parameters (leftovers of labs 11 and 12).
  Proof: in a session with optimizer_use_invisible_indexes = TRUE the plan is INDEX RANGE SCAN + TABLE ACCESS BY INDEX ROWID BATCHED, cost 13 versus 4601.
  Cause: the invisible index ONLY. Noise (not the cause): stale/locked statistics (the 10-row estimate was still right), optimizer_index_cost_adj (it pushes towards indexes), adaptive-plans leftovers.
  Fix: ALTER INDEX lab.ix_prof_cust VISIBLE; (dictionary change, cursors invalidated and re-parsed). Result: plan 275726001 -> 4051247491, 58.3 ms -> 0.03 ms, 20,803 -> 16 gets per run.
  Follow-up actions (separate changes): find out who made the index invisible and why; unlock and regather the statistics (decide whether locking is intended); remove the index_cost_adj hack after testing; revert optimizer_adaptive_plans to default.

### 7.3 SQLHC (SQL Health-Check, My Oracle Support note 1366133.1)
  What: a script bundle that produces a zip of reports for ONE sql_id: health check (observations with priority), diagnostics, execution plans, SQL detail, SQL Monitor reports, a 10053 optimizer trace, a planx text report, optionally a tuning advisor report and a Test Case Builder export.
  Get it: from My Oracle Support (login needed). Files in the download used here: sqlhc.sql (version 12.1.07, about 7,500 lines), sqlhc_sta.sql, sqlhc_tcb.sql, sqldx.sql, util_planx.sql, rwp_sqlmonreport.sql. Keep them together in one folder (lab/sqlhc/). Read the scripts before running them as SYS.
  Run it (generic, any system):
    1. Put ALL the SQLHC scripts in one directory on the machine where SQL*Plus runs (the database server, or a client with SQL*Plus), and make that directory the current directory: the scripts call each other by relative name and write their output files (html, log, zip) into the current directory. The OS user needs write permission there, and `zip`, `unzip` must be installed (the script runs them).
         cd /path/to/sqlhc
    2. Start SQL*Plus as SYS or a user with the DBA role, connected to the database (the PDB, if the statement runs in a PDB) and, on RAC, to the instance where the statement is in the shared pool:
         sqlplus / as sysdba                      -- or: sqlplus sys@//<host>:<port>/<service> as sysdba
    3. Make sure the statement is still in the shared pool (SELECT sql_id FROM gv$sql WHERE sql_id = '<sql_id>';). If it is not, run the application again first.
    4. Run the script with two parameters, the pack licence and the sql_id:
         SQL> START sqlhc.sql T <sql_id>
       The first parameter: T = Tuning Pack licensed (includes Diagnostics; adds the tuning advisor and SQL Monitor reports), D = Diagnostics Pack only, N = no packs. Use the one your licence allows; the script does not check it for you. Without the arguments it prompts for them.
       Example: SQL> START sqlhc.sql T cdy8kdv7k7x9f
    5. Wait for it to finish (about a minute on a small statement; the tuning advisor step can take up to 20 minutes). It ends by listing the zip: sqlhc_<date>_<time>_<sql_id>.zip (and sqlhc.log for errors).
    6. Copy the zip to your PC, unzip it and open the _1_health_check.html first (then _2_diagnostics.html, _3_execution_plans.html).
    7. Fix the cause, re-execute the statement and run SQLHC again to compare (the report says so itself).
  Lab (the database runs in a Docker container, so SQL*Plus runs inside it):
    docker exec oracle-lab mkdir -p /tmp/sqlhc_manual
    docker cp /Users/rajeshkumar/Documents/Oracle_Commands/lab/sqlhc/. oracle-lab:/tmp/sqlhc_manual/
    docker exec -it -w /tmp/sqlhc_manual oracle-lab sqlplus 'sys/OracleLab#2026@//localhost:1521/FREEPDB1 as sysdba'
    SQL> START sqlhc.sql T <sql_id>
    SQL> EXIT
    docker exec oracle-lab bash -c 'ls /tmp/sqlhc_manual/*.zip'
    docker cp oracle-lab:/tmp/sqlhc_manual/<zip name> /Users/rajeshkumar/Documents/Oracle_Commands/lab/reports/sqlhc/manual/
    (do NOT run an interactive `docker exec -it ... bash` in the same pasted block as other commands: the following lines go into the container shell.)
  Lab helper (does the same as the lab commands above in one go): ./lab/run_sqlhc.sh <sql_id> [T|D|N] copies the scripts into a scratch directory in the container, runs them, and brings the zip to lab/reports/sqlhc/<sql_id>/ (run_console.txt holds the log). ./lab/run_sqlhc.sh clean <sql_id> drops the tuning task.
  Side effects (the header says "no DDL, no objects", but the full run also does the following): switches on 10046 for its own session; forces an extra AWR snapshot (create_snapshot flush ALL); creates a tuning task <sql_id>_tuning_task over the whole AWR range and runs it (up to 20 minutes); dumps a 10053 trace with DBMS_SQLDIAG.DUMP_TRACE; tries a Test Case Builder export into directory SQL_TCB_DIR; runs zip/cp/mv in the working directory. On production this needs approval.
  Failures in this multitenant lab (everything else ran): (1) the tuning advisor step: ORA-13768 Snapshot ID must be between 140 and 355 (it takes min/max snap_id over dba_hist_snapshot, which mixes CDB and PDB snapshot numbers; the task is never created); (2) Test Case Builder: ORA-20000 not allowed under user SYS (and not for PDBs).
  Report: the zip holds _1_health_check.html (Observations, SQL text, tables and indexes summary), _2_diagnostics.html, _3_execution_plans.html, _4_sql_detail.html, _5 SQL Monitor, _6 10053 trace, _8 sqldx, _9 log, planx_<sql_id>_*.txt.
  Lab observations (14 with the index invisible): invisible index 90 / 89 / 90, stale statistics 83, statistics job 66, locked statistics 48, optimizer features 45 (x2), non-default parameters 35 (x5), system statistics 33. Row #13 ("the index referenced in the execution plan is invisible") appears when a plan in the history used the index: the statement used to be fast.
  After the fix the invisible-index rows disappear; run it before and after to prove it.
  Where the real evidence is (unzip; the Observations table is only the summary):
    _2_diagnostics.html : Historical Plans Summary (DBA_HIST_SQLSTAT) = the plan history: lab: index plan 4051247491 in AWR, 19.9M executions, 16 gets, 0.019 ms; full-scan plan 275726001 now 55 ms and 16.5K gets (proof that it used to be fast = a regression). Current Plans Summary (GV$SQL): loads and invalidations. ASH by Plan Line (memory and AWR): time per plan line, object and event per plan (full scan: ON CPU + direct path read on LAB.PROF_ORDERS; index plan: INDEX RANGE SCAN and BY INDEX ROWID). Tables/Indexes Statistics Versions: when statistics changed, row counts, blocks. Indexes: distinct keys, B-tree height, clustering factor (2,000,000 = equal to the rows: every row of a key is in a different table block, so about 16 gets per lookup), locked and stale flags. Also SQL baselines/profiles/patches attached, cursor sharing reasons, DBMS_STATS preferences, non-default parameters, constraints, metadata.
    _3_execution_plans.html : Outline Data = the hints that reproduce each plan, including OPT_PARAM('optimizer_index_cost_adj' 50) and DB_VERSION('23.1.0') (confirms the OPTIMIZER_FEATURES_ENABLE observation was a naming artefact).
    _6_10053_trace_from_cursor.trc : the optimizer's reasoning. Lab: "Access path analysis for PROF_ORDERS" lists only Access Path: TableScan, cost 4601.215, Best:: TableScan; the index is never a candidate, and optimizer_use_invisible_indexes = false is printed in the parameter list = the strongest proof "not considered" versus "rejected on cost".
    planx_<sql_id>_*.txt and rwp_*.zip : plans per hash value from AWR and memory with average times and gets; the text SQL Monitor list/detail.
    _4_sql_detail.html is an active report (needs a browser with JavaScript).

### 7.4 How to read the observations (triage)
  - The priority is a fixed weight, not a diagnosis. Stale statistics scored 83 and were not the cause here.
  - Some wording is generic: "Disable this job immediately" (automatic statistics job) must NOT be followed blindly; the job normally stays on, the real message is to check how statistics are gathered. "System statistics not gathered" is usually normal. The OPTIMIZER_FEATURES_ENABLE 23.1.0 versus 23.0.0.0.0 observation was a false positive (the parameter is default; checked with gv$sql_optimizer_env).
  - Always confirm a suspected cause with a test that changes nothing for the application (7.1 step 8) before changing anything.
  - Sort the findings in three lists: CAUSE (fix now, one at a time), NOISE (note and leave), FOLLOW-UP (separate change requests).
  - Not covered here: SQLT (heavier, installs a schema) and sqltrpt.sql (ships in $ORACLE_HOME/rdbms/admin; "SQL Tune RePorT": lists the 15 most expensive statements in the cursor cache, asks for one sql_id, runs the Tuning Advisor and prints the report; compare lab 11).

### 7.5 Built-in alternative: DBMS_SQLDIAG.REPORT_SQL (tested on 26ai Free)
  Signature (dba_arguments): FUNCTION REPORT_SQL(sql_id VARCHAR2, directory VARCHAR2 DEFAULT ..., level VARCHAR2 DEFAULT ...) RETURN CLOB, plus an overload taking incident_id. I did not verify which release introduced it.
  It is a function that does DDL/commit-like work internally, so it fails in a query:
     SELECT DBMS_SQLDIAG.REPORT_SQL(sql_id => 'cdy8kdv7k7x9f') FROM dual;   -- ORA-14552: cannot perform a DDL, commit or rollback inside a query or DML
  Call it from PL/SQL or SQL*Plus and write the HTML to a file:
     SET LONG 2000000 LONGCHUNKSIZE 2000000 PAGESIZE 0 LINESIZE 250 FEEDBACK OFF
     VAR r CLOB
     EXEC :r := DBMS_SQLDIAG.REPORT_SQL(sql_id => '<sql_id>');
     SPOOL report_sql.html
     PRINT r
     SPOOL OFF
  Result: one HTML report (about 175,000 characters in the lab) with sections GLOBAL (SQL text, environment, non-default parameters, baselines/profiles, SQL set statements, Observations), PLANS (last, all, historical), SQL STATISTICS (current and historical, monitored executions, reoptimization hints, SQL history from the automatic STS), ASH, TABLES (summary, columns, modifications, preferences, extensions, statistics versions), INDEXES, CURSOR SHARING AND BINDS (peeked vs captured), AUTO TASKS, OPTIMIZER STATISTICS TASKS, PLAN MANAGEMENT (SPM) TASKS, TUNING ADVISOR TASKS, TUNING SET TASKS, MISCELLANEOUS (dependencies, index and view metadata, VPD policies, undo usage).
  If the statement is no longer in the shared pool the report starts with "Warning: SQL Not found in memory" and the in-memory sections are empty (the history sections still fill from AWR).
  Lab comparison with SQLHC (same statement, same state):
     - REPORT_SQL "Observations": "No data was found for this section" both with the index visible and with it invisible, although the table statistics were stale and locked and optimizer_index_cost_adj was non-default. It collects the data (Table Modifications showed 500000 inserts, Stale YES; Plan Control Objects listed the automatic STS SYS_AUTO_STS entry with the old plan) but did not list findings. SQLHC gave 13-14 rule-based observations with priorities (invisible index 90).
     - REPORT_SQL: one PL/SQL call, no downloaded scripts, no OS commands, no files written, no tuning task, no 10053 trace. SQLHC: MOS download, runs zip/cp/mv, forces an AWR snapshot, creates a tuning task, dumps a 10053, produces SQL Monitor and planx reports.
     - SQLHC works on older releases and is what Oracle Support asks for; REPORT_SQL exists in recent releases only.
     - The Index Summary of REPORT_SQL shows status (VALID) but has no visibility column; the invisible index is visible in SQLHC's observations and in dba_indexes.visibility.
  Use: REPORT_SQL for a quick data collection without installing anything; SQLHC when you want the rule-based observations (priority list) or have to send it to Oracle Support; the by-hand health check (7.1) always.

### 7.6 Optimizer environment hash (OPTIMIZER_ENV_HASH_VALUE) (tested)
  A number that stands for all optimizer settings in effect when the statement was parsed (optimizer_mode, optimizer_index_cost_adj, optimizer_features_enable, optimizer_adaptive_plans, multiblock read count, work-area settings, ...). Same settings = same hash. It is a hash: it cannot be decoded, you compare the settings.
  Where it appears: gv$sql.optimizer_env_hash_value, dba_hist_sqlstat.optimizer_env_hash_value, and the "Min/Max OptimizerEnv HV" columns of SQLHC / REPORT_SQL (lowest and highest across the executions or children of that row; different values = parsed under different settings).
  Use it for: (a) a plan flipped and "nothing changed": the old and new plan rows have different hashes = a setting changed (system or session); (b) several child cursors of one sql_id: gv$sql_shared_cursor.optimizer_mismatch = 'Y'; (c) your SQL*Plus test behaves differently from the application: compare hashes before trusting the test (same text typed in SQL*Plus also got another sql_id, because PL/SQL stores the text differently).
  Queries:
     SELECT inst_id, child_number child, plan_hash_value phv, optimizer_env_hash_value env_hash, executions FROM gv$sql WHERE sql_id = '&sql_id' ORDER BY 1, 2;
     SELECT inst_id, child_number child, optimizer_mismatch FROM gv$sql_shared_cursor WHERE sql_id = '&sql_id' ORDER BY 1, 2;
     SELECT inst_id, child_number child, name, value FROM gv$sql_optimizer_env WHERE sql_id = '&sql_id' AND isdefault = 'NO' ORDER BY 1, 2, 3;   -- compare two children side by side
  Lab: application sessions (optimizer_index_cost_adj = 50) hash 2501485544; a SQL*Plus session with 100: hash 3623384726.

---

## 8. SQL tuning report: sqltrpt.sql and the SQL Tuning Advisor  (lab 17, tested on 26ai Free)

sqltrpt.sql ships with the database ($ORACLE_HOME/rdbms/admin/sqltrpt.sql, "SQL Tune RePorT", Tuning Pack licence). It lists the 15 most expensive statements in the cursor cache (V$SQLSTATS: the current instance only, run it on the instance that holds the statement) and in AWR (dba_hist_sqlstat, all dbids), asks for one sql_id, creates a tuning task (name TASK_<n>, scope COMPREHENSIVE, time limit 1800 s), runs it and prints the report. The task stays in the advisor repository: drop it afterwards (DBMS_SQLTUNE.DROP_TUNING_TASK).
  Run (SQL*Plus as SYS in the PDB):   SQL> @?/rdbms/admin/sqltrpt.sql      -- then type the sql_id at the prompt "Enter value for sqlid"
  Which statements to tune: the heaviest application statements by TOTAL elapsed time, not the advisor's own or the monitoring SQL:
     SELECT inst_id, module, sql_id, plan_hash_value phv, executions execs, ROUND(elapsed_time/1e6) total_ela_s, ROUND(elapsed_time/NULLIF(executions,0)/1e3,1) ms_per_exec,
            ROUND(buffer_gets/NULLIF(executions,0)) gets_per_exec, sql_text
     FROM   gv$sql WHERE parsing_schema_name = '&schema' AND module IS NOT NULL AND executions > 0 AND sql_text NOT LIKE 'DECLARE%'
     ORDER  BY elapsed_time DESC FETCH FIRST 8 ROWS ONLY;
     Ignore: rows whose module starts with dbms_stats (statistics gathering SQL), SQL*Plus helper statements, the DECLARE wrappers (their time contains the statements inside).
  Reading the report: GENERAL INFORMATION (task name, scope, bind values peeked), FINDINGS SECTION (type of each finding, recommendation, estimated benefit), EXPLAIN PLANS SECTION (Original plan with the SQL Analysis Report, then the plan "Using New Indices" or "With SQL Profile").
  Housekeeping: each run leaves a tuning task (TASK_<n>). List and drop:
     SELECT task_name, status, TO_CHAR(created,'MM-DD HH24:MI') created FROM dba_advisor_tasks WHERE advisor_name = 'SQL Tuning Advisor' AND owner = 'SYS' ORDER BY created;
     EXEC DBMS_SQLTUNE.DROP_TUNING_TASK('TASK_506');

### 8.1 Case 1: account search, two findings (statement 56k4srw85xbcb, module ACCT_SEARCH)
  Statement: SELECT COUNT(*) FROM LAB.TR_ACCT WHERE ACCT_NO = :B1, bound as a NUMBER, while ACCT_NO is VARCHAR2 and has an index (IX_TR_ACCT). Cost in the workload: 676 ms and 13,143 gets per run.
  Advisor (task TASK_506):
     Finding 1 "Index Finding", estimated benefit 99.91 percent: create index LAB.IDX$$_01FA0001 on LAB.TR_ACCT(TO_NUMBER("ACCT_NO")) (a function-based index; plan INDEX RANGE SCAN, cost 3 against 3619).
     Finding 2 "Restructure SQL": the predicate TO_NUMBER("TR_ACCT"."ACCT_NO") = :B1 contains an implicit data type conversion on the indexed column, which prevents the optimizer from using indexes on the table. Recommendation: rewrite the predicate. (The plan's "SQL Analysis Report" repeats it: "columns have predicates which preclude their use as keys in index range scan".)
  Plan symptom: filter(TO_NUMBER("ACCT_NO")=:B1) on TABLE ACCESS FULL although an index on ACCT_NO exists.
  The better fix is the RESTRUCTURE one, not the index (tested):
     compare as a string:  WHERE acct_no = TO_CHAR(:v)    -- or bind a VARCHAR2 in the application
     plans: number predicate = TABLE ACCESS FULL, cost 3619; string predicate = INDEX RANGE SCAN on the existing IX_TR_ACCT, cost 3.
     300 real lookups: number predicate 25.25 s, 13,158 gets per lookup (about 84 ms); string predicate 0.13 s, 3 gets per lookup (about 0.4 ms).
  Why not simply create the recommended function-based index: it treats the symptom, adds another index to maintain, and leaves a data-quality bomb. The original statement converts EVERY row: a single non-numeric value in ACCT_NO makes the query fail (tested, in an uncommitted row that was rolled back):
     INSERT INTO lab.tr_acct VALUES ('A-100', 'test', 1);
     SELECT COUNT(*) FROM lab.tr_acct WHERE acct_no = 1101416;
     ORA-01722: unable to convert string value containing 'A' to a number: ACCT_NO
  An index on TO_NUMBER(acct_no) would also make the INSERT of such a value fail (the index expression is evaluated at insert time; documented behaviour, not run here).
  Rule: when the advisor lists an Index finding AND a Restructure SQL finding for the same statement, look at the Restructure one first; the index may be unnecessary.

### 8.2 Case 2: segment report, the same statement gave two different answers (statement fxq3t8cw0bt0c, module SEGMENT_REPORT)
  Statement: the lab 11 join on the correlated columns seg/tier/grp (nested loops, 240K gets; hash join would need 18K).
  Two runs of sqltrpt.sql one minute apart, six sessions competing on 2 CPUs:
     TASK_507: "There are no recommendations to improve the statement."
     TASK_508: SQL Profile Finding, estimated benefit 90.55 percent.
  Lessons:
     1. The advisor validates by executing the original and the new plan a few times; on a loaded system those trials vary and so can the answer (my explanation, not verified in the advisor's internals). If the advisor says nothing or something odd, run it again at a quiet moment before concluding.
     2. The headline percentage here was the BUFFER GETS improvement. Read the "Validation results" table:
          Buffer gets 242,295 -> 22,864 (90.56 percent better), CPU 0.340 s -> 0.267 s (21.7 percent better),
          ELAPSED 0.526 s -> 0.552 s (4.98 percent WORSE), user I/O 0 -> 0.369 s, physical read bytes 0 -> 175,824,896.
        The profile plan (HASH JOIN with TABLE ACCESS FULL on PROF_ORDERS) reads the whole 2M-row table from disk; under contention it was no faster in elapsed time. In lab 11 on a quiet system the same profile gave 0.60 s -> 0.076 s.
     3. Accept a profile only when ELAPSED time improves under realistic conditions (the user feels elapsed time, not gets). Accept: EXEC DBMS_SQLTUNE.ACCEPT_SQL_PROFILE(task_name => 'TASK_508', task_owner => 'SYS', replace => TRUE);
     4. If the cause is known (correlated columns), prefer the root-cause fix: extended statistics (section 3.3), which corrects the estimate without forcing a plan.

### 8.3 Case 3: balance lookup, an index finding (statement fcayz3v3h36jb, module BALANCE_LOOKUP)
  Statement: SELECT SUM(AMOUNT) FROM LAB.TR_ORDERS WHERE CUST_ID = :B1; TR_ORDERS (2,000,000 rows, 136 MB) has no index. Cost in the workload: 352 ms and 16,681 gets per run (full scan, plan 1784661877, cost 4599).
  Advisor (the user's run TASK_509 and my run agree): Index Finding, estimated benefit 99.73 percent: create index LAB.IDX$$_01FD0001 on LAB.TR_ORDERS("CUST_ID") (plan with the index: TABLE ACCESS BY INDEX ROWID BATCHED + INDEX RANGE SCAN, cost 12 against 4599). The advisor itself says it may be better to run the Access Advisor with a representative workload: it sees one statement, not the write overhead of the new index.
  Result with the index (I created it as IX_TR_ORDERS_CUST ... ONLINE and let the workload re-parse): plan 1770804204, 0.027 ms per run, 13 gets per run (was 352 ms and 16,681 gets).
  What the index costs (measured on scratch tables, the lab was busy so read the ratios, not the absolute times):
     INSERT of 500,000 rows:                    1.04 s without the index, 5.02 s with it (about 4.8 times)
     UPDATE of the indexed column, 200,000 rows: 1.13 s without, 4.10 s with (about 3.6 times)
     Build: CREATE INDEX ... ONLINE on 2,000,000 rows: 4.18 s
     Space: 36 MB for the index against 136 MB for the table (26 percent)
  So the index is a good trade for a read-mostly lookup table and a bad one for a heavy-insert table whose rows are rarely looked up by this column. Before creating an index check: the write rate of the table, space, other statements that could use it, that it is not a duplicate of an existing index (dba_ind_columns), and use ONLINE on a live system.

### 8.3b Fixes applied and proved (the user's run, lab 17)
  Capture the "before" and "after" with the same query (look at last_active against the time of your change):
     SELECT module, sql_id, child_number child, plan_hash_value phv, executions execs, ROUND(elapsed_time/NULLIF(executions,0)/1e3,3) ms_per_exec,
            ROUND(buffer_gets/NULLIF(executions,0)) gets_per_exec, TO_CHAR(last_active_time,'HH24:MI:SS') last_active
     FROM   gv$sql WHERE sql_id IN ('&id1','&id2','&id3') ORDER BY module, child_number;
  Fix A, balance lookup: CREATE INDEX lab.ix_tr_orders_cust ON lab.tr_orders (cust_id) ONLINE;
     plan 1784661877 -> 1770804204 (child 1), 72.288 ms -> 0.025 ms (about 2,900 times faster), 16,685 -> 13 gets per run.
  Fix C, segment report: extended statistics (the root cause, correlated columns), not the advisor's profile:
     SELECT DBMS_STATS.CREATE_EXTENDED_STATS('LAB', 'PROF_CUST', '(SEG,TIER,GRP)') FROM dual;
     EXEC DBMS_STATS.GATHER_TABLE_STATS('LAB', 'PROF_CUST', method_opt => 'FOR ALL COLUMNS SIZE 1', no_invalidate => FALSE);
     plan 1912197898 -> 3981533769 (hash join), 1,078 ms -> 135 ms, 241,741 -> 22,723 gets per run (about 8 times faster in elapsed time on the busy lab).
     Afterwards sqltrpt.sql on the same statement (TASK_510): "Alternative Plan Finding": the original (new) plan 3981533769 at 0.138 s is the best of the plans found (AWR still lists the old nested-loop plan 1912197898 at 1.732 s); no profile recommended. The advisor confirms the fix: with correct estimates (PROF_CUST 20,000 rows) there is nothing left to correct. The plan reads PROF_ORDERS from disk (21,360 reads per run), which is acceptable here but costs I/O.
  Fix B, account search (application change): compare as a string (acct_no = TO_CHAR(:v)); see 8.1.
  Measurement lesson: the three modules shared the CPUs. Fixing the heaviest (the balance lookup) also lowered the others' times a little (account search 272 -> 260 ms) without touching them. Tune the heaviest first, change one thing at a time, and measure each change separately.
  Note: the AWR "15 most expensive" list of sqltrpt.sql covers the whole AWR history and all dbids: it shows statements from earlier labs; ignore anything that is not part of the current problem. Long elapsed values print as ########## (column too narrow: SET NUMWIDTH).

### 8.4 Summary of what sqltrpt / the advisor can answer
  Index finding (physical design: create an index, check the cost), Restructure SQL finding (fix the SQL: implicit conversion, Cartesian join...), SQL Profile finding (wrong estimates: profile or better statistics), Statistics finding (missing or stale statistics), Alternative Plan finding (other plans of the same statement found in the cursor cache or AWR, ranked by elapsed time; the original plan may already be the best), or no recommendation (also an answer: look at the plan and the health check, section 7).
  Always: one statement at a time; run it on a quiet moment; read the validation table; drop the TASK_<n> afterwards.

---

## 9. SQLT (SQLTXPLAIN) and how it differs from sqltrpt, SQLHC and REPORT_SQL  (documentation, to be reproduced in lab 18)

Not yet run in the lab; the facts below are from the documentation and memory. Check the readme of the downloaded version.
Comparison:
  sqltrpt.sql                : ships with the database. Runs the SQL Tuning Advisor on one sql_id and prints its advice (section 8). Creates a tuning task. No install.
  SQLHC (MOS note 1366133.1) : scripts only, no install. Health check of one sql_id: rule-based observations, plans, history, statistics, parameters, ASH (section 7.3). Side effects: extra AWR snapshot, tuning task, traces.
  SQLT  (MOS note 215187.1)  : INSTALLS a schema (SQLTXPLAIN) with packages and repository tables (run sqcreate.sql as SYS once; it asks for the tablespace and the pack licence T/D/N). The deepest diagnostic: everything SQLHC has plus plan comparison between systems, optimizer trace (10053), Test Case Builder export, statistics and histograms in detail, and it can execute the statement under trace.
  DBMS_SQLDIAG.REPORT_SQL    : built into recent releases. One PL/SQL call returning one HTML CLOB; collects data, no observations in my tests (section 7.5).
SQLT methods (names from memory; check the readme): sqltxtract.sql <sql_id> (XTRACT: from memory and AWR for a statement that already ran), sqltxecute.sql <script> (XECUTE: runs the SQL under trace and collects everything), sqltxtrxec.sql (XTRXEC), sqltxplain.sql (XPLAIN: explain only), sqltcompare.sql (COMPARE: the same statement between two systems or plans), sqltxtrsby.sql (for a standby), sqltrcanlzr.sql (TRCANLZR: analyse a trace).
Use: SQLHC or the by-hand health check first; SQLT for hard plan problems, cross-system plan comparison, or when Oracle Support asks for it. An install is a change request on a production system: read the install script first.

---

## 10. SQL Performance Analyzer (SPA): will my SQL statements get slower after the change?  (NOT runnable on the lab)

Not reproduced: on Oracle AI Database 26ai Free, DBMS_SQLPA.CREATE_ANALYSIS_TASK fails with ORA-00438: Real Application Testing Option not installed (checked 2026-10-27). The SQL tuning set it uses (DBMS_SQLTUNE) works on Free. Everything below is from the Oracle documentation; check the argument names in the manual of your version. Licence: SPA is part of the Real Application Testing option (Enterprise Edition), separately licensed.

### 10.1 What it answers, and what it does not
  Question: after a change (upgrade, patch, parameter, statistics, index, hardware, migration) will any of my SQL statements choose a worse plan or run slower?
  It runs (or explains) every statement of a saved SQL tuning set BEFORE and AFTER the change, compares the metrics statement by statement and ranks the regressions by their impact on the whole workload.
  It does not test concurrency, locking, memory pressure or capacity (that is Database Replay, section 6), and DML is only partly exercised. Use SPA first (cheap, per statement), Database Replay second (whole system).

### 10.2 The setup
  PRODUCTION (heavy workload)                  TEST DATABASE (clone of production, or production off-peak)
    1. collect the SQL into a tuning set  -->    2. bring the tuning set over
                                                 3. create the analysis task
                                                 4. trial 1 = BEFORE the change
                                                 5. APPLY THE CHANGE
                                                 6. trial 2 = AFTER the change
                                                 7. compare, read the report
                                                 8. fix the regressions, re-run trial 2
  Data requirement: no point-in-time restore is needed (statements run one by one with the bind values saved in the tuning set), but the system where SPA runs must be REPRESENTATIVE: same schema objects and indexes, similar data volume and distribution, production-like statistics and parameters before trial 1. Options: a full clone; a smaller copy with the production statistics imported (DBMS_STATS.EXPORT_SCHEMA_STATS / IMPORT_SCHEMA_STATS via a stats table; compare plans and buffer gets, not elapsed time); or production itself off-peak (no copy, but the statements really run and the change must be applied there, so rarely used).

### 10.3 Steps (documentation, not reproduced)
  1. PRODUCTION: build the tuning set from the heavy, representative statements.
       EXEC DBMS_SQLTUNE.CREATE_SQLSET(sqlset_name => 'PEAK_STS', description => 'peak week');
       -- from AWR (a busy period) ...
       DECLARE c DBMS_SQLTUNE.SQLSET_CURSOR;
       BEGIN
         OPEN c FOR SELECT VALUE(p) FROM TABLE(DBMS_SQLTUNE.SELECT_WORKLOAD_REPOSITORY(begin_snap => &b, end_snap => &e,
                    basic_filter => 'parsing_schema_name = ''APP'' AND elapsed_time > 100000')) p;
         DBMS_SQLTUNE.LOAD_SQLSET('PEAK_STS', c);
       END;
       /
       -- ... or from the cursor cache over time: DBMS_SQLTUNE.CAPTURE_CURSOR_CACHE_SQLSET(sqlset_name => 'PEAK_STS', time_limit => 3600, repeat_interval => 60);
       Check: SELECT name, statement_count FROM dba_sqlset;
     The set holds SQL text, bind values, plans, execution statistics, parsing schema and optimizer environment.
  2. Move it to the test system (skip if SPA runs on production):
       EXEC DBMS_SQLTUNE.CREATE_STGTAB_SQLSET(table_name => 'STS_STG');
       EXEC DBMS_SQLTUNE.PACK_STGTAB_SQLSET(sqlset_name => 'PEAK_STS', staging_table_name => 'STS_STG');
       -- export/import the table (Data Pump or a database link), then on the test system:
       EXEC DBMS_SQLTUNE.UNPACK_STGTAB_SQLSET(sqlset_name => 'PEAK_STS', replace => TRUE, staging_table_name => 'STS_STG');
  3. Create the task:
       VAR t VARCHAR2(100)
       EXEC :t := DBMS_SQLPA.CREATE_ANALYSIS_TASK(sqlset_name => 'PEAK_STS', task_name => 'UPG_TEST');
  4. Trial 1, BEFORE the change, in one of three modes:
       'TEST EXECUTE'   : really runs every statement (for DML only the query part by default) and records time, CPU, buffer gets, I/O
       'EXPLAIN PLAN'   : generates plans only (fast, no execution metrics)
       'CONVERT SQLSET' : takes the plans and metrics already stored in the tuning set (for example captured on the old database)
       EXEC DBMS_SQLPA.EXECUTE_ANALYSIS_TASK(task_name => 'UPG_TEST', execution_type => 'TEST EXECUTE', execution_name => 'before');
       Useful parameters (execution_params => DBMS_ADVISOR.ARGLIST(...)): 'TIME_LIMIT' (total), 'LOCAL_TIME_LIMIT' (per statement), 'EXECUTE_FULLDML' (default FALSE).
  5. Apply the change (upgrade, patch, parameter, statistics, index, move to the new system).
  6. Trial 2, AFTER the change: the same call with execution_name => 'after'.
  7. Compare:
       EXEC DBMS_SQLPA.EXECUTE_ANALYSIS_TASK(task_name => 'UPG_TEST', execution_type => 'COMPARE PERFORMANCE', execution_name => 'compare',
            execution_params => DBMS_ADVISOR.ARGLIST('execution_name1', 'before', 'execution_name2', 'after', 'comparison_metric', 'elapsed_time'));
       Metrics: elapsed_time, cpu_time, buffer_gets, disk_reads, optimizer_cost and others (check the list). Compare more than one: elapsed time is noisy on a test system, buffer gets and plans are stable.
  8. Report:
       SELECT DBMS_SQLPA.REPORT_ANALYSIS_TASK(task_name => 'UPG_TEST', type => 'HTML', level => 'REGRESSED', section => 'ALL') FROM dual;   -- HTML or TEXT; level: ALL, TYPICAL, REGRESSED, CHANGED, IMPROVED, UNCHANGED, CHANGED_PLANS, ERRORS  (call it from PL/SQL or SQL*Plus if the SELECT form fails)
  9. Fix the regressions:
       - load the good plans of the "before" trial as SQL plan baselines (section 2): DBMS_SPM.LOAD_PLANS_FROM_SQLSET with a filter on the regressed statements;
       - or tune the statement (profile, section 3; hint or patch, section 4; statistics; index);
       - then run trial 3 ('after_fix') and compare 'before' with 'after_fix'.

### 10.4 Reading the report
  Per statement: the metric before and after, the "Impact on Workload" (percent change of the whole workload's total, weighting by executions) and the "Impact on SQL" (percent change of that statement alone), whether the plan changed, and the plans side by side.
  Priorities: a big regression with many executions matters (large impact on workload); a 10x regression of a statement that runs once a month usually does not. Plan changed but the metric improved: leave it. Errors: statements that failed in a trial (missing object, privilege): fix the environment and re-run.
  Pass criteria to write down before you start (for example: no statement with more than 20 percent regression on buffer gets and more than 1 percent impact on the workload).
  Common mistakes: test system with different data or statistics; trial 1 run after the change; comparing elapsed time on a busy test machine; forgetting the bind values (the set must hold them); leaving DML out of the picture.

### 10.5 SPA compared with Database Replay
                        SPA                                  Database Replay
   unit                 one statement, executed alone        the recorded workload with its concurrency
   test data            representative                       restored to the capture start
   finds                plan and time regressions            concurrency, locking, capacity, errors, wrong results
   cost                 low                                  high
   order                first                                second

### 10.6 Mini-SPA by hand (lab 18, tested on 26ai Free)
  The same method without the RAT option: tuning set, BEFORE trial, change, AFTER trial, compare, fix, compare again. Files: lab/18_minispa_setup.sql (creates LAB.SPA_RESULT and the procedure LAB.RUN_TRIAL), lab/18_minispa_compare.sql, lab/18_minispa_lab.sh (setup | reset | drop).
  The workload: five statements on LAB.PROF_CUST / LAB.PROF_ORDERS (S1 order lookup by cust_id, S2 join on the correlated columns seg/tier/grp, S3 count by seg, S4 range on order_id, S5 join for one customer), run with bind variables by LAB.RUN_TRIAL('<trial name>'); each trial stores per statement: sql_id, plan hash, executions, elapsed and logical reads.
  Steps (as LAB unless noted):
     1. Trial BEFORE:         EXEC lab.run_trial('before')
     2. Tuning set (SYS):     EXEC DBMS_SQLTUNE.CREATE_SQLSET('MINI_STS');  then load it with DBMS_SQLTUNE.LOAD_SQLSET from DBMS_SQLTUNE.SELECT_CURSOR_CACHE(basic_filter => 'module = ''MINI_SPA'' AND parsing_schema_name = ''LAB''');
                              check: SELECT sql_id, plan_hash_value, executions, buffer_gets FROM dba_sqlset_statements WHERE sqlset_name = 'MINI_STS';   (sql_text is a CLOB: use DBMS_LOB.SUBSTR(sql_text, 70, 1), never ORDER BY it)
     3. The change (SYS):     ALTER INDEX lab.ix_prof_cust INVISIBLE;      (what a careless migration script could do)
     4. Trial AFTER:          EXEC lab.run_trial('after')
     5. Compare:              @18_minispa_compare.sql before after
     6. The fix (SYS):        ALTER INDEX lab.ix_prof_cust VISIBLE; plus extended statistics on PROF_CUST (SEG,TIER,GRP) for S2 (section 3.3)
     7. Trial AFTER_FIX:      EXEC lab.run_trial('after_fix');   @18_minispa_compare.sql before after_fix
  Results:
     before vs after:      S1 PLAN CHANGED 13 -> 21,466 gets REGRESSED; S5 PLAN CHANGED 6 -> 21,469 gets REGRESSED; S3 and S4 same plan, unchanged; S2 PLAN CHANGED 242,291 -> 22,864 gets IMPROVED (without the index the nested loops became a hash join).
     before vs after_fix:  S1, S3, S4, S5 back to the same plans and gets; S2 still IMPROVED (242,291 -> 22,865 gets, 397 -> 158 ms).
  Lessons:
     - One change gave regressions AND an improvement: read every statement, not only the average. Whether to keep an improvement is a decision (here the improvement of S2 came from fixing the real problem of S2, so we kept it with the right fix).
     - Base the verdict on buffer gets and the plan hash, show the times for information. S4 had the same plan and the same 14 gets but 0.1 -> 0.3 ms: noise, not a regression (my first verdict rule on elapsed time flagged it wrongly).
     - Measure inside the session (v$mystat 'session logical reads' and the clock). The first version took differences of v$sqlstats; when the change invalidates a cursor its cumulative statistics restart from zero and the differences became zero or negative.
     - The real SPA also fixes regressions with SQL plan baselines loaded from the tuning set (DBMS_SPM.LOAD_PLANS_FROM_SQLSET, section 2.3). Here the cause was an invisible index, so the old plan could not be reproduced anyway: remove the cause first. Not run in this lab.
  Cleanup: ./lab/18_minispa_lab.sh reset   (state back to the beginning)  or  drop   (also removes the objects and puts optimizer_adaptive_plans back to TRUE).

## 11. TRACE FILES: 10046 trace, tkprof, reading the raw file (lab 20, tested on 26ai Free)
  WHAT: a trace file is a diary the server process writes about ONE session: every parse, execute and fetch, with CPU, elapsed time, blocks read, rows and every wait. tkprof turns that diary into a per-statement summary. Use it when you need the exact cost of every call of one session (a batch job, a procedure, one app user), which AWR/ASH (sampled, all sessions) cannot give.

### 11.1 Where the file is (RAC: each instance has its own trace directory; the file is on the node where the session ran)
  SELECT inst_id, value FROM gv$diag_info WHERE name = 'Diag Trace';
  SELECT value FROM v$diag_info WHERE name = 'Default Trace File';      -- the file of MY session (v$ only: it is the current session, there is no gv$ version for "my session")
  SELECT p.inst_id, p.tracefile FROM gv$process p JOIN gv$session s ON s.inst_id = p.inst_id AND s.paddr = p.addr WHERE s.sid = &sid AND s.inst_id = &inst;   -- file of ANOTHER session

### 11.2 Switch tracing on and off
  Own session (needs the ALTER SESSION privilege: without it ORA-01031, found in the lab, grant with GRANT ALTER SESSION TO <user>):
     ALTER SESSION SET tracefile_identifier = 'MYTRACE';                       -- puts the word in the file name, easy to find
     ALTER SESSION SET events '10046 trace name context forever, level 8';    -- level 8 = SQL + waits (level 4 = + bind values, level 12 = both)
     ... run the work ...
     ALTER SESSION SET events '10046 trace name context off';
  Another session (DBA, no change to the application; RAC: the instance number matters):
     EXEC DBMS_MONITOR.SESSION_TRACE_ENABLE(session_id => &sid, serial_num => &serial, waits => TRUE, binds => FALSE);
     EXEC DBMS_MONITOR.SESSION_TRACE_DISABLE(session_id => &sid, serial_num => &serial);
     (on RAC run it on the instance of that session; find it with SELECT inst_id, sid, serial# FROM gv$session WHERE ...)

### 11.3 Read it with tkprof (on the database server, in the shell, not in SQL*Plus)
  tkprof <trace file> <output file> sys=no sort=exeela,fchela
     sys=no               hide Oracle's own recursive SQL
     sort=exeela,fchela   worst elapsed time first (execute + fetch)
  Lab: docker exec oracle-lab bash -c "cd /opt/oracle/diag/rdbms/free/FREE/trace; tkprof <file>.trc /tmp/out.txt sys=no sort=exeela,fchela"
  GOTCHA (lab 20): do NOT pick the file with "ls -t | head -1". A session that is still open, or just closed, keeps writing to its file, so an older trace can look newest. Use the exact name printed by v$diag_info (or the pid in the name). First check of every tkprof report: the "Trace file:" line at the top is the file you meant, and "elapsed seconds in trace file" is not 0.
  GOTCHA (lab 20): run the traced work in the schema that owns it (PLS-00201 for the procedure when connected as SYS). The trace of a failed call is almost empty (73 lines).

### 11.4 How to read a tkprof report (lab 20)
  Per statement block, in this order:
     1. Header: "Trace file:" is the right file? "elapsed seconds in trace file" > 0?  (see GOTCHA above)
     2. Sort order puts the biggest elapsed time first: read the FIRST block and the OVERALL TOTALS only, then the rest.
     3. Call table. count = how often; cpu vs elapsed (elapsed >> cpu = the session WAITED, look at the wait list under the table; elapsed ~ cpu = CPU/logical reads); query + current = blocks read from the buffer cache; disk = physical reads; rows = rows returned.
     4. Ratios (do the arithmetic, this is where the problem shows):  query / rows, query / count, count of Execute vs rows.  Few rows returned for very many blocks = a scan that does not fit the question.  Huge Execute count for a trivial statement = row-by-row (loop) processing.  Parse count close to Execute count = no cursor reuse (literals, section "parse storm" in the Wait Event playbook).
     5. "Row Source Operation": the plan that REALLY ran, with real rows (cr = blocks, time in us per step). Compare it with the estimate (card=) in the same line.
     6. "Elapsed times include waiting on" lists the waits of that statement; if its total is small the statement is not waiting.
     7. OVERALL TOTALS FOR ALL RECURSIVE STATEMENTS = the work done inside PL/SQL; NON-RECURSIVE = the calls the client sent.
  Case (lab 20, procedure LAB.TRC_MONTH_END, 1.6 s):  the first block was SELECT SUM(AMOUNT) FROM TRC_ORDERS WHERE CUST_ID = :B1  -  Execute 400, Fetch 400, cpu 1.50 s = 96% of the whole run, query 530,000, rows 400, plan TABLE ACCESS FULL (cr=1325 per execution, 750 rows used).  530,000 / 400 = 1,325 blocks (the whole table) to get ONE number per customer.  INSERT (0.03 s) and COMMIT (0.02 s), executed 400 times too, were NOT the problem: a high count is only a problem when each execution is expensive.  No waits: elapsed = cpu.  The bind name :B1 shows that the SQL sits inside PL/SQL.
  Lesson: the statement that is slowest per execution is not always the problem; multiply by count.  And the row source line shows WHAT it did, the call table shows HOW MUCH.
  Lab 20 step 3 (index on TRC_ORDERS(CUST_ID) added): NO change. Fetch still 400 calls, query 530,000, 1.5 to 1.8 s, plan still TABLE ACCESS FULL (the optimizer was right: see clustering factor).
     Check why an index is ignored (RAC: dba_indexes has no gv$ version, the data dictionary is shared):
        SELECT i.index_name, i.clustering_factor, t.blocks, t.num_rows FROM dba_indexes i JOIN dba_tables t ON t.owner = i.table_owner AND t.table_name = i.table_name WHERE i.table_owner = 'LAB' AND i.table_name = 'TRC_ORDERS';
     Reading: clustering factor near BLOCKS = rows of a key sit together (index good); near NUM_ROWS = rows of a key are scattered over the table (each index entry costs a different block). Lab: TRC_ORDERS_CUST clustering factor 300,000 (= num_rows) against 1,378 blocks: 750 index hits would cost ~750 table block visits against 1,325 for a full scan. Rows were inserted with cust_id = mod(n,400)+1, so every customer is in every block.
  Lab 20 step 4 (index on TRC_ORDERS(CUST_ID, AMOUNT), a covering index, tested by me): plan INDEX RANGE SCAN (cr=4 per execution, no table access), Fetch query 2,017 (was 530,000), cpu 0.02 s (was 1.50 s), whole job 1.6 s -> 0.07 s.  Rewriting the loop as one set-based INSERT ... SELECT ... GROUP BY was also tested: 1,337 gets in total, 0.04 s - the better fix when the code can be changed.
  Lesson: an index that the optimizer ignores is usually the optimizer being right. Look at the clustering factor, then consider an index that contains every column the query needs, or set-based SQL.
     Check clustering directly on the table, no index needed (lab 20: cust_id = 7 touches 750 table blocks for 750 rows; order_id 1 to 750 touches 4):
        SELECT COUNT(DISTINCT DBMS_ROWID.ROWID_BLOCK_NUMBER(ROWID)) AS table_blocks_touched FROM lab.trc_orders WHERE cust_id = &cust;
     Read the clustering factor of the RIGHT index: every index has its own value (the primary key on ORDER_ID was 1,304, good; the CUST_ID index 300,000, bad).
     Why the covering index worked although its clustering factor is also 300,000 (user question): the clustering factor only prices the jumps from index entry to TABLE block. With (CUST_ID, AMOUNT) the plan has no TABLE ACCESS BY INDEX ROWID line, so there are no jumps; the entries of one customer are adjacent inside the index itself (cr=4 per execution). Read the plan, not only the clustering factor.
     Cost of this fix: every insert/update of CUST_ID or AMOUNT also maintains the index, and it takes space. Worth it for a statement run 400 times per job, probably not for one run daily.

### 11.5 Reading the raw trace file (lab 20)
  Print the raw lines around one statement (shell, on the server; replace file name and sql_id):
     docker exec oracle-lab bash -c 'cd /opt/oracle/diag/rdbms/free/FREE/trace && n=$(grep -n -m1 "sqlid=.<sql_id>" <file>.trc | cut -d: -f1) && sed -n "$((n-1)),$((n+9))p" <file>.trc | cut -c1-230'
  Line types:  PARSING IN CURSOR #n (SQL text, sqlid, dep = recursion depth: 0 = sent by the client, 1 = inside PL/SQL, 2 = Oracle's own recursive SQL)  |  PARSE / EXEC / FETCH (the calls)  |  WAIT (a wait event inside a call)  |  STAT (real plan with real rows, written when the cursor closes)  |  CLOSE  |  BINDS (only with bind tracing, level 4 or 12).
  Fields (all times in MICROSECONDS):  c = cpu, e = elapsed, p = physical reads, cr = consistent reads (tkprof "query"), cu = current reads, mis = 1 hard parse (library cache miss), r = rows, dep, og = optimizer goal, plh = plan hash value, tim = timestamp.
  Lab 20 first execution of the loop SELECT: PARSE c=539 e=698 mis=1; EXEC c=821; FETCH c=3735 e=3709 cr=1325 r=1; one parse for 400 executions: PL/SQL keeps the cursor open and reuses it.
  How the raw lines add up to tkprof (lab 20): FETCH cr=1325 c=3735 us x 400 executions = 530,000 blocks and ~1.5 s = the tkprof line "Fetch 400 ... 1.50 ... 530000". e almost equal to c and no WAIT lines = no waiting, CPU/logical reads only.
  CLOSE ... type=3 does not drop the cursor: it keeps it in the session cursor cache (PL/SQL does this), so later executions show only EXEC and FETCH and mis=1 appears once. A PARSE line before every EXEC with mis=1 each time would mean a parse storm (literals).

### 11.6 Trace ANOTHER running session from outside (lab 20b, tested on 26ai Free)
  Use when: "the posting job is slow now", you must not change the code and cannot restart it. Files: lab/20_trace_other.sh (start [seconds] | stop | drop), sessions modules NIGHTLY_ADJUST and POSTING_JOB on LAB.TRC_ACCT.
  Steps (SYS; RAC: take inst_id from the first query and run the DBMS_MONITOR call so it reaches that session; the trace file is written on THAT node):
     1. Find the session:     SELECT inst_id, sid, serial#, username, module, status FROM gv$session WHERE username = '&user' AND type = 'USER' ORDER BY module;
        WHICH one is the slow one? status ACTIVE does not tell you. First the complaint (user, module, program), then what each session is doing now (event only counts when state = 'WAITING'):
                              SELECT inst_id, sid, serial#, module, state, event, wait_class, seconds_in_wait, sql_id FROM gv$session WHERE username = '&user' AND type = 'USER' ORDER BY module;
        or for an intermittent problem ASH: SELECT session_id, event, COUNT(*) FROM gv$active_session_history WHERE sample_time > SYSTIMESTAMP - INTERVAL '10' MINUTE AND user_id = (SELECT user_id FROM dba_users WHERE username = '&user') GROUP BY session_id, event ORDER BY 3 DESC;
        sids change on every start of the lab: always read them from the query, never reuse old ones.
     2. Switch trace on:      EXEC DBMS_MONITOR.SESSION_TRACE_ENABLE(session_id => &sid, serial_num => &serial, waits => TRUE, binds => TRUE);
     3. Find its trace file:  SELECT p.inst_id, p.tracefile FROM gv$process p JOIN gv$session s ON s.inst_id = p.inst_id AND s.paddr = p.addr WHERE s.sid = &sid AND s.serial# = &serial AND s.inst_id = &inst;
     4. Wait 30 to 60 s of normal activity, then switch it off (never forget this step: the file keeps growing):
                              EXEC DBMS_MONITOR.SESSION_TRACE_DISABLE(session_id => &sid, serial_num => &serial);
     5. tkprof the file (shell, section 11.3) and read it (11.4).
  Notes: only work done AFTER step 2 is traced. Cursors already open are fine (lab: Parse 0, the statements still appear). With a connection pool or shared server one session is not one user: trace by service/module/client id instead (DBMS_MONITOR.SERV_MOD_ACT_TRACE_ENABLE / CLIENT_ID_TRACE_ENABLE) and merge the files with trcsess (not yet covered).
  Lab result (tested by me): POSTING_JOB, 51 executions of the UPDATE in about 25 s: cpu 0.04 s, elapsed 10.93 s, 10 waits "enq: TX - row lock contention" of about 1 s each (total 9.89 s). The BINDS blocks of the raw file show the values: :B1 = 35, 36, 37 ...

### 11.7 Trace by end user / service / module across a connection pool, merge with trcsess (lab 20c)
  Problem: a pool reuses the same sessions for many users, so "trace session X" mixes people, and one user's work is spread over several sessions (RAC: several nodes). Trace the IDENTITY instead of the session. The application must set it (DBMS_SESSION.SET_IDENTIFIER for client id; module/action via DBMS_APPLICATION_INFO; service from the connect string).
  Files: lab/20_trcsess_lab.sh (start [seconds] | stop): 3 pool sessions, module WEBSHOP, users alice and bob in random turns; alice's request sums orders by customer (1,325 blocks, no index), bob's reads one order by primary key. start also drops the lab 20 indexes on TRC_ORDERS.
  Switch on / off (SYS; works for sessions that already exist; the identity is checked at every call):
     EXEC DBMS_MONITOR.CLIENT_ID_TRACE_ENABLE(client_id => '&client', waits => TRUE, binds => FALSE);
     EXEC DBMS_MONITOR.CLIENT_ID_TRACE_DISABLE(client_id => '&client');
     EXEC DBMS_MONITOR.SERV_MOD_ACT_TRACE_ENABLE(service_name => '&service', module_name => '&module', action_name => DBMS_MONITOR.ALL_ACTIONS, waits => TRUE, binds => FALSE, instance_name => NULL);   -- by service/module/action; instance_name => 'X' limits it to one RAC instance, NULL = all
     EXEC DBMS_MONITOR.SERV_MOD_ACT_TRACE_DISABLE(service_name => '&service', module_name => '&module');
     SELECT trace_type, primary_id, qualifier_id1, qualifier_id2, waits, binds, instance_name FROM dba_enabled_traces;      -- what is switched on right now; empty = nothing forgotten
     (do not use DBMS_MONITOR.DATABASE_TRACE_ENABLE on a busy system: it traces every session)
  What you get: one trace file per pool session, each containing ONLY the marked identity ("*** CLIENT ID:(alice)" lines appear before every traced call; lab: 0 "bob" markers). Find them: ls -lt in the trace directory (RAC: on every node), or the file names modified after the enable.
  Merge with trcsess (shell, on the server), then tkprof the merged file:
     trcsess output=/tmp/merged.trc clientid=&client <trace files, e.g. *.trc>
        other selectors: service=<name>  module=<name>  action=<name>  session=<sid.serial#.. as printed in the file>
     tkprof /tmp/merged.trc /tmp/merged.txt sys=no sort=exeela,fchela
     RAC: copy the files of all nodes into one directory first (trcsess reads files, not instances).
  NOT TESTED HERE: trcsess does not run in the lab image (the script has an unfilled JDK_HOME=%s_jdkLocation%, the JDK and trcsess.jar are missing in the Free container). The syntax above is from Oracle's documentation. Without it, run tkprof on each file and add the counts by hand (lab: 3 files, 45 + 41 + 46 executions of the same statement).
  Lab result (tested by me): 20 s of client-id tracing for alice: 3 files, 41 to 46 executions each of SELECT SUM(AMOUNT) ... WHERE CUST_ID = :B1, 1,325 blocks per execution (59,625 / 45), about 9 ms each; no bob statement in any file.
  Pitfalls: the identifier can be blank when you look (the lab clears it after each request: a gv$session snapshot showed an empty client_identifier although the pool serves alice and bob all the time); a session that never sets the identifier cannot be selected this way; forgetting DISABLE (check dba_enabled_traces); trace files from all nodes.
  Lab 20c user result (tracing alice 30 s, 3 pool sessions, 3 files): executions 74 + 64 + 73 = 211 of SELECT SUM(AMOUNT) ... WHERE CUST_ID = :B1; query 98,050 + 84,800 + 96,725 = 279,575 blocks = 1,325 per execution (full scan every time); cpu 0.76 + 0.64 + 0.76 = 2.16 s, about 10 ms per request. Fix: covering index TRC_ORDERS(CUST_ID, AMOUNT), verified by tracing the same client id again and comparing blocks per execution.
  Find the files of a pool trace without "ls -t" (see GOTCHA in 11.4): find . -name "FREE_ora_*.trc" -mmin -3 -size +5k      (written in the last 3 minutes, bigger than a few KB, which leaves out your own tiny SYS session file)
  GOTCHA (lab 20c): a trace file belongs to the SERVER PROCESS, not to the trace run. Switching tracing off and on again for the same session or client id APPENDS to the same file (lab: the same 3 pool files held the run at 23:23 and the run at 23:29, markers six minutes apart), so a tkprof of it adds the "before" and "after" runs together. For a clean second run: new sessions (restart the pool/job), or a session that starts with ALTER SESSION SET tracefile_identifier before tracing (own session), or note the timestamps. Check before comparing: grep "CLIENT ID" <file> | sed -n '1p;$p' shows the first and last time in the file; find the files with: find . -name "FREE_ora_*.trc" -mmin -3 -size +5k.

### 11.8 Trace topic: status and cleanup (lab 20, closed 2026-10-28)
  Covered: own-session trace, tkprof and how to read it, raw trace lines, trace of another session (DBMS_MONITOR), trace by client id across a pool. Reading summary: count x cost per execution, cpu versus elapsed, wait list, Row Source Operation.
  Tested by me but NOT run by the user: the "after" trace of the pool with the covering index (expected about 5 blocks per execution instead of 1,325), the bind values check of lab 20b (step 5).
  NOT covered / not testable here: trcsess (does not run in the lab image), 10053 optimizer trace, level 4/12 bind analysis in depth, ORADEBUG, SQL_TRACE parameter, tracing with DBMS_SESSION.SET_SQL_TRACE, trace from Oracle Net / listener.
  Cleanup (Mac terminal): ./lab/20_trace_other.sh drop    ./lab/20_trace_lab.sh drop      (pool: ./lab/20_trcsess_lab.sh stop). Old .trc files stay in the trace directory: ADR purges them by age, or delete them in the container.
