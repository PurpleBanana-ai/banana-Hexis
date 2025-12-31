# Reflex Examples (Local Repo Notes)

Use these when you need patterns beyond basic layouts. Paths are from
`/Users/eric/git/reflex-examples`.

## Streaming + Background Tasks

- **Chat streaming + telemetry**: `chat_v2/chat_v2/page_chat/chat_state.py`
  - Streaming completions, DB‑backed history, OpenTelemetry spans.
- **Background loop task**: `snakegame/snakegame/snakegame.py`
  - `@rx.event(background=True)` loop with `async with self` and a guard (`_n_tasks`) to avoid duplicate loops.
- **Multiple concurrent background tasks**: `lorem-stream/lorem_stream/lorem_stream.py`
  - Per‑task progress dicts + `rx.foreach` over task ids, toggles to pause/stop.
- **Graph traversal (BFS/DFS)**: `traversal/traversal/traversal.py`
  - Async stepper + `rx.toast` feedback, slider for parameters, nested `rx.foreach`.

## UI/UX Patterns

- **Form designer + auth + dynamic routes**: `form-designer/form_designer/form_designer.py`
  - `rx.State.setup_dynamic_args(...)`, route args, `reflex_local_auth`, `rx.Model.migrate()`.
- **Clipboard JSON viewer**: `json-tree/json_tree/json_tree.py`
  - `rx.clipboard(on_paste=...)` + `rx.data_list` to render nested JSON.
- **Upload flow**: `upload/upload/upload.py`
  - `rx.upload`, `rx.selected_files`, `rx.upload_files`, `rx.cancel_upload`, progress bar.
- **Custom React component + popover**: `local-component/local_component/local_component.py`
  - Custom component wrapper, `rx.popover`, `rx.scroll_to`, `prevent_default`.

## Styling + Assets

- **Tailwind class_name with `rx.el`**: `flux-fast/flux_fast/flux_fast.py`
  - Heavy className styling, image mosaic, fonts via `head_components`.
- **Wordle + global hotkeys**: `reflexle/reflexle/reflexle.py`
  - `reflex_global_hotkey`, toasts, computed vars for board state.
- **Typing test + client state**: `overkey/overkey/overkey.py`
  - `ClientStateVar`, `rx.field` typed vars, timer background events.

## Data + Charts

- **AG Grid + Recharts**: `ag_grid_finance/ag_grid_finance/ag_grid_finance.py`
  - `reflex_enterprise.ag_grid`, selection -> chart updates, `rx.recharts.line_chart`.
