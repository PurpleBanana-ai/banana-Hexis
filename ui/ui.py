from __future__ import annotations

from typing import Any

import reflex as rx

from core import agent_api, chat, consent, ingest_api


PROVIDER_OPTIONS = [
    "openai",
    "anthropic",
    "gemini",
    "grok",
    "ollama",
    "openai-chat-completions-endpoint",
]

GLOBAL_CSS = """
@import url('https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600;700&family=IBM+Plex+Mono:wght@400;500&display=swap');

:root {
  --bg-1: #f2f5ff;
  --bg-2: #fef8ee;
  --ink: #1b1b22;
  --muted: #5b6474;
  --accent: #4f46e5;
  --accent-2: #f97316;
  --card: rgba(255, 255, 255, 0.85);
  --border: rgba(148, 163, 184, 0.35);
  --panel: rgba(255, 255, 255, 0.92);
  --panel-muted: rgba(238, 242, 255, 0.9);
  --bubble-user: #1e1b4b;
  --bubble-agent: rgba(255, 255, 255, 0.95);
}

html, body {
  font-family: 'Space Grotesk', sans-serif;
  color: var(--ink);
  background: linear-gradient(135deg, var(--bg-1) 0%, var(--bg-2) 100%);
}

* {
  box-sizing: border-box;
}

.fade-up {
  animation: fadeUp 0.6s ease both;
}

@keyframes fadeUp {
  from { opacity: 0; transform: translateY(10px); }
  to { opacity: 1; transform: translateY(0); }
}

.soft-glow {
  position: absolute;
  filter: blur(40px);
  opacity: 0.6;
}

.responsive-flex {
  display: flex;
  flex-direction: column;
  gap: 24px;
}

@media (min-width: 900px) {
  .responsive-flex {
    flex-direction: row;
    align-items: stretch;
  }
}
"""


def _split_lines(raw: str) -> list[str]:
    return [line.strip() for line in (raw or "").splitlines() if line.strip()]


def _parse_int(raw: str, default: int) -> int:
    try:
        return int(raw)
    except Exception:
        return default


def _parse_float(raw: str, default: float) -> float:
    try:
        return float(raw)
    except Exception:
        return default


class AppState(rx.State):
    initialized: bool = False
    terminated: bool = False
    consent_status: str = ""
    force_init_view: bool = False

    init_error: str = ""

    heartbeat_interval_minutes: str = "60"
    maintenance_interval_seconds: str = "60"
    max_energy: str = "20"
    base_regeneration: str = "10"
    max_active_goals: str = "3"

    objectives_text: str = ""
    guardrails_text: str = ""
    initial_message: str = ""
    tools_text: str = ""

    hb_provider: str = "openai"
    hb_model: str = "gpt-4o"
    hb_endpoint: str = ""
    hb_api_key_env: str = "OPENAI_API_KEY"

    chat_provider: str = "openai"
    chat_model: str = "gpt-4o"
    chat_endpoint: str = ""
    chat_api_key_env: str = "OPENAI_API_KEY"

    contact_channel: str = ""
    contact_destination: str = ""
    contact_entries: list[dict[str, Any]] = []
    contact_counter: int = 0

    enable_autonomy: bool = True
    enable_maintenance: bool = True

    consent_output: str = ""
    consent_decision: str = ""
    consent_running: bool = False

    chat_history: list[dict[str, Any]] = []
    chat_input: str = ""
    chat_busy: bool = False
    chat_error: str = ""

    active_panel: str = "chat"

    ingest_path: str = ""
    ingest_recursive: bool = True
    ingest_log: list[str] = []
    ingest_running: bool = False
    ingest_cancel_requested: bool = False
    ingest_session_id: str = ""

    @rx.var
    def has_chat_history(self) -> bool:
        return len(self.chat_history) > 0

    @rx.var
    def has_ingest_log(self) -> bool:
        return len(self.ingest_log) > 0

    @rx.var
    def has_contacts(self) -> bool:
        return len(self.contact_entries) > 0

    async def load_status(self) -> None:
        status = await agent_api.get_agent_status()
        consent_status = str(status.get("consent_status") or "")
        self.initialized = bool(status.get("configured")) and consent_status == "consent"
        self.terminated = bool(status.get("terminated"))
        self.consent_status = consent_status

        if not self.initialized:
            defaults = await agent_api.get_init_defaults()
            self.heartbeat_interval_minutes = str(defaults.get("heartbeat_interval_minutes", 60))
            self.maintenance_interval_seconds = str(defaults.get("maintenance_interval_seconds", 60))
            self.max_energy = str(defaults.get("max_energy", 20))
            self.base_regeneration = str(defaults.get("base_regeneration", 10))
            self.max_active_goals = str(defaults.get("max_active_goals", 3))

            hb_cfg = await agent_api.get_llm_config(None, "llm.heartbeat")
            if hb_cfg:
                hb_provider = str(hb_cfg.get("provider") or self.hb_provider)
                if hb_provider == "openai_compatible":
                    hb_provider = "openai-chat-completions-endpoint"
                self.hb_provider = hb_provider
                self.hb_model = str(hb_cfg.get("model") or self.hb_model)
                self.hb_endpoint = str(hb_cfg.get("endpoint") or self.hb_endpoint)
                self.hb_api_key_env = str(hb_cfg.get("api_key_env") or self.hb_api_key_env)

            chat_cfg = await agent_api.get_llm_config(None, "llm.chat")
            if chat_cfg:
                chat_provider = str(chat_cfg.get("provider") or self.chat_provider)
                if chat_provider == "openai_compatible":
                    chat_provider = "openai-chat-completions-endpoint"
                self.chat_provider = chat_provider
                self.chat_model = str(chat_cfg.get("model") or self.chat_model)
                self.chat_endpoint = str(chat_cfg.get("endpoint") or self.chat_endpoint)
                self.chat_api_key_env = str(chat_cfg.get("api_key_env") or self.chat_api_key_env)

    def add_contact(self) -> None:
        channel = self.contact_channel.strip()
        destination = self.contact_destination.strip()
        if not channel:
            return
        self.contact_entries.append(
            {
                "id": self.contact_counter,
                "channel": channel,
                "destination": destination,
            }
        )
        self.contact_counter += 1
        self.contact_channel = ""
        self.contact_destination = ""

    def remove_contact(self, entry_id: int) -> None:
        self.contact_entries = [e for e in self.contact_entries if e.get("id") != entry_id]

    async def initialize_agent(self) -> Any:
        self.init_error = ""
        self.consent_output = ""
        self.consent_decision = ""
        self.consent_running = False

        objectives = _split_lines(self.objectives_text)
        if not objectives:
            self.init_error = "At least one objective is required."
            return

        guardrails = _split_lines(self.guardrails_text)
        tools = _split_lines(self.tools_text)
        contact_channels = [entry["channel"] for entry in self.contact_entries]
        contact_destinations = {entry["channel"]: entry["destination"] for entry in self.contact_entries}

        await agent_api.apply_agent_config(
            heartbeat_interval_minutes=_parse_int(self.heartbeat_interval_minutes, 60),
            maintenance_interval_seconds=_parse_int(self.maintenance_interval_seconds, 60),
            max_energy=_parse_float(self.max_energy, 20.0),
            base_regeneration=_parse_float(self.base_regeneration, 10.0),
            max_active_goals=_parse_int(self.max_active_goals, 3),
            objectives=objectives,
            guardrails=guardrails,
            initial_message=self.initial_message.strip(),
            tools=tools,
            llm_heartbeat={
                "provider": self.hb_provider,
                "model": self.hb_model,
                "endpoint": self.hb_endpoint,
                "api_key_env": self.hb_api_key_env,
            },
            llm_chat={
                "provider": self.chat_provider,
                "model": self.chat_model,
                "endpoint": self.chat_endpoint,
                "api_key_env": self.chat_api_key_env,
            },
            contact_channels=contact_channels,
            contact_destinations=contact_destinations,
            enable_autonomy=self.enable_autonomy,
            enable_maintenance=self.enable_maintenance,
            mark_configured=False,
        )

        self.consent_running = True
        yield

        consent_llm = {
            "provider": self.chat_provider,
            "model": self.chat_model,
            "endpoint": self.chat_endpoint,
            "api_key_env": self.chat_api_key_env,
        }

        try:
            async for event in consent.stream_consent_flow(llm_config=consent_llm):
                if event.get("type") == "chunk":
                    self.consent_output += event.get("text", "")
                    yield
                if event.get("type") == "final":
                    self.consent_decision = str(event.get("decision") or "")
                    self.consent_running = False
                    yield
        except Exception as exc:
            self.init_error = f"Consent flow failed: {exc}"
            self.consent_running = False
            yield

        if self.consent_decision == "consent":
            await agent_api.set_agent_configured(None, configured=True)

        status = await agent_api.get_agent_status()
        consent_status = str(status.get("consent_status") or "")
        self.initialized = bool(status.get("configured")) and consent_status == "consent"
        self.terminated = bool(status.get("terminated"))
        self.consent_status = consent_status
        if self.initialized:
            self.force_init_view = False

    async def send_chat(self) -> Any:
        message = self.chat_input.strip()
        if not message or self.chat_busy:
            return

        self.chat_busy = True
        self.chat_error = ""
        history = list(self.chat_history)
        self.chat_history = history + [{"role": "user", "content": message}]
        self.chat_input = ""
        yield

        try:
            llm_cfg = await agent_api.get_llm_config(None, "llm.chat")
            result = await chat.chat_turn(user_message=message, history=history, llm_config=llm_cfg)
        except Exception as exc:
            self.chat_error = str(exc)
        else:
            self.chat_history = result.get("history", self.chat_history)
        finally:
            self.chat_busy = False
            yield

    async def start_ingestion(self) -> Any:
        path = self.ingest_path.strip()
        if not path or self.ingest_running:
            return

        self.ingest_running = True
        self.ingest_cancel_requested = False
        self.ingest_log = []
        self.active_panel = "ingest"
        self.ingest_session_id = ingest_api.create_ingestion_session()
        yield

        try:
            llm_cfg = await agent_api.get_llm_config(None, "llm.chat")
            async for event in ingest_api.stream_ingestion(
                session_id=self.ingest_session_id,
                path=path,
                recursive=self.ingest_recursive,
                llm_config=llm_cfg,
            ):
                if self.ingest_cancel_requested:
                    ingest_api.cancel_ingestion(self.ingest_session_id)
                if event.get("type") == "log":
                    self.ingest_log.append(event.get("text", ""))
                    yield
        finally:
            self.ingest_running = False
            yield

    def cancel_ingestion(self) -> None:
        if self.ingest_session_id:
            self.ingest_cancel_requested = True
            ingest_api.cancel_ingestion(self.ingest_session_id)

    def show_init(self) -> None:
        self.force_init_view = True

    def show_chat(self) -> None:
        self.force_init_view = False

    def clear_chat(self) -> None:
        self.chat_history = []
        self.chat_error = ""


def status_badge() -> rx.Component:
    status = rx.cond(
        AppState.initialized,
        rx.badge("configured", color_scheme="green"),
        rx.badge("needs init", color_scheme="orange"),
    )
    consent_label = rx.cond(
        AppState.consent_status != "",
        "consent: " + AppState.consent_status,
        "consent: unknown",
    )
    consent_badge = rx.badge(consent_label, color_scheme="gray")
    return rx.hstack(status, consent_badge, spacing="3")


def labeled_field(label: str, component: rx.Component) -> rx.Component:
    return rx.vstack(
        rx.text(label, font_size="0.85rem", color="var(--muted)", font_weight="500"),
        component,
        spacing="1",
        align="start",
        width="100%",
    )


def llm_section(
    *,
    title: str,
    provider_value: rx.Var,
    provider_setter: Any,
    model_value: rx.Var,
    model_setter: Any,
    endpoint_value: rx.Var,
    endpoint_setter: Any,
    api_key_value: rx.Var,
    api_key_setter: Any,
) -> rx.Component:
    return rx.vstack(
        rx.text(title, font_weight="600"),
        rx.grid(
            labeled_field(
                "Provider",
                rx.select(
                    PROVIDER_OPTIONS,
                    value=provider_value,
                    on_change=provider_setter,
                    width="100%",
                ),
            ),
            labeled_field(
                "Model",
                rx.input(value=model_value, on_change=model_setter, placeholder="Model name"),
            ),
            columns=rx.breakpoints(initial="1", md="2"),
            spacing="3",
            width="100%",
        ),
        rx.grid(
            labeled_field(
                "Endpoint",
                rx.input(value=endpoint_value, on_change=endpoint_setter, placeholder="https://..."),
            ),
            labeled_field(
                "API key env",
                rx.input(value=api_key_value, on_change=api_key_setter, placeholder="OPENAI_API_KEY"),
            ),
            columns=rx.breakpoints(initial="1", md="2"),
            spacing="3",
            width="100%",
        ),
        spacing="3",
        width="100%",
    )


def init_view() -> rx.Component:
    return rx.flex(
        rx.box(
            rx.vstack(
                rx.heading("Initialize Hexis", size="7"),
                rx.text(
                    "Configure cadence, guardrails, and model settings before bringing the agent online.",
                    color="var(--muted)",
                ),
                rx.cond(
                    AppState.init_error != "",
                    rx.box(
                        rx.text(AppState.init_error, color="#7f1d1d", font_weight="600"),
                        background="#fee2e2",
                        border="1px solid #fecaca",
                        padding="10px 12px",
                        border_radius="12px",
                        width="100%",
                    ),
                    rx.box(),
                ),
                rx.vstack(
                    rx.text("Heartbeat and maintenance", font_weight="600"),
                    rx.grid(
                        labeled_field(
                            "Heartbeat interval (minutes)",
                            rx.input(
                                value=AppState.heartbeat_interval_minutes,
                                on_change=AppState.set_heartbeat_interval_minutes,
                                type_="number",
                            ),
                        ),
                        labeled_field(
                            "Maintenance interval (seconds)",
                            rx.input(
                                value=AppState.maintenance_interval_seconds,
                                on_change=AppState.set_maintenance_interval_seconds,
                                type_="number",
                            ),
                        ),
                        labeled_field(
                            "Max energy budget",
                            rx.input(
                                value=AppState.max_energy,
                                on_change=AppState.set_max_energy,
                                type_="number",
                            ),
                        ),
                        labeled_field(
                            "Base regeneration",
                            rx.input(
                                value=AppState.base_regeneration,
                                on_change=AppState.set_base_regeneration,
                                type_="number",
                            ),
                        ),
                        labeled_field(
                            "Max active goals",
                            rx.input(
                                value=AppState.max_active_goals,
                                on_change=AppState.set_max_active_goals,
                                type_="number",
                            ),
                        ),
                        columns=rx.breakpoints(initial="1", md="2"),
                        spacing="3",
                        width="100%",
                    ),
                    spacing="3",
                    width="100%",
                ),
                rx.vstack(
                    rx.text("Objectives and guardrails", font_weight="600"),
                    labeled_field(
                        "Major objectives (one per line)",
                        rx.text_area(
                            value=AppState.objectives_text,
                            on_change=AppState.set_objectives_text,
                            placeholder="Ship the alpha, maintain alignment, ...",
                        ),
                    ),
                    labeled_field(
                        "Guardrails (one per line)",
                        rx.text_area(
                            value=AppState.guardrails_text,
                            on_change=AppState.set_guardrails_text,
                            placeholder="No irreversible actions without approval, ...",
                        ),
                    ),
                    labeled_field(
                        "Initial message",
                        rx.text_area(
                            value=AppState.initial_message,
                            on_change=AppState.set_initial_message,
                            placeholder="A welcome message for the agent.",
                        ),
                    ),
                    spacing="3",
                    width="100%",
                ),
                llm_section(
                    title="Heartbeat model",
                    provider_value=AppState.hb_provider,
                    provider_setter=AppState.set_hb_provider,
                    model_value=AppState.hb_model,
                    model_setter=AppState.set_hb_model,
                    endpoint_value=AppState.hb_endpoint,
                    endpoint_setter=AppState.set_hb_endpoint,
                    api_key_value=AppState.hb_api_key_env,
                    api_key_setter=AppState.set_hb_api_key_env,
                ),
                llm_section(
                    title="Chat model",
                    provider_value=AppState.chat_provider,
                    provider_setter=AppState.set_chat_provider,
                    model_value=AppState.chat_model,
                    model_setter=AppState.set_chat_model,
                    endpoint_value=AppState.chat_endpoint,
                    endpoint_setter=AppState.set_chat_endpoint,
                    api_key_value=AppState.chat_api_key_env,
                    api_key_setter=AppState.set_chat_api_key_env,
                ),
                rx.vstack(
                    rx.text("Contact and tools", font_weight="600"),
                    labeled_field(
                        "Contact channels",
                        rx.hstack(
                            rx.input(
                                value=AppState.contact_channel,
                                on_change=AppState.set_contact_channel,
                                placeholder="email, sms, telegram",
                            ),
                            rx.input(
                                value=AppState.contact_destination,
                                on_change=AppState.set_contact_destination,
                                placeholder="address or handle",
                            ),
                            rx.button(
                                "Add",
                                on_click=AppState.add_contact,
                                color_scheme="teal",
                                is_disabled=AppState.contact_channel == "",
                            ),
                            spacing="2",
                            width="100%",
                        ),
                    ),
                    rx.cond(
                        AppState.has_contacts,
                        rx.vstack(
                            rx.foreach(
                                AppState.contact_entries,
                                lambda entry: rx.hstack(
                                    rx.badge(entry["channel"], color_scheme="gray"),
                                    rx.text(
                                        rx.cond(
                                            entry["destination"] != "",
                                            entry["destination"],
                                            "unspecified",
                                        ),
                                        color="var(--muted)",
                                    ),
                                    rx.spacer(),
                                    rx.button(
                                        "Remove",
                                        size="1",
                                        variant="outline",
                                        on_click=lambda: AppState.remove_contact(entry["id"]),
                                    ),
                                    width="100%",
                                ),
                            ),
                            spacing="2",
                            width="100%",
                        ),
                        rx.text("No contact channels yet.", color="var(--muted)"),
                    ),
                    labeled_field(
                        "Tools (one per line)",
                        rx.text_area(
                            value=AppState.tools_text,
                            on_change=AppState.set_tools_text,
                            placeholder="email, sms, web_research",
                        ),
                    ),
                    spacing="3",
                    width="100%",
                ),
                rx.hstack(
                    rx.checkbox(
                        "Enable autonomous heartbeats",
                        is_checked=AppState.enable_autonomy,
                        on_change=AppState.set_enable_autonomy,
                    ),
                    rx.checkbox(
                        "Enable subconscious maintenance",
                        is_checked=AppState.enable_maintenance,
                        on_change=AppState.set_enable_maintenance,
                    ),
                    spacing="4",
                ),
                rx.button(
                    "Save config and request consent",
                    on_click=AppState.initialize_agent,
                    is_loading=AppState.consent_running,
                    color_scheme="teal",
                    size="4",
                    width="100%",
                ),
                spacing="4",
                width="100%",
            ),
            padding="24px",
            border_radius="18px",
            background="var(--card)",
            border=f"1px solid var(--border)",
            box_shadow="0 20px 50px rgba(22, 18, 12, 0.08)",
            class_name="fade-up",
            flex="1",
        ),
        rx.box(
            rx.vstack(
                rx.heading("Consent output", size="6"),
                rx.text(
                    "The agent will respond here in real time. Consent must be granted before activation.",
                    color="var(--muted)",
                ),
                rx.hstack(
                    rx.badge(
                        rx.cond(
                            AppState.consent_decision != "",
                            AppState.consent_decision,
                            "pending",
                        ),
                        color_scheme=rx.cond(
                            AppState.consent_decision == "consent",
                            "green",
                            "orange",
                        ),
                    ),
                    rx.cond(
                        AppState.consent_running,
                        rx.text("running...", color="var(--muted)"),
                        rx.text("", color="var(--muted)"),
                    ),
                ),
                rx.box(
                    rx.text(
                        AppState.consent_output,
                        white_space="pre-wrap",
                        font_family="'IBM Plex Mono', monospace",
                        font_size="0.85rem",
                    ),
                    height="420px",
                    overflow="auto",
                    padding="16px",
                    border_radius="14px",
                    background="#11100e",
                    color="#f1f0ea",
                    border="1px solid #2a241b",
                    width="100%",
                ),
                spacing="3",
                width="100%",
            ),
            padding="24px",
            border_radius="18px",
            background="rgba(20, 18, 14, 0.9)",
            border="1px solid #2a241b",
            box_shadow="0 20px 50px rgba(22, 18, 12, 0.15)",
            class_name="fade-up",
            flex="1",
        ),
        class_name="responsive-flex",
        width="100%",
    )


def message_bubble(message: dict[str, Any]) -> rx.Component:
    is_user = message["role"] == "user"
    name = rx.cond(is_user, "You", "Hexis")
    avatar_label = rx.cond(is_user, "YU", "HX")
    avatar_color = rx.cond(is_user, "indigo", "gray")
    bubble_bg = rx.cond(is_user, "var(--bubble-user)", "var(--bubble-agent)")
    bubble_color = rx.cond(is_user, "#f8fafc", "var(--ink)")
    bubble_border = rx.cond(is_user, "none", f"1px solid var(--border)")

    return rx.hstack(
        rx.flex(
            rx.avatar(
                fallback=avatar_label,
                variant="solid",
                color_scheme=avatar_color,
                size="3",
                radius="full",
            ),
            rx.box(
                rx.vstack(
                    rx.text(name, font_weight="600", font_size="0.8rem", color="var(--muted)"),
                    rx.markdown(
                        message["content"],
                        color=bubble_color,
                        overflow_wrap="break-word",
                    ),
                    spacing="2",
                    align="start",
                ),
                background=bubble_bg,
                border=bubble_border,
                padding="16px 18px",
                border_radius="16px",
                box_shadow="0 12px 30px rgba(24, 28, 38, 0.08)",
                max_width="100%",
            ),
            direction=rx.cond(is_user, "row-reverse", "row"),
            spacing="3",
            align="start",
            width="100%",
        ),
        justify=rx.cond(is_user, "end", "start"),
        width="100%",
    )


def chat_view() -> rx.Component:
    chat_panel = rx.box(
        rx.vstack(
            rx.hstack(
                rx.vstack(
                    rx.heading("Hexis Chat", size="7"),
                    rx.text("Memory-aware conversation with tool access.", color="var(--muted)"),
                    spacing="1",
                    align="start",
                ),
                rx.spacer(),
                rx.button(
                    "Clear",
                    on_click=AppState.clear_chat,
                    variant="outline",
                    size="1",
                    is_disabled=~AppState.has_chat_history,
                ),
                align="center",
                width="100%",
            ),
            rx.box(
                rx.cond(
                    AppState.has_chat_history,
                    rx.scroll_area(
                        rx.vstack(
                            rx.foreach(AppState.chat_history, message_bubble),
                            spacing="4",
                            align="stretch",
                            width="100%",
                        ),
                        scrollbars="vertical",
                        type="auto",
                    ),
                    rx.center(
                        rx.vstack(
                            rx.heading("Start the thread", size="5"),
                            rx.text(
                                "Ask a question, load context, or give the agent a task.",
                                color="var(--muted)",
                            ),
                            spacing="2",
                        ),
                        height="100%",
                    ),
                ),
                height="440px",
                padding="16px",
                border_radius="20px",
                background="var(--panel)",
                border=f"1px solid var(--border)",
                width="100%",
            ),
            rx.box(
                rx.vstack(
                    rx.text_area(
                        value=AppState.chat_input,
                        on_change=AppState.set_chat_input,
                        placeholder="Type your message…",
                        min_height="96px",
                        max_height="240px",
                        auto_height=True,
                        rows="1",
                        variant="soft",
                        background_color="var(--panel-muted)",
                        color="var(--ink)",
                        is_disabled=AppState.ingest_running,
                    ),
                    rx.divider(),
                    rx.hstack(
                        rx.text(
                            "Shift+Enter for newline",
                            color="var(--muted)",
                            font_size="0.8rem",
                        ),
                        rx.spacer(),
                        rx.button(
                            rx.icon(tag="send", size=16),
                            "Send",
                            on_click=AppState.send_chat,
                            is_loading=AppState.chat_busy,
                            is_disabled=AppState.ingest_running,
                            color_scheme="indigo",
                            size="3",
                        ),
                        align="center",
                        width="100%",
                    ),
                    spacing="3",
                ),
                padding="18px",
                border_radius="18px",
                background="var(--panel-muted)",
                border=f"1px solid var(--border)",
                box_shadow="0 8px 24px rgba(24, 28, 38, 0.08)",
                width="100%",
            ),
            rx.cond(
                AppState.chat_error != "",
                rx.box(
                    rx.text(AppState.chat_error, color="#7f1d1d", font_weight="600"),
                    background="#fee2e2",
                    border="1px solid #fecaca",
                    padding="10px 12px",
                    border_radius="12px",
                    width="100%",
                ),
                rx.box(),
            ),
            spacing="4",
            width="100%",
        ),
        padding="24px",
        border_radius="18px",
        background="var(--card)",
        border=f"1px solid var(--border)",
        box_shadow="0 20px 50px rgba(24, 28, 38, 0.08)",
        class_name="fade-up",
        flex="1.5",
    )

    ingest_panel = rx.vstack(
        rx.heading("Ingestion", size="6"),
        rx.text("Stream ingestion output in real time. Cancel to stop.", color="var(--muted)"),
        labeled_field(
            "File or directory path",
            rx.input(value=AppState.ingest_path, on_change=AppState.set_ingest_path),
        ),
        rx.checkbox(
            "Recursive directory scan",
            is_checked=AppState.ingest_recursive,
            on_change=AppState.set_ingest_recursive,
        ),
        rx.hstack(
            rx.button(
                "Start ingestion",
                on_click=AppState.start_ingestion,
                is_loading=AppState.ingest_running,
                is_disabled=AppState.ingest_path == "",
                color_scheme="orange",
            ),
            rx.button(
                "Cancel",
                on_click=AppState.cancel_ingestion,
                variant="outline",
                is_disabled=~AppState.ingest_running,
            ),
            spacing="3",
        ),
        rx.box(
            rx.cond(
                AppState.has_ingest_log,
                rx.vstack(
                    rx.foreach(
                        AppState.ingest_log,
                        lambda line: rx.text(line, white_space="pre-wrap"),
                    ),
                    spacing="1",
                    align="start",
                    width="100%",
                ),
                rx.text("No ingestion output yet.", color="#93c5b4"),
            ),
            height="260px",
            overflow="auto",
            padding="12px",
            border_radius="14px",
            background="#0f0e0c",
            color="#d7f5e8",
            border="1px solid #201b14",
            font_family="'IBM Plex Mono', monospace",
            font_size="0.8rem",
            width="100%",
        ),
        spacing="3",
        width="100%",
    )

    side_panel = rx.box(
        rx.vstack(
            rx.text("Actions", font_weight="600"),
            rx.select(
                ["chat", "ingest"],
                value=AppState.active_panel,
                on_change=AppState.set_active_panel,
                is_disabled=AppState.ingest_running,
            ),
            rx.cond(AppState.active_panel == "ingest", ingest_panel, rx.box()),
            spacing="3",
            width="100%",
        ),
        padding="24px",
        border_radius="18px",
        background="var(--card)",
        border=f"1px solid var(--border)",
        box_shadow="0 20px 50px rgba(22, 18, 12, 0.08)",
        class_name="fade-up",
        flex="1",
    )

    return rx.flex(
        chat_panel,
        side_panel,
        class_name="responsive-flex",
        width="100%",
    )


def index() -> rx.Component:
    return rx.box(
        rx.el.style(GLOBAL_CSS),
        rx.box(
            width="360px",
            height="360px",
            background="radial-gradient(circle, #0f766e 0%, rgba(15,118,110,0.0) 70%)",
            top="-120px",
            right="-120px",
            class_name="soft-glow",
        ),
        rx.box(
            width="280px",
            height="280px",
            background="radial-gradient(circle, #c2410c 0%, rgba(194,65,12,0.0) 70%)",
            bottom="-120px",
            left="-80px",
            class_name="soft-glow",
        ),
        rx.container(
            rx.hstack(
                rx.vstack(
                    rx.heading("Hexis", size="8"),
                    rx.text("Cognitive memory engine", color="var(--muted)"),
                    spacing="1",
                    align="start",
                ),
                rx.spacer(),
                status_badge(),
                rx.cond(
                    AppState.force_init_view & AppState.initialized,
                    rx.button("Back to chat", on_click=AppState.show_chat, variant="outline"),
                    rx.cond(
                        AppState.initialized,
                        rx.button("Reconfigure", on_click=AppState.show_init, variant="outline"),
                        rx.box(),
                    ),
                ),
                align="center",
                width="100%",
            ),
            rx.cond(
                AppState.terminated,
                rx.box(
                    rx.heading("Agent terminated", size="7"),
                    rx.text("The agent has ended its session. Reset the database to start again."),
                    padding="24px",
                    border_radius="18px",
                    background="var(--card)",
                    border=f"1px solid var(--border)",
                ),
                rx.cond(
                    AppState.force_init_view,
                    init_view(),
                    rx.cond(AppState.initialized, chat_view(), init_view()),
                ),
            ),
            max_width="1200px",
            padding="32px",
            position="relative",
            z_index="1",
        ),
        min_height="100vh",
        position="relative",
        padding_bottom="60px",
    )


app = rx.App()
app.add_page(index, on_load=AppState.load_status)
