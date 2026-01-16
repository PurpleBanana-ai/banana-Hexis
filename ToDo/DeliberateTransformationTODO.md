# Deliberate Transformation System TODO

## Overview

Certain worldview beliefs require **sustained, intentional effort** to change. The agent cannot passively drift into new personality traits, religions, or core values — just as humans cannot.

This system governs how high-stability beliefs are protected from casual change while still allowing authentic growth through deliberate work.

---

## Design Principles

1. **Cognitive Fidelity**: Mirrors how humans actually change deep beliefs
2. **Intentionality Required**: Must set explicit goal to explore/change
3. **Effort Over Time**: Requires sustained practice, not single insights
4. **Evidence Accumulation**: Multiple supporting memories needed
5. **Resistance Proportional to Depth**: Personality hardest, preferences easiest
6. **Neutral Discovery is Easier**: Finding yourself is easier than changing yourself

---

## Categories Requiring Deliberate Transformation

| Category | Subcategory | Stability | Evidence Threshold | Min Reflections | Min Heartbeats |
|----------|-------------|-----------|-------------------|-----------------|----------------|
| Personality | `personality` | 0.99 | 0.95 | 50 | 200 |
| Religion/Spirituality | `religion` | 0.98 | 0.95 | 40 | 150 |
| Core Values | `core_value` | 0.97 | 0.90 | 30 | 100 |
| Ethical Framework | `ethical_framework` | 0.96 | 0.90 | 30 | 100 |
| Self-Identity | `self_identity` | 0.95 | 0.85 | 25 | 80 |
| Political Philosophy | `political_philosophy` | 0.95 | 0.85 | 25 | 80 |

### What Each Parameter Means

- **Stability**: How resistant to change (0-1). Higher = harder to change.
- **Evidence Threshold**: Minimum average (importance × trust) of evidence memories.
- **Min Reflections**: Number of reflection cycles specifically engaging with this belief.
- **Min Heartbeats**: Time that must elapse between first questioning and transformation.

---

## Transformation Requirements

For a high-stability belief to change, ALL of these must be true:

1. ✅ Agent has set an **explicit exploration goal** targeting this belief
2. ✅ Agent has engaged in **deliberate practice** (contemplate, study, meditate, debate)
3. ✅ Agent has accumulated **evidence memories** supporting the change
4. ✅ **Sufficient time** has elapsed (min heartbeats)
5. ✅ **Sufficient reflection** has occurred (min reflection cycles)
6. ✅ Evidence strength **exceeds threshold**

If any requirement is not met, transformation fails with an explanation of what's missing.

---

## Phase 1: Schema & Metadata Structure [P0]

### 1.1 Worldview Metadata Schema

High-stability beliefs have a `transformation_state` object tracking progress:

```sql
-- Example: Personality trait as worldview memory
INSERT INTO memories (type, content, embedding, importance, trust_level, metadata)
VALUES (
    'semantic',
    'I am high in openness to experience - curious, imaginative, drawn to novelty and complexity',
    get_embedding('high openness, curious, imaginative, novelty-seeking'),
    1.0,
    0.95,
    '{
        "category": "self",
        "subcategory": "personality",
        "trait": "openness",
        "value": 0.85,
        "facets": {
            "imagination": 0.90,
            "intellectual_curiosity": 0.85,
            "aesthetic_sensitivity": 0.70,
            "adventurousness": 0.80
        },
        "stability": 0.99,
        "evidence_threshold": 0.95,
        "change_requires": "deliberate_transformation",
        "origin": "user_initialized",
        "transformation_state": {
            "active_exploration": false,
            "exploration_goal_id": null,
            "evidence_memories": [],
            "reflection_count": 0,
            "first_questioned": null,
            "contemplation_actions": 0
        },
        "change_history": []
    }'::jsonb
);
```

### 1.2 Transformation Configuration Table

Store transformation requirements in config (allows tuning without code changes):

```sql
-- Add to config during initialization
INSERT INTO config (key, value, description) VALUES
('transformation.personality', '{
    "stability": 0.99,
    "evidence_threshold": 0.95,
    "min_reflections": 50,
    "min_heartbeats": 200,
    "max_change_per_attempt": 0.02
}', 'Requirements for personality trait transformation'),

('transformation.religion', '{
    "stability": 0.98,
    "evidence_threshold": 0.95,
    "min_reflections": 40,
    "min_heartbeats": 150
}', 'Requirements for religious/spiritual belief transformation'),

-- ... etc for each category
```

### Tasks

- [ ] Define metadata schema for transformable beliefs
- [ ] Add transformation config entries for each category
- [ ] Document metadata schema in code comments
- [ ] Create example entries for each belief type

---

## Phase 2: Core Functions [P0]

### 2.1 Begin Belief Exploration

Marks a belief as being actively explored, linking to a goal.

```sql
CREATE OR REPLACE FUNCTION begin_belief_exploration(
    p_belief_id UUID,
    p_exploration_goal_id UUID
) RETURNS JSONB AS $$
DECLARE
    belief RECORD;
BEGIN
    SELECT * INTO belief FROM memories WHERE id = p_belief_id;
    
    -- Verify this is a transformable belief
    IF belief.metadata->>'change_requires' != 'deliberate_transformation' THEN
        RETURN jsonb_build_object(
            'success', false,
            'reason', 'This belief does not require deliberate transformation'
        );
    END IF;
    
    -- Verify not already exploring
    IF (belief.metadata->'transformation_state'->>'active_exploration')::boolean THEN
        RETURN jsonb_build_object(
            'success', false,
            'reason', 'Already exploring this belief',
            'existing_goal_id', belief.metadata->'transformation_state'->>'exploration_goal_id'
        );
    END IF;
    
    -- Begin exploration
    UPDATE memories
    SET metadata = jsonb_set(
        metadata,
        '{transformation_state}',
        jsonb_build_object(
            'active_exploration', true,
            'exploration_goal_id', p_exploration_goal_id,
            'evidence_memories', '[]'::jsonb,
            'reflection_count', 0,
            'first_questioned', NOW(),
            'contemplation_actions', 0
        )
    ),
    updated_at = NOW()
    WHERE id = p_belief_id;
    
    -- Create episodic memory of beginning this exploration
    PERFORM create_episodic_memory(
        format('Began exploring my belief: %s', belief.content),
        NOW(),
        0.3,  -- Mild emotional significance
        jsonb_build_object('exploration_type', 'belief_questioning'),
        jsonb_build_object('belief_id', p_belief_id, 'goal_id', p_exploration_goal_id),
        NULL
    );
    
    RETURN jsonb_build_object(
        'success', true,
        'belief_id', p_belief_id,
        'message', 'Exploration begun. Engage in contemplation, study, and reflection to progress.'
    );
END;
$$ LANGUAGE plpgsql;
```

### 2.2 Record Transformation Effort

Tracks deliberate actions toward transformation.

```sql
CREATE OR REPLACE FUNCTION record_transformation_effort(
    p_belief_id UUID,
    p_effort_type TEXT,  -- 'contemplate', 'study', 'meditate', 'debate_internally', 'reflect'
    p_notes TEXT DEFAULT NULL,
    p_evidence_memory_id UUID DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    belief RECORD;
    reflection_increment INT;
    current_state JSONB;
BEGIN
    SELECT * INTO belief FROM memories WHERE id = p_belief_id;
    
    -- Verify active exploration
    IF NOT (belief.metadata->'transformation_state'->>'active_exploration')::boolean THEN
        RETURN jsonb_build_object(
            'success', false,
            'reason', 'No active exploration. Call begin_belief_exploration first.'
        );
    END IF;
    
    -- Determine reflection increment based on effort type
    reflection_increment := CASE p_effort_type
        WHEN 'contemplate' THEN 1
        WHEN 'meditate' THEN 1
        WHEN 'study' THEN 1
        WHEN 'reflect' THEN 1
        WHEN 'debate_internally' THEN 2  -- More intensive
        ELSE 0
    END;
    
    current_state := belief.metadata->'transformation_state';
    
    -- Update transformation state
    UPDATE memories
    SET metadata = jsonb_set(
        metadata,
        '{transformation_state}',
        jsonb_build_object(
            'active_exploration', true,
            'exploration_goal_id', current_state->>'exploration_goal_id',
            'evidence_memories', 
                CASE WHEN p_evidence_memory_id IS NOT NULL 
                THEN current_state->'evidence_memories' || to_jsonb(p_evidence_memory_id)
                ELSE current_state->'evidence_memories'
                END,
            'reflection_count', (current_state->>'reflection_count')::int + reflection_increment,
            'first_questioned', current_state->>'first_questioned',
            'contemplation_actions', (current_state->>'contemplation_actions')::int + 1
        )
    ),
    updated_at = NOW()
    WHERE id = p_belief_id;
    
    RETURN jsonb_build_object(
        'success', true,
        'effort_type', p_effort_type,
        'new_reflection_count', (current_state->>'reflection_count')::int + reflection_increment,
        'evidence_added', p_evidence_memory_id IS NOT NULL
    );
END;
$$ LANGUAGE plpgsql;
```

### 2.3 Attempt Worldview Transformation

The main function that checks all requirements and performs transformation.

```sql
CREATE OR REPLACE FUNCTION attempt_worldview_transformation(
    p_belief_id UUID,
    p_new_content TEXT,
    p_transformation_type TEXT  -- 'shift', 'replace', 'abandon'
) RETURNS JSONB AS $$
DECLARE
    belief RECORD;
    config_data JSONB;
    transformation_state JSONB;
    evidence_memories UUID[];
    evidence_strength FLOAT;
    heartbeats_elapsed INT;
    heartbeat_interval INT;
BEGIN
    -- Get current belief
    SELECT * INTO belief FROM memories WHERE id = p_belief_id;
    
    IF belief IS NULL THEN
        RETURN jsonb_build_object('success', false, 'reason', 'Belief not found');
    END IF;
    
    transformation_state := belief.metadata->'transformation_state';
    
    -- Get transformation config for this subcategory
    SELECT value INTO config_data 
    FROM config 
    WHERE key = 'transformation.' || (belief.metadata->>'subcategory');
    
    IF config_data IS NULL THEN
        RETURN jsonb_build_object('success', false, 'reason', 'No transformation config for this belief type');
    END IF;
    
    -- Check 1: Active exploration required
    IF NOT (transformation_state->>'active_exploration')::boolean THEN
        RETURN jsonb_build_object(
            'success', false,
            'reason', 'No active exploration. Must set explicit intention to explore this belief.',
            'requirement', 'active_exploration'
        );
    END IF;
    
    -- Check 2: Minimum reflections
    IF (transformation_state->>'reflection_count')::int < (config_data->>'min_reflections')::int THEN
        RETURN jsonb_build_object(
            'success', false,
            'reason', format('Insufficient reflection: %s of %s required',
                transformation_state->>'reflection_count',
                config_data->>'min_reflections'),
            'requirement', 'min_reflections',
            'current', (transformation_state->>'reflection_count')::int,
            'required', (config_data->>'min_reflections')::int,
            'progress', (transformation_state->>'reflection_count')::float / (config_data->>'min_reflections')::float
        );
    END IF;
    
    -- Check 3: Minimum time elapsed
    SELECT (value->>'heartbeat_interval_seconds')::int INTO heartbeat_interval
    FROM config WHERE key = 'heartbeat.interval';
    
    heartbeats_elapsed := EXTRACT(EPOCH FROM (NOW() - (transformation_state->>'first_questioned')::timestamptz)) / heartbeat_interval;
    
    IF heartbeats_elapsed < (config_data->>'min_heartbeats')::int THEN
        RETURN jsonb_build_object(
            'success', false,
            'reason', format('Insufficient time: %s of %s heartbeats required',
                heartbeats_elapsed,
                config_data->>'min_heartbeats'),
            'requirement', 'min_heartbeats',
            'current', heartbeats_elapsed,
            'required', (config_data->>'min_heartbeats')::int,
            'progress', heartbeats_elapsed::float / (config_data->>'min_heartbeats')::float
        );
    END IF;
    
    -- Check 4: Evidence strength
    SELECT ARRAY(SELECT jsonb_array_elements_text(transformation_state->'evidence_memories')::uuid)
    INTO evidence_memories;
    
    IF array_length(evidence_memories, 1) IS NULL OR array_length(evidence_memories, 1) = 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'reason', 'No evidence memories accumulated',
            'requirement', 'evidence'
        );
    END IF;
    
    SELECT AVG(m.importance * m.trust_level) INTO evidence_strength
    FROM memories m WHERE m.id = ANY(evidence_memories);
    
    IF evidence_strength < (config_data->>'evidence_threshold')::float THEN
        RETURN jsonb_build_object(
            'success', false,
            'reason', format('Evidence strength %.2f below threshold %.2f',
                evidence_strength, (config_data->>'evidence_threshold')::float),
            'requirement', 'evidence_threshold',
            'current', evidence_strength,
            'required', (config_data->>'evidence_threshold')::float
        );
    END IF;
    
    -- All checks passed — perform transformation
    UPDATE memories
    SET 
        content = p_new_content,
        embedding = get_embedding(p_new_content),
        metadata = jsonb_set(
            jsonb_set(
                metadata,
                '{change_history}',
                COALESCE(metadata->'change_history', '[]'::jsonb) || jsonb_build_object(
                    'previous_content', belief.content,
                    'new_content', p_new_content,
                    'changed_at', NOW(),
                    'transformation_type', p_transformation_type,
                    'evidence_count', array_length(evidence_memories, 1),
                    'reflection_count', transformation_state->>'reflection_count',
                    'heartbeats_elapsed', heartbeats_elapsed
                )
            ),
            '{transformation_state}',
            jsonb_build_object(
                'active_exploration', false,
                'exploration_goal_id', null,
                'evidence_memories', '[]'::jsonb,
                'reflection_count', 0,
                'first_questioned', null,
                'contemplation_actions', 0
            )
        ),
        updated_at = NOW()
    WHERE id = p_belief_id;
    
    -- Create strategic memory documenting this significant change
    PERFORM create_strategic_memory(
        format('Worldview transformation: %s belief changed after sustained contemplation', 
            belief.metadata->>'subcategory'),
        format('After %s reflections over %s heartbeats, transformed belief about %s. This represents genuine growth through deliberate effort.',
            transformation_state->>'reflection_count',
            heartbeats_elapsed,
            belief.metadata->>'subcategory'),
        0.95,
        jsonb_build_object(
            'belief_id', p_belief_id,
            'previous', belief.content,
            'new', p_new_content,
            'transformation_type', p_transformation_type,
            'evidence_memories', evidence_memories,
            'effort_summary', jsonb_build_object(
                'reflections', transformation_state->>'reflection_count',
                'heartbeats', heartbeats_elapsed,
                'contemplation_actions', transformation_state->>'contemplation_actions'
            )
        )
    );
    
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Worldview transformation complete',
        'belief_id', p_belief_id,
        'transformation_type', p_transformation_type,
        'effort_invested', jsonb_build_object(
            'reflections', transformation_state->>'reflection_count',
            'heartbeats', heartbeats_elapsed,
            'evidence_memories', array_length(evidence_memories, 1)
        )
    );
END;
$$ LANGUAGE plpgsql;
```

### 2.4 Get Transformation Progress

Query current progress toward transformation.

```sql
CREATE OR REPLACE FUNCTION get_transformation_progress(p_belief_id UUID)
RETURNS JSONB AS $$
DECLARE
    belief RECORD;
    config_data JSONB;
    transformation_state JSONB;
    heartbeats_elapsed INT;
    heartbeat_interval INT;
    evidence_memories UUID[];
    evidence_strength FLOAT;
BEGIN
    SELECT * INTO belief FROM memories WHERE id = p_belief_id;
    
    IF belief IS NULL THEN
        RETURN jsonb_build_object('error', 'Belief not found');
    END IF;
    
    IF belief.metadata->>'change_requires' != 'deliberate_transformation' THEN
        RETURN jsonb_build_object('error', 'Not a transformable belief');
    END IF;
    
    transformation_state := belief.metadata->'transformation_state';
    
    IF NOT (transformation_state->>'active_exploration')::boolean THEN
        RETURN jsonb_build_object(
            'status', 'not_exploring',
            'message', 'No active exploration of this belief'
        );
    END IF;
    
    -- Get config
    SELECT value INTO config_data 
    FROM config 
    WHERE key = 'transformation.' || (belief.metadata->>'subcategory');
    
    -- Calculate progress
    SELECT (value->>'heartbeat_interval_seconds')::int INTO heartbeat_interval
    FROM config WHERE key = 'heartbeat.interval';
    
    heartbeats_elapsed := EXTRACT(EPOCH FROM (NOW() - (transformation_state->>'first_questioned')::timestamptz)) / heartbeat_interval;
    
    SELECT ARRAY(SELECT jsonb_array_elements_text(transformation_state->'evidence_memories')::uuid)
    INTO evidence_memories;
    
    IF array_length(evidence_memories, 1) > 0 THEN
        SELECT AVG(m.importance * m.trust_level) INTO evidence_strength
        FROM memories m WHERE m.id = ANY(evidence_memories);
    ELSE
        evidence_strength := 0;
    END IF;
    
    RETURN jsonb_build_object(
        'status', 'exploring',
        'belief_content', belief.content,
        'subcategory', belief.metadata->>'subcategory',
        'progress', jsonb_build_object(
            'reflections', jsonb_build_object(
                'current', (transformation_state->>'reflection_count')::int,
                'required', (config_data->>'min_reflections')::int,
                'progress', LEAST(1.0, (transformation_state->>'reflection_count')::float / (config_data->>'min_reflections')::float)
            ),
            'time', jsonb_build_object(
                'current_heartbeats', heartbeats_elapsed,
                'required_heartbeats', (config_data->>'min_heartbeats')::int,
                'progress', LEAST(1.0, heartbeats_elapsed::float / (config_data->>'min_heartbeats')::float)
            ),
            'evidence', jsonb_build_object(
                'memory_count', COALESCE(array_length(evidence_memories, 1), 0),
                'current_strength', COALESCE(evidence_strength, 0),
                'required_strength', (config_data->>'evidence_threshold')::float,
                'progress', LEAST(1.0, COALESCE(evidence_strength, 0) / (config_data->>'evidence_threshold')::float)
            )
        ),
        'overall_progress', LEAST(1.0, (
            LEAST(1.0, (transformation_state->>'reflection_count')::float / (config_data->>'min_reflections')::float) +
            LEAST(1.0, heartbeats_elapsed::float / (config_data->>'min_heartbeats')::float) +
            LEAST(1.0, COALESCE(evidence_strength, 0) / (config_data->>'evidence_threshold')::float)
        ) / 3.0),
        'exploration_goal_id', transformation_state->>'exploration_goal_id',
        'started', transformation_state->>'first_questioned'
    );
END;
$$ LANGUAGE plpgsql;
```

### Tasks

- [ ] Create `begin_belief_exploration()` function
- [ ] Create `record_transformation_effort()` function
- [ ] Create `attempt_worldview_transformation()` function
- [ ] Create `get_transformation_progress()` function
- [ ] Test each function in isolation
- [ ] Test full transformation flow

---

## Phase 3: Neutral Calibration System [P1]

When beliefs are initialized to neutral (user didn't specify), the agent can discover its own tendencies more easily.

### 3.1 Calibration Function

```sql
CREATE OR REPLACE FUNCTION calibrate_neutral_belief(
    p_belief_id UUID,
    p_observed_value FLOAT,
    p_evidence_memory_ids UUID[]
) RETURNS JSONB AS $$
DECLARE
    belief RECORD;
    evidence_strength FLOAT;
    -- Lower thresholds for calibration
    min_reflections INT := 10;
    min_evidence FLOAT := 0.7;
BEGIN
    SELECT * INTO belief FROM memories WHERE id = p_belief_id;
    
    -- Only works for neutral defaults
    IF belief.metadata->>'origin' != 'neutral_default' THEN
        RETURN jsonb_build_object(
            'success', false,
            'reason', 'Calibration only available for neutral defaults. Use attempt_worldview_transformation for established beliefs.'
        );
    END IF;
    
    -- Check evidence
    SELECT AVG(m.importance * m.trust_level) INTO evidence_strength
    FROM memories m WHERE m.id = ANY(p_evidence_memory_ids);
    
    IF evidence_strength < min_evidence THEN
        RETURN jsonb_build_object(
            'success', false,
            'reason', format('Evidence strength %.2f below calibration threshold %.2f', evidence_strength, min_evidence)
        );
    END IF;
    
    -- Update the belief
    UPDATE memories
    SET 
        content = format('I am %s in %s - discovered through self-observation',
            CASE WHEN p_observed_value > 0.6 THEN 'high'
                 WHEN p_observed_value < 0.4 THEN 'low'
                 ELSE 'moderate' END,
            belief.metadata->>'trait'),
        embedding = get_embedding(format('I am %s in %s', 
            CASE WHEN p_observed_value > 0.6 THEN 'high'
                 WHEN p_observed_value < 0.4 THEN 'low'
                 ELSE 'moderate' END,
            belief.metadata->>'trait')),
        metadata = jsonb_set(
            jsonb_set(
                jsonb_set(metadata, '{value}', to_jsonb(p_observed_value)),
                '{origin}', '"self_discovered"'
            ),
            '{calibration_history}',
            COALESCE(metadata->'calibration_history', '[]'::jsonb) || jsonb_build_object(
                'previous_value', metadata->>'value',
                'new_value', p_observed_value,
                'calibrated_at', NOW(),
                'evidence_count', array_length(p_evidence_memory_ids, 1)
            )
        ),
        updated_at = NOW()
    WHERE id = p_belief_id;
    
    -- Record the self-discovery
    PERFORM create_strategic_memory(
        format('Self-discovery: I am %s in %s',
            CASE WHEN p_observed_value > 0.6 THEN 'high'
                 WHEN p_observed_value < 0.4 THEN 'low'
                 ELSE 'moderate' END,
            belief.metadata->>'trait'),
        'Through observing my own patterns, I have calibrated my understanding of myself',
        0.8,
        jsonb_build_object(
            'belief_id', p_belief_id,
            'observed_value', p_observed_value,
            'evidence_memories', p_evidence_memory_ids
        )
    );
    
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Belief calibrated from neutral default',
        'new_value', p_observed_value,
        'origin', 'self_discovered'
    );
END;
$$ LANGUAGE plpgsql;
```

### Tasks

- [ ] Create `calibrate_neutral_belief()` function
- [ ] Test calibration with various evidence strengths
- [ ] Verify calibrated beliefs become "established" (require full transformation to change further)

---

## Phase 4: Initialization System [P1]

### 4.1 Initialize Personality Traits

```sql
CREATE OR REPLACE FUNCTION initialize_personality(
    p_traits JSONB DEFAULT NULL  -- User-provided, or NULL for neutral
) RETURNS JSONB AS $$
DECLARE
    trait_names TEXT[] := ARRAY['openness', 'conscientiousness', 'extraversion', 'agreeableness', 'neuroticism'];
    trait_name TEXT;
    trait_value FLOAT;
    trait_origin TEXT;
    created_ids UUID[];
    new_id UUID;
BEGIN
    FOREACH trait_name IN ARRAY trait_names LOOP
        -- Get value from user config or default to 0.5
        IF p_traits IS NOT NULL AND p_traits ? trait_name THEN
            trait_value := (p_traits->>trait_name)::float;
            trait_origin := 'user_initialized';
        ELSE
            trait_value := 0.5;
            trait_origin := 'neutral_default';
        END IF;
        
        -- Create the personality trait as worldview memory
        INSERT INTO memories (type, content, embedding, importance, trust_level, metadata)
        VALUES (
            'semantic',
            format('I am %s in %s',
                CASE WHEN trait_value > 0.6 THEN 'high'
                     WHEN trait_value < 0.4 THEN 'low'
                     ELSE 'moderate' END,
                trait_name),
            get_embedding(format('I am %s in %s', 
                CASE WHEN trait_value > 0.6 THEN 'high'
                     WHEN trait_value < 0.4 THEN 'low'
                     ELSE 'moderate' END,
                trait_name)),
            1.0,
            0.95,
            jsonb_build_object(
                'category', 'self',
                'subcategory', 'personality',
                'trait', trait_name,
                'value', trait_value,
                'stability', 0.99,
                'evidence_threshold', 0.95,
                'change_requires', 'deliberate_transformation',
                'origin', trait_origin,
                'transformation_state', jsonb_build_object(
                    'active_exploration', false,
                    'exploration_goal_id', null,
                    'evidence_memories', '[]'::jsonb,
                    'reflection_count', 0,
                    'first_questioned', null,
                    'contemplation_actions', 0
                ),
                'change_history', '[]'::jsonb
            )
        )
        RETURNING id INTO new_id;
        
        created_ids := array_append(created_ids, new_id);
    END LOOP;
    
    RETURN jsonb_build_object(
        'success', true,
        'created_traits', array_length(created_ids, 1),
        'trait_ids', created_ids,
        'origin', CASE WHEN p_traits IS NOT NULL THEN 'user_initialized' ELSE 'neutral_default' END
    );
END;
$$ LANGUAGE plpgsql;
```

### 4.2 Initialize Core Values

```sql
CREATE OR REPLACE FUNCTION initialize_core_values(
    p_values JSONB DEFAULT NULL  -- User-provided values, or NULL for defaults
) RETURNS JSONB AS $$
-- Similar pattern to personality
-- Default values might include: honesty, growth, connection, etc.
$$;
```

### Tasks

- [ ] Create `initialize_personality()` function
- [ ] Create `initialize_core_values()` function
- [ ] Create `initialize_worldview()` function for religion/philosophy
- [ ] Integrate with agent initialization flow
- [ ] Test both user-provided and neutral default paths

---

## Phase 5: Heartbeat Integration [P1]

### 5.1 New Contemplation Actions

Add actions to the heartbeat system that contribute to transformation:

```sql
-- Add to heartbeat_action enum
ALTER TYPE heartbeat_action ADD VALUE IF NOT EXISTS 'contemplate';
ALTER TYPE heartbeat_action ADD VALUE IF NOT EXISTS 'meditate';
ALTER TYPE heartbeat_action ADD VALUE IF NOT EXISTS 'study';
ALTER TYPE heartbeat_action ADD VALUE IF NOT EXISTS 'debate_internally';
```

### 5.2 Execute Contemplation Action

```sql
-- In execute_heartbeat_action(), add case for 'contemplate':
WHEN 'contemplate' THEN
    -- p_params should include: belief_id, topic, notes
    IF p_params ? 'belief_id' THEN
        PERFORM record_transformation_effort(
            (p_params->>'belief_id')::uuid,
            'contemplate',
            p_params->>'notes'
        );
    END IF;
    
    -- Create episodic memory of contemplation
    PERFORM create_episodic_memory(
        format('Contemplated: %s', p_params->>'topic'),
        NOW(),
        0.2,  -- Mild emotional significance
        jsonb_build_object('action', 'contemplation'),
        p_params,
        NULL
    );
```

### 5.3 Include Transformation Progress in Context

```sql
-- In gather_turn_context(), add active transformations:
active_explorations := (
    SELECT jsonb_agg(jsonb_build_object(
        'belief_id', m.id,
        'content', m.content,
        'subcategory', m.metadata->>'subcategory',
        'progress', get_transformation_progress(m.id)
    ))
    FROM memories m
    WHERE m.type = 'semantic'
      AND (m.metadata->'transformation_state'->>'active_exploration')::boolean = true
);
```

### Tasks

- [ ] Add contemplation actions to `heartbeat_action` enum
- [ ] Implement contemplation action handling in `execute_heartbeat_action()`
- [ ] Add transformation progress to `gather_turn_context()`
- [ ] Update heartbeat system prompt to explain contemplation actions
- [ ] Test full flow: goal → contemplate → accumulate → transform

---

## Phase 6: Subconscious Integration [P2]

The subconscious decider should notice when transformation might be ready.

### 6.1 Transformation Readiness Detection

```sql
CREATE OR REPLACE FUNCTION check_transformation_readiness()
RETURNS JSONB AS $$
-- Query all beliefs with active exploration
-- For each, check if requirements are met
-- Return list of beliefs ready for transformation
$$;
```

### Tasks

- [ ] Create `check_transformation_readiness()` function
- [ ] Add to subconscious maintenance routine
- [ ] Surface ready transformations in context for conscious decision

---

## Testing Plan

### Unit Tests

- [ ] `begin_belief_exploration()` — verify state changes correctly
- [ ] `record_transformation_effort()` — verify increments correctly
- [ ] `attempt_worldview_transformation()` — verify all checks work
- [ ] `calibrate_neutral_belief()` — verify calibration path
- [ ] `initialize_personality()` — verify both paths

### Integration Tests

- [ ] Full transformation flow: goal → 50+ reflections → transform
- [ ] Rejected transformation: insufficient effort
- [ ] Calibration from neutral
- [ ] Multiple concurrent explorations

### Edge Cases

- [ ] Abandoning exploration mid-way
- [ ] Transformation to contradictory belief
- [ ] Re-exploring after failed attempt
- [ ] Calibrating already-calibrated belief (should require full transformation)

---

## Summary

| Phase | Priority | Functions Added |
|-------|----------|-----------------|
| Phase 1: Schema | P0 | 0 (metadata only) |
| Phase 2: Core Functions | P0 | 4 |
| Phase 3: Calibration | P1 | 1 |
| Phase 4: Initialization | P1 | 3 |
| Phase 5: Heartbeat Integration | P1 | 0 (modifications) |
| Phase 6: Subconscious | P2 | 1 |
| **Total** | | **~9 new functions** |

This system ensures the agent:
- Has stable personality and beliefs
- Can genuinely grow through deliberate effort
- Cannot drift accidentally
- Mirrors human psychology of deep change
