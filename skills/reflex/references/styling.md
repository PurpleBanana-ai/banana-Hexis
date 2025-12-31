# Responsive + Styling

## Responsive values

Any style prop can take a list or `rx.breakpoints`:

```python
rx.text(color=["orange", "red", "purple", "blue", "green"])
```

```python
rx.text(
    color=rx.breakpoints(
        initial="orange",
        sm="purple",
        lg="green",
    ),
)
```

Use `rx.breakpoints` for Radix component props that support responsive values.

## Showing/hiding by breakpoint

Use display arrays or helper components:

```python
rx.desktop_only(rx.text("Desktop"))
rx.mobile_and_tablet(rx.text("Mobile + Tablet"))
```

## Custom breakpoints

In `rxconfig.py`:

```python
app = rx.App(style={"breakpoints": ["520px", "768px", "1024px", "1280px", "1640px"]})
```
