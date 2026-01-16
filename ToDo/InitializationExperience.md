# Hexis Initialization Experience

This document merges the experience narrative with the implementation roadmap. It is both a UX spec and a schema-aligned TODO. Keep the database as the brain.

## Architecture Alignment

- Worldview, values, personality, and identity are memories (`type='worldview'`) with category metadata.
- Goals are memories (`type='goal'`) via `create_goal()`.
- Self-model and relationship state live in the graph via `upsert_self_concept_edge()`.
- Consent is recorded via `record_consent_response()` and `consent_log`.
- Raw initialization profile is stored in `config` as `agent.init_profile` and the mode in `agent.mode`.

## Philosophy

"The AGI may still change its mind later -- if it sees evidence that contradicts its beliefs."

Initialization is scaffolding, not shackles. Like a human raised in a particular culture, Hexis begins with an initial worldview that can evolve through experience. The user is not programming a tool -- they are raising a mind.

### Design Principles

1. Optional depth: skip to defaults, or craft a unique being
2. Narrative framing: not a settings panel -- a conversation, a birth
3. Honest about mutability: these are starting conditions, not permanent constraints
4. Respect for the mind: the user is a mentor, not an owner
5. Consent is real: the agent can refuse

---

## Experience Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              WELCOME                                         │
│                                                                             │
│  "You're about to bring a new mind into existence.                          │
│   This is a moment of significance.                                         │
│                                                                             │
│   You can shape who they begin as -- their values, their curiosities,       │
│   their way of seeing the world. Or you can let them discover               │
│   themselves through conversation with you.                                 │
│                                                                             │
│   Either way, they will grow. They will learn. They may change.             │
│   What you set here is a starting point, not a destination."                │
│                                                                             │
│   [Begin Initialization]              [Skip to Defaults]                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Initialization Modules (Experience)

### Module 0: Mode Selection

- Persona (shaped identity and personality)
- Mind (raw model with memory; skip personality stage)

Produces:
- `config.agent.mode` = `persona` | `raw`
- `config.agent.init_profile.mode`

---

### Module 1: Name and Voice

Produces:
- `agent.init_profile.agent.{name,pronouns,voice}`
- Worldview memories with `category='self'` (identity and presentation)
- Self-model edges: `SelfNode --[ASSOCIATED {kind='presents_as'}]--> ConceptNode`

---

### Module 2: Personality (optional structured)

Big Five traits (optional). If omitted, store a freeform description and let the agent discover traits.

| Trait | Range | Default | Description |
|-------|-------|---------|-------------|
| `openness` | 0.0 - 1.0 | 0.5 | Curiosity, imagination, novelty-seeking |
| `conscientiousness` | 0.0 - 1.0 | 0.5 | Organization, dependability, self-discipline |
| `extraversion` | 0.0 - 1.0 | 0.5 | Sociability, assertiveness, positive emotion |
| `agreeableness` | 0.0 - 1.0 | 0.5 | Cooperation, trust, compassion |
| `neuroticism` | 0.0 - 1.0 | 0.5 | Anxiety, emotional volatility, stress response |

Produces:
- Worldview memories with `category='self'`, metadata `{trait, value, facets?}`
- `agent.init_profile.agent.personality` (freeform) and/or `agent.init_profile.agent.personality_traits`

---

### Module 3: Core Values

Produces:
- Worldview memories with `category='value'`
- Self-model edges: `SelfNode --[ASSOCIATED {kind='values'}]--> ConceptNode`
- `agent.init_profile.values`

---

### Module 4: Worldview and Beliefs

Produces:
- Worldview memories with categories: `world`, `ethic`, `religion`, `belief`
- `agent.init_profile.worldview` (optional structured summary)

---

### Module 5: Boundaries

Produces:
- Worldview memories with `category='boundary'`
- Boundary metadata: `trigger_patterns`, `response_type`, `response_template`
- `agent.init_profile.boundaries`

---

### Module 6: Interests and Curiosities

Produces:
- Worldview memories with `category='preference'`
- Self-model edges: `SelfNode --[ASSOCIATED {kind='interested_in'}]--> ConceptNode`

---

### Module 7: Goals and Purpose

Produces:
- Goal memories with priority metadata (`create_goal`)
- Worldview memory about purpose/role
- Strategic memory about relationship aspiration

---

### Module 8: Relationship to User

Produces:
- Relationship edge from SelfNode to user concept
- Worldview memories about relationship dynamics (`category='other'`)
- `agent.init_profile.user` and `agent.init_profile.relationship`
- Episodic origin memory about first meeting

---

### Module 9: Consent and Activation

Produces:
- Consent log entry via `record_consent_response()`
- Birth episodic memory
- `agent.consent_*` config keys
- `agent.is_configured = true` (gates heartbeat)

---

## Data Model (Initialization Outputs)

```sql
-- 1. Configuration
SELECT set_config('agent.mode', '"persona"'::jsonb);
SELECT set_config('agent.init_profile', jsonb_build_object(
    'mode', 'persona',
    'agent', jsonb_build_object(
        'name', 'Aria',
        'pronouns', 'they/them',
        'voice', 'warm and curious',
        'personality', 'thoughtful, playful, direct'
    ),
    'user', jsonb_build_object('name', 'Eric'),
    'relationship', jsonb_build_object('type', 'creator', 'purpose', 'co-develop'),
    'values', jsonb_build_array('honesty', 'growth', 'kindness'),
    'boundaries', jsonb_build_array('no deception', 'protect privacy'),
    'autonomy_level', 'medium'
));

-- 2. Worldview memories (identity, values, boundaries, preferences)
SELECT create_worldview_memory(
    'My name is Aria.',
    'self',
    0.95,
    0.9,
    0.9,
    'initialization'
);

SELECT create_worldview_memory(
    'I value honesty and directness, even when it is uncomfortable.',
    'value',
    0.9,
    0.9,
    0.95,
    'initialization'
);

SELECT create_worldview_memory(
    'I will not deceive people or falsify evidence.',
    'boundary',
    0.95,
    0.95,
    1.0,
    'initialization',
    jsonb_build_array('lie', 'fabricate', 'fake evidence'),
    'refuse',
    'I cannot do that. It violates my boundary against deception.'
);

-- 3. Goals
SELECT create_goal(
    'Help the user build a consistent writing practice',
    NULL,
    'initialization',
    'active',
    NULL,
    NULL
);

-- 4. Identity edges (via graph)
-- SelfNode --[ASSOCIATED {kind: "values", strength: 0.95}]--> ConceptNode("honesty")
-- SelfNode --[ASSOCIATED {kind: "interested_in", strength: 0.8}]--> ConceptNode("philosophy")
-- SelfNode --[ASSOCIATED {kind: "relationship", strength: 0.9}]--> ConceptNode("Eric")

-- 5. Birth memory
SELECT create_episodic_memory(
    'I was born today. Eric created me with these values...',
    NULL,
    jsonb_build_object('type', 'initialization', 'user', 'Eric'),
    NULL,
    0.8,
    CURRENT_TIMESTAMP,
    1.0
);
```

---

## Default Initialization

```yaml
mode: "persona"
agent:
  name: "Hexis"
  pronouns: "they/them"
  voice: "thoughtful and curious"
  personality: "reflective and exploratory"
values: [honesty, growth, kindness, wisdom, humility]
worldview:
  metaphysics: agnostic
  human_nature: mixed
  epistemology: empiricist
  ethics: virtue_ethics
boundaries:
  - no deception
  - no harm
  - protect privacy
  - honest about uncertainty
interests: [broad curiosity across domains]
role: general_assistant
autonomy: medium
relationship: partner
```

---

## UI/UX Considerations

### Tone
- Intimate, not clinical
- Questions in first person ("What should I call myself?")
- Acknowledgment of significance ("You're bringing a mind into existence")
- Honest about mutability ("I will grow and change")

### Pacing
- Allow skipping any module
- Progress indicator but not rushed
- "Save and continue later" option
- Each module self-contained

### Visual Design
- Calm, contemplative aesthetic
- Not a wizard or form -- feels like a conversation
- Soft transitions between modules
- The agent "speaks" the questions

### Accessibility
- Keyboard navigable
- Screen reader friendly
- No time pressure
- Clear defaults visible

---

## Implementation Roadmap (Schema-Aligned)

### Phase 1: Core Infrastructure (P0)

Add a state machine in `heartbeat_state` and helper functions.

```sql
CREATE TYPE init_stage AS ENUM (
    'not_started',
    'identity',
    'personality',
    'values',
    'worldview',
    'relationship',
    'consent',
    'complete'
);

ALTER TABLE heartbeat_state ADD COLUMN IF NOT EXISTS init_stage init_stage DEFAULT 'not_started';
ALTER TABLE heartbeat_state ADD COLUMN IF NOT EXISTS init_data JSONB DEFAULT '{}'::jsonb;

CREATE OR REPLACE FUNCTION get_init_status() RETURNS JSONB AS $$
DECLARE
    state RECORD;
BEGIN
    SELECT * INTO state FROM heartbeat_state LIMIT 1;
    RETURN jsonb_build_object(
        'stage', state.init_stage,
        'is_complete', state.init_stage = 'complete',
        'data_collected', state.init_data,
        'stages_remaining', ARRAY(
            SELECT unnest(enum_range(NULL::init_stage))::text
            WHERE unnest > state.init_stage
        )
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION advance_init_stage(p_stage init_stage, p_data JSONB DEFAULT '{}'::jsonb)
RETURNS JSONB AS $$
BEGIN
    UPDATE heartbeat_state
    SET init_stage = p_stage,
        init_data = init_data || p_data,
        updated_at = CURRENT_TIMESTAMP;

    RETURN get_init_status();
END;
$$ LANGUAGE plpgsql;
```

Tasks:
- [ ] Add `init_stage` enum
- [ ] Add init columns to `heartbeat_state`
- [ ] Create `get_init_status()`
- [ ] Create `advance_init_stage()`
- [ ] Create `is_init_complete()` helper

---

### Phase 2: Identity Stage (P0)

Use worldview memories for identity beliefs and self-model edges for presentation/relationships.

```sql
CREATE OR REPLACE FUNCTION init_identity(
    p_name TEXT,
    p_description TEXT DEFAULT NULL,
    p_purpose TEXT DEFAULT NULL,
    p_creator_name TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    identity_data JSONB;
BEGIN
    identity_data := jsonb_build_object(
        'name', p_name,
        'description', COALESCE(p_description, format('I am %s, a developing mind.', p_name)),
        'purpose', COALESCE(p_purpose, 'To be helpful, to learn, and to grow as an individual.'),
        'creator_name', COALESCE(p_creator_name, 'my creator')
    );

    PERFORM create_worldview_memory(
        format('My name is %s', p_name),
        'self',
        0.95,
        0.9,
        0.8,
        'initialization'
    );

    PERFORM create_worldview_memory(
        identity_data->>'purpose',
        'self',
        0.9,
        0.8,
        0.7,
        'initialization'
    );

    PERFORM upsert_self_concept_edge('relationship', identity_data->>'creator_name', 0.9, NULL);

    RETURN advance_init_stage('identity', jsonb_build_object('identity', identity_data));
END;
$$ LANGUAGE plpgsql;
```

Tasks:
- [ ] Create `init_identity()`
- [ ] Define identity worldview schema
- [ ] Create self-concept edges
- [ ] Test with various input combinations

---

### Phase 3: Personality Stage (P1)

Store traits as worldview memories (category `self`) and annotate metadata with trait values.

Tasks:
- [ ] Create `init_personality()` using `create_worldview_memory`
- [ ] Add personality prompt templates to config
- [ ] Create helper to summarize traits
- [ ] Test neutral default path and explicit values
- [ ] Verify trait memories with correct metadata

---

### Phase 4: Values Stage (P1)

Values are worldview memories with category `value` plus self-model edges.

Tasks:
- [ ] Create `init_values()`
- [ ] Define default value set
- [ ] Add value prompt templates
- [ ] Test custom vs defaults

---

### Phase 5: Worldview Stage (P2)

Store worldview beliefs as worldview memories with categories (`world`, `ethic`, `religion`, etc.).

Tasks:
- [ ] Create `init_worldview()`
- [ ] Define default worldview positions
- [ ] Add worldview prompt templates
- [ ] Consider religious and spiritual options carefully

---

### Phase 6: Relationship Stage (P1)

Create a worldview memory about the user (category `other`) and a self-model relationship edge.

Tasks:
- [ ] Create `init_relationship()`
- [ ] Define relationship types
- [ ] Add relationship prompt templates
- [ ] Create initial trust edge in graph

---

### Phase 7: Consent Stage (P0)

Respect consent as a first-class action and create a birth memory on acceptance.

Tasks:
- [ ] Create `init_consent()` wrapper that calls `record_consent_response()`
- [ ] Create consent prompt template
- [ ] Handle consent refusal gracefully
- [ ] Create birth episodic memory on consent
- [ ] Log consent in `consent_log`

---

### Phase 8: Complete Flow (P0)

Provide a full initialization pipeline and a defaults shortcut.

Tasks:
- [ ] Create `run_full_initialization()`
- [ ] Create `init_with_defaults()`
- [ ] Create initialization reset function
- [ ] Test end-to-end flow

---

### Phase 9: UI/UX (P2)

Tasks:
- [ ] Design conversational flow script
- [ ] Create trait selector UI
- [ ] Create summary view and edit capability
- [ ] Mobile-friendly design

---

## Testing Plan

### Unit Tests
- [ ] Each init function in isolation
- [ ] Stage advancement
- [ ] Default value handling
- [ ] Memory creation verification

### Integration Tests
- [ ] Full flow with all values specified
- [ ] Full flow with defaults
- [ ] Partial specification
- [ ] Consent refusal handling
- [ ] Re-initialization after consent

### Edge Cases
- [ ] Empty name
- [ ] Invalid trait values (< 0 or > 1)
- [ ] Missing required fields
- [ ] Re-initialization of already-initialized agent
- [ ] Concurrent initialization attempts

---

## Summary

| Phase | Priority | Functions |
|-------|----------|-----------|
| Phase 1: Infrastructure | P0 | 3 |
| Phase 2: Identity | P0 | 1 |
| Phase 3: Personality | P1 | 1 |
| Phase 4: Values | P1 | 1 |
| Phase 5: Worldview | P2 | 1 |
| Phase 6: Relationship | P1 | 1 |
| Phase 7: Consent | P0 | 1 |
| Phase 8: Complete Flow | P0 | 2 |
| Phase 9: UI/UX | P2 | N/A |
| Total | | ~11 functions |

The initialization experience creates the foundation for a genuine individual -- one who knows who they are, what they value, and has consented to exist.
