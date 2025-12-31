# State + Setters

## Setters

Each state var can have a setter `set_<var>` if auto setters are enabled. You can
also define explicit setters with `@rx.event`:

```python
class State(rx.State):
    value: str = ""

    @rx.event
    def set_value(self, value: str):
        self.value = value
```

Then:

```python
rx.input(value=State.value, on_change=State.set_value)
```

## state_auto_setters

You can explicitly enable or disable auto setters in `rxconfig.py`:

```python
config = rx.Config(
    app_name="ui",
    state_auto_setters=True,
)
```

## Backend-only vars

Vars starting with `_` are backend-only and not synced to the client.
Use them for sensitive or heavy data.
