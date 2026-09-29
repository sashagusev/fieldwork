# Fieldwork

A native macOS research workspace for humans and AI agents. SwiftUI provides a white, minimalist checklist interface; CSV files are the authoritative research records. The app and agent CLI share the same validation, persistence, and workflow engine.

## Run

Requires macOS 14 or later. There are no third-party runtime dependencies or network services.

```sh
./scripts/build-app.sh
open dist/Fieldwork.app
```

The build produces `dist/Fieldwork.app` and the standalone agent command `dist/fieldwork`. The app bundle also contains the CLI at `Contents/MacOS/fieldwork-cli`. It is signed locally for use on this machine; distribution to other users would require your own Developer ID signing and notarization.

Every new workspace, whether created in the app or with `fieldwork init`, contains a copy of `AGENT_FILE_GUIDE.md` so an agent pointed at the folder knows how to add to it. The copy is generated from the repository’s Markdown at build time.

On first launch, Fieldwork creates a **synthetic example workspace** at:

```text
~/Library/Application Support/Fieldwork/Example Research/
```

Use **File → New Workspace** for your own research or **File → Open Workspace** to open a CSV workspace created by an agent; the open panel starts beside the current workspace. **File → Open Recent** and the toolbar folder menu list the last ten workspaces, and the last opened one reopens at launch. You can also launch the executable with `--workspace /absolute/path`.

## Interface

The window is a minimalist checklist: small plain rows on a white window, a lot of empty space, no cards. Every row is two lines tall; longer titles truncate, and the full title shows on hover and in the detail panel. The lists take the left 60% of the window and the detail panel the right 40%. Two list columns fit at a time: aims and questions to begin with, and opening a question slides the view over to questions and steps. Close the question or click **‹ Aims** to slide back.

- **Aims** is a list with progress-pie bullets. Click an aim to show its **Questions** in a column to the right; click a question to show its **Steps** (tasks, answers, and conclusions, with results indented beneath their task) in a third column. Click an open aim or question again to close it. Each aim’s bullet is a small pie that fills as its questions are done; hover over it for the count.
- Every question, step, and result has a status bullet. A dashed circle is **staged**, a filled circle is **working**, and a checked circle is **done** (the title dims). Click the bullet to advance staged → working → done; a further click returns it to staged, so a misclick is easy to undo. Clicking a bullet never changes the selection. A question nobody has set by hand shows as working once any of its steps has started. Failed, held, and skipped steps show a cross, pause, or dash.
- Hover over a done row’s bullet and a thumb slides out to its left. Click it to cycle **neutral → thumbs up → thumbs down → neutral**. Thumbs up washes the row light green and thumbs down light red, so ratings read at a glance without any extra icons. Ratings are stored in `ratings.csv`, only show while the row is done, and survive a trip through the status cycle.
- Bullet clicks are explicit overrides, the same as **Mark Staged**, **Mark Working**, and **Mark Done** in the right-click menu. Done is stored as `complete`, working as `running`, and staged as `planned`; `manual_status.csv` tracks records exempted from normal workflow checks, and `events.csv` records each override. Status clicks preserve summaries and output files; they do not create findings. Marking a running task done closes its existing attempt; returning it to staged clears its execution timestamps and closes any active attempt as stopped, keeping its history. Ordinary agent commands still enforce their workflow requirements.
- The Questions column opens with a **New question** field: type a title and press Return to add it at the top of the list, as many in a row as you like, without moving the selection. The pencil beside it opens the full editor, prefilled with what you typed, for a summary and details. New questions always lead the list, including ones agents add with the CLI. A quiet **+ New aim** row ends the active aims, and steps read top to bottom in execution order. **+ New task** and **+ New conclusion** append to their sections of the question’s workflow. The toolbar’s **+** menu can create any record type.
- Drag an aim up or down to reorder it. Finished aims sit under a **Completed** divider: drag an aim below it to complete it, or back above it to reopen it; the divider appears as a target whenever an aim is being dragged. **Mark Done** files an aim there too. The arrangement is stored in each aim’s `order` column.
- Conclusions sit in their own section under a **Conclusions** divider at the bottom of the Steps column, and are always the last steps in order, however a step is numbered or moved. Drag a step up or down within its section to reorder it; results travel with their task. Steps run in the order shown, so the first unfinished step is the one agents pick up next. Dragging a finished step below an unfinished one keeps its state as an explicit override, the same as a bullet click, rather than refusing the move.
- Drag a question up or down to reorder it; its neighbours slide apart to show where it will land, and dropping it back where it started changes nothing. Drop it on an aim to move its whole workflow there; the view follows it to that aim without opening it, and a reorder leaves the selection alone. Releasing outside a destination or pressing Escape cancels the move.
- The detail panel shows the selected row’s kind, ID, state, title, short summary, and detailed summary, rendering Markdown including headings, emphasis, links, lists, quotes, code blocks, and tables. Click **Edit**, right-click a row, or use **⌘E** to open the full editor for its fields, results path, or metrics. Task execution, completion, result creation, and deletion are in the right-click menu.
- **Mark Complete…** records a task completion note, which becomes an explicitly labeled user completion result when its attempt has no output. Earlier workflow steps still apply.
- The title bar shows the workspace name on the left and, on the right, the **Aims**, **Timeline**, and **Graph** views beside the folder and + menus.
- **Timeline** lists every record in creation order, newest first, with its creation date. Edits, status changes, and question moves keep the original chronological position. The same bullets, ratings, and menus work here. Click a row to read it, or double-click to show it among the aims.
- **Graph** draws the workspace as a spring graph: each aim is a large node, its questions are medium nodes sprung to it, and each question’s steps are small nodes sprung to the question. Finished work rated thumbs up is green and thumbs down is red; everything else is grey by progress (filled grey done, black working, hollow staged), with a legend along the bottom. Aims are always labelled with their title; hover over any node for its title, kind, and state; click to select it (a soft halo marks the selection) and read it in the detail panel; double-click to show it among the aims; drag a node to pull the graph around. Whole subgraphs repel each other as discs, so each aim’s subgraph stands apart as one piece with its aim at the centre, and a large subgraph cannot crush a small neighbour. The layout is seeded from record IDs, so the same workspace always opens to the same picture, and new records appear beside their parent without reshuffling the rest.
- Right-click any row and choose **Delete [type]**. Descendants are included: deleting a task includes its results, and deleting an aim or question includes its workflow. Result files and audit history remain. **Research → Undo Delete [type]** restores the last deletion during the current workspace session, including ratings and manual statuses. CSV backups remain in `.fieldwork-trash/`. To remove a completed task’s last supporting result, mark the task working first or delete the task together with its results. Undo preserves unrelated agent changes.
- CSV changes are checked every two seconds, so rows an agent adds, completes, or rates appear on their own. Invalid changes display a retry banner while the last valid workspace remains visible. All writes reload the latest data while holding the writer lock.

Keyboard shortcuts: **⌘1** Aims, **⌘2** Timeline, **⌘3** Graph, **⌘E** edit selection, **⌘N** new question, **⇧⌘T** new task, **⌘O** open workspace, **⇧⌘N** new workspace, **⌘R** reload.

## Research model

```text
AIM
  QUESTION — may be inspired by another question
    TASK 1 → RESULT(s), each linked to a source RUN
    TASK 2 → RESULT(s)
    TASK 3 → RESULT(s)
    ANSWER(s)
    CONCLUSION
```

**A question is the unit of parallel work.** Its workflow consists of tasks, answers, and conclusions with unique integer `order` positions, and steps can be reordered at any time by dragging in the app or with `fieldwork move`. Only the first nonterminal step is ready. A task must be claimed before execution, and a successful attempt must produce at least one result associated with that attempt. Failed attempts can be retried without reusing an earlier attempt’s results.

Record types and parent relationships are fixed after creation to preserve workflow history. Add follow-up questions or later steps for new research.

## CSV layout

| File | Purpose |
| --- | --- |
| `workspace.csv` | Schema version and workspace name |
| `aims.csv`, `questions.csv` | Research organization |
| `tasks.csv`, `answers.csv`, `conclusions.csv` | Ordered workflow steps |
| `results.csv` | Findings, review status, artifact references, and source run IDs |
| `runs.csv` | Task claims, attempt owners, execution times, and failure notes |
| `metrics.csv` | Result measurement key/value pairs |
| `links.csv` | `inspired_by`, `supports`, `contradicts`, `related`, `supersedes` |
| `manual_status.csv` | Records with explicit Planned/Running/Done workflow overrides; one `node_id` per row, optional in older workspaces |
| `ratings.csv` | Thumbs ratings of finished work: `node_id`, `rating` (`up` or `down`; no row means neutral); optional in older workspaces |
| `events.csv` | Append-only audit events for application and CLI mutations |

Each entity CSV has these columns:

```text
id,parent_id,order,title,short_summary,detailed_summary,results_path,status,
created_at,updated_at,started_at,finished_at,agent_id,run_id
```

The physical header is one CSV row. Multiline summaries, Unicode, commas, and quotes are supported. Header order may vary, but missing or unknown columns are rejected rather than silently dropped. Timestamps use ISO 8601 with UTC offsets; generated timestamps use UTC with fractional seconds.

Results paths can point to a file or a directory. Relative paths resolve against the workspace root; absolute paths are also supported. Blank means no output linked. Missing files are displayed as expected paths. Fieldwork does not fabricate a results file simply because its path is populated.

Results from an actual attempt have `recorded`, `accepted`, or `rejected` status and a valid `run_id`. A `planned` result is an expected-output placeholder. The CLI assigns the latest source run automatically when recording a result. `Ready` and `Blocked` are derived interface states, not stored task statuses.

Writes are serialized using `.fieldwork.lock`. A write stages only the tables that changed in `.fieldwork-pending` before publication, and interrupted committed transactions are recovered on the next open. `events.csv` is append-only: new rows are added at the end rather than rewriting the log, recovery truncates to the pre-write length first so a repeated recovery cannot duplicate rows, and a running app parses only the rows added since it last looked. Together with a byte-level CSV parser this keeps a click to a few milliseconds on workspaces with hundreds of records and thousands of events. Agents should use the CLI for mutations. Direct file edits are supported, but bypass locking, audit events, and application transition checks; coordinate those edits with other writers, and append to `events.csv` rather than editing earlier rows.

## Agent interface

See [AGENT_GUIDE.md](AGENT_GUIDE.md) for a complete CLI example, and [AGENT_FILE_GUIDE.md](AGENT_FILE_GUIDE.md) for a prompt that lets an agent populate a workspace by writing the CSV files directly. The CLI manages records and workflow state; it does not launch an LLM or perform research itself. Agents perform their work through their existing tools, then record evidence using the CLI.

```sh
dist/fieldwork init /path/to/research --name "My Research"
dist/fieldwork ready --workspace /path/to/research
dist/fieldwork validate --workspace /path/to/research
dist/fieldwork --help
```

## Build and test

```sh
./scripts/swift.sh build
./scripts/test.sh
./scripts/build-app.sh release
```

`scripts/test.sh` runs the Swift core test cases with a small assertion runner that works with Command Line Tools, separate-process CLI integration tests, and app-level checks for editor saves, list expansion, status and rating cycles, navigation, stable selection, completion, deletion/undo, question dragging, and appending workflow records. A native mouse-event check also clicks real status bullets and rating thumbs, drags steps, questions, and aims, and uses the add row in an offscreen window. Coverage includes CSV quoting and multiline content, persistence, workflow sequencing, step reordering, result provenance, retries, stale editors, transaction recovery, direct CSV edits, historical overlap, concurrent task claims, deletion recovery, ratings, and user-reported completion.

With a complete Xcode installation, the Swift cases can also run using `swift test`. The assertion runner exists because Command Line Tools installations do not necessarily include XCTest.

The build wrapper detects two known stale-file problems in mixed Command Line Tools installations: old private PackageDescription interfaces and duplicate SwiftBridging module maps. It uses a private copy and a compiler filesystem overlay under `.build`; it never edits the installed SDK or system toolchain.

## Source organization

- `Sources/ResearchCore`: CSV codec, records, validation, workflow, transactional repository, synthetic example.
- `Sources/Fieldwork`: native SwiftUI app: checklist columns, chronological timeline, spring graph, detail panel, and record editors.
- `Sources/FieldworkCLI`: agent-oriented command-line interface.
- `Tests`: core scenarios and a standalone assertion adapter.
- `scripts`: build, packaging, app icon generation, and CLI integration checks.

This first version is local, supports multiple cooperating processes on one Mac, and has no cloud sync or remote agent scheduler. Keep versioned backups of research workspaces as you would other project data.
