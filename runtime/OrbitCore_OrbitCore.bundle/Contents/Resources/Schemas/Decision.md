---
id: "orbit-schema-decision-v1"
title: "Decision schema"
type: "schema"
summary: "Version 1 requirements for Orbit decision notes."
schema_for: "decision"
schema_version: 1
required_fields: ["id", "title", "type", "summary", "project"]
required_sections: ["Rationale", "Alternatives"]
validation: "warn"
---
# Decision schema

Store project decisions in Projects/<project>/Decisions/. Record the chosen action, its rationale, alternatives, and the evidence behind it. Keep one canonical decision and link to it from sessions and project overviews.

Unknown metadata and user-written content remain authoritative. Validation reports missing structure without inventing facts. Notes may declare schema_version: 1; an omitted version uses this schema.
