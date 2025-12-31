# Reflex Components: Conditional + Iterables

## Conditional rendering

Use `rx.cond` instead of Python `if/else` when the condition is a state var.

```python
rx.cond(State.show, rx.text("On"), rx.text("Off"))
```

For multiple branches, prefer `rx.match` over nested `rx.cond`.

Var logic uses bitwise operators: `&`, `|`, `~`.

## Iterables

Use `rx.foreach` to render state-driven lists:

```python
rx.foreach(State.items, render_item)
```

Notes:
- The item argument is a `rx.Var`, so avoid Python-only operations on it.
- For dicts, each item is `[key, value]` and requires correct type annotations
  (e.g., `dict[str, str]`).
- For constant iterables, normal Python loops or list comprehensions are fine.
