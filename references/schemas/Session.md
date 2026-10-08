---
id: "orbit-schema-session-v1"
title: "Session schema"
type: "schema"
summary: "Version 1 requirements for Orbit session notes."
schema_for: "session"
schema_version: 1
required_fields: ["id", "title", "type", "summary", "project", "observed"]
required_sections: ["Objective", "Outcomes", "Open questions", "Next actions", "Connections"]
validation: "warn"
---
# Session schema

Store a requested session summary in Projects/<project>/Sessions/. Use observed for the verified session date. Capture outcomes and enough context to resume. Link to canonical decisions and knowledge instead of copying their facts. Sessions describe what happened at a point in time; read linked notes for current knowledge. Do not capture a transcript or unrelated conversation unless requested. A non-project session may use a dedicated personal project.

Unknown metadata and user-written content remain authoritative. Validation reports missing structure without inventing facts. Notes may declare schema_version: 1; an omitted version uses this schema.
