// Generated from AGENT_FILE_GUIDE.md by scripts/embed-guide.py. Edit the Markdown file, not this one.
public enum AgentGuide {
    public static let filename = "AGENT_FILE_GUIDE.md"
    public static let text = #"""
# Populating a Fieldwork workspace by writing its files

You are adding research work to a Fieldwork workspace. Fieldwork is a macOS checklist app whose only data store is a folder of CSV files. There is no database and no API: whatever you write into the CSVs is what the app shows, and it re-reads the folder every two seconds while open. Write valid files and your entries appear on their own.

## The model

```text
AIM                       a line of work
  QUESTION                something to find out; the unit of parallel work
    TASK → RESULT(s)      a step, and what it produced
    ANSWER                what the evidence says
    CONCLUSION            what was decided; always the last step(s)
```

Every record is a row in the CSV for its kind. Questions belong to an aim, steps (tasks, answers, conclusions) belong to a question, results belong to a task. Within a question the steps run in `order`; the first unfinished step is the one to do next. Conclusions are always last in a question.

The app shows each question and step as a checklist bullet: **staged** (dashed circle), **working** (filled), **done** (checked). A person can rate finished work with a thumb, which you will see in `ratings.csv`.

## Files

All files live in the workspace folder. Every entity file has the same header, in this order:

```text
id,parent_id,order,title,short_summary,detailed_summary,results_path,status,created_at,updated_at,started_at,finished_at,agent_id,run_id
```

| File | Rows |
| --- | --- |
| `workspace.csv` | Exactly one row: `schema_version,name` → `1,<name>` |
| `aims.csv` | Aims. `parent_id` empty. `order` sets the list order (10, 20, 30…). Status `active`, or `complete` for a finished aim (shown under a “Completed” divider). |
| `questions.csv` | Questions. `parent_id` is an aim ID. Lower `order` is higher in the list. Status `active`, or `complete`. |
| `tasks.csv` | Tasks. `parent_id` is a question ID. Status `planned`, `running`, `complete`, `failed`, or `skipped`. |
| `answers.csv`, `conclusions.csv` | Same columns. Status `planned`, `complete`, or `skipped`. |
| `results.csv` | Results. `parent_id` is a task ID. Status `planned` (expected output) or `recorded`, `accepted`, `rejected` (actual output; see runs). |
| `runs.csv` | `id,task_id,agent_id,started_at,finished_at,status,note`. One row per attempt at a task; status `running`, `complete`, or `failed`. |
| `metrics.csv` | `result_id,key,value`. Numbers or text attached to a result. `status` is not allowed as a key. |
| `links.csv` | `id,source_id,target_id,relation`. Relation is `inspired_by` (question → question), `supports`, `contradicts`, `related`, or `supersedes`. |
| `manual_status.csv` | `node_id`. Records whose status was set directly rather than through the run/result workflow. See below. |
| `ratings.csv` | `node_id,rating`. `up` or `down`; absent means neutral. Written by people. Read it; do not write it unless asked. |
| `events.csv` | `id,time,actor,action,node_id,detail`. Append-only audit log. Append one row per change you make; never edit earlier rows. |

Rules for every row:

- `id` is any string unique across all files. Conventions: `AIM-…`, `Q-…`, `T-…`, `R-…`, `ANS-…`, `C-…`, `RUN-…`. Use short readable slugs or random suffixes; never reuse an ID.
- `order` is an integer, unique among a question’s steps (and among an aim’s questions). Leave gaps (10, 20, 30) so things can be inserted.
- `title` is required. `short_summary` is one or two sentences; `detailed_summary` may be long and may contain Markdown and newlines. `results_path` is a file or folder relative to the workspace, or blank; never invent a path that has no file behind it.
- `created_at` and `updated_at` are required ISO 8601 timestamps with a UTC offset, e.g. `2026-09-27T14:03:00Z`. `started_at`, `finished_at`, `agent_id`, and `run_id` may be empty.
- Standard CSV quoting: wrap a field in double quotes if it contains a comma, a quote, or a newline, and double any quotes inside it. UTF-8. LF or CRLF line endings both work.
- Do not add, remove, or rename columns. A file with unexpected columns is rejected.

## Two ways to record status

**Simple (checklist) way.** Set `status` directly and add the record’s `id` to `manual_status.csv`. That row means “this status was set by hand; do not check it against runs and results.” Use `planned` for staged, `running` for working, `complete` for done. This is what the app itself does when someone clicks a bullet, and it is the right choice when you are entering a plan or a summary of work done elsewhere. A `manual_status.csv` row is needed for a `planned`, `running`, or `complete` status set by hand, and for a `recorded` result that has no run behind it in `runs.csv`. An `active` aim or question needs none (a row for one is harmless).

**Evidence way.** If you want a task’s completion to carry provenance:

1. Add a row to `runs.csv` with status `running`, `started_at` set, `finished_at` empty; set the task’s status to `running`, its `agent_id`, and `started_at`.
2. Add one or more rows to `results.csv` with status `recorded` (or `accepted`/`rejected` after review) and `run_id` set to that run.
3. Finish: set the run’s status to `complete` and `finished_at`; set the task’s status to `complete` and `finished_at`.

Without a `manual_status.csv` entry, these are enforced: a `running` task has exactly one `running` run; a `complete` task has a `complete` run and at least one result from it; a result with status `recorded`/`accepted`/`rejected` has a valid `run_id` for its parent task; a question has at most one running task; a `complete` step never follows an unfinished step in its question; a question is `complete` only when it has a completed answer and every step is finished; attempts within a question do not overlap in time.

If in doubt, use the simple way. It is always valid.

## Placing new entries

- New questions go at the **top** of their aim’s list: use an `order` lower than the existing minimum (e.g. existing 10, 20 → use 0, then −10).
- New tasks and answers go at the end of the question’s steps but **before its conclusions**; conclusions keep the highest orders.
- New aims go at the end of the active aims: `order` higher than the existing maximum.
- To reorder, renumber `order` values; nothing else needs to change.

## Writing safely

- The app takes a lock (`.fieldwork.lock`) while it writes and stages its own writes in `.fieldwork-pending/`. Do not touch either. Write each file completely and atomically (write to a temporary file in the same folder, then rename over the target), and do not leave a file half-written between rows.
- If you are adding a batch, write the files in dependency order: aims, questions, tasks, runs, results, then the rest, so that a reader in between sees no orphans.
- Append to `events.csv` for each change: `id` unique, `time` now, `actor` your name, `action` a short verb such as `create`, `set_status`, `edit`, `node_id` the record touched, `detail` a phrase.
- After writing, check with `fieldwork validate --workspace <folder>` if the `fieldwork` binary is available. If the folder is invalid, the app keeps showing the last valid state with a “CSV changes need attention” banner and the reason; fix the file and it recovers by itself.
- Do not delete rows from `events.csv`, and do not remove other people’s or agents’ records unless asked. Deleting a record means removing it and everything under it (a question’s steps and their results, a task’s results) from every file, including `manual_status.csv`, `ratings.csv`, `links.csv`, `metrics.csv`, and `runs.csv`.

## Example: adding a planned question with three tasks

`questions.csv` (existing questions have orders 10 and 20):

```text
Q-cohort-dropout,AIM-robustness,0,Does dropping any one cohort change the leaderboard?,Leave-one-cohort-out over the current leaderboard.,"Re-run the leaderboard with each cohort held out in turn. Report rank changes for the top ten methods and flag any that depend on a single cohort.",,active,2026-09-27T14:03:00Z,2026-09-27T14:03:00Z,,,,
```

`tasks.csv`:

```text
T-cohort-dropout-1,Q-cohort-dropout,10,Enumerate cohorts and freeze the method list,Ten cohorts; forty-two methods frozen.,,,planned,2026-09-27T14:03:00Z,2026-09-27T14:03:00Z,,,,
T-cohort-dropout-2,Q-cohort-dropout,20,Run leave-one-out leaderboards,,,,planned,2026-09-27T14:03:00Z,2026-09-27T14:03:00Z,,,,
T-cohort-dropout-3,Q-cohort-dropout,30,Summarise rank changes,,,,planned,2026-09-27T14:03:00Z,2026-09-27T14:03:00Z,,,,
```

`answers.csv` and `conclusions.csv`:

```text
ANS-cohort-dropout,Q-cohort-dropout,40,What the leave-one-out runs show,,,,planned,2026-09-27T14:03:00Z,2026-09-27T14:03:00Z,,,,
C-cohort-dropout,Q-cohort-dropout,50,Decide whether cohort dependence needs fixing,,,,planned,2026-09-27T14:03:00Z,2026-09-27T14:03:00Z,,,,
```

`events.csv` (appended):

```text
evt-7f3a,2026-09-27T14:03:00Z,planner-agent,create,Q-cohort-dropout,Planned question with three tasks
```

To mark the first task done the simple way later: set its status to `complete` and `finished_at`, add `T-cohort-dropout-1` to `manual_status.csv`, bump `updated_at`, and append an event.

"""#
}
