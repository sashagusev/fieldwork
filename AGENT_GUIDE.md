# Working in a Fieldwork research workspace

Use the `fieldwork` CLI to read and update the research CSVs. Supply `--workspace` on every command except `init`. Supply a stable `--actor` when claiming and completing tasks. Do not rewrite shared CSVs while another writer is active.

## Find and claim work

```sh
fieldwork ready --workspace /path/to/research
fieldwork show T-123 --workspace /path/to/research
fieldwork start T-123 --actor researcher-a --workspace /path/to/research
```

`ready` returns JSON containing the next actionable step in each question. Check each record’s kind. Tasks can be claimed; answers and conclusions require synthesis. A successful `start` atomically claims a task and creates its run. If another agent claims it first, the command fails. Choose another question rather than running a second task within the same question.

## Perform research and record outputs

Write actual research outputs using your normal tools. Store artifacts inside the workspace when practical. Then record a result:

```sh
fieldwork result T-123 \
  --title "Replication comparison" \
  --summary "The improvement reproduced on the independent evaluation set." \
  --details-file /path/to/detailed-summary.txt \
  --results artifacts/replication/metrics.csv \
  --actor researcher-a \
  --workspace /path/to/research
```

The result command returns its new ID and assigns its source run. Use that returned ID to record structured evidence:

```sh
fieldwork metric R-RETURNED-ID gain_pp 6.8 --workspace /path/to/research
fieldwork edit R-RETURNED-ID --status accepted --workspace /path/to/research
fieldwork complete T-123 --actor researcher-a --workspace /path/to/research
```

Mark a result accepted only after performing the appropriate review. A task cannot complete successfully without a result from its current attempt. If execution fails:

```sh
fieldwork fail T-123 --actor researcher-a \
  --reason "The source dataset was unavailable; no evaluation was completed." \
  --workspace /path/to/research
```

The failed task remains at the current position and can be retried with a new run. Previous attempts and results are preserved.

## Checklist status and ratings

The app shows every question and step as a checklist row: staged (dashed circle), working (filled circle), or done (checked circle). The workflow commands above move tasks through these states with full provenance. For a question, or for lightweight work that does not need runs and results, set the state directly:

```sh
fieldwork status Q-123 working --actor researcher-a --workspace /path/to/research
fieldwork status Q-123 done --actor researcher-a --workspace /path/to/research
```

This is the same explicit override as clicking the bullet in the app: it is recorded in `manual_status.csv` and `events.csv` and exempts the record from workflow checks. Prefer `start`, `result`, and `complete` for tasks whose evidence matters.

People rate finished work with a thumb beside the bullet. Read ratings before planning follow-up work; a thumbs down on a done question usually means it needs another look.

```sh
fieldwork ratings --workspace /path/to/research
fieldwork rate Q-123 up --workspace /path/to/research
```

`ratings` prints a JSON object of node ID to `up` or `down`; unrated records are neutral and absent. `rate` accepts `up`, `down`, or `neutral`. Leave rating to the human unless asked to review.

## Define a question and sequential workflow

```sh
fieldwork add aim --title "Reliable retrieval" --workspace /path/to/research
fieldwork add question --parent AIM-RETURNED-ID --title "Does reranking help?" \
  --summary "Compare reranked retrieval with a baseline." --workspace /path/to/research
fieldwork add task --parent Q-RETURNED-ID --order 10 --title "Run pilot" --workspace /path/to/research
fieldwork add task --parent Q-RETURNED-ID --order 20 --title "Run replication" --workspace /path/to/research
fieldwork add answer --parent Q-RETURNED-ID --order 30 --title "Synthesize evidence" --workspace /path/to/research
fieldwork add conclusion --parent Q-RETURNED-ID --order 40 --title "Conclude" --workspace /path/to/research
fieldwork move T-REPLICATION-ID --before T-PILOT-ID --workspace /path/to/research
```

Use the actual IDs returned by each command. A new question leads its aim’s list unless you pass `--order`; the person arranging the list can drag it elsewhere. Positions must be unique within a question. `move` takes `--before ID`, `--after ID`, or `--last` and renumbers the question’s steps; moving a finished step below an unfinished one keeps its state as an explicit override. New steps must follow work that has already started.

Every node supports the same content flags:

```text
--title TEXT
--summary TEXT
--details TEXT          or --details-file PATH
--results FILE_OR_FOLDER
```

Use an accurate short summary; reserve method details, evidence, and limitations for the detailed summary. A missing results path is preferable to an invented result.

## Link and synthesize evidence

```sh
fieldwork link Q-NEW-ID Q-PRIOR-ID inspired_by --workspace /path/to/research
fieldwork link ANS-ID R-ID supports --workspace /path/to/research
fieldwork link ANS-ID R-OTHER-ID contradicts --workspace /path/to/research
fieldwork edit ANS-ID --summary "A qualified answer." --details-file answer.txt --workspace /path/to/research
fieldwork complete ANS-ID --workspace /path/to/research
```

In `supports` and `contradicts` links, the source is the answer or other claim being evaluated and the target is the evidence record. Inspiration links record provenance; they do not block execution. Complete a conclusion only after the preceding workflow is finished and both summaries are written.

Use `fieldwork validate --workspace /path/to/research` to check the workspace after importing or editing files. The app automatically reloads valid CSV changes.
