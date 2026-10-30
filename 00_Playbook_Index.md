# Playbook index: which file do I open?

Pick by **your situation**, not by the tool.

| Your situation | Open this | Status |
|---|---|---|
| **Not sure which tool to use** (SQL Baseline, Profile, Patch, SPA, SQLTRPT, SQLT, ADDM, Database Replay, SQLHC, SQL Monitor, AWR/ASH, ...) | `Oracle_Tool_Selection_Playbook.sql` (symptom -> first tool, decision path, one entry per tool) | done |
| Sessions are slow or waiting **right now**: locks, I/O, hot blocks, parse storm, commits | `Oracle_Wait_Event_Playbook.sql` (live troubleshooting; section 13 is the wait-event cheat sheet) | done |
| You have an **ORA- error or a log message** (alert log, listener log, trace, RMAN) | `Oracle_ORA_Error_Playbook.sql` | started: log locations, alert-log queries, 10 entries |
| It **was** slow earlier ("3 hours ago", "last night"): AWR, ASH, ADDM, compare periods | `Oracle_Historical_Analysis_Playbook.sql` | started: workflow, AWR/ASH/ADDM/compare-periods queries, gotchas, worked case (lab 14) |
| You **know the SQL** and need to control or fix its plan: SQL plan baseline, SQL profile, SQL hint, SQL Monitor, plan regression | `Oracle_SQL_Tuning_Playbook.sql` | done: baseline (2), profile (3), hints and SQL patch (4), SQL Monitor (5), Real Application Testing: Database Replay (6, documentation only), SQL health check / SQLHC (7), trace files, tkprof, trace of another session and by client id (11, lab 20, done) |
| One query is slow and you want a quick runbook | `Slow_SQL_Troubleshooting.sql` | older runbook, partly superseded by the playbooks |
| Docker/Colima lab: start, stop, connect, logs | `Docker_Oracle_Lab_Guide.md` | done |

Lab scripts and walkthroughs are in `lab/` (`01_...` to `16_...`, plus `awr_report.sh`, `run_sqlhc.sh`). Each playbook says which lab each entry came from.

Quick decision tree
1. Is something broken *now*? -> wait-event playbook, section 2 first.
2. Do you have an error code or log text? -> ORA/log playbook, section 1 (workflow) and the entry for the code.
3. Is the problem in the past? -> historical playbook (AWR/ASH).
4. Is the problem one SQL whose plan changed or is wrong? -> SQL tuning playbook (decision guide at the top).

Conventions in every playbook: RAC-ready queries (`gv$`, `inst_id`); when a view has no `gv$` version it is said explicitly; PDB versus `CDB$ROOT` visibility is noted where it matters; anything not reproduced in the lab is marked "(not reproduced)".
