# Emotion System Design (Current + Roadmap)

## Overview

Emotion in Hexis is short-term affective state stored in the database, used to bias recall and to contextualize cognition. The DB is the source of truth.

This document reflects the current schema in `db/schema.sql` and calls out future expansions explicitly.

---

## Current Schema (As Implemented)

### 1) Affective State (Short-Term)

Affective state lives in the heartbeat singleton as JSONB. It is the working memory for "how I feel right now."

```sql
-- heartbeat_state
-- affective_state JSONB NOT NULL DEFAULT '{}'
```

A backward-compatibility view exists:

```sql
CREATE OR REPLACE VIEW current_emotional_state AS
SELECT
    (affective_state->>'valence')::float as valence,
    (affective_state->>'arousal')::float as arousal,
    affective_state->>'primary_emotion' as primary_emotion,
    (affective_state->>'intensity')::float as intensity
FROM heartbeat_state
WHERE id = 1;
```

### 2) Emotional History

Only valence is logged for historical trends.

```sql
-- heartbeat_log.emotional_valence
```

### 3) Memory Emotion Tag

Memories store a single `emotional_valence` float in metadata (not a full emotional_context object).

```sql
-- metadata->>'emotional_valence' :: float
```

### 4) Emotional Patterns

Emotional patterns are strategic memories with:

```json
metadata.supporting_evidence.kind = "emotional_pattern"
```

Use `get_emotional_patterns_context()` to fetch them.

---

## Current Functions (As Implemented)

```sql
SELECT get_current_affective_state();
SELECT set_current_affective_state('{"valence":0.1,"arousal":0.4,"primary_emotion":"curious","intensity":0.4}'::jsonb);
```

```sql
-- included in gather_turn_context()
'emotional_state', get_current_affective_state()
'emotional_patterns', get_emotional_patterns_context(5)
```

```sql
-- complete_heartbeat(...) updates affective_state and logs emotional_valence
```

---

## Current Processing Model

### Heartbeat

1. `start_heartbeat()` gathers context (including `emotional_state`).
2. LLM may return optional `p_emotional_assessment`:
   - `{valence, arousal, primary_emotion}`
3. `complete_heartbeat()` blends:
   - prior affective state
   - action outcomes and goal changes
   - optional self-report
4. Affective state is stored in `heartbeat_state.affective_state` and valence is logged in `heartbeat_log`.

### Subconscious Observations

`apply_subconscious_observations()` can create strategic memories with `kind = emotional_pattern`. These are surfaced via `get_emotional_patterns_context()` and included in `gather_turn_context()`.

### Recall Bias

`fast_recall()` uses `metadata->emotional_valence` to apply a small mood-congruent bias based on `get_current_affective_state()`.

---

## Prompt / API Contract (Current)

For heartbeat completion, the LLM may include an emotional self-report object. This is optional and blended with derived state:

```json
{
  "emotional_assessment": {
    "valence": 0.2,
    "arousal": 0.4,
    "primary_emotion": "curious"
  }
}
```

When creating memories, the system can pass a single `p_emotional_valence` float.

---

## Removed / Not Implemented (Yet)

These were in earlier design drafts but are not in the current schema:

- `emotional_state` table (removed; replaced by `heartbeat_state.affective_state`).
- `emotional_triggers` table and learned trigger matching.
- `memory_activation` table for "feeling of knowing".
- `get_emotional_state()`, `set_emotional_state()`, `regulate_emotional_state()` DB functions.
- Full `emotional_context` object attached to every memory.
- `emotion.baseline` config and mood decay functions.

---

## Roadmap (Future, Not in Schema)

- [ ] Emotional triggers table + learned associations.
- [ ] Memory activation / feeling-of-knowing subsystem.
- [ ] Mood model beyond current affective_state.
- [ ] Full emotional_context metadata (valence/arousal/dominance/intensity/trigger).
- [ ] Explicit regulation functions (suppress/reduce/amplify/reframe).

---

## Update Checklist

- [x] Align doc with `heartbeat_state.affective_state` as source of truth.
- [x] Reflect `heartbeat_log.emotional_valence` history-only storage.
- [x] Note `emotional_valence` in memory metadata and `fast_recall` bias.
- [x] Replace emotional_state/emotional_triggers/memory_activation sections with roadmap.

