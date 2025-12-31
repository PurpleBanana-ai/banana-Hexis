# Reflex Library Cheatsheet

## Select

Preferred high-level select:

```python
rx.select(
    ["apple", "grape", "pear"],
    value=State.value,
    on_change=State.set_value,
)
```

Lower-level variant (when you need custom trigger/content):

```python
rx.select.root(
    rx.select.trigger(),
    rx.select.content(
        rx.select.group(
            rx.select.item("apple", value="apple"),
            rx.select.item("grape", value="grape"),
        ),
    ),
    value=State.value,
    on_change=State.set_value,
)
```

Notes:
- Use `rx.select(...)` with a list of strings for typical cases.
- Do **not** use `rx.option` (not part of Reflex).

## Grid

```python
rx.grid(
    rx.foreach(State.items, render_item),
    columns="3",
    spacing="4",
    width="100%",
)
```

Responsive columns:

```python
rx.grid(
    ...,
    columns=rx.breakpoints(initial="1", md="2", lg="3"),
)
```

## Flex

```python
rx.flex(
    child_a,
    child_b,
    spacing="2",
    direction="row",  # or "column"
    align="center",
    justify="between",
)
```
